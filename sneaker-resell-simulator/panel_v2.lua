--[[
    Sneaker Panel v2 — Sneaker Resell Simulator (PlaceId 12991635726)
    UI: Obsidian (deividcomsono)

    Ground-up rebuild around one idea the v1 panel did not have:
    the panel decides HOW to sell before it decides WHAT to buy.

        profit(unit) = MaxSellPrice * rate(channel) - offerPrice

    Cashier pays 0.55x flat. A Perfect bar sale pays 1.10x. So the SAME offer is
    either a 9% margin or a 64% margin depending only on which drain you use.
    Every filter in this panel is derived from that number instead of guessed.

    File layout:
        [1] CONST     - game facts. Game update => edit here only.
        [2] CORE      - state, config, paths, safety.
        [3] ECON      - measured payout rates, break-even, expected profit, throughput.
        [4] FEATURES  - Buy / Slots / Sell router / Bar / Trade / Market / Boxes.
        [5] DIRECTOR  - phase machine + tuner. The "stay optimal" part.
        [6] UI        - Obsidian tabs; widgets only read/write Config.
        [7] HARDENING - watchdog, kill switch, teardown.

    Mechanics verified live; see sneaker-panel-spec.md.
]]

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local UIS         = game:GetService("UserInputService")
local RunService  = game:GetService("RunService")
local TweenService= game:GetService("TweenService")
local Lighting    = game:GetService("Lighting")

local LP = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")

if getgenv().__SNEAKER_PANEL then pcall(getgenv().__SNEAKER_PANEL.Unload) end
if getgenv().__SNEAKER_PANEL_V2 then pcall(getgenv().__SNEAKER_PANEL_V2.Unload) end

--=========================================================================
-- [1] CONST
--=========================================================================

local Remotes          = RS:WaitForChild("RemoteEvents")
local SneakerModule    = require(RS:WaitForChild("SneakerModule"))
local MysteryBoxModule = require(RS:WaitForChild("MysteryBoxModule"))

local CONST = {
    Sneakers       = SneakerModule.sneakers,
    BoughtSentinel = "Bought",

    Remote = {
        Buy         = Remotes:WaitForChild("BuySneakerFunction"),   -- ("OfferN") -> bool
        Refresh     = Remotes:WaitForChild("RefreshPageFunction"),  -- () -> {names} | nil
        TradeUp     = Remotes:WaitForChild("TradeUpEvent"),         -- (key, {names}) -> reward
        BuyShoesApp = Remotes:WaitForChild("BuyShoesApp"),          -- (name) -> true | err
        ShoesData   = Remotes:WaitForChild("GetShoesAppData"),
        BuyNewOffer = Remotes:WaitForChild("BuyNewOfferFunction"),
        Cashier     = Remotes:WaitForChild("CashierEvents"),
    },

    -- Measured reroll cooldown (swept at fixed spacings): 1.1s is the throughput optimum.
    -- Racing under it is strictly worse - a refused refresh still pays the confirm wait.
    RefreshCooldown = { Min = 1.1, Throttled = 5.1, Max = 8.0, Step = 0.4, Decay = 0.85, ThrottleAt = 5000 },

    Rarities    = { "Common", "Uncommon", "Epic", "Legendary", "Special", "Grail", "Limited", "Legacy" },
    CashierRate = 0.55,                                        -- measured, 3 clean samples, zero variance
    Bands       = { Perfect = 1.1, Good = 1.0, Miss = 0.85 },  -- client table u14

    TradeUps    = SneakerModule.TradeUps,
    UnlockCosts = { 500, 3000, 8000, 15000, 35000, 75000, 100000, 160000, 300000, 500000,
                    850000, 1250000, 2000000, 4500000, 7500000, 15000000, 25000000, 50000000 },
    MaxSlots    = 16,

    LimitedShop = SneakerModule.LimitedShopSneaker,   -- [utcHour % 6 + 1]
    GrailRot    = SneakerModule.GrailRotationSneaker, -- [utcHour % #list + 1]
    MoneyBoxes  = MysteryBoxModule.MoneyBoxes,        -- Random.new(yday + h*h)
    BoxPrices   = MysteryBoxModule.Prices,
}

-- Paths resolve live, never cached: PCScreenGui/MainScreenGui have ResetOnSpawn, so a
-- reference taken at load points at an orphan after the first death - and an orphan does
-- not throw, it just returns nothing, so loops "run" forever against a ghost GUI.
local Resolve = {
    PCScroll = function()
        local gui = PlayerGui:FindFirstChild("PCScreenGui")
        local sf  = gui and gui:FindFirstChild("ScreenFrame")
        local eb  = sf and sf:FindFirstChild("eBuyFrame")
        return eb and eb:FindFirstChild("ScrollingFrame")
    end,
    SellAnim   = function()
        local gui = PlayerGui:FindFirstChild("MainScreenGui")
        return gui and gui:FindFirstChild("SellAnimFrame")
    end,
    MainGui    = function() return PlayerGui:FindFirstChild("MainScreenGui") end,
    Sellable   = function()
        local inv = LP:FindFirstChild("Inventory")
        return inv and inv:FindFirstChild("SellableInventory")
    end,
    Unsellable = function()
        local inv = LP:FindFirstChild("Inventory")
        return inv and inv:FindFirstChild("UnsellableInventory")
    end,
    Money      = function()
        local ls = LP:FindFirstChild("leaderstats")
        return ls and ls:FindFirstChild("Money")
    end,
}

local Paths = setmetatable({}, { __index = function(_, k)
    local fn = Resolve[k]
    return fn and fn() or nil
end })

local function pathsReady()
    return Paths.PCScroll ~= nil and Paths.Money ~= nil and Paths.Sellable ~= nil
end

local function money()
    local m = Paths.Money
    return m and m.Value or 0
end

local function offerFrames()
    local scroll = Paths.PCScroll
    if not scroll then return {} end
    local out = {}
    for _, f in ipairs(scroll:GetChildren()) do
        if f:IsA("GuiObject") and f.Name:match("^Offer%d+$") then out[#out + 1] = f end
    end
    table.sort(out, function(a, b)
        return tonumber(a.Name:match("%d+")) < tonumber(b.Name:match("%d+"))
    end)
    return out
end

-- The refresh button inside PCScreenGui is a decoy (PCLocalScript reads it into `_`).
-- The live handler sits on the PC model in the world.
local function realRefreshButton()
    local stores = workspace:FindFirstChild("Stores")
    local store  = stores and stores:FindFirstChild(LP.Name .. "Store")
    local pc     = store and store:FindFirstChild("PC")
    local rb     = pc and pc:FindFirstChild("RefreshButton")
    local sg     = rb and rb:FindFirstChild("SurfaceGui")
    return sg and sg:FindFirstChild("RefreshButton")
end

--=========================================================================
-- [2] CORE
--=========================================================================

local Panel = {
    Running   = {},        -- feature -> true while its loop lives
    Beat      = {},        -- feature -> os.clock() of last completed pass
    Restarts  = {},
    Log       = {},
    Spent     = 0,
    Bought    = 0,
    Sold      = 0,
    BarSales  = 0,
    BarAimed  = 0,
    Earned    = 0,         -- cash received from sales this session
    RefreshOK = 0,
    RefreshMiss = 0,
    RefreshExtra = 0,
    DirtySamples = 0,      -- contaminated rate samples, discarded rather than learned from
    RefusedTotal = 0,      -- cumulative; Panel.Refused is a STREAK and resets on every success
    Refused      = 0,
    StartMoney = nil,
    StartClock = os.clock(),
    Phase     = "Idle",
}

local Perf   -- forward declared: UI builds the toggle before the perf block exists

--=========================================================================
-- CONFIG - defaults are the max-money profile, not a neutral one.
--
-- The whole default set follows from three measured numbers:
--   cashier 0.55x, bar-Perfect 1.10x, offers land at 2.1-2.3x MaxSellPrice.
-- Therefore:
--   * Bar selling is worth ~6.7x the PROFIT of a cashier sale on the same unit
--     (0.645 vs 0.095 of MaxSellPrice at ROI 2.2), so bar is on by default and
--     the cashier is demoted to a dump valve for cheap stock.
--   * Filters are profit-based, not rarity-based: rarity does not appear in the
--     payout formula at all, so every rarity is bought when the ratio is right.
--   * Slot unlocks scale rolls-per-refresh linearly and are the only compounding
--     purchase in the game, so auto-upgrade runs to 16 with no cash reserved
--     (measured: reserving stalls the very engine that earns the slot).
--=========================================================================
local Config = {
    ----------------------------------------------------------------- safety
    SpendCap     = 0,                    -- 0 = unlimited
    KillKey      = Enum.KeyCode.F4,
    PerfKey      = Enum.KeyCode.F5,
    PanicSell    = false,                -- dump everything when the kill switch fires

    ----------------------------------------------------------------- director
    Director     = true,                 -- the money mode: phase machine + tuner
    ArmOnStart   = true,                 -- Director.Start() switches buy/sell/upgrade on once
    Preset       = "Max Money",
    TuneEvery    = 20,                   -- seconds between tuner passes
    AutoROI      = true,                 -- derive MinROI from the live sell rate
    MarginPct    = 12,                   -- profit margin demanded over break-even
    AutoMaxUnit  = true,                 -- cap unit price as a share of bankroll
    MaxUnitPct   = 25,                   -- % of cash the priciest single buy may take
    AutoBarValue = true,                 -- split bar/cashier stock at the live median

    ----------------------------------------------------------------- acquisition
    -- OFF. Claiming needs the character walked onto a pad and a chooser handler pressed;
    -- the handler fires but dies at its own yield, so it only ever completed on the focused
    -- window, and the walking is what put clients at risk. Claim manually, then run the farm.
    AutoClaim    = false,
    ClaimHop     = false,                -- opt-in: rejoining is indistinguishable from a crash to a watching human, so never do it unasked
    MaxHops      = 10,
    AutoBuy      = false,
    BuyRarities  = { Common = true, Uncommon = true, Epic = true, Legendary = true,
                     Special = true, Grail = true, Limited = true, Legacy = true },
    MinROI       = 2.00,                 -- manual fallback when AutoROI is off
    MaxUnitPrice = 50000,                -- manual fallback when AutoMaxUnit is off
    MinUnitValue = 0,                    -- ignore sneakers under this MaxSellPrice
    BuyDelay     = 0,                    -- measured: BuySneakerFunction is not rate limited
    BuyBurst     = true,                 -- whole page in ~0.07s vs ~0.74s walked
    BuyReturnToPC= true,
    AutoReinvest = true,                 -- out of cash -> liquidate -> keep buying
    ReinvestVia  = "Router",             -- "Router" | "Cashier" | "NPC bar"

    ----------------------------------------------------------------- slots
    -- OFF by default. Slots are the strongest multiplier in the game (a 15-slot client
    -- measured ~89k/min against ~40k at 10), so turn this on deliberately - but the unlock
    -- costs run 500 -> 50,000,000 and a rejoining client boots on these defaults unattended.
    AutoUpgrade  = false,
    -- The hard stop. While true, NOTHING automatic can unlock a slot - not the Director, not
    -- a restored config, not a toggle flipped by a preset. Only the button in the UI.
    SlotsManualOnly = true,
    TargetSlots  = 16,
    ReservePct   = 0,                    -- measured: >0 freezes the farm, do not raise

    ----------------------------------------------------------------- liquidation
    SellRouter   = true,                 -- value split: bar the good stock, dump the rest
    BarMinValue  = 3000,                 -- MaxSellPrice at or above this -> bar sell
    BarBatch     = 15,                   -- bar-grade units to accumulate before a sell trip
    SellMode     = "Keep One",           -- "Keep One" | "Everything"
    SellAtUnits  = 25,                   -- inventory units that trigger a dump
    InvHardCap   = 120,                  -- above this, dump regardless of value

    AutoSell     = false,                -- plain cashier loop (router off / no travel)
    -- Bar selling pays 1.115x against the cashier's 0.55x, but it walks the character to an
    -- NPC and blocks the PC reroll for the whole sale. Off by default: a cold boot should
    -- never start moving a character on its own.
    AutoBar      = false,
    BarTarget    = "Perfect",
    BarAcceptGood= true,
    BarAutoLead  = true,
    BarLead      = 1.0,
    BarApproach  = false,
    BarAutoClose = true,
    BarReturn    = true,
    BarTunnel    = true,
    BarTunnelDepth = 25,
    BarTweenSpeed  = 60,

    ----------------------------------------------------------------- market
    WatchTarget  = "",                   -- limited-shop sneaker to snipe
    LimitedSnipe = false,
    SnipeLead    = 30,                   -- seconds before the UTC hour to travel
    AutoDrops    = false,                -- SHOES app drop sniper
    DropMaxPrice = 0,                    -- 0 = any
    BoxAutoOpen  = true,                 -- drive the game's own MysteryBoxAutoOpen

    ----------------------------------------------------------------- craft
    TradeRecipe  = "EpicTradeUp",
    AutoTrade    = false,
    TradeKeepOne = true,                 -- never consume the last copy of an index line

    ----------------------------------------------------------------- system
    PerfMode     = false,
    PerfFps      = 30,                   -- below ~30 the bar minigame cannot hit Perfect
    PollEvery    = 0.5,                  -- label repaint interval
}

-- Presets are sparse overlays applied over the defaults.
local PRESETS = {
    ["Max Money"] = {
        Director = true, AutoBuy = true, AutoBar = true, AutoSell = true,
        SellRouter = true, BuyBurst = true, BarApproach = true, AutoReinvest = true,
        AutoROI = true, MarginPct = 12, AutoMaxUnit = true, PerfMode = false,
    },
    ["AFK Safe"] = {
        Director = true, AutoBuy = true, AutoBar = true, AutoSell = true,
        SellRouter = true, BuyBurst = false, BuyDelay = 0.15, BarApproach = true,
        AutoROI = true, MarginPct = 25, AutoMaxUnit = true, MaxUnitPct = 10,
    },
    ["No Travel"] = {   -- cashier only, never moves the character
        Director = true, AutoBuy = true, AutoBar = false, AutoSell = true,
        SellRouter = false, BarApproach = false, AutoROI = true, MarginPct = 12,
        SellAtUnits = 20, ReinvestVia = "Cashier",
    },
    ["Fleet"] = {       -- many clients on one machine
        Director = true, AutoBuy = true, AutoBar = false, AutoSell = true,
        SellRouter = false, BuyBurst = true, PerfMode = true, PollEvery = 2,
        ReinvestVia = "Cashier",
    },
    ["Collector"] = {   -- index / trade-up completion, money secondary
        Director = false, AutoBuy = true, AutoBar = false, AutoSell = false,
        SellRouter = false, AutoTrade = true, BoxAutoOpen = true, AutoROI = false, MinROI = 1.0,
    },
}

----------------------------------------------------------------- helpers
local function beat(name) Panel.Beat[name] = os.clock() end

-- Loop ownership. A stop sets Running[name]=nil, but the old coroutine is usually parked in
-- a wait; if a start (watchdog restart, quick UI off/on) lands before it wakes, it saw
-- Running=true again and kept going - two loops buying off one budget. Each start takes a
-- fresh generation and a loop only lives while the generation is still its own.
Panel.Gen = {}
local function newGen(name)
    Panel.Gen[name] = (Panel.Gen[name] or 0) + 1
    return Panel.Gen[name]
end
local function live(name, gen)
    return Panel.Running[name] ~= nil and Panel.Gen[name] == gen
end

local function log(fmt, ...)
    local line = ("[%s] "):format(os.date("%H:%M:%S")) .. string.format(fmt, ...)
    Panel.Log[#Panel.Log + 1] = line
    if #Panel.Log > 200 then table.remove(Panel.Log, 1) end
    if Panel.OnLog then Panel.OnLog(line) end
end

local function notify(msg, dur)
    if Panel.Library then pcall(function() Panel.Library:Notify(msg, dur or 4) end) end
    log("%s", msg)
end

local function commas(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function sneakerData(name) return name and CONST.Sneakers[name] or nil end

local function maxSell(name)
    local d = sneakerData(name)
    return d and d.MaxSellPrice or 0
end

local function roiOf(name, price)
    if not price or price <= 0 then return 0 end
    return maxSell(name) / price
end

local function slotsNow() return LP.PcProgressOffer.Value end

local function nextSlotCost()
    local i = slotsNow()
    if i >= CONST.MaxSlots then return nil end
    return CONST.UnlockCosts[i]
end

local function unitsHeld()
    local n = 0
    local inv = Paths.Sellable
    if not inv then return 0 end
    for _, c in ipairs(inv:GetChildren()) do n = n + c.Value end
    return n
end

-- Every held line as { Name, Count, Value }, value-sorted. One walk, shared by the router,
-- the tuner and the UI, which each used to do their own.
local function stockLines()
    local out, total, units = {}, 0, 0
    local inv = Paths.Sellable
    if not inv then return out, 0, 0 end
    for _, c in ipairs(inv:GetChildren()) do
        if c.Value > 0 then
            local v = maxSell(c.Name)
            out[#out + 1] = { Name = c.Name, Count = c.Value, Value = v }
            total = total + v * c.Value
            units = units + c.Value
        end
    end
    table.sort(out, function(a, b) return a.Value > b.Value end)
    return out, total, units
end

-- Units a dump can actually move. Keep One pins a copy of every line, and counting those
-- made the dump fire every 2s once the distinct-line count alone crossed the threshold.
local function sellableUnits()
    local keep = (Config.SellMode == "Keep One") and 1 or 0
    local n = 0
    for _, l in ipairs(stockLines()) do n = n + math.max(0, l.Count - keep) end
    return n
end

local function pressButton(signal)
    local ok, conns = pcall(getconnections, signal)
    if not ok then return false end
    local n = 0
    for _, c in ipairs(conns) do
        pcall(function() c:Fire() end)
        n = n + 1
    end
    return n > 0
end

-- Nothing works before a store is claimed: PCLocalScript itself blocks on Plot.Value.
local function storeReady()
    local plot = LP:FindFirstChild("Plot")
    if not plot or plot.Value == "" then return false, "no store claimed yet" end
    local loaded = LP:FindFirstChild("dataLoadStart")
    if not loaded or not loaded.Value then return false, "player data still loading" end
    local stores = workspace:FindFirstChild("Stores")
    local store = stores and stores:FindFirstChild(LP.Name .. "Store")
    if not store then return false, "store model not spawned" end
    if not store:FindFirstChild("PC") then return false, "PC not built yet" end
    return true
end

----------------------------------------------------------------- spend gate
local function refreshFloor()
    local daily = LP:FindFirstChild("DailyBoughtSneakers")
    local cd = CONST.RefreshCooldown
    if daily and daily.Value >= cd.ThrottleAt then return cd.Throttled end
    return cd.Min
end

-- ReservePct is WHEN TO START SAVING, not how much to freeze: below pct% of the slot cost
-- spend freely (buying is what earns the rest); at or above it, hold the FULL cost so the
-- unlock can actually complete. A fractional freeze deadlocks - you cannot buy a slot with
-- 60% of its price, and every dollar earned lands above the floor and is re-reserved.
local function reserveFloor()
    local pct = math.clamp(Config.ReservePct or 0, 0, 100)
    if pct <= 0 then return 0 end
    if not Panel.Running.AutoUpgrade then return 0 end
    if slotsNow() >= math.min(Config.TargetSlots, CONST.MaxSlots) then return 0 end
    local cost = nextSlotCost() or 0
    if cost <= 0 then return 0 end
    if money() < math.floor(cost * pct / 100) then return 0 end
    return cost
end

local function canSpend(amount, ignoreReserve)
    if amount <= 0 then return false, "invalid amount" end
    if money() < amount then return false, "not enough money" end
    if Config.SpendCap > 0 and Panel.Spent + amount > Config.SpendCap then
        return false, ("spend cap reached (%d/%d)"):format(Panel.Spent, Config.SpendCap)
    end
    if not ignoreReserve then
        local floor = reserveFloor()
        if floor > 0 and (money() - amount) < floor then
            return false, "reserved for slot unlock"
        end
    end
    return true
end

local function recordSpend(amount) Panel.Spent = Panel.Spent + amount end

local Features = {}

local function stopAll(reason)
    -- In-flight work (a snipe mid-tween, a bar approach) checks this before its prompt.
    Panel.KillEpoch = (Panel.KillEpoch or 0) + 1
    for name in pairs(Panel.Running) do Panel.Running[name] = nil end
    local toggles = Panel.Library and Panel.Library.Toggles
    if toggles then
        for _, key in ipairs({ "Director", "AutoBuy", "AutoSell", "AutoBar", "AutoTrade",
                               "AutoUpgrade", "AutoDrops", "LimitedSnipe", "AutoClaim" }) do
            local t = toggles[key]
            if t and t.Value then pcall(function() t:SetValue(false) end) end
        end
    end
    notify("KILL SWITCH - all automation stopped" .. (reason and (" (" .. reason .. ")") or ""))
    if Config.PanicSell and Features.Sell then pcall(Features.Sell.DumpAll) end
end

--=========================================================================
-- [3] ECON
--
-- Everything the panel decides comes from here. The two payout rates are seeded
-- with the measured values and then re-measured from live sales, because the
-- realised bar rate is a MIX of Perfect (1.10) and Good (1.00) - it is never the
-- textbook 1.10, and pretending otherwise makes every filter slightly wrong.
--
--   profit(unit)      = MaxSellPrice * rate(channel) - price
--   break-even ROI    = 1 / rate(channel)
--   cashier           1 / 0.55 = 1.82x   <- buying under this LOSES money
--   bar (Perfect)     1 / 1.10 = 0.91x
--
-- So the same offer page is judged by a completely different threshold depending
-- on whether the bar sell loop is live. That is the whole point of the split.
--=========================================================================

local Econ = {
    Rate = { Cashier = CONST.CashierRate, Bar = CONST.Bands.Perfect },
    Samples = { Cashier = 0, Bar = 0 },
    Hist = {},          -- rolling { t, netWorth } for the $/min readout
}

-- One sale's worth of evidence. `expected` is the summed MaxSellPrice of what left the
-- inventory, `gained` the cash that arrived. Guarded: a zero or negative sample means the
-- sale did not land, and folding that in would drag the rate toward nonsense.
-- Measuring a payout means watching the wallet, and the wallet is shared. Three things move
-- it at once: this sale, the buy loop, and the OTHER sell channel. Live that produced a
-- cashier reading of 0.67 (true 0.55) and a bar reading of 0.40 (true up to 1.10) - both
-- wrong, in opposite directions, from the same contamination.
--
-- So: mark the wallet AND every counter before a sale. Spending is exact and gets added
-- back; a sale on the other channel inside the window is not recoverable, so that sample is
-- thrown away instead of folded in. Fewer samples, but each one means something.
function Econ.Mark()
    local counts = {}
    for _, l in ipairs(stockLines()) do counts[l.Name] = l.Count end
    return { money = money(), spent = Panel.Spent, bar = Panel.BarSales,
             dumps = Panel.Sold, bought = Panel.Bought, counts = counts }
end

-- Which line actually left the inventory, and what it was worth. The carousel click is a
-- button press on a spinning list: assuming it landed is exactly the kind of guess that
-- produced a "bar pays 0.65x" reading. The inventory does not guess.
function Econ.SoldValue(mark)
    if not mark or not mark.counts then return nil end
    local now = {}
    for _, l in ipairs(stockLines()) do now[l.Name] = l.Count end
    local total, units = 0, 0
    for name, was in pairs(mark.counts) do
        local left = (was - (now[name] or 0))
        if left > 0 then
            total = total + maxSell(name) * left
            units = units + left
        end
    end
    if units == 0 then return nil end
    return total, units
end

-- A rate above what the game itself pays is a measurement error, not a discovery. The
-- client tables cap this: cashier 0.55 flat, bar 1.10 on a Perfect. Anything past that came
-- from crediting something else's money to this sale.
local RATE_CEILING = { Cashier = CONST.CashierRate * 1.05, Bar = CONST.Bands.Perfect * 1.05 }

function Econ.Close(channel, expected, mark)
    if not mark then return nil end
    -- Was: `(channel == "Bar") and (Panel.Sold ~= mark.dumps) or (Panel.BarSales ~= mark.bar)`.
    -- `and` binds tighter than `or`, so the second disjunct ran for BOTH channels - and a bar
    -- sale increments Panel.BarSales before Close is reached, so every bar sample was thrown
    -- away as contaminated. Econ.Samples.Bar could never leave 0 and the bar rate stayed a
    -- hardcoded 1.1 forever, while the cashier (whose test collapsed to the correct one)
    -- converged fine. That asymmetry is exactly what the live runs showed.
    -- Contamination is anything else that moved the wallet inside the window: the other
    -- sell channel, OR a purchase.
    --
    -- Buying used to be "compensated" by adding Panel.Spent back. That is wrong whenever the
    -- buy loop is bursting: a 0.6s dump window can contain a whole page of purchases that
    -- have nothing to do with this sale, and adding them back inflates the payout. Measured
    -- live, that pushed the cashier rate to 0.739 against a true 0.55 - which then LOWERED
    -- the ROI floor (break-even is 1/rate) until the panel was buying offers that lose money
    -- through the cashier. Net worth went negative on both A/B clients.
    --
    -- So: no compensation, just honesty about which windows are clean. Clean windows are
    -- rarer, and that is fine - the seeded rates are already the decompiled truth.
    local moved
    if channel == "Bar" then
        moved = (Panel.Sold ~= mark.dumps)
    else
        moved = (Panel.BarSales ~= mark.bar)
    end
    local bought = (Panel.Bought ~= mark.bought)
    local gained = money() - mark.money
    if moved or bought or gained <= 0 then
        Panel.DirtySamples = (Panel.DirtySamples or 0) + 1
        -- still the real cash for reporting; just not evidence about the rate
        return math.max(0, gained) + math.max(0, Panel.Spent - mark.spent)
    end

    local ceiling = RATE_CEILING[channel]
    if ceiling and expected > 0 and (gained / expected) > ceiling then
        Panel.DirtySamples = (Panel.DirtySamples or 0) + 1
        log("discarded %s sample: %.2fx exceeds the game's own %.2fx ceiling",
            channel, gained / expected, ceiling)
        return gained
    end

    Econ.Observe(channel, expected, gained)
    return gained
end

function Econ.Observe(channel, expected, gained)
    if not expected or expected <= 0 or not gained or gained <= 0 then return end
    local sample = gained / expected
    if sample < 0.2 or sample > 2.0 then return end          -- not a sale we understand
    local n = Econ.Samples[channel] or 0
    local w = n < 5 and 0.5 or 0.15                          -- converge fast, then settle
    Econ.Rate[channel] = Econ.Rate[channel] + (sample - Econ.Rate[channel]) * w
    -- Never let a learned rate exceed what the game pays: the ROI floor is 1/rate, so an
    -- inflated rate silently authorises unprofitable buying.
    local cap = (channel == "Bar") and CONST.Bands.Perfect or CONST.CashierRate
    if Econ.Rate[channel] > cap then Econ.Rate[channel] = cap end
    Econ.Samples[channel] = n + 1
    Panel.Earned = Panel.Earned + gained
end

-- Is the bar drain actually available right now? Not "is the toggle on" - a bar sale needs
-- the loop running AND permission to walk, or it will never fire and the ROI filter would
-- be reading a rate the panel cannot realise.
function Econ.BarLive()
    return Panel.Running.AutoBar == true and Config.BarApproach == true
end

function Econ.RateFor(name)
    if Econ.BarLive() and maxSell(name) >= Config.BarMinValue then
        return Econ.Rate.Bar, "Bar"
    end
    return Econ.Rate.Cashier, "Cashier"
end

function Econ.BreakEven(name)
    local r = Econ.RateFor(name)
    return 1 / math.max(r, 0.01)
end

-- The threshold an offer must clear. Manual mode still respects break-even as a hard floor:
-- a MinROI below it is not a risky setting, it is a guaranteed loss on every unit.
function Econ.MinROIFor(name)
    local be = Econ.BreakEven(name)
    if not Config.AutoROI then
        return math.max(Config.MinROI, be * 1.01)
    end
    return be * (1 + math.max(Config.MarginPct, 1) / 100)
end

function Econ.MaxUnit()
    if not Config.AutoMaxUnit then return Config.MaxUnitPrice end
    return math.max(100, math.floor(money() * math.clamp(Config.MaxUnitPct, 1, 100) / 100))
end

-- Expected cash profit of one purchase, in dollars, through the drain that unit will use.
function Econ.Profit(name, price)
    return maxSell(name) * select(1, Econ.RateFor(name)) - price
end

-- Net worth = cash + what the inventory is worth through the drain each line would use.
-- Money alone is a bad progress signal: a buying spree looks like a loss until it sells.
function Econ.NetWorth()
    local lines = stockLines()
    local held = 0
    for _, l in ipairs(lines) do
        held = held + l.Value * l.Count * select(1, Econ.RateFor(l.Name))
    end
    return money() + held, held
end

-- Dollars per minute, measured over a rolling 5 minute window of net worth.
function Econ.PerMinute()
    local now = os.clock()
    local nw = Econ.NetWorth()
    local h = Econ.Hist
    h[#h + 1] = { t = now, v = nw }
    while #h > 2 and now - h[1].t > 300 do table.remove(h, 1) end
    if #h < 2 then return 0, 0 end
    local dt = h[#h].t - h[1].t
    if dt < 15 then return 0, dt end                          -- too short to mean anything
    return (h[#h].v - h[1].v) / dt * 60, dt
end

-- Median held value, used to place the bar/cashier split where it actually splits the
-- stock in half rather than at a number someone typed once.
function Econ.MedianStockValue()
    local lines = stockLines()
    local flat = {}
    for _, l in ipairs(lines) do
        for _ = 1, math.min(l.Count, 50) do flat[#flat + 1] = l.Value end
    end
    if #flat == 0 then return nil end
    table.sort(flat)
    return flat[math.ceil(#flat / 2)]
end

--=========================================================================
-- [4] FEATURES
--=========================================================================

---------------------------------------------------------------- Acquisition: PC / eBuy
Features.Buy = {}

local function pageSignature()
    local parts = {}
    for _, frame in ipairs(offerFrames()) do
        parts[#parts + 1] = ("%s:%s:%s"):format(frame.Name,
            tostring(frame:GetAttribute("Sneaker")), tostring(frame:GetAttribute("SneakerPrice")))
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

-- Repaint one card from its own attributes, exactly like the game's newOfferAppear.
-- We drive the refresh remote directly, so nothing else ever repaints these cards, and a
-- stale card advertises a sneaker and price the server has already replaced.
local function repaintOffer(frame)
    local name  = frame:GetAttribute("Sneaker")
    local price = frame:GetAttribute("SneakerPrice")
    local data  = sneakerData(name)
    pcall(function()
        local bf = frame:FindFirstChild("BoughtFrame")
        if bf then bf.Visible = (name == CONST.BoughtSentinel) end
        if not data then return end
        -- Child names verified live on the running client: NameText, PriceText,
        -- SneakerImage, BuyButton, BigBuyButton, BoughtFrame, UnlockFrame. There is no
        -- rarity label on the card - rarity only shows through the image border.
        if frame:FindFirstChild("NameText")  then frame.NameText.Text  = name end
        if frame:FindFirstChild("PriceText") then frame.PriceText.Text = "$" .. commas(price or 0) end
        if frame:FindFirstChild("SneakerImage") and data.ImageLink then
            -- rbxthumb, not rbxassetid: ImageLink is an asset id whose thumbnail is the
            -- shoe render. rbxassetid on it shows nothing (verified in v1).
            frame.SneakerImage.Image = "rbxthumb://type=Asset&id=" .. tostring(data.ImageLink) .. "&w=150&h=150"
        end
    end)
end

local function repaintAll()
    for _, f in ipairs(offerFrames()) do repaintOffer(f) end
end

-- Do NOT press the game's refresh button. refreshfunction() sets AutoButtonColor = false,
-- rerolls, then task.wait(1) before restoring it. Firing it through getconnections() dies
-- at that yield, so the lock (upvalue u9) is never released and refresh is bricked for the
-- whole session - for the player too. Call the remote and paint the cards ourselves.
local function refreshOnce()
    if LP.IsAutoBuyOn.Value then
        return false, "in-game auto-buy is on, it blocks refresh"
    end

    -- Away from the PC the offer frames read empty, so a successful reroll looks identical
    -- to a refusal and the backoff ratchets to its ceiling on a page nobody can see.
    -- Measured live: 1 success against 122 "misses", every one of them during a sell trip.
    if #offerFrames() == 0 then
        return false, "PC page not readable (away from the PC?)"
    end

    -- The reroll is refused for the whole duration of a sale. Measured live while bar
    -- selling continuously: 2 successes against 317 refusals. Selling and rerolling are
    -- not concurrent activities, so do not spend calls pretending they are.
    --
    -- But only while a sale is actually being driven. A sell frame left open by a stopped
    -- bar loop is not a sale, and treating it as one wedges the buy loop permanently: a
    -- client sat at 0 buys and 0 rerolls for ten minutes with the frame open and AutoBar off.
    local sa = Paths.SellAnim
    local reallySelling = LP:FindFirstChild("IsCharacterSelling") and LP.IsCharacterSelling.Value
    if reallySelling or (Panel.Running.AutoBar and sa and sa.Visible) then
        return false, "selling - the reroll is refused until the sale finishes"
    end

    local before = pageSignature()
    local page
    local ok = pcall(function() page = CONST.Remote.Refresh:InvokeServer() end)
    if not ok then return false, "refresh remote errored" end
    if type(page) ~= "table" then return false end            -- cooldown refusal, retryable

    local t0 = os.clock()
    repeat task.wait(0.05) until pageSignature() ~= before or os.clock() - t0 > 1

    -- Own slot visibility too: UnlockFrame.Visible is cleared only inside newOfferAppear,
    -- which lives on the path we bypass. If PCLocalScript's handler is gone (it dies when
    -- the GUI is rebuilt on respawn) every offer reads as locked forever. The server's
    -- reply says how many slots are unlocked, so use that.
    local unlocked = #page
    local scroll = Paths.PCScroll
    if scroll then
        for i = 1, CONST.MaxSlots do
            local f  = scroll:FindFirstChild("Offer" .. i)
            local uf = f and f:FindFirstChild("UnlockFrame")
            if uf then
                local shouldBeOpen = i <= unlocked
                if uf.Visible == shouldBeOpen then uf.Visible = not shouldBeOpen end
                if shouldBeOpen then
                    pcall(function()
                        f.BigBuyButton.Visible = true
                        f.BuyButton.Selectable = true
                    end)
                end
            end
        end
    end

    repaintAll()
    return pageSignature() ~= before
end

-- Undo a bricked refresh button (someone Fire()d it across the yield). Upvalue layout of
-- refreshfunction, verified: [1] u9 lock, [6] RefreshButton, [10] refreshPageLocal. Only
-- index 1 is touched, and only once the shape checks out.
local function repairRefreshButton()
    local btn = realRefreshButton()
    if not btn then return false, "PC model not found" end
    local restored = false
    local ok, conns = pcall(getconnections, btn.MouseButton1Click)
    if ok then
        for _, c in ipairs(conns) do
            local okU, ups = pcall(debug.getupvalues, c.Function)
            if okU and type(ups[1]) == "boolean"
                and typeof(ups[6]) == "Instance" and ups[6]:IsA("ImageButton")
                and type(ups[10]) == "function" then
                if ups[1] == true then
                    pcall(debug.setupvalue, c.Function, 1, false)
                    restored = true
                end
            end
        end
    end
    pcall(function() btn.AutoButtonColor = true end)
    return restored
end

-- One attempt per call, paced from the last SUCCESSFUL reroll rather than the last attempt.
-- Stacking sleeps per attempt ratchets the delay well past the real cooldown while still
-- eating refusals, and a multi-attempt call can outlast the watchdog's stall threshold.
local function refreshPage()
    local cd    = CONST.RefreshCooldown
    local floor = refreshFloor()
    local extra = Panel.RefreshExtra or 0

    local hold = floor + extra - (os.clock() - (Panel.LastReroll or 0))
    if hold > 0 then task.wait(hold) end

    local changed, why = refreshOnce()
    if changed then
        Panel.LastReroll   = os.clock()
        Panel.RefreshOK    = Panel.RefreshOK + 1
        Panel.RefreshExtra = math.max(0, extra * cd.Decay)
        return true
    end
    if why then return false, why end                          -- hard block, not a cooldown

    Panel.RefreshMiss  = Panel.RefreshMiss + 1
    Panel.RefreshExtra = math.min(math.max(0, cd.Max - floor), extra + cd.Step)
    return false
end

local function readOffers()
    local out = {}
    for _, frame in ipairs(offerFrames()) do
        local uf = frame:FindFirstChild("UnlockFrame")
        local bf = frame:FindFirstChild("BoughtFrame")
        local locked = uf and uf.Visible
        local bought = bf and bf.Visible
        local name   = frame:GetAttribute("Sneaker")
        local price  = frame:GetAttribute("SneakerPrice")
        if name == CONST.BoughtSentinel then
            bought = true
            if bf then bf.Visible = true end
        end
        if not locked and not bought and name and price and price > 0 and CONST.Sneakers[name] then
            out[#out + 1] = {
                Frame = frame, Name = name, Price = price, Data = CONST.Sneakers[name],
                ROI = roiOf(name, price), Profit = Econ.Profit(name, price),
            }
        end
    end
    -- Best expected profit first. With a spend cap or a thin bankroll the order decides
    -- which offers on the page you can still afford by the time you reach them.
    table.sort(out, function(a, b) return a.Profit > b.Profit end)
    return out
end

local function wantsOffer(o)
    if not Config.BuyRarities[o.Data.Rarity] then return false, "rarity filtered" end
    if o.Data.MaxSellPrice and o.Data.MaxSellPrice < Config.MinUnitValue then return false, "under min value" end
    if o.Data[1] == "Unsellable" then return false, "unsellable" end   -- array slot 1 = cannot be sold for cash
    if o.Price > Econ.MaxUnit() then return false, "over unit cap" end
    if o.ROI < Econ.MinROIFor(o.Name) then return false, "under ROI floor" end
    if o.Profit <= 0 then return false, "no profit at the live sell rate" end
    return true
end

Features.Buy.ReadOffers = readOffers
Features.Buy.Wants      = wantsOffer
Features.Buy.RefreshPage = refreshPage
Features.Buy.RefreshOnce = refreshOnce
Features.Buy.Repair      = repairRefreshButton
Features.Buy.Repaint     = repaintAll

local function armFail(name, why)
    notify(("%s: %s"):format(name, why))
    local tg = Panel.Library and Panel.Library.Toggles and Panel.Library.Toggles[name]
    if tg then task.spawn(function() task.wait(0.1) pcall(function() tg:SetValue(false) end) end) end
end

function Features.Buy.Start()
    if Panel.Running.AutoBuy then return end
    local ok, why = storeReady()
    if not ok then return armFail("AutoBuy", why .. " - claim your store first") end
    Panel.Running.AutoBuy = true
    local gen = newGen("AutoBuy")
    notify("Auto-buy started")

    if Config.BuyReturnToPC then
        task.spawn(function()
            local sa = Paths.SellAnim
            if sa and sa.Visible then return end
            if Panel.WentToNpc then return end
            -- Already at the PC (every watchdog restart and toggle flip): do not move.
            local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
            local back = Features.Bar and Features.Bar.PCCFrame and Features.Bar.PCCFrame()
            if hrp and back and (hrp.Position - back.Position).Magnitude < 20 then return end
            if Features.Bar and Features.Bar.ReturnToPC then pcall(Features.Bar.ReturnToPC) end
        end)
    end

    task.spawn(function()
        while live("AutoBuy", gen) do
            beat("AutoBuy")

            -- One bad pass must not kill the coroutine: without this an unhandled error
            -- ends the loop silently while the toggle stays lit.
            local passOk, passErr = pcall(function()
                if not pathsReady() then
                    log("waiting for UI to come back (respawn?)")
                    task.wait(1)
                    return
                end
                -- A sell frame nobody is driving blocks nothing else in the game, but it
                -- does sit over the screen and it used to wedge the reroll. Shut it.
                local stray = Paths.SellAnim
                if stray and stray.Visible and not Panel.Running.AutoBar then
                    local closed, why = Features.Bar.CloseUI()
                    log("closed a stray sell frame: %s", closed and "ok" or tostring(why))
                    task.wait(0.5)
                end

                local sOk, sWhy = storeReady()
                if not sOk then
                    if Panel.LastBlock ~= sWhy then
                        Panel.LastBlock = sWhy
                        log("paused: %s", sWhy)
                    end
                    task.wait(3)
                    return
                end

                local boughtThisPage, guard = {}, 0

                -- Burst pass: buys are independent server calls and measured un-throttled,
                -- so a whole page clears in ~0.07s fired together vs ~0.74s walked.
                if Config.BuyBurst then
                    local batch, running = {}, 0
                    for _, o in ipairs(readOffers()) do
                        -- Re-read the attributes the walked path checks: the server rerolls a
                        -- slot as we go, and a stale entry in the batch is a guaranteed refusal.
                        local liveName = o.Frame:GetAttribute("Sneaker")
                        local livePrice = o.Frame:GetAttribute("SneakerPrice")
                        local fresh = (liveName == o.Name and livePrice == o.Price)
                        if fresh and wantsOffer(o) and canSpend(running + o.Price) then
                            -- Budget the batch up front: fired together, the per-call money
                            -- check cannot serialise them and the tail gets refused.
                            running = running + o.Price
                            batch[#batch + 1] = o
                        end
                    end
                    if #batch > 0 then
                        local done = 0
                        for _, o in ipairs(batch) do
                            task.spawn(function()
                                local bought = false
                                pcall(function()
                                    bought = CONST.Remote.Buy:InvokeServer(o.Frame.Name) == true
                                end)
                                if bought then
                                    pcall(function() o.Frame.BoughtFrame.Visible = true end)
                                    recordSpend(o.Price)
                                    Panel.Bought = Panel.Bought + 1
                                    Panel.LastBuy = os.clock()
                                    Panel.Refused = 0
                                else
                                    repaintOffer(o.Frame)
                                    Panel.Refused = (Panel.Refused or 0) + 1
                                    Panel.RefusedTotal = (Panel.RefusedTotal or 0) + 1
                                    log("server refused %s @ $%s (burst)", o.Name, commas(o.Price))
                                end
                                boughtThisPage[o.Frame.Name] = true
                                done = done + 1
                            end)
                        end
                        local t0 = os.clock()
                        repeat task.wait(0.03) until done >= #batch or os.clock() - t0 > 8
                        Panel.LastBlock = nil
                        log("BUY burst %d offers, $%s", #batch, commas(running))
                        -- Same safety stop the walked path has. Without it, burst mode - the
                        -- default - hammers a refusing server indefinitely.
                        if (Panel.Refused or 0) >= 12 then
                            notify("Auto-buy: 12 refusals in a row - stopping. See log.")
                            stopAll("server refusing buys")
                            return
                        end
                    end
                end

                while live("AutoBuy", gen) and guard < 20 do
                    guard = guard + 1
                    beat("AutoBuy")          -- a walked page at max BuyDelay outlasts the 25s stall

                    -- One snapshot serves both the pick AND the diagnostic: re-reading for
                    -- the explanation reports on a page that was never judged (right after
                    -- a buy every slot is briefly the "Bought" sentinel).
                    local snapshot = readOffers()
                    local pick, bestROI, bestName = nil, 0, nil
                    for _, o in ipairs(snapshot) do
                        if not boughtThisPage[o.Frame.Name] then
                            if o.ROI > bestROI then bestROI, bestName = o.ROI, o.Name end
                            if not pick and wantsOffer(o) then pick = o end
                        end
                    end

                    if not pick then
                        if next(boughtThisPage) == nil then
                            local reason = ("no match (%d offers, best %.2fx | need >=%.2fx, <=$%s via %s)")
                                :format(#snapshot, bestROI, Econ.MinROIFor(bestName or ""),
                                        commas(Econ.MaxUnit()), select(2, Econ.RateFor(bestName or "")))
                            if Panel.LastBlock ~= reason then
                                Panel.LastBlock = reason
                                log("%s", reason)
                            end
                        end
                        break
                    end

                    local spendOk, spendWhy = canSpend(pick.Price)
                    if not spendOk then
                        if spendWhy:find("cap") then
                            stopAll("spend cap")
                            return
                        end
                        -- Out of cash with stock on hand: recycle it rather than idling next
                        -- to an offer we want. Rate limited so a failed sale cannot spin.
                        if Config.AutoReinvest and spendWhy:find("not enough money")
                            and unitsHeld() > 0
                            and os.clock() - (Panel.LastReinvest or 0) > 5 then
                            Panel.LastReinvest = os.clock()
                            local gained, gWhy = Features.Sell.Reinvest()
                            if gained and gained > 0 then
                                log("reinvest +$%s back into buying power", commas(gained))
                                Panel.LastBlock = nil
                            else
                                log("reinvest failed: %s", tostring(gWhy))
                                break
                            end
                        else
                            if Panel.LastBlock ~= spendWhy then
                                Panel.LastBlock = spendWhy
                                log("not buying: %s (cheapest match $%s, you have $%s)",
                                    spendWhy, commas(pick.Price), commas(money()))
                            end
                            break
                        end
                    end
                    Panel.LastBlock = nil

                    -- re-validate against the attribute right now, not the snapshot
                    local liveName  = pick.Frame:GetAttribute("Sneaker")
                    local livePrice = pick.Frame:GetAttribute("SneakerPrice")
                    if liveName ~= pick.Name or livePrice ~= pick.Price then
                        repaintOffer(pick.Frame)
                    else
                        local bought = false
                        pcall(function()
                            bought = CONST.Remote.Buy:InvokeServer(pick.Frame.Name) == true
                        end)
                        boughtThisPage[pick.Frame.Name] = true
                        if bought then
                            pcall(function() pick.Frame.BoughtFrame.Visible = true end)
                            recordSpend(pick.Price)
                            Panel.Bought  = Panel.Bought + 1
                            Panel.LastBuy = os.clock()
                            Panel.Refused = 0
                            log("BUY %s @ $%s (%.2fx, +$%s exp)", pick.Name, commas(pick.Price),
                                pick.ROI, commas(pick.Profit))
                        else
                            repaintOffer(pick.Frame)
                            Panel.Refused = (Panel.Refused or 0) + 1
                            log("server refused %s @ $%s | money $%s cooldown=%s selling=%s daily=%d",
                                pick.Name, commas(pick.Price), commas(money()),
                                tostring(LP.playerBuyCooldown and LP.playerBuyCooldown.Value),
                                tostring(LP.IsCharacterSelling and LP.IsCharacterSelling.Value),
                                LP.DailyBoughtSneakers.Value)
                            if Panel.Refused >= 12 then
                                notify("Auto-buy: 12 refusals in a row - stopping. See log.")
                                stopAll("server refusing buys")
                                return
                            end
                        end
                        if Config.BuyDelay > 0 then task.wait(Config.BuyDelay) end
                    end
                end

                local changed, rWhy = refreshPage()
                if not changed and rWhy then
                    log("refresh skipped: %s", rWhy)
                    task.wait(2)          -- a hard block is not a cooldown, so pace it here
                end
            end)

            if not passOk then
                log("auto-buy pass failed (recovering): %s", tostring(passErr))
                task.wait(1)
            end
            task.wait(0.05)               -- refreshPage already paid the cooldown wait
        end
    end)
end

function Features.Buy.Stop()
    Panel.Running.AutoBuy = nil
    log("Auto-buy stopped")
end

---------------------------------------------------------------- Acquisition: offer slots
-- The only compounding purchase in the game: rolls per refresh scale linearly with slots,
-- so rare/high-ROI hunting scales with them too.
Features.Slots = {}

local function purchasableSlotFrame()
    for _, frame in ipairs(offerFrames()) do
        local uf = frame:FindFirstChild("UnlockFrame")
        local lf = uf and uf:FindFirstChild("LockedFrame")
        if uf and uf.Visible and lf and not lf.Visible then return frame end
    end
end

function Features.Slots.CostToTarget()
    local total, target = 0, math.min(Config.TargetSlots, CONST.MaxSlots)
    for i = slotsNow(), target - 1 do total = total + (CONST.UnlockCosts[i] or 0) end
    return total
end

-- `manual` is true only when a human pressed the button. Automation passes nothing.
--
-- This exists because every softer guard failed in production. Defaults were made safe and a
-- saved config overrode them; the toggle was made authoritative and the Director re-armed it;
-- each time, the result was a real $2,000,000 slot bought while nobody was watching. A slot
-- is the largest purchase in the game (up to $50,000,000) and it is irreversible, so the
-- spend refuses at the point of spending, not three layers up where the next bug can route
-- around it.
function Features.Slots.BuyOne(manual)
    if Config.SlotsManualOnly and not manual then
        return false, "slot buying is locked (Buy tab -> Offer slots -> Lock slot buying)"
    end
    local target = math.min(Config.TargetSlots, CONST.MaxSlots)
    if slotsNow() >= target then return false, "target reached" end
    local cost = nextSlotCost()
    if not cost then return false, "max slots" end
    if money() < cost then return false, ("need $%s, have $%s"):format(commas(cost), commas(money())) end

    local ok, why = canSpend(cost, true)
    if not ok then return false, why end

    local frame = purchasableSlotFrame()
    if not frame then return false, "no unlockable slot on screen (open the PC)" end

    -- Do NOT press the unlock button: refreshPageLocal disconnects every unlock handler and
    -- re-binds only the next one, and we bypass refreshPageLocal, so the button has zero
    -- connections. Call the remote and do the reveal ourselves.
    local before, result = slotsNow(), nil
    local invoked = pcall(function() result = CONST.Remote.BuyNewOffer:InvokeServer() end)
    if not invoked then return false, "unlock remote errored" end
    -- Only an explicit false is a refusal. A nil return may still be a completed unlock,
    -- so the slot count below decides - otherwise a real purchase skips recordSpend.
    if result == false then return false, "server refused the unlock" end

    local t0 = os.clock()
    repeat task.wait(0.1) until slotsNow() > before or os.clock() - t0 > 4
    if slotsNow() > before then
        recordSpend(cost)
        -- A slot is the largest single purchase the panel can make, up to $50,000,000.
        -- Announce it: one of these went unnoticed for an hour and read as missing money.
        notify(("Slot %d unlocked for $%s"):format(slotsNow(), commas(cost)))
        pcall(function()
            frame.UnlockFrame.Visible = false
            frame.BigBuyButton.Visible = true
            frame.BuyButton.Selectable = true
        end)
        repaintOffer(frame)
        log("UPGRADE slot %d -> %d for $%s", before, slotsNow(), commas(cost))
        return true
    end
    return false, "server did not confirm"
end

function Features.Slots.Start()
    if Config.SlotsManualOnly then
        notify("Auto-upgrade blocked: slot buying is locked (Buy tab -> Offer slots)")
        local tg = Panel.Library and Panel.Library.Toggles and Panel.Library.Toggles.AutoUpgrade
        if tg and tg.Value then task.spawn(function() task.wait(0.1) pcall(function() tg:SetValue(false) end) end) end
        return
    end
    if Panel.Running.AutoUpgrade then return end
    local ok, why = storeReady()
    if not ok then return armFail("AutoUpgrade", why .. " - claim your store first") end
    Panel.Running.AutoUpgrade = true
    local gen = newGen("AutoUpgrade")
    notify("Auto-upgrade running (target " .. math.min(Config.TargetSlots, CONST.MaxSlots) .. " slots)")

    task.spawn(function()
        while live("AutoUpgrade", gen) do
            beat("AutoUpgrade")
            local target = math.min(Config.TargetSlots, CONST.MaxSlots)
            if slotsNow() >= target then
                notify(("Auto-upgrade done: %d slots"):format(slotsNow()))
                Panel.Running.AutoUpgrade = nil
                local tg = Panel.Library and Panel.Library.Toggles and Panel.Library.Toggles.AutoUpgrade
                if tg then pcall(function() tg:SetValue(false) end) end
                break
            end
            local done, why2 = Features.Slots.BuyOne()
            if not done and why2 and why2:find("cap") then
                stopAll("spend cap")
                return
            end
            task.wait(done and 0.5 or 3)
        end
    end)
end

function Features.Slots.Stop()
    Panel.Running.AutoUpgrade = nil
    log("Auto-upgrade stopped")
end

---------------------------------------------------------------- Liquidation: router
-- The cashier and the bar are not two ways of doing the same thing, they are two prices.
-- Cashier 0.55x, bar up to 1.10x, and a bar sale costs a trip plus a minigame per UNIT
-- while the cashier clears the whole inventory in one remote. So the split is by value:
-- the bar earns its per-unit time cost only on stock worth enough to matter, and the
-- cheap tail is dumped so it stops clogging the carousel the bar picks from.
Features.Sell = {}

local function expectedValue(lines, predicate)
    local total = 0
    for _, l in ipairs(lines) do
        local n = l.Count - ((Config.SellMode == "Keep One") and 1 or 0)
        if n > 0 and (not predicate or predicate(l)) then total = total + l.Value * n end
    end
    return total
end

-- Whole-inventory dump through the cashier. No proximity: measured firing from 150+ studs.
function Features.Sell.DumpAll()
    local lines = stockLines()
    if #lines == 0 then return 0, "nothing to sell" end
    local expected = expectedValue(lines)
    local ev = (Config.SellMode == "Everything") and "SellAllEvent" or "SellAllButOneEvent"
    local mark = Econ.Mark()
    -- Counted BEFORE the fire: a bar payout closing inside this 0.6s window must see a dump
    -- happened, or cashier money is learned as a clean bar sample.
    Panel.Sold = Panel.Sold + 1
    pcall(function() CONST.Remote.Cashier[ev]:FireServer() end)
    task.wait(0.6)
    local gained = Econ.Close("Cashier", expected, mark) or 0
    log("DUMP %s -> +$%s (rate %.2f)", ev, commas(gained), Econ.Rate.Cashier)
    return gained
end

-- Dump only what the bar would never be worth walking for. SingleSellEvent is per line, so
-- this leaves the valuable stock intact for the bar loop instead of levelling everything.
function Features.Sell.DumpCheap()
    local lines = stockLines()
    local sold, expected, count = 0, 0, 0
    local keepOne = (Config.SellMode == "Keep One")
    local mark = Econ.Mark()
    for _, l in ipairs(lines) do
        local n = l.Count - (keepOne and 1 or 0)
        if n > 0 and l.Value < Config.BarMinValue then
            if count == 0 then Panel.Sold = Panel.Sold + 1 end   -- before the first fire, see DumpAll
            expected = expected + l.Value * n
            count = count + n
            pcall(function() CONST.Remote.Cashier.SingleSellEvent:FireServer(l.Name, n) end)
            task.wait(0.05)
        end
    end
    if count == 0 then return 0, "nothing under the bar threshold" end
    task.wait(0.8)
    sold = Econ.Close("Cashier", expected, mark) or 0
    log("DUMP %d cheap units (<$%s) -> +$%s", count, commas(Config.BarMinValue), commas(sold))
    return sold
end

-- Refill buying power. "Router" prefers the cheap tail so the good stock survives for the
-- bar; it falls back to a full dump when the tail alone raises nothing.
function Features.Sell.Reinvest()
    local sa = Paths.SellAnim
    if sa and sa.Visible and Config.ReinvestVia ~= "NPC bar" then
        return nil, "bar sale in progress"
    end
    if Config.ReinvestVia == "NPC bar" then
        return Features.Bar.SellOne()
    elseif Config.ReinvestVia == "Cashier" then
        return Features.Sell.DumpAll()
    end
    local gained = Features.Sell.DumpCheap()
    if gained and gained > 0 then return gained end
    return Features.Sell.DumpAll()
end

function Features.Sell.Start()
    if Panel.Running.AutoSell then return end
    local ok, why = storeReady()
    if not ok then return armFail("AutoSell", why .. " - claim your store first") end
    Panel.Running.AutoSell = true
    local gen = newGen("AutoSell")
    notify(("Cashier loop armed (dump at %d units)"):format(Config.SellAtUnits))

    task.spawn(function()
        while live("AutoSell", gen) do
            beat("AutoSell")
            local sa = Paths.SellAnim
            if sa and sa.Visible then
                task.wait(1)                 -- a dump mid-sale corrupts the sale and the sample
            else
            local units = sellableUnits()
            if units >= Config.InvHardCap then
                Features.Sell.DumpAll()                      -- overflow: value split loses to volume
            elseif units >= Config.SellAtUnits then
                if Config.SellRouter and Econ.BarLive() then
                    local gained = Features.Sell.DumpCheap()
                    -- Everything held is bar-grade and the bar is not keeping up: dump it,
                    -- otherwise the buy loop starves waiting on a queue that cannot drain.
                    if (not gained or gained <= 0) and units >= Config.SellAtUnits * 2 then
                        Features.Sell.DumpAll()
                    end
                else
                    Features.Sell.DumpAll()
                end
            end
            end
            task.wait(2)
        end
    end)
end

function Features.Sell.Stop()
    Panel.Running.AutoSell = nil
    log("Cashier loop stopped")
end

---------------------------------------------------------------- Liquidation: NPC bar
-- The server invokes the CLIENT for this minigame and trusts the band it returns. We do
-- NOT touch OnClientInvoke (that freezes the game); we watch the bar and press the game's
-- own StopButton, so the band handed back is one we genuinely landed on.
Features.Bar = {}

local function lineCentreX()
    local sa = Paths.SellAnim
    local bl = sa and sa:FindFirstChild("BarAndLine")
    local line = bl and bl:FindFirstChild("Line")
    if not line then return nil end
    return line.AbsolutePosition.X + line.AbsoluteSize.X / 2
end

-- Band geometry read off the colour strips. They are re-randomised to a new centre
-- (0.30-0.70) after EVERY sale, so this is re-read each pass and never cached.
local function bandRects()
    local sa  = Paths.SellAnim
    local bl  = sa and sa:FindFirstChild("BarAndLine")
    local ebf = bl and bl:FindFirstChild("ExtraBarFrame")
    local lcf = ebf and ebf:FindFirstChild("LineColorsFrame")
    if not lcf then return nil end
    local list = {}
    for _, v in ipairs(lcf:GetDescendants()) do
        if v:IsA("GuiObject") and v.Name:match("COLORX") then
            list[#list + 1] = {
                name = v.Name:split("_")[2],
                x0 = v.AbsolutePosition.X,
                x1 = v.AbsolutePosition.X + v.AbsoluteSize.X,
            }
        end
    end
    if #list == 0 then return nil end
    table.sort(list, function(a, b) return a.x0 < b.x0 end)
    return list
end

-- Miss spans the whole bar and sits under Good and Perfect, and the strips overlap by a
-- pixel at the seams. Narrowest match wins, so a hit reads Perfect only when it is inside.
local function bandAt(rects, x)
    local hit
    for _, b in ipairs(rects) do
        if x >= b.x0 and x <= b.x1 then
            if not hit or (b.x1 - b.x0) < (hit.x1 - hit.x0) then hit = b end
        end
    end
    return hit
end

local function bandNamed(rects, name, nearTo)
    local best
    for _, b in ipairs(rects) do
        if b.name == name then
            if not best or math.abs((b.x0 + b.x1) / 2 - nearTo) < math.abs((best.x0 + best.x1) / 2 - nearTo) then
                best = b
            end
        end
    end
    return best
end

-- Aiming. The game does not sample the bar when we press: pressing sets a flag, and the
-- sample happens on the next wake of its own `repeat wait(0.03)` loop, a later frame. At
-- 30fps the line covers ~30px per frame through the scoring zone - about one Perfect band
-- wide - so firing while ON Perfect reliably scores Good. Aim where it WILL be instead.
local lastLineX = nil

local function predictBand()
    local rects, x = bandRects(), lineCentreX()
    if not rects or not x then
        lastLineX = nil
        return nil
    end
    local prev = lastLineX
    lastLineX = x
    if not prev then return nil end
    local dx = x - prev
    local span = rects[#rects].x1 - rects[1].x0
    -- Between sales the line resets from 0.995 to 0.005, a jump the width of the bar. That
    -- is not velocity; drop the frame and re-seed on the next one.
    if math.abs(dx) > span * 0.25 or dx == 0 then return nil end
    local xp = x + dx * math.clamp(Config.BarLead or 1, 0, 4)
    local hit = bandAt(rects, xp)
    return (hit and hit.name or nil), xp, dx, rects
end

-- Self-calibration: the game clones the Line into ExtraBarFrame at the instant it reads the
-- band, so the clone's position measures where our press actually landed. No inference from
-- payouts needed - compare it to where the line was when we fired and that is the real lead.
local function calibrateLead(firedX, firedDx)
    if not Config.BarAutoLead or not firedX or not firedDx or firedDx == 0 then return end
    local sa = Paths.SellAnim
    local bl = sa and sa:FindFirstChild("BarAndLine")
    local ebf = bl and bl:FindFirstChild("ExtraBarFrame")
    if not ebf then return end
    task.spawn(function()
        local conn, done = nil, false
        conn = ebf.ChildAdded:Connect(function(child)
            if done or not child:IsA("GuiObject") then return end
            done = true
            -- AbsolutePosition is not laid out on the frame the child is added and reads
            -- off-bar; one frame of settle makes it real. The clone lives 0.6s and is never
            -- moved, so it is still valid here.
            RunService.Heartbeat:Wait()
            if not child.Parent then return end
            local cx = child.AbsolutePosition.X + child.AbsoluteSize.X / 2
            local measured = (cx - firedX) / firedDx
            if measured >= 0 and measured <= 4 then
                local cur = Config.BarLead or 1
                Config.BarLead = cur + (measured - cur) * 0.25   -- ease, never snap
                Panel.BarLeadMeasured = measured
            end
            if conn then conn:Disconnect() end
        end)
        task.wait(2)
        done = true
        if conn then conn:Disconnect() end
    end)
end

local function selectBestCarouselEntry()
    local sa = Paths.SellAnim
    local sf = sa and sa:FindFirstChild("SpinningSelectFrame")
    local frame = sf and sf:FindFirstChild("SelectedFrame")
    if not frame then return end
    local best, bestVal
    for _, btn in ipairs(frame:GetChildren()) do
        if btn:IsA("ImageButton") or btn:IsA("TextButton") then
            local v = maxSell(btn.Name)
            if not bestVal or v > bestVal then best, bestVal = btn, v end
        end
    end
    if best then
        pressButton(best.MouseButton1Click)
        Panel.BarPick = { Name = best.Name, Value = bestVal or 0 }
        log("BAR select %s ($%s)", best.Name, commas(bestVal or 0))
    end
end

local function nearestSellNpc()
    local char = LP.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    local folder = workspace:FindFirstChild("NPCFolder")
    if not (hrp and folder) then return nil end
    local best, bestDist
    for _, npc in ipairs(folder:GetChildren()) do
        local nh = npc:FindFirstChild("HumanoidRootPart")
        local prompt = npc:FindFirstChild("ProximityPrompt")
        if nh and prompt and prompt.Enabled then
            local d = (nh.Position - hrp.Position).Magnitude
            if not bestDist or d < bestDist then best, bestDist = npc, d end
        end
    end
    return best, bestDist
end

-- Distance is enforced server-side, so we have to actually be there. Tween rather than
-- teleport: same end state, but the server sees a normal stream of positions. Tunnel mode
-- drops below the map, travels flat and surfaces, which avoids ploughing through the
-- shopfront and other players.
local function tweenRootTo(targetCFrame)
    local char = LP.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not (hrp and targetCFrame) then return false end

    local speed = math.max(10, Config.BarTweenSpeed)
    local depth = math.max(0, Config.BarTunnelDepth)

    local function leg(cf, studs)
        local t = math.clamp(studs / speed, 0.12, 4)
        local tw = TweenService:Create(hrp,
            TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { CFrame = cf })
        local done = false
        tw.Completed:Once(function() done = true end)
        tw:Play()
        -- Completed never fires if the HRP dies mid-tween (respawn); do not hang on it.
        local t0 = os.clock()
        repeat task.wait() until done or os.clock() - t0 > t + 1
    end

    -- One mover at a time. The bar loop, Reinvest-via-bar, Buy's return-to-PC and the
    -- sniper can all travel; overlapping tweens made the second one save the first's
    -- Anchored=true as "the way we found it" and leave the character anchored.
    local t0 = os.clock()
    while Panel.Moving and os.clock() - t0 < 15 do task.wait(0.1) end
    if Panel.Moving then return false end
    Panel.Moving = true

    local prevAnchored, prevPlatform = hrp.Anchored, hum and hum.PlatformStand
    local ok = pcall(function()
        hrp.Anchored = true
        if hum then hum.PlatformStand = true end
        if Config.BarTunnel and depth > 0 then
            local down   = hrp.CFrame - Vector3.new(0, depth, 0)
            local across = targetCFrame - Vector3.new(0, depth, 0)
            leg(down, depth)
            leg(across, (across.Position - down.Position).Magnitude)
            leg(targetCFrame, depth)
        else
            leg(targetCFrame, (targetCFrame.Position - hrp.Position).Magnitude)
        end
    end)
    -- always put the character back the way we found it
    pcall(function()
        hrp.Anchored = prevAnchored or false
        if hum then hum.PlatformStand = prevPlatform or false end
    end)
    Panel.Moving = false
    return ok
end

-- NPCs patrol, so the CFrame we aim at goes stale mid-flight: a measured run landed at
-- 10.1 studs against a 10 stud reach and the prompt silently refused. Re-target and close.
local function approachNpc(npc)
    local nh = npc and npc:FindFirstChild("HumanoidRootPart")
    if not nh then return false end
    local prompt = npc:FindFirstChild("ProximityPrompt")
    local reach  = prompt and prompt.MaxActivationDistance or 10

    for _ = 1, 4 do
        if not tweenRootTo(nh.CFrame * CFrame.new(0, 0, 3)) then return false end
        local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        if not hrp then return false end
        if (hrp.Position - nh.Position).Magnitude <= reach - 2 then
            -- The server checks the prompt against ITS copy of our position, which lags a
            -- fast tween: arriving from 62 studs and firing immediately left the bar shut.
            task.wait(0.4)
            return true
        end
    end
    return false, "NPC outpaced the approach"
end

local function pcReturnCFrame()
    local stores = workspace:FindFirstChild("Stores")
    local store  = stores and stores:FindFirstChild(LP.Name .. "Store")
    local pc     = store and store:FindFirstChild("PC")
    if pc then
        local ok, pivot = pcall(function() return pc:GetPivot() end)
        if ok and pivot then return pivot * CFrame.new(0, 0, 5) end
    end
    return Panel.HomeCFrame
end

-- exitSell upvalues: [1] u4 "payout in progress", [2] u3 cancel flag. It yields only while
-- u4 is true, so read u4 first and fire while it is false - firing across that yield is the
-- same mistake that bricks the refresh button.
local function closeSellUI()
    local sa = Paths.SellAnim
    local btn = sa and sa:FindFirstChild("ExitButton")
    if not btn then return false, "no exit button" end
    local ok, conns = pcall(getconnections, btn.MouseButton1Click)
    if not ok or #conns == 0 then return false, "exit button has no handler" end
    for _, c in ipairs(conns) do
        local okU, ups = pcall(debug.getupvalues, c.Function)
        if okU and type(ups[1]) == "boolean" and type(ups[2]) == "boolean" then
            local t0 = os.clock()
            while ups[1] == true and os.clock() - t0 < 3 do
                task.wait(0.1)
                local _, again = pcall(debug.getupvalues, c.Function)
                ups = again or ups
            end
            if ups[1] == false then
                pcall(function() c:Fire() end)
                return true
            end
            return false, "payout still running"
        end
    end
    return false, "exitSell closure not recognised"
end

Features.Bar.NearestNpc = nearestSellNpc
Features.Bar.Approach   = approachNpc
Features.Bar.TweenTo    = tweenRootTo
Features.Bar.CloseUI    = closeSellUI
Features.Bar.BandUnderLine = function()
    local rects, x = bandRects(), lineCentreX()
    if not rects or not x then return nil end
    local hit = bandAt(rects, x)
    return hit and hit.name or nil
end

Features.Bar.PCCFrame = pcReturnCFrame

function Features.Bar.ReturnToPC()
    local back = pcReturnCFrame()
    if not back then return false, "no PC and no saved position" end
    local moved = tweenRootTo(back)
    if moved then
        Panel.WentToNpc = false
        log("returned to the PC")
    end
    return moved
end

-- One bar sale end to end. The running loop is what picks the sneaker and stops on the
-- target band, so this refuses to start without it rather than parking you at a dead bar.
function Features.Bar.SellOne(timeout)
    if not Panel.Running.AutoBar then return nil, "enable bar-sell auto-stop first" end
    if unitsHeld() == 0 then return nil, "nothing to sell" end

    local mark = Econ.Mark()
    local sa = Paths.SellAnim
    if not (sa and sa.Visible) then
        local npc, dist = nearestSellNpc()
        if not npc then return nil, "no sell NPC found" end
        local prompt = npc:FindFirstChild("ProximityPrompt")
        local reach = prompt and prompt.MaxActivationDistance or 10
        if dist > reach - 2 then
            if not Config.BarApproach then return nil, "too far from an NPC and Walk to NPCs is off" end
            beat("AutoBuy")                       -- called from the buy loop via Reinvest
            approachNpc(npc)
            Panel.WentToNpc = true
        end
        local fired = pcall(function()
            fireproximityprompt(prompt, prompt.HoldDuration > 0 and prompt.HoldDuration or nil)
        end)
        if not fired then return nil, "could not trigger the NPC prompt" end
    end

    local t0 = os.clock()
    repeat task.wait(0.2) beat("AutoBuy") until money() > mark.money or os.clock() - t0 > (timeout or 15)
    -- No Econ.Close here: the running AutoBar loop (required above) already folds this
    -- payout into the rate via its own saleMark, and closing it twice double-weights it.
    local gained = money() - mark.money
    if gained <= 0 then return nil, "bar sale timed out" end
    return gained
end

function Features.Bar.Start()
    if Panel.Running.AutoBar then return end
    local ok, why = storeReady()
    if not ok then return armFail("AutoBar", why .. " - claim your store first") end
    Panel.Running.AutoBar = true
    local gen = newGen("AutoBar")
    notify("Bar-sell armed" .. (Config.BarApproach and " (auto-approach on)" or " - walk to an NPC"))

    task.spawn(function()
        local armed, lastApproach, saleMark = nil, 0, nil
        while live("AutoBar", gen) do
            beat("AutoBar")
            local sa = Paths.SellAnim
            local barOpen = sa and sa.Visible

            -- payout landed: fold it into the measured bar rate
            if saleMark and money() > saleMark.money then
                local expected = Econ.SoldValue(saleMark) or (Panel.BarPick and Panel.BarPick.Value)
                if expected and expected > 0 then Econ.Close("Bar", expected, saleMark) end
                saleMark = Econ.Mark()
            end

            if Config.BarAutoClose and barOpen and unitsHeld() == 0 then
                local closed, cWhy = closeSellUI()
                log("sell bar auto-close: %s", closed and "closed (out of stock)" or tostring(cWhy))
                task.wait(1)
            end

            -- Stock on hand and nothing open: go find someone. With the router on, only
            -- bar-grade stock justifies the trip; the cheap tail is the cashier's job.
            local barGrade = 0
            for _, l in ipairs(stockLines()) do
                if l.Value >= Config.BarMinValue then barGrade = barGrade + l.Count end
            end
            -- Travel on a BATCH, not on every unit. One trip per sneaker meant the buy loop
            -- never got a page to itself, and the reroll is refused mid-sale anyway - so a
            -- unit-at-a-time cadence spends the whole session unable to restock.
            -- Once the bar is already open, keep selling: the trip is already paid for.
            local batch = math.max(1, Config.BarBatch)
            local enough = barOpen or barGrade >= batch or unitsHeld() >= Config.InvHardCap
            local worthGoing = enough and
                (Config.SellRouter and (barGrade > 0) or (not Config.SellRouter and unitsHeld() > 0))

            -- Done selling and we travelled to get here: head back. "Done" is nothing left
            -- worth a sale, not an empty inventory - Keep One copies and the cheap tail stay
            -- behind, and parked at the NPC the PC page is unreadable, so buying stalls.
            if Config.BarReturn and Panel.WentToNpc and not barOpen and not worthGoing then
                Features.Bar.ReturnToPC()
                task.wait(0.5)
            end

            if Config.BarApproach and not barOpen and worthGoing and os.clock() - lastApproach > 3 then
                lastApproach = os.clock()
                local npc, dist = nearestSellNpc()
                if npc then
                    if not Panel.WentToNpc then
                        local hrp0 = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
                        if hrp0 then Panel.HomeCFrame = hrp0.CFrame end
                        Panel.WentToNpc = true
                    end
                    local prompt = npc:FindFirstChild("ProximityPrompt")
                    local reach = prompt and prompt.MaxActivationDistance or 10
                    if dist > reach - 2 then
                        log("approaching %s (%.0f studs)", npc.Name, dist)
                        approachNpc(npc)
                    end
                    -- Killed or toggled off during the walk: do not open a sale nobody wants.
                    if not live("AutoBar", gen) then return end
                    local fired = pcall(function()
                        fireproximityprompt(prompt, prompt.HoldDuration > 0 and prompt.HoldDuration or nil)
                    end)
                    if not fired then log("could not trigger %s's prompt", npc.Name) end
                    task.wait(0.5)
                else
                    log("no sell NPC found")
                end
            end

            if barOpen then
                if armed ~= true then
                    armed = true
                    saleMark = Econ.Mark()
                    task.wait(0.35)
                    selectBestCarouselEntry()
                end
                local want = Config.BarTarget
                local predicted, xp, dx, rects = predictBand()
                local fire = false
                if predicted then
                    if predicted == want then
                        fire = true
                    elseif Config.BarAcceptGood and predicted ~= "Miss" then
                        -- A frame of travel is about as wide as the Perfect band, so on
                        -- roughly half of all passes no frame ever predicts onto it. Take
                        -- the closest approach as the line crosses the target's centre
                        -- rather than burning another 1.5s sweep.
                        local target = bandNamed(rects, want, xp)
                        if target then
                            local centre = (target.x0 + target.x1) / 2
                            if ((xp - dx) - centre) * (xp - centre) < 0 then fire = true end
                        end
                    end
                end
                if fire and predicted == "Miss" then fire = false end   -- hard guard
                if fire then
                    local stop = sa:FindFirstChild("StopButton")
                    if stop then
                        calibrateLead(lineCentreX(), dx)
                        pressButton(stop.MouseButton1Down)
                        Panel.BarSales = Panel.BarSales + 1
                        Panel.BarAimed = Panel.BarAimed + (predicted == want and 1 or 0)
                        log("BAR stop, aimed %s (lead %.2f)", tostring(predicted), Config.BarLead or 1)
                        task.wait(1.5)
                        lastLineX = nil        -- that gap is many frames: re-seed velocity
                    end
                end
            else
                armed = nil
            end

            -- Heartbeat, not RenderStepped: RenderStepped stops firing entirely once 3D
            -- rendering is disabled, which would wedge this loop under perf mode.
            RunService.Heartbeat:Wait()
        end
    end)
end

function Features.Bar.Stop()
    Panel.Running.AutoBar = nil
    log("Bar-sell stopped")
end

---------------------------------------------------------------- Craft: trade-ups
-- One remote call, no GUI, no proximity. Consumes UnsellableInventory only (box/limited
-- stock), so it never touches the cash loop's sellable inventory.
Features.Trade = {}

local function unsellableByRarity()
    local counts, lines = {}, {}
    local inv = Paths.Unsellable
    if not inv then return counts, lines end
    for _, c in ipairs(inv:GetChildren()) do
        local d = sneakerData(c.Name)
        if d and c.Value > 0 then
            counts[d.Rarity] = (counts[d.Rarity] or 0) + c.Value
            lines[#lines + 1] = { Name = c.Name, Count = c.Value, Rarity = d.Rarity }
        end
    end
    return counts, lines
end

local function collectForRecipe(key)
    local recipe = CONST.TradeUps[key]
    if not recipe then return nil, "unknown recipe" end
    local list = {}
    local _, lines = unsellableByRarity()
    for _, l in ipairs(lines) do
        if l.Rarity == recipe.From then
            -- Keeping one of each line preserves the index while still feeding duplicates in.
            local spare = Config.TradeKeepOne and (l.Count - 1) or l.Count
            for _ = 1, math.max(0, spare) do
                if #list >= recipe.Amount then break end
                list[#list + 1] = l.Name
            end
        end
        if #list >= recipe.Amount then break end
    end
    if #list < recipe.Amount then
        return nil, ("need %d %s, have %d spare"):format(recipe.Amount, recipe.From, #list)
    end
    return list
end

Features.Trade.Collect = collectForRecipe
Features.Trade.Stock   = unsellableByRarity

-- What the current stock can actually produce, recipe by recipe. Answers "you hold 47
-- Uncommon -> 3x EpicTradeUp, 2 left over" without the player doing the arithmetic.
function Features.Trade.Plan()
    local counts = unsellableByRarity()
    local plan = {}
    for key, recipe in pairs(CONST.TradeUps) do
        local have = counts[recipe.From] or 0
        local runs = math.floor(have / recipe.Amount)
        if runs > 0 then
            plan[#plan + 1] = { Key = key, Runs = runs, From = recipe.From,
                                To = recipe.To, Left = have % recipe.Amount }
        end
    end
    table.sort(plan, function(a, b) return a.Runs > b.Runs end)
    return plan
end

function Features.Trade.Run(key)
    key = key or Config.TradeRecipe
    local list, err = collectForRecipe(key)
    if not list then
        notify("Trade-up: " .. err)
        return nil, err
    end
    local reward
    local ok = pcall(function() reward = CONST.Remote.TradeUp:InvokeServer(key, list) end)
    if ok and reward then
        notify(("Trade-up %s -> %s"):format(key, tostring(reward)))
        return reward
    end
    notify("Trade-up failed: " .. key)
end

function Features.Trade.Start()
    if Panel.Running.AutoTrade then return end
    Panel.Running.AutoTrade = true
    local gen = newGen("AutoTrade")
    notify("Auto trade-up running: " .. Config.TradeRecipe)
    task.spawn(function()
        while live("AutoTrade", gen) do
            beat("AutoTrade")
            -- pcall'd like Buy: a recipe shaped differently than expected must not kill the
            -- coroutine while the toggle stays lit. A failed run backs off instead of
            -- notifying every 1.5s.
            local ok, res = pcall(function()
                if not collectForRecipe(Config.TradeRecipe) then return "idle" end
                return Features.Trade.Run(Config.TradeRecipe) and "done" or "failed"
            end)
            if not ok then log("trade pass failed: %s", tostring(res)) end
            task.wait(res == "done" and 1.5 or res == "idle" and 5 or 30)
        end
    end)
end

function Features.Trade.Stop()
    Panel.Running.AutoTrade = nil
    log("Auto trade-up stopped")
end

---------------------------------------------------------------- Claim a store
-- Nothing in the panel works until a plot is claimed: PCLocalScript itself blocks on
-- `repeat wait(0.2) until LocalPlayer.Plot.Value ~= ""`, so an unclaimed client parks every
-- loop forever. Observed live across a six client fleet, all six idle for six minutes.
--
-- The claim flow was captured with a passive listener while a human claimed one, because
-- guessing it wrong twice had already cost two runs:
--
--   [35.70s] TOUCHED pad Workspace.StorePositions.Store6
--   [36.48s] GUI click MainScreenGui.ChooseStoreFrame.StoreListFrame.store1.ChooseButton
--   [36.56s] PLOT CHANGED -> "Store6"
--   [36.57s] Stores.ChildAdded: an altStore
--
-- So: walk onto a free pad, a chooser opens, press Choose on an UNLOCKED tier, and the
-- server writes Plot. There is no claim remote and no claim prompt anywhere in the game -
-- an earlier text-matching version instead found an ItemShop "Purchase" prompt (via "own"
-- inside "Baroque Brown") and three daily-quest remotes, which would have spent money.
--
-- Note the two namespaces that look alike and are not:
--   StorePositions.StoreN  - the physical pads, and the value Plot takes
--   ChooseStoreFrame.storeN - store TIERS (First Store, Second Store), gated by progression
Features.Claim = {}

local TeleportService = game:GetService("TeleportService")

local function claimed()
    local plot = LP:FindFirstChild("Plot")
    return plot ~= nil and plot.Value ~= ""
end

Features.Claim.Claimed = claimed

-- A pad is taken when some player in the server holds it as their Plot. Store models are
-- named "<owner>Store" and only exist once claimed, so the pads are the authority here.
function Features.Claim.FreePads()
    local held = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        local v = plr:FindFirstChild("Plot")
        if v and v.Value ~= "" then held[v.Value] = plr.Name end
    end
    local free, taken = {}, 0
    local sp = workspace:FindFirstChild("StorePositions")
    for _, pad in ipairs(sp and sp:GetChildren() or {}) do
        if held[pad.Name] then taken = taken + 1 else free[#free + 1] = pad end
    end
    return free, taken, held
end

local function chooserFrame()
    local gui = Paths.MainGui
    return gui and gui:FindFirstChild("ChooseStoreFrame")
end

-- Pick the default tier: "First Store" (entry `store1`). Every other tier is gated behind
-- completing the previous one, and its LockedFrame reads "Complete the Previous Store to
-- Unlock" - pressing one does nothing at all.
local function chooseButtonFor()
    local csf = chooserFrame()
    local list = csf and csf:FindFirstChild("StoreListFrame")
    if not list then return nil end

    local entries = list:GetChildren()
    table.sort(entries, function(a, b) return a.Name < b.Name end)

    local function usable(entry)
        local btn = entry:FindFirstChild("ChooseButton")
        local locked = entry:FindFirstChild("LockedFrame")
        if not btn or (locked and locked.Visible) then return nil end
        return btn
    end

    -- by name first, then by its label, then fall back to the first unlocked tier
    local first = list:FindFirstChild("store1")
    if first then
        local btn = usable(first)
        if btn then return btn, "store1" end
    end
    for _, entry in ipairs(entries) do
        local label = entry:FindFirstChild("StoreNameText")
        if label and tostring(label.Text):lower():find("first") then
            local btn = usable(entry)
            if btn then return btn, entry.Name end
        end
    end
    for _, entry in ipairs(entries) do
        local btn = usable(entry)
        if btn then return btn, entry.Name end
    end
end

-- Pressing the chooser is timing, not aim.
--
-- While the chooser is CLOSED, ChooseButton has exactly one connection: SoundScript, which
-- is attached to every button under MainScreenGui and only plays a click. The game binds its
-- real handler as the frame opens - measured live, open chooser reports two connections, the
-- second one being the game's. So an early press "succeeds" and claims nothing, which is
-- what every failed pad attempt looked like.
--
-- VirtualInputManager was the previous approach and it is unusable here: a synthetic click
-- only lands in the FOCUSED window, so it worked on whichever client was on screen and
-- silently failed on the other five. Firing the connection needs no focus.
local VirtualInput = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")

-- Connections that are not SoundScript. Returns them so a caller can tell "handler is bound"
-- from "only the click sound is bound".
local function gameHandlers(signal)
    local ok, conns = pcall(getconnections, signal)
    if not ok then return {} end
    local out = {}
    for _, c in ipairs(conns) do
        local src = ""
        pcall(function() src = tostring(debug.info(c.Function, "s")) end)
        if not src:find("SoundScript") then out[#out + 1] = c end
    end
    return out
end

-- Wait for the game to bind its handler, then fire exactly that.
local function clickGui(btn, timeout)
    local t0 = os.clock()
    local handlers = gameHandlers(btn.MouseButton1Click)
    while #handlers == 0 and os.clock() - t0 < (timeout or 3) do
        task.wait(0.15)
        handlers = gameHandlers(btn.MouseButton1Click)
    end
    if #handlers == 0 then
        -- Nothing but the click sound is bound. Fall back to a real click, which only works
        -- if this window happens to be focused - better than doing nothing, but say so.
        local pos, size = btn.AbsolutePosition, btn.AbsoluteSize
        local inset = GuiService:GetGuiInset()
        pcall(function()
            VirtualInput:SendMouseButtonEvent(pos.X + size.X / 2, pos.Y + size.Y / 2 + inset.Y, 0, true, game, 0)
            task.wait(0.06)
            VirtualInput:SendMouseButtonEvent(pos.X + size.X / 2, pos.Y + size.Y / 2 + inset.Y, 0, false, game, 0)
        end)
        return false, "no game handler bound; fell back to a focus-dependent click"
    end
    for _, c in ipairs(handlers) do
        pcall(function() c:Fire() end)
    end
    return true, ("fired %d handler(s)"):format(#handlers)
end

local function waitClaimed(seconds)
    local t0 = os.clock()
    repeat task.wait(0.2) until claimed() or os.clock() - t0 > (seconds or 3)
    return claimed()
end

-- One pad, start to finish. Returns true only when the SERVER-owned Plot value fills in.
--
-- The arrival matters more than the click. Tweening straight onto the pad anchors the
-- character in permanent contact, so `Touched` fires once and never again - which looks
-- exactly like the pad breaking after the first attempt, and it did. So: fly to a point
-- BESIDE the pad, hand control back to physics, then walk the last stretch. The touch is
-- then a real transition and the chooser opens the way it does for a player.
function Features.Claim.TakePad(pad)
    local ok, pivot = pcall(function()
        return pad:IsA("BasePart") and pad.CFrame or pad:GetPivot()
    end)
    if not ok or not pivot then return false, "pad has no position" end

    local char = LP.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not (hrp and hum) then return false, "no character" end

    -- land clear of the pad, then restore physics: an anchored arrival is what kills Touched
    Features.Bar.TweenTo(pivot * CFrame.new(0, 6, 18))
    task.wait(0.4)
    pcall(function()
        hrp.Anchored = false
        hum.PlatformStand = false
    end)
    task.wait(0.4)

    hum:MoveTo(pivot.Position)

    local t0 = os.clock()
    local csf
    repeat
        task.wait(0.2)
        csf = chooserFrame()
    until (csf and csf.Visible) or os.clock() - t0 > 10
    if not (csf and csf.Visible) then
        return false, "chooser did not open on " .. pad.Name
    end

    local btn, tier = chooseButtonFor()
    if not btn then return false, "no unlocked store tier in the chooser" end

    -- Stand still while choosing: stepping off the pad closes the chooser mid-attempt.
    pcall(function() hum:Move(Vector3.new()) end)
    task.wait(0.4)
    local fired, how = clickGui(btn)
    log("claim press on %s: %s", tostring(tier), tostring(how))
    if not fired and not waitClaimed(2) then
        return false, "chooser handler never bound (" .. tostring(how) .. ")"
    end
    if waitClaimed(5) then
        log("CLAIM %s via tier %s", pad.Name, tostring(tier))
        return true, pad.Name
    end
    return false, ("pressed Choose on %s but Plot never filled in"):format(tostring(tier))
end

-- Re-arm after a hop, or the teleport lands in a fresh DataModel with no bridge and no
-- panel: a dead window that still costs 2 GB.
local function armRejoin()
    local q = queue_on_teleport or queueonteleport
        or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
    if not q then return false, "executor has no queue_on_teleport" end
    local payload = [==[
        task.wait(8)
        pcall(function() loadstring(game:HttpGet("http://localhost:3111/loader-script"))() end)
        task.wait(4)
        pcall(function() loadstring(readfile("panel_v2.lua"), "panel_v2")() end)
    ]==]
    local ok = pcall(q, payload)
    return ok, ok and "armed" or "queue_on_teleport rejected the payload"
end

Features.Claim.ArmRejoin = armRejoin

local function pickServer()
    local ok, body = pcall(function()
        return game:HttpGet(("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100")
            :format(game.PlaceId))
    end)
    if not ok or type(body) ~= "string" then return nil end
    local decoded
    if not pcall(function() decoded = game:GetService("HttpService"):JSONDecode(body) end) then return nil end
    local best
    for _, srv in ipairs((decoded and decoded.data) or {}) do
        if srv.id ~= game.JobId and (srv.playing or 0) < (srv.maxPlayers or 0) then
            if not best or (srv.playing or 0) < (best.playing or 0) then best = srv end
        end
    end
    return best
end

function Features.Claim.Hop()
    local armed, why = armRejoin()
    if not armed then return false, "will not hop: " .. tostring(why) end
    local srv = pickServer()
    log("hopping for a free pad%s", srv and (" -> %d/%d players"):format(srv.playing, srv.maxPlayers) or "")
    Panel.Hops = (Panel.Hops or 0) + 1
    return pcall(function()
        if srv then
            TeleportService:TeleportToPlaceInstance(game.PlaceId, srv.id, LP)
        else
            TeleportService:Teleport(game.PlaceId, LP)
        end
    end)
end

function Features.Claim.Try()
    if claimed() then return true, "already claimed" end
    local free, taken = Features.Claim.FreePads()
    if #free == 0 then
        return false, ("no free pad here (%d taken)"):format(taken)
    end
    -- ONE pad per attempt, deliberately. Sweeping every free pad in one pass means four
    -- anchored CFrame tweens plus four chooser cycles back to back, which preceded a client
    -- dying; the retry loop revisits the others a few seconds later anyway.
    local pad = free[(Panel.ClaimPad or 0) % #free + 1]
    Panel.ClaimPad = (Panel.ClaimPad or 0) + 1
    local ok, why = Features.Claim.TakePad(pad)
    if ok then return true, why end
    if claimed() then return true, "claimed during retry" end
    return false, ("%s: %s (%d free)"):format(pad.Name, tostring(why), #free)
end

function Features.Claim.Start()
    if Panel.Running.AutoClaim then return end
    Panel.Running.AutoClaim = true
    local gen = newGen("AutoClaim")
    task.spawn(function()
        local attempts = 0
        while live("AutoClaim", gen) do
            beat("AutoClaim")
            if claimed() then
                if attempts > 0 then notify("Plot claimed: " .. tostring(LP.Plot.Value)) end
                Panel.Running.AutoClaim = nil
                break
            end
            attempts = attempts + 1
            local ok, why = Features.Claim.Try()
            if ok then
                notify("Plot claimed: " .. tostring(LP.Plot.Value))
                Panel.Running.AutoClaim = nil
                break
            end

            log("auto-claim attempt %d: %s", attempts, tostring(why))
            local noPad = tostring(why):find("no free pad")
            if noPad and Config.ClaimHop and (Panel.Hops or 0) < Config.MaxHops then
                local hopped, hopWhy = Features.Claim.Hop()
                if not hopped then
                    notify("Cannot hop: " .. tostring(hopWhy))
                    Panel.Running.AutoClaim = nil
                    break
                end
                task.wait(10)
            elseif noPad then
                -- Pads free up when players leave, so waiting is not hopeless - but say so
                -- rather than looking busy.
                Panel.Phase = "Waiting for a free store pad"
                task.wait(20)
            else
                task.wait(5)
            end
        end
    end)
end

function Features.Claim.Stop()
    Panel.Running.AutoClaim = nil
end

---------------------------------------------------------------- Market: rotations
-- Rotations are a pure function of UTC time, computed identically on every client. So the
-- panel never polls for them - it computes the schedule and sets alarms.
Features.Market = {}

function Features.Market.At(hour, yday)
    local t = os.date("!*t")
    hour = hour or t.hour
    yday = yday or t.yday
    local limited = CONST.LimitedShop[hour % 6 + 1]
    local grail   = CONST.GrailRot[hour % #CONST.GrailRot + 1]
    local box     = CONST.MoneyBoxes[Random.new(yday + hour * hour):NextInteger(1, #CONST.MoneyBoxes)]
    return {
        Hour = hour,
        Limited = limited,
        LimitedPrice = limited and CONST.Sneakers[limited] and CONST.Sneakers[limited].LimitedPrice,
        Grail = grail,
        MoneyBox = box,
        BoxPrice = box and CONST.BoxPrices and CONST.BoxPrices[box],
    }
end

function Features.Market.Schedule(hours)
    local t, out = os.date("!*t"), {}
    for i = 0, (hours or 24) - 1 do
        local h = (t.hour + i) % 24
        local r = Features.Market.At(h, t.yday + math.floor((t.hour + i) / 24))
        r.InHours = i
        out[#out + 1] = r
    end
    return out
end

function Features.Market.NextTimeFor(name, lookahead)
    for _, r in ipairs(Features.Market.Schedule(lookahead or 48)) do
        if r.Limited == name then return r end
    end
end

function Features.Market.SecondsToHour()
    local t = os.date("!*t")
    return 3600 - (t.min * 60 + t.sec)
end

-- Limited-shop sniper. Purchase is a server-owned ProximityPrompt at 7 studs and distance
-- is enforced server-side (tested: firing from 139 studs did nothing), so the character
-- genuinely has to travel. Everything else is clock arithmetic.
local function limitedBoxes()
    local shop = workspace:FindFirstChild("LimitedShop")
    local boxes = shop and shop:FindFirstChild("Boxes")
    return boxes and boxes:GetChildren() or {}
end

-- travelOnly gets us standing at the box without firing the prompt. Firing early buys
-- whatever is on sale RIGHT NOW, not the target - the rotation flips on the hour.
-- `only` restricts it to the box selling that sneaker (the prompt's ObjectText is the
-- sneaker name, checked live), so a second box can never ride along on one decision.
function Features.Market.SnipeNow(travelOnly, only)
    local acted, epoch = false, Panel.KillEpoch

    for _, box in ipairs(limitedBoxes()) do
        local hp = box:FindFirstChild("HoldPart")
        local prompt = hp and hp:FindFirstChild("BuyPrompt")
        if prompt and prompt.Enabled and (not only or travelOnly or prompt.ObjectText == only) then
            local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
            local d = hrp and (hp.Position - hrp.Position).Magnitude or 1e9
            if d > (prompt.MaxActivationDistance or 7) - 2 then
                Features.Bar.TweenTo(hp.CFrame * CFrame.new(0, 0, 4))
                task.wait(0.4)
            end
            if Panel.KillEpoch ~= epoch then return acted end   -- kill switch mid-travel
            if not travelOnly then
                pcall(function()
                    fireproximityprompt(prompt, prompt.HoldDuration > 0 and prompt.HoldDuration or nil)
                end)
            end
            acted = true
        end
    end
    return acted
end

function Features.Market.SnipeStart()
    if Panel.Running.LimitedSnipe then return end
    Panel.Running.LimitedSnipe = true
    local gen = newGen("LimitedSnipe")
    notify("Limited sniper armed: " .. (Config.WatchTarget ~= "" and Config.WatchTarget
        or "whatever is on sale now (one buy, then disarms)"))
    task.spawn(function()
        local firedFor, skippedFor = nil, nil
        while live("LimitedSnipe", gen) do
            beat("LimitedSnipe")
            local now = Features.Market.At()
            local want = Config.WatchTarget
            local matches = (want == "" ) or (now.Limited == want)
            local secs = Features.Market.SecondsToHour()
            if matches and firedFor ~= now.Hour then
                -- Through the spend gate like every other outlay: limiteds run $200k-$10M.
                local okSpend, spendWhy = canSpend(now.LimitedPrice or 0)
                if now.LimitedPrice and okSpend then
                    firedFor = now.Hour
                    local before = money()
                    log("SNIPE %s @ $%s", tostring(now.Limited), commas(now.LimitedPrice or 0))
                    Features.Market.SnipeNow(false, now.Limited)
                    task.wait(3)
                    if before - money() >= now.LimitedPrice * 0.9 then recordSpend(now.LimitedPrice) end
                    -- Parked at the shop the PC page is unreadable and buying stalls.
                    if Config.BarReturn or Panel.Running.AutoBuy then Features.Bar.ReturnToPC() end
                    -- Blank target means "this one", not "every rotation, forever".
                    if want == "" then
                        notify("Limited sniper: bought the current rotation, disarming")
                        Panel.Running.LimitedSnipe = nil
                        local tg = Panel.Library and Panel.Library.Toggles.LimitedSnipe
                        if tg then pcall(function() tg:SetValue(false) end) end
                        return
                    end
                elseif skippedFor ~= now.Hour then
                    -- Not firedFor: cash can still arrive later in the hour.
                    skippedFor = now.Hour
                    log("snipe waiting: %s costs $%s (%s)", tostring(now.Limited),
                        commas(now.LimitedPrice or 0), tostring(spendWhy or "no price"))
                end
            end
            -- travel early so we are standing there when the rotation flips. Travel ONLY:
            -- firing the prompt here would buy the current hour's shoe, not the target.
            local nextR = Features.Market.At((now.Hour + 1) % 24)
            if want ~= "" and nextR.Limited == want and secs <= Config.SnipeLead then
                Features.Market.SnipeNow(true)
                task.wait(secs > 5 and 5 or 1)
            end
            task.wait(5)
        end
    end)
end

function Features.Market.SnipeStop()
    Panel.Running.LimitedSnipe = nil
    log("Limited sniper stopped")
end

-- Alias so a blanket "stop everything" sweep over Features finds it by the usual name.
Features.Market.Stop = Features.Market.SnipeStop

---------------------------------------------------------------- Market: SHOES drops
Features.Drops = {}

function Features.Drops.List()
    local data
    pcall(function() data = CONST.Remote.ShoesData:InvokeServer() end)
    local out = {}
    if type(data) == "table" then
        for _, entry in pairs(data) do
            local v = entry.value or entry
            if type(v) == "table" and v.Sn then
                out[#out + 1] = { Name = v.Sn, Price = v.Pc, Stock = v.Cw,
                                  ReleaseAt = v.tm, In = (v.tm or 0) - os.time() }
            end
        end
    end
    table.sort(out, function(a, b) return (a.ReleaseAt or 0) < (b.ReleaseAt or 0) end)
    return out
end

function Features.Drops.Buy(name, price)
    local ok, res = pcall(function() return CONST.Remote.BuyShoesApp:InvokeServer(name) end)
    if ok and res == true then
        recordSpend(price or 0)
        notify("Drop bought: " .. name)
    else
        notify("Drop failed: " .. tostring(res))
    end
    return res
end

function Features.Drops.Start()
    if Panel.Running.AutoDrops then return end
    Panel.Running.AutoDrops = true
    Panel.DropFail = Panel.DropFail or {}
    local gen = newGen("AutoDrops")
    notify("Drop sniper armed")
    task.spawn(function()
        while live("AutoDrops", gen) do
            beat("AutoDrops")
            -- pcall'd: one odd field type (Pc arrives as the server sends it) used to kill
            -- the coroutine silently while the toggle stayed lit.
            local passOk, passErr = pcall(function()
                for _, d in ipairs(Features.Drops.List()) do
                    local price = tonumber(d.Price) or 0
                    local priceOk = Config.DropMaxPrice == 0 or price <= Config.DropMaxPrice
                    local released = (tonumber(d.ReleaseAt) or 0) <= os.time()
                    -- A refused drop (sold out, cooldown) is not retried for 5 minutes.
                    local backoff = os.clock() - (Panel.DropFail[d.Name] or -1e9) < 300
                    if released and priceOk and not backoff and Econ.Profit(d.Name, price) > 0
                       and canSpend(price) then
                        if Features.Drops.Buy(d.Name, price) ~= true then
                            Panel.DropFail[d.Name] = os.clock()
                        end
                        task.wait(1)
                    end
                end
            end)
            if not passOk then log("drops pass failed: %s", tostring(passErr)) end
            task.wait(10)
        end
    end)
end

function Features.Drops.Stop()
    Panel.Running.AutoDrops = nil
    log("Drop sniper stopped")
end

---------------------------------------------------------------- Market: mystery boxes
-- Opening is already automated by the game (MysteryBoxAutoOpen drives OpenBoxEvent), so
-- the panel just drives that switch instead of rebuilding it.
Features.Boxes = {}

function Features.Boxes.SetAutoOpen(on)
    local gui = Paths.MainGui
    local flag = gui and gui:FindFirstChild("MysteryBoxAutoOpen")
    local val = flag and flag:FindFirstChild("IsTurnedOn")
    if not val then return false, "MysteryBoxAutoOpen not found" end
    val.Value = on and true or false
    return true
end

function Features.Boxes.NextBoxes(hours)
    local out = {}
    for _, r in ipairs(Features.Market.Schedule(hours or 24)) do
        if r.MoneyBox then
            out[#out + 1] = { In = r.InHours, Hour = r.Hour, Box = r.MoneyBox, Price = r.BoxPrice }
        end
    end
    return out
end

--=========================================================================
-- [5] DIRECTOR - the "keep it optimal" half of the panel
--
-- Two loops, deliberately separate:
--   PHASE decides WHICH features should be running for the bankroll you have.
--   TUNER decides WHAT NUMBERS those features use, from measured throughput.
--
-- Both only ever write Config and toggles, never remotes, so anything they do is
-- visible in the UI and can be overridden by turning the Director off.
--=========================================================================
Features.Director = {}

-- Phases exist because the right strategy genuinely changes with bankroll:
--   Bootstrap  no slots, tiny cash    -> buy anything profitable, dump fast, unlock slots
--   Scale      slots coming online    -> value-split selling, bar the good stock
--   Cruise     16 slots, deep pockets -> pure margin: only high-value units are worth time
local function decidePhase()
    local slots = slotsNow()
    local cash  = money()
    if slots < 8 or cash < 50000 then return "Bootstrap" end
    if slots < CONST.MaxSlots or cash < 2000000 then return "Scale" end
    return "Cruise"
end

local function applyPhase(phase)
    if phase == "Bootstrap" then
        -- Cash is the constraint, not margin. Take every profitable trade, keep the
        -- inventory small so money is never parked in stock, and get the slots up.
        Config.MarginPct   = 8
        Config.MaxUnitPct  = 35
        Config.SellAtUnits = 12
        Config.MinUnitValue = 0
        -- TargetSlots is NOT a Director dial: an operator's lower target is a spend limit.
    elseif phase == "Scale" then
        Config.MarginPct   = 12
        Config.MaxUnitPct  = 25
        Config.SellAtUnits = 25
        Config.MinUnitValue = 0
    else -- Cruise
        -- Slots are done and cash is not the limit: throughput now costs time, not money,
        -- so stop spending page-time on units too cheap to be worth a sale.
        Config.MarginPct   = 18
        Config.MaxUnitPct  = 20
        Config.SellAtUnits = 40
        Config.MinUnitValue = math.max(Config.MinUnitValue, 1500)
    end
    -- A preset's dials win over the phase baseline: otherwise AFK Safe's 25% margin and
    -- 10% unit cap lasted exactly until the Director's first pass.
    for _, k in ipairs({ "MarginPct", "MaxUnitPct", "SellAtUnits", "MinUnitValue" }) do
        local v = Panel.PresetOverlay and Panel.PresetOverlay[k]
        if v ~= nil then Config[k] = v end
    end
end

-- Turn a feature on/off through its toggle when there is one, so the UI never lies about
-- what is running. Falls back to the raw Start/Stop when the UI is not built yet.
-- Drive the LOOP, and keep the toggle in sync as a second step.
--
-- This used to only call SetValue when the toggle disagreed, and let the toggle's callback
-- do the starting. That silently never started any feature whose default was already ON:
-- SetValue(true) on a toggle already true is a no-op, so the callback never fired and the
-- loop never existed - the UI said AutoBar was on while nothing was running.
--
-- `gated` = the toggle is a PERMISSION and `on` also folds in a runtime condition (stock
-- level, slot target). Those must not be written back to the toggle: its callback stores the
-- value in Config, so the first "not needed right now" pass revoked the permission for good
-- and the cashier valve never re-armed. The Loops readout shows what is actually running.
local function setFeature(key, on, startFn, stopFn, gated)
    local running = Panel.Running[key] ~= nil
    if on and not running then
        startFn()
    elseif not on and running then
        stopFn()
    end
    if gated then return end
    local tg = Panel.Library and Panel.Library.Toggles and Panel.Library.Toggles[key]
    if tg and tg.Value ~= on then pcall(function() tg:SetValue(on) end) end
end

-- `restart` = the watchdog reviving a stalled Director. That is not the operator turning it
-- on, so it must not re-arm switches the operator has since turned off.
function Features.Director.Start(restart)
    if Panel.Running.Director then return end
    Panel.Running.Director = true
    local gen = newGen("Director")

    -- Arm the income engine ONCE, here. After this the loop only reads these flags, so
    -- switching one off in the UI stays off until the operator turns the Director off and
    -- on again. Anything already set false by a preset or by hand is left alone.
    if Config.ArmOnStart ~= false and not restart then
        Config.AutoBuy = true
        Config.AutoSell = true
        -- AutoSell is gated in setFeature, so its toggle is not synced there. Show the
        -- permission here, without firing the callback (that would start the loop now).
        local tg = Panel.Library and Panel.Library.Toggles and Panel.Library.Toggles.AutoSell
        if tg and not tg.Value then pcall(function() tg.Value = true; tg:Display() end) end
        -- AutoUpgrade is deliberately NOT armed. A slot unlock is one irreversible purchase
        -- of up to $50,000,000, and arming it here cost a real $2,000,000: a client rejoined,
        -- booted on defaults, and bought slot 14 in the ~90s before its profile was pushed.
        -- Unlocking slots is the operator's decision, not a side effect of starting the Director.
    end
    notify("Director on - phases and tuning are automatic")

    task.spawn(function()
        while live("Director", gen) do
            beat("Director")
            local ok, err = pcall(function()
                -- Say WHY it is parked. This used to be `if not storeReady() then return end`,
                -- which spins every 10s forever on a client with no plot: no log line, phase
                -- stuck on "Idle", last word in the log still "Director on". Six minutes of a
                -- fleet test looked healthy while nothing could ever run.
                local ready, why = storeReady()
                if not ready then
                    -- Report only. Auto-claim is opt-in and off: it moves the character,
                    -- and a farm loop should never move a character the operator did not ask
                    -- it to move.
                    if why == "no store claimed yet" and not Panel.SaidClaim then
                        Panel.SaidClaim = true
                        local free = Features.Claim.FreePads()
                        notify(("No plot on this client - claim one manually (%d pads free)"):format(#free))
                    end
                    Panel.Phase = "Blocked: " .. tostring(why)
                    if Panel.LastStoreBlock ~= why then
                        Panel.LastStoreBlock = why
                        notify("Director parked: " .. tostring(why))
                    end
                    return
                end
                if Panel.LastStoreBlock then
                    Panel.LastStoreBlock = nil
                    log("store ready - Director resuming")
                end

                local phase = decidePhase()
                -- Baselines are applied ON THE PHASE CHANGE ONLY. Re-applying every pass
                -- would silently overwrite whatever the tuner had learned since, so the
                -- panel would look like it was tuning while standing still.
                if phase ~= Panel.Phase then
                    Panel.Phase = phase
                    applyPhase(phase)
                    notify(("Phase: %s (%d slots, $%s)"):format(phase, slotsNow(), commas(money())))
                end

                -- Every toggle is a PERMISSION the Director may not override.
                --
                -- These used to be forced: AutoBuy hardcoded `true`, AutoUpgrade gated only on
                -- slot count. Turning either off in the UI worked for about ten seconds, then
                -- the next Director pass restarted the loop AND flipped the switch back on -
                -- so the panel looked like it was ignoring the operator, because it was.
                --
                -- The Director still decides WHEN a permitted feature runs; it no longer
                -- decides whether it is allowed to.
                setFeature("AutoBuy", Config.AutoBuy == true, Features.Buy.Start, Features.Buy.Stop)
                setFeature("AutoUpgrade",
                           Config.AutoUpgrade == true and slotsNow() < math.min(Config.TargetSlots, CONST.MaxSlots),
                           Features.Slots.Start, Features.Slots.Stop, true)

                -- The cashier loop is the pressure valve. It runs whenever the bar is not
                -- draining stock fast enough, and always when the bar is off.
                -- barOn means "the bar drains stock on its own" (loop + permission to walk),
                -- which is what the valve cares about. It is NOT the run-permission for the
                -- bar loop itself: AutoBar with BarApproach off is the legit manual mode
                -- (player walks, panel times the stop), and stopping it here overrode the
                -- operator's toggle every 10s.
                local barOn = Config.AutoBar and Config.BarApproach
                local units = sellableUnits()
                -- Hysteresis: arm at the threshold, disarm only at half of it. Without the
                -- gap the valve flaps on and off every pass while stock sits on the line.
                local wantSell = (not barOn)
                    or units >= Config.SellAtUnits
                    or (Panel.Running.AutoSell and units > Config.SellAtUnits / 2)
                setFeature("AutoSell", Config.AutoSell == true and wantSell and true or false,
                           Features.Sell.Start, Features.Sell.Stop, true)
                setFeature("AutoBar", Config.AutoBar == true, Features.Bar.Start, Features.Bar.Stop)
            end)
            if not ok then log("director pass failed: %s", tostring(err)) end
            task.wait(10)
        end
    end)
end

function Features.Director.Stop()
    Panel.Running.Director = nil
    log("Director off - settings are yours again")
end

--=========================================================================
-- TUNER - moves the dials the Director does not own, from measurement.
--
-- Three signals, three dials. Nothing else is auto-changed, because a tuner that
-- touches everything is impossible to reason about when it goes wrong.
--
--   starving  (offers seen, nothing bought for a while)  -> loosen the margin
--   cash-bound(buy loop blocked on money, stock on hand) -> sell sooner
--   stock mix (median held value)                        -> move the bar/cashier split
--=========================================================================
function Features.Director.Tune()
    local nowT = os.clock()
    local mpm = Econ.PerMinute()
    Panel.PerMinute = mpm

    -- 1. Starving: the page has offers but nothing clears the filter, and no buy has landed
    -- in two tuner windows. Loosen the demanded margin, never below +2% over break-even -
    -- under that the panel would be buying trades it cannot profit on.
    local sinceBuy = nowT - (Panel.LastBuy or Panel.StartClock)
    -- Away from the PC (bar trip, snipe) nothing CAN be bought; that is not a filter too tight.
    local away = Panel.WentToNpc or (Paths.SellAnim and Paths.SellAnim.Visible)
    if Config.AutoROI and Panel.Running.AutoBuy and not away and sinceBuy > Config.TuneEvery * 2 then
        local before = Config.MarginPct
        Config.MarginPct = math.max(2, Config.MarginPct - 2)
        if Config.MarginPct ~= before then
            log("tuner: starving (%.0fs no buy) -> margin %d%% -> %d%%", sinceBuy, before, Config.MarginPct)
        end
    elseif Config.AutoROI and sinceBuy < Config.TuneEvery / 2 and Config.MarginPct < 25 then
        -- Buying freely: buy BETTER instead of more. Raising the margin here is what turns
        -- a fast-but-thin loop into a fast-and-fat one.
        Config.MarginPct = Config.MarginPct + 1
    end

    -- 2. Cash-bound with stock on hand: the money is sitting in the inventory. Pull the
    -- dump threshold down so it converts sooner. Floor at 5 - below that the cashier call
    -- costs more round trips than it saves.
    if Panel.LastBlock and tostring(Panel.LastBlock):find("not enough money") and sellableUnits() > 0 then
        local before = Config.SellAtUnits
        Config.SellAtUnits = math.max(5, Config.SellAtUnits - 5)
        if Config.SellAtUnits ~= before then
            log("tuner: cash-bound -> dump at %d units (was %d)", Config.SellAtUnits, before)
        end
    end

    -- 3. Split the stock where it actually splits. A fixed BarMinValue either sends
    -- everything to the bar (which then cannot keep up) or nothing (which wastes the 2x).
    if Config.AutoBarValue and Config.SellRouter then
        local med = Econ.MedianStockValue()
        if med and med > 0 then
            local target = math.max(500, math.floor(med))
            if math.abs(target - Config.BarMinValue) / math.max(1, Config.BarMinValue) > 0.2 then
                log("tuner: bar/cashier split $%s -> $%s (median held value)",
                    commas(Config.BarMinValue), commas(target))
                Config.BarMinValue = target
            end
        end
    end
end

task.spawn(function()
    while Panel.Alive ~= false do
        task.wait(math.max(5, Config.TuneEvery))
        -- Gated on the store too: a parked client used to keep tuning off stale inventory
        -- and silently drift its config away from the profile it was given.
        if Panel.Running.Director and select(1, storeReady()) then
            pcall(Features.Director.Tune)
        end
    end
end)

--=========================================================================
-- [6] UI
--
-- Widgets only read and write Config. No widget calls a remote directly, so the
-- panel behaves identically whether a value came from a click, a preset, the
-- Director, or a saved config file.
--=========================================================================

local Library      = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua"))()
local ThemeManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/ThemeManager.lua"))()
local SaveManager  = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/SaveManager.lua"))()

Panel.Library = Library

local Window = Library:CreateWindow({
    Title = "CruelHub", Icon = (function() -- CruelHub logo from the repo, cached in the workspace; a skull if the executor can't load it
        local ok, id = pcall(function()
            local f = "CruelHub/logo.jpg"
            if not isfolder("CruelHub") then makefolder("CruelHub") end
            if not isfile(f) then
                local img = game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/assets/cruelhub.jpg")
                assert(img:sub(1, 2) == "\255\216", "not a jpeg")
                writefile(f, img)
            end
            return getcustomasset(f)
        end)
        return ok and id or "skull"
    end)(),
    Footer = "Sneaker Resell Simulator - F4 kill, F5 perf",
    Center = true,
    AutoShow = true,
    ShowCustomCursor = true,
    NotifySide = "Right",
    Size = UDim2.fromOffset(680, 560),
})

-- Six tabs, one job each. A setting lives next to the loop that reads it, and every
-- auto/manual pair shows only the half that is currently in effect (dependency boxes),
-- so nothing on screen is a dial that does nothing.
local Tabs = {
    Home   = Window:AddTab("Home", "gauge"),
    Buy    = Window:AddTab("Buy", "shopping-cart"),
    Sell   = Window:AddTab("Sell", "banknote"),
    Market = Window:AddTab("Market", "store"),
    Craft  = Window:AddTab("Craft", "hammer"),
    System = Window:AddTab("System", "cpu"),
    Config = Window:AddTab("Settings", "settings"),
}

local L = {}

-- Show `box` only while every { element, value } pair matches.
local function dependsOn(box, ...)
    box:SetupDependencies({ ... })
    return box
end

local function applyPreset(name)
    local overlay = PRESETS[name]
    if not overlay then return end
    Panel.PresetOverlay = overlay
    for k, v in pairs(overlay) do
        Config[k] = v
        local tg = Library.Toggles[k]
        local op = Library.Options[k]
        if tg then pcall(function() tg:SetValue(v) end)
        elseif op then pcall(function() op:SetValue(v) end) end
    end
    notify("Preset applied: " .. name)
end

---------------------------------------------------------------- Home tab
local DirBox = Tabs.Home:AddLeftGroupbox("Director", "brain")

DirBox:AddToggle("Director", {
    Text = "Director (auto strategy)",
    Tooltip = "Runs the phase machine and the tuner: picks which features run and keeps the\n" ..
              "ROI floor, unit cap and bar/cashier split on the measured optimum.\n" ..
              "Turn off to drive everything by hand.",
    Default = Config.Director,
    Callback = function(v)
        Config.Director = v
        if v then Features.Director.Start() else Features.Director.Stop() end
    end,
})

local DirDep = dependsOn(DirBox:AddDependencyBox(), { Library.Toggles.Director, true })
DirDep:AddSlider("TuneEvery", {
    Text = "Tuner interval",
    Default = Config.TuneEvery, Min = 5, Max = 120, Rounding = 0, Suffix = "s",
    Callback = function(v) Config.TuneEvery = v end,
})

DirBox:AddDivider()

DirBox:AddDropdown("Preset", {
    Text = "Preset",
    Tooltip = "Max Money: everything on, bar-sell routing, walks to NPCs.\n" ..
              "AFK Safe: same engine, gentler pacing and a 10% bankroll cap per buy.\n" ..
              "No Travel: cashier only, character never moves.\n" ..
              "Fleet: cashier only + perf mode, for many clients on one machine.\n" ..
              "Collector: index/trade-up focus, money secondary.\n" ..
              "No preset ever unlocks slots - that stays a manual decision (Buy tab).",
    Values = { "Max Money", "AFK Safe", "No Travel", "Fleet", "Collector" },
    Default = Config.Preset,
    Callback = function(v) Config.Preset = v end,
})
DirBox:AddButton({ Text = "Apply preset", Func = function() applyPreset(Config.Preset) end })

local SafeBox = Tabs.Home:AddLeftGroupbox("Safety", "shield")

SafeBox:AddButton({ Text = "KILL ALL (F4)", Func = function() stopAll("button") end })

SafeBox:AddToggle("PanicSell", {
    Text = "Dump inventory on kill",
    Default = Config.PanicSell,
    Callback = function(v) Config.PanicSell = v end,
})

SafeBox:AddSlider("SpendCap", {
    Text = "Session spend cap",
    Default = Config.SpendCap, Min = 0, Max = 50000000, Rounding = 0, Suffix = "$",
    Tooltip = "0 = unlimited. Every outlay in the panel passes one gate, so this covers buys,\n" ..
              "slot unlocks, drops and snipes alike.",
    Callback = function(v) Config.SpendCap = v end,
})

SafeBox:AddButton({ Text = "Reset session counters", Func = function()
    Panel.Spent, Panel.Bought, Panel.Sold = 0, 0, 0
    Panel.BarSales, Panel.BarAimed, Panel.Earned = 0, 0, 0
    Panel.StartMoney, Panel.StartClock, Econ.Hist = money(), os.clock(), {}
    notify("Session counters reset")
end })

local StatBox = Tabs.Home:AddRightGroupbox("Live", "activity")
L.Phase   = StatBox:AddLabel("Phase: -", true)
L.Rate    = StatBox:AddLabel("$/min: -", true)
L.Worth   = StatBox:AddLabel("Net worth: -", true)
L.Money   = StatBox:AddLabel("Cash: -", true)
L.Rates   = StatBox:AddLabel("Sell rates: -", true)
L.Floor   = StatBox:AddLabel("ROI floor: -", true)
L.Cap     = StatBox:AddLabel("Unit cap: -", true)
L.Aim     = StatBox:AddLabel("Bar aim: -", true)
L.Session = StatBox:AddLabel("Session: -", true)

local FlowBox = Tabs.Home:AddRightGroupbox("Loops", "list-checks")
L.Loops = FlowBox:AddLabel("-", true)

---------------------------------------------------------------- Buy tab
local BuyBox = Tabs.Buy:AddLeftGroupbox("PC offers", "monitor")

BuyBox:AddToggle("AutoBuy", {
    Text = "Auto buy",
    Tooltip = "Rerolls the PC page and buys every offer that clears the profit filter.\n" ..
              "Remote-driven: no proximity, works anywhere on the map.",
    Default = Config.AutoBuy,
    Callback = function(v)
        Config.AutoBuy = v
        if v then Features.Buy.Start() else Features.Buy.Stop() end
    end,
})

BuyBox:AddToggle("BuyBurst", {
    Text = "Burst buy the page",
    Tooltip = "Fires every eligible buy at once (~0.07s a page vs ~0.74s walked).\n" ..
              "Measured un-throttled, but it is a louder traffic pattern than a human makes.",
    Default = Config.BuyBurst,
    Callback = function(v) Config.BuyBurst = v end,
})

-- The delay only paces the walked path; a burst fires the page at once.
dependsOn(BuyBox:AddDependencyBox(), { Library.Toggles.BuyBurst, false }):AddSlider("BuyDelay", {
    Text = "Delay between buys",
    Default = Config.BuyDelay, Min = 0, Max = 2, Rounding = 2, Suffix = "s",
    Tooltip = "0 is measured safe: BuySneakerFunction is not rate limited.",
    Callback = function(v) Config.BuyDelay = v end,
})

BuyBox:AddToggle("BuyReturnToPC", {
    Text = "Return to PC on start",
    Default = Config.BuyReturnToPC,
    Callback = function(v) Config.BuyReturnToPC = v end,
})

L.Offers = BuyBox:AddLabel("-", true)
BuyBox:AddButton({ Text = "Refresh page now", Func = function()
    local ok, why = Features.Buy.RefreshPage()
    if not ok and why then notify("Refresh: " .. why) end
end })

local FilterBox = Tabs.Buy:AddLeftGroupbox("Profit filter", "filter")

FilterBox:AddToggle("AutoROI", {
    Text = "Auto ROI floor",
    Tooltip = "Derives the minimum ROI from the live sell rate instead of a typed number.\n" ..
              "Break-even is 1.82x through the cashier and 0.91x through a Perfect bar sale,\n" ..
              "so the correct floor is not a constant - it depends on how you are selling.",
    Default = Config.AutoROI,
    Callback = function(v) Config.AutoROI = v end,
})

dependsOn(FilterBox:AddDependencyBox(), { Library.Toggles.AutoROI, true }):AddSlider("MarginPct", {
    Text = "Margin over break-even",
    Default = Config.MarginPct, Min = 2, Max = 60, Rounding = 0, Suffix = "%",
    Tooltip = "How much better than break-even an offer must be. Higher = fatter trades but\n" ..
              "fewer of them. The Director and tuner move this.",
    Callback = function(v) Config.MarginPct = v end,
})

dependsOn(FilterBox:AddDependencyBox(), { Library.Toggles.AutoROI, false }):AddSlider("MinROI", {
    Text = "ROI floor",
    Default = Config.MinROI, Min = 0.5, Max = 4, Rounding = 2, Suffix = "x",
    Tooltip = "Break-even is enforced regardless: 1.82x cashier, 0.91x bar.\n" ..
              "Below that, every unit loses money.",
    Callback = function(v) Config.MinROI = v end,
})

FilterBox:AddToggle("AutoMaxUnit", {
    Text = "Auto unit-price cap",
    Tooltip = "Caps any single purchase at a share of your cash, so one expensive offer\n" ..
              "cannot eat the bankroll the loop needs to keep trading.",
    Default = Config.AutoMaxUnit,
    Callback = function(v) Config.AutoMaxUnit = v end,
})

dependsOn(FilterBox:AddDependencyBox(), { Library.Toggles.AutoMaxUnit, true }):AddSlider("MaxUnitPct", {
    Text = "Max unit price (% of cash)",
    Default = Config.MaxUnitPct, Min = 1, Max = 100, Rounding = 0, Suffix = "%",
    Callback = function(v) Config.MaxUnitPct = v end,
})

dependsOn(FilterBox:AddDependencyBox(), { Library.Toggles.AutoMaxUnit, false }):AddSlider("MaxUnitPrice", {
    Text = "Max unit price",
    Default = Config.MaxUnitPrice, Min = 100, Max = 5000000, Rounding = 0, Suffix = "$",
    Callback = function(v) Config.MaxUnitPrice = v end,
})

FilterBox:AddSlider("MinUnitValue", {
    Text = "Min sneaker value",
    Default = Config.MinUnitValue, Min = 0, Max = 100000, Rounding = 0, Suffix = "$",
    Tooltip = "Ignore sneakers whose MaxSellPrice is under this. Once selling costs time\n" ..
              "rather than money, cheap units are worse than no units. Cruise phase raises it.",
    Callback = function(v) Config.MinUnitValue = v end,
})

FilterBox:AddDropdown("BuyRarities", {
    Text = "Rarities",
    Tooltip = "Rarity does not appear in the payout formula - the ratio does. All on is\n" ..
              "correct for money; narrow it only when hunting specific index lines.",
    Values = CONST.Rarities, Multi = true,
    Default = { "Common", "Uncommon", "Epic", "Legendary", "Special", "Grail", "Limited", "Legacy" },
    Callback = function(v) Config.BuyRarities = v end,
})

local SlotBox = Tabs.Buy:AddRightGroupbox("Offer slots", "lock")
L.Store = SlotBox:AddLabel("-", true)

SlotBox:AddToggle("SlotsManualOnly", {
    Text = "Lock slot buying (manual only)",
    Tooltip = "ON means no loop can ever unlock a slot - only the button below. Slots cost up to\n" ..
              "$50,000,000 each and cannot be refunded. Unlock to reveal Auto unlock slots.\n" ..
              "Never saved: every boot starts locked.",
    Default = Config.SlotsManualOnly,
    Callback = function(v)
        Config.SlotsManualOnly = v
        if v then pcall(Features.Slots.Stop) end
    end,
})

local SlotAuto = dependsOn(SlotBox:AddDependencyBox(), { Library.Toggles.SlotsManualOnly, false })
SlotAuto:AddToggle("AutoUpgrade", {
    Text = "Auto unlock slots",
    Tooltip = "More slots = more rolls per refresh. The only compounding purchase in the game.",
    Default = Config.AutoUpgrade,
    Callback = function(v)
        Config.AutoUpgrade = v
        if v then Features.Slots.Start() else Features.Slots.Stop() end
    end,
})
SlotAuto:AddSlider("ReservePct", {
    Text = "Start saving at",
    Default = Config.ReservePct, Min = 0, Max = 100, Rounding = 0, Suffix = "%",
    Tooltip = "Percent of the next slot price at which buying pauses to save for it.\n" ..
              "0 is measured best: reserving stalls the loop that earns the slot.",
    Callback = function(v) Config.ReservePct = v end,
})

SlotBox:AddSlider("TargetSlots", {
    Text = "Target slots",
    Default = Config.TargetSlots, Min = 1, Max = CONST.MaxSlots, Rounding = 0,
    Callback = function(v) Config.TargetSlots = v end,
})

SlotBox:AddButton({ Text = "Unlock one now", Func = function()
    local ok, why = Features.Slots.BuyOne(true)
    notify(ok and "Slot unlocked" or ("Unlock failed: " .. tostring(why)))
end })

---------------------------------------------------------------- Sell tab
local CashBox = Tabs.Sell:AddLeftGroupbox("Cashier", "landmark")

CashBox:AddToggle("AutoSell", {
    Text = "Cashier loop",
    Tooltip = "Watches the inventory and dumps at the threshold. Remote-only, no proximity.\n" ..
              "With the Director on this is a permission: it runs as the bar's pressure valve.",
    Default = Config.AutoSell,
    Callback = function(v)
        Config.AutoSell = v
        if v then Features.Sell.Start() else Features.Sell.Stop() end
    end,
})

CashBox:AddSlider("SellAtUnits", {
    Text = "Dump at",
    Default = Config.SellAtUnits, Min = 1, Max = 200, Rounding = 0, Suffix = " units",
    Callback = function(v) Config.SellAtUnits = v end,
})

CashBox:AddSlider("InvHardCap", {
    Text = "Hard cap",
    Default = Config.InvHardCap, Min = 20, Max = 500, Rounding = 0, Suffix = " units",
    Tooltip = "Above this the whole inventory is dumped regardless of value: at that point\n" ..
              "volume is costing you more than the split earns.",
    Callback = function(v) Config.InvHardCap = v end,
})

CashBox:AddDropdown("SellMode", {
    Text = "Cashier mode",
    Values = { "Keep One", "Everything" }, Default = Config.SellMode,
    Tooltip = "Keep One leaves a copy of every line for the index.",
    Callback = function(v) Config.SellMode = v end,
})

CashBox:AddToggle("AutoReinvest", {
    Text = "Reinvest when broke",
    Tooltip = "Buy loop out of cash with stock on hand: liquidate and keep buying instead of idling.",
    Default = Config.AutoReinvest,
    Callback = function(v) Config.AutoReinvest = v end,
})

dependsOn(CashBox:AddDependencyBox(), { Library.Toggles.AutoReinvest, true }):AddDropdown("ReinvestVia", {
    Text = "Reinvest via",
    Values = { "Router", "Cashier", "NPC bar" }, Default = Config.ReinvestVia,
    Tooltip = "Router dumps the cheap tail first and keeps bar-grade stock for the bar.",
    Callback = function(v) Config.ReinvestVia = v end,
})

CashBox:AddButton({ Text = "Dump cheap now", Func = function() Features.Sell.DumpCheap() end })
CashBox:AddButton({ Text = "Dump everything now", Func = function() Features.Sell.DumpAll() end })

local RouteBox = Tabs.Sell:AddLeftGroupbox("Value routing", "split")

RouteBox:AddToggle("SellRouter", {
    Text = "Route by value",
    Tooltip = "Bar-sell stock worth the trip, cashier-dump the rest. A bar sale pays up to\n" ..
              "1.10x vs the cashier's 0.55x but costs a trip and a minigame per unit, so the\n" ..
              "split is by value, not by preference.",
    Default = Config.SellRouter,
    Callback = function(v) Config.SellRouter = v end,
})

local RouteDep = dependsOn(RouteBox:AddDependencyBox(), { Library.Toggles.SellRouter, true })
RouteDep:AddToggle("AutoBarValue", {
    Text = "Auto split point",
    Tooltip = "Tuner puts the bar/cashier threshold at the median value of what you hold, so\n" ..
              "half the stock goes each way. Needs the Director on.",
    Default = Config.AutoBarValue,
    Callback = function(v) Config.AutoBarValue = v end,
})

-- Not behind AutoBarValue: Dump cheap reads this threshold whether or not it is tuned.
RouteBox:AddSlider("BarMinValue", {
    Text = "Bar-sell above",
    Default = Config.BarMinValue, Min = 0, Max = 200000, Rounding = 0, Suffix = "$",
    Tooltip = "Units worth at least this go to the bar; Dump cheap sells everything under it.",
    Callback = function(v) Config.BarMinValue = v end,
})

L.Stock = RouteBox:AddLabel("-", true)

local BarBox = Tabs.Sell:AddRightGroupbox("NPC bar", "target")

BarBox:AddToggle("AutoBar", {
    Text = "Auto bar sell",
    Tooltip = "Watches the sweeping line and presses the game's own Stop button on the band\n" ..
              "you asked for. Without Walk to NPCs, you walk and the panel times the stop.",
    Default = Config.AutoBar,
    Callback = function(v)
        Config.AutoBar = v
        if v then Features.Bar.Start() else Features.Bar.Stop() end
    end,
})

BarBox:AddDropdown("BarTarget", {
    Text = "Aim for",
    Values = { "Perfect", "Good" }, Default = Config.BarTarget,
    Callback = function(v) Config.BarTarget = v end,
})

-- Falling back to Good only means something while aiming for Perfect.
dependsOn(BarBox:AddDependencyBox(), { Library.Options.BarTarget, "Perfect" }):AddToggle("BarAcceptGood", {
    Text = "Take Good over a lost pass",
    Tooltip = "One frame of travel is about as wide as the Perfect band, so roughly half of\n" ..
              "all passes never predict onto it. Good is 1.00x - still ~1.8x the cashier.",
    Default = Config.BarAcceptGood,
    Callback = function(v) Config.BarAcceptGood = v end,
})

BarBox:AddToggle("BarAutoLead", {
    Text = "Auto-calibrate aim",
    Tooltip = "Measures the real press-to-read latency from the game's own marker clone and\n" ..
              "eases the lead toward it. Beats any hardcoded offset - the band moves each sale.",
    Default = Config.BarAutoLead,
    Callback = function(v) Config.BarAutoLead = v end,
})

dependsOn(BarBox:AddDependencyBox(), { Library.Toggles.BarAutoLead, false }):AddSlider("BarLead", {
    Text = "Aim lead (frames)",
    Default = Config.BarLead, Min = 0, Max = 4, Rounding = 2,
    Callback = function(v) Config.BarLead = v end,
})

BarBox:AddToggle("BarAutoClose", {
    Text = "Close the bar when empty",
    Default = Config.BarAutoClose,
    Callback = function(v) Config.BarAutoClose = v end,
})

local TravelBox = Tabs.Sell:AddRightGroupbox("Travel", "footprints")

TravelBox:AddToggle("BarApproach", {
    Text = "Walk to NPCs",
    Tooltip = "Bar-sell distance is enforced server-side, so the character genuinely travels.\n" ..
              "Never saved: every boot starts with the character standing still.",
    Default = Config.BarApproach,
    Callback = function(v) Config.BarApproach = v end,
})

local WalkDep = dependsOn(TravelBox:AddDependencyBox(), { Library.Toggles.BarApproach, true })
WalkDep:AddSlider("BarBatch", {
    Text = "Trip batch",
    Default = Config.BarBatch, Min = 1, Max = 60, Rounding = 0, Suffix = " units",
    Tooltip = "Bar-grade units to accumulate before walking to an NPC. Selling one unit per\n" ..
              "trip starves the buy loop: the PC reroll is refused for the whole sale.",
    Callback = function(v) Config.BarBatch = v end,
})

-- Travel settings below are shared with the limited sniper, so they stay visible.
TravelBox:AddToggle("BarReturn", {
    Text = "Return to the PC after",
    Tooltip = "After a bar trip or a limited snipe.",
    Default = Config.BarReturn,
    Callback = function(v) Config.BarReturn = v end,
})

TravelBox:AddToggle("BarTunnel", {
    Text = "Tunnel while travelling",
    Tooltip = "Drops below the map, travels flat, surfaces. Avoids ploughing through the\n" ..
              "shopfront and other players.",
    Default = Config.BarTunnel,
    Callback = function(v) Config.BarTunnel = v end,
})

dependsOn(TravelBox:AddDependencyBox(), { Library.Toggles.BarTunnel, true }):AddSlider("BarTunnelDepth", {
    Text = "Tunnel depth", Default = Config.BarTunnelDepth, Min = 0, Max = 120, Rounding = 0, Suffix = " studs",
    Callback = function(v) Config.BarTunnelDepth = v end,
})

TravelBox:AddSlider("BarTweenSpeed", {
    Text = "Travel speed", Default = Config.BarTweenSpeed, Min = 10, Max = 200, Rounding = 0, Suffix = " st/s",
    Callback = function(v) Config.BarTweenSpeed = v end,
})

---------------------------------------------------------------- Market tab
local RotBox = Tabs.Market:AddLeftGroupbox("Rotations (UTC)", "clock")
L.Rot = RotBox:AddLabel("-", true)

local SnipeBox = Tabs.Market:AddRightGroupbox("Limited shop", "crosshair")

SnipeBox:AddToggle("LimitedSnipe", {
    Text = "Auto snipe",
    Tooltip = "Purchase is a 7-stud server prompt and distance is enforced server-side, so\n" ..
              "this travels to the shop and fires on the rotation flip. Uses Sell > Travel.\n" ..
              "Limiteds are Unsellable: index value, not cash. Counts against the spend cap.",
    Default = Config.LimitedSnipe,
    Callback = function(v)
        Config.LimitedSnipe = v
        if v then Features.Market.SnipeStart() else Features.Market.SnipeStop() end
    end,
})

SnipeBox:AddDropdown("WatchTarget", {
    Text = "Target",
    Values = (function()
        local v = { "" }
        for _, n in ipairs(CONST.LimitedShop) do v[#v + 1] = n end
        return v
    end)(),
    Default = 1,
    Tooltip = "Blank = buy whatever is on sale now, once, then disarm.\n" ..
              "A named target is bought every time it rotates in.",
    Callback = function(v) Config.WatchTarget = v end,
})

SnipeBox:AddSlider("SnipeLead", {
    Text = "Travel ahead of the hour",
    Default = Config.SnipeLead, Min = 5, Max = 300, Rounding = 0, Suffix = "s",
    Callback = function(v) Config.SnipeLead = v end,
})

SnipeBox:AddButton({ Text = "Buy limited now", Func = function()
    notify(Features.Market.SnipeNow() and "Limited prompt fired" or "No limited box found")
end })

local DropBox = Tabs.Market:AddRightGroupbox("SHOES drops", "smartphone")

DropBox:AddToggle("AutoDrops", {
    Text = "Auto buy drops",
    Tooltip = "Buys released drops that are profitable at the live sell rate.",
    Default = Config.AutoDrops,
    Callback = function(v)
        Config.AutoDrops = v
        if v then Features.Drops.Start() else Features.Drops.Stop() end
    end,
})

DropBox:AddSlider("DropMaxPrice", {
    Text = "Max drop price", Default = Config.DropMaxPrice, Min = 0, Max = 10000000, Rounding = 0, Suffix = "$",
    Tooltip = "0 = any price that is still profitable.",
    Callback = function(v) Config.DropMaxPrice = v end,
})

L.Drops = DropBox:AddLabel("-", true)

---------------------------------------------------------------- Craft tab
-- Boxes -> unsellable stock -> trade-ups: one pipeline, one tab.
local BoxBox = Tabs.Craft:AddLeftGroupbox("Mystery boxes", "package")

BoxBox:AddToggle("BoxAutoOpen", {
    Text = "Game auto-open",
    Tooltip = "Drives the game's own MysteryBoxAutoOpen switch rather than rebuilding it.\n" ..
              "Box sneakers are Unsellable: they are trade-up fodder and index, not cash.",
    Default = Config.BoxAutoOpen,
    Callback = function(v)
        Config.BoxAutoOpen = v
        local ok, why = Features.Boxes.SetAutoOpen(v)
        if not ok then notify("Box auto-open: " .. tostring(why)) end
    end,
})

L.Boxes = BoxBox:AddLabel("-", true)

local TradeBox = Tabs.Craft:AddLeftGroupbox("Trade up", "repeat")

TradeBox:AddToggle("AutoTrade", {
    Text = "Auto trade up",
    Default = Config.AutoTrade,
    Callback = function(v)
        Config.AutoTrade = v
        if v then Features.Trade.Start() else Features.Trade.Stop() end
    end,
})

TradeBox:AddDropdown("TradeRecipe", {
    Text = "Recipe",
    Values = (function()
        local keys = {}
        for k in pairs(CONST.TradeUps) do keys[#keys + 1] = k end
        table.sort(keys)
        return keys
    end)(),
    Default = Config.TradeRecipe,
    Callback = function(v) Config.TradeRecipe = v end,
})

TradeBox:AddToggle("TradeKeepOne", {
    Text = "Keep one of each line",
    Tooltip = "Feeds duplicates only, so a trade-up never eats your last copy of an index entry.",
    Default = Config.TradeKeepOne,
    Callback = function(v) Config.TradeKeepOne = v end,
})

TradeBox:AddButton({ Text = "Run once", Func = function() Features.Trade.Run() end })

local PlanBox = Tabs.Craft:AddRightGroupbox("Plan", "clipboard-list")
L.Plan = PlanBox:AddLabel("-", true)

local UnsellBox = Tabs.Craft:AddRightGroupbox("Unsellable stock", "archive")
L.Unsell = UnsellBox:AddLabel("-", true)

---------------------------------------------------------------- System tab
local ClaimBox = Tabs.System:AddLeftGroupbox("Store plot", "map-pin")

ClaimBox:AddToggle("AutoClaim", {
    Text = "Auto claim a plot",
    Tooltip = "Walks onto a free pad, waits for the store chooser, and presses Choose on the\n" ..
              "first unlocked tier. Without a plot there is no PC and every loop parks.\n" ..
              "Never saved: moves the character.",
    Default = Config.AutoClaim,
    Callback = function(v)
        Config.AutoClaim = v
        if v then Features.Claim.Start() else Features.Claim.Stop() end
    end,
})

ClaimBox:AddToggle("ClaimHop", {
    Text = "Rejoin when every pad is taken",
    Tooltip = "Off by default: a rejoin looks exactly like a crash to whoever is watching the\n" ..
              "window. Needs queue_on_teleport, or the hop leaves a client with no panel.",
    Default = Config.ClaimHop,
    Callback = function(v) Config.ClaimHop = v end,
})

dependsOn(ClaimBox:AddDependencyBox(), { Library.Toggles.ClaimHop, true }):AddSlider("MaxHops", {
    Text = "Hop limit",
    Default = Config.MaxHops, Min = 1, Max = 50, Rounding = 0,
    Callback = function(v) Config.MaxHops = v end,
})

ClaimBox:AddButton({ Text = "Claim now", Func = function()
    local ok, why = Features.Claim.Try()
    notify(ok and ("Plot claimed: " .. tostring(why)) or ("Claim failed: " .. tostring(why)))
end })

ClaimBox:AddButton({ Text = "Show pads", Func = function()
    local free, taken, held = Features.Claim.FreePads()
    local names = {}
    for _, p in ipairs(free) do names[#names + 1] = p.Name end
    notify(("%d free (%s), %d taken"):format(#free, table.concat(names, " "), taken))
    for pad, owner in pairs(held) do log("  %s -> %s", pad, owner) end
end })

local PerfBox = Tabs.System:AddLeftGroupbox("Performance", "zap")

PerfBox:AddToggle("PerfMode", {
    Text = "Perf mode (F5)",
    Tooltip = "Stops drawing the scene while the game keeps simulating and the remotes keep\n" ..
              "firing. Built for running many clients at once.",
    Default = Config.PerfMode,
    Callback = function(v)
        Config.PerfMode = v
        if Perf then Perf.Apply(v) end
    end,
})

PerfBox:AddSlider("PerfFps", {
    Text = "FPS cap (perf mode)",
    Default = Config.PerfFps, Min = 5, Max = 240, Rounding = 0,
    Tooltip = "Measured: 30 matches 240 for throughput, and below ~30 the bar minigame can\n" ..
              "no longer land on Perfect - Heartbeat samples too coarsely to catch the sweep.",
    Callback = function(v)
        Config.PerfFps = v
        if Perf and Perf.on then pcall(function() setfpscap(v) end) end
    end,
})

PerfBox:AddSlider("PollEvery", {
    Text = "UI refresh",
    Default = Config.PollEvery, Min = 0.2, Max = 5, Rounding = 1, Suffix = "s",
    Callback = function(v) Config.PollEvery = v end,
})

PerfBox:AddButton({ Text = "Repair refresh button", Func = function()
    local fixed = Features.Buy.Repair()
    notify(fixed and "Refresh button unlocked" or "Refresh button was not locked")
end })

local LogBox = Tabs.System:AddRightGroupbox("Log", "scroll-text")
local LogLabel = LogBox:AddLabel("", true)
LogLabel:SetText("panel starting...")
Panel.OnLog = function()
    local tail = {}
    for i = math.max(1, #Panel.Log - 15), #Panel.Log do tail[#tail + 1] = Panel.Log[i] end
    pcall(function() LogLabel:SetText(table.concat(tail, "\n")) end)
end
LogBox:AddButton({ Text = "Clear log", Func = function()
    Panel.Log = {}
    LogLabel:SetText("")
end })

---------------------------------------------------------------- live labels
-- One pass, pcall'd as a unit. Split out of the loop so a single nil during a respawn
-- cannot kill the thread and freeze every read-only label until the panel is re-run.
local function repaintLabels()
    local mpm, window = Econ.PerMinute()
    local nw, held = Econ.NetWorth()

    L.Phase:SetText(("Phase: %s   (%d slots)"):format(Panel.Phase, slotsNow()))
    L.Rate:SetText(("$/min: %s%s"):format(commas(mpm), window < 15 and "  (warming up)" or ""))
    L.Worth:SetText(("Net worth: $%s   (stock $%s)"):format(commas(nw), commas(held)))
    L.Money:SetText(("Cash: $%s"):format(commas(money())))
    L.Rates:SetText(("Sell rates: cashier %.2fx (%d) | bar %.2fx (%d) | %d discarded")
        :format(Econ.Rate.Cashier, Econ.Samples.Cashier, Econ.Rate.Bar, Econ.Samples.Bar,
                Panel.DirtySamples or 0))
    -- Both floors, because the panel is genuinely using two: a unit's drain decides which.
    -- Mirrors Econ.MinROIFor for a bar-grade unit, including the manual floor.
    local be = 1 / math.max(Econ.Rate.Bar, 0.01)
    local beBar = Config.AutoROI and be * (1 + math.max(Config.MarginPct, 1) / 100)
                  or math.max(Config.MinROI, be * 1.01)
    L.Floor:SetText(("ROI floor: %.2fx cashier | %.2fx bar%s"):format(
        Econ.MinROIFor(""), beBar, Econ.BarLive() and "  (bar live)" or "  (bar idle)"))
    L.Cap:SetText(("Unit cap: $%s"):format(commas(Econ.MaxUnit())))
    L.Aim:SetText(("Bar aim: %s, lead %.2f%s"):format(Config.BarTarget, Config.BarLead or 1,
        Panel.BarLeadMeasured and (" (measured %.2f)"):format(Panel.BarLeadMeasured) or ""))
    L.Session:SetText(("Session: %d bought / %d dumps / %d bar sales (%d%% on target)  spent $%s")
        :format(Panel.Bought, Panel.Sold, Panel.BarSales,
                Panel.BarSales > 0 and math.floor(Panel.BarAimed / Panel.BarSales * 100) or 0,
                commas(Panel.Spent)))

    local loops = {}
    for _, name in ipairs({ "Director", "AutoClaim", "AutoBuy", "AutoUpgrade", "AutoSell", "AutoBar",
                            "AutoTrade", "AutoDrops", "LimitedSnipe" }) do
        local live = Panel.Running[name]
        local last = Panel.Beat[name]
        loops[#loops + 1] = ("%-13s %s%s"):format(name, live and "RUN" or "off",
            (live and last) and (" %.0fs"):format(os.clock() - last) or "")
    end
    L.Loops:SetText(table.concat(loops, "\n"))

    -- live offer page
    local rows, offers = {}, Features.Buy.ReadOffers()
    for _, o in ipairs(offers) do
        rows[#rows + 1] = ("%s $%s  %.2fx  %s%s"):format(
            o.Data.Rarity:sub(1, 4), commas(o.Price), o.ROI,
            o.Profit > 0 and ("+$" .. commas(o.Profit)) or "-",
            Features.Buy.Wants(o) and "  <" or "")
    end
    L.Offers:SetText(#rows > 0 and table.concat(rows, "\n") or "no offers readable")

    local sOk, sWhy = storeReady()
    local nextCost = nextSlotCost()
    L.Store:SetText(("%s\nslots %d/%d   next $%s   to target $%s\nrefresh %d ok / %d refused")
        :format(sOk and "store ready" or ("waiting: " .. tostring(sWhy)),
                slotsNow(), CONST.MaxSlots, nextCost and commas(nextCost) or "-",
                commas(Features.Slots.CostToTarget()), Panel.RefreshOK, Panel.RefreshMiss))

    -- inventory
    local lines, total, units = stockLines()
    local barGrade = 0
    for _, l in ipairs(lines) do
        if l.Value >= Config.BarMinValue then barGrade = barGrade + l.Count end
    end
    local top = {}
    for i = 1, math.min(6, #lines) do
        top[#top + 1] = ("%dx %s ($%s)"):format(lines[i].Count, lines[i].Name, commas(lines[i].Value))
    end
    L.Stock:SetText(("%d units, list value $%s\nbar-grade %d (>= $%s), cashier %d\n%s")
        :format(units, commas(total), barGrade, commas(Config.BarMinValue),
                units - barGrade, table.concat(top, "\n")))

    -- rotations
    local rot = {}
    for _, r in ipairs(Features.Market.Schedule(6)) do
        rot[#rot + 1] = ("+%dh %02d:00  %s  $%s"):format(r.InHours, r.Hour,
            tostring(r.Limited), commas(r.LimitedPrice or 0))
    end
    rot[#rot + 1] = ("rotation flips in %ds"):format(Features.Market.SecondsToHour())
    L.Rot:SetText(table.concat(rot, "\n"))

    local boxes = {}
    for _, b in ipairs(Features.Boxes.NextBoxes(8)) do
        boxes[#boxes + 1] = ("+%dh %02d:00  %s  $%s"):format(b.In, b.Hour, tostring(b.Box), commas(b.Price or 0))
    end
    L.Boxes:SetText(table.concat(boxes, "\n"))

    -- craft
    local plan = Features.Trade.Plan()
    local prows = {}
    for i = 1, math.min(6, #plan) do
        local p = plan[i]
        prows[#prows + 1] = ("%s  x%d  (%s -> %s, %d spare)"):format(p.Key, p.Runs, p.From, p.To, p.Left)
    end
    L.Plan:SetText(#prows > 0 and table.concat(prows, "\n") or "nothing craftable yet")

    local counts = Features.Trade.Stock()
    local crows = {}
    for _, r in ipairs(CONST.Rarities) do
        if counts[r] then crows[#crows + 1] = ("%s: %d"):format(r, counts[r]) end
    end
    L.Unsell:SetText(#crows > 0 and table.concat(crows, "\n") or "UnsellableInventory is empty")

    -- The Director and tuner write these straight into Config. Pull the sliders along so
    -- the UI (and a config saved from it) never shows a number the panel is not using.
    for _, k in ipairs({ "MarginPct", "MaxUnitPct", "SellAtUnits", "MinUnitValue",
                         "TargetSlots", "BarMinValue", "BarLead" }) do
        local op = Library.Options[k]
        if op and type(Config[k]) == "number" and math.abs((op.Value or 0) - Config[k]) >= 0.01 then
            op:SetValue(Config[k])
        end
    end
end

task.spawn(function()
    while Panel.Alive ~= false do
        pcall(function()
            local drops = Features.Drops.List()
            local rows = {}
            for i = 1, math.min(5, #drops) do
                local d = drops[i]
                rows[#rows + 1] = ("%s $%s  %s  %s"):format(d.Name, commas(d.Price or 0),
                    tostring(d.Stock), d.In > 0 and ("in %dh%02dm"):format(math.floor(d.In / 3600), math.floor(d.In % 3600 / 60)) or "LIVE")
            end
            L.Drops:SetText(#rows > 0 and table.concat(rows, "\n") or "no drops listed")
        end)
        task.wait(30)                     -- the drops remote is a round trip, so poll it slowly
    end
end)

task.spawn(function()
    while Panel.Alive ~= false do
        pcall(repaintLabels)
        task.wait(Config.PollEvery)
    end
end)

--=========================================================================
-- [7] HARDENING
--=========================================================================

-- PERF MODE. Nothing here touches gameplay: the farm is remote-driven, so this only strips
-- what the GPU and CPU spend on SHOWING you the game. Everything is captured before it is
-- changed and restored on the way out.
Perf = { on = false, saved = nil }

local function syncPerfToggle()
    local tg = Library.Toggles and Library.Toggles.PerfMode
    if tg and tg.Value ~= Perf.on then pcall(function() tg:SetValue(Perf.on) end) end
end

function Perf.Apply(on)
    if on == Perf.on then return end
    if on then
        local saved = { particles = {}, effects = {} }
        pcall(function() saved.fps = getfpscap and getfpscap() or nil end)
        pcall(function() saved.shadows = Lighting.GlobalShadows end)
        pcall(function() saved.quality = settings().Rendering.QualityLevel end)
        for _, d in ipairs(Lighting:GetDescendants()) do
            if d:IsA("PostEffect") and d.Enabled then
                saved.effects[#saved.effects + 1] = d
                d.Enabled = false
            end
        end
        for _, d in ipairs(workspace:GetDescendants()) do
            if (d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke") or d:IsA("Fire")) and d.Enabled then
                saved.particles[#saved.particles + 1] = d
                d.Enabled = false
            end
        end
        pcall(function() Lighting.GlobalShadows = false end)
        pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
        pcall(function() if setfpscap then setfpscap(Config.PerfFps) end end)
        pcall(function() RunService:Set3dRenderingEnabled(false) end)
        Perf.saved, Perf.on = saved, true
        notify(("Perf mode ON - 3D off, %d fps, %d particles + %d effects disabled")
            :format(Config.PerfFps, #saved.particles, #saved.effects))
    else
        local saved = Perf.saved or {}
        pcall(function() RunService:Set3dRenderingEnabled(true) end)
        pcall(function() if setfpscap then setfpscap(saved.fps and saved.fps > 0 and saved.fps or 60) end end)
        pcall(function() if saved.shadows ~= nil then Lighting.GlobalShadows = saved.shadows end end)
        pcall(function() if saved.quality then settings().Rendering.QualityLevel = saved.quality end end)
        for _, d in ipairs(saved.effects or {}) do pcall(function() d.Enabled = true end) end
        for _, d in ipairs(saved.particles or {}) do pcall(function() d.Enabled = true end) end
        Perf.saved, Perf.on = nil, false
        notify("Perf mode OFF - rendering restored")
    end
    syncPerfToggle()
end

-- WATCHDOG. The layers above stop the failures we know about; this catches the ones we do
-- not. A stall threshold must sit above each loop's slowest LEGITIMATE pass or the watchdog
-- becomes the bug - AutoBar is the loose one, since a sale plus a round trip takes a while.
local WATCHED = {
    Director     = { stall = 45,  start = function() Features.Director.Start(true) end, stop = Features.Director.Stop },
    AutoClaim    = { stall = 60,  start = Features.Claim.Start,      stop = Features.Claim.Stop },
    AutoBuy      = { stall = 25,  start = Features.Buy.Start,        stop = Features.Buy.Stop },
    AutoUpgrade  = { stall = 30,  start = Features.Slots.Start,      stop = Features.Slots.Stop },
    AutoSell     = { stall = 30,  start = Features.Sell.Start,       stop = Features.Sell.Stop },
    AutoBar      = { stall = 90,  start = Features.Bar.Start,        stop = Features.Bar.Stop },
    AutoTrade    = { stall = 40,  start = Features.Trade.Start,      stop = Features.Trade.Stop },
    AutoDrops    = { stall = 60,  start = Features.Drops.Start,      stop = Features.Drops.Stop },
    LimitedSnipe = { stall = 60,  start = Features.Market.SnipeStart, stop = Features.Market.SnipeStop },
}

local function restartBudgetExceeded(name)
    local now, recent = os.clock(), {}
    for _, t in ipairs(Panel.Restarts[name] or {}) do
        if now - t < 90 then recent[#recent + 1] = t end
    end
    recent[#recent + 1] = now
    Panel.Restarts[name] = recent
    return #recent > 3
end

task.spawn(function()
    while Panel.Alive ~= false do
        task.wait(5)
        for name, cfg in pairs(WATCHED) do
            if Panel.Running[name] then
                local last = Panel.Beat[name]
                if last == nil then
                    Panel.Beat[name] = os.clock()          -- one grace period, not an instant restart
                elseif not storeReady() then
                    Panel.Beat[name] = os.clock()          -- parked waiting for a plot, not wedged
                elseif os.clock() - last > cfg.stall then
                    local silent = os.clock() - last
                    if restartBudgetExceeded(name) then
                        notify(("%s keeps stalling - stopped. Check the log."):format(name))
                        Panel.Running[name] = nil
                        local tg = Library.Toggles and Library.Toggles[name]
                        if tg then pcall(function() tg:SetValue(false) end) end
                    else
                        log("watchdog: %s silent for %.0fs, restarting", name, silent)
                        Panel.Running[name] = nil
                        pcall(cfg.stop)
                        task.wait(0.25)
                        Panel.Beat[name] = os.clock()
                        pcall(cfg.start)
                    end
                end
            else
                Panel.Beat[name] = nil
                Panel.Restarts[name] = nil
            end
        end
    end
end)

LP.CharacterAdded:Connect(function()
    log("respawned - UI references re-resolving")
end)

local killConn = UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Config.KillKey then stopAll("hotkey") end
    if input.KeyCode == Config.PerfKey then Perf.Apply(not Perf.on) end
end)

function Panel.Unload()
    Panel.Alive = false
    for name in pairs(Panel.Running) do Panel.Running[name] = nil end
    pcall(function() Perf.Apply(false) end)
    pcall(function() killConn:Disconnect() end)
    pcall(function() Library:Unload() end)
    getgenv().__SNEAKER_PANEL_V2 = nil
end

Library:OnUnload(function()
    Panel.Alive = false
    for name in pairs(Panel.Running) do Panel.Running[name] = nil end
    pcall(function() Perf.Apply(false) end)
    pcall(function() killConn:Disconnect() end)
    getgenv().__SNEAKER_PANEL_V2 = nil
end)

Panel.Alive      = true
Panel.StartMoney = money()
Panel.Config     = Config
Panel.Features   = Features
Panel.Econ       = Econ
Panel.Perf       = Perf
Panel.Presets    = PRESETS
Panel.Watched    = WATCHED
Panel.StoreReady = storeReady     -- diagnostics keep reaching for this
Panel.PathsReady = pathsReady
Panel.Toggles    = Library.Toggles
Panel.Options    = Library.Options
getgenv().__SNEAKER_PANEL_V2 = Panel

---------------------------------------------------------------- persistence
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
-- Never persist or restore the switches that spend money or move the character. A saved
-- config loads AFTER the defaults and silently wins: the live clients had one that restored
-- BarApproach=true, so every cold boot resumed walking to NPCs.
-- LimitedSnipe and AutoDrops join them: a snipe travels and spends up to $10M, a drop
-- spends without a trip, and neither should resume on a boot nobody is watching.
SaveManager:SetIgnoreIndexes({ "MenuKeybind", "AutoUpgrade", "SlotsManualOnly",
                              "AutoBar", "BarApproach", "AutoClaim", "ClaimHop",
                              "LimitedSnipe", "AutoDrops" })
ThemeManager:SetFolder("SneakerPanelV2")
SaveManager:SetFolder("SneakerPanelV2/configs")
SaveManager:BuildConfigSection(Tabs.Config)
ThemeManager:SetDefaultTheme({ BackgroundColor = "0c0a0b", MainColor = "161214", AccentColor = "e0233c", OutlineColor = "2a1d20", FontColor = "f2eded" }) -- CruelHub look
ThemeManager:ApplyToTab(Tabs.Config)
-- SAFEBOOT means nothing starts - including loops a saved config would switch back on.
if getgenv().SNEAKER_PANEL_SAFEBOOT then
    log("SAFEBOOT: autoload config skipped (load it from Settings when ready)")
else
    SaveManager:LoadAutoloadConfig()
end

---------------------------------------------------------------- boot
do
    if Features.Buy.Repair() then log("repaired the game's refresh button (was left locked)") end
    pcall(function() Features.Boxes.SetAutoOpen(Config.BoxAutoOpen) end)
    if Config.AutoClaim then Features.Claim.Start() end   -- off by default; opt in from the UI
    -- getgenv().SNEAKER_PANEL_SAFEBOOT = true loads the UI without starting anything, so a
    -- new build can be inspected before it is allowed to spend money.
    if Config.Director and not getgenv().SNEAKER_PANEL_SAFEBOOT then
        Features.Director.Start()
    elseif Config.Director then
        Config.Director = false
        local tg = Library.Toggles.Director
        if tg then pcall(function() tg.Value = false; tg:Display() end) end
        log("SAFEBOOT: Director not started - flip it on in the UI when ready")
    end
end

Library:Notify("Sneaker Panel v2 loaded - F4 kills all automation, F5 perf mode", 6)
log("panel v2 loaded | cashier %.2fx, bar %.2fx seeded", Econ.Rate.Cashier, Econ.Rate.Bar)
