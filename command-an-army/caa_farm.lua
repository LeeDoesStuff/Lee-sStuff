--[[
    Command An Army v1  (GameId 10258991999; built on the New Player Server build, place 92949164250558)
    UI: Obsidian. Config folder: CommandArmy. Log: CommandArmy/log.txt (heartbeat every 60 s).
    Every payload below is copied from the game's own client (decompile, caa_main/) or seen live (spy capture):
      Rewards : DailyRewardRequest:Invoke({Type="GetState"|"Claim"}), QuestRequest:Invoke({Type="GetState"}|{Type="Claim",Period,QuestId}),
                RewardRequest:Invoke("GetState"|"CheckLike"), RedeemCode:Invoke(code)
      Units   : BannerRequest {Type="GetState"|"Summon",BannerId="Standard",Count=1|10,SummonKey,RequestId} -> BannerResponse
                AscensionRequest {RequestId,MainCopyId,DuplicateCopyId}; EvolutionRequest {RequestId,CopyId}
                UnitInventoryRequest("EquipBest")
      Match   : MapVoteTeleportRequest() during Intermission, else TeamPickerOpenRequest() + TeamRequest("Attackers"|"Defenders")
                RespawnUnitRequest("Select", slot) then RespawnUnitRequest(slot) while AwaitingRespawnUnit
      Army    : TroopStateRequest("Hold"|"Follow"|"Attack"|"Formation1-3"), RushRequest(dir, endPos), AimVolleyState + AimArrowFire
      Combat  : PlayerCombatRequest("Attack") / ("Heal")  (server resolves hits; no target argument exists)
    NEVER fired: Remotes.Admin.*, Remotes.TesterMenu.* (staff-only / honeypots) — fire() refuses them.
    Spec: command-an-army-spec.md
]]

if getgenv().CAA_FARM then pcall(getgenv().CAA_FARM.unload) end

local Players   = game:GetService("Players")
local RS        = game:GetService("ReplicatedStorage")
local HS        = game:GetService("HttpService")
local UIS       = game:GetService("UserInputService")
local Teams     = game:GetService("Teams")
local lp        = Players.LocalPlayer

local Shared  = RS:WaitForChild("Shared")
local Remotes = Shared:WaitForChild("Remotes")
local GROUP_ID = 1014980424 -- "Fight, Fight, Fight!" (game owner)

-- ============================== helpers ==============================
local FORBID = { Admin = true, TesterMenu = true, ClientSecuritySignal = true }
local function remote(name)
    assert(not FORBID[name], "refusing honeypot/staff remote " .. name)
    local r = Remotes:FindFirstChild(name)
    assert(r and (r:IsA("RemoteEvent") or r:IsA("RemoteFunction")), "missing remote " .. name)
    return r
end
local function fire(name, ...) remote(name):FireServer(...) end
local function invoke(name, ...)
    local r = remote(name)
    local ok, res = pcall(r.InvokeServer, r, ...)
    return ok and res or nil, (not ok) and res or nil
end
local function attr(k) return lp:GetAttribute(k) end
local function now() return workspace:GetServerTimeNow() end
local function guid() return HS:GenerateGUID(false) end
local function json(k)
    local s = attr(k)
    if type(s) ~= "string" or s == "" then return nil end
    local ok, t = pcall(HS.JSONDecode, HS, s)
    return ok and t or nil
end
local function root(m)
    return m and (m:FindFirstChild("HumanoidRootPart") or (m:IsA("Model") and m.PrimaryPart)) or nil
end
local function fmt(n)
    n = tonumber(n) or 0
    if n >= 1e6 then return ("%.1fM"):format(n / 1e6) elseif n >= 1e3 then return ("%.1fK"):format(n / 1e3) end
    return tostring(math.floor(n))
end

local LOGDIR, LOG = "CommandArmy", "CommandArmy/log.txt"
local logLines = {}
local function log(msg)
    msg = os.date("%H:%M:%S ") .. tostring(msg)
    table.insert(logLines, 1, msg)
    if #logLines > 40 then logLines[41] = nil end
    pcall(function()
        if not isfolder(LOGDIR) then makefolder(LOGDIR) end
        if isfile(LOG) then appendfile(LOG, msg .. "\n") else writefile(LOG, msg .. "\n") end
    end)
end
local errs = {}
local function guard(name, f, ...)
    local ok, err = pcall(f, ...)
    if not ok and errs[name] ~= err then errs[name] = err; log("ERR " .. name .. ": " .. tostring(err)) end
end

-- ============================== config (every automation starts OFF) ==============================
local CFG = {
    daily = false, quests = false,
    summon = false, summonCount = 10, gemReserve = 0,
    ascend = false, ascendMaxLevel = 3, ascendKeepFav = true,
    evolve = false, equipBest = false,
    autoJoin = false, team = "Smaller team", joinDelay = 8,
    antiIdle = true,
    campLoop = false, autoRespawn = false, autoResupply = false, walkToCamp = false, spawnPriority = "Strongest ready", spawnPreferred = 0, spawnAllowed = {}, spawnDelay = 0,
    keepState = false, keepStateName = "Attack", keepStateEvery = 8, manualPause = 20,
    autoRush = false, rushRange = 120, autoVolley = false,
    autoAttack = false, attackRange = 8, attackPlayers = true, attackTroops = true, faceTarget = false,
    autoHeal = false, healBelow = 45,
    espPlayers = false, espArmies = false, espAI = true, espBeacon = true, espEnemies = true, espTeam = false, espMaxDist = 800,
    enemyColor = Color3.fromRGB(255, 50, 50), enemyArmyColor = Color3.fromRGB(255, 150, 40),
    teamColor = Color3.fromRGB(70, 150, 255), teamArmyColor = Color3.fromRGB(60, 225, 200),
    enemyAIColor = Color3.fromRGB(190, 90, 255), teamAIColor = Color3.fromRGB(160, 170, 185),
    pauseOnAC = true, pauseOnStaff = false, staffRank = 200,
}
local stats = { summons = 0, ascends = 0, evolves = 0, quests = 0, dailies = 0, joins = 0, spawns = 0, attacks = 0, heals = 0, corrections = 0 }
local status = { summon = "-", units = "-", match = "-", combat = "-", safety = "ok", battle = "-", army = "-" }
local paused, pauseWhy = false, nil
local running, conns = true, {}
local function on(sig, f) local c = sig:Connect(f); conns[#conns + 1] = c; return c end
local notify = function() end

local function inLobby() return attr("MatchState") == "Lobby" end
local function inGame() return attr("MatchState") == "Game" end
local function blocked() return paused or not running end

-- ============================== safety ==============================
local function readAC()
    local m = Shared:FindFirstChild("Modules") and Shared.Modules:FindFirstChild("ClientSecurityProtocol")
    if not m then return nil end
    local ok, t = pcall(require, m) -- table read only; module is plain data
    return ok and type(t) == "table" and t.AntiCheatEnabled == true
end
local staffSeen = {}
local function checkStaff(p)
    if p == lp then return end
    task.spawn(function()
        local ok, rank = pcall(p.GetRankInGroup, p, GROUP_ID)
        if ok and rank and rank >= CFG.staffRank then
            staffSeen[p] = rank
            log(("staff? %s rank %d joined"):format(p.Name, rank))
            notify(("High group rank player: %s (%d)"):format(p.Name, rank))
        end
    end)
end
for _, p in ipairs(Players:GetPlayers()) do checkStaff(p) end
on(Players.PlayerAdded, checkStaff)
on(Players.PlayerRemoving, function(p) staffSeen[p] = nil end)
do
    local mc = Remotes:FindFirstChild("MovementCorrection")
    if mc then on(mc.OnClientEvent, function() stats.corrections += 1 end) end
end

task.spawn(function()
    while running do
        local ac = readAC()
        local staff = next(staffSeen) ~= nil
        local why = (CFG.pauseOnAC and ac) and "anti-cheat enabled by an update" or ((CFG.pauseOnStaff and staff) and "staff in server" or nil)
        if why ~= pauseWhy then
            paused, pauseWhy = why ~= nil, why
            log(why and ("PAUSED: " .. why) or "resumed")
            if why then notify("Automation paused: " .. why) end
        end
        status.safety = ("anti-cheat %s · staff %s · corrections %d%s"):format(ac and "ON" or (ac == false and "off" or "?"),
            staff and "PRESENT" or "none", stats.corrections, paused and (" · PAUSED (" .. pauseWhy .. ")") or "")
        task.wait(15)
    end
end)

-- manual input detection (pause auto army state after the player commands troops themselves)
local lastManual = 0
on(UIS.InputBegan, function(i, gp)
    if gp then return end
    local k = i.KeyCode -- TroopHudClient keys: X hold, C follow, V attack, B rush/aim, 1-3 formations
    if k == Enum.KeyCode.X or k == Enum.KeyCode.C or k == Enum.KeyCode.V or k == Enum.KeyCode.B
        or k == Enum.KeyCode.One or k == Enum.KeyCode.Two or k == Enum.KeyCode.Three then
        lastManual = os.clock()
    end
end)

-- anti idle (Roblox 20 min kick)
on(lp.Idled, function()
    if not CFG.antiIdle then return end
    local vu = game:GetService("VirtualUser")
    vu:CaptureController(); vu:ClickButton2(Vector2.new())
end)

-- ============================== rewards ==============================
local function doDaily()
    local r = invoke("DailyRewardRequest", { Type = "GetState" })
    if type(r) ~= "table" then return end
    local st = type(r.State) == "table" and r.State or r
    if st.CanClaim == true then
        local c = invoke("DailyRewardRequest", { Type = "Claim" })
        stats.dailies += 1
        log("daily claim -> " .. (type(c) == "table" and tostring(c.Status or c.Code or "ok") or tostring(c)))
    end
end

local function doQuests()
    local r = invoke("QuestRequest", { Type = "GetState" })
    if type(r) ~= "table" or type(r.State) ~= "table" then return end
    local periods = type(r.State.Periods) == "table" and r.State.Periods or r.State -- live: State.Periods.Daily.Quests
    for _, period in ipairs({ "Daily", "Weekly" }) do
        local p = periods[period]
        for _, q in ipairs(type(p) == "table" and type(p.Quests) == "table" and p.Quests or {}) do
            local goal, prog = tonumber(q.Goal) or 0, tonumber(q.Progress) or 0
            if q.Claimed ~= true and (q.Completed == true or (goal > 0 and prog >= goal)) then
                task.wait(0.6) -- the game spaces quest requests 0.55 s apart
                local c = invoke("QuestRequest", { Type = "Claim", Period = period, QuestId = tostring(q.Id) })
                stats.quests += 1
                log(("quest %s %s -> %s"):format(period, tostring(q.Id), type(c) == "table" and tostring(c.Status or "ok") or tostring(c)))
            end
        end
    end
end

task.spawn(function()
    while running do
        if not blocked() and inLobby() then
            if CFG.daily then guard("daily", doDaily) end
            if CFG.quests then guard("quests", doQuests) end
        end
        task.wait(120)
    end
end)

-- ============================== lobby stations ==============================
-- ponytail: unused for now. Measured 2026-09-27 after a rejoin: BannerRequest GetState answers from anywhere with the
-- UI closed (an earlier "no reply" was a wedged session, likely from a non-GUID RequestId). Kept in case a station
-- turns out to be range-gated: game's own lobby teleport (LobbyMarkerTeleportRequest "<Marker>") + the station prompt.
local STATION = { Summon = "Summon", Ascension = "Upgrade", Evolve = "Upgrade", Quest = "Play", Traits = "Upgrade" }
local openStation = nil
local function stationPart(name)
    local lm = workspace:FindFirstChild("Lobby") -- live: workspace.Lobby.Interactable.<Summon|Ascension|Evolve|Quest|Traits|Guild>
    local m = lm and lm:FindFirstChild("Interactable")
    return m and m:FindFirstChild(name)
end
local function useStation(name)
    if not inLobby() then return false end
    if openStation == name and attr("InteractableUIOpen") == true then return true end
    local part = stationPart(name)
    local prompt = part and part:FindFirstChildOfClass("ProximityPrompt")
    if not prompt then status.summon = "station " .. name .. " not found"; return false end
    local r = root(lp.Character)
    if not r or (r.Position - part.Position).Magnitude > prompt.MaxActivationDistance then
        fire("LobbyMarkerTeleportRequest", STATION[name])
        task.wait(1.5)
    end
    if attr("InteractableUIOpen") == true then
        -- another station is open and its prompts are locked: close it through the game's InteractableUIManager.
        -- Calling a game module drops this thread's capabilities until it yields, hence the wait.
        pcall(function() require(Shared.Modules.InteractableUIManager).Get():Close() end)
        task.wait(0.5)
    end
    fireproximityprompt(prompt)
    for _ = 1, 20 do
        if attr("InteractableUIOpen") == true then break end
        task.wait(0.1)
    end
    openStation = attr("InteractableUIOpen") == true and name or nil
    log(("open station %s -> %s"):format(name, tostring(openStation ~= nil)))
    return openStation ~= nil
end

-- ============================== units: summon ==============================
local banner = { state = nil, pending = {}, inFlight = false }
do
    local resp = Remotes:FindFirstChild("BannerResponse")
    if resp then
        on(resp.OnClientEvent, function(p)
            if type(p) ~= "table" then return end
            if type(p.State) == "table" then banner.state = p.State end
            local kind = p.RequestId and banner.pending[p.RequestId]
            if not kind then return end
            banner.pending[p.RequestId] = nil
            if kind == "Summon" then
                banner.inFlight = false
                if p.Success == true then
                    local names = {}
                    for _, u in ipairs(type(p.Results) == "table" and p.Results or {}) do
                        names[#names + 1] = type(u) == "table" and tostring(u.TroopId or u.Name or "?") or tostring(u)
                    end
                    log("summon ok: " .. table.concat(names, ", "))
                else
                    status.summon = "failed: " .. tostring(p.Code or p.Message)
                    log("summon failed: " .. tostring(p.Code) .. " " .. tostring(p.Message))
                    if p.Code == "InsufficientGems" or p.Code == "InventoryFull" then CFG.summon = false end
                end
            end
        end)
    end
end
local function bannerRequest(kind, t)
    local id = guid()
    banner.pending[id] = kind
    t.RequestId = id
    fire("BannerRequest", t)
    return id
end

local function doSummon()
    if banner.inFlight then return end
    if not banner.state then bannerRequest("State", { Type = "GetState" }); task.wait(1.5) end
    local st = banner.state
    local b = st and st.Banner
    local cost = type(b) == "table" and tonumber(b.GemCost)
    if not cost or (type(b) == "table" and b.Enabled ~= true) or st.CurrencyKind == "Tickets" then
        status.summon = "banner unavailable (or tickets-only region)"; return
    end
    local count = CFG.summonCount
    local gems = tonumber(attr("Gems")) or 0
    local inv = type(st.Inventory) == "table" and tonumber(st.Inventory.Available)
    if gems - cost * count < CFG.gemReserve then status.summon = ("waiting: %s gems, need %s + reserve"):format(fmt(gems), fmt(cost * count)); return end
    if inv and inv < count then status.summon = "inventory full (" .. inv .. " free)"; return end
    banner.inFlight = true
    bannerRequest("Summon", { Type = "Summon", BannerId = "Standard", Count = count, SummonKey = guid() })
    stats.summons += count
    status.summon = ("summoned x%d (%s gems each)"):format(count, fmt(cost))
    task.delay(12, function() banner.inFlight = false end)
end

-- ============================== units: ascend / evolve / equip ==============================
local function inventory() return json("UnitsInventory") end
local function loadoutSet(inv)
    local s = {}
    for _, l in ipairs(inv.Loadout or {}) do if l.CopyId then s[l.CopyId] = true end end
    return s
end
local function favSet(inv)
    local s = {}
    for k, v in pairs(inv.Favorites or {}) do
        if type(k) == "string" and v then s[k] = true elseif type(v) == "string" then s[v] = true end
    end
    return s
end

-- pairs of same TroopId + same AscensionLevel; the kept unit is the one in the loadout, else the most mastered
local function planAscend(inv)
    local lo, fav, groups = loadoutSet(inv), favSet(inv), {}
    for _, u in ipairs(inv.Units or {}) do
        local lvl = math.clamp(math.floor(tonumber(u.AscensionLevel) or 0), 0, 3)
        if u.CopyId and u.TroopId and lvl < CFG.ascendMaxLevel then
            local key = u.TroopId .. "#" .. lvl
            groups[key] = groups[key] or {}
            table.insert(groups[key], u)
        end
    end
    local plan = {}
    for _, g in pairs(groups) do
        table.sort(g, function(a, b)
            local la, lb = lo[a.CopyId] and 1 or 0, lo[b.CopyId] and 1 or 0
            if la ~= lb then return la > lb end
            return (tonumber(a.MasteryXP) or 0) + (tonumber(a.MasteryLevel) or 0) * 1e6 > (tonumber(b.MasteryXP) or 0) + (tonumber(b.MasteryLevel) or 0) * 1e6
        end)
        local main = g[1]
        for i = 2, #g do
            local d = g[i]
            if not lo[d.CopyId] and not (CFG.ascendKeepFav and fav[d.CopyId]) then
                plan[#plan + 1] = { main = main, dup = d }
                break -- one merge per group per pass; the inventory refreshes before the next
            end
        end
    end
    return plan
end
do -- self-check of the pairing rule
    local saved = CFG.ascendKeepFav
    local p = planAscend({ Loadout = { { CopyId = "b" } }, Favorites = {}, Units = {
        { CopyId = "a", TroopId = "Archer", AscensionLevel = 0, MasteryLevel = 5 },
        { CopyId = "b", TroopId = "Archer", AscensionLevel = 0, MasteryLevel = 1 },
        { CopyId = "c", TroopId = "Archer", AscensionLevel = 1 },
        { CopyId = "d", TroopId = "Knight", AscensionLevel = 3 }, { CopyId = "e", TroopId = "Knight", AscensionLevel = 3 } } })
    assert(#p == 1 and p[1].main.CopyId == "b" and p[1].dup.CopyId == "a", "planAscend self-check")
    CFG.ascendKeepFav = saved
end

local upg = { pending = nil }
for _, n in ipairs({ "AscensionResponse", "EvolutionResponse" }) do
    local r = Remotes:FindFirstChild(n)
    if r then
        on(r.OnClientEvent, function(p)
            if type(p) ~= "table" or p.RequestId ~= upg.pending then return end
            upg.pending = nil
            -- measured: merges land even when the reply says "Invalid Ascension request." — judge by the inventory, not the text
            log(("%s: Success=%s %s"):format(n, tostring(p.Success), tostring(p.Message or p.Code or "")))
        end)
    end
end

local function doAscend()
    local inv = inventory()
    if not inv then return end
    local plan = planAscend(inv)
    if #plan == 0 then return end
    local s = plan[1]
    upg.pending = guid()
    fire("AscensionRequest", { RequestId = upg.pending, MainCopyId = s.main.CopyId, DuplicateCopyId = s.dup.CopyId })
    stats.ascends += 1
    log(("ascend %s lv%d (keep %s, merge %s)"):format(s.main.TroopId, tonumber(s.main.AscensionLevel) or 0, s.main.CopyId:sub(6, 13), s.dup.CopyId:sub(6, 13)))
end

local function doEvolve()
    local inv = inventory()
    if not inv then return end
    for _, u in ipairs(inv.Units or {}) do
        if type(u.EvolutionPreview) == "table" and (tonumber(u.MasteryLevel) or 0) >= 20 then -- EvolutionEligibility.REQUIRED_MASTERY_LEVEL
            upg.pending = guid()
            fire("EvolutionRequest", { RequestId = upg.pending, CopyId = u.CopyId })
            stats.evolves += 1
            log(("evolve %s -> %s"):format(tostring(u.TroopId), tostring(u.EvolutionPreview.TroopId)))
            return
        end
    end
end

local lastInvSig = nil
task.spawn(function()
    while running do
        if not blocked() and inLobby() then
            if CFG.summon then guard("summon", doSummon) end
            if CFG.ascend and not upg.pending then guard("ascend", doAscend) end
            if CFG.evolve and not upg.pending then guard("evolve", doEvolve) end
            if CFG.equipBest then
                local inv = inventory()
                local sig = inv and #(inv.Units or {}) or 0
                if sig ~= lastInvSig then lastInvSig = sig; guard("equip", fire, "UnitInventoryRequest", "EquipBest") end
            end
        end
        local inv = inventory()
        if inv then
            local lo = {}
            for _, l in ipairs(inv.Loadout or {}) do lo[#lo + 1] = ("%s%s"):format(l.TroopId, (tonumber(l.AscensionLevel) or 0) > 0 and (" " .. l.AscensionLevel) or "") end
            status.units = ("%d / %d units · loadout: %s"):format(#(inv.Units or {}), tonumber(inv.MaxOwned) or 0, table.concat(lo, ", "))
        end
        task.wait(2.5)
        if upg.pending then task.wait(2); upg.pending = nil end -- response timeout
    end
end)

-- ============================== match: join + spawn ==============================
local function teamCount(name)
    local t = Teams:FindFirstChild(name)
    return t and #t:GetPlayers() or 0
end
local lastJoin = 0
local function doJoin()
    if os.clock() - lastJoin < CFG.joinDelay or lp:GetAttribute("TeamPickerActive") == true then return end
    lastJoin = os.clock()
    if workspace:GetAttribute("RoundState") == "Intermission" then
        fire("MapVoteTeleportRequest")
        status.match = "intermission: sent to map vote"
    else
        local team = CFG.team
        if team == "Smaller team" then team = teamCount("Attackers") <= teamCount("Defenders") and "Attackers" or "Defenders" end
        fire("TeamPickerOpenRequest")
        task.wait(0.5)
        fire("TeamRequest", team)
        status.match = "joining as " .. team
    end
    stats.joins += 1
    log(status.match)
end

-- ============================== battle: auto respawn ==============================
-- Two ways the game gives you a new army (DeathRespawnController / SupplyPointController):
--  1. Commander died: server sets AwaitingRespawnUnit=true and auto-spawns at AutoSpawnEndsAt (~15 s).
--     Client picks a loadout slot: RespawnUnitRequest("Select", slot), then RespawnUnitRequest(slot).
--     Server answers on the same remote: "Completed" | "Skipped" | "Rejected".
--  2. Army wiped, commander alive (CurrentUnitWiped=true): stand in a friendly supply camp, trigger its
--     "Spawn Unit" prompt -> server "Opened", point -> SupplyPointRequest("Begin", slot) -> "Started" -> "Completed".
--     Denied with "AccessDenied","EnemyNearby" when an enemy is in the camp. Camp cooldown: SupplyPointCooldownEndsAt.
-- Units on cooldown: UnitRespawnCooldowns[CopyId] = server time the unit is ready again.
local spawnState = { respawnReply = nil, supply = nil, supplyPoint = nil, lastTry = 0 }
do
    local rr = Remotes:FindFirstChild("RespawnUnitRequest")
    if rr then on(rr.OnClientEvent, function(msg) spawnState.respawnReply = msg end) end
    local sp = Remotes:FindFirstChild("SupplyPointRequest")
    if sp then
        on(sp.OnClientEvent, function(msg, a)
            spawnState.supply = msg
            if msg == "Opened" then spawnState.supplyPoint = a end
            if msg == "AccessDenied" then log("supply denied: " .. tostring(a)) end
        end)
    end
end

local function unitPower(u)
    return (tonumber(u.Stars) or 0) * 1e6 + (tonumber(u.AscensionLevel) or 0) * 1e4 + (tonumber(u.MasteryLevel) or 0) * 10
        + (tonumber(u.DPS) or 0) * (tonumber(u.TroopAmount) or 0) / 1e3
end

-- unlocked loadout slots and what's in them. The unlocked count isn't a recorded field yet, so try the likely names on
-- UnitsInventory and on the player, else fall back to the loadout entries (the game lists one per unlocked slot).
local SLOT_FIELDS = { "UnlockedSlots", "LoadoutSlots", "MaxLoadout", "LoadoutSize", "MaxEquipped", "UnlockedLoadoutSlots", "SlotCount" }
local function unlockedSlots(inv)
    for _, k in ipairs(SLOT_FIELDS) do
        local n = tonumber(inv[k]) or tonumber(attr(k))
        if n and n > 0 then return math.floor(n) end
    end
    local n = 0
    for _, l in ipairs(inv.Loadout or {}) do n = math.max(n, tonumber(l.Slot) or 0) end
    return math.max(n, #(inv.Loadout or {}))
end
local function loadoutSlots()
    local inv = inventory()
    if not inv then return {} end
    local byId, bySlot = {}, {}
    for _, u in ipairs(inv.Units or {}) do byId[u.CopyId] = u end
    for _, l in ipairs(inv.Loadout or {}) do if l.Slot then bySlot[tonumber(l.Slot)] = l end end
    local out = {}
    for s = 1, unlockedSlots(inv) do
        local l = bySlot[s]
        out[#out + 1] = { slot = s, unit = l and l.CopyId and byId[l.CopyId] or nil, troop = l and l.TroopId }
    end
    return out
end
local function slotLabel(e)
    local u = e.unit
    if not u then return ("Slot %d · empty"):format(e.slot) end
    local asc = tonumber(u.AscensionLevel) or 0
    return ("Slot %d · %s%s%s"):format(e.slot, tostring(u.TroopId or e.troop or "?"),
        u.Stars and (" ★" .. tostring(u.Stars)) or "", asc > 0 and (" A" .. asc) or "")
end
local function slotOf(label) return tonumber(tostring(label):match("^Slot (%d+)")) end

-- best loadout slot that is off cooldown and allowed, by the chosen priority
local function pickSlot()
    local inv = inventory()
    if not inv then return nil end
    local byId, cds, t = {}, json("UnitRespawnCooldowns") or {}, now()
    for _, u in ipairs(inv.Units or {}) do byId[u.CopyId] = u end
    local ready = {}
    for _, l in ipairs(inv.Loadout or {}) do
        local u = byId[l.CopyId]
        local cd = (tonumber(cds[tostring(l.CopyId)]) or 0) - t
        if u and cd <= 0 and CFG.spawnAllowed[tonumber(l.Slot)] ~= false then ready[#ready + 1] = { slot = l.Slot, unit = u } end
    end
    if #ready == 0 then return nil end
    table.sort(ready, function(a, b)
        if CFG.spawnPriority == "Slot order" then return a.slot < b.slot end
        local pa, pb = a.slot == CFG.spawnPreferred and 1 or 0, b.slot == CFG.spawnPreferred and 1 or 0
        if pa ~= pb then return pa > pb end
        return unitPower(a.unit) > unitPower(b.unit)
    end)
    return ready[1].slot, ready[1].unit
end

local function doDeathRespawn()
    if attr("AwaitingRespawnUnit") ~= true or os.clock() - spawnState.lastTry < 3 then return end
    local slot, u = pickSlot()
    if not slot then status.battle = "death screen: every allowed unit on cooldown, the game will auto-spawn"; return end
    if CFG.spawnDelay > 0 then task.wait(CFG.spawnDelay) end
    if attr("AwaitingRespawnUnit") ~= true then return end
    spawnState.lastTry, spawnState.respawnReply = os.clock(), nil
    fire("RespawnUnitRequest", "Select", slot)
    task.wait(0.3)
    fire("RespawnUnitRequest", slot)
    for _ = 1, 30 do if spawnState.respawnReply then break end task.wait(0.1) end
    stats.spawns += 1
    status.battle = ("respawned slot %d: %s → %s"):format(slot, tostring(u.TroopId), tostring(spawnState.respawnReply or "no reply"))
    log(status.battle)
end

-- friendly supply camps of the active map
local function mySide()
    local t = lp.Team and lp.Team.Name
    return t == "Attackers" and "Attacker" or (t == "Defenders" and "Defender" or nil)
end
local function friendlyCamps()
    local out, side = {}, mySide()
    local am = workspace:FindFirstChild("ActiveMap")
    for _, map in ipairs(am and am:GetChildren() or {}) do
        local sup = map:FindFirstChild("Interactable") and map.Interactable:FindFirstChild("Supplies")
        for _, pt in ipairs(sup and sup:GetChildren() or {}) do
            local marker = pt:FindFirstChild("LocationMarker")
            local owned = pt:GetAttribute("OwnedBy") or (marker and marker:GetAttribute("OwnedBy"))
            local att = pt:FindFirstChild("Attachment", true)
            local prompt = att and att:FindFirstChildOfClass("ProximityPrompt")
            if owned == side and prompt then
                local enemy = pt:GetAttribute("SupplyEnemyPresent") or (marker and marker:GetAttribute("SupplyEnemyPresent"))
                out[#out + 1] = { point = pt, prompt = prompt, pos = att.WorldPosition, enemy = enemy == true }
            end
        end
    end
    return out
end

-- walks the commander to walker.target with PathfindingService waypoints (normal walking, no teleport: the server
-- validates movement). Falls back to a straight MoveTo when no path is found. Path is recomputed every 3 s or when stuck.
local PFS = game:GetService("PathfindingService")
local walker = { target = nil, points = nil, i = 0, builtAt = 0, builtFor = nil, lastPos = nil, stuckSince = nil }
local function buildPath(from, to)
    local path = PFS:CreatePath({ AgentRadius = 2.5, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 6 })
    local ok = pcall(path.ComputeAsync, path, from, to)
    if ok and path.Status == Enum.PathStatus.Success then return path:GetWaypoints() end
    return nil
end
task.spawn(function()
    while running do
        local char = lp.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local r = root(char)
        local target = walker.target
        if target and hum and r and hum.Health > 0 and not blocked() and inGame() then
            local stuck = false
            if walker.lastPos and (r.Position - walker.lastPos).Magnitude < 0.4 then
                walker.stuckSince = walker.stuckSince or os.clock()
                stuck = os.clock() - walker.stuckSince > 1.5
            else
                walker.stuckSince = nil
            end
            walker.lastPos = r.Position
            if not walker.points or walker.builtFor ~= target or os.clock() - walker.builtAt > 3 or stuck then
                walker.points, walker.i, walker.builtAt, walker.builtFor, walker.stuckSince = buildPath(r.Position, target), 2, os.clock(), target, nil
                if stuck then hum.Jump = true end
            end
            local pts = walker.points
            if pts and pts[walker.i] then
                local wp = pts[walker.i]
                if Vector3.new(wp.Position.X - r.Position.X, 0, wp.Position.Z - r.Position.Z).Magnitude < 3.5 then
                    walker.i += 1
                    wp = pts[walker.i] or wp
                end
                if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
                hum:MoveTo(wp.Position)
            else
                hum:MoveTo(target)
            end
        elseif walker.points then
            walker.points, walker.builtFor, walker.lastPos, walker.stuckSince = nil, nil, nil, nil
        end
        task.wait(0.15)
    end
end)

local function doResupply()
    if attr("CurrentUnitWiped") ~= true or attr("IsDead") == true or attr("AwaitingRespawnUnit") == true then walker.target = nil; return end
    if os.clock() - spawnState.lastTry < 4 then return end
    local r = root(lp.Character)
    if not r then return end
    local best, bd = nil, math.huge
    for _, c in ipairs(friendlyCamps()) do
        local d = (c.pos - r.Position).Magnitude
        if not c.enemy and d < bd then best, bd = c, d end
    end
    if not best then walker.target = nil; status.battle = "army wiped · no friendly camp free of enemies"; return end
    if bd > best.prompt.MaxActivationDistance - 1 then
        local walking = CFG.walkToCamp or CFG.campLoop
        status.battle = ("army wiped · nearest camp %dm away%s"):format(math.floor(bd), walking and " (walking)" or "")
        if walking then walker.target = best.pos end
        return
    end
    walker.target = nil
    local cd = (tonumber(attr("SupplyPointCooldownEndsAt")) or 0) - now()
    if cd > 0 then status.battle = ("army wiped · at camp · supply cooldown %ds"):format(math.ceil(cd)); return end
    local slot, u = pickSlot()
    if not slot then status.battle = "army wiped · every allowed unit on cooldown"; return end
    spawnState.lastTry, spawnState.supply = os.clock(), nil
    fireproximityprompt(best.prompt)
    for _ = 1, 20 do if spawnState.supply == "Opened" or spawnState.supply == "AccessDenied" then break end task.wait(0.1) end
    if spawnState.supply ~= "Opened" then status.battle = "supply prompt: " .. tostring(spawnState.supply or "no reply"); return end
    fire("SupplyPointRequest", "Begin", slot)
    for _ = 1, 150 do -- channel time is server-set ("Started", duration)
        if spawnState.supply == "Completed" or spawnState.supply == "Cancelled" then break end
        task.wait(0.1)
    end
    if spawnState.supply ~= "Completed" then pcall(fire, "SupplyPointRequest", "Close") end
    stats.spawns += 1
    status.battle = ("resupplied slot %d: %s → %s"):format(slot, tostring(u.TroopId), tostring(spawnState.supply))
    log(status.battle)
end

task.spawn(function()
    while running do
        if not blocked() then
            if CFG.autoJoin and inLobby() then guard("join", doJoin) end
            if inGame() then
                if CFG.autoRespawn or CFG.campLoop then guard("respawn", doDeathRespawn) end
                if CFG.autoResupply or CFG.campLoop then guard("resupply", doResupply) else walker.target = nil end
            end
        end
        if blocked() or not inGame() then walker.target = nil end
        if inGame() then
            status.match = ("in match · %s · army %s/%s · round %s"):format(lp.Team and lp.Team.Name or "?", tostring(attr("CurrentUnitAliveCount") or "?"),
                tostring(attr("CurrentUnitMaxCount") or "?"), tostring(workspace:GetAttribute("RoundState")))
        end
        task.wait(0.5)
    end
end)

-- ============================== battlefield model ==============================
local function norm(s) s = tostring(s or ""); return (s:gsub("s$", "")) end
local function myTeam() return lp.Team and norm(lp.Team.Name) or nil end
-- workspace.Troops/<folder>: player armies are named by UserId (no Team attr on the folder); AI armies are
-- AI_<Team>_<n>_<id> with AIControlled=true, Team, TroopId. Every logical troop model carries Team too.
local function armyTeam(folder)
    local t = folder:GetAttribute("Team")
    if not t then
        local p = Players:GetPlayerByUserId(tonumber(folder.Name) or 0)
        t = p and p.Team and p.Team.Name
    end
    if not t then
        local m = folder:FindFirstChildWhichIsA("Model")
        t = m and m:GetAttribute("Team")
    end
    return t and norm(t) or nil
end
local function isAIArmy(folder) return folder:GetAttribute("AIControlled") == true or folder.Name:sub(1, 3) == "AI_" end
local function isEnemyArmy(folder)
    local mine = myTeam()
    if folder.Name == tostring(lp.UserId) then return false end
    local t = armyTeam(folder)
    return mine ~= nil and t ~= nil and t ~= mine
end
local function isEnemyPlayer(p)
    return p ~= lp and p.Team ~= nil and lp.Team ~= nil and p.Team ~= lp.Team
end
-- logical troops (server's Troop_NN) that are alive; the client's Troop_NN_Visual clones are skipped
local function troopsOf(folder)
    local out = {}
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") and m.Name:sub(-7) ~= "_Visual" and (tonumber(m:GetAttribute("MotionHealth")) or 1) > 0 then
            out[#out + 1] = m
        end
    end
    return out
end
-- where a troop is drawn: its visual clone's root (TroopVisualProxyClient keeps the root even when it strips far
-- parts), else the logical root
local function troopPart(m)
    local vp = m:FindFirstChild("VisualProxy")
    local v = vp and vp.Value
    return (v and v.Parent and root(v)) or root(m)
end
local function armyCenter(troops)
    local sum, n = Vector3.zero, 0
    for _, m in ipairs(troops) do
        local p = troopPart(m)
        if p then sum += p.Position; n += 1 end
    end
    return n > 0 and sum / n or nil, n
end
local function myArmy() -- same lookup as TroopHudClient._getOwnedTroopFolder
    local tf = workspace:FindFirstChild("Troops")
    for _, f in ipairs(tf and tf:GetChildren() or {}) do
        if f.Name == tostring(lp.UserId) and f:GetAttribute("DetachedRetreat") ~= true then return f end
    end
end
local function nearestEnemyArmy(pos, maxDist)
    local best, bd, bf = nil, maxDist, nil
    local tf = workspace:FindFirstChild("Troops")
    for _, f in ipairs(tf and tf:GetChildren() or {}) do
        if isEnemyArmy(f) then
            local c = armyCenter(troopsOf(f))
            if c then
                local d = Vector3.new(c.X - pos.X, 0, c.Z - pos.Z).Magnitude
                if d < bd then best, bd, bf = c, d, f end
            end
        end
    end
    return best, bd, bf
end
local function groundAt(pos)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local skip = {}
    for _, n in ipairs({ "Troops", "Formations", "Mounts", "ClientArrows" }) do skip[#skip + 1] = workspace:FindFirstChild(n) end
    for _, p in ipairs(Players:GetPlayers()) do skip[#skip + 1] = p.Character end
    rp.FilterDescendantsInstances = skip
    local hit = workspace:Raycast(pos + Vector3.new(0, 25, 0), Vector3.new(0, -250, 0), rp)
    return hit and hit.Position or pos
end

-- ============================== army actions ==============================
-- Copied from TroopHudClient:
--   Hold/Follow/Attack : TroopStateRequest(state)                       cooldowns 0.1 / 0.25 / 0.25 s
--   Formation1..3      : TroopStateRequest("FormationN") (the client's fallback when it has no placement preview)
--   Rush               : RushRequest(flatDirection.Unit, groundEndPosition), max 300 studs, cooldown = troop RushCooldown;
--                        only when the troop's RushState ~= false
--   Aim volley (ranged, troop AimState == true): AimVolleyState(true, targetPos, 9); for 10 s each troop that stands
--                        still fires AimArrowFire(troop, AimAttackTick, origin, apex, landing, flightTime) every
--                        AttackInterval, landings scattered within 9 studs; then AimVolleyState(false). Cooldown 10 s.
-- The game refuses commands while CanCommandTroops ~= true or in a cannon/catapult. TroopControllerInputActive is
-- ignored on purpose: it's client-only, shared by the desktop + mobile HUD copies, and measured stuck at true while
-- idle (2026-09-29). The player's own picking is covered by the manual-key pause instead.
local act = { rushAt = 0, volleyAt = 0, volleying = false }
local function canCommand()
    return inGame() and attr("CanCommandTroops") == true and attr("InCannon") ~= true and attr("CatapultTargeting") ~= true
end
local function sendState(s)
    if not canCommand() then status.army = "can't command troops right now"; return end
    fire("TroopStateRequest", s)
    status.army = "order: " .. s
end

local function doRush(maxDist)
    if not canCommand() then return false, "can't command troops right now" end
    if os.clock() < act.rushAt then return false, ("rush cooldown %.0fs"):format(act.rushAt - os.clock()) end
    local army = myArmy()
    local troops = army and troopsOf(army) or {}
    local rep = troops[1]
    if not rep then return false, "no army" end
    if rep:GetAttribute("RushState") == false then return false, rep:GetAttribute("TroopId") .. " can't rush" end
    local from = armyCenter(troops)
    local to, d, f = nearestEnemyArmy(from, maxDist)
    if not to then return false, ("no enemy army within %d studs"):format(maxDist) end
    local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
    if flat.Magnitude < 2 then return false, "already on top of it" end
    local dir = flat.Unit
    if flat.Magnitude > 300 then to = from + dir * 300 end
    fire("RushRequest", dir, groundAt(to))
    act.rushAt = os.clock() + (tonumber(rep:GetAttribute("RushCooldown")) or 10) + 0.25
    local who = isAIArmy(f) and "AI" or (Players:GetPlayerByUserId(tonumber(f.Name) or 0) or f).Name
    return true, ("rushed %s's %s at %dm"):format(who, tostring(f:GetAttribute("TroopId") or "?"), math.floor(d))
end

local function fireArrow(m, pos, target) -- TroopHudClient._fireAimArrow
    local a, r = math.random() * 2 * math.pi, math.sqrt(math.random()) * 9
    local land = target + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
    local rp = m.PrimaryPart or m:FindFirstChild("HumanoidRootPart")
    local origin = pos + (rp and rp.CFrame.LookVector or Vector3.zero) * 2 + Vector3.new(0, tonumber(m:GetAttribute("ArrowOriginHeight")) or 2.5, 0)
    local dist = Vector3.new(land.X - origin.X, 0, land.Z - origin.Z).Magnitude
    local range = tonumber(m:GetAttribute("Range")) or 0
    local lo, hi = 0.12, 0.5
    if m:GetAttribute("RangedTrajectory") == "Line" then lo, hi = 0.03, 0.12 end
    local k = math.clamp(dist / (range > 0 and range or math.max(dist, 1)), 0, 1)
    local apex = origin:Lerp(land, 0.5) + Vector3.new(0, dist * (lo + (hi - lo) * k), 0)
    local tick = (m:GetAttribute("AimAttackTick") or 0) + 1
    m:SetAttribute("AimAttackTick", tick)
    fire("AimArrowFire", m, tick, origin, apex, land, dist / 150)
end

local function doVolley()
    if not canCommand() then return false, "can't command troops right now" end
    if act.volleying or os.clock() < act.volleyAt then return false, "volley cooldown" end
    local army = myArmy()
    local troops = army and troopsOf(army) or {}
    local rep = troops[1]
    if not rep then return false, "no army" end
    if rep:GetAttribute("AimState") ~= true then return false, tostring(rep:GetAttribute("TroopId")) .. " is not ranged" end
    local range = tonumber(rep:GetAttribute("Range")) or 0
    local from = armyCenter(troops)
    local to, d, f = nearestEnemyArmy(from, range > 0 and range or 150)
    if not to then return false, ("no enemy army within range (%d)"):format(range) end
    local target = groundAt(to)
    act.volleying, act.volleyAt = true, os.clock() + 10.25
    fire("AimVolleyState", true, target, 9)
    task.spawn(function()
        local t0, nextShot, last, shots = os.clock(), {}, {}, 0
        while running and os.clock() - t0 < 10 and canCommand() do
            for _, m in ipairs(troopsOf(army)) do
                local p = m.PrimaryPart or m:FindFirstChild("HumanoidRootPart")
                if p then
                    local iv = tonumber(m:GetAttribute("AttackInterval")) or 0
                    iv = iv > 0 and iv or 1.8
                    local still = last[m] and (p.Position - last[m]).Magnitude < 0.3
                    last[m] = p.Position
                    if not nextShot[m] then
                        nextShot[m] = os.clock() + math.random() * iv
                    elseif still and os.clock() >= nextShot[m] then
                        nextShot[m] = os.clock() + iv
                        fireArrow(m, p.Position, target)
                        shots += 1
                    end
                end
            end
            task.wait(0.1)
        end
        pcall(fire, "AimVolleyState", false)
        act.volleying = false
        log(("volley done: %d arrows"):format(shots))
    end)
    return true, ("volley on %s at %dm"):format(tostring(f:GetAttribute("TroopId") or "?"), math.floor(d))
end
local function runAction(name, f, ...)
    local ok, ok2, msg = pcall(f, ...)
    status.army = ok and tostring(msg) or ("error: " .. tostring(ok2))
    if ok and ok2 then log(msg) end
    return ok and ok2
end

task.spawn(function()
    local lastKeep = 0
    while running do
        if not blocked() and inGame() and os.clock() - lastManual > CFG.manualPause then
            if CFG.autoVolley then runAction("volley", doVolley) end
            if CFG.autoRush and not act.volleying then runAction("rush", doRush, CFG.rushRange) end
            -- keeping an order would cancel a rush / volley in flight, so it waits for them
            if CFG.keepState and canCommand() and not act.volleying and os.clock() > act.rushAt - 7
                and os.clock() - lastKeep >= math.max(CFG.keepStateEvery, 3) then
                lastKeep = os.clock()
                guard("state", fire, "TroopStateRequest", CFG.keepStateName)
            end
        end
        task.wait(0.5)
    end
end)

-- ============================== commander combat ==============================
local function nearestEnemy(pos, range)
    local best, bd = nil, range
    if CFG.attackPlayers then
        for _, p in ipairs(Players:GetPlayers()) do
            local c = p.Character
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            local r = root(c)
            if isEnemyPlayer(p) and r and hum and hum.Health > 0 then
                local d = (r.Position - pos).Magnitude
                if d < bd then best, bd = r, d end
            end
        end
    end
    if CFG.attackTroops then
        local tf = workspace:FindFirstChild("Troops")
        for _, f in ipairs(tf and tf:GetChildren() or {}) do
            if isEnemyArmy(f) then
                for _, m in ipairs(f:GetChildren()) do
                    if m:IsA("Model") then
                        local ok, pv = pcall(m.GetPivot, m)
                        if ok then
                            local d = (pv.Position - pos).Magnitude
                            if d < bd then best, bd = m, d end
                        end
                    end
                end
            end
        end
    end
    return best, bd
end

local lastAttack, lastHeal = 0, 0
task.spawn(function()
    while running do
        local char = lp.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local r = root(char)
        if not blocked() and inGame() and hum and r and hum.Health > 0 then
            if CFG.autoHeal and hum.Health / math.max(hum.MaxHealth, 1) * 100 < CFG.healBelow
                and attr("IsHealing") ~= true and (tonumber(attr("HealCooldownEndsAt")) or 0) <= now()
                and os.clock() - lastHeal > 3 then -- IsHealing / HealCooldownEndsAt replicate late: 291 heals in 2 s without this (log 2026-09-28)
                lastHeal = os.clock()
                guard("heal", fire, "PlayerCombatRequest", "Heal")
                stats.heals += 1
                log(("heal at %d%%"):format(math.floor(hum.Health / hum.MaxHealth * 100)))
            end
            if CFG.autoAttack and attr("CanUseCombat") == true and attr("IsRolling") ~= true and attr("IsHealing") ~= true then
                local mounted = attr("MountState") == "Mounted"
                local interval = tonumber(attr(mounted and "MountedAttackInterval" or "AttackInterval")) or 0.8
                if os.clock() - lastAttack >= interval + 0.05 then
                    local target, d = nearestEnemy(r.Position, CFG.attackRange)
                    if target then
                        if CFG.faceTarget then
                            local tp = typeof(target) == "Instance" and (target:IsA("BasePart") and target.Position or target:GetPivot().Position)
                            if tp then r.CFrame = CFrame.lookAt(r.Position, Vector3.new(tp.X, r.Position.Y, tp.Z)) end
                        end
                        lastAttack = os.clock()
                        guard("attack", fire, "PlayerCombatRequest", "Attack")
                        stats.attacks += 1
                        status.combat = ("attacking %s at %.1f studs"):format(target.Parent and target.Parent.Name or "?", d)
                    else
                        status.combat = "no enemy in range"
                    end
                end
            end
        end
        task.wait(0.1)
    end
end)

-- ============================== ESP ==============================
-- Why the old ESP flickered: the engine draws at most 31 Highlights and the game spends them on hit flashes
-- (DamageIndicatorClient "HitHighlight"), and TroopVisualProxyClient strips far troops down to their root part,
-- so a Highlight on an army folder came and went. Now:
--   player : Highlight (few of them, always first) with white outline + solid fill, a light beacon above the head,
--            and a big "★ Name [Class]" pill with HP and their army count
--   army   : one AlwaysOnTop cube per troop (HandleAdornments have no cap and only need the troop's root part),
--            one label pinned to a troop near the centre (sticky, so it doesn't jump between troops)
--   AI army: small spheres in their own colours, dim "AI" label — reads differently from a player's army
local espFolder = Instance.new("Folder")
espFolder.Name = "CAA_ESP"
pcall(function() espFolder.Parent = gethui and gethui() or game:GetService("CoreGui") end)
if not espFolder.Parent then espFolder.Parent = lp:WaitForChild("PlayerGui") end
local tags, hls, dots, beacons, anchors = {}, {}, {}, {}, {}
local STYLE = {
    player = { font = Enum.Font.GothamBlack, size = 15, w = 240, h = 38, offset = 3.5, bg = 0.3, tt = 0 },
    army   = { font = Enum.Font.GothamBold, size = 12, w = 260, h = 16, offset = 4, bg = 1, tt = 0 },
    ai     = { font = Enum.Font.Gotham, size = 11, w = 220, h = 14, offset = 4, bg = 1, tt = 0.3 },
}
local function tag(key, adornee, text, color, st)
    local b = tags[key]
    if not b then
        b = Instance.new("BillboardGui")
        b.AlwaysOnTop = true
        b.LightInfluence = 0
        local l = Instance.new("TextLabel")
        l.Name = "L"
        l.Size = UDim2.fromScale(1, 1)
        l.BorderSizePixel = 0
        l.BackgroundColor3 = Color3.new(0, 0, 0)
        l.TextStrokeTransparency = 0.35
        l.Parent = b
        Instance.new("UICorner", l).CornerRadius = UDim.new(0, 6)
        b.Parent = espFolder
        tags[key] = b
    end
    b.Size = UDim2.fromOffset(st.w, st.h)
    b.StudsOffset = Vector3.new(0, st.offset, 0)
    if b.Adornee ~= adornee then b.Adornee = adornee end
    b.L.Font, b.L.TextSize, b.L.BackgroundTransparency, b.L.TextTransparency = st.font, st.size, st.bg, st.tt
    b.L.Text = text
    b.L.TextColor3 = color
end
local function hl(key, adornee, color)
    local h = hls[key]
    if not h then
        h = Instance.new("Highlight")
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        h.FillTransparency, h.OutlineTransparency = 0.45, 0
        h.OutlineColor = Color3.new(1, 1, 1)
        h.Parent = espFolder
        hls[key] = h
    end
    if h.Adornee ~= adornee then h.Adornee = adornee end
    h.FillColor = color
end
local function beacon(key, part, color)
    local a = beacons[key]
    if not a then
        a = Instance.new("BoxHandleAdornment")
        a.AlwaysOnTop, a.ZIndex, a.Transparency = true, 2, 0.35
        a.Size, a.CFrame = Vector3.new(0.5, 40, 0.5), CFrame.new(0, 24, 0)
        a.Parent = espFolder
        beacons[key] = a
    end
    if a.Adornee ~= part then a.Adornee = part end
    a.Color3 = color
end
local function dot(m, part, color, ai)
    local a = dots[m]
    local cls = ai and "SphereHandleAdornment" or "BoxHandleAdornment"
    if a and a.ClassName ~= cls then a:Destroy(); a = nil end
    if not a then
        a = Instance.new(cls)
        a.AlwaysOnTop, a.ZIndex = true, 1
        if ai then a.Radius, a.Transparency = 0.6, 0.35 else a.Size, a.Transparency = Vector3.new(1.4, 1.4, 1.4), 0.15 end
        a.Parent = espFolder
        dots[m] = a
    end
    if a.Adornee ~= part then a.Adornee = part end
    if a.Color3 ~= color then a.Color3 = color end
end

-- side of a player / army: "enemy", "team", or nil (own, lobby, unknown team)
local function playerSide(p)
    if p == lp or not p.Team or not lp.Team then return nil end
    return p.Team == lp.Team and "team" or "enemy"
end
local function armySide(f)
    local mine = myTeam()
    if f.Name == tostring(lp.UserId) or not mine then return nil end
    local t = armyTeam(f)
    if not t then return nil end
    return t == mine and "team" or "enemy"
end
local function shown(side) return (side == "enemy" and CFG.espEnemies) or (side == "team" and CFG.espTeam) end
local function colorOf(side, kind) -- kind: "player" | "army" | "ai"
    local e = side == "enemy"
    if kind == "player" then return e and CFG.enemyColor or CFG.teamColor end
    if kind == "ai" then return e and CFG.enemyAIColor or CFG.teamAIColor end
    return e and CFG.enemyArmyColor or CFG.teamArmyColor
end

local function drawArmies(seen, pos)
    local tf = workspace:FindFirstChild("Troops")
    for _, f in ipairs(tf and tf:GetChildren() or {}) do
        local side, ai = armySide(f), isAIArmy(f)
        if shown(side) and (not ai or CFG.espAI) then
            local troops = troopsOf(f)
            local c, n = armyCenter(troops)
            if c and (c - pos).Magnitude <= CFG.espMaxDist then
                local col = colorOf(side, ai and "ai" or "army")
                local anchor, cand, best = anchors[f.Name], nil, math.huge
                if anchor and (not anchor.Parent or (anchor.Position - c).Magnitude > 25) then anchor = nil end
                for _, m in ipairs(troops) do
                    local part = troopPart(m)
                    if part then
                        seen[m] = true
                        dot(m, part, col, ai)
                        if not anchor and (part.Position - c).Magnitude < best then cand, best = part, (part.Position - c).Magnitude end
                    end
                end
                anchor = anchor or cand
                anchors[f.Name] = anchor
                if anchor then
                    seen["a" .. f.Name] = true
                    local troop, d = tostring(f:GetAttribute("TroopId") or "?"), math.floor((c - pos).Magnitude)
                    if ai then
                        tag("a" .. f.Name, anchor, ("AI · %s ×%d · %dm"):format(troop, n, d), col, STYLE.ai)
                    else
                        local owner = Players:GetPlayerByUserId(tonumber(f.Name) or 0)
                        tag("a" .. f.Name, anchor, ("⚑ %s · %s ×%d · %dm"):format(owner and owner.DisplayName or f.Name, troop, n, d), col, STYLE.army)
                    end
                end
            end
        end
    end
end

local function drawPlayers(seen, pos)
    local tf = workspace:FindFirstChild("Troops")
    for _, p in ipairs(Players:GetPlayers()) do
        local c = p.Character
        local pr, hum = root(c), c and c:FindFirstChildOfClass("Humanoid")
        local side = playerSide(p)
        if pr and hum and hum.Health > 0 and shown(side) then
            local d = (pr.Position - pos).Magnitude
            if d <= CFG.espMaxDist then
                local col = colorOf(side, "player")
                local k = "p" .. p.UserId
                seen[k] = true
                local army = tf and tf:FindFirstChild(tostring(p.UserId))
                local alive, max = p:GetAttribute("CurrentUnitAliveCount"), p:GetAttribute("CurrentUnitMaxCount")
                local armyTxt = army and (" · %s %s/%s"):format(tostring(army:GetAttribute("TroopId") or "?"), tostring(alive or "?"), tostring(max or "?")) or " · no army"
                tag(k, pr, ("★ %s [%s]\n%d HP%s · %dm"):format(p.DisplayName, tostring(p:GetAttribute("PlayerClass") or "?"),
                    math.floor(hum.Health), armyTxt, math.floor(d)), col, STYLE.player)
                hl(k, c, col)
                if CFG.espBeacon then beacon(k, pr, col) end
            end
        end
    end
end

task.spawn(function()
    while running do
        local seen = {}
        local r = root(lp.Character)
        local pos = r and r.Position or workspace.CurrentCamera.CFrame.Position
        guard("esp", function()
            if CFG.espPlayers then drawPlayers(seen, pos) end
            if CFG.espArmies then drawArmies(seen, pos) end
        end)
        for _, pool in ipairs({ hls, tags, dots, beacons }) do
            for k, v in pairs(pool) do
                if not seen[k] or (pool == beacons and not CFG.espBeacon) then v:Destroy(); pool[k] = nil end
            end
        end
        for k in pairs(anchors) do if not seen["a" .. k] then anchors[k] = nil end end
        task.wait(0.2)
    end
end)

-- ============================== spectate ==============================
-- Camera only (CameraSubject), nothing is sent to the server. Player = their Humanoid; army = the troop nearest the
-- army's centre (sticky, re-picked when it dies). Waits through respawns / resupplies instead of dropping the target.
local spec = { kind = nil, id = nil, filter = "All", ai = false, anchor = nil, prevType = nil, map = {} }
local function specWanted(side)
    return spec.filter == "All" or (spec.filter == "Enemies" and side == "enemy") or (spec.filter == "Teammates" and side == "team")
end
local function specTargets(kind)
    local out = {}
    if kind == "player" then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= lp and specWanted(playerSide(p)) then
                out[#out + 1] = { id = p.UserId, label = ("%s (@%s)%s"):format(p.DisplayName, p.Name, p.Team and (" · " .. p.Team.Name) or "") }
            end
        end
    else
        local tf = workspace:FindFirstChild("Troops")
        for _, f in ipairs(tf and tf:GetChildren() or {}) do
            local ai = isAIArmy(f)
            if f.Name ~= tostring(lp.UserId) and (spec.ai or not ai) and specWanted(armySide(f)) and #troopsOf(f) > 0 then
                local troop = tostring(f:GetAttribute("TroopId") or "?")
                local owner = not ai and Players:GetPlayerByUserId(tonumber(f.Name) or 0)
                out[#out + 1] = { id = f.Name, label = ai and ("AI · %s · %s #%s"):format(troop, tostring(armyTeam(f) or "?"), f.Name:match("^AI_[^_]+_(%d+)") or f.Name:sub(-4))
                    or ("⚑ %s · %s"):format(owner and owner.DisplayName or f.Name, troop) }
            end
        end
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end
local function ownSubject()
    local c = lp.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function specSubject()
    if spec.kind == "player" then
        local p = Players:GetPlayerByUserId(spec.id)
        if not p then return nil, "left the game" end
        local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then return nil, "dead, waiting for respawn" end
        return hum, ("%s · %d HP"):format(p.DisplayName, math.floor(hum.Health))
    end
    local tf = workspace:FindFirstChild("Troops")
    local f = tf and tf:FindFirstChild(spec.id)
    local troops = f and troopsOf(f) or {}
    local c, n = armyCenter(troops)
    if not c then spec.anchor = nil; return nil, "army gone, waiting for it to respawn" end
    local a = spec.anchor
    if not a or not a.Parent or (a.Position - c).Magnitude > 25 then
        local best = math.huge
        for _, m in ipairs(troops) do
            local part = troopPart(m)
            if part and (part.Position - c).Magnitude < best then a, best = part, (part.Position - c).Magnitude end
        end
        spec.anchor = a
    end
    return a, ("%s · %d troops"):format(tostring(f:GetAttribute("TroopId") or "?"), n)
end
local function startSpectate(kind, id)
    local cam = workspace.CurrentCamera
    if not spec.kind then spec.prevType = cam.CameraType end
    spec.kind, spec.id, spec.anchor = kind, id, nil
    log(("spectate %s %s"):format(kind, tostring(id)))
end
local function stopSpectate()
    if not spec.kind then return end
    spec.kind, spec.id, spec.anchor = nil, nil, nil
    local cam = workspace.CurrentCamera
    local own = ownSubject()
    if own then cam.CameraSubject = own end
    if spec.prevType then cam.CameraType = spec.prevType end
    status.spec = "not spectating"
end
local function cycleSpectate(kind, step)
    local list = specTargets(kind)
    if #list == 0 then status.spec = "no " .. kind .. "s match the filter"; return end
    local i = 0
    for j, t in ipairs(list) do if spec.kind == kind and t.id == spec.id then i = j end end
    if i == 0 then i = step > 0 and 1 or #list else i = ((i - 1 + step) % #list) + 1 end
    startSpectate(kind, list[i].id)
end
status.spec = "not spectating"
task.spawn(function()
    while running do
        if spec.kind then
            guard("spectate", function()
                local cam = workspace.CurrentCamera
                local subj, info = specSubject()
                if subj then
                    if cam.CameraType ~= Enum.CameraType.Custom then cam.CameraType = Enum.CameraType.Custom end
                    if cam.CameraSubject ~= subj then cam.CameraSubject = subj end
                end
                status.spec = ("spectating %s: %s"):format(spec.kind, tostring(info))
            end)
        end
        task.wait(0.25)
    end
end)

-- ============================== heartbeat ==============================
task.spawn(function()
    while running do
        task.wait(60)
        log(("HB state=%s gems=%s tickets=%s lvlxp=%s | sum %d asc %d evo %d q %d daily %d join %d spawn %d atk %d heal %d corr %d%s"):format(
            tostring(attr("MatchState")), tostring(attr("Gems")), tostring(attr("Tickets")), tostring(attr("PlayerTotalXP")),
            stats.summons, stats.ascends, stats.evolves, stats.quests, stats.dailies, stats.joins, stats.spawns, stats.attacks, stats.heals,
            stats.corrections, paused and (" PAUSED " .. tostring(pauseWhy)) or ""))
    end
end)

-- ============================== unload ==============================
local Library
local function unload()
    pcall(stopSpectate)
    running = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    pcall(function() espFolder:Destroy() end)
    getgenv().CAA_FARM = nil
end
getgenv().CAA_FARM = { unload = function() unload(); if Library then pcall(function() Library:Unload() end) end end }

-- ============================== Obsidian UI ==============================
local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local function obsidian(file, remotePath)
    local path = "BattleBotFarm/lib/" .. file -- shared local copy (a hung HttpGet once jammed the executor queue)
    local ok, src = pcall(function() return isfile(path) and readfile(path) end)
    return loadstring(ok and src or game:HttpGet(repo .. remotePath))()
end
Library            = obsidian("Library.lua", "Library.lua")
local ThemeManager = obsidian("ThemeManager.lua", "addons/ThemeManager.lua")
local SaveManager  = obsidian("SaveManager.lua", "addons/SaveManager.lua")

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
    end)(), Footer = "Command An Army · v1.3 · rewards · units · match · army · combat · ESP · spectate",
    Center = true, AutoShow = true, ToggleKeybind = Enum.KeyCode.RightControl,
})
local Tabs = {
    Rewards = Window:AddTab("Rewards", "gift"), Units = Window:AddTab("Units", "users"), Match = Window:AddTab("Match", "swords"),
    Battle = Window:AddTab("Battle", "flame"), Army = Window:AddTab("Army", "shield"), Combat = Window:AddTab("Combat", "crosshair"), ESP = Window:AddTab("ESP", "eye"), Spectate = Window:AddTab("Spectate", "video"),
    Status = Window:AddTab("Status", "activity"), Settings = Window:AddTab("Settings", "settings"),
}
local function set(k) return function(v) CFG[k] = v end end

-- Rewards
local RW = Tabs.Rewards:AddLeftGroupbox("Auto claim", "gift")
RW:AddLabel("Checks every 2 min while you're in the lobby. Same requests the reward menus send.", true)
RW:AddToggle("CA_Daily", { Text = "Daily reward", Default = CFG.daily, Callback = set("daily") })
RW:AddToggle("CA_Quests", { Text = "Daily + weekly quests", Default = CFG.quests, Callback = set("quests") })
RW:AddButton({ Text = "Check now", Func = function() task.spawn(function() guard("daily", doDaily); guard("quests", doQuests) end) end })
local RW2 = Tabs.Rewards:AddRightGroupbox("Codes & social", "ticket")
RW2:AddInput("CA_Code", { Text = "Code", Default = "", Placeholder = "code", Finished = false })
RW2:AddButton({ Text = "Redeem", Func = function()
    local code = Library.Options.CA_Code.Value
    if code == "" then return end
    task.spawn(function()
        local r, e = invoke("RedeemCode", code)
        local msg = type(r) == "table" and tostring(r.Message or r.Status or HS:JSONEncode(r)) or tostring(r or e)
        log("code " .. code .. " -> " .. msg); notify("Code: " .. msg)
    end)
end })
RW2:AddButton({ Text = "Claim like reward (after liking)", Func = function()
    task.spawn(function()
        local r = invoke("RewardRequest", "CheckLike")
        local msg = type(r) == "table" and tostring(r.Status or r.Message) or tostring(r)
        log("like reward -> " .. msg); notify("Like reward: " .. msg)
    end)
end })

-- Units
local SU = Tabs.Units:AddLeftGroupbox("Summon (Standard banner)", "sparkles")
SU:AddLabel("Lobby only, works from anywhere in the lobby. Stops by itself on InsufficientGems / InventoryFull.", true)
SU:AddToggle("CA_Summon", { Text = "Auto summon", Default = CFG.summon, Callback = set("summon") })
SU:AddDropdown("CA_SummonCount", { Text = "Per summon", Values = { "1", "10" }, Default = tostring(CFG.summonCount),
    Callback = function(v) CFG.summonCount = tonumber(v) end })
SU:AddSlider("CA_GemReserve", { Text = "Keep gems", Default = CFG.gemReserve, Min = 0, Max = 5000, Rounding = 0, Callback = set("gemReserve") })
local UP = Tabs.Units:AddRightGroupbox("Upgrades", "circle-arrow-up")
UP:AddToggle("CA_Ascend", { Text = "Auto ascend duplicates", Tooltip = "Merges two copies of the same troop at the same ascension level. Keeps the loadout copy, else the most mastered.",
    Default = CFG.ascend, Callback = set("ascend") })
UP:AddSlider("CA_AscMax", { Text = "Ascend up to level", Default = CFG.ascendMaxLevel, Min = 1, Max = 3, Rounding = 0, Callback = set("ascendMaxLevel") })
UP:AddToggle("CA_AscFav", { Text = "Never merge away favorites", Default = CFG.ascendKeepFav, Callback = set("ascendKeepFav") })
UP:AddToggle("CA_Evolve", { Text = "Auto evolve at mastery 20", Default = CFG.evolve, Callback = set("evolve") })
UP:AddToggle("CA_Equip", { Text = "Auto equip best (after inventory changes)", Default = CFG.equipBest, Callback = set("equipBest") })
UP:AddButton({ Text = "Equip best now", Func = function() guard("equip", fire, "UnitInventoryRequest", "EquipBest") end })
local unitsLabel = UP:AddLabel("-", true)
local summonLabel = SU:AddLabel("-", true)

-- Match
local MA = Tabs.Match:AddLeftGroupbox("Queue", "list-ordered")
MA:AddToggle("CA_Join", { Text = "Auto join matches", Default = CFG.autoJoin, Callback = set("autoJoin") })
MA:AddDropdown("CA_Team", { Text = "Team", Values = { "Smaller team", "Attackers", "Defenders" }, Default = CFG.team, Callback = set("team") })
MA:AddSlider("CA_JoinDelay", { Text = "Seconds between tries", Default = CFG.joinDelay, Min = 3, Max = 30, Rounding = 0, Callback = set("joinDelay") })
MA:AddToggle("CA_AntiIdle", { Text = "Anti idle kick", Default = CFG.antiIdle, Callback = set("antiIdle") })
MA:AddButton({ Text = "Toggle game AFK mode", Tooltip = "The game's own AFK button (AFKRequest)", Func = function() fire("AFKRequest", attr("AFK") ~= true) end })
local matchLabel = MA:AddLabel("-", true)

-- Battle
local BA = Tabs.Battle:AddLeftGroupbox("Auto respawn units", "refresh-cw")
BA:AddToggle("CA_CampLoop", { Text = "AUTO RESPAWN AT CAMP (all-in-one)",
    Tooltip = "Turns on everything below: instant respawn after your commander dies, and when your army is wiped, walks (pathfinding) to the nearest safe friendly camp and spawns your next unit there.",
    Default = CFG.campLoop, Callback = set("campLoop") })
BA:AddDivider()
BA:AddLabel("Or pick pieces:", true)
BA:AddLabel("Commander died: skips the 15 s death timer and picks your unit right away.", true)
BA:AddToggle("CA_Respawn", { Text = "Auto respawn after death", Default = CFG.autoRespawn, Callback = set("autoRespawn") })
BA:AddSlider("CA_SpawnDelay", { Text = "Wait before picking (s)", Default = CFG.spawnDelay, Min = 0, Max = 10, Rounding = 1, Callback = set("spawnDelay") })
BA:AddDivider()
BA:AddLabel("Army wiped but you're alive: at a friendly supply camp, opens it and starts your next unit.", true)
BA:AddToggle("CA_Resupply", { Text = "Auto resupply at camp", Default = CFG.autoResupply, Callback = set("autoResupply") })
BA:AddToggle("CA_WalkCamp", { Text = "Walk to nearest friendly camp", Tooltip = "Normal walking along a pathfinding route (goes around walls), no teleport.",
    Default = CFG.walkToCamp, Callback = set("walkToCamp") })
local BA2 = Tabs.Battle:AddRightGroupbox("Which unit", "user-check")
BA2:AddDropdown("CA_SpawnPriority", { Text = "Pick", Values = { "Strongest ready", "Slot order" }, Default = CFG.spawnPriority, Callback = set("spawnPriority") })
-- options come from your unlocked loadout slots and the unit in each; rebuilt when the loadout changes
local function slotOptions()
    local labels, filled = {}, {}
    for _, e in ipairs(loadoutSlots()) do
        labels[#labels + 1] = slotLabel(e)
        if e.unit then filled[#filled + 1] = slotLabel(e) end
    end
    return labels, filled
end
local _, filled0 = slotOptions()
local slotsLabel = BA2:AddLabel("-", true)
local preferDD = BA2:AddDropdown("CA_SpawnPreferred", { Text = "Prefer this unit (if ready)", Values = { "None", table.unpack(filled0) }, Default = "None",
    Callback = function(v) CFG.spawnPreferred = slotOf(v) or 0 end })
local allowDD
allowDD = BA2:AddDropdown("CA_SpawnAllowed", { Text = "Units it may spawn", Values = filled0, Multi = true, AllowNull = true,
    Tooltip = "Unticked units are never picked. Nothing ticked = all units allowed.",
    Callback = function(v)
        local any = next(v or {}) ~= nil
        CFG.spawnAllowed = {}
        for _, l in ipairs(allowDD and allowDD.Values or filled0) do
            local s = slotOf(l)
            if s and any then CFG.spawnAllowed[s] = v[l] == true end
        end
    end })
BA2:AddLabel("Strongest = stars, then ascension, then mastery. Units on cooldown are skipped.", true)
local battleLabel = BA2:AddLabel("-", true)

local lastSlotSig = nil
local function refreshSlotOptions()
    local labels, filled = slotOptions()
    local sig = table.concat(labels, "|")
    if sig == lastSlotSig then return end
    lastSlotSig = sig
    slotsLabel:SetText(#labels > 0 and ("%d slots unlocked:\n%s"):format(#labels, table.concat(labels, "\n")) or "loadout not loaded yet")
    -- keep the selections by slot number when a slot's unit changes
    local keepPref, keepAllowed = CFG.spawnPreferred, CFG.spawnAllowed
    preferDD:SetValues({ "None", table.unpack(filled) })
    local pref = "None"
    for _, l in ipairs(filled) do if slotOf(l) == keepPref then pref = l end end
    preferDD:SetValue(pref)
    allowDD:SetValues(filled)
    local sel, any = {}, false
    for _, l in ipairs(filled) do
        local s = slotOf(l)
        if keepAllowed[s] == true then sel[l] = true; any = true end
    end
    allowDD:SetValue(any and sel or {})
    CFG.spawnAllowed = keepAllowed
end

-- Army
local AR = Tabs.Army:AddLeftGroupbox("Orders", "flag")
AR:AddLabel("Same requests as the X / C / V keys and the 1 / 2 / 3 formation buttons.", true)
for _, s in ipairs({ "Hold", "Follow", "Attack" }) do
    AR:AddButton({ Text = s, Func = function() guard("state", sendState, s) end })
end
AR:AddDivider()
AR:AddLabel("Hold in formation (shapes depend on the troop: square / line / circle...)", true)
for n = 1, 3 do
    AR:AddButton({ Text = "Formation " .. n, Func = function() guard("state", sendState, "Formation" .. n) end })
end
local armyLabel = AR:AddLabel("-", true)

local AR3 = Tabs.Army:AddRightGroupbox("Rush & volley", "zap")
AR3:AddLabel("Rush charges your army at the nearest enemy army (cooldown ~10 s). Volley makes ranged troops shoot at it for 10 s (they must stand still).", true)
AR3:AddButton({ Text = "Rush nearest enemy army", Func = function() task.spawn(runAction, "rush", doRush, CFG.rushRange) end })
AR3:AddButton({ Text = "Volley nearest enemy army", Func = function() task.spawn(runAction, "volley", doVolley) end })
AR3:AddSlider("CA_RushRange", { Text = "Rush reach (studs)", Default = CFG.rushRange, Min = 30, Max = 300, Rounding = 0, Callback = set("rushRange") })
AR3:AddToggle("CA_AutoRush", { Text = "Auto rush when an enemy army is in reach", Default = CFG.autoRush, Callback = set("autoRush") })
AR3:AddToggle("CA_AutoVolley", { Text = "Auto volley (ranged armies)", Default = CFG.autoVolley, Callback = set("autoVolley") })

local AR2 = Tabs.Army:AddRightGroupbox("Keep an order", "lock")
AR2:AddToggle("CA_KeepState", { Text = "Re-send order during matches", Tooltip = "Waits for a rush / volley to finish first.", Default = CFG.keepState, Callback = set("keepState") })
AR2:AddDropdown("CA_KeepStateName", { Text = "Order", Values = { "Attack", "Follow", "Hold", "Formation1", "Formation2", "Formation3" }, Default = CFG.keepStateName, Callback = set("keepStateName") })
AR2:AddSlider("CA_KeepEvery", { Text = "Every (s)", Default = CFG.keepStateEvery, Min = 3, Max = 30, Rounding = 0, Callback = set("keepStateEvery") })
AR2:AddSlider("CA_ManualPause", { Text = "Pause autos after my own X/C/V/B/1-3 (s)", Default = CFG.manualPause, Min = 0, Max = 120, Rounding = 0, Callback = set("manualPause") })

-- Combat
local CO = Tabs.Combat:AddLeftGroupbox("Commander", "crown")
CO:AddLabel("Swings only when an enemy is in reach, at the class's own attack speed. The server decides what gets hit.", true)
CO:AddToggle("CA_Attack", { Text = "Auto attack", Default = CFG.autoAttack, Callback = set("autoAttack") })
CO:AddSlider("CA_Range", { Text = "Reach (studs)", Default = CFG.attackRange, Min = 4, Max = 14, Rounding = 1, Callback = set("attackRange") })
CO:AddToggle("CA_AtkPlayers", { Text = "Target players", Default = CFG.attackPlayers, Callback = set("attackPlayers") })
CO:AddToggle("CA_AtkTroops", { Text = "Target troops", Default = CFG.attackTroops, Callback = set("attackTroops") })
CO:AddToggle("CA_Face", { Text = "Turn to face target", Default = CFG.faceTarget, Callback = set("faceTarget") })
local CO2 = Tabs.Combat:AddRightGroupbox("Heal", "heart-pulse")
CO2:AddToggle("CA_Heal", { Text = "Auto heal", Default = CFG.autoHeal, Callback = set("autoHeal") })
CO2:AddSlider("CA_HealBelow", { Text = "Heal below HP %", Default = CFG.healBelow, Min = 10, Max = 90, Rounding = 0, Callback = set("healBelow") })
local combatLabel = CO2:AddLabel("-", true)

-- ESP
local ES = Tabs.ESP:AddLeftGroupbox("ESP", "eye")
ES:AddToggle("CA_EspPlayers", { Text = "Players: glow + ★ label + army count", Default = CFG.espPlayers, Callback = set("espPlayers") })
ES:AddToggle("CA_EspBeacon", { Text = "Player beacon (light pillar)", Default = CFG.espBeacon, Callback = set("espBeacon") })
ES:AddToggle("CA_EspArmies", { Text = "Player armies: cube per troop + ⚑ owner", Default = CFG.espArmies, Callback = set("espArmies") })
ES:AddToggle("CA_EspAI", { Text = "AI armies: sphere per troop + AI label", Default = CFG.espAI, Callback = set("espAI") })
ES:AddToggle("CA_EspEnemies", { Text = "Show enemies", Default = CFG.espEnemies, Callback = set("espEnemies") })
ES:AddToggle("CA_EspTeam", { Text = "Show teammates", Default = CFG.espTeam, Callback = set("espTeam") })
ES:AddSlider("CA_EspDist", { Text = "Max distance", Default = CFG.espMaxDist, Min = 100, Max = 3000, Rounding = 0, Callback = set("espMaxDist") })

local EC = Tabs.ESP:AddRightGroupbox("Colors", "palette")
EC:AddLabel("Players glow with a white outline. Player armies = cubes, AI armies = small dim spheres.", true)
EC:AddLabel("Enemy player"):AddColorPicker("CA_EnemyColor", { Title = "Enemy player", Default = CFG.enemyColor, Callback = set("enemyColor") })
EC:AddLabel("Enemy player army"):AddColorPicker("CA_EnemyArmyColor", { Title = "Enemy player army", Default = CFG.enemyArmyColor, Callback = set("enemyArmyColor") })
EC:AddLabel("Enemy AI army"):AddColorPicker("CA_EnemyAIColor", { Title = "Enemy AI army", Default = CFG.enemyAIColor, Callback = set("enemyAIColor") })
EC:AddLabel("Teammate player"):AddColorPicker("CA_TeamColor", { Title = "Teammate player", Default = CFG.teamColor, Callback = set("teamColor") })
EC:AddLabel("Teammate player army"):AddColorPicker("CA_TeamArmyColor", { Title = "Teammate player army", Default = CFG.teamArmyColor, Callback = set("teamArmyColor") })
EC:AddLabel("Teammate AI army"):AddColorPicker("CA_TeamAIColor", { Title = "Teammate AI army", Default = CFG.teamAIColor, Callback = set("teamAIColor") })

-- Spectate
local SP = Tabs.Spectate:AddLeftGroupbox("Spectate", "video")
SP:AddLabel("Moves only your camera. Stays on the target through deaths and respawns.", true)
SP:AddDropdown("CA_SpecFilter", { Text = "Show", Values = { "All", "Enemies", "Teammates" }, Default = spec.filter,
    Callback = function(v) spec.filter = v end })
SP:AddToggle("CA_SpecAI", { Text = "Include AI armies", Default = spec.ai, Callback = function(v) spec.ai = v end })
local specPlayerDD = SP:AddDropdown("CA_SpecPlayer", { Text = "Player", Values = {}, AllowNull = true,
    Callback = function(v) local t = v and spec.map["p" .. v]; if t then startSpectate("player", t) end end })
local specArmyDD = SP:AddDropdown("CA_SpecArmy", { Text = "Army", Values = {}, AllowNull = true,
    Callback = function(v) local t = v and spec.map["a" .. v]; if t then startSpectate("army", t) end end })
SP:AddButton({ Text = "Stop spectating", Func = function() stopSpectate() end })
local specLabel = SP:AddLabel("-", true)

local SP2 = Tabs.Spectate:AddRightGroupbox("Quick cycle", "repeat")
SP2:AddButton({ Text = "◀ Previous player", Func = function() cycleSpectate("player", -1) end })
SP2:AddButton({ Text = "Next player ▶", Func = function() cycleSpectate("player", 1) end })
SP2:AddDivider()
SP2:AddButton({ Text = "◀ Previous army", Func = function() cycleSpectate("army", -1) end })
SP2:AddButton({ Text = "Next army ▶", Func = function() cycleSpectate("army", 1) end })

-- dropdown lists follow who / which armies are in the server; only rebuilt when the list itself changes
local specSig = {}
local function refreshSpecLists()
    for _, k in ipairs({ { "player", "p", specPlayerDD }, { "army", "a", specArmyDD } }) do
        local list, labels = specTargets(k[1]), {}
        for _, t in ipairs(list) do labels[#labels + 1] = t.label; spec.map[k[2] .. t.label] = t.id end
        local sig = table.concat(labels, "|")
        if sig ~= specSig[k[1]] then
            specSig[k[1]] = sig
            local keep = k[3].Value
            k[3]:SetValues(labels)
            if keep and not table.find(labels, keep) then k[3]:SetValue(nil) end
        end
    end
end

-- Status
local ST = Tabs.Status:AddLeftGroupbox("Status", "activity")
local statusLabel = ST:AddLabel("-", true)
local ST2 = Tabs.Status:AddRightGroupbox("Log (also CommandArmy/log.txt)", "scroll-text")
local logLabel = ST2:AddLabel("-", true)

-- Settings
local SA = Tabs.Settings:AddLeftGroupbox("Safety", "shield-alert")
SA:AddToggle("CA_PauseAC", { Text = "Pause if the game's anti-cheat gets enabled", Default = CFG.pauseOnAC, Callback = set("pauseOnAC") })
SA:AddToggle("CA_PauseStaff", { Text = "Pause while a high group rank player is here", Default = CFG.pauseOnStaff, Callback = set("pauseOnStaff") })
SA:AddSlider("CA_StaffRank", { Text = "Group rank counted as staff", Default = CFG.staffRank, Min = 1, Max = 255, Rounding = 0, Callback = set("staffRank") })
local safetyLabel = SA:AddLabel("-", true)
local Menu = Tabs.Settings:AddRightGroupbox("Menu", "menu")
Menu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })
Library:OnUnload(unload)
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "CA_SpecPlayer", "CA_SpecArmy" }) -- never start spectating from a saved config
SaveManager:SetFolder("CommandArmy")
ThemeManager:SetFolder("CommandArmy")
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:SetDefaultTheme({ BackgroundColor = "0c0a0b", MainColor = "161214", AccentColor = "e0233c", OutlineColor = "2a1d20", FontColor = "f2eded" }) -- CruelHub look
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:LoadAutoloadConfig()
notify = function(msg) Library:Notify(msg, 4) end

task.spawn(function()
    while running do
        pcall(function()
            summonLabel:SetText(status.summon)
            unitsLabel:SetText(status.units)
            matchLabel:SetText(("%s\nstate %s · round %s · map %s"):format(status.match, tostring(attr("MatchState")),
                tostring(workspace:GetAttribute("RoundState")), tostring(workspace:GetAttribute("ActiveMap"))))
            battleLabel:SetText(status.battle)
            pcall(refreshSlotOptions)
            pcall(refreshSpecLists)
            specLabel:SetText(status.spec)
            armyLabel:SetText(("%s\nrush %s · volley %s"):format(status.army, os.clock() < act.rushAt and ("%.0fs"):format(act.rushAt - os.clock()) or "ready",
                act.volleying and "firing" or (os.clock() < act.volleyAt and "cooldown" or "ready")))
            combatLabel:SetText(("%s\nattacks %d · heals %d"):format(status.combat, stats.attacks, stats.heals))
            safetyLabel:SetText(status.safety)
            statusLabel:SetText(("Gems %s · Tickets %s · XP %s\nWins %s · Kills %s · Luck %s\nSummoned %d · ascended %d · evolved %d\nQuests %d · dailies %d · joins %d · spawns %d\n%s"):format(
                fmt(attr("Gems")), fmt(attr("Tickets")), fmt(attr("PlayerTotalXP")), tostring(attr("LifetimeWins")), tostring(attr("LifetimeKills")),
                tostring(attr("LuckTier")), stats.summons, stats.ascends, stats.evolves, stats.quests, stats.dailies, stats.joins, stats.spawns, status.safety))
            logLabel:SetText(table.concat(logLines, "\n", 1, math.min(#logLines, 14)))
        end)
        task.wait(1)
    end
end)

log("loaded v1.3 in place " .. game.PlaceId)
Library:Notify("Command An Army v1 ready — RightCtrl toggles the UI. Everything starts off.", 5)
