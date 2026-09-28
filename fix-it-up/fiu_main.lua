--[[
    Fix It Up! (place 72712036210947) — junkyard tiers + auto flip
    UI: Obsidian (deividcomsono)

    Junkyard: every junk car named (the game hides it) + tier by spawn chance, colored billboard + outline,
              sorted list, TP / buy, spawn alerts from the server's "rare car has appeared" message.
    Auto:     buy -> repair -> sell loop with tier / model / price filters and a money reserve.
    Car:      your garage cars: condition, wear per part, spawn here, repair, sell, hood.
    Shop:     spare parts + tools, buy (and install).
    Teleport: every shop, job, garage and player.

    SAFETY: favorited cars (FixItUp/favorites.json, Car tab > Favorites) are locked: never sold, never touched by auto.
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

if getgenv().FIU_MAIN then pcall(getgenv().FIU_MAIN.unload) end

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local RunService  = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LP          = Players.LocalPlayer
local Events      = RS:WaitForChild("Events")
local PD          = LP:WaitForChild("PlayerData")
local Status      = PD:WaitForChild("Status")
local Garage      = PD:WaitForChild("Garage")
local Vehicles    = workspace:WaitForChild("Vehicles")
local MoveParts   = workspace:WaitForChild("MoveableParts")
local CONFIRM     = Events.HUD.Confirmation

local DIR = "FixItUp"
pcall(function() if not isfolder(DIR) then makefolder(DIR) end end)

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
    esp = true, outline = true, maxDist = 3000, textSize = 14,
    alerts = true, alertMin = "B",
    -- auto flip: everything off until the player (or SaveManager autoload) turns it on
    autoBuy = false, autoRepair = false, autoSell = false,
    buyMinTier = "C", buyModels = {}, buyMaxPrice = 60000, buyMinProfit = 0,
    reserve = 20000,
    repairMin = 1, replaceWorn = true, station = "Dealership",
    sellCooldown = 0, -- seconds; 0 = learn it from the server's refusal
    bringCar = false, walkSpeed = 16, speedOn = false, antiAfk = true,
}
local STATE = readJSON(DIR .. "/state.json", {})
local OWNED = readJSON(DIR .. "/owned.json", {}) -- [garage GUID] = { model, boughtAt } — the ONLY sellable cars
if STATE.sellCooldown then CFG.sellCooldown = STATE.sellCooldown end
local FAV = readJSON(DIR .. "/favorites.json", {}) -- [garage GUID] = model name — locked by the player
local function saveOwned() writeJSON(DIR .. "/owned.json", OWNED) end
local function saveFav() writeJSON(DIR .. "/favorites.json", FAV) end
local function saveState() STATE.sellCooldown = CFG.sellCooldown; writeJSON(DIR .. "/state.json", STATE) end

local function myMoney() return Status.Money.Value end

-- ============================== confirm + notify hooks ==============================
local origConfirm = getgenv().FIU_ORIG_CONFIRM or getcallbackvalue(CONFIRM, "OnClientInvoke")
getgenv().FIU_ORIG_CONFIRM = origConfirm
local confirmFn, lastConfirm = nil, nil -- confirmFn(text) -> bool while the script is buying/selling
CONFIRM.OnClientInvoke = function(text, ...)
    lastConfirm = { t = os.clock(), text = tostring(text) }
    if confirmFn then return confirmFn(tostring(text)) == true end
    return origConfirm(text, ...)
end

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

local function tpTo(target) -- CFrame or Vector3
    local h = hum()
    if h and h.SeatPart then h.Sit = false; task.wait(0.25) end
    local r = hrp()
    if not r then return false end
    local cf = typeof(target) == "Vector3" and CFrame.new(target) or target
    pcall(function() LP:RequestStreamAroundAsync(cf.Position, 3) end)
    r.AssemblyLinearVelocity, r.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
    char():PivotTo(cf)
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
    local old = carOf(e)
    local ok, err = pcall(function() Events.Vehicles.RemoteLoad:InvokeServer(e, cf) end)
    if not ok then log("spawn failed: " .. tostring(err)); return nil end
    local t = os.clock()
    repeat
        local c = carOf(e)
        if c and c ~= old and c:FindFirstChild("PartsEvent") then task.wait(0.5); return c end
        task.wait(0.1)
    until os.clock() - t > 6
    return carOf(e)
end

local function sellCooldownLeft(e)
    if CFG.sellCooldown <= 0 then return 0 end
    local bought = tonumber(entryVal(e, "BoughtAt")) or 0
    return math.max(0, bought + CFG.sellCooldown - os.time())
end

-- ============================== machines ==============================
local SHOPS = {
    Dealership = function() return workspace.Map.FirstCity.Buildings.Dealership.Folder end,
    Pitstop = function() return workspace.Map.FirstCity.Buildings["Pitstop(Large)"] end,
}
local function stationRoot() return SHOPS[CFG.station] and SHOPS[CFG.station]() or SHOPS.Dealership() end

-- where the car goes for a repair: open floor, not up on a lift (Dealership spot picked by the player)
local FLOOR_SPOT = { Dealership = Vector3.new(-533.6, 4.8, -799.0) }
local function liftCF()
    local root = stationRoot()
    local lift = root:FindFirstChild("Lift") or (root:FindFirstChild("Lifts") and root.Lifts:FindFirstChild("Lift"))
    local rot = lift and lift:GetPivot().Rotation or CFrame.identity
    local spot = FLOOR_SPOT[CFG.station]
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
    pcall(function() LP:RequestStreamAroundAsync(liftCF().Position, 5) end)
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
    tpTo(CFrame.new(model:GetPivot().Position + Vector3.new(0, 2, 5)))
    task.wait(0.4)
    local asked = false
    confirmFn = function(text) asked = true; local p = parsePrice(text); return p ~= nil and myMoney() - p >= CFG.reserve end
    fireclickdetector(model.ClickDetector)
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
local busy, busyWhat = false, nil
local INSTALL_FIRST = { EngineBlock = 1 }

local function repairCar(e)
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
    for try = 1, 3 do
        if hoodOpen() or not cd then break end
        task.wait(0.6)
        tpTo(hoodSpot(car))
        task.wait(0.4)
        fireclickdetector(cd)
        local t = os.clock()
        repeat task.wait(0.1) until hoodOpen() or os.clock() - t > 2
        if not hoodOpen() then
            local r = hrp()
            log(("hood try %d failed, %.1f studs from it"):format(try, r and (r.Position - det.Position).Magnitude or -1))
        end
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
        if eng[slot].Value ~= "" then car.PartsEvent:FireServer("RemovePart", slot); task.wait(0.3) end
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
            local new, why = buyStore(storeModel(p:GetAttribute("Category") or "", p:GetAttribute("PartName") or p.Name))
            if new then
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
            if p.Parent == MoveParts then car.PartsEvent:FireServer("ReapplyPart", p); task.wait(0.3) end
        end
        task.wait(0.8)
    end
    pin:Disconnect()
    local left = 0
    for _, p in ipairs(installs) do if p.Parent == MoveParts then left += 1 end end
    return left == 0, ("%s condition %s%%%s"):format(entryModel(e), tostring(condition(car)), left > 0 and (" · " .. left .. " part(s) not installed") or "")
end

-- ============================== sell ==============================
local function sellCar(e, manual)
    if isFav(e) then return false, "locked: " .. entryModel(e) .. " is a favorite" end
    if not manual and not isFlip(e) then return false, "auto only sells cars it bought" end
    local left = sellCooldownLeft(e)
    if left > 0 then return false, ("sell timer: %dm %02ds"):format(left // 60, left % 60) end
    local npc = workspace.Utils.SellCar
    pcall(function() LP:RequestStreamAroundAsync(npc:GetPivot().Position, 5) end)
    local pr = npc:FindFirstChild("Prompt") or npc:WaitForChild("Prompt", 5)
    if not pr then return false, "sell NPC not loaded" end
    -- the prompt sells whatever car is in the zone: never with another of your cars there
    for _, o in ipairs(entries()) do
        local c = carOf(o)
        if o ~= e and c and (c:GetPivot().Position - pr.Position).Magnitude < 40 then return false, entryModel(o) .. " is parked at the sell zone, move it first" end
    end
    local car = spawnCar(e, CFrame.lookAt(pr.Position + pr.CFrame.LookVector * 9 + Vector3.new(0, 3, 0), pr.Position))
    if not car then return false, "spawn failed" end
    tpTo(pr.CFrame * CFrame.new(0, 0, -4))
    task.wait(0.5)
    local want, offer = entryModel(e), nil
    confirmFn = function(text)
        offer = parsePrice(text)
        return text:find("sell your", 1, true) ~= nil and text:find(want, 1, true) ~= nil -- only the car we meant
    end
    local nt0, gone = os.clock(), false
    fireproximityprompt(pr.ProximityPrompt)
    local t = os.clock()
    repeat task.wait(0.1); gone = e.Parent == nil until gone or os.clock() - t > 4
    confirmFn = nil
    if gone then
        OWNED[e.Name] = nil; saveOwned()
        STATE.sold = (STATE.sold or 0) + 1; STATE.earned = (STATE.earned or 0) + (offer or 0); saveState()
        return true, ("sold %s for %s"):format(want, money(offer))
    end
    if lastNotify.t >= nt0 then
        local secs = parseWait(lastNotify.text)
        if secs then
            -- learn the timer: now - BoughtAt + remaining
            local bought = tonumber(entryVal(e, "BoughtAt")) or os.time()
            CFG.sellCooldown = math.max(CFG.sellCooldown, os.time() - bought + secs)
            saveState()
            log(("learned sell timer: %d s"):format(CFG.sellCooldown))
        end
        return false, "server: " .. lastNotify.text
    end
    return false, "no sell offer"
end

-- ============================== buy ==============================
local function buyJunk(info)
    local m = info.model
    if not m.Parent or not m:FindFirstChild("ClickDetector") then return nil, "car gone" end
    if #entries() >= garageSlots() then return nil, ("garage full (%d/%d)"):format(#entries(), garageSlots()) end
    if myMoney() - info.lo < CFG.reserve then return nil, "reserve" end
    local before = {}
    for _, g in ipairs(entries()) do before[g] = true end
    tpTo(m:GetPivot() * CFrame.new(0, 3, 8))
    task.wait(0.5)
    local asked, price = false, nil
    confirmFn = function(text)
        asked, price = true, parsePrice(text)
        return price ~= nil and price <= CFG.buyMaxPrice and myMoney() - price >= CFG.reserve
    end
    fireclickdetector(m.ClickDetector)
    local new, t = nil, os.clock()
    repeat
        task.wait(0.1)
        for _, g in ipairs(entries()) do if not before[g] then new = g end end
    until new or os.clock() - t > 5
    confirmFn = nil
    if new then
        OWNED[new.Name] = { model = entryModel(new), boughtAt = os.time(), price = price }
        saveOwned()
        return new, ("bought %s for %s"):format(entryModel(new), money(price))
    end
    if not asked then return nil, "no confirm (garage full or click cooldown)" end
    return nil, ("declined at %s"):format(money(price))
end

-- ============================== junk scan + ESP ==============================
local hui = gethui and gethui() or game:GetService("CoreGui")
local espRoot = Instance.new("Folder")
espRoot.Name = "FixItUpESP"
espRoot.Parent = hui

local junk = {} -- [model] = info + { bb, txt, hl }
local function dropJunk(m)
    local j = junk[m]
    junk[m] = nil
    if j then if j.bb then j.bb:Destroy() end if j.hl then j.hl:Destroy() end end
end

local function makeEsp(j)
    local part = j.model:FindFirstChild("DriveSeat") or j.model.PrimaryPart or j.model:FindFirstChildWhichIsA("BasePart", true)
    if not part then return end
    local bb = Instance.new("BillboardGui")
    bb.AlwaysOnTop, bb.LightInfluence, bb.ResetOnSpawn, bb.Adornee = true, 0, false, part
    bb.Size, bb.StudsOffsetWorldSpace = UDim2.fromOffset(260, 48), Vector3.new(0, 6, 0)
    local txt = Instance.new("TextLabel")
    txt.Size, txt.BackgroundTransparency, txt.RichText = UDim2.fromScale(1, 1), 1, true
    txt.Font, txt.TextStrokeTransparency = Enum.Font.GothamBold, 0.3
    txt.Parent = bb
    bb.Parent = espRoot
    local hl = Instance.new("Highlight")
    hl.Adornee, hl.FillTransparency, hl.OutlineTransparency = j.model, 0.8, 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = espRoot
    j.bb, j.txt, j.hl = bb, txt, hl
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
        end
    end
    local cp = camPos()
    for m, j in pairs(junk) do
        if not j.bb then makeEsp(j) end -- far cars stream in later
        j.dist = (m:GetPivot().Position - cp).Magnitude
        local col, show = CFG.color[j.tier], CFG.show[j.tier]
        if j.bb then
            j.bb.Enabled = CFG.esp and show and j.dist <= CFG.maxDist
            j.txt.TextSize, j.txt.TextColor3 = CFG.textSize, col
            j.txt.Text = ("[%s] %s\n<font size=\"%d\" color=\"#ffffff\">%s–%s · +%s–%s · %dm</font>"):format(
                j.tier, j.name, CFG.textSize - 2, money(j.lo), money(j.hi), money(j.profitLo), money(j.profitHi), j.dist)
        end
        if j.hl then
            j.hl.Enabled = CFG.esp and CFG.outline and show and j.dist <= CFG.maxDist
            j.hl.OutlineColor, j.hl.FillColor = col, col
        end
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

local function junkLabel(j) return ("[%s] %s  %s–%s"):format(j.tier, j.name, money(j.lo), money(j.hi)) end

-- my loose parts: wear + game's delete countdown
local partEsp = {}
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
local notify = function() end
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
    local best
    for _, j in ipairs(sortedJunk()) do
        local modelOk = next(CFG.buyModels) == nil
        for _, n in ipairs(j.names) do if CFG.buyModels[n] then modelOk = true end end
        if not j.exclusive and TIER_RANK[j.tier] <= TIER_RANK[CFG.buyMinTier] and modelOk
            and j.lo <= CFG.buyMaxPrice and j.profitLo >= CFG.buyMinProfit and myMoney() - j.lo >= CFG.reserve then
            best = best or j
        end
    end
    return best
end

local function autoStep()
    if busy then return end
    -- 1) finish cars we bought: repair, then sell
    for _, e in ipairs(entries()) do
        local o = not isFav(e) and OWNED[e.Name]
        if o and os.time() >= (o.nextTry or 0) then
            if CFG.autoRepair and not o.repaired then
                busy, busyWhat = true, "repairing " .. entryModel(e)
                local ok, msg = repairCar(e)
                o.tries = (o.tries or 0) + 1
                if ok or o.tries >= 2 then o.repaired = true end -- two tries, then sell it as it is
                saveOwned()
                log(msg)
                busy = false
                return
            end
            if CFG.autoSell and (o.repaired or not CFG.autoRepair) then
                local left = sellCooldownLeft(e)
                if left > 0 then
                    autoStatus = ("waiting sell timer for %s: %dm %02ds"):format(entryModel(e), left // 60, left % 60)
                else
                    busy, busyWhat = true, "selling " .. entryModel(e)
                    local ok, msg = sellCar(e)
                    log(msg)
                    busy = false
                    if not ok and OWNED[e.Name] then OWNED[e.Name].nextTry = os.time() + 30 end -- don't respawn it at the NPC every 2 s
                    return
                end
            end
        end
    end
    -- 2) buy the best junk car that fits
    if CFG.autoBuy then
        if #entries() >= garageSlots() then autoStatus = ("garage full %d/%d"):format(#entries(), garageSlots()) return end
        local j = wantedJunk()
        if not j then autoStatus = "no junk car matches the filters" return end
        busy, busyWhat = true, "buying " .. j.name
        local e, msg = buyJunk(j)
        log(msg)
        busy = false
    end
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
for _, g in ipairs(workspace.Garages:GetChildren()) do
    local ex = g:FindFirstChild("ExitPos")
    if ex then
        local price = g:GetAttribute("Price")
        PLACES[#PLACES + 1] = { ("Garage: %s%s"):format(g.Name, price and (" (" .. money(price) .. ")") or ""), ex.Position }
    end
end
local PLACE_NAMES, PLACE_POS = {}, {}
for _, p in ipairs(PLACES) do PLACE_NAMES[#PLACE_NAMES + 1] = p[1]; PLACE_POS[p[1]] = p[2] end

local selectedCar -- garage entry picked in the Car tab
local function goPlace(name)
    local pos = name == "My garage" and (function()
        local g = workspace.Garages:FindFirstChild(tostring(PD:FindFirstChild("GarageModel") and PD.GarageModel.Value or "Default"))
        return g and g:FindFirstChild("ExitPos") and g.ExitPos.Position
    end)() or PLACE_POS[name]
    if not pos then return end
    local at = ground(pos)
    tpTo(CFrame.new(at))
    if CFG.bringCar and selectedCar and selectedCar.Parent then
        spawnCar(selectedCar, CFrame.new(at + Vector3.new(0, 2, 12)))
    end
end
table.insert(PLACE_NAMES, 1, "My garage")

-- ============================== unload ==============================
local Library
local function unload()
    if getgenv().FIU_MAIN == nil then return end
    getgenv().FIU_MAIN = nil
    running = false
    for _, c in ipairs(conns) do pcall(c.Disconnect, c) end
    CONFIRM.OnClientInvoke = origConfirm
    espRoot:Destroy()
    if Library then pcall(Library.Unload, Library) end
end
getgenv().FIU_MAIN = { unload = unload, cfg = CFG, junk = junk, owned = OWNED, state = STATE,
    repairCar = repairCar, sellCar = sellCar, buyJunk = buyJunk, spawnCar = spawnCar, log = logLines,
    machines = machines, liftCF = liftCF, garageSlots = garageSlots }

-- ============================== loops ==============================
task.spawn(function()
    while running do
        guard("scan", scanJunk)
        guard("parts", scanParts)
        task.wait(0.5)
    end
end)
task.spawn(function()
    while running do
        if CFG.autoBuy or CFG.autoRepair or CFG.autoSell then guard("auto", autoStep) else autoStatus = "off" end
        task.wait(2)
    end
end)

-- ============================== Obsidian UI ==============================
local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local function obsidian(file, remote)
    local path = "BattleBotFarm/lib/" .. file -- shared local copy (a hung HttpGet once jammed the executor queue)
    local ok, src = pcall(function() return isfile(path) and readfile(path) end)
    return loadstring(ok and src or game:HttpGet(repo .. remote))()
end
Library            = obsidian("Library.lua", "Library.lua")
local ThemeManager = obsidian("ThemeManager.lua", "addons/ThemeManager.lua")
local SaveManager  = obsidian("SaveManager.lua", "addons/SaveManager.lua")
notify = function(msg) Library:Notify(msg, 5) end

local Window = Library:CreateWindow({
    Title = "Fix It Up", Footer = "junkyard tiers · auto flip · repair · teleports",
    Center = true, AutoShow = true, ToggleKeybind = Enum.KeyCode.RightControl,
})
local Tabs = {
    Junk     = Window:AddTab("Junkyard"),
    Auto     = Window:AddTab("Auto"),
    Car      = Window:AddTab("Car"),
    Shop     = Window:AddTab("Shop"),
    Teleport = Window:AddTab("Teleport"),
    Settings = Window:AddTab("Settings"),
}
local function set(key) return function(v) CFG[key] = v end end
local function run(name, f) -- buttons: one action at a time, off the UI thread
    return function()
        if busy then notify("Busy: " .. tostring(busyWhat)) return end
        task.spawn(function()
            busy, busyWhat = true, name
            local ok = guard(name, f)
            busy = false
        end)
    end
end

-- Junkyard
local Tier = Tabs.Junk:AddLeftGroupbox("Tiers")
Tier:AddLabel("Tier = spawn chance. Toggle shows/hides a tier's labels and outlines; the swatch recolors it.", true)
for _, t in ipairs(TIERS) do
    Tier:AddToggle("FIU_Show_" .. t, { Text = TIER_TEXT[t], Default = CFG.show[t], Callback = function(v) CFG.show[t] = v end })
        :AddColorPicker("FIU_Col_" .. t, { Default = CFG.color[t], Title = TIER_TEXT[t], Callback = function(c) CFG.color[t] = c end })
end
local Disp = Tabs.Junk:AddLeftGroupbox("Display")
Disp:AddToggle("FIU_Esp", { Text = "Car labels", Default = CFG.esp, Callback = set("esp") })
Disp:AddToggle("FIU_Outline", { Text = "Outline cars", Default = CFG.outline, Callback = set("outline") })
Disp:AddSlider("FIU_MaxDist", { Text = "Max distance", Default = CFG.maxDist, Min = 100, Max = 6000, Rounding = 0, Suffix = " studs", Callback = set("maxDist") })
Disp:AddSlider("FIU_TextSize", { Text = "Text size", Default = CFG.textSize, Min = 10, Max = 24, Rounding = 0, Suffix = "px", Callback = set("textSize") })
Disp:AddToggle("FIU_Alerts", { Text = "Spawn alerts", Default = CFG.alerts, Tooltip = "Uses the server's 'rare car has appeared' broadcast", Callback = set("alerts") })
Disp:AddDropdown("FIU_AlertMin", { Text = "Alert from tier", Values = TIERS, Default = CFG.alertMin, Callback = set("alertMin") })

local List = Tabs.Junk:AddRightGroupbox("Junk cars now")
local junkDrop = List:AddDropdown("FIU_JunkPick", { Text = "Car", Values = {}, AllowNull = true })
local junkByLabel = {}
List:AddButton({ Text = "Teleport to car", Func = run("tp junk", function()
    local j = junkByLabel[junkDrop.Value]
    if j and j.model.Parent then tpTo(j.model:GetPivot() * CFrame.new(0, 3, 8)) end
end) })
List:AddButton({ Text = "Buy car", Tooltip = "Buys at the real price if it's under Auto > max price and above your reserve", Func = run("buy", function()
    local j = junkByLabel[junkDrop.Value]
    if not j then return end
    local e, msg = buyJunk(j)
    log(msg); notify(msg)
end) })
local junkLabelBox = List:AddLabel("-", true)

-- Auto
local AutoBox = Tabs.Auto:AddLeftGroupbox("Flip loop")
AutoBox:AddLabel("Buys junk cars that pass the filters, repairs them at the repair shop, sells them at Used Cars once the sell timer allows. Only cars bought by this script are ever sold.", true)
AutoBox:AddToggle("FIU_AutoBuy", { Text = "Auto buy", Default = CFG.autoBuy, Callback = set("autoBuy") })
AutoBox:AddToggle("FIU_AutoRepair", { Text = "Auto repair after buy", Default = CFG.autoRepair, Callback = set("autoRepair") })
AutoBox:AddToggle("FIU_AutoSell", { Text = "Auto sell (script-bought only)", Default = CFG.autoSell, Callback = set("autoSell") })
local autoLabel = AutoBox:AddLabel("-", true)

local Filt = Tabs.Auto:AddRightGroupbox("Buy filters")
Filt:AddDropdown("FIU_BuyTier", { Text = "Tier at least", Values = { "S", "A", "B", "C", "D" }, Default = CFG.buyMinTier, Callback = set("buyMinTier") })
Filt:AddDropdown("FIU_BuyModels", { Text = "Only these models (none = any)", Values = CAT_NAMES, Multi = true, Default = {},
    Callback = function(v) CFG.buyModels = v end })
Filt:AddSlider("FIU_BuyMax", { Text = "Max price", Default = CFG.buyMaxPrice, Min = 1000, Max = 500000, Rounding = 0, Suffix = "€", Callback = set("buyMaxPrice") })
Filt:AddSlider("FIU_BuyProfit", { Text = "Min profit", Default = CFG.buyMinProfit, Min = 0, Max = 100000, Rounding = 0, Suffix = "€",
    Tooltip = "Profit = price x profit multiplier (sale at 100% condition)", Callback = set("buyMinProfit") })

local Timer = Tabs.Auto:AddRightGroupbox("Sell timer")
Timer:AddLabel("The server refuses to sell a car for a while after you buy it. 0 = learn it from the first refusal (saved).", true)
Timer:AddSlider("FIU_SellCd", { Text = "Sell timer", Default = math.ceil(CFG.sellCooldown / 60), Min = 0, Max = 60, Rounding = 0, Suffix = " min",
    Callback = function(v) CFG.sellCooldown = v * 60; saveState() end })

-- Car
local CarBox = Tabs.Car:AddLeftGroupbox("Your cars")
local carDrop = CarBox:AddDropdown("FIU_CarPick", { Text = "Car", Values = {}, AllowNull = true })
local carByLabel = {}
carDrop:OnChanged(function(v) selectedCar = carByLabel[v] end)
CarBox:AddButton({ Text = "Spawn car here", Func = run("spawn", function()
    if selectedCar then local r = hrp(); spawnCar(selectedCar, r.CFrame * CFrame.new(0, 2, -12)) end
end) })
CarBox:AddButton({ Text = "Teleport to car", Func = run("tp car", function()
    local c = selectedCar and carOf(selectedCar)
    if c then tpTo(c:GetPivot() * CFrame.new(0, 3, 8)) end
end) })
CarBox:AddButton({ Text = "Repair (teleports car to the repair shop)", Func = run("repair", function()
    if not selectedCar then return end
    local ok, msg = repairCar(selectedCar)
    if ok and isFlip(selectedCar) then OWNED[selectedCar.Name].repaired = true; saveOwned() end
    log(msg); notify(msg)
end) })
CarBox:AddButton({ Text = "Sell (not favorites)", DoubleClick = true, Tooltip = "Double-click. Favorites are locked and never sold.", Func = run("sell", function()
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

local FavBox = Tabs.Car:AddRightGroupbox("Favorites / collection")
FavBox:AddLabel("Locked cars are never sold, and the auto loop never touches them. Pick a car above, then lock it.", true)
FavBox:AddButton({ Text = "★ Lock selected car", Func = function()
    if selectedCar then FAV[selectedCar.Name] = entryModel(selectedCar); saveFav(); log("locked " .. entryModel(selectedCar)) end
end })
FavBox:AddButton({ Text = "Unlock selected car", DoubleClick = true, Func = function()
    if selectedCar and FAV[selectedCar.Name] then FAV[selectedCar.Name] = nil; saveFav(); log("unlocked " .. entryModel(selectedCar)) end
end })
local favLabel = FavBox:AddLabel("-", true)

local RepBox = Tabs.Car:AddRightGroupbox("Repair settings")
RepBox:AddDropdown("FIU_Station", { Text = "Repair shop", Values = { "Dealership", "Pitstop" }, Default = CFG.station,
    Tooltip = "Dealership = the quiet one; Pitstop is the busy one", Callback = set("station") })
RepBox:AddSlider("FIU_RepMin", { Text = "Repair parts worn at least", Default = CFG.repairMin, Min = 1, Max = 90, Rounding = 0, Suffix = "%", Callback = set("repairMin") })
RepBox:AddToggle("FIU_Replace", { Text = "Replace parts with no machine", Default = CFG.replaceWorn,
    Tooltip = "Sparkplugs, injectors, timing belts...: buys a new one at the parts store", Callback = set("replaceWorn") })
RepBox:AddToggle("FIU_PartEsp", { Text = "Show my loose parts", Default = false, Tooltip = "Wear + the game's 90 s delete countdown", Callback = set("partEsp") })

-- Shop
local ShopBox = Tabs.Shop:AddLeftGroupbox("Spare parts")
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
    if new then c.PartsEvent:FireServer("ReapplyPart", new); log("installed " .. p.Name) else log("buy failed: " .. tostring(why)) end
end) })

local ToolBox = Tabs.Shop:AddRightGroupbox("Tools")
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
local TpBox = Tabs.Teleport:AddLeftGroupbox("Shops & places")
local placeDrop = TpBox:AddDropdown("FIU_Place", { Text = "Place", Values = PLACE_NAMES, AllowNull = true })
TpBox:AddButton({ Text = "Go", Func = run("tp", function() if placeDrop.Value then goPlace(placeDrop.Value) end end) })
TpBox:AddToggle("FIU_BringCar", { Text = "Bring selected car", Default = CFG.bringCar,
    Tooltip = "Spawns the car picked in the Car tab next to you when you teleport", Callback = set("bringCar") })
local PlBox = Tabs.Teleport:AddRightGroupbox("Players")
local plDrop = PlBox:AddDropdown("FIU_Player", { Text = "Player", SpecialType = "Player", ExcludeLocalPlayer = true })
PlBox:AddButton({ Text = "Go to player", Func = run("tp player", function()
    local p = plDrop.Value
    p = typeof(p) == "Instance" and p or Players:FindFirstChild(tostring(p))
    local c = p and p.Character
    if c then tpTo(c:GetPivot() * CFrame.new(0, 0, 4)) end
end) })

-- Settings
local Spend = Tabs.Settings:AddRightGroupbox("Spending")
Spend:AddSlider("FIU_Reserve", { Text = "Always keep", Default = CFG.reserve, Min = 0, Max = 1000000, Rounding = 0, Suffix = "€",
    Tooltip = "Buying never takes your money below this", Callback = set("reserve") })
local PlayerBox = Tabs.Settings:AddRightGroupbox("Player")
PlayerBox:AddToggle("FIU_SpeedOn", { Text = "Walk speed", Default = CFG.speedOn, Callback = function(v)
    CFG.speedOn = v
    if not v then local h = hum(); if h then h.WalkSpeed = 16 end end
end })
PlayerBox:AddSlider("FIU_Speed", { Text = "Speed", Default = CFG.walkSpeed, Min = 16, Max = 120, Rounding = 0, Callback = set("walkSpeed") })
PlayerBox:AddToggle("FIU_AntiAfk", { Text = "Anti-AFK", Default = CFG.antiAfk, Callback = set("antiAfk") })
local LogBox = Tabs.Settings:AddLeftGroupbox("Log")
logLabel = LogBox:AddLabel("-", true)
local Menu = Tabs.Settings:AddLeftGroupbox("Menu")
Menu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })
Library:OnUnload(unload)
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "FIU_JunkPick", "FIU_CarPick", "FIU_ShopCat", "FIU_ShopPart", "FIU_Tool", "FIU_Place", "FIU_Player", "FIU_SellCd" })
SaveManager:SetFolder(DIR)
ThemeManager:SetFolder(DIR)
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:LoadAutoloadConfig()

-- ============================== label refresh ==============================
task.spawn(function()
    local lastJunkVals, lastCarVals = "", ""
    while running do
        guard("labels", function()
            -- junk list
            local list, vals, lines = sortedJunk(), {}, {}
            table.clear(junkByLabel)
            for _, j in ipairs(list) do
                local l = junkLabel(j)
                vals[#vals + 1] = l; junkByLabel[l] = j
                lines[#lines + 1] = ('<font color="%s"><b>[%s]</b> %s</font>  %s–%s · +%s · %dm'):format(
                    hex(CFG.color[j.tier]), j.tier, j.name, money(j.lo), money(j.hi), money(j.profitHi), j.dist or 0)
            end
            local key = table.concat(vals, "|")
            if key ~= lastJunkVals then lastJunkVals = key; junkDrop:SetValues(vals) end
            junkLabelBox:SetText(#lines > 0 and table.concat(lines, "\n") or "no junk cars loaded")

            -- cars
            local cvals = {}
            table.clear(carByLabel)
            for _, e in ipairs(entries()) do
                local l = ("%s%s [%s]"):format(isFav(e) and "★ " or isFlip(e) and "FLIP " or "", entryModel(e), e.Name:sub(1, 4))
                cvals[#cvals + 1] = l; carByLabel[l] = e
            end
            local ckey = table.concat(cvals, "|")
            if ckey ~= lastCarVals then lastCarVals = ckey; carDrop:SetValues(cvals) end
            if selectedCar and not selectedCar.Parent then selectedCar = nil end
            local e = selectedCar
            if e then
                local c = carOf(e)
                local lines2 = { ("<b>%s</b> · %s"):format(entryModel(e), isFav(e) and '<font color="#ffd24a">★ favorite (locked)</font>' or isFlip(e) and '<font color="#5ee07a">flip car</font>' or '<font color="#aaaaaa">not locked</font>') }
                local buy = tonumber(entryVal(e, "BuyPrice")) or 0
                local pm = c and c:GetAttribute("ProfitMultiplier")
                lines2[#lines2 + 1] = ("Bought %s%s"):format(money(buy), pm and (" · sells for %s at 100%%"):format(money(buy * (1 + pm))) or "")
                if isFlip(e) then
                    local left = sellCooldownLeft(e)
                    lines2[#lines2 + 1] = CFG.sellCooldown == 0 and "Sell timer: unknown yet" or (left > 0 and ("Can sell in %dm %02ds"):format(left // 60, left % 60) or "Can sell ✓")
                end
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
                carInfo:SetText(table.concat(lines2, "\n"))
            else
                carInfo:SetText("Pick a car")
            end

            local fl = {}
            for guid, model in pairs(FAV) do fl[#fl + 1] = ("★ %s [%s]%s"):format(model, guid:sub(1, 4), Garage:FindFirstChild(guid) and "" or " (not in garage)") end
            table.sort(fl)
            favLabel:SetText(#fl > 0 and table.concat(fl, "\n") or "No locked cars")

            autoLabel:SetText(("%s\nGarage %d/%d · money %s · reserve %s\nSold by script: %d (%s)\nSell timer: %s"):format(
                busy and ("busy: " .. tostring(busyWhat)) or autoStatus, #entries(), garageSlots(), money(myMoney()), money(CFG.reserve),
                STATE.sold or 0, money(STATE.earned or 0), CFG.sellCooldown > 0 and (math.floor(CFG.sellCooldown / 60) .. " min") or "learning"))
        end)
        task.wait(0.5)
    end
end)

Library:Notify("Fix It Up ready — RightCtrl toggles the UI. Only script-bought cars are ever sold.", 5)
