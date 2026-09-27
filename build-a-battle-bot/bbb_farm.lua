--[[
    Build A Battle Bot — auto farm
    UI: Obsidian (deividcomsono)

    MECHANISM (measured live 2026-09-26 — full notes in bbb-spec.md):
      * Combat is server-side. The only "input" for the bot is where it is:
        BotCommandRemote "depthsStart" / "depthsStop" / "toArena" / "toWorkshop".
        toArena is ignored from the Depths (depthsStop first), and "toPlot" is the
        resting state — the server never follows it with "plot".
      * Depths pays money only. XP only accrues at the plot: each Energy Station
        buffers 120 s of fuel and the bot drains it when home, so runs are split by
        a short stay at the plot until the fullest buffer is low again.
      * Pit event tiers are SERVER-wide totals. You only need `joined`, and it
        survives leaving, so the bot goes in, lands a hit and leaves (the Pit is PvP).
        The Titan sends no joined flag: we count N seconds in the Pit instead.
      * CrateRemote "claim"/"open" and GarageRemote "equip" work from anywhere.
      * Plot signs (station buy/upgrade, workshop level, scrapper level) go through
        PlotSignRemote, which the server range-checks: stand next to the sign. The
        prompts are unreliable (WorkshopSign disables them unless the camera faces them).
      * A rebirth also wipes the stations and resets the workshop (2 pads) and the
        scrapper to LV.1: empty pads read "ENERGY STATION · BUY · 400" and get re-bought first.
      * Scrap is a second, character-driven farm that runs alongside the bot:
        pieces in the Pit pick up within 4.5 studs and deposit within 10 of your
        Scrapper. Hard teleports keep the load (unlike Needle in a Haystack).
]]

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local LP          = Players.LocalPlayer
local PG          = LP:WaitForChild("PlayerGui")
local Shared      = RS:WaitForChild("Shared")

-- Re-exec safe
if getgenv().BBB_FARM then pcall(getgenv().BBB_FARM.unload) end

local BotParts       = require(Shared:WaitForChild("BotParts"))
local CrateConfig    = require(Shared:WaitForChild("CrateConfig"))
local RewardConfig   = require(Shared:WaitForChild("RewardConfig"))
local RebirthConfig  = require(Shared:WaitForChild("RebirthConfig"))
local SkillConfig    = require(Shared:WaitForChild("SkillConfig"))
local MaterialConfig = require(Shared:WaitForChild("MaterialConfig"))
local compact        = require(Shared:WaitForChild("NumberFormat")).compact

local R = {
    bot     = RS:WaitForChild("BotCommandRemote"),
    crate   = RS:WaitForChild("CrateRemote"),
    garage  = RS:WaitForChild("GarageRemote"),
    reward  = RS:WaitForChild("RewardRemote"),
    quest   = RS:WaitForChild("QuestRemote"),
    guild   = RS:WaitForChild("GuildRemote"),
    rebirth = RS:WaitForChild("RebirthRemote"),
    skill   = RS:WaitForChild("SkillRemote"),
    swarm   = RS:WaitForChild("SwarmRemote"),
    boss    = RS:WaitForChild("PitBossRemote"),
    alien   = RS:WaitForChild("AlienShipRemote"),
    scrap   = RS:WaitForChild("ScrapperRemote"),
    sign    = RS:WaitForChild("PlotSignRemote"),
}
local money = LP:WaitForChild("leaderstats"):WaitForChild("Money")

local EVENT_KINDS = { "swarm", "elite", "frenzy", "rush", "titan" }
local function set(list)
    local t = {}
    for _, v in ipairs(list) do t[v] = true end
    return t
end

local CFG = {
    -- Bot · Depths
    depths = false, maxRun = 0, drainTo = 15, drainMax = 30, skip = false, skipPct = 25,
    -- Bot · Pit events
    events = false, eventKinds = set(EVENT_KINDS), stay = false, titanHold = 20, manualPause = 90,
    -- Crates & parts
    claim = false, open = false, openKinds = set(CrateConfig.CRATE_ORDER), hideReveal = true,
    holdLuck = false, holdTier = 3, -- keep crates of this tier+ (3 = Lava) shut until an admin CRATE LUCK event
    equip = false, equipSlots = set(BotParts.SLOT_ORDER),
    sellJunk = false, keepPerSlot = 2, keepRarity = 6, -- never sell rarity >= keepRarity (6 = Mythic)
    -- Upgrades
    upgrades = false, workshopFirst = true, stationCap = 0, reserve = 0, fabricator = false,
    skills = false, skillFocus = "Economy", saveForTop = true,
    rebirth = false, rebirthExtra = 0, rebirthMax = 0,
    -- Rewards
    playtime = false, daily = false, quests = false, guild = false,
    -- Scrap
    scrap = false, frenzyOnly = false, minGround = 1, scrapReturn = true, scrapper = false, raid = false,
    -- Misc
    antiAfk = true,
}

local weak = { __mode = "k" }
local S = {
    alive = true, conns = {}, cfg = CFG,
    mode = "plot", modeAt = os.clock(),
    evs = {},           -- active pit events by kind: { joined, pit = s in arena, seen }
    garage = nil, counts = {}, gsync = nil,
    reward = nil, rewardAt = 0, quest = nil, guild = nil, rb = nil, sk = nil, raid = nil,
    lastCmd = {}, fullUntil = 0, lastErr = {},
    failUntil = setmetatable({}, weak), skipMat = setmetatable({}, weak),
    t0 = os.clock(), earned = 0, runs = 0, events = 0, opened = 0, equips = 0, upgrades = 0,
    scrapPieces = 0, scrapBase = 0,
    log = {}, logDirty = false,
    unload = function() end,
}
getgenv().BBB_FARM = S

local function log(msg)
    table.insert(S.log, os.date("%H:%M:%S ") .. msg)
    if #S.log > 200 then table.remove(S.log, 1) end
    S.logDirty = true
end

-- pcall wrapper that logs each distinct error once instead of every tick
local function safe(name, f, ...)
    local ok, err = pcall(f, ...)
    if not ok and S.lastErr[name] ~= tostring(err) then
        S.lastErr[name] = tostring(err)
        log(name .. " error: " .. tostring(err))
    end
end

-- ============================== helpers ==============================
local SUF = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, Qa = 1e15, Qi = 1e18, Sx = 1e21, Sp = 1e24, Oc = 1e27, No = 1e30, Dc = 1e33 }
-- ponytail: suffix table stops at Dc (1e33); copy more from NumberFormat if costs ever get there
local function num(s)
    local n, suf = (tostring(s or ""):gsub(",", "")):match("^%s*([%d%.]+)(%a*)%s*$")
    n = n and tonumber(n)
    if not n then return nil end
    if suf == "" then return n end
    return SUF[suf] and n * SUF[suf] or nil
end

-- Fuel/s gained by the next station level: +1 up to LV30, +5 after; an empty pad starts at 5/s
local function stationGain(lv)
    if lv == nil then return 5 end
    return lv < 30 and 1 or 5
end

assert(num("3.5K") == 3500 and num("1,025") == 1025 and num("1.25M") == 1250000 and num("MAX LEVEL") == nil, "num() broken")
assert(stationGain(29) == 1 and stationGain(30) == 5 and stationGain(nil) == 5, "stationGain() broken")

local function hrp()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function plotIdx() return LP:GetAttribute("PlotIndex") end

local function myPlot()
    for _, m in ipairs(workspace:GetChildren()) do
        local plots = m.Name == "Map" and m:FindFirstChild("Plots")
        if plots then return plots:FindFirstChild("Plot" .. tostring(plotIdx())) end
    end
end

-- ======================= upgrade targets (read from server-written labels) =======================
-- Energy station pads, from the billboards the server writes into PlayerGui:
--   PlotSignBillboard       "ENERGY STATION LV.25" + "29/s · 3.0K/3.5K"   (built)
--   PlotSignBillboard       "ENERGY STATION · BUY · 400"                 (empty pad, e.g. after a rebirth)
--   PlotSignActionBillboard "UPGRADE STATION · 63.5K"
local function myStations()
    local by = {}
    for _, g in ipairs(PG:GetChildren()) do
        local a = g:IsA("BillboardGui") and g.Adornee
        if a and a.Name == "StationAnchor" and a:GetAttribute("PlotIndex") == plotIdx() then
            local e = by[a] or { anchor = a }
            by[a] = e
            local title = g:FindFirstChild("Title", true)
            local info  = g:FindFirstChild("InfoLabel", true)
            local cost  = g:FindFirstChild("CostLabel", true)
            if title then e.lv = tonumber(title.Text:match("LV%.(%d+)")) or e.lv end
            if info then
                local cur, cap = info.Text:match("([%d%.,]+%a*)%s*/%s*([%d%.,]+%a*)%s*$")
                cur, cap = num(cur), num(cap)
                if cur and cap and cap > 0 then e.fill = cur / cap end
            end
            if cost then e.cost = num(cost.Text) or e.cost end
        end
    end
    return by
end

-- Workshop level = station pad count (2..6). SurfaceGui on the plot sign: "WORKSHOP LV.3 · UPGRADE · 16.0K"
-- ("MAX LEVEL" at LV.5, which num() rejects)
local function workshop()
    local plot = myPlot()
    local sign = plot and plot:FindFirstChild("Sign")
    local part = sign and sign:FindFirstChild("WorkshopSign_" .. tostring(plotIdx()))
    local screen = sign and sign:FindFirstChild("WorkshopSignScreen", true)
    if not (part and screen) then return end
    local w = { part = part }
    for _, d in ipairs(screen:GetDescendants()) do
        if d:IsA("TextLabel") then
            w.lv = w.lv or tonumber(d.Text:match("LV%.(%d+)"))
            w.cost = w.cost or num(d.Text)
        end
    end
    return w
end

-- Scrapper: PlotSignBillboard "SCRAPPER LV.9 · UPGRADE · 25.6K · ×5.59" (levels are wave-gated)
local function scrapper()
    for _, g in ipairs(PG:GetChildren()) do
        local a = g:IsA("BillboardGui") and g.Adornee
        if a and a.Name == "ScrapperSignHolder" and a:GetAttribute("PlotIndex") == plotIdx() then
            local title, cost = g:FindFirstChild("Title", true), g:FindFirstChild("CostLabel", true)
            return { part = a, lv = title and tonumber(title.Text:match("LV%.(%d+)")), cost = cost and num(cost.Text) }
        end
    end
end

local function levelOf(part)
    if part.Name == "StationAnchor" then
        local e = myStations()[part]
        return e and e.lv
    elseif part.Name == "ScrapperSignHolder" then
        local s = scrapper()
        return s and s.lv
    end
    local w = workshop()
    return w and w.lv
end

local function stationFill()
    local mx = 0
    for _, e in pairs(myStations()) do mx = math.max(mx, e.fill or 0) end
    return mx
end

-- Every coins -> fuel/s option, scored by coins per fuel/s: an empty pad (+5/s), a station level
-- (+1/s to LV30, +5/s after), a workshop level (opens one more pad: value it as that pad, +400 for 5/s).
-- "Workshop first" = rebuild order after a rebirth: empty pads, then the next workshop level (saving
-- up for it — the caller stops when it's unaffordable), and station levels only once it's maxed.
-- A new pad also unlocks a run of cheap levels, which the per-level score doesn't see.
local function bestUpgrade()
    local w = workshop()
    if CFG.workshopFirst and w and w.cost and os.clock() >= (S.failUntil[w.part] or 0) then
        for anchor, e in pairs(myStations()) do
            if e.cost and e.lv == nil and os.clock() >= (S.failUntil[anchor] or 0) then
                return { part = anchor, cost = e.cost, what = "new station" }
            end
        end
        return { part = w.part, cost = w.cost, lv = w.lv, what = "workshop LV." .. tostring(w.lv) }
    end
    local best, bestScore
    local function consider(part, cost, lv, score, what)
        if os.clock() < (S.failUntil[part] or 0) then return end
        if not bestScore or score < bestScore then
            best, bestScore = { part = part, cost = cost, lv = lv, what = what }, score
        end
    end
    for anchor, e in pairs(myStations()) do
        if e.cost and not (CFG.stationCap > 0 and e.lv and e.lv >= CFG.stationCap) then
            consider(anchor, e.cost, e.lv, e.cost / stationGain(e.lv), e.lv and ("station LV." .. e.lv) or "new station")
        end
    end
    if w and w.cost then consider(w.part, w.cost, w.lv, (w.cost + 400) / 5, "workshop LV." .. tostring(w.lv)) end
    return best
end

-- Stand 4 studs off a part toward the plot spawn (open plaza)
local function moveNear(part)
    local h = hrp()
    if not h then return false end
    local plot  = myPlot()
    local spawn = plot and plot:FindFirstChildOfClass("SpawnLocation")
    local flat  = spawn and (spawn.Position - part.Position) * Vector3.new(1, 0, 1) or Vector3.zero
    local dir   = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, 1)
    h.CFrame = CFrame.new(part.Position + dir * 4 + Vector3.new(0, 3, 0))
    task.wait(0.35) -- let the server see us in range before triggering
    return true
end

-- Did the sign level up (or money drop by ~its cost) within 1.5 s? A blank reading (label mid-redraw)
-- is not a change — it once logged a phantom "workshop LV.2 -> LV.2".
local function waitTook(part, lv0, m0, cost)
    local t = os.clock()
    repeat
        task.wait(0.1)
        local lv = levelOf(part)
        if (lv ~= nil and lv ~= lv0) or money.Value <= m0 - cost * 0.5 then return true end
    until os.clock() - t > 1.5
    return false
end

-- One sign action: stand next to it and fire PlotSignRemote (the game's own billboard-click
-- path — range-checked, measured: ignored from 30+ studs). Prompt as the last resort.
local function press(e)
    local part, lv0, m0 = e.part, e.lv, money.Value
    if not moveNear(part) then return false end
    R.sign:FireServer(part)
    if waitTook(part, lv0, m0, e.cost) then return true end
    local pp = part:FindFirstChildOfClass("ProximityPrompt")
    if not pp then return false end
    pp.Enabled = true
    fireproximityprompt(pp)
    return waitTook(part, lv0, m0, e.cost)
end

-- Part value within its slot. Stat slots: PARTS[id].stat is final (the crate-tier bonus is baked in
-- at load) and is exactly what BotStats.computeStats sums. Satellites: rarity, crate tier breaks ties.
local function partScore(id)
    local p = id and BotParts.PARTS[id]
    if not p or BotParts.isAdminPart(id) then return -math.huge end
    if p.slot ~= "Satellite" then return p.stat or -math.huge end
    local crate = CrateConfig.CRATES[p.pool or "Normal"]
    return (p.rarity or 0) + (crate and crate.tier or 1) / 100
end

-- Best part per enabled slot for the deployed build. Parts on other builds are left alone.
local function bestEquip()
    local g = S.gsync
    if not (g and g.builds and g.parts) then return end
    local build
    for _, b in ipairs(g.builds) do if b.id == g.deployedId then build = b end end
    if not build then return end
    local onOther, idOf = {}, {}
    for _, b in ipairs(g.builds) do
        if b ~= build then for _, uid in pairs(b.parts or {}) do onOther[uid] = true end end
    end
    for _, p in ipairs(g.parts) do idOf[p.uid] = p.id end
    local score = partScore
    for _, slot in ipairs(BotParts.SLOT_ORDER) do
        if CFG.equipSlots[slot] then
            local cur = build.parts and build.parts[slot]
            local best, bestScore = nil, score(cur and idOf[cur])
            for _, p in ipairs(g.parts) do
                local d = BotParts.PARTS[p.id]
                if d and d.slot == slot and p.uid ~= cur and not onOther[p.uid] then
                    local s = score(p.id)
                    if s > bestScore then best, bestScore = p, s end
                end
            end
            if best then return build.id, best.uid, slot, best.id end
        end
    end
end

-- Parts worth nothing to us: per slot, keep the top keepPerSlot by score (equipped ones count), plus
-- anything locked, on any build, or at/above keepRarity. Everything else is junk.
local function junkParts()
    local g = S.gsync
    if not (g and g.builds and g.parts) then return {}, 0 end
    local onBuild = {}
    for _, b in ipairs(g.builds) do for _, uid in pairs(b.parts or {}) do onBuild[uid] = true end end
    local bySlot = {}
    for _, p in ipairs(g.parts) do
        local d = BotParts.PARTS[p.id]
        if d then
            bySlot[d.slot] = bySlot[d.slot] or {}
            table.insert(bySlot[d.slot], p)
        end
    end
    local junk, value = {}, 0
    for _, list in pairs(bySlot) do
        table.sort(list, function(a, b) return partScore(a.id) > partScore(b.id) end)
        local kept = 0
        for _, p in ipairs(list) do
            local rarity = BotParts.PARTS[p.id].rarity or 1
            if onBuild[p.uid] or p.locked or rarity >= CFG.keepRarity or kept < CFG.keepPerSlot then
                kept += 1
            else
                junk[#junk + 1] = p.uid
                value += CrateConfig.sellValue(rarity)
            end
        end
    end
    return junk, value
end

-- Admin "CRATE LUCK" event: workspace AdminLuckMult/AdminLuckEndsAt; the server raises
-- CrateConfig.EVENT_LUCK, which scales the rarer rows of both crate-type and part-rarity odds.
local function luckEvent()
    local m, e = workspace:GetAttribute("AdminLuckMult"), workspace:GetAttribute("AdminLuckEndsAt")
    if typeof(m) == "number" and m > 1 and typeof(e) == "number" and os.time() < e then return m end
end

-- The game's CrateOpen overlay queues a tap-to-reveal per "opened" event; mute
-- just that one connection while auto-opening so it doesn't stack up.
local function applyReveal()
    if not getconnections then return end
    local mute = CFG.open and CFG.hideReveal and S.alive
    for _, c in ipairs(getconnections(R.crate.OnClientEvent)) do
        local ok, env = pcall(getfenv, c.Function)
        if ok and env and rawget(env, "script") and env.script.Name == "CrateOpen" then
            if mute then c:Disable() else c:Enable() end
        end
    end
end

local function carried()
    local c, n = LP.Character, 0
    if c then
        for _, x in ipairs(c:GetChildren()) do
            if x.Name:sub(1, 9) == "Material_" then n += 1 end
        end
    end
    return n
end

local function cmd(c, arg)
    local now = os.clock()
    if now - (S.lastCmd[c] or -1e9) < 8 then return end
    S.lastCmd[c], S.lastSent = now, now
    R.bot:FireServer(c, arg)
    log("bot -> " .. c .. (arg and arg.skip and (" (skip to wave " .. tostring(LP:GetAttribute("DepthsSkipWave")) .. ")") or ""))
end

-- ============================== listeners ==============================
local function on(remote, fn) table.insert(S.conns, remote.OnClientEvent:Connect(fn)) end

-- Where the bot is right now: the game's own HUD labels
pcall(function()
    for _, d in ipairs(PG.BotCommand:GetDescendants()) do
        if d:IsA("TextLabel") and d.Text == "LEAVE DEPTHS" then S.mode = "depths" end
        if d:IsA("TextLabel") and d.Text == "TO WORKSHOP" then S.mode = "arena" end
    end
end)

on(R.bot, function(k, d)
    if k == "mode" then
        -- toArena/toDepths/bay only follow a command; if it wasn't ours, the player clicked the HUD.
        -- toPlot doesn't count: the server sends that itself (e.g. right after a rebirth).
        local ours = os.clock() - (S.lastSent or -1e9) < 2
        if not ours and CFG.manualPause > 0 and (d == "toArena" or d == "toDepths" or d == "bay") then
            S.manualUntil = os.clock() + CFG.manualPause
            log(("manual %s — pausing bot control %d s"):format(tostring(d), CFG.manualPause))
        elseif not ours and d == "toPlot" then
            log("server sent the bot home")
        end
        S.mode, S.modeAt = d, os.clock()
    elseif k == "depthsDefeat" and typeof(d) == "table" then
        S.runs += 1
        log(("depths over: wave %s, +%s"):format(tostring(d.wave), compact(tonumber(d.earned) or 0)))
        if CFG.depths then
            S.lastCmd.depthsStop = nil -- skip the 90 s revive window right away
            cmd("depthsStop")
        end
    elseif k == "arenaKo" then
        log("KO'd in the Pit (" .. tostring(typeof(d) == "table" and d.cause) .. ")")
    end
end)

local function eventHandler(fixedKind)
    return function(k, d)
        local kind = fixedKind or (typeof(d) == "table" and d.kind) or "swarm"
        if k == "start" or k == "state" then
            local e = S.evs[kind]
            if not e then
                e = { joined = false, pit = 0 }
                S.evs[kind] = e
                log("event: " .. kind)
            end
            e.seen = os.clock()
            if typeof(d) == "table" and d.joined == true and not e.joined then
                e.joined = true
                log("joined " .. kind)
            end
        elseif k == "end" then
            S.evs[kind] = nil
        elseif k == "rewards" and typeof(d) == "table" then
            S.events += 1
            log(("%s rewards: %s tiers, %s coins, %d crates"):format(kind, tostring(d.tiers),
                compact(tonumber(d.coins) or 0), typeof(d.crates) == "table" and #d.crates or 0))
        end
    end
end
on(R.swarm, eventHandler(nil))
on(R.boss, eventHandler("titan"))

on(R.alien, function(k, d)
    if k == "start" or k == "state" then
        if not S.raid then
            log("alien raid started")
            S.raidLogged = false
        end
        S.raid = os.clock()
        if k == "state" and typeof(d) == "table" and not S.raidLogged then -- first state of each raid: record its fields
            S.raidLogged = true
            local keys = {}
            for key, v in pairs(d) do keys[#keys + 1] = tostring(key) .. "=" .. tostring(v) end
            log("raid state: " .. table.concat(keys, ", "))
        end
    elseif k == "end" then
        S.raid = nil
        log("alien raid over — caught " .. tostring(typeof(d) == "table" and d.caught))
    end
end)

on(R.scrap, function(k, _, value)
    if k == "deposit" then
        S.scrapPieces += 1
        S.scrapBase += tonumber(value) or 0
    end
end)

on(R.crate, function(k, d)
    if k == "garage" and typeof(d) == "table" then
        S.garage = d
    elseif k == "sync" and typeof(d) == "table" and typeof(d.counts) == "table" then
        local alien = tonumber(d.counts.Alien) or 0 -- a caught raid crate shows up here
        -- only while holding one: event/quest rewards hand out Alien crates too
        if S.raidBusy and alien > (S.lastAlien or alien) then S.alienCaught = (S.alienCaught or 0) + alien - S.lastAlien end
        S.lastAlien = alien
        S.counts = d.counts
    elseif k == "full" then
        S.fullUntil = os.clock() + 60
        log("inventory full — pausing opens 60 s (turn on the game's AUTO SELL for low rarities)")
    elseif k == "opened" then
        S.opened += 1
    end
end)
on(R.garage, function(k, d) if k == "sync" and typeof(d) == "table" then S.gsync = d end end)
on(R.reward, function(k, d)
    if k == "sync" and typeof(d) == "table" then S.reward, S.rewardAt = d, os.clock()
    elseif k == "claimed" then log("claimed " .. tostring(typeof(d) == "table" and d.kind)) end
end)
on(R.quest, function(k, d) if k == "sync" and typeof(d) == "table" then S.quest = d end end)
on(R.guild, function(k, d)
    if k == "sync" and typeof(d) == "table" then S.guild = d
    elseif k == "claimed" then log("guild chest " .. tostring(typeof(d) == "table" and d.period)) end
end)
on(R.rebirth, function(k, d) if k == "sync" and typeof(d) == "table" then S.rb = d end end)
on(R.skill, function(k, d) if k == "sync" and typeof(d) == "table" then S.sk = d end end)

local lastMoney = money.Value
table.insert(S.conns, money.Changed:Connect(function(v)
    if v > lastMoney then S.earned += v - lastMoney end
    lastMoney = v
end))

table.insert(S.conns, LP.Idled:Connect(function()
    if not CFG.antiAfk then return end
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end))

local function refresh()
    R.crate:FireServer("request")
    R.garage:FireServer("request")
    R.reward:FireServer("request")
    R.quest:FireServer("request")
    R.rebirth:FireServer("request")
    R.skill:FireServer("request")
end

-- ============================== ticks ==============================
local function startDepths()
    local wave, cost = LP:GetAttribute("DepthsSkipWave") or 0, LP:GetAttribute("DepthsSkipCost") or 0
    if CFG.skip and wave >= 3 and cost > 0 and cost <= money.Value * CFG.skipPct / 100 then
        cmd("depthsStart", { skip = true })
    else
        cmd("depthsStart")
    end
end

local function botTick(dt)
    local m, now = S.mode, os.clock()
    local want, active = false, false -- an enabled event we haven't joined yet / any enabled event
    for kind, e in pairs(S.evs) do
        if now - e.seen > 10 then
            S.evs[kind] = nil -- missed its "end"
        elseif CFG.eventKinds[kind] ~= false then
            active = true
            if kind == "titan" and m == "arena" and not e.joined then
                e.pit += dt
                if e.pit >= CFG.titanHold then
                    e.joined = true
                    log("titan: counted as joined")
                end
            end
            want = want or not e.joined
        end
    end
    if m == "bay" or now < (S.manualUntil or 0) then return end -- player is steering
    -- The server never sends "plot" after toWorkshop/depthsStop: "toPlot" is the resting state.
    local home     = m == "plot" or m == "toPlot"
    local inPit    = m == "arena" or m == "toArena"
    local inDepths = m == "depths" or m == "toDepths"
    if CFG.events and (want or (CFG.stay and active)) then
        if inDepths then
            cmd("depthsStop") -- toArena is ignored from the Depths; leave first
        elseif not inPit then
            cmd("toArena")
        end
    elseif inPit then
        if CFG.events then cmd("toWorkshop") end
    elseif m == "depths" then
        if CFG.depths and CFG.maxRun > 0 and now - S.modeAt >= CFG.maxRun then cmd("depthsStop") end
    elseif home and CFG.depths and now - S.modeAt >= 8 then -- ~8 s to drive home first
        if stationFill() * 100 <= CFG.drainTo or now - S.modeAt >= CFG.drainMax then startDepths() end
    end
end

local function crateTick()
    local now = os.clock()
    local pending = S.garage and S.garage.pending
    if CFG.claim and typeof(pending) == "table" and #pending > 0 and now - (S.lastClaim or 0) > 3 then
        S.lastClaim = now
        R.crate:FireServer("claim")
        log(("claimed %d crate(s)"):format(#pending))
    end
    if CFG.open and now > S.fullUntil and now - (S.lastOpen or 0) > 1 then
        local lucky = luckEvent()
        for _, id in ipairs(CrateConfig.CRATE_ORDER) do
            local n = S.counts[id] or 0
            local held = CFG.holdLuck and not lucky and CrateConfig.CRATES[id].tier >= CFG.holdTier
            if n > 0 and CFG.openKinds[id] and not held then
                local take = math.min(CrateConfig.MAX_OPEN, n)
                S.lastOpen = now
                S.counts[id] = n - take -- optimistic; the "sync" reply corrects it
                R.crate:FireServer("open", { crateId = id, count = take })
                break
            end
        end
    end
end

-- Sell junk in batches (GarageRemote "sellMany", confirmed = true for legendary+)
local function sellTick()
    if not (CFG.sellJunk and S.gsync) then return end
    local junk, value = junkParts()
    if #junk == 0 then return end
    local batch = table.move(junk, 1, math.min(#junk, 50), 1, {})
    R.garage:FireServer("sellMany", batch, true)
    log(("sold %d junk part(s) (~%s)"):format(#batch, compact(value * #batch / #junk)))
    S.gsync = nil
    R.garage:FireServer("request")
end

local function equipTick()
    if not (CFG.equip and (S.mode == "plot" or S.mode == "toPlot")) then return end -- only at home, where it's known-safe
    local bid, uid, slot, id = bestEquip()
    if not bid then return end
    R.garage:FireServer("equip", { buildId = bid, uid = uid })
    S.equips += 1
    log(("equip %s -> %s"):format(slot, id))
    S.gsync = nil
    R.garage:FireServer("request")
end

local function upgradeTick()
    local reserve = money.Value * CFG.reserve / 100
    local function afford(cost) return cost and money.Value - reserve >= cost end
    local g = S.garage
    if CFG.fabricator and g and not g.maxed and not g.locked and afford(g.cost) and os.clock() - (S.lastFab or 0) > 5 then
        S.lastFab = os.clock()
        R.crate:FireServer("upgrade")
        log("fabricator -> LV." .. tostring((g.level or 0) + 1))
    end
    local h = hrp()
    local raiding = S.raidBusy or (CFG.raid and S.raid) -- the character belongs to the raid catcher
    if not h or raiding or PG:GetAttribute("OpenPanel") ~= nil then return end
    local home = h.CFrame
    if CFG.upgrades then
        for _ = 1, 25 do -- ponytail: cap per batch so the character is only away a few seconds
            local e = bestUpgrade()
            if not (e and afford(e.cost)) then break end
            if press(e) then
                S.upgrades += 1
                log(("%s -> LV.%s (%s)"):format(e.what, tostring(levelOf(e.part)), compact(e.cost)))
            else
                S.failUntil[e.part] = os.clock() + 60
                log(e.what .. " didn't take — skipping it for 60 s")
            end
        end
    end
    local s = CFG.scrapper and scrapper()
    if s and afford(s.cost) and os.clock() >= (S.failUntil[s.part] or 0) then
        local e = { part = s.part, cost = s.cost, lv = s.lv, what = "scrapper LV." .. tostring(s.lv) }
        if press(e) then
            log(("%s -> LV.%s (%s)"):format(e.what, tostring(levelOf(s.part)), compact(s.cost)))
        else
            S.failUntil[s.part] = os.clock() + 120
            log("scrapper didn't take (levels are wave-gated) — retry in 2 min")
        end
    end
    local hb = hrp()
    if hb and (hb.Position - home.Position).Magnitude > 5 then hb.CFrame = home end
end

-- Skill focus = arm order; lower rank is bought first, cost breaks ties
local FOCUS = {
    Economy  = { core = 0, wealth = 1, energy = 1, depthspay = 2, sell = 3, boosttime = 3, power = 4, armor = 4, luck = 5, delivery = 5, skip = 6, scrap = 7, storage = 7 },
    Combat   = { core = 0, power = 1, armor = 1, depthspay = 2, energy = 2, wealth = 3, skip = 4, luck = 5, delivery = 5, boosttime = 5, sell = 6, scrap = 7, storage = 7 },
    Crates   = { core = 0, luck = 1, delivery = 1, scrap = 2, storage = 2, wealth = 3, energy = 3, sell = 3, depthspay = 4, power = 5, armor = 5, boosttime = 5, skip = 6 },
    Cheapest = {},
}
local function skillTick()
    local sk = S.sk
    if not (CFG.skills and sk) then return end
    local pts, lv, rank = sk.points or 0, sk.levels or {}, FOCUS[CFG.skillFocus] or FOCUS.Economy
    local top, topKey, buy, buyKey
    for _, n in ipairs(SkillConfig.NODES) do
        if (lv[n.id] or 0) == 0 and (n.requires == nil or (lv[n.requires] or 0) > 0) then
            local cost = SkillConfig.costOf(n)
            local key = (rank[n.id:match("^(%a+)")] or 9) * 1000 + cost
            if not topKey or key < topKey then top, topKey = n, key end
            if cost <= pts and (not buyKey or key < buyKey) then buy, buyKey = n, key end
        end
    end
    local pick = CFG.saveForTop and top or buy
    if not pick or SkillConfig.costOf(pick) > pts then return end -- saving up for the top pick
    R.skill:FireServer("buy", pick.id)
    log("skill " .. pick.id)
    S.sk = nil
    task.delay(1, function() R.skill:FireServer("request") end)
end

local function progressTick()
    local rb = S.rb
    if CFG.rebirth and rb and not RebirthConfig.capped(rb.rebirths or 0)
        and (CFG.rebirthMax == 0 or (rb.rebirths or 0) < CFG.rebirthMax)
        and (LP:GetAttribute("BestDepthWave") or 0) >= (rb.requiredWave or math.huge) + CFG.rebirthExtra then
        R.rebirth:FireServer("rebirth")
        log("rebirth -> " .. tostring((rb.rebirths or 0) + 1))
        S.rb = nil
        task.delay(3, function()
            R.rebirth:FireServer("request")
            R.skill:FireServer("request")
        end)
    end
    local r = S.reward
    if r then
        local fired = false
        if CFG.daily and typeof(r.daily) == "table" and r.daily.claimable then
            R.reward:FireServer("claimDaily")
            fired = true
        end
        local pt = r.playtime
        if CFG.playtime and typeof(pt) == "table" then
            local elapsed = (pt.elapsed or 0) + (os.clock() - S.rewardAt)
            local claimed = typeof(pt.claimed) == "table" and pt.claimed or {}
            for i, tier in ipairs(RewardConfig.PLAYTIME) do
                if not (claimed[i] or claimed[tostring(i)]) and elapsed >= tier.minutes * 60 then
                    R.reward:FireServer("claimPlaytime", i)
                    fired = true
                end
            end
        end
        if fired then
            S.reward = nil
            task.delay(1, function() R.reward:FireServer("request") end)
        end
    end
    local q = S.quest
    if CFG.quests and q then
        local fired = false
        for _, list in ipairs({ q.daily or {}, q.weekly or {} }) do
            for _, e in pairs(list) do
                if typeof(e) == "table" and not e.claimed and (e.progress or 0) >= (e.goal or math.huge) then
                    R.quest:FireServer("claim", e.id)
                    log("quest " .. tostring(e.id))
                    fired = true
                end
            end
        end
        if fired then
            S.quest = nil
            task.delay(1, function() R.quest:FireServer("request") end)
        end
    end
    local g = S.guild
    if CFG.guild and g then
        for _, period in ipairs({ "day", "week" }) do
            if typeof(g[period]) == "table" and (tonumber(g[period].claimable) or 0) > 0 then
                R.guild:FireServer("claim", { period = period })
                S.guild = nil -- the server re-pushes sync every few seconds
            end
        end
    end
end

-- One scrap trip: sweep the Pit nearest-first until full (or empty), deposit at our Scrapper, go back.
local function scrapTick()
    if not CFG.scrap or (CFG.frenzyOnly and not S.evs.frenzy) or PG:GetAttribute("OpenPanel") ~= nil
        or S.raidBusy or (CFG.raid and S.raid) then return end
    local plot  = myPlot()
    local mouth = plot and plot:FindFirstChild("Scrapper") and plot.Scrapper:FindFirstChild("Mouth")
    local h     = hrp()
    if not (mouth and h and #workspace.Materials:GetChildren() >= CFG.minGround) then return end
    local home = h.CFrame
    while carried() < MaterialConfig.CARRY_MAX do
        h = hrp()
        if not h then break end
        local best, bd
        for _, m in ipairs(workspace.Materials:GetChildren()) do
            if os.clock() >= (S.skipMat[m] or 0) then
                local d = (m:GetPivot().Position - h.Position).Magnitude
                if not bd or d < bd then best, bd = m, d end
            end
        end
        if not best then break end
        h.CFrame = CFrame.new(best:GetPivot().Position + Vector3.new(0, 2.5, 0))
        local t = os.clock()
        while best.Parent == workspace.Materials and os.clock() - t < 0.6 do task.wait(0.05) end
        if best.Parent == workspace.Materials then S.skipMat[best] = os.clock() + 30 end -- won't pick up; skip it a while
    end
    if carried() > 0 then
        h = hrp()
        if h then
            h.CFrame = CFrame.new(mouth.Position + Vector3.new(4, 3, 0))
            local t = os.clock()
            while carried() > 0 and os.clock() - t < 8 do task.wait(0.1) end -- ~0.16 s per piece
        end
    end
    h = hrp()
    if h and CFG.scrapReturn then h.CFrame = home end
end

-- ============================== Alien Raid ==============================
-- Crates ("Crate_Alien_N" in workspace.AlienShip) drop from the ship into the Pit. Touching one
-- isn't enough (measured: touch-and-leave caught 0): the character has to stay with it, inside the
-- Pit, for the whole capture timer until it's delivered. So we park there and nothing else may
-- teleport the character meanwhile (S.raidBusy). Delivery = the Alien count rising in CrateRemote "sync".
local ALIEN = require(Shared:WaitForChild("AlienShipConfig"))
local MAP   = require(Shared:WaitForChild("MapConfig"))

local function raidCrates()
    local folder, list = workspace:FindFirstChild("AlienShip"), {}
    if folder then
        for _, c in ipairs(folder:GetChildren()) do
            if c:IsA("Model") and c.Name:match("^Crate_") then list[#list + 1] = c end
        end
    end
    return list
end

-- Measured live: a caught crate is welded to its carrier (WeldConstraint "CarryWeld", Body -> HumanoidRootPart)
-- and shows a mm:ss countdown; hold it until the countdown ends. Dying/lasers drop it for anyone to grab.
local function crateCarrier(crate)
    for _, w in ipairs(crate:GetDescendants()) do
        if w:IsA("WeldConstraint") and w.Name == "CarryWeld" and w.Part1 and w.Part1.Name == "HumanoidRootPart" then
            return Players:GetPlayerFromCharacter(w.Part1.Parent)
        end
    end
end

local function inPit(pos)
    local c = MAP.ARENA_CENTER
    return (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(c.X, 0, c.Z)).Magnitude < MAP.ARENA_RADIUS - 4
end

-- What knocks the crate off you in the Pit (measured/player-confirmed): the ship's lasers — a flat
-- 12-stud warning disc (0.2 x 12 x 12 Part in workspace.AlienShip) lands ~0.9 s before a 6-stud hit —
-- and bots: other players' PlotBots fighting in the Pit, event bots (BotSwarm) and the Titan (PitBoss).
local function pitThreats()
    local list = {}
    local ship = workspace:FindFirstChild("AlienShip")
    if ship then
        for _, p in ipairs(ship:GetChildren()) do
            if p:IsA("BasePart") and p.Position.Y < 4 and p.Size.Y >= 8 then
                list[#list + 1] = { pos = p.Position, r = p.Size.Y / 2 + 4 }
            end
        end
    end
    local mine = "PlotBot_" .. tostring(plotIdx())
    for _, m in ipairs(workspace.PlotBots:GetChildren()) do
        if m:IsA("Model") and m.Name:match("^PlotBot_") and m.Name ~= mine then
            local ok, cf = pcall(m.GetPivot, m)
            if ok and inPit(cf.Position) then list[#list + 1] = { pos = cf.Position, r = 14 } end
        end
    end
    for name, r in pairs({ BotSwarm = 12, PitBoss = 22 }) do
        local f = workspace:FindFirstChild(name)
        if f then
            for _, m in ipairs(f:GetChildren()) do
                local ok, cf = pcall(m.GetPivot, m)
                if ok then list[#list + 1] = { pos = cf.Position, r = r } end
            end
        end
    end
    return list
end

local function flatDist(a, b) return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude end

-- Of 16 random points inside the Pit, the one farthest (edge-to-edge) from every threat
local function safestPitSpot(rng, threats)
    local best, bestScore
    for _ = 1, 16 do
        local a, r = rng:NextNumber(0, math.pi * 2), rng:NextNumber(4, MAP.ARENA_RADIUS - 8)
        local p = MAP.ARENA_CENTER + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
        local score = math.huge
        for _, t in ipairs(threats) do score = math.min(score, flatDist(t.pos, p) - t.r) end
        if not bestScore or score > bestScore then best, bestScore = p, score end
    end
    return best + Vector3.new(0, 3, 0)
end

-- Catch one crate and carry it until it's delivered: touch it (teleport onto it + firetouchinterest) until
-- its CarryWeld points at our root, then stay inside the Pit and keep away from threats — hop at once when
-- a laser disc or bot gets in range, and at least every 0.8 s anyway.
local function catchCrate(crate)
    local got0, t0 = S.alienCaught or 0, os.clock()
    local limit = ALIEN.CAPTURE_TIME + ALIEN.CRATE_LIFETIME + 15
    local rng, lastHop = Random.new(), 0
    log("raid: going for " .. crate.Name)
    while S.alive and CFG.raid and crate.Parent and os.clock() - t0 < limit do
        local h = hrp()
        if h then
            local carrier = crateCarrier(crate)
            if carrier and carrier ~= LP then
                log("raid: " .. carrier.Name .. " has " .. crate.Name)
                return
            end
            if carrier == LP then -- riding on us: keep it inside the Pit, away from lasers and bots
                local threats, danger = pitThreats(), false
                for _, t in ipairs(threats) do
                    if flatDist(t.pos, h.Position) < t.r then danger = true break end
                end
                if danger or os.clock() - lastHop > 0.8 then
                    lastHop = os.clock()
                    h.CFrame = CFrame.new(safestPitSpot(rng, threats))
                end
                task.wait(0.1)
            else -- free: stand on it and touch it
                local body = crate:FindFirstChild("Body", true) or crate.PrimaryPart
                h.CFrame = CFrame.new(crate:GetPivot().Position + Vector3.new(0, 1, 0))
                if body and firetouchinterest then
                    firetouchinterest(h, body, 0)
                    firetouchinterest(h, body, 1)
                end
                task.wait(0.15)
            end
        else
            task.wait(0.25)
        end
    end
    task.wait(1.5) -- let the inventory sync land
    log(((S.alienCaught or 0) > got0) and ("raid: caught " .. crate.Name .. "!")
        or ("raid: lost " .. crate.Name .. (crate.Parent and " (timed out)" or " (gone)")))
end

task.spawn(function()
    while S.alive do
        local h = hrp()
        if CFG.raid and S.raid and h then
            local best, bd
            for _, c in ipairs(raidCrates()) do
                if os.clock() >= (S.skipMat[c] or 0) and not crateCarrier(c) then
                    local d = (c:GetPivot().Position - h.Position).Magnitude
                    if not bd or d < bd then best, bd = c, d end
                end
            end
            if best then
                S.raidHome = S.raidHome or h.CFrame
                S.raidBusy = true
                safe("raid", catchCrate, best)
                S.skipMat[best] = os.clock() + 60
                S.raidBusy = false
            end
        elseif S.raidHome and not S.raid then -- raid over: back to where we were
            if h then h.CFrame = S.raidHome end
            S.raidHome = nil
        end
        task.wait(0.5)
    end
end)

task.spawn(function()
    local last = os.clock()
    while S.alive do
        local now = os.clock()
        safe("bot", botTick, now - last)
        last = now
        task.wait(0.5)
    end
end)

task.spawn(function()
    local n = 0
    while S.alive do
        n += 1
        if n % 30 == 1 then safe("refresh", refresh) end
        safe("crates", crateTick)
        if n % 2 == 0 then safe("equip", equipTick) end
        if n % 10 == 0 and (CFG.equip or CFG.sellJunk) then R.garage:FireServer("request") end
        if n % 10 == 5 then safe("sell", sellTick) end
        if n % 3 == 0 and (CFG.upgrades or CFG.fabricator or CFG.scrapper) then safe("upgrades", upgradeTick) end
        if n % 5 == 0 then
            safe("progress", progressTick)
            safe("skills", skillTick)
        end
        if n % 3 == 1 then safe("scrap", scrapTick) end
        if not S.junkLogged and S.gsync and S.gsync.parts then -- one-time preview so a dry run needs no UI
            S.junkLogged = true
            local junk, value = junkParts()
            log(("parts %d/%d · junk by current rules: %d (~%s)"):format(#S.gsync.parts, CrateConfig.inventorySlots(LP), #junk, compact(value)))
        end
        if n % 60 == 0 then -- heartbeat: enough to follow the farm from the log file alone
            local g, w = S.garage, workshop()
            log(("status: bot %s · money %s · workshop LV.%s · fabricator LV.%s pile %s/%s luck %.0f%% · raid %s · scrap %d · alien caught %d")
                :format(tostring(S.mode), compact(money.Value), tostring(w and w.lv), tostring(g and g.level),
                    tostring(g and typeof(g.pending) == "table" and #g.pending), tostring(g and g.capacity),
                    tonumber(g and g.luckPercent) or 0, S.raid and (S.raidBusy and "holding" or "active") or "none",
                    S.scrapPieces, S.alienCaught or 0))
        end
        if S.logDirty and n % 3 == 0 then
            S.logDirty = false
            pcall(writefile, "bbb_farm_log.txt", table.concat(S.log, "\n"))
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
local Library      = obsidian("Library.lua", "Library.lua")
local ThemeManager = obsidian("ThemeManager.lua", "addons/ThemeManager.lua")
local SaveManager  = obsidian("SaveManager.lua", "addons/SaveManager.lua")

local Window = Library:CreateWindow({
    Title = "Battle Bot Farm",
    Footer = "bot · crates · upgrades · rewards · scrap",
    Center = true, AutoShow = true,
    ToggleKeybind = Enum.KeyCode.RightControl,
})
local Tabs = {
    Bot      = Window:AddTab("Bot"),
    Crates   = Window:AddTab("Crates & Parts"),
    Upgrades = Window:AddTab("Upgrades"),
    Rewards  = Window:AddTab("Rewards"),
    Scrap    = Window:AddTab("Scrap"),
    Status   = Window:AddTab("Status"),
    Settings = Window:AddTab("Settings"),
}

local function toggle(box, idx, key, text, tip, extra)
    box:AddToggle(idx, {
        Text = text, Tooltip = tip, Default = CFG[key],
        Callback = function(v)
            CFG[key] = v
            if extra then extra(v) end
        end,
    })
end
local function slider(box, idx, key, text, min, max, suffix, tip)
    box:AddSlider(idx, {
        Text = text, Tooltip = tip, Default = CFG[key], Min = min, Max = max, Rounding = 0, Suffix = suffix,
        Callback = function(v) CFG[key] = v end,
    })
end
local function multi(box, idx, key, text, values, tip)
    local defaults = {}
    for _, v in ipairs(values) do if CFG[key][v] then defaults[#defaults + 1] = v end end
    box:AddDropdown(idx, {
        Text = text, Tooltip = tip, Values = values, Default = defaults, Multi = true,
        Callback = function(v)
            local t = {}
            for _, name in ipairs(values) do t[name] = v[name] == true end
            CFG[key] = t
        end,
    })
end

-- ---------- Bot ----------
local Depths = Tabs.Bot:AddLeftGroupbox("Depths — money")
toggle(Depths, "BBB_Depths", "depths", "Auto Depths", "Runs the Depths for money; between runs the bot drains your stations at the plot (that's where XP comes from)")
slider(Depths, "BBB_MaxRun", "maxRun", "Max run length", 0, 300, "s", "Go home after this long even if the bot is still winning. 0 = until defeat")
slider(Depths, "BBB_DrainTo", "drainTo", "Leave plot at station fill", 0, 100, "%", "Start the next run once the fullest station buffer is at or below this")
slider(Depths, "BBB_DrainMax", "drainMax", "Max plot stay", 5, 120, "s", "…or after this long at the plot, whichever comes first")
toggle(Depths, "BBB_Skip", "skip", "Use wave skip", "Start runs at your best wave (costs half of what waves 1..N pay)")
slider(Depths, "BBB_SkipPct", "skipPct", "Skip only if cost ≤", 1, 100, "% of money")

local Pit = Tabs.Bot:AddRightGroupbox("Pit Events — crates, coins, boosts")
toggle(Pit, "BBB_Events", "events", "Auto Pit Events", "Tiers are server-wide: the bot only needs to land one hit to get the full rewards")
multi(Pit, "BBB_EventKinds", "eventKinds", "Events to join", EVENT_KINDS)
Pit:AddDropdown("BBB_PitMode", {
    Text = "In the Pit", Values = { "Join, then leave", "Stay whole event" }, Default = "Join, then leave",
    Tooltip = "Leaving is safe (joined survives it) and frees the bot for the Depths. Staying farms event-kill quests but risks PvP KOs",
    Callback = function(v) CFG.stay = v == "Stay whole event" end,
})
slider(Pit, "BBB_TitanHold", "titanHold", "Titan: time in Pit", 5, 60, "s", "The Titan sends no joined flag; count as joined after this long in the Pit")
slider(Pit, "BBB_ManualPause", "manualPause", "Pause after manual command", 0, 300, "s", "When you click TO ARENA / DEPTHS / GARAGE yourself, hands off for this long. 0 = never pause")

-- ---------- Crates & Parts ----------
local RARITY_KEEP = { ["Rare+"] = 3, ["Epic+"] = 4, ["Legendary+"] = 5, ["Mythic+"] = 6, ["Godly only"] = 7, ["Sell any rarity"] = 99 }
local RARITY_KEEP_ORDER = { "Rare+", "Epic+", "Legendary+", "Mythic+", "Godly only", "Sell any rarity" }

local Fab = Tabs.Crates:AddLeftGroupbox("Fabricator & Crates")
toggle(Fab, "BBB_Claim", "claim", "Auto Claim Crates", "Fabricator pile -> inventory, from anywhere (what the AUTO CLAIM pass does). A full pile stops deliveries")
toggle(Fab, "BBB_Fabricator", "fabricator", "Auto Fabricator", "Each level: -9 s delivery, +3 storage, better crate odds, more bulk copies. Levels unlock with rebirths")
toggle(Fab, "BBB_Open", "open", "Auto Open Crates", "Opening is the only use for crates; parts from Lava+ can be Mythic/Godly", applyReveal)
multi(Fab, "BBB_OpenKinds", "openKinds", "Crate types to open", CrateConfig.CRATE_ORDER)
toggle(Fab, "BBB_HideReveal", "hideReveal", "Hide reveal animation", "Mutes the tap-to-reveal overlay while auto-opening so it doesn't queue up", applyReveal)
toggle(Fab, "BBB_HoldLuck", "holdLuck", "Hold crates for CRATE LUCK events", "Admin 'CRATE LUCK' events multiply the rare-part odds. These are rare and unscheduled — crates at/above the tier below wait for one")
Fab:AddDropdown("BBB_HoldTier", {
    Text = "Hold crates from", Values = CrateConfig.CRATE_ORDER, Default = CrateConfig.CRATE_ORDER[CFG.holdTier],
    Callback = function(v) CFG.holdTier = (CrateConfig.CRATES[v] or { tier = 3 }).tier end,
})
local fabLabel = Fab:AddLabel("…", true)

local Parts = Tabs.Crates:AddRightGroupbox("Parts")
toggle(Parts, "BBB_Equip", "equip", "Auto Equip Best", "Highest stat per slot (attack/health/crit/speed); satellites by rarity, then crate tier. Only while the bot is home")
multi(Parts, "BBB_EquipSlots", "equipSlots", "Slots to manage", BotParts.SLOT_ORDER, "Leave a slot out to keep your own pick (e.g. a favourite satellite special)")
toggle(Parts, "BBB_SellJunk", "sellJunk", "Auto Sell Junk", "Sells everything except the best N per slot, locked parts, parts on any build, and the rarities you protect. Irreversible")
slider(Parts, "BBB_KeepPerSlot", "keepPerSlot", "Keep best per slot", 1, 10, "")
Parts:AddDropdown("BBB_KeepRarity", {
    Text = "Never sell", Values = RARITY_KEEP_ORDER, Default = "Mythic+",
    Callback = function(v) CFG.keepRarity = RARITY_KEEP[v] or 6 end,
})
Parts:AddButton({ Text = "Sell junk now", Func = function()
    local on = CFG.sellJunk
    CFG.sellJunk = true
    safe("sell", sellTick)
    CFG.sellJunk = on
end })
local partsLabel = Parts:AddLabel("…", true)

-- The game's own AUTO SELL (free, server-side): parts of these rarities are sold as crates open and
-- never reach the inventory. Server state is the source of truth — the dropdown mirrors it and only
-- writes back what you change (never on load/autoload).
local RARITY_NAMES = {}
for i, r in ipairs(require(Shared:WaitForChild("BotEffects")).RARITIES) do RARITY_NAMES[i] = r.name end
local GameSell = Tabs.Crates:AddRightGroupbox("Game's AUTO SELL")
GameSell:AddLabel("Built into the game (same toggles as its inventory): chosen rarities are sold the moment a crate opens, before they take a slot. Common/Uncommon never beat a Rare+ part.", true)
local gameSell = GameSell:AddDropdown("BBB_GameAutoSell", {
    Text = "Auto-sell rarities", Values = RARITY_NAMES, Multi = true, Default = {},
    Callback = function(v)
        local st = S.reward and S.reward.settings
        if S.syncingSell or typeof(st) ~= "table" then return end
        for i, name in ipairs(RARITY_NAMES) do
            local want = v[name] == true
            if want ~= (st["AutoSell" .. i] == true) then
                R.reward:FireServer("setSetting", "AutoSell" .. i, want)
                st["AutoSell" .. i] = want
                log(("game AUTO SELL %s -> %s"):format(name, want and "on" or "off"))
            end
        end
    end,
})

-- ---------- Upgrades ----------
local Plot = Tabs.Upgrades:AddLeftGroupbox("Plot")
toggle(Plot, "BBB_Upgrades", "upgrades", "Auto Stations & Workshop", "Buys empty pads, workshop levels (more pads) and station levels — whichever gives the most fuel/s per coin")
toggle(Plot, "BBB_WorkshopFirst", "workshopFirst", "Workshop first", "Buy the next workshop level as soon as it's affordable (each opens a pad with cheap early levels)")
slider(Plot, "BBB_StationCap", "stationCap", "Station level cap", 0, 100, "", "Stop upgrading stations at this level. 0 = no cap")
slider(Plot, "BBB_Reserve", "reserve", "Keep in reserve", 0, 90, "% of money", "Plot and fabricator upgrades only spend what's above this")

local Skills = Tabs.Upgrades:AddRightGroupbox("Skill Tree")
toggle(Skills, "BBB_Skills", "skills", "Auto Skill Tree", "Spends the skill points every rebirth pays")
Skills:AddDropdown("BBB_SkillFocus", {
    Text = "Focus", Values = { "Economy", "Combat", "Crates", "Cheapest" }, Default = CFG.skillFocus,
    Tooltip = "Economy: money/energy/depths pay · Combat: power/armor · Crates: luck/delivery/slots · Cheapest: any",
    Callback = function(v) CFG.skillFocus = v end,
})
toggle(Skills, "BBB_SaveForTop", "saveForTop", "Save points for top pick", "Wait for the best node of your focus instead of spending on cheap off-focus ones")

local Reb = Tabs.Upgrades:AddRightGroupbox("Rebirth")
toggle(Reb, "BBB_Rebirth", "rebirth", "Auto Rebirth", "Resets money, bot levels, best wave, stations, workshop and scrapper (the farm rebuilds them). Pays +money/+energy % and skill points")
slider(Reb, "BBB_RebirthExtra", "rebirthExtra", "Extra waves before rebirth", 0, 30, "", "Rebirth once the best wave is this far past the requirement")
slider(Reb, "BBB_RebirthMax", "rebirthMax", "Stop at rebirth", 0, 100, "", "0 = no limit")
-- The game's own AUTO REBIRTH is a pass (Perk_AutoRebirth); mirror its switch when you own it
local gameReb
if LP:GetAttribute("Perk_AutoRebirth") == true then
    gameReb = Reb:AddToggle("BBB_GameAutoRebirth", {
        Text = "Game's AUTO REBIRTH (pass)", Default = false,
        Tooltip = "The pass's own switch. Use this or Auto Rebirth above, not both",
        Callback = function(v) if not S.syncingReb then R.rebirth:FireServer("auto", v) end end,
    })
else
    Reb:AddLabel("The game's AUTO REBIRTH is a pass you don't own. Auto Rebirth above does the same, free.", true)
end

-- ---------- Rewards ----------
local Claims = Tabs.Rewards:AddLeftGroupbox("Claims")
toggle(Claims, "BBB_Playtime", "playtime", "Playtime rewards", "1 / 5 / 10 / … / 120 min tiers (per session)")
toggle(Claims, "BBB_Daily", "daily", "Daily login")
toggle(Claims, "BBB_Quests", "quests", "Daily & weekly quests")
toggle(Claims, "BBB_Guild", "guild", "Guild chests", "Day and week ladders")
local Codes = Tabs.Rewards:AddRightGroupbox("Codes")
Codes:AddButton({ Text = "Redeem BUILDABOT", Func = function() R.reward:FireServer("redeemCode", "BUILDABOT") end })

-- ---------- Scrap ----------
local Scrap = Tabs.Scrap:AddLeftGroupbox("Scrap — character farm")
Scrap:AddLabel("Your character sweeps scrap in the Pit (4.5-stud pickup, carry 20) and teleports it to your Scrapper, alongside whatever the bot is doing.", true)
toggle(Scrap, "BBB_Scrap", "scrap", "Auto Collect Scrap", "It's PvP in the Pit — a bot smash can KO your character mid-sweep")
toggle(Scrap, "BBB_FrenzyOnly", "frenzyOnly", "Only during Scrap Frenzy", "Frenzy drops 2 scrap per kill")
slider(Scrap, "BBB_MinGround", "minGround", "Start a trip at", 1, 12, " pieces", "Wait until this many pieces are on the ground")
toggle(Scrap, "BBB_ScrapReturn", "scrapReturn", "Return to start after each trip")
toggle(Scrap, "BBB_Scrapper", "scrapper", "Auto Upgrade Scrapper", "×1.24 scrap value per level; levels need Depths waves")
local scrapLabel = Scrap:AddLabel("…", true)

local Raid = Tabs.Scrap:AddRightGroupbox("Alien Raid")
Raid:AddLabel("Every ~10 min the ship drops Alien crates into the Pit. A crate is yours only if your character stays with it in the Pit for the whole capture timer — the catcher parks there (hopping to dodge lasers) and pauses scrap/upgrade teleports until the raid ends.", true)
toggle(Raid, "BBB_Raid", "raid", "Catch Alien Crates", "Alien crates: 42% Rare, 29% Epic, 7.5% Legendary+, incl. 2.25% Mythic / 0.75% Godly")
local raidLabel = Raid:AddLabel("…", true)

-- ---------- Status ----------
local Stat = Tabs.Status:AddLeftGroupbox("Status")
local statusLabel = Stat:AddLabel("…", true)
local Log = Tabs.Status:AddRightGroupbox("Log")
local logLabel = Log:AddLabel("", true)

task.spawn(function()
    while S.alive do
        pcall(function()
            local now = os.clock()
            local evs = {}
            for kind, e in pairs(S.evs) do evs[#evs + 1] = kind .. (e.joined and " (joined)" or "") end
            local hours = math.max((now - S.t0) / 3600, 1 / 60)
            local s, w = scrapper(), workshop()
            statusLabel:SetText(table.concat({
                ("bot: %s %ds%s"):format(tostring(S.mode), math.floor(now - S.modeAt), now < (S.manualUntil or 0) and "  [paused: manual]" or ""),
                ("event: %s"):format(#evs > 0 and table.concat(evs, ", ") or "none"),
                ("money %s · earned %s (%s/h)"):format(compact(money.Value), compact(S.earned), compact(S.earned / hours)),
                ("stations fill %d%% · workshop LV.%s · upgrades %d"):format(math.floor(stationFill() * 100), tostring(w and w.lv), S.upgrades),
                ("rebirths %s · best wave %s · skill pts %s"):format(tostring(LP:GetAttribute("Rebirths")), tostring(LP:GetAttribute("BestDepthWave")), tostring(S.sk and S.sk.points or LP:GetAttribute("SkillPoints"))),
                ("depth runs %d · events %d · opens %d · equips %d"):format(S.runs, S.events, S.opened, S.equips),
            }, "\n"))
            logLabel:SetText(table.concat(S.log, "\n", math.max(1, #S.log - 13)))
            -- mirror the game's own auto switches (server state) without writing them back
            local st = S.reward and S.reward.settings
            if typeof(st) == "table" and S.sellSeen ~= S.rewardAt then
                S.sellSeen = S.rewardAt
                local on = {}
                for i, name in ipairs(RARITY_NAMES) do if st["AutoSell" .. i] == true then on[name] = true end end
                S.syncingSell = true
                gameSell:SetValue(on)
                S.syncingSell = false
            end
            if gameReb and S.rb and gameReb.Value ~= (S.rb.auto == true) then
                S.syncingReb = true
                gameReb:SetValue(S.rb.auto == true)
                S.syncingReb = false
            end
            local gar = S.garage
            if gar then
                local unopened = 0
                for _, c in pairs(S.counts) do unopened += tonumber(c) or 0 end
                local lucky = luckEvent()
                fabLabel:SetText(("fabricator LV.%s%s · pile %d/%s · next %ds\nluck bar %.0f%% · unopened crates %d%s")
                    :format(tostring(gar.level), gar.maxed and " (max)" or (gar.locked and (" (LV." .. tostring((gar.level or 0) + 1) .. " at rebirth " .. tostring(gar.needRebirths) .. ")") or (" (next " .. compact(gar.cost or 0) .. ")")),
                        typeof(gar.pending) == "table" and #gar.pending or 0, tostring(gar.capacity), math.floor(tonumber(gar.timer) or 0),
                        tonumber(gar.luckPercent) or 0, unopened, lucky and (" · CRATE LUCK ×" .. tostring(lucky) .. "!") or ""))
            end
            if S.gsync and S.gsync.parts then
                local junk, value = junkParts()
                partsLabel:SetText(("parts %d/%d · junk by current rules: %d (~%s)")
                    :format(#S.gsync.parts, CrateConfig.inventorySlots(LP), #junk, compact(value)))
            end
            raidLabel:SetText(("%s · crates in the Pit %d · caught this session %d")
                :format(S.raid and (S.raidBusy and "RAID — holding a crate" or "RAID — waiting for a drop") or "no raid",
                    #raidCrates(), S.alienCaught or 0))
            scrapLabel:SetText(("carrying %d · delivered %d pieces (%s base value)\nscrapper %s · on ground %d%s")
                :format(carried(), S.scrapPieces, compact(S.scrapBase), s and ("LV." .. tostring(s.lv)) or "?",
                    #workspace.Materials:GetChildren(), S.evs.frenzy and " · FRENZY" or ""))
        end)
        task.wait(0.5)
    end
end)

Library:OnUnload(function()
    S.alive = false
    for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
    pcall(applyReveal)
    getgenv().BBB_FARM = nil
end)
S.unload = function() pcall(function() Library:Unload() end) end

-- ---------- Settings ----------
local Menu = Tabs.Settings:AddLeftGroupbox("Menu")
toggle(Menu, "BBB_AntiAfk", "antiAfk", "Anti-AFK", "Stops the 20-minute idle kick")
Menu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "BBB_GameAutoSell", "BBB_GameAutoRebirth" }) -- server-stored; a saved copy would fight it
SaveManager:SetFolder("BattleBotFarm")
ThemeManager:SetFolder("BattleBotFarm")
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:LoadAutoloadConfig()

log("loaded — bot is " .. S.mode)
Library:Notify("Battle Bot Farm ready — RightCtrl toggles the UI. Save a config in Settings to keep your toggles.", 5)
