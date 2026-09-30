--[[
    Pixel Conquest farm v1.9  (place 138110382920220, OpenFront.io port)
    UI: Obsidian. Config folder: PixelConquest. Log: PixelConquest/log.txt
    Server-authoritative game: every action is ConquestNet.Intent:FireServer({t=...}) exactly as the game's client sends it
    (decompiled ConquestClient / DiplomacyClient / LobbyClient, confirmed with the spy). Spec: pixel-conquest-spec.md
      Match : {t="spawn",tile} {t="attack",tile,ratio} {t="build",tile,kind} {t="nuke",tile,kind}
              {t="airstrike"|"railgun",from,tile} {t="reinforce"} {t="leave"} {t="ally"|"renew",id}
      Lobby : LobbyIntent("join","slotN",tag) ("reward")  Shop("passmoney",KEY)
    Map state is read from the game's own TileMap object (owner/terrain buffers, 880x550, idx = y*880+x).
    NEVER fired: ConquestCheats.* / ConquestSim.* (dev relays, honeypot), revive/topup/Shop "buy"/"pass" (Robux).
]]

if getgenv().PC_FARM then pcall(getgenv().PC_FARM.unload) end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer

local NetF = RS:WaitForChild("ConquestNet")
local Intent, LobbyIntent, Shop = NetF:WaitForChild("Intent"), NetF:WaitForChild("LobbyIntent"), NetF:WaitForChild("Shop")
local State, Lobby = NetF:WaitForChild("State"), NetF:WaitForChild("Lobby")
local Conquest = RS:WaitForChild("Conquest")
local Config = require(Conquest:WaitForChild("Config")) -- read-only table access (no game function calls on UI threads)
local Matchmaker = require(Conquest:WaitForChild("Matchmaker"))

local W, H = Config.MAP_W or 880, Config.MAP_H or 550
local N = W * H
local readu8, btest = buffer.readu8, bit32.btest
local MIN_DIST = (Config.STRUCTURE_MIN_DIST or 15) + 1

local KIND = { city = 1, port = 2, defense = 3, sam = 5, artillery = 18, airfield = 19, railgun = 21 }
local NUKE = { Atom = { kind = 13, cost = 750000, r = 30 }, Mega = { kind = 17, cost = Config.MEGA_NUKE_COST or 2500000, r = 60, pass = "MEGANUKE" },
    Scattershot = { kind = 20, cost = Config.SCATTERSHOT_COST or 3750000, r = 45, pass = "SCATTERSHOT" } }
local BUILD_PASS = { artillery = "ARTILLERY", airfield = "AIRSTRIKE", railgun = "RAILGUN" }
local PASS_PRICE = { MEGANUKE = 10000, BARRACKS = 20000, SCATTERSHOT = 20000, ARTILLERY = 25000, AIRSTRIKE = 100000, RAILGUN = 250000 }
local PASS_ORDER = { "MEGANUKE", "BARRACKS", "SCATTERSHOT", "ARTILLERY", "AIRSTRIKE", "RAILGUN" }

-- ============================== config ==============================
local CFG = {
    -- expand
    spawn = true, spawnCoast = false,
    expand = true, expandRatio = 0.25, bandLow = 0.40, bandHigh = 0.60, reclaim = true, reclaimMin = 0.15, reclaimRatio = 0.1,
    islands = true, islandMin = 0.45, islandMinLocked = 0.15, islandEvery = 15, islandMaxDist = 250, islandOnlyLocked = false,
    -- combat
    attack = false, attackRatio = 0.33, attackMin = 0.55, edge = 1.2, maxFronts = 3, hitBots = true, hitPlayers = true,
    counterCancel = true, counterPunish = true, keepHome = 0.35, keepCap = 0.1,
    lastStand = true, lastStandNuke = "Best owned", lastStandAlly = true,
    revenge = true, revengeRatio = 0.3, revengeMin = 0.5, revengeEdge = 0.6, revengeStronger = 1.3, grudgeSecs = 120,
    hitTraitors = true, finish = true, holdWhenHit = true, nukeCooldown = 45, nukeStronger = false,
    revengeNuke = true, revengeNukeKind = "Best owned", revengeMinLv = 1, nukeGrudgeSecs = 300, revengeOnce = true, revengeNukeStrikes = false,
    useFree = true,
    samAuto = true, samMode = "Prepare", samPrepMin = 6, samPrepCityLv = 20, samMaxLv = 5, samMinCityLv = 5, samMinValue = 20, samUpgrade = true, samPriority = true,
    -- build
    build = true, reserve = 0, saveForTop = false,
    b_city = true, b_port = true, b_defense = true, b_sam = false, b_artillery = true, b_airfield = true, b_railgun = false,
    max_city = 10, max_port = 3, max_defense = 4, max_sam = 2, max_artillery = 3, max_airfield = 1, max_railgun = 1,
    upgradeCities = true, cityMaxLv = 5, citySpread = 31,
    -- weapons
    nuke = false, nukeKind = "Best owned", nukeMinGold = 0, nukeSkipBots = true, avoidSam = true,
    airstrike = true, railgun = true, reinforce = true, reinforceBelow = 0.5,
    -- diplomacy
    accept = true, renew = true, request = false, requestRatio = 1.5, blockUnally = true, blacklist = "",
    -- lobby / loop
    queue = false, queueSizes = {}, skipSpecial = false, leave = true, leaveDelay = 4, claimReward = true,
    buyPasses = false, passReserve = 0, reinject = true,
    -- safety
    blockPrompts = true, gap = 0.12, scanEvery = 2, useHudRatio = true,
    camUnlock = true, camMargin = 0.6, camZoom = 2,
}

-- ============================== camera (game's Camera2D module; the client calls it through the table) ==============================
local Cam = require(Conquest:WaitForChild("Camera2D"))
local camOrig = { clamp = Cam.clamp, settle = Cam.settle, min = Config.MIN_ZOOM, max = Config.MAX_ZOOM }
local function applyCamera()
    if CFG.camUnlock then
        -- the game's clamp keeps the map edge on screen (extra room only while "soft"); allow camMargin x the viewport on every side
        Cam.clamp = function(c)
            local mx, my = (c.viewW or 0) * CFG.camMargin, (c.viewH or 0) * CFG.camMargin
            local ex = c.viewW - W * c.zoom
            c.x = math.clamp(c.x, math.min(0, ex) - mx, math.max(0, ex) + mx)
            local top = c.padTop or 0
            local ey = c.viewH - (c.padBottom or 0) - H * c.zoom
            c.y = math.clamp(c.y, math.min(top, ey) - my, math.max(top, ey) + my)
        end
        Cam.settle = function(c) c.settling = false end -- no spring back to the tight bounds
        Config.MIN_ZOOM = camOrig.min / CFG.camZoom
        Config.MAX_ZOOM = camOrig.max * CFG.camZoom
    else
        Cam.clamp, Cam.settle, Config.MIN_ZOOM, Config.MAX_ZOOM = camOrig.clamp, camOrig.settle, camOrig.min, camOrig.max
    end
end

-- ============================== state / log ==============================
local S = { myId = nil, phase = nil, players = {}, byId = {}, names = {}, me = nil, fronts = nil, gold = 0, diplo = nil,
    structs = {}, grudge = {}, nukeGrudge = {}, nukedAt = -1e9, nukeSeenAt = -1e9, pendingSam = {}, holes = {}, holeSent = {}, islandTargets = {}, money = nil, ended = false, lastState = os.clock(), spawnSent = 0, badTile = {}, lastDenied = "-",
    board = nil, lobbyMoney = nil, rewardClaimed = nil, scan = nil, readyAt = {}, leaveAt = nil }
local reqAt, counterAt = {}, {}
local stats = { sent = 0, attacks = 0, builds = 0, nukes = 0, strikes = 0, allies = 0, joins = 0, denied = 0 }
local status = { expand = "-", combat = "-", build = "-", weapons = "-", diplo = "-", lobby = "-" }
local running, conns, logLines, Library, notify = true, {}, {}, nil, function() end

if not isfolder("PixelConquest") then makefolder("PixelConquest") end
if not isfile("PixelConquest/log.txt") or #readfile("PixelConquest/log.txt") > 200000 then pcall(writefile, "PixelConquest/log.txt", "") end -- keep history across reloads
local function log(msg)
    local line = os.date("%H:%M:%S ") .. msg
    table.insert(logLines, 1, line)
    if #logLines > 40 then table.remove(logLines) end
    pcall(appendfile, "PixelConquest/log.txt", line .. "\n")
end
local function fmt(n)
    n = tonumber(n) or 0
    if n >= 1e6 then return ("%.2fM"):format(n / 1e6) elseif n >= 1e3 then return ("%.1fK"):format(n / 1e3) end
    return tostring(math.floor(n))
end
-- every pass (Products.lua). Money passes show up as the ConquestPass_<KEY> attribute; Robux-only ones
-- (VIP, FAST_RELOAD, HOST, ADVANCED) are checked through the pass API once at load.
local PASSES = {
    { key = "MEGANUKE", id = 1989902339, money = 10000, use = "Mega nuke (4x blast) in auto / revenge / last stand" },
    { key = "SCATTERSHOT", id = 1999838282, money = 20000, use = "Scattershot nuke (+4-6 warheads)" },
    { key = "BARRACKS", id = 1990256322, money = 20000, use = "Auto reinforce + last stand reinforce" },
    { key = "ARTILLERY", id = 1987550354, money = 25000, use = "Auto artillery behind the longest enemy border" },
    { key = "AIRSTRIKE", id = 1988684354, money = 100000, use = "Auto airfield + airstrikes on the best target in range" },
    { key = "RAILGUN", id = 1998602304, money = 250000, use = "Auto railgun + shots at the most valuable enemy building" },
    { key = "FAST_RELOAD", id = 1998782486, use = "Strike timers halved (airfield / railgun)" },
    { key = "VIP", id = 1983032307, use = "+10% troop growth (passive)" },
    { key = "HOST", id = 1969592603, use = "Private room settings (not automated)" },
    { key = "ADVANCED", id = 1969906389, use = "Private room modes (not automated)" },
}
local passApi = {}
task.spawn(function()
    local MPS = game:GetService("MarketplaceService")
    for _, p in PASSES do
        local ok, owns = pcall(MPS.UserOwnsGamePassAsync, MPS, lp.UserId, p.id)
        if ok and owns then passApi[p.key] = true end
    end
end)
local function hasPass(k) return lp:GetAttribute("ConquestPass_" .. k) == true or passApi[k] == true end
local function role() return RS:GetAttribute("ConquestRole") end
local function dist(a, b)
    local dx, dy = a % W - b % W, a // W - b // W
    return math.sqrt(dx * dx + dy * dy)
end
local function setOf(list)
    local s = {}
    if type(list) == "table" then for _, v in list do s[tonumber(v) or v] = true end end
    return s
end

-- the game's own ATTACK SIZE slider (HUD "Conquest.Bar.CapCommit" = "ATTACK SIZE  33%"); nil if not readable
local hudRatio, hudAt = nil, 0
local function gameRatio()
    if os.clock() - hudAt > 1 then
        hudAt = os.clock()
        local ok, txt = pcall(function() return lp.PlayerGui.Conquest.Bar.CapCommit.Text end)
        local n = ok and tonumber(tostring(txt):match("(%d+)%s*%%"))
        hudRatio = n and math.clamp(n / 100, Config.MIN_ATTACK_RATIO or 0.05, 1) or nil
    end
    return hudRatio
end
-- ratio for a push: the HUD slider when "use game slider" is on, else this feature's own slider
local function ratio(own) return CFG.useHudRatio and gameRatio() or own end

-- ============================== sender (single queue, dedup, rate cap) ==============================
local lastSent, lastAny = {}, 0
local FORBID = { revive = true, topup = true, unally = true }
local function send(msg, key)
    if FORBID[msg.t] then return false end
    key = key or (msg.t .. ":" .. tostring(msg.tile or msg.id or ""))
    local now = os.clock()
    if lastSent[key] and now - lastSent[key] < 1 then return false end
    local wait = CFG.gap - (now - lastAny)
    if wait > 0 then task.wait(wait) end
    lastSent[key], lastAny = os.clock(), os.clock()
    if msg.t == "build" then S.lastBuildAt = os.clock() end
    Intent:FireServer(msg)
    stats.sent += 1
    return true
end
local lastLobby = 0
local function lobbySend(...)
    local wait = 1.1 - (os.clock() - lastLobby)
    if wait > 0 then task.wait(wait) end
    lastLobby = os.clock()
    LobbyIntent:FireServer(...)
end

-- ============================== game map (the client's own TileMap) ==============================
local function stateUpvalues()
    for _, c in getconnections(State.OnClientEvent) do
        local f = c.Function
        if f and islclosure(f) then
            local ok, ups = pcall(debug.getupvalues, f)
            if ok then
                for _, uv in ups do
                    if type(uv) == "table" and type(rawget(uv, "terrain")) == "buffer" and type(rawget(uv, "owner")) == "buffer" then
                        return uv, ups
                    end
                end
            end
        end
    end
end
local function getMap()
    local m, ups = stateUpvalues()
    if ups and not S.namesFromClient then -- mid-match inject misses "roster": take the client's biggest id->name table
        local best, bestN = nil, 0
        for _, uv in ups do
            if type(uv) == "table" then
                local n, ok = 0, true
                for k, v in uv do if type(k) ~= "number" or type(v) ~= "string" then ok = false break end n += 1 end
                if ok and n > bestN then best, bestN = uv, n end
            end
        end
        if best then for k, v in best do S.names[k] = S.names[k] or v end S.namesFromClient = true end
    end
    if m and not S.myId and ups then -- injected mid-match: recover my id from the client's id->userId table
        for _, uv in ups do
            if type(uv) == "table" then
                for k, v in uv do
                    if v == lp.UserId and type(k) == "number" and k < 256 then S.myId = k; log("my id " .. k .. " (from client)") break end
                end
            end
            if S.myId then break end
        end
    end
    return m
end
local function passable(ter, i)
    local b = readu8(ter, i)
    return btest(b, 128) and bit32.band(b, 63) < 63
end

-- one pass over the map: my tiles, border contacts per owner, candidate tiles for buildings, per-owner samples
local function scanMap()
    local m = getMap()
    if not m or not S.myId then return nil end
    local own, ter, me = m.owner, m.terrain, S.myId
    S.map = m -- missile listener checks whether a launch lands on my land
    local r = { shoreN = 0, coast = {}, coastN = 0, hole = {}, holeD = {}, region = {}, regions = {}, mine = 0, contacts = {}, sample = {}, borderMine = {}, interior = {}, shore = {}, any = {}, anyN = {}, sumx = 0, sumy = 0 }
    for i = 0, N - 1 do
        local o = readu8(own, i)
        if o == me then
            r.mine += 1
            local x = i % W
            r.sumx += x; r.sumy += i // W
            local inner = true
            for d = 1, 4 do
                local j = (d == 1 and i - W) or (d == 2 and i + W) or (d == 3 and x > 0 and i - 1) or (d == 4 and x < W - 1 and i + 1) or -1
                if j >= 0 and j < N then
                    local oj = readu8(own, j)
                    if oj ~= me then
                        inner = false
                        if passable(ter, j) then
                            local c = (r.contacts[oj] or 0) + 1
                            r.contacts[oj] = c
                            if math.random(c) == 1 then r.sample[oj] = j end
                            if oj == 0 then
                                -- open land next to me: nearest one to each nuke hole, plus a coarse per-region sample (disconnected pockets)
                                for h in S.holes do
                                    local d = dist(j, h)
                                    if d < 80 and (not r.holeD[h] or d < r.holeD[h]) then r.holeD[h], r.hole[h] = d, j end
                                end
                                local reg = (j // W) // 40 * 100 + (j % W) // 40
                                if not r.region[reg] then r.region[reg] = j; r.regions[#r.regions + 1] = reg end
                            end
                            local bm = r.borderMine[oj]
                            if not bm then bm = {}; r.borderMine[oj] = bm end
                            if #bm < 60 then bm[#bm + 1] = i elseif math.random(c) <= 60 then bm[math.random(60)] = i end
                        end
                    end
                end
            end
            if inner and #r.interior < 400 and math.random() < 0.05 then r.interior[#r.interior + 1] = i end
            if btest(readu8(ter, i), 64) then -- my coast: reservoir sample so the whole coastline is represented
                r.shoreN += 1
                if #r.shore < 300 then r.shore[#r.shore + 1] = i elseif math.random(r.shoreN) <= 300 then r.shore[math.random(300)] = i end
            end
        elseif o == 0 and i % 5 == 0 and btest(readu8(ter, i), 64) and passable(ter, i) then -- open coast anywhere (island targets)
            r.coastN += 1
            if #r.coast < 400 then r.coast[#r.coast + 1] = i elseif math.random(r.coastN) <= 400 then r.coast[math.random(400)] = i end
        elseif o ~= 0 and i % 61 == 0 then
            local c = (r.anyN[o] or 0) + 1
            r.anyN[o] = c
            if math.random(c) == 1 then r.any[o] = i end
        end
        if i % 25000 == 0 then task.wait() end
    end
    if r.mine > 0 then r.center = math.floor(r.sumy / r.mine) * W + math.floor(r.sumx / r.mine) end
    return r
end

-- ============================== listeners ==============================
local function onState(k, p, full)
    S.lastState = os.clock()
    if k == "init" and type(p) == "table" then
        S.myId = tonumber(p.yourId) or S.myId
        S.phase = p.phase; S.ended = false; S.leaveAt = nil
        table.clear(S.structs); table.clear(S.badTile); S.spawnSent = 0; S.spawnOk = false; table.clear(S.grudge); table.clear(S.nukeGrudge); S.nukedAt = -1e9; S.nukeSeenAt = -1e9; table.clear(S.holes); S.islandOff = nil; S.playStart = nil
        log("match init: id " .. tostring(S.myId) .. " phase " .. tostring(p.phase))
    elseif k == "roster" and type(p) == "table" then
        for _, v in p do
            if v.i then S.names[v.i] = v.n; if v.u == lp.UserId then S.myId = v.i end end
        end
    elseif k == "players" and typeof(p) == "buffer" then -- inlined Net.unpackPlayers (10 bytes each)
        local list, by = {}, {}
        for n = 0, buffer.len(p) // 10 - 1 do
            local o = n * 10
            local fl = readu8(p, o + 9)
            local t = bit32.rshift(fl, 2)
            local v = { id = readu8(p, o), tiles = buffer.readu32(p, o + 1), troops = buffer.readu32(p, o + 5),
                alive = bit32.band(fl, 1) == 1, isBot = bit32.band(fl, 2) == 2, team = t > 0 and t or nil }
            list[#list + 1] = v; by[v.id] = v
        end
        S.players, S.byId = list, by
        S.me = S.myId and by[S.myId] or nil
    elseif k == "fronts" and type(p) == "table" then
        S.fronts = p
        S.gold = p.gold or S.gold
        if type(p.diplo) == "table" then S.diplo = p.diplo end
    elseif k == "phase" and type(p) == "table" then
        if p.phase ~= S.phase then log("phase " .. tostring(p.phase)) end
        if p.phase == "playing" and S.phase == "spawn" then S.playStart = os.clock() end -- real start seen (not a mid-match inject)
        S.phase = p.phase
    elseif k == "structs" and type(p) == "table" then
        if full then table.clear(S.structs) end
        for _, v in p do
            if type(v) == "table" and v.tile then
                S.structs[v.tile] = (v.ownerId and v.ownerId ~= 0) and v or nil
            end
        end
    elseif k == "missiles" and type(p) == "table" and S.map and S.myId then
        -- launches: l = nuke {owner,src,dst,kind}, pl = airstrike plane, rf = railgun shot; count only those landing on my land
        local now = os.clock()
        for _, v in p do
            if type(v) == "table" and v.e == "l" and v.owner ~= S.myId then S.nukeSeenAt = now end -- someone is nuking: arm anti-nukes
            if type(v) == "table" and (v.e == "l" or v.e == "pl" or v.e == "rf") and v.owner and v.owner ~= S.myId
                and type(v.dst) == "number" and v.dst >= 0 and v.dst < N and readu8(S.map.owner, v.dst) == S.myId then
                local who = S.names[v.owner] or ("#" .. v.owner)
                S.grudge[v.owner] = now + CFG.grudgeSecs
                if v.e == "l" then
                    S.nukedAt = now
                    S.holes[v.dst] = now -- reclaim target once it lands (neutral pocket inside my land)
                    S.nukeGrudge[v.owner] = now + CFG.nukeGrudgeSecs
                    log("NUKE incoming from " .. who .. " -> revenge queued")
                elseif CFG.revengeNukeStrikes then
                    S.nukeGrudge[v.owner] = now + CFG.nukeGrudgeSecs
                    log((v.e == "pl" and "airstrike" or "railgun") .. " from " .. who .. " -> revenge queued")
                end
            end
        end
    elseif k == "fell" and type(p) == "table" and p.tile then
        S.structs[p.tile] = nil
    elseif k == "rearmed" and type(p) == "table" and type(p.tile) == "number" then
        S.readyAt[p.tile] = 0
    elseif k == "spawned" and type(p) == "table" then
        S.spawnOk = true -- preview = server accepted the pick; don't re-pick and move
        if not p.preview then log("spawned at " .. tostring(p.tile)) end
    elseif k == "denied" and type(p) == "table" then
        stats.denied += 1
        S.lastDenied = tostring(p.reason)
        if S.lastTile then
            local permanent = p.reason == "toonear" or p.reason == "taken" or p.reason == "water" or p.reason == "notplayable" or p.reason == "nocoast"
            -- any other build refusal (under construction, maxlevel, ...): skip that tile for 30 s instead of retrying every tick
            if permanent then S.badTile[S.lastTile] = math.huge
            elseif S.lastBuildAt and os.clock() - S.lastBuildAt < 3 and p.reason ~= "gold" then S.badTile[S.lastTile] = os.clock() + 30 end
            S.lastDeniedTile = S.lastTile
        end
    elseif k == "money" then
        S.money = p
    elseif k == "win" then
        S.phase, S.ended = "ended", true
        log("match over: " .. tostring(type(p) == "table" and (p.name or p.team) or p))
    end
end
table.insert(conns, State.OnClientEvent:Connect(onState))

table.insert(conns, Lobby.OnClientEvent:Connect(function(k, p, p2)
    if k == "board" and type(p) == "table" then
        local uid = lp.UserId
        local ok, b = pcall(Matchmaker.readWire, p, uid) -- game function: this thread must not touch Instances after it
        if ok then S.board = b end
    elseif k == "money" then
        S.lobbyMoney = tonumber(p)
    elseif k == "patterns" and type(p) == "table" then
        S.money2x = p.money2x
    elseif k == "reward" and type(p) == "table" then
        S.rewardClaimed = p.claimed == true
    end
end))

-- ============================== guard hook (Robux prompts, alliance breaks) ==============================
local oldNC
oldNC = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
    if running and not checkcaller() and getnamecallmethod() == "FireServer" then
        if self == Shop and CFG.blockPrompts then
            local a = ...
            if a == "buy" or a == "pass" then return end
        elseif self == Intent and CFG.blockUnally then
            local m = ...
            if type(m) == "table" and m.t == "unally" then return end
        end
    end
    return oldNC(self, ...)
end))

-- ============================== helpers ==============================
local function troopCap()
    local me = S.me
    if not me then return 1 end
    local lv = S.fronts and S.fronts.levels or 0
    return (Config.MAX_TROOPS_MULT or 2) * (me.tiles ^ (Config.TROOPS_TILE_EXPONENT or 0.6) * (Config.TROOPS_PER_TILE_COEF or 1000)
        + (Config.BASE_MAX_TROOPS or 50000)) + lv * (Config.CITY_TROOP_INCREASE or 250000)
end
local function allies() return setOf(S.diplo and S.diplo.allies) end
local function blacklisted(id)
    local n = S.names[id]
    if not n or CFG.blacklist == "" then return false end
    for w in CFG.blacklist:gmatch("[^,%s]+") do if n:lower():find(w:lower(), 1, true) then return true end end
    return false
end
local function friendly(id, al)
    if al[id] then return true end
    local me, v = S.me, S.byId[id]
    return me and v and me.team and v.team == me.team or false
end
local function myStructs(kind)
    local out = {}
    for t, v in S.structs do if v.ownerId == S.myId and (v.kind or 1) == kind then out[#out + 1] = t end end
    return out
end
local function spaced(tile)
    if (S.badTile[tile] or 0) > os.clock() then return false end
    for t in S.structs do if dist(t, tile) < MIN_DIST then return false end end
    return true
end
local function pick(list, extra)
    if not list then return nil end
    for _ = 1, math.min(#list, 40) do
        local t = list[math.random(#list)]
        if spaced(t) and (not extra or extra(t)) then return t end
    end
end
local function inMatch() return role() == "match" end

-- ============================== spawn ==============================
local function doSpawn(r)
    local m = getMap()
    if not m then return end
    local own, ter = m.owner, m.terrain
    local taken = {}
    local seen = 0
    for i = 0, N - 1, 7 do
        if readu8(own, i) ~= 0 then -- reservoir-capped at 600 so the distance loop stays cheap
            seen += 1
            if #taken < 600 then taken[#taken + 1] = i elseif math.random(seen) <= 600 then taken[math.random(600)] = i end
        end
        if i % 70000 == 0 then task.wait() end
    end
    local best, bestScore = nil, -1
    for n = 1, 1000 do
        local i = math.random(0, N - 1)
        if passable(ter, i) then
            local x, y = i % W, i // W
            local land = 0
            for dy = -4, 4, 4 do for dx = -4, 4, 4 do
                local xx, yy = x + dx, y + dy
                if xx >= 0 and xx < W and yy >= 0 and yy < H and passable(ter, yy * W + xx) then land += 1 end
            end end
            if land >= 8 then
                local near = 1e9
                for _, t in taken do local d = dist(t, i); if d < near then near = d end end
                local score = math.min(near, 200) + (CFG.spawnCoast and btest(readu8(ter, i), 64) and 30 or 0)
                if score > bestScore then best, bestScore = i, score end
            end
        end
        if n % 100 == 0 then task.wait() end
    end
    if best then
        send({ t = "spawn", tile = best })
        S.spawnSent = os.clock()
        status.expand = ("spawn picked %d (%.0f tiles from others)"):format(best, bestScore)
        log(status.expand)
    end
end

-- ============================== expand + combat (one front scheduler) ==============================
local function doFronts(r)
    local me, f = S.me, S.fronts
    if not me or not f or not me.alive then return end
    local cap = troopCap()
    local fill = me.troops / cap
    local out = f.out or {}
    local fronted = {}
    for _, v in out do fronted[v.id] = true end
    status.expand = ("troops %s / %s (%.0f%%) · fronts %d out / %d in · land %d tiles"):format(fmt(me.troops), fmt(cap), fill * 100, #out, #(f.inc or {}), me.tiles)
    if me.troops < (Config.MIN_ATTACK_TROOPS or 250) * 2 then return end

    if CFG.expand and not fronted[0] and #out < 4 and r.sample[0] and fill >= CFG.bandLow then
        S.lastTile = r.sample[0]
        if send({ t = "attack", tile = r.sample[0], ratio = ratio(CFG.expandRatio) }, "expand") then
            stats.attacks += 1
            fronted[0] = true; out = table.clone(out); out[#out + 1] = { id = 0 }
        end
    end

    -- a neutral attack only spreads through CONNECTED open land from its seed tile (Sim.seedFrontier); another attack on
    -- open land merges into the same front and seeds there. Use that to retake nuke holes and disconnected pockets.
    local now0 = os.clock()
    if CFG.reclaim and S.map then
        for h, at in S.holes do
            if now0 - at > 600 or readu8(S.map.owner, h) == S.myId then S.holes[h] = nil -- retaken or stale
            elseif r.hole[h] and fill >= CFG.reclaimMin and now0 - at > 3 and now0 - (S.holeSent[h] or -99) > 6 then
                S.holeSent[h] = now0
                S.lastTile = r.hole[h]
                if send({ t = "attack", tile = r.hole[h], ratio = CFG.reclaimRatio }, "reclaim:" .. h) then
                    stats.attacks += 1; fronted[0] = true
                    status.expand = ("reclaiming nuked land near %d"):format(h)
                end
            end
        end
    end
    -- ISLANDS: an attack on land I don't border becomes a transport boat server-side (troops/5, max 3 boats,
    -- Sim.launchTransportBoat). Pick the nearest open coast tile across water from my coast.
    local locked = not r.sample[0] -- no open land touches me: boats are the only way to grow
    if CFG.islands and not S.islandOff and S.map and #r.shore > 0 and #r.coast > 0 and now0 >= (S.islandAt or 0)
        and fill >= (locked and CFG.islandMinLocked or CFG.islandMin) and me.troops / 5 >= (Config.TRANSPORT_BOAT_MIN_TROOPS or 250)
        and not (CFG.islandOnlyLocked and not locked) then
        -- nearest open coast across water, skipping spots a recent boat already went for (spread over islands)
        local best, bd
        for _, i in r.coast do
            local fresh = true
            for t, at in S.islandTargets do if now0 - at < 60 and dist(t, i) < 30 then fresh = false break end end
            if fresh then
                for k = 1, 16 do
                    local d = dist(r.shore[math.random(#r.shore)], i)
                    if d > 3 and d <= CFG.islandMaxDist and (not bd or d < bd) then best, bd = i, d end
                end
            end
        end
        S.islandAt = now0 + CFG.islandEvery
        if best then
            S.lastTile, S.islandSent, S.lastDenied = best, now0, "-"
            S.islandTargets[best] = now0 -- fresh so a stale denial can't switch islands off
            if send({ t = "attack", tile = best, ratio = ratio(CFG.expandRatio) }, "island") then
                stats.attacks += 1
                status.expand = ("boat to open coast %d (%.0f tiles away)"):format(best, bd); log(status.expand)
            end
        end
    end
    if S.islandSent and now0 - S.islandSent < 3 then
        local d = S.lastDenied
        if d == "notadjacent" then S.islandOff = true; log("islands: server won't boat to open land here, island expand off"); S.islandSent = nil
        elseif d == "toomanytransportboats" or d == "busy" then S.islandAt = now0 + 20; S.islandSent = nil end
    end

    if CFG.expand and fronted[0] and fill >= CFG.bandHigh and #r.regions > 1 and now0 - (S.spreadAt or -99) > 5 then
        S.spreadAt = now0
        local reg = r.regions[math.random(#r.regions)]
        if send({ t = "attack", tile = r.region[reg], ratio = ratio(CFG.expandRatio) / 2 }, "spread") then stats.attacks += 1 end
    end

    -- grudges: everyone attacking me is remembered for CFG.grudgeSecs
    local now = os.clock()
    local incoming = 0
    for _, v in f.inc or {} do
        incoming += 1
        if v.id and v.id ~= 0 then
            if not S.grudge[v.id] or S.grudge[v.id] < now then log("grudge: " .. (S.names[v.id] or ("#" .. v.id)) .. " attacked me") end
            S.grudge[v.id] = now + CFG.grudgeSecs
        end
    end
    local al = allies()
    local traitors = setOf(S.diplo and S.diplo.traitors)

    local function pickTarget(onlyGrudge)
        local sendTroops = me.troops * ratio(CFG.attackRatio)
        local best, bestScore, why
        for id in r.contacts do
            local v = S.byId[id]
            local grudge = S.grudge[id] and S.grudge[id] > now
            if id ~= 0 and v and v.alive and not fronted[id] and not friendly(id, al) and (grudge or not onlyGrudge)
                and ((v.isBot and CFG.hitBots) or (not v.isBot and CFG.hitPlayers) or (grudge and CFG.revenge))
                -- Sim.attackLoss: attacker losses scale with the defender's WHOLE army / attack troops, so compare against all of it
                and sendTroops >= v.troops * (grudge and CFG.revengeEdge or CFG.edge)
                -- revenge only when I'm stronger overall; otherwise troops stay home (my defense = my total troops)
                and (not grudge or me.troops >= v.troops * CFG.revengeStronger) then -- both paths: never chase a stronger grudge
                -- lower score = better: weakest first, grudges/traitors/finishable players pulled to the front
                local score = v.troops
                local tag = "weakest"
                if CFG.finish and not v.isBot and v.troops < me.troops * 0.1 then score *= 0.2; tag = "finish off (50% of their gold)" end
                if CFG.hitTraitors and traitors[id] then score *= 0.3; tag = "traitor (x0.5 defense)" end
                if grudge and CFG.revenge then score *= 0.05; tag = "revenge" end
                if not bestScore or score < bestScore then best, bestScore, why = id, score, tag end
            end
        end
        return best, why
    end

    local function strike(id, why, ratio)
        S.lastTile = r.sample[id]
        if r.sample[id] and send({ t = "attack", tile = r.sample[id], ratio = ratio }, "atk:" .. id) then
            stats.attacks += 1
            status.combat = ("%s: %s (%s troops) @%d%%"):format(why, S.names[id] or ("#" .. id), fmt(S.byId[id].troops), math.floor(ratio * 100 + 0.5))
            log(status.combat)
            fronted[id] = true
            return true
        end
    end

    -- COUNTER (Sim.launchAttack, OPPOSING_ATTACKS_CANCEL): my attack on someone attacking me first cancels their incoming
    -- attack 1:1, the rest invades their home. Their home troops (players.troops) already exclude what they sent at me.
    S.threat = nil
    local keep = math.max(me.troops * CFG.keepHome, cap * CFG.keepCap) -- floor: never invade myself down to ~0% of cap
    for _, v in f.inc or {} do
        local a = S.byId[v.id]
        local incT = v.troops or 0
        if a and v.id ~= 0 and a.alive and not friendly(v.id, al) and r.sample[v.id] then
            local cancel = incT * 1.05
            local punish = cancel + a.troops * CFG.revengeEdge
            local spare = me.troops - keep
            local send, why
            if CFG.counterPunish and spare >= punish then send, why = punish, "counter: cancel + invade"
            elseif CFG.counterCancel and spare >= cancel then send, why = cancel, "counter: cancel their attack"
            end
            if send and send >= (Config.MIN_ATTACK_TROOPS or 250) then
                if now - (counterAt[v.id] or -99) > 4 then -- wait for the fronts update before topping up again
                    counterAt[v.id] = now
                    strike(v.id, why, math.clamp(send / me.troops, Config.MIN_ATTACK_RATIO or 0.05, 1))
                end
            elseif not send then
                -- can't cancel it without emptying my home: last stand against the biggest such attacker
                if not S.threat or incT > S.threat.inc then S.threat = { id = v.id, inc = incT } end
            end
        elseif a and v.id ~= 0 and not r.sample[v.id] then
            if not S.threat or incT > S.threat.inc then S.threat = { id = v.id, inc = incT } end -- boat landing: can't touch their border
        end
    end
    if S.threat then
        status.combat = ("LAST STAND vs %s (attack %s, my home %s)"):format(S.names[S.threat.id] or ("#" .. S.threat.id), fmt(S.threat.inc), fmt(me.troops))
        if CFG.lastStandAlly and not (S.byId[S.threat.id] or {}).isBot and now - (reqAt[S.threat.id] or -99) > 35 then
            reqAt[S.threat.id] = now
            if send({ t = "ally", id = S.threat.id }) then log("last stand: asked " .. (S.names[S.threat.id] or "?") .. " for an alliance") end
        end
    end

    -- revenge after their attack is gone: only when I'm clearly stronger
    if CFG.revenge and #out < 4 and fill >= CFG.revengeMin and not S.threat then
        local id = pickTarget(true)
        if id and strike(id, "revenge", ratio(CFG.revengeRatio)) then out = table.clone(out); out[#out + 1] = { id = id } end
    end

    if not CFG.attack then if not status.combat:find("^revenge") then status.combat = "auto attack off" end return end
    if CFG.holdWhenHit then
        for _, v in f.inc or {} do
            local a = S.byId[v.id]
            if a and a.troops >= me.troops * 0.7 then status.combat = ("holding troops: %s (%s) is attacking"):format(S.names[v.id] or ("#" .. v.id), fmt(a.troops)); return end
        end
    end
    if #out >= math.min(CFG.maxFronts, 4) then status.combat = "front limit"; return end
    if fill < CFG.attackMin then status.combat = ("saving troops (%.0f%% < %.0f%%)"):format(fill * 100, CFG.attackMin * 100); return end
    local best, why = pickTarget(false)
    if best then strike(best, why, ratio(CFG.attackRatio)) else status.combat = "no valid target" end
end

-- ============================== gold arbiter: build + nukes + reinforce ==============================
local function buildCost(kind)
    local f = S.fronts or {}
    if kind == "city" then return (f.freeCities or 0) > 0 and 0 or f.cost
    elseif kind == "port" then return f.portCost
    elseif kind == "defense" then return (f.freePosts or 0) > 0 and 0 or f.postCost
    elseif kind == "sam" then return (f.freeSams or 0) > 0 and 0 or f.samCost
    elseif kind == "artillery" then return f.artilleryCost
    elseif kind == "airfield" then return f.airfieldCost
    elseif kind == "railgun" then return f.railgunCost end
end

-- PLACEMENT STRATEGY (numbers from Config / Nukes / Economy):
--  * a nuke removes every structure within its outer radius (Atom 30, Mega 60): spread city levels over several
--    cities >= citySpread apart instead of one Lv10 city (= 2.5M army cap in one blast)
--  * cities deep inside (far from any border) survive attacks longest
--  * trade ships pay by route length (50/tile, short routes < 300 debuffed): spread ports far from each other
--  * defense posts buff 30 tiles around them: sit ~6 tiles behind the attacked border, not on it (overrun first)
--  * artillery shells 45 tiles: sit ~12 behind the border so the ring reaches ~33 tiles into enemy land
local function borderSamples(r)
    local all = {}
    for _, list in r.borderMine do for _, t in list do all[#all + 1] = t end end
    return all
end
local function depthOf(t, border)
    local d = 1e9
    for _, b in border do local x = dist(t, b); if x < d then d = x end end
    return d
end
local function owned(t) return S.map and t >= 0 and t < N and readu8(S.map.owner, t) == S.myId and passable(S.map.terrain, t) end
-- step k tiles from border tile b toward my territory's center
local function inward(b, k, r)
    if not r.center then return nil end
    local bx, by, cx, cy = b % W, b // W, r.center % W, r.center // W
    local dx, dy = cx - bx, cy - by
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return nil end
    local x, y = math.floor(bx + dx / len * k + 0.5), math.floor(by + dy / len * k + 0.5)
    if x < 0 or x >= W or y < 0 or y >= H then return nil end
    return y * W + x
end
-- best of a candidate list by score(t) (higher = better), only owned + spaced tiles
local function bestOf(cands, score)
    local best, bs
    for i = 1, math.min(#cands, 80) do
        local t = cands[#cands > 80 and math.random(#cands) or i]
        if owned(t) and spaced(t) then
            local sc = score(t)
            if sc and (not bs or sc > bs) then best, bs = t, sc end
        end
    end
    return best, bs
end

local function placeFor(kind, r)
    local border = borderSamples(r)
    if kind == "city" then
        local cities = myStructs(KIND.city)
        -- upgrade the LOWEST city first, and only up to cityMaxLv while a new city still fits
        local low, lowLv = nil, 99
        for _, t in cities do
            local lv = S.structs[t].level or 1
            if lv < lowLv and (S.badTile[t] or 0) <= os.clock() then low, lowLv = t, lv end
        end
        local cap = #cities < CFG.max_city and CFG.cityMaxLv or (Config.CITY_MAX_LEVEL or 10)
        if CFG.upgradeCities and low and lowLv < cap then return low end
        if #cities >= CFG.max_city then return nil end
        local function score(t)
            local near = 1e9
            for _, c in cities do local d = dist(t, c); if d < near then near = d end end
            if near < CFG.citySpread then return nil end -- inside another city's blast
            return math.min(depthOf(t, border), 60) * 2 + math.min(near, 120)
        end
        local t = bestOf(r.interior, score)
        if t then return t end
        -- no room for a spread-out city: upgrade past cityMaxLv instead
        if CFG.upgradeCities and low and lowLv < (Config.CITY_MAX_LEVEL or 10) then return low end
        return nil
    elseif kind == "port" then
        local ports = myStructs(KIND.port)
        return (bestOf(r.shore, function(t)
            local near = 1e9
            for _, p in ports do local d = dist(t, p); if d < near then near = d end end
            -- far from my other ports (longer trade routes), and not on a front line
            return math.min(near, 400) + math.min(depthOf(t, border), 40)
        end))
    elseif kind == "defense" or kind == "artillery" then
        local top, topV = nil, -1
        if kind == "defense" then -- the biggest incoming attack
            for _, v in (S.fronts and S.fronts.inc or {}) do if v.troops and v.troops > topV and r.borderMine[v.id] then top, topV = v.id, v.troops end end
        else -- the enemy player I share the longest border with
            for id, c in r.contacts do if id ~= 0 and c > topV and r.borderMine[id] then top, topV = id, c end end
        end
        if not top then return nil end
        local back = kind == "defense" and 6 or 12
        local reach = kind == "defense" and (Config.DEFENSE_POST_RANGE or 30) or 45
        local front = r.borderMine[top]
        local cands = {}
        for _, b in front do local t = inward(b, back, r); if t then cands[#cands + 1] = t end end
        return (bestOf(cands, function(t)
            local c = 0
            for _, b in front do if dist(t, b) <= reach then c += 1 end end -- border tiles it protects / shells
            return c
        end))
    elseif kind == "airfield" then
        -- strikes reach 156: behind the busiest enemy front, deep enough to survive
        local top, topC = nil, 0
        for id, c in r.contacts do if id ~= 0 and c > topC then top, topC = id, c end end
        local cands = {}
        if top then for _, b in r.borderMine[top] do local t = inward(b, 25, r); if t then cands[#cands + 1] = t end end end
        return (bestOf(#cands > 0 and cands or r.interior, function(t) return math.min(depthOf(t, border), 40) end))
    else -- railgun (no range limit) / sam fallback: deepest interior
        return (bestOf(r.interior, function(t) return depthOf(t, border) end))
    end
end

local ORDER = { "city", "port", "defense", "artillery", "airfield", "railgun" } -- anti-nukes: own manager (samAuto)
local builtAt = {}
local function wantBuild(kind)
    if not CFG["b_" .. kind] then return false end
    if os.clock() - (builtAt[kind] or -99) < 3 then return false end -- structs packet lags; don't overshoot the max
    if BUILD_PASS[kind] and not hasPass(BUILD_PASS[kind]) then return false end
    local mine = #myStructs(KIND[kind])
    if kind == "city" then
        local lv = S.fronts and S.fronts.levels or 0
        return lv < CFG.max_city * (Config.CITY_MAX_LEVEL or 10) and (mine < CFG.max_city or CFG.upgradeCities)
    end
    if kind == "defense" and #(S.fronts and S.fronts.inc or {}) == 0 then return false end
    return mine < CFG["max_" .. kind]
end

local function doEconomy(r)
    local f, me = S.fronts, S.me
    if not f or not me or not me.alive then return end
    local gold = S.gold
    local cap = troopCap()

    -- reinforce (cheap, time-critical) first
    if CFG.reinforce and hasPass("BARRACKS") and (f.reinforceLeft or 0) <= 0 and f.reinforceCost and gold - CFG.reserve >= f.reinforceCost
        and me.troops / cap < CFG.reinforceBelow then
        if send({ t = "reinforce" }) then log("reinforce"); gold -= f.reinforceCost end
    end

    -- nukes: revenge first (whoever nuked / struck my land), then the normal biggest-enemy nuke
    -- Nukes.lua:1153 removes EVERY structure inside the outer radius, and kills troops per tile hit (their home army and
    -- all their running attacks). Best spot = their structures covering the most city levels (city Lv = 250K of their cap).
    local function nukeSpot(who, nk, allowLand, minLv)
        local theirs, mine, sams = {}, {}, {}
        for t, s in S.structs do
            if s.ownerId == who then theirs[#theirs + 1] = t end
            if s.ownerId == S.myId then mine[#mine + 1] = t end
            if s.kind == KIND.sam and s.ownerId ~= S.myId then sams[#sams + 1] = t end
        end
        local function safe(c)
            for _, t in mine do if dist(t, c) < nk.r + 2 then return false end end
            for _, list in r.borderMine do for _, t in list do if dist(t, c) < nk.r + 5 then return false end end end
            if CFG.avoidSam then for _, t in sams do if dist(t, c) < 80 then return false end end end
            return true
        end
        local best, bestScore, bestLv = nil, 0, 0
        for _, c in theirs do
            local score, lv = 0, 0
            for _, t in theirs do
                if dist(t, c) < nk.r then
                    local s = S.structs[t]
                    local k = s.kind or 1
                    if k == KIND.city then score += 10 * (s.level or 1); lv += s.level or 1
                    elseif k == KIND.sam or k == KIND.railgun or k == KIND.airfield then score += 8
                    else score += 2 end
                end
            end
            if score > bestScore and lv >= (minLv or 0) and safe(c) then best, bestScore, bestLv = c, score, lv end
        end
        if best then return best, ("%d city levels"):format(bestLv) end
        if allowLand then
            local t = r.any[who] or r.sample[who]
            if t and safe(t) then return t, "their land (no known cities)" end
        end
    end

    local function fireNuke(kindName, who, minGold, why, allowLand, minLv)
        local free = (f.freeNukes or 0) > 0
        if kindName == "Best owned" then -- strongest nuke I own and can pay for (a free nuke takes the strongest owned)
            kindName = "Atom"
            for _, k in { "Scattershot", "Mega" } do
                local n = NUKE[k]
                if hasPass(n.pass) and (free or gold - CFG.reserve >= math.max(n.cost, minGold)) then kindName = k break end
            end
        end
        local nk = NUKE[kindName]
        if not nk or (nk.pass and not hasPass(nk.pass)) then return false end
        if not free and gold - CFG.reserve < math.max(nk.cost, minGold) then
            status.weapons = ("%s: saving for %s nuke (%s / %s)"):format(why, kindName, fmt(gold), fmt(nk.cost)); return false
        end
        local target, what = nukeSpot(who, nk, allowLand, minLv)
        if not target then status.weapons = why .. ": nuke held (no safe spot: their cities unknown, near me, or under an anti-nuke)"; return false end
        if send({ t = "nuke", tile = target, kind = nk.kind }) then
            stats.nukes += 1
            status.weapons = ("%s: %s nuke -> %s (%s)"):format(why, kindName, S.names[who] or ("#" .. who), what); log(status.weapons)
            if not free then gold -= nk.cost end
            return true
        end
        return false
    end

    local now = os.clock()
    -- LAST STAND (set by doFronts when an attack can't be cancelled without emptying my home)
    local th = CFG.lastStand and S.threat
    if th then
        if hasPass("BARRACKS") and (f.reinforceLeft or 0) <= 0 and f.reinforceCost and gold >= f.reinforceCost then
            if send({ t = "reinforce" }) then log("last stand: reinforce"); gold -= f.reinforceCost end
        end
        if now - (S.lastStandNukeAt or -1e9) >= 10 and fireNuke(CFG.lastStandNuke, th.id, 0, "last stand", true) then S.lastStandNukeAt = now end
        local bm = r.borderMine[th.id]
        local cost = buildCost("defense")
        if bm and cost and gold >= cost and #myStructs(KIND.defense) < CFG.max_defense + 2 then
            local tile = pick(bm)
            if tile then
                S.lastTile = tile
                if send({ t = "build", tile = tile, kind = KIND.defense }) then stats.builds += 1; log("last stand: defense post at " .. tile); gold -= cost end
            end
        end
    end
    if CFG.revengeNuke then
        local who, latest = nil, 0
        for id, t in S.nukeGrudge do
            local v = S.byId[id]
            if t > now and v and v.alive and not friendly(id, allies()) and t > latest then who, latest = id, t end
        end
        if who and fireNuke(CFG.revengeNukeKind, who, 0, "revenge", false, CFG.revengeMinLv) and CFG.revengeOnce then S.nukeGrudge[who] = nil end
    end
    local freeNuke = CFG.useFree and (f.freeNukes or 0) > 0 -- product nukes (starter packs / railgun bundle) cost no gold
    if (CFG.nuke or freeNuke) and now - (S.lastAutoNuke or -1e9) >= CFG.nukeCooldown then
        local al, best, bestTiles = allies(), nil, 0
        for _, v in S.players do
            local grudge = (S.grudge[v.id] or 0) > now
            -- don't poke a stronger player who isn't already fighting me (they retaliate)
            local provoke = v.troops > me.troops and not grudge and not CFG.nukeStronger
            if v.id ~= S.myId and v.alive and not friendly(v.id, al) and not (v.isBot and CFG.nukeSkipBots) and not provoke and v.tiles > bestTiles then best, bestTiles = v.id, v.tiles end
        end
        if best and fireNuke(CFG.nukeKind, best, CFG.nukeMinGold, "auto", true) then S.lastAutoNuke = now end
    end

    -- AUTO ANTI-NUKE: cover my most valuable structures, then upgrade for range (Nukes.samRange = 150 - 480/(lv+5))
    if CFG.samAuto then
        local nuked = now - S.nukedAt < 120
        local seen = now - S.nukeSeenAt < 600
        local played = S.playStart and (now - S.playStart) / 60 or 99 -- injected mid-match: assume late game
        local sams, value = {}, {}
        local cityLv = 0
        -- anti-nukes take ~10 s to build and may not be in structs yet: count my recent orders for 20 s
        for t, at in S.pendingSam do
            local real = S.structs[t] and not S.structs[t].pending
            if now - at > 20 or real then
                S.pendingSam[t] = nil
                if not real and S.structs[t] then S.structs[t] = nil end -- order never materialised
            else sams[#sams + 1] = t; if not S.structs[t] then S.structs[t] = { ownerId = S.myId, kind = KIND.sam, level = 1, pending = true } end end
        end
        for t, s in S.structs do
            if s.ownerId == S.myId then
                local k = s.kind or 1
                if k == KIND.sam then if not s.pending then sams[#sams + 1] = t end
                else
                    local w = k == KIND.city and 10 * (s.level or 1) or 3
                    if k == KIND.city then cityLv += s.level or 1 end
                    value[#value + 1] = { t = t, w = w }
                end
            end
        end
        local function covered(t)
            for _, sm in sams do if dist(sm, t) <= 150 - 480 / ((S.structs[sm].level or 1) + 5) then return true end end
            return false
        end
        local uncovered = 0
        for _, v in value do if not covered(v.t) then uncovered += v.w end end
        -- Prepare: others earn a flat 1K gold/s, so anyone can afford an Atom (750K) ~12 min in; get cover up before that
        local armed = CFG.samMode == "Always" or nuked or (seen and CFG.samMode ~= "After I'm nuked")
            or (CFG.samMode == "Prepare" and (played >= CFG.samPrepMin or cityLv >= CFG.samPrepCityLv))
        status.samInfo = ("anti-nukes %d/%d · city levels %d · uncovered value %d · %s"):format(#sams, CFG.max_sam, cityLv,
            uncovered, armed and (nuked and "NUKED: rushing" or "armed") or ("waiting (" .. CFG.samMode .. ")"))
        local total = 0
        for _, v in value do total += v.w end
        -- worth protecting at all? (after a nuke wipes my cities there may be nothing left: rebuild first)
        if armed and total >= CFG.samMinValue and (cityLv >= CFG.samMinCityLv or nuked) and now - (builtAt.sam or -99) >= 15 then
            local cost = buildCost("sam")
            local tile, what
            local why = "all covered"
            if uncovered > 0 and #sams < CFG.max_sam then
                -- new anti-nuke where a Lv1 ring (70 tiles) covers the most uncovered value. Dense land rarely has a random
                -- tile 15+ from every building, so seed rings 18/28/40 tiles around the most valuable uncovered buildings.
                local own, ter = S.map.owner, S.map.terrain
                local cands = table.clone(r.interior)
                local top = {}
                for _, v in value do if not covered(v.t) then top[#top + 1] = v end end
                table.sort(top, function(a, b) return a.w > b.w end)
                for i = 1, math.min(#top, 10) do
                    local cx, cy = top[i].t % W, top[i].t // W
                    for _, rad in { 18, 28, 40 } do
                        for a = 0, 11 do
                            local x = math.floor(cx + rad * math.cos(a * math.pi / 6) + 0.5)
                            local y = math.floor(cy + rad * math.sin(a * math.pi / 6) + 0.5)
                            if x >= 0 and x < W and y >= 0 and y < H then cands[#cands + 1] = y * W + x end
                        end
                    end
                end
                local best, bestV = nil, 0
                for _, c in cands do
                    if readu8(own, c) == S.myId and passable(ter, c) and spaced(c) then
                        local sc = 0
                        for _, v in top do if dist(v.t, c) <= 70 then sc += v.w end end
                        if sc > bestV then best, bestV = c, sc end
                    end
                end
                if best and bestV >= CFG.samMinValue then tile, what = best, ("new, covers %d value"):format(bestV)
                else why = best and ("best spot only covers " .. bestV) or "no free spot 15+ tiles from buildings" end
            elseif #sams >= CFG.max_sam then why = "at max count" end
            if not tile and CFG.samUpgrade and #sams > 0 then -- nowhere new (or all covered / at max): upgrade for range instead
                local low, lowLv = nil, 99
                for _, sm in sams do local lv = S.structs[sm].level or 1 if lv < lowLv and (S.badTile[sm] or 0) <= os.clock() then low, lowLv = sm, lv end end
                local rich = gold >= (cost or math.huge) * 2 or nuked or seen
                if low and lowLv < math.min(CFG.samMaxLv, Config.STRUCTURE_MAX_LEVEL or 10) and rich then tile, what = low, ("upgrade Lv%d -> %d (%s)"):format(lowLv, lowLv + 1, why) end
            end
            if not tile then status.samInfo ..= " · idle: " .. why end
            if tile and cost then
                if gold - CFG.reserve >= cost or (nuked and gold >= cost) then
                    S.lastTile = tile
                    if send({ t = "build", tile = tile, kind = KIND.sam }) then
                        stats.builds += 1; builtAt.sam = now; S.pendingSam[tile] = now
                        log(("anti-nuke %s at %d for %s"):format(what, tile, fmt(cost))); gold -= cost
                        return
                    end
                elseif CFG.samPriority and (nuked or seen) and uncovered >= CFG.samMinValue then -- real threat only: Prepare never stalls growth
                    status.build = ("saving for anti-nuke (%s / %s)"):format(fmt(gold), fmt(cost))
                    return -- hold other builds until it's funded
                end
            end
        end
    end

    if not CFG.build then status.build = "off"; return end
    for _, kind in ORDER do
        if wantBuild(kind) then
            local cost = buildCost(kind)
            if cost then
                if gold - CFG.reserve >= cost then
                    local tile = placeFor(kind, r)
                    if tile then
                        S.lastTile = tile
                        if send({ t = "build", tile = tile, kind = KIND[kind] }) then
                            stats.builds += 1; builtAt[kind] = os.clock()
                            status.build = ("%s at %d for %s"):format(kind, tile, fmt(cost)); log("build " .. status.build)
                            return
                        end
                    end
                elseif CFG.saveForTop then
                    status.build = ("saving for %s (%s / %s)"):format(kind, fmt(gold), fmt(cost))
                    return
                end
            end
        end
    end
end

-- ============================== airstrikes / railgun on cooldown ==============================
local function doStrikes(r)
    if not S.me or not S.me.alive then return end
    local al = allies()
    -- value of hitting an enemy building: anti-nukes and strike platforms first, then city levels
    local VAL = { [KIND.sam] = 40, [KIND.railgun] = 30, [KIND.airfield] = 25, [KIND.artillery] = 15, [KIND.defense] = 8, [KIND.port] = 6 }
    local incoming = {}
    for _, v in (S.fronts and S.fronts.inc or {}) do incoming[v.id] = true end
    local function worth(s)
        local v = s.kind == KIND.city and 10 * (s.level or 1) or (VAL[s.kind] or 3)
        if incoming[s.ownerId] or (S.grudge[s.ownerId] or 0) > os.clock() then v *= 2 end -- whoever is fighting me
        return v
    end
    local targets = {}
    for t, s in S.structs do if s.ownerId ~= S.myId and not friendly(s.ownerId, al) then targets[#targets + 1] = t end end
    local now = os.clock()
    local cd = hasPass("FAST_RELOAD") and 0.5 or 1
    local function fire(kind, verb, reload, range, radius)
        for _, from in myStructs(kind) do
            if now >= (S.readyAt[from] or 0) then
                local best, bv
                for _, t in targets do
                    if not range or dist(from, t) <= range then
                        local v = 0 -- everything inside the hit radius counts
                        for _, u in targets do if dist(t, u) <= radius then v += worth(S.structs[u]) end end
                        if not bv or v > bv then best, bv = t, v end
                    end
                end
                if not best then -- no known enemy building in range: nearest enemy border tile
                    local bd
                    for id, t in r.sample do
                        if id ~= 0 and not friendly(id, al) then
                            local d = dist(from, t)
                            if (not range or d <= range) and (not bd or d < bd) then best, bd = t, d end
                        end
                    end
                end
                if best and send({ t = verb, from = from, tile = best }) then
                    S.readyAt[from] = now + reload * cd + 1
                    stats.strikes += 1
                    local st = S.structs[best]
                    status.weapons = ("%s -> %s (%s)"):format(verb, st and (S.names[st.ownerId] or "?") or "border", bv and ("value " .. bv) or "no buildings in range")
                end
            end
        end
    end
    if CFG.airstrike then fire(KIND.airfield, "airstrike", 30, Config.AIRFIELD_RANGE or 156, 15) end -- strike radius 15
    if CFG.railgun then fire(KIND.railgun, "railgun", 25, nil, 5) end -- no range limit, radius 5
end

-- ============================== diplomacy ==============================
-- reqAt: defined at the top (shared with last stand)
local function doDiplo(r)
    local d = S.diplo
    if not d then status.diplo = "no data yet"; return end
    local al = setOf(d.allies)
    if CFG.accept then
        for id in setOf(d.inreq) do
            if not blacklisted(id) and send({ t = "ally", id = id }) then stats.allies += 1; log("accepted alliance from " .. tostring(S.names[id] or id)) end
        end
    end
    if CFG.renew and type(d.expiring) == "table" then
        for _, v in d.expiring do if type(v) == "table" and v.id then send({ t = "renew", id = v.id }) end end
    end
    if CFG.request and S.me then
        local out = setOf(d.outreq)
        for id in r.contacts do
            local v = S.byId[id]
            if id ~= 0 and v and v.alive and not v.isBot and not al[id] and not out[id] and not blacklisted(id)
                and v.troops >= S.me.troops * CFG.requestRatio and os.clock() - (reqAt[id] or -99) > 35 then
                reqAt[id] = os.clock()
                if send({ t = "ally", id = id }) then log("asked " .. tostring(S.names[id] or id) .. " to ally") end
            end
        end
    end
    local n = 0
    for _ in al do n += 1 end
    status.diplo = ("allies %d · incoming requests %d · traitors %d"):format(n, #(d.inreq or {}), #(d.traitors or {}))
end

-- ============================== lobby loop ==============================
local function doLobby()
    if CFG.claimReward and S.rewardClaimed == false then
        lobbySend("reward"); S.rewardClaimed = true; log("claimed free reward")
    end
    if CFG.buyPasses then
        local money = S.lobbyMoney
        if money then
            for _, k in PASS_ORDER do
                if not hasPass(k) and money - CFG.passReserve >= PASS_PRICE[k] then
                    Shop:FireServer("passmoney", k); log("bought pass " .. k .. " for " .. PASS_PRICE[k] .. " Money")
                    S.lobbyMoney = money - PASS_PRICE[k]
                    task.wait(2)
                    break
                end
            end
        end
    end
    if not CFG.queue then status.lobby = "auto queue off"; return end
    local b = S.board
    if not b then
        status.lobby = "waiting for the match board"
        return
    end
    for _, s in b do if s.mine then status.lobby = ("queued: %s · %s %s (%d/%d, %ss)"):format(s.name, s.mapName, s.modeName, s.count, s.cap, tostring(s.remaining)); return end end
    local sizes = CFG.queueSizes
    local anySize = next(sizes) == nil
    local best, bestFill
    for _, s in b do
        if s.state == "open" and s.count < s.cap and (anySize or sizes[tostring(s.name):upper()]) and not (CFG.skipSpecial and (s.special or s.historical)) then
            local fill = s.count / math.max(s.cap, 1) + (s.count > 0 and 0.01 or 0)
            if not bestFill or fill > bestFill then best, bestFill = s, fill end
        end
    end
    if best then
        lobbySend("join", "slot" .. best.slot, "")
        stats.joins += 1
        status.lobby = ("joining %s · %s %s"):format(best.name, best.mapName, best.modeName)
        log(status.lobby)
    else
        status.lobby = "no open slot matches the filter"
    end
end

-- ============================== main loops ==============================
local function guard(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log(name .. " error: " .. tostring(err)) end
end

task.spawn(function()
    while running do
        if inMatch() then
            if not S.myId then pcall(getMap) end -- injected mid-match: no init packet, recover id from the client
            local me = S.me or (S.myId and S.byId[S.myId])
            S.me = me
            -- spawn phase (or injected mid-spawn with no land)
            if CFG.spawn and not S.spawnOk and (S.phase == "spawn" or (S.phase == nil and me and me.tiles == 0 and me.alive ~= false))
                and os.clock() - S.spawnSent > 6 then
                guard("spawn", doSpawn)
            end
            -- end of match / death -> leave for the lobby
            if CFG.leave and (S.ended or (me and not me.alive and S.phase ~= "spawn" and me.tiles == 0)) then
                S.leaveAt = S.leaveAt or (os.clock() + CFG.leaveDelay)
                if os.clock() >= S.leaveAt then
                    send({ t = "leave" }); log("leaving match"); S.leaveAt = os.clock() + 10
                end
            end
            -- watchdog: dead server
            if CFG.leave and os.clock() - S.lastState > 30 then
                log("no match state for 30 s, leaving"); send({ t = "leave" }); S.lastState = os.clock()
            end
            if S.phase ~= "spawn" and me and me.alive and me.tiles > 0 then
                local r = scanMap()
                if r then
                    S.scan = r
                    guard("fronts", doFronts, r)
                    guard("economy", doEconomy, r)
                    guard("strikes", doStrikes, r)
                    guard("diplo", doDiplo, r)
                end
            end
        elseif role() == "lobby" then
            guard("lobby", doLobby)
        end
        task.wait(CFG.scanEvery)
    end
end)

pcall(applyCamera)

-- reload after the lobby <-> match teleport
if CFG.reinject and queue_on_teleport and not getgenv().PC_QUEUED then -- once per server: reloads here must not stack queue entries
    getgenv().PC_QUEUED = true
    -- local dev copy if present, else the published script
    pcall(queue_on_teleport, [[repeat task.wait() until game:IsLoaded(); task.wait(3)
local src = isfile("pc_main.lua") and readfile("pc_main.lua") or game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/pixel-conquest/pc_main.lua")
local f = loadstring(src); if f then f() end]])
end

-- ============================== unload ==============================
local function unload()
    running = false
    CFG.camUnlock = false; pcall(applyCamera) -- give the game its camera back
    for _, c in conns do pcall(function() c:Disconnect() end) end
    getgenv().PC_FARM = nil
end
getgenv().PC_FARM = { S = S, CFG = CFG, stats = stats, status = status, unload = function() unload(); if Library then pcall(function() Library:Unload() end) end end }

-- ============================== Obsidian UI ==============================
local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local function obsidian(file, remotePath)
    local path = "BattleBotFarm/lib/" .. file -- shared local copy (a hung HttpGet once jammed the executor queue)
    local ok, src = pcall(function() return isfile(path) and readfile(path) end)
    return loadstring(ok and src or game:HttpGet(repo .. remotePath))()
end
Library = obsidian("Library.lua", "Library.lua")
local ThemeManager = obsidian("ThemeManager.lua", "addons/ThemeManager.lua")
local SaveManager = obsidian("SaveManager.lua", "addons/SaveManager.lua")

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
    end)(), Footer = "Pixel Conquest · v1.9 · expand · combat · build · weapons · diplomacy · lobby",
    Center = true, AutoShow = true, ToggleKeybind = Enum.KeyCode.RightControl,
})
local Tabs = {
    Expand = Window:AddTab("Expand", "map"), Combat = Window:AddTab("Combat", "swords"), Build = Window:AddTab("Build", "hammer"),
    Weapons = Window:AddTab("Weapons", "flame"), Diplo = Window:AddTab("Diplomacy", "handshake"), Lobby = Window:AddTab("Lobby", "repeat"),
    Passes = Window:AddTab("Passes", "badge-check"), Info = Window:AddTab("Info", "activity"), Settings = Window:AddTab("Settings", "settings"),
}
local function set(k) return function(v) CFG[k] = v end end
local function pct(k) return function(v) CFG[k] = v / 100 end end

-- Expand
local EX = Tabs.Expand:AddLeftGroupbox("Spawn", "map-pin")
EX:AddToggle("PC_Spawn", { Text = "Auto pick spawn", Default = CFG.spawn, Callback = set("spawn") })
EX:AddToggle("PC_SpawnCoast", { Text = "Prefer coast (ports / trade)", Default = CFG.spawnCoast, Callback = set("spawnCoast") })
EX:AddLabel("Picks open land as far as possible from everyone already placed.", true)
local EX2 = Tabs.Expand:AddRightGroupbox("Expand into open land", "expand")
EX2:AddToggle("PC_Expand", { Text = "Auto expand", Default = CFG.expand, Callback = set("expand") })
EX2:AddSlider("PC_ExpandRatio", { Text = "Troops sent per push %", Default = CFG.expandRatio * 100, Min = 5, Max = 100, Rounding = 0, Callback = pct("expandRatio") })
EX2:AddSlider("PC_BandLow", { Text = "Only push above % of cap", Default = CFG.bandLow * 100, Min = 0, Max = 95, Rounding = 0, Callback = pct("bandLow") })
EX2:AddLabel("Troops grow fastest at 40-60% of cap: small pushes that keep you there grow the most.", true)
EX2:AddSlider("PC_BandHigh", { Text = "Seed other open pockets above % of cap", Default = CFG.bandHigh * 100, Min = 10, Max = 100, Rounding = 0, Callback = pct("bandHigh") })
local EXI = Tabs.Expand:AddRightGroupbox("Islands (transport boats)", "ship")
EXI:AddToggle("PC_Islands", { Text = "Boat to open land across water", Default = CFG.islands, Callback = set("islands") })
EXI:AddToggle("PC_IslandLocked", { Text = "Only when no open land borders me", Default = CFG.islandOnlyLocked, Callback = set("islandOnlyLocked") })
EXI:AddSlider("PC_IslandMin", { Text = "Only above % of cap", Default = CFG.islandMin * 100, Min = 10, Max = 95, Rounding = 0, Callback = pct("islandMin") })
EXI:AddSlider("PC_IslandMinLocked", { Text = "...when boxed in (no open land next to me)", Default = CFG.islandMinLocked * 100, Min = 0, Max = 95, Rounding = 0, Callback = pct("islandMinLocked") })
EXI:AddSlider("PC_IslandEvery", { Text = "Seconds between boats", Default = CFG.islandEvery, Min = 5, Max = 120, Rounding = 0, Callback = set("islandEvery") })
EXI:AddSlider("PC_IslandDist", { Text = "Max sea distance (tiles)", Default = CFG.islandMaxDist, Min = 20, Max = 600, Rounding = 0, Callback = set("islandMaxDist") })
EXI:AddLabel("Each boat carries 1/5 of your troops (game rule, ratio ignored), max 3 at sea. Nearest open coast first.", true)
local EX3 = Tabs.Expand:AddLeftGroupbox("Reclaim nuked land", "radiation")
EX3:AddToggle("PC_Reclaim", { Text = "Retake land nuked out of my territory", Default = CFG.reclaim, Callback = set("reclaim") })
EX3:AddSlider("PC_ReclaimMin", { Text = "Only above % of cap", Default = CFG.reclaimMin * 100, Min = 0, Max = 90, Rounding = 0, Callback = pct("reclaimMin") })
EX3:AddSlider("PC_ReclaimRatio", { Text = "Troops per reclaim push %", Default = CFG.reclaimRatio * 100, Min = 5, Max = 60, Rounding = 0, Callback = pct("reclaimRatio") })
EX3:AddLabel("Holes aren't connected to your expand front, so each gets its own push. Fallout tiles defend ~x5 for a while.", true)
local expandLabel = EX2:AddLabel("-", true)

-- Combat
local CB = Tabs.Combat:AddLeftGroupbox("Auto attack", "swords")
CB:AddToggle("PC_Attack", { Text = "Attack weakest neighbour", Default = CFG.attack, Callback = set("attack") })
CB:AddToggle("PC_HitBots", { Text = "Target bots / nations", Default = CFG.hitBots, Callback = set("hitBots") })
CB:AddToggle("PC_HitPlayers", { Text = "Target players", Default = CFG.hitPlayers, Callback = set("hitPlayers") })
CB:AddSlider("PC_AttackRatio", { Text = "Troops sent per attack %", Default = CFG.attackRatio * 100, Min = 5, Max = 100, Rounding = 0, Callback = pct("attackRatio") })
CB:AddSlider("PC_AttackMin", { Text = "Only attack above % of cap", Default = CFG.attackMin * 100, Min = 0, Max = 100, Rounding = 0, Callback = pct("attackMin") })
CB:AddSlider("PC_Edge", { Text = "Required troop edge (x)", Default = CFG.edge, Min = 0.5, Max = 4, Rounding = 1, Callback = set("edge") })
CB:AddSlider("PC_MaxFronts", { Text = "Max fronts (game cap 4)", Default = CFG.maxFronts, Min = 1, Max = 4, Rounding = 0, Callback = set("maxFronts") })
CB:AddToggle("PC_HoldHit", { Text = "Hold troops while a strong player attacks me", Tooltip = "Your defense = your total troops at home", Default = CFG.holdWhenHit, Callback = set("holdWhenHit") })
CB:AddLabel("Allies and teammates are never attacked.", true)
local CT = Tabs.Combat:AddLeftGroupbox("Counter attack (game cancels opposing attacks 1:1)", "shield")
CT:AddToggle("PC_CounterCancel", { Text = "Cancel incoming attacks", Tooltip = "Sends exactly their attack size back: both armies cancel 1:1", Default = CFG.counterCancel, Callback = set("counterCancel") })
CT:AddToggle("PC_CounterPunish", { Text = "Cancel + invade when I can afford it", Tooltip = "Extra troops push into their home, which is emptied by their own attack", Default = CFG.counterPunish, Callback = set("counterPunish") })
CT:AddSlider("PC_KeepHome", { Text = "Always keep % of my troops home", Default = CFG.keepHome * 100, Min = 0, Max = 90, Rounding = 0, Callback = pct("keepHome") })
CT:AddSlider("PC_KeepCap", { Text = "...and never below % of my cap", Default = CFG.keepCap * 100, Min = 0, Max = 60, Rounding = 0, Callback = pct("keepCap") })
CT:AddToggle("PC_LastStand", { Text = "Last stand when I can't cancel it", Tooltip = "Nuke the attacker, defense post on that border, reinforce, ask to ally", Default = CFG.lastStand, Callback = set("lastStand") })
CT:AddDropdown("PC_LastNuke", { Text = "Last stand nuke", Values = { "Best owned", "Atom", "Mega", "Scattershot" }, Default = CFG.lastStandNuke, Callback = set("lastStandNuke") })
CT:AddToggle("PC_LastAlly", { Text = "Last stand: ask the attacker to ally", Default = CFG.lastStandAlly, Callback = set("lastStandAlly") })
CT:AddLabel("A nuke kills troops in the attacker's running attacks too, and wipes every building in its blast.", true)
local RV = Tabs.Combat:AddRightGroupbox("Revenge & priorities", "skull")
RV:AddToggle("PC_Revenge", { Text = "Revenge: hit back whoever attacks me", Tooltip = "Works even with auto attack off", Default = CFG.revenge, Callback = set("revenge") })
RV:AddSlider("PC_RevRatio", { Text = "Revenge troops sent %", Default = CFG.revengeRatio * 100, Min = 5, Max = 100, Rounding = 0, Callback = pct("revengeRatio") })
RV:AddSlider("PC_RevMin", { Text = "Revenge only above % of cap", Default = CFG.revengeMin * 100, Min = 0, Max = 100, Rounding = 0, Callback = pct("revengeMin") })
RV:AddSlider("PC_RevEdge", { Text = "Revenge troop edge (x)", Default = CFG.revengeEdge, Min = 0.1, Max = 4, Rounding = 1, Callback = set("revengeEdge") })
RV:AddSlider("PC_RevStronger", { Text = "Revenge only if my army is x theirs", Default = CFG.revengeStronger, Min = 0.5, Max = 4, Rounding = 1, Callback = set("revengeStronger") })
RV:AddSlider("PC_Grudge", { Text = "Remember attackers for (s)", Default = CFG.grudgeSecs, Min = 10, Max = 600, Rounding = 0, Callback = set("grudgeSecs") })
RV:AddToggle("PC_Traitors", { Text = "Prioritise traitors (x0.5 defense)", Default = CFG.hitTraitors, Callback = set("hitTraitors") })
RV:AddToggle("PC_Finish", { Text = "Prioritise finishing weak players (+50% their gold)", Default = CFG.finish, Callback = set("finish") })
local combatLabel = RV:AddLabel("-", true)

-- Build
local BD = Tabs.Build:AddLeftGroupbox("Auto build (priority top to bottom)", "hammer")
BD:AddToggle("PC_Build", { Text = "Auto build", Default = CFG.build, Callback = set("build") })
BD:AddToggle("PC_Upgrade", { Text = "Upgrade cities in place (to Lv 10)", Default = CFG.upgradeCities, Callback = set("upgradeCities") })
BD:AddSlider("PC_CityMaxLv", { Text = "Upgrade each city to Lv (then build a new one)", Tooltip = "One nuke wipes every building in its blast: spread levels over several cities", Default = CFG.cityMaxLv, Min = 1, Max = 10, Rounding = 0, Callback = set("cityMaxLv") })
BD:AddSlider("PC_CitySpread", { Text = "Min tiles between cities", Tooltip = "31 = outside one Atom blast, 61 = outside a Mega", Default = CFG.citySpread, Min = 16, Max = 90, Rounding = 0, Callback = set("citySpread") })
BD:AddToggle("PC_SaveTop", { Text = "Save gold for the top missing building", Default = CFG.saveForTop, Callback = set("saveForTop") })
BD:AddSlider("PC_Reserve", { Text = "Gold reserve (K)", Default = CFG.reserve / 1000, Min = 0, Max = 5000, Rounding = 0, Callback = function(v) CFG.reserve = v * 1000 end })
local BD2 = Tabs.Build:AddRightGroupbox("Buildings", "building")
local NAMES = { city = "City (+army cap)", port = "Port (trade gold)", defense = "Defense post (on attacked border)", sam = "Anti-nuke (near cities)",
    artillery = "Artillery (pass)", airfield = "Airfield (pass)", railgun = "Railgun (pass)" }
for _, k in ORDER do
    BD2:AddToggle("PC_B_" .. k, { Text = NAMES[k], Default = CFG["b_" .. k], Callback = set("b_" .. k) })
    BD2:AddSlider("PC_M_" .. k, { Text = "  max " .. k .. (k == "city" and " (count)" or ""), Default = CFG["max_" .. k], Min = 0, Max = 10, Rounding = 0, Callback = set("max_" .. k) })
end
local buildLabel = BD:AddLabel("-", true)

-- Weapons
local WP = Tabs.Weapons:AddLeftGroupbox("Nukes", "radiation")
WP:AddToggle("PC_Nuke", { Text = "Auto nuke biggest enemy", Default = CFG.nuke, Callback = set("nuke") })
WP:AddDropdown("PC_NukeKind", { Text = "Nuke type", Values = { "Best owned", "Atom", "Mega", "Scattershot" }, Default = CFG.nukeKind, Callback = set("nukeKind") })
WP:AddSlider("PC_NukeMin", { Text = "Min gold before nuking (K)", Default = 0, Min = 0, Max = 10000, Rounding = 0, Callback = function(v) CFG.nukeMinGold = v * 1000 end })
WP:AddSlider("PC_NukeCd", { Text = "Seconds between auto nukes", Default = CFG.nukeCooldown, Min = 5, Max = 300, Rounding = 0, Callback = set("nukeCooldown") })
WP:AddToggle("PC_NukeStronger", { Text = "Also nuke stronger players who aren't attacking me", Tooltip = "Off = don't provoke them", Default = CFG.nukeStronger, Callback = set("nukeStronger") })
WP:AddToggle("PC_NukeBots", { Text = "Skip bots", Default = CFG.nukeSkipBots, Callback = set("nukeSkipBots") })
WP:AddToggle("PC_AvoidSam", { Text = "Skip targets under an enemy anti-nuke", Default = CFG.avoidSam, Callback = set("avoidSam") })
WP:AddLabel("Aims at their highest-level city; never within blast range of your own border.", true)
local WR = Tabs.Weapons:AddLeftGroupbox("Revenge nukes", "skull")
WR:AddToggle("PC_RevNuke", { Text = "Nuke back whoever nukes my land", Tooltip = "Aims at their best city cluster (city Lv = their army cap); holds if none known", Default = CFG.revengeNuke, Callback = set("revengeNuke") })
WR:AddDropdown("PC_RevNukeKind", { Text = "Revenge nuke type", Values = { "Best owned", "Atom", "Mega", "Scattershot" }, Default = CFG.revengeNukeKind, Callback = set("revengeNukeKind") })
WR:AddSlider("PC_RevMinLv", { Text = "Only if the blast hits city levels >=", Default = CFG.revengeMinLv, Min = 1, Max = 30, Rounding = 0, Callback = set("revengeMinLv") })
WR:AddToggle("PC_RevStrikes", { Text = "Also for airstrikes / railgun hits", Default = CFG.revengeNukeStrikes, Callback = set("revengeNukeStrikes") })
WR:AddToggle("PC_RevOnce", { Text = "One nuke per offence (off = keep nuking)", Default = CFG.revengeOnce, Callback = set("revengeOnce") })
WR:AddSlider("PC_NukeGrudge", { Text = "Remember nukers for (s)", Default = CFG.nukeGrudgeSecs, Min = 30, Max = 900, Rounding = 0, Callback = set("nukeGrudgeSecs") })
local AN = Tabs.Weapons:AddRightGroupbox("Auto anti-nuke", "shield-check")
AN:AddToggle("PC_SamAuto", { Text = "Auto anti-nuke", Default = CFG.samAuto, Callback = set("samAuto") })
AN:AddDropdown("PC_SamMode", { Text = "When", Values = { "Prepare", "Always", "Once nukes fly", "After I'm nuked" }, Default = CFG.samMode, Callback = set("samMode") })
AN:AddSlider("PC_SamPrepMin", { Text = "Prepare: arm after minutes played", Default = CFG.samPrepMin, Min = 0, Max = 30, Rounding = 0, Callback = set("samPrepMin") })
AN:AddSlider("PC_SamPrepLv", { Text = "Prepare: or once cities total Lv", Default = CFG.samPrepCityLv, Min = 1, Max = 100, Rounding = 0, Callback = set("samPrepCityLv") })
AN:AddSlider("PC_SamMax", { Text = "Max anti-nukes", Default = CFG.max_sam, Min = 0, Max = 8, Rounding = 0, Callback = set("max_sam") })
AN:AddSlider("PC_SamCityLv", { Text = "Only once my cities total Lv", Default = CFG.samMinCityLv, Min = 0, Max = 50, Rounding = 0, Callback = set("samMinCityLv") })
AN:AddSlider("PC_SamMinValue", { Text = "New one must cover value (city Lv x10)", Default = CFG.samMinValue, Min = 0, Max = 200, Rounding = 0, Callback = set("samMinValue") })
AN:AddSlider("PC_SamMaxLv", { Text = "Max upgrade level", Default = CFG.samMaxLv, Min = 1, Max = 10, Rounding = 0, Callback = set("samMaxLv") })
AN:AddToggle("PC_SamUpgrade", { Text = "Upgrade them for range when all covered", Tooltip = "Lv1 70 tiles -> Lv10 118 tiles", Default = CFG.samUpgrade, Callback = set("samUpgrade") })
AN:AddToggle("PC_SamPriority", { Text = "Pause other builds to fund it once nukes fly", Default = CFG.samPriority, Callback = set("samPriority") })
AN:AddLabel("Placed to cover your highest-level cities first. Being nuked always triggers it (ignores the reserve).", true)
local samLabel = AN:AddLabel("-", true)
local WP2 = Tabs.Weapons:AddRightGroupbox("Strikes & reinforce", "crosshair")
WP2:AddToggle("PC_Air", { Text = "Airstrike on cooldown (needs airfield)", Default = CFG.airstrike, Callback = set("airstrike") })
WP2:AddToggle("PC_Rail", { Text = "Railgun on cooldown (needs railgun)", Default = CFG.railgun, Callback = set("railgun") })
WP2:AddToggle("PC_Reinforce", { Text = "Auto reinforce (BARRACKS pass)", Default = CFG.reinforce, Callback = set("reinforce") })
WP2:AddSlider("PC_ReinBelow", { Text = "Reinforce below % of cap", Default = CFG.reinforceBelow * 100, Min = 5, Max = 100, Rounding = 0, Callback = pct("reinforceBelow") })
local weaponsLabel = WP2:AddLabel("-", true)

-- Diplomacy
local DP = Tabs.Diplo:AddLeftGroupbox("Alliances", "handshake")
DP:AddToggle("PC_Accept", { Text = "Auto accept requests", Default = CFG.accept, Callback = set("accept") })
DP:AddToggle("PC_Renew", { Text = "Auto renew expiring alliances", Default = CFG.renew, Callback = set("renew") })
DP:AddToggle("PC_Request", { Text = "Ask stronger neighbours to ally", Default = CFG.request, Callback = set("request") })
DP:AddSlider("PC_ReqRatio", { Text = "Ask when they have x my troops", Default = CFG.requestRatio, Min = 0.5, Max = 5, Rounding = 1, Callback = set("requestRatio") })
DP:AddToggle("PC_BlockUnally", { Text = "Block breaking alliances (traitor = x0.5 defense)", Default = CFG.blockUnally, Callback = set("blockUnally") })
DP:AddInput("PC_Blacklist", { Text = "Never ally (names, comma separated)", Default = "", Finished = true, Callback = set("blacklist") })
local diploLabel = Tabs.Diplo:AddRightGroupbox("Status", "activity"):AddLabel("-", true)

-- Lobby
local LB = Tabs.Lobby:AddLeftGroupbox("Loop", "repeat")
LB:AddToggle("PC_Queue", { Text = "Auto queue (fullest open slot)", Default = CFG.queue, Callback = set("queue") })
LB:AddDropdown("PC_Sizes", { Text = "Only these lobbies", Tooltip = "None picked = any", Values = { "SKIRMISH", "BATTLE", "WORLD WAR" }, Multi = true, Default = {}, Callback = set("queueSizes") })
LB:AddToggle("PC_SkipSpecial", { Text = "Skip special / historical modes", Default = CFG.skipSpecial, Callback = set("skipSpecial") })
LB:AddToggle("PC_Leave", { Text = "Leave after win / death (+ dead-server watchdog)", Default = CFG.leave, Callback = set("leave") })
LB:AddSlider("PC_LeaveDelay", { Text = "Wait before leaving (s)", Default = CFG.leaveDelay, Min = 0, Max = 30, Rounding = 0, Callback = set("leaveDelay") })
LB:AddToggle("PC_Reinject", { Text = "Reload after teleport", Default = CFG.reinject, Callback = set("reinject") })
LB:AddLabel("Money pays mostly per minute survived: long survival beats fast wins.", true)
local LB2 = Tabs.Lobby:AddRightGroupbox("Rewards & passes", "gift")
LB2:AddToggle("PC_Reward", { Text = "Claim the one-time free reward", Default = CFG.claimReward, Callback = set("claimReward") })
LB2:AddToggle("PC_BuyPasses", { Text = "Buy passes with Money", Default = CFG.buyPasses, Callback = set("buyPasses") })
LB2:AddLabel("Order: Mega Nuke 10K, Barracks 20K, Scattershot 20K, Artillery 25K, Airstrike 100K, Railgun 250K", true)
LB2:AddSlider("PC_PassReserve", { Text = "Keep Money (K)", Default = 0, Min = 0, Max = 250, Rounding = 0, Callback = function(v) CFG.passReserve = v * 1000 end })
local lobbyLabel = LB2:AddLabel("-", true)

-- Passes
local PS = Tabs.Passes:AddLeftGroupbox("Your passes", "badge-check")
PS:AddLabel("Each feature only runs when you own its pass. Money passes can be bought here with in-game Money.", true)
local passLabel = PS:AddLabel("-", true)
local PS2 = Tabs.Passes:AddRightGroupbox("Buy with Money", "coins")
local moneyKeys = {}
for _, p in PASSES do if p.money then moneyKeys[#moneyKeys + 1] = p.key end end
PS2:AddDropdown("PC_BuyPick", { Text = "Pass", Values = moneyKeys, Default = moneyKeys[1] })
PS2:AddButton({ Text = "Buy selected (lobby only)", Func = function()
    local k = Library.Options.PC_BuyPick.Value
    if role() ~= "lobby" then notify("Passes can only be bought in the lobby"); return end
    if hasPass(k) then notify("You already own " .. k); return end
    Shop:FireServer("passmoney", k); log("bought pass " .. k .. " with Money (manual)")
end })
PS2:AddToggle("PC_UseFree", { Text = "Use free items from packs (nukes, cities, posts, anti-nukes)", Tooltip = "Free nukes fire even with auto nuke off", Default = CFG.useFree, Callback = set("useFree") })
PS2:AddLabel("Robux-only passes (VIP, Fast Reload, Host, Advanced) are detected but never bought.", true)

-- Info
local IN = Tabs.Info:AddLeftGroupbox("Match", "activity")
local infoLabel = IN:AddLabel("-", true)
local IN2 = Tabs.Info:AddRightGroupbox("Standings", "list")
local standLabel = IN2:AddLabel("-", true)
local IN3 = Tabs.Info:AddLeftGroupbox("Log (also PixelConquest/log.txt)", "scroll-text")
local logLabel = IN3:AddLabel("-", true)

-- Settings
local SA = Tabs.Settings:AddLeftGroupbox("Safety", "shield-alert")
SA:AddToggle("PC_HudRatio", { Text = "Use the game's ATTACK SIZE slider", Tooltip = "Expand, attack, revenge and islands send the % set on the game HUD. Off = each feature's own slider. Counter attacks always size themselves to cancel the incoming attack.", Default = CFG.useHudRatio, Callback = set("useHudRatio") })
SA:AddToggle("PC_BlockPrompts", { Text = "Block the game's Robux purchase prompts", Tooltip = "Also blocks prompts you click yourself", Default = CFG.blockPrompts, Callback = set("blockPrompts") })
SA:AddSlider("PC_Gap", { Text = "Min seconds between actions", Default = CFG.gap, Min = 0.05, Max = 1, Rounding = 2, Callback = set("gap") })
SA:AddSlider("PC_ScanEvery", { Text = "Think every (s)", Default = CFG.scanEvery, Min = 1, Max = 10, Rounding = 0, Callback = set("scanEvery") })
local CM = Tabs.Settings:AddRightGroupbox("Camera", "camera")
CM:AddToggle("PC_CamUnlock", { Text = "Unlock camera bounds", Default = CFG.camUnlock, Callback = function(v) CFG.camUnlock = v; applyCamera() end })
CM:AddSlider("PC_CamMargin", { Text = "Pan past the map edge (x screen)", Default = CFG.camMargin, Min = 0, Max = 2, Rounding = 1, Callback = function(v) CFG.camMargin = v; applyCamera() end })
CM:AddSlider("PC_CamZoom", { Text = "Zoom range (x game's)", Default = CFG.camZoom, Min = 1, Max = 4, Rounding = 1, Callback = function(v) CFG.camZoom = v; applyCamera() end })
local Menu = Tabs.Settings:AddRightGroupbox("Menu", "menu")
Menu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })
Library:OnUnload(unload)
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetFolder("PixelConquest")
ThemeManager:SetFolder("PixelConquest")
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:SetDefaultTheme({ BackgroundColor = "0c0a0b", MainColor = "161214", AccentColor = "e0233c", OutlineColor = "2a1d20", FontColor = "f2eded" })
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:LoadAutoloadConfig()
notify = function(msg) Library:Notify(msg, 4) end

task.spawn(function()
    while running do
        pcall(function()
            expandLabel:SetText(status.expand)
            combatLabel:SetText(status.combat)
            buildLabel:SetText(status.build)
            weaponsLabel:SetText(status.weapons)
            samLabel:SetText(status.samInfo or "-")
            local pl = {}
            for _, p in PASSES do
                pl[#pl + 1] = ("%s %s - %s%s"):format(hasPass(p.key) and "[OWNED]" or "[  -  ]", p.key, p.use,
                    hasPass(p.key) and "" or (p.money and (" · " .. fmt(p.money) .. " Money") or " · Robux"))
            end
            local fr = S.fronts or {}
            pl[#pl + 1] = ("Free items now: nukes %d · cities %d · posts %d · anti-nukes %d · Money 2x %s"):format(fr.freeNukes or 0, fr.freeCities or 0, fr.freePosts or 0, fr.freeSams or 0, tostring(S.money2x or "?"))
            passLabel:SetText(table.concat(pl, "\n"))
            diploLabel:SetText(status.diplo)
            lobbyLabel:SetText(("%s\nMoney %s · reward %s"):format(status.lobby, S.lobbyMoney and fmt(S.lobbyMoney) or "?",
                S.rewardClaimed == nil and "?" or (S.rewardClaimed and "claimed" or "available")))
            local me = S.me
            local payout = type(S.money) == "table" and (S.money.total or S.money.amount or S.money.money) or S.money
            infoLabel:SetText(("server %s · phase %s · id %s\ngold %s · troops %s / %s · land %s tiles\npayout so far %s\nsent %d · attacks %d · builds %d · nukes %d · strikes %d · allies %d · joins %d\ndenied %d (last: %s)"):format(
                tostring(role()), tostring(S.phase), tostring(S.myId), fmt(S.gold), fmt(me and me.troops), fmt(troopCap()), me and me.tiles or 0,
                tostring(payout or "-"), stats.sent, stats.attacks, stats.builds, stats.nukes, stats.strikes, stats.allies, stats.joins, stats.denied, S.lastDenied))
            local list = table.clone(S.players)
            table.sort(list, function(a, b) return a.tiles > b.tiles end)
            local al, traitors, lines = allies(), setOf(S.diplo and S.diplo.traitors), {}
            for i = 1, math.min(#list, 10) do
                local v = list[i]
                lines[#lines + 1] = ("%d. %s%s  %s tiles · %s troops%s%s%s"):format(i, S.names[v.id] or ("#" .. v.id), v.id == S.myId and " (you)" or "",
                    fmt(v.tiles), fmt(v.troops), v.isBot and " · bot" or "", al[v.id] and " · ALLY" or "", traitors[v.id] and " · TRAITOR" or "")
            end
            standLabel:SetText(#lines > 0 and table.concat(lines, "\n") or "-")
            logLabel:SetText(table.concat(logLines, "\n", 1, math.min(#logLines, 14)))
        end)
        task.wait(1)
    end
end)

log("loaded v1.9 on " .. tostring(role()) .. " server")
Library:Notify("Pixel Conquest v1.9 ready — RightCtrl toggles the UI.", 5)
