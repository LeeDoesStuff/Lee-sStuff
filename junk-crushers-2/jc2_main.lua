-- CruelHub · Junk Crushers 2
-- Auto farm hub for [AUTO CLICK] Junk Crushers 2 (PlaceId 73968232750026). See notes.md / spec.md.

local Players            = game:GetService("Players")
local RS                 = game:GetService("ReplicatedStorage")
local HttpService        = game:GetService("HttpService")
local VirtualUser        = game:GetService("VirtualUser")
local GuiService         = game:GetService("GuiService")
local PathfindingService = game:GetService("PathfindingService")
local LP                 = Players.LocalPlayer

local PLACE_ID, SPEC_VERSION = 73968232750026, 1616
local SELF_URL = "https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/junk-crushers-2/jc2_main.lua"
local DIR      = "CruelHub/JunkCrushers2"
local LOG_FILE = DIR .. "/log.txt"

if game.PlaceId ~= PLACE_ID then
    warn("[CruelHub] jc2_main.lua only runs in Junk Crushers 2")
    return
end
if not game:IsLoaded() then game.Loaded:Wait() end

-- newest copy wins (autoexec + teleport requeue can both start one)
local TOKEN = {}
getgenv().CruelHubJC2_TOKEN = TOKEN
if getgenv().CruelHubJC2 then pcall(getgenv().CruelHubJC2.unload) end
for _, d in { "CruelHub", DIR } do if not isfolder(d) then pcall(makefolder, d) end end

-- ============================== config ==============================
local CFG = {
    -- farm
    farm = false, pickup = true, loot = true, crush = true, blocks = true, unload = true,
    reach = 44, crushMin = 10, lootIdle = 8, fastMove = false,
    smeltClaim = true, smeltInput = false,
    -- upgrades
    upgrades = false, coinKeys = { Rain = true, Speed = true, AutoClicker = true, DroneSpeed = true, Slots = true },
    coinOrder = "Cheapest first", reserve = 0, crusher = true, dumpster = true,
    factoryBuy = true, autoBuild = true, upgraderTut = true,
    roll = true, crateKind = "Normal (100 gems)", crateBatch = 3, crateFloor = 0, crateStop = "Exotic",
    -- rebirth
    rebirthMode = "Off", rebirthMinTokens = 2, rebirthMax = 0,
    shop = false, shopSave = true,
    shopItems = { ["Junk Magnet"] = true, Mutations = true, Refabricator = true, ["Rebirth Amplifier"] = true,
        ["Ion Accelerator"] = true, ["PowerCore Boosters"] = true, ["Drone Luck"] = true },
    -- drones
    equipBest = false, rareNotify = true, serverRare = false,
    -- rewards
    claims = false, cWelcome = true, cDaily = true, cOffline = true, cHourly = true, cDailyQuest = true,
    cMain = true, cIndex = true, cMilestone = true, cChest = true,
    -- events
    bossMode = "Default", diamond = false, gemUpgrades = false, gemFloor = 0,
    megaCrates = false, meteorCrates = false, worldChallenge = false, eventNotify = true,
    -- settings
    antiAfk = true, rejoin = true, gap = 0.35, iySafety = false, iyNoRender = false,
}

local S = {
    alive = true, conns = {}, log = {}, logDirty = false, cfg = CFG,
    status = "off", farmBusy = false, eventBusy = false, idleSince = os.clock(),
    seq = 1000000, skip = {}, backoff = {}, t0 = os.clock(), gate = 0,
    lastCoins = nil, income = 0, incomeWin = {}, earned = 0, sales = 0,
    counts = { picks = 0, loots = 0, crushes = 0, blocks = 0, unloads = 0, buys = 0, rebirths = 0, claims = 0,
        drones = 0, bossKills = 0, diamonds = 0, drops = 0 },
    lastRebirth = os.clock(), rebirthLock = 0, equipDirty = true, equipAt = 0, coinRes = {},
    dropLogged = {}, dropTries = {}, unload = function() end,
}
getgenv().CruelHubJC2 = S

local notify = function() end -- becomes Library:Notify once the UI loads

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

-- ============================== remotes ==============================
-- never fired: no client caller (honeypots), the admin panel, Robux, trades
local FORBIDDEN = {}
for _, n in { "PrivatePlaytimeQuery", "PrivatePlaytimeDevice", "AdminPlayerStats", "JunkRainUpgradeRequest",
    "JunkRainUpgradeResult", "ClaimGroupReward", "SetBigJunkScale",
    "AdminActivateEvent", "AdminSetGlobalBoost", "AdminToggleFlight", "SendAdminAnnouncement",
    "SkipRebirthPurchase", "GemPackPurchase", "MegaRainPurchase", "StarterPackPurchaseRequest", "GamepassGifting",
    "LimitedDronePurchase", "DroneTradeInvite", "DroneTradeSession" } do FORBIDDEN[n] = true end

-- remotes that also have Robux or destructive forms: only these argument shapes go out
local ARGLOCK = {
    NormalDroneCratePurchase  = function(a) return a[1] == "Gems" end,
    PremiumDroneCratePurchase = function(a) return a[1] == 1 and a[2] == "Gems" end,
    OfflineEarningsAction     = function(a) return a[1] == "Claim" end,
    DroneEquipRequest         = function(a) return a[2] == "EquipBest" end,
    FactoryAction             = function(a) return a[1] == "Buy" or a[1] == "AutoBuild" end,
    SetAutoLoaderEnabled      = function() return LP:GetAttribute("AutoLoader") == true end,
}

-- one shared clock for every remote and prompt: CFG.gap apart plus jitter
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
    -- RemoteFunctions can hang: stop waiting after 10 s
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

-- ============================== helpers ==============================
local function A(k) return LP:GetAttribute(k) end
local function num(k) return tonumber(LP:GetAttribute(k)) or 0 end
local function now() return workspace:GetServerTimeNow() end
local function due(k) return (S.backoff[k] or 0) < os.clock() end
local function hold(k, s) S.backoff[k] = os.clock() + s end

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
local function looted()  return valueOf("InventoryFolder", "Junk") end
local function carried() return valueOf("Inventory", "JunkBlocks") end -- total value of blocks in hand, not a count
local function gems()    return num("Diamonds") end
local function tokens()  return num("RebirthCoins") end

local function json(k)
    local s = LP:GetAttribute(k)
    if type(s) ~= "string" or s == "" then return {} end
    local ok, t = pcall(HttpService.JSONDecode, HttpService, s)
    return ok and type(t) == "table" and t or {}
end
local function held() return #json("CarriedBlockValues") end -- blocks in hand

local function ready()
    return A("CoinDataReady") == true and A("DataLoadState") == "Ready" and not A("RebirthPending") and not A("DroneSavePending")
end

local SUFFIX = { "", "K", "M", "B", "T", "QD", "QN", "SX", "SP", "OC", "NO", "DC" }
local function compact(n)
    n = tonumber(n) or 0
    local neg, i = n < 0, 1
    n = math.abs(n)
    while n >= 1000 and i < #SUFFIX do n /= 1000; i += 1 end
    local s = i == 1 and tostring(math.floor(n)) or (n >= 100 and "%.0f" or n >= 10 and "%.1f" or "%.2f"):format(n) .. SUFFIX[i]
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

-- distance to the closest point of the instance's box (the measure the game's pickup range uses)
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

-- ============================== movement + prompts ==============================
local function flat(a, b) return Vector3.new(b.X - a.X, 0, b.Z - a.Z) end

-- short CFrame steps; small steps because one long jump is what server movement checks look for
local function stepTo(pos, radius, deadline, size)
    while S.alive and os.clock() < deadline do
        local h = hrp()
        if not h then return false end
        local d = flat(h.Position, pos)
        if d.Magnitude <= radius then return true end
        h.CFrame += d.Magnitude > size and d.Unit * size or d
        task.wait(0.07)
    end
    return false
end

-- straight walk; gives up after 1 s without progress (no jumping: a jump by the crusher lands in its feed bin)
local function walkStraight(pos, radius, deadline)
    local anchor, anchorT = nil, os.clock()
    while S.alive and os.clock() < deadline do
        local h, hum = hrp(), humanoid()
        if not (h and hum) then return false end
        if flat(h.Position, pos).Magnitude <= radius then return true end
        hum:MoveTo(Vector3.new(pos.X, h.Position.Y, pos.Z))
        if not anchor or (h.Position - anchor).Magnitude > 1 then
            anchor, anchorT = h.Position, os.clock()
        elseif os.clock() - anchorT > 1 then
            return false
        end
        task.wait(0.15)
    end
    return false
end

-- pathfinding walk, straight-line fallback, then short steps when stuck close to the target
local function moveTo(pos, radius, timeout)
    if not pos then return false end
    radius, timeout = radius or 3, timeout or 10
    local deadline = os.clock() + timeout
    local h, hum = hrp(), humanoid()
    if not (h and hum) then return false end
    if flat(h.Position, pos).Magnitude <= radius then return true end
    if CFG.fastMove then return stepTo(pos, radius, deadline, 8) end
    if flat(h.Position, pos).Magnitude > 10 then
        -- aim just short: buttons sit inside solid parts, which fails a path
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
    if walkStraight(pos, radius, deadline) then return true end
    h = hrp()
    if h and flat(h.Position, pos).Magnitude <= 30 then return stepTo(pos, radius, os.clock() + 3, 4) end
    return false
end

local function firePrompt(prompt)
    pace()
    if fireproximityprompt and pcall(fireproximityprompt, prompt) then return true end
    return (pcall(function()
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
    S.seq += 1 -- ours start at 1,000,001 so they never collide with the game's counter
    return call("JunkPickupRequest", inst, S.seq)
end

-- ============================== game data (copied, never require()d) ==============================
local JUNK_VALUE = {} -- JunkIndexConfig order = value order; unknown names are newer, higher tiers
for i, id in { "CupTrash", "PlankTrash", "PipeTrash", "TableTrash", "TireTrash", "DumbellTrash", "BenchPressTrash",
    "TukTukTrash", "SmallBoatTrash", "ForkLiftTrash", "RoofTrash", "TentTrash", "ExcavatorTrash", "CamperTrash",
    "MiningTruckTrash", "LocomotiveTrash", "BulldozerTrash", "CargoHelicopterTrash", "GarbageTruckTrash", "CargoShip",
    "SkyScraperJunk", "AirplaneTrash", "RoadTrash", "CraneTrash", "NuclearReactorTrash", "SatelliteTrash",
    "FighterJetTrash", "SportsCarTrash", "RocketTrash", "AlienAircraftTrash", "AlienRoverTrash", "AlienStatueTrash",
    "AlienRailgunTrash", "AngelicHelmetTrash", "AngelicGateTrash", "AngelicSwordTrash", "AngelicStatueTrash",
    "AngelicPowerCoreTrash", "InfernalGuardianTrash", "ForgottenHaulerTrash" } do JUNK_VALUE[id] = i end

local HOURLY = { { "Coins", 1000, "Collect 1K junk" }, { "Diamond", 10, "10 diamond junk" },
    { "Playtime", 1800, "Play 30 min" }, { "Blocks", 30, "30 junk blocks" } }
local DAILY = { { "Crates", 15, "Open 15 crates" }, { "Rebirth", 1, "Rebirth" }, { "Mega", 1, "Open a Mega Crate" },
    { "Rain", 20, "20 rain upgrades" } }

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
local COIN_TEXT = { Rain = "Junk Rain", Speed = "Rain Speed", AutoClicker = "Auto Clicker", DroneSpeed = "Drone Speed",
    Slots = "Drone Slots" }
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
    ["Mega (10K gems)"] = { cur = "gems", price = 10000, single = true, path = { "MegaDroneCrate", "CrateBody" },
        buy = function() return call("PremiumDroneCratePurchase", 1, "Gems") end },
}
local CRATE_KINDS = { "Normal (100 gems)", "Infernal (300 gems)", "Rebirth (10 tokens)", "Mega (10K gems)" }

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

-- rebirth shop, in buy order
local SHOP = {
    { group = "Mutations", id = "Gold", label = "Gold unlock", cost = function() return not A("GoldUnlocked") and 1 or nil end },
    { group = "Junk Magnet", id = "JunkMagnet", label = "Junk Magnet",
        cost = function() local l = num("JunkMagnetLevel") return l < 3 and ({ 4, 8, 16 })[l + 1] or nil end },
    { group = "Refabricator", id = "PrismaticReactor", label = "Refabricator", factory = true, cost = 6 },
    { group = "Mutations", id = "Diamond", label = "Diamond unlock", cost = function() return not A("DiamondUnlocked") and 3 or nil end },
    { group = "Mutations", id = "Atomic", label = "Atomic unlock", cost = function() return not A("AtomicUnlocked") and 6 or nil end },
    { group = "Rebirth Amplifier", id = "RebirthAmplifier", label = "Rebirth Amplifier", factory = true, cost = 15 },
    { group = "Ion Accelerator", id = "IonAccelerator", label = "Ion Accelerator", factory = true, cost = 20 },
    { group = "PowerCore Boosters", id = "NewRebirthConveyor", label = "PowerCore Boosters", factory = true, cost = 30 },
    { group = "Drone Luck", id = "DroneLuck", label = "Drone Luck",
        cost = function() local l = num("DroneLuckLevel") return l < 4 and 2 ^ (l + 1) or nil end },
    { group = "Mutations", id = "Atomic", label = "Atomic level",
        cost = function() return A("AtomicUnlocked") and mutationCost("Atomic", 6) or nil end },
    { group = "Mutations", id = "Diamond", label = "Diamond level",
        cost = function() return A("DiamondUnlocked") and mutationCost("Diamond", 3) or nil end },
    { group = "Mutations", id = "Gold", label = "Gold level",
        cost = function() return A("GoldUnlocked") and mutationCost("Gold", 1) or nil end },
}
local SHOP_GROUPS = { "Junk Magnet", "Mutations", "Refabricator", "Rebirth Amplifier", "Ion Accelerator",
    "PowerCore Boosters", "Drone Luck" }

-- ============================== farm (owns the character) ==============================
local F, U = {}, {}

function F.dumpster(p)
    local d = p:FindFirstChild("Dumpster")
    return d and d:FindFirstChild("Dumpster")
end

function F.full(d)
    if not d or d:GetAttribute("InfiniteStorage") then return false end
    return (d:GetAttribute("CurrentCapacity") or 0) >= (d:GetAttribute("MaxCapacity") or 25)
end

-- The rain pad is fenced on the plot side, and only 28 studs wide against a 48-stud reach:
-- stand 3 studs outside the fence (dumpster side), slid along it to line up with the target.
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
            -- in reach: most valuable first; otherwise the nearest
            local score = d <= CFG.reach and (1e9 + (JUNK_VALUE[j.Name] or 1000) * 1000 - d) or -d
            if score > bestScore then best, bestScore, bestDist = j, score, d end
        end
    end
    if not best then return false end
    if bestDist > CFG.reach then
        moveTo(F.padSpot(p, posOf(best)), 2.5, 8)
        local h2 = hrp()
        if not h2 or boxDist(best, h2.Position) > CFG.reach then S.skip[best] = c + 10 end -- leave it to drones
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
        log(("looted %d junk"):format(cur))
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
        local n0 = held()
        if usePrompt(sp, 10) then
            task.wait(0.6)
            S.counts.blocks += math.max(0, held() - n0)
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

-- free Auto Loader: stand on the Unload Pad while the server takes the blocks (~1 per 1.8 s, measured)
function F.unloadStep(p)
    if carried() <= 0 then return false end
    if A("AutoLoader") == true and A("AutoLoaderDisabled") ~= true then return false end -- the pass does it
    local f = p:FindFirstChild("Factory")
    local st = f and f:FindFirstChild("Start")
    local base = st and (st:FindFirstChild("Base") or st:FindFirstChildWhichIsA("BasePart", true))
    if not base then return false end
    moveTo(base.Position, 1.5, 12)
    local h = hrp()
    if not h or flat(h.Position, base.Position).Magnitude > 2.5 then
        log("couldn't reach the Unload Pad, retrying in 10 s")
        hold("unload", 10)
        return true
    end
    local n0, v0 = held(), carried()
    local last, lastT = n0, os.clock()
    while S.alive and carried() > 0 and not S.eventBusy and os.clock() - lastT < 6 do
        task.wait(0.25)
        local n = held()
        if n < last then last, lastT = n, os.clock() end
    end
    local n = n0 - held()
    if n > 0 or carried() < v0 then
        S.counts.unloads += math.max(n, 0)
        log(("unloaded %d blocks (%s)"):format(n, compact(v0 - carried())))
    else
        log("Unload Pad took nothing, retrying in 20 s")
        hold("unload", 20)
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
    if CFG.smeltInput and sm:GetAttribute("Smelting") ~= true and due("smelt") and (carried() > 0 or looted() > 0) then
        local pr = input and input:FindFirstChildWhichIsA("ProximityPrompt", true)
        if pr and pr.Enabled then
            local b0, j0 = held(), looted()
            hold("smelt", 30)
            if usePrompt(pr, 10) then
                task.wait(1.5)
                log(("smelter started (blocks %d -> %d, junk %d -> %d)"):format(b0, held(), j0, looted()))
                return true
            end
        end
    end
    return false
end

function F.step()
    local p = plot()
    if not p then return "no plot yet" end
    if not ready() then return "loading" end
    local h = hrp()
    if not (h and humanoid()) then return "no character" end
    if S.wantBuild and not onBase(p) and due("build") then
        if not moveTo(U.buildSpot(p), 3, 12) then hold("build", 30) end
        return "walking to base"
    end
    local d = F.dumpster(p)
    if CFG.blocks and F.blocksStep(p, h) then return "collecting blocks" end
    if CFG.unload and due("unload") and F.unloadStep(p) then return "unloading" end
    if (CFG.smeltClaim or CFG.smeltInput) and F.smelterStep(p) then return "smelter" end
    if CFG.crush and F.crushStep(p) then return "crushing" end
    if CFG.loot and d and F.full(d) and F.lootStep(d) then return "looting" end
    if CFG.pickup and not A("JunkBossActive") and not F.full(d) and F.pickupStep(p, h) then
        S.idleSince = os.clock()
        return "picking up junk"
    end
    if CFG.loot and d then
        local cur = d:GetAttribute("CurrentCapacity") or 0
        local inf = d:GetAttribute("InfiniteStorage") and cur >= 60
        if (inf or (cur > 0 and os.clock() - S.idleSince > CFG.lootIdle)) and F.lootStep(d) then return "looting" end
    end
    return "waiting for junk"
end

-- ============================== upgrades, rebirth, drones ==============================
local MULT = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, QD = 1e15, QN = 1e18, SX = 1e21, SP = 1e24, OC = 1e27, NO = 1e30, DC = 1e33 }
local function parseCoins(text)
    text = tostring(text):gsub(",", "")
    local n, suf = text:match("([%d%.]+)%s*(%a*)")
    n = tonumber(n)
    if not n then return nil end
    return n * (MULT[(suf or ""):upper()] or 1)
end

local function affordable(cost)
    return cost and cost ~= math.huge and cost <= coins() * (1 - CFG.reserve / 100)
end

-- the Rain card's price isn't in a decompiled module: read it off the board, else try and back off
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

function U.coinBoard(p)
    local pick, pickCost
    for _, key in COIN_KEYS do
        if CFG.coinKeys[key] and due("coin" .. key) then
            local cost = U.coinCost(p, key)
            if (key == "Rain" and cost == nil) or affordable(cost) then
                local rank = CFG.coinOrder == "Cheapest first" and (cost or 1e300) or 0
                if not pick or rank < pickCost then pick, pickCost = key, rank end
                if CFG.coinOrder ~= "Cheapest first" then break end
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
        hold("coin" .. pick, 20)
        if r then log(COIN_TEXT[pick] .. ": " .. tostring(r.text)) end
    end
    return true
end

function U.crusher(p)
    local lvl = num("CrusherSpeedLevel")
    if lvl >= 4 or not affordable(CRUSHER_COST[lvl + 1]) or not due("crusher") then return false end
    S.crusherRes = nil
    call("CrusherUpgradeRequest", p.Name)
    local t = os.clock()
    while S.crusherRes == nil and os.clock() - t < 4 do task.wait(0.1) end
    if S.crusherRes and S.crusherRes.ok then
        S.counts.buys += 1
        log(("crusher level %d"):format(lvl + 1))
    else
        hold("crusher", 30)
        log("crusher upgrade: " .. tostring(S.crusherRes and S.crusherRes.text or "no answer"))
    end
    return true
end

function U.dumpster()
    local nextLvl = num("DumpsterLevel") + 1
    local cap = math.min(18, tonumber(RS:GetAttribute("DumpsterMaxAvailable")) or 17)
    if nextLvl > cap or not affordable(DUMPSTER_COST[nextLvl]) or not due("dumpster") then return false end
    S.dumpRes = nil
    call("DumpsterPurchaseRequest", nextLvl)
    local t = os.clock()
    while S.dumpRes == nil and os.clock() - t < 8 do task.wait(0.1) end
    if S.dumpRes and S.dumpRes.ok then
        S.counts.buys += 1
        log(("dumpster level %d"):format(nextLvl))
    else
        local why = S.dumpRes and tostring(S.dumpRes.reason) or "no answer"
        hold("dumpster", why == "Busy" and 5 or 60)
        log("dumpster upgrade: " .. why)
    end
    return true
end

-- an upgrader in Stock isn't on the line yet (spare conveyors don't count)
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
    if not onBase(p) then S.wantBuild = why return false end -- build tools only open on your own Base
    for _ = 1, 20 do
        local ok, res, msg = call("FactoryAction", "AutoBuild")
        if ok and res then
            S.wantBuild = nil
            log("Auto Build (" .. why .. ")")
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

function U.factory()
    if not due("factory") then return false end
    local data = json("FactoryDataJSON")
    local free = num("UpgraderTutorialStage") >= 1 and num("UpgraderTutorialStage") <= 2
    for _, u in UPGRADERS do
        local id, price = u[1], u[2]
        if not factoryOwned(data, id) then
            if not (affordable(price) or (id == "Polisher" and free)) then return false end -- cheapest missing first
            local ok, res, msg = call("FactoryAction", "Buy", id)
            if ok and res then
                S.counts.buys += 1
                log("bought " .. id .. " (" .. compact(price) .. ")")
                if CFG.autoBuild then S.wantBuild = "new " .. id end
            else
                hold("factory", 30)
                log(id .. ": " .. tostring(msg or res or "no answer"))
            end
            return true
        end
    end
    return false
end

function U.upgraderTutorial(p)
    local stage = num("UpgraderTutorialStage")
    if stage < 1 or stage > 3 or not due("utut") then return false end
    hold("utut", 10)
    if stage == 1 then
        call("UpgraderTutorialGo")
        log("upgrader tutorial: GO")
    elseif stage == 2 then
        local ok, res, msg = call("FactoryAction", "Buy", "Polisher")
        log("upgrader tutorial: free Polisher " .. tostring(ok and res and "ok" or msg))
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
    if mode == "ASAP" then return true end
    if mode == "At tokens" then return k >= CFG.rebirthMinTokens end
    if mode == "Smart" then
        if num("Rebirths") < 5 then return true end -- each of the first 5 adds +0.5x coins
        if S.income <= 0 then return false end
        -- rebirth once the next token would take longer than this run's average per token
        local tNext = (1e6 * 5 ^ k - c) / S.income
        return tNext > (os.clock() - S.lastRebirth) / math.max(k, 1)
    end
    return false
end

function U.rebirth()
    local c = coins()
    log(("rebirthing: %s coins -> %d tokens"):format(compact(c), rebirthTokensFor(c)))
    S.rebirthLock = os.clock() + 15
    call("RebirthRequest")
end

function U.rebirthShop()
    if not due("shop") then return false end
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
                        hold("shop", 60)
                        log("rebirth shop " .. it.label .. ": " .. tostring(msg or res or "no answer"))
                    end
                    return true
                elseif CFG.shopSave then
                    return false
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
    call("DroneEquipRequest", "", "EquipBest")
    return true
end

function U.tick()
    local p = plot()
    if not (p and ready()) then return end
    if CFG.upgrades and CFG.autoBuild and not S.wantBuild and due("build") then
        local kind = U.needsBuild(json("FactoryDataJSON"))
        if kind then S.wantBuild = kind .. " in stock" end
    end
    if S.wantBuild and due("build") then
        -- the farm walks to the pad itself; with it off, walk here
        if not onBase(p) and not CFG.farm and not S.eventBusy then moveTo(U.buildSpot(p), 3, 12) end
        if not U.autoBuild(p, S.wantBuild) and not onBase(p) and not CFG.farm then hold("build", 30) end
    end
    if CFG.rebirthMode ~= "Off" and U.rebirthWanted() then U.rebirth() return end
    if CFG.shop and U.rebirthShop() then return end
    if (CFG.equipBest or (CFG.upgrades and CFG.roll)) and U.equipBest() then return end
    if not CFG.upgrades then return end
    if CFG.upgraderTut and U.upgraderTutorial(p) then return end
    if CFG.factoryBuy and U.factory() then return end
    if CFG.crusher and U.crusher(p) then return end
    if CFG.dumpster and U.dumpster() then return end
    U.coinBoard(p)
end

-- ============================== rewards ==============================
local C = {}

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

-- { quest, progressAttr, claimedAttr } per daily slot
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
        claimed("welcome boost", call("ClaimWelcomeBoost"))
    end
    if CFG.cDaily and A("DailyRewardsReady") and num("DailyNextClaim") <= t and due("daily") then
        hold("daily", 60)
        claimed("daily reward", call("ClaimDailyReward"))
    end
    if CFG.cOffline and num("OfflineCoins") > 0 and due("offline") then
        hold("offline", 30)
        claimed("offline coins (" .. compact(num("OfflineCoins")) .. ")", call("OfflineEarningsAction", "Claim"))
    end
    if CFG.cHourly then
        for _, q in C.activeHourly() do
            local k = q[1]
            if num("Hourly" .. k .. "Progress") >= q[2] and not A("Hourly" .. k .. "Claimed") and due("h" .. k) then
                hold("h" .. k, 60)
                claimed("hourly: " .. q[3], call("ClaimCollect1K", k))
            end
        end
    end
    if CFG.cDailyQuest then
        for _, slot in C.activeDaily() do
            local q = slot[1]
            if num(slot[2]) >= q[2] and not A(slot[3]) and due("d" .. q[1]) then
                hold("d" .. q[1], 60)
                claimed("daily: " .. q[3], call("ClaimDailyQuest", q[1]))
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
            if not (ms[tostring(n)] or ms[n] or table.find(ms, n) or table.find(ms, tostring(n))) then
                if n <= found then
                    if C.indexWait("__milestone", tostring(n)) then
                        S.counts.claims += 1
                        log("index milestone " .. n)
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
            notify("Daily chest needs the game's group (3876902)")
        else
            claimed("daily chest", ok, res, msg)
        end
    end
end

-- ============================== events (own the character while running) ==============================
local E = {}

function E.gemUpgrades()
    if not due("gemUp") then return false end
    local g, gl, ll = gems(), num("EventGemLevel"), num("EventLuckLevel")
    local which, cost
    if gl < 10 then which, cost = "Gems", (gl + 1) * 50 elseif ll < 30 then which, cost = "Luck", (ll + 1) * 100 end
    if not which or g - cost < CFG.gemFloor then return false end
    hold("gemUp", 1)
    local ok, res, msg = call("BuyDiamondUpgrade", which)
    if ok and res ~= false then
        log("event upgrade: " .. which)
    else
        hold("gemUp", 30)
        log("event upgrade: " .. tostring(msg or res))
    end
    return true
end

function E.diamond()
    local st = RS:FindFirstChild("DiamondEventState")
    local live = st and st:GetAttribute("Active") and st:GetAttribute("EventType") == "Diamond"
    local onPf = A("AtDiamondPlatform") == true
    -- the teleport takes a moment to set AtDiamondPlatform
    if S.onPlatform and ((not onPf and os.clock() - (S.joinAt or 0) > 15) or (not live and os.clock() - (S.joinAt or 0) > 180)) then
        S.onPlatform, S.eventBusy = false, false
        log("diamond event over")
        if onPf then call("TeleportToBase") end
    end
    if not (CFG.diamond and live) then return S.onPlatform == true end
    if not onPf then
        if S.onPlatform then return true end
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
    if not S.onPlatform then S.joinAt = os.clock() end -- joined by hand
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

-- Mega Crate rain + meteor crates have no client claim code: use the crate's prompt, else walk onto it
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
    local target, td
    for _, m in list do
        if (S.skip[m] or 0) < os.clock() and (S.dropTries[m] or 0) < 3 then
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
    if not S.dropLogged[target.Name] then -- record how the drop is built (prompt vs touch)
        S.dropLogged[target.Name] = true
        local kinds, parts = {}, {}
        for _, d in target:GetDescendants() do kinds[d.ClassName] = (kinds[d.ClassName] or 0) + 1 end
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
    log("grabbed drop " .. target.Name)
    return true
end

function E.world()
    if not CFG.worldChallenge or A("WorldChallengeRewardClaimed") or not due("world") then return false end
    local wc = workspace:FindFirstChild("WorldChallenge")
    local part = wc and wc:FindFirstChild("RewardPromptPart")
    local pr = part and part:FindFirstChild("ClaimWorldReward")
    if not (pr and pr.Enabled) then return false end
    hold("world", 120)
    S.eventBusy = true
    waitFarmIdle()
    if dist(posOf(part)) > 150 then call("TeleportToShops") task.wait(1.5) end
    if usePrompt(pr, 25) then log("claimed World Challenge reward") end
    task.wait(1)
    call("TeleportToBase")
    task.wait(1.5)
    S.eventBusy = false
    return true
end

function E.crates()
    if not (CFG.upgrades and CFG.roll) or not due("crates") then return false end
    if A("PaidRandomAllowed") ~= true then return false end -- crates hidden for this account (policy)
    local c = CRATES[CFG.crateKind]
    if not c then return false end
    local function balance() return c.cur == "gems" and gems() or tokens() end
    local function batch()
        local n = c.single and 1 or CFG.crateBatch
        if balance() - c.price * n < CFG.crateFloor then n = 1 end
        return balance() - c.price * n >= CFG.crateFloor and n or 0
    end
    -- only travel when a full batch is affordable above the floor
    if balance() - c.price * (c.single and 1 or CFG.crateBatch) < CFG.crateFloor then return false end
    local part = workspace
    for _, name in c.path do part = part and part:FindFirstChild(name) end
    local pos = posOf(part)
    if not pos then log(CFG.crateKind .. " crate not found") hold("crates", 60) return false end
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
        if S.crateDone == "error" or S.crateDone == nil then hold("crates", 60) break end
        opened += n
        if S.stopHit then
            CFG.roll = false
            if S.rollToggle then S.rollToggle:SetValue(false) end
            notify("Auto Roll stopped: " .. (DRONE_NAME[S.stopHit] or S.stopHit) .. "!")
            break
        end
        task.wait(1 + math.random() * 0.4)
    end
    log(("rolled %d crates"):format(opened))
    call("TeleportToBase")
    task.wait(1.5)
    hold("crates", 20)
    S.eventBusy = false
    return true
end

-- ============================== listeners ==============================
local function gotDrone(t)
    local r = RANK[t] or 0
    S.counts.drones += 1
    S.equipDirty = true
    log(("unboxed %s (%s)"):format(DRONE_NAME[t] or tostring(t), RARITY[r] or "?"))
    if r >= 5 and CFG.rareNotify then notify(("%s: %s!"):format(RARITY[r], DRONE_NAME[t] or tostring(t))) end
    if r >= (STOP_RANK[CFG.crateStop] or 99) then S.stopHit = t end
end

local function ev(name) return RS:WaitForChild(name, 10) end

do
    local e = ev("DroneResult")
    if e then on(e.OnClientEvent, function(kind, data)
        if kind == "Unboxed" and type(data) == "table" then
            gotDrone(data.Type)
            S.crateDone = true
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
    if e then on(e.OnClientEvent, function(_, ok, reason) S.dumpRes = { ok = ok, reason = reason } end) end

    e = ev("RebirthResult")
    if e then on(e.OnClientEvent, function(success, msg, count)
        if success then
            S.counts.rebirths += 1
            S.lastRebirth, S.rebirthLock = os.clock(), os.clock() + 5
            S.equipDirty = true
            if CFG.autoBuild then S.wantBuild = "after rebirth" end
            log("rebirth " .. tostring(count))
            notify("Rebirth " .. tostring(count))
        else
            S.rebirthLock = os.clock() + 30
            log("rebirth refused: " .. tostring(msg))
        end
    end) end

    -- FactorySale(plot, cframe components x12, value) is broadcast for every plot
    e = ev("FactorySale")
    if e then on(e.OnClientEvent, function(p, _, _, _, _, _, _, _, _, _, _, _, _, amount)
        if typeof(p) == "Instance" and p.Name == A("PlotName") then
            S.factorySaleSeen = true
            S.sales += tonumber(amount) or 0
        end
    end) end

    e = ev("JunkSoldEvent") -- used until a FactorySale of ours shows up
    if e then on(e.OnClientEvent, function(_, amount)
        if not S.factorySaleSeen then S.sales += tonumber(amount) or 0 end
    end) end

    e = ev("JunkBossEvent")
    if e then on(e.OnClientEvent, function(kind, a, b)
        if kind == "Start" then
            log("boss spawned")
        elseif kind == "Victory" then
            S.counts.bossKills += 1
            log("boss defeated")
        elseif kind == "Reward" then
            log(("boss reward: %s coins, %s gems"):format(compact(a), compact(b)))
            if CFG.eventNotify then notify(("Boss: +%s coins, +%s gems"):format(compact(a), compact(b))) end
        elseif kind == "Failed" then
            log("boss escaped")
        end
    end) end
end

for _, k in { "DroneInventoryJSON", "DroneXPJSON", "DroneSlots", "PaidDroneSlots", "GiftedDroneSlots" } do
    on(LP:GetAttributeChangedSignal(k), function() S.equipDirty = true end)
end

do
    local st = RS:FindFirstChild("DiamondEventState")
    if st then on(st:GetAttributeChangedSignal("Active"), function()
        if not (st:GetAttribute("Active") and CFG.eventNotify) then return end
        if st:GetAttribute("EventType") == "Meteor" then
            notify("Meteor shower started")
        else
            notify(("Diamond event: join closes in %s"):format(clock((st:GetAttribute("JoinEndsAt") or 0) - now())))
        end
    end) end
    local mega = RS:FindFirstChild("MegaCrateEventState")
    if mega then on(mega:GetAttributeChangedSignal("Active"), function()
        if mega:GetAttribute("Active") and CFG.eventNotify then notify("Mega Crate rain started") end
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
    log(("disconnected: code %s · %s"):format(ok and tostring(code) or "?", msg))
    pcall(writefile, LOG_FILE, table.concat(S.log, "\n"))
end)

-- requeue across teleports (rejoins, server hops)
on(LP.OnTeleport, function(state)
    if state == Enum.TeleportState.Started and CFG.rejoin and queue_on_teleport then
        queue_on_teleport(('local ok, src = pcall(readfile, "jc2_main.lua") loadstring(ok and src or game:HttpGet(%q))()')
            :format(SELF_URL))
        log("teleporting, hub queued")
        pcall(writefile, LOG_FILE, table.concat(S.log, "\n"))
    end
end)

-- ============================== lifecycle ==============================
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

local function guard(name, fn)
    local ok, err = pcall(fn)
    if not ok then log(name .. " error: " .. tostring(err)) end
    return ok, err
end

task.spawn(function() -- watchdog: a newer copy took over
    while S.alive do
        if getgenv().CruelHubJC2_TOKEN ~= TOKEN then log("newer copy started, unloading") unload() break end
        task.wait(1)
    end
end)

task.spawn(function() -- farm
    while S.alive do
        if CFG.farm and not S.eventBusy then
            S.farmBusy = true
            local ok, res = guard("farm", F.step)
            S.status = ok and res or "error"
            S.farmBusy = false
            task.wait(0.05)
        else
            S.status = S.eventBusy and "paused for event" or "off"
            task.wait(0.3)
        end
    end
end)

task.spawn(function() -- events, drops, world challenge, crates
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
                if CFG.bossMode == "Disable" and A("JunkBossEnabled") ~= false and due("boss") then
                    hold("boss", 30)
                    call("JunkBossEvent", "SetEnabled", false)
                    log("boss disabled")
                elseif CFG.bossMode == "Kill" then
                    if A("JunkBossEnabled") == false and due("boss") then
                        hold("boss", 30)
                        call("JunkBossEvent", "SetEnabled", true)
                    end
                    local p = plot()
                    local boss = p and p:FindFirstChild("PersonalJunkBoss")
                    if A("JunkBossActive") and boss and (boss:GetAttribute("Health") or 1) > 0 then
                        call("JunkBossEvent", "Click", boss)
                    end
                end
            end)
        end
        task.wait(A("JunkBossActive") and 0.02 or 0.5)
    end
end)

task.spawn(function() -- upgrades, rebirth, drones
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

task.spawn(function() -- income (5-min window of coin gains), housekeeping
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
        if n % 30 == 0 then
            for k in S.skip do if typeof(k) == "Instance" and not k.Parent then S.skip[k] = nil end end
        end
        if S.logDirty and n % 3 == 0 then
            S.logDirty = false
            pcall(writefile, LOG_FILE, table.concat(S.log, "\n"))
        end
        task.wait(1)
    end
end)

-- ============================== UI ==============================
local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local function obsidian(file, remote) -- workspace copy first: a hung HttpGet once jammed the executor
    local path = "BattleBotFarm/lib/" .. file
    local ok, src = pcall(function() return isfile(path) and readfile(path) end)
    return loadstring(ok and src or game:HttpGet(repo .. remote))()
end
Library = obsidian("Library.lua", "Library.lua")
local ThemeManager = obsidian("ThemeManager.lua", "addons/ThemeManager.lua")
local SaveManager  = obsidian("SaveManager.lua", "addons/SaveManager.lua")
notify = function(msg) pcall(function() Library:Notify(msg, 5) end) end

local Window = Library:CreateWindow({
    Title = "CruelHub",
    Icon = (function() -- CruelHub logo, cached; skull if the executor can't load it
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
    Footer = "Junk Crushers 2 · v1.1",
    Size = UDim2.fromOffset(704, 824),
    Center = true, AutoShow = true, ToggleKeybind = Enum.KeyCode.RightControl,
})
if not S.alive or getgenv().CruelHubJC2_TOKEN ~= TOKEN then pcall(Library.Unload, Library) return end

local Tabs = {
    Farm     = Window:AddTab("Farm", "pickaxe"),
    Upgrades = Window:AddTab("Upgrades", "circle-arrow-up"),
    Rebirth  = Window:AddTab("Rebirth", "rotate-ccw"),
    Drones   = Window:AddTab("Drones", "plane"),
    Rewards  = Window:AddTab("Rewards", "gift"),
    Events   = Window:AddTab("Events", "party-popper"),
    Misc     = Window:AddTab("Misc", "map-pin"),
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
local function slider(box, idx, key, text, min, max, suffix, rounding)
    return box:AddSlider(idx, {
        Text = text, Default = CFG[key], Min = min, Max = max, Rounding = rounding or 0, Suffix = suffix,
        Callback = function(v) CFG[key] = v end,
    })
end
local function dropdown(box, idx, key, text, values, tip)
    return box:AddDropdown(idx, {
        Text = text, Tooltip = tip, Values = values, Default = CFG[key],
        Callback = function(v) CFG[key] = v end,
    })
end
local function multi(box, idx, key, text, values, labels)
    local defaults, shown, back = {}, {}, {}
    for _, v in values do
        local l = labels and labels[v] or v
        shown[#shown + 1], back[l] = l, v
        if CFG[key][v] then defaults[#defaults + 1] = l end
    end
    return box:AddDropdown(idx, {
        Text = text, Values = shown, Default = defaults, Multi = true,
        Callback = function(sel)
            local t = {}
            for _, l in shown do t[back[l]] = sel[l] == true end
            CFG[key] = t
        end,
    })
end

local L = {} -- live readouts

-- Farm
do
    local box = Tabs.Farm:AddLeftGroupbox("Auto Farm", "recycle")
    toggle(box, "JC2_Farm", "farm", "Auto Farm")
        :AddKeyPicker("JC2_FarmKey", { Default = "F6", SyncToggleState = true, Mode = "Toggle", Text = "Auto Farm" })
    box:AddDivider()
    toggle(box, "JC2_Pickup", "pickup", "Pick up junk")
    toggle(box, "JC2_Loot", "loot", "Loot dumpster")
    toggle(box, "JC2_Crush", "crush", "Crush junk")
    toggle(box, "JC2_Blocks", "blocks", "Collect blocks")
    toggle(box, "JC2_Unload", "unload", "Unload blocks", "Free Auto Loader")
    if A("AutoLoader") == true then -- pass owners: mirror the game's own switch
        local gl = box:AddToggle("JC2_GameLoader", {
            Text = "Game Auto Loader", Default = A("AutoLoaderDisabled") ~= true,
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
    end
    box:AddDivider()
    slider(box, "JC2_Reach", "reach", "Pickup reach", 10, 46, " studs")
    slider(box, "JC2_CrushMin", "crushMin", "Crush at", 1, 50, " junk")
    slider(box, "JC2_LootIdle", "lootIdle", "Loot when idle", 2, 60, "s")
    box:AddDivider()
    L.farm = box:AddLabel("", true)

    local smelt = Tabs.Farm:AddRightGroupbox("Smelter", "flame")
    toggle(smelt, "JC2_SmeltClaim", "smeltClaim", "Claim rewards")
    toggle(smelt, "JC2_SmeltInput", "smeltInput", "Start batches", "Uses junk you're holding")
    L.smelt = smelt:AddLabel("", true)

    local move = Tabs.Farm:AddRightGroupbox("Movement", "footprints")
    toggle(move, "JC2_FastMove", "fastMove", "Fast move", "Steps instead of walking")
end

-- Upgrades
do
    local box = Tabs.Upgrades:AddLeftGroupbox("Upgrades", "coins")
    toggle(box, "JC2_Upgrades", "upgrades", "Auto Upgrades", "Also runs Auto Build and Auto Roll")
    box:AddDivider()
    multi(box, "JC2_CoinKeys", "coinKeys", "Coin cards", COIN_KEYS, COIN_TEXT)
    dropdown(box, "JC2_CoinOrder", "coinOrder", "Buy order", { "Cheapest first", "Card order" })
    toggle(box, "JC2_Crusher", "crusher", "Crusher speed")
    toggle(box, "JC2_Dumpster", "dumpster", "Dumpster size")
    slider(box, "JC2_Reserve", "reserve", "Keep in reserve", 0, 90, "%")
    box:AddDivider()
    L.up = box:AddLabel("", true)

    local fac = Tabs.Upgrades:AddRightGroupbox("Factory", "factory")
    toggle(fac, "JC2_FactoryBuy", "factoryBuy", "Buy upgraders", "Cheapest missing first")
    toggle(fac, "JC2_AutoBuild", "autoBuild", "Auto Build", "Re-lays out the whole factory")
    toggle(fac, "JC2_UpgraderTut", "upgraderTut", "Upgrader tutorial", "Free Polisher + 2,000 coins")
    fac:AddDivider()
    L.fac = fac:AddLabel("", true)

    local roll = Tabs.Upgrades:AddRightGroupbox("Auto Roll", "dices")
    S.rollToggle = toggle(roll, "JC2_Roll", "roll", "Auto Roll", "Gems / tokens only")
    roll:AddDivider()
    dropdown(roll, "JC2_CrateKind", "crateKind", "Crate", CRATE_KINDS)
    roll:AddDropdown("JC2_CrateBatch", { Text = "Per roll", Values = { "1", "3" }, Default = tostring(CFG.crateBatch),
        Callback = function(v) CFG.crateBatch = tonumber(v) or 1 end })
    slider(roll, "JC2_CrateFloor", "crateFloor", "Keep at least", 0, 50000, "")
    dropdown(roll, "JC2_CrateStop", "crateStop", "Stop at", { "Never", "Legendary", "Mythical", "Exotic", "Akashic", "Secret" })
    roll:AddDivider()
    L.roll = roll:AddLabel("", true)
end

-- Rebirth
do
    local box = Tabs.Rebirth:AddLeftGroupbox("Rebirth", "rotate-ccw")
    dropdown(box, "JC2_RebirthMode", "rebirthMode", "Auto Rebirth", { "Off", "ASAP", "At tokens", "Smart" },
        "Smart: ASAP until 5 rebirths, then when tokens slow down")
    slider(box, "JC2_RebirthTokens", "rebirthMinTokens", "Tokens", 1, 12, "")
    slider(box, "JC2_RebirthMax", "rebirthMax", "Stop at rebirth", 0, 200, "")
    box:AddDivider()
    L.reb = box:AddLabel("", true)

    local shop = Tabs.Rebirth:AddRightGroupbox("Rebirth Shop", "store")
    toggle(shop, "JC2_Shop", "shop", "Auto Rebirth Shop")
    toggle(shop, "JC2_ShopSave", "shopSave", "Save for next item", "Don't skip ahead to cheaper items")
    multi(shop, "JC2_ShopItems", "shopItems", "Buy", SHOP_GROUPS)
    shop:AddDivider()
    L.shop = shop:AddLabel("", true)
end

-- Drones
do
    local box = Tabs.Drones:AddLeftGroupbox("Drones", "plane")
    toggle(box, "JC2_EquipBest", "equipBest", "Auto Equip Best")
    toggle(box, "JC2_RareNotify", "rareNotify", "Notify Mythical+")
    toggle(box, "JC2_ServerRare", "serverRare", "Server rare drops")
    box:AddDivider()
    L.drone = box:AddLabel("", true)
end

-- Rewards
do
    local box = Tabs.Rewards:AddLeftGroupbox("Auto Claim", "gift")
    toggle(box, "JC2_Claims", "claims", "Auto Claim")
    box:AddDivider()
    toggle(box, "JC2_CWelcome", "cWelcome", "Welcome boost")
    toggle(box, "JC2_CDaily", "cDaily", "Daily reward")
    toggle(box, "JC2_COffline", "cOffline", "Offline coins")
    toggle(box, "JC2_CHourly", "cHourly", "Hourly quests")
    toggle(box, "JC2_CDailyQuest", "cDailyQuest", "Daily quests")
    toggle(box, "JC2_CMain", "cMain", "Main quests")
    toggle(box, "JC2_CIndex", "cIndex", "Index entries")
    toggle(box, "JC2_CMilestone", "cMilestone", "Index milestones")
    S.chestToggle = toggle(box, "JC2_CChest", "cChest", "Daily chest", "Needs the game's group")

    L.quests = Tabs.Rewards:AddRightGroupbox("Quests", "list-checks"):AddLabel("", true)
    L.timers = Tabs.Rewards:AddRightGroupbox("Timers", "timer"):AddLabel("", true)
end

-- Events
do
    local boss = Tabs.Events:AddLeftGroupbox("Junk Boss", "skull")
    dropdown(boss, "JC2_BossMode", "bossMode", "Boss", { "Default", "Kill", "Disable" }, "Disable: the farm never pauses")
    L.boss = boss:AddLabel("", true)

    local dia = Tabs.Events:AddLeftGroupbox("Diamond Event", "gem")
    toggle(dia, "JC2_Diamond", "diamond", "Auto Diamond Event")
    toggle(dia, "JC2_GemUp", "gemUpgrades", "Buy event upgrades")
    slider(dia, "JC2_GemFloor", "gemFloor", "Keep gems", 0, 50000, "")

    local drop = Tabs.Events:AddRightGroupbox("Drops", "party-popper")
    toggle(drop, "JC2_Mega", "megaCrates", "Mega Crate rain")
    toggle(drop, "JC2_Meteor", "meteorCrates", "Meteor crates")
    toggle(drop, "JC2_World", "worldChallenge", "World Challenge")
    toggle(drop, "JC2_EventNotify", "eventNotify", "Notifications")
    drop:AddDivider()
    L.event = drop:AddLabel("", true)
end

-- Misc
local function iy(command)
    local root = gethui and gethui() or game:GetService("CoreGui")
    local bar = root:FindFirstChild("Cmdbar", true)
    local input = bar and (bar:IsA("TextBox") and bar or bar:FindFirstChildWhichIsA("TextBox"))
    if not (input and getconnections) then log("IY not loaded: " .. command) return false end
    input.Text = command
    for _, c in getconnections(input.FocusLost) do c:Fire(true) end
    log("IY: " .. command)
    return true
end

do
    local tp = Tabs.Misc:AddLeftGroupbox("Teleport", "map-pin")
    tp:AddButton({ Text = "Base", Func = function() task.spawn(call, "TeleportToBase") end })
    tp:AddButton({ Text = "Shops", Func = function() task.spawn(call, "TeleportToShops") end })
    tp:AddDivider()
    for _, spot in { { "Drone crates", { "DroneShop", "DroneCrate" } }, { "Rebirth shop", { "RebirthShop" } },
        { "Dumpster shop", { "DumpsterShop" } }, { "World Challenge", { "WorldChallenge" } } } do
        tp:AddButton({ Text = spot[1], Func = function()
            task.spawn(function()
                local part = workspace
                for _, n in spot[2] do part = part and part:FindFirstChild(n) end
                local pos = posOf(part)
                if not pos then notify(spot[1] .. " not found") return end
                if dist(pos) > 60 then call("TeleportToShops") task.wait(1.5) end
                moveTo(pos, 8, 25)
            end)
        end })
    end

    -- server-stored settings: mirrored, only written when you change them
    local game_ = Tabs.Misc:AddRightGroupbox("Game Settings", "sliders-horizontal")
    for _, s in { { "Reduce lag", "SettingsReduceLag" }, { "Hide other drones", "SettingsHideOtherDrones" },
        { "Mute music", "SettingsMusicMuted" } } do
        local key = s[2]
        local tg = game_:AddToggle("JC2_" .. key, {
            Text = s[1], Default = A(key) == true,
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

    local iyBox = Tabs.Misc:AddRightGroupbox("Infinite Yield", "terminal")
    toggle(iyBox, "JC2_IySafety", "iySafety", "AFK safety", "staffwatch + noprompts + clearerror",
        function(v) iy(v and "staffwatch\\noprompts\\clearerror" or "unstaffwatch\\showprompts") end)
    toggle(iyBox, "JC2_IyNoRender", "iyNoRender", "No rendering", "CPU saver",
        function(v) iy(v and "norender" or "render") end)
end

-- Status
L.status = Tabs.Status:AddLeftGroupbox("Status", "activity"):AddLabel("", true)
L.log = Tabs.Status:AddRightGroupbox("Log", "scroll-text"):AddLabel("", true)

-- Settings
do
    local box = Tabs.Settings:AddLeftGroupbox("Menu", "menu")
    toggle(box, "JC2_AntiAfk", "antiAfk", "Anti-AFK")
    toggle(box, "JC2_Rejoin", "rejoin", "Reload after teleport")
    slider(box, "JC2_Gap", "gap", "Action spacing", 0.3, 1, "s", 2)
    box:AddDivider()
    box:AddButton({ Text = "Unload", Func = unload })
end

-- ============================== readouts ==============================
local function left(untilT) local s = (tonumber(untilT) or 0) - now() return s > 0 and clock(s) or nil end
local function lv(attr, max) return ("%d/%d"):format(num(attr), max) end

task.spawn(function()
    while S.alive do
        pcall(function()
            local p, t, cnt = plot(), now(), S.counts
            local d = p and F.dumpster(p)
            local c = coins()

            L.farm:SetText(("%s\nDumpster %s/%s · Junk %s\nHolding %d blocks (%s)\nPicked %d · Loots %d · Unloaded %d")
                :format(S.status, compact(d and d:GetAttribute("CurrentCapacity") or 0),
                    d and (d:GetAttribute("InfiniteStorage") and "∞" or compact(d:GetAttribute("MaxCapacity") or 25)) or "?",
                    compact(looted()), held(), compact(carried()), cnt.picks, cnt.loots, cnt.unloads))

            local sm = p and p:FindFirstChild("Smelter")
            L.smelt:SetText(sm and ("%s · %d waiting"):format(sm:GetAttribute("Smelting") and "Smelting" or "Idle",
                sm:GetAttribute("PendingRewards") or 0) or "")

            L.up:SetText(("Rain %d · Speed %s · Clicker %s\nDrone speed %s · Slots %s\nCrusher %s · Dumpster %d · Bought %d")
                :format(num("JunkRainLevel"), lv("RainSpeedLevel", 30), lv("AutoClickerLevel", 16), lv("DroneSpeedLevel", 20),
                    lv("DroneSlots", 3), lv("CrusherSpeedLevel", 4), num("DumpsterLevel"), cnt.buys))

            local data, own = json("FactoryDataJSON"), 0
            for _, u in UPGRADERS do if factoryOwned(data, u[1]) then own += 1 end end
            L.fac:SetText(("Upgraders %d/%d · Sales %s%s"):format(own, #UPGRADERS, compact(S.sales),
                S.wantBuild and "\nAuto Build waiting for base" or ""))

            local cr = CRATES[CFG.crateKind]
            if cr then
                local need = cr.price * (cr.single and 1 or CFG.crateBatch) + CFG.crateFloor
                L.roll:SetText(A("PaidRandomAllowed") ~= true and "Crates disabled for this account"
                    or ("%s %s/%s · Rolled %d"):format(cr.cur == "gems" and "Gems" or "Tokens",
                        compact(cr.cur == "gems" and gems() or tokens()), compact(need), cnt.drones))
            end

            local k = rebirthTokensFor(c)
            L.reb:SetText(("Rebirths %d · x%.1f coins\n%s coins → %d tokens\nNext token at %s")
                :format(num("Rebirths"), 1 + 0.5 * math.min(num("Rebirths"), 5), compact(c), k, compact(1e6 * 5 ^ k)))

            local function mut(id) return A(id .. "Unlocked") and tostring(num(id .. "Level")) or "-" end
            L.shop:SetText(("Tokens %d · Magnet %s · Luck %s\nGold %s · Diamond %s · Atomic %s")
                :format(tokens(), lv("JunkMagnetLevel", 3), lv("DroneLuckLevel", 4), mut("Gold"), mut("Diamond"), mut("Atomic")))

            local inv, eq, owned = json("DroneInventoryJSON"), {}, 0
            for _ in inv do owned += 1 end
            for _, key in { "EquippedDrone", "EquippedDrone2", "EquippedDrone3", "EquippedDrone4", "EquippedDrone5" } do
                local id = A(key)
                if type(id) == "string" and id ~= "" then eq[#eq + 1] = DRONE_NAME[inv[id]] or tostring(inv[id] or id) end
            end
            L.drone:SetText(("Owned %d · Slots %d · Gems %s\n%s")
                :format(owned, num("DroneSlots") + num("PaidDroneSlots") + num("GiftedDroneSlots") + (A("VIP") and 1 or 0),
                    compact(gems()), #eq > 0 and table.concat(eq, "\n") or "Nothing equipped"))

            local ql = {}
            for _, q in C.activeHourly() do
                ql[#ql + 1] = ("%s  %s/%s%s"):format(q[3], compact(num("Hourly" .. q[1] .. "Progress")), compact(q[2]),
                    A("Hourly" .. q[1] .. "Claimed") and " ✓" or "")
            end
            for _, slot in C.activeDaily() do
                local q = slot[1]
                ql[#ql + 1] = ("%s  %d/%d%s"):format(q[3], num(slot[2]), q[2], A(slot[3]) and " ✓" or "")
            end
            local stage = num("MainQuestStage")
            ql[#ql + 1] = stage <= 4 and ("Main quest %d%s"):format(stage, A("MainQuestDone" .. stage) and " ✓" or "") or "Main quests done"
            L.quests:SetText(table.concat(ql, "\n"))

            local tl = {
                "Daily reward  " .. (num("DailyNextClaim") <= t and "ready" or clock(num("DailyNextClaim") - t)),
                "Daily chest  " .. (num("GroupChestNextClaim") <= t and "ready" or clock(num("GroupChestNextClaim") - t)),
                "Hourly reset  " .. clock(3600 - math.floor(t) % 3600),
                "Daily reset  " .. clock((num("DailyQuestDay") + 1) * 86400 - t),
            }
            for _, b in { { "WelcomeBoostUntil", "Welcome 2x" }, { "SmelterCoinBoostUntil", "2x coins" },
                { "SmelterLuckBoostUntil", "2x luck" }, { "DailyCoinBoostUntil", "Daily 2x" } } do
                local l = left(A(b[1]))
                if l then tl[#tl + 1] = b[2] .. "  " .. l end
            end
            L.timers:SetText(table.concat(tl, "\n"))

            local boss = p and p:FindFirstChild("PersonalJunkBoss")
            L.boss:SetText(A("JunkBossActive") and boss
                and ("Boss up · %s/%s HP"):format(compact(boss:GetAttribute("Health")), compact(boss:GetAttribute("MaxHealth")))
                or ("%s · %d/150 · Kills %d"):format(A("JunkBossEnabled") == false and "Off" or "On", num("JunkBossProgress"), cnt.bossKills))

            local st, mega = RS:FindFirstChild("DiamondEventState"), RS:FindFirstChild("MegaCrateEventState")
            local el = {}
            if st and st:GetAttribute("Active") then
                el[#el + 1] = ("%s · %s"):format(tostring(st:GetAttribute("EventType")), tostring(st:GetAttribute("DiamondPhase") or "active"))
            elseif st then
                el[#el + 1] = "Next event  " .. clock((st:GetAttribute("EndsAt") or t) - t)
            end
            if mega and mega:GetAttribute("Active") then el[#el + 1] = "Mega Crate rain now" end
            el[#el + 1] = ("Diamonds %d · Drops %d"):format(cnt.diamonds, cnt.drops)
            L.event:SetText(table.concat(el, "\n"))

            local hours = math.max((os.clock() - S.t0) / 3600, 1 / 60)
            local boosts = {}
            if (tonumber(RS:GetAttribute("AdminGlobalCoinMultiplier")) or 1) > 1 then boosts[#boosts + 1] = "coins x" .. RS:GetAttribute("AdminGlobalCoinMultiplier") end
            if (tonumber(RS:GetAttribute("AdminGlobalLuckMultiplier")) or 1) > 1 then boosts[#boosts + 1] = "luck x" .. RS:GetAttribute("AdminGlobalLuckMultiplier") end
            local sl = {
                "Farm: " .. S.status,
                ("Coins %s · %s/h"):format(compact(c), compact(S.earned / hours)),
                ("Gems %s · Tokens %d · Rebirths %d"):format(compact(gems()), tokens(), num("Rebirths")),
                ("Claims %d · Rolled %d · Sales %s"):format(cnt.claims, cnt.drones, compact(S.sales)),
            }
            if #boosts > 0 then sl[#sl + 1] = "Global boost: " .. table.concat(boosts, ", ") end
            if game.PlaceVersion ~= SPEC_VERSION then sl[#sl + 1] = ("Game updated (v%d), watch the log"):format(game.PlaceVersion) end
            L.status:SetText(table.concat(sl, "\n"))
            L.log:SetText(table.concat(S.log, "\n", math.max(1, #S.log - 13)))
        end)
        task.wait(0.5)
    end
end)

Library:OnUnload(function()
    S.alive = false
    for _, c in S.conns do pcall(function() c:Disconnect() end) end
    if getgenv().CruelHubJC2 == S then getgenv().CruelHubJC2 = nil end
end)

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "JC2_GameLoader", "JC2_SettingsReduceLag", "JC2_SettingsHideOtherDrones", "JC2_SettingsMusicMuted" })
SaveManager:SetFolder(DIR)
ThemeManager:SetFolder(DIR)
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:SetDefaultTheme({ BackgroundColor = "0c0a0b", MainColor = "161214", AccentColor = "e0233c", OutlineColor = "2a1d20", FontColor = "f2eded" }) -- CruelHub look
ThemeManager:ApplyToTab(Tabs.Settings)
if not getgenv().CRUELHUB_SAFEBOOT then SaveManager:LoadAutoloadConfig() end

log(("loaded · %s · v%s"):format(A("PlotName") or "no plot", tostring(game.PlaceVersion)))
Library:Notify("Junk Crushers 2 loaded · RightCtrl menu · F6 farm", 5)
