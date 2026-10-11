-- Generic game recon, run in steps: loadstring(readfile("recon.lua"))(step, arg)
-- 1        = static: info, attrs, tree, remotes + which scripts reference them (!NOCALLER = honeypot candidate)
-- 2 [pat]  = decompile ReplicatedStorage modules + player LocalScripts (name filter pat optional). Resumable, 300 per run
-- 3 [secs] = spy (default 90s): outgoing FireServer/InvokeServer tagged GAME/ME, inbound events, attribute changes
-- "snap" label = dump attrs/leaderstats/PlayerData values to snap_<label>.txt (diff before/after rebirth or rejoin)
-- Every step yields often; output -> workspace/recon_<PlaceId>/, progress in status_<step>.txt
local step, arg = ...
step = step or 1
local D = "recon_" .. game.PlaceId .. "/"
if not isfolder(D) then makefolder(D) end
if not isfolder(D .. "src") then makefolder(D .. "src") end
local function W(f, s) writefile(D .. f, s) end
local ST = "status_" .. tostring(step) .. ".txt"
W(ST, "started " .. os.clock())

local P = game:GetService("Players").LocalPlayer
local RS = game:GetService("ReplicatedStorage")

local function isRemote(d)
	return d:IsA("BaseRemoteEvent") or d:IsA("RemoteFunction")
end

-- ponytail: never tostring/iterate tables with metatables or userdata; trap-guarded classes (Death Ball) kill the client on that
local function ser(v, d)
	d = d or 0
	local t = typeof(v)
	if t == "table" then
		if getmetatable(v) ~= nil then return "<table+mt>" end
		if d > 1 then return "{..}" end
		local p, i = {}, 0
		for k, x in next, v do
			i += 1
			if i > 10 then p[#p + 1] = "..."; break end
			p[#p + 1] = ser(k, 9) .. "=" .. ser(x, d + 1)
		end
		return "{" .. table.concat(p, ",") .. "}"
	elseif t == "Instance" then return v:GetFullName()
	elseif t == "string" then return ("%q"):format(v:sub(1, 80))
	elseif t == "userdata" then return "<userdata>"
	elseif t == "buffer" then return "<buffer " .. buffer.len(v) .. ">" end
	return tostring(v)
end

local function attrs(out, tag, inst)
	for k, v in inst:GetAttributes() do out[#out + 1] = tag .. " " .. k .. " = " .. ser(v) end
end

local function values(out, tag, root)
	for i, v in root:GetDescendants() do
		if v:IsA("ValueBase") then out[#out + 1] = tag .. " " .. v:GetFullName() .. " = " .. ser(v.Value) end
		if i % 300 == 0 then task.wait() end
	end
end

local steps = {}

steps[1] = function()
	local out = {}
	local function add(s) out[#out + 1] = s end
	add(("PlaceId %d GameId %d PlaceVersion %d JobId %s Players %d"):format(game.PlaceId, game.GameId, game.PlaceVersion, game.JobId, #game:GetService("Players"):GetPlayers()))
	add(("CreatorType %s CreatorId %d PrivateServerId %q StreamingEnabled %s"):format(tostring(game.CreatorType), game.CreatorId, game.PrivateServerId, tostring(workspace.StreamingEnabled)))
	pcall(function()
		local pages = game:GetService("AssetService"):GetGamePlacesAsync()
		for _, pl in pages:GetCurrentPage() do add("PLACE " .. pl.PlaceId .. " " .. pl.Name) end
	end)
	attrs(out, "PATTR", P)
	attrs(out, "GUIATTR", P:WaitForChild("PlayerGui"))
	attrs(out, "WATTR", workspace)
	attrs(out, "RSATTR", RS)
	for _, f in P:GetChildren() do
		if not (f:IsA("PlayerGui") or f:IsA("PlayerScripts") or f:IsA("Backpack")) then values(out, "PVAL", f) end
	end
	W("info.txt", table.concat(out, "\n"))
	W(ST, "info done")

	-- tree: depth-limited, big folders collapsed, yields every 200 nodes
	out = {}
	local n = 0
	local function tree(inst, depth, max, pre)
		n += 1
		if n % 200 == 0 then task.wait() end
		local kids = inst:GetChildren()
		add(pre .. inst.ClassName .. " " .. inst.Name .. (#kids > 0 and (" [" .. #kids .. "]") or ""))
		if depth >= max then return end
		if #kids > 60 then
			local cls = {}
			for _, c in kids do cls[c.ClassName] = (cls[c.ClassName] or 0) + 1 end
			for c, k in cls do add(pre .. "  (" .. k .. "x " .. c .. ", first: " .. kids[1].Name .. ")") end
			return
		end
		for _, c in kids do tree(c, depth + 1, max, pre .. "  ") end
	end
	tree(RS, 0, 5, "")
	tree(workspace, 0, 3, "")
	tree(P.PlayerGui, 0, 3, "")
	W("tree.txt", table.concat(out, "\n"))
	W(ST, "tree done")

	local remotes = {}
	for i, d in RS:GetDescendants() do
		if isRemote(d) then remotes[#remotes + 1] = d end
		if i % 500 == 0 then task.wait() end
	end

	-- bytecode once per script, yield after each (unyielded loops froze Pixel Conquest twice)
	local bcs = {}
	for _, s in getscripts() do
		local ok, bc = pcall(getscriptbytecode, s)
		if ok and bc then bcs[#bcs + 1] = { s:GetFullName(), bc } end
		task.wait()
	end
	W(ST, "bytecode cached " .. #bcs)
	out = {}
	for i, r in remotes do
		local users = {}
		for _, b in bcs do
			if b[2]:find(r.Name, 1, true) then users[#users + 1] = b[1] end
			if #users >= 6 then break end
		end
		add((#users == 0 and "!NOCALLER " or "") .. r.ClassName .. " " .. r:GetFullName() .. "  <- " .. table.concat(users, ", "))
		if i % 10 == 0 then task.wait() end
	end
	W("remotes.txt", table.concat(out, "\n"))
end

steps[2] = function()
	local pat = arg
	local list = {}
	for _, s in getscripts() do
		local mine = s:IsDescendantOf(RS) and s:IsA("ModuleScript") or s:IsDescendantOf(P) and (s:IsA("LocalScript") or s:IsA("ModuleScript"))
		if mine and (not pat or s:GetFullName():lower():find(pat:lower(), 1, true)) then list[#list + 1] = s end
	end
	local done, names = 0, {}
	for i, s in list do
		local fname = s:GetFullName():gsub("[^%w_%.]", "_"):sub(-100) .. ".lua"
		if not isfile(D .. "src/" .. fname) then
			local ok, src = pcall(decompile, s)
			if ok and src and #src > 40 then
				writefile(D .. "src/" .. fname, src)
				names[#names + 1] = #src .. "\t" .. fname
			end
			done += 1
			task.wait()
		end
		if done >= 300 then W(ST, "paused at " .. i .. "/" .. #list .. ", run step 2 again"); break end
		if i % 10 == 0 then W(ST, "decompiled " .. i .. "/" .. #list) end
	end
	if not isfile(D .. "modules.txt") then writefile(D .. "modules.txt", "") end -- appendfile fails silently on a missing file
	appendfile(D .. "modules.txt",table.concat(names, "\n") .. "\n")
end

steps[3] = function()
	local secs = tonumber(arg) or 90
	local log, counts, stop = {}, {}, false
	local function push(tag, m, who, args)
		log[#log + 1] = { os.clock(), tag, m, who, args }
	end
	local old
	old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		if not stop then
			local m = getnamecallmethod()
			if (m == "FireServer" or m == "InvokeServer") and typeof(self) == "Instance" then
				local c = (counts[self] or 0) + 1
				counts[self] = c
				if c <= 20 then push(checkcaller() and "ME" or "GAME", m, self, table.pack(...)) end
			end
		end
		return old(self, ...)
	end))
	local conns, inCount = {}, {}
	for _, r in RS:GetDescendants() do
		if r:IsA("BaseRemoteEvent") then
			conns[#conns + 1] = r.OnClientEvent:Connect(function(...)
				local c = (inCount[r] or 0) + 1
				inCount[r] = c
				if c <= 8 then push("IN", "", r, table.pack(...)) end
			end)
		end
	end
	for _, inst in { P, workspace, RS } do
		conns[#conns + 1] = inst.AttributeChanged:Connect(function(k)
			push("ATTR", k, inst, table.pack(inst:GetAttribute(k)))
		end)
	end
	local function dump(final)
		local out = {}
		for i, e in log do
			local p = {}
			for j = 1, e[5].n do p[j] = ser(e[5][j]) end
			out[#out + 1] = ("%.1f %s %s %s(%s)"):format(e[1], e[2], e[3], e[4]:GetFullName(), table.concat(p, ", "):sub(1, 500))
			if i % 50 == 0 then task.wait() end
		end
		if final then
			local c = {}
			for k, v in counts do c[#c + 1] = k.Name .. " x" .. v end
			out[#out + 1] = "\nOUT COUNTS " .. table.concat(c, ", ")
			c = {}
			for k, v in inCount do c[#c + 1] = k.Name .. " x" .. v end
			out[#out + 1] = "IN COUNTS " .. table.concat(c, ", ")
		end
		W("spy.txt", table.concat(out, "\n"))
	end
	for t = 10, secs, 10 do
		task.wait(10)
		dump(false)
		W(ST, "spying " .. t .. "/" .. secs .. "s, entries " .. #log)
	end
	stop = true
	for _, c in conns do c:Disconnect() end
	dump(true)
end

steps.snap = function()
	local out = { "time " .. os.time() .. " PlaceVersion " .. game.PlaceVersion }
	attrs(out, "PATTR", P)
	attrs(out, "WATTR", workspace)
	for _, f in P:GetChildren() do
		if not (f:IsA("PlayerGui") or f:IsA("PlayerScripts") or f:IsA("Backpack")) then values(out, "PVAL", f) end
	end
	table.sort(out)
	W("snap_" .. tostring(arg or "x") .. ".txt", table.concat(out, "\n"))
end

local ok, err = pcall(steps[step])
W(ST, ok and "done" or ("ERROR " .. tostring(err)))
