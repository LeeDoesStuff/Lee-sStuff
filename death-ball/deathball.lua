-- CruelHub · Death Ball
-- Auto parry with aim (reads the real ball through rawget; never touches the guarded lBall class), auto moves
-- per champion, human-like movement, auto ready, tutorial automation, ball visuals, and a multi-account swarm
-- (host drives alts over shared workspace files: servers, autoplay, aim, moves, movement, votes, rules, performance).
-- Spec: deathball-spec.md. Re-exec safe: a newer copy unloads the older one.
if getgenv().CruelHubDB then pcall(getgenv().CruelHubDB.unload) end
local self = {}
getgenv().CruelHubDB = self
-- newest copy wins: a copy whose generation is stale unloads itself (double loads after teleports)
getgenv().CruelHubDB_GEN = (getgenv().CruelHubDB_GEN or 0) + 1
local GEN = getgenv().CruelHubDB_GEN

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local VIM = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")
local RS = game:GetService("ReplicatedStorage")
local RF = game:GetService("ReplicatedFirst")
local LP = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local TUTORIAL_PLACE = 109661515411512
local LOADER = 'loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/LuaLoader/main/loader.lua"))()'
local DIR = "CruelHub/DeathBall"
local SWARM = DIR .. "/swarm"
local hasFiles = writefile and readfile and isfile and makefolder and isfolder
if hasFiles then
	for _, d in { "CruelHub", DIR, SWARM } do if not isfolder(d) then pcall(makefolder, d) end end
end

local CFG = {
	parry = false, lead = 0.45, pingComp = true, closeDist = 14, humanize = 0, aimMode = "Off", aimName = "",
	slotMode = { "Smart", "Smart", "Smart", "Smart" }, moveKind = "Off", followName = "", followDist = 12,
	aimStyle = "Auto (per account)", aimLog = false,
	moveBand = 80, dashChance = 0.1, spread = false, spreadDist = 25, idleMove = false, idleAfkMax = 25, persona = "Auto (per account)", animFix = true,
	clash = true, clashDist = 18, clashSpeed = 150,
	autoReady = false, antiAfk = true,
	tutorial = true, requeue = true,
	marker = true, markerColor = Color3.fromHex("e0233c"), info = true, velLine = false, pathLine = true,
	predict = true, predMove = true,
	perfFps = 60, perf3d = false, perfLow = false, perfMute = false, memGuard = true, memLimit = 2100,
}
local conns, alive = {}, true
local Library -- set by the UI section; earlier code (swarm role sync) checks it
local function on(sig, fn) local c = sig:Connect(fn) conns[#conns + 1] = c return c end

-- ============================== game state ==============================
local Values, Inventory
pcall(function() Values = require(RS:WaitForChild("Values", 10)) end)
pcall(function() Inventory = require(RF.Core.Inventory) end)
local function val(name)
	local ok, v = pcall(function() return Values[name]:Get() end)
	return ok and v or nil
end
local function stat(key)
	local ok, v = pcall(function() return Inventory:Get().Statistics[key] end)
	return ok and v or 0
end
local function tutorialStage()
	local ok, v = pcall(function() return Inventory:Get().TutorialStage end)
	return ok and v or nil
end
local function inGame(plr) return (plr or LP):GetAttribute("IsInGame") == true end
local function hrpOf(plr)
	local ch = (plr or LP).Character
	return ch and ch:FindFirstChild("HumanoidRootPart")
end
local function typing() return UIS:GetFocusedTextBox() ~= nil end

-- ============================== input ==============================
local function key(k)
	if typing() then return end
	VIM:SendKeyEvent(true, k, false, game)
	task.wait(0.03)
	VIM:SendKeyEvent(false, k, false, game)
end
local function clickAt(x, y)
	VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
	task.wait(0.05)
	VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
end
local function shown(g)
	local x = g
	while x and x ~= LP.PlayerGui do
		if (x:IsA("GuiObject") and not x.Visible) or (x:IsA("ScreenGui") and not x.Enabled) then return false end
		x = x.Parent
	end
	return g.AbsoluteSize.X > 0
end
-- Game buttons listen on InputBegan/InputEnded. Firing those connections works in background windows, where
-- injected mouse clicks are ignored (measured 2026-10-08: a VIM click on a background client did nothing).
-- Executors without getconnections fall back to a real VIM click.
local function fireButton(g)
	if type(getconnections) ~= "function" then return false end
	local pos = g.AbsolutePosition + g.AbsoluteSize / 2
	local function fake(state)
		return { UserInputType = Enum.UserInputType.MouseButton1, UserInputState = state, Position = Vector3.new(pos.X, pos.Y, 0),
			KeyCode = Enum.KeyCode.Unknown, Delta = Vector3.zero }
	end
	local fired = false
	local ok = pcall(function()
		for _, c in getconnections(g.InputBegan) do c:Fire(fake(Enum.UserInputState.Begin)) fired = true end
		task.wait(0.05)
		for _, c in getconnections(g.InputEnded) do c:Fire(fake(Enum.UserInputState.End)) fired = true end
		if g:IsA("GuiButton") then for _, sig in { g.Activated, g.MouseButton1Click } do for _, c in getconnections(sig) do c:Fire() fired = true end end end
	end)
	return ok and fired
end
local function clickGui(g)
	if fireButton(g) then return end
	local sg = g:FindFirstAncestorWhichIsA("ScreenGui")
	local inset = (sg and not sg.IgnoreGuiInset) and GuiService:GetGuiInset() or Vector2.zero
	local p = g.AbsolutePosition + g.AbsoluteSize / 2 + inset
	clickAt(p.X, p.Y)
end
local function clickWorld(pos)
	local v, onScreen = Camera:WorldToViewportPoint(pos)
	if onScreen then clickAt(v.X, v.Y) return true end
end
local function walkTo(pos)
	local ch = LP.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if hum then hum:MoveTo(pos) end
end

-- ============================== ball reader ==============================
-- getgc route (exact): ball tables are read with rawget only. The position lives obfuscated in a store
-- table keyed by ball Id; offsets come from a gc table with numeric Position/_last/_sPosition.
-- NEVER tostring/print `offs`, `store` or a ball table: their __tostring is an anti-cheat trap.
local hasGc = type(getgc) == "function"
local offs, store
local balls = {}
local lastScan, lastBallId = 0, nil
local mode = hasGc and "exact" or "fallback"

local function scan()
	lastScan = os.clock()
	table.clear(balls)
	if not hasGc then return end
	local ok = pcall(function()
		for _, t in getgc(true) do
			if type(t) == "table" then
				local b = rawget(t, "Body")
				if typeof(b) == "Instance" and b.Parent and rawget(t, "Id") ~= nil and rawget(t, "interpolatorSpring") ~= nil then
					balls[#balls + 1] = t
				end
				if not offs and type(rawget(t, "Position")) == "number" and type(rawget(t, "_sPosition")) == "number"
					and type(rawget(t, "_last")) == "number" then offs = t end
			end
		end
		if offs and balls[1] and not store then -- the store is module-level (one table for every ball): find it once
			local id = rawget(balls[1], "Id")
			local len = 9 + math.max(rawget(offs, "Position"), rawget(offs, "_last"), rawget(offs, "_sPosition")) + 24 + 15
			do
				for _, t in getgc(true) do
					if type(t) == "table" and t ~= offs then
						local v = rawget(t, id)
						if type(v) == "string" and #v == len then store = t break end
					end
				end
			end
		end
	end)
	if not ok then hasGc, mode = false, "fallback" end
end

local function exactPos(b)
	local s = store and rawget(store, rawget(b, "Id"))
	if type(s) ~= "string" or not offs then return end
	local buf = buffer.fromstring(string.sub(s, 10, #s - 15))
	local o = rawget(offs, "Position")
	return Vector3.new(buffer.readf64(buf, o), buffer.readf64(buf, o + 8), buffer.readf64(buf, o + 16))
end

-- fallback (executors without getgc, by design — not live-tested): the Body part's position is scrambled
-- every frame except mostly at PreAnimation; accept samples that are consistent with the last one.
local fb = { pos = nil, vel = Vector3.zero, t = 0, rejects = 0 }
local function findBody()
	for _, c in workspace:GetChildren() do
		if c.Name == "Part" and c:IsA("BasePart") and c:FindFirstChildOfClass("Highlight") and c:FindFirstChildOfClass("Trail") then return c end
	end
end
on(RunService.PreAnimation, function()
	if mode ~= "fallback" or not inGame() then return end
	local body = findBody()
	if not body then fb.pos = nil return end
	local p, now = body.Position, os.clock()
	if fb.pos then
		local dt = math.max(now - fb.t, 1 / 240)
		local jump = (p - fb.pos).Magnitude
		if jump > 25 + fb.vel.Magnitude * dt * 3 and fb.rejects < 3 then fb.rejects += 1 return end
		fb.vel = fb.vel:Lerp((p - fb.pos) / dt, 0.5)
	end
	fb.pos, fb.t, fb.rejects = p, now, 0
	fb.body = body
end)

-- trajectory: the ball homes on its target. Shape from the game's client step (lBall._predictionUpdate):
-- velocity steers toward dir*Speed, gain x0.3 for 0.5 s after hitting a wall, floor at GroundHeight + Radius.
-- Constants FITTED to 12 real hits (2026-10-08, 592 samples): the server turns harder than the client formula
-- (gain 6/s, x1.25 above speed 500, vs the client's 4), no 25-stud snap, and a hit lands ~12 studs from the root.
local function lerpN(a, b, t) return a + (b - a) * t end
local function simulate(b, target, tvel, horizon, path)
	if b.anchored then return math.huge end
	local p, v, spd = b.pos, b.vel, b.speed
	local dt = 1 / 120
	local hitR = 12
	local coll = b.coll or 1
	for i = 1, math.floor(horizon / dt) do
		local t = i * dt
		local d = target + tvel * t - p
		local m = d.Magnitude
		if m <= hitR or spd * dt >= m then return t, p end
		if not b.seekOff and spd > 0 then
			local want = d.Unit * spd
			v += (want - v) * lerpN(6, 7.5, math.clamp((spd - 300) / 200, 0, 1)) * coll * dt
		end
		p += v * dt
		if b.ground and p.Y < b.ground + b.radius then p = Vector3.new(p.X, b.ground + b.radius, p.Z) end
		if path and i % 10 == 0 then path[#path + 1] = p end
	end
	return math.huge
end

-- one snapshot per frame: { pos, vel, speed, mine, target(Player?) }
local function readBalls()
	local out = {}
	if mode == "exact" then
		for _, b in balls do
			local body = rawget(b, "Body")
			if body and body.Parent then
				local p = exactPos(b)
				if p then
					local tgt = rawget(b, "Target")
					out[#out + 1] = {
						pos = p, vel = rawget(b, "Velocity") or Vector3.zero, speed = rawget(b, "Speed") or 0,
						mine = rawget(b, "isTargettingLocalPlayer") == true, radius = rawget(b, "Radius") or 2,
						ground = rawget(b, "GroundHeight"), seekOff = rawget(b, "isSeekDisabled") == true, anchored = rawget(b, "Anchored") == true,
						coll = (rawget(b, "collideTick") and os.clock() - rawget(b, "collideTick") < 0.5) and 0.3 or 1,
						interp = tonumber(rawget(b, "_currentInterpolationDelay")) or 0.048,
						target = typeof(tgt) == "Instance" and tgt.Parent and Players:GetPlayerFromCharacter(tgt.Parent) or nil,
					}
				end
			end
		end
	elseif fb.pos and fb.body and fb.body.Parent then
		local hl = fb.body:FindFirstChildOfClass("Highlight")
		out[1] = { pos = fb.pos, vel = fb.vel, speed = fb.vel.Magnitude, mine = hl and hl.FillTransparency < 0.5 or false, radius = 2 }
	end
	return out
end

-- ============================== swarm bus ==============================
-- Same-PC accounts share the executor workspace: the host writes swarm/host.json (commands, autoplay,
-- rules, performance); every account writes swarm/acc_<UserId>.json as a heartbeat. Role is per UserId.
local SW = { role = "Off", host = nil, members = {}, lastSeen = 0, obey = true, status = "-" }
local function jread(path)
	if not hasFiles or not isfile(path) then return end
	local ok, d = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
	return ok and d or nil
end
local function jwrite(path, t) if hasFiles then pcall(writefile, path, HttpService:JSONEncode(t)) end end
local ROLE_FILE = SWARM .. "/role_" .. LP.UserId .. ".txt"
local SEEN_FILE = SWARM .. "/seen_" .. LP.UserId .. ".txt"
if hasFiles and isfile(ROLE_FILE) then SW.role = readfile(ROLE_FILE) end
if hasFiles and isfile(SEEN_FILE) then SW.lastSeen = tonumber(readfile(SEEN_FILE)) or 0 end

local HOSTF = SWARM .. "/host.json"
local hostState = {
	id = LP.UserId, name = LP.Name, seq = 0, cmds = {},
	autoplay = { ready = false, parry = false },
	rules = { loseHostLastAlive = false, loseSwarmLastAlive = false, loseAliveLE = 0, loseSpeedGE = 0, loseAfter = 0, final = "Always" },
	perf = { on = false, fps = 30, no3d = true, low = true, mute = true },
	lock = false,
	parry = {},
	play = { aimMode = "Not swarm", aimName = "", moves = "Own", moveKind = "Human", followName = "", followDist = 12,
		spread = true, spreadDist = 25, diverseAim = true, pushParry = false, parryPushAt = 0, copyAim = false, copyMoves = false, copyMovement = false, copyTutorial = false, copyVote = true, voteMode = "Copy me", voteMap = "Copy me", tutorial = true, stayWithHost = false, idleMove = "Own", diverse = true,
		attack = { on = false, pick = "Auto", name = "", victim = "" },
		whitelistHost = true, whitelist = {} },
	vote = {},
}
do -- a re-elected host keeps its sequence numbers, so alts don't ignore its new commands
	local old = jread(HOSTF)
	if old and old.id == LP.UserId then
		hostState.seq = old.seq or 0
		hostState.autoplay = old.autoplay or hostState.autoplay
		hostState.rules = old.rules or hostState.rules
		hostState.rules.loseHostLastAlive = hostState.rules.loseHostLastAlive or hostState.rules.loseHostAlive or false
		hostState.rules.loseHostAlive = nil
		hostState.perf = old.perf or hostState.perf
		for k, v in pairs(old.play or {}) do hostState.play[k] = v end
		hostState.lock = old.lock or false
	end
end
local function hostWrite()
	hostState.t, hostState.placeId, hostState.jobId = os.time(), game.PlaceId, game.JobId
	hostState.slots = Players.MaxPlayers - #Players:GetPlayers()
	jwrite(HOSTF, hostState)
end
local function pushCmd(kind, args)
	hostState.seq += 1
	table.insert(hostState.cmds, { id = hostState.seq, kind = kind, args = args or {}, t = os.time() })
	while #hostState.cmds > 10 do table.remove(hostState.cmds, 1) end
	hostWrite()
end
local function hostLive() return SW.host and os.time() - (SW.host.t or 0) <= 10 end
local NOAUTO_FILE = SWARM .. "/noauto_" .. LP.UserId .. ".txt"
SW.noAuto = hasFiles and isfile(NOAUTO_FILE) or false
-- host parry settings: the host publishes them, alts copy them into their own UI (button or auto sync)
local PARRY_OPTS = { lead = "DB_Lead", pingComp = "DB_Ping", closeDist = "DB_Close", humanize = "DB_Human",
	clash = "DB_Clash", clashDist = "DB_ClashDist", clashSpeed = "DB_ClashSpeed", predict = "DB_Predict", predMove = "DB_PredMove" }
local parrySynced
local function applyHostParry()
	local hp = SW.host and SW.host.parry
	if not (hp and Library) then return false end
	for k, id in PARRY_OPTS do
		local el = Library.Options[id] or Library.Toggles[id]
		if el and hp[k] ~= nil and el.Value ~= hp[k] then el:SetValue(hp[k]) end
	end
	parrySynced = HttpService:JSONEncode(hp)
	return true
end
local function setRole(r)
	SW.role = r
	if hasFiles then pcall(writefile, ROLE_FILE, r) end
	if Library and Library.Options and Library.Options.SW_Role and Library.Options.SW_Role.Value ~= r then Library.Options.SW_Role:SetValue(r) end
end
local function following() return SW.role == "Swarm" and SW.obey and hostLive() end
local function isSwarmId(id)
	for _, m in SW.members do if m.id == id then return true end end
	return false
end

-- effective settings: swarm accounts follow the host's autoplay while it is online
local function eff(k)
	if following() then
		if k == "parry" then return SW.host.autoplay.parry end
		if k == "autoReady" then return SW.host.autoplay.ready end
		local pl = SW.host.play
		local hs = pl and pl.hostSettings
		if hs then
			if pl.copyAim and (k == "aimMode" or k == "aimName" or k == "aimStyle") and hs[k] ~= nil then return hs[k] end
			if pl.copyMovement and (k == "moveKind" or k == "followName" or k == "followDist" or k == "idleMove" or k == "idleAfkMax" or k == "moveBand" or k == "dashChance" or k == "persona" or k == "spread" or k == "spreadDist") and hs[k] ~= nil then return hs[k] end
			if pl.copyTutorial and k == "tutorial" and hs[k] ~= nil then return hs[k] end
		end
		if pl and pl[k] ~= nil and (k ~= "moveKind" or pl.moveKind ~= "Own") and (k ~= "aimMode" or pl.aimMode ~= "Own") then
			if k == "aimName" and pl.aimMode == "Own" then return CFG[k] end
			if (k == "followName" or k == "followDist") and pl.moveKind == "Own" then return CFG[k] end
			if k == "idleMove" then if pl.idleMove == "Own" then return CFG.idleMove end return pl.idleMove == "On" end
			return pl[k]
		end
	end
	return CFG[k]
end

-- ============================== performance ==============================
local perfApplied
-- memory guard: 7 clients at ~1.8 GB each ran a 16 GB PC at critical memory and crashed (2026-10-09 logs:
-- memoryPrioritizationCallback level 3 from 2 s after join). Above the limit: lowest graphics + 30 FPS, and
-- swarm accounts also stop 3D rendering. It lets go 300 MB below the limit.
local memGuard = { on = false, mb = 0 }
local function guarded(p)
	if not memGuard.on then return p end
	local g = table.clone(p or {})
	g.on, g.low = true, true
	g.fps = math.min((p and p.on and p.fps) or 30, 30)
	if SW.role == "Swarm" then g.no3d = true end
	return g
end
local function applyPerf(p)
	p = guarded(p or { on = false })
	local key_ = HttpService:JSONEncode(p)
	if key_ == perfApplied then return end
	perfApplied = key_
	if setfpscap then pcall(setfpscap, p.on and p.fps or 0) end
	pcall(function() RunService:Set3dRenderingEnabled(not (p.on and p.no3d)) end)
	pcall(function() settings().Rendering.QualityLevel = (p.on and p.low) and Enum.QualityLevel.Level01 or Enum.QualityLevel.Automatic end)
	pcall(function() UserSettings():GetService("UserGameSettings").MasterVolume = (p.on and p.mute) and 0 or 1 end)
end
local function localPerf()
	return { on = CFG.perfFps ~= 60 or CFG.perf3d or CFG.perfLow or CFG.perfMute, fps = CFG.perfFps, no3d = CFG.perf3d, low = CFG.perfLow, mute = CFG.perfMute }
end

-- ============================== win / lose rules ==============================
local roundStart
local function aliveList()
	local t = {}
	for _, p in Players:GetPlayers() do if inGame(p) then t[#t + 1] = p end end
	return t
end
local parryReason = "-"
local function allowedToParry(ball)
	if not following() then parryReason = "free" return true end
	local r = SW.host.rules or {}
	local host = Players:GetPlayerByUserId(SW.host.id)
	local al = aliveList()
	if r.loseHostLastAlive and host and #al == 1 and al[1] == host then parryReason = "host last alive" return false end
	if r.loseSwarmLastAlive and #al > 0 then
		local swarmLastAlive, hasSwarmAlt = true, false
		for _, p in al do
			if p.UserId ~= SW.host.id then
				if not isSwarmId(p.UserId) then swarmLastAlive = false break end
				hasSwarmAlt = true
			end
		end
		if swarmLastAlive and hasSwarmAlt then parryReason = "swarm last alive" return false end
	end
	if (r.loseAliveLE or 0) > 0 and #al <= r.loseAliveLE then parryReason = "alive <= " .. r.loseAliveLE return false end
	if (r.loseSpeedGE or 0) > 0 and ball.speed >= r.loseSpeedGE then parryReason = "speed" return false end
	if (r.loseAfter or 0) > 0 and roundStart and os.clock() - roundStart >= r.loseAfter then parryReason = "time" return false end
	if #al == 2 and inGame() then -- final duel: only win if...
		local opp = al[1] == LP and al[2] or al[1]
		local f = r.final or "Always"
		if f == "Never" then parryReason = "final: never" return false end
		if f == "Not vs host" and host and opp == host then parryReason = "final: host" return false end
		if f == "Not vs swarm" and (opp.UserId == SW.host.id or isSwarmId(opp.UserId)) then parryReason = "final: swarm" return false end
	end
	parryReason = "allowed"
	return true
end

-- ============================== auto parry ==============================
local stats = { parries = 0, startWins = stat("Wins:Total"), startDeflects = stat("Deflects:Total"), rounds = 0 }
local live = { text = "-" }
local lastPress, lastClash = 0, 0
-- ============================== aim ==============================
-- The server sends a deflected ball toward where your camera looks (CamLook replicates at 60 Hz).
-- Verified 2026-10-08: camera locked on a player 1 frame before F → ball went to that player 4/4.
local AIM_MODES = { "Off", "Player", "Nearest", "Farthest", "Random", "Not swarm", "Swarm", "Host" }
local aim = { at = nil, untilT = 0 }
RunService:BindToRenderStep("CruelHubDBAim" .. GEN, Enum.RenderPriority.Last.Value + 50, function()
	local p = aim.at
	local h = p and os.clock() < aim.untilT and hrpOf(p)
	if h then Camera.CFrame = CFrame.lookAt(Camera.CFrame.Position, h.Position) * CFrame.Angles(math.rad(aim.pitch or 0), math.rad(aim.yaw or 0), 0) end
end)

-- targeting styles, built from 110 real deflects (2026-10-09, Classic): real players launch off the straight line
-- (yaw offset median 14 deg, quartiles 5/14/26, 10 % over 70), some lean one side, a few aim down ~20 deg;
-- they send it back to whoever sent it 14-50 % of the time and to the nearest player 0-40 %, almost never the farthest.
-- yaw = {min, max} degrees, side = chance the offset goes right, ret/near/far = target choice weights (rest random).
local AIM_STYLES = {
	Straight = { yaw = { 0, 6 }, side = 0.5, down = 0.02, ret = 0.15, near = 0.10, far = 0.05 },
	["Curve right"] = { yaw = { 8, 26 }, side = 0.85, down = 0.05, ret = 0.30, near = 0.20, far = 0 },
	["Curve left"] = { yaw = { 8, 26 }, side = 0.15, down = 0.05, ret = 0.30, near = 0.20, far = 0 },
	Mixer = { yaw = { 4, 22 }, side = 0.5, down = 0.08, ret = 0.25, near = 0.15, far = 0 },
	Wild = { yaw = { 15, 60 }, side = 0.5, down = 0.10, ret = 0.40, near = 0.30, far = 0 },
	Returner = { yaw = { 3, 15 }, side = 0.5, down = 0.05, ret = 0.50, near = 0.20, far = 0 },
	Bully = { yaw = { 5, 18 }, side = 0.5, down = 0.10, ret = 0.15, near = 0.45, far = 0 },
}
local AIM_STYLE_NAMES = { "Straight", "Curve right", "Curve left", "Mixer", "Wild", "Returner", "Bully" }
local function aimStyle()
	local pick = eff("aimStyle") or CFG.aimStyle
	if following() and SW.host.play and SW.host.play.diverseAim and not SW.host.play.copyAim then pick = "Auto (per account)" end
	if pick == "Off" then return nil, "Off" end
	local name = AIM_STYLES[pick] and pick or AIM_STYLE_NAMES[(LP.UserId * 104729) % #AIM_STYLE_NAMES + 1]
	return AIM_STYLES[name], name
end
local lastSender -- who sent the ball to us last (for "return to sender")
-- coordinated attack: keep safe-passing until the chosen victim finishes a parry and is on cooldown.
local atkState = { phase = "-", parries = {} }
-- whitelist: swarm accounts never send the ball at the host (if whitelisted) or at whitelisted players
local function protected(p)
	if SW.role == "Host" then return table.find(hostState.play.whitelist or {}, p.Name) ~= nil end
	local pl = following() and SW.host.play
	if not pl then return false end
	if pl.whitelistHost and p.UserId == SW.host.id then return true end
	return table.find(pl.whitelist or {}, p.Name) ~= nil
end
local function attackAim()
	local atk = (SW.role == "Host" and hostState.play.attack) or (following() and SW.host.play and SW.host.play.attack)
	if not (atk and atk.on) then atkState.phase = "-" return nil, false end
	local b = live and live.balls and live.balls[1]
	local spd = b and b.speed or 0
	local function swarmish(p) return (SW.host and p.UserId == SW.host.id) or isSwarmId(p.UserId) end
	local v = Players:FindFirstChild(atk.victim or "")
	if v and v ~= LP and inGame(v) and not swarmish(v) and not protected(v) then
		local ch = v.Character
		local state = atkState.parries[v.UserId] or { active = false, readyAt = 0 }
		local active, now = ch and ch:GetAttribute("isDeflecting") == true or false, os.clock()
		local cfg = RS:FindFirstChild("RoundSettings") and RS.RoundSettings:FindFirstChild("Configuration")
		local cooldown = cfg and cfg:GetAttribute("BallDeflectCooldown") or 1.3
		local block = cfg and cfg:GetAttribute("BallDeflectBlockTime") or 0.7
		if active and not state.active then state.readyAt = now + cooldown end
		if state.active and not active then state.readyAt = math.max(state.readyAt, now + math.max(cooldown - block, 0)) end
		state.active = active
		atkState.parries[v.UserId] = state
		if not active and now < state.readyAt then atkState.phase = "attacking " .. v.Name .. " (parry cooldown)" return v, true end
		local mates, me = {}, hrpOf()
		local passSpd = math.max(spd + 10, 50)
		for _, p in Players:GetPlayers() do
			local h = p ~= LP and inGame(p) and swarmish(p) and not protected(p) and hrpOf(p)
			local d = h and me and (h.Position - me.Position).Magnitude
			if d and d >= 35 and d / passSpd >= 0.75 then mates[#mates + 1] = { p = p, d = d } end
		end
		table.sort(mates, function(a, b) return a.d > b.d end)
		if #mates > 0 then
			local mate = mates[math.random(1, math.min(2, #mates))].p
			atkState.phase = ("passing %.0f to %s; waiting for %s to parry"):format(spd, mate.Name, v.Name)
			return mate, true
		end
		atkState.phase = "waiting for " .. v.Name .. " to parry"
		return nil, true, true
	end
	atkState.phase = "no victim"
	return nil, true
end
local function pickAim()
	local ap, active, hold = attackAim()
	if hold then return end
	if ap then return ap end
	local m, name = eff("aimMode"), eff("aimName")
	if active and m ~= "Off" and m ~= "Not swarm" then m = "Not swarm" end -- never hand the ball to the swarm outside the pump phase
	if m == "Off" then return end
	local me = hrpOf()
	local c = {}
	for _, p in Players:GetPlayers() do
		if p ~= LP and inGame(p) and hrpOf(p) and not protected(p) then
			local sw = (SW.host and p.UserId == SW.host.id) or isSwarmId(p.UserId)
			if m == "Not swarm" and sw then continue end
			if m == "Swarm" and not sw then continue end
			c[#c + 1] = p
		end
	end
	if m == "Player" then
		local p = Players:FindFirstChild(name or "")
		return p and inGame(p) and not protected(p) and p or nil
	elseif m == "Host" then
		local p = SW.host and Players:GetPlayerByUserId(SW.host.id)
		return p and p ~= LP and inGame(p) and not protected(p) and p or nil
	end
	if #c == 0 then return end
	if (m == "Nearest" or m == "Farthest") and me then
		table.sort(c, function(a, b) return (hrpOf(a).Position - me.Position).Magnitude < (hrpOf(b).Position - me.Position).Magnitude end)
		return m == "Nearest" and c[1] or c[#c]
	end
	local st = aimStyle()
	if st and me then
		local r = math.random()
		if r < st.ret and lastSender and table.find(c, lastSender) then return lastSender end
		r -= st.ret
		table.sort(c, function(a, b) return (hrpOf(a).Position - me.Position).Magnitude < (hrpOf(b).Position - me.Position).Magnitude end)
		if r < st.near then return c[1] end
		r -= st.near
		if r < st.far then return c[#c] end
	end
	return c[math.random(1, #c)]
end
-- presses `k` with the camera on the aim target; waits 2 frames so CamLook replicates first
local function aimedKey(k)
	local p = pickAim()
	if p then
		local st = aimStyle()
		aim.yaw, aim.pitch = 0, 0
		if st then
			local mag_ = st.yaw[1] + math.random() * (st.yaw[2] - st.yaw[1])
			aim.yaw = (math.random() < st.side and -1 or 1) * mag_
			aim.pitch = math.random() < st.down and -(10 + math.random() * 15) or (math.random() * 4 - 2)
		end
		aim.at, aim.untilT = p, os.clock() + 0.3
		if hasFiles and CFG.aimLog then pcall(appendfile, DIR .. "/aimlog_" .. LP.Name .. ".txt",
			("%.2f %s yaw=%.1f pitch=%.1f\n"):format(workspace:GetServerTimeNow(), p.Name, aim.yaw, aim.pitch)) end
		RunService.RenderStepped:Wait()
		RunService.RenderStepped:Wait()
	end
	key(k)
	return p
end

-- ============================== moves (abilities) ==============================
-- Champion + its 4 slots come from Inventory + ChampionData; tags/cooldowns from AbilityData.HoverData.
local AbilityData, ChampionData = {}, {}
pcall(function() AbilityData = require(RS.DataBins.AbilityData) end)
pcall(function() ChampionData = require(RS.DataBins.ChampionData) end)
local SLOT_KEYS = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four }
local MOVE_MODES = { "Off", "Smart", "On cooldown", "Spam", "Save me", "When targeted" }
local function myChampion()
	local ok, r = pcall(function()
		local inv = Inventory:Get()
		local id = inv.EquippedChampions and inv.EquippedChampions[1]
		local c = id and inv.Champions[id]
		if not c then return end
		local data = ChampionData[c.Type] or {}
		local slots = {}
		for i = 1, 4 do
			local opts = data.Abilities and data.Abilities[i]
			local name = opts and opts[(c.Abilities and c.Abilities[i]) or 1] or (opts and opts[1])
			local a = name and AbilityData[name] or {}
			local tags = {}
			for t, v in pairs(a.HoverData or {}) do if v == true then tags[t] = true end end
			slots[i] = name and { name = name, cd = a.Cooldown or 30, active = a.ActiveTime, lvl = a.LevelRequirement or 0,
				unlocked = (c.Level or 1) >= (a.LevelRequirement or 0), tags = tags } or nil
		end
		return { type = c.Type, level = c.Level or 1, slots = slots }
	end)
	return ok and r or nil
end
local function smartMode(s)
	if s.tags.AutoDeflect then return "Save me" end
	if s.tags.Untargetable or s.tags.ExtraHealth then return "When targeted" end
	if s.tags.Movement and not s.tags.Passive then return "Off" end -- dashes/warps move you somewhere random
	return "On cooldown"
end
local moves = { champ = nil, lastUse = {}, text = "-" }
local function slotMode(i)
	local hs = following() and SW.host.play and SW.host.play.hostSettings
	if SW.host and SW.host.play and SW.host.play.copyMoves and hs and hs.slotMode then return hs.slotMode[i] or "Smart" end
	local o = following() and SW.host.play and SW.host.play.moves or "Own"
	if o == "Off all" then return "Off" end
	if o == "Spam all" then return "Spam" end
	if o == "Smart all" then return "Smart" end
	return CFG.slotMode[i] or "Smart"
end

-- ============================== movement ==============================
-- Human profile measured 2026-10-08 (7 real players, ~2 min each at 10 Hz, Classic):
-- moving 84 % of the time at walkspeed, bursts ~1.2 s / stops ~0.6 s, heading change every ~1.6 s,
-- dash (Q) in 1–8 % of samples, ~1 jump/min, ~86 studs from the ball when it isn't theirs.
local MOVE_KINDS = { "Off", "Human", "Follow host", "Follow player" }
local mv = { goal = nil, segEnd = 0, stopUntil = 0, userUntil = 0, text = "-", rng = Random.new(LP.UserId * 104729 % 2147483647), redScanUntil = 0, dodgeUntil = 0 }
local function arena()
	local am = workspace:FindFirstChild("ActiveMap")
	local map = am and am:GetChildren()[1]
	local floor = map and map:FindFirstChild("Floor")
	if floor and floor:IsA("BasePart") then return floor.Position + Vector3.new(0, floor.Size.Y / 2 + 3, 0), math.min(floor.Size.X, floor.Size.Z) / 2 end
	local sp = map and map:FindFirstChild("Spawns")
	if sp and #sp:GetChildren() > 0 then
		local sum, n = Vector3.zero, 0
		for _, s in sp:GetChildren() do if s:IsA("BasePart") then sum += s.Position n += 1 end end
		if n > 0 then return sum / n, 80 end
	end
end
function mv.dodgeBoss(hum, hrp, now)
	if now < mv.dodgeUntil then return true end
	if now < mv.redScanUntil then return false end
	mv.redScanUntil = now + 0.2
	local am = workspace:FindFirstChild("ActiveMap")
	local map = am and am:GetChildren()[1]
	local function warningIn(root)
		if not root then return false end
		for _, part in root:GetDescendants() do
			if part:IsA("BasePart") and part.Transparency < 0.8 and part.Color.R > 0.65 and part.Color.G < 0.35 and part.Color.B < 0.35
				and part.Size.Y < math.min(part.Size.X, part.Size.Z) * 0.25 then
				local name = part.Name:lower()
				if name:find("circle") or name:find("warning") or name:find("telegraph") or part:IsA("MeshPart")
					or (part:IsA("Part") and part.Shape == Enum.PartType.Cylinder) then
					local d = Vector3.new(hrp.Position.X - part.Position.X, 0, hrp.Position.Z - part.Position.Z).Magnitude
					if d <= math.max(part.Size.X, part.Size.Z) * 0.5 + 3 and math.abs(hrp.Position.Y - part.Position.Y) < 20 then return true end
				end
			end
		end
		return false
	end
	if warningIn(map) or warningIn(workspace:FindFirstChild("Effects")) then
		if hum.FloorMaterial == Enum.Material.Air then mv.dodgeUntil = now + 0.08
		else hum.Jump = true mv.dodgeUntil = now + 0.7 end
		return true
	end
	return false
end
local function idOffset(uid, r) -- stable ring slot per account, so a swarm doesn't stack on one spot
	local a = (uid % 997) / 997 * math.pi * 2
	return Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
end
-- personalities: each account moves a bit differently. The base numbers are the measured human averages;
-- every account gets one style (stable per UserId) plus its own +-15 % jitter, so a swarm never moves in sync.
local PERSONAS = {
	Average = { stop = 0.30, stopMin = 0.25, stopMax = 0.95, segMin = 0.6, segMax = 2.5, dash = 0.10, jump = 0.02, air = 0.02, band = 80, rMin = 0.15, rMax = 0.70, afk = 1.0 },
	Calm = { stop = 0.45, stopMin = 0.5, stopMax = 1.8, segMin = 1.2, segMax = 3.5, dash = 0.03, jump = 0.01, air = 0.00, band = 95, rMin = 0.20, rMax = 0.65, afk = 1.3 },
	Twitchy = { stop = 0.15, stopMin = 0.15, stopMax = 0.5, segMin = 0.35, segMax = 1.2, dash = 0.15, jump = 0.04, air = 0.06, band = 70, rMin = 0.10, rMax = 0.70, afk = 0.6 },
	Runner = { stop = 0.10, stopMin = 0.2, stopMax = 0.6, segMin = 1.5, segMax = 3.0, dash = 0.25, jump = 0.02, air = 0.10, band = 85, rMin = 0.30, rMax = 0.80, afk = 0.7 },
	Camper = { stop = 0.55, stopMin = 0.8, stopMax = 2.5, segMin = 0.6, segMax = 1.5, dash = 0.02, jump = 0.00, air = 0.00, band = 110, rMin = 0.55, rMax = 0.80, afk = 1.5 },
	Jumper = { stop = 0.25, stopMin = 0.25, stopMax = 0.9, segMin = 0.6, segMax = 2.0, dash = 0.08, jump = 0.12, air = 0.15, band = 80, rMin = 0.15, rMax = 0.70, afk = 0.9 },
	Bunny = { stop = 0.20, stopMin = 0.2, stopMax = 0.7, segMin = 0.5, segMax = 1.6, dash = 0.06, jump = 0.40, air = 0.08, band = 75, rMin = 0.15, rMax = 0.70, afk = 0.8 },
	Dasher = { stop = 0.15, stopMin = 0.2, stopMax = 0.6, segMin = 0.8, segMax = 2.2, dash = 0.50, jump = 0.04, air = 0.20, band = 85, rMin = 0.20, rMax = 0.80, afk = 0.7 },
	Strafer = { stop = 0.10, stopMin = 0.1, stopMax = 0.4, segMin = 0.25, segMax = 0.8, dash = 0.10, jump = 0.05, air = 0.04, band = 80, rMin = 0.10, rMax = 0.60, afk = 0.6 },
	Lazy = { stop = 0.65, stopMin = 1.0, stopMax = 3.5, segMin = 0.8, segMax = 2.0, dash = 0.01, jump = 0.01, air = 0.00, band = 100, rMin = 0.20, rMax = 0.60, afk = 1.7 },
}
local PERSONA_NAMES = { "Average", "Calm", "Twitchy", "Runner", "Camper", "Jumper", "Bunny", "Dasher", "Strafer", "Lazy" }
-- every account also gets its own wide trait multipliers (0.4x..2.5x on jump/dash/air/stop/segment), so two bots
-- with the same base style still differ: one jumps a lot, another barely dashes.
local TRAITS = { "jump", "dash", "air", "stop", "segMin", "segMax" }
local function persona()
	local pick = eff("persona") or "Auto (per account)"
	if following() and SW.host.play and SW.host.play.diverse and not SW.host.play.copyMovement then pick = "Auto (per account)" end
	if pick == "Off (measured average)" then
		local b = table.clone(PERSONAS.Average)
		b.dash, b.band, b.name = eff("dashChance"), eff("moveBand"), "Average"
		return b
	end
	local rng = Random.new(LP.UserId * 7919 % 2147483647)
	local name = PERSONAS[pick] and pick or PERSONA_NAMES[rng:NextInteger(1, #PERSONA_NAMES)]
	local out = { name = name }
	for k, v in PERSONAS[name] do out[k] = v * (0.85 + rng:NextNumber() * 0.3) end
	local trng = Random.new(LP.UserId * 31 + 7)
	for _, k in TRAITS do out[k] = out[k] * math.exp(trng:NextNumber(-0.9, 0.9)) end
	out.stop, out.jump, out.dash, out.air = math.min(out.stop, 0.8), math.min(out.jump, 0.6), math.min(out.dash, 0.7), math.min(out.air, 0.4)
	out.segMax = math.max(out.segMax, out.segMin + 0.2)
	out.rMax = math.min(out.rMax, 0.85)
	return out
end

local function humanGoal(hrp)
	local c, half = arena()
	if not c then return end
	local ball = live and live.balls and live.balls[1]
	local pp = persona()
	local band = pp.band
	for _ = 1, 10 do
		local a, r = mv.rng:NextNumber() * math.pi * 2, half * (pp.rMin + mv.rng:NextNumber() * (pp.rMax - pp.rMin))
		local g = c + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
		local ok = (g - hrp.Position).Magnitude > 12
		if ok and ball and not ball.mine and (g - ball.pos).Magnitude < band * 0.6 then ok = false end
		if ok and eff("spread") then
			for _, m in SW.members do
				local p = m.id ~= LP.UserId and Players:GetPlayerByUserId(m.id)
				local h = p and hrpOf(p)
				if h and (h.Position - g).Magnitude < (eff("spreadDist") or 25) then ok = false break end
			end
		end
		if ok then return g end
	end
	return c + idOffset(LP.UserId, half * 0.3)
end

local function press(why, ball, d, tti)
	lastPress = os.clock()
	stats.parries += 1
	local h = CFG.humanize
	task.spawn(function()
		if h > 0 then task.wait(math.random() * h / 1000) end
		local p = aimedKey(Enum.KeyCode.F)
		live.last = string.format("%s · %.0f studs · %.2fs · speed %.0f%s", why, d, tti, ball.speed, p and (" → " .. p.Name) or "")
	end)
end

on(RunService.Heartbeat, function()
	if not alive then return end
	local me = inGame()
	if me and not roundStart then roundStart = os.clock() stats.rounds += 1 end
	do
		local b0 = live.balls and live.balls[1]
		local t0 = b0 and (b0.mine and LP or b0.target)
		if t0 ~= live.prevTarget then
			if t0 == LP and live.prevTarget then lastSender = live.prevTarget end
			live.prevTarget = t0
		end
	end
	if not me then roundStart = nil end
	if mode == "exact" then
		local id = val("CURRENT_BALL_ID")
		local stale = #balls == 0 or not (rawget(balls[1], "Body") and rawget(balls[1], "Body").Parent)
		-- getgc(true) builds a table of every live object: costly on 7 clients. Scan on a new ball id, and while the ball
		-- isn't found retry with backoff (0.5, 1, 2, 4 s) instead of every second.
		if id ~= lastBallId then lastBallId, live.scanWait = id, 0.5 scan()
		elseif stale and id and os.clock() - lastScan > (live.scanWait or 0.5) then live.scanWait = math.min((live.scanWait or 0.5) * 2, 4) scan() end
	end
	local onTut = game.PlaceId == TUTORIAL_PLACE and eff("tutorial")
	local hrp = hrpOf()
	live.balls = (me or onTut) and readBalls() or {}
	if hrp then
		local mv = hrp.AssemblyLinearVelocity
		local tvel = CFG.predMove and Vector3.new(mv.X, 0, mv.Z) or Vector3.zero
		for _, b in live.balls do
			local rel = hrp.Position - b.pos
			b.closing = rel.Magnitude > 0 and b.vel:Dot(rel.Unit) or 0
			b.d = rel.Magnitude - b.radius
			b.path = nil
			if b.mine and CFG.predict then
				b.path = CFG.pathLine and { b.pos } or nil
				b.tti = simulate(b, hrp.Position, tvel, 3, b.path)
			else
				b.tti = b.closing > 1 and b.d / b.closing or math.huge
			end
		end
	end
	if not (eff("parry") or onTut) or not hrp then return end
	local ch = LP.Character
	for _, b in live.balls do
		if b.mine then
			local d, tti = b.d, b.tti
			-- the drawn ball runs ~interp behind the server's, and F needs one-way ping to arrive
			local lead = CFG.lead + (CFG.pingComp and (LP:GetNetworkPing() + b.interp) or 0)
			if not allowedToParry(b) then continue end
			local deflecting = ch:GetAttribute("isDeflecting")
			if CFG.clash and d <= CFG.clashDist and b.speed >= CFG.clashSpeed and os.clock() - lastClash > 0.12 then
				lastClash = os.clock()
				stats.parries += 1
				lastPress = os.clock()
				task.spawn(key, Enum.KeyCode.F)
			-- fly-by gate: a ball sweeping past (not closing fast) gets no early press; it curves back and we press then
			elseif ((tti <= lead and (b.closing >= 0.5 * b.speed or d < 25)) or (d <= CFG.closeDist and (b.closing > 0 or b.anchored)))
				and os.clock() - lastPress > 0.5 and not deflecting then
				press("parry", b, d, tti)
			end
		end
	end
end)

-- moves loop
task.spawn(function()
	local nextChamp = 0
	while alive do
		task.wait(0.1)
		if os.clock() > nextChamp then nextChamp = os.clock() + 5 moves.champ = myChampion() end
		local ch = moves.champ
		if not (ch and inGame()) then moves.round = nil continue end
		if not moves.round then -- new round: every account waits its own random time before its first move
			moves.round = true
			moves.nextOk = {}
			for i = 1, 4 do moves.nextOk[i] = os.clock() + 1.5 + math.random() * 12 end
		end
		local b = live.balls and live.balls[1]
		local mine = b and b.mine
		local tti = mine and b.tti or math.huge
		local deflectCd = (RS:FindFirstChild("RoundSettings") and RS.RoundSettings:FindFirstChild("Configuration")
			and RS.RoundSettings.Configuration:GetAttribute("BallDeflectCooldown")) or 1.3
		for i = 1, 4 do
			local s = ch.slots[i]
			if not (s and s.unlocked) then continue end
			local m = slotMode(i)
			if m == "Smart" then m = smartMode(s) end
			local since = os.clock() - (moves.lastUse[i] or 0)
			local ready = since >= s.cd + 0.3
			local fire = false
			if m == "Spam" then fire = since >= 0.2 + math.random() * 0.4
			elseif m == "On cooldown" then -- not the instant it's ready: a random extra wait + a per-check chance, so bots never sync
				fire = ready and os.clock() >= (moves.nextOk[i] or 0) and math.random() < 0.12
			elseif m == "When targeted" then fire = ready and mine and tti < 1.5
			elseif m == "Save me" then -- an AutoDeflect move parries for you: use it when F is on cooldown and the ball is close
				fire = ready and mine and tti < 1.1 and os.clock() - lastPress < deflectCd and b and allowedToParry(b)
			end
			if fire then
				moves.lastUse[i] = os.clock()
				moves.nextOk[i] = os.clock() + s.cd + 0.5 + math.random() * (3 + s.cd * 0.4)
				task.spawn(aimedKey, SLOT_KEYS[i])
				moves.text = ("%s (%s)"):format(s.name, m)
			end
		end
	end
end)

-- movement loop
local MOVE_KEYS = { Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right }
task.spawn(function()
	while alive do
		task.wait(0.1)
		local kind = eff("moveKind")
		local hrp = hrpOf()
		local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
		local pp = persona()
		local now = os.clock()
		if hrp and hum and inGame() and mv.dodgeBoss(hum, hrp, now) then mv.text = "jumping boss attack" continue end
		if kind == "Off" or not (hrp and hum and inGame()) then mv.goal = nil mv.text = kind == "Off" and "off" or "waiting for a round" continue end
		if not typing() then for _, k in MOVE_KEYS do if UIS:IsKeyDown(k) then mv.userUntil = os.clock() + 1.5 end end end
		if os.clock() < mv.userUntil then mv.text = "you're moving" continue end
		if kind == "Follow host" or kind == "Follow player" then
			local p = kind == "Follow host" and SW.host and Players:GetPlayerByUserId(SW.host.id) or Players:FindFirstChild(eff("followName") or "")
			local th = p and p ~= LP and hrpOf(p)
			if not th then mv.text = "nobody to follow" continue end
			local g = th.Position + idOffset(LP.UserId, eff("followDist") or 12)
			if (g - hrp.Position).Magnitude > 4 then hum:MoveTo(g) end
			if (g - hrp.Position).Magnitude > 60 and mv.rng:NextNumber() < 0.02 then key(Enum.KeyCode.Q) end
			mv.text = "following " .. p.Name
		else -- Human
			if now < mv.stopUntil then mv.text = "pausing" continue end
			if not mv.goal or now > mv.segEnd or (mv.goal - hrp.Position).Magnitude < 5 then
				if mv.goal and mv.rng:NextNumber() < pp.stop then -- stop-and-go like real players
					mv.stopUntil = now + pp.stopMin + mv.rng:NextNumber() * (pp.stopMax - pp.stopMin)
					mv.goal = nil
					hum:MoveTo(hrp.Position)
					continue
				end
				mv.goal = humanGoal(hrp)
				mv.segEnd = now + pp.segMin + mv.rng:NextNumber() * (pp.segMax - pp.segMin)
				if mv.goal and (mv.goal - hrp.Position).Magnitude > 45 and mv.rng:NextNumber() < pp.dash then task.spawn(key, Enum.KeyCode.Q) end
				if mv.rng:NextNumber() < pp.jump then hum.Jump = true end
				if mv.rng:NextNumber() < (pp.air or 0) then -- air dash: jump, then dash near the top of the jump
					hum.Jump = true
					task.delay(0.2 + mv.rng:NextNumber() * 0.15, key, Enum.KeyCode.Q)
				end
			end
			if mv.goal then hum:MoveTo(mv.goal) end
			mv.text = "human · " .. pp.name
		end
	end
end)

local function readyZone()
	for _, n in { "New Lobby", "Lobby" } do
		local f = workspace:FindFirstChild(n)
		local ra = f and f:FindFirstChild("ReadyArea")
		local z = ra and ra:FindFirstChild("ReadyZone")
		if z then return z end
	end
end

-- idle movement (lobby): walk between the game's own lobby walk points with short pauses, plus AFK spells
-- that never last longer than "Max AFK". While ready it wanders inside the ready zone so it stays ready.
local idle = { goal = nil, segEnd = 0, afkUntil = 0, text = "-" }
local function lobbyPoints()
	local pts = {}
	for _, n in { "LobbyWalkToPoints", "WalkToPoints" } do
		local f = workspace:FindFirstChild(n)
		if f then for _, c in f:GetDescendants() do if c:IsA("BasePart") then pts[#pts + 1] = c.Position end end end
	end
	return pts
end
task.spawn(function()
	while alive do
		task.wait(0.2)
		local hrp = hrpOf()
		local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
		if not eff("idleMove") or game.PlaceId == TUTORIAL_PLACE or inGame() or not (hrp and hum) then idle.goal = nil idle.text = "off" continue end
		local ready = val("IS_READY") == true
		if eff("autoReady") and not ready then idle.text = "walking to ready" continue end -- auto ready drives
		if os.clock() < mv.userUntil then idle.text = "you're moving" continue end
		local now = os.clock()
		if now < idle.afkUntil then idle.text = ("afk %.0fs"):format(idle.afkUntil - now) continue end
		if idle.goal and now < idle.segEnd and (idle.goal - hrp.Position).Magnitude > 4 then hum:MoveTo(idle.goal) continue end
		local r = mv.rng:NextNumber()
		if idle.goal and r < 0.18 then -- AFK spell, capped
			idle.afkUntil = now + 4 + mv.rng:NextNumber() * math.max(eff("idleAfkMax") * math.min(persona().afk, 1) - 4, 0)
			idle.goal = nil
			hum:MoveTo(hrp.Position)
			continue
		elseif idle.goal and r < 0.5 then -- short pause
			idle.afkUntil = now + 0.4 + mv.rng:NextNumber() * 1.6
			idle.goal = nil
			continue
		end
		local z = ready and readyZone()
		if z then
			local half = z.Size / 2 - Vector3.new(4, 0, 4)
			idle.goal = z.Position + Vector3.new((mv.rng:NextNumber() * 2 - 1) * half.X, 0, (mv.rng:NextNumber() * 2 - 1) * half.Z)
		else
			local pts = lobbyPoints()
			local c = pts[#pts > 0 and mv.rng:NextInteger(1, #pts) or 0] or hrp.Position
			idle.goal = c + Vector3.new(mv.rng:NextInteger(-8, 8), 0, mv.rng:NextInteger(-8, 8))
		end
		idle.segEnd = now + 3 + mv.rng:NextNumber() * 6
		if mv.rng:NextNumber() < 0.06 then hum.Jump = true end
		idle.text = ready and "wandering (ready zone)" or "wandering"
	end
end)

-- votes: read our own pick from the vote pages (VotedFrame on the chosen button, keyed by LayoutOrder)
local VOTE_PAGES = { mode = "GamemodeSelectPage", map = "MapSelectPage" }
local function voteButtons(kind)
	local pages = LP.PlayerGui:FindFirstChild("PAGES")
	local pg = pages and pages:FindFirstChild(VOTE_PAGES[kind])
	local list = pg and pg:FindFirstChild("Content") and pg.Content:FindFirstChild("ListFrame")
	local out = {}
	if list then
		for _, f in list:GetChildren() do
			local btn = f:IsA("Frame") and f.Visible and f:FindFirstChild("ImageButton")
			if btn then out[#out + 1] = { order = f.LayoutOrder, btn = btn, voted = btn:FindFirstChild("VotedFrame") and btn.VotedFrame.Visible,
				name = btn:FindFirstChild("BottomFrame") and btn.BottomFrame:FindFirstChild("MapNameLabel") and btn.BottomFrame.MapNameLabel.Text or "?" } end
		end
	end
	return out
end
local MODE_ORDER = { Classic = 1, ["One Life"] = 2, Team = 3, ["Cyber Brawl"] = 4 } -- AVAILABLE_GAMEMODES LayoutOrder
local MAP_ORDER, MAP_NAMES = {}, {}
pcall(function()
	for _, info in require(RS.DataBins.MapData).MapInfo do
		if type(info) == "table" and info.Name and info.LayoutOrder then MAP_ORDER[info.Name] = info.LayoutOrder MAP_NAMES[#MAP_NAMES + 1] = info.Name end
	end
	table.sort(MAP_NAMES)
end)
local clicked, hooked, openedAt = {}, setmetatable({}, { __mode = "k" }), {}
local function hookVoteButtons()
	for kind in VOTE_PAGES do
		for _, b in voteButtons(kind) do
			if not hooked[b.btn] then
				hooked[b.btn] = true
				local order, name = b.order, b.name
				conns[#conns + 1] = b.btn.InputBegan:Connect(function(i)
					if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
						clicked[kind] = { order = order, name = b.btn.BottomFrame.MapNameLabel.Text, t = os.time() }
					end
				end)
			end
		end
	end
end
local function myVotes()
	hookVoteButtons()
	local v = { modeOpen = val("GAMEMODE_VOTING_ACTIVE") == true, mapOpen = val("MAP_VOTING_ACTIVE") == true }
	for kind, open in { mode = v.modeOpen, map = v.mapOpen } do
		if open and not openedAt[kind] then openedAt[kind] = os.time() elseif not open then openedAt[kind] = nil end
		local pick = kind == "mode" and hostState.play.voteMode or hostState.play.voteMap
		local fixed = pick ~= "Copy me" and (kind == "mode" and MODE_ORDER[pick] or MAP_ORDER[pick])
		if open and fixed then
			v[kind] = { order = fixed, name = pick }
		elseif open and clicked[kind] and clicked[kind].t >= (openedAt[kind] or 0) - 1 then
			v[kind] = { order = clicked[kind].order, name = clicked[kind].name }
		end
	end
	return v
end
local voteText, lastVoteClick = "-", 0
local voteTries = {}
local function copyVotes(hv)
	if not hv or os.clock() - lastVoteClick < 1.5 then return end
	for kind in VOTE_PAGES do
		local want = hv[kind]
		local open = val(kind == "mode" and "GAMEMODE_VOTING_ACTIVE" or "MAP_VOTING_ACTIVE") == true
		if not open then voteTries[kind] = nil end
		if want and open then
			local key_ = kind .. want.order
			for _, b in voteButtons(kind) do
				if b.order == want.order then
					if b.voted then
						voteText = ("voted %s: %s ✓"):format(kind, want.name)
					elseif (voteTries[key_] or 0) < 6 then -- the page may be closed: fire the button's own handler
						voteTries[key_] = (voteTries[key_] or 0) + 1
						lastVoteClick = os.clock()
						if not fireButton(b.btn) and shown(b.btn) then clickGui(b.btn) end
						voteText = ("voting %s: %s (try %d)"):format(kind, want.name, voteTries[key_])
						return
					end
				end
			end
		end
	end
end

task.spawn(function()
	local Stats = game:GetService("Stats")
	while alive do
		local ok, mb = pcall(Stats.GetTotalMemoryUsageMb, Stats)
		memGuard.mb = ok and mb or 0
		if CFG.memGuard and memGuard.mb > CFG.memLimit then memGuard.on = true
		elseif memGuard.on and (not CFG.memGuard or memGuard.mb < CFG.memLimit - 300) then memGuard.on = false end
		task.wait(5)
	end
end)

-- frozen animations: seen 2026-10-08 on an alt mid-session: a bare Animation (asset 68645, never loads, length 0)
-- replayed ~8x/s at Action priority piles up 60+ tracks and freezes the local walk/run (others see you fine).
-- Source not found yet; this stops such tracks and logs what we were doing the first time it shows up.
local animLog = { seen = 0, first = nil }
task.spawn(function()
	while alive do
		task.wait(0.5)
		if not CFG.animFix then continue end
		local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
		local an = hum and hum:FindFirstChildOfClass("Animator")
		if not an then continue end
		local n = 0
		for _, t in an:GetPlayingAnimationTracks() do
			local a = t.Animation
			if a and a.AnimationId:find("68645", 1, true) and t.Length == 0 then -- only the broken asset; a real track also has length 0 while it loads
				n += 1
				pcall(function() t:Stop(0) t:Destroy() end)
			end
		end
		if n > 0 then
			animLog.seen += n
			if not animLog.first then
				animLog.first = os.date("%X")
				if hasFiles then pcall(writefile, DIR .. "/anim_freeze.txt", ("%s %s inGame=%s move=%s parry=%s last=%s move=%s aim=%s"):format(os.date("%c"), LP.Name,
					tostring(inGame()), tostring(eff("moveKind")), tostring(eff("parry")), tostring(live.last), tostring(moves.text), tostring(eff("aimMode")))) end
			end
		end
	end
end)

-- anti afk
on(LP.Idled, function()
	if not CFG.antiAfk then return end
	pcall(function()
		local VU = game:GetService("VirtualUser")
		VU:CaptureController()
		VU:ClickButton2(Vector2.zero)
	end)
end)

-- ============================== auto ready ==============================
task.spawn(function()
	local lastMove = 0
	while alive do
		task.wait(1)
		if eff("autoReady") and game.PlaceId ~= TUTORIAL_PLACE and not inGame() and not val("IS_READY") then
			local z, hrp = readyZone(), hrpOf()
			if z and hrp and os.clock() - lastMove > 2 then
				lastMove = os.clock()
				walkTo(z.Position)
				local hum = LP.Character:FindFirstChildOfClass("Humanoid")
				if hum and hrp.AssemblyLinearVelocity.Magnitude < 1 and (hrp.Position - z.Position).Magnitude > 20 then hum.Jump = true end
			end
		end
	end
end)

-- ============================== tutorial ==============================
local tut = { text = "-" }
local function promptClose()
	local pg = LP.PlayerGui:FindFirstChild("PROMPT")
	if not pg then return end
	for _, g in pg:GetDescendants() do
		if g.Name == "CloseButton" and g:IsA("GuiButton") and shown(g) then return g end
	end
end
task.spawn(function()
	if game.PlaceId ~= TUTORIAL_PLACE then return end
	local lastAct = 0
	while alive do
		task.wait(0.5)
		local s = tutorialStage()
		tut.text = "Stage " .. tostring(s) .. " / 13"
		if eff("tutorial") and s and os.clock() - lastAct > 1.5 then
			local close = promptClose()
			if close then
				lastAct = os.clock() clickGui(close) tut.text ..= " · closing prompt"
			elseif s == 1 then
				local m = workspace.FX:FindFirstChild("Model")
				local cards = {}
				if m then for _, c in m:GetChildren() do if c.Name == "Card" and c:IsA("BasePart") then cards[#cards + 1] = c end end end
				if #cards >= 3 then
					lastAct = os.clock()
					local btn -- the card's SurfaceGui button (adornee = card part) takes the click directly
					for _, sg in LP.PlayerGui:GetDescendants() do
						if sg:IsA("SurfaceGui") and sg.Adornee == cards[2] and sg.Name == "BackGui" then btn = sg:FindFirstChildWhichIsA("GuiButton") end
					end
					if not (btn and fireButton(btn)) then clickWorld(cards[2].Position) end
					tut.text ..= " · picking a card"
				end
			elseif s == 2 then
				lastAct = os.clock() walkTo(Vector3.new(17.64, 55.33, -122.28)) tut.text ..= " · walking to the arena"
			elseif s >= 3 and s <= 5 then
				tut.text ..= " · deflecting"
			elseif s == 6 then
				lastAct = os.clock() + 1.5 key(Enum.KeyCode.One) tut.text ..= " · using ability"
			elseif s == 9 or s == 10 then
				local pack = workspace:FindFirstChild("Summon") and workspace.Summon:FindFirstChild("Standard Pack")
				local pp = pack and pack:FindFirstChild("ActionPrompt", true)
				local hrp = hrpOf()
				if pp and hrp then
					local at = pp.Parent:IsA("BasePart") and pp.Parent.Position or pack:GetPivot().Position
					lastAct = os.clock()
					if (hrp.Position - at).Magnitude > 10 then walkTo(at) tut.text ..= " · walking to summon"
					else key(Enum.KeyCode.E) tut.text ..= " · summoning" end
				end
			elseif s == 11 then
				local vp = Camera.ViewportSize
				lastAct = os.clock()
				local sink = LP.PlayerGui:FindFirstChild("SummonGui") and LP.PlayerGui.SummonGui:FindFirstChild("InputSinker")
				if not (sink and fireButton(sink)) then clickAt(vp.X / 2, vp.Y * 0.75) end
				tut.text ..= " · closing reveal"
			elseif s >= 12 then
				tut.text ..= " · finishing (teleport)"
			end
		end
	end
end)

-- ============================== teleports ==============================
local function queueReload()
	local q = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
	if not (q and CFG.requeue) then return end
	-- local dev copy wins when present, else the public loader (saved key passes it)
	pcall(q, 'if isfile and isfile("deathball.lua") then loadstring(readfile("deathball.lua"))() else ' .. LOADER .. ' end')
end
local function tpTo(placeId, jobId)
	queueReload()
	if jobId and jobId ~= "" then
		pcall(TeleportService.TeleportToPlaceInstance, TeleportService, placeId, jobId, LP)
	else
		pcall(TeleportService.Teleport, TeleportService, placeId, LP)
	end
end
local function serverList(placeId)
	local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&excludeFullGames=true&limit=100"):format(placeId)
	local ok, body = pcall(game.HttpGet, game, url)
	if not ok then return nil, "request failed" end
	local ok2, data = pcall(HttpService.JSONDecode, HttpService, body)
	if not ok2 or type(data) ~= "table" or type(data.data) ~= "table" then return nil, "rate limited, wait a minute" end
	return data.data
end

-- ============================== swarm loop ==============================
local cmdLog = {}
local function runCmd(c)
	local k, a = c.kind, c.args or {}
	cmdLog[#cmdLog + 1] = os.date("%H:%M:%S ") .. k
	if k == "join" then
		if game.JobId ~= a.jobId then tpTo(a.placeId, a.jobId) end
	elseif k == "scatter" then
		local job = a.map and a.map[tostring(LP.UserId)]
		if job and job ~= game.JobId then tpTo(a.placeId, job) end
	elseif k == "rejoin" then
		tpTo(game.PlaceId, game.JobId)
	elseif k == "mode" then
		tpTo(a.placeId)
	elseif k == "reset" then
		local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
		if hum then hum.Health = 0 end
	elseif k == "close" then
		game:Shutdown()
	end
end
local function accStatus()
	return {
		id = LP.UserId, name = LP.Name, role = SW.role, t = os.time(), placeId = game.PlaceId, jobId = game.JobId,
		inGame = inGame(), ready = val("IS_READY") == true, wins = stat("Wins:Total"),
		parries = stats.parries, hp = val("PLAYER_HEALTH_CURRENT"), mem = math.floor(memGuard.mb), guard = memGuard.on, tut = game.PlaceId == TUTORIAL_PLACE and tutorialStage() or nil,
	}
end
task.spawn(function()
	if not hasFiles then SW.status = "executor has no file functions — swarm off" return end
	local first = true
	while alive do
		jwrite(SWARM .. "/acc_" .. LP.UserId .. ".json", accStatus())
		SW.host = jread(HOSTF)
		-- member list (every account that heartbeated in the last 15 s)
		local list = {}
		pcall(function()
			for _, f in listfiles(SWARM) do
				local n = f:match("acc_(%d+)%.json$")
				if n then
					local d = jread(SWARM .. "/acc_" .. n .. ".json")
					if d and os.time() - (d.t or 0) <= 15 then list[#list + 1] = d end
				end
			end
		end)
		SW.members = list
		local locked = SW.host and SW.host.lock and SW.host.id ~= LP.UserId and os.time() - (SW.host.t or 0) <= 15
		if locked and SW.role == "Host" then setRole("Swarm") SW.status = "Host is locked to " .. SW.host.name
		elseif locked and SW.role == "Off" and not SW.noAuto then setRole("Swarm") end
		if SW.role == "Host" then
			hostState.vote = myVotes()
			do -- attack victim: a named player, or keep one random non-swarm target until it's out
				local atk = hostState.play.attack
				local cur = Players:FindFirstChild(atk.victim or "")
				local function ok(p) return p and p ~= LP and inGame(p) and not isSwarmId(p.UserId) and not table.find(hostState.play.whitelist or {}, p.Name) end
				if atk.pick == "Player" then atk.victim = atk.name
				elseif not ok(cur) then
					local c = {}
					for _, p in Players:GetPlayers() do if ok(p) then c[#c + 1] = p end end
					atk.victim = #c > 0 and c[math.random(1, #c)].Name or ""
				end
			end
			for k in PARRY_OPTS do hostState.parry[k] = CFG[k] end
			hostState.play.hostSettings = {
				aimMode = CFG.aimMode, aimName = CFG.aimName, aimStyle = CFG.aimStyle, slotMode = table.clone(CFG.slotMode),
				moveKind = CFG.moveKind, followName = CFG.followName, followDist = CFG.followDist, idleMove = CFG.idleMove,
				idleAfkMax = CFG.idleAfkMax, moveBand = CFG.moveBand, dashChance = CFG.dashChance, persona = CFG.persona,
				spread = CFG.spread, spreadDist = CFG.spreadDist, tutorial = CFG.tutorial,
			}
			hostWrite()
			SW.host = hostState
			applyPerf(localPerf())
		elseif SW.role == "Swarm" then
			if hostLive() and SW.host.id ~= LP.UserId then
				if first then -- a fresh alt doesn't replay commands older than a minute
					for _, c in SW.host.cmds or {} do if os.time() - (c.t or 0) > 60 then SW.lastSeen = math.max(SW.lastSeen, c.id) end end
				end
				for _, c in SW.host.cmds or {} do
					if c.id > SW.lastSeen then
						SW.lastSeen = c.id
						pcall(writefile, SEEN_FILE, tostring(c.id))
						if os.time() - (c.t or 0) <= 60 then task.spawn(runCmd, c) end
					end
				end
				applyPerf(SW.obey and SW.host.perf or localPerf())
				if (SW.syncParry or (SW.host.play and SW.host.play.pushParry)) and SW.host.parry and HttpService:JSONEncode(SW.host.parry) ~= parrySynced then applyHostParry() end
				if SW.host.play and (SW.host.play.parryPushAt or 0) > (SW.parryPushSeen or 0) then SW.parryPushSeen = SW.host.play.parryPushAt applyHostParry() end
				if SW.obey and SW.host.play and SW.host.play.copyVote and SW.host.jobId == game.JobId then copyVotes(SW.host.vote) end
				-- keep alts in the host's server (also brings fresh accounts over once their tutorial ends)
				-- auto join: alts outside the host's server queue for its free slots. Only as many alts as there are
				-- free slots try at once (lowest UserIds first), so they don't all fight for one opening.
				SW.joinText = nil
				if SW.obey and SW.autoJoin ~= false and SW.host.play and SW.host.play.stayWithHost and SW.host.jobId ~= game.JobId and game.PlaceId ~= TUTORIAL_PLACE
					and SW.host.placeId ~= TUTORIAL_PLACE and not inGame() then
					local free = SW.host.slots or 0
					local queue = {}
					for _, m in SW.members do if m.role == "Swarm" and m.jobId ~= SW.host.jobId and m.placeId ~= TUTORIAL_PLACE then queue[#queue + 1] = m.id end end
					table.sort(queue)
					local rank = table.find(queue, LP.UserId) or 1
					if free <= 0 then SW.joinText = "host server full, waiting for a slot"
					elseif rank > free then SW.joinText = ("waiting in line (%d of %d)"):format(rank, #queue)
					elseif os.clock() - (SW.lastPull or 0) > 8 then
						SW.lastPull = os.clock()
						SW.joinText = "joining host"
						tpTo(SW.host.placeId, SW.host.jobId)
					end
				end
				SW.status = ("Connected to %s%s"):format(SW.host.name, SW.host.jobId == game.JobId and " · same server" or (" · other server" .. (SW.joinText and (" · " .. SW.joinText) or "")))
			else
				applyPerf(localPerf())
				SW.status = SW.host and "Host offline" or "No host found"
			end
			first = false
		else
			applyPerf(localPerf())
			SW.status = "Not in the swarm"
		end
		task.wait(1)
	end
end)

-- ============================== visuals ==============================
local draw = {}
if Drawing then
	draw.ring = Drawing.new("Circle") draw.ring.Thickness = 2 draw.ring.NumSides = 32 draw.ring.Filled = false
	draw.text = Drawing.new("Text") draw.text.Size = 14 draw.text.Center = true draw.text.Outline = true
	draw.line = Drawing.new("Line") draw.line.Thickness = 2
	draw.path = {}
	for i = 1, 30 do local l = Drawing.new("Line") l.Thickness = 2 l.Transparency = 0.8 draw.path[i] = l end
end
on(RunService.RenderStepped, function()
	if not draw.ring then return end
	local b = live.balls and live.balls[1]
	local show = b and (CFG.marker or CFG.info or CFG.velLine)
	if not show then draw.ring.Visible, draw.text.Visible, draw.line.Visible = false, false, false return end
	local v, onScreen = Camera:WorldToViewportPoint(b.pos)
	local col = b.mine and CFG.markerColor or Color3.new(1, 1, 1)
	draw.ring.Visible = CFG.marker and onScreen
	if draw.ring.Visible then
		draw.ring.Position = Vector2.new(v.X, v.Y)
		draw.ring.Radius = math.clamp(900 / math.max(v.Z, 1), 6, 60)
		draw.ring.Color = col
	end
	draw.text.Visible = CFG.info and onScreen
	if draw.text.Visible then
		local who = b.mine and "YOU" or (b.target and b.target.Name or "?")
		draw.text.Text = string.format("%s · %.0f%s", who, b.speed, b.tti and b.tti < 9 and string.format(" · %.2fs", b.tti) or "")
		draw.text.Position = Vector2.new(v.X, v.Y - draw.ring.Radius - 18)
		draw.text.Color = col
	end
	local v2, on2 = Camera:WorldToViewportPoint(b.pos + b.vel * 0.5)
	draw.line.Visible = CFG.velLine and onScreen and on2
	if draw.line.Visible then draw.line.From = Vector2.new(v.X, v.Y) draw.line.To = Vector2.new(v2.X, v2.Y) draw.line.Color = col end
end)

-- ============================== UI ==============================
local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local function obsidian(file, remote)
	local path = "BattleBotFarm/lib/" .. file -- shared local copy (a hung HttpGet once jammed the executor queue)
	local ok, src = pcall(function() return isfile(path) and readfile(path) end)
	return loadstring(ok and src or game:HttpGet(repo .. remote))()
end
Library = obsidian("Library.lua", "Library.lua")
local ThemeManager = obsidian("ThemeManager.lua", "addons/ThemeManager.lua")
local SaveManager = obsidian("SaveManager.lua", "addons/SaveManager.lua")
local Options, Toggles = Library.Options, Library.Toggles

local Window = Library:CreateWindow({
	Title = "CruelHub", Icon = (function()
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
	end)(), Footer = "Death Ball · parry · aim · moves · swarm",
	Size = UDim2.fromOffset(704, 600), Center = true, AutoShow = true, ToggleKeybind = Enum.KeyCode.RightControl,
})
local Tabs = {
	Parry = Window:AddTab("Parry", "shield"),
	Moves = Window:AddTab("Moves", "zap"),
	Movement = Window:AddTab("Movement", "footprints"),
	Visuals = Window:AddTab("Visuals", "eye"),
	Swarm = Window:AddTab("Swarm", "network"),
	Play = Window:AddTab("Swarm Play", "gamepad-2"),
	Tutorial = Window:AddTab("Tutorial", "graduation-cap"),
	Misc = Window:AddTab("Misc", "gauge"),
	Settings = Window:AddTab("Settings", "settings"),
}
local function set(k) return function(v) CFG[k] = v end end

-- Parry tab
local B = {} -- UI groupboxes (kept in one table: the main chunk hit Luau's 200-local limit)
B.AP = Tabs.Parry:AddLeftGroupbox("Auto parry", "shield")
B.AP:AddToggle("DB_Parry", { Text = "Auto parry", Default = CFG.parry, Callback = set("parry") })
	:AddKeyPicker("DB_ParryKey", { Default = "None", Mode = "Toggle", Text = "Auto parry", SyncToggleState = true })
B.AP:AddSlider("DB_Lead", { Text = "Parry timing", Default = CFG.lead, Min = 0.15, Max = 0.7, Rounding = 2, Suffix = "s",
	Tooltip = "Presses F when the ball is this many seconds away. The block lasts 0.7 s, so 0.35–0.5 is safe.", Callback = set("lead") })
B.AP:AddToggle("DB_Ping", { Text = "Add ping to timing", Default = CFG.pingComp, Callback = set("pingComp") })
B.AP:AddSlider("DB_Close", { Text = "Always parry within", Default = CFG.closeDist, Min = 0, Max = 40, Rounding = 0, Suffix = " studs",
	Callback = set("closeDist") })
B.AP:AddToggle("DB_Predict", { Text = "Predict curve", Default = CFG.predict,
	Tooltip = "Runs the game's own homing math forward to find when the ball really reaches you (it curves toward its target)", Callback = set("predict") })
B.AP:AddToggle("DB_PredMove", { Text = "Include my movement", Default = CFG.predMove, Callback = set("predMove") })
B.AP:AddSlider("DB_Human", { Text = "Random delay", Default = CFG.humanize, Min = 0, Max = 200, Rounding = 0, Suffix = " ms",
	Tooltip = "Adds 0..N ms before each press so the timing doesn't look perfect", Callback = set("humanize") })
B.CL = Tabs.Parry:AddLeftGroupbox("Clash", "swords")
B.CL:AddLabel("Two players trading the ball point-blank: spams F while it's yours, close and fast.", true)
B.CL:AddToggle("DB_Clash", { Text = "Clash spam", Default = CFG.clash, Callback = set("clash") })
B.CL:AddSlider("DB_ClashDist", { Text = "Within", Default = CFG.clashDist, Min = 5, Max = 40, Rounding = 0, Suffix = " studs", Callback = set("clashDist") })
B.AM = Tabs.Parry:AddLeftGroupbox("Aim", "crosshair")
B.AM:AddLabel("Your deflect flies where your camera looks. This turns the camera onto the chosen player for a moment as you press F (and for moves).", true)
B.AM:AddDropdown("DB_AimMode", { Text = "Send the ball to", Values = AIM_MODES, Default = CFG.aimMode, Callback = set("aimMode") })
B.AM:AddDropdown("DB_AimStyle", { Text = "Shot style", Values = { "Auto (per account)", "Off", table.unpack(AIM_STYLE_NAMES) }, Default = CFG.aimStyle,
	Tooltip = "How you send it: launch angle off the straight line and who you prefer to hit. Built from real players' deflects.", Callback = set("aimStyle") })
B.AM:AddDropdown("DB_AimName", { Text = "Player", SpecialType = "Player", ExcludeLocalPlayer = true, AllowNull = true,
	Callback = function(v) CFG.aimName = v or "" end })
B.CL:AddSlider("DB_ClashSpeed", { Text = "Ball faster than", Default = CFG.clashSpeed, Min = 50, Max = 400, Rounding = 0, Callback = set("clashSpeed") })

B.RD = Tabs.Parry:AddRightGroupbox("Rounds", "repeat")
B.RD:AddToggle("DB_Ready", { Text = "Auto ready", Tooltip = "Walks into the ready zone before every round", Default = CFG.autoReady, Callback = set("autoReady") })
B.RD:AddToggle("DB_Afk", { Text = "Anti AFK", Default = CFG.antiAfk, Callback = set("antiAfk") })
B.LV = Tabs.Parry:AddRightGroupbox("Live", "activity")
local liveLabel = B.LV:AddLabel("-", true)
local statLabel = B.LV:AddLabel("-", true)

-- Moves tab
B.MC = Tabs.Moves:AddLeftGroupbox("Your champion", "user")
local champLabel = B.MC:AddLabel("-", true)
B.MC:AddLabel("Smart = Save me for moves that deflect (AutoDeflect), When targeted for invisibility/armor, Off for pure dashes, On cooldown for the rest. Save me fires when F is on cooldown and the ball is under 1.1 s away.", true)
B.MS = Tabs.Moves:AddRightGroupbox("Slots", "layers")
for i = 1, 4 do
	B.MS:AddDropdown("DB_Slot" .. i, { Text = "Slot " .. i .. " (key " .. i .. ")", Values = MOVE_MODES, Default = CFG.slotMode[i],
		Callback = function(v) CFG.slotMode[i] = v end })
end
local movesLabel = B.MS:AddLabel("-", true)

-- Movement tab
B.AF = Tabs.Misc:AddLeftGroupbox("Animation fix", "person-standing")
B.AF:AddToggle("DB_AnimFix", { Text = "Unfreeze my animations", Default = CFG.animFix,
	Tooltip = "Stops broken Action tracks (asset 68645) that freeze your own walk animation", Callback = set("animFix") })
local animLabel = B.AF:AddLabel("-", true)
B.MG = Tabs.Misc:AddRightGroupbox("Crash guard", "shield-alert")
B.MG:AddLabel("Each client uses ~1.8 GB; many clients on one PC run out of RAM and crash. Above the limit this switches to lowest graphics and 30 FPS (swarm alts also stop 3D rendering) until memory drops.", true)
B.MG:AddToggle("DB_MemGuard", { Text = "Memory guard", Default = CFG.memGuard, Callback = set("memGuard") })
B.MG:AddSlider("DB_MemLimit", { Text = "Limit", Default = CFG.memLimit, Min = 1200, Max = 4000, Rounding = 0, Suffix = " MB", Callback = set("memLimit") })
local memLabel = B.MG:AddLabel("-", true)
B.AF:AddToggle("DB_AimLog", { Text = "Log my aims (debug)", Default = CFG.aimLog, Callback = set("aimLog") })
B.MV = Tabs.Movement:AddLeftGroupbox("In-round movement", "footprints")
B.MV:AddLabel("Human copies how real players moved (measured): walk in short bursts, brief stops, new direction every ~1.6 s, a dash now and then, keep away from the ball. Pressing WASD pauses it.", true)
B.MV:AddDropdown("DB_MoveKind", { Text = "Mode", Values = MOVE_KINDS, Default = CFG.moveKind, Callback = set("moveKind") })
B.MV:AddDropdown("DB_FollowName", { Text = "Follow player", SpecialType = "Player", ExcludeLocalPlayer = true, AllowNull = true,
	Callback = function(v) CFG.followName = v or "" end })
B.MV:AddSlider("DB_FollowDist", { Text = "Follow distance", Default = CFG.followDist, Min = 4, Max = 60, Rounding = 0, Suffix = " studs", Callback = set("followDist") })
B.IM = Tabs.Movement:AddLeftGroupbox("Idle (lobby)", "coffee")
B.IM:AddLabel("Walks around the lobby between rounds like a player: short walks, pauses, sometimes AFK, never longer than Max AFK. Stays inside the ready zone once ready.", true)
B.IM:AddToggle("DB_IdleMove", { Text = "Move while idle", Default = CFG.idleMove, Callback = set("idleMove") })
B.IM:AddSlider("DB_IdleAfk", { Text = "Max AFK", Default = CFG.idleAfkMax, Min = 4, Max = 120, Rounding = 0, Suffix = "s", Callback = set("idleAfkMax") })
local idleLabel = B.IM:AddLabel("-", true)
B.MH = Tabs.Movement:AddRightGroupbox("Human tuning", "sliders-horizontal")
B.MH:AddSlider("DB_Band", { Text = "Stay away from ball", Default = CFG.moveBand, Min = 20, Max = 150, Rounding = 0, Suffix = " studs", Callback = set("moveBand") })
B.MH:AddSlider("DB_Dash", { Text = "Dash chance per move", Default = CFG.dashChance, Min = 0, Max = 1, Rounding = 2, Callback = set("dashChance") })
B.MH:AddDropdown("DB_Persona", { Text = "Personality", Values = { "Auto (per account)", "Off (measured average)", table.unpack(PERSONA_NAMES) },
	Default = CFG.persona, Tooltip = "Auto gives each account its own style + jitter. Off uses the sliders below.", Callback = set("persona") })
B.MH:AddToggle("DB_Spread", { Text = "Keep apart from swarm", Default = CFG.spread, Callback = set("spread") })
B.MH:AddSlider("DB_SpreadDist", { Text = "Distance from swarm", Default = CFG.spreadDist, Min = 8, Max = 120, Rounding = 0, Suffix = " studs", Callback = set("spreadDist") })
local moveLabel = B.MH:AddLabel("-", true)

-- Visuals tab
B.VB = Tabs.Visuals:AddLeftGroupbox("Ball", "circle-dot")
B.VB:AddLabel("The game scrambles the ball part's position for scripts; these draw the real one.", true)
B.VB:AddToggle("DB_Marker", { Text = "Ball marker", Default = CFG.marker, Callback = set("marker") })
	:AddColorPicker("DB_MarkerCol", { Default = CFG.markerColor, Title = "Targeting you", Callback = set("markerColor") })
B.VB:AddToggle("DB_Info", { Text = "Target · speed · time", Default = CFG.info, Callback = set("info") })
B.VB:AddToggle("DB_PathLine", { Text = "Predicted path (yours)", Default = CFG.pathLine, Callback = set("pathLine") })
B.VB:AddToggle("DB_VelLine", { Text = "Direction line (0.5 s)", Default = CFG.velLine, Callback = set("velLine") })
if not Drawing then B.VB:AddLabel("Your executor has no Drawing API.", true) end

-- Swarm tab
B.ID = Tabs.Swarm:AddLeftGroupbox("Identity", "user")
B.ID:AddLabel("Accounts on this PC talk through the executor workspace. Pick Host on the account that drives, Swarm on the alts. Saved per account.", true)
B.ID:AddDropdown("SW_Role", { Text = "This account", Values = { "Off", "Host", "Swarm" }, Default = SW.role,
	Callback = function(v) SW.role = v if hasFiles then pcall(writefile, ROLE_FILE, v) end end })
local swStatus = B.ID:AddLabel("-", true)
B.LK = B.ID:AddDependencyBox()
B.LK:AddToggle("SW_Lock", { Text = "Lock host + auto add accounts", Default = hostState.lock,
	Tooltip = "Every other account that runs the hub joins your swarm by itself, and none of them can become host while you're online",
	Callback = function(v) hostState.lock = v end })
B.LK:SetupDependencies({ { Options.SW_Role, "Host" } })
B.NA = B.ID:AddDependencyBox()
B.NA:AddToggle("SW_NoAuto", { Text = "Never auto join a swarm", Default = SW.noAuto, Callback = function(v)
	SW.noAuto = v
	if hasFiles then if v then pcall(writefile, NOAUTO_FILE, "1") elseif isfile(NOAUTO_FILE) then pcall(delfile, NOAUTO_FILE) end end
end })
B.NA:SetupDependencies({ { Options.SW_Role, "Off" } })
B.SD = B.ID:AddDependencyBox()
B.SD:AddToggle("SW_Obey", { Text = "Obey host", Tooltip = "Follow the host's autoplay, rules and performance while it's online",
	Default = true, Callback = function(v) SW.obey = v end })
B.SD:AddButton({ Text = "Copy host parry settings", Tooltip = "Timing, ping, close range, delay, clash and prediction settings",
	Func = function() Library:Notify(applyHostParry() and "Copied the host's parry settings" or "No host parry settings yet", 3) end })
B.SD:AddToggle("SW_AutoJoin", { Text = "Auto join host", Default = true,
	Tooltip = "Join the host's server when it has a free slot (the host's own toggle must be on too)",
	Callback = function(v) SW.autoJoin = v end })
B.SD:AddToggle("SW_SyncParry", { Text = "Keep host parry settings", Default = false, Tooltip = "Copies them again whenever the host changes one",
	Callback = function(v) SW.syncParry = v if v then applyHostParry() end end })
local swCmdLabel = B.SD:AddLabel("-", true)
B.SD:SetupDependencies({ { Options.SW_Role, "Swarm" } })

B.MB = Tabs.Swarm:AddRightGroupbox("Members", "users")
local membersLabel = B.MB:AddLabel("-", true)

-- host-only boxes: controls show for the Host role, a hint for the others
local function hostOnly(box)
	for _, r in { "Off", "Swarm" } do
		local hint = box:AddDependencyBox()
		hint:AddLabel("Host controls. Set this account to Host to use them.", true)
		hint:SetupDependencies({ { Options.SW_Role, r } })
	end
	return box:AddDependencyBox()
end
B.HD = Tabs.Swarm:AddLeftGroupbox("Servers", "server")
B.hd = hostOnly(B.HD)
B.hd:AddToggle("SW_Stay", { Text = "Auto join (alts join my server)", Default = hostState.play.stayWithHost,
	Tooltip = "ON: alts outside your server join you between rounds; when it's full they wait and take slots as they open, one alt per free slot. OFF: alts stay where they are.",
	Callback = function(v) hostState.play.stayWithHost = v end })
B.hd:AddButton({ Text = "Join my server", Func = function() pushCmd("join", { placeId = game.PlaceId, jobId = game.JobId }) Library:Notify("Swarm: joining you", 3) end })
B.hd:AddButton({ Text = "Scatter servers", Tooltip = "Every alt goes to a different public server of this mode", Func = function()
	task.spawn(function()
		local list, err = serverList(game.PlaceId)
		if not list then Library:Notify("Scatter: " .. err, 4) return end
		local map, i = {}, 1
		for _, m in SW.members do
			if m.id ~= LP.UserId and m.role == "Swarm" then
				while list[i] and (list[i].id == game.JobId or (list[i].playing or 0) >= (list[i].maxPlayers or 0)) do i += 1 end
				if not list[i] then break end
				map[tostring(m.id)] = list[i].id
				i += 1
			end
		end
		pushCmd("scatter", { placeId = game.PlaceId, map = map })
		Library:Notify("Swarm: scattering", 3)
	end)
end })
B.hd:AddButton({ Text = "Rejoin", Func = function() pushCmd("rejoin") end })
B.hd:AddButton({ Text = "Reset characters", Func = function() pushCmd("reset") end })
B.hd:AddDropdown("SW_Mode", { Text = "Send to mode", Values = { "Lobby (beginner)", "Classic", "Death Ball hub", "Pro" }, Default = "Classic" })
B.hd:AddButton({ Text = "Send swarm to mode", Func = function()
	local ids = { ["Lobby (beginner)"] = 83678792452277, Classic = 71000936793663, ["Death Ball hub"] = 15002061926, Pro = 89775940525999 }
	pushCmd("mode", { placeId = ids[Options.SW_Mode.Value] })
end })
B.hd:AddButton({ Text = "Close swarm clients", DoubleClick = true, Func = function() pushCmd("close") end })
B.hd:SetupDependencies({ { Options.SW_Role, "Host" } })

B.AU = Tabs.Swarm:AddRightGroupbox("Autoplay", "play")
B.au = hostOnly(B.AU)
B.au:AddToggle("SW_AutoReady", { Text = "Swarm auto ready", Default = hostState.autoplay.ready, Callback = function(v) hostState.autoplay.ready = v end })
B.au:AddToggle("SW_AutoParry", { Text = "Swarm auto parry", Default = hostState.autoplay.parry, Callback = function(v) hostState.autoplay.parry = v end })
B.au:SetupDependencies({ { Options.SW_Role, "Host" } })

B.WL = Tabs.Swarm:AddRightGroupbox("Win / lose rules", "scale")
B.wl = hostOnly(B.WL)
B.wl:AddLabel("Alts stop parrying (and lose) when a lose rule is true. The final rule decides the last 1v1.", true)
B.wl:AddToggle("SW_LoseHost", { Text = "Lose when host is last alive", Default = hostState.rules.loseHostLastAlive, Callback = function(v) hostState.rules.loseHostLastAlive = v end })
B.wl:AddToggle("SW_LoseSwarm", { Text = "Lose when swarm is last alive", Default = hostState.rules.loseSwarmLastAlive, Callback = function(v) hostState.rules.loseSwarmLastAlive = v end })
B.wl:AddSlider("SW_LoseAlive", { Text = "Lose when alive ≤", Default = hostState.rules.loseAliveLE, Min = 0, Max = 9, Rounding = 0,
	Tooltip = "0 = off", Callback = function(v) hostState.rules.loseAliveLE = v end })
B.wl:AddSlider("SW_LoseSpeed", { Text = "Lose when ball ≥", Default = hostState.rules.loseSpeedGE, Min = 0, Max = 400, Rounding = 0,
	Tooltip = "0 = off", Callback = function(v) hostState.rules.loseSpeedGE = v end })
B.wl:AddSlider("SW_LoseAfter", { Text = "Lose after surviving", Default = hostState.rules.loseAfter, Min = 0, Max = 300, Rounding = 0, Suffix = "s",
	Tooltip = "0 = off", Callback = function(v) hostState.rules.loseAfter = v end })
B.wl:AddDropdown("SW_Final", { Text = "Only win the final 1v1", Values = { "Always", "Never", "Not vs host", "Not vs swarm" },
	Default = hostState.rules.final, Callback = function(v) hostState.rules.final = v end })
B.wl:SetupDependencies({ { Options.SW_Role, "Host" } })

B.PA = Tabs.Play:AddLeftGroupbox("Swarm aim", "crosshair")
B.pa = hostOnly(B.PA)
B.pa:AddLabel("Where alts send the ball. Own = each alt's own Aim setting.", true)
B.pa:AddDropdown("SW_AimMode", { Text = "Alts send the ball to", Values = { "Own", table.unpack(AIM_MODES) }, Default = hostState.play.aimMode,
	Callback = function(v) hostState.play.aimMode = v end })
B.pa:AddToggle("SW_CopyAim", { Text = "Copy host aim settings", Default = hostState.play.copyAim,
	Tooltip = "Keeps alts on your Aim tab mode, target and shot style", Callback = function(v) hostState.play.copyAim = v end })
B.pa:AddToggle("SW_PushParry", { Text = "Copy host parry settings", Default = hostState.play.pushParry,
	Tooltip = "Alts copy your timing, ping, close range, delay, clash and prediction settings and follow your changes",
	Callback = function(v) hostState.play.pushParry = v end })
B.pa:AddButton({ Text = "Copy my parry settings to alts now", Func = function()
	hostState.play.parryPushAt = os.time()
	Library:Notify("Alts will copy your parry settings", 3)
end })
B.pa:AddToggle("SW_DiverseAim", { Text = "Different shot style per alt", Default = hostState.play.diverseAim,
	Callback = function(v) hostState.play.diverseAim = v end })
B.pa:AddToggle("SW_WhitelistHost", { Text = "Whitelist me (alts never target me)", Default = hostState.play.whitelistHost,
	Tooltip = "Covers aim modes, attack passes and the attack victim", Callback = function(v) hostState.play.whitelistHost = v end })
B.pa:AddDropdown("SW_Whitelist", { Text = "Whitelist players", SpecialType = "Player", ExcludeLocalPlayer = true, Multi = true,
	Tooltip = "Nobody in the swarm sends the ball at these players", Callback = function(v)
		local t = {}
		for name, on in v do if on then t[#t + 1] = typeof(name) == "Instance" and name.Name or tostring(name) end end
		hostState.play.whitelist = t
	end })
B.pa:AddDropdown("SW_AimName", { Text = "Target player", SpecialType = "Player", AllowNull = true,
	Callback = function(v) hostState.play.aimName = v or "" end })
B.pa:SetupDependencies({ { Options.SW_Role, "Host" } })

B.PM = Tabs.Play:AddLeftGroupbox("Swarm moves", "zap")
B.pm = hostOnly(B.PM)
B.pm:AddDropdown("SW_Moves", { Text = "Alts' champion moves", Values = { "Own", "Smart all", "Spam all", "Off all" }, Default = hostState.play.moves,
	Tooltip = "Own = each alt's Moves tab", Callback = function(v) hostState.play.moves = v end })
B.pm:AddToggle("SW_CopyMoves", { Text = "Copy host move settings", Default = hostState.play.copyMoves,
	Tooltip = "Copies your four champion move slot choices", Callback = function(v) hostState.play.copyMoves = v end })
B.pm:SetupDependencies({ { Options.SW_Role, "Host" } })

B.PV = Tabs.Play:AddRightGroupbox("Swarm movement", "footprints")
B.pv = hostOnly(B.PV)
B.pv:AddDropdown("SW_MoveKind", { Text = "Alts move", Values = { "Own", table.unpack(MOVE_KINDS) }, Default = hostState.play.moveKind,
	Callback = function(v) hostState.play.moveKind = v end })
B.pv:AddToggle("SW_CopyMovement", { Text = "Copy host movement settings", Default = hostState.play.copyMovement,
	Tooltip = "Keeps alts on your Movement tab mode, follow target, spacing and personality", Callback = function(v) hostState.play.copyMovement = v end })
B.pv:AddDropdown("SW_FollowName", { Text = "Follow player", SpecialType = "Player", AllowNull = true,
	Callback = function(v) hostState.play.followName = v or "" end })
B.pv:AddSlider("SW_FollowDist", { Text = "Follow distance", Default = hostState.play.followDist, Min = 4, Max = 60, Rounding = 0, Suffix = " studs",
	Callback = function(v) hostState.play.followDist = v end })
B.pv:AddDropdown("SW_IdleMove", { Text = "Alts idle movement", Values = { "Own", "On", "Off" }, Default = hostState.play.idleMove,
	Callback = function(v) hostState.play.idleMove = v end })
B.pv:AddToggle("SW_Diverse", { Text = "Different personality per alt", Default = hostState.play.diverse,
	Callback = function(v) hostState.play.diverse = v end })
B.pv:AddToggle("SW_Spread", { Text = "Keep alts apart", Default = hostState.play.spread, Callback = function(v) hostState.play.spread = v end })
B.pv:AddSlider("SW_SpreadDist", { Text = "Distance between alts", Default = hostState.play.spreadDist, Min = 8, Max = 120, Rounding = 0, Suffix = " studs",
	Callback = function(v) hostState.play.spreadDist = v end })
B.pv:SetupDependencies({ { Options.SW_Role, "Host" } })

B.PK = Tabs.Play:AddLeftGroupbox("Coordinated attack", "swords")
B.pk = hostOnly(B.PK)
B.pk:AddLabel("The swarm passes safely until the chosen victim finishes a parry and is on cooldown, then attacks. Swarm accounts need auto parry on.", true)
B.pk:AddToggle("SW_Attack", { Text = "Organize attacks", Default = hostState.play.attack.on, Callback = function(v) hostState.play.attack.on = v end })
B.pk:AddDropdown("SW_AttackPick", { Text = "Victim", Values = { "Auto", "Player" }, Default = hostState.play.attack.pick,
	Tooltip = "Auto keeps one random non-swarm player until they're out", Callback = function(v) hostState.play.attack.pick = v end })
B.pk:AddDropdown("SW_AttackName", { Text = "Victim player", SpecialType = "Player", ExcludeLocalPlayer = true, AllowNull = true,
	Callback = function(v) hostState.play.attack.name = v or "" end })
local atkLabel = B.pk:AddLabel("-", true)
B.pk:SetupDependencies({ { Options.SW_Role, "Host" } })

B.PVo = Tabs.Play:AddRightGroupbox("Votes", "vote")
B.pvo = hostOnly(B.PVo)
B.pvo:AddLabel("Alts in your server vote with you: what you click this vote, or a fixed pick. They vote even with their vote page closed and retry until it counts.", true)
B.pvo:AddToggle("SW_CopyVote", { Text = "Swarm votes", Default = hostState.play.copyVote, Callback = function(v) hostState.play.copyVote = v end })
B.pvo:AddDropdown("SW_VoteMode", { Text = "Gamemode vote", Values = { "Copy me", "Classic", "One Life", "Team", "Cyber Brawl" },
	Default = hostState.play.voteMode, Tooltip = "Copy me = whatever you click this vote", Callback = function(v) hostState.play.voteMode = v end })
B.pvo:AddDropdown("SW_VoteMap", { Text = "Map vote", Values = { "Copy me", table.unpack(MAP_NAMES) },
	Default = hostState.play.voteMap, Callback = function(v) hostState.play.voteMap = v end })
local voteLabel = B.pvo:AddLabel("-", true)
B.pvo:SetupDependencies({ { Options.SW_Role, "Host" } })

B.PT = Tabs.Play:AddLeftGroupbox("Swarm tutorial + server", "graduation-cap")
B.pt = hostOnly(B.PT)
B.pt:AddToggle("SW_Tutorial", { Text = "Alts auto complete tutorial", Default = hostState.play.tutorial,
	Tooltip = "Fresh accounts in the tutorial play it through (card, bot round, crystals, summon) and land in the lobby",
	Callback = function(v) hostState.play.tutorial = v end })
B.pt:AddToggle("SW_CopyTutorial", { Text = "Copy host tutorial setting", Default = hostState.play.copyTutorial,
	Tooltip = "Follows Auto complete tutorial on your Tutorial tab", Callback = function(v) hostState.play.copyTutorial = v end })
B.pt:SetupDependencies({ { Options.SW_Role, "Host" } })

B.PF = Tabs.Swarm:AddLeftGroupbox("Swarm performance", "cpu")
B.pf = hostOnly(B.PF)
B.pf:AddLabel("Only these controls apply to swarm accounts; Misc performance stays local.", true)
B.pf:AddToggle("SW_PerfOn", { Text = "Apply to swarm", Default = hostState.perf.on, Callback = function(v) hostState.perf.on = v end })
B.pf:AddSlider("SW_PerfFps", { Text = "FPS cap", Default = hostState.perf.fps, Min = 5, Max = 240, Rounding = 0, Callback = function(v) hostState.perf.fps = v end })
B.pf:AddToggle("SW_Perf3d", { Text = "Turn off 3D rendering", Default = hostState.perf.no3d, Callback = function(v) hostState.perf.no3d = v end })
B.pf:AddToggle("SW_PerfLow", { Text = "Lowest graphics", Default = hostState.perf.low, Callback = function(v) hostState.perf.low = v end })
B.pf:AddToggle("SW_PerfMute", { Text = "Mute", Default = hostState.perf.mute, Callback = function(v) hostState.perf.mute = v end })
B.pf:SetupDependencies({ { Options.SW_Role, "Host" } })

-- Tutorial tab
B.TB = Tabs.Tutorial:AddLeftGroupbox("Tutorial", "graduation-cap")
B.TB:AddLabel("New accounts start in the tutorial. This picks a champion card, plays the bot round (parries + ability), claims the crystals, summons and finishes; the game then sends you to the lobby.", true)
B.TB:AddToggle("DB_Tutorial", { Text = "Auto complete tutorial", Default = CFG.tutorial, Callback = set("tutorial") })
local tutLabel = B.TB:AddLabel("-", true)

-- Misc tab
B.PL = Tabs.Misc:AddLeftGroupbox("Performance (this account)", "gauge")
B.PL:AddLabel("These settings affect this account only. Configure swarm performance on the Swarm tab.", true)
B.PL:AddSlider("DB_Fps", { Text = "FPS cap", Default = CFG.perfFps, Min = 5, Max = 240, Rounding = 0, Tooltip = "60 = off", Callback = set("perfFps") })
B.PL:AddToggle("DB_No3d", { Text = "Turn off 3D rendering", Default = CFG.perf3d, Callback = set("perf3d") })
B.PL:AddToggle("DB_Low", { Text = "Lowest graphics", Default = CFG.perfLow, Callback = set("perfLow") })
B.PL:AddToggle("DB_Mute", { Text = "Mute", Default = CFG.perfMute, Callback = set("perfMute") })
B.TP = Tabs.Misc:AddRightGroupbox("Teleport", "plane")
B.TP:AddToggle("DB_Requeue", { Text = "Reload after teleport", Default = CFG.requeue, Callback = set("requeue") })
B.TP:AddButton({ Text = "Rejoin", Func = function() tpTo(game.PlaceId, game.JobId) end })

B.Menu = Tabs.Settings:AddLeftGroupbox("Menu", "menu")
B.Menu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })

function self.unload()
	alive = false
	for _, c in conns do pcall(function() c:Disconnect() end) end
	for _, d in draw do pcall(function() d:Remove() end) end
	pcall(function() RunService:UnbindFromRenderStep("CruelHubDBAim" .. GEN) end)
	if getgenv().CruelHubDB_GEN == GEN then perfApplied = nil applyPerf({ on = false }) end -- a stale copy leaves the newer one's settings alone
	if getgenv().CruelHubDB == self then getgenv().CruelHubDB = nil end
	pcall(function() Library:Unload() end)
end
Library:OnUnload(function() if alive then self.unload() end end)

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "SW_Role" }) -- role is per account, not per config
SaveManager:SetFolder(DIR)
ThemeManager:SetFolder(DIR)
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:SetDefaultTheme({ BackgroundColor = "0c0a0b", MainColor = "161214", AccentColor = "e0233c", OutlineColor = "2a1d20", FontColor = "f2eded" })
ThemeManager:ApplyToTab(Tabs.Settings)
if not getgenv().CRUELHUB_SAFEBOOT then SaveManager:LoadAutoloadConfig() end -- safe boot: nothing auto-starts

-- label refresh
task.spawn(function()
	while alive do
		if getgenv().CruelHubDB_GEN ~= GEN then self.unload() break end
		local b = live.balls and live.balls[1]
		local ball = b and string.format("Ball: %s · speed %.0f%s", b.mine and "on YOU" or (b.target and b.target.Name or "?"), b.speed,
			b.tti and b.tti < 9 and string.format(" · %.2fs", b.tti) or "") or "Ball: none"
		liveLabel:SetText(("%s\nReader: %s\nLast: %s\nRule: %s"):format(ball, mode, live.last or "-", parryReason))
		statLabel:SetText(("Session: %d presses · %d rounds · %d wins · %d deflects"):format(stats.parries, stats.rounds,
			stat("Wins:Total") - stats.startWins, stat("Deflects:Total") - stats.startDeflects))
		swStatus:SetText(("Role: %s\n%s"):format(SW.role, SW.status))
		swCmdLabel:SetText((voteText ~= "-" and (voteText .. "\n") or "") .. "Last commands: " .. (#cmdLog > 0 and table.concat(cmdLog, ", ", math.max(1, #cmdLog - 3)) or "none"))
		local lines = {}
		for _, m in SW.members do
			lines[#lines + 1] = ("%s [%s] %s · %s · %d wins · %s MB%s%s"):format(m.name, m.role, m.jobId == game.JobId and "here" or "away",
				m.tut and ("tutorial " .. tostring(m.tut)) or (m.inGame and "in round" or (m.ready and "ready" or "lobby")), m.wins or 0,
				tostring(m.mem or "?"), m.guard and " (guard)" or "",
				m.id == LP.UserId and " (you)" or "")
		end
		membersLabel:SetText(#lines > 0 and table.concat(lines, "\n") or "No accounts online")
		local ch = moves.champ
		if ch then
			local t = {}
			for i = 1, 4 do
				local s = ch.slots[i]
				if s then
					local tg = {}
					for k in s.tags do tg[#tg + 1] = k end
					t[#t + 1] = ("%d. %s%s · cd %ss%s"):format(i, s.name, s.unlocked and "" or (" (locked, lvl " .. s.lvl .. ")"), tostring(s.cd),
						#tg > 0 and (" · " .. table.concat(tg, ", ")) or "")
				end
			end
			champLabel:SetText(("%s · level %d\n%s"):format(ch.type, ch.level, table.concat(t, "\n")))
		else
			champLabel:SetText("No champion data yet")
		end
		movesLabel:SetText("Last move: " .. moves.text .. (following() and SW.host.play and SW.host.play.moves ~= "Own" and ("\nHost: " .. SW.host.play.moves) or ""))
		do local a = (SW.role == "Host" and hostState.play.attack) or (SW.host and SW.host.play and SW.host.play.attack) or {}
			atkLabel:SetText(("Victim: %s\nPhase: %s"):format(a.victim ~= "" and a.victim or "-", atkState.phase)) end
		do
			local pp = persona()
			idleLabel:SetText(("Idle: %s\n%s · stop %.0f%% · burst %.1f–%.1fs · dash %.0f%% · jump %.0f%% · air %.0f%%"):format(idle.text, pp.name,
				pp.stop * 100, pp.segMin, pp.segMax, pp.dash * 100, pp.jump * 100, (pp.air or 0) * 100))
		end
		memLabel:SetText(("Memory %.0f MB%s"):format(memGuard.mb, memGuard.on and " · GUARD ON (low graphics)" or ""))
		animLabel:SetText(animLog.first and ("Stopped %d broken tracks (first at %s)"):format(animLog.seen, animLog.first) or "No broken tracks seen")
		moveLabel:SetText("Movement: " .. mv.text .. " (" .. tostring(eff("moveKind")) .. ")")
		do
			local v = SW.role == "Host" and hostState.vote or (SW.host and SW.host.vote) or {}
			voteLabel:SetText(("Mode: %s\nMap: %s%s"):format(v.mode and v.mode.name or "-", v.map and v.map.name or "-",
				voteText ~= "-" and ("\n" .. voteText) or ""))
		end
		tutLabel:SetText(game.PlaceId == TUTORIAL_PLACE and tut.text or "Not in the tutorial")
		task.wait(0.5)
	end
end)

Library:Notify("CruelHub · Death Ball loaded — RightCtrl toggles the UI.", 4)
