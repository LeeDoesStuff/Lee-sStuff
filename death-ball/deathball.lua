-- CruelHub · Death Ball
-- Auto parry (reads the real ball through rawget; never touches the guarded lBall class), auto ready,
-- tutorial automation, ball visuals, and a multi-account swarm (host drives alts over shared workspace files).
-- Spec: deathball-spec.md. Re-exec safe: a newer copy unloads the older one.
if getgenv().CruelHubDB then pcall(getgenv().CruelHubDB.unload) end
local self = {}
getgenv().CruelHubDB = self

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
	parry = false, lead = 0.45, pingComp = true, closeDist = 14, humanize = 0,
	clash = true, clashDist = 18, clashSpeed = 150,
	autoReady = false, autoAbility = false, abilityEvery = 6, antiAfk = true,
	tutorial = true, requeue = true,
	marker = true, markerColor = Color3.fromHex("e0233c"), info = true, velLine = false,
	perfFps = 60, perf3d = false, perfLow = false, perfMute = false,
}
local conns, alive = {}, true
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
local function clickGui(g)
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
		if offs and balls[1] then
			local id = rawget(balls[1], "Id")
			local len = 9 + math.max(rawget(offs, "Position"), rawget(offs, "_last"), rawget(offs, "_sPosition")) + 24 + 15
			if not (store and type(rawget(store, id)) == "string") then
				store = nil
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
	rules = { loseHostAlive = false, loseAliveLE = 0, loseSpeedGE = 0, loseAfter = 0, final = "Always" },
	perf = { on = false, fps = 30, no3d = true, low = true, mute = true },
}
do -- a re-elected host keeps its sequence numbers, so alts don't ignore its new commands
	local old = jread(HOSTF)
	if old and old.id == LP.UserId then
		hostState.seq = old.seq or 0
		hostState.autoplay = old.autoplay or hostState.autoplay
		hostState.rules = old.rules or hostState.rules
		hostState.perf = old.perf or hostState.perf
	end
end
local function hostWrite()
	hostState.t, hostState.placeId, hostState.jobId = os.time(), game.PlaceId, game.JobId
	jwrite(HOSTF, hostState)
end
local function pushCmd(kind, args)
	hostState.seq += 1
	table.insert(hostState.cmds, { id = hostState.seq, kind = kind, args = args or {}, t = os.time() })
	while #hostState.cmds > 10 do table.remove(hostState.cmds, 1) end
	hostWrite()
end
local function hostLive() return SW.host and os.time() - (SW.host.t or 0) <= 10 end
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
	end
	return CFG[k]
end

-- ============================== performance ==============================
local perfApplied
local function applyPerf(p)
	p = p or { on = false }
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
	if r.loseHostAlive and host and host ~= LP and inGame(host) then parryReason = "host alive" return false end
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
local function press(why, ball, d, tti)
	lastPress = os.clock()
	stats.parries += 1
	local h = CFG.humanize
	task.spawn(function()
		if h > 0 then task.wait(math.random() * h / 1000) end
		key(Enum.KeyCode.F)
	end)
	live.last = string.format("%s · %.0f studs · %.2fs · speed %.0f", why, d, tti, ball.speed)
end

on(RunService.Heartbeat, function()
	if not alive then return end
	local me = inGame()
	if me and not roundStart then roundStart = os.clock() stats.rounds += 1 end
	if not me then roundStart = nil end
	if mode == "exact" then
		local id = val("CURRENT_BALL_ID")
		local stale = #balls == 0 or not (rawget(balls[1], "Body") and rawget(balls[1], "Body").Parent)
		if id ~= lastBallId or (stale and id and os.clock() - lastScan > 1) then lastBallId = id scan() end
	end
	local onTut = game.PlaceId == TUTORIAL_PLACE and CFG.tutorial
	local hrp = hrpOf()
	live.balls = (me or onTut) and readBalls() or {}
	if not (eff("parry") or onTut) or not hrp then return end
	local ch = LP.Character
	for _, b in live.balls do
		if b.mine then
			local rel = hrp.Position - b.pos
			local dist = rel.Magnitude
			local d = dist - b.radius
			local closing = dist > 0 and b.vel:Dot(rel.Unit) or 0
			local tti = closing > 1 and d / closing or math.huge
			local lead = CFG.lead + (CFG.pingComp and LP:GetNetworkPing() or 0)
			b.d, b.tti = d, tti
			if not allowedToParry(b) then continue end
			local deflecting = ch:GetAttribute("isDeflecting")
			if CFG.clash and d <= CFG.clashDist and b.speed >= CFG.clashSpeed and os.clock() - lastClash > 0.12 then
				lastClash = os.clock()
				press("clash", b, d, tti)
			elseif (tti <= lead or d <= CFG.closeDist) and os.clock() - lastPress > 0.5 and not deflecting then
				press("parry", b, d, tti)
			end
		end
	end
end)

-- ability + anti afk
task.spawn(function()
	local last = 0
	while alive do
		task.wait(0.5)
		if CFG.autoAbility and inGame() and os.clock() - last >= CFG.abilityEvery then last = os.clock() key(Enum.KeyCode.One) end
	end
end)
on(LP.Idled, function()
	if not CFG.antiAfk then return end
	pcall(function()
		local VU = game:GetService("VirtualUser")
		VU:CaptureController()
		VU:ClickButton2(Vector2.zero)
	end)
end)

-- ============================== auto ready ==============================
local function readyZone()
	for _, n in { "New Lobby", "Lobby" } do
		local f = workspace:FindFirstChild(n)
		local ra = f and f:FindFirstChild("ReadyArea")
		local z = ra and ra:FindFirstChild("ReadyZone")
		if z then return z end
	end
end
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
		if CFG.tutorial and s and os.clock() - lastAct > 1.5 then
			local close = promptClose()
			if close then
				lastAct = os.clock() clickGui(close) tut.text ..= " · closing prompt"
			elseif s == 1 then
				local m = workspace.FX:FindFirstChild("Model")
				local cards = {}
				if m then for _, c in m:GetChildren() do if c.Name == "Card" and c:IsA("BasePart") then cards[#cards + 1] = c end end end
				if #cards >= 3 then lastAct = os.clock() clickWorld(cards[2].Position) tut.text ..= " · picking a card" end
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
				lastAct = os.clock() clickAt(vp.X / 2, vp.Y * 0.75) tut.text ..= " · closing reveal"
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
		parries = stats.parries, hp = val("PLAYER_HEALTH_CURRENT"), tut = game.PlaceId == TUTORIAL_PLACE and tutorialStage() or nil,
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
		if SW.role == "Host" then
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
				SW.status = ("Connected to %s%s"):format(SW.host.name, SW.host.jobId == game.JobId and " · same server" or " · other server")
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
local Library = obsidian("Library.lua", "Library.lua")
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
	end)(), Footer = "Death Ball · parry · swarm · tutorial",
	Size = UDim2.fromOffset(704, 600), Center = true, AutoShow = true, ToggleKeybind = Enum.KeyCode.RightControl,
})
local Tabs = {
	Parry = Window:AddTab("Parry", "shield"),
	Visuals = Window:AddTab("Visuals", "eye"),
	Swarm = Window:AddTab("Swarm", "network"),
	Tutorial = Window:AddTab("Tutorial", "graduation-cap"),
	Misc = Window:AddTab("Misc", "gauge"),
	Settings = Window:AddTab("Settings", "settings"),
}
local function set(k) return function(v) CFG[k] = v end end

-- Parry tab
local AP = Tabs.Parry:AddLeftGroupbox("Auto parry", "shield")
AP:AddToggle("DB_Parry", { Text = "Auto parry", Default = CFG.parry, Callback = set("parry") })
	:AddKeyPicker("DB_ParryKey", { Default = "None", Mode = "Toggle", Text = "Auto parry", SyncToggleState = true })
AP:AddSlider("DB_Lead", { Text = "Parry timing", Default = CFG.lead, Min = 0.15, Max = 0.7, Rounding = 2, Suffix = "s",
	Tooltip = "Presses F when the ball is this many seconds away. The block lasts 0.7 s, so 0.35–0.5 is safe.", Callback = set("lead") })
AP:AddToggle("DB_Ping", { Text = "Add ping to timing", Default = CFG.pingComp, Callback = set("pingComp") })
AP:AddSlider("DB_Close", { Text = "Always parry within", Default = CFG.closeDist, Min = 0, Max = 40, Rounding = 0, Suffix = " studs",
	Callback = set("closeDist") })
AP:AddSlider("DB_Human", { Text = "Random delay", Default = CFG.humanize, Min = 0, Max = 200, Rounding = 0, Suffix = " ms",
	Tooltip = "Adds 0..N ms before each press so the timing doesn't look perfect", Callback = set("humanize") })
local CL = Tabs.Parry:AddLeftGroupbox("Clash", "swords")
CL:AddLabel("Two players trading the ball point-blank: spams F while it's yours, close and fast.", true)
CL:AddToggle("DB_Clash", { Text = "Clash spam", Default = CFG.clash, Callback = set("clash") })
CL:AddSlider("DB_ClashDist", { Text = "Within", Default = CFG.clashDist, Min = 5, Max = 40, Rounding = 0, Suffix = " studs", Callback = set("clashDist") })
CL:AddSlider("DB_ClashSpeed", { Text = "Ball faster than", Default = CFG.clashSpeed, Min = 50, Max = 400, Rounding = 0, Callback = set("clashSpeed") })

local RD = Tabs.Parry:AddRightGroupbox("Rounds", "repeat")
RD:AddToggle("DB_Ready", { Text = "Auto ready", Tooltip = "Walks into the ready zone before every round", Default = CFG.autoReady, Callback = set("autoReady") })
RD:AddToggle("DB_Ability", { Text = "Auto ability", Tooltip = "Presses 1 during rounds", Default = CFG.autoAbility, Callback = set("autoAbility") })
RD:AddSlider("DB_AbilityEvery", { Text = "Ability every", Default = CFG.abilityEvery, Min = 1, Max = 30, Rounding = 0, Suffix = "s", Callback = set("abilityEvery") })
RD:AddToggle("DB_Afk", { Text = "Anti AFK", Default = CFG.antiAfk, Callback = set("antiAfk") })
local LV = Tabs.Parry:AddRightGroupbox("Live", "activity")
local liveLabel = LV:AddLabel("-", true)
local statLabel = LV:AddLabel("-", true)

-- Visuals tab
local VB = Tabs.Visuals:AddLeftGroupbox("Ball", "circle-dot")
VB:AddLabel("The game scrambles the ball part's position for scripts; these draw the real one.", true)
VB:AddToggle("DB_Marker", { Text = "Ball marker", Default = CFG.marker, Callback = set("marker") })
	:AddColorPicker("DB_MarkerCol", { Default = CFG.markerColor, Title = "Targeting you", Callback = set("markerColor") })
VB:AddToggle("DB_Info", { Text = "Target · speed · time", Default = CFG.info, Callback = set("info") })
VB:AddToggle("DB_VelLine", { Text = "Direction line (0.5 s)", Default = CFG.velLine, Callback = set("velLine") })
if not Drawing then VB:AddLabel("Your executor has no Drawing API.", true) end

-- Swarm tab
local ID = Tabs.Swarm:AddLeftGroupbox("Identity", "user")
ID:AddLabel("Accounts on this PC talk through the executor workspace. Pick Host on the account that drives, Swarm on the alts. Saved per account.", true)
ID:AddDropdown("SW_Role", { Text = "This account", Values = { "Off", "Host", "Swarm" }, Default = SW.role,
	Callback = function(v) SW.role = v if hasFiles then pcall(writefile, ROLE_FILE, v) end end })
local swStatus = ID:AddLabel("-", true)
local SD = ID:AddDependencyBox()
SD:AddToggle("SW_Obey", { Text = "Obey host", Tooltip = "Follow the host's autoplay, rules and performance while it's online",
	Default = true, Callback = function(v) SW.obey = v end })
local swCmdLabel = SD:AddLabel("-", true)
SD:SetupDependencies({ { Options.SW_Role, "Swarm" } })

local MB = Tabs.Swarm:AddRightGroupbox("Members", "users")
local membersLabel = MB:AddLabel("-", true)

-- host-only boxes: controls show for the Host role, a hint for the others
local function hostOnly(box)
	for _, r in { "Off", "Swarm" } do
		local hint = box:AddDependencyBox()
		hint:AddLabel("Host controls. Set this account to Host to use them.", true)
		hint:SetupDependencies({ { Options.SW_Role, r } })
	end
	return box:AddDependencyBox()
end
local HD = Tabs.Swarm:AddLeftGroupbox("Servers", "server")
local hd = hostOnly(HD)
hd:AddButton({ Text = "Join my server", Func = function() pushCmd("join", { placeId = game.PlaceId, jobId = game.JobId }) Library:Notify("Swarm: joining you", 3) end })
hd:AddButton({ Text = "Scatter servers", Tooltip = "Every alt goes to a different public server of this mode", Func = function()
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
hd:AddButton({ Text = "Rejoin", Func = function() pushCmd("rejoin") end })
hd:AddButton({ Text = "Reset characters", Func = function() pushCmd("reset") end })
hd:AddDropdown("SW_Mode", { Text = "Send to mode", Values = { "Lobby (beginner)", "Classic", "Death Ball hub", "Pro" }, Default = "Classic" })
hd:AddButton({ Text = "Send swarm to mode", Func = function()
	local ids = { ["Lobby (beginner)"] = 83678792452277, Classic = 71000936793663, ["Death Ball hub"] = 15002061926, Pro = 89775940525999 }
	pushCmd("mode", { placeId = ids[Options.SW_Mode.Value] })
end })
hd:AddButton({ Text = "Close swarm clients", DoubleClick = true, Func = function() pushCmd("close") end })
hd:SetupDependencies({ { Options.SW_Role, "Host" } })

local AU = Tabs.Swarm:AddRightGroupbox("Autoplay", "play")
local au = hostOnly(AU)
au:AddToggle("SW_AutoReady", { Text = "Swarm auto ready", Default = hostState.autoplay.ready, Callback = function(v) hostState.autoplay.ready = v end })
au:AddToggle("SW_AutoParry", { Text = "Swarm auto parry", Default = hostState.autoplay.parry, Callback = function(v) hostState.autoplay.parry = v end })
au:SetupDependencies({ { Options.SW_Role, "Host" } })

local WL = Tabs.Swarm:AddRightGroupbox("Win / lose rules", "scale")
local wl = hostOnly(WL)
wl:AddLabel("Alts stop parrying (and lose) when a lose rule is true. The final rule decides the last 1v1.", true)
wl:AddToggle("SW_LoseHost", { Text = "Lose while host is alive", Default = hostState.rules.loseHostAlive, Callback = function(v) hostState.rules.loseHostAlive = v end })
wl:AddSlider("SW_LoseAlive", { Text = "Lose when alive ≤", Default = hostState.rules.loseAliveLE, Min = 0, Max = 9, Rounding = 0,
	Tooltip = "0 = off", Callback = function(v) hostState.rules.loseAliveLE = v end })
wl:AddSlider("SW_LoseSpeed", { Text = "Lose when ball ≥", Default = hostState.rules.loseSpeedGE, Min = 0, Max = 400, Rounding = 0,
	Tooltip = "0 = off", Callback = function(v) hostState.rules.loseSpeedGE = v end })
wl:AddSlider("SW_LoseAfter", { Text = "Lose after surviving", Default = hostState.rules.loseAfter, Min = 0, Max = 300, Rounding = 0, Suffix = "s",
	Tooltip = "0 = off", Callback = function(v) hostState.rules.loseAfter = v end })
wl:AddDropdown("SW_Final", { Text = "Only win the final 1v1", Values = { "Always", "Never", "Not vs host", "Not vs swarm" },
	Default = hostState.rules.final, Callback = function(v) hostState.rules.final = v end })
wl:SetupDependencies({ { Options.SW_Role, "Host" } })

local PF = Tabs.Swarm:AddLeftGroupbox("Swarm performance", "cpu")
local pf = hostOnly(PF)
pf:AddToggle("SW_PerfOn", { Text = "Apply to swarm", Default = hostState.perf.on, Callback = function(v) hostState.perf.on = v end })
pf:AddSlider("SW_PerfFps", { Text = "FPS cap", Default = hostState.perf.fps, Min = 5, Max = 60, Rounding = 0, Callback = function(v) hostState.perf.fps = v end })
pf:AddToggle("SW_Perf3d", { Text = "Turn off 3D rendering", Default = hostState.perf.no3d, Callback = function(v) hostState.perf.no3d = v end })
pf:AddToggle("SW_PerfLow", { Text = "Lowest graphics", Default = hostState.perf.low, Callback = function(v) hostState.perf.low = v end })
pf:AddToggle("SW_PerfMute", { Text = "Mute", Default = hostState.perf.mute, Callback = function(v) hostState.perf.mute = v end })
pf:SetupDependencies({ { Options.SW_Role, "Host" } })

-- Tutorial tab
local TB = Tabs.Tutorial:AddLeftGroupbox("Tutorial", "graduation-cap")
TB:AddLabel("New accounts start in the tutorial. This picks a champion card, plays the bot round (parries + ability), claims the crystals, summons and finishes; the game then sends you to the lobby.", true)
TB:AddToggle("DB_Tutorial", { Text = "Auto complete tutorial", Default = CFG.tutorial, Callback = set("tutorial") })
local tutLabel = TB:AddLabel("-", true)

-- Misc tab
local PL = Tabs.Misc:AddLeftGroupbox("Performance (this account)", "gauge")
PL:AddLabel("Swarm accounts that obey the host use the host's performance instead.", true)
PL:AddSlider("DB_Fps", { Text = "FPS cap", Default = CFG.perfFps, Min = 5, Max = 240, Rounding = 0, Tooltip = "60 = off", Callback = set("perfFps") })
PL:AddToggle("DB_No3d", { Text = "Turn off 3D rendering", Default = CFG.perf3d, Callback = set("perf3d") })
PL:AddToggle("DB_Low", { Text = "Lowest graphics", Default = CFG.perfLow, Callback = set("perfLow") })
PL:AddToggle("DB_Mute", { Text = "Mute", Default = CFG.perfMute, Callback = set("perfMute") })
local TP = Tabs.Misc:AddRightGroupbox("Teleport", "plane")
TP:AddToggle("DB_Requeue", { Text = "Reload after teleport", Default = CFG.requeue, Callback = set("requeue") })
TP:AddButton({ Text = "Rejoin", Func = function() tpTo(game.PlaceId, game.JobId) end })

local Menu = Tabs.Settings:AddLeftGroupbox("Menu", "menu")
Menu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })

function self.unload()
	alive = false
	for _, c in conns do pcall(function() c:Disconnect() end) end
	for _, d in draw do pcall(function() d:Remove() end) end
	perfApplied = nil
	applyPerf({ on = false })
	getgenv().CruelHubDB = nil
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
SaveManager:LoadAutoloadConfig()

-- label refresh
task.spawn(function()
	while alive do
		local b = live.balls and live.balls[1]
		local ball = b and string.format("Ball: %s · speed %.0f%s", b.mine and "on YOU" or (b.target and b.target.Name or "?"), b.speed,
			b.tti and b.tti < 9 and string.format(" · %.2fs", b.tti) or "") or "Ball: none"
		liveLabel:SetText(("%s\nReader: %s\nLast: %s\nRule: %s"):format(ball, mode, live.last or "-", parryReason))
		statLabel:SetText(("Session: %d presses · %d rounds · %d wins · %d deflects"):format(stats.parries, stats.rounds,
			stat("Wins:Total") - stats.startWins, stat("Deflects:Total") - stats.startDeflects))
		swStatus:SetText(("Role: %s\n%s"):format(SW.role, SW.status))
		swCmdLabel:SetText("Last commands: " .. (#cmdLog > 0 and table.concat(cmdLog, ", ", math.max(1, #cmdLog - 3)) or "none"))
		local lines = {}
		for _, m in SW.members do
			lines[#lines + 1] = ("%s [%s] %s · %s · %d wins%s"):format(m.name, m.role, m.jobId == game.JobId and "here" or "away",
				m.tut and ("tutorial " .. tostring(m.tut)) or (m.inGame and "in round" or (m.ready and "ready" or "lobby")), m.wins or 0,
				m.id == LP.UserId and " (you)" or "")
		end
		membersLabel:SetText(#lines > 0 and table.concat(lines, "\n") or "No accounts online")
		tutLabel:SetText(game.PlaceId == TUTORIAL_PLACE and tut.text or "Not in the tutorial")
		task.wait(0.5)
	end
end)

Library:Notify("CruelHub · Death Ball loaded — RightCtrl toggles the UI.", 4)
