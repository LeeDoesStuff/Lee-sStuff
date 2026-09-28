--[[
    Hit The Thrift rack ESP v1  (place 122454884469606)
    UI: Obsidian (deividcomsono)
    Every item on the thrift racks, shoe/glasses shelves and jewelry displays, by rarity:
      - a dot on each item (optional name + rack price), colored by rarity
      - a summary over each rack: rarity counts + floor
      - a rack outline in the color of its best shown rarity
      - Finds tab: every item at or above a rarity, with its rack + floor
    Data: the children of any part with attribute Main=true carry ItemKey ("Key" or "Key_Color=Blue"); rarity comes
    from ClothingModule.Items. A restock swaps the slot models; buying one deletes it locally, so its dot goes too.
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

local Library, statusLabel, findsLabel
local function unload()
    if getgenv().THRIFT_ESP == nil then return end
    getgenv().THRIFT_ESP = nil
    running = false
    for _, c in ipairs(conns) do c:Disconnect() end
    for main in pairs(containers) do drop(main) end
    root:Destroy()
    if Library then pcall(Library.Unload, Library) end
end
getgenv().THRIFT_ESP = { unload = unload, cfg = CFG, containers = containers, finds = finds, totals = totals, errs = errs }

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
    Title = "Hit The Thrift ESP", Footer = "racks · shelves · jewelry by rarity",
    Center = true, AutoShow = true, ToggleKeybind = Enum.KeyCode.RightControl,
})
local Tabs = {
    ESP      = Window:AddTab("ESP"),
    Finds    = Window:AddTab("Finds"),
    Settings = Window:AddTab("Settings"),
}
local function set(key) return function(v) CFG[key] = v; dirty = true end end

local Rar = Tabs.ESP:AddLeftGroupbox("Rarities")
Rar:AddLabel("Each toggle shows or hides that rarity everywhere (dots, summaries, outlines). Click the swatch to recolor.", true)
for i = #RARITIES, 1, -1 do
    local r = RARITIES[i]
    Rar:AddToggle("TE_Show_" .. r, { Text = r, Default = CFG.show[r],
        Callback = function(v) CFG.show[r] = v; dirty = true end })
        :AddColorPicker("TE_Col_" .. r, { Default = CFG.color[r], Title = r,
            Callback = function(c) CFG.color[r] = c; dirty = true end })
end

local Disp = Tabs.ESP:AddRightGroupbox("Display")
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

local FindBox = Tabs.Finds:AddLeftGroupbox("Finds")
FindBox:AddDropdown("TE_ListMin", { Text = "List from", Values = RARITIES, Default = CFG.listMin, Callback = set("listMin") })
statusLabel = FindBox:AddLabel("-", true)
findsLabel = FindBox:AddLabel("-", true)

local Menu = Tabs.Settings:AddLeftGroupbox("Menu")
Menu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })
Library:OnUnload(unload)
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetFolder("ThriftESP")
ThemeManager:SetFolder("ThriftESP")
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:LoadAutoloadConfig()
Library:Notify("Thrift ESP ready — RightCtrl toggles the UI.", 4)
