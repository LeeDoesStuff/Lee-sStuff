--[[
    Hit The Thrift v2  (place 122454884469606)
    UI: Obsidian (deividcomsono)
    ESP: every item on the thrift racks, shoe/glasses shelves and jewelry displays, by rarity:
      - a dot on each item (optional name + rack price), colored by rarity
      - a summary over each rack: rarity counts + floor
      - a rack outline in the color of its best shown rarity
      - Finds tab: every item at or above a rarity, with its rack + floor
    Data: the children of any part with attribute Main=true carry ItemKey ("Key" or "Key_Color=Blue"); rarity comes
    from ClothingModule.Items. A restock swaps the slot models; buying one deletes it locally, so its dot goes too.
    Matcha: auto buy + collect drinks at Kat (teleports there and back).
    Laundry: auto buy picked detergent pods after each restock; auto pop washer bubbles.
    MRKET: auto pack accepted orders at your apartment station; auto deliver boxes to the buyers.
    Spec: hit-the-thrift-spec.md
]]

if getgenv().THRIFT_ESP then pcall(getgenv().THRIFT_ESP.unload) end

local RS        = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local lp        = game:GetService("Players").LocalPlayer

local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Divine" }
local RANK = {}
for i, r in ipairs(RARITIES) do RANK[r] = i end

local Global = RS:WaitForChild("MyServices"):WaitForChild("Services"):WaitForChild("Global")
-- Only table reads from game modules. Calling a game module's function drops this thread's capabilities until it
-- yields: gethui() then errors and CoreGui instances throw "lacking capability Plugin" (measured on Potassium).
local okCM, CM = pcall(require, Global:WaitForChild("ClothingModule"))
assert(okCM and type(CM) == "table" and type(CM.Items) == "table", "ThriftESP: can't read ClothingModule: " .. tostring(CM))

local function rackPrice(p) -- MorieliPricing.DisplayPrice inlined: Morieli members pay 80%
    p = tonumber(p) or 0
    return lp:GetAttribute("MorieliMember") == true and math.floor(p * 0.8) or p
end

-- ItemKey is "Key" or "Key_Color=Blue". The rack UI also resolves numeric IDs, so fall back to those.
local function parseKey(key)
    local base, col = string.match(key, "^(.-)_Color=(.+)$")
    base = base or key
    local it, id = CM.Items[base], tonumber(base)
    if not it and id then
        for _, v in pairs(CM.Items) do
            if v.ID == id then it = v; break end
        end
    end
    return it, base, col
end
do
    local _, b, c = parseKey("MDOSJeans_Color=Blue")
    local _, b2, c2 = parseKey("SovereinChain")
    assert(b == "MDOSJeans" and c == "Blue" and b2 == "SovereinChain" and c2 == nil, "parseKey self-check")
end

local function displayName(it, base, col) -- same order as ClothingModule.GetDisplayName: brand, color, name
    local parts = {}
    if it.Brand and it.Brand ~= "" then parts[#parts + 1] = it.Brand end
    if col and type(it.Color) == "table" and it.Color[col] then parts[#parts + 1] = col end
    parts[#parts + 1] = it.Name or base
    return table.concat(parts, " ")
end

local function money(n)
    for _, s in ipairs({ { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= s[1] then return (("$%.1f"):format(n / s[1]):gsub("%.0$", "")) .. s[2] end
    end
    return "$" .. math.floor(n)
end
assert(money(3500000) == "$3.5M" and money(12000) == "$12K" and money(55) == "$55", "money self-check")

local CFG = {
    show = { Common = false, Uncommon = false, Rare = true, Epic = true, Legendary = true, Mythical = true, Divine = true },
    color = {},
    dots = true, labels = false, summary = true, outline = true,
    outlineMin = "Epic", listMin = "Legendary",
    maxDist = 600, dotSize = 10, textSize = 13,
    -- every automation starts off; SaveManager autoload turns on what the player saved
    matchaAuto = false, matchaDrink = "Ceremonial Matcha", matchaKeep = 15, matchaReturn = true,
    podAuto = false, podMax = 15, bubbles = false,
    pods = { ["Amethyst Pod"] = true, ["Phoenix Pod"] = true, ["Supreme Pod"] = true, ["Onyx Pod"] = true, ["Gold Pod"] = true },
    mkPack = false, mkDeliver = false, mkReturn = true,
    reserve = 1, -- $M never spent by matcha / pods
}
for _, r in ipairs(RARITIES) do -- default colors = the game's rarity colors
    local def = type(CM.Rarities) == "table" and CM.Rarities[r]
    CFG.color[r] = def and def.Color or Color3.new(1, 1, 1)
end

-- ============================== drawing ==============================
local hui = gethui and gethui() or game:GetService("CoreGui")
local root = Instance.new("Folder") -- highlights; billboards go straight into hui, like warfare_hud's ESP
root.Name = "ThriftESP"
root.Parent = hui

local containers = {} -- [Main part] = { rack = Model, anchor = BasePart, slots = { [slot] = marker }, sum, hl }
local finds, totals = {}, { racks = 0, items = 0, shown = 0 }
local dirty = true -- a setting changed: restyle every marker on the next sync
local conns, running = {}, true

local errs = {} -- feature -> last error; also appended to ThriftESP/errors.txt once per distinct message
local function guard(name, f, ...)
    local ok, err = pcall(f, ...)
    if not ok and errs[name] ~= err then
        errs[name] = err
        local msg, path = os.date("%H:%M:%S ") .. name .. ": " .. tostring(err) .. "\n", "ThriftESP/errors.txt"
        pcall(function()
            if not isfolder("ThriftESP") then makefolder("ThriftESP") end
            if isfile(path) then appendfile(path, msg) else writefile(path, msg) end
        end)
    end
end

local function styleMarker(m)
    if not m.b then return end
    local dot, w, col = CFG.dotSize, CFG.labels and 240 or 0, CFG.color[m.rarity]
    m.b.Enabled = CFG.dots and CFG.show[m.rarity] == true
    m.b.MaxDistance = CFG.maxDist
    m.b.Size = UDim2.fromOffset(dot + w, math.max(dot, CFG.textSize + 4))
    m.b.SizeOffset = Vector2.new(0.5 - dot / (2 * (dot + w)), 0) -- keep the dot, not the label, on the item
    m.dot.Size, m.dot.BackgroundColor3 = UDim2.fromOffset(dot, dot), col
    m.txt.Visible, m.txt.TextSize, m.txt.TextColor3 = CFG.labels, CFG.textSize, col
    m.txt.Position, m.txt.Size = UDim2.new(0, dot + 4, 0.5, 0), UDim2.new(1, -(dot + 4), 1, 0)
end

local function newMarker(slot, key)
    local it, base, col = parseKey(key)
    local m = { key = key }
    if not it or not RANK[it.Rarity] then return m end -- unknown item: kept so it isn't re-parsed every tick
    m.rarity, m.name, m.price = it.Rarity, displayName(it, base, col), rackPrice(it.Price)
    local part = slot:IsA("BasePart") and slot or slot:FindFirstChild("Main") or slot.PrimaryPart
        or slot:FindFirstChildWhichIsA("BasePart", true)
    if not part then return m end
    local b = Instance.new("BillboardGui")
    b.AlwaysOnTop, b.LightInfluence, b.ResetOnSpawn, b.Adornee = true, 0, false, part
    local dot = Instance.new("Frame")
    dot.AnchorPoint, dot.Position, dot.BorderSizePixel = Vector2.new(0, 0.5), UDim2.fromScale(0, 0.5), 0
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
    local stroke = Instance.new("UIStroke", dot)
    stroke.Thickness, stroke.Transparency = 1, 0.3
    dot.Parent = b
    local txt = Instance.new("TextLabel")
    txt.AnchorPoint, txt.BackgroundTransparency, txt.TextXAlignment = Vector2.new(0, 0.5), 1, Enum.TextXAlignment.Left
    txt.Font, txt.TextStrokeTransparency = Enum.Font.GothamMedium, 0.35
    txt.Text = m.name .. "  " .. money(m.price)
    txt.Parent = b
    b.Parent = hui
    m.b, m.dot, m.txt = b, dot, txt
    styleMarker(m)
    return m
end

local function newSummary(c)
    local b = Instance.new("BillboardGui")
    b.AlwaysOnTop, b.LightInfluence, b.ResetOnSpawn, b.Adornee = true, 0, false, c.anchor
    b.StudsOffsetWorldSpace = Vector3.new(0, c.anchor.Size.Y / 2 + 1.5, 0)
    local t = Instance.new("TextLabel")
    t.Name, t.Size, t.BackgroundTransparency, t.RichText = "T", UDim2.fromScale(1, 1), 1, true
    t.Font, t.TextColor3, t.TextStrokeTransparency = Enum.Font.GothamBold, Color3.new(1, 1, 1), 0.3
    t.Parent = b
    b.Parent = hui
    return b
end

local function place(c)
    local loc = c.rack and c.rack:GetAttribute("Location")
    return (c.rack and c.rack.Name or "?") .. (loc and ("  " .. (tostring(loc):gsub("^Floor", "Floor "))) or "")
end

local function drop(main)
    local c = containers[main]
    containers[main] = nil
    for _, m in pairs(c.slots) do if m.b then m.b:Destroy() end end
    if c.sum then c.sum:Destroy() end
    if c.hl then c.hl:Destroy() end
end

local function register(d)
    if containers[d] or d:GetAttribute("Main") ~= true or not d:IsA("BasePart") then return end
    local parent = d.Parent
    containers[d] = { rack = d:FindFirstAncestorWhichIsA("Model"), slots = {},
        anchor = parent and parent:IsA("BasePart") and parent or d }
end

local function sync()
    local cam = Workspace.CurrentCamera
    local camPos = cam and cam.CFrame.Position or Vector3.zero
    local restyle = dirty
    dirty = false
    table.clear(finds)
    totals.racks, totals.items, totals.shown = 0, 0, 0
    local listRank, outlineRank = RANK[CFG.listMin] or 5, RANK[CFG.outlineMin] or 4
    for main, c in pairs(containers) do
        if not main:IsDescendantOf(Workspace) then drop(main); continue end -- streamed out or destroyed
        local present = {}
        for _, slot in ipairs(main:GetChildren()) do
            local key = slot:GetAttribute("ItemKey")
            if key then
                present[slot] = true
                local m = c.slots[slot]
                if m and m.key ~= key then
                    if m.b then m.b:Destroy() end
                    m = nil
                end
                if not m then c.slots[slot] = newMarker(slot, key) elseif restyle then styleMarker(m) end
            end
        end
        local counts, best, n, shown = {}, 0, 0, 0
        for slot, m in pairs(c.slots) do
            if not present[slot] then -- bought (local delete) or restocked away
                if m.b then m.b:Destroy() end
                c.slots[slot] = nil
            elseif m.rarity then
                n += 1
                local rk = RANK[m.rarity]
                if CFG.show[m.rarity] then
                    counts[m.rarity] = (counts[m.rarity] or 0) + 1
                    shown += 1
                    best = math.max(best, rk)
                end
                if rk >= listRank then finds[#finds + 1] = { rk = rk, m = m, where = place(c) } end
            end
        end
        if n > 0 then totals.racks += 1 end
        totals.items += n
        totals.shown += shown

        if CFG.summary and shown > 0 then
            c.sum = c.sum or newSummary(c)
            local parts = {}
            for i = #RARITIES, 1, -1 do
                local r = RARITIES[i]
                if counts[r] then
                    parts[#parts + 1] = ('<font color="#%s">%d %s</font>'):format(CFG.color[r]:ToHex(), counts[r], r)
                end
            end
            local text = "<b>" .. place(c) .. "</b>\n" .. table.concat(parts, "  ")
            if c.sum.T.Text ~= text then c.sum.T.Text = text end
            c.sum.Size = UDim2.fromOffset(360, (CFG.textSize + 4) * 2)
            c.sum.T.TextSize, c.sum.MaxDistance, c.sum.Enabled = CFG.textSize, CFG.maxDist, true
        elseif c.sum then
            c.sum.Enabled = false
        end

        -- ponytail: Roblox renders at most 31 Highlights; ~21 racks plus the game's own few fits. Nearest-first cap if it overflows
        local near = (c.anchor.Position - camPos).Magnitude <= CFG.maxDist
        if CFG.outline and c.rack and near and best >= outlineRank then
            if not c.hl then
                c.hl = Instance.new("Highlight")
                c.hl.DepthMode, c.hl.FillTransparency, c.hl.OutlineTransparency = Enum.HighlightDepthMode.AlwaysOnTop, 0.85, 0
                c.hl.Adornee, c.hl.Parent = c.rack, root
            end
            local col = CFG.color[RARITIES[best]]
            c.hl.OutlineColor, c.hl.FillColor, c.hl.Enabled = col, col, true
        elseif c.hl then
            c.hl.Enabled = false
        end
    end
    table.sort(finds, function(a, b)
        if a.rk ~= b.rk then return a.rk > b.rk end
        return a.m.price > b.m.price
    end)
end

local function findsText()
    if #finds == 0 then return "Nothing at or above " .. CFG.listMin .. " on the racks right now." end
    local lines = {}
    for i = 1, math.min(#finds, 30) do
        local f = finds[i]
        lines[i] = ("%s · %s · %s · %s"):format(f.m.rarity, f.m.name, money(f.m.price), f.where)
    end
    if #finds > 30 then lines[#lines + 1] = ("+%d more"):format(#finds - 30) end
    return table.concat(lines, "\n")
end

for _, d in ipairs(Workspace:GetDescendants()) do register(d) end
table.insert(conns, Workspace.DescendantAdded:Connect(register)) -- racks streaming back in

-- ============================== shared (automation) ==============================
local Events = RS:WaitForChild("Events")
local function bucks()
    local st = lp:FindFirstChild("Stats")
    local v = st and st:FindFirstChild("Thrift Bucks")
    return v and v.Value or 0
end
local function canSpend(price) return bucks() - price >= CFG.reserve * 1e6 end
local function countTools(pred)
    local n = 0
    for _, holder in ipairs({ lp:FindFirstChild("Backpack"), lp.Character }) do
        for _, t in ipairs(holder and holder:GetChildren() or {}) do
            if t:IsA("Tool") and pred(t) then n += 1 end
        end
    end
    return n
end
local function mmss(s) s = math.max(0, math.floor(s)); return ("%d:%02d"):format(s // 60, s % 60) end
local notify = function() end -- becomes Library:Notify once the UI has loaded

-- ============================== matcha ==============================
-- Measured 2026-09-27: MatchaOrderEvent:FireServer(key, os.time()) is ignored from 90 studs but works 6 studs in
-- front of Kat. The server answers StartMaking; the game's own Kat animation (~8 s) sends AnimationComplete; then
-- OrderReady(model) and the model's ClickDetector (range 32) collects the drink. 15 matcha drinks max ("Limit").
local OrderEvent = Events:WaitForChild("OrderEvents"):WaitForChild("MatchaOrderEvent")
local AnimEvent = Events:WaitForChild("OrderEvents"):WaitForChild("MatchaAnimationEvent")
local okMI, MI = pcall(require, Global:WaitForChild("MatchaItems"))
local MATCHA_KEYS = { "Culinary Matcha", "Strawberry Matcha", "Ceremonial Matcha" }
local MATCHA_PRICE = { ["Culinary Matcha"] = 500, ["Strawberry Matcha"] = 10000, ["Ceremonial Matcha"] = 250000 }
if okMI and type(MI) == "table" then
    for _, k in ipairs(MATCHA_KEYS) do
        if type(MI[k]) == "table" and tonumber(MI[k].Price) then MATCHA_PRICE[k] = MI[k].Price end
    end
end
local matcha = { busy = false, pausedUntil = 0, status = "off", bought = 0, spot = nil }

local function matchaCount() -- every matcha drink counts toward the server's 15
    return countTools(function(t)
        local k = t:GetAttribute("ItemKey")
        return type(k) == "string" and k:find("Matcha$") ~= nil
    end)
end

local function katSpot() -- 6 studs in front of Kat = the customer side of her counter (measured floor)
    local misc = Workspace:FindFirstChild("Misc")
    local npc = misc and misc:FindFirstChild("MatchaNPC")
    local kat = npc and npc:FindFirstChild("HumanoidRootPart")
    local prompt = npc and npc:FindFirstChild("NPC_ProximityPrompt")
    -- her prompt is off while she walks off to make a drink, so only cache the spot while she's home
    if kat and prompt and prompt.Enabled then
        local lv = kat.CFrame.LookVector
        local spot = kat.Position + Vector3.new(lv.X, 0, lv.Z).Unit * 6
        matcha.spot = CFrame.lookAt(spot, Vector3.new(kat.Position.X, spot.Y, kat.Position.Z))
    end
    return matcha.spot
end

local function matchaRun()
    local key = CFG.matchaDrink
    local price = rackPrice(MATCHA_PRICE[key] or math.huge)
    local target = math.clamp(CFG.matchaKeep, 1, 15)
    if os.clock() < matcha.pausedUntil then return end
    if matchaCount() >= target then matcha.status = "stocked"; return end
    if not canSpend(price) then matcha.status = "waiting for money (reserve)"; return end
    local char = lp.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local spot = katSpot()
    if not (hrp and spot) then matcha.status = "can't find Kat"; return end
    matcha.busy = true
    local saved, moved = hrp.CFrame, false
    char:PivotTo(spot)
    task.wait(0.5)
    while running and CFG.matchaAuto and matchaCount() < target and canSpend(price) do
        if (hrp.Position - spot.Position).Magnitude > 8 then -- you walked off: hand control back
            moved, matcha.pausedUntil, matcha.status = true, os.clock() + 120, "you moved, paused 2 min"
            break
        end
        local ready, limit, queued, makingAt, nudged
        local conn = OrderEvent.OnClientEvent:Connect(function(kind, obj)
            if kind == "OrderReady" then ready = obj
            elseif kind == "Limit" then limit = true
            elseif kind == "StartDrinkSoon" then queued = true end
        end)
        local conn2 = AnimEvent.OnClientEvent:Connect(function(kind)
            if kind == "StartMaking" then makingAt = os.clock() end
        end)
        local n0 = matchaCount()
        matcha.status = "ordering " .. key
        OrderEvent:FireServer(key, os.time())
        local t0 = os.clock()
        while running and not ready and not limit do
            local now = os.clock()
            if makingAt then
                -- Kat's animation sends AnimationComplete after ~8 s. If hers never ran (she was already busy, e.g. with
                -- an order you placed by hand), the server waits forever, so send it the way she would.
                if now - makingAt > 20 and not nudged then nudged = true; OrderEvent:FireServer("AnimationComplete") end
                if now - makingAt > 30 then break end
            elseif now - t0 > (queued and 90 or 20) then
                break
            end
            task.wait(0.2)
        end
        conn:Disconnect()
        conn2:Disconnect()
        if limit then matcha.status = "at the 15-drink limit"; break end
        if not ready then
            matcha.pausedUntil, matcha.status = os.clock() + 60, "no drink came (retry in 1 min)"
            break
        end
        local cd = typeof(ready) == "Instance" and ready:FindFirstChildWhichIsA("ClickDetector", true)
        if cd then fireclickdetector(cd) end
        local t1 = os.clock()
        while matchaCount() <= n0 and os.clock() - t1 < 3 do task.wait(0.1) end
        if matchaCount() > n0 then matcha.bought += 1 end
    end
    if CFG.matchaReturn and not moved and lp.Character == char then char:PivotTo(saved) end
    if matcha.status:find("^ordering") then matcha.status = "done" end
    matcha.busy = false
end

-- ============================== laundry ==============================
-- Measured 2026-09-27: DetergentEvent:FireServer(key, true) buys one pod from anywhere (45 studs from Franklin worked).
-- A buy answers PodEvent("Stock", stock, boughtThisRestock); a pod with no stock is silently ignored and costs
-- nothing. Racks and pods share one 5-minute restock (getRestockTime / RestockTimerEvent). The shop refuses a 16th pod.
local DetergentEvent = Events:WaitForChild("LaundryEvents"):WaitForChild("DetergentEvent")
local PodEvent = Events:WaitForChild("DataEvents"):WaitForChild("PodEvent")
local RestockTimerEvent = Events:WaitForChild("RackEvents"):WaitForChild("RestockTimerEvent")
local getRestockTime = Events:WaitForChild("RackEvents"):WaitForChild("getRestockTime")
local okDM, DM = pcall(require, Global:WaitForChild("DetergentModule"))
local PODS = {} -- { key, name, price }, most expensive first
if okDM and type(DM) == "table" and type(DM.Detergents) == "table" then
    for _, key in ipairs(DM.InShop or {}) do
        local d = DM.Detergents[key]
        if type(d) == "table" and tonumber(d.Price) then PODS[#PODS + 1] = { key = key, name = d.Name, price = d.Price } end
    end
    table.sort(PODS, function(a, b) return a.price > b.price end)
end
local POD_NAMES = {}
for i, p in ipairs(PODS) do POD_NAMES[i] = p.name end
local pod = { stock = nil, bought = {}, fresh = false, pending = true, nextRestock = nil, last = {} }

table.insert(conns, PodEvent.OnClientEvent:Connect(function(kind, stock, bought)
    if kind == "Stock" and type(stock) == "table" then
        pod.stock, pod.bought, pod.fresh = stock, type(bought) == "table" and bought or {}, true
        pod.pending = true -- a buy (yours or mine) may show more stock
    end
end))
-- At a restock the server pushes PodEvent("Stock", newStock, {}) and then RestockTimerEvent(300) in the same frame
-- (measured), so this handler must not throw that fresh stock away.
table.insert(conns, RestockTimerEvent.OnClientEvent:Connect(function(sec)
    pod.nextRestock = os.clock() + (tonumber(sec) or 60)
    pod.pending = true
end))
task.spawn(function()
    local ok, t = pcall(function() return getRestockTime:InvokeServer() end)
    if ok and tonumber(t) then pod.nextRestock = os.clock() + t end
end)

local function podCount(name) return countTools(function(t) return t.Name == name end) end

local function podRun()
    pod.pending = false
    for _, p in ipairs(PODS) do
        if CFG.pods[p.name] then
            for _ = 1, 15 do
                if not (running and CFG.podAuto) then return end
                local have = podCount(p.name)
                local avail = pod.fresh and pod.stock and (tonumber(pod.stock[p.key]) or 0) - (tonumber(pod.bought[p.key]) or 0) or 1
                if avail <= 0 or have >= CFG.podMax or not canSpend(rackPrice(p.price)) then break end
                DetergentEvent:FireServer(p.key, true)
                local t0 = os.clock()
                while podCount(p.name) <= have and os.clock() - t0 < 1.5 do task.wait(0.1) end
                if podCount(p.name) <= have then break end -- no stock: the server stays silent
                table.insert(pod.last, 1, os.date("%H:%M ") .. p.name)
                pod.last[7] = nil
            end
        end
    end
end

local bubbles = { popped = 0 }
local function hookBubbles() -- the game's own pop handler: BubbleEvent + 1 s off your wash timer
    local main = lp:WaitForChild("PlayerGui"):WaitForChild("MainGUI", 30)
    local frame = main and main:WaitForChild("ScreenFrame"):WaitForChild("BubbleGameFrame", 30)
    if not frame then return end
    table.insert(conns, frame.ChildAdded:Connect(function(b)
        if not (CFG.bubbles and b:IsA("GuiButton")) then return end
        task.delay(0.15, function()
            if running and CFG.bubbles and b.Parent and b.ImageTransparency ~= 1 then
                task.spawn(firesignal, b.Activated) -- own thread: running game code lowers that thread's capabilities
                bubbles.popped += 1
            end
        end)
    end))
end
task.spawn(guard, "bubbles", hookBubbles)

-- ============================== MRKET ==============================
-- Read from code 2026-09-27 (no live order yet): an accepted offer puts an order on your apartment's pack station
-- (Packaging attribute HasOrder). The station's client prompt runs RopopEvent("PackOrder") and gives a box tool
-- (attributes MRKETBox, MRKETListingId). The box's only script sends ToolEvent(box, true) when used; the server
-- then delivers if you're at the listing's MeetingPlace (MRKETDeliveryComplete / MRKETDeliveryWarning).
local RopopEvent = Events:WaitForChild("DataEvents"):WaitForChild("RopopEvent")
local ApartmentEvent = Events:WaitForChild("DataEvents"):WaitForChild("ApartmentEvent")
local ToolEvent = Events:WaitForChild("RackEvents"):WaitForChild("ToolEvent")
local mk = { busy = false, status = "off", listings = {}, maxListings = 3, packed = 0, delivered = 0, earned = 0,
    warn = nil, pausedUntil = 0, listMsg = nil, gotListings = false }

table.insert(conns, RopopEvent.OnClientEvent:Connect(function(kind, a)
    if kind == "Listings" and type(a) == "table" then
        mk.listings = type(a.listings) == "table" and a.listings or {}
        mk.maxListings, mk.gotListings = tonumber(a.maxListings) or mk.maxListings, true
    elseif kind == "MRKETDeliveryComplete" and type(a) == "table" then
        mk.delivered += 1
        mk.earned += tonumber(a.Price) or 0
    elseif kind == "MRKETDeliveryWarning" and type(a) == "string" then
        mk.warn = a
    end
end))

local function myStation()
    local apts = Workspace:FindFirstChild("Apartments")
    local mine = apts and apts:FindFirstChild(lp.Name)
    local st = mine and mine:FindFirstChild("Structure")
    local ropop = st and st:FindFirstChild("Ropop")
    return ropop and ropop:FindFirstChild("Packaging"), st
end
local function boxes()
    local list = {}
    for _, holder in ipairs({ lp:FindFirstChild("Backpack"), lp.Character }) do
        for _, t in ipairs(holder and holder:GetChildren() or {}) do
            if t:IsA("Tool") and t:GetAttribute("MRKETBox") then list[#list + 1] = t end
        end
    end
    return list
end
local function placeFor(listingId)
    for _, l in ipairs(mk.listings) do
        if l.Id == listingId then return l.MeetingPlace end
    end
end

local function waitFor(cond, timeout)
    local t0 = os.clock()
    while not cond() and os.clock() - t0 < timeout do task.wait(0.1) end
    return cond()
end

local function enterApartment(char, part) -- ends next to `part` inside your apartment
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if hrp and (hrp.Position - part.Position).Magnitude < 30 then return end
    -- the game's own way in (Teleport app): the server answers "Entered" and the apartment module moves you inside
    ApartmentEvent:FireServer("Enter")
    if not waitFor(function() return hrp and (hrp.Position - part.Position).Magnitude < 30 end, 4) then
        char:PivotTo(part.CFrame + Vector3.new(0, 3, 0)) -- fallback: straight there
    end
    task.wait(0.5)
end

local function packAll(char, pk)
    enterApartment(char, pk.PlrPos)
    local prompt = pk:FindFirstChild("BoxPos") and pk.BoxPos:FindFirstChildOfClass("ProximityPrompt")
    for _ = 1, 10 do
        if not (running and CFG.mkPack and pk:GetAttribute("HasOrder")) then break end
        if not prompt then mk.status = "pack prompt missing"; break end
        char:PivotTo(pk.PlrPos.CFrame) -- the game's pack handler puts you here too
        task.wait(0.3)
        local n0 = #boxes()
        mk.status = "packing"
        fireproximityprompt(prompt) -- the station's own handler: PackOrder + animation
        if not waitFor(function() return #boxes() > n0 end, 8) then mk.status = "packing gave no box"; break end
        mk.packed += 1
        task.wait(0.5)
    end
end

local function deliver(char, box)
    local id = box:GetAttribute("MRKETListingId")
    local place = placeFor(id)
    if not place then
        RopopEvent:FireServer("GetListings")
        waitFor(function() return placeFor(id) ~= nil end, 3)
        place = placeFor(id)
    end
    local mp = place and Workspace:FindFirstChild("MeetingPlaces") and Workspace.MeetingPlaces:FindFirstChild(place)
    if not (mp and mp:FindFirstChild("Final") and mp:FindFirstChild("Start")) then
        mk.status = "no meeting place for " .. tostring(box.Name)
        return false
    end
    local final, dir = mp.Final.Position, mp.Start.Position - mp.Final.Position
    dir = Vector3.new(dir.X, 0, dir.Z).Unit
    local pos = final + dir * 4 + Vector3.new(0, 3, 0) -- in front of where the buyer stands
    char:PivotTo(CFrame.lookAt(pos, Vector3.new(final.X, pos.Y, final.Z)))
    task.wait(0.5)
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum and box.Parent ~= char then hum:EquipTool(box); task.wait(0.3) end
    local d0 = mk.delivered
    mk.warn, mk.status = nil, "delivering to " .. place
    ToolEvent:FireServer(box, true) -- what using the box sends
    local ok = waitFor(function() return mk.delivered > d0 or mk.warn ~= nil or not box.Parent end, 6)
    if mk.warn then mk.status = "server: " .. mk.warn end
    return ok and mk.warn == nil
end

local function mrketRun()
    if os.clock() < mk.pausedUntil then return end
    local char = lp.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local pk = myStation()
    local needPack = CFG.mkPack and pk and pk:GetAttribute("HasOrder")
    local needDeliver = CFG.mkDeliver and #boxes() > 0
    if not (needPack or needDeliver) then mk.status = "waiting for orders"; return end
    mk.busy = true
    local saved = hrp.CFrame
    local startedInside = pk and (hrp.Position - pk.PlrPos.Position).Magnitude < 60
    local inside = startedInside
    local function leave() -- tell the server, like touching the apartment's exit does
        if inside then ApartmentEvent:FireServer("LeftApartment", lp.Name); inside = false end
    end
    if needPack then packAll(char, pk); inside = true end
    if CFG.mkDeliver and #boxes() > 0 then
        leave()
        RopopEvent:FireServer("GetListings")
        task.wait(1)
        for _, box in ipairs(boxes()) do
            if not (running and CFG.mkDeliver) then break end
            if not deliver(char, box) then mk.pausedUntil = os.clock() + 60; break end
        end
    end
    if CFG.mkReturn and lp.Character == char then -- otherwise you stay where the run ended
        if startedInside then
            if inside then char:PivotTo(saved) else ApartmentEvent:FireServer("Enter") end -- back in the game's way
        else
            leave()
            char:PivotTo(saved)
        end
    end
    if mk.status == "packing" or mk.status:find("^delivering") then mk.status = "done" end
    mk.busy = false
end

-- The dashboard's LIST button sends RopopEvent("ListItem", ItemInstanceId); the server answers "ItemListed" or
-- "ListingError" <text>. The dashboard's own filter (MRKETModule.ToolInfo): clothing types below, Clean, not
-- Favorite, not a box, and a rarity with a buyer rate (Rare and up).
local LISTABLE_TYPES = { Shirt = true, InnerLayerTop = true, OuterLayerTop = true, Pants = true, Shoes = true, Accessory = true }
local LISTABLE_RARITY = { Rare = true, Epic = true, Legendary = true, Mythical = true, Divine = true }
local function heldListable()
    local tool = lp.Character and lp.Character:FindFirstChildOfClass("Tool")
    if not tool then return nil, "hold the item you want to list" end
    local key = tool:GetAttribute("ItemKey")
    if type(key) ~= "string" or tool:GetAttribute("MRKETBox") then return nil, tool.Name .. " isn't clothing" end
    local it, base = parseKey(key)
    if not it then return nil, "unknown item " .. key end
    if not LISTABLE_TYPES[it.Type] then return nil, "MRKET doesn't take " .. tostring(it.Type) end
    local cond = tool:GetAttribute("Condition")
    if cond and cond ~= "Clean" then return nil, "wash it first (" .. tostring(cond) .. ")" end
    if tool:GetAttribute("Favorite") then return nil, "unfavorite it first" end
    if not LISTABLE_RARITY[it.Rarity] then return nil, tostring(it.Rarity) .. " items can't be listed (Rare and up)" end
    local id = tool:GetAttribute("ItemInstanceId")
    if not id then return nil, "the item has no instance id" end
    return tool, displayName(it, base, tool:GetAttribute("Color")), id
end

local listing = false
local function listResult(msg) -- status line + a toast, since the hotkey is used with the menu closed
    mk.listMsg = msg
    notify("MRKET: " .. msg)
end
local function listHeld()
    if listing or mk.busy then listResult("busy, try again in a moment"); return end
    local tool, name, id = heldListable()
    if not tool then listResult(name); return end
    listing = true
    mk.gotListings = false
    RopopEvent:FireServer("GetListings")
    waitFor(function() return mk.gotListings end, 2)
    if mk.gotListings and #mk.listings >= mk.maxListings then
        listing = false
        listResult(("all %d listing slots are full"):format(mk.maxListings))
        return
    end
    local reply
    local conn = RopopEvent.OnClientEvent:Connect(function(kind, a)
        if kind == "ItemListed" then reply = true
        elseif kind == "ListingError" then reply = tostring(a or "That item cannot be listed.") end
    end)
    mk.listMsg = "listing " .. name .. "..."
    RopopEvent:FireServer("ListItem", id)
    waitFor(function() return reply ~= nil end, 3)
    if reply == nil then
        -- no answer: maybe it has to be done at your laptop, like the dashboard. Try once from there, then come back.
        local _, st = myStation()
        local laptop = st and st:FindFirstChild("Ropop") and st.Ropop:FindFirstChild("Prox")
        local char = lp.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if laptop and hrp then
            local saved = hrp.CFrame
            local wasInside = (hrp.Position - laptop.Position).Magnitude < 60
            enterApartment(char, laptop)
            RopopEvent:FireServer("ListItem", id)
            waitFor(function() return reply ~= nil end, 3)
            if not wasInside then ApartmentEvent:FireServer("LeftApartment", lp.Name) end
            char:PivotTo(saved)
        end
    end
    conn:Disconnect()
    listing = false
    listResult(reply == true and ("listed " .. name) or ("not listed: " .. (reply or "no answer from the server")))
end

task.spawn(function() -- MRKET: pack new orders, deliver held boxes
    while running do
        if (CFG.mkPack or CFG.mkDeliver) and not mk.busy and not listing then
            guard("mrket", mrketRun)
            mk.busy = false
        end
        task.wait(3)
    end
end)

task.spawn(function() -- pods: after each restock, whenever new stock shows up, and when switched on
    while running do
        if CFG.podAuto then
            if pod.nextRestock and os.clock() >= pod.nextRestock + 3 then -- missed RestockTimerEvent: ask again
                pod.fresh, pod.pending = false, true
                local ok, t = pcall(function() return getRestockTime:InvokeServer() end)
                pod.nextRestock = os.clock() + (ok and tonumber(t) or 60)
            end
            if pod.pending then guard("pods", podRun) end
        end
        task.wait(1)
    end
end)
task.spawn(function() -- matcha: top up whenever you're below the target
    while running do
        if CFG.matchaAuto and not matcha.busy then
            guard("matcha", matchaRun)
            matcha.busy = false -- also after an error mid-run
        end
        task.wait(2)
    end
end)

local Library, statusLabel, findsLabel, matchaLabel, podLabel, bubbleLabel, mrketLabel
local function unload()
    if getgenv().THRIFT_ESP == nil then return end
    getgenv().THRIFT_ESP = nil
    running = false
    for _, c in ipairs(conns) do c:Disconnect() end
    for main in pairs(containers) do drop(main) end
    root:Destroy()
    if Library then pcall(Library.Unload, Library) end
end
getgenv().THRIFT_ESP = { unload = unload, cfg = CFG, containers = containers, finds = finds, totals = totals, errs = errs,
    matcha = matcha, pod = pod, bubbles = bubbles, mk = mk, heldListable = heldListable }

task.spawn(function()
    local lastFinds
    while running do
        guard("sync", sync)
        guard("labels", function()
            if statusLabel then
                statusLabel:SetText(("%d racks · %d items · %d shown"):format(totals.racks, totals.items, totals.shown))
            end
            local text = findsText()
            if findsLabel and text ~= lastFinds then lastFinds = text; findsLabel:SetText(text) end
            if matchaLabel then
                matchaLabel:SetText(("%s\nDrinks: %d / %d · bought this session: %d"):format(
                    CFG.matchaAuto and matcha.status or "off", matchaCount(), CFG.matchaKeep, matcha.bought))
            end
            if podLabel then
                local stock = {}
                if pod.fresh and pod.stock then
                    for _, p in ipairs(PODS) do
                        local n = (tonumber(pod.stock[p.key]) or 0) - (tonumber(pod.bought[p.key]) or 0)
                        if n > 0 then stock[#stock + 1] = p.name:gsub(" Pod$", "") .. " " .. n end
                    end
                end
                podLabel:SetText(("Restock in %s\nLeft for you: %s\n%s"):format(
                    pod.nextRestock and mmss(pod.nextRestock - os.clock()) or "?",
                    not pod.fresh and "unknown until a buy this restock" or (#stock > 0 and table.concat(stock, " · ") or "nothing"),
                    #pod.last > 0 and ("Bought: " .. table.concat(pod.last, ", ")) or ""))
            end
            if bubbleLabel then bubbleLabel:SetText(("Popped this session: %d"):format(bubbles.popped)) end
            if mrketLabel then
                local counts = {}
                for _, l in ipairs(mk.listings) do
                    local s = l.DeliveryStatus or (l.HasOffer and "offer") or "listed"
                    counts[s] = (counts[s] or 0) + 1
                end
                local parts = {}
                for s, n in pairs(counts) do parts[#parts + 1] = n .. " " .. s end
                local pk = myStation()
                mrketLabel:SetText(("%s\nListings: %s · station order: %s · boxes: %d\nPacked %d · delivered %d (%s)%s"):format(
                    (CFG.mkPack or CFG.mkDeliver) and mk.status or "off",
                    #parts > 0 and table.concat(parts, ", ") or "none", pk and (pk:GetAttribute("HasOrder") and "yes" or "no") or "no apartment",
                    #boxes(), mk.packed, mk.delivered, money(mk.earned), mk.warn and ("\nLast warning: " .. mk.warn) or "")
                    .. (mk.listMsg and ("\nList: " .. mk.listMsg) or ""))
            end
        end)
        task.wait(0.5)
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
    end)(), Footer = "Hit The Thrift · rack ESP · matcha · laundry · MRKET",
    Size = UDim2.fromOffset(704, 824), -- default window size (user pick)
    Center = true, AutoShow = true, ToggleKeybind = Enum.KeyCode.RightControl,
})
local Tabs = {
    ESP      = Window:AddTab("ESP", "eye"),
    Finds    = Window:AddTab("Finds", "search"),
    Matcha   = Window:AddTab("Matcha", "coffee"),
    Laundry  = Window:AddTab("Laundry", "washing-machine"),
    MRKET    = Window:AddTab("MRKET", "store"),
    Settings = Window:AddTab("Settings", "settings"),
}
local function set(key) return function(v) CFG[key] = v; dirty = true end end

local Rar = Tabs.ESP:AddLeftGroupbox("Rarities", "gem")
Rar:AddLabel("Each toggle shows or hides that rarity everywhere (dots, summaries, outlines). Click the swatch to recolor.", true)
for i = #RARITIES, 1, -1 do
    local r = RARITIES[i]
    Rar:AddToggle("TE_Show_" .. r, { Text = r, Default = CFG.show[r],
        Callback = function(v) CFG.show[r] = v; dirty = true end })
        :AddColorPicker("TE_Col_" .. r, { Default = CFG.color[r], Title = r,
            Callback = function(c) CFG.color[r] = c; dirty = true end })
end

local Disp = Tabs.ESP:AddRightGroupbox("Display", "monitor")
Disp:AddToggle("TE_Dots", { Text = "Dot on each item", Default = CFG.dots, Callback = set("dots") })
Disp:AddToggle("TE_Labels", { Text = "Item name + price", Tooltip = "Rack price, as the rack menu shows it",
    Default = CFG.labels, Callback = set("labels") })
Disp:AddToggle("TE_Summary", { Text = "Rack summary", Tooltip = "Rarity counts and floor over each rack",
    Default = CFG.summary, Callback = set("summary") })
Disp:AddToggle("TE_Outline", { Text = "Outline racks", Tooltip = "The rack glows in its best shown rarity's color",
    Default = CFG.outline, Callback = set("outline") })
Disp:AddDropdown("TE_OutlineMin", { Text = "Outline from", Values = RARITIES, Default = CFG.outlineMin,
    Callback = set("outlineMin") })
Disp:AddSlider("TE_MaxDist", { Text = "Max distance", Default = CFG.maxDist, Min = 50, Max = 2000, Rounding = 0,
    Suffix = " studs", Callback = set("maxDist") })
Disp:AddSlider("TE_DotSize", { Text = "Dot size", Default = CFG.dotSize, Min = 4, Max = 24, Rounding = 0,
    Suffix = "px", Callback = set("dotSize") })
Disp:AddSlider("TE_TextSize", { Text = "Text size", Default = CFG.textSize, Min = 9, Max = 22, Rounding = 0,
    Suffix = "px", Callback = set("textSize") })

local FindBox = Tabs.Finds:AddLeftGroupbox("Finds", "search")
FindBox:AddDropdown("TE_ListMin", { Text = "List from", Values = RARITIES, Default = CFG.listMin, Callback = set("listMin") })
statusLabel = FindBox:AddLabel("-", true)
findsLabel = FindBox:AddLabel("-", true)

local MatchaBox = Tabs.Matcha:AddLeftGroupbox("Auto buy + collect", "shopping-cart")
MatchaBox:AddLabel("Teleports you in front of Kat, orders, clicks your drink on the counter (about 10 s each) and takes you back. Walking away cancels the run for 2 min. The game caps you at 15 matcha drinks.", true)
MatchaBox:AddToggle("MA_Auto", { Text = "Auto buy matcha", Default = CFG.matchaAuto,
    Callback = function(v) CFG.matchaAuto = v; matcha.pausedUntil = 0 end })
MatchaBox:AddDropdown("MA_Drink", { Text = "Drink", Values = MATCHA_KEYS, Default = CFG.matchaDrink,
    Tooltip = ("Culinary %s x1.3 · Strawberry %s x2 · Ceremonial %s x3 aura"):format(money(MATCHA_PRICE["Culinary Matcha"]),
        money(MATCHA_PRICE["Strawberry Matcha"]), money(MATCHA_PRICE["Ceremonial Matcha"])),
    Callback = function(v) CFG.matchaDrink = v end })
MatchaBox:AddSlider("MA_Keep", { Text = "Keep this many drinks", Default = CFG.matchaKeep, Min = 1, Max = 15, Rounding = 0,
    Tooltip = "Buys until you hold this many matcha drinks (all kinds count)", Callback = function(v) CFG.matchaKeep = v end })
MatchaBox:AddToggle("MA_Return", { Text = "Go back after buying", Default = CFG.matchaReturn,
    Callback = function(v) CFG.matchaReturn = v end })
matchaLabel = MatchaBox:AddLabel("-", true)

local PodBox = Tabs.Laundry:AddLeftGroupbox("Detergent pods", "droplets")
PodBox:AddLabel("Buys the picked pods right after each restock (same timer as the racks), from anywhere. Trying a pod with no stock costs nothing.", true)
PodBox:AddToggle("LA_PodAuto", { Text = "Auto buy pods on restock", Default = CFG.podAuto,
    Callback = function(v) CFG.podAuto = v; pod.pending = true end })
local podDefaults = {}
for name, on in pairs(CFG.pods) do if on then podDefaults[#podDefaults + 1] = name end end
PodBox:AddDropdown("LA_Pods", { Text = "Pods to buy", Values = POD_NAMES, Multi = true, Default = podDefaults,
    Tooltip = "Most expensive first", Callback = function(v) CFG.pods = v; pod.pending = true end })
PodBox:AddSlider("LA_PodMax", { Text = "Max of each pod", Default = CFG.podMax, Min = 1, Max = 15, Rounding = 0,
    Callback = function(v) CFG.podMax = v; pod.pending = true end })
podLabel = PodBox:AddLabel("-", true)

local BubbleBox = Tabs.Laundry:AddRightGroupbox("Bubbles", "sparkles")
BubbleBox:AddLabel("Pops every bubble while you wash; each pop takes 1 s off the wash timer. Bubbles only spawn while you stay within 20 studs of your machine.", true)
BubbleBox:AddToggle("LA_Bubbles", { Text = "Auto pop bubbles", Default = CFG.bubbles, Callback = function(v) CFG.bubbles = v end })
bubbleLabel = BubbleBox:AddLabel("-", true)

local MkBox = Tabs.MRKET:AddLeftGroupbox("Orders", "clipboard-list")
MkBox:AddLabel("You still list items and accept offers on your phone. Auto pack goes to your apartment's pack station and packs every accepted order. Auto deliver takes each box to its buyer's meeting spot and hands it over. Then it takes you back.", true)
MkBox:AddToggle("MK_Pack", { Text = "Auto pack orders", Default = CFG.mkPack,
    Callback = function(v) CFG.mkPack = v; mk.pausedUntil = 0 end })
MkBox:AddToggle("MK_Deliver", { Text = "Auto deliver (fulfill)", Default = CFG.mkDeliver,
    Callback = function(v) CFG.mkDeliver = v; mk.pausedUntil = 0 end })
MkBox:AddToggle("MK_Return", { Text = "Go back after", Default = CFG.mkReturn, Callback = function(v) CFG.mkReturn = v end })
MkBox:AddButton({ Text = "List held item", Tooltip = "Lists the item in your hand on MRKET (clean, not favorited, Rare and up)",
    Func = function() task.spawn(guard, "list", listHeld) end })
    -- hotkey: pressing it runs the button (Obsidian Press mode); ignored while you type in chat; saved with the config
    :AddKeyPicker("MK_ListKey", { Default = "None", Mode = "Press", Text = "List held item" })
mrketLabel = MkBox:AddLabel("-", true)

local Spend = Tabs.Settings:AddRightGroupbox("Spending", "wallet")
Spend:AddSlider("SP_Reserve", { Text = "Always keep", Default = CFG.reserve, Min = 0, Max = 100, Rounding = 1, Suffix = "M",
    Tooltip = "Matcha and pod buying never take your Thrift Bucks below this", Callback = function(v) CFG.reserve = v end })

local Menu = Tabs.Settings:AddLeftGroupbox("Menu", "menu")
Menu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })
Library:OnUnload(unload)
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetFolder("ThriftESP")
ThemeManager:SetFolder("ThriftESP")
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:SetDefaultTheme({ BackgroundColor = "0c0a0b", MainColor = "161214", AccentColor = "e0233c", OutlineColor = "2a1d20", FontColor = "f2eded" }) -- CruelHub look
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:LoadAutoloadConfig()
notify = function(msg) Library:Notify(msg, 3) end
Library:Notify("Hit The Thrift ready — RightCtrl toggles the UI.", 4)
