--[[
    Pixel Conquest farm v3.3  (place 138110382920220, OpenFront.io port)
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
-- r = outer blast radius (Nukes.lua), reach = how far anything can land (safety), ring = Scattershot's random warhead band
local NUKE = { Atom = { kind = 13, cost = Config.ATOM_BOMB_COST or 750000, r = 30 }, Mega = { kind = 17, cost = Config.MEGA_NUKE_COST or 2500000, r = 60, pass = "MEGANUKE" },
    Scattershot = { kind = 20, cost = Config.SCATTERSHOT_COST or 3750000, r = 30, reach = (Config.SCATTERSHOT_SPREAD_MAX or 46) + 18,
        ring = 0.4, pass = "SCATTERSHOT" } } -- 4-6 warheads x ~1K tiles over a ~12.5K-tile ring: ~40% of it gets hit
local BUILD_PASS = { artillery = "ARTILLERY", airfield = "AIRSTRIKE", railgun = "RAILGUN" }
local PASS_PRICE = { MEGANUKE = 10000, BARRACKS = 20000, SCATTERSHOT = 20000, ARTILLERY = 25000, AIRSTRIKE = 100000, RAILGUN = 250000 }
local PASS_ORDER = { "MEGANUKE", "BARRACKS", "SCATTERSHOT", "ARTILLERY", "AIRSTRIKE", "RAILGUN" }

-- ============================== config ==============================
local CFG = {
    -- expand
    spawn = true, spawnCoast = false,
    expand = true, expandRatio = 0.25, bandLow = 0.40, bandHigh = 0.60, reclaim = true, reclaimMin = 0.15, reclaimRatio = 0.1,
    seaPath = true, seaEvery = 8,
    lootWeight = 0.05, lootRadius = 50, cheapFrac = 0.08, askAlly = false, leech = true, leechAny = false, leechMin = 0.3, leechEdge = 0.5,
    boatAttack = true, boatMin = 0.4, boatEdge = 1.1, boatEvery = 20, riverDist = 15, riverEdge = 0.6, riverEvery = 4,
    brain = true, brainSurvive = 0.25, brainNbrShare = 0.3, pushEdge = 0.5, surviveIn = 1.2, surviveOut = 0.8, postureDwell = 20,
    denyMargin = 0.15, denyReserve = true, holdable = 1.5, record = true,
    underdog = true, udRatio = 1.5, udDanger = 0.15, udDiplo = true, udStrike = true, udOpening = 0.6, udStrikeRatio = 0.5, udEdge = 1.0,
    udNuke = true, udDenyCd = 12, udDefense = true,
    siege = true, siegeBots = true, siegeTrigger = 2, siegeFill = 0.9, siegeEdge = 1.3, siegeKeep = 0.3, siegeHold = true, siegeGap = 25, siegeNuke = true, siegeNukeKind = "Best owned",
    islands = true, islandMin = 0.45, islandMinLocked = 0.15, islandEvery = 15, islandMaxDist = 250, islandOnlyLocked = false,
    -- combat
    attack = false, attackRatio = 0.33, attackMin = 0.55, edge = 1.2, maxFronts = 3, hitBots = true, hitPlayers = true,
    counterCancel = true, counterPunish = true, keepHome = 0.35, keepCap = 0.1,
    lastStand = true, lastStandNuke = "Best owned", lastStandAlly = false,
    revenge = true, revengeRatio = 0.3, revengeMin = 0.5, revengeEdge = 0.6, revengeStronger = 1.3, grudgeSecs = 120,
    hitTraitors = true, finish = true, holdWhenHit = true, nukeCooldown = 45, nukeStronger = false,
    revengeNuke = true, revengeNukeKind = "Best owned", revengeMinLv = 1, nukeGrudgeSecs = 300, revengeOnce = true, revengeNukeStrikes = false,
    useFree = true,
    nukeUpsize = 1.15, -- a bigger nuke must beat the smaller one by 15% value-per-gold
    samAuto = true, samMode = "Prepare", samPrepMin = 6, samPrepCityLv = 20, samMaxLv = 5, samMinCityLv = 5, samMinValue = 20, samUpgrade = true, samPriority = true,
    -- build
    build = true, reserve = 0, saveForTop = false,
    b_city = true, b_port = true, b_defense = true, b_sam = false, b_artillery = true, b_airfield = true, b_railgun = false,
    max_city = 10, max_port = 3, max_defense = 4, max_sam = 2, max_artillery = 3, max_airfield = 1, max_railgun = 1,
    upgradeCities = true, cityMaxLv = 5, citySpread = 31, cityWeight = true, cityFillHigh = 0.55, cityFillLow = 0.25, citySpare = 2,
    -- weapons
    nuke = false, nukeKind = "Best owned", nukeMinGold = 0, nukeSkipBots = true, avoidSam = true,
    airstrike = true, railgun = true, reinforce = true, reinforceBelow = 0.5,
    -- diplomacy
    accept = false, renew = true, request = false, requestRatio = 1.5, blockUnally = true, blacklist = "",
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
    structs = {}, grudge = {}, nukeGrudge = {}, nukedAt = -1e9, nukeSeenAt = -1e9, pendingSam = {}, holes = {}, holeSent = {}, islandTargets = {}, boatBad = {}, siege = nil, siegeSkip = {}, hist = {}, askN = {}, udPeak = {}, udEmbargo = {}, money = nil, ended = false, lastState = os.clock(), spawnSent = 0, badTile = {}, lastDenied = "-",
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
local function fmtT(n) return fmt((tonumber(n) or 0) / 10) end -- troops are stored x10; the HUD shows troops/10 (Numbers.formatTroops)
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
local HOSTILE = { attack = true, nuke = true, airstrike = true, railgun = true }
-- ally or teammate (fronts.diplo.allies + players.team); used by the sender's last-line check
local function isFriend(id)
    if not id or id == 0 or id == S.myId then return false end
    for _, a in (S.diplo and S.diplo.allies or {}) do if tonumber(a) == id then return true end end
    local me, v = S.me, S.byId[id]
    return (me and v and me.team ~= nil and v.team == me.team) or false
end
local blockedAt = {}
local function send(msg, key)
    if FORBID[msg.t] then return false end
    if msg.t == "ally" then -- the same intent asks OR accepts: both need the player's explicit switch
        local incoming = false
        for _, v in (S.diplo and S.diplo.inreq or {}) do if tonumber(v) == msg.id then incoming = true end end
        if incoming and not CFG.accept then return false end
        if not incoming and not CFG.askAlly then return false end
    end
    if HOSTILE[msg.t] and S.map and type(msg.tile) == "number" and msg.tile >= 0 and msg.tile < N then
        local o = readu8(S.map.owner, msg.tile)
        if isFriend(o) then -- last line: never hit an ally / teammate, whatever picked the target
            if os.clock() - (blockedAt[o] or -99) > 10 then
                blockedAt[o] = os.clock()
                log(("blocked %s on ally %s"):format(msg.t, S.names[o] or ("#" .. o)))
            end
            return false
        end
    end
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
    if ups and not S.namesFromClient then
        -- mid-match inject misses "roster": the client's id->name table is the number->string one holding MY name
        -- (the biggest one can be a building-label table: "PORT", "ANTI-NUKE", ...)
        local mine = { [lp.Name] = true, [lp.DisplayName] = true }
        for _, uv in ups do
            if type(uv) == "table" then
                local ok, hit = true, false
                for k, v in uv do
                    if type(k) ~= "number" or type(v) ~= "string" then ok = false break end
                    if mine[v] then hit = true end
                end
                if ok and hit then
                    for k, v in uv do S.names[k] = v end
                    S.namesFromClient = true
                    break
                end
            end
        end
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
-- the client keeps every building in its structures renderer (.byTile[tile] = {ownerId, kind, level, site, ...});
-- my own "structs" listener misses the full list after a mid-match reload, so mirror the client's list each scan
local function syncStructs()
    local byTile
    for _, c in getconnections(State.OnClientEvent) do
        local f = c.Function
        if f and islclosure(f) then
            local ok, ups = pcall(debug.getupvalues, f)
            if ok then
                for _, uv in ups do
                    if type(uv) == "table" and type(rawget(uv, "byTile")) == "table" then byTile = uv.byTile break end
                end
            end
        end
        if byTile then break end
    end
    if not byTile then return false end
    local fresh = {}
    for t, e in byTile do
        if type(t) == "number" and type(e) == "table" and e.ownerId and e.ownerId ~= 0 and not e.site then
            fresh[t] = { tile = t, ownerId = e.ownerId, kind = e.kind or 1, level = e.level or 1 }
        end
    end
    for t, v in S.structs do if v.pending and not fresh[t] then fresh[t] = v end end -- keep my just-ordered anti-nukes
    S.structs = fresh
    return true
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
    pcall(syncStructs)
    local r = { seeds = {}, ecoast = {}, ecoastN = {}, shoreN = 0, coast = {}, coastN = 0, hole = {}, holeD = {}, region = {}, regions = {}, mine = 0, contacts = {}, sample = {}, borderMine = {}, interior = {}, shore = {}, any = {}, anyN = {}, sumx = 0, sumy = 0 }
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
                if #r.seeds < 4000 then r.seeds[#r.seeds + 1] = i elseif math.random(r.shoreN) <= 4000 then r.seeds[math.random(4000)] = i end
            end
        elseif o == 0 and i % 5 == 0 and btest(readu8(ter, i), 64) and passable(ter, i) then -- open coast anywhere (island targets)
            r.coastN += 1
            if #r.coast < 400 then r.coast[#r.coast + 1] = i elseif math.random(r.coastN) <= 400 then r.coast[math.random(400)] = i end
        elseif o ~= 0 and i % 5 == 0 and btest(readu8(ter, i), 64) then -- someone else's coast: boat invasion targets
            local n = (r.ecoastN[o] or 0) + 1
            r.ecoastN[o] = n
            local l = r.ecoast[o]
            if not l then l = {}; r.ecoast[o] = l end
            if #l < 40 then l[#l + 1] = i elseif math.random(n) <= 40 then l[math.random(40)] = i end
            if i % 61 == 0 then local c = (r.anyN[o] or 0) + 1; r.anyN[o] = c; if math.random(c) == 1 then r.any[o] = i end end
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
        table.clear(S.structs); table.clear(S.badTile); S.spawnSent = 0; S.spawnOk = false; table.clear(S.grudge); table.clear(S.nukeGrudge); S.nukedAt = -1e9; S.nukeSeenAt = -1e9; table.clear(S.holes); S.islandOff = nil; S.playStart = nil; S.siege = nil; table.clear(S.udPeak); table.clear(S.udEmbargo); table.clear(S.hist); table.clear(S.askN); S.brain = nil
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
        S.threshold = tonumber(p.threshold) or S.threshold -- tiles needed to win (drops after 30 min)
        S.playable = tonumber(p.contested or p.playableLand) or S.playable
    elseif k == "structs" and type(p) == "table" then
        if full then table.clear(S.structs) end
        for _, v in p do
            if type(v) == "table" and v.tile then
                S.structs[v.tile] = (v.ownerId and v.ownerId ~= 0) and v or nil
            end
        end
    elseif k == "armies" and typeof(p) == "buffer" then
        local list = {}
        for n = 0, buffer.len(p) // 17 - 1 do
            local o = n * 17
            list[#list + 1] = { atk = readu8(p, o + 4), tgt = readu8(p, o + 5), troops = buffer.readu32(p, o + 6) }
        end
        S.armies, S.armiesAt = list, os.clock()
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
-- LOOT: humans keep captured buildings (Config.TIER human RAZES_CAPTURED = false; Economy hands ownerId over),
-- so a weak neighbour's city near where I hit is a free city with its levels
local LOOT = { [KIND.sam] = 20, [KIND.port] = 6 }
local function lootNear(o, at, radius)
    if not at then return 0 end
    local v = 0
    for t, st in S.structs do
        if st.ownerId == o and dist(t, at) <= radius then
            v += (st.kind or 1) == KIND.city and 10 * (st.level or 1) or (LOOT[st.kind] or 5)
        end
    end
    return v
end

-- ============================== brain: one read of the position that every feature obeys ==============================
-- posture SURVIVE / CONTEND / DOMINATE + a troop budget. Home defense need = incoming attacks + a share of the
-- strongest non-allied land neighbour's army (their home troops can come at me any moment).
-- history per player (last ~3 min) -> growth; threat = army x growth x reach, and anyone near the win bar
local function recordHistory(now)
    for _, v in S.players do
        local h = S.hist[v.id]
        if not h then h = {}; S.hist[v.id] = h end
        if #h == 0 or now - h[#h].t >= 10 then
            h[#h + 1] = { t = now, tiles = v.tiles, troops = v.troops }
            while #h > 18 do table.remove(h, 1) end
        end
    end
end
-- land growth per minute as a fraction (0.5 = +50%/min), over up to the last 60 s
local function growth(id)
    local h = S.hist[id]
    if not h or #h < 2 then return 0 end
    local last, first = h[#h], nil
    for i = #h, 1, -1 do if last.t - h[i].t <= 60 then first = h[i] else break end end
    if not first or last.t - first.t < 15 then return 0 end
    return (last.tiles - first.tiles) / math.max(first.tiles, 1) / ((last.t - first.t) / 60)
end
local function winBar()
    local th, pl = S.threshold or 0.9, S.playable or 0
    return th <= 1 and th or (th <= 100 and th / 100 or (pl > 0 and th / pl or 0.9))
end

local function doBrain(r)
    local me, f = S.me, S.fronts or {}
    local prev = S.brain
    local B = { posture = prev and prev.posture or "CONTEND", spare = 0, need = 0 }
    S.brain = B
    if not me or not me.alive then return end
    local now = os.clock()
    recordHistory(now)
    local cap = troopCap()
    local al = allies()
    local inc = 0
    for _, v in f.inc or {} do inc += v.troops or 0 end
    local nbr, nbrT = nil, 0
    for id in r.contacts do
        local v = S.byId[id]
        if id ~= 0 and v and v.alive and not friendly(id, al) and v.troops > nbrT then nbr, nbrT = id, v.troops end
    end
    B.need = math.max(inc * 1.1 + nbrT * CFG.brainNbrShare, cap * CFG.keepCap, me.troops * CFG.keepHome)
    B.spare = math.max(0, me.troops - B.need)

    -- MAIN ENEMY = biggest threat, not biggest land: army x (1 + growth) x reach, and whoever nears the win bar
    local bar, pl = winBar(), math.max(S.playable or 0, 1)
    local main, mainT, first, second = nil, -1, nil, nil
    for _, v in S.players do
        if v.alive then
            if v.id == S.myId or not friendly(v.id, al) then
                if not first or v.tiles > first.tiles then second = first; first = v
                elseif not second or v.tiles > second.tiles then second = v end
            end
            if v.id ~= S.myId and not friendly(v.id, al) then
                local reach = r.contacts[v.id] and 1 or (r.ecoast[v.id] and 0.6 or 0.25)
                local share = v.tiles / pl
                local t = v.troops * (1 + math.clamp(growth(v.id), 0, 1)) * reach -- tiny bots show huge % growth: cap it
                if share >= bar - CFG.denyMargin then t += me.troops * 10 + v.troops end -- about to win: nothing matters more
                if t > mainT then main, mainT = v.id, t end
                if v.id == (prev and prev.main) then B.prevT = t end
            end
        end
    end
    -- sticky: keep the current main enemy unless the new one is clearly (30%+) more dangerous
    if prev and prev.main and B.prevT and main ~= prev.main and mainT < B.prevT * 1.3 then main = prev.main end
    B.main = main
    B.deny = main and S.byId[main] and S.byId[main].tiles / pl >= bar - CFG.denyMargin or false

    -- posture from PRESSURE (what can hit me vs what I have), with hysteresis + minimum dwell
    local pressure = (inc + nbrT * 0.5) / math.max(me.troops, 1)
    local want
    if pressure >= CFG.surviveIn or (B.posture == "SURVIVE" and pressure > CFG.surviveOut) then want = "SURVIVE"
    elseif first and first.id == S.myId and (not second or me.tiles >= second.tiles * 2) then want = "DOMINATE"
    else want = "CONTEND" end
    if want ~= B.posture and now - (S.postureAt or -99) >= CFG.postureDwell then B.posture = want; S.postureAt = now end
    if B.posture == "DOMINATE" then B.rival = second and second.id end
    status.brain = ("%s · pressure %.1fx · main enemy %s%s · home needs %s, spare %s · incoming %s"):format(B.posture, pressure,
        main and (S.names[main] or "?") or "-", B.deny and " (NEAR WIN: deny)" or "", fmtT(B.need), fmtT(B.spare), fmtT(inc))
    if B.posture ~= S.lastPosture then log("brain: posture " .. tostring(S.lastPosture) .. " -> " .. B.posture .. (" (pressure %.1fx)"):format(pressure)); S.lastPosture = B.posture end
    if main ~= S.lastMain then log("brain: main enemy -> " .. (main and (S.names[main] or "?") or "none")); S.lastMain = main end
end
local function surviving() return CFG.brain and S.brain and S.brain.posture == "SURVIVE" end
local function spare() return CFG.brain and S.brain and S.brain.spare or math.huge end

-- nearest crossing: every sampled coast tile of theirs vs every sampled coast tile of mine (<= 40 x 300)
-- TRUE SEA DISTANCE: 8-way flood over water tiles from my coast, capped at islandMaxDist, double-buffered so readers
-- never see a half-filled map. The server launches from my coast tile nearest the landing and pathfinds the shortest
-- sea route (Navy.spawnTile / Navy.path), so picking the landing by real sailing distance = the shortest crossing.
local seaBufs, seaCur = { buffer.create(N * 2), buffer.create(N * 2) }, nil
local function seaFlood(r)
    local m = S.map
    if S.seaBusy or not m or #r.seeds == 0 then return end
    S.seaBusy = true
    local ter = m.terrain
    local buf = seaBufs[seaCur == seaBufs[1] and 2 or 1]
    buffer.fill(buf, 0, 255) -- 0xFFFF = unreached
    local q, head, pushed = {}, 1, 0
    local function push(j, d)
        if buffer.readu16(buf, j * 2) == 65535 and not btest(readu8(ter, j), 128) then
            buffer.writeu16(buf, j * 2, d); q[#q + 1] = j
        end
    end
    for _, t in r.seeds do
        local x, y = t % W, t // W
        for dy = -1, 1 do for dx = -1, 1 do
            local nx, ny = x + dx, y + dy
            if nx >= 0 and nx < W and ny >= 0 and ny < H then push(ny * W + nx, 1) end
        end end
    end
    local maxD = CFG.islandMaxDist
    while head <= #q do
        local i = q[head]; head += 1
        local d = buffer.readu16(buf, i * 2)
        if d < maxD then
            local x, y = i % W, i // W
            for dy = -1, 1 do
                local ny = y + dy
                if ny >= 0 and ny < H then
                    for dx = -1, 1 do
                        local nx = x + dx
                        if nx >= 0 and nx < W and (dx ~= 0 or dy ~= 0) then push(ny * W + nx, d + 1) end
                    end
                end
            end
        end
        if head % 15000 == 0 then task.wait() end
    end
    seaCur, S.seaAt, S.seaBusy, S.seaCells = buf, os.clock(), false, #q
end
-- sailing steps from my coast to a land (coast) tile: its best water neighbour; nil = unreachable by sea
local function seaD(t)
    if not seaCur then return nil end
    local x, y, best = t % W, t // W, nil
    for dy = -1, 1 do for dx = -1, 1 do
        local nx, ny = x + dx, y + dy
        if nx >= 0 and nx < W and ny >= 0 and ny < H then
            local d = buffer.readu16(seaCur, (ny * W + nx) * 2)
            if d ~= 65535 and (not best or d < best) then best = d end
        end
    end end
    return best
end
local function seaFresh() return CFG.seaPath and S.seaAt and os.clock() - S.seaAt < 30 end

local function crossing(r, list, maxD)
    local t, d
    if seaFresh() then -- real sailing distance; unreachable waters drop out on their own
        for _, c in list do
            local dd = seaD(c)
            if dd and dd <= maxD and (not d or dd < d) then t, d = c, dd end
        end
        return t, d
    end
    for _, c in list do
        for _, m in r.shore do
            local dd = dist(m, c)
            if dd <= maxD and (not d or dd < d) then t, d = c, dd end
        end
    end
    return t, d
end

local function doFronts(r)
    local me, f = S.me, S.fronts
    if not me or not f or not me.alive then return end
    local cap = troopCap()
    local fill = me.troops / cap
    local out = f.out or {}
    local fronted = {}
    for _, v in out do fronted[v.id] = true end
    status.expand = ("troops %s / %s (%.0f%%) · fronts %d out / %d in · land %d tiles"):format(fmtT(me.troops), fmtT(cap), fill * 100, #out, #(f.inc or {}), me.tiles)
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
                if seaFresh() then
                    local d = seaD(i)
                    if d and d > 3 and d <= CFG.islandMaxDist and (not bd or d < bd) then best, bd = i, d end
                else
                    for k = 1, 16 do
                        local d = dist(r.shore[math.random(#r.shore)], i)
                        if d > 3 and d <= CFG.islandMaxDist and (not bd or d < bd) then best, bd = i, d end
                    end
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

    -- SEA SIEGE: an enemy only reachable by sea whose army beats one boat. Boats carry troops/5 each, max 3 at sea,
    -- and my attacks on the same player MERGE when they land (Sim launchAttack), so: charge troops, (nuke), then send
    -- a salvo of 3 boats at ONE landing tile (1 - 0.8^3 = 49% of my army) and keep reinforcing that beachhead.
    local sg = S.siege
    local cheaperGrowth = r.sample[0] ~= nil
    if not cheaperGrowth then
        for o in r.ecoast do local v = S.byId[o]; if v and v.alive and v.isBot and v.troops * CFG.boatEdge <= me.troops * CFG.cheapFrac then cheaperGrowth = true break end end
    end
    if CFG.siege and S.map and #r.shore > 0 and not surviving() and (S.siege or not cheaperGrowth) then
        local al3 = allies()
        if not sg then
            local best, bestT, bestD
            for o, list in r.ecoast do
                local v = S.byId[o]
                if v and v.alive and o ~= S.myId and not r.contacts[o] and not friendly(o, al3) and (not v.isBot or CFG.siegeBots) and now0 >= (S.siegeSkip[o] or 0) then
                    local t, d = crossing(r, list, CFG.islandMaxDist)
                    local river = d and d <= CFG.riverDist
                    local need = river and CFG.boatEdge * CFG.riverEdge or CFG.siegeTrigger -- river: only if chained boats can't win either
                    local reachable = troopCap() * (1 - 0.8 ^ 3) >= v.troops * CFG.siegeEdge -- a full-strength salvo could win at all
                    if t and reachable and me.troops / 5 < v.troops * need then -- one boat can't win comfortably: overwhelm with a salvo instead of trickling
                        if t and (not bestT or v.tiles > S.byId[best].tiles) then best, bestT, bestD = o, t, d end -- biggest island rival first
                    end
                end
            end
            if best then
                sg = { id = best, tile = bestT, stage = "charge", at = now0 }
                S.siege = sg
                log(("sea siege on %s: landing at %d (%.0f tiles of sea)"):format(S.names[best] or ("#" .. best), bestT, bestD))
            end
        end
        if sg then
            local v = S.byId[sg.id]
            local owner = readu8(S.map.owner, sg.tile)
            if not v or not v.alive or isFriend(sg.id) then
                log("sea siege on " .. (S.names[sg.id] or "?") .. " ended (" .. (v and v.alive and "now an ally" or "eliminated") .. ")")
                S.siege = nil
            elseif r.contacts[sg.id] and r.sample[sg.id] then
                -- BEACHHEAD: I border them now. Feed it by land every 4 s (attacks on the same player merge),
                -- sized by the HUD ratio, never below my keep-home floor; normal combat would leave it to die
                if sg.stage ~= "push" then sg.stage = "push"; log("sea siege: beachhead on " .. (S.names[sg.id] or "?") .. ", pushing") end
                local spare_ = math.min(me.troops - math.max(me.troops * CFG.keepHome, cap * CFG.keepCap), spare())
                local send_ = math.min(me.troops * ratio(CFG.attackRatio), spare_)
                if send_ < v.troops * CFG.pushEdge then -- feeding a beachhead into a much bigger army is pure bleed
                    log(("sea siege on %s abandoned: push %s vs their %s"):format(S.names[sg.id] or "?", fmtT(send_), fmtT(v.troops)))
                    S.siege, send_ = nil, 0
                    S.siegeSkip[sg.id] = now0 + 120
                end
                status.combat = ("SEA SIEGE vs %s: pushing the beachhead (their army %s)"):format(S.names[sg.id] or "?", fmtT(v.troops))
                if send_ >= (Config.MIN_ATTACK_TROOPS or 250) and now0 - (sg.last or 0) >= 4 then
                    sg.last = now0
                    S.lastTile = r.sample[sg.id]
                    if send({ t = "attack", tile = r.sample[sg.id], ratio = math.clamp(send_ / me.troops, Config.MIN_ATTACK_RATIO or 0.05, 1) }, "siegeP") then stats.attacks += 1 end
                end
            else
                if sg.stage == "push" then -- beachhead lost: recharge before the next wave
                    log("sea siege: beachhead on " .. (S.names[sg.id] or "?") .. " lost, recharging")
                    sg.stage, sg.at, sg.lastSalvo = "charge", now0, sg.lastSalvo or now0
                end
                if (S.boatBad[sg.id] or 0) > now0 then S.boatBad[sg.id] = nil; owner = -1 end -- last landing refused (no beach / route)
                if owner ~= sg.id then -- landing tile changed hands or was refused: pick another of their coast tiles
                    local l = r.ecoast[sg.id]
                    if l and #l > 0 then sg.tile = l[math.random(#l)] end
                end
                local salvo = me.troops * (1 - 0.8 ^ 3)
                local ready = salvo >= v.troops * CFG.siegeEdge and now0 - (sg.lastSalvo or -99) >= CFG.siegeGap -- the 3 boats must beat them (fill alone launched losing salvos)
                if sg.stage == "charge" then
                    status.combat = ("SEA SIEGE vs %s: charging %d%% / %d%% (salvo %s vs their %s)"):format(S.names[sg.id] or "?",
                        math.floor(fill * 100), math.floor(CFG.siegeFill * 100), fmtT(salvo), fmtT(v.troops))
                    if ready then
                        sg.stage, sg.at = "salvo", now0
                        if CFG.siegeNuke then S.siegeNukeWanted = sg.id end -- doEconomy fires one at their best spot
                    end
                elseif sg.stage == "salvo" then
                    -- give the nuke a moment, then 3 boats ~0.35 s apart (server launches 1 boat per 0.1 s tick)
                    if now0 - sg.at >= (CFG.siegeNuke and 2 or 0) then
                        local sent = 0
                        for n = 1, 3 do
                            S.lastTile, S.boatSent, S.boatOwner, S.lastDenied = sg.tile, os.clock(), sg.id, "-"
                            if send({ t = "attack", tile = sg.tile, ratio = ratio(CFG.attackRatio) }, "siege" .. n .. ":" .. math.floor(now0)) then sent += 1 end
                            task.wait(0.35)
                        end
                        stats.attacks += sent
                        log(("sea siege: salvo of %d boats -> %s (~%s troops)"):format(sent, S.names[sg.id] or "?", fmtT(salvo)))
                        sg.stage, sg.at, sg.lastSalvo = "reinforce", now0, now0
                    end
                elseif sg.stage == "reinforce" then
                    status.combat = ("SEA SIEGE vs %s: reinforcing the landing (their army %s)"):format(S.names[sg.id] or "?", fmtT(v.troops))
                    -- a boat slot frees as boats land; keep feeding the same beachhead while I have troops to spare
                    if fill >= CFG.siegeKeep and now0 - (sg.last or 0) >= 4 then
                        sg.last = now0
                        S.lastTile, S.boatSent, S.boatOwner, S.lastDenied = sg.tile, now0, sg.id, "-"
                        send({ t = "attack", tile = sg.tile, ratio = ratio(CFG.attackRatio) }, "siegeR")
                    end
                    if now0 - sg.at > 90 then sg.stage, sg.at = "charge", now0 end -- wave spent: recharge for the next salvo
                end
            end
        end
    end

    -- BOAT INVASIONS: attack a neighbour across water. A boat carries troops/5 (ratio ignored) and fights the defender's
    -- WHOLE army (Sim attack loss), so only take on someone that boat can beat. Shares the 3-boat cap with islands.
    if CFG.boatAttack and S.map and #r.shore > 0 and now0 >= (S.boatAt or 0) and not (S.siege and S.siege.stage == "charge") then
        local boat = me.troops / 5
        local al2 = allies()
        local best, bestScore, bestTile, bestD
        for o, list in r.ecoast do
            local v = S.byId[o]
            local grudge = (S.grudge[o] or 0) > now0
            if v and v.alive and o ~= S.myId and not r.contacts[o] and not friendly(o, al2) and now0 >= (S.boatBad[o] or 0)
                and not (S.siege and S.siege.id == o) -- the siege is handling them
                and ((v.isBot and CFG.hitBots) or (not v.isBot and CFG.hitPlayers)) and not blacklisted(o) then
                -- cheap grab: their whole army is a rounding error of mine -> ignore the fill gate (bots even while surviving)
                local cheap = v.troops * CFG.boatEdge <= me.troops * CFG.cheapFrac
                local gateOk = cheap and (v.isBot or not surviving()) or (not surviving() and fill >= CFG.boatMin)
                local t, d
                if gateOk then t, d = crossing(r, list, CFG.islandMaxDist) end
                -- boats sail 1 tile per tick: across a river the next boat lands ~1 s behind the last and merges
                -- into the same attack, so a much thinner edge holds; on open sea a lone boat bleeds out
                local river = d and d <= CFG.riverDist
                if t and boat >= v.troops * CFG.boatEdge * (river and CFG.riverEdge or 1) then
                    -- thin armies spread over lots of land are the cheapest to take; grudges and bots first
                    local loot = lootNear(o, t, CFG.lootRadius)
                    local score = (v.troops / math.max(v.tiles, 1) * (grudge and 0.3 or 1) * (v.isBot and 0.7 or 1) + d * 0.5) / (1 + loot * CFG.lootWeight)
                    if not bestScore or score < bestScore then best, bestScore, bestTile, bestD = o, score, t, d end
                end
            end
        end
        S.boatAt = now0 + ((bestD and bestD <= CFG.riverDist) and CFG.riverEvery or CFG.boatEvery)
        if best then
            S.lastTile, S.boatSent, S.boatOwner, S.lastDenied = bestTile, now0, best, "-"
            if send({ t = "attack", tile = bestTile, ratio = ratio(CFG.attackRatio) }, "boat:" .. best) then
                stats.attacks += 1
                status.combat = ((bestD <= CFG.riverDist and "river crossing" or "boat invasion") .. " -> %s (%s troops, %.0f tiles of sea, boat %s)"):format(S.names[best] or ("#" .. best), fmtT(S.byId[best].troops), bestD, fmtT(boat))
                log(status.combat)
            end
        end
    end
    if S.boatSent and now0 - S.boatSent < 3 then
        local d = S.lastDenied
        if d == "nobeach" or d == "nosearoute" or d == "nocoast" or d == "immunity" or d == "allied" or d == "ally" then
            S.boatBad[S.boatOwner] = now0 + 90; S.boatSent = nil -- that coast can't be reached / attacked: try someone else
        elseif d == "toomanytransportboats" or d == "busy" then S.boatAt = now0 + 20; S.boatSent = nil end
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
        local sendTroops = math.min(me.troops * ratio(CFG.attackRatio), spare())
        local best, bestScore, why
        for id in r.contacts do
            local v = S.byId[id]
            local grudge = S.grudge[id] and S.grudge[id] > now
            if id ~= 0 and v and v.alive and not fronted[id] and not friendly(id, al) and (grudge or not onlyGrudge)
                and not (surviving() and not v.isBot) -- surviving: no new wars with players
                and ((v.isBot and CFG.hitBots) or (not v.isBot and CFG.hitPlayers) or (grudge and CFG.revenge))
                -- Sim.attackLoss: attacker losses scale with the defender's WHOLE army / attack troops, so compare against all of it
                and sendTroops >= v.troops * (grudge and CFG.revengeEdge or CFG.edge)
                -- revenge only when I'm stronger overall; otherwise troops stay home (my defense = my total troops)
                and (not grudge or me.troops >= v.troops * CFG.revengeStronger) then -- both paths: never chase a stronger grudge
                -- lower score = better: weakest first, grudges/traitors/finishable players pulled to the front
                local loot = lootNear(id, r.sample[id], CFG.lootRadius)
                local score = v.troops / (1 + loot * CFG.lootWeight)
                local tag = loot > 0 and ("loot " .. loot) or "weakest"
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
            status.combat = ("%s: %s (%s troops) @%d%%"):format(why, S.names[id] or ("#" .. id), fmtT(S.byId[id].troops), math.floor(ratio * 100 + 0.5))
            log(status.combat)
            fronted[id] = true
            return true
        end
    end

    -- COUNTER (Sim.launchAttack, OPPOSING_ATTACKS_CANCEL): my attack on someone attacking me first cancels their incoming
    -- attack 1:1, the rest invades their home. Their home troops (players.troops) already exclude what they sent at me.
    S.threat = nil
    local keep = math.max(me.troops * CFG.keepHome, cap * CFG.keepCap) -- floor: never invade myself down to ~0% of cap
    if CFG.brain and S.brain and S.brain.main then
        for _, v in f.inc or {} do
            local a = S.byId[v.id]
            if a and not a.isBot and v.id ~= S.brain.main and now - (reqAt[v.id] or -99) > 35 then
                reqAt[v.id] = now
                if send({ t = "ally", id = v.id }) then log(("side war with %s: asking for peace (main enemy is %s)"):format(S.names[v.id] or "?", S.names[S.brain.main] or "?")) end
            end
        end
    end
    for _, v in f.inc or {} do
        local a = S.byId[v.id]
        local incT = v.troops or 0
        if a and v.id ~= 0 and a.alive and not friendly(v.id, al) and r.sample[v.id] then
            local cancel = incT * 1.05
            local punish = cancel + a.troops * CFG.revengeEdge
            local spare = me.troops - keep
            local send, why
            local sideWar = CFG.brain and S.brain and S.brain.main and S.brain.main ~= v.id -- someone else is the real threat
            if CFG.counterPunish and (not sideWar or a.troops <= spare * 0.5) and spare >= punish then send, why = punish, "counter: cancel + invade" -- side war: only if their home is nearly empty
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
        status.combat = ("LAST STAND vs %s (attack %s, my home %s)"):format(S.names[S.threat.id] or ("#" .. S.threat.id), fmtT(S.threat.inc), fmtT(me.troops))
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

    if S.siege and S.siege.stage == "charge" and CFG.siegeHold then return end -- saving troops for the salvo
    -- LEECH: allies are pouring troops into someone I border -> they fight on two fronts; join in with a thinner edge
    if CFG.leech and S.armies and now - (S.armiesAt or 0) < 10 and #out < 4 and not surviving() then
        local hit, by = {}, {}
        for _, a in S.armies do
            if a.tgt ~= 0 and a.tgt ~= S.myId and a.atk ~= S.myId and (friendly(a.atk, al) or CFG.leechAny) and not friendly(a.tgt, al) then
                hit[a.tgt] = (hit[a.tgt] or 0) + a.troops
                by[a.tgt] = a.atk
            end
        end
        local best, bestP
        for id, t in hit do
            local v = S.byId[id]
            if v and v.alive and r.sample[id] and not fronted[id] and ((v.isBot and CFG.hitBots) or (not v.isBot and CFG.hitPlayers)) then
                local p = t / math.max(v.troops, 1) -- how hard they're being hit vs their home army
                if p >= CFG.leechMin and (not bestP or p > bestP) then best, bestP = id, p end
            end
        end
        if best and now - (S.leechAt or -99) >= 4 then
            local v = S.byId[best]
            local sendT = math.min(me.troops * ratio(CFG.attackRatio), spare())
            if sendT >= (Config.MIN_ATTACK_TROOPS or 250) and sendT >= v.troops * CFG.leechEdge then
                S.leechAt = now
                if strike(best, ("leech (%s is hitting them %.1fx)"):format(S.names[by[best]] or "ally", bestP), math.clamp(sendT / me.troops, Config.MIN_ATTACK_RATIO or 0.05, 1)) then
                    out = table.clone(out); out[#out + 1] = { id = best }
                end
            end
        end
    end

    if not CFG.attack then if not status.combat:find("^revenge") then status.combat = "auto attack off" end return end
    if CFG.holdWhenHit then
        for _, v in f.inc or {} do
            local a = S.byId[v.id]
            if a and a.troops >= me.troops * 0.7 then status.combat = ("holding troops: %s (%s) is attacking"):format(S.names[v.id] or ("#" .. v.id), fmtT(a.troops)); return end
        end
    end
    if #out >= math.min(CFG.maxFronts, 4) then status.combat = "front limit"; return end
    if fill < CFG.attackMin then status.combat = ("saving troops (%.0f%% < %.0f%%)"):format(fill * 100, CFG.attackMin * 100); return end
    local best, why = pickTarget(false)
    if best then strike(best, why, math.min(ratio(CFG.attackRatio), spare() / math.max(me.troops, 1))) else status.combat = "no valid target" end
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
            if not top and CFG.udDefense and S.underdog and r.borderMine[S.underdog.id] then top = S.underdog.id end -- brace for the leader
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
-- growth per tick ~ (1 - troops/cap): cap only matters when troops are near it
local function cityPriority()
    local me = S.me
    if not me then return "normal", 0 end
    local fill = me.troops / math.max(troopCap(), 1)
    if fill >= CFG.cityFillHigh then return "high", fill end
    if fill <= CFG.cityFillLow then return "low", fill end
    return "normal", fill
end
local function wantBuild(kind)
    if not CFG["b_" .. kind] then return false end
    if os.clock() - (builtAt[kind] or -99) < 3 then return false end -- structs packet lags; don't overshoot the max
    if BUILD_PASS[kind] and not hasPass(BUILD_PASS[kind]) then return false end
    local mine = #myStructs(KIND[kind])
    if kind == "city" then
        local lv = S.fronts and S.fronts.levels or 0
        return lv < CFG.max_city * (Config.CITY_MAX_LEVEL or 10) and (mine < CFG.max_city or CFG.upgradeCities)
    end
    local udBorder = CFG.udDefense and S.underdog and S.scan and S.scan.contacts[S.underdog.id]
    if kind == "defense" and #(S.fronts and S.fronts.inc or {}) == 0 and not udBorder then return false end
    if kind == "defense" and S.me then -- skip fronts I can't hold: the attacker keeps the post
        local incT = 0
        for _, v in (S.fronts and S.fronts.inc or {}) do incT += v.troops or 0 end
        if incT > S.me.troops * CFG.holdable then return false end
    end
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
        local reach = nk.reach or nk.r
        local theirs, mine, sams = {}, {}, {}
        for t, s in S.structs do
            if s.ownerId == who then theirs[#theirs + 1] = t end
            if s.ownerId == S.myId then mine[#mine + 1] = t end
            if s.kind == KIND.sam and s.ownerId ~= S.myId then sams[#sams + 1] = t end
        end
        local own = S.map and S.map.owner
        local function safe(c)
            for _, t in mine do if dist(t, c) < reach + 2 then return false end end
            for t, st in S.structs do if isFriend(st.ownerId) and dist(t, c) < reach + 2 then return false end end
            if own then -- sample the blast disc for allied land
                local cx, cy = c % W, c // W
                for _, rr in { reach, nk.r, nk.r * 0.6, nk.r * 0.3 } do
                    for a = 0, 15 do
                        local x = math.floor(cx + rr * math.cos(a * math.pi / 8) + 0.5)
                        local y = math.floor(cy + rr * math.sin(a * math.pi / 8) + 0.5)
                        if x >= 0 and x < W and y >= 0 and y < H and isFriend(readu8(own, y * W + x)) then return false end
                    end
                end
            end
            for _, list in r.borderMine do for _, t in list do if dist(t, c) < reach + 5 then return false end end end
            if CFG.avoidSam then for _, t in sams do if dist(t, c) < 80 then return false end end end
            return true
        end
        local best, bestScore, bestLv = nil, 0, 0
        for _, c in theirs do
            local score, lv = 0, 0
            for _, t in theirs do
                local d = dist(t, c)
                local w = d < nk.r and 1 or (nk.ring and d <= reach and nk.ring or 0) -- Scattershot ring counts at its odds
                if w > 0 then
                    local s = S.structs[t]
                    local k = s.kind or 1
                    if k == KIND.city then score += 10 * (s.level or 1) * w; lv += (s.level or 1) * w
                    elseif k == KIND.sam or k == KIND.railgun or k == KIND.airfield then score += 8 * w
                    else score += 2 * w end
                end
            end
            if score > bestScore and lv >= (minLv or 0) and safe(c) then best, bestScore, bestLv = c, score, lv end
        end
        if best then return best, ("%.0f city levels"):format(bestLv), bestScore end
        if allowLand then
            local t = r.any[who] or r.sample[who]
            if t and safe(t) then return t, "their land (no known cities)", 1 end
        end
    end

    local function fireNuke(kindName, who, minGold, why, allowLand, minLv)
        local free = (f.freeNukes or 0) > 0
        local pre
        if kindName == "Best owned" then
            -- size the bomb to the target: tight cluster -> Atom covers it cheaply; spread cities -> Mega's 60 radius;
            -- clusters around a centre -> Scattershot's ring. Pick the most value destroyed per gold (a free nuke: most value).
            local bestK, bestEff
            for _, k in { "Atom", "Mega", "Scattershot" } do
                local n = NUKE[k]
                if (not n.pass or hasPass(n.pass)) and (free or gold - CFG.reserve >= math.max(n.cost, minGold)) then
                    local t, what, score = nukeSpot(who, n, allowLand, minLv)
                    if t then
                        local eff = free and score or score / (n.cost / 1e6)
                        if why == "deny win" then -- knocking them under the bar: land wiped per gold (Mega 3.6K r^2 / 2.5M wins)
                            eff = (n.r ^ 2 + (n.ring and 5 * 18 ^ 2 or 0)) / (free and 1 or n.cost / 1e6)
                        end
                        if not bestEff or eff > bestEff * CFG.nukeUpsize then bestK, bestEff, pre = k, eff, { t, what } end
                    end
                end
            end
            kindName = bestK or "Atom"
        end
        local nk = NUKE[kindName]
        if not nk or (nk.pass and not hasPass(nk.pass)) then return false end
        if not free and gold - CFG.reserve < math.max(nk.cost, minGold) then
            status.weapons = ("%s: saving for %s nuke (%s / %s)"):format(why, kindName, fmt(gold), fmt(nk.cost)); return false
        end
        local target, what
        if pre then target, what = pre[1], pre[2] else target, what = nukeSpot(who, nk, allowLand, minLv) end
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
        local holdable = (th.inc or 0) <= me.troops * CFG.holdable -- a post on a front I'm losing is a gift (RAZES_CAPTURED = false)
        if not holdable then status.build = "last stand: no post, that front can't be held (it would be captured)" end
        if holdable and bm and cost and gold >= cost and now - (S.lsPostAt or -99) >= 20 and #myStructs(KIND.defense) < CFG.max_defense + 2 then
            S.lsPostAt = now
            local tile = pick(bm)
            if tile then
                S.lastTile = tile
                if send({ t = "build", tile = tile, kind = KIND.defense }) then stats.builds += 1; log("last stand: defense post at " .. tile); gold -= cost end
            end
        end
    end
    if S.siegeNukeWanted then
        local who = S.siegeNukeWanted
        S.siegeNukeWanted = nil
        fireNuke(CFG.siegeNukeKind, who, 0, "siege", true)
    end
    if CFG.revengeNuke then
        local who, latest = nil, 0
        local B = CFG.brain and S.brain
        for id, t in S.nukeGrudge do
            local v = S.byId[id]
            -- while surviving / denying, only the main enemy is worth a nuke
            local worth = not B or not (B.posture == "SURVIVE" or B.deny) or id == B.main
            if t > now and v and v.alive and worth and not friendly(id, allies()) and t > latest then who, latest = id, t end
        end
        if who and fireNuke(CFG.revengeNukeKind, who, 0, "revenge", false, CFG.revengeMinLv) and CFG.revengeOnce then S.nukeGrudge[who] = nil end
    end
    local freeNuke = CFG.useFree and (f.freeNukes or 0) > 0 -- product nukes (starter packs / railgun bundle) cost no gold
    local ud = CFG.udNuke and not surviving() and S.underdog
    if ud then
        local cd = ud.danger and CFG.udDenyCd or CFG.nukeCooldown
        if (CFG.nuke or freeNuke or ud.danger) and now - (S.lastAutoNuke or -1e9) >= cd
            and fireNuke(CFG.nukeKind, ud.id, ud.danger and 0 or CFG.nukeMinGold, ud.danger and "deny win" or "underdog", true) then
            S.lastAutoNuke = now
        end
    end
    if not ud and not surviving() and (CFG.nuke or freeNuke) and now - (S.lastAutoNuke or -1e9) >= CFG.nukeCooldown then
        local al, best, bestTiles = allies(), nil, 0
        for _, v in S.players do
            local grudge = (S.grudge[v.id] or 0) > now
            -- don't poke a stronger player who isn't already fighting me (they retaliate)
            local provoke = v.troops > me.troops and not grudge and not CFG.nukeStronger
            if v.id ~= S.myId and v.alive and not friendly(v.id, al) and not (v.isBot and CFG.nukeSkipBots) and not provoke and v.tiles > bestTiles then best, bestTiles = v.id, v.tiles end
        end
        local prio, fill = cityPriority()
        local cityCost = buildCost("city")
        local nukeCost = (NUKE[CFG.nukeKind] or NUKE.Atom).cost
        if best and not freeNuke and CFG.cityWeight and prio == "high" and CFG.b_city and (f.levels or 0) < CFG.max_city * (Config.CITY_MAX_LEVEL or 10) and cityCost and gold - nukeCost < cityCost then
            status.weapons = ("auto nuke on hold: cities first (troops at %d%% of cap)"):format(math.floor(fill * 100))
        elseif best and fireNuke(CFG.nukeKind, best, CFG.nukeMinGold, "auto", true) then S.lastAutoNuke = now end
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
    -- DENY RESERVE: the main enemy is near the win bar -> gold is for the nuke that knocks them under it
    if CFG.brain and S.brain and S.brain.deny and CFG.denyReserve then
        local nk = NUKE.Atom.cost
        if gold < nk then status.build = ("holding gold to deny %s's win (%s / %s)"):format(S.names[S.brain.main] or "?", fmt(gold), fmt(nk)); return end
        gold -= nk -- build only with what's above one nuke
    end
    local prio, fill = cityPriority()
    for _, kind in ORDER do
        if wantBuild(kind) then
            local cost = buildCost(kind)
            if cost and kind == "city" and CFG.cityWeight and prio == "low" and cost > 0 and gold - CFG.reserve < cost * CFG.citySpare then
                status.build = ("cities waiting: troops only at %d%% of cap, more cap won't help yet"):format(math.floor(fill * 100))
                cost = nil -- skip to the next building type
            end
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
                        for u, st in S.structs do if isFriend(st.ownerId) and dist(t, u) <= radius then v = -1 break end end -- splash on an ally
                        if v >= 0 and (not bv or v > bv) then best, bv = t, v end
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

-- ============================== underdog (someone is running away with the game) ==============================
-- Tools the rules give a losing player:
--  * nukes turn the leader's tiles back into open land (Nukes.lua blast), so a leader near the win bar can be knocked under it
--  * players.troops is HOME troops: when the leader commits big attacks elsewhere their home is thin -> hit it then
--  * diplomacy: ally everyone else, "target" the leader for allies (10 s mark, 15 s cooldown), embargo their trade
--  * city clusters are their army cap; defense posts on their border before they come
local function doUnderdog(r)
    S.underdog = nil
    local me = S.me
    if not CFG.underdog or not me or not me.alive then status.underdog = CFG.underdog and "-" or "off"; return end
    local al = allies()
    local lead = CFG.brain and S.brain and S.brain.main and S.byId[S.brain.main] or nil
    if not lead then
        for _, v in S.players do
            if v.alive and v.id ~= S.myId and not friendly(v.id, al) and (not lead or v.tiles > lead.tiles) then lead = v end
        end
    end
    if not lead or lead.tiles < me.tiles * CFG.udRatio then
        status.underdog = lead and ("not needed: biggest rival %s has %.1fx your land"):format(S.names[lead.id] or "?", lead.tiles / math.max(me.tiles, 1)) or "no rival"
        return
    end
    local playable = S.playable or 0
    local share = playable > 0 and lead.tiles / playable or 0
    local th = S.threshold or 0.9
    local bar = th <= 1 and th or (th <= 100 and th / 100 or (playable > 0 and th / playable or 0.9))
    local ud = { id = lead.id, share = share, bar = bar, danger = share >= bar - CFG.udDanger }
    S.underdog = ud
    local now = os.clock()
    local name = S.names[lead.id] or ("#" .. lead.id)

    -- their home army's recent peak: a big drop means their troops are out attacking someone
    local pk = S.udPeak[lead.id]
    if not pk or now - pk.at > 60 or lead.troops > pk.v then pk = { v = lead.troops, at = now }; S.udPeak[lead.id] = pk end
    ud.opening = lead.troops < pk.v * CFG.udOpening

    if CFG.udDiplo then
        if now - (S.udTargetAt or -99) > 16 then S.udTargetAt = now; send({ t = "target", id = lead.id }, "udtarget") end
        if not S.udEmbargo[lead.id] then
            S.udEmbargo[lead.id] = true
            if send({ t = "embargo", id = lead.id, stop = false }, "udembargo") then log("underdog: embargo on " .. name) end
        end
        local outreq = setOf(S.diplo and S.diplo.outreq)
        for _, v in S.players do
            if v.alive and not v.isBot and v.id ~= S.myId and v.id ~= lead.id and not al[v.id] and not outreq[v.id]
                and not blacklisted(v.id) and now - (reqAt[v.id] or -99) > 35 and (S.askN[v.id] or 0) < 2 then
                S.askN[v.id] = (S.askN[v.id] or 0) + 1
                reqAt[v.id] = now
                if send({ t = "ally", id = v.id }) then log(("underdog: asked %s to ally against %s"):format(S.names[v.id] or "?", name)) end
            end
        end
    end

    -- OPENING: their home is thin -> hit it with a real army, but never below my keep-home floor
    if CFG.udStrike and not surviving() and ud.opening and r.contacts[lead.id] and r.sample[lead.id] and now - (S.udStrikeAt or -99) > 8 then
        local cap = troopCap()
        local spare = me.troops - math.max(me.troops * CFG.keepHome, cap * CFG.keepCap)
        local sendT = math.min(spare, me.troops * CFG.udStrikeRatio, (CFG.brain and S.brain) and S.brain.spare or math.huge)
        if sendT >= (Config.MIN_ATTACK_TROOPS or 250) and sendT >= lead.troops * CFG.udEdge then
            S.udStrikeAt = now
            S.lastTile = r.sample[lead.id]
            if send({ t = "attack", tile = r.sample[lead.id], ratio = math.clamp(sendT / me.troops, Config.MIN_ATTACK_RATIO or 0.05, 1) }, "udstrike") then
                stats.attacks += 1
                log(("underdog: %s's army is out (%s, peak %s) -> hitting home with %s"):format(name, fmtT(lead.troops), fmtT(pk.v), fmtT(sendT)))
            end
        end
    end
    status.underdog = ("UNDERDOG vs %s: they hold %.1f%% (win bar %.0f%%)%s%s"):format(name, share * 100, bar * 100,
        ud.danger and " · DENYING THE WIN" or "", ud.opening and " · their army is out" or "")
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
            if CFG.record and S.phase == "playing" and os.clock() - (S.recAt or -99) >= 30 then
                S.recAt = os.clock()
                pcall(function()
                    local f = ("PixelConquest/match_%s.csv"):format(game.JobId:sub(1, 8))
                    if not isfile(f) then writefile(f, "time,player,bot,tiles,troops,cityLv,posture,main\n") end
                    local lv = {}
                    for _, st in S.structs do if (st.kind or 1) == KIND.city then lv[st.ownerId] = (lv[st.ownerId] or 0) + (st.level or 1) end end
                    local list = table.clone(S.players)
                    table.sort(list, function(a, b) return a.tiles > b.tiles end)
                    local rows = {}
                    for i = 1, math.min(#list, 8) do
                        local v = list[i]
                        rows[#rows + 1] = ("%s,%s,%s,%d,%d,%d,%s,%s"):format(os.date("%H:%M:%S"), (S.names[v.id] or v.id), v.isBot and 1 or 0, v.tiles, math.floor(v.troops / 10), lv[v.id] or 0,
                            S.brain and S.brain.posture or "-", S.brain and S.brain.main and (S.names[S.brain.main] or "?") or "-")
                    end
                    if me and me.tiles > 0 then rows[#rows + 1] = ("%s,ME:%s,0,%d,%d,%d,,"):format(os.date("%H:%M:%S"), S.names[S.myId] or "me", me.tiles, math.floor(me.troops / 10), lv[S.myId] or 0) end
                    appendfile(f, table.concat(rows, "\n") .. "\n")
                end)
            end
            if S.phase ~= "spawn" and me and me.alive and me.tiles > 0 then
                local r = scanMap()
                if r then
                    S.scan = r
                    if CFG.seaPath and not S.seaBusy and os.clock() - (S.seaRun or -99) >= CFG.seaEvery then
                        S.seaRun = os.clock()
                        task.spawn(function() local ok, e = pcall(seaFlood, r); if not ok then S.seaBusy = false; log("sea flood error: " .. tostring(e)) end end)
                    end
                    guard("brain", doBrain, r)
                    guard("underdog", doUnderdog, r)
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
    end)(), Footer = "Pixel Conquest · v3.3 · brain · expand · attack · defend · build · weapons",
    Size = UDim2.fromOffset(704, 824), -- default window size (user pick)
    Center = true, AutoShow = true, ToggleKeybind = Enum.KeyCode.RightControl,
})
local Tabs = {
    Overview = Window:AddTab("Overview", "layout-dashboard"), Brain = Window:AddTab("Brain", "brain"),
    Expand = Window:AddTab("Expand", "map"), Attack = Window:AddTab("Attack", "swords"), Defend = Window:AddTab("Defend", "shield"),
    Build = Window:AddTab("Build", "hammer"), Weapons = Window:AddTab("Weapons", "radiation"), Diplo = Window:AddTab("Diplomacy", "handshake"),
    Lobby = Window:AddTab("Lobby & Passes", "repeat"), Settings = Window:AddTab("Settings", "settings"),
}
local function set(k) return function(v) CFG[k] = v end end
local function pct(k) return function(v) CFG[k] = v / 100 end end
-- compact builders: same option ids as before, so saved configs keep loading
local function T(b, id, text, key, tip) return b:AddToggle(id, { Text = text, Tooltip = tip, Default = CFG[key], Callback = set(key) }) end
local function P(b, id, text, key, lo, hi, tip) return b:AddSlider(id, { Text = text, Tooltip = tip, Default = math.floor(CFG[key] * 100 + 0.5), Min = lo, Max = hi, Rounding = 0, Callback = pct(key) }) end
local function Nm(b, id, text, key, lo, hi, rnd, tip) return b:AddSlider(id, { Text = text, Tooltip = tip, Default = CFG[key], Min = lo, Max = hi, Rounding = rnd or 0, Callback = set(key) }) end
local function K(b, id, text, key, hi, tip) return b:AddSlider(id, { Text = text, Tooltip = tip, Default = math.floor((CFG[key] or 0) / 1000), Min = 0, Max = hi, Rounding = 0, Callback = function(v) CFG[key] = v * 1000 end }) end
local NUKES = { "Best owned", "Atom", "Mega", "Scattershot" }
local function Dd(b, id, text, key, values, tip) return b:AddDropdown(id, { Text = text, Tooltip = tip, Values = values, Default = CFG[key], Callback = set(key) }) end

-- ============ OVERVIEW: what the brain sees + the big switches ============
local OB = Tabs.Overview:AddLeftGroupbox("Brain", "brain")
local brainLabel = OB:AddLabel("-", true)
local udLabel = OB:AddLabel("-", true)
local OS = Tabs.Overview:AddLeftGroupbox("Autopilot", "power")
T(OS, "PC_Brain", "Brain (posture + budget)", "brain", "Reads the whole position first; every feature obeys it")
T(OS, "PC_Expand", "Expand", "expand")
T(OS, "PC_Attack", "Attack", "attack", "Land attacks on the best target (boats and siege are on the Attack tab)")
T(OS, "PC_Build", "Build", "build")
T(OS, "PC_Nuke", "Auto nukes", "nuke")
T(OS, "PC_SamAuto", "Auto anti-nuke", "samAuto")
T(OS, "PC_Accept", "Accept alliances", "accept")
T(OS, "PC_Queue", "Auto queue (lobby)", "queue")
local OP = Tabs.Overview:AddRightGroupbox("Play style", "sliders-horizontal")
local PRESETS = {
    Balanced = { PC_Attack = true, PC_AttackMin = 55, PC_Edge = 1.2, PC_KeepHome = 35, PC_CounterPunish = true, PC_Nuke = false, PC_BoatAttack = true, PC_Siege = true,
        PC_SurviveIn = 1.2, PC_UdStrike = true, PC_SamMode = "Prepare" },
    Aggressive = { PC_Attack = true, PC_AttackMin = 30, PC_Edge = 1.0, PC_KeepHome = 25, PC_CounterPunish = true, PC_Nuke = true, PC_BoatAttack = true, PC_Siege = true,
        PC_SurviveIn = 1.6, PC_UdStrike = true, PC_SamMode = "Once nukes fly" },
    Defensive = { PC_Attack = false, PC_AttackMin = 70, PC_Edge = 1.5, PC_KeepHome = 50, PC_CounterPunish = false, PC_Nuke = false, PC_BoatAttack = false, PC_Siege = false,
        PC_SurviveIn = 0.9, PC_UdStrike = false, PC_SamMode = "Prepare" },
    ["Money farm (survive long)"] = { PC_Attack = true, PC_AttackMin = 60, PC_Edge = 1.5, PC_KeepHome = 45, PC_CounterPunish = false, PC_Nuke = false, PC_BoatAttack = true,
        PC_Siege = false, PC_SurviveIn = 1.0, PC_UdStrike = false, PC_SamMode = "Prepare" },
}
local PRESET_TIPS = {
    Balanced = "Default brain play: grow, hit weak targets, deny winners.",
    Aggressive = "Attacks earlier, nukes on, less kept home. Wins fast or loses fast.",
    Defensive = "Holds land: no auto attacks or boats, keeps half the army home, asks neighbours to ally.",
    ["Money farm (survive long)"] = "Money pays per minute survived: cheap growth, allies, no risky wars.",
}
local presetLabel
OP:AddDropdown("PC_Preset", { Text = "Preset", Values = { "Balanced", "Aggressive", "Defensive", "Money farm (survive long)" }, Default = "Balanced",
    Callback = function(v) if presetLabel then presetLabel:SetText(PRESET_TIPS[v] or "") end end })
OP:AddButton({ Text = "Apply preset", Func = function()
    local name = Library.Options.PC_Preset.Value
    for id, v in PRESETS[name] or {} do
        local o = Library.Toggles[id] or Library.Options[id]
        if o then pcall(o.SetValue, o, v) end
    end
    notify("Play style: " .. name)
end })
presetLabel = OP:AddLabel(PRESET_TIPS.Balanced, true)
local standLabel = Tabs.Overview:AddRightGroupbox("Standings", "list"):AddLabel("-", true)
local infoLabel = Tabs.Overview:AddRightGroupbox("Match", "activity"):AddLabel("-", true)
local logLabel = Tabs.Overview:AddLeftGroupbox("Log", "scroll-text"):AddLabel("-", true)

-- ============ BRAIN ============
local BP = Tabs.Brain:AddLeftGroupbox("Posture", "gauge")
Nm(BP, "PC_SurviveIn", "SURVIVE at pressure (x)", "surviveIn", 0.5, 3, 1, "(incoming + half the strongest neighbour) / my army")
Nm(BP, "PC_SurviveOut", "Leave SURVIVE below (x)", "surviveOut", 0.2, 2, 1)
Nm(BP, "PC_BrainNbr", "Keep home vs neighbour (x)", "brainNbrShare", 0, 1, 1, "Share of the strongest neighbour's army kept home")
Nm(BP, "PC_Holdable", "Posts if incoming < x army", "holdable", 0.5, 4, 1, "Posts on a front you can't hold become the attacker's")
BP:AddLabel("SURVIVE: defend and grab cheap land only. CONTEND: normal. DOMINATE: #1 with 2x the land of #2.", true)
local BD_ = Tabs.Brain:AddLeftGroupbox("Deny the winner", "octagon-x")
P(BD_, "PC_DenyMargin", "Deny within % of win bar", "denyMargin", 2, 40)
T(BD_, "PC_DenyReserve", "Keep gold for a deny nuke", "denyReserve", "Nukes turn their land open again: knock them under the bar")
T(BD_, "PC_Record", "Record match (CSV / 30 s)", "record", "PixelConquest/match_<server>.csv, for reviews")
local UD = Tabs.Brain:AddRightGroupbox("Underdog", "trending-up")
T(UD, "PC_Underdog", "Underdog mode", "underdog", "When the main enemy has x your land")
Nm(UD, "PC_UdRatio", "Trigger: they have x my land", "udRatio", 1.1, 5, 1)
T(UD, "PC_UdDiplo", "Gang up: ally, target, embargo", "udDiplo")
T(UD, "PC_UdStrike", "Hit home when their army is out", "udStrike")
P(UD, "PC_UdOpening", "Opening: army < % of peak", "udOpening", 20, 95)
P(UD, "PC_UdStrikeRatio", "Opening strike troops %", "udStrikeRatio", 10, 90)
T(UD, "PC_UdNuke", "Nukes go at the main enemy", "udNuke")
P(UD, "PC_UdDanger", "Fast nukes within % of bar", "udDanger", 1, 30)
T(UD, "PC_UdDefense", "Posts on their border early", "udDefense")

-- ============ EXPAND ============
local EX = Tabs.Expand:AddLeftGroupbox("Spawn & open land", "map-pin")
T(EX, "PC_Spawn", "Auto spawn (far from others)", "spawn")
T(EX, "PC_SpawnCoast", "Prefer coast", "spawnCoast")
P(EX, "PC_ExpandRatio", "Troops per push %", "expandRatio", 5, 100)
P(EX, "PC_BandLow", "Push above % of cap", "bandLow", 0, 95, "Troops grow fastest at 40-60% of cap")
P(EX, "PC_BandHigh", "Seed pockets above % of cap", "bandHigh", 10, 100)
local expandLabel = EX:AddLabel("-", true)
local EXI = Tabs.Expand:AddRightGroupbox("Islands", "ship")
T(EXI, "PC_Islands", "Boat to open land", "islands", "Each boat carries 1/5 of your troops; max 3 at sea")
T(EXI, "PC_IslandLocked", "Only when boxed in", "islandOnlyLocked")
P(EXI, "PC_IslandMin", "Above % of cap", "islandMin", 10, 95)
P(EXI, "PC_IslandMinLocked", "Boxed in: above % of cap", "islandMinLocked", 0, 95)
Nm(EXI, "PC_IslandEvery", "Seconds between boats", "islandEvery", 5, 120)
Nm(EXI, "PC_IslandDist", "Max sea distance", "islandMaxDist", 20, 600)
local EX3 = Tabs.Expand:AddRightGroupbox("Reclaim nuked land", "radiation")
T(EX3, "PC_Reclaim", "Retake nuked holes", "reclaim", "Holes aren't connected to your expand front")
P(EX3, "PC_ReclaimMin", "Above % of cap", "reclaimMin", 0, 90)
P(EX3, "PC_ReclaimRatio", "Troops per push %", "reclaimRatio", 5, 60)

-- ============ ATTACK ============
local AT = Tabs.Attack:AddLeftGroupbox("Targets", "crosshair")
T(AT, "PC_HitBots", "Bots / nations", "hitBots")
T(AT, "PC_HitPlayers", "Players", "hitPlayers")
Nm(AT, "PC_LootWeight", "Loot pull", "lootWeight", 0, 0.3, 2, "You keep buildings you conquer: weak targets with cities go first")
T(AT, "PC_Finish", "Finish weak players (+50% gold)", "finish")
T(AT, "PC_Traitors", "Traitors first (x0.5 defense)", "hitTraitors")
Nm(AT, "PC_Edge", "Edge vs their army (x)", "edge", 0.5, 4, 1)
P(AT, "PC_AttackMin", "Attack above % of cap", "attackMin", 0, 100)
P(AT, "PC_AttackRatio", "Troops per attack %", "attackRatio", 5, 100, "Ignored while 'Use game ATTACK SIZE' is on")
Nm(AT, "PC_MaxFronts", "Max fronts", "maxFronts", 1, 4)
local combatLabel = AT:AddLabel("-", true)
local LC = Tabs.Attack:AddLeftGroupbox("Leech momentum", "git-merge")
T(LC, "PC_Leech", "Join allies' attacks", "leech", "Enemy fighting an ally on another front: hit them too")
T(LC, "PC_LeechAny", "Also anyone's attacks", "leechAny", "Pile onto whoever is being hit, not just by allies")
P(LC, "PC_LeechMin", "When hit with % of their army", "leechMin", 5, 200)
Nm(LC, "PC_LeechEdge", "Edge needed (x their army)", "leechEdge", 0.1, 2, 1)
local BT = Tabs.Attack:AddRightGroupbox("Across water", "ship")
T(BT, "PC_BoatAttack", "Boat invasions", "boatAttack", "A boat carries 1/5 of your troops and fights their whole army")
P(BT, "PC_CheapFrac", "Cheap grab: army < % mine", "cheapFrac", 1, 30, "Skips the fill gate; bots allowed even in SURVIVE")
P(BT, "PC_BoatMin", "Above % of cap", "boatMin", 10, 95)
Nm(BT, "PC_BoatEdge", "Boat vs their army (x)", "boatEdge", 0.3, 3, 1)
Nm(BT, "PC_BoatEvery", "Seconds between boats", "boatEvery", 5, 120)
T(BT, "PC_SeaPath", "Real sailing distance", "seaPath", "Flood-fills the water from your coast so crossings around land count their true length")
Nm(BT, "PC_RiverDist", "River: up to tiles", "riverDist", 3, 60, 0, "Boats sail ~10 tiles/s: short crossings chain boats")
Nm(BT, "PC_RiverEdge", "River: edge (x normal)", "riverEdge", 0.2, 1, 1)
Nm(BT, "PC_RiverEvery", "River: seconds per boat", "riverEvery", 1, 30)
local SG = Tabs.Attack:AddRightGroupbox("Sea siege", "anchor")
T(SG, "PC_Siege", "Sea siege", "siege", "3 boats at once (~49% of your army) merge on landing")
T(SG, "PC_SiegeBots", "Siege bots too", "siegeBots")
Nm(SG, "PC_SiegeTrigger", "When 1 boat < x army", "siegeTrigger", 1, 5, 1)
P(SG, "PC_SiegeFill", "Charge to % of cap", "siegeFill", 30, 100)
Nm(SG, "PC_SiegeEdge", "...or salvo = x army", "siegeEdge", 0.5, 3, 1)
P(SG, "PC_SiegeKeep", "Reinforce above % of cap", "siegeKeep", 5, 90)
Nm(SG, "PC_SiegeGap", "Seconds between salvos", "siegeGap", 5, 120)
T(SG, "PC_SiegeHold", "Pause attacks while charging", "siegeHold")
T(SG, "PC_SiegeNuke", "Nuke before the salvo", "siegeNuke")
Dd(SG, "PC_SiegeNukeKind", "Siege nuke", "siegeNukeKind", NUKES)

-- ============ DEFEND ============
local CT = Tabs.Defend:AddLeftGroupbox("Counter attacks", "shield")
T(CT, "PC_CounterCancel", "Cancel incoming (1:1)", "counterCancel", "Their attack size sent back: both armies cancel")
T(CT, "PC_CounterPunish", "Cancel + invade", "counterPunish", "Only vs the main enemy; side wars just cancel")
P(CT, "PC_KeepHome", "Keep % of troops home", "keepHome", 0, 90)
P(CT, "PC_KeepCap", "...and % of cap", "keepCap", 0, 60)
T(CT, "PC_HoldHit", "Hold when a strong player hits", "holdWhenHit")
local LS = Tabs.Defend:AddLeftGroupbox("Last stand", "flag")
T(LS, "PC_LastStand", "Last stand", "lastStand", "Can't cancel it: nuke them, post, reinforce, ask to ally")
Dd(LS, "PC_LastNuke", "Nuke", "lastStandNuke", NUKES)
T(LS, "PC_LastAlly", "Ask the attacker to ally", "lastStandAlly")
local RV = Tabs.Defend:AddRightGroupbox("Revenge", "skull")
T(RV, "PC_Revenge", "Hit back attackers", "revenge", "Only when you're stronger")
P(RV, "PC_RevRatio", "Troops %", "revengeRatio", 5, 100)
P(RV, "PC_RevMin", "Above % of cap", "revengeMin", 0, 100)
Nm(RV, "PC_RevEdge", "Edge (x)", "revengeEdge", 0.1, 4, 1)
Nm(RV, "PC_RevStronger", "Only if my army is x theirs", "revengeStronger", 0.5, 4, 1)
Nm(RV, "PC_Grudge", "Remember attackers (s)", "grudgeSecs", 10, 600)

-- ============ BUILD ============
local BD = Tabs.Build:AddLeftGroupbox("Cities & gold", "building-2")
T(BD, "PC_Upgrade", "Upgrade cities in place", "upgradeCities")
Nm(BD, "PC_CityMaxLv", "Each city to Lv", "cityMaxLv", 1, 10, 0, "Then a new city: one nuke wipes a whole cluster")
Nm(BD, "PC_CitySpread", "Tiles between cities", "citySpread", 16, 90, 0, "31 = outside an Atom, 61 = outside a Mega")
T(BD, "PC_CityWeight", "Weigh cities by army fill", "cityWeight", "Cap only limits growth when troops are near it")
P(BD, "PC_CityHigh", "Cities first above %", "cityFillHigh", 20, 100)
P(BD, "PC_CityLow", "Spare gold only below %", "cityFillLow", 0, 80)
Nm(BD, "PC_CitySpare", "Spare gold = x cost", "citySpare", 1, 5, 1)
T(BD, "PC_SaveTop", "Save for the top building", "saveForTop")
K(BD, "PC_Reserve", "Gold reserve (K)", "reserve", 5000)
local buildLabel = BD:AddLabel("-", true)
local BD2 = Tabs.Build:AddRightGroupbox("Buildings", "building")
local NAMES = { city = "City", port = "Port", defense = "Defense post", artillery = "Artillery (pass)", airfield = "Airfield (pass)", railgun = "Railgun (pass)" }
for _, k in ORDER do
    BD2:AddToggle("PC_B_" .. k, { Text = NAMES[k] or k, Default = CFG["b_" .. k], Callback = set("b_" .. k) })
    BD2:AddSlider("PC_M_" .. k, { Text = "max " .. (k == "city" and "cities" or k), Default = CFG["max_" .. k], Min = 0, Max = 10, Rounding = 0, Callback = set("max_" .. k) })
end

-- ============ WEAPONS ============
local WP = Tabs.Weapons:AddLeftGroupbox("Nukes", "radiation")
Dd(WP, "PC_NukeKind", "Type", "nukeKind", NUKES)
K(WP, "PC_NukeMin", "Min gold (K)", "nukeMinGold", 10000)
Nm(WP, "PC_NukeCd", "Seconds between nukes", "nukeCooldown", 5, 300)
T(WP, "PC_NukeStronger", "Also unprovoked stronger", "nukeStronger", "Off = don't provoke them")
T(WP, "PC_NukeBots", "Skip bots", "nukeSkipBots")
Nm(WP, "PC_NukeUpsize", "Bigger nuke must be x better", "nukeUpsize", 1, 2, 2, "Best owned: value destroyed per gold; a pricier type must beat a cheaper one by this")
T(WP, "PC_AvoidSam", "Skip targets under anti-nuke", "avoidSam")
local WR = Tabs.Weapons:AddLeftGroupbox("Revenge nukes", "skull")
T(WR, "PC_RevNuke", "Nuke back nukers", "revengeNuke", "Their best city cluster")
Dd(WR, "PC_RevNukeKind", "Type", "revengeNukeKind", NUKES)
Nm(WR, "PC_RevMinLv", "Blast must hit city Lv", "revengeMinLv", 1, 30)
T(WR, "PC_RevStrikes", "Also for strikes / railgun", "revengeNukeStrikes")
T(WR, "PC_RevOnce", "One per offence", "revengeOnce")
Nm(WR, "PC_NukeGrudge", "Remember nukers (s)", "nukeGrudgeSecs", 30, 900)
local weaponsLabel = WR:AddLabel("-", true)
local AN = Tabs.Weapons:AddRightGroupbox("Anti-nuke", "shield-check")
Dd(AN, "PC_SamMode", "When", "samMode", { "Prepare", "Always", "Once nukes fly", "After I'm nuked" })
Nm(AN, "PC_SamPrepMin", "Prepare: after minutes", "samPrepMin", 0, 30)
Nm(AN, "PC_SamPrepLv", "Prepare: or city Lv", "samPrepCityLv", 1, 100)
Nm(AN, "PC_SamMax", "Max anti-nukes", "max_sam", 0, 8)
Nm(AN, "PC_SamCityLv", "Only once city Lv", "samMinCityLv", 0, 50)
Nm(AN, "PC_SamMinValue", "Must cover value", "samMinValue", 0, 200, 0, "City Lv x10")
Nm(AN, "PC_SamMaxLv", "Max upgrade Lv", "samMaxLv", 1, 10)
T(AN, "PC_SamUpgrade", "Upgrade for range", "samUpgrade", "Lv1 70 tiles -> Lv10 118")
T(AN, "PC_SamPriority", "Pause builds once nukes fly", "samPriority")
local samLabel = AN:AddLabel("-", true)
local WP2 = Tabs.Weapons:AddRightGroupbox("Strikes & reinforce", "zap")
T(WP2, "PC_Air", "Airstrikes", "airstrike")
T(WP2, "PC_Rail", "Railgun", "railgun")
T(WP2, "PC_Reinforce", "Reinforce (Barracks)", "reinforce")
P(WP2, "PC_ReinBelow", "Reinforce below % of cap", "reinforceBelow", 5, 100)

-- ============ DIPLOMACY ============
local DP = Tabs.Diplo:AddLeftGroupbox("Alliances", "handshake")
T(DP, "PC_Renew", "Renew expiring", "renew")
T(DP, "PC_AskAlly", "Send alliance requests", "askAlly", "Off: the script never asks anyone (it still accepts requests)")
T(DP, "PC_Request", "Ask stronger neighbours", "request")
Nm(DP, "PC_ReqRatio", "When they have x my troops", "requestRatio", 0.5, 5, 1)
T(DP, "PC_BlockUnally", "Block breaking alliances", "blockUnally", "Traitors get x0.5 defense")
DP:AddInput("PC_Blacklist", { Text = "Never ally (names)", Default = "", Finished = true, Callback = set("blacklist") })
local diploLabel = Tabs.Diplo:AddRightGroupbox("Status", "activity"):AddLabel("-", true)

-- ============ LOBBY & PASSES ============
local LB = Tabs.Lobby:AddLeftGroupbox("Loop", "repeat")
LB:AddDropdown("PC_Sizes", { Text = "Only these lobbies", Tooltip = "None = any", Values = { "SKIRMISH", "BATTLE", "WORLD WAR" }, Multi = true, Default = {}, Callback = set("queueSizes") })
T(LB, "PC_SkipSpecial", "Skip special modes", "skipSpecial")
T(LB, "PC_Leave", "Leave after win / death", "leave")
Nm(LB, "PC_LeaveDelay", "Wait before leaving (s)", "leaveDelay", 0, 30)
T(LB, "PC_Reinject", "Reload after teleport", "reinject")
T(LB, "PC_Reward", "Claim free reward", "claimReward")
T(LB, "PC_BuyPasses", "Auto buy passes (Money)", "buyPasses")
K(LB, "PC_PassReserve", "Keep Money (K)", "passReserve", 250)
local lobbyLabel = LB:AddLabel("-", true)
local PS = Tabs.Lobby:AddRightGroupbox("Passes", "badge-check")
local passLabel = PS:AddLabel("-", true)
local moneyKeys = {}
for _, p in PASSES do if p.money then moneyKeys[#moneyKeys + 1] = p.key end end
PS:AddDropdown("PC_BuyPick", { Text = "Buy with Money", Values = moneyKeys, Default = moneyKeys[1] })
PS:AddButton({ Text = "Buy (lobby only)", Func = function()
    local k = Library.Options.PC_BuyPick.Value
    if role() ~= "lobby" then notify("Passes can only be bought in the lobby"); return end
    if hasPass(k) then notify("You already own " .. k); return end
    Shop:FireServer("passmoney", k); log("bought pass " .. k .. " with Money (manual)")
end })
T(PS, "PC_UseFree", "Use free pack items", "useFree", "Free nukes fire even with auto nuke off")

-- ============ SETTINGS ============
local SA = Tabs.Settings:AddLeftGroupbox("Behaviour", "shield-alert")
T(SA, "PC_HudRatio", "Use game ATTACK SIZE", "useHudRatio", "Expand, attack, revenge and boats send the HUD %; counters size themselves")
T(SA, "PC_BlockPrompts", "Block Robux prompts", "blockPrompts", "Also blocks prompts you click yourself")
Nm(SA, "PC_Gap", "Seconds between actions", "gap", 0.05, 1, 2)
Nm(SA, "PC_ScanEvery", "Think every (s)", "scanEvery", 1, 10)
local CM = Tabs.Settings:AddRightGroupbox("Camera", "camera")
CM:AddToggle("PC_CamUnlock", { Text = "Unlock camera bounds", Default = CFG.camUnlock, Callback = function(v) CFG.camUnlock = v; applyCamera() end })
CM:AddSlider("PC_CamMargin", { Text = "Pan past edge (x screen)", Default = CFG.camMargin, Min = 0, Max = 2, Rounding = 1, Callback = function(v) CFG.camMargin = v; applyCamera() end })
CM:AddSlider("PC_CamZoom", { Text = "Zoom range (x)", Default = CFG.camZoom, Min = 1, Max = 4, Rounding = 1, Callback = function(v) CFG.camZoom = v; applyCamera() end })
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
            udLabel:SetText(status.underdog or "-")
            brainLabel:SetText(status.brain or "-")
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
            local winTxt = ""
            if S.threshold and S.playable and S.playable > 0 and me then
                local bar = S.threshold <= 1 and S.threshold * 100 or (S.threshold <= 100 and S.threshold or S.threshold / S.playable * 100)
                winTxt = ("\nwin bar %.1f%% of land · you %.1f%%"):format(bar, me.tiles / S.playable * 100)
            end
            infoLabel:SetText((winTxt ~= "" and (winTxt:sub(2) .. "\n") or "") .. ("server %s · phase %s · id %s\ngold %s · troops %s / %s · land %s tiles\npayout so far %s\nsent %d · attacks %d · builds %d · nukes %d · strikes %d · allies %d · joins %d\ndenied %d (last: %s)"):format(
                tostring(role()), tostring(S.phase), tostring(S.myId), fmt(S.gold), fmtT(me and me.troops), fmtT(troopCap()), me and me.tiles or 0,
                tostring(payout or "-"), stats.sent, stats.attacks, stats.builds, stats.nukes, stats.strikes, stats.allies, stats.joins, stats.denied, S.lastDenied))
            local list = table.clone(S.players)
            table.sort(list, function(a, b) return a.tiles > b.tiles end)
            local al, traitors, lines = allies(), setOf(S.diplo and S.diplo.traitors), {}
            for i = 1, math.min(#list, 10) do
                local v = list[i]
                lines[#lines + 1] = ("%d. %s%s  %s tiles · %s troops%s%s%s"):format(i, S.names[v.id] or ("#" .. v.id), v.id == S.myId and " (you)" or "",
                    fmt(v.tiles), fmtT(v.troops), v.isBot and " · bot" or "", al[v.id] and " · ALLY" or "", traitors[v.id] and " · TRAITOR" or "")
            end
            standLabel:SetText(#lines > 0 and table.concat(lines, "\n") or "-")
            logLabel:SetText(table.concat(logLines, "\n", 1, math.min(#logLines, 14)))
        end)
        task.wait(1)
    end
end)

log("loaded v3.3 on " .. tostring(role()) .. " server")
Library:Notify("Pixel Conquest v3.3 ready — RightCtrl toggles the UI.", 5)
