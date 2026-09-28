-- JJBI Hub — Rayfield UI, all farms in one script.
-- Re-run to reload cleanly.
local RS = game:GetService("ReplicatedStorage")
local Network = RS:WaitForChild("Network")
local pg = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")

-- ================= cleanup from previous run =================
if getgenv().JJBIHub then
	getgenv().JJBIHub.alive = false -- kills the old run's loops
	pcall(function() getgenv().JJBIHub.rayfield:Destroy() end)
	for _, c in ipairs(getgenv().JJBIHub.conns or {}) do pcall(function() c:Disconnect() end) end
end
local conns = {}
local hub = { alive = true, conns = conns }
getgenv().JJBIHub = hub

-- ================= state =================
local S = {
	activeFight = nil,   -- nil | "combat" | "worldboss" | "dungeon" | "raid"  (global fight lock)
	engagedAt = 0,
	lastEvent = 0,       -- last combat event on the active channel
	eventCount = 0,
	cooldowns = {}, hpFrac = 1, stamFrac = 1,
	duds = {},
	bossUp = false, inRaidLobby = false,
	notifs = {},         -- recent NotificationEvent texts (tags stripped), newest first
}
-- T = toggle/config values, driven by the Rayfield callbacks
local T = {
	story = false, random = false, worldboss = false, dungeon = false, raid = false,
	dungeonFloor = 1,
	stats = {}, -- statName -> bool
	horseSpeed = false, horseEndurance = false,
	horseReroll = false, horseTraits = {},
	prestige = false,
}

-- dungeon list order in the DungeonFrame menu = StartDungeon floor number
-- ponytail: ordinal mapping assumed from UI order; spy-verify on first use
local DUNGEONS = {
	"Phantom Blood Dungeon", "Battle Tendency Dungeon", "Stardust Crusaders Dungeon",
	"Diamond is Unbreakable Dungeon", "Golden Wind Dungeon", "Stone Ocean Dungeon",
	"Endless Dungeon",
}

local function stripTags(s) return (s:gsub("<[^>]->", "")) end
local function parseList(s)
	local out = {}
	for item in s:gmatch("[^,]+") do
		item = item:match("^%s*(.-)%s*$")
		if #item > 0 then table.insert(out, item:lower()) end
	end
	return out
end
local function matchList(text, list)
	text = text:lower()
	for _, w in ipairs(list) do
		if text:find(w, 1, true) then return w end
	end
	return nil
end

-- ================= combat monitors (the fight lock) =================
-- Every combat channel is watched all the time, so the lock also protects
-- fights the user entered manually: while any fight is live, no engage fires.
local function parseBattle(data)
	local me = data.Battle and data.Battle.Player
	if me then
		S.cooldowns = me.Cooldowns or {}
		if me.MaxHP and me.MaxHP > 0 then S.hpFrac = (me.HP or 0) / me.MaxHP end
		if me.MaxStamina and me.MaxStamina > 0 then S.stamFrac = (me.Stamina or 0) / me.MaxStamina end
	end
	if data.LogMsg then print("[HUB] " .. stripTags(data.LogMsg)) end
end

local onDefeat -- set below (needs the toggles)

local KNOWN_EVENTS = { Start=1, TurnStrike=1, Update=1, WaveComplete=1, Victory=1, Defeat=1,
	SyncBoss=1, LobbiesUpdate=1, LobbyStatus=1, MatchStart=1, Waiting=1, TrainingTick=1 }

local function watchChannel(remoteName, sys)
	local r = Network:WaitForChild(remoteName)
	table.insert(conns, r.OnClientEvent:Connect(function(event, data)
		pcall(function()
			local isTable = type(data) == "table"
			local mine = isTable and data.Battle ~= nil
			if sys == S.activeFight or mine then
				S.lastEvent = os.clock()
				S.eventCount += 1
			end
			if isTable then parseBattle(data) end
			if event == "Start" or event == "MatchStart" then
				-- claim the lock only for our own fight: either we engaged it, or the
				-- payload carries our Battle (WB/raid events can broadcast to everyone)
				if S.activeFight == sys or mine then
					S.activeFight = sys
					S.duds = {}
					print("[HUB] fight started (" .. sys .. ")")
				end
			elseif event == "Victory" or event == "Defeat" then
				if S.activeFight == sys then
					S.activeFight = nil
					print("[HUB] " .. event .. " (" .. sys .. ")")
					if sys == "worldboss" then S.bossUp = false end
					if event == "Defeat" and onDefeat then onDefeat() end
				end
			elseif event == "SyncBoss" then
				S.bossUp = true
				print("[HUB] world boss spawned: " .. tostring(data))
			elseif event == "LobbyStatus" then
				S.inRaidLobby = true
			elseif not KNOWN_EVENTS[event] then
				-- unknown event = probably a terminal we haven't cataloged (WB/raid)
				print("[HUB] event " .. remoteName .. "." .. tostring(event))
				if S.activeFight == sys then
					S.activeFight = nil
					if sys == "worldboss" then S.bossUp = false end
				end
			end
		end)
	end))
end
watchChannel("CombatUpdate", "combat")
watchChannel("WorldBossUpdate", "worldboss")
watchChannel("DungeonUpdate", "dungeon")
watchChannel("RaidUpdate", "raid")

-- notifications drive the reroll whitelists (full text arrives here)
table.insert(conns, Network:WaitForChild("NotificationEvent").OnClientEvent:Connect(function(msg)
	pcall(function()
		if type(msg) == "string" then
			table.insert(S.notifs, 1, stripTags(msg))
			if #S.notifs > 30 then table.remove(S.notifs) end
		end
	end)
end))
local function recentNotifMatch(list, count)
	for i = 1, math.min(count or 3, #S.notifs) do
		local hit = matchList(S.notifs[i], list)
		if hit then return hit, S.notifs[i] end
	end
	return nil
end

-- ================= combat engine (spec/stand agnostic) =================
local BASE_MOVES = { ["Basic Attack"]=true, ["Heavy Strike"]=true, ["Block"]=true, ["Rest"]=true, ["Flee"]=true }
local KNOWN_PRIORITY = {
	"Stand Barrage", "Horn Drill", "Body Contortion", "Flesh Assimilation",
	"Accelerated Knives", "Speed Slice", "Time Acceleration", "Universe Reset",
}
local FALLBACK = { "Heavy Strike", "Basic Attack" }

local function isShown(gui)
	local o = gui
	while o and o:IsA("GuiObject") do
		if not o.Visible then return false end
		o = o.Parent
	end
	return true
end

-- whichever combat UI is currently on screen (story/random/WB/dungeon/raid all
-- have their own AbilitiesArea; the game's buttons fire the right remote for us)
local function activeAbilities()
	for _, d in ipairs(pg:GetDescendants()) do
		if d.Name == "AbilitiesArea" and isShown(d) then return d end
	end
	return nil
end

local function click(btn)
	for _, name in ipairs({ "Activated", "MouseButton1Click" }) do
		local cs = getconnections(btn[name])
		if #cs > 0 then
			for _, c in ipairs(cs) do pcall(function() c:Fire() end) end
			return true
		end
	end
	return false
end

local function baseName(n) return (n:gsub("%s*%(%d+%)%s*$", "")) end

local function usable(area, name)
	if S.duds[name] or S.cooldowns[name] then return nil end
	for _, child in ipairs(area:GetChildren()) do
		if child:IsA("GuiButton") and baseName(child.Name) == name then
			-- "(N)" suffix on the live name = N turns of cooldown left
			if child.Interactable and not child.Name:match("%(%d+%)%s*$") then return child end
			return nil
		end
	end
	return nil
end

local function pickMove(area)
	if S.hpFrac < 0.3 then
		local b = usable(area, "Block")
		if b then return b, "Block" end
	end
	if S.stamFrac < 0.15 then
		local b = usable(area, "Rest")
		if b then return b, "Rest" end
	end
	-- discover this stand's specials live, known priority first
	local specials, prio = {}, {}
	for i, n in ipairs(KNOWN_PRIORITY) do prio[n] = i end
	for _, child in ipairs(area:GetChildren()) do
		if child:IsA("GuiButton") then
			local n = baseName(child.Name)
			if not BASE_MOVES[n] then table.insert(specials, n) end
		end
	end
	table.sort(specials, function(a, b)
		local pa, pb = prio[a], prio[b]
		if pa and pb then return pa < pb end
		if pa or pb then return pa ~= nil end
		return a < b
	end)
	for _, n in ipairs(specials) do
		local b = usable(area, n)
		if b then return b, n end
	end
	for _, n in ipairs(FALLBACK) do
		local b = usable(area, n)
		if b then return b, n end
	end
	return nil
end

-- one combat turn; dud/stuck watchdog falls back to Basic Attack
local lastMove, lastEvents, dudClicks = nil, 0, 0
local function fightTick()
	local area = activeAbilities()
	if not area then return end
	local b, name
	if os.clock() - S.lastEvent > 6 then
		-- stuck: server stopped reacting to our picks — hammer Basic Attack
		b, name = usable(area, "Basic Attack"), "Basic Attack"
		if not b then b, name = pickMove(area) end
	else
		b, name = pickMove(area)
	end
	if not b then return end
	if name == lastMove and S.eventCount == lastEvents then
		dudClicks += 1
		if dudClicks >= 2 and not BASE_MOVES[name] then
			S.duds[name] = true
			print("[HUB] '" .. name .. "' does nothing — skipping this fight")
		end
	else
		dudClicks = 0
	end
	lastMove, lastEvents = name, S.eventCount
	click(b)
end

-- ================= engage helpers =================
local function engage(sys, fire)
	S.activeFight = sys -- optimistic lock: no other engage can race us
	S.engagedAt = os.clock()
	S.lastEvent = os.clock()
	pcall(fire)
end

local function worldBossReady()
	if not S.bossUp then
		-- also trust the engage button if the WB menu is loaded
		local ok, txt = pcall(function()
			return pg.JJBIMenu.MainFrame.ContentContainer.SingleplayerFrame.MainPanel
				.InnerContent.ContentArea.WorldBossFrame.MenuContainer.InfoCard.EngageBtn.Text
		end)
		return ok and txt == "ENGAGE BOSS"
	end
	return true
end

-- ================= orchestrator =================
task.spawn(function()
	while hub.alive do
		pcall(function()
			if S.activeFight then
				-- 20s with no combat events = failed engage or uncataloged fight end
				if os.clock() - S.lastEvent > 20 then
					print("[HUB] fight went silent — releasing lock")
					if S.activeFight == "worldboss" then S.bossUp = false end
					S.activeFight = nil
				end
				if S.activeFight then fightTick() end
			else
				S.cooldowns = {}
				-- priority: world boss > raid > dungeon > story/random
				if T.worldboss and worldBossReady() then
					engage("worldboss", function() Network.WorldBossAction:FireServer("Engage") end)
				elseif T.raid and S.inRaidLobby then
					-- ponytail: lobby creation args unknown; join/create the raid lobby
					-- manually once, the hub force-starts and fights it
					engage("raid", function() Network.RaidAction:FireServer("ForceStartRaid") end)
				elseif T.dungeon then
					engage("dungeon", function() Network.DungeonAction:FireServer("StartDungeon", T.dungeonFloor) end)
				elseif T.story then
					engage("combat", function() Network.CombatAction:FireServer("EngageStory") end)
				elseif T.random then
					engage("combat", function() Network.CombatAction:FireServer("EngageRandom") end)
				end
			end
		end)
		task.wait(1)
	end
end)

-- ================= side loops =================
local function sideLoop(interval, fn)
	task.spawn(function()
		while hub.alive do
			pcall(fn)
			task.wait(interval)
		end
	end)
end

-- stats: server ignores the call when no points are available
sideLoop(3, function()
	for stat, on in pairs(T.stats) do
		if on then Network.UpgradeStat:FireServer(stat, 1) end
	end
end)

-- SBR horse upgrades: server gates these behind its own upgrade timer
sideLoop(8, function()
	if T.horseSpeed then Network.SBRAction:FireServer("UpgradeHorse", "Speed") end
	if T.horseEndurance then Network.SBRAction:FireServer("UpgradeHorse", "Endurance") end
end)

-- needs the Rayfield toggle object to switch itself off
local horseToggle, Rayfield

sideLoop(2.5, function()
	if not T.horseReroll then return end
	if #T.horseTraits > 0 then
		local hit, msg = recentNotifMatch(T.horseTraits, 3)
		if hit then
			T.horseReroll = false
			pcall(function() horseToggle:Set(false) end)
			pcall(function() Rayfield:Notify({ Title = "Horse trait hit!", Content = msg, Duration = 8 }) end)
			print("[HUB] horse reroll stopped: " .. msg)
			return
		end
	end
	Network.SBRAction:FireServer("RerollHorseYen")
end)

-- prestige: server ignores it until requirements are met
sideLoop(30, function()
	if T.prestige then Network.PrestigeEvent:FireServer() end
end)

-- ================= Rayfield UI =================
Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Window = Rayfield:CreateWindow({
	Name = "JohnChina's Bizarre AutoFarm",
	ConfigurationSaving = { Enabled = true, FolderName = "JJBIHub", FileName = "config" },
})

-- ---- Combat tab ----
local Combat = Window:CreateTab("Combat", 4483362458)
local storyToggle, randomToggle
local mutex = false -- guard against Set() re-entering the callbacks
storyToggle = Combat:CreateToggle({
	Name = "Auto Story", CurrentValue = false, Flag = "AutoStory",
	Callback = function(v)
		T.story = v
		if v and not mutex then
			mutex = true
			pcall(function() randomToggle:Set(false) end)
			mutex = false
		end
	end,
})
randomToggle = Combat:CreateToggle({
	Name = "Auto Random Encounter", CurrentValue = false, Flag = "AutoRandom",
	Callback = function(v)
		T.random = v
		if v and not mutex then
			mutex = true
			pcall(function() storyToggle:Set(false) end)
			mutex = false
		end
	end,
})
Combat:CreateToggle({
	Name = "Auto World Boss", CurrentValue = false, Flag = "AutoWB",
	Callback = function(v) T.worldboss = v end,
})
Combat:CreateToggle({
	Name = "Auto Dungeon", CurrentValue = false, Flag = "AutoDungeon",
	Callback = function(v) T.dungeon = v end,
})
Combat:CreateDropdown({
	Name = "Dungeon", Options = DUNGEONS, CurrentOption = { DUNGEONS[1] },
	MultipleOptions = false, Flag = "DungeonPick",
	Callback = function(v)
		local name = type(v) == "table" and v[1] or v
		T.dungeonFloor = table.find(DUNGEONS, name) or 1
	end,
})
Combat:CreateToggle({
	Name = "Auto Raid (join/make lobby manually)", CurrentValue = false, Flag = "AutoRaid",
	Callback = function(v) T.raid = v end,
})
Combat:CreateParagraph({
	Title = "Fight lock",
	Content = "Only one fight can run at a time. World boss/raid fights (even ones you enter yourself) freeze story/random farming until they finish.",
})

onDefeat = function()
	-- lost a fight: stop all combat farming for safety
	T.story, T.random, T.worldboss, T.dungeon, T.raid = false, false, false, false, false
	for _, t in ipairs({ storyToggle, randomToggle }) do pcall(function() t:Set(false) end) end
	pcall(function() Rayfield:Notify({ Title = "Defeat", Content = "Combat farming stopped for safety.", Duration = 8 }) end)
	print("[HUB] defeated — combat farming stopped")
end

-- ---- Stats tab ----
-- stat keys = frame names in PlayerStatsCard/StandStatsCard (verified via scan)
local Stats = Window:CreateTab("Stats", 4483362458)
for _, stat in ipairs({
	{ "Health", "Health" }, { "Strength", "Strength" }, { "Defense", "Defense" },
	{ "Speed", "Speed" }, { "Stamina", "Stamina" }, { "Willpower", "Willpower" },
	{ "Stand Power", "Stand_Power_Val" }, { "Stand Speed", "Stand_Speed_Val" },
	{ "Stand Range", "Stand_Range_Val" }, { "Stand Durability", "Stand_Durability_Val" },
	{ "Stand Precision", "Stand_Precision_Val" }, { "Stand Potential", "Stand_Potential_Val" },
}) do
	Stats:CreateToggle({
		Name = "Auto " .. stat[1], CurrentValue = false, Flag = "Stat_" .. stat[2],
		Callback = function(v) T.stats[stat[2]] = v end,
	})
end

-- ---- SBR tab ----
local SBR = Window:CreateTab("SBR", 4483362458)
local speedToggle, enduranceToggle
speedToggle = SBR:CreateToggle({
	Name = "Auto Upgrade Horse Speed", CurrentValue = false, Flag = "HorseSpeed",
	Callback = function(v)
		T.horseSpeed = v
		if v and not mutex then
			mutex = true
			T.horseEndurance = false
			pcall(function() enduranceToggle:Set(false) end)
			mutex = false
		end
	end,
})
enduranceToggle = SBR:CreateToggle({
	Name = "Auto Upgrade Horse Endurance", CurrentValue = false, Flag = "HorseEndurance",
	Callback = function(v)
		T.horseEndurance = v
		if v and not mutex then
			mutex = true
			T.horseSpeed = false
			pcall(function() speedToggle:Set(false) end)
			mutex = false
		end
	end,
})
SBR:CreateInput({
	Name = "Horse trait whitelist (stop on match)", PlaceholderText = "Thoroughbred, Swift",
	RemoveTextAfterFocusLost = false, Flag = "HorseTraits",
	Callback = function(v) T.horseTraits = parseList(v) end,
})
horseToggle = SBR:CreateToggle({
	Name = "Auto Reroll Horse Trait", CurrentValue = false, Flag = "HorseReroll",
	Callback = function(v) T.horseReroll = v end,
})

-- ---- Misc tab ----
local Misc = Window:CreateTab("Misc", 4483362458)
Misc:CreateToggle({
	Name = "Auto Prestige", CurrentValue = false, Flag = "AutoPrestige",
	Callback = function(v) T.prestige = v end,
})

hub.rayfield = Rayfield
print("[HUB] loaded — JJBI Hub ready")
