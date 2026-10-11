-- CruelHub · Junk Crushers 2
--[[
    [AUTO CLICK] Junk Crushers 2 (PlaceId 73968232750026) - auto farm hub
    UI: Obsidian (deividcomsono), CruelHub look

    THE LOOP (read from the client; notes.md / spec.md have the citations):
      junk rains on your plot -> click it (JunkPickupRequest) -> dumpster -> "Loot Dumpster" prompt ->
      "Crush Junk" prompt -> junk blocks roll out -> pick up (JunkPickupRequest, 12 studs) or "Pick Up All" ->
      stand on the factory's Unload Pad -> upgraders multiply each block -> the Sell pad pays coins (server side).

    Recreated passes (the outcome, not ownership: every pass effect is applied by the server):
      AutoLoader       -> Auto Unload walks your blocks to the Unload Pad
      Infinite Storage -> loots the dumpster the moment it fills, plus auto dumpster upgrades
      Fast Rain        -> maxes the free Rain Speed card (+300% vs the pass's +50%)
      Auto Clicker     -> Auto Pickup at ~2.5 clicks/s stacks with the game's own clicker

    Never fired: remotes no client script calls (honeypot candidates), the admin panel's remotes and every
    Robux path. Crate and offline-earnings remotes are argument-locked to their gem / free forms.
]]

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local GuiService  = game:GetService("GuiService")
local PathfindingService = game:GetService("PathfindingService")
local LP          = Players.LocalPlayer

local PLACE_ID, SPEC_VERSION = 73968232750026, 1616
local SELF_URL = "https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/junk-crushers-2/jc2_main.lua"
local DIR      = "CruelHub/JunkCrushers2"
local LOG_FILE = DIR .. "/log.txt"

if game.PlaceId ~= PLACE_ID then
    warn("[CruelHub] jc2_main.lua is the Junk Crushers 2 script; this place (" .. game.PlaceId .. ") isn't it")
    return
end
if not game:IsLoaded() then game.Loaded:Wait() end

-- newest copy wins: autoexec + a teleport requeue can both start one; an older copy sees the token change and unloads
local TOKEN = {}
getgenv().CruelHubJC2_TOKEN = TOKEN
if getgenv().CruelHubJC2 then pcall(getgenv().CruelHubJC2.unload) end
for _, d in { "CruelHub", DIR } do if not isfolder(d) then pcall(makefolder, d) end end

local CFG = {
    -- Farm
    farm = false, pickup = true, loot = true, crush = true, blocks = true, unload = true,
    reach = 44, crushMin = 10, lootIdle = 8, fastMove = false,
    smeltClaim = true, smeltInput = false,
    -- Upgrades
    upgrades = false, coinKeys = { Rain = true, Speed = true, AutoClicker = true, DroneSpeed = true, Slots = true },
    coinOrder = "Cheapest first", reserve = 0, crusher = true, dumpster = true,
    factoryBuy = true, autoBuild = true, upgraderTut = true, roll = true,
    -- Rebirth
    rebirthMode = "Off", rebirthMinTokens = 2, rebirthMax = 0,
    shop = false, shopSave = true,
    shopItems = { ["Junk Magnet"] = true, ["Mutations (Gold / Diamond / Atomic)"] = true, ["Refabricator (2.5x)"] = true,
        ["Rebirth Amplifier (3x)"] = true, ["Ion Accelerator (1.5x)"] = true, ["PowerCore Boosters (2.5x)"] = true,
        ["Drone Crate Luck"] = true },
    -- Drones
    equipBest = false, crateKind = "Normal (100 gems)", crateBatch = 3, crateFloor = 0, crateStop = "Exotic",
    rareNotify = true, serverRare = false,
    -- Rewards
    claims = false, cWelcome = true, cDaily = true, cOffline = true, cHourly = true, cDailyQuest = true, cMain = true,
    cIndex = true, cMilestone = true, cChest = true,
    -- Events
    bossMode = "Game default", diamond = false, gemUpgrades = false, gemFloor = 0,
    megaCrates = false, meteorCrates = false, worldChallenge = false, eventNotify = true,
    -- Settings
    antiAfk = true, rejoin = true, gap = 0.35,
}

local S = {
    alive = true, conns = {}, log = {}, logDirty = false, cfg = CFG,
    status = "off", farmBusy = false, eventBusy = false, idleSince = os.clock(),
    seq = 1000000, skip = {}, backoff = {}, t0 = os.clock(), gate = 0,
    lastCoins = nil, income = 0, incomeWin = {}, earned = 0, sales = 0,
    counts = { picks = 0, loots = 0, crushes = 0, blocks = 0, unloads = 0, buys = 0, rebirths = 0, claims = 0,
        drones = 0, bossKills = 0, diamonds = 0, drops = 0 },
    lastRebirth = os.clock(), rebirthLock = 0, equipDirty = true, equipAt = 0, coinRes = {},
    dropLogged = {}, unload = function() end,
}
getgenv().CruelHubJC2 = S

local notify = function() end -- Library:Notify once the UI exists

local function log(msg)
    S.log[#S.log + 1] = os.date("%H:%M:%S ") .. tostring(msg)
    if #S.log > 300 then table.remove(S.log, 1) end
    S.logDirty = true
end

local function on(signal, fn)
    local c = signal:Connect(function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log("handler error: " .. tostring(err)) end
    end)
    S.conns[#S.conns + 1] = c
    return c
end

-- ============================== remotes (guarded) ==============================
-- Remotes the hub never fires. First block: no client script calls them (honeypot candidates).
-- Then the admin panel (shown to one UserId only), then Robux and trades.
local FORBIDDEN = {}
for _, n in { "PrivatePlaytimeQuery", "PrivatePlaytimeDevice", "AdminPlayerStats", "JunkRainUpgradeRequest",
    "JunkRainUpgradeResult", "ClaimGroupReward", "SetBigJunkScale",
    "AdminActivateEvent", "AdminSetGlobalBoost", "AdminToggleFlight", "SendAdminAnnouncement",
    "SkipRebirthPurchase", "GemPackPurchase", "MegaRainPurchase", "StarterPackPurchaseRequest", "GamepassGifting",
    "LimitedDronePurchase", "DroneTradeInvite", "DroneTradeSession" } do FORBIDDEN[n] = true end

-- These remotes also have Robux or destructive forms: only the listed argument shapes go out
local ARGLOCK = {
    NormalDroneCratePurchase  = function(a) return a[1] == "Gems" end,
    PremiumDroneCratePurchase = function(a) return a[1] == 1 and a[2] == "Gems" end,
    OfflineEarningsAction     = function(a) return a[1] == "Claim" end,
    DroneEquipRequest         = function(a) return a[2] == "EquipBest" end,
    FactoryAction             = function(a) return a[1] == "Buy" or a[1] == "AutoBuild" end,
    SetAutoLoaderEnabled      = function() return LP:GetAttribute("AutoLoader") == true end,
}

-- One shared clock for every remote and prompt: CFG.gap apart plus jitter, never a burst
local function pace()
    local slot = math.max(os.clock(), S.gate)
    S.gate = slot + CFG.gap + math.random() * 0.12
    local w = slot - os.clock()
    if w > 0 then task.wait(w) end
end

-- call(name, ...) -> true, <server returns...> | false
local function call(name, ...)
    if FORBIDDEN[name] then log("BLOCKED " .. name) return false end
    local args = table.pack(...)
    local lock = ARGLOCK[name]
    if lock and not lock(args) then log("BLOCKED " .. name .. " (argument lock)") return false end
    local r = RS:FindFirstChild(name)
    if not r then log("missing remote " .. name) return false end
    pace()
    if not S.alive then return false end
    if r:IsA("BaseRemoteEvent") then
        local ok, err = pcall(r.FireServer, r, table.unpack(args, 1, args.n))
        if not ok then log(name .. ": " .. tostring(err)) end
        return ok
    end
    -- a RemoteFunction can hang forever: stop waiting for the answer after 10 s (the request still went out)
    local res, done = nil, false
    task.spawn(function()
        res = table.pack(pcall(r.InvokeServer, r, table.unpack(args, 1, args.n)))
        done = true
    end)
    local t = os.clock()
    while not done and os.clock() - t < 10 do task.wait(0.05) end
    if not done then log(name .. ": no answer in 10 s") return false end
    if not res[1] then log(name .. ": " .. tostring(res[2])) return false end
    return true, table.unpack(res, 2, res.n)
end

-- ============================== state helpers ==============================
local function A(k) return LP:GetAttribute(k) end
local function num(k) return tonumber(LP:GetAttribute(k)) or 0 end
local function now() return workspace:GetServerTimeNow() end

local function json(k)
    local s = LP:GetAttribute(k)
    if type(s) ~= "string" or s == "" then return {} end
    local ok, t = pcall(HttpService.JSONDecode, HttpService, s)
    return ok and type(t) == "table" and t or {}
end

local function plot()
    local m = workspace:FindFirstChild("Map")
    local ps = m and m:FindFirstChild("Plots")
    local p = ps and ps:FindFirstChild(A("PlotName") or "")
    if p and p:GetAttribute("OwnerUserId") == LP.UserId then return p end
end

local function hrp() local c = LP.Character return c and c:FindFirstChild("HumanoidRootPart") end
local function humanoid()
    local c = LP.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    return h and h.Health > 0 and h or nil
end

local function valueOf(folder, child)
    local f = LP:FindFirstChild(folder)
    local v = f and f:FindFirstChild(child)
    return v and tonumber(v.Value) or 0
end
local function coins()   return valueOf("PlayerBalances", "Coins") end
local function looted()  return valueOf("InventoryFolder", "Junk") end   -- looted, not crushed yet
local function carried() return valueOf("Inventory", "JunkBlocks") end   -- blocks in hand
local function gems()    return num("Diamonds") end                     -- the game calls the Diamonds attr "gems"
local function tokens()  return num("RebirthCoins") end

local function ready()
    return A("CoinDataReady") == true and A("DataLoadState") == "Ready" and not A("RebirthPending") and not A("DroneSavePending")
end

local SUFFIX = { "", "K", "M", "B", "T", "QD", "QN", "SX", "SP", "OC", "NO", "DC" }
local function compact(n)
    n = tonumber(n) or 0
    local neg, i = n < 0, 1
    n = math.abs(n)
    while n >= 1000 and i < #SUFFIX do n /= 1000; i += 1 end
    local s = i == 1 and tostring(math.floor(n)) or (n >= 100 and ("%.0f") or n >= 10 and ("%.1f") or ("%.2f")):format(n) .. SUFFIX[i]
    return (neg and "-" or "") .. s
end

local function clock(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    if sec >= 3600 then return ("%dh %02dm"):format(sec // 3600, sec % 3600 // 60) end
    if sec >= 60 then return ("%dm %02ds"):format(sec // 60, sec % 60) end
    return sec .. "s"
end

local function posOf(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst.Position end
    if inst:IsA("Attachment") then return inst.WorldPosition end
    if inst:IsA("Model") then return inst:GetPivot().Position end
end

-- closest point of the instance's box to pos: the same measure the game's pickup range uses
local function boxDist(inst, pos)
    local cf, size
    if inst:IsA("Model") then cf, size = inst:GetBoundingBox()
    elseif inst:IsA("BasePart") then cf, size = inst.CFrame, inst.Size
    else return math.huge end
    local p = cf:PointToObjectSpace(pos)
    local c = Vector3.new(math.clamp(p.X, -size.X / 2, size.X / 2), math.clamp(p.Y, -size.Y / 2, size.Y / 2),
        math.clamp(p.Z, -size.Z / 2, size.Z / 2))
    return (p - c).Magnitude
end

local function dist(p)
    local h = hrp()
    return (h and p) and (h.Position - p).Magnitude or math.huge
end

local function flat(a, b) return Vector3.new(b.X - a.X, 0, b.Z - a.Z) end

-- Straight walk. Stops when it stops moving (a wall): one jump, then it gives up instead of grinding.
local function walkStraight(pos, radius, deadline)
    local anchor, anchorT = nil, os.clock()
    while S.alive and os.clock() < deadline do
        local h, hum = hrp(), humanoid()
        if not (h and hum) then return false end
        if flat(h.Position, pos).Magnitude <= radius then return true end
        hum:MoveTo(Vector3.new(pos.X, h.Position.Y, pos.Z))
        if not anchor or (h.Position - anchor).Magnitude > 1 then
            anchor, anchorT = h.Position, os.clock()
        elseif os.clock() - anchorT > 2 then
            return false
        elseif os.clock() - anchorT > 1 then
            hum.Jump = true
        end
        task.wait(0.15)
    end
    return false
end

-- Walk with the Humanoid like a player, around obstacles (PathfindingService), straight line as fallback.
-- Fast mode steps the root 8 studs at a time instead: small steps, because a single long CFrame jump is
-- what server movement checks look for.
local function moveTo(pos, radius, timeout)
    if not pos then return false end
    radius, timeout = radius or 3, timeout or 10
    local deadline = os.clock() + timeout
    local h, hum = hrp(), humanoid()
    if not (h and hum) then return false end
    if flat(h.Position, pos).Magnitude <= radius then return true end
    if CFG.fastMove then
        while S.alive and os.clock() < deadline do
            h = hrp()
            if not h then return false end
            local d = flat(h.Position, pos)
            if d.Magnitude <= radius then return true end
            h.CFrame += d.Magnitude > 8 and d.Unit * 8 or d
            task.wait(0.06)
        end
        return false
    end
    if flat(h.Position, pos).Magnitude > 10 then
        -- aim just short of the target: buttons and prompts sit inside solid parts, which fails a path
        local away = flat(pos, h.Position)
        local goal = pos + (away.Magnitude > 0 and away.Unit * math.max(radius - 1, 0) or Vector3.zero)
        local path = PathfindingService:CreatePath({ AgentRadius = 2.5, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 6 })
        local ok = pcall(path.ComputeAsync, path, h.Position, goal)
        if ok and (path.Status == Enum.PathStatus.Success or path.Status == Enum.PathStatus.ClosestNoPath) then
            for _, wp in path:GetWaypoints() do
                local hh = hrp()
                if not hh then return false end
                if flat(hh.Position, pos).Magnitude <= radius then return true end
                if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
                if not walkStraight(wp.Position, 2, math.min(deadline, os.clock() + 4)) then break end
            end
        end
    end
    return walkStraight(pos, radius, deadline)
end

local function firePrompt(prompt)
    pace()
    if fireproximityprompt and pcall(fireproximityprompt, prompt) then return true end
    return (pcall(function() -- what the game's own prompt UI does
        prompt:InputHoldBegin()
        task.wait(prompt.HoldDuration + 0.1)
        prompt:InputHoldEnd()
    end))
end

local function usePrompt(prompt, timeout)
    if not (prompt and prompt.Parent and prompt.Enabled) then return false end
    local p = posOf(prompt.Parent)
    if not p then return false end
    local reach = prompt.MaxActivationDistance
    if dist(p) > reach - 1.5 then moveTo(p, math.max(1.5, reach - 3), timeout or 10) end
    if dist(p) > reach then return false end
    return firePrompt(prompt)
end

local function pickup(inst)
    S.seq += 1 -- the game numbers its own pickups from 1; ours start at 1,000,001 so they never collide
    return call("JunkPickupRequest", inst, S.seq)
end

local function onBase(p)
    local b, h = p:FindFirstChild("Base"), hrp()
    if not (b and h and b:IsA("BasePart")) then return false end
    local rel = b.CFrame:PointToObjectSpace(h.Position)
    return math.abs(rel.X) <= b.Size.X / 2 and math.abs(rel.Z) <= b.Size.Z / 2
end

local function waitFarmIdle()
    local t = os.clock()
    while S.farmBusy and os.clock() - t < 20 do task.wait(0.1) end
end

-- ============================== game tables (copied, never require()d) ==============================
local JUNK_VALUE = {}
for i, id in { "CupTrash", "PlankTrash", "PipeTrash", "TableTrash", "TireTrash", "DumbellTrash", "BenchPressTrash",
    "TukTukTrash", "SmallBoatTrash", "ForkLiftTrash", "RoofTrash", "TentTrash", "ExcavatorTrash", "CamperTrash",
    "MiningTruckTrash", "LocomotiveTrash", "BulldozerTrash", "CargoHelicopterTrash", "GarbageTruckTrash", "CargoShip",
    "SkyScraperJunk", "AirplaneTrash", "RoadTrash", "CraneTrash", "NuclearReactorTrash", "SatelliteTrash",
    "FighterJetTrash", "SportsCarTrash", "RocketTrash", "AlienAircraftTrash", "AlienRoverTrash", "AlienStatueTrash",
    "AlienRailgunTrash", "AngelicHelmetTrash", "AngelicGateTrash", "AngelicSwordTrash", "AngelicStatueTrash",
    "AngelicPowerCoreTrash", "InfernalGuardianTrash", "ForgottenHaulerTrash" } do JUNK_VALUE[id] = i end
-- JunkIndexConfig order = value order (each tier is worth ~2x the last); unknown names are newer, higher tiers

local HOURLY = { { "Coins", 1000, "Collect 1K Junk" }, { "Diamond", 10, "Pick Up 10 Diamond Junk" },
    { "Playtime", 1800, "Play 30 Minutes" }, { "Blocks", 30, "Pick Up 30 Junk Blocks" } }
local DAILY = { { "Crates", 15, "Open 15 Drone Crates" }, { "Rebirth", 1, "Rebirth" }, { "Mega", 1, "Open a Mega Crate" },
    { "Rain", 20, "Buy 20 Junk Rain Upgrades" } }

local COIN_COST = {
    Speed = { 100, 1e3, 1e4, 1e5, 1e6, 2e7, 2e8, 2e9, 4e9, 8e9, 1.6e10, 3.2e10, 6.4e10, 1.28e11, 2.56e11, 3.08e11, 3.68e11,
        4.44e11, 5.32e11, 6.4e11, 9.6e12, 1.155e13, 1.385e13, 1.665e13, 2e13, 2.4e13, 2.885e13, 3.465e13, 4.165e13, 5e13 },
    DroneSpeed = { 5e3, 1.5e4, 4.5e4, 2e5, 1e6, 1e7, 5e7, 1e8, 1e9, 1e10, 2e11, 4e12, 8e13, 1.6e15, 3.2e16, 6.4e17, 1.28e19,
        2.56e20, 5.12e21, 1.024e23 },
    AutoClicker = { 5e3, 1.5e5, 2.25e6, 6.75e6, 2.025e7, 6.075e7, 1.8225e8, 5.4675e8, 1.64e9, 4.92e9, 1.476e10, 4.429e10,
        1.3286e11, 3.9858e11, 1.196e12, 3.587e12 },
}
local COIN_LEVEL = { Speed = "RainSpeedLevel", DroneSpeed = "DroneSpeedLevel", AutoClicker = "AutoClickerLevel" }
local COIN_KEYS = { "Rain", "Speed", "AutoClicker", "DroneSpeed", "Slots" }
local COIN_TEXT = { Rain = "Junk Rain (better junk)", Speed = "Rain Speed", AutoClicker = "Auto Clicker",
    DroneSpeed = "Drone Speed", Slots = "Drone Slots" }
local CRUSHER_COST = { 1e3, 1e4, 1e5, 1e6 }
local DUMPSTER_COST = { [2] = 30, [3] = 500, [4] = 4500, [5] = 2e4, [6] = 6e4, [7] = 1.8e5, [8] = 5.5e5, [9] = 1.5e6,
    [10] = 4.5e6, [11] = 1.3e7, [12] = 1.2e8, [13] = 1e9, [14] = 5e9, [15] = 1e11, [16] = 1e12, [17] = 1e13, [18] = 5e17 }
local UPGRADERS = { { "Polisher", 1e3 }, { "WoodenSmelter", 2.5e4 }, { "Laser", 1e5 }, { "Press", 2.5e6 },
    { "Furnace", 1e8 }, { "IndustrialSmoker", 5e9 }, { "DrumRefiner", 1e13 } }

local RANK = { Drone1 = 1, Drone2 = 2, CobaltScout = 2, Drone3 = 3, AmethystMantis = 3, Drone4 = 4, GildedGriffin = 4,
    Drone5 = 5, VoidDrone = 5, Afterburner = 5, Drone6 = 6, PrismLeviathan = 6, Reforge = 6, Drone7 = 7, Cinder = 7,
    Harbringer = 8, PlanetEater = 8 }
local RARITY = { "Common", "Rare", "Epic", "Legendary", "Mythical", "Exotic", "Akashic", "Secret" }
local DRONE_NAME = { Drone1 = "Bin Tracker", Drone2 = "Industrialist", Drone3 = "Heavy Duty", Drone4 = "Junk Hunter",
    Drone5 = "Colossus", Drone6 = "Reactor Overlord", Drone7 = "Halo", CobaltScout = "Cobalt Scout",
    AmethystMantis = "Amethyst Mantis", GildedGriffin = "Gilded Griffin", PrismLeviathan = "Prism Leviathan",
    VoidDrone = "Void Drone", PlanetEater = "Planet Eater" }
local STOP_RANK = { Never = 99, Legendary = 4, Mythical = 5, Exotic = 6, Akashic = 7, Secret = 8 }

local CRATES = {
    ["Normal (100 gems)"] = { cur = "gems", price = 100, path = { "DroneShop", "DroneCrate" },
        buy = function(n) return call("NormalDroneCratePurchase", "Gems", n) end },
    ["Infernal (300 gems)"] = { cur = "gems", price = 300, path = { "DroneShop", "InfernalDroneCrate" },
        buy = function(n) return call("NormalDroneCratePurchase", "Gems", n, "Infernal") end },
    ["Rebirth (10 tokens)"] = { cur = "tokens", price = 10, path = { "RebirthShop", "RebirthCrate", "RebirthDroneCrate" },
        buy = function(n) return call("RebirthDroneCratePurchase", n) end },
    ["Mega (10,000 gems)"] = { cur = "gems", price = 10000, single = true, path = { "MegaDroneCrate", "CrateBody" },
        buy = function() return call("PremiumDroneCratePurchase", 1, "Gems") end },
}
local CRATE_KINDS = { "Normal (100 gems)", "Infernal (300 gems)", "Rebirth (10 tokens)", "Mega (10,000 gems)" }

local function rebirthTokensFor(c)
    if c < 1e6 then return 0 end
    return math.min(100, 1 + math.floor(math.log(c / 1e6) / math.log(5) + 1e-9))
end

local function factoryOwned(data, id)
    local stock = type(data.Stock) == "table" and data.Stock or {}
    if (tonumber(stock[id]) or 0) > 0 then return true end
    if type(data.Layout) == "table" then
        for _, cell in data.Layout do
            if type(cell) == "table" and cell.Kind == id then return true end
        end
    end
    return false
end

local function mutationCost(id, unlock)
    if not A(id .. "Unlocked") then return unlock end
    local l = num(id .. "Level")
    return l < 10 and 2 ^ l or nil
end

-- rebirth shop in buy order; group = the toggle that covers it
local SHOP = {
    { group = "Mutations (Gold / Diamond / Atomic)", id = "Gold", label = "Gold unlock",
        cost = function() return not A("GoldUnlocked") and 1 or nil end },
    { group = "Junk Magnet", id = "JunkMagnet", label = "Junk Magnet",
        cost = function() local l = num("JunkMagnetLevel") return l < 3 and ({ 4, 8, 16 })[l + 1] or nil end },
    { group = "Refabricator (2.5x)", id = "PrismaticReactor", label = "Refabricator", factory = true, cost = 6 },
    { group = "Mutations (Gold / Diamond / Atomic)", id = "Diamond", label = "Diamond unlock",
        cost = function() return not A("DiamondUnlocked") and 3 or nil end },
    { group = "Mutations (Gold / Diamond / Atomic)", id = "Atomic", label = "Atomic unlock",
        cost = function() return not A("AtomicUnlocked") and 6 or nil end },
    { group = "Rebirth Amplifier (3x)", id = "RebirthAmplifier", label = "Rebirth Amplifier", factory = true, cost = 15 },
    { group = "Ion Accelerator (1.5x)", id = "IonAccelerator", label = "Ion Accelerator", factory = true, cost = 20 },
    { group = "PowerCore Boosters (2.5x)", id = "NewRebirthConveyor", label = "PowerCore Boosters", factory = true, cost = 30 },
    { group = "Drone Crate Luck", id = "DroneLuck", label = "Drone Crate Luck",
        cost = function() local l = num("DroneLuckLevel") return l < 4 and 2 ^ (l + 1) or nil end },
    { group = "Mutations (Gold / Diamond / Atomic)", id = "Atomic", label = "Atomic level",
        cost = function() return A("AtomicUnlocked") and mutationCost("Atomic", 6) or nil end },
    { group = "Mutations (Gold / Diamond / Atomic)", id = "Diamond", label = "Diamond level",
        cost = function() return A("DiamondUnlocked") and mutationCost("Diamond", 3) or nil end },
    { group = "Mutations (Gold / Diamond / Atomic)", id = "Gold", label = "Gold level",
        cost = function() return A("GoldUnlocked") and mutationCost("Gold", 1) or nil end },
}
local SHOP_GROUPS = { "Junk Magnet", "Mutations (Gold / Diamond / Atomic)", "Refabricator (2.5x)", "Rebirth Amplifier (3x)",
    "Ion Accelerator (1.5x)", "PowerCore Boosters (2.5x)", "Drone Crate Luck" }

-- ============================== farm (one action per step, owns the character) ==============================
local F, U = {}, {} -- farm steps, upgrades (declared together: the farm walks to base for U's Auto Build)

function F.dumpster(p)
    local d = p:FindFirstChild("Dumpster")
    return d and d:FindFirstChild("Dumpster")
end

function F.full(d)
    if not d or d:GetAttribute("InfiniteStorage") then return false end
    return (d:GetAttribute("CurrentCapacity") or 0) >= (d:GetAttribute("MaxCapacity") or 25)
end

-- The rain pad is fenced on the side facing the rest of the plot (Decor mesh, collidable), and it's
-- only 28 studs wide against a 48-stud pickup reach. So never walk onto it: stand 3 studs outside
-- the fence on the dumpster's side, slid along it to line up with the target.
function F.padSpot(p, target)
    local pad, d = p:FindFirstChild("RainSpawnPad"), F.dumpster(p)
    if not (pad and d and pad:IsA("BasePart")) then return target end
    local hx, hz = pad.Size.X / 2, pad.Size.Z / 2
    local side = pad.CFrame:PointToObjectSpace(d.Position)
    local t = pad.CFrame:PointToObjectSpace(target or pad.Position)
    local spot
    if math.abs(side.X) - hx > math.abs(side.Z) - hz then
        spot = Vector3.new(math.sign(side.X) * (hx + 3), 0, math.clamp(t.Z, -hz + 4, hz - 4))
    else
        spot = Vector3.new(math.clamp(t.X, -hx + 4, hx - 4), 0, math.sign(side.Z) * (hz + 3))
    end
    return pad.CFrame:PointToWorldSpace(spot)
end

function F.pickupStep(p, h)
    local folder = p:FindFirstChild("Junk")
    if not folder then return false end
    local t, c, best, bestScore, bestDist = now(), os.clock(), nil, -math.huge, 0
    for _, j in folder:GetChildren() do
        if not j:GetAttribute("ProducedByCrusher") and not j:GetAttribute("Collected") and not j:GetAttribute("Claimed")
            and t >= (j:GetAttribute("PlanetCollectAt") or 0) and (S.skip[j] or 0) < c then
            local d = boxDist(j, h.Position)
            -- in reach: most valuable first; nothing in reach: walk to the nearest
            local score = d <= CFG.reach and (1e9 + (JUNK_VALUE[j.Name] or 1000) * 1000 - d) or -d
            if score > bestScore then best, bestScore, bestDist = j, score, d end
        end
    end
    if not best then return false end
    if bestDist > CFG.reach then
        moveTo(F.padSpot(p, posOf(best)), 2.5, 8)
        local h2 = hrp()
        if not h2 or boxDist(best, h2.Position) > CFG.reach then
            S.skip[best] = c + 10 -- out of reach even from the fence: leave it to drones / the magnet
        end
        return true
    end
    S.skip[best] = c + 2.5
    if pickup(best) then S.counts.picks += 1 end
    return true
end

function F.lootStep(d)
    local cur = d:GetAttribute("CurrentCapacity") or 0
    if cur <= 0 then return false end
    if usePrompt(d:FindFirstChild("LootDumpsterPrompt", true), 10) then
        S.counts.loots += 1
        log(("looted the dumpster (%d junk)"):format(cur))
        task.wait(0.6)
        return true
    end
    return false
end

function F.crushStep(p)
    if looted() < CFG.crushMin then return false end
    local c = p:FindFirstChild("Crusher")
    if not c then return false end
    local started = c:GetAttribute("CycleStartedAt")
    if started and now() < started + (c:GetAttribute("CycleDuration") or 7) + 0.5 then return false end
    local fb = c:FindFirstChild("FeedBin")
    local panel = fb and fb:FindFirstChild("Panel")
    local btn = panel and panel:FindFirstChild("Button")
    local prompt = btn and btn:FindFirstChildWhichIsA("ProximityPrompt")
    if not (prompt and prompt.Enabled) then return false end
    local n = looted()
    if usePrompt(prompt, 10) then
        S.counts.crushes += 1
        log(("crushing %d junk"):format(n))
        task.wait(1)
        return true
    end
    return false
end

function F.blocksStep(p, h)
    local c = p:FindFirstChild("Crusher")
    local stack = c and c:FindFirstChild("StackPickup")
    local sp = stack and stack:FindFirstChildWhichIsA("ProximityPrompt", true)
    if sp and sp.Enabled then
        local n0 = carried()
        if usePrompt(sp, 10) then
            task.wait(0.6)
            S.counts.blocks += math.max(0, carried() - n0)
            return true
        end
    end
    local folder = p:FindFirstChild("Junk")
    if not folder then return false end
    for _, j in folder:GetChildren() do
        if j:GetAttribute("ProducedByCrusher") and not j:GetAttribute("Collected") and not j:GetAttribute("Claimed")
            and not j:GetAttribute("RollingOut") and not j:GetAttribute("StackedCrusherBlock")
            and not j:GetAttribute("OnConveyor") and not j:GetAttribute("HandPlacementStartedAt")
            and (S.skip[j] or 0) < os.clock() then
            if boxDist(j, h.Position) > 10 then moveTo(posOf(j), 7, 6) end
            local h2 = hrp()
            if h2 and boxDist(j, h2.Position) <= 11 then
                S.skip[j] = os.clock() + 2.5
                if pickup(j) then S.counts.blocks += 1 end
            else
                S.skip[j] = os.clock() + 4
            end
            return true
        end
    end
    return false
end

-- free AutoLoader: carry the blocks to the Unload Pad and stand there while the server takes them
function F.unloadStep(p)
    if carried() <= 0 then return false end
    if A("AutoLoader") == true and A("AutoLoaderDisabled") ~= true then return false end -- the pass does it
    local f = p:FindFirstChild("Factory")
    local st = f and f:FindFirstChild("Start")
    local base = st and (st:FindFirstChild("Base") or st:FindFirstChildWhichIsA("BasePart", true))
    if not base then return false end
    local n0 = carried()
    moveTo(base.Position, 1.5, 12)
    local t = os.clock()
    while S.alive and carried() > 0 and os.clock() - t < 15 and not S.eventBusy do task.wait(0.2) end
    local n = n0 - carried()
    if n > 0 then
        S.counts.unloads += n
        log(("unloaded %d block(s) onto the line"):format(n))
    else
        log("Unload Pad took no blocks in 15 s - backing off 20 s")
        S.backoff.unload = os.clock() + 20
    end
    return true
end

function F.smelterStep(p)
    local sm = p:FindFirstChild("Smelter")
    if not sm then return false end
    local input = sm:FindFirstChild("InputPart")
    if CFG.smeltClaim and (sm:GetAttribute("PendingRewards") or 0) > 0 then
        for _, pr in sm:GetDescendants() do
            if pr:IsA("ProximityPrompt") and pr.Enabled and not (input and pr:IsDescendantOf(input))
                and not pr:GetAttribute("ClaimInProgress") then
                if usePrompt(pr, 10) then
                    log("claimed smelter rewards")
                    task.wait(1)
                    return true
                end
            end
        end
    end
    if CFG.smeltInput and sm:GetAttribute("Smelting") ~= true and (S.backoff.smelt or 0) < os.clock()
        and (carried() > 0 or looted() > 0) then
        local pr = input and input:FindFirstChildWhichIsA("ProximityPrompt", true)
        if pr and pr.Enabled then
            local b0, j0 = carried(), looted()
            S.backoff.smelt = os.clock() + 30
            if usePrompt(pr, 10) then
                task.wait(1.5)
                log(("smelter started: blocks %d -> %d, junk %d -> %d"):format(b0, carried(), j0, looted()))
                return true
            end
        end
    end
    return false
end

function F.step()
    local p = plot()
    if not p then return "no plot yet" end
    if not ready() then return "waiting for game data" end
    local h = hrp()
    if not (h and humanoid()) then return "no character" end
    if S.wantBuild and not onBase(p) and (S.backoff.build or 0) < os.clock() then
        if not moveTo(U.buildSpot(p), 3, 12) then S.backoff.build = os.clock() + 30 end
        return "walking to base for Auto Build"
    end
    local d = F.dumpster(p)
    if CFG.blocks and F.blocksStep(p, h) then return "collecting blocks" end
    if CFG.unload and (S.backoff.unload or 0) < os.clock() and F.unloadStep(p) then return "unloading blocks" end
    if (CFG.smeltClaim or CFG.smeltInput) and F.smelterStep(p) then return "smelter" end
    if CFG.crush and F.crushStep(p) then return "crushing" end
    if CFG.loot and d and F.full(d) and F.lootStep(d) then return "looting (full)" end
    if CFG.pickup and not A("JunkBossActive") and not F.full(d) and F.pickupStep(p, h) then
        S.idleSince = os.clock()
        return "picking up junk"
    end
    if CFG.loot and d then
        local cur = d:GetAttribute("CurrentCapacity") or 0
        local inf = d:GetAttribute("InfiniteStorage") and cur >= 60
        if (inf or (cur > 0 and os.clock() - S.idleSince > CFG.lootIdle)) and F.lootStep(d) then return "looting" end
    end
    return "idle - waiting for junk"
end

-- ============================== upgrades, rebirth, drones (remote-only; walks only for Auto Build when the farm is off) ==============================

local MULT = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, QD = 1e15, QN = 1e18, SX = 1e21, SP = 1e24, OC = 1e27, NO = 1e30, DC = 1e33 }
local function parseCoins(text)
    text = tostring(text):gsub(",", "")
    local n, suf = text:match("([%d%.]+)%s*(%a*)")
    n = tonumber(n)
    if not n then return nil end
    return n * (MULT[(suf or ""):upper()] or 1)
end

-- the Rain card's price isn't in any decompiled module: read it off the plot's board, else try and back off
function U.rainCost(p)
    local g = LP.PlayerGui:FindFirstChild("CoinUpgrades_" .. p.Name)
    local card = g and g:FindFirstChild("Rain", true)
    if not card then return nil end
    for _, d in card:GetDescendants() do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local tx = d.Text
            if tx == "MAX" then return math.huge end
            if tx:find("Coins") then return parseCoins(tx) end
        end
    end
end

function U.coinCost(p, key)
    if key == "Slots" then return ({ 1e4, 1e7 })[math.max(1, num("DroneSlots"))] end
    if key == "Rain" then return U.rainCost(p) end
    return COIN_COST[key][num(COIN_LEVEL[key]) + 1]
end

local function affordable(cost)
    return cost and cost ~= math.huge and cost <= coins() * (1 - CFG.reserve / 100)
end

function U.coinBoard(p)
    local pick, pickCost
    for _, key in COIN_KEYS do
        if CFG.coinKeys[key] and (S.backoff["coin" .. key] or 0) < os.clock() then
            local cost = U.coinCost(p, key)
            local unknown = key == "Rain" and cost == nil
            if unknown or affordable(cost) then
                local rank = CFG.coinOrder == "Cheapest first" and (cost or 1e300) or 0
                if not pick or rank < pickCost then pick, pickCost = key, rank end
                if CFG.coinOrder ~= "Cheapest first" then break end -- list order = priority
            end
        end
    end
    if not pick then return false end
    S.coinRes[pick] = nil
    call("CoinUpgradeRequest", p.Name, pick, "One")
    local t = os.clock()
    while not S.coinRes[pick] and os.clock() - t < 4 do task.wait(0.1) end
    local r = S.coinRes[pick]
    if r and r.ok then
        S.counts.buys += 1
        log("bought " .. COIN_TEXT[pick])
    else
        S.backoff["coin" .. pick] = os.clock() + 20
        if r then log(COIN_TEXT[pick] .. ": " .. tostring(r.text)) end
    end
    return true
end

function U.crusher(p)
    local lvl = num("CrusherSpeedLevel")
    if lvl >= 4 or not affordable(CRUSHER_COST[lvl + 1]) or (S.backoff.crusher or 0) > os.clock() then return false end
    S.crusherRes = nil
    call("CrusherUpgradeRequest", p.Name)
    local t = os.clock()
    while S.crusherRes == nil and os.clock() - t < 4 do task.wait(0.1) end
    if S.crusherRes and S.crusherRes.ok then
        S.counts.buys += 1
        log(("crusher upgraded to level %d (%ds crush)"):format(lvl + 1, 7 - (lvl + 1)))
    else
        S.backoff.crusher = os.clock() + 30
        log("crusher upgrade: " .. tostring(S.crusherRes and S.crusherRes.text or "no answer"))
    end
    return true
end

function U.dumpster()
    local nextLvl = num("DumpsterLevel") + 1
    local cap = math.min(18, tonumber(RS:GetAttribute("DumpsterMaxAvailable")) or 17)
    if nextLvl > cap or not affordable(DUMPSTER_COST[nextLvl]) or (S.backoff.dumpster or 0) > os.clock() then return false end
    S.dumpRes = nil
    call("DumpsterPurchaseRequest", nextLvl)
    local t = os.clock()
    while S.dumpRes == nil and os.clock() - t < 8 do task.wait(0.1) end
    if S.dumpRes and S.dumpRes.ok then
        S.counts.buys += 1
        log(("dumpster upgraded to level %d"):format(nextLvl))
    else
        local why = S.dumpRes and tostring(S.dumpRes.reason) or "no answer"
        S.backoff.dumpster = os.clock() + (why == "Busy" and 5 or 60)
        log("dumpster upgrade: " .. why)
    end
    return true
end

-- an upgrader sitting in Stock isn't on the line yet (spare Conveyors don't count: Auto Build adds those itself)
function U.needsBuild(data)
    if type(data.Stock) ~= "table" then return false end
    for kind, n in data.Stock do
        if kind ~= "Conveyor" and kind ~= "Start" and kind ~= "Sell" and (tonumber(n) or 0) > 0 then return kind end
    end
    return false
end

function U.buildSpot(p)
    local f = p:FindFirstChild("Factory")
    local st = f and f:FindFirstChild("Start")
    return st and posOf(st:FindFirstChild("Base") or st)
end

function U.autoBuild(p, why)
    if not onBase(p) then S.wantBuild = why return false end -- the build tools only open on your own Base
    for _ = 1, 20 do
        local ok, res, msg = call("FactoryAction", "AutoBuild")
        if ok and res then
            S.wantBuild = nil
            log("factory re-laid out with Auto Build (" .. why .. ")")
            return true
        end
        if not (msg == "Please wait." or msg == "Data is loading.") then
            log("Auto Build: " .. tostring(msg or res))
            S.wantBuild = nil
            return false
        end
        task.wait(0.4)
    end
    return false
end

function U.factory(p)
    if (S.backoff.factory or 0) > os.clock() then return false end
    local data = json("FactoryDataJSON")
    local free = num("UpgraderTutorialStage") >= 1 and num("UpgraderTutorialStage") <= 2
    for _, u in UPGRADERS do
        local id, price = u[1], u[2]
        if not factoryOwned(data, id) then
            if not (affordable(price) or (id == "Polisher" and free)) then return false end -- cheapest missing first
            local ok, res, msg = call("FactoryAction", "Buy", id)
            if ok and res then
                S.counts.buys += 1
                log("bought upgrader " .. id .. " (" .. compact(price) .. ")")
                if CFG.autoBuild then S.wantBuild = "new " .. id end
            else
                S.backoff.factory = os.clock() + 30
                log("upgrader " .. id .. ": " .. tostring(msg or res or "no answer"))
            end
            return true
        end
    end
    return false
end

function U.upgraderTutorial(p)
    local stage = num("UpgraderTutorialStage")
    if stage < 1 or stage > 3 or (S.backoff.utut or 0) > os.clock() then return false end
    S.backoff.utut = os.clock() + 10
    if stage == 1 then
        call("UpgraderTutorialGo")
        log("upgrader tutorial: GO")
    elseif stage == 2 then
        local ok, res, msg = call("FactoryAction", "Buy", "Polisher")
        log("upgrader tutorial: free Polisher - " .. tostring(ok and res and "ok" or msg))
    else
        return U.autoBuild(p, "upgrader tutorial")
    end
    return true
end

function U.rebirthWanted()
    local c = coins()
    if c < 1e6 or os.clock() < S.rebirthLock then return false end
    if A("JunkBossActive") or A("AtDiamondPlatform") or S.eventBusy then return false end
    if CFG.rebirthMax > 0 and num("Rebirths") >= CFG.rebirthMax then return false end
    local k = rebirthTokensFor(c)
    local mode = CFG.rebirthMode
    if mode == "As soon as possible" then return true end
    if mode == "At token count" then return k >= CFG.rebirthMinTokens end
    if mode == "Smart" then
        if num("Rebirths") < 5 then return true end -- each of the first 5 adds a permanent +0.5x coins
        if S.income <= 0 then return false end
        -- rebirth when the next token would take longer than this run's average time per token
        local tNext = (1e6 * 5 ^ k - c) / S.income
        return tNext > (os.clock() - S.lastRebirth) / math.max(k, 1)
    end
    return false
end

function U.rebirth()
    local c = coins()
    log(("rebirthing: %s coins -> %d token(s)"):format(compact(c), rebirthTokensFor(c)))
    S.rebirthLock = os.clock() + 15
    call("RebirthRequest")
    return true
end

function U.rebirthShop()
    if (S.backoff.shop or 0) > os.clock() then return false end
    local data = json("FactoryDataJSON")
    local have = tokens()
    for _, it in SHOP do
        if CFG.shopItems[it.group] then
            local cost
            if it.factory then
                cost = not factoryOwned(data, it.id) and it.cost or nil
            else
                cost = it.cost()
            end
            if cost then
                if cost <= have then
                    local ok, res, msg = call("RebirthShopAction", it.id)
                    if ok and res then
                        S.counts.buys += 1
                        log(("rebirth shop: %s (%d tokens)"):format(it.label, cost))
                        if it.factory and CFG.autoBuild then S.wantBuild = it.label end
                    else
                        S.backoff.shop = os.clock() + 60
                        log("rebirth shop " .. it.label .. ": " .. tostring(msg or res or "no answer"))
                    end
                    return true
                elseif CFG.shopSave then
                    return false -- save tokens for the next item in priority order
                end
            end
        end
    end
    return false
end

function U.equipBest()
    if not S.equipDirty or os.clock() - S.equipAt < 3 then return false end
    S.equipDirty, S.equipAt = false, os.clock()
    if A("Trading") then return false end
    call("DroneEquipRequest", "", "EquipBest") -- the game's own Equip Best: the server ranks your drones
    return true
end

function U.tick()
    local p = plot()
    if not (p and ready()) then return end
    if CFG.upgrades and CFG.autoBuild and not S.wantBuild and (S.backoff.build or 0) < os.clock() then
        local kind = U.needsBuild(json("FactoryDataJSON"))
        if kind then S.wantBuild = kind .. " in stock" end
    end
    if S.wantBuild and (S.backoff.build or 0) < os.clock() then
        -- the farm walks to the pad itself when it's running; otherwise nobody owns the character, so walk here
        if not onBase(p) and not CFG.farm and not S.eventBusy then moveTo(U.buildSpot(p), 3, 12) end
        if not U.autoBuild(p, S.wantBuild) and not onBase(p) and not CFG.farm then S.backoff.build = os.clock() + 30 end
    end
    if CFG.rebirthMode ~= "Off" and U.rebirthWanted() then U.rebirth() return end
    if CFG.shop and U.rebirthShop() then return end
    if (CFG.equipBest or (CFG.upgrades and CFG.roll)) and U.equipBest() then return end
    if not CFG.upgrades then return end
    if CFG.upgraderTut and U.upgraderTutorial(p) then return end
    if CFG.factoryBuy and U.factory(p) then return end
    if CFG.crusher and U.crusher(p) then return end
    if CFG.dumpster and U.dumpster() then return end
    U.coinBoard(p)
end

-- ============================== rewards (remote-only) ==============================
local C = {}

local function due(k) return (S.backoff[k] or 0) < os.clock() end
local function hold(k, s) S.backoff[k] = os.clock() + s end
local function claimed(what, ok, res, msg)
    if ok and res ~= false then
        S.counts.claims += 1
        log("claimed " .. what)
        return true
    end
    log(what .. ": " .. tostring(msg or res or "no answer"))
    return false
end

function C.indexWait(...)
    local got, okv
    local ev = RS:FindFirstChild("JunkIndexResult")
    local c = ev and ev.OnClientEvent:Connect(function(ok) got, okv = true, ok end)
    call("JunkIndexClaim", ...)
    local t = os.clock()
    while not got and os.clock() - t < 12 do task.wait(0.1) end
    if c then c:Disconnect() end
    return got and okv
end

function C.activeHourly()
    local H, out = num("HourlyQuestHour"), {}
    for i = 0, 2 do out[#out + 1] = HOURLY[(H + i) % #HOURLY + 1] end
    return out
end

-- { def, progressAttr, claimedAttr } for each daily slot
function C.activeDaily()
    local D, out = num("DailyQuestDay"), {}
    out[1] = { DAILY[D % #DAILY + 1], "DailyQuestProgress", "DailyQuestClaimed" }
    if num("MainQuestStage") > 4 then
        local q = DAILY[(D + 1) % #DAILY + 1]
        out[2] = { q, "Daily" .. q[1] .. "Progress", "Daily" .. q[1] .. "Claimed" }
    end
    return out
end

function C.tick()
    local p = plot()
    if not (p and ready()) then return end
    local t = now()
    if CFG.cWelcome and A("WelcomeBoostReady") and A("WelcomeBoostPending") and due("welcome") then
        hold("welcome", 30)
        claimed("welcome boost (2x coins + 2x luck)", call("ClaimWelcomeBoost"))
    end
    if CFG.cDaily and A("DailyRewardsReady") and num("DailyNextClaim") <= t and due("daily") then
        hold("daily", 60)
        claimed("daily reward (day " .. (num("DailyRewardCount") % 7 + 1) .. ")", call("ClaimDailyReward"))
    end
    if CFG.cOffline and num("OfflineCoins") > 0 and due("offline") then
        hold("offline", 30)
        claimed("offline earnings (" .. compact(num("OfflineCoins")) .. ")", call("OfflineEarningsAction", "Claim"))
    end
    if CFG.cHourly then
        for _, q in C.activeHourly() do
            local k = q[1]
            if num("Hourly" .. k .. "Progress") >= q[2] and not A("Hourly" .. k .. "Claimed") and due("h" .. k) then
                hold("h" .. k, 60)
                claimed("hourly quest: " .. q[3], call("ClaimCollect1K", k))
            end
        end
    end
    if CFG.cDailyQuest then
        for _, slot in C.activeDaily() do
            local q = slot[1]
            if num(slot[2]) >= q[2] and not A(slot[3]) and due("d" .. q[1]) then
                hold("d" .. q[1], 60)
                claimed("daily quest: " .. q[3], call("ClaimDailyQuest", q[1]))
            end
        end
    end
    local stage = num("MainQuestStage")
    if CFG.cMain and stage >= 1 and stage <= 4 and A("MainQuestDone" .. stage) and due("main") then
        hold("main", 30)
        claimed("main quest " .. stage, call("ClaimMainQuest", stage))
    end
    if CFG.cIndex and due("index") then
        local disc, done = json("JunkIndexJSON"), json("JunkIndexClaimsJSON")
        for key, v in disc do
            if v and not done[key] and type(key) == "string" then
                local id, variant = key:match("^(.-):(.+)$")
                if id then
                    if not C.indexWait(id, variant) then hold("index", 120) end
                    log("junk index: " .. key)
                    S.counts.claims += 1
                    break
                end
            end
        end
    end
    if CFG.cMilestone and due("milestone") then
        local disc, ms, found = json("JunkIndexJSON"), json("IndexMilestonesJSON"), 0
        for _, v in disc do if v then found += 1 end end
        for n = 10, 200, 10 do
            local got = ms[tostring(n)] or ms[n] or table.find(ms, n) or table.find(ms, tostring(n))
            if not got then
                if n <= found then
                    if C.indexWait("__milestone", tostring(n)) then
                        S.counts.claims += 1
                        log("junk index milestone " .. n)
                    else
                        hold("milestone", 120)
                    end
                end
                break
            end
        end
    end
    local chest = p:FindFirstChild("DailyChest")
    if CFG.cChest and chest and num("GroupChestNextClaim") <= t and due("chest") then
        hold("chest", 120)
        local ok, res, msg, status = call("ClaimGroupChest", chest)
        if status == "JoinGroup" then
            CFG.cChest = false
            if S.chestToggle then S.chestToggle:SetValue(false) end
            notify("Daily chest needs the game's Roblox group (3876902). Join it, then turn the chest back on.")
        else
            claimed("daily chest", ok, res, msg)
        end
    end
end

-- ============================== events (own the character while they run) ==============================
local E = {}

function E.gemUpgrades()
    if (S.backoff.gemUp or 0) > os.clock() then return false end
    local g, gl, ll = gems(), num("EventGemLevel"), num("EventLuckLevel")
    local which, cost
    if gl < 10 then which, cost = "Gems", (gl + 1) * 50 elseif ll < 30 then which, cost = "Luck", (ll + 1) * 100 end
    if not which or g - cost < CFG.gemFloor then return false end
    S.backoff.gemUp = os.clock() + 1
    local ok, res, msg = call("BuyDiamondUpgrade", which)
    if ok and res ~= false then log("event upgrade: " .. which) else S.backoff.gemUp = os.clock() + 30 log("event upgrade: " .. tostring(msg or res)) end
    return true
end

function E.diamond()
    local st = RS:FindFirstChild("DiamondEventState")
    local live = st and st:GetAttribute("Active") and st:GetAttribute("EventType") == "Diamond"
    local onPf = A("AtDiamondPlatform") == true
    -- the teleport takes a moment to set AtDiamondPlatform: only call the trip over once it's had time to land
    if S.onPlatform and ((not onPf and os.clock() - (S.joinAt or 0) > 15) or (not live and os.clock() - (S.joinAt or 0) > 180)) then
        S.onPlatform, S.eventBusy = false, false
        log("diamond event over - back to farming")
        if onPf then call("TeleportToBase") end
    end
    if not (CFG.diamond and live) then return S.onPlatform == true end
    if not onPf then
        if S.onPlatform then return true end -- teleport still landing
        local joinEnds = st:GetAttribute("JoinEndsAt") or 0
        if st:GetAttribute("DiamondPhase") == "Joining" and joinEnds - now() > 1 and S.joined ~= joinEnds then
            S.joined = joinEnds
            S.eventBusy = true
            waitFarmIdle()
            task.wait(0.5 + math.random() * 1.5)
            local ok, res = call("DiamondEventTeleport")
            log("diamond event: " .. ((ok and res) and "joined" or "join refused"))
            if ok and res then S.onPlatform, S.joinAt = true, os.clock() else S.eventBusy = false end
            return true
        end
        return false
    end
    if not S.onPlatform then S.joinAt = os.clock() end -- joined by hand: farm it too
    S.eventBusy, S.onPlatform = true, true
    if st:GetAttribute("DiamondPhase") == "Returning" then return true end
    local folder, h = workspace:FindFirstChild("DiamondEventJunk"), hrp()
    if not (folder and h) then return true end
    local best, bd
    for _, j in folder:GetChildren() do
        if not j:GetAttribute("Collected") and not j:GetAttribute("Claimed") and (S.skip[j] or 0) < os.clock() then
            local d = boxDist(j, h.Position)
            if not bd or d < bd then best, bd = j, d end
        end
    end
    if best then
        local reach = best:GetAttribute("PlatformDiamond") and 14 or 90
        if bd > reach then moveTo(posOf(best), reach - 3, 5) end
        S.skip[best] = os.clock() + 2.5
        if pickup(best) then S.counts.diamonds += 1 end
    elseif CFG.gemUpgrades then
        E.gemUpgrades()
    end
    return true
end

-- Mega Crate rain + meteor crates: no client script claims them, so it's a prompt or a touch on the server.
-- Use a prompt when the crate has one, otherwise walk onto it.
function E.drops()
    local list = {}
    local mega = RS:FindFirstChild("MegaCrateEventState")
    if CFG.megaCrates and mega and mega:GetAttribute("Active") then
        local f = workspace:FindFirstChild("MegaCrateEventDrops")
        if f then
            for _, m in f:GetChildren() do
                if now() >= (m:GetAttribute("FallStart") or 0) + 1.5 then list[#list + 1] = m end
            end
        end
    end
    local st = RS:FindFirstChild("DiamondEventState")
    if CFG.meteorCrates and st and st:GetAttribute("Active") and st:GetAttribute("EventType") == "Meteor" then
        local f = workspace:FindFirstChild("MeteorEventDrops")
        if f then for _, m in f:GetChildren() do list[#list + 1] = m end end
    end
    S.dropTries = S.dropTries or {}
    local target, td
    for _, m in list do
        if (S.skip[m] or 0) < os.clock() and (S.dropTries[m] or 0) < 3 then -- 3 tries, then it isn't claimable by us
            local d = dist(posOf(m))
            if not td or d < td then target, td = m, d end
        end
    end
    if not target then
        if S.dropTrip then
            S.dropTrip = false
            call("TeleportToBase")
            task.wait(1.5)
            S.eventBusy = false
        end
        return false
    end
    S.eventBusy, S.dropTrip = true, true
    waitFarmIdle()
    S.skip[target] = os.clock() + 15
    S.dropTries[target] = (S.dropTries[target] or 0) + 1
    if not S.dropLogged[target.Name] then -- recon: record how this drop is built (prompt vs touch) for the spec
        S.dropLogged[target.Name] = true
        local kinds = {}
        for _, d in target:GetDescendants() do kinds[d.ClassName] = (kinds[d.ClassName] or 0) + 1 end
        local parts = {}
        for k, v in kinds do parts[#parts + 1] = k .. " x" .. v end
        log("drop " .. target:GetFullName() .. ": " .. table.concat(parts, ", "))
    end
    local prompt = target:FindFirstChildWhichIsA("ProximityPrompt", true)
    if prompt then
        usePrompt(prompt, 25)
    else
        local body = target:FindFirstChild("CrateBody", true) or target:FindFirstChild("RewardDroneCrate", true) or target
        moveTo(posOf(body), 1.5, 25)
        task.wait(0.6)
    end
    S.counts.drops += 1
    log("went for drop " .. target.Name)
    return true
end

function E.world()
    if not CFG.worldChallenge or A("WorldChallengeRewardClaimed") or (S.backoff.world or 0) > os.clock() then return false end
    local wc = workspace:FindFirstChild("WorldChallenge")
    local part = wc and wc:FindFirstChild("RewardPromptPart")
    local pr = part and part:FindFirstChild("ClaimWorldReward")
    if not (pr and pr.Enabled) then return false end
    S.backoff.world = os.clock() + 120
    S.eventBusy = true
    waitFarmIdle()
    if dist(posOf(part)) > 150 then call("TeleportToShops") task.wait(1.5) end
    if usePrompt(pr, 25) then log("claimed the World Challenge reward (1,000 gems)") end
    task.wait(1)
    call("TeleportToBase")
    task.wait(1.5)
    S.eventBusy = false
    return true
end

function E.crates()
    if not (CFG.upgrades and CFG.roll) or (S.backoff.crates or 0) > os.clock() then return false end
    if A("PaidRandomAllowed") ~= true then return false end -- the game hides crates for this account (policy)
    local c = CRATES[CFG.crateKind]
    local function balance() return c.cur == "gems" and gems() or tokens() end
    local function batch()
        local n = c.single and 1 or CFG.crateBatch
        if balance() - c.price * n < CFG.crateFloor then n = 1 end
        return balance() - c.price * n >= CFG.crateFloor and n or 0
    end
    -- only make the trip when a full batch is affordable above the floor
    if balance() - c.price * (c.single and 1 or CFG.crateBatch) < CFG.crateFloor then return false end
    local part = workspace
    for _, name in c.path do part = part and part:FindFirstChild(name) end
    local pos = posOf(part)
    if not pos then log("crate " .. CFG.crateKind .. " not found") S.backoff.crates = os.clock() + 60 return false end
    S.eventBusy = true
    waitFarmIdle()
    if dist(pos) > 60 then call("TeleportToShops") task.wait(1.5) end
    moveTo(pos, 10, 20)
    local opened = 0
    S.stopHit = nil
    while S.alive and CFG.upgrades and CFG.roll and opened < 30 do
        local n = batch()
        if n == 0 then break end
        S.crateDone = nil
        c.buy(n)
        local t = os.clock()
        while S.crateDone == nil and os.clock() - t < 5 do task.wait(0.1) end
        if S.crateDone == "error" or S.crateDone == nil then S.backoff.crates = os.clock() + 60 break end
        opened += n
        if S.stopHit then
            CFG.roll = false
            if S.rollToggle then S.rollToggle:SetValue(false) end
            notify("Auto Roll paused: you unboxed " .. (DRONE_NAME[S.stopHit] or S.stopHit) .. "!")
            break
        end
        task.wait(1 + math.random() * 0.4)
    end
    log(("opened %d crate(s)"):format(opened))
    call("TeleportToBase")
    task.wait(1.5)
    S.backoff.crates = os.clock() + 20
    S.eventBusy = false
    return true
end

-- ============================== listeners ==============================
local function gotDrone(t)
    local r = RANK[t] or 0
    S.counts.drones += 1
    S.equipDirty = true
    log(("unboxed %s (%s)"):format(DRONE_NAME[t] or tostring(t), RARITY[r] or "?"))
    if r >= 5 and CFG.rareNotify then notify(("%s drone: %s!"):format(RARITY[r], DRONE_NAME[t] or tostring(t))) end
    if r >= (STOP_RANK[CFG.crateStop] or 99) then S.stopHit = t end
end

local function ev(name) return RS:WaitForChild(name, 10) end

do
    local e = ev("DroneResult")
    if e then on(e.OnClientEvent, function(kind, data)
        if kind == "Unboxed" and type(data) == "table" then gotDrone(data.Type) S.crateDone = true
        elseif kind == "UnboxedBatch" and type(data) == "table" and type(data.Results) == "table" then
            for _, r in data.Results do if type(r) == "table" then gotDrone(r.Type) end end
            S.crateDone = true
        elseif kind == "Error" then
            S.crateDone = "error"
            log("crate: " .. (type(data) == "table" and tostring(data.Message) or tostring(data)))
        end
    end) end
    e = ev("PremiumDroneCrateResult")
    if e then on(e.OnClientEvent, function(data)
        if type(data) == "table" then for _, t in data do if type(t) == "string" then gotDrone(t) end end end
        S.crateDone = true
    end) end
    e = ev("RareDroneAnnouncement")
    if e then on(e.OnClientEvent, function(who, t, how)
        if CFG.serverRare and who ~= LP.Name then
            notify(("%s %s %s"):format(tostring(who), how == "Looted" and "looted" or "unboxed", DRONE_NAME[t] or tostring(t)))
        end
    end) end
    e = ev("CoinUpgradeResult")
    if e then on(e.OnClientEvent, function(plotName, key, ok, text)
        if plotName == A("PlotName") then S.coinRes[key] = { ok = ok, text = text } end
    end) end
    e = ev("CrusherUpgradeResult")
    if e then on(e.OnClientEvent, function(plotName, ok, text)
        if plotName == A("PlotName") then S.crusherRes = { ok = ok, text = text } end
    end) end
    e = ev("DumpsterPurchaseResult")
    if e then on(e.OnClientEvent, function(level, ok, reason) S.dumpRes = { ok = ok, reason = reason } end) end
    e = ev("RebirthResult")
    if e then on(e.OnClientEvent, function(success, msg, count)
        if success then
            S.counts.rebirths += 1
            S.lastRebirth, S.rebirthLock = os.clock(), os.clock() + 5
            S.equipDirty = true
            if CFG.autoBuild then S.wantBuild = "after rebirth" end
            log("rebirth " .. tostring(count) .. " done")
            notify("Rebirth " .. tostring(count) .. " done")
        else
            S.rebirthLock = os.clock() + 30
            log("rebirth refused: " .. tostring(msg))
        end
    end) end
    e = ev("FactorySale")
    if e then on(e.OnClientEvent, function(p, _, _, _, _, _, _, _, _, _, _, _, _, amount)
        -- (plot, cframe components..., value): the value is always the last argument
        if typeof(p) == "Instance" and p.Name == A("PlotName") then
            S.factorySaleSeen = true
            S.sales += tonumber(amount) or 0
        end
    end) end
    e = ev("JunkSoldEvent") -- "N JUNK BLOCKS SOLD FOR X COINS": sent to you only; used until a FactorySale of yours shows up
    if e then on(e.OnClientEvent, function(_, amount)
        if not S.factorySaleSeen then S.sales += tonumber(amount) or 0 end
    end) end
    e = ev("JunkBossEvent")
    if e then on(e.OnClientEvent, function(kind, a, b)
        if kind == "Start" then log("junk boss spawned")
        elseif kind == "Victory" then S.counts.bossKills += 1 log("junk boss defeated")
        elseif kind == "Reward" then
            log(("boss reward: %s coins, %s gems"):format(compact(a), compact(b)))
            if CFG.eventNotify then notify(("Boss down: +%s coins, +%s gems"):format(compact(a), compact(b))) end
        elseif kind == "Failed" then log("junk boss escaped") end
    end) end
end

for _, k in { "DroneInventoryJSON", "DroneXPJSON", "DroneSlots", "PaidDroneSlots", "GiftedDroneSlots" } do
    on(LP:GetAttributeChangedSignal(k), function() S.equipDirty = true end)
end

do -- event announcements
    local st = RS:FindFirstChild("DiamondEventState")
    if st then on(st:GetAttributeChangedSignal("Active"), function()
        if not (st:GetAttribute("Active") and CFG.eventNotify) then return end
        if st:GetAttribute("EventType") == "Meteor" then notify("Meteor shower: +50% junk rain, drone crates falling")
        else notify(("Diamond event: joining closes in %s"):format(clock((st:GetAttribute("JoinEndsAt") or 0) - now()))) end
    end) end
    local mega = RS:FindFirstChild("MegaCrateEventState")
    if mega then on(mega:GetAttributeChangedSignal("Active"), function()
        if mega:GetAttribute("Active") and CFG.eventNotify then notify("Mega Crate rain: 4 free Mega Crates") end
    end) end
end

on(LP.Idled, function()
    if not CFG.antiAfk then return end
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

on(GuiService.ErrorMessageChanged, function(msg)
    if msg == "" then return end
    local ok, code = pcall(function() return GuiService:GetErrorCode().Value end)
    log(("disconnected: code %s · %s · job %s"):format(ok and tostring(code) or "?", msg, game.JobId:sub(1, 8)))
    pcall(writefile, LOG_FILE, table.concat(S.log, "\n"))
end)

-- keep farming across teleports (IY autorejoin, server hops): queue this file for the next server
on(LP.OnTeleport, function(state)
    if state == Enum.TeleportState.Started and CFG.rejoin and queue_on_teleport then
        queue_on_teleport(('local ok, src = pcall(readfile, "jc2_main.lua") loadstring(ok and src or game:HttpGet(%q))()')
            :format(SELF_URL))
        log("teleport started - hub queued for the next server")
        pcall(writefile, LOG_FILE, table.concat(S.log, "\n"))
    end
end)

-- ============================== unload + watchdog ==============================
local Library
local function unload()
    if not S.alive then return end
    S.alive = false
    for _, c in S.conns do pcall(function() c:Disconnect() end) end
    if getgenv().CruelHubJC2 == S then getgenv().CruelHubJC2 = nil end
    pcall(writefile, LOG_FILE, table.concat(S.log, "\n"))
    if Library then pcall(Library.Unload, Library) end
end
S.unload = unload

task.spawn(function()
    while S.alive do
        if getgenv().CruelHubJC2_TOKEN ~= TOKEN then log("newer copy started, unloading this one") unload() break end
        task.wait(1)
    end
end)

-- ============================== loops ==============================
local function guard(name, fn)
    local ok, err = pcall(fn)
    if not ok then log(name .. " error: " .. tostring(err)) end
    return ok, err
end

task.spawn(function() -- farm: owns the character unless an event does
    while S.alive do
        if CFG.farm and not S.eventBusy then
            S.farmBusy = true
            local ok, res = guard("farm", F.step)
            S.status = ok and res or "error"
            S.farmBusy = false
            task.wait(0.05)
        else
            S.status = S.eventBusy and "paused: event" or "off"
            task.wait(0.3)
        end
    end
end)

task.spawn(function() -- events, crates, world challenge
    while S.alive do
        if ready() then
            local busy = select(2, guard("diamond", E.diamond))
            if not busy then busy = select(2, guard("drops", E.drops)) end
            if not busy then busy = select(2, guard("world", E.world)) end
            if not busy then guard("crates", E.crates) end
        end
        task.wait(0.25)
    end
end)

task.spawn(function() -- boss
    while S.alive do
        if ready() then
            guard("boss", function()
                local mode = CFG.bossMode
                if mode == "Turn it off" and A("JunkBossEnabled") ~= false and due("boss") then
                    hold("boss", 30)
                    call("JunkBossEvent", "SetEnabled", false)
                    log("junk boss turned off: pickups never pause")
                elseif mode == "Kill it" then
                    if A("JunkBossEnabled") == false and due("boss") then
                        hold("boss", 30)
                        call("JunkBossEvent", "SetEnabled", true)
                    end
                    local p = plot()
                    local boss = p and p:FindFirstChild("PersonalJunkBoss")
                    if A("JunkBossActive") and boss and (boss:GetAttribute("Health") or 1) > 0 then
                        call("JunkBossEvent", "Click", boss) -- paced: one click per action slot
                    end
                end
            end)
        end
        task.wait(A("JunkBossActive") and 0.02 or 0.5)
    end
end)

task.spawn(function() -- upgrades / rebirth / drones
    while S.alive do
        guard("upgrades", U.tick)
        task.wait(1.2)
    end
end)

task.spawn(function() -- rewards
    while S.alive do
        if CFG.claims then guard("claims", C.tick) end
        task.wait(5)
    end
end)

task.spawn(function() -- income (5-min window of coin gains; spending and rebirths don't count against it)
    local n = 0
    while S.alive do
        n += 1
        local c, t = coins(), os.clock()
        if S.lastCoins and c > S.lastCoins then
            S.incomeWin[#S.incomeWin + 1] = { t, c - S.lastCoins }
            S.earned += c - S.lastCoins
        end
        S.lastCoins = c
        while S.incomeWin[1] and t - S.incomeWin[1][1] > 300 do table.remove(S.incomeWin, 1) end
        local sum = 0
        for _, e in S.incomeWin do sum += e[2] end
        S.income = sum / math.clamp(t - S.t0, 1, 300)
        if n % 30 == 0 then for k in S.skip do if typeof(k) == "Instance" and not k.Parent then S.skip[k] = nil end end end
        if S.logDirty and n % 3 == 0 then
            S.logDirty = false
            pcall(writefile, LOG_FILE, table.concat(S.log, "\n"))
        end
        task.wait(1)
    end
end)

-- ============================== Obsidian UI ==============================
-- Local copies in the workspace first: a hung GitHub HttpGet once stalled a reload (and the
-- executor's whole script queue with it). Falls back to GitHub when a copy is missing.
local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local function obsidian(file, remote)
    local path = "BattleBotFarm/lib/" .. file
    local ok, src = pcall(function() return isfile(path) and readfile(path) end)
    return loadstring(ok and src or game:HttpGet(repo .. remote))()
end
Library = obsidian("Library.lua", "Library.lua")
local ThemeManager = obsidian("ThemeManager.lua", "addons/ThemeManager.lua")
local SaveManager  = obsidian("SaveManager.lua", "addons/SaveManager.lua")
notify = function(msg) pcall(function() Library:Notify(msg, 5) end) end

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
    end)(), Footer = "Junk Crushers 2 · v1 · farm · upgrades · rebirth · drones · rewards · events",
    Size = UDim2.fromOffset(704, 824), -- default window size (user pick)
    Center = true, AutoShow = true, ToggleKeybind = Enum.KeyCode.RightControl,
})
-- unloaded by a newer copy while we were still setting up: don't leave a dead menu behind
if not S.alive or getgenv().CruelHubJC2_TOKEN ~= TOKEN then pcall(Library.Unload, Library) return end

local Tabs = {
    Farm     = Window:AddTab("Farm", "pickaxe"),
    Upgrades = Window:AddTab("Upgrades", "circle-arrow-up"),
    Rebirth  = Window:AddTab("Rebirth", "rotate-ccw"),
    Drones   = Window:AddTab("Drones", "plane"),
    Rewards  = Window:AddTab("Rewards", "gift"),
    Events   = Window:AddTab("Events", "party-popper"),
    Teleport = Window:AddTab("Teleport", "map-pin"),
    Status   = Window:AddTab("Status", "activity"),
    Settings = Window:AddTab("Settings", "settings"),
}

local function toggle(box, idx, key, text, tip, extra)
    return box:AddToggle(idx, {
        Text = text, Tooltip = tip, Default = CFG[key],
        Callback = function(v)
            CFG[key] = v
            if extra then extra(v) end
        end,
    })
end
local function slider(box, idx, key, text, min, max, suffix, tip, rounding)
    return box:AddSlider(idx, {
        Text = text, Tooltip = tip, Default = CFG[key], Min = min, Max = max, Rounding = rounding or 0, Suffix = suffix,
        Callback = function(v) CFG[key] = v end,
    })
end
local function dropdown(box, idx, key, text, values, tip)
    return box:AddDropdown(idx, {
        Text = text, Tooltip = tip, Values = values, Default = CFG[key],
        Callback = function(v) CFG[key] = v end,
    })
end
local function multi(box, idx, key, text, values, tip, labels)
    local defaults, shown, back = {}, {}, {}
    for _, v in values do
        local l = labels and labels[v] or v
        shown[#shown + 1], back[l] = l, v
        if CFG[key][v] then defaults[#defaults + 1] = l end
    end
    return box:AddDropdown(idx, {
        Text = text, Tooltip = tip, Values = shown, Default = defaults, Multi = true,
        Callback = function(sel)
            local t = {}
            for _, l in shown do t[back[l]] = sel[l] == true end
            CFG[key] = t
        end,
    })
end

-- ---------- Farm ----------
local Loop = Tabs.Farm:AddLeftGroupbox("Junk loop — coins", "recycle")
Loop:AddLabel("Rain junk -> dumpster -> crusher -> blocks -> Unload Pad -> factory sells. Each step below is one part of that loop; the farm does whichever is due.", true)
toggle(Loop, "JC2_Farm", "farm", "Auto Farm", "Runs the whole loop with the steps ticked below. Owns your character while on (events pause it)")
    :AddKeyPicker("JC2_FarmKey", { Default = "F6", SyncToggleState = true, Mode = "Toggle", Text = "Auto Farm" })
toggle(Loop, "JC2_Pickup", "pickup", "Pick up rain junk", "Most valuable junk in reach first; walks to the nearest when nothing is in reach. Stacks with the game's Auto Clicker and magnet")
toggle(Loop, "JC2_Loot", "loot", "Loot dumpster", "The moment it's full (what the Infinite Storage pass saves you), or when the rain runs dry")
toggle(Loop, "JC2_Crush", "crush", "Crush junk", "Presses the crusher's Crush Junk button once enough junk is looted")
toggle(Loop, "JC2_Blocks", "blocks", "Collect junk blocks", "Pick Up All on the stack, or each block that rolls out (12-stud pickup)")
toggle(Loop, "JC2_Unload", "unload", "Unload blocks (free Auto Loader)", "Carries your blocks to the factory's Unload Pad and waits there while the line takes them. Skipped while the Auto Loader pass is doing it")
slider(Loop, "JC2_Reach", "reach", "Pickup reach", 10, 46, " studs", "The game allows 48 from your character to the junk's box")
slider(Loop, "JC2_CrushMin", "crushMin", "Crush at looted junk ≥", 1, 50, "", "The game warns below 10")
slider(Loop, "JC2_LootIdle", "lootIdle", "Loot a part-full dumpster after", 2, 60, "s idle")
local farmLabel = Loop:AddLabel("…", true)

local Smelt = Tabs.Farm:AddRightGroupbox("Smelter — potions, gems, drones", "flame")
Smelt:AddLabel("A 10-minute batch pays 2-5 rolls: 2x coin or 2x luck potions (applied on claim), gems, or drones up to Halo and Cinder.", true)
toggle(Smelt, "JC2_SmeltClaim", "smeltClaim", "Claim smelter rewards", "Uses the claim prompt as soon as a batch is ready (part of Auto Farm)")
toggle(Smelt, "JC2_SmeltInput", "smeltInput", "Start smelter batches", "Feeds the smelter whenever it's idle. It takes from what you're holding, so it competes a little with the factory")
local smeltLabel = Smelt:AddLabel("…", true)

local Move = Tabs.Farm:AddRightGroupbox("Movement", "footprints")
toggle(Move, "JC2_FastMove", "fastMove", "Fast move", "Steps your character 8 studs at a time instead of walking. Faster, but more visible than walking")
local Game = Tabs.Farm:AddRightGroupbox("Game's AUTO LOADER", "package")
if A("AutoLoader") == true then
    local gl = Game:AddToggle("JC2_GameLoader", {
        Text = "Game's Auto Loader (pass)", Default = A("AutoLoaderDisabled") ~= true,
        Tooltip = "The pass's own switch. While it's on, Unload blocks above stands aside",
        Callback = function(v)
            if S.syncLoader or v == (A("AutoLoaderDisabled") ~= true) then return end
            task.spawn(call, "SetAutoLoaderEnabled", v)
        end,
    })
    on(LP:GetAttributeChangedSignal("AutoLoaderDisabled"), function()
        S.syncLoader = true
        gl:SetValue(A("AutoLoaderDisabled") ~= true)
        S.syncLoader = false
    end)
else
    Game:AddLabel("The Auto Loader is a pass you don't own. Unload blocks above does the same, free.", true)
end

-- ---------- Upgrades ----------
local Plot = Tabs.Upgrades:AddLeftGroupbox("Plot — coin board, crusher, dumpster", "coins")
toggle(Plot, "JC2_Upgrades", "upgrades", "Auto Upgrades", "Coin board, crusher, dumpster, factory upgraders + Auto Build, and Auto Roll. One purchase at a time, each confirmed by the server before the next")
multi(Plot, "JC2_CoinKeys", "coinKeys", "Coin board cards", COIN_KEYS, "Rain = better junk tiers · Rain Speed = more drops (beats the Fast Rain pass at max) · Auto Clicker = server pickups · Drone Speed / Slots", COIN_TEXT)
dropdown(Plot, "JC2_CoinOrder", "coinOrder", "Buy order", { "Cheapest first", "Card order (Rain first)" })
toggle(Plot, "JC2_Crusher", "crusher", "Crusher speed", "4 levels: 1K / 10K / 100K / 1M. Each takes 1 s off the 7 s crush")
toggle(Plot, "JC2_Dumpster", "dumpster", "Bigger dumpster", "17 levels from 30 coins. More room = fewer loot trips")
slider(Plot, "JC2_Reserve", "reserve", "Keep in reserve", 0, 90, "% of coins", "Upgrades only spend what's above this")
local upLabel = Plot:AddLabel("…", true)

local Roll = Tabs.Upgrades:AddLeftGroupbox("Auto Roll — drone crates", "dices")
Roll:AddLabel("Runs with Auto Upgrades. When a full batch is affordable above the floor it goes to the crate (game's Shops teleport), rolls, equips your best drones and comes home. Gems / tokens only: Robux crate buttons are locked out of this hub.", true)
S.rollToggle = toggle(Roll, "JC2_Roll", "roll", "Auto Roll", "Pauses farming while it's at the shop")
dropdown(Roll, "JC2_CrateKind", "crateKind", "Crate", CRATE_KINDS,
    "Normal 100 gems · Infernal 300 gems (Griffin / Prism Leviathan) · Rebirth 10 tokens (Reforge / Afterburner / Harbringer) · Mega 10K gems")
Roll:AddDropdown("JC2_CrateBatch", { Text = "Roll at a time", Values = { "1", "3" }, Default = tostring(CFG.crateBatch),
    Callback = function(v) CFG.crateBatch = tonumber(v) or 1 end })
slider(Roll, "JC2_CrateFloor", "crateFloor", "Keep at least", 0, 50000, "", "Gems (or tokens for the Rebirth crate) never spent")
dropdown(Roll, "JC2_CrateStop", "crateStop", "Stop rolling when I get", { "Never", "Legendary", "Mythical", "Exotic", "Akashic", "Secret" },
    "Turns Auto Roll off and notifies you when a drone this rare or better drops")
local rollLabel = Roll:AddLabel("…", true)

local Fac = Tabs.Upgrades:AddRightGroupbox("Factory — upgraders", "factory")
Fac:AddLabel("Every upgrader on the line multiplies each block once (Polisher x1.4 … Drum Refiner x1.8). Coin upgraders are lost on rebirth; this buys them back.", true)
toggle(Fac, "JC2_FactoryBuy", "factoryBuy", "Buy upgraders", "Cheapest missing first: Polisher 1K -> Wooden Smelter 25K -> Laser 100K -> Press 2.5M -> Spectrum 100M -> Smoker 5B -> Drum Refiner 10T")
toggle(Fac, "JC2_AutoBuild", "autoBuild", "Auto Build", "The game's free Auto Build button, pressed after every upgrader buy, after rebirth, and whenever a part sits unplaced in stock. It re-lays out the WHOLE factory into the game's spiral, so a custom layout gets replaced")
toggle(Fac, "JC2_UpgraderTut", "upgraderTut", "Finish the upgrader tutorial", "GO -> free Polisher -> Auto Build: +x1.4 and +2,000 coins")
local facLabel = Fac:AddLabel("…", true)

local Pass = Tabs.Upgrades:AddRightGroupbox("Gamepasses, recreated free", "sparkles")
Pass:AddLabel("Auto Loader -> Farm > Unload blocks\nInfinite Storage -> Farm > Loot dumpster + Bigger dumpster\nFast Rain (+50%) -> Rain Speed card (+300% at max)\nAuto Clicker -> Farm > Pick up rain junk (~2.5/s)\n2x Sell, Drone Luck, VIP: server-side multipliers, no free equivalent. Stack the free 2x coin boosts instead (Rewards).", true)

-- ---------- Rebirth ----------
local Reb = Tabs.Rebirth:AddLeftGroupbox("Rebirth — tokens, gems, +0.5x coins", "rotate-ccw")
Reb:AddLabel("Costs 1M and spends ALL coins; resets coins, upgrades, dumpster and coin upgraders. Pays rebirth tokens (1 at 1M, +1 each 5x more), 50 gems per token, and +0.5x coins for each of your first 5 rebirths.", true)
dropdown(Reb, "JC2_RebirthMode", "rebirthMode", "Auto Rebirth", { "Off", "As soon as possible", "At token count", "Smart" },
    "Smart: rebirths at 1M until you have 5, then waits while the next token comes faster than this run's average")
slider(Reb, "JC2_RebirthTokens", "rebirthMinTokens", "Token count", 1, 12, " tokens", "For 'At token count'")
slider(Reb, "JC2_RebirthMax", "rebirthMax", "Stop at rebirth", 0, 200, "", "0 = no limit")
local rebLabel = Reb:AddLabel("…", true)

local Shop = Tabs.Rebirth:AddRightGroupbox("Rebirth shop — spends tokens", "store")
toggle(Shop, "JC2_Shop", "shop", "Auto Rebirth Shop", "Buys in this order: Gold, Magnet, Refabricator, Diamond, Atomic, Amplifier, Ion, PowerCore, Drone Luck, then mutation levels. Everything here survives rebirth")
multi(Shop, "JC2_ShopItems", "shopItems", "Buy", SHOP_GROUPS)
toggle(Shop, "JC2_ShopSave", "shopSave", "Save for the next item", "Don't skip ahead to cheaper items while the next one in order is unaffordable")
local shopLabel = Shop:AddLabel("…", true)

-- ---------- Drones ----------
local Eq = Tabs.Drones:AddLeftGroupbox("Equip", "plane")
toggle(Eq, "JC2_EquipBest", "equipBest", "Auto Equip Best", "The game's own Equip Best, re-run whenever you get a drone, a slot, or a level")
local droneLabel = Eq:AddLabel("…", true)

local DN = Tabs.Drones:AddRightGroupbox("Rolls — notifications", "bell")
DN:AddLabel("Auto Roll (crate opening) lives under Upgrades > Auto Roll and runs with Auto Upgrades.", true)
toggle(DN, "JC2_RareNotify", "rareNotify", "Notify on Mythical+")
toggle(DN, "JC2_ServerRare", "serverRare", "Server-wide rare drops", "Other players' Mythical+ unboxes")

-- ---------- Rewards ----------
local Cl = Tabs.Rewards:AddLeftGroupbox("Claims", "gift")
toggle(Cl, "JC2_Claims", "claims", "Auto Claim", "Checks every 5 s; each claim is the game's own button")
toggle(Cl, "JC2_CWelcome", "cWelcome", "Welcome boost", "2x coins + 2x luck each session")
toggle(Cl, "JC2_CDaily", "cDaily", "Daily reward", "7-day cycle: coins, Junk Hunter, gems, Reactor Overlord")
toggle(Cl, "JC2_COffline", "cOffline", "Offline earnings", "The free claim only (the 2x button is Robux)")
toggle(Cl, "JC2_CHourly", "cHourly", "Hourly quests")
toggle(Cl, "JC2_CDailyQuest", "cDailyQuest", "Daily quests")
toggle(Cl, "JC2_CMain", "cMain", "Main quests")
toggle(Cl, "JC2_CIndex", "cIndex", "Junk index entries", "10-40 gems for each new junk / mutation found")
toggle(Cl, "JC2_CMilestone", "cMilestone", "Junk index milestones", "Gems, +0.1x coins, +10% rain, a drone slot, a Mega Crate")
S.chestToggle = toggle(Cl, "JC2_CChest", "cChest", "Daily chest", "Needs the game's Roblox group")
local Quests = Tabs.Rewards:AddRightGroupbox("Quests", "list-checks")
local questLabel = Quests:AddLabel("…", true)
local Timers = Tabs.Rewards:AddRightGroupbox("Timers & boosts", "timer")
local timerLabel = Timers:AddLabel("…", true)

-- ---------- Events ----------
local Boss = Tabs.Events:AddLeftGroupbox("Junk Boss", "skull")
Boss:AddLabel("Spawns every 150 pickups for 20 s and blocks rain pickups while it's up. Faster kills pay up to 100x coins and 2x gems.", true)
dropdown(Boss, "JC2_BossMode", "bossMode", "Boss", { "Game default", "Kill it", "Turn it off" },
    "Kill it: clicks it at action pace. Turn it off: the game's own switch, so the farm never pauses")
local bossLabel = Boss:AddLabel("…", true)

local Dia = Tabs.Events:AddLeftGroupbox("Diamond event", "gem")
toggle(Dia, "JC2_Diamond", "diamond", "Auto Diamond Event", "Joins with the game's teleport, picks up diamonds on the platform, then farming resumes")
toggle(Dia, "JC2_GemUp", "gemUpgrades", "Buy event upgrades", "Gems (+0.2x rebirth gems, max 10) then Luck (+0.1x crate luck, max 30), bought on the platform")
slider(Dia, "JC2_GemFloor", "gemFloor", "Keep at least", 0, 50000, " gems")

local Drop = Tabs.Events:AddRightGroupbox("Drops & world", "party-popper")
toggle(Drop, "JC2_Mega", "megaCrates", "Grab Mega Crate rain", "4 free Mega Crates per rain. Walks to each landed crate")
toggle(Drop, "JC2_Meteor", "meteorCrates", "Grab meteor crates", "Drone crates from the Meteor shower")
toggle(Drop, "JC2_World", "worldChallenge", "World Challenge reward", "1,000 gems once the server-wide goal is reached")
toggle(Drop, "JC2_EventNotify", "eventNotify", "Event notifications")
local eventLabel = Drop:AddLabel("…", true)

-- ---------- Teleport ----------
local Tp = Tabs.Teleport:AddLeftGroupbox("Teleports", "map-pin")
Tp:AddLabel("Uses the game's own Base / Shops buttons. Turn Auto Farm off first or it walks you back.", true)
Tp:AddButton({ Text = "My base", Func = function() task.spawn(call, "TeleportToBase") end })
Tp:AddButton({ Text = "Shops", Func = function() task.spawn(call, "TeleportToShops") end })
local function walkSpot(text, path)
    Tp:AddButton({ Text = text, Func = function()
        task.spawn(function()
            local part = workspace
            for _, n in path do part = part and part:FindFirstChild(n) end
            local pos = posOf(part)
            if not pos then notify(text .. ": not found") return end
            if dist(pos) > 60 then call("TeleportToShops") task.wait(1.5) end
            moveTo(pos, 8, 25)
        end)
    end })
end
walkSpot("Drone crates", { "DroneShop", "DroneCrate" })
walkSpot("Rebirth shop", { "RebirthShop" })
walkSpot("Dumpster shop", { "DumpsterShop" })
walkSpot("World Challenge", { "WorldChallenge" })

-- ---------- Status ----------
local Stat = Tabs.Status:AddLeftGroupbox("Status", "activity")
local statusLabel = Stat:AddLabel("…", true)
local Log = Tabs.Status:AddRightGroupbox("Log", "scroll-text")
local logLabel = Log:AddLabel("", true)

local function fmtSince(untilT) local s = (tonumber(untilT) or 0) - now() return s > 0 and clock(s) or nil end

task.spawn(function()
    while S.alive do
        pcall(function()
            local p, t = plot(), now()
            local d = p and F.dumpster(p)
            local hours = math.max((os.clock() - S.t0) / 3600, 1 / 60)
            local cnt = S.counts
            farmLabel:SetText(("%s\ndumpster %s/%s · looted %d · carrying %d\npicked %d · loots %d · crushes %d · blocks %d · unloaded %d")
                :format(S.status, tostring(d and d:GetAttribute("CurrentCapacity") or "?"),
                    d and (d:GetAttribute("InfiniteStorage") and "∞" or tostring(d:GetAttribute("MaxCapacity") or 25)) or "?",
                    looted(), carried(), cnt.picks, cnt.loots, cnt.crushes, cnt.blocks, cnt.unloads))
            local sm = p and p:FindFirstChild("Smelter")
            smeltLabel:SetText(sm and ("%s · %d reward(s) waiting"):format(sm:GetAttribute("Smelting") and "smelting" or "idle",
                sm:GetAttribute("PendingRewards") or 0) or "smelter not found")
            upLabel:SetText(("rain Lv.%d · speed %d/30 · clicker %d/16 · drone speed %d/20 · slots %d/3\ncrusher %d/4 · dumpster Lv.%d · bought %d")
                :format(num("JunkRainLevel"), num("RainSpeedLevel"), num("AutoClickerLevel"), num("DroneSpeedLevel"),
                    num("DroneSlots"), num("CrusherSpeedLevel"), num("DumpsterLevel"), cnt.buys))
            local data, own = json("FactoryDataJSON"), {}
            for _, u in UPGRADERS do if factoryOwned(data, u[1]) then own[#own + 1] = u[1] end end
            facLabel:SetText(("owned: %s · sales %s%s"):format(#own > 0 and table.concat(own, ", ") or "none", compact(S.sales),
                S.wantBuild and "\nAuto Build waits until you're on your base" or ""))
            local c = coins()
            local k = rebirthTokensFor(c)
            rebLabel:SetText(("rebirths %d · coins %s -> %d token(s)\nnext token at %s · coin mult x%.1f\nrebirths this session %d")
                :format(num("Rebirths"), compact(c), k, compact(1e6 * 5 ^ k), 1 + 0.5 * math.min(num("Rebirths"), 5), cnt.rebirths))
            shopLabel:SetText(("tokens %d · magnet %d/3 · drone luck %d/4\nmutations: gold %s · diamond %s · atomic %s")
                :format(tokens(), num("JunkMagnetLevel"), num("DroneLuckLevel"),
                    A("GoldUnlocked") and ("Lv." .. num("GoldLevel")) or "locked",
                    A("DiamondUnlocked") and ("Lv." .. num("DiamondLevel")) or "locked",
                    A("AtomicUnlocked") and ("Lv." .. num("AtomicLevel")) or "locked"))
            local inv, eq = json("DroneInventoryJSON"), {}
            local owned = 0
            for _ in inv do owned += 1 end
            for _, key in { "EquippedDrone", "EquippedDrone2", "EquippedDrone3", "EquippedDrone4", "EquippedDrone5" } do
                local id = A(key)
                if type(id) == "string" and id ~= "" then eq[#eq + 1] = DRONE_NAME[inv[id]] or tostring(inv[id] or id) end
            end
            droneLabel:SetText(("%d drone(s) owned · slots %d\nequipped: %s\nunboxed this session %d · gems %s")
                :format(owned, num("DroneSlots") + num("PaidDroneSlots") + num("GiftedDroneSlots") + (A("VIP") and 1 or 0),
                    #eq > 0 and table.concat(eq, ", ") or "none", cnt.drones, compact(gems())))
            local cr = CRATES[CFG.crateKind]
            local need = cr.price * (cr.single and 1 or CFG.crateBatch) + CFG.crateFloor
            local have = cr.cur == "gems" and gems() or tokens()
            rollLabel:SetText(("%s %s / %s for the next roll%s\nrolled this session %d")
                :format(cr.cur == "gems" and "gems" or "tokens", compact(have), compact(need),
                    A("PaidRandomAllowed") ~= true and "\ncrates are disabled for this account (policy)" or "", cnt.drones))
            local ql = {}
            for _, q in C.activeHourly() do
                ql[#ql + 1] = ("hourly · %s %s/%s%s"):format(q[3], compact(num("Hourly" .. q[1] .. "Progress")), compact(q[2]),
                    A("Hourly" .. q[1] .. "Claimed") and " ✓" or "")
            end
            for _, slot in C.activeDaily() do
                local q = slot[1]
                ql[#ql + 1] = ("daily · %s %d/%d%s"):format(q[3], num(slot[2]), q[2], A(slot[3]) and " ✓" or "")
            end
            local stage = num("MainQuestStage")
            ql[#ql + 1] = stage <= 4 and ("main · stage %d%s"):format(stage, A("MainQuestDone" .. stage) and " (ready)" or "") or "main · done"
            ql[#ql + 1] = ("claimed this session %d"):format(cnt.claims)
            questLabel:SetText(table.concat(ql, "\n"))
            local tl = {
                "daily reward " .. (num("DailyNextClaim") <= t and "ready" or clock(num("DailyNextClaim") - t)),
                "hourly quests reset " .. clock(3600 - math.floor(t) % 3600),
                "daily quests reset " .. clock((num("DailyQuestDay") + 1) * 86400 - t),
                "daily chest " .. (num("GroupChestNextClaim") <= t and "ready" or clock(num("GroupChestNextClaim") - t)),
            }
            for _, b in { { "WelcomeBoostUntil", "welcome 2x" }, { "SmelterCoinBoostUntil", "2x coins potion" },
                { "SmelterLuckBoostUntil", "2x luck potion" }, { "DailyCoinBoostUntil", "daily 2x coins" } } do
                local left = fmtSince(A(b[1]))
                if left then tl[#tl + 1] = b[2] .. " " .. left end
            end
            if num("OfflineCoins") > 0 then tl[#tl + 1] = "offline coins waiting: " .. compact(num("OfflineCoins")) end
            timerLabel:SetText(table.concat(tl, "\n"))
            local boss = p and p:FindFirstChild("PersonalJunkBoss")
            bossLabel:SetText(A("JunkBossActive") and boss and ("BOSS UP · %s/%s HP"):format(compact(boss:GetAttribute("Health")),
                compact(boss:GetAttribute("MaxHealth"))) or ("%s · next at %d/150 pickups · kills %d")
                :format(A("JunkBossEnabled") == false and "off" or "on", num("JunkBossProgress"), cnt.bossKills))
            local st, mega = RS:FindFirstChild("DiamondEventState"), RS:FindFirstChild("MegaCrateEventState")
            local el = {}
            if st and st:GetAttribute("Active") then
                el[#el + 1] = ("%s event · %s · %s/%s drops"):format(tostring(st:GetAttribute("EventType")),
                    tostring(st:GetAttribute("DiamondPhase") or "active"), tostring(st:GetAttribute("CollectedDrops") or 0),
                    tostring(st:GetAttribute("PlannedDrops") or 40))
            elseif st then
                el[#el + 1] = "next diamond/meteor event in " .. clock((st:GetAttribute("EndsAt") or t) - t)
            end
            if mega and mega:GetAttribute("Active") then el[#el + 1] = "Mega Crate rain NOW" end
            el[#el + 1] = ("diamonds %d · drops %d · gems %s"):format(cnt.diamonds, cnt.drops, compact(gems()))
            eventLabel:SetText(table.concat(el, "\n"))
            local admin = {}
            if (tonumber(RS:GetAttribute("AdminGlobalCoinMultiplier")) or 1) > 1 then admin[#admin + 1] = "COINS x" .. RS:GetAttribute("AdminGlobalCoinMultiplier") end
            if (tonumber(RS:GetAttribute("AdminGlobalLuckMultiplier")) or 1) > 1 then admin[#admin + 1] = "LUCK x" .. RS:GetAttribute("AdminGlobalLuckMultiplier") end
            statusLabel:SetText(table.concat({
                ("farm: %s%s"):format(S.status, S.eventBusy and " (event running)" or ""),
                ("coins %s · earned %s (%s/h) · now %s/s"):format(compact(c), compact(S.earned), compact(S.earned / hours), compact(S.income)),
                ("gems %s · tokens %d · rebirths %d · factory sales %s"):format(compact(gems()), tokens(), num("Rebirths"), compact(S.sales)),
                ("rain x%.2f%s · global boosts: %s"):format(
                    (tonumber(RS:GetAttribute("MeteorRainMultiplier")) or 1) * (A("FastRain") and 1.5 or 1) * (1 + 0.1 * num("RainSpeedLevel") + num("IndexRainBonus")),
                    A("FastRain") and " (Fast Rain pass)" or "", #admin > 0 and table.concat(admin, ", ") or "none"),
                ("place v%d (spec verified on v%d)%s"):format(game.PlaceVersion, SPEC_VERSION,
                    game.PlaceVersion ~= SPEC_VERSION and " · game updated since: watch the log" or ""),
            }, "\n"))
            logLabel:SetText(table.concat(S.log, "\n", math.max(1, #S.log - 13)))
        end)
        task.wait(0.5)
    end
end)

Library:OnUnload(function()
    S.alive = false
    for _, c in S.conns do pcall(function() c:Disconnect() end) end
    if getgenv().CruelHubJC2 == S then getgenv().CruelHubJC2 = nil end
end)

-- ---------- Settings ----------
local iy
do
    function iy(command)
        local root = gethui and gethui() or game:GetService("CoreGui")
        local bar = root:FindFirstChild("Cmdbar", true)
        local input = bar and (bar:IsA("TextBox") and bar or bar:FindFirstChildWhichIsA("TextBox"))
        if not (input and getconnections) then
            log("IY not loaded - skipped: " .. command)
            return false
        end
        input.Text = command
        for _, c in getconnections(input.FocusLost) do c:Fire(true) end
        log("IY: " .. command)
        return true
    end
end

local Menu = Tabs.Settings:AddLeftGroupbox("Menu", "menu")
toggle(Menu, "JC2_AntiAfk", "antiAfk", "Anti-AFK", "Stops the 20-minute idle kick")
toggle(Menu, "JC2_Rejoin", "rejoin", "Restart hub after a rejoin / server hop",
    "Queues this hub for the next server when a teleport starts (IY autorejoin, hops). Save it in your workspace as jc2_main.lua to skip the download")
slider(Menu, "JC2_Gap", "gap", "Action spacing", 0.3, 1, "s", "Time between any two remotes or prompts. 0.3 s is the floor every CruelHub script keeps", 2)
-- the game's own settings live on the server: these mirror them and only write what you change
local function gameSetting(text, key, tip)
    local tg = Menu:AddToggle("JC2_" .. key, {
        Text = text, Tooltip = tip, Default = A(key) == true,
        Callback = function(v)
            if S["sync" .. key] or v == (A(key) == true) then return end
            task.spawn(call, "UpdatePlayerSetting", key, v)
        end,
    })
    on(LP:GetAttributeChangedSignal(key), function()
        S["sync" .. key] = true
        tg:SetValue(A(key) == true)
        S["sync" .. key] = false
    end)
end
gameSetting("Reduce lag (game setting)", "SettingsReduceLag", "Skips collect / crusher / unbox animations, shadows and post effects")
gameSetting("Hide other drones (game setting)", "SettingsHideOtherDrones", "Hides other players' drones, sounds and pulses")
gameSetting("Mute music (game setting)", "SettingsMusicMuted")
Menu:AddButton({ Text = "Unload", Func = function() unload() end })

local IyBox = Tabs.Settings:AddRightGroupbox("Infinite Yield (runs its own commands)", "terminal")
IyBox:AddLabel("Drives IY's command bar, so these need IY loaded (your autoexec does it).", true)
CFG.iySafety, CFG.iyNoRender = false, false
toggle(IyBox, "JC2_IySafety", "iySafety", "AFK safety bundle",
    "staffwatch (alert when game staff join) + noprompts (no purchase popups) + clearerror (clear kick blur)",
    function(v) iy(v and "staffwatch\\noprompts\\clearerror" or "unstaffwatch\\showprompts") end)
toggle(IyBox, "JC2_IyNoRender", "iyNoRender", "Stop 3D rendering (AFK CPU saver)", "IY norender / render",
    function(v) iy(v and "norender" or "render") end)

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "JC2_GameLoader", "JC2_SettingsReduceLag", "JC2_SettingsHideOtherDrones", "JC2_SettingsMusicMuted" }) -- server-stored; a saved copy would fight it
SaveManager:SetFolder(DIR)
ThemeManager:SetFolder(DIR)
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:SetDefaultTheme({ BackgroundColor = "0c0a0b", MainColor = "161214", AccentColor = "e0233c", OutlineColor = "2a1d20", FontColor = "f2eded" }) -- CruelHub look
ThemeManager:ApplyToTab(Tabs.Settings)
if not getgenv().CRUELHUB_SAFEBOOT then SaveManager:LoadAutoloadConfig() end -- safe boot: nothing auto-starts

-- PlaceVersion: the spec was verified on 1616; a different number means the game updated since
log(("loaded - %s · place v%s · job %s"):format(A("PlotName") or "no plot yet", tostring(game.PlaceVersion), game.JobId:sub(1, 8)))
Library:Notify("Junk Crushers 2 ready — RightCtrl toggles the UI, F6 toggles Auto Farm. Save a config in Settings to keep your toggles.", 5)
