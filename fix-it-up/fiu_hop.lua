--[[
    Fix It Up! — low-seller server hopper
    UI: Obsidian (deividcomsono)

    Hops public servers until every other player has fewer than N "Cars Sold"
    (leaderstats["Cars Sold"], mirrors PlayerData.Status.CarsSold).
    The servers API exposes no user ids, so there is no way to see a server's
    stats from outside: it joins, checks, hops again.

    Deploy: Potassium workspace\fiu_hop.lua  ->  loadstring(readfile("fiu_hop.lua"))()
    State lives in fiu_hop.json so settings + visited servers survive teleports.
]]

if getgenv().FIU_Hop_Unload then pcall(getgenv().FIU_Hop_Unload) end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players         = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService     = game:GetService("HttpService")
local LP              = Players.LocalPlayer
local req             = request or http_request or (syn and syn.request)

local FILE, SELF = "fiu_hop.json", "fiu_hop.lua"
local VISIT_TTL  = 3600 -- don't re-check a server for an hour

local cfg = { auto = false, max = 50, over = 0, maxp = 8, hops = 0, visited = {} }
pcall(function()
    for k, v in pairs(HttpService:JSONDecode(readfile(FILE))) do cfg[k] = v end
end)
local function save() pcall(writefile, FILE, HttpService:JSONEncode(cfg)) end

local now = os.time()
for id, t in pairs(cfg.visited) do
    if now - t > VISIT_TTL then cfg.visited[id] = nil end
end
cfg.visited[game.JobId] = now
save()

local alive, hopping, queued = true, false, false

-- values = Cars Sold of every other player (math.huge = stats never loaded, counts as over)
local function judge(values, c)
    local over = 0
    for _, v in ipairs(values) do
        if v >= c.max then over += 1 end
    end
    return #values >= 1 and over <= c.over, over
end
assert(judge({ 10, 49 }, { max = 50, over = 0 }))
assert(not judge({ 10, 50 }, { max = 50, over = 0 }))
assert(judge({ 10, 900 }, { max = 50, over = 1 }))
assert(not judge({}, { max = 50, over = 0 }))

local function soldOf(pl)
    local ls = pl:FindFirstChild("leaderstats")
    local v = ls and ls:FindFirstChild("Cars Sold")
    return v and tonumber(v.Value)
end

-- Waits up to 8s for everyone's leaderstats to replicate.
local function scan()
    local deadline, others = os.clock() + 8, nil
    repeat
        others = {}
        local missing = false
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl ~= LP then
                local s = soldOf(pl)
                if not s then missing = true end
                table.insert(others, s or math.huge)
            end
        end
        if not missing then break end
        task.wait(0.5)
    until os.clock() > deadline
    table.sort(others)
    return others
end

-- ONE request per hop, page 1 only. Measured 2026-09-25: the API 429s on the 3rd call
-- within 4s, and every retry while limited extends the ban. Page 1 ascending is the 100
-- smallest servers (1-7 players here), which is where the player cap lives anyway.
-- Returns server, or nil + reason (429 / http code / nil = nothing unvisited under the cap).
local function candidates()
    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100")
        :format(game.PlaceId)
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
    if not ok or type(data) ~= "table" or type(data.data) ~= "table" then
        return nil, data and data.errors and 429 or code
    end
    local best
    for _, s in ipairs(data.data) do
        local p = s.playing or 0
        if not cfg.visited[s.id] and p >= 1 and p <= cfg.maxp and p < (s.maxPlayers or 0) then
            -- ponytail: largest server under the cap = most low-sellers per hop. Lower the cap if it keeps failing.
            if not best or p > best.playing then best = s end
        end
    end
    return best
end

-- ============================== Obsidian UI ==============================
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua"))()

local Window = Library:CreateWindow({
    Title    = "Fix It Up! — Server Hop",
    Footer   = "low Cars Sold finder",
    Size = UDim2.fromOffset(704, 824), -- default window size (user pick)
    Center   = true,
    AutoShow = true,
})

local Tab  = Window:AddTab("Main")
local Hop  = Tab:AddLeftGroupbox("Auto Hop")
local Info = Tab:AddRightGroupbox("This Server")

local statusLabel = Hop:AddLabel("idle", true)
local serverLabel = Info:AddLabel("scanning...", true)
local function status(s) pcall(function() statusLabel:SetText(s) end) end

-- A teleport that fails is otherwise a silent 15s stall in the hop loop.
local tpFail = TeleportService.TeleportInitFailed:Connect(function(_, result, msg)
    status(("teleport failed: %s %s"):format(tostring(result), tostring(msg)))
end)

local function check()
    local vals = scan()
    local ok, over = judge(vals, cfg)
    local shown = {}
    for i, v in ipairs(vals) do
        shown[i] = v == math.huge and "?" or tostring(v)
    end
    pcall(function()
        serverLabel:SetText(("%d others · %d at/over %d\nlowest %s · highest %s\n%s")
            :format(#vals, over, cfg.max, shown[1] or "-", shown[#shown] or "-",
                ok and "PASSES" or "fails"))
    end)
    return ok, #vals, over
end

local function hop()
    if hopping then return end
    hopping = true
    local q = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
    if not q then
        Library:Notify("Executor has no queue_on_teleport — script won't reload after hopping.", 6)
    elseif not queued then
        queued = pcall(q, ('loadstring(readfile("%s"))()'):format(SELF))
    end
    local backoff = 60
    while alive and cfg.auto do
        local s, why = candidates()
        if s then
            backoff = 60
            cfg.visited[s.id] = os.time()
            cfg.hops += 1
            save()
            status(("hop #%d -> %d/%d players"):format(cfg.hops, s.playing, s.maxPlayers))
            pcall(TeleportService.TeleportToPlaceInstance, TeleportService, game.PlaceId, s.id, LP)
            task.wait(15) -- teleport normally leaves before this; still here = it failed, try next
        elseif why == 429 then
            status(("Roblox rate-limited the server list, waiting %ds"):format(backoff))
            task.wait(backoff)
            backoff = math.min(backoff * 2, 300)
        elseif why then
            status(("server list failed (%s), retry in 30s"):format(tostring(why)))
            task.wait(30)
        else
            status(("no unvisited servers with <= %d players, retry in 30s"):format(cfg.maxp))
            task.wait(30)
        end
    end
    hopping = false
end

local autoToggle

local function run()
    status("checking this server...")
    task.wait(2) -- let the player list settle after joining
    if not (alive and cfg.auto) then return end
    local ok, n, over = check()
    if ok then
        cfg.auto = false
        save()
        autoToggle:SetValue(false)
        status(("FOUND after %d hops: %d others, %d over limit"):format(cfg.hops, n, over))
        Library:Notify(("Found it! %d players, all under %d cars sold."):format(n, cfg.max), 15)
    else
        hop()
    end
end

autoToggle = Hop:AddToggle("FIU_Auto", {
    Text     = "Auto hop until match",
    Tooltip  = "Checks this server, hops if it fails, repeats after every teleport",
    Default  = cfg.auto,
    Callback = function(v)
        if v == cfg.auto then return end
        cfg.auto = v
        if v then cfg.hops = 0 end
        save()
        if v then task.spawn(run) else status("stopped") end
    end,
})

Hop:AddSlider("FIU_Max", {
    Text = "Cars Sold must be under", Default = cfg.max, Min = 5, Max = 500, Rounding = 0,
    Callback = function(v) cfg.max = v; save() end,
})
Hop:AddSlider("FIU_Over", {
    Text = "Players allowed over limit", Default = cfg.over, Min = 0, Max = 10, Rounding = 0,
    Tooltip = "0 = everyone must be under. Raise it if hunting takes forever.",
    Callback = function(v) cfg.over = v; save() end,
})
Hop:AddSlider("FIU_MaxP", {
    Text = "Max other players", Default = cfg.maxp, Min = 1, Max = 21, Rounding = 0,
    Tooltip = "Only hop into servers with at most this many players. Smaller = passes more often.",
    Callback = function(v) cfg.maxp = v; save() end,
})

Info:AddButton({
    Text = "Rescan this server",
    Func = function() task.spawn(check) end,
})
Info:AddButton({
    Text = "Forget visited servers",
    Func = function()
        cfg.visited = { [game.JobId] = os.time() }
        save()
        Library:Notify("Visited list cleared.", 3)
    end,
})

local Menu = Tab:AddRightGroupbox("Menu")
Menu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })

Library:OnUnload(function()
    alive = false
    pcall(function() tpFail:Disconnect() end)
    getgenv().FIU_Hop_Unload = nil
end)
getgenv().FIU_Hop_Unload = function() Library:Unload() end

if cfg.auto then
    task.spawn(run)
else
    task.spawn(check)
end
