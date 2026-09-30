--[[
    Fix It Up! (place 72712036210947) — junkyard tiers + auto flip
    UI: Obsidian (deividcomsono)

    Junkyard: every junk car named (the game hides it) + tier by spawn chance, colored billboard + outline,
              sorted list, TP / buy, spawn alerts from the server's "rare car has appeared" message.
    Auto:     buy -> repair -> sell loop with tier / model / price filters and a money reserve.
    Car:      your garage cars: condition, wear per part, spawn here, repair, sell, hood.
    Shop:     spare parts + tools, buy (and install).
    Teleport: every shop, job, garage and player.

    SAFETY: favorited cars (FixItUp/favorites.json, Garage tab > Favorites) are locked: never sold, never touched by auto.
            Auto sell only sells cars this script bought (FixItUp/owned.json). Manual Sell works on any unlocked car.

    Mechanics (measured 2026-09-27, see fix-it-up-spec.md):
      junk car      workspace.Vehicles[*] with Junkyard=true; name hidden, matched by Price/ProfitMultiplier/SpawnChance
                    against ReplicatedStorage.Cache.CarList. ClickDetector (32 studs) -> HUD.Confirmation invoke.
      spawn car     Events.Vehicles.RemoteLoad:InvokeServer(garageEntry, anyCFrame) — server spawns it there.
      remove part   car.PartsEvent:FireServer("RemovePart", slot)   hood open, no distance gate
      repair        part held inside a machine's Detector + click the machine: grinder ~16 s, washer ~10 s, charger ~13 s
      install       car.PartsEvent:FireServer("ReapplyPart", partModel)   no distance gate
      loose parts   the game's client deletes them 90 s after DroppedAt unless inside a NoCleanup zone
      sell          car within ~12 studs of the Used Cars NPC + prompt + confirm; pays BuyPrice * (1 + ProfitMultiplier)
]]

-- newest copy wins: autoexec + the hop reload can both start one; an older copy sees the token change and unloads itself
local HOOK = { token = {} } -- token + confirm hook state in one table (the main chunk is at Luau's 200-local limit)
getgenv().FIU_TOKEN = HOOK.token
if getgenv().FIU_MAIN then pcall(getgenv().FIU_MAIN.unload) end
-- after a server hop this runs from queue_on_teleport, before the game has loaded: wait for what we read at load
if not game:IsLoaded() then game.Loaded:Wait() end
if getgenv().FIU_TOKEN ~= HOOK.token then return end -- a newer copy started while we waited

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local RunService  = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
while not Players.LocalPlayer do task.wait() end
local LP          = Players.LocalPlayer
local Events      = RS:WaitForChild("Events")
local PD          = LP:WaitForChild("PlayerData")
PD:WaitForChild("Loaded", 30)
for _, n in ipairs({ "Map", "Garages", "PartsStore", "Utils", "Vehicles", "MoveableParts" }) do workspace:WaitForChild(n, 30) end
do
    local list = RS:WaitForChild("Cache"):WaitForChild("CarList", 30)
    local t = os.clock() -- the catalog replicates in pieces; names need all of it
    while list and #list:GetChildren() < 100 and os.clock() - t < 15 do task.wait(0.25) end
end
while not workspace.CurrentCamera do task.wait() end
local Status      = PD:WaitForChild("Status")
local Garage      = PD:WaitForChild("Garage")
local Vehicles    = workspace:WaitForChild("Vehicles")
local MoveParts   = workspace:WaitForChild("MoveableParts")
local CONFIRM     = Events.HUD.Confirmation

local DIR = "FixItUp"
pcall(function() if not isfolder(DIR) then makefolder(DIR) end end)
-- load/unload trail across server hops (queued runs have no console)
local function lifeLog(msg)
    pcall(function()
        local p, line = DIR .. "/life.log", os.date("%H:%M:%S ") .. game.JobId:sub(1, 8) .. " " .. msg .. "\n"
        if isfile(p) then appendfile(p, line) else writefile(p, line) end
    end)
end
lifeLog("load")

-- ============================== helpers ==============================
local function money(n)
    n = tonumber(n) or 0
    local a = math.abs(n)
    for _, s in ipairs({ { 1e6, "M" }, { 1e3, "K" } }) do
        if a >= s[1] then return (("€%.1f"):format(n / s[1]):gsub("%.0$", "")) .. s[2] end
    end
    return "€" .. math.floor(n)
end
assert(money(12675) == "€12.7K" and money(3000000) == "€3M" and money(30) == "€30", "money self-check")

local function parsePrice(text) -- "Do you want to buy Ontel Pontus Neta for 9,750€?" -> 9750
    local s = tostring(text):match("for ([%d,%.]+)€")
    return s and tonumber((s:gsub(",", "")))
end
assert(parsePrice("Do you want to buy Ontel Pontus Neta for 9,750€?") == 9750, "parsePrice self-check")
assert(parsePrice("Do you want to sell your Merquis Maibac S650 for 238,061€?") == 238061, "parsePrice self-check 2")

-- sell-timer refusal text is unknown until seen; accept "mm:ss", "X minutes", "X seconds", "Xm Ys"
local function parseWait(text)
    text = tostring(text):lower()
    local m, s = text:match("(%d+):(%d%d)")
    if m then return tonumber(m) * 60 + tonumber(s) end
    local total, found = 0, false
    for n, unit in text:gmatch("(%d+)%s*([hms])") do
        found = true
        total += tonumber(n) * (unit == "h" and 3600 or unit == "m" and 60 or 1)
    end
    return found and total or nil
end
assert(parseWait("wait 4:30") == 270 and parseWait("You must wait 5 minutes") == 300
    and parseWait("2m 10s left") == 130 and parseWait("Car is too far from the sell zone") == nil, "parseWait self-check")

local function readJSON(path, default)
    local ok, t = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
    return ok and type(t) == "table" and t or default
end
local function writeJSON(path, t) pcall(writefile, path, HttpService:JSONEncode(t)) end

local conns, running = {}, true
local function on(sig, f) local c = sig:Connect(f); conns[#conns + 1] = c; return c end

local logLines, logLabel = {}, nil
local function log(msg)
    table.insert(logLines, 1, os.date("%H:%M:%S ") .. msg)
    if #logLines > 14 then table.remove(logLines) end
    if logLabel then pcall(logLabel.SetText, logLabel, table.concat(logLines, "\n")) end
end
local errs = {}
local function guard(name, f, ...)
    local ok, err = pcall(f, ...)
    if not ok and errs[name] ~= err then
        errs[name] = err
        log(name .. " error: " .. tostring(err))
        pcall(function()
            local p, msg = DIR .. "/errors.txt", os.date("%H:%M:%S ") .. name .. ": " .. tostring(err) .. "\n"
            if isfile(p) then appendfile(p, msg) else writefile(p, msg) end
        end)
    end
    return ok
end

-- ============================== config / state ==============================
local TIERS = { "EX", "S", "A", "B", "C", "D" }
local TIER_RANK = {} for i, t in ipairs(TIERS) do TIER_RANK[t] = i end
local TIER_TEXT = { EX = "Exclusive", S = "S ≤0.1%", A = "A ≤1%", B = "B ≤5%", C = "C ≤15%", D = "D >15%" }
local function chanceText(sc) -- spawn chance as the server words it: "3%", "0.02%"; exclusives have none
    sc = tonumber(sc)
    if not sc or sc <= 0 then return "exclusive" end
    return (("%.2f"):format(sc):gsub("%.?0+$", "")) .. "%"
end
assert(chanceText(3) == "3%" and chanceText(0.02) == "0.02%" and chanceText(0.5) == "0.5%" and chanceText(0) == "exclusive", "chanceText self-check")
local function tierOf(sc, exclusive)
    if exclusive or not sc or sc <= 0 then return "EX" end
    if sc <= 0.1 then return "S" elseif sc <= 1 then return "A" elseif sc <= 5 then return "B" elseif sc <= 15 then return "C" end
    return "D"
end
assert(tierOf(0.02) == "S" and tierOf(0.5) == "A" and tierOf(3) == "B" and tierOf(12) == "C" and tierOf(50) == "D" and tierOf(0) == "EX", "tierOf self-check")

local CFG = {
    show = { EX = true, S = true, A = true, B = true, C = true, D = true },
    color = {
        EX = Color3.fromRGB(255, 70, 140), S = Color3.fromRGB(255, 200, 40), A = Color3.fromRGB(190, 90, 255),
        B = Color3.fromRGB(60, 150, 255), C = Color3.fromRGB(80, 220, 110), D = Color3.fromRGB(170, 170, 170),
    },
    esp = true, outline = true, maxDist = 600, textSize = 13, espDetail = true,
    alerts = true, alertMin = "B",
    -- auto flip: everything off until the player (or SaveManager autoload) turns it on
    autoBuy = false, autoRepair = false, autoSell = false,
    buyMinTier = "C", buySettle = 3.5, buyBy = "Tier", buyMaxPct = 1, buyModels = {}, buyMaxPrice = 60000, buyMinProfit = 0,
    contestOn = false, contestRadius = 40, snipeTier = "A", -- leave a car to a player standing at it, unless it's this rare
    reserve = 20000,
    repairMin = 1, replaceWorn = true, station = "Dealership",
    sellCooldown = 0, -- seconds; 0 = learn it from the server's refusal
    bringCar = false, walkSpeed = 16, speedOn = false, antiAfk = true,
    cleanAfter = false, paintAfter = false, paintRandom = false, paintMaterial = "Normal", paintColor = Color3.fromRGB(30, 90, 220),
    homeAfterTp = false, aucCount = 1, aucBudget = 75000, aucFloor = 300000, aucStopRare = true, aucMode = "Total spend", autoLock = false, autoLockTier = "A", autoLockModels = {}, autoLockPctOn = false, autoLockPct = 0.5,
    driveSpeed = 85, driveExtra = 2, driveNoLimit = false, farmYield = false, driveRoute = "Highway", swapOld = "Store in inventory",
    playerEsp = false, playerCarTitles = true, playerOutline = false, playerMaxDist = 2000, playerColor = Color3.fromRGB(255, 255, 255),
}
local STATE = readJSON(DIR .. "/state.json", {})
local OWNED = readJSON(DIR .. "/owned.json", {}) -- [garage GUID] = { model, boughtAt } — the ONLY sellable cars
if STATE.sellCooldown then CFG.sellCooldown = STATE.sellCooldown end
local FAV = readJSON(DIR .. "/favorites.json", {}) -- [garage GUID] = model name — locked by the player
local function saveOwned() writeJSON(DIR .. "/owned.json", OWNED) end
local function saveFav() writeJSON(DIR .. "/favorites.json", FAV) end
local function saveState() STATE.sellCooldown = CFG.sellCooldown; writeJSON(DIR .. "/state.json", STATE) end

local function myMoney() return tonumber(Status.Money.Value) or 0 end -- the game stores it as text: comparing it crashed refuel

-- ============================== confirm + notify hooks ==============================
-- The game's HUD script (PlayerGui.HUD...ConfirmationClient) sets OnClientInvoke itself, and sets it AGAIN when the HUD
-- rebuilds (respawn, and after a hop where we load first). That silently replaced our hook, so script buys/sells never
-- saw their prompt ("server never offered the car"). hookConfirm() re-installs every second and adopts the game's
-- newest callback as the pass-through. FIU_HOOKS marks every copy's hook so one is never mistaken for the game's.
getgenv().FIU_HOOKS = getgenv().FIU_HOOKS or setmetatable({}, { __mode = "k" })
HOOK.orig = getgenv().FIU_ORIG_CONFIRM
local confirmFn, lastConfirm = nil, nil -- confirmFn(text) -> bool while the script is buying/selling
function HOOK.fn(text, ...)
    lastConfirm = { t = os.clock(), text = tostring(text) }
    if confirmFn then return confirmFn(tostring(text)) == true end
    -- the game's own sell prompt (you at the NPC): never let it sell a locked car
    local selling = tostring(text):match("sell your (.-) for [%d,]+")
    if selling and getgenv().FIU_MAIN and getgenv().FIU_MAIN.lockedAtNpc and getgenv().FIU_MAIN.lockedAtNpc(selling) then
        task.defer(function() pcall(function() getgenv().FIU_MAIN.lib():Notify(selling .. " is locked: sale blocked", 6) end) end)
        return false
    end
    if HOOK.orig then return HOOK.orig(text, ...) end
    return false -- the game's dialog isn't set up yet: decline rather than hang
end
getgenv().FIU_HOOKS[HOOK.fn] = true
function HOOK.install()
    local cur = getcallbackvalue(CONFIRM, "OnClientInvoke")
    if cur == HOOK.fn then return end
    if cur and not getgenv().FIU_HOOKS[cur] then HOOK.orig = cur; getgenv().FIU_ORIG_CONFIRM = cur end
    CONFIRM.OnClientInvoke = HOOK.fn
end
HOOK.install()

-- declared up here: buyJunk (auto-lock message) calls it long before the UI section sets it to Library:Notify.
-- It used to be declared below buyJunk, so a rare auto-locked buy crashed on a nil global (errors.txt ":931").
local notify = function() end
local lastNotify = { t = 0, text = "" }
on(Events.HUD.Notifiy.OnClientEvent, function(text) lastNotify = { t = os.clock(), text = tostring(text) } end)

-- ============================== car catalog (hidden junk names) ==============================
local CATALOG = {} -- key -> { names }
local CAT_NAMES = {}
local function catKey(price, pm, sc)
    if typeof(price) ~= "NumberRange" then return nil end
    return ("%d|%d|%.4f|%.4f"):format(price.Min, price.Max, tonumber(pm) or -1, tonumber(sc) or -1)
end
for _, c in ipairs(RS.Cache.CarList:GetChildren()) do
    local k = catKey(c:GetAttribute("Price"), c:GetAttribute("ProfitMultiplier"), c:GetAttribute("SpawnChance"))
    if k then
        CATALOG[k] = CATALOG[k] or {}
        table.insert(CATALOG[k], c.Name)
        if (c:GetAttribute("SpawnChance") or 0) > 0 then CAT_NAMES[#CAT_NAMES + 1] = c.Name end
    end
end
table.sort(CAT_NAMES)

local function junkInfo(m)
    local price, pm, sc = m:GetAttribute("Price"), m:GetAttribute("ProfitMultiplier") or 0, m:GetAttribute("SpawnChance")
    local names = CATALOG[catKey(price, pm, sc)]
    local excl = m:GetAttribute("ExclusivePrice") ~= nil
    local name = names and table.concat(names, " / ") or (excl and "Exclusive car" or "Unknown car")
    local lo, hi = price and price.Min or 0, price and price.Max or 0
    return { model = m, name = name, names = names or {}, tier = tierOf(sc, excl), sc = sc or 0, pm = pm,
        lo = lo, hi = hi, profitLo = lo * pm, profitHi = hi * pm, exclusive = excl }
end

-- ============================== movement ==============================
local function char() return LP.Character end
local function hrp() local c = char(); return c and c:FindFirstChild("HumanoidRootPart") end
local function hum() local c = char(); return c and c:FindFirstChildOfClass("Humanoid") end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local function ground(pos) -- floor under pos, cast from just above so roofs don't catch it
    rayParams.FilterDescendantsInstances = { char(), Vehicles, MoveParts }
    local hit = workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -60, 0), rayParams)
    return hit and hit.Position + Vector3.new(0, 3, 0) or pos + Vector3.new(0, 3, 0)
end

-- RequestStreamAroundAsync can stop answering for the rest of a session, timeout arg or not (2026-09-29 from 11:27:
-- every call hung for good; it froze auto at the sell NPC, then waiting out a timeout per call doubled repair times).
-- The request itself still works: the far sell prompt loaded 0.2 s after one (measured), only the answer never comes.
-- So after one timeout, keep sending it but wait a short moment instead of the full timeout. Skipping it outright
-- broke selling from home ("sell NPC not loaded"). Callers wait for the parts they need themselves.
local streamAt
do -- the main chunk is at Luau's 200-local limit: new top-level helpers go in do-blocks or tables
    local jammed = false
    function streamAt(pos, timeout)
        local done = false
        task.spawn(function() pcall(function() LP:RequestStreamAroundAsync(pos, timeout) end); done = true; jammed = false end)
        -- ponytail: 0.5 s settle while jammed (0.2 s measured for the sell prompt); a bigger area may need longer
        local t, limit = os.clock(), jammed and math.min(timeout, 0.5) or timeout
        repeat task.wait() until done or os.clock() - t > limit
        if not done then jammed = true end
    end
end

local function tpTo(target) -- CFrame or Vector3
    local h = hum()
    if h and h.SeatPart then -- a seated character drags the car along or snaps back: get out first
        local t = os.clock()
        repeat
            h.Sit = false
            h:ChangeState(Enum.HumanoidStateType.Jumping)
            task.wait(0.1)
        until not h.SeatPart or os.clock() - t > 2
        task.wait(0.15)
    end
    local r = hrp()
    if not r then return false end
    local cf = typeof(target) == "Vector3" and CFrame.new(target) or target
    -- ponytail: 64 = Roblox's default StreamingMinRadius (the game's value isn't readable from the client); hops
    -- inside it (machine to machine, hood re-stands) are already loaded
    if (cf.Position - r.Position).Magnitude > 64 then streamAt(cf.Position, 3) end
    r.AssemblyLinearVelocity, r.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
    char():PivotTo(cf)
    CFG.lastTp = os.clock() -- "Return after tp" goes home only after actions that moved you
    return true
end

-- ============================== garage ==============================
local function garageSlots()
    local g = workspace.Garages:FindFirstChild(tostring(PD:FindFirstChild("GarageModel") and PD.GarageModel.Value or "Default"))
    local cp = g and g:FindFirstChild("CarPositions")
    return cp and #cp:GetChildren() or 2
end
local function entries() return Garage:GetChildren() end
local function entryModel(e) local v = e:FindFirstChild("Model"); return v and v.Value or "?" end
local function entryVal(e, n) local v = e:FindFirstChild(n); return v and v.Value end
local function carOf(e) return Vehicles:FindFirstChild(e.Name) end
-- always the car's current instance: a respawn mid-job destroys the one we started with
local function fireParts(e, ...)
    local c = carOf(e)
    local pe = c and (c:FindFirstChild("PartsEvent") or c:WaitForChild("PartsEvent", 3))
    if pe then pe:FireServer(...) return true end
    log("car not loaded: " .. entryModel(e))
    return false
end
-- the hood ClickDetector only reaches 10 studs: stand just outside the hood, away from the car's middle
local function hoodSpot(car)
    local det = car:FindFirstChild("Misc") and car.Misc:FindFirstChild("Hood") and car.Misc.Hood:FindFirstChild("Detector")
    if not det then return car:GetPivot() * CFrame.new(0, 2, -8) end
    local out = det.Position - car:GetPivot().Position
    out = Vector3.new(out.X, 0, out.Z)
    out = out.Magnitude > 0.1 and out.Unit or Vector3.new(0, 0, -1)
    return CFrame.lookAt(det.Position + out * 4 + Vector3.new(0, 1, 0), det.Position)
end
local function isFav(e) return FAV[e.Name] ~= nil end
-- auto lock: a car the script bought that is rare enough (or a picked model) becomes a favorite, so it's never sold
local TIER_ORDER = { EX = 1, S = 2, A = 3, B = 4, C = 5, D = 6 }
local function modelTier(model)
    local cat = RS.Cache.CarList:FindFirstChild(tostring(model))
    local sc = cat and cat:GetAttribute("SpawnChance")
    if not sc or sc <= 0 then return "EX" end
    if sc <= 0.1 then return "S" elseif sc <= 1 then return "A" elseif sc <= 5 then return "B" elseif sc <= 15 then return "C" end
    return "D"
end
local function maybeAutoLock(e)
    if not (CFG.autoLock or CFG.autoLockPctOn) or FAV[e.Name] or not OWNED[e.Name] then return false end
    local mv = e:FindFirstChild("Model")
    local model = mv and mv.Value
    if not model then return false end
    local tier = modelTier(model)
    local cat = RS.Cache.CarList:FindFirstChild(tostring(model))
    local sc = cat and cat:GetAttribute("SpawnChance")
    local byTier = CFG.autoLock and (CFG.autoLockModels[model] or TIER_ORDER[tier] <= TIER_ORDER[CFG.autoLockTier])
    local byPct = CFG.autoLockPctOn and sc ~= nil and sc <= CFG.autoLockPct
    if byTier or byPct then
        FAV[e.Name] = model
        saveFav()
        log(("auto-locked [%s] %s"):format(tier, model))
        return true
    end
    return false
end
local function isFlip(e) return OWNED[e.Name] ~= nil and not isFav(e) end

local function condition(car)
    local eng = car and car:FindFirstChild("Values") and car.Values:FindFirstChild("Engine")
    if not eng then return nil end
    local sum, n = 0, 0
    for _, v in ipairs(eng:GetChildren()) do
        if v:IsA("StringValue") and v.Value ~= "" and eng.Wear:FindFirstChild(v.Name) then
            sum += eng.Wear[v.Name].Value; n += 1
        end
    end
    return n > 0 and 100 - math.round(sum / n) or 100
end

-- server spawns the car at cf (the old instance is replaced); returns the new instance
local function spawnCar(e, cf)
    -- the server sometimes won't move a car (seen right after buying one at the junkyard): check it really arrived
    -- near cf and retry; never hand back a car that is still somewhere else
    local function ready(c)
        return c and c:FindFirstChild("PartsEvent") and c:FindFirstChild("Values") and c.Values:FindFirstChild("Engine")
    end
    streamAt(cf.Position, 5) -- a car spawned out of streaming range arrives empty
    for try = 1, 3 do
        local ok, err = pcall(function() Events.Vehicles.RemoteLoad:InvokeServer(e, cf) end)
        if not ok then log("spawn failed: " .. tostring(err)) end
        local t = os.clock()
        repeat
            local c = carOf(e)
            if ready(c) and (c:GetPivot().Position - cf.Position).Magnitude < 40 then task.wait(0.5); return c end
            task.wait(0.2)
        until os.clock() - t > 4
        task.wait(1.5 * try)
    end
    log(("the server wouldn't move %s there"):format(entryModel(e)))
    return nil
end

local function sellCooldownLeft(e)
    if CFG.sellCooldown <= 0 then return 0 end
    local bought = tonumber(entryVal(e, "BoughtAt")) or 0
    return math.max(0, bought + CFG.sellCooldown - os.time())
end

-- ============================== machines ==============================
-- repair shops: 4 buildings with Station1..N machine folders (both small Pitstops share one name, told apart by position)
local ST = {
    order = { "Dealership", "Pitstop (large)", "Pitstop (small) south", "Pitstop (small) west" },
    at = {
        Dealership = Vector3.new(-511, 14, -779),
        ["Pitstop (large)"] = Vector3.new(-1048, 25, -389),
        ["Pitstop (small) south"] = Vector3.new(-557, 15, -1617),
        ["Pitstop (small) west"] = Vector3.new(-1130, 15, -1546.5),
    },
    building = { Dealership = "Dealership", ["Pitstop (large)"] = "Pitstop(Large)", ["Pitstop (small) south"] = "Pitstop(Small)", ["Pitstop (small) west"] = "Pitstop(Small)" },
    quiet = { t = 0 },
}
function ST.root(name)
    local at, bname = ST.at[name], ST.building[name]
    local function find()
        for _, b in ipairs(workspace.Map.FirstCity.Buildings:GetChildren()) do
            if b.Name == bname and (b:GetPivot().Position - at).Magnitude < 150 then
                return name == "Dealership" and b:FindFirstChild("Folder") or b
            end
        end
    end
    local r = find()
    if not r then streamAt(at, 5); r = find() end
    return r
end
-- "Quietest": the shop with the fewest other players within 80 studs, re-picked at most every 90 s so a repair stays put
-- ponytail: players streamed out of range aren't seen, so a far shop can look emptier than it is
function ST.name()
    local n = CFG.station == "Pitstop" and "Pitstop (large)" or CFG.station -- old saved name
    if n ~= "Quietest" then return ST.at[n] and n or "Dealership" end
    if ST.quiet.name and os.clock() - ST.quiet.t < 90 then return ST.quiet.name end
    local best, bestN
    for _, s in ipairs(ST.order) do
        local c = 0
        for _, p in ipairs(Players:GetPlayers()) do
            local r = p ~= LP and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
            if r and (r.Position - ST.at[s]).Magnitude < 80 then c += 1 end
        end
        if not bestN or c < bestN then best, bestN = s, c end
    end
    ST.quiet.name, ST.quiet.t = best, os.clock()
    return best
end
local function stationRoot() return ST.root(ST.name()) or ST.root("Dealership") end

-- where the car goes for a repair: open floor, not up on a lift (Dealership spot picked by the player)
local FLOOR_SPOT = { Dealership = Vector3.new(-533.6, 4.8, -799.0) }
local function liftCF()
    local root = stationRoot()
    local lift = root:FindFirstChild("Lift")
    if not lift and root:FindFirstChild("Lifts") then -- Pitstops have several: take one with nobody else's car on it
        local first
        for _, l in ipairs(root.Lifts:GetChildren()) do
            if l.Name == "Lift" then
                first = first or l
                local taken = false
                for _, v in ipairs(Vehicles:GetChildren()) do
                    if v:GetAttribute("Owner") ~= LP.Name and (v:GetPivot().Position - l:GetPivot().Position).Magnitude < 8 then taken = true break end
                end
                if not taken then lift = l break end
            end
        end
        lift = lift or first
    end
    local rot = lift and lift:GetPivot().Rotation or CFrame.identity
    local spot = FLOOR_SPOT[ST.name()]
    if spot then return CFrame.new(spot) * rot end
    if lift then return lift:GetPivot() * CFrame.new(0, 4, 0) end
    return CFrame.new(-563.4, 11, -799.9)
end

local function partInBox(box, pos)
    local p = box.CFrame:PointToObjectSpace(pos)
    local h = box.Size * 0.5
    return math.abs(p.X) <= h.X and math.abs(p.Y) <= h.Y + 1 and math.abs(p.Z) <= h.Z
end

local function machines()
    local root = stationRoot()
    streamAt(liftCF().Position, 5)
    local list = {}
    for _, st in ipairs(root:GetChildren()) do
        if st.Name:match("^Station") then
            for _, m in ipairs(st:GetChildren()) do
                local det = m:FindFirstChild("Detector") or m:WaitForChild("Detector", 1)
                local cd = m:FindFirstChildWhichIsA("ClickDetector", true)
                if det and cd then
                    local busy = false -- someone else's part already in it
                    for _, p in ipairs(MoveParts:GetChildren()) do
                        if p:GetAttribute("Owner") ~= LP.Name and p:IsA("Model") and partInBox(det, p:GetPivot().Position) then busy = true break end
                    end
                    if not busy then list[#list + 1] = { kind = m.Name, det = det, cd = cd, model = m } end
                end
            end
        end
    end
    return list
end

local function holdCF(m)
    local bp = m.det:FindFirstChild("BatteryPosition")
    return bp and bp.WorldCFrame or m.det.CFrame
end

-- ============================== store ==============================
local SPARE = workspace.PartsStore.SpareParts
local function storeModel(category, partName)
    local cat = SPARE.Parts:FindFirstChild(category)
    return cat and cat:FindFirstChild(partName)
end

local function myParts()
    local t = {}
    for _, p in ipairs(MoveParts:GetChildren()) do if p:GetAttribute("Owner") == LP.Name then t[p] = true end end
    return t
end

-- buys one store item; returns the new MoveableParts model (parts) or true (tools)
local function buyStore(model, isTool)
    if not model or not model:FindFirstChild("ClickDetector") then return nil, "not in store" end
    local price = tonumber(model:GetAttribute("Price")) or 0
    if myMoney() - price < CFG.reserve then return nil, "reserve" end
    local before = myParts()
    local asked = false
    confirmFn = function(text) asked = true; local p = parsePrice(text); return p ~= nil and myMoney() - p >= CFG.reserve end
    -- store clicks work from anywhere (measured 450 studs); only hop over if the server doesn't answer
    fireclickdetector(model.ClickDetector)
    local t0 = os.clock()
    repeat task.wait(0.05) until asked or os.clock() - t0 > 1.5
    if not asked then
        local back = hrp() and hrp().CFrame
        tpTo(CFrame.new(model:GetPivot().Position + Vector3.new(0, 2, 5)))
        task.wait(0.2)
        fireclickdetector(model.ClickDetector)
        t0 = os.clock()
        repeat task.wait(0.05) until asked or os.clock() - t0 > 2
        if back then tpTo(back) end
    end
    local found, t = nil, os.clock()
    repeat
        task.wait(0.1)
        if not isTool then
            for p in pairs(myParts()) do if not before[p] then found = p end end
        end
    until found or os.clock() - t > (isTool and 2 or 5)
    confirmFn = nil
    if isTool then return asked or nil end
    if found then task.wait(0.3) end
    return found, not asked and "no confirm" or nil
end

-- ============================== repair ==============================
-- manualPending: a button is waiting for its turn. Auto starts nothing new, and the distance farm (which holds busy
-- the whole time it drives) steps out until the button is done.
local busy, busyWhat, manualPending = false, nil, false
local INSTALL_FIRST = { EngineBlock = 1 }

local function repairCar(e)
    log(("repairing %s at %s"):format(entryModel(e), ST.name()))
    tpTo(liftCF() * CFrame.new(0, 0, 12)) -- be there first so the car streams in with you
    local car = spawnCar(e, liftCF())
    if not car then return false, "spawn failed" end
    local eng, wear = car.Values.Engine, car.Values.Engine.Wear
    tpTo(hoodSpot(car))
    task.wait(0.4)
    -- IsHoodOpen only exists once the hood has been used on this spawn
    local function hoodOpen() local v = car.Values.Cache:FindFirstChild("IsHoodOpen"); return v ~= nil and v.Value end
    -- a fresh spawn needs a moment before its hood takes clicks; 10-stud range, so re-stand each try
    local hood = car:WaitForChild("Misc", 5) and car.Misc:WaitForChild("Hood", 5)
    local det = hood and hood:WaitForChild("Detector", 5)
    local cd = det and det:FindFirstChildWhichIsA("ClickDetector")
    -- measured 2026-09-28: a freshly spawned car ignores hood clicks for ~4.5 s, so keep clicking for up to 10 s
    if cd and not hoodOpen() then
        tpTo(hoodSpot(car))
        local t = os.clock()
        repeat
            fireclickdetector(cd)
            task.wait(0.5)
            if not hoodOpen() and os.clock() - t > 3 then tpTo(hoodSpot(car)) end -- re-stand in case the car shifted
        until hoodOpen() or os.clock() - t > 10
    end
    if not hoodOpen() then return false, "couldn't open the hood" end

    -- slots to pull: installed, worn, and either repairable or replaceable
    local bay = car.Body:FindFirstChild("EngineBay")
    local pull = {}
    for _, v in ipairs(eng:GetChildren()) do
        local w = wear:FindFirstChild(v.Name)
        if v:IsA("StringValue") and v.Value ~= "" and w and w.Value >= CFG.repairMin then
            local bm = bay and bay:FindFirstChild(v.Name)
            if bm and (bm:GetAttribute("RepairMachine") or CFG.replaceWorn) then pull[#pull + 1] = v.Name end
        end
    end
    if #pull == 0 then return true, "nothing to repair" end

    local before = myParts()
    for _, slot in ipairs(pull) do
        if eng[slot].Value ~= "" then fireParts(e, "RemovePart", slot); task.wait(0.3) end
    end
    task.wait(1)
    -- everything that came off, including parts the engine block dragged along
    local parts = {}
    for p in pairs(myParts()) do if not before[p] then parts[#parts + 1] = p end end

    local jobs, installs, pinned = {}, {}, {}
    local pin = on(RunService.Heartbeat, function()
        for p, cf in pairs(pinned) do
            if p.Parent then
                p:PivotTo(cf)
                p:SetAttribute("DroppedAt", nil) -- the game's own client deletes loose parts 90 s after this
                for _, b in ipairs(p:GetDescendants()) do
                    if b:IsA("BasePart") then b.AssemblyLinearVelocity = Vector3.zero; b.AssemblyAngularVelocity = Vector3.zero end
                end
            end
        end
    end)
    local parkCF = car:GetPivot() * CFrame.new(0, 6, 0) -- non-machine parts wait above the car
    for _, p in ipairs(parts) do
        local w, rm = p:GetAttribute("Wear") or 0, p:GetAttribute("RepairMachine")
        if w >= CFG.repairMin and rm then
            jobs[#jobs + 1] = { part = p, kind = rm }
        elseif w >= CFG.repairMin and CFG.replaceWorn then
            local sm = storeModel(p:GetAttribute("Category") or "", p:GetAttribute("PartName") or p.Name)
            local new, why = buyStore(sm)
            if new then
                if OWNED[e.Name] then OWNED[e.Name].parts = (OWNED[e.Name].parts or 0) + (tonumber(sm and sm:GetAttribute("Price")) or 0) end
                installs[#installs + 1] = new
                pinned[new] = parkCF
                Events.PartsEvent:FireServer("DeletePart", p)
                log(("replaced %s (wear %d)"):format(p.Name, w))
            else
                installs[#installs + 1] = p; pinned[p] = parkCF
                log(("couldn't replace %s: %s"):format(p.Name, tostring(why)))
            end
        else
            installs[#installs + 1] = p; pinned[p] = parkCF
        end
    end

    -- machine batches
    local pending = jobs
    while #pending > 0 do
        local free, batch, rest = machines(), {}, {}
        local used = {}
        for _, j in ipairs(pending) do
            local pick
            for i, m in ipairs(free) do if not used[i] and m.kind == j.kind then pick = i break end end
            if pick then used[pick] = true; j.m = free[pick]; batch[#batch + 1] = j; pinned[j.part] = holdCF(j.m)
            else rest[#rest + 1] = j end
        end
        if #batch == 0 then log("no free machine for " .. #rest .. " part(s)"); for _, j in ipairs(rest) do installs[#installs + 1] = j.part end break end
        task.wait(0.8)
        for _, j in ipairs(batch) do -- click range is 10-14 studs: stand at each machine
            tpTo(CFrame.new(j.m.cd.Parent:GetPivot().Position + Vector3.new(0, 2, 0)) * CFrame.new(0, 0, 3))
            task.wait(0.25)
            fireclickdetector(j.m.cd)
        end
        local t, reclicked = os.clock(), false
        repeat
            task.wait(0.5)
            local left = 0
            for _, j in ipairs(batch) do if j.part.Parent and (j.part:GetAttribute("Wear") or 0) > 0 then left += 1 end end
            busyWhat = ("repairing %s: %d/%d parts in machines"):format(entryModel(e), #batch - left, #batch)
            if left == 0 then break end
            if not reclicked and os.clock() - t > 22 then
                reclicked = true
                for _, j in ipairs(batch) do
                    if (j.part:GetAttribute("Wear") or 0) > 0 then tpTo(CFrame.new(j.m.cd.Parent:GetPivot().Position + Vector3.new(0, 2, 3))); task.wait(0.2); fireclickdetector(j.m.cd) end
                end
            end
        until os.clock() - t > 45
        for _, j in ipairs(batch) do installs[#installs + 1] = j.part; pinned[j.part] = parkCF end
        pending = rest
    end

    -- install: block and gearbox first
    local function rank(p) return INSTALL_FIRST[p.Name] or (p:GetAttribute("Category") == "Transmission" and 2) or 9 end
    table.sort(installs, function(a, b) return rank(a) < rank(b) end)
    for pass = 1, 2 do
        for _, p in ipairs(installs) do
            if p.Parent == MoveParts then fireParts(e, "ReapplyPart", p); task.wait(0.3) end
        end
        task.wait(0.8)
    end
    pin:Disconnect()
    local left = 0
    for _, p in ipairs(installs) do if p.Parent == MoveParts then left += 1 end end
    return left == 0, ("%s condition %s%%%s"):format(entryModel(e), tostring(condition(car)), left > 0 and (" · " .. left .. " part(s) not installed") or "")
end

-- ============================== clean / paint ==============================
-- both need the car inside the shop's Detector box; RemoteLoad drops it straight in
local function inBox(det) return CFrame.new(det.Position.X, det.Position.Y - det.Size.Y / 2 + 3, det.Position.Z) * det.CFrame.Rotation end

-- nearest car wash with nobody else's car in its bay (a car already there would collide and take the prompt)
local function freeWash(e)
    local r = hrp()
    local from = r and r.Position or Vector3.zero
    local washes = workspace.Map.CarWashes:GetChildren()
    table.sort(washes, function(a, b) return (a:GetPivot().Position - from).Magnitude < (b:GetPivot().Position - from).Magnitude end)
    for _, w in ipairs(washes) do
        streamAt(w:GetPivot().Position, 5)
        local det = w:FindFirstChild("Detector") or w:WaitForChild("Detector", 3)
        local taken = false
        for _, v in ipairs(det and Vehicles:GetChildren() or {}) do
            if v.Name ~= e.Name and partInBox(det, v:GetPivot().Position) then taken = true break end
        end
        if det and not taken then return w, det end
    end
end

local function cleanCar(e)
    local wash, det = freeWash(e)
    if not wash then return false, "no free car wash (all taken or not loaded)" end
    local backMe, oldCar = hrp() and hrp().CFrame, carOf(e)
    local backCar = oldCar and oldCar:GetPivot()
    -- standing next to the car (prompt, washing) touched its seats and sat you down mid-wash: no sitting until done
    local sitHum = hum()
    if sitHum then sitHum.Sit = false; sitHum:SetStateEnabled(Enum.HumanoidStateType.Seated, false) end
    local function restore()
        if sitHum then sitHum:SetStateEnabled(Enum.HumanoidStateType.Seated, true) end
        if backCar then spawnCar(e, backCar + Vector3.new(0, 2, 0)) end
        if backMe then tpTo(backMe) end
    end
    local car = spawnCar(e, inBox(det))
    if not car then restore(); return false, "spawn failed" end
    local dirt = car.Values:FindFirstChild("DirtLevel")
    if dirt and dirt.Value <= 0 then restore(); return true, entryModel(e) .. " is already clean" end
    local prompt = wash:FindFirstChild("Prompt")
    local pp = prompt and prompt:FindFirstChildWhichIsA("ProximityPrompt")
    if not pp then restore(); return false, "car wash prompt not loaded" end
    tpTo(CFrame.new(prompt.Position + Vector3.new(0, 1, 3)))
    task.wait(0.3) -- the prompt's 10-stud range is checked where the server thinks you are
    -- "Grab Pressure Wash" only switches on once the server sees your car in the bay (~0.8 s after the spawn,
    -- measured 2026-09-29): wait for it, and press again if no washer arrives. SetDirt is ignored without one.
    local function washer() return LP.Backpack:FindFirstChild("PressureWasher") or (char() and char():FindFirstChild("PressureWasher")) end
    local tool = washer()
    for _ = 1, 3 do
        if tool then break end
        local t = os.clock()
        repeat task.wait(0.1) until pp.Enabled or os.clock() - t > 3
        fireproximityprompt(pp)
        t = os.clock()
        repeat task.wait(0.1); tool = washer() until tool or os.clock() - t > 2
    end
    if not tool then restore(); return false, "the car wash didn't hand over a pressure washer" end
    local h = hum()
    if h then h:EquipTool(tool) end
    tpTo(car:GetPivot() * CFrame.new(5, 1, 0))
    local start = dirt and dirt.Value or 100
    for i = 1, 40 do -- 10 s at 4 Hz, the same curve the game's washer sends
        Events.Vehicles.SetDirt:FireServer(start * (1 - i / 40))
        task.wait(0.25)
        if dirt and dirt.Value <= 0 then break end
    end
    if h then h:UnequipTools() end
    task.wait(0.5)
    local left = dirt and dirt.Value or 0
    restore()
    return left <= 1, ("%s dirt %d%%"):format(entryModel(e), math.floor(left))
end

local MATERIALS = { "Normal", "Shiny", "Matte", "Aluminum", "Metallic" }
local function paintCar(e, color, material)
    local mat = RS.Assets.CarMaterials:FindFirstChild(material)
    local price = mat and mat:GetAttribute("Price") or 0
    if myMoney() - price < CFG.reserve then return false, "reserve" end
    local booth = workspace.Map.FirstCity.Buildings["Pitstop(Large)"].Model:FindFirstChild("CarPaint")
    if not booth then return false, "paint booth not found" end
    streamAt(booth:GetPivot().Position, 5)
    local det = booth:FindFirstChild("Detector") or booth:WaitForChild("Detector", 3)
    if not det then return false, "paint booth not loaded" end
    -- afterwards the car goes back where it was (if it was out) and so do you
    local backMe, oldCar = hrp() and hrp().CFrame, carOf(e)
    local backCar = oldCar and oldCar:GetPivot()
    local function restore()
        if backCar then spawnCar(e, backCar + Vector3.new(0, 2, 0)) end
        if backMe then tpTo(backMe) end
    end
    local car = spawnCar(e, inBox(det))
    if not car then restore(); return false, "spawn failed" end
    local prompt = booth:FindFirstChild("Prompt")
    local pp = prompt and prompt:FindFirstChildWhichIsA("ProximityPrompt")
    if pp then tpTo(prompt.CFrame * CFrame.new(0, 0, -3)); task.wait(0.3); fireproximityprompt(pp); task.wait(0.6) end
    local before = car.Values.PaintColor.Value
    Events.Vehicles.SetPaint:FireServer("Car", car, color, material)
    local t = os.clock()
    repeat task.wait(0.1) until car.Values.PaintColor.Value ~= before or os.clock() - t > 3
    local fr = LP.PlayerGui:FindFirstChild("HUD") and LP.PlayerGui.HUD.Frames:FindFirstChild("Paint")
    if fr and fr.Visible then fr.Visible = false end
    local ok = car.Values.PaintColor.Value ~= before
    restore()
    return ok, ok and ("painted %s %s for %s"):format(entryModel(e), material, money(price)) or "paint didn't take"
end

local function paintColor() return CFG.paintRandom and Color3.fromHSV(math.random(), 0.75, 0.9) or CFG.paintColor end

-- ============================== sell ==============================
local function sellCar(e, manual)
    if isFav(e) then return false, "locked: " .. entryModel(e) .. " is a favorite" end
    if not manual and not isFlip(e) then return false, "auto only sells cars it bought" end
    local left = sellCooldownLeft(e)
    if left > 0 then return false, ("sell timer: %dm %02ds"):format(left // 60, left % 60) end
    local npc = workspace.Utils.SellCar
    streamAt(npc:GetPivot().Position, 5)
    local pr = npc:FindFirstChild("Prompt") or npc:WaitForChild("Prompt", 5)
    if not pr then return false, "sell NPC not loaded" end
    -- the prompt sells whatever car is in the zone: never with another of your cars there
    for _, o in ipairs(entries()) do
        local c = carOf(o)
        if o ~= e and c and (c:GetPivot().Position - pr.Position).Magnitude < 40 then return false, entryModel(o) .. " is parked at the sell zone, move it first" end
    end
    -- afterwards you go back where you were (sold or not)
    local backMe = hrp() and hrp().CFrame
    local function back(...)
        confirmFn = nil
        if backMe then tpTo(backMe) end
        return ...
    end
    local want, offer = entryModel(e), nil
    local o = OWNED[e.Name]
    local cost = (o and o.price) or tonumber(entryVal(e, "BuyPrice")) or 0
    local partsCost = o and o.parts or 0
    confirmFn = function(text)
        offer = parsePrice(text)
        return text:find("sell your", 1, true) ~= nil and text:find(want, 1, true) ~= nil -- only the car we meant
    end
    local lastMsg = "no sell offer"
    for _, gap in ipairs({ 9, 6 }) do -- a fresh spawn sometimes settles out of the zone: second try closer
        local car = spawnCar(e, CFrame.lookAt(pr.Position + pr.CFrame.LookVector * gap + Vector3.new(0, 3, 0), pr.Position))
        if not car then return back(false, "spawn failed") end
        tpTo(pr.CFrame * CFrame.new(0, 0, -4))
        task.wait(1)
        -- the area loaded from afar can stream out and back in meanwhile: that makes a new Prompt instance
        if not pr.Parent then pr = npc:FindFirstChild("Prompt") or npc:WaitForChild("Prompt", 3) or pr end
        local nt0, gone = os.clock(), false
        fireproximityprompt(pr.ProximityPrompt)
        local t = os.clock()
        repeat task.wait(0.1); gone = e.Parent == nil until gone or os.clock() - t > 4
        if gone then
            confirmFn = nil
            OWNED[e.Name] = nil; saveOwned()
            -- "earned" was always revenue (sale prices); profit = sale - buy price - parts bought for it, tracked from now on
            STATE.sold = (STATE.sold or 0) + 1; STATE.earned = (STATE.earned or 0) + (offer or 0)
            if offer and cost > 0 then
                STATE.profit = (STATE.profit or 0) + offer - cost - partsCost
                STATE.profitSales = (STATE.profitSales or 0) + 1
            end
            saveState()
            return back(true, ("sold %s for %s"):format(want, money(offer)))
        end
        if lastNotify.t >= nt0 then
            lastMsg = "server: " .. lastNotify.text
            local secs = parseWait(lastNotify.text)
            if secs then
                -- learn the timer: now - BoughtAt + remaining
                local bought = tonumber(entryVal(e, "BoughtAt")) or os.time()
                CFG.sellCooldown = math.max(CFG.sellCooldown, os.time() - bought + secs)
                saveState()
                log(("learned sell timer: %d s"):format(CFG.sellCooldown))
                break
            end
            if not lastNotify.text:find("too far", 1, true) then break end
        end
    end
    return back(false, lastMsg)
end

-- ============================== buy ==============================
-- opts.quote: only read the price (declines). opts.max: accept up to this price (a quoted price); default = Auto limits.
-- The game's own dialog is never used: shown from a script it didn't take the player's click (measured 2026-09-28).
-- contested cars: another player standing at a junk car is probably about to buy it. Auto buy leaves it to them unless
-- it's at the snipe tier or rarer. ponytail: players out of streaming range aren't loaded, so buyJunk looks again once
-- it has teleported there
local CONTEST = {} -- one table: the main chunk is at Luau's 200-local limit
function CONTEST.near(pos) -- other players within the radius
    local n = 0
    for _, p in ipairs(Players:GetPlayers()) do
        local r = p ~= LP and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
        if r and (r.Position - pos).Magnitude <= CFG.contestRadius then n += 1 end
    end
    return n
end
function CONTEST.snipes(tier, from) return TIER_RANK[tier] <= (TIER_RANK[from] or 0) end -- "Never" ranks 0
assert(CONTEST.snipes("A", "A") and CONTEST.snipes("S", "A") and not CONTEST.snipes("B", "A") and not CONTEST.snipes("S", "Never"), "snipe self-check")
function CONTEST.snipe(j) return CONTEST.snipes(j.tier, CFG.snipeTier) end
function CONTEST.skip(j) -- leave this car to the player at it?
    if not CFG.contestOn or CONTEST.snipe(j) then return false end
    return (j.skipUntil or 0) > os.clock() or CONTEST.near(j.model:GetPivot().Position) > 0
end

local function buyJunk(info, opts)
    opts = opts or {}
    local m = info.model
    if not m.Parent or not m:FindFirstChild("ClickDetector") then return nil, "car gone" end
    if not opts.quote and #entries() >= garageSlots() then return nil, ("garage full (%d/%d)"):format(#entries(), garageSlots()) end
    local max = opts.max or CFG.buyMaxPrice
    local reserve = opts.max and 0 or CFG.reserve -- a price you confirmed yourself ignores the auto reserve
    if not opts.quote and myMoney() - info.lo < reserve then return nil, "reserve" end
    local before = {}
    for _, g in ipairs(entries()) do before[g] = true end
    local asked, price, yes = false, nil, false
    confirmFn = function(text)
        asked, price = true, parsePrice(text)
        yes = not opts.quote and price ~= nil and price <= max and myMoney() - price >= reserve
        return yes
    end
    -- the server checks where it thinks you are: give the teleport time to replicate, retry the click
    local sniped = false
    for _ = 1, 3 do
        tpTo(m:GetPivot() * CFrame.new(0, 3, 8))
        task.wait(0.8)
        if not m.Parent then break end
        if opts.auto and CFG.contestOn then -- players near the car are loaded now that we're here
            local near = CONTEST.near(m:GetPivot().Position)
            if near > 0 and not CONTEST.snipe(info) then
                confirmFn = nil
                info.skipUntil = os.clock() + 30 -- they weren't visible from afar: don't teleport straight back
                return nil, ("left %s to the player%s at it"):format(info.name, near == 1 and "" or "s")
            end
            sniped = near > 0
        end
        fireclickdetector(m.ClickDetector)
        local t = os.clock()
        repeat task.wait(0.1) until asked or os.clock() - t > 2.5
        if asked then break end
    end
    local new
    if yes then
        local t = os.clock()
        repeat
            task.wait(0.1)
            for _, g in ipairs(entries()) do if not before[g] then new = g end end
        until new or os.clock() - t > 5
    end
    confirmFn = nil
    if opts.quote then
        if price then return nil, price end
        return nil, nil, asked and "no price in the offer" or "the server never offered the car (someone else bought it, or you're too far)"
    end
    if new then
        OWNED[new.Name] = { model = entryModel(new), boughtAt = os.time(), price = price }
        if maybeAutoLock(new) then notify(("Auto-locked %s: rare, it will not be sold"):format(entryModel(new))) end
        saveOwned()
        return new, ("bought %s for %s%s"):format(entryModel(new), money(price), sniped and " · sniped from a player at it" or "")
    end
    if not asked then return nil, "the server never offered the car (someone else bought it, or you're too far)" end
    if not yes then
        if price and price > max then return nil, ("price went up: %s"):format(money(price)) end
        return nil, ("declined at %s"):format(money(price))
    end
    return nil, "accepted but the car didn't arrive"
end

-- ============================== junk scan + ESP ==============================
local hui = gethui and gethui() or game:GetService("CoreGui")
local espRoot = Instance.new("Folder")
espRoot.Name = "FixItUpESP"
espRoot.Parent = hui
-- labels hang on our own local anchor parts: a car's real parts are replaced when it streams out and back
-- in, which left labels with a nil Adornee floating in the wrong place
local anchorRoot = Instance.new("Folder")
anchorRoot.Name = "FixItUpAnchors"
anchorRoot.Parent = workspace -- made by the client, so it never replicates (the join camera gets replaced, don't use it)

local function newAnchor()
    local p = Instance.new("Part")
    p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
    p.Transparency, p.Size = 1, Vector3.new(0.2, 0.2, 0.2)
    p.Parent = anchorRoot
    return p
end
local function placeAnchor(anchor, model) -- above the car's box; false while it's streamed out
    local ok, cf, size = pcall(model.GetBoundingBox, model)
    if not ok or size.Magnitude < 2 then return false end
    anchor.CFrame = CFrame.new(cf.Position + Vector3.new(0, size.Y / 2 + 1, 0))
    return true
end

local function makeLabel(w, h)
    local bb = Instance.new("BillboardGui")
    bb.AlwaysOnTop, bb.LightInfluence, bb.ResetOnSpawn = true, 0, false
    bb.Size, bb.SizeOffset = UDim2.fromOffset(w, h), Vector2.new(0, 0.5) -- bottom edge sits on the anchor
    local txt = Instance.new("TextLabel")
    txt.Size, txt.BackgroundTransparency, txt.RichText = UDim2.fromScale(1, 1), 1, true
    txt.Font, txt.TextStrokeTransparency, txt.TextYAlignment = Enum.Font.GothamBold, 0.35, Enum.TextYAlignment.Bottom
    txt.Parent = bb
    bb.Parent = espRoot
    return bb, txt
end

local junk = {} -- [model] = info + { bb, txt, hl, anchor }
local function dropJunk(m)
    local j = junk[m]
    junk[m] = nil
    if j then
        for _, k in ipairs({ "bb", "hl", "anchor" }) do if j[k] then j[k]:Destroy() end end
        if j.partConn then j.partConn:Disconnect() end
    end
end

local function makeEsp(j)
    j.anchor = newAnchor()
    j.bb, j.txt = makeLabel(220, 36)
    j.bb.Adornee = j.anchor
    local hl = Instance.new("Highlight")
    hl.Adornee, hl.FillTransparency, hl.OutlineTransparency = j.model, 0.85, 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = espRoot
    j.hl = hl
    -- a Highlight doesn't pick up parts that stream in after it was set: re-attach when the car gains parts
    j.partConn = j.model.DescendantAdded:Connect(function(d) if d:IsA("BasePart") then j.reAdorn = true end end)
end

local function hex(c) return ("#%02x%02x%02x"):format(c.R * 255, c.G * 255, c.B * 255) end
local function camPos() local c = workspace.CurrentCamera; return c and c.CFrame.Position or Vector3.zero end

local function scanJunk()
    for m in pairs(junk) do if not m.Parent or not m:GetAttribute("Junkyard") then dropJunk(m) end end
    for _, m in ipairs(Vehicles:GetChildren()) do
        if m:GetAttribute("Junkyard") and not junk[m] then
            local j = junkInfo(m)
            junk[m] = j
            makeEsp(j)
            CONTEST.lastSpawn = os.clock() -- a refresh swaps the 10 cars one every ~2 s: auto buy waits for the wave
            -- spawn log, to test "do fuller servers spawn rarer cars?" (skips the cars already there when the script loads)
            if CONTEST.scanned then pcall(function()
                local f = DIR .. "/spawns.csv"
                if not isfile(f) then writefile(f, "time,server,type,players,car,chance,tier\n") end
                appendfile(f, ("%d,%s,%s,%d,%s,%s,%s\n"):format(os.time(), game.JobId:sub(1, 8), tostring(RS:GetAttribute("ServerType")),
                    #Players:GetPlayers(), (j.name:gsub(",", " ")), tostring(j.sc), j.tier))
            end) end
        end
    end
    CONTEST.scanned = true -- from the second scan on, new junk cars are real spawns
    local cp = camPos()
    for m, j in pairs(junk) do
        j.dist = (m:GetPivot().Position - cp).Magnitude
        local col, show = CFG.color[j.tier], CFG.show[j.tier]
        local on = CFG.esp and show and j.dist <= CFG.maxDist
        local loaded = on and placeAnchor(j.anchor, m)
        j.bb.Enabled = loaded == true
        if loaded then
            j.txt.TextSize, j.txt.TextColor3 = CFG.textSize, col
            j.txt.Text = CFG.espDetail
                and ('[%s] %s\n<font size="%d" color="#dddddd">%s · +%s · %dm</font>'):format(j.tier, j.name, CFG.textSize - 3, chanceText(j.sc), money(j.profitHi), j.dist)
                or ("[%s] %s %s"):format(j.tier, j.name, chanceText(j.sc))
        end
        if j.reAdorn then j.reAdorn = false; j.hl.Adornee = nil; j.hl.Adornee = m end
        j.hl.Enabled = on and CFG.outline
        j.hl.OutlineColor, j.hl.FillColor = col, col
    end
end

local function sortedJunk()
    local list = {}
    for _, j in pairs(junk) do list[#list + 1] = j end
    table.sort(list, function(a, b)
        if a.tier ~= b.tier then return TIER_RANK[a.tier] < TIER_RANK[b.tier] end
        return a.profitHi > b.profitHi
    end)
    return list
end

local function junkLabel(j) return ("[%s] %s  %s–%s  #%s"):format(j.tier, j.name, money(j.lo), money(j.hi), j.model.Name:sub(1, 4)) end

-- my loose parts: wear + game's delete countdown
local partEsp = {}
-- other players: a label over each one (name, cars sold, what they have spawned) + a title over each of their cars
local plEsp, carEsp = {}, {} -- [Player] = { anchor, bb, txt, hl }, [car model] = { anchor, bb, txt }
local function dropEsp(t, k)
    local e = t[k]
    t[k] = nil
    if e then for _, n in ipairs({ "bb", "hl", "anchor" }) do if e[n] then e[n]:Destroy() end end end
end
local function carTier(c)
    local sc = c:GetAttribute("SpawnChance")
    return tierOf(sc, (sc or 0) <= 0)
end
local function soldText(p)
    local ls = p:FindFirstChild("leaderstats")
    local v = ls and ls:FindFirstChild("Cars Sold")
    return v and tostring(v.Value) or "?"
end
-- labels ride the player's root part / the car's seat, so they follow every frame; re-found each scan after streaming
local function carAnchorPart(c) return c:FindFirstChild("DriveSeat") or c.PrimaryPart or c:FindFirstChildWhichIsA("BasePart", true) end
-- an attachment welded (by being a child) to the seat, placed once above the roof: the engine moves it with the car
-- every frame, so a title on it never trails a moving car. Re-made when the car streams back in (new seat part).
local function titleAttachment(c, old)
    local part = carAnchorPart(c)
    if not part then return nil end
    if old and old.Parent == part then return old end
    if old then old:Destroy() end
    local ok, cf, size = pcall(c.GetBoundingBox, c)
    local top = (ok and size.Magnitude > 2) and (cf.Position + Vector3.new(0, size.Y / 2 + 1, 0)) or (part.Position + Vector3.new(0, 4, 0))
    local a = Instance.new("Attachment")
    a.Name = "FIU_Title"
    a.Position = part.CFrame:PointToObjectSpace(top)
    a.Parent = part
    return a
end
local function scanPlayers()
    if not CFG.playerEsp and not next(plEsp) and not next(carEsp) then return end -- off and already cleaned up
    local cp = camPos()
    local byOwner, driving = {}, {} -- owner name -> cars; car -> driver
    for _, c in ipairs(Vehicles:GetChildren()) do
        local owner = c:GetAttribute("Owner")
        if owner and owner ~= LP.Name and not c:GetAttribute("Junkyard") then
            byOwner[owner] = byOwner[owner] or {}
            table.insert(byOwner[owner], c)
        end
    end
    local titles = CFG.playerEsp and CFG.playerCarTitles
    -- player labels
    for p in pairs(plEsp) do if not p.Parent or not CFG.playerEsp then dropEsp(plEsp, p) end end
    if CFG.playerEsp then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then
                local e = plEsp[p]
                if not e then
                    e = {}
                    e.bb, e.txt = makeLabel(240, 60)
                    e.bb.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
                    e.hl = Instance.new("Highlight")
                    e.hl.FillTransparency, e.hl.OutlineTransparency, e.hl.DepthMode = 1, 0, Enum.HighlightDepthMode.AlwaysOnTop
                    e.hl.Parent = espRoot
                    plEsp[p] = e
                end
                local ch = p.Character
                local root = ch and ch:FindFirstChild("HumanoidRootPart")
                local h = ch and ch:FindFirstChildOfClass("Humanoid")
                local seat = h and h.SeatPart
                local car = seat and seat:IsDescendantOf(Vehicles) and seat or nil
                while car and car.Parent ~= Vehicles do car = car.Parent end
                if car then driving[car] = p end
                local dist = root and (root.Position - cp).Magnitude or math.huge
                -- a driver's info moves onto the car title instead of stacking a second label on top of it
                local on = root ~= nil and dist <= CFG.playerMaxDist and not (car and titles)
                e.bb.Adornee = root
                e.bb.Enabled = on
                e.hl.Adornee, e.hl.Enabled, e.hl.OutlineColor = ch, root ~= nil and dist <= CFG.playerMaxDist and CFG.playerOutline, CFG.playerColor
                if on then
                    local extra = ""
                    if not titles then -- no car titles: list their cars here instead
                        local cars = {}
                        for _, c in ipairs(byOwner[p.Name] or {}) do
                            cars[#cars + 1] = ('<font color="%s">%s</font>'):format(hex(CFG.color[carTier(c)]), tostring(c:GetAttribute("Model")))
                        end
                        if #cars > 0 then extra = ('\n<font size="%d">%s</font>'):format(CFG.textSize - 3, table.concat(cars, ", ")) end
                    end
                    e.txt.TextSize, e.txt.TextColor3 = CFG.textSize, CFG.playerColor
                    e.txt.Text = ('%s\n<font size="%d" color="#dddddd">%s sold · %dm</font>%s'):format(p.DisplayName, CFG.textSize - 3, soldText(p), dist, extra)
                end
            end
        end
    end
    -- titles over their cars
    for c in pairs(carEsp) do
        local owner = c:GetAttribute("Owner")
        if not c.Parent or not titles or not owner or owner == LP.Name or c:GetAttribute("Junkyard") then dropEsp(carEsp, c) end
    end
    if titles then
        for owner, list in pairs(byOwner) do
            for _, c in ipairs(list) do
                local e = carEsp[c]
                if not e then
                    e = {}
                    e.bb, e.txt = makeLabel(240, 40)
                    carEsp[c] = e
                end
                local dist = (c:GetPivot().Position - cp).Magnitude
                e.anchor = titleAttachment(c, e.anchor)
                local on = e.anchor ~= nil and dist <= CFG.playerMaxDist
                e.bb.Adornee = e.anchor
                if on then
                    local tier = carTier(c)
                    local pl = Players:FindFirstChild(owner)
                    local driver = driving[c]
                    local who = driver and (driver.DisplayName .. " · " .. soldText(driver) .. " sold" .. (driver.Name ~= owner and (" · owner " .. (pl and pl.DisplayName or owner)) or ""))
                        or (pl and pl.DisplayName or owner)
                    e.txt.TextSize, e.txt.TextColor3 = CFG.textSize - 1, CFG.color[tier]
                    e.txt.Text = ('[%s] %s\n<font size="%d" color="#dddddd">%s</font>'):format(tier, tostring(c:GetAttribute("Model")), CFG.textSize - 4, who)
                end
                e.bb.Enabled = on
            end
        end
    end
end

local function scanParts()
    for p, b in pairs(partEsp) do if not p.Parent or not CFG.partEsp then b:Destroy(); partEsp[p] = nil end end
    if not CFG.partEsp then return end
    for _, p in ipairs(MoveParts:GetChildren()) do
        if p:GetAttribute("Owner") == LP.Name and p:IsA("Model") then
            local b = partEsp[p]
            if not b then
                b = Instance.new("BillboardGui")
                b.AlwaysOnTop, b.Size, b.Adornee = true, UDim2.fromOffset(160, 30), p.PrimaryPart or p:FindFirstChildWhichIsA("BasePart", true)
                local t = Instance.new("TextLabel", b)
                t.Size, t.BackgroundTransparency, t.Font, t.TextSize, t.TextStrokeTransparency = UDim2.fromScale(1, 1), 1, Enum.Font.GothamBold, 13, 0.3
                b.Parent = espRoot
                partEsp[p] = b
            end
            local w, dropped = p:GetAttribute("Wear") or 0, p:GetAttribute("DroppedAt")
            local t = b:FindFirstChildOfClass("TextLabel")
            t.TextColor3 = w == 0 and Color3.fromRGB(90, 230, 120) or Color3.fromRGB(255, 170, 60)
            t.Text = ("%s · wear %d%%%s"):format(p:GetAttribute("PartName") or p.Name, w,
                dropped and ("\ndeletes in %ds"):format(math.max(0, 90 - (workspace:GetServerTimeNow() - dropped))) or "")
        end
    end
end

-- ============================== spawn alerts ==============================
on(Events.DisplayMessage.OnClientEvent, function(_, text)
    text = tostring(text)
    if not CFG.alerts then return end
    local name, chance = text:match("rare car has appeared! (.-) — Chance: ([%d%.]+)%%")
    if name then
        local tier = tierOf(tonumber(chance))
        if TIER_RANK[tier] <= TIER_RANK[CFG.alertMin] then
            notify(("[%s] %s spawned in the junkyard (%s%%)"):format(tier, name, chance))
            log(("spawn: [%s] %s %s%%"):format(tier, name, chance))
        end
    elseif text:find("exclusive car", 1, true) then
        notify("Exclusive car appeared somewhere on the map")
        log("spawn: exclusive car")
    end
end)

-- ============================== auto flip ==============================
local autoStatus = "off"
local function wantedJunk()
    local best, taken = nil, 0 -- taken = matching cars left to players standing at them
    -- rarest first by the real spawn chance (tiers are too coarse: a 0.2% A beats a 0.9% A), then profit
    local list = sortedJunk()
    table.sort(list, function(a, b)
        local sa, sb = a.sc or 100, b.sc or 100
        if sa ~= sb then return sa < sb end
        return a.profitHi > b.profitHi
    end)
    for _, j in ipairs(list) do
        local modelOk = next(CFG.buyModels) == nil
        for _, n in ipairs(j.names) do if CFG.buyModels[n] then modelOk = true end end
        local rareOk
        if CFG.buyBy == "Spawn chance" then rareOk = j.sc ~= nil and j.sc > 0 and j.sc <= CFG.buyMaxPct
        else rareOk = TIER_RANK[j.tier] <= TIER_RANK[CFG.buyMinTier] end
        if not j.exclusive and rareOk and modelOk
            and j.lo <= CFG.buyMaxPrice and j.profitLo >= CFG.buyMinProfit and myMoney() - j.lo >= CFG.reserve then
            if CONTEST.skip(j) then taken += 1 else best = best or j end
        end
    end
    return best, taken
end

-- home: a quiet spot you park at between auto actions (STATE.home = { x, y, z, lookX, lookZ })
local function goHome(force)
    local h = STATE.home
    if not (h and (force or CFG.homeAfterTp)) then return end
    local pos = Vector3.new(h[1], h[2], h[3])
    local r = hrp()
    if r and (r.Position - pos).Magnitude < 10 then return end
    streamAt(pos, 5)
    tpTo(CFrame.lookAt(pos, pos + Vector3.new(h[4], 0, h[5])))
end

-- buy the best matching junk car. onlyRare: just A tier or rarer (they jump ahead of repairs and sales).
-- returns true when it acted (or is holding for a refresh), so autoStep stops there
local function buyStep(onlyRare)
    if not CFG.autoBuy then return false end
    if #entries() >= garageSlots() then
        if not onlyRare then autoStatus = ("garage full %d/%d"):format(#entries(), garageSlots()) end
        return false
    end
    local j, taken = wantedJunk()
    if not j then
        if not onlyRare then
            autoStatus = taken > 0 and ("%d matching car%s left to players at them"):format(taken, taken == 1 and "" or "s")
                or "no junk car matches the filters"
        end
        return false
    end
    if onlyRare and TIER_RANK[j.tier] > TIER_RANK.A then return false end
    busy, busyWhat = true, "buying " .. j.name
    local e, msg = buyJunk(j, { auto = true })
    log(msg)
    if not (e and CFG.autoRepair) then goHome() end -- a repair is next anyway: go straight there
    busy = false
    return true
end

local function autoStep()
    if busy or manualPending then return end
    -- 0) a junkyard refresh spawns a car every ~2 s for ~20 s. Don't commit to anything (a buy, or a repair that
    -- would block the rare that spawns last) until the wave is over, then pick the rarest. An S-tier or rarer match
    -- is bought on sight: nothing later in the wave can beat it.
    if CFG.autoBuy and #entries() < garageSlots() and os.clock() - (CONTEST.lastSpawn or 0) < CFG.buySettle then
        local j = wantedJunk()
        if not (j and TIER_RANK[j.tier] <= TIER_RANK.S) then
            autoStatus = "junkyard refreshing: waiting for every car to spawn before choosing"
            return
        end
    end
    -- rare matches jump ahead of repairs and sales (another player would take them first)
    if buyStep(true) then return end
    -- 1) finish cars we bought: repair, then sell
    for _, e in ipairs(entries()) do
        maybeAutoLock(e) -- also catches cars bought before auto lock was turned on
        local o = OWNED[e.Name] -- locked (favorite) script-bought cars still get repaired, they're just never sold
        if o and os.time() >= (o.nextTry or 0) then
            if CFG.autoRepair and not o.repaired then
                busy, busyWhat = true, "repairing " .. entryModel(e)
                local ok, msg = repairCar(e)
                o.tries = (o.tries or 0) + 1
                if ok or o.tries >= 2 then o.repaired = true end -- two tries, then sell it as it is
                saveOwned()
                log(msg)
                if o.repaired and CFG.cleanAfter then local _, m2 = cleanCar(e); log(m2) end
                if o.repaired and CFG.paintAfter then local _, m3 = paintCar(e, paintColor(), CFG.paintMaterial); log(m3) end
                goHome()
                busy = false
                return
            end
            if CFG.autoSell and not isFav(e) and e.Name ~= CFG.farmCarGuid and (o.repaired or not CFG.autoRepair) then
                local left = sellCooldownLeft(e)
                if left > 0 then
                    autoStatus = ("waiting sell timer for %s: %dm %02ds"):format(entryModel(e), left // 60, left % 60)
                else
                    busy, busyWhat = true, "selling " .. entryModel(e)
                    local ok, msg = sellCar(e)
                    log(msg)
                    goHome()
                    busy = false
                    if not ok and OWNED[e.Name] then OWNED[e.Name].nextTry = os.time() + 30 end -- don't respawn it at the NPC every 2 s
                    return
                end
            end
        end
    end
    -- 2) buy the best junk car that fits
    buyStep(false)
end

-- ============================== player ==============================
on(RunService.Heartbeat, function()
    if CFG.speedOn then local h = hum(); if h and h.WalkSpeed ~= CFG.walkSpeed then h.WalkSpeed = CFG.walkSpeed end end
end)
on(LP.Idled, function()
    if CFG.antiAfk then
        local vu = game:GetService("VirtualUser")
        vu:CaptureController(); vu:ClickButton2(Vector2.new())
    end
end)

-- ============================== teleports ==============================
local V = Vector3.new
local PLACES = {
    { "Junkyard", V(-1670, 6, -373) },
    { "Junkyard shop", V(-1548, 5, -98) },
    { "Spare Parts Shop", V(-1470.6, 3.6, -531) },
    { "Used Cars (sell NPC)", V(-1918, 4, -790) },
    { "Auctions", V(-1950.5, 5, -814) },
    { "Premium Car Dealership", V(-1641, 5.2, -459.3) },
    { "Dealership repair shop", V(-560, 5, -806) },
    { "Pitstop (large)", V(-1095, 5, -410) },
    { "Pitstop (small) south", V(-557, 5, -1617) },
    { "Pitstop (small) west", V(-1130.3, 5, -1546.5) },
    { "Car Paint", V(-989.4, 4.6, -389.6) },
    { "Window Tint", V(-1043.8, 5, -340.6) },
    { "Gas Station (west)", V(-1450.2, 5.6, -708) },
    { "Gas Station (east)", V(-349.2, 5, -1295.4) },
    { "Car Wash", V(-1548.6, 5.3, -819.2) },
    { "Car Wash (city)", V(-896.5, 7, -1006.9) },
    { "Pressure Washer (east)", V(-257, 10.6, -1210.4) },
    { "Plate Shop", V(-1317.3, 4, -599.5) },
    { "Tire Shop (south)", V(-1380.8, 5, -1552.5) },
    { "Tire Shop (north)", V(-720.2, 5, -411.2) },
    { "Rim Paint (south)", V(-1405.5, 5.2, -1537.4) },
    { "Rim Paint (north)", V(-744.3, 5.2, -419.3) },
    { "Brake Shop", V(79.7, 10.3, -1453.7) },
    { "Underglow Shop", V(-958.5, 6.4, -1721) },
    { "Bank / Exchange", V(-1462, 7.1, -768.7) },
    { "Bank (city)", V(-246.4, 7, -1019) },
    { "Clothes Shop", V(-1216.6, 5, -894.1) },
    { "RodEx Shop", V(-1288.4, 5, -861.2) },
    { "Body Parts Shop", V(-10840.2, 6, 5742.1) },
    { "Job: Gas Station Cashier", V(-1521, 8.9, -747.4) },
    { "Job: RodEx Mail Clerk", V(-1294.9, 8.6, -857.5) },
    { "Race Track", V(631.3, 17.7, 820.9) },
    { "Races", V(800.4, 12.5, 570.9) },
}
-- garage points resolve at teleport time: their parts stream out when you're far away
local function streamed(model, name)
    local p = model:FindFirstChild(name, true)
    if not p then
        streamAt(model:GetPivot().Position, 5)
        p = model:FindFirstChild(name, true)
    end
    if not p then return model:GetPivot().Position end
    return p:IsA("Model") and p:GetPivot().Position or p.Position
end
-- interiors sit underground (y -14 to -108); DoorDetector is the real front door
local function garagePoints(label, g) -- the user wants the front door only
    PLACES[#PLACES + 1] = { label, function() return streamed(g, "DoorDetector") end }
end
local myGarageModel = function() return workspace.Garages:FindFirstChild(tostring(PD:FindFirstChild("GarageModel") and PD.GarageModel.Value or "Default")) end
do
    local mine = myGarageModel()
    if mine then garagePoints("My garage", mine) end
end
local garages = workspace.Garages:GetChildren()
table.sort(garages, function(a, b) return (a:GetAttribute("Price") or math.huge) < (b:GetAttribute("Price") or math.huge) end)
for _, g in ipairs(garages) do
    local price = g:GetAttribute("Price")
    garagePoints(("Garage %s%s"):format(g.Name, price and (" · " .. money(price)) or " · Robux"), g)
end
local PLACE_NAMES, PLACE_POS = {}, {}
for _, p in ipairs(PLACES) do PLACE_NAMES[#PLACE_NAMES + 1] = p[1]; PLACE_POS[p[1]] = p[2] end

local selectedCar -- garage entry picked in the Garage tab
local function goPlace(name)
    local pos = PLACE_POS[name]
    if type(pos) == "function" then pos = pos() end
    if not pos then return end
    local at = ground(pos)
    tpTo(CFrame.new(at))
    if CFG.bringCar and selectedCar and selectedCar.Parent then
        spawnCar(selectedCar, CFrame.new(at + Vector3.new(0, 2, 12)))
    end
end

-- ============================== server hop (was fiu_hop.lua) ==============================
-- Hops public servers until every other player has fewer than N "Cars Sold" (fewer competitors for junk).
-- State in fiu_hop.json (shared with the old standalone hopper) so settings + visited servers survive teleports.
if getgenv().FIU_Hop_Unload then pcall(getgenv().FIU_Hop_Unload) end -- the standalone hopper would fight this one
local TeleportService = game:GetService("TeleportService")
local req = request or http_request or (syn and syn.request)
local HOP_FILE, VISIT_TTL = "fiu_hop.json", 3600
local HOP = readJSON(HOP_FILE, {})
for k, v in pairs({ auto = false, max = 50, over = 0, maxp = 8, hops = 0, visited = {}, hard = false, hardMax = 1500, gate = false, leaveOnFail = false,
    antiMod = true, modRank = 2, modAction = "Leave game", staffBoard = true }) do if HOP[k] == nil then HOP[k] = v end end
local function saveHop() writeJSON(HOP_FILE, HOP) end
do
    local now = os.time()
    for id, t in pairs(HOP.visited) do if now - t > VISIT_TTL then HOP.visited[id] = nil end end
    HOP.visited[game.JobId] = now
    saveHop()
end
local hopping, hopQueued, hopStatus, hopServer = false, false, "idle", "scanning..."
-- what runs in the next server: wait for the game, then load; a failure lands in FixItUp/reload_error.txt
local RELOAD = [==[
repeat task.wait() until game:IsLoaded() and game:GetService("Players").LocalPlayer
local f, e = loadstring(readfile("fiu_main.lua"))
if not f then pcall(writefile, "FixItUp/reload_error.txt", os.date() .. " compile: " .. tostring(e)) return end
local ok, err = pcall(f)
if not ok then pcall(writefile, "FixItUp/reload_error.txt", os.date() .. " " .. tostring(err)) end
]==]

-- ============================== anti-mod ==============================
-- Game group ".workspace" (12249805): regular players are Member (rank 1); every rank above is staff.
-- Settings live in fiu_hop.json so the watch is on the moment the script loads after a hop.
local STAFF = {
    group = 12249805,
    roles = { { "Tester", 2 }, { "Content Creator", 3 }, { "Analytics", 4 }, { "Contributor", 130 }, { "Developers / Anti-Cheat", 150 },
        { "Builder", 151 }, { "Moderator", 249 }, { "Senior Moderator", 250 }, { "Admin", 251 }, { "Senior Admin", 252 },
        { "Manager", 253 }, { "Owners", 254 }, { "Holder", 255 } },
    gone = false, status = "watching",
}
function STAFF.rank(p) -- one retry: the group web call fails now and then
    for _ = 1, 2 do
        local ok, r = pcall(p.GetRankInGroup, p, STAFF.group)
        if ok and r then return r end
        task.wait(2)
    end
end
function STAFF.check(p)
    if not HOP.antiMod or STAFF.gone or p == LP then return end
    local rank = STAFF.rank(p)
    if not rank or rank < HOP.modRank or STAFF.gone or not HOP.antiMod then return end
    STAFF.gone = true
    local _, role = pcall(p.GetRoleInGroup, p, STAFF.group)
    local why = ("%s (@%s) is %s, rank %d"):format(p.DisplayName, p.Name, tostring(role), rank)
    STAFF.status = "staff found: " .. why
    lifeLog("anti-mod: " .. why .. " -> " .. HOP.modAction)
    if HOP.modAction == "Server hop" then
        local q = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
        if q and not hopQueued then hopQueued = pcall(q, RELOAD) end
        pcall(TeleportService.Teleport, TeleportService, game.PlaceId, LP)
        task.delay(12, function() LP:Kick("Staff joined (hop failed): " .. why) end) -- still here = the teleport didn't happen
    else
        LP:Kick("Left: staff joined. " .. why)
    end
end
function STAFF.scan()
    for _, p in ipairs(Players:GetPlayers()) do task.spawn(STAFF.check, p) end
end

-- status board: every group member at/above the staff rank, with where they are right now
function STAFF.get(url, body)
    if not req then return nil end
    local ok, res = pcall(req, { Url = url, Method = body and "POST" or "GET",
        Headers = body and { ["Content-Type"] = "application/json" } or nil, Body = body and HttpService:JSONEncode(body) or nil })
    if not ok or not res or res.StatusCode ~= 200 then return nil, res and res.StatusCode end
    local ok2, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
    return ok2 and data or nil
end
-- Everyone ranked above Member (~100 people), saved to FixItUp/staff.json for 6 h: the groups API rate-limits hard
-- (15 quick calls from a few reloads got 21 s timeouts). The staff-rank setting only filters this list.
function STAFF.members()
    if not STAFF.mem then
        local saved = readJSON(DIR .. "/staff.json", nil)
        if saved and saved.list then STAFF.mem, STAFF.memAt = saved.list, saved.at or 0 end
    end
    if STAFF.mem and os.time() - (STAFF.memAt or 0) < 6 * 3600 then return STAFF.mem end
    local roles, code = STAFF.get(("https://groups.roblox.com/v1/groups/%d/roles"):format(STAFF.group))
    if not roles then STAFF.err = "group roles: " .. tostring(code or "timeout"); return STAFF.mem end
    STAFF.done = STAFF.done or {} -- role id -> its members; a failed run resumes where it stopped
    local list = {}
    for _, r in ipairs(roles.roles or {}) do
        if r.rank >= 2 then
            if not STAFF.done[r.id] then
                local got, cursor = {}, ""
                repeat
                    local page, c2
                    for try = 1, 3 do -- dropped requests (status 0) happen: back off and retry
                        task.wait(0.6 * try * try)
                        page, c2 = STAFF.get(("https://groups.roblox.com/v1/groups/%d/roles/%d/users?limit=100&sortOrder=Asc&cursor=%s"):format(STAFF.group, r.id, cursor))
                        if page then break end
                    end
                    if not page then STAFF.err = r.name .. ": " .. tostring(c2 or "timeout"); return STAFF.mem end -- keep the old list, don't save half
                    for _, u in ipairs(page.data or {}) do
                        got[#got + 1] = { id = u.userId, name = u.username, display = u.displayName, role = r.name, rank = r.rank }
                    end
                    cursor = page.nextPageCursor
                until not cursor
                STAFF.done[r.id] = got
            end
            for _, m in ipairs(STAFF.done[r.id]) do list[#list + 1] = m end
        end
    end
    STAFF.done = nil
    STAFF.mem, STAFF.memAt, STAFF.err = list, os.time(), nil
    writeJSON(DIR .. "/staff.json", { at = STAFF.memAt, list = list })
    return list
end
STAFF.where = { -- order + color on the board
    { "server", "#ff5555", "IN YOUR SERVER" }, { "game", "#ff9f43", "in Fix It Up (other server)" }, { "other", "#ffd24a", "in another game" },
    { "hidden", "#ffd24a", "in a game (hidden)" }, { "studio", "#aaaaaa", "in Studio" }, { "online", "#aaaaaa", "online" },
}
function STAFF.refresh()
    local list = STAFF.members()
    if not list then STAFF.board = "Couldn't load the group's staff list (" .. tostring(STAFF.err) .. "), retrying in a minute"; return end
    local byId, ids = {}, {}
    for _, m in ipairs(list) do
        if m.rank >= HOP.modRank and (not byId[m.id] or m.rank > byId[m.id].rank) then byId[m.id] = m; m.where = nil end
    end
    for id in pairs(byId) do ids[#ids + 1] = id end
    for i = 1, #ids, 50 do
        local data, code = STAFF.get("https://presence.roblox.com/v1/presence/users", { userIds = { table.unpack(ids, i, math.min(i + 49, #ids)) } })
        if not data then STAFF.board = "Couldn't read who's online (" .. tostring(code or "timeout") .. "), retrying in a minute"; return end
        for _, p in ipairs(data and data.userPresences or {}) do
            local m, t = byId[p.userId], p.userPresenceType
            if m then
                m.where = t == 2 and (p.gameId == game.JobId and "server" or p.rootPlaceId == game.PlaceId and "game" or p.rootPlaceId and "other" or "hidden")
                    or t == 1 and "online" or t == 3 and "studio" or "offline"
                m.loc = p.lastLocation
            end
        end
    end
    local lines, off, counts = {}, {}, {}
    for _, wdef in ipairs(STAFF.where) do
        local group = {}
        for _, m in pairs(byId) do if m.where == wdef[1] then group[#group + 1] = m end end
        table.sort(group, function(a, b) return a.rank > b.rank end)
        counts[wdef[1]] = #group
        for _, m in ipairs(group) do
            lines[#lines + 1] = ('<font color="%s">● %s (@%s) · %s · %s</font>'):format(wdef[2], m.display, m.name, m.role,
                wdef[1] == "other" and ("in " .. tostring(m.loc)) or wdef[3])
        end
    end
    for _, m in pairs(byId) do if m.where == "offline" or not m.where then off[#off + 1] = m.display end end
    table.sort(off)
    table.insert(lines, 1, ("<b>%d staff</b> · %d here · %d in Fix It Up · %d in games · %d online · %s"):format(#ids, counts.server, counts.game,
        counts.other + counts.hidden, counts.online + counts.studio, os.date("%H:%M")))
    if #off > 0 then lines[#lines + 1] = ('<font color="#777777">Offline (%d): %s</font>'):format(#off, table.concat(off, ", ")) end
    STAFF.board = table.concat(lines, "\n")
end
on(Players.PlayerAdded, STAFF.check)
task.spawn(STAFF.scan)

-- values = Cars Sold of every other player (math.huge = stats never loaded, counts as over)
-- c.hard: anyone at/over c.hardMax fails the server outright, whatever c.over allows
-- ponytail: "?" (stats never loaded) only counts toward the normal limit, not the hard block
local function judge(values, c)
    local over, hard = 0, 0
    for _, v in ipairs(values) do
        if v >= c.max then over += 1 end
        if c.hard and v ~= math.huge and v >= c.hardMax then hard += 1 end
    end
    return #values >= 1 and over <= c.over and hard == 0, over, hard
end
assert(judge({ 10, 49 }, { max = 50, over = 0 }) and not judge({ 10, 50 }, { max = 50, over = 0 })
    and judge({ 10, 900 }, { max = 50, over = 1 }) and not judge({}, { max = 50, over = 0 })
    and not judge({ 10, 1500 }, { max = 50, over = 1, hard = true, hardMax = 1500 })
    and judge({ 10, 1499 }, { max = 50, over = 1, hard = true, hardMax = 1500 })
    and judge({ 10, math.huge }, { max = 50, over = 1, hard = true, hardMax = 1500 }), "judge self-check")

local function soldOf(pl)
    local ls = pl:FindFirstChild("leaderstats")
    local v = ls and ls:FindFirstChild("Cars Sold")
    return v and tonumber(v.Value)
end

local function scanServer() -- waits up to 8 s for everyone's leaderstats
    local deadline, others = os.clock() + 8, nil
    repeat
        others = {}
        local missing = false
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl ~= LP then
                local s = soldOf(pl)
                if not s then missing = true end
                others[#others + 1] = s or math.huge
            end
        end
        if not missing then break end
        task.wait(0.5)
    until os.clock() > deadline
    table.sort(others)
    return others
end

local function checkServer()
    local vals = scanServer()
    local ok, over, hard = judge(vals, HOP)
    -- the action gate: an empty server is fine to farm in (judge() wants >= 1 other player only for hop hunting)
    STAFF.gateOk = #vals == 0 or ok
    if HOP.leaveOnFail and not STAFF.gateOk and not STAFF.leaving and not HOP.auto then task.spawn(STAFF.leave) end
    local shown = {}
    for i, v in ipairs(vals) do shown[i] = v == math.huge and "?" or tostring(v) end
    hopServer = ("%d others · %d at/over %d%s\nlowest %s · highest %s\n%s%s"):format(#vals, over, HOP.max,
        HOP.hard and (" · %d hard-blocked (%d+)"):format(hard, HOP.hardMax) or "",
        shown[1] or "-", shown[#shown] or "-", ok and "PASSES" or "fails",
        HOP.gate and (STAFF.gateOk and " · actions allowed" or " · ACTIONS BLOCKED") or "")
    return ok, #vals, over
end
-- "Block actions in failing servers": nothing acts until this server has been checked and passes
function STAFF.gated() return STAFF.leaving or (HOP.gate and STAFF.gateOk ~= true) end
STAFF.gateMsg = "this server fails the hop requirements"

-- ONE request per hop, page 1 only: the API 429s on the 3rd call within 4 s (measured 2026-09-25)
local function candidates()
    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100"):format(game.PlaceId)
    local body, code
    if req then
        local ok, res = pcall(req, { Url = url, Method = "GET" })
        if not ok then return nil, "request error" end
        body, code = res.Body, res.StatusCode
    else
        local ok, b = pcall(game.HttpGet, game, url)
        if not ok then return nil, "request error" end
        body, code = b, 200
    end
    if code == 429 then return nil, 429 end
    local ok, data = pcall(HttpService.JSONDecode, HttpService, body)
    if not ok or type(data) ~= "table" or type(data.data) ~= "table" then return nil, data and data.errors and 429 or code end
    local best
    for _, s in ipairs(data.data) do
        local p = s.playing or 0
        -- ponytail: largest server under the cap = most low-sellers per hop
        if not HOP.visited[s.id] and p >= 1 and p <= HOP.maxp and p < (s.maxPlayers or 0) and (not best or p > best.playing) then best = s end
    end
    return best
end

on(TeleportService.TeleportInitFailed, function(_, result, msg) hopStatus = ("teleport failed: %s %s"):format(tostring(result), tostring(msg)) end)

local function hop()
    if hopping then return end
    hopping = true
    local q = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
    if q and not hopQueued then hopQueued = pcall(q, RELOAD) end
    local backoff = 60
    while running and HOP.auto do
        local s, why = candidates()
        if s then
            backoff = 60
            HOP.visited[s.id] = os.time()
            HOP.hops += 1
            saveHop()
            hopStatus = ("hop #%d -> %d/%d players"):format(HOP.hops, s.playing, s.maxPlayers)
            lifeLog(("hop -> %s (%d players)"):format(s.id:sub(1, 8), s.playing))
            pcall(TeleportService.TeleportToPlaceInstance, TeleportService, game.PlaceId, s.id, LP)
            task.wait(15) -- normally gone before this; still here = it failed, try the next one
        elseif why == 429 then
            hopStatus = ("Roblox rate-limited the server list, waiting %ds"):format(backoff)
            task.wait(backoff)
            backoff = math.min(backoff * 2, 300)
        elseif why then
            hopStatus = ("server list failed (%s), retry in 30s"):format(tostring(why))
            task.wait(30)
        else
            hopStatus = ("no unvisited servers with <= %d players, retry in 30s"):format(HOP.maxp)
            task.wait(30)
        end
    end
    hopping = false
end

local hopToggle
local function hopRun()
    hopStatus = "checking this server..."
    task.wait(2) -- let the player list settle after joining
    if not (running and HOP.auto) then return end
    local ok, n, over = checkServer()
    if ok then
        HOP.auto = false
        saveHop()
        if hopToggle then hopToggle:SetValue(false) end
        hopStatus = ("FOUND after %d hops: %d others, %d over limit"):format(HOP.hops, n, over)
        lifeLog(hopStatus)
        notify(("Found it! %d players, all under %d cars sold."):format(n, HOP.max))
    else
        hop()
    end
end

-- "Hop away when the server breaks the rules": block new actions, let the running one finish (a repair has loose
-- engine parts on the floor that a teleport would strand), re-check, then start the normal auto hop hunt.
function STAFF.leave()
    STAFF.leaving = true -- STAFF.gated() is now true: auto, buttons, farm and gold start nothing new
    hopStatus = "server broke the rules: finishing the current job, then hopping"
    lifeLog("rules broken: waiting for " .. tostring(busy and busyWhat or "nothing") .. " before hopping")
    local t = os.clock()
    while running and (busy or manualPending) and os.clock() - t < 600 do task.wait(0.5) end
    task.wait(1) -- let a finished job's last parts settle into the car / inventory
    if not running then return end
    checkServer()
    if STAFF.gateOk then -- whoever broke it left while we waited
        STAFF.leaving = false
        hopStatus = "the rule breaker left, staying"
        return
    end
    lifeLog("rules broken: hopping")
    if hopToggle then hopToggle:SetValue(true) else HOP.auto = true; saveHop(); task.spawn(hopRun) end
end

-- ============================== unload ==============================
local Library
local function unload()
    if not running then return end
    lifeLog("unload\n" .. debug.traceback())
    if getgenv().FIU_MAIN and getgenv().FIU_MAIN.unload == unload then getgenv().FIU_MAIN = nil end -- not a newer copy's export
    running = false
    for _, c in ipairs(conns) do pcall(c.Disconnect, c) end
    if getcallbackvalue(CONFIRM, "OnClientInvoke") == HOOK.fn and HOOK.orig then CONFIRM.OnClientInvoke = HOOK.orig end
    for m in pairs(junk) do dropJunk(m) end
    espRoot:Destroy()
    anchorRoot:Destroy()
    for _, d in ipairs(Vehicles:GetDescendants()) do if d.Name == "FIU_Title" and d:IsA("Attachment") then d:Destroy() end end
    if Library then pcall(Library.Unload, Library) end
end
getgenv().FIU_MAIN = { unload = unload, lib = function() return Library end,
    lockedAtNpc = function(model) -- a locked car with this model name is out and near the Used Cars NPC
        local npc = workspace.Utils:FindFirstChild("SellCar")
        local at = npc and npc:GetPivot().Position
        for _, e in ipairs(entries()) do
            local c = carOf(e)
            if isFav(e) and entryModel(e) == model and c and (not at or (c:GetPivot().Position - at).Magnitude < 60) then return true end
        end
        return false
    end, sel = function() return selectedCar end, cfg = CFG, plEsp = plEsp, carEsp = carEsp, junk = junk, owned = OWNED, state = STATE,
    repairCar = repairCar, sellCar = sellCar, buyJunk = buyJunk, spawnCar = spawnCar, log = logLines,
    machines = machines, liftCF = liftCF, garageSlots = garageSlots, goPlace = goPlace, places = PLACE_NAMES, cleanCar = cleanCar, paintCar = paintCar, buyStore = buyStore,
    contested = CONTEST.skip } -- for scripted tests

-- watchdog: a newer copy took over -> step aside; the game re-set the confirm callback -> hook it again
task.spawn(function()
    local mine = getgenv().FIU_MAIN
    while running do
        if getgenv().FIU_TOKEN ~= HOOK.token then lifeLog("newer copy started, unloading this one"); unload() break end
        if getgenv().FIU_MAIN ~= mine then getgenv().FIU_MAIN = mine end -- an older copy raced its export over ours
        pcall(HOOK.install)
        task.wait(1)
    end
end)

-- ============================== loops ==============================
task.spawn(function()
    while running do
        guard("scan", scanJunk)
        guard("parts", scanParts)
        task.wait(0.5)
    end
end)
task.spawn(function() -- players move: their labels refresh 4x a second (positions follow every frame)
    while running do
        guard("players", scanPlayers)
        task.wait(0.25)
    end
end)
task.spawn(function()
    while running do
        if STAFF.gated() then autoStatus = "blocked: " .. STAFF.gateMsg
        elseif CFG.autoBuy or CFG.autoRepair or CFG.autoSell then
            -- autoStep only runs when nothing is busy and it's the only thing that set busy: if it errors mid-job,
            -- clear it, or one crash leaves auto frozen on "busy" for the rest of the session
            if not guard("auto", autoStep) then busy, confirmFn = false, nil end
        else autoStatus = "off" end
        task.wait(2)
    end
end)

-- ============================== Obsidian UI ==============================
local ThemeManager, SaveManager
do
local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local function obsidian(file, remote)
    local path = "BattleBotFarm/lib/" .. file -- shared local copy (a hung HttpGet once jammed the executor queue)
    local ok, src = pcall(function() return isfile(path) and readfile(path) end)
    return loadstring(ok and src or game:HttpGet(repo .. remote))()
end
Library            = obsidian("Library.lua", "Library.lua")
ThemeManager = obsidian("ThemeManager.lua", "addons/ThemeManager.lua")
SaveManager  = obsidian("SaveManager.lua", "addons/SaveManager.lua")
end
notify = function(msg) Library:Notify(msg, 5) end

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
    end)(), Footer = "Fix It Up · junkyard tiers · auto flip · repair · distance farm",
    Size = UDim2.fromOffset(704, 824), -- default window size (user pick)
    Center = true, AutoShow = true, ToggleKeybind = Enum.KeyCode.RightControl,
})
-- unloaded by a newer copy while we were still setting up: don't leave a dead menu behind
if not running or getgenv().FIU_TOKEN ~= HOOK.token then running = false; pcall(Library.Unload, Library); return end
local Tabs = {
    Junk     = Window:AddTab("Junkyard", "car"),
    Auto     = Window:AddTab("Auto", "repeat"),
    Car      = Window:AddTab("Garage", "warehouse"),
    Shop     = Window:AddTab("Parts", "wrench"),
    Teleport = Window:AddTab("Teleport", "map-pin"),
    Players  = Window:AddTab("Players", "users"),
    Gold     = Window:AddTab("Gold", "coins"),
    Drive    = Window:AddTab("Drive", "gauge"),
    Hop      = Window:AddTab("Server hop", "server"),
    Settings = Window:AddTab("Settings", "settings"),
}
local function set(key) return function(v) CFG[key] = v end end
-- buttons that exist to move you somewhere: never sent home after
local STAY = { ["tp junk"] = true, spawn = true, ["tp car"] = true, tp = true, ["tp garage"] = true, ["tp player"] = true, hood = true }
local function run(name, f) -- buttons: one action at a time, off the UI thread
    return function()
        if STAFF.gated() then notify("Blocked: " .. STAFF.gateMsg) return end
        -- the distance farm holds busy all the time it drives: it steps out for a button and resumes after. Teleport
        -- buttons stay refused while it drives (it would take you straight back to the highway)
        if busy and (busyWhat ~= "farming distance" or STAY[name]) then notify("Busy: " .. tostring(busyWhat)) return end
        if manualPending then notify("Another button is still waiting") return end
        manualPending = true
        task.spawn(function()
            local t = os.clock()
            while busy and os.clock() - t < 30 do task.wait(0.1) end -- next frame, or once the farm's car has spawned
            if busy then manualPending = false; notify("Busy: " .. tostring(busyWhat)) return end
            busy, busyWhat, manualPending = true, name, false
            local t0 = os.clock()
            local ok = guard(name, f)
            if CFG.homeAfterTp and not STAY[name] and (CFG.lastTp or 0) >= t0 then goHome(true) end
            busy = false
        end)
    end
end

-- Junkyard
do
local Tier = Tabs.Junk:AddLeftGroupbox("Tiers", "layers")
Tier:AddLabel("Tier = spawn chance. Toggle shows/hides a tier's labels and outlines; the swatch recolors it.", true)
for _, t in ipairs(TIERS) do
    Tier:AddToggle("FIU_Show_" .. t, { Text = TIER_TEXT[t], Default = CFG.show[t], Callback = function(v) CFG.show[t] = v end })
        :AddColorPicker("FIU_Col_" .. t, { Default = CFG.color[t], Title = TIER_TEXT[t], Callback = function(c) CFG.color[t] = c end })
end
local Disp = Tabs.Junk:AddLeftGroupbox("Display", "eye")
Disp:AddToggle("FIU_Esp", { Text = "Car labels", Default = CFG.esp, Callback = set("esp") })
Disp:AddToggle("FIU_Outline", { Text = "Outline cars", Default = CFG.outline, Callback = set("outline") })
Disp:AddToggle("FIU_EspDetail", { Text = "Profit + distance line", Default = CFG.espDetail, Callback = set("espDetail") })
Disp:AddSlider("FIU_MaxDist", { Text = "Max distance", Default = CFG.maxDist, Min = 100, Max = 6000, Rounding = 0, Suffix = " studs", Callback = set("maxDist") })
Disp:AddSlider("FIU_TextSize", { Text = "Text size", Default = CFG.textSize, Min = 10, Max = 24, Rounding = 0, Suffix = "px", Callback = set("textSize") })
Disp:AddToggle("FIU_Alerts", { Text = "Spawn alerts", Default = CFG.alerts, Tooltip = "Uses the server's 'rare car has appeared' broadcast", Callback = set("alerts") })
Disp:AddDropdown("FIU_AlertMin", { Text = "Alert from tier", Values = TIERS, Default = CFG.alertMin, Callback = set("alertMin") })
local Cont = Tabs.Junk:AddLeftGroupbox("Contested cars", "swords")
Cont:AddLabel("Auto buy leaves a car to another player standing within the radius (they're about to buy it). At the snipe tier or rarer it grabs the car first instead.", true)
Cont:AddToggle("FIU_ContestOn", { Text = "Skip cars players are at", Default = CFG.contestOn, Callback = set("contestOn") })
Cont:AddSlider("FIU_ContestRadius", { Text = "Radius", Default = CFG.contestRadius, Min = 10, Max = 150, Rounding = 0, Suffix = " studs",
    Tooltip = "Junk cars can be bought from 32 studs away", Callback = set("contestRadius") })
Cont:AddDropdown("FIU_SnipeTier", { Text = "Snipe anyway if tier at least", Values = { "Never", "S", "A", "B", "C", "D" },
    Default = CFG.snipeTier, Callback = set("snipeTier") })

end
local List = Tabs.Junk:AddRightGroupbox("Junk cars now", "list")
local junkDrop = List:AddDropdown("FIU_JunkPick", { Text = "Car", Values = {}, AllowNull = true })
local junkByLabel = {}
List:AddButton({ Text = "Teleport to car", Func = run("tp junk", function()
    local j = junkByLabel[junkDrop.Value]
    if j and j.model.Parent then tpTo(j.model:GetPivot() * CFrame.new(0, 3, 8)) end
end) })
local function queued(what, f) -- one job at a time: wait for a running repair/sell instead of refusing
    if STAFF.gated() then notify("Blocked: " .. STAFF.gateMsg) return end
    if manualPending then notify("Another button is still waiting") return end
    manualPending = true -- auto starts nothing new and the distance farm steps out while this is pending
    task.spawn(function()
        if busy then
            notify("Waiting for " .. tostring(busyWhat) .. " to finish")
            local t = os.clock()
            repeat task.wait(0.5) until not busy or os.clock() - t > 180
        end
        if not busy then
            busy, busyWhat = true, what
            local t0 = os.clock()
            local ok, err = pcall(f)
            if CFG.homeAfterTp and (CFG.lastTp or 0) >= t0 then goHome(true) end
            busy = false
            if not ok then log("buy error: " .. tostring(err)); notify("buy error: " .. tostring(err)) end
        end
        manualPending = false
    end)
end
List:AddButton({ Text = "Buy car", Tooltip = "Teleports to the car and buys it at its real price, confirming for you", Func = function()
    local j = junkByLabel[junkDrop.Value]
    if not j then notify("Pick a car in the list first") return end
    queued("buying " .. j.name, function()
        local _, msg = buyJunk(j, { max = math.huge }) -- you picked it: accept whatever it costs
        log(msg); notify(msg)
    end)
end })
local junkLabelBox = List:AddLabel("-", true)
-- the junk list as clickable rows: clicking one picks that car in the dropdown above (for Buy / Teleport)
do
    local rows = {}
    for i = 1, 20 do
        local row = {}
        row.btn = List:AddButton({ Text = "", Func = function()
            if row.label then
                junkDrop:SetValue(row.label)
                notify("Picked " .. tostring(row.name))
            end
        end })
        row.btn.Base.RichText = true
        row.btn.Base.TextXAlignment = Enum.TextXAlignment.Left
        row.btn.Base.TextTruncate = Enum.TextTruncate.AtEnd
        row.btn:SetVisible(false)
        rows[i] = row
    end
    task.spawn(function()
        while running do
            pcall(function()
                local list = sortedJunk()
                for i, row in ipairs(rows) do
                    local j = list[i]
                    if j then
                        local label = junkLabel(j)
                        local near = CONTEST.near(j.model:GetPivot().Position) -- up front: the row's end gets cut off
                        local text = ('%s%s<font color="%s"><b>[%s]</b> %s</font> <font color="#aaaaaa">%s</font>  %s · +%s · %dm'):format(
                            junkDrop.Value == label and "▶ " or "", near > 0 and ('<font color="#ff6b6b">[%d near]</font> '):format(near) or "",
                            hex(CFG.color[j.tier]), j.tier, j.name, chanceText(j.sc), money(j.hi), money(j.profitHi), j.dist or 0)
                        row.label, row.name = label, j.name
                        if row.text ~= text then row.text = text; row.btn:SetText(text) end
                        if not row.shown then row.shown = true; row.btn:SetVisible(true) end
                    else
                        row.label = nil
                        if row.shown then row.shown = false; row.btn:SetVisible(false) end
                    end
                end
            end)
            task.wait(0.5)
        end
    end)
end

-- ============================== auctions ==============================
-- 12 garages at Utils.Auctions. Buying one (the "75,000€" MoneyBuy prompt; the RobuxBuy prompt is never touched)
-- rolls a prize on the server, so nothing predicts it. Not profitable (~€20K average loss per open, the game's own
-- sign says so): every open is capped by a per-run count, a per-run budget and a money floor, all checked before
-- EACH open, and the prompt's price must still read 75,000€.
do
local AUC = { price = 75000, running = false, status = "idle", runLog = {} }
STATE.auction = STATE.auction or { opened = 0, spent = 0, won = 0, cars = {} }
local RARE = { ["Chule El Caminho SS 454"] = true, ["Four JF"] = true, ["Missah Silva S15"] = true, ["Four Mustank Hoonicorn"] = true }
local function aucFloor() return math.max(CFG.reserve or 0, CFG.aucFloor or 0) end
function AUC.free()
    local A = workspace:FindFirstChild("Utils") and workspace.Utils:FindFirstChild("Auctions")
    if not A then return {} end
    pcall(function() LP:RequestStreamAroundAsync(A:GetPivot().Position, 5) end)
    local list = {}
    for _, g in ipairs(A:FindFirstChild("Garages") and A.Garages:GetChildren() or {}) do
        local pp = g:FindFirstChild("MoneyBuy", true)
        if pp and pp:IsA("ProximityPrompt") and not g:GetAttribute("Open") and g:FindFirstChild("Cache") then
            list[#list + 1] = { g = g, pp = pp }
        end
    end
    return list
end
-- one open; returns a result table or nil, reason (nothing spent)
function AUC.openOne(budgetLeft)
    local free = AUC.free()
    if #free == 0 then return nil, "every auction garage is taken right now" end
    local pick = free[1]
    local shown = tonumber((pick.pp.ActionText:gsub("[^%d]", "")))
    if shown ~= AUC.price then return nil, "price reads " .. pick.pp.ActionText .. ", expected 75,000€" end
    if shown > budgetLeft then return nil, "run budget used up" end
    if myMoney() - shown < aucFloor() then return nil, ("opening would drop you under %s"):format(money(aucFloor())) end
    local m0, before = myMoney(), {}
    for _, e in ipairs(entries()) do before[e] = true end
    local asked
    confirmFn = function(text) -- only this garage's price, and only if the floor still holds
        asked = text
        local p = tonumber((tostring(text):match("([%d,]+)%s*€") or ""):gsub(",", ""), 10)
        return p ~= nil and p <= AUC.price and myMoney() - p >= aucFloor()
    end
    local t0 = os.clock()
    tpTo(CFrame.new(pick.pp.Parent.WorldPosition + Vector3.new(0, 2, 0)))
    task.wait(0.8)
    fireproximityprompt(pick.pp)
    repeat task.wait(0.2) until pick.g:GetAttribute("Open") or os.clock() - t0 > 10
    confirmFn = nil
    task.wait(2.5) -- the prize lands after the gate opens
    local cache = {}
    for _, c in ipairs(pick.g.Cache:GetChildren()) do cache[#cache + 1] = c.Name end
    local cars = {}
    for _, e in ipairs(entries()) do if not before[e] then cars[#cars + 1] = entryModel(e) end end
    return {
        garage = pick.g.Name, opened = pick.g:GetAttribute("Open") == true, asked = asked,
        delta = myMoney() - m0, cache = cache, cars = cars, notify = lastNotify.t >= t0 and lastNotify.text or nil,
    }
end
function AUC.start()
    if AUC.running then return end
    AUC.running = true
    task.spawn(function()
        local count, budget = math.max(0, math.floor(CFG.aucCount or 1)), math.max(0, CFG.aucBudget or AUC.price)
        -- "Total spend": the budget caps what goes in (wins never refill it). "Net loss": it caps how far down the run
        -- may get, so wins let it continue. Either way an open only starts if losing its whole 75K stays within budget.
        local netMode = CFG.aucMode == "Net loss"
        local spent, net, n = 0, 0, 0
        AUC.runLog = {}
        while running and AUC.running and n < count do
            if STAFF.gated() then AUC.status = "blocked: " .. STAFF.gateMsg break end
            if busy or manualPending then
                AUC.status = "waiting for " .. tostring(busy and busyWhat or "a button")
                local t = os.clock()
                repeat task.wait(0.5) until not (busy or manualPending) or os.clock() - t > 120 or not AUC.running
                if busy or manualPending or not AUC.running then AUC.status = "stopped: still busy" break end
            end
            busy, busyWhat = true, "opening an auction"
            AUC.status = ("opening %d of %d..."):format(n + 1, count)
            local okR, r, why = pcall(AUC.openOne, netMode and (budget + net) or (budget - spent))
            busy = false
            if not okR then AUC.status = "error: " .. tostring(r); log("auction: " .. tostring(r)) break end
            if not r then AUC.status = "stopped: " .. tostring(why) break end
            if not r.opened then
                AUC.status = "the garage didn't open (nothing bought?): " .. tostring(r.notify or r.asked or "no reply")
                log("auction: " .. AUC.status)
                break
            end
            n += 1; spent += AUC.price
            local prize = r.delta + AUC.price -- money back from this open (0 if the prize was a car)
            net += prize - AUC.price
            local A = STATE.auction
            A.opened += 1; A.spent += AUC.price; A.won += math.max(0, prize)
            for _, c in ipairs(r.cars) do A.cars[#A.cars + 1] = c end
            saveState()
            local line = ("%s: %s%s%s"):format(r.garage, prize > 0 and ("+" .. money(prize)) or "no cash",
                #r.cars > 0 and (" · car: " .. table.concat(r.cars, ", ")) or "", #r.cache > 0 and (" · [" .. table.concat(r.cache, ",") .. "]") or "")
            AUC.runLog[#AUC.runLog + 1] = line
            log("auction " .. line)
            lifeLog("auction " .. line .. " | " .. tostring(r.asked) .. " | " .. tostring(r.notify))
            local rare = false
            for _, c in ipairs(r.cars) do if RARE[c] then rare = true end end
            if rare then notify("RARE auction car: " .. table.concat(r.cars, ", ")) end
            if rare and CFG.aucStopRare then AUC.status = "stopped: rare car won!" break end
            AUC.status = netMode and ("done %d of %d · run net %s · can lose %s more"):format(n, count, money(net), money(math.max(0, budget + net)))
                or ("done %d of %d · spent %s of %s · run net %s"):format(n, count, money(spent), money(budget), money(net))
        end
        AUC.running = false
        if CFG.homeAfterTp and running then goHome(true) end
    end)
end
getgenv().FIU_MAIN.auction = AUC -- for scripted tests

local AucBox = Tabs.Junk:AddLeftGroupbox("Auctions", "gavel")
AucBox:AddLabel("Each open costs 75,000€ and the prize is rolled when you buy, so it can't be predicted. Odds (the game's own list): "
    .. "junk car 40% · €65K 30.5% · €70K 15% · €75K 8% · €150K 4% · €200K 2% · rare car 0.5%. Average return is about €46K cash "
    .. "+ a junk car per €75K: a loss. Only for hunting the rare cars.", true)
AucBox:AddInput("FIU_AucCount", { Text = "Opens per run", Default = tostring(CFG.aucCount or 1), Numeric = true, Finished = true,
    Callback = function(v) CFG.aucCount = math.max(0, math.floor(tonumber(v) or 1)) end })
AucBox:AddDropdown("FIU_AucMode", { Text = "Budget counts", Values = { "Total spend", "Net loss" }, Default = CFG.aucMode,
    Tooltip = "Total spend (strict): every 75K counts, wins never refill it. Net loss: stops once the run is down by the budget, "
        .. "so wins let it keep going (on average it still loses ~€20K per open).", Callback = set("aucMode") })
AucBox:AddInput("FIU_AucBudget", { Text = "Budget per run (€)", Default = tostring(CFG.aucBudget or 75000), Numeric = true, Finished = true,
    Tooltip = "No open starts unless losing its whole 75K stays within this", Callback = function(v) CFG.aucBudget = math.max(0, tonumber(v) or 0) end })
AucBox:AddInput("FIU_AucFloor", { Text = "Never go below (€)", Default = tostring(CFG.aucFloor or 300000), Numeric = true, Finished = true,
    Tooltip = "No open happens if it would leave you under this (or the Settings reserve, whichever is higher)",
    Callback = function(v) CFG.aucFloor = math.max(0, tonumber(v) or 0) end })
AucBox:AddToggle("FIU_AucStopRare", { Text = "Stop when a rare car hits", Default = CFG.aucStopRare, Callback = set("aucStopRare") })
AucBox:AddButton({ Text = "Open auctions", DoubleClick = true, Tooltip = "Double-click. Uses the 75,000€ prompt only, never Robux.", Func = function()
    if STAFF.gated() then notify("Blocked: " .. STAFF.gateMsg) return end
    AUC.start()
end })
AucBox:AddButton({ Text = "Stop", Func = function() AUC.running = false; AUC.status = "stopping after this open" end })
local aucLabel = AucBox:AddLabel("-", true)
task.spawn(function()
    while running do
        local A = STATE.auction
        pcall(function()
            aucLabel:SetText(("%s\n%s\nAll time: %d opened · spent %s · cash back %s · net %s%s"):format(AUC.status,
                #AUC.runLog > 0 and table.concat(AUC.runLog, "\n") or "no opens this run", A.opened, money(A.spent), money(A.won),
                money(A.won - A.spent), #A.cars > 0 and ("\nCars won: " .. table.concat(A.cars, ", ")) or ""))
        end)
        task.wait(1)
    end
end)
end

-- Auto
local AutoBox = Tabs.Auto:AddLeftGroupbox("Flip loop", "refresh-cw")
AutoBox:AddLabel("Buys junk cars that pass the filters, repairs them at the repair shop, sells them at Used Cars once the sell timer allows. Only cars bought by this script are ever sold.", true)
AutoBox:AddToggle("FIU_AutoBuy", { Text = "Auto buy", Default = CFG.autoBuy, Callback = set("autoBuy") })
AutoBox:AddToggle("FIU_AutoRepair", { Text = "Auto repair after buy", Default = CFG.autoRepair, Callback = set("autoRepair") })
AutoBox:AddToggle("FIU_AutoSell", { Text = "Auto sell", Tooltip = "Only sells cars this script bought", Default = CFG.autoSell, Callback = set("autoSell") })
AutoBox:AddToggle("FIU_CleanAfter", { Text = "Clean after auto repair", Default = CFG.cleanAfter, Callback = set("cleanAfter") })
AutoBox:AddToggle("FIU_PaintAfter", { Text = "Paint after auto repair", Tooltip = "Uses the finish and color set in Garage > Car actions",
    Default = CFG.paintAfter, Callback = set("paintAfter") })
local autoLabel = AutoBox:AddLabel("-", true)

do
local HomeBox = Tabs.Auto:AddLeftGroupbox("Home", "house")
HomeBox:AddLabel("A quiet spot of your choosing. With Return after tp on, anything that teleports you (auto or buttons) ends back here instead of at the junkyard or the sell NPC.", true)
local homeLabel = HomeBox:AddLabel("-", true)
local function showHome()
    local h = STATE.home
    homeLabel:SetText(h and ("Home set at %d, %d, %d"):format(h[1], h[2], h[3]) or "No home set")
end
HomeBox:AddToggle("FIU_HomeAfterTp", { Text = "Return after tp", Default = CFG.homeAfterTp,
    Tooltip = "Back home after anything that teleported you: auto buy/repair/sell, Buy car, Sell, Repair, Clean, Paint, swaps, and when the distance farm stops. Teleport buttons and Hood are left alone.",
    Callback = set("homeAfterTp") })
HomeBox:AddButton({ Text = "Set home here", Func = function()
    local r = hrp()
    if not r then return end
    local p, l = r.Position, r.CFrame.LookVector
    STATE.home = { p.X, p.Y, p.Z, l.X, l.Z }
    saveState(); showHome(); notify("Home set")
end })
HomeBox:AddButton({ Text = "Go home", Func = function()
    if not STATE.home then notify("No home set") return end
    goHome(true)
end })
HomeBox:AddButton({ Text = "Clear home", DoubleClick = true, Func = function() STATE.home = nil; saveState(); showHome() end })
showHome()
end

do
local Filt = Tabs.Auto:AddRightGroupbox("Buy filters", "filter")
local buyTier, buyPct
local function showBuyBy()
    if buyTier then buyTier:SetVisible(CFG.buyBy ~= "Spawn chance") end
    if buyPct then buyPct:SetVisible(CFG.buyBy == "Spawn chance") end
end
Filt:AddDropdown("FIU_BuyBy", { Text = "Buy by", Values = { "Tier", "Spawn chance" }, Default = CFG.buyBy,
    Tooltip = "Pick one: a tier and rarer, or a spawn % and rarer", Callback = function(v) CFG.buyBy = v; showBuyBy() end })
buyTier = Filt:AddDropdown("FIU_BuyTier", { Text = "Tier at least", Values = { "S", "A", "B", "C", "D" }, Default = CFG.buyMinTier, Callback = set("buyMinTier") })
buyPct = Filt:AddInput("FIU_BuyPct", { Text = "Spawn chance at most (%)", Default = tostring(CFG.buyMaxPct), Numeric = true, Finished = true,
    Tooltip = "e.g. 0.25 buys only cars that spawn 0.25% of the time or less",
    Callback = function(v) CFG.buyMaxPct = math.max(0, tonumber(v) or 0) end })
showBuyBy()
Filt:AddDropdown("FIU_BuyModels", { Text = "Only these models", Tooltip = "None picked = any model", Values = CAT_NAMES, Multi = true, Default = {},
    Callback = function(v) CFG.buyModels = v end })
Filt:AddSlider("FIU_BuyMax", { Text = "Max price", Default = CFG.buyMaxPrice, Min = 1000, Max = 500000, Rounding = 0, Suffix = "€", Callback = set("buyMaxPrice") })
Filt:AddSlider("FIU_BuyProfit", { Text = "Min profit", Default = CFG.buyMinProfit, Min = 0, Max = 100000, Rounding = 0, Suffix = "€",
    Tooltip = "Profit = price x profit multiplier (sale at 100% condition)", Callback = set("buyMinProfit") })

local Timer = Tabs.Auto:AddRightGroupbox("Sell timer", "timer")
Timer:AddLabel("The server refuses to sell a car for a while after you buy it. 0 = learn it from the first refusal (saved).", true)
Timer:AddSlider("FIU_SellCd", { Text = "Sell timer", Default = math.ceil(CFG.sellCooldown / 60), Min = 0, Max = 60, Rounding = 0, Suffix = " min",
    Callback = function(v) CFG.sellCooldown = v * 60; saveState() end })

end
-- Car
local CarBox = Tabs.Car:AddLeftGroupbox("Your cars", "car-front")
local carDrop = CarBox:AddDropdown("FIU_CarPick", { Text = "Car", Values = {}, AllowNull = true })
local carByLabel = {}
local keepingCar = false -- set while the list refreshes, so the rebuild can't clear your pick
carDrop:OnChanged(function(v)
    if keepingCar then return end
    selectedCar = v and carByLabel[v] or nil
end)
CarBox:AddButton({ Text = "Spawn car here", Func = run("spawn", function()
    if selectedCar then local r = hrp(); spawnCar(selectedCar, r.CFrame * CFrame.new(0, 2, -12)) end
end) })
CarBox:AddButton({ Text = "Teleport to car", Func = run("tp car", function()
    local c = selectedCar and carOf(selectedCar)
    if c then tpTo(c:GetPivot() * CFrame.new(0, 3, 8)) end
end) })
CarBox:AddButton({ Text = "Repair", Tooltip = "Teleports the car to the repair shop floor and fixes every worn part", Func = run("repair", function()
    if not selectedCar then return end
    local ok, msg = repairCar(selectedCar)
    if ok and isFlip(selectedCar) then OWNED[selectedCar.Name].repaired = true; saveOwned() end
    log(msg); notify(msg)
end) })
CarBox:AddButton({ Text = "Sell", DoubleClick = true, Tooltip = "Double-click. Favorites are locked and never sold.", Func = run("sell", function()
    if not selectedCar then return end
    local ok, msg = sellCar(selectedCar, true)
    log(msg); notify(msg)
end) })
CarBox:AddButton({ Text = "Open / close hood", Func = run("hood", function()
    local c = selectedCar and carOf(selectedCar)
    local cd = c and c:FindFirstChild("Misc") and c.Misc:FindFirstChild("Hood") and c.Misc.Hood:FindFirstChild("ClickDetector", true)
    if cd then tpTo(hoodSpot(c)); task.wait(0.3); fireclickdetector(cd) end
end) })
local carInfo = CarBox:AddLabel("-", true)

local FavBox = Tabs.Car:AddRightGroupbox("Favorites / collection", "star")
FavBox:AddLabel("Locked cars are never sold, and the auto loop never touches them. Pick a car above, then lock it.", true)
FavBox:AddButton({ Text = "★ Lock selected car", Func = function()
    if selectedCar then FAV[selectedCar.Name] = entryModel(selectedCar); saveFav(); log("locked " .. entryModel(selectedCar)) end
end })
FavBox:AddButton({ Text = "Unlock selected car", DoubleClick = true, Func = function()
    if selectedCar and FAV[selectedCar.Name] then FAV[selectedCar.Name] = nil; saveFav(); log("unlocked " .. entryModel(selectedCar)) end
end })
FavBox:AddToggle("FIU_AutoLock", { Text = "Auto lock tier", Default = CFG.autoLock,
    Tooltip = "Cars the script buys at this tier or rarer (or the models below) are locked right away and never sold",
    Callback = function(v)
        CFG.autoLock = v
        if v then for _, e in ipairs(entries()) do maybeAutoLock(e) end end
    end })
FavBox:AddDropdown("FIU_AutoLockTier", { Text = "Lock tier and rarer", Values = { "EX", "S", "A", "B", "C" }, Default = CFG.autoLockTier,
    Tooltip = "EX exclusive, S up to 0.1%, A up to 1%, B up to 5%, C up to 15%",
    Callback = function(v) CFG.autoLockTier = v; for _, e in ipairs(entries()) do maybeAutoLock(e) end end })
FavBox:AddDropdown("FIU_AutoLockModels", { Text = "Also lock these models", Values = CAT_NAMES, Multi = true, Default = {},
    Callback = function(v) CFG.autoLockModels = v; for _, e in ipairs(entries()) do maybeAutoLock(e) end end })
FavBox:AddToggle("FIU_AutoLockPctOn", { Text = "Auto lock by spawn chance", Default = CFG.autoLockPctOn,
    Tooltip = "Separate from the tier lock: cars the script buys at or under this spawn % are locked right away",
    Callback = function(v)
        CFG.autoLockPctOn = v
        if v then for _, e in ipairs(entries()) do maybeAutoLock(e) end end
    end })
FavBox:AddInput("FIU_AutoLockPct", { Text = "Lock at or under (%)", Default = tostring(CFG.autoLockPct), Numeric = true, Finished = true,
    Tooltip = "e.g. 0.25 catches the rare end of A tier (A goes up to 1%)",
    Callback = function(v) CFG.autoLockPct = math.max(0, tonumber(v) or 0); for _, e in ipairs(entries()) do maybeAutoLock(e) end end })
local favLabel = FavBox:AddLabel("-", true)

do
local RepBox = Tabs.Car:AddRightGroupbox("Repair settings", "wrench")
RepBox:AddDropdown("FIU_Station", { Text = "Repair shop", Values = { "Quietest", "Dealership", "Pitstop (large)", "Pitstop (small) south", "Pitstop (small) west" },
    Default = CFG.station == "Pitstop" and "Pitstop (large)" or CFG.station,
    Tooltip = "Quietest = whichever shop has the fewest other players around when a repair starts. Pitstop (large) is the busy one.",
    Callback = function(v) CFG.station = v; ST.quiet.t = 0 end })
RepBox:AddSlider("FIU_RepMin", { Text = "Repair parts worn at least", Default = CFG.repairMin, Min = 1, Max = 90, Rounding = 0, Suffix = "%", Callback = set("repairMin") })
RepBox:AddToggle("FIU_Replace", { Text = "Replace parts with no machine", Default = CFG.replaceWorn,
    Tooltip = "Sparkplugs, injectors, timing belts...: buys a new one at the parts store", Callback = set("replaceWorn") })
RepBox:AddToggle("FIU_PartEsp", { Text = "Show my loose parts", Default = false, Tooltip = "Wear + the game's 90 s delete countdown", Callback = set("partEsp") })

local ActBox = Tabs.Car:AddRightGroupbox("Car actions", "sparkles")
-- the pump's own remote works from anywhere (measured: +1 L for €2 far from any station); pays the cheapest station's price
ActBox:AddButton({ Text = "Refuel", Tooltip = "Fills the tank of the car picked above from anywhere, at the cheapest station's price", Func = run("refuel", function()
    local e = selectedCar
    if not e then notify("Pick a car above first") return end
    local car = carOf(e)
    if not car then notify("Spawn the car first (Spawn car here)") return end
    local tc = car:FindFirstChild("A-Chassis Tune") and car["A-Chassis Tune"]:FindFirstChild("TuneChanges")
    local max = tc and tc:FindFirstChild("MaxFuel") and tc.MaxFuel.Value or 40
    local kind = tc and tc:FindFirstChild("Fuel") and tc.Fuel.Value or "Petrol"
    local fuel = car.Values:FindFirstChild("Fuel")
    local need = math.floor((max - (fuel and fuel.Value or 0)) * 100) / 100
    if need <= 0.05 then notify("The tank is already full") return end
    local price
    for _, d in ipairs(workspace.Map:GetDescendants()) do
        local p = d.Name == "Prompts" and tonumber(d:GetAttribute(kind .. "Price")) -- each station keeps its prices on its Prompts (was once a string: compare crash)
        if p and (not price or p < price) then price = p end
    end
    price = price or 1.6
    local cost = math.round(need * price)
    if myMoney() < cost then notify("Not enough money for " .. money(cost)) return end
    local before = fuel and fuel.Value or 0
    Events.Vehicles.GasStation:FireServer(car, need, price)
    task.wait(1.5)
    local msg = ("Refuelled %s: %.1f L for %s"):format(entryModel(e), (fuel and fuel.Value or 0) - before, money(cost))
    log(msg); notify(msg)
end) })
ActBox:AddButton({ Text = "Clean", Tooltip = "Puts the car in the nearest car wash and washes it (~10 s)", Func = run("clean", function()
    if not selectedCar then notify("Pick a car above first") return end
    local _, msg = cleanCar(selectedCar)
    log(msg); notify(msg)
end) })
local matLabels, matByLabel = {}, {}
for _, n in ipairs(MATERIALS) do
    local m = RS.Assets.CarMaterials:FindFirstChild(n)
    local l = ("%s  %s"):format(n, money(m and m:GetAttribute("Price") or 0))
    matLabels[#matLabels + 1] = l; matByLabel[l] = n
end
ActBox:AddDropdown("FIU_PaintMat", { Text = "Paint finish", Values = matLabels, Default = matLabels[1],
    Callback = function(v) CFG.paintMaterial = matByLabel[v] or "Normal" end })
ActBox:AddLabel("Paint color"):AddColorPicker("FIU_PaintCol", { Default = CFG.paintColor, Title = "Paint color",
    Callback = function(c) CFG.paintColor = c end })
ActBox:AddToggle("FIU_PaintRandom", { Text = "Random color", Default = CFG.paintRandom, Callback = set("paintRandom") })
ActBox:AddButton({ Text = "Paint", Tooltip = "Puts the car in the paint booth and paints it", Func = run("paint", function()
    if not selectedCar then return end
    local _, msg = paintCar(selectedCar, paintColor(), CFG.paintMaterial)
    log(msg); notify(msg)
end) })

end
do
-- Car lookup: search any car in the game. Catalog numbers come from ReplicatedStorage.Cache.CarList; engines,
-- gearboxes and weight come from the car's "A-Chassis Tune" (decompiled, since requiring a loose copy errors),
-- fetched the way the game's garage does it (GetModel) and cached in FixItUp/cars.json.
do
    local CARS_FILE = DIR .. "/cars.json"
    local CC = readJSON(CARS_FILE, {})
    local fetching = {}

    local function parseTune(src)
        local function list(key)
            local blk = src:match("%." .. key .. " = (%b{})")
            local t = {}
            if blk then for v in blk:gmatch('"([^"]+)"') do t[#t + 1] = v end end
            return t
        end
        local function num(key) return tonumber(src:match("%." .. key .. " = (%-?[%d%.]+)")) end
        return { engines = list("DefaultEngines"), trans = list("DefaultTransmission"), maxSize = num("MaxEngineSize"),
            weight = num("Weight"), body = list("StartBody") }
    end
    do
        local t = parseTune('v1.DefaultEngines = { "V8 4.0" };\nv1.DefaultTransmission = { "8-Speed TC", "7-Speed DCT" };\nv1.MaxEngineSize = 6;\nv1.Weight = 2395;')
        assert(t.engines[1] == "V8 4.0" and #t.trans == 2 and t.maxSize == 6 and t.weight == 2395, "parseTune self-check")
    end

    local function tuneSource(m)
        local tune = m and m:FindFirstChild("A-Chassis Tune")
        if not tune then return nil end
        local ok, src = pcall(decompile, tune)
        return ok and type(src) == "string" and src:find("DefaultEngines") and src or nil
    end

    local function tuneOf(name) -- cached, then any copy already on the client, then ask the server like the garage does
        if CC[name] then return CC[name] end
        local src
        local cache = RS.Cache:FindFirstChild("Vehicles")
        src = tuneSource(cache and cache:FindFirstChild(name))
        if not src then
            for _, v in ipairs(Vehicles:GetChildren()) do
                if v:GetAttribute("Model") == name then src = tuneSource(v); if src then break end end
            end
        end
        if not src then
            local ok, id = pcall(function() return Events.Vehicles.GetModel:InvokeServer(name, true) end)
            if ok and typeof(id) == "string" then
                local t, m = os.clock(), nil
                repeat m = LP.PlayerGui:FindFirstChild(id); task.wait(0.1) until (m and m:FindFirstChild("A-Chassis Tune")) or os.clock() - t > 15
                src = tuneSource(m)
                local fd = m and m:FindFirstChild("ForceDelete")
                if fd then fd:FireServer() end -- tell the server we're done with the preview copy, as the game does
            end
        end
        if not src then return nil end
        local info = parseTune(src)
        CC[name] = info
        writeJSON(CARS_FILE, CC)
        return info
    end

    local engineStats = {}
    local function engineInfo(eng) -- from the engine block's PartInfo in the parts store
        if engineStats[eng] ~= nil then return engineStats[eng] end
        local cat = SPARE.Parts:FindFirstChild(eng)
        local blk = cat and cat:FindFirstChild("EngineBlock")
        local pi = blk and blk:FindFirstChild("PartInfo")
        local info = false
        if pi then
            local ok, s = pcall(decompile, pi)
            if ok and type(s) == "string" then
                info = { size = tonumber(s:match("EngineSize = ([%d%.]+)")), hp = tonumber(s:match("HPLimit = ([%d%.]+)")),
                    torque = tonumber(s:match("PeakTorque = ([%d%.]+)")), redline = tonumber(s:match("Redline = ([%d%.]+)")),
                    fuel = s:match('Fuel = "(%a+)"'), price = blk:GetAttribute("Price") }
            end
        end
        engineStats[eng] = info
        return info
    end
    local function engineLine(eng)
        local e = engineInfo(eng)
        if not e then return eng end
        return ("%s · %s Nm · %s rpm · HP limit %s · %s · block %s"):format(eng, tostring(e.torque or "?"), tostring(e.redline or "?"),
            tostring(e.hp or "?"), e.fuel or "?", money(e.price or 0))
    end

    local names = {}
    for _, c in ipairs(RS.Cache.CarList:GetChildren()) do names[#names + 1] = c.Name end
    table.sort(names)

    local Look = Tabs.Junk:AddLeftGroupbox("Car lookup", "search")
    local lookDrop = Look:AddDropdown("FIU_Lookup", { Text = "Search any car", Values = names, Searchable = true, AllowNull = true })
    local lookLabel = Look:AddLabel("Pick a car to see its rarity, price, profit and engines.", true)
    -- filter the search by engine / engine size (needs each car's tune: "Load all car data" fetches and saves them)
    local F = { engine = "Any", size = "Any", loading = false, done = 0 }
    do
        local sizes, seen = { "Any" }, {}
        for _, c in ipairs(SPARE.Parts:GetChildren()) do
            local e = engineInfo(c.Name)
            if e and e.size and not seen[e.size] then seen[e.size] = true; sizes[#sizes + 1] = e.size end
        end
        table.sort(sizes, function(a, b) if a == "Any" then return true elseif b == "Any" then return false end return a < b end)
        for i, v in ipairs(sizes) do sizes[i] = tostring(v) end
        F.sizes = sizes
        local engines = { "Any" }
        for _, c in ipairs(SPARE.Parts:GetChildren()) do if c:FindFirstChild("EngineBlock") then engines[#engines + 1] = c.Name end end
        table.sort(engines, function(a, b) if a == "Any" then return true elseif b == "Any" then return false end return a < b end)
        F.engines = engines
    end
    function F.matches(name)
        if F.engine == "Any" and F.size == "Any" then return true end
        local t = CC[name]
        if not t then return false end
        for _, eng in ipairs(t.engines) do
            local e = engineInfo(eng)
            if (F.engine == "Any" or eng == F.engine) and (F.size == "Any" or (e and tostring(e.size) == F.size)) then return true end
        end
        return false
    end
    function F.apply()
        local vals, unknown = {}, 0
        for _, n in ipairs(names) do
            if F.matches(n) then vals[#vals + 1] = n elseif not CC[n] then unknown += 1 end
        end
        lookDrop:SetValues(vals)
        local filtered = F.engine ~= "Any" or F.size ~= "Any"
        F.label:SetText(("%d car%s%s"):format(#vals, #vals == 1 and "" or "s",
            filtered and unknown > 0 and (" · %d not loaded yet, press Load all car data"):format(unknown) or ""))
    end
    Look:AddDropdown("FIU_LookEngine", { Text = "Filter: engine", Values = F.engines, Default = "Any", Searchable = true,
        Callback = function(v) F.engine = v or "Any"; F.apply() end })
    Look:AddDropdown("FIU_LookSize", { Text = "Filter: engine size", Values = F.sizes, Default = "Any",
        Callback = function(v) F.size = v or "Any"; F.apply() end })
    F.label = Look:AddLabel("-", true)
    Look:AddButton({ Text = "Load all car data", Tooltip = "Fetches every car's engines once (a few minutes) and saves them", Func = function()
        if F.loading then return end
        F.loading = true
        task.spawn(function()
            local todo = {}
            for _, n in ipairs(names) do if not CC[n] then todo[#todo + 1] = n end end
            -- the server stops answering GetModel after ~30 quick calls: 1.5 s apart, backing off while it refuses
            local gap = 1.5
            for i, n in ipairs(todo) do
                if not running then break end
                local ok, info = pcall(tuneOf, n)
                if not (ok and info) then
                    gap = math.min(gap * 2, 20)
                    task.wait(gap)
                    pcall(tuneOf, n)
                else
                    gap = math.max(1.5, gap * 0.8)
                end
                F.label:SetText(("Loading car data %d / %d"):format(i, #todo))
                task.wait(gap)
            end
            F.loading = false
            F.apply()
            notify("Car data loaded")
        end)
    end })
    task.defer(F.apply)
    getgenv().FIU_MAIN.carLookup = { F = F, tuneOf = tuneOf, cache = CC, names = names } -- for scripted tests
    local shown

    local function render(name)
        local cat = RS.Cache.CarList:FindFirstChild(name)
        if not cat then return "Unknown car" end
        local price, pm, sc = cat:GetAttribute("Price"), cat:GetAttribute("ProfitMultiplier") or 0, cat:GetAttribute("SpawnChance") or 0
        local lo, hi = typeof(price) == "NumberRange" and price.Min or 0, typeof(price) == "NumberRange" and price.Max or 0
        local tier = tierOf(sc, sc <= 0)
        local L = { ('<font color="%s"><b>[%s] %s</b></font>'):format(hex(CFG.color[tier]), tier, name) }
        L[#L + 1] = sc > 0 and ("Rarity %s · %s spawn chance in the junkyard"):format(TIER_TEXT[tier], chanceText(sc))
            or "Doesn't spawn in the junkyard (dealership, event or exclusive)"
        if hi > 0 then
            L[#L + 1] = ("Junk price %s – %s · profit ×%s"):format(money(lo), money(hi), tostring(pm))
            L[#L + 1] = ("Profit %s – %s · sells for %s – %s at 100%%"):format(money(lo * pm), money(hi * pm), money(lo * (1 + pm)), money(hi * (1 + pm)))
        end
        local flags = {}
        if cat:GetAttribute("NoRust") then flags[#flags + 1] = "never rusty" end
        if cat:GetAttribute("ShowEngine") then flags[#flags + 1] = "open engine" end
        if #flags > 0 then L[#L + 1] = table.concat(flags, " · ") end
        -- where it is right now
        local junkN = 0
        for _, j in pairs(junk) do for _, n in ipairs(j.names) do if n == name then junkN += 1 end end end
        local mine, others = 0, {}
        for _, e in ipairs(entries()) do if entryModel(e) == name then mine += 1 end end
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then
                local g = p:FindFirstChild("PlayerData") and p.PlayerData:FindFirstChild("Garage")
                for _, e in ipairs(g and g:GetChildren() or {}) do if entryVal(e, "Model") == name then others[#others + 1] = p.DisplayName end end
            end
        end
        L[#L + 1] = ("In the junkyard now: %d · you own %d%s"):format(junkN, mine, #others > 0 and (" · also owned by " .. table.concat(others, ", ")) or "")
        -- engines and the rest from the car's tune
        local t = CC[name]
        if not t then
            L[#L + 1] = fetching[name] and "Loading engines..." or "Engines not loaded"
        else
            L[#L + 1] = "<b>Engines it can spawn with</b>"
            for _, eng in ipairs(t.engines) do L[#L + 1] = "  " .. engineLine(eng) end
            if #t.trans > 0 then L[#L + 1] = "Gearboxes: " .. table.concat(t.trans, ", ") end
            if t.maxSize then
                local fits = {}
                for _, c in ipairs(SPARE.Parts:GetChildren()) do
                    local e = engineInfo(c.Name)
                    if e and e.size and e.size <= t.maxSize then fits[#fits + 1] = c.Name end
                end
                table.sort(fits)
                L[#L + 1] = ("Max engine size %s · swaps that fit: %s"):format(tostring(t.maxSize), #fits > 0 and table.concat(fits, ", ") or "none")
            end
            if t.weight then L[#L + 1] = ("Weight %s"):format(tostring(t.weight)) end
        end
        return table.concat(L, "\n")
    end

    lookDrop:OnChanged(function(name)
        shown = name
        if not name then lookLabel:SetText("Pick a car to see its rarity, price, profit and engines.") return end
        lookLabel:SetText(render(name))
        if not CC[name] and not fetching[name] then
            fetching[name] = true
            task.spawn(function()
                local ok, err = pcall(tuneOf, name)
                fetching[name] = nil
                if not ok then log("car lookup: " .. tostring(err)) end
                if shown == name then lookLabel:SetText(render(name)) end
            end)
            lookLabel:SetText(render(name))
        end
    end)
    task.spawn(function() -- keep the junkyard/owner counts fresh
        while running do
            task.wait(2)
            if shown then pcall(function() lookLabel:SetText(render(shown)) end) end
        end
    end)
end

-- Spec swap: put a different engine or gearbox in the selected car. Buys the new parts first (store clicks work from
-- anywhere), then pulls the old ones at the repair-shop spot and installs the new ones (block first).
do
    local ENGINES = {}
    for _, c in ipairs(SPARE.Parts:GetChildren()) do if c:FindFirstChild("EngineBlock") then ENGINES[#ENGINES + 1] = c.Name end end
    table.sort(ENGINES)
    local TRANS = {}
    for _, t in ipairs(SPARE.Parts.Transmission:GetChildren()) do TRANS[#TRANS + 1] = t.Name end
    table.sort(TRANS)

    local function slotOf(partName) return (partName:gsub("_.*$", "")) end -- AirIntake_Turbo -> AirIntake
    local function categoryOf(value) return (tostring(value):match("^([^|]+)")) end -- "V8 4.0|EngineBlock" -> "V8 4.0"
    assert(slotOf("AirIntake_Turbo") == "AirIntake" and slotOf("EngineBlock") == "EngineBlock" and categoryOf("V8 4.0|EngineBlock") == "V8 4.0"
        and categoryOf("i3 1.0") == "i3 1.0", "swap helpers self-check")

    -- the full set of store parts for an engine: one per slot, with the chosen intake / block variant
    local function engineKit(eng, intake, forged)
        local cat = SPARE.Parts:FindFirstChild(eng)
        if not cat then return nil end
        local bySlot = {}
        for _, p in ipairs(cat:GetChildren()) do
            local slot = slotOf(p.Name)
            local want = (slot == "AirIntake" and (intake == "Stock" and "AirIntake" or "AirIntake_" .. intake))
                or (slot == "EngineBlock" and (forged and "EngineBlock_Forged" or "EngineBlock")) or p.Name
            if p.Name == want then bySlot[slot] = p -- the variant you picked
            elseif p.Name == slot and not bySlot[slot] then bySlot[slot] = p end -- stock, unless the picked variant exists
        end
        local kit = {}
        for _, p in pairs(bySlot) do kit[#kit + 1] = p end
        table.sort(kit, function(a, b) return (slotOf(a.Name) == "EngineBlock" and 0 or 1) < (slotOf(b.Name) == "EngineBlock" and 0 or 1) end)
        return kit
    end
    local function kitCost(kit)
        local sum = 0
        for _, p in ipairs(kit or {}) do sum += tonumber(p:GetAttribute("Price")) or 0 end
        return sum
    end

    local function openHood(car)
        local function isOpen() local v = car.Values.Cache:FindFirstChild("IsHoodOpen"); return v ~= nil and v.Value end
        if isOpen() then return true end
        local hood = car:WaitForChild("Misc", 5) and car.Misc:WaitForChild("Hood", 5)
        local det = hood and hood:WaitForChild("Detector", 5)
        local cd = det and det:FindFirstChildWhichIsA("ClickDetector")
        if not cd then return false end
        tpTo(hoodSpot(car))
        local t = os.clock()
        repeat fireclickdetector(cd); task.wait(0.5) until isOpen() or os.clock() - t > 10 -- a fresh spawn ignores the hood ~4.5 s
        return isOpen()
    end

    local function dealWithOld(parts)
        for _, p in ipairs(parts) do
            if p.Parent == MoveParts then
                if CFG.swapOld == "Delete" then Events.PartsEvent:FireServer("DeletePart", p)
                else Events.PartsEvent:FireServer("StoreItem", p) end
                task.wait(0.25)
            end
        end
    end

    -- kit: store models to buy; pull: engine slots to empty first
    local function swap(e, kit, pull, label)
        local cost = kitCost(kit)
        if myMoney() - cost < CFG.reserve then return false, ("%s costs %s: not enough above your reserve"):format(label, money(cost)) end
        tpTo(liftCF() * CFrame.new(0, 0, 12))
        local car = spawnCar(e, liftCF())
        if not car then return false, "the car didn't come to the repair shop" end
        if not openHood(car) then return false, "couldn't open the hood" end
        -- 1) buy everything first, so a failed buy never leaves the car without an engine
        local bought = {}
        local mine0 = myParts()
        for _, m in ipairs(kit) do
            local p, why = buyStore(m)
            if not p then
                dealWithOld(bought)
                return false, ("couldn't buy %s (%s)"):format(m.Name, tostring(why))
            end
            bought[#bought + 1] = p
            mine0[p] = true
        end
        -- 2) pull the old parts (the engine block drags its attached parts off with it)
        local eng = car.Values.Engine
        for _, slot in ipairs(pull) do
            local v = eng:FindFirstChild(slot)
            if v and v.Value ~= "" then fireParts(e, "RemovePart", slot); task.wait(0.35) end
        end
        task.wait(1)
        local old = {}
        for p in pairs(myParts()) do if not mine0[p] then old[#old + 1] = p end end
        -- 3) install, block first; a second pass catches parts that needed the block
        for pass = 1, 2 do
            for _, p in ipairs(bought) do
                if p.Parent == MoveParts then fireParts(e, "ReapplyPart", p); task.wait(0.3) end
            end
            task.wait(0.8)
        end
        local left = 0
        for _, p in ipairs(bought) do if p.Parent == MoveParts then left += 1 end end
        -- 4) the old parts: into your inventory, or deleted
        dealWithOld(old)
        if left > 0 then return false, ("%s: %d new part(s) didn't fit, check the car"):format(label, left) end
        return true, ("%s done for %s (%d old part%s %s)"):format(label, money(cost), #old, #old == 1 and "" or "s",
            CFG.swapOld == "Delete" and "deleted" or "stored")
    end

    local function engineSlots(car, oldCat)
        local slots = {}
        for _, v in ipairs(car.Values.Engine:GetChildren()) do
            if v:IsA("StringValue") and v.Value ~= "" and v.Name ~= "Transmission" and v.Name ~= "Battery" and v.Name ~= "Radiator"
                and v.Name ~= "Suspension" and categoryOf(v.Value) == oldCat then
                slots[#slots + 1] = v.Name
            end
        end
        table.sort(slots, function(a, b) return (a == "EngineBlock" and 0 or 1) < (b == "EngineBlock" and 0 or 1) end)
        return slots
    end

    local sizeCache = {}
    local function maxEngineSize(car)
        local key = car and car:GetAttribute("Model")
        if key and sizeCache[key] ~= nil then return sizeCache[key] or nil end
        local tune = car and car:FindFirstChild("A-Chassis Tune")
        local ok, src = pcall(decompile, tune)
        local v = ok and type(src) == "string" and tonumber(src:match("%.MaxEngineSize = ([%d%.]+)")) or nil
        if key then sizeCache[key] = v or false end
        return v
    end
    local function engineSize(eng)
        local cat = SPARE.Parts:FindFirstChild(eng)
        local pi = cat and cat:FindFirstChild("EngineBlock") and cat.EngineBlock:FindFirstChild("PartInfo")
        local ok, src = pcall(decompile, pi)
        return ok and type(src) == "string" and tonumber(src:match("EngineSize = ([%d%.]+)")) or nil
    end

    -- ============ car to car: move or trade parts between two of your cars ============
    -- Only one of your cars can be out at a time, so: pull from A, pull from B, fit A's into B, bring A back, fit B's.
    -- Loose parts wait at the shop with their cleanup timer held off (the game's client deletes loose parts after 90 s).
    local X = { held = {} } -- car-to-car helpers live in one table (Luau caps a function at 200 locals)
    function X.slotsFor(car, what)
        local eng = car.Values.Engine
        local cur = categoryOf(eng.EngineBlock.Value)
        local slots = {}
        if what.Engine and cur then for _, s in ipairs(engineSlots(car, cur)) do slots[#slots + 1] = s end end
        for _, s in ipairs({ "Transmission", "Battery", "Radiator" }) do
            local key = s == "Transmission" and "Gearbox" or s
            if what[key] and eng:FindFirstChild(s) and eng[s].Value ~= "" then slots[#slots + 1] = s end
        end
        return slots
    end

    function X.holdParts(on)
        if on and not X.holdConn then
            X.holdConn = RunService.Heartbeat:Connect(function()
                for p in pairs(X.held) do
                    if p.Parent then p:SetAttribute("DroppedAt", nil) else X.held[p] = nil end
                end
            end)
        elseif not on and X.holdConn then
            X.holdConn:Disconnect(); X.holdConn = nil; table.clear(X.held)
        end
    end

    function X.pull(e, slots)
        tpTo(liftCF() * CFrame.new(0, 0, 12))
        local car = spawnCar(e, liftCF())
        if not car then return nil, "car didn't come to the shop" end
        if not openHood(car) then return nil, "couldn't open the hood" end
        local before = myParts()
        for _, s in ipairs(slots) do
            local v = car.Values.Engine:FindFirstChild(s)
            if v and v.Value ~= "" then fireParts(e, "RemovePart", s); task.wait(0.35) end
        end
        task.wait(1)
        local got = {}
        for p in pairs(myParts()) do if not before[p] then got[#got + 1] = p; X.held[p] = true end end
        return got
    end

    function X.fit(e, parts)
        tpTo(liftCF() * CFrame.new(0, 0, 12))
        local car = spawnCar(e, liftCF())
        if not car then return #parts, "car didn't come to the shop" end
        openHood(car)
        table.sort(parts, function(a, b) return (a.Name == "EngineBlock" and 0 or 1) < (b.Name == "EngineBlock" and 0 or 1) end)
        for pass = 1, 2 do
            for _, p in ipairs(parts) do if p.Parent == MoveParts then fireParts(e, "ReapplyPart", p); task.wait(0.3) end end
            task.wait(0.8)
        end
        local left = 0
        for _, p in ipairs(parts) do if p.Parent == MoveParts then left += 1 end end
        return left
    end

    -- ============ tyres: wheels only come off on a lift (server-enforced, measured 2026-09-28) ============
    -- Spawn the car onto the Dealership lift, press its Up button (OnLift=true in ~0.3 s), then RemovePart "FL".. gives
    -- one rim+tyre "Parts" model per corner; RenamePart(part, corner) + ReapplyPart puts one on.
    X.CORNERS = { "FL", "FR", "RL", "RR" }
    -- lift buttons: one press, then wait for the platform (Holder) to stop moving. Down takes ~3 s, Up ~3.5 s; presses
    -- while it moves are ignored, and hammering Up kept OnLift from ever being set (measured 2026-09-28).
    function X.holderY(lift) local h = lift:FindFirstChild("Holder", true); return h and h.Position.Y end
    function X.waitStill(lift, maxT)
        local t, last = os.clock(), X.holderY(lift)
        repeat
            task.wait(0.4)
            local y = X.holderY(lift)
            if y and last and math.abs(y - last) < 0.01 then return y end
            last = y
        until os.clock() - t > maxT
        return last
    end
    function X.liftCar(e)
        local folder = workspace.Map.FirstCity.Buildings.Dealership.Folder
        local lift
        for _, l in ipairs(folder:GetChildren()) do if l.Name == "Lift" and l:FindFirstChild("Up") then lift = l break end end
        if not lift then return nil, "no lift found" end
        streamAt(lift:GetPivot().Position, 5)
        local up = lift.Up:FindFirstChildWhichIsA("ClickDetector")
        local down = lift:FindFirstChild("Down") and lift.Down:FindFirstChildWhichIsA("ClickDetector")
        local button = CFrame.new(lift.Up:GetPivot().Position + Vector3.new(0, 2, 3))
        tpTo(button)
        local y = X.waitStill(lift, 5)
        if y and y > 3.1 and down then -- left up from before: bring it down (low ~2.35, high ~3.85)
            fireclickdetector(down)
            task.wait(0.5)
            X.waitStill(lift, 6)
        end
        local car = spawnCar(e, lift:GetPivot() * CFrame.new(0, 4, 0))
        if not car then return nil, "the car didn't come to the lift" end
        tpTo(button)
        task.wait(0.6)
        for _ = 1, 2 do
            fireclickdetector(up)
            local t = os.clock()
            repeat task.wait(0.3) until car:GetAttribute("OnLift") or os.clock() - t > 6
            if car:GetAttribute("OnLift") then break end
            X.waitStill(lift, 5)
        end
        if not car:GetAttribute("OnLift") then return nil, "the lift didn't go up" end
        X.waitStill(lift, 5)
        return car, lift
    end
    function X.lowerLift(lift)
        local down = lift and lift:FindFirstChild("Down") and lift.Down:FindFirstChildWhichIsA("ClickDetector")
        if not down then return end
        X.waitStill(lift, 5)
        fireclickdetector(down)
        task.wait(0.5)
        X.waitStill(lift, 6)
    end
    function X.pullWheels(e) -- corner -> wheel part
        local car, lift = X.liftCar(e)
        if not car then return nil, lift end
        local got = {}
        for _, corner in ipairs(X.CORNERS) do
            local v = car.Values.Wheels:FindFirstChild(corner)
            if v and v.Value ~= "" then
                local before = myParts()
                fireParts(e, "RemovePart", corner)
                local t = os.clock()
                repeat
                    task.wait(0.1)
                    for p in pairs(myParts()) do if not before[p] and p:GetAttribute("IsWheel") then got[corner] = p end end
                until got[corner] or os.clock() - t > 3
                if got[corner] then X.held[got[corner]] = true end
            end
        end
        X.lowerLift(lift)
        return got
    end
    function X.fitWheels(e, byCorner) -- putting wheels on needs no lift (measured), only taking them off does
        tpTo(liftCF() * CFrame.new(0, 0, 12))
        local car = spawnCar(e, liftCF())
        if not car then return 4, "the car didn't come to the shop" end
        for pass = 1, 2 do
            for corner, p in pairs(byCorner) do
                if p.Parent == MoveParts then
                    fireParts(e, "RenamePart", p, corner) -- tells the server which corner this wheel is for
                    task.wait(0.2)
                    fireParts(e, "ReapplyPart", p)
                    task.wait(0.3)
                end
            end
            task.wait(0.8)
        end
        local left = 0
        for _, p in pairs(byCorner) do if p.Parent == MoveParts then left += 1 end end
        return left
    end
    function X.tireTransfer(eFrom, eTo, mode)
        local fromA, why = X.pullWheels(eFrom)
        if not fromA then return 0, 0, why end
        local fromB, why2 = X.pullWheels(eTo)
        if not fromB then
            X.fitWheels(eFrom, fromA) -- never leave car A without wheels
            return 0, 0, why2 .. " (the first car's wheels were put back)"
        end
        local leftB = X.fitWheels(eTo, fromA)
        local leftA = 0
        if mode == "Swap" then leftA = X.fitWheels(eFrom, fromB)
        else
            local old = {}
            for _, p in pairs(fromB) do old[#old + 1] = p end
            dealWithOld(old)
        end
        local n = 0
        for _ in pairs(fromA) do n += 1 end
        return n, leftA + leftB
    end

    function X.transfer(eFrom, eTo, what, mode)
        if eFrom == eTo then return false, "pick two different cars" end
        -- engine sizes: read both tunes (each car has to be out once to read it)
        if what.Engine then
            local a = spawnCar(eFrom, liftCF())
            local aSize = a and engineSize(categoryOf(a.Values.Engine.EngineBlock.Value) or "")
            local aMax = a and maxEngineSize(a)
            local b = spawnCar(eTo, liftCF())
            local bSize = b and engineSize(categoryOf(b.Values.Engine.EngineBlock.Value) or "")
            local bMax = b and maxEngineSize(b)
            if aSize and bMax and aSize > bMax then return false, ("%s's engine (size %s) is too big for %s (takes %s)"):format(entryModel(eFrom), aSize, entryModel(eTo), bMax) end
            if mode == "Swap" and bSize and aMax and bSize > aMax then return false, ("%s's engine (size %s) is too big for %s (takes %s)"):format(entryModel(eTo), bSize, entryModel(eFrom), aMax) end
        end
        X.holdParts(true)
        local ok, res = pcall(function()
            local notes = {}
            if what.Tires then
                local n, left, why = X.tireTransfer(eFrom, eTo, mode)
                if why then return "tyres: " .. why end
                notes[#notes + 1] = ("%s %d wheel(s)%s"):format(mode == "Swap" and "swapped" or "moved", n, left > 0 and (" (%d didn't go on)"):format(left) or "")
            end
            if not (what.Engine or what.Gearbox or what.Battery or what.Radiator) then
                return ("%s: %s"):format(entryModel(eFrom) .. (mode == "Swap" and " <-> " or " -> ") .. entryModel(eTo), table.concat(notes, " · "))
            end
            local carA = spawnCar(eFrom, liftCF())
            if not carA then return "car A didn't spawn" end
            local fromA, why = X.pull(eFrom, X.slotsFor(carA, what))
            if not fromA then return why end
            local carB = spawnCar(eTo, liftCF())
            if not carB then return "car B didn't spawn (A's parts are waiting at the shop)" end
            local fromB, why2 = X.pull(eTo, X.slotsFor(carB, what))
            if not fromB then return why2 end
            local leftB = X.fit(eTo, fromA)
            local leftA = 0
            if mode == "Swap" then
                leftA = X.fit(eFrom, fromB)
            else
                dealWithOld(fromB) -- Move: B's old parts go to the inventory or get deleted
            end
            local leftover = {}
            for _, p in ipairs(fromA) do if p.Parent == MoveParts then leftover[#leftover + 1] = p end end
            if mode == "Swap" then for _, p in ipairs(fromB) do if p.Parent == MoveParts then leftover[#leftover + 1] = p end end end
            if #leftover > 0 then dealWithOld(leftover) end
            return ("%s %d part(s) %s %s%s%s"):format(mode == "Swap" and "swapped" or "moved", #fromA, mode == "Swap" and "between" or "from",
                entryModel(eFrom) .. (mode == "Swap" and " and " or " to ") .. entryModel(eTo),
                (leftA + leftB) > 0 and (" · %d didn't fit and went to %s"):format(leftA + leftB, CFG.swapOld == "Delete" and "the bin" or "your inventory") or "",
                #notes > 0 and (" · " .. table.concat(notes, " · ")) or "")
        end)
        X.holdParts(false)
        return ok, ok and res or ("error: " .. tostring(res))
    end

    local SwapBox = Tabs.Shop:AddRightGroupbox("Spec swap", "arrow-left-right")
    SwapBox:AddLabel("Works on the car picked in the Garage tab. The car goes to the repair shop; new parts are bought first, then the old ones come out and the new ones go in.", true)
    local engDrop = SwapBox:AddDropdown("FIU_SwapEngine", { Text = "Engine", Values = ENGINES, AllowNull = true, Searchable = true })
    local intakeDrop = SwapBox:AddDropdown("FIU_SwapIntake", { Text = "Intake", Values = { "Stock", "Sport", "Turbo" }, Default = "Stock",
        Tooltip = "Uses the stock intake if that engine has no Sport/Turbo one" })
    local forgedToggle = SwapBox:AddToggle("FIU_SwapForged", { Text = "Forged block (if the engine has one)", Default = false })
    local swapInfo = SwapBox:AddLabel("-", true)
    SwapBox:AddButton({ Text = "Swap engine", DoubleClick = true, Tooltip = "Double-click", Func = function()
        local e, eng = selectedCar, engDrop.Value
        if not e then notify("Pick a car in the Garage tab first") return end
        if not eng then notify("Pick an engine") return end
        queued("engine swap", function()
            local car = carOf(e)
            local cur = car and categoryOf(car.Values.Engine.EngineBlock.Value)
            if not car then
                car = spawnCar(e, liftCF()) -- need it out to read its current engine
                cur = car and categoryOf(car.Values.Engine.EngineBlock.Value)
            end
            if not car then notify("The car didn't spawn") return end
            local max, size = maxEngineSize(car), engineSize(eng)
            if max and size and size > max then notify(("%s is size %s, this car takes up to %s"):format(eng, tostring(size), tostring(max))) return end
            local pull = cur and engineSlots(car, cur) or { "EngineBlock" }
            local ok, msg = swap(e, engineKit(eng, intakeDrop.Value, forgedToggle.Value), pull, ("engine swap to %s"):format(eng))
            log(msg); notify(msg)
        end)
    end })
    local transDrop = SwapBox:AddDropdown("FIU_SwapTrans", { Text = "Gearbox", Values = TRANS, AllowNull = true })
    SwapBox:AddButton({ Text = "Swap gearbox", DoubleClick = true, Tooltip = "Double-click", Func = function()
        local e, tr = selectedCar, transDrop.Value
        if not e then notify("Pick a car in the Garage tab first") return end
        if not tr then notify("Pick a gearbox") return end
        queued("gearbox swap", function()
            local ok, msg = swap(e, { SPARE.Parts.Transmission[tr] }, { "Transmission" }, ("gearbox swap to %s"):format(tr))
            log(msg); notify(msg)
        end)
    end })
    SwapBox:AddDropdown("FIU_SwapOld", { Text = "Old parts", Values = { "Store in inventory", "Delete" }, Default = CFG.swapOld,
        Tooltip = "Inventory holds 10 items; anything that doesn't fit stays on the floor and the game clears it after 90 s",
        Callback = set("swapOld") })

    getgenv().FIU_MAIN.transfer = X.transfer -- for scripted tests
    X.box = Tabs.Shop:AddRightGroupbox("Car to car", "repeat-2")
    X.box:AddLabel("Takes parts out of one of your cars and puts them in another. Swap = the two cars trade; Move = the first car's parts replace the second's (its old parts go to your inventory or the bin, per Old parts above).", true)
    X.from = X.box:AddDropdown("FIU_XFrom", { Text = "From car", Values = {}, AllowNull = true })
    X.to = X.box:AddDropdown("FIU_XTo", { Text = "To car", Values = {}, AllowNull = true })
    X.what = X.box:AddDropdown("FIU_XWhat", { Text = "Parts", Values = { "Engine", "Gearbox", "Battery", "Radiator", "Tires" }, Multi = true,
        Default = { "Engine" } })
    X.mode = X.box:AddDropdown("FIU_XMode", { Text = "Mode", Values = { "Swap", "Move" }, Default = "Swap" })
    X.box:AddButton({ Text = "Transfer parts", DoubleClick = true, Tooltip = "Double-click", Func = function()
        local a, b = carByLabel[X.from.Value], carByLabel[X.to.Value]
        if not (a and b) then notify("Pick both cars") return end
        if not next(X.what.Value) then notify("Pick which parts") return end
        local what, mode = table.clone(X.what.Value), X.mode.Value
        queued("part transfer", function()
            local ok, msg = X.transfer(a, b, what, mode)
            log(msg); notify(msg)
        end)
    end })
    task.spawn(function() -- keep both car lists in step with your garage
        local lastKey = ""
        while running do
            local labels = {}
            for l in pairs(carByLabel) do labels[#labels + 1] = l end
            table.sort(labels)
            local key = table.concat(labels, "|")
            if key ~= lastKey then
                lastKey = key
                local fa, ta = carByLabel[X.from.Value], carByLabel[X.to.Value]
                X.from:SetValues(labels); X.to:SetValues(labels)
                for l, e2 in pairs(carByLabel) do
                    if e2 == fa then X.from:SetValue(l) end
                    if e2 == ta then X.to:SetValue(l) end
                end
            end
            task.wait(1)
        end
    end)

    task.spawn(function() -- price + fit preview for the picks
        while running do
            pcall(function()
                local lines = {}
                local car = selectedCar and carOf(selectedCar)
                if selectedCar then
                    local cur = car and categoryOf(car.Values.Engine.EngineBlock.Value)
                    local tr = car and car.Values.Engine.Transmission.Value:match("|(.+)$")
                    lines[#lines + 1] = ("Now: %s · %s%s"):format(cur or "?", tr or "?", car and "" or " (spawn the car to read it)")
                end
                if engDrop.Value then
                    local kit = engineKit(engDrop.Value, intakeDrop.Value, forgedToggle.Value)
                    local names = {}
                    for _, p in ipairs(kit or {}) do names[#names + 1] = p.Name end
                    local max, size = car and maxEngineSize(car), engineSize(engDrop.Value)
                    lines[#lines + 1] = ("%s kit %s: %s"):format(engDrop.Value, money(kitCost(kit)), table.concat(names, ", "))
                    if max and size then lines[#lines + 1] = size <= max and ("Fits (size %s of %s)"):format(tostring(size), tostring(max))
                        or ('<font color="#ff6b6b">Too big (size %s, car takes %s)</font>'):format(tostring(size), tostring(max)) end
                end
                if transDrop.Value then
                    lines[#lines + 1] = ("%s: %s"):format(transDrop.Value, money(SPARE.Parts.Transmission[transDrop.Value]:GetAttribute("Price") or 0))
                end
                swapInfo:SetText(#lines > 0 and table.concat(lines, "\n") or "Pick a car, then an engine or gearbox")
            end)
            task.wait(1.5)
        end
    end)
end

-- Shop
local ShopBox = Tabs.Shop:AddLeftGroupbox("Spare parts", "package")
local cats = {}
for _, c in ipairs(SPARE.Parts:GetChildren()) do cats[#cats + 1] = c.Name end
table.sort(cats)
local partDrop
local catDrop = ShopBox:AddDropdown("FIU_ShopCat", { Text = "Engine / category", Values = cats, AllowNull = true })
partDrop = ShopBox:AddDropdown("FIU_ShopPart", { Text = "Part", Values = {}, AllowNull = true })
local partByLabel = {}
catDrop:OnChanged(function(v)
    local vals = {}
    table.clear(partByLabel)
    local cat = v and SPARE.Parts:FindFirstChild(v)
    if cat then
        for _, p in ipairs(cat:GetChildren()) do
            local l = ("%s  %s"):format(p.Name, money(p:GetAttribute("Price")))
            vals[#vals + 1] = l; partByLabel[l] = p
        end
    end
    table.sort(vals)
    partDrop:SetValues(vals)
end)
ShopBox:AddButton({ Text = "Buy", Func = run("shop buy", function()
    local p = partByLabel[partDrop.Value]
    local new, why = buyStore(p)
    log(new and ("bought " .. p.Name) or ("buy failed: " .. tostring(why)))
end) })
ShopBox:AddButton({ Text = "Buy + install on selected car", Func = run("shop install", function()
    local p, c = partByLabel[partDrop.Value], selectedCar and carOf(selectedCar)
    if not c then notify("Spawn the selected car first") return end
    local new, why = buyStore(p)
    if new then fireParts(selectedCar, "ReapplyPart", new); log("installed " .. p.Name) else log("buy failed: " .. tostring(why)) end
end) })

local ToolBox = Tabs.Shop:AddLeftGroupbox("Tools", "hammer")
local tools, toolByLabel = {}, {}
for _, folder in ipairs({ SPARE:FindFirstChild("Tools"), workspace.PartsStore:FindFirstChild("GasStation") and workspace.PartsStore.GasStation:FindFirstChild("Tools") }) do
    for _, t in ipairs(folder and folder:GetChildren() or {}) do
        local l = ("%s  %s"):format(t.Name, money(t:GetAttribute("Price")))
        if not toolByLabel[l] then tools[#tools + 1] = l; toolByLabel[l] = t end
    end
end
local toolDrop = ToolBox:AddDropdown("FIU_Tool", { Text = "Tool", Values = tools, AllowNull = true })
ToolBox:AddButton({ Text = "Buy", Func = run("tool", function()
    local t = toolByLabel[toolDrop.Value]
    local ok = buyStore(t, true)
    log(ok and ("bought " .. t.Name) or "tool buy failed")
end) })

-- Teleport
local shopNames, garageNames = {}, {}
for _, n in ipairs(PLACE_NAMES) do
    if n:find("^My garage") or n:find("^Garage ") or n:find("^Auction") then garageNames[#garageNames + 1] = n else shopNames[#shopNames + 1] = n end
end
local TpBox = Tabs.Teleport:AddLeftGroupbox("Shops & places", "store")
local placeDrop = TpBox:AddDropdown("FIU_Place", { Text = "Place", Values = shopNames, AllowNull = true })
TpBox:AddButton({ Text = "Go", Func = run("tp", function() if placeDrop.Value then goPlace(placeDrop.Value) end end) })
local GarBox = Tabs.Teleport:AddLeftGroupbox("Garages", "warehouse")
GarBox:AddLabel("Teleports to the front door of each garage.", true)
local garDrop = GarBox:AddDropdown("FIU_GaragePlace", { Text = "Garage", Values = garageNames, AllowNull = true })
GarBox:AddButton({ Text = "Go", Func = run("tp garage", function() if garDrop.Value then goPlace(garDrop.Value) end end) })
TpBox:AddToggle("FIU_BringCar", { Text = "Bring selected car", Default = CFG.bringCar,
    Tooltip = "Spawns the car picked in the Garage tab next to you when you teleport", Callback = set("bringCar") })
local PlBox = Tabs.Teleport:AddRightGroupbox("Players", "users")
local plDrop = PlBox:AddDropdown("FIU_Player", { Text = "Player", SpecialType = "Player", ExcludeLocalPlayer = true })
PlBox:AddButton({ Text = "Go to player", Func = run("tp player", function()
    local p = plDrop.Value
    p = typeof(p) == "Instance" and p or Players:FindFirstChild(tostring(p))
    local c = p and p.Character
    if c then tpTo(c:GetPivot() * CFrame.new(0, 0, 4)) end
end) })

end
do
-- Settings
local Spend = Tabs.Settings:AddRightGroupbox("Spending", "wallet")
Spend:AddSlider("FIU_Reserve", { Text = "Always keep", Default = CFG.reserve, Min = 0, Max = 1000000, Rounding = 0, Suffix = "€",
    Tooltip = "Buying never takes your money below this", Callback = set("reserve") })
local PlayerBox = Tabs.Settings:AddRightGroupbox("Player", "user")
PlayerBox:AddToggle("FIU_SpeedOn", { Text = "Walk speed", Default = CFG.speedOn, Callback = function(v)
    CFG.speedOn = v
    if not v then local h = hum(); if h then h.WalkSpeed = 16 end end
end })
PlayerBox:AddSlider("FIU_Speed", { Text = "Speed", Default = CFG.walkSpeed, Min = 16, Max = 120, Rounding = 0, Callback = set("walkSpeed") })
PlayerBox:AddToggle("FIU_AntiAfk", { Text = "Anti-AFK", Default = CFG.antiAfk, Callback = set("antiAfk") })
local LogBox = Tabs.Settings:AddLeftGroupbox("Log", "scroll-text")
logLabel = LogBox:AddLabel("-", true)
local Menu = Tabs.Settings:AddLeftGroupbox("Menu", "menu")
Menu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })
end
Library:OnUnload(unload)
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "FIU_JunkPick", "FIU_CarPick", "FIU_ShopCat", "FIU_ShopPart", "FIU_Tool", "FIU_Place", "FIU_GaragePlace", "FIU_Player", "FIU_SellCd", "FIU_HopAuto", "FIU_HopMax", "FIU_HopOver", "FIU_HopMaxP", "FIU_HopHard", "FIU_HopHardMax", "FIU_HopGate", "FIU_HopLeave", "FIU_AntiMod", "FIU_ModRank", "FIU_ModAction", "FIU_StaffBoard", "FIU_GvPlayer", "FIU_GoldMode", "FIU_GoldAmount", "FIU_GoldBudget", "FIU_GoldMax", "FIU_GoldOn", "FIU_DriveFarm", "FIU_KmPerCar", "FIU_Lookup", "FIU_SwapEngine", "FIU_SwapTrans", "FIU_XFrom", "FIU_XTo", "FIU_LookEngine", "FIU_LookSize", "FIU_DriveCar" })
SaveManager:SetFolder(DIR)
ThemeManager:SetFolder(DIR)
-- CruelHub look: near-black with a crimson accent (still switchable under Settings > Themes)
ThemeManager:SetDefaultTheme({ BackgroundColor = "0c0a0b", MainColor = "161214", AccentColor = "e0233c", OutlineColor = "2a1d20", FontColor = "f2eded" })
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:ApplyToTab(Tabs.Settings, "palette")
SaveManager:LoadAutoloadConfig()
-- autosave: settings changes go into your autoload config within ~5 s, so nothing needs a manual "Save config"
-- (no autoload set = an "autosave" config is made and set as autoload). Polls the encoded config instead of hooking
-- OnChanged, which in Obsidian replaces an element's one callback.
task.spawn(function()
    task.wait(5) -- let the autoload apply first
    local last
    while running do
        local name = SaveManager.AutoloadConfig
        if type(name) ~= "string" or name == "" or name == "none" then name = nil end
        local ok, data, good = pcall(SaveManager.SaveJSON, SaveManager, name or "autosave")
        if ok and good then
            data = data:gsub('"timestamp":"[^"]*",?', "")
            if last and data ~= last then
                SaveManager:Save(name or "autosave")
                if not name then SaveManager:SaveAutoloadConfig("autosave") end
            end
            last = data
        end
        task.wait(5)
    end
end)

-- ============================== selected car tag ==============================
-- floating tag over the car picked in the Garage tab: name, condition, and how long until it can be sold
local selTag = Instance.new("BillboardGui")
selTag.AlwaysOnTop, selTag.LightInfluence, selTag.ResetOnSpawn = true, 0, false
selTag.Size, selTag.StudsOffsetWorldSpace = UDim2.fromOffset(240, 54), Vector3.new(0, 7, 0)
local selText = Instance.new("TextLabel")
selText.Size, selText.BackgroundTransparency, selText.RichText = UDim2.fromScale(1, 1), 1, true
selText.Font, selText.TextSize, selText.TextStrokeTransparency, selText.TextColor3 = Enum.Font.GothamBold, 15, 0.3, Color3.new(1, 1, 1)
selText.Parent = selTag
selTag.Parent = espRoot

local function sellLine(e)
    if isFav(e) then return '<font color="#ffd24a">★ locked</font>' end
    if CFG.sellCooldown <= 0 then return '<font color="#aaaaaa">sell timer unknown</font>' end
    local left = sellCooldownLeft(e)
    if left <= 0 then return '<font color="#5ee07a">can sell ✓</font>' end
    return ('<font color="#ff9b5e">sell in %d:%02d</font>'):format(left // 60, left % 60)
end

local selAtt
selTag.SizeOffset = Vector2.new(0, 0.5)
selTag.StudsOffsetWorldSpace = Vector3.new(0, 0.5, 0)
local function updateSelTag()
    local c = selectedCar and carOf(selectedCar)
    if selAtt and (not c or not selAtt:IsDescendantOf(c)) then selAtt:Destroy(); selAtt = nil end
    selAtt = c and titleAttachment(c, selAtt)
    selTag.Adornee = selAtt
    selTag.Enabled = selAtt ~= nil
    if not selTag.Enabled then return end
    local tier = modelTier(entryModel(selectedCar))
    selText.Text = ('<font color="%s">[%s] %s</font> · %d%%\n%s'):format(hex(CFG.color[tier]), tier, entryModel(selectedCar), condition(c) or 0, sellLine(selectedCar))
end

-- ============================== label refresh ==============================
task.spawn(function()
    local lastJunkVals, lastCarVals = "", ""
    local shownText = {}
    local function put(lbl, text) -- SetText re-lays out the label: skip it when nothing changed
        if shownText[lbl] ~= text then shownText[lbl] = text; lbl:SetText(text) end
    end
    while running do
        guard("labels", function()
            -- junk list
            local list, vals = sortedJunk(), {}
            table.clear(junkByLabel)
            for _, j in ipairs(list) do
                local l = junkLabel(j)
                vals[#vals + 1] = l; junkByLabel[l] = j
            end
            local key = table.concat(vals, "|")
            if key ~= lastJunkVals then lastJunkVals = key; junkDrop:SetValues(vals) end
            put(junkLabelBox, #vals > 0 and ("%d junk car%s · click one to pick it"):format(#vals, #vals == 1 and "" or "s") or "no junk cars loaded")

            -- cars
            local cvals = {}
            table.clear(carByLabel)
            for _, e in ipairs(entries()) do
                local l = ("%s%s [%s]"):format(isFav(e) and "★ " or isFlip(e) and "FLIP " or "", entryModel(e), e.Name:sub(1, 4))
                cvals[#cvals + 1] = l; carByLabel[l] = e
            end
            local ckey = table.concat(cvals, "|")
            if ckey ~= lastCarVals then
                lastCarVals = ckey
                -- a car's label changes when it's locked/sold/bought; keep the same car picked across the rebuild
                keepingCar = true
                carDrop:SetValues(cvals)
                local keepLabel
                for l, e2 in pairs(carByLabel) do if e2 == selectedCar then keepLabel = l end end
                carDrop:SetValue(keepLabel)
                keepingCar = false
            end
            if selectedCar and not selectedCar.Parent then selectedCar = nil end
            local e = selectedCar
            if e then
                local c = carOf(e)
                local tier = modelTier(entryModel(e))
                local cat = RS.Cache.CarList:FindFirstChild(entryModel(e))
                local sc = cat and cat:GetAttribute("SpawnChance")
                local lines2 = { ('<font color="%s"><b>[%s] %s</b></font> · %s'):format(hex(CFG.color[tier]), tier, entryModel(e), isFav(e) and '<font color="#ffd24a">★ favorite (locked)</font>' or isFlip(e) and '<font color="#5ee07a">flip car</font>' or '<font color="#aaaaaa">not locked</font>') }
                lines2[#lines2 + 1] = ('Rarity <font color="%s">%s</font>%s'):format(hex(CFG.color[tier]), TIER_TEXT[tier] or tier,
                    sc and sc > 0 and (" · %s%% spawn chance"):format(tostring(sc)) or " · doesn't spawn in the junkyard")
                local buy = tonumber(entryVal(e, "BuyPrice")) or 0
                local pm = c and c:GetAttribute("ProfitMultiplier")
                lines2[#lines2 + 1] = ("Bought %s%s"):format(money(buy), pm and (" · sells for %s at 100%%"):format(money(buy * (1 + pm))) or "")
                lines2[#lines2 + 1] = sellLine(e)
                if c then
                    lines2[#lines2 + 1] = ("Condition %d%%"):format(condition(c) or 0)
                    local eng = c.Values.Engine
                    for _, v in ipairs(eng:GetChildren()) do
                        if v:IsA("StringValue") and v.Value ~= "" then
                            local w = eng.Wear:FindFirstChild(v.Name) and eng.Wear[v.Name].Value or 0
                            local col = w == 0 and "#5ee07a" or w < 40 and "#ffd24a" or "#ff6b6b"
                            lines2[#lines2 + 1] = ('<font color="%s">%s %d%%</font>'):format(col, v.Name, w)
                        end
                    end
                else
                    lines2[#lines2 + 1] = "Not spawned"
                end
                put(carInfo, table.concat(lines2, "\n"))
                updateSelTag()
            else
                selTag.Enabled = false
                put(carInfo, "Pick a car")
            end

            local fl = {}
            for guid, model in pairs(FAV) do fl[#fl + 1] = ("★ %s [%s]%s"):format(model, guid:sub(1, 4), Garage:FindFirstChild(guid) and "" or " (not in garage)") end
            table.sort(fl)
            put(favLabel, #fl > 0 and table.concat(fl, "\n") or "No locked cars")

            put(autoLabel, ("%s\nGarage %d/%d · money %s · reserve %s\nSold by script: %d cars · %s in sales\nProfit: %s over the last %d sale%s (buy price and parts taken off)\nSell timer: %s"):format(
                busy and ("busy: " .. tostring(busyWhat)) or autoStatus, #entries(), garageSlots(), money(myMoney()), money(CFG.reserve),
                STATE.sold or 0, money(STATE.earned or 0), money(STATE.profit or 0), STATE.profitSales or 0, (STATE.profitSales or 0) == 1 and "" or "s",
                CFG.sellCooldown > 0 and (math.floor(CFG.sellCooldown / 60) .. " min") or "learning"))
        end)
        task.wait(0.5)
    end
end)

do
-- Players tab: ESP + garage viewer (every player's PlayerData.Garage replicates, wear values included)
local PEsp = Tabs.Players:AddLeftGroupbox("Player ESP", "scan-eye")
PEsp:AddToggle("FIU_PlEsp", { Text = "Player ESP", Default = CFG.playerEsp,
    Tooltip = "Name, cars sold, distance and the cars they have out", Callback = set("playerEsp") })
    :AddColorPicker("FIU_PlCol", { Default = CFG.playerColor, Title = "Player label color", Callback = function(c) CFG.playerColor = c end })
PEsp:AddToggle("FIU_PlCars", { Text = "Titles over their cars", Default = CFG.playerCarTitles,
    Tooltip = "Model + owner over every car another player has spawned, in its tier color", Callback = set("playerCarTitles") })
PEsp:AddToggle("FIU_PlOutline", { Text = "Outline players", Default = CFG.playerOutline, Callback = set("playerOutline") })
PEsp:AddSlider("FIU_PlDist", { Text = "Max distance", Default = CFG.playerMaxDist, Min = 100, Max = 6000, Rounding = 0, Suffix = " studs", Callback = set("playerMaxDist") })

local GView = Tabs.Players:AddRightGroupbox("Garage viewer", "binoculars")
local gvDrop = GView:AddDropdown("FIU_GvPlayer", { Text = "Player", SpecialType = "Player", ExcludeLocalPlayer = true, AllowNull = true })
local gvLabel = GView:AddLabel("Pick a player", true)
local function valuesCondition(values)
    local eng = values and values:FindFirstChild("Engine")
    local wear = eng and eng:FindFirstChild("Wear")
    if not wear then return nil end
    local sum, n = 0, 0
    for _, v in ipairs(eng:GetChildren()) do
        if v:IsA("StringValue") and v.Value ~= "" and wear:FindFirstChild(v.Name) then sum += wear[v.Name].Value; n += 1 end
    end
    return n > 0 and 100 - math.round(sum / n) or 100
end
local function garageText(p)
    local pd = p:FindFirstChild("PlayerData")
    local g = pd and pd:FindFirstChild("Garage")
    if not g then return p.DisplayName .. ": garage not loaded" end
    local gm = pd:FindFirstChild("GarageModel") and pd.GarageModel.Value or "?"
    local gmodel = workspace.Garages:FindFirstChild(tostring(gm))
    local slots = gmodel and gmodel:FindFirstChild("CarPositions") and #gmodel.CarPositions:GetChildren() or "?"
    local st = pd:FindFirstChild("Status")
    local lines = { ("<b>%s</b> · %s garage %d/%s"):format(p.DisplayName, tostring(gm), #g:GetChildren(), tostring(slots)),
        ("Money %s · %s cars sold"):format(st and money(st.Money.Value) or "?", st and tostring(st.CarsSold.Value) or "?") }
    local cars = g:GetChildren()
    table.sort(cars, function(a, b) return (tonumber(entryVal(a, "BuyPrice")) or 0) > (tonumber(entryVal(b, "BuyPrice")) or 0) end)
    for _, e in ipairs(cars) do
        local model = tostring(entryVal(e, "Model") or "?")
        local cat = RS.Cache.CarList:FindFirstChild(model)
        local sc = cat and cat:GetAttribute("SpawnChance")
        local tier = tierOf(sc, (sc or 0) <= 0)
        local cond = valuesCondition(e:FindFirstChild("Values"))
        lines[#lines + 1] = ('<font color="%s">[%s] %s</font> · %s%s%s'):format(hex(CFG.color[tier]), tier, model,
            money(tonumber(entryVal(e, "BuyPrice")) or 0), cond and (" · " .. cond .. "%") or "", Vehicles:FindFirstChild(e.Name) and " · out" or "")
    end
    if #cars == 0 then lines[#lines + 1] = "Empty garage" end
    return table.concat(lines, "\n")
end
task.spawn(function()
    while running do
        pcall(function()
            local p = gvDrop.Value
            p = typeof(p) == "Instance" and p or (p and Players:FindFirstChild(tostring(p)))
            gvLabel:SetText(p and garageText(p) or "Pick a player")
        end)
        task.wait(1)
    end
end)

end

-- Gold tab: live price + history (FixItUp/gold.json) + a buy contract: N gold (or a budget) at or under a price.
-- Money -> gold is Events.Exchange:FireServer("mtg", amount) at price floor(GoldPrice + 0.5); selling back costs 20 % tax.
do
    local GP = RS.Cache:WaitForChild("GoldPrice")
    local GOLD_FILE = DIR .. "/gold.json"
    local G = readJSON(GOLD_FILE, {})
    G.hist = G.hist or {}
    G.c = G.c or { on = false, mode = "Amount", amount = 1, budget = 100000, maxPrice = 0, filled = 0, spent = 0 }
    local function saveGold() writeJSON(GOLD_FILE, G) end
    local function priceNow() return math.floor(GP.Value + 0.5) end
    local function record(p)
        p = math.floor(p + 0.5)
        local h = G.hist
        if #h == 0 or h[#h][2] ~= p then
            h[#h + 1] = { os.time(), p }
            if #h > 3000 then table.remove(h, 1) end
            saveGold()
        end
    end
    record(GP.Value)
    on(GP.Changed, record)
    local function window(secs)
        local lo, hi, loAt, n = nil, nil, nil, 0
        local cut = os.time() - secs
        for _, e in ipairs(G.hist) do
            if e[1] >= cut then
                n += 1
                if not lo or e[2] < lo then lo, loAt = e[2], e[1] end
                if not hi or e[2] > hi then hi = e[2] end
            end
        end
        return lo, hi, loAt, n
    end
    local function ago(t)
        local d = os.time() - t
        return d < 90 and (d .. "s ago") or d < 5400 and (math.floor(d / 60) .. "m ago") or (("%.1fh ago"):format(d / 3600))
    end

    local function nearestBank()
        local list = {}
        for _, b in ipairs(workspace.Utils.ExchangeDetectors:GetChildren()) do if b:IsA("BasePart") then list[#list + 1] = b end end
        local r, best, bd = hrp(), nil, nil
        for _, b in ipairs(list) do
            local d = r and (b.Position - r.Position).Magnitude or 0
            if not bd or d < bd then best, bd = b, d end
        end
        return best
    end

    -- buys up to `amount` gold; tries from where you are first, then from the nearest bank
    local function buyGold(amount)
        local gold = Status.Gold
        local price = priceNow()
        amount = math.min(amount, math.floor((myMoney() - CFG.reserve) / math.max(1, price)))
        if amount <= 0 then return 0, "not enough money above your reserve" end
        local before = gold.Value
        Events.Exchange:FireServer("mtg", amount)
        local t = os.clock()
        repeat task.wait(0.1) until gold.Value ~= before or os.clock() - t > 2
        if gold.Value == before then
            local bank = nearestBank()
            if bank then
                local back = hrp() and hrp().CFrame
                tpTo(CFrame.new(bank.Position + Vector3.new(0, 3, 0)))
                task.wait(0.8)
                Events.Exchange:FireServer("mtg", amount)
                t = os.clock()
                repeat task.wait(0.1) until gold.Value ~= before or os.clock() - t > 3
                if back then tpTo(back) end
            end
        end
        local got = gold.Value - before
        if got <= 0 then return 0, "the exchange didn't go through" end
        return got, ("bought %d gold at %s"):format(got, money(price))
    end

    local function contractLeft()
        local c = G.c
        if c.mode == "Budget" then return math.floor((c.budget - c.spent) / math.max(1, priceNow())) end
        return c.amount - c.filled
    end

    task.spawn(function()
        while running do
            local c = G.c
            if c.on and not busy and not manualPending then
                local left = contractLeft()
                if left <= 0 then
                    c.on = false; saveGold()
                    notify(("Gold contract done: %d gold for %s"):format(c.filled, money(c.spent)))
                    log("gold contract done")
                elseif c.maxPrice > 0 and priceNow() <= c.maxPrice and not STAFF.gated() then
                    busy, busyWhat = true, "buying gold"
                    local price = priceNow()
                    local ok, got, msg = pcall(buyGold, left)
                    busy = false
                    if ok and got > 0 then
                        c.filled += got; c.spent += got * price; saveGold()
                        log(msg); notify(msg)
                    elseif ok then log("gold: " .. tostring(msg)); task.wait(10) end
                end
            end
            task.wait(1)
        end
    end)

    local GoldBox = Tabs.Gold:AddLeftGroupbox("Gold price", "trending-up")
    local priceLabel = GoldBox:AddLabel("-", true)
    local ConBox = Tabs.Gold:AddRightGroupbox("Buy contract", "file-signature")
    ConBox:AddLabel("Buys gold only when the price is at or under your max. Most gold per euro = the lowest max you can wait for. Selling gold back costs 20% tax.", true)
    ConBox:AddDropdown("FIU_GoldMode", { Text = "Contract", Values = { "Amount", "Budget" }, Default = G.c.mode,
        Tooltip = "Amount: buy this many gold. Budget: spend up to this many euros.",
        Callback = function(v) G.c.mode = v; saveGold() end })
    ConBox:AddInput("FIU_GoldAmount", { Text = "Gold to buy", Default = tostring(G.c.amount), Numeric = true, Finished = true,
        Callback = function(v) G.c.amount = math.max(1, math.floor(tonumber(v) or 1)); saveGold() end })
    ConBox:AddInput("FIU_GoldBudget", { Text = "Budget (€)", Default = tostring(G.c.budget), Numeric = true, Finished = true,
        Callback = function(v) G.c.budget = math.max(0, math.floor(tonumber(v) or 0)); saveGold() end })
    local maxInput = ConBox:AddInput("FIU_GoldMax", { Text = "Max price per gold (€)", Default = tostring(G.c.maxPrice), Numeric = true, Finished = true,
        Callback = function(v) G.c.maxPrice = math.max(0, math.floor(tonumber(v) or 0)); saveGold() end })
    ConBox:AddButton({ Text = "Use cheapest price seen (24h)", Func = function()
        local lo = window(86400)
        if lo then G.c.maxPrice = lo; saveGold(); maxInput:SetValue(tostring(lo)); notify("Max price set to " .. money(lo)) end
    end })
    local conToggle = ConBox:AddToggle("FIU_GoldOn", { Text = "Contract active", Default = G.c.on,
        Callback = function(v)
            if v and not G.c.on then G.c.filled, G.c.spent = 0, 0 end
            G.c.on = v; saveGold()
        end })
    ConBox:AddButton({ Text = "Buy now at current price", DoubleClick = true, Func = function()
        task.spawn(function()
            local amt = G.c.mode == "Budget" and math.floor(G.c.budget / math.max(1, priceNow())) or G.c.amount
            local got, msg = buyGold(amt)
            log(msg); notify(msg)
        end)
    end })
    local conLabel = ConBox:AddLabel("-", true)

    task.spawn(function()
        while running do
            pcall(function()
                local p = priceNow()
                local h = G.hist
                local last = h[#h]
                local prev = h[#h - 1]
                local lo1, hi1 = window(3600)
                local lo24, hi24, loAt24 = window(86400)
                local loAll, hiAll, loAtAll = window(10 ^ 9)
                priceLabel:SetText(table.concat({
                    ("<b>%s per gold</b>%s"):format(money(p), prev and (" (%s%s since %s)"):format(p >= prev[2] and "+" or "", money(p - prev[2]), ago(last[1])) or ""),
                    ("Gold per €100K: %.2f"):format(100000 / math.max(1, p)),
                    ("Last hour: %s – %s"):format(money(lo1 or p), money(hi1 or p)),
                    ("Last 24h: %s – %s · cheapest %s"):format(money(lo24 or p), money(hi24 or p), loAt24 and ago(loAt24) or "-"),
                    ("All seen: %s – %s · cheapest %s"):format(money(loAll or p), money(hiAll or p), loAtAll and ago(loAtAll) or "-"),
                    ("Price changes logged: %d · your gold %s"):format(#h, tostring(Status.Gold.Value)),
                    ("Sell back now: %s per gold after 20%% tax"):format(money(math.floor(p * 0.8))),
                }, "\n"))
                local c = G.c
                conLabel:SetText(("%s · %s\n%s"):format(c.on and '<font color="#5ee07a">active</font>' or "off",
                    c.mode == "Budget" and ("%s of %s spent"):format(money(c.spent), money(c.budget)) or ("%d of %d gold"):format(c.filled, c.amount),
                    c.maxPrice > 0 and (p <= c.maxPrice and "price is under your max: buying" or ("waiting for %s (now %s)"):format(money(c.maxPrice), money(p))) or "set a max price"))
                if conToggle.Value ~= c.on then conToggle:SetValue(c.on) end
            end)
            task.wait(1)
        end
    end)
end

-- Drive tab: distance owed for cars sold + a farm that drives your selected car along the traffic loop.
-- The server counts distance from the car really moving (the client never sends it). 3937 studs = 1 km in the game's own math.
do
    local DRIVE_FILE = DIR .. "/drive.json"
    local D = readJSON(DRIVE_FILE, {})
    if D.kmPerCar == nil then D.kmPerCar = 1 end
    local function saveD() writeJSON(DRIVE_FILE, D) end
    -- the server's words about distance, whenever it says something (e.g. when a sale is refused)
    on(Events.HUD.Notifiy.OnClientEvent, function(text)
        text = tostring(text)
        local low = text:lower()
        if low:find("km") or low:find("drive") or low:find("kilomet") or low:find("distance") then
            D.lastMsg, D.lastMsgAt = text, os.time(); saveD()
            log("server about distance: " .. text)
        end
    end)
    local function numbers()
        local km, sold = tonumber(Status.KMs.Value) or 0, tonumber(Status.CarsSold.Value) or 0
        local owed = sold * D.kmPerCar - km        -- > 0 = behind
        local spare = math.floor((km - sold * D.kmPerCar) / math.max(0.001, D.kmPerCar)) -- sales left before you owe
        return km, sold, owed, spare
    end

    local farm = { on = false, status = "off", startKm = 0 }
    -- route: back and forth along the city's longest straight road (the traffic lanes run on a far-off highway)
    local function roadRoute()
        local best
        for _, d in ipairs(workspace.Map.FirstCity.Roads:GetDescendants()) do
            if d:IsA("BasePart") and d.Name == "Road" and d.Size.Y < 1 then
                local len = math.max(d.Size.X, d.Size.Z)
                if not best or len > best.len then best = { part = d, len = len } end
            end
        end
        if not best then return nil end
        local p = best.part
        local alongX = p.Size.X >= p.Size.Z
        local axis = alongX and p.CFrame.RightVector or p.CFrame.LookVector
        local side = alongX and p.CFrame.LookVector or p.CFrame.RightVector
        local top = p.Position.Y + p.Size.Y / 2
        local mid = Vector3.new(p.Position.X, top, p.Position.Z) + side * 8 -- keep to one lane
        local half = best.len / 2 - 30
        return { mid - axis * half, mid + axis * half }, top
    end

    -- highway: the long straight stretch north of town the player picked (1121 x 101 studs, centre ~(-985, 1, 2100),
    -- measured 2026-09-28). Back and forth along one lane of it.
    local HWY_AT = Vector3.new(-984.75, 0.52, 2100.19)
    local function highwayRoute()
        local best
        streamAt(HWY_AT, 5)
        for _, d in ipairs(workspace.Map.Map:GetDescendants()) do
            if d:IsA("BasePart") and d.Size.Y < 3 and math.max(d.Size.X, d.Size.Z) > 800 and math.min(d.Size.X, d.Size.Z) > 60 then
                local dist = (d.Position - HWY_AT).Magnitude
                if dist < 60 and (not best or dist < best.dist) then best = { part = d, dist = dist } end
            end
        end
        -- not streamed in yet: the ends measured on 2026-09-28 (both on the asphalt at y 1.02)
        if not best then return { Vector3.new(-1076.83, 1.02, 2612.93), Vector3.new(-843.24, 1.02, 1598.84) }, 1.02 end
        local p = best.part
        local alongX = p.Size.X >= p.Size.Z
        local axis = alongX and p.CFrame.RightVector or p.CFrame.LookVector
        local side = alongX and p.CFrame.LookVector or p.CFrame.RightVector
        local len, wid = math.max(p.Size.X, p.Size.Z), math.min(p.Size.X, p.Size.Z)
        local top = p.Position.Y + p.Size.Y / 2
        local mid = Vector3.new(p.Position.X, top, p.Position.Z) + side * (wid * 0.25) -- a lane on one carriageway
        local half = len / 2 - 40
        return { mid - axis * half, mid + axis * half }, top
    end

    function farm.pending()
        if not (CFG.autoBuy or CFG.autoRepair or CFG.autoSell) then return false end
        for _, e in ipairs(entries()) do
            local o = OWNED[e.Name]
            if o and os.time() >= (o.nextTry or 0) then
                if CFG.autoRepair and not o.repaired then return true end
                if CFG.autoSell and not isFav(e) and e.Name ~= CFG.farmCarGuid and (o.repaired or not CFG.autoRepair)
                    and sellCooldownLeft(e) <= 0 then return true end
            end
        end
        return CFG.autoBuy and #entries() < garageSlots() and wantedJunk() ~= nil
    end

    local function farmRun()
        -- a car picked in the Drive tab that has gone (sold) stops the farm: never fall back to some other car
        if farm.chosen and not (farm.car and farm.car.Parent) then
            farm.status = "the farm car is gone (sold?), pick another one"
            farm.on = false
            return
        end
        local e = (farm.chosen and farm.car) or selectedCar -- the Drive tab's own pick, else the Garage tab's
        CFG.farmCarGuid = e and e.Name or nil -- auto sell never sells the car being farmed
        if not e then farm.status = "pick a car in the Garage tab first"; return end
        local pts, top, cycle
        if CFG.driveRoute == "Highway" then
            pts, top = highwayRoute()
        else
            pts, top = roadRoute()
        end
        if not pts then farm.status = "no route found"; return end
        farm.status = "spawning " .. entryModel(e) .. " on the route (can take ~20 s)"
        streamAt(pts[1], 5)
        local car = spawnCar(e, CFrame.lookAt(pts[1] + Vector3.new(0, 4, 0), pts[2] + Vector3.new(0, 4, 0)))
        if not car then farm.status = "car didn't spawn"; return end
        local h, seat = hum(), car:FindFirstChild("DriveSeat")
        if not (h and seat) then farm.status = "no seat"; return end
        farm.status = "getting in"
        tpTo(seat.CFrame * CFrame.new(0, 3, 0))
        task.wait(0.3)
        seat:Sit(h)
        task.wait(1.2) -- let it land before measuring its ride height
        if h.SeatPart ~= seat then farm.status = "couldn't sit in the car"; return end
        -- tyres stay on the road: the distance only counts while they turn (floating them 0.6 studs up counted 0 km,
        -- measured 2026-09-28). They're spun to match the car's speed below, so they roll instead of sliding (no screech).
        local ride = math.clamp(car:GetPivot().Position.Y - (top or pts[1].Y), 0.5, 6)
        local wheels = {}
        for _, w in ipairs(car:FindFirstChild("Wheels") and car.Wheels:GetChildren() or {}) do
            if w:IsA("BasePart") then wheels[#wheels + 1] = { part = w, r = math.max(0.5, math.max(w.Size.X, w.Size.Y, w.Size.Z) / 2) } end
        end
        farm.startKm = tonumber(Status.KMs.Value) or 0
        farm.moved = 0
        local i = 2
        while farm.on and running do
            local dt = RunService.Heartbeat:Wait()
            if h.SeatPart ~= seat then farm.status = "stopped: you left the car"; break end
            if not car.Parent then farm.status = "stopped: the car despawned"; break end
            local pos = car:GetPivot().Position
            local target = pts[i]
            local flat = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
            if flat.Magnitude < 6 then
                if cycle then i = i % #pts + 1 else i = 3 - i end -- highway: next node, loops round; city road: turn around
            else
                local dir = flat.Unit
                local step = math.min(CFG.driveSpeed * dt, flat.Magnitude)
                local roadY = top or target.Y -- highway nodes carry the road height
                local nextPos = Vector3.new(pos.X, roadY + ride, pos.Z) + dir * step
                car:PivotTo(CFrame.lookAt(nextPos, nextPos + dir))
                seat.AssemblyLinearVelocity = dir * CFG.driveSpeed -- the speedo (and anything reading velocity) sees real speed
                -- rolling without slip: spin = (dir x up) * speed / radius
                local axis = dir:Cross(Vector3.yAxis)
                for _, w in ipairs(wheels) do
                    if w.part.Parent then w.part.AssemblyAngularVelocity = axis * (CFG.driveSpeed / w.r) end
                end
                farm.moved += step
            end
            local km, _, owed = numbers()
            if not CFG.driveNoLimit and owed + CFG.driveExtra <= 0 then farm.status = ("done: drove %.2f km"):format(km - farm.startKm); notify("Distance farm done"); break end
            if farm.chosen and farm.car ~= e then farm.yielded = true; farm.status = "switching car"; break end -- picked another car mid-run
            if manualPending then farm.yielded = true; farm.status = "paused for a button"; break end
            if STAFF.gated() then farm.yielded = true; farm.status = "blocked: " .. STAFF.gateMsg; break end
            if CFG.farmYield and os.clock() - (farm.lastCheck or 0) > 1 then
                farm.lastCheck = os.clock()
                if farm.pending() then farm.yielded = true; farm.status = "paused: auto flip has work"; break end
            end
            farm.status = ("driving · moved %.2f km · counted %.2f km · %s"):format(farm.moved / 3937, km - farm.startKm,
                CFG.driveNoLimit and "no limit" or ("%.2f km to go"):format(math.max(0, owed + CFG.driveExtra)))
        end
        pcall(function() seat.AssemblyLinearVelocity = Vector3.zero end)
        if not farm.yielded then farm.on = false end
    end

    local DistBox = Tabs.Drive:AddLeftGroupbox("Distance owed", "route")
    local distLabel = DistBox:AddLabel("-", true)
    DistBox:AddSlider("FIU_KmPerCar", { Text = "Km needed per car sold", Default = D.kmPerCar, Min = 0.1, Max = 10, Rounding = 1, Suffix = " km",
        Tooltip = "Learned from the server's message when it refuses a sale for distance; set it by hand if you know it",
        Callback = function(v) D.kmPerCar = v; saveD() end })
    local FarmBox = Tabs.Drive:AddRightGroupbox("Distance farm", "gauge")
    FarmBox:AddLabel("Spawns the car picked in the Garage tab on the route, seats you and drives until your distance debt is paid plus the extra below. Get out of the car to stop.", true)
    local farmToggle = FarmBox:AddToggle("FIU_DriveFarm", { Text = "Farm distance", Default = false, Callback = function(v)
        if v and not farm.on then
            farm.on = true
            -- one worker only: a run still spawning the car (slow) sees farm.on again and carries on. A second thread
            -- used to wait on the first one's busy flag, then get switched off by it (stuck on "waiting for farming distance")
            if farm.worker then return end
            farm.worker = true
            task.spawn(function()
                local okLoop, errLoop = pcall(function() -- any error still reaches the cleanup below (else worker stays set)
                    while farm.on and running do
                        if busy or manualPending then
                            farm.status = "waiting for " .. (busy and tostring(busyWhat) or "a button")
                            repeat task.wait(0.5) until not (busy or manualPending) or not farm.on or not running
                        end
                        if STAFF.gated() then
                            farm.status = "blocked: " .. STAFF.gateMsg
                            repeat task.wait(1) until not STAFF.gated() or not farm.on or not running
                        end
                        if not (farm.on and running) then break end
                        busy, busyWhat = true, "farming distance"
                        farm.yielded = false
                        local ok, err = pcall(farmRun)
                        busy = false
                        if not ok then farm.status = "error: " .. tostring(err); log("drive farm: " .. tostring(err)); break end
                        if not (farm.yielded and farm.on) then break end
                        -- the auto loop buys / repairs / sells now (it runs every 2 s once busy is free); drive again after
                        local t = os.clock()
                        repeat task.wait(1) until (not busy and not manualPending and not (CFG.farmYield and farm.pending())) or not farm.on or os.clock() - t > 600
                        task.wait(1)
                    end
                end)
                if not okLoop then farm.status = "error: " .. tostring(errLoop); log("drive farm: " .. tostring(errLoop)) end
                farm.on = false
                farm.worker = nil
                CFG.farmCarGuid = nil
                if CFG.homeAfterTp and running then goHome(true) end
            end)
        elseif not v then
            farm.on = false
        end
    end })
    FarmBox:AddToggle("FIU_DriveYield", { Text = "Pause for auto flips", Default = CFG.farmYield,
        Tooltip = "Steps out while Auto has a car to buy, repair or sell (sell timer up), then keeps driving. Needs the Auto toggles on.",
        Callback = set("farmYield") })
    local PICK = "Garage tab pick"
    local carDropF = FarmBox:AddDropdown("FIU_DriveCar", { Text = "Car", Values = { PICK }, Default = PICK,
        Tooltip = "Which car to drive; \"Garage tab pick\" uses the car picked in the Garage tab",
        Callback = function(v)
            if farm.refreshing then return end -- the list being rebuilt isn't a new pick
            farm.chosen = v ~= nil and v ~= PICK
            farm.car = farm.chosen and carByLabel[v] or nil
            D.car = farm.car and farm.car.Name or nil; saveD() -- remembered by car id (labels change when a car is locked)
        end })
    task.spawn(function() -- keep the list in step with your garage, keeping the pick
        local lastKey = ""
        while running do
            local labels = {}
            for l in pairs(carByLabel) do labels[#labels + 1] = l end
            table.sort(labels)
            local key = table.concat(labels, "|")
            if key ~= lastKey then
                lastKey = key
                local keep = farm.car
                if not keep and D.car and Garage:FindFirstChild(D.car) then -- the pick saved last session
                    keep = Garage[D.car]; farm.chosen, farm.car = true, keep
                end
                table.insert(labels, 1, PICK)
                farm.refreshing = true
                carDropF:SetValues(labels)
                local keepLabel = PICK
                for l, e2 in pairs(carByLabel) do if e2 == keep then keepLabel = l end end
                carDropF:SetValue(keepLabel) -- a sold farm car shows "Garage tab pick" but the farm still stops (farm.chosen stays)
                farm.refreshing = false
            end
            task.wait(1)
        end
    end)
    FarmBox:AddDropdown("FIU_DriveRoute", { Text = "Route", Values = { "Highway", "City road" }, Default = CFG.driveRoute,
        Tooltip = "Highway: back and forth on the long straight stretch north of town. City road: the longest straight road in town.", Callback = set("driveRoute") })
    FarmBox:AddSlider("FIU_DriveSpeed", { Text = "Speed", Default = CFG.driveSpeed, Min = 20, Max = 150, Rounding = 0, Suffix = " studs/s",
        Tooltip = "3937 studs = 1 km. Faster finishes sooner but looks less like real driving.", Callback = set("driveSpeed") })
    FarmBox:AddSlider("FIU_DriveExtra", { Text = "Keep driving past the debt", Default = CFG.driveExtra, Min = 0, Max = 50, Rounding = 0, Suffix = " km",
        Callback = set("driveExtra") })
    FarmBox:AddToggle("FIU_DriveNoLimit", { Text = "No limit", Default = CFG.driveNoLimit,
        Tooltip = "Keep driving until you turn the farm off or get out, ignoring the debt and the extra km",
        Callback = set("driveNoLimit") })
    local farmLabel = FarmBox:AddLabel("-", true)

    task.spawn(function()
        while running do
            pcall(function()
                local km, sold, owed, spare = numbers()
                distLabel:SetText(table.concat({
                    ("Driven <b>%.2f km</b> · %d cars sold"):format(km, sold),
                    ("Needed for %d sales at %.1f km each: %.1f km"):format(sold, D.kmPerCar, sold * D.kmPerCar),
                    owed > 0 and ('<font color="#ff6b6b">You owe %.2f km</font>'):format(owed)
                        or ('<font color="#5ee07a">Ahead by %.2f km · %d more sale%s before you owe</font>'):format(-owed, spare, spare == 1 and "" or "s"),
                    ("Next sale needs %.2f km total (%.2f to go)"):format((sold + 1) * D.kmPerCar, math.max(0, (sold + 1) * D.kmPerCar - km)),
                    D.lastMsg and ("Server said (%s): %s"):format(os.date("%H:%M", D.lastMsgAt or 0), D.lastMsg) or "No distance message from the server seen yet",
                }, "\n"))
                farmLabel:SetText(farm.status)
                if farmToggle.Value ~= farm.on and not farm.on then farmToggle:SetValue(false) end
            end)
            task.wait(1)
        end
    end)
end

do
-- Server hop tab (settings live in fiu_hop.json, not SaveManager, so they survive the teleport before autoload)
local HopBox = Tabs.Hop:AddLeftGroupbox("Auto hop", "shuffle")
HopBox:AddLabel("Hops to servers where the other players have sold few cars (less competition at the junkyard). Reloads this script after every hop.", true)
hopToggle = HopBox:AddToggle("FIU_HopAuto", { Text = "Auto hop until match", Default = HOP.auto,
    Tooltip = "Checks this server, hops if it fails, repeats after every teleport",
    Callback = function(v)
        if v == HOP.auto then return end
        HOP.auto = v
        if v then HOP.hops = 0 end
        saveHop()
        if v then task.spawn(hopRun) else hopStatus = "stopped" end
    end })
HopBox:AddSlider("FIU_HopMax", { Text = "Cars Sold must be under", Default = HOP.max, Min = 5, Max = 500, Rounding = 0,
    Callback = function(v) HOP.max = v; saveHop() end })
HopBox:AddSlider("FIU_HopOver", { Text = "Players allowed over limit", Default = HOP.over, Min = 0, Max = 10, Rounding = 0,
    Tooltip = "0 = everyone must be under. Raise it if hunting takes forever.", Callback = function(v) HOP.over = v; saveHop() end })
HopBox:AddToggle("FIU_HopHard", { Text = "Hard block big sellers", Default = HOP.hard,
    Tooltip = "Any player at or over the number below fails the server, even if the allowance above would let them through",
    Callback = function(v) HOP.hard = v; saveHop(); task.spawn(checkServer) end })
HopBox:AddInput("FIU_HopHardMax", { Text = "Hard block at Cars Sold", Default = tostring(HOP.hardMax), Numeric = true, Finished = true,
    Callback = function(v) HOP.hardMax = math.max(1, math.floor(tonumber(v) or 1500)); saveHop() end })
HopBox:AddSlider("FIU_HopMaxP", { Text = "Max other players", Default = HOP.maxp, Min = 1, Max = 21, Rounding = 0,
    Tooltip = "Only hop into servers with at most this many players", Callback = function(v) HOP.maxp = v; saveHop() end })
HopBox:AddToggle("FIU_HopGate", { Text = "Block actions in failing servers", Default = HOP.gate,
    Tooltip = "While this server fails the rules above (e.g. someone with 2k sold is here), nothing runs: auto buy/repair/sell, "
        .. "buttons, the distance farm and gold contracts all wait. Rechecked every 15 s and when someone joins; hopping still works.",
    Callback = function(v) HOP.gate = v; saveHop(); task.spawn(checkServer) end })
HopBox:AddToggle("FIU_HopLeave", { Text = "Hop away when the server breaks the rules", Default = HOP.leaveOnFail,
    Tooltip = "When someone who fails the rules above is here (or joins), new actions stop, the running job (a repair, sale, swap...) "
        .. "finishes so no parts are left lying around, and then auto hop hunts for a passing server.",
    Callback = function(v) HOP.leaveOnFail = v; saveHop(); task.spawn(checkServer) end })
local hopLabel = HopBox:AddLabel("-", true)
local HopInfo = Tabs.Hop:AddRightGroupbox("This server", "server")
local hopServerLabel = HopInfo:AddLabel("-", true)
HopInfo:AddButton({ Text = "Rescan this server", Func = function() task.spawn(checkServer) end })
HopInfo:AddButton({ Text = "Hop once now", Func = function()
    task.spawn(function()
        local s, why = candidates()
        if not s then notify("No server to hop to: " .. tostring(why or "none under the player cap")) return end
        local q = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
        if q and not hopQueued then hopQueued = pcall(q, RELOAD) end
        HOP.visited[s.id] = os.time(); saveHop()
        pcall(TeleportService.TeleportToPlaceInstance, TeleportService, game.PlaceId, s.id, LP)
    end)
end })
HopInfo:AddButton({ Text = "Forget visited servers", Func = function()
    HOP.visited = { [game.JobId] = os.time() }; saveHop(); notify("Visited list cleared.")
end })

local ModBox = Tabs.Hop:AddRightGroupbox("Anti-mod", "shield-alert")
ModBox:AddLabel("Leaves as soon as anyone ranked above Member in the game's group (.workspace) is in the server, including when you join.", true)
ModBox:AddToggle("FIU_AntiMod", { Text = "Leave when staff join", Default = HOP.antiMod,
    Callback = function(v) HOP.antiMod = v; saveHop(); if v then task.spawn(STAFF.scan) end end })
local rankVals, rankByLabel, rankDefault = {}, {}, nil
for _, r in ipairs(STAFF.roles) do
    local l = ("%s (%d) and up"):format(r[1], r[2])
    rankVals[#rankVals + 1] = l; rankByLabel[l] = r[2]
    if r[2] == HOP.modRank then rankDefault = l end
end
ModBox:AddDropdown("FIU_ModRank", { Text = "Counts as staff", Values = rankVals, Default = rankDefault or rankVals[1],
    Tooltip = "Tester (2) and up = everyone above a regular member",
    Callback = function(v) HOP.modRank = rankByLabel[v] or 2; saveHop(); task.spawn(STAFF.scan); STAFF.wake = true end })
ModBox:AddDropdown("FIU_ModAction", { Text = "Then", Values = { "Leave game", "Server hop" }, Default = HOP.modAction,
    Tooltip = "Server hop joins a random server and reloads the script there; if the teleport fails it leaves after 12 s",
    Callback = function(v) HOP.modAction = v; saveHop() end })
local modLabel = ModBox:AddLabel("-", true)
ModBox:AddToggle("FIU_StaffBoard", { Text = "Staff status list", Default = HOP.staffBoard,
    Tooltip = "Everyone at the rank above: in your server, in Fix It Up elsewhere, in another game, online or offline. Updates every minute.",
    Callback = function(v) HOP.staffBoard = v; saveHop(); STAFF.wake = true end })
ModBox:AddButton({ Text = "Refresh staff list", Func = function() STAFF.wake = true end })
local staffLabel = ModBox:AddLabel("-", true)
getgenv().FIU_MAIN.staff = STAFF -- for scripted tests
task.spawn(function()
    while running do
        if HOP.staffBoard then
            if not STAFF.board then staffLabel:SetText("Loading staff...") end
            pcall(STAFF.refresh)
            staffLabel:SetText(STAFF.board or "-")
        else
            staffLabel:SetText("Off")
        end
        STAFF.wake = false
        local t = os.clock()
        repeat task.wait(0.5) until STAFF.wake or not running or os.clock() - t > 60
    end
end)
task.spawn(function()
    while running do
        pcall(function()
            hopLabel:SetText(hopStatus .. ("\nHops this hunt: %d"):format(HOP.hops)); hopServerLabel:SetText(hopServer)
            modLabel:SetText(not HOP.antiMod and "Off" or STAFF.status == "watching" and ("Watching %d players, no staff seen"):format(#Players:GetPlayers() - 1) or STAFF.status)
        end)
        task.wait(1)
    end
end)
end
if HOP.auto then task.spawn(hopRun) else task.spawn(checkServer) end
-- keep the verdict current for the action gate: people join, leave and keep selling
on(Players.PlayerAdded, function() task.wait(3); if running then pcall(checkServer) end end)
task.spawn(function()
    while running do
        task.wait(15)
        if running and not hopping then pcall(checkServer) end
    end
end)

lifeLog("ready")
Library:Notify("Fix It Up ready — RightCtrl toggles the UI. Only script-bought cars are ever sold.", 5)
