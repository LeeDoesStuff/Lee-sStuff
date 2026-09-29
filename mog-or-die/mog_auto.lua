-- MogAuto v2 — Mog or Die panel (Obsidian)
-- Efficient: one-time getgc scan (cached), event-driven prompts/status, no hot polling.
if getgenv().MogAuto_Stop then getgenv().MogAuto_Stop() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local plr = Players.LocalPlayer

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua"))()
local ThemeManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/SaveManager.lua"))()

local state = {
  running = true,
  magnet = true, radius = 500,
  tp = false, tpCooldown = 0.08, tpBatch = 20,
  pad = true,
  crate = true,
  antiafk = true,
}
local conns = {}

getgenv().MogAuto = state
getgenv().MogAuto_Stop = function()
  state.running = false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  table.clear(conns)
  pcall(function() Library:Unload() end)
  print("[MogAuto] stopped")
end

-- ========= Magnet: patch the per-type radius table (u7: CollectibleType -> halfSize+CollectRadius) =========
-- Computed once at CollectibleVisualClient startup, so setting Config.CollectRadius alone does nothing.
local radiusTbl, radiusOrig
local function scanMagnet()
  local Config = require(RS.MogOrDie.Config)
  local names = {}
  for k in pairs(Config.Collectibles) do names[k] = true end
  local seen = {}
  for _, g in pairs(getgc(true)) do
    if type(g) == "function" then
      local ok, src = pcall(debug.info, g, "s")
      if ok and src and tostring(src):find("CollectibleVisual") then
        for _, v in pairs(getupvalues(g)) do
          if type(v) == "table" and not seen[v] then
            seen[v] = true
            local hit = 0
            for k, val in pairs(v) do
              if type(k) == "string" and names[k] and type(val) == "number" then hit = hit + 1 end
            end
            if hit >= 2 then
              radiusTbl = v
              radiusOrig = {}
              for k, val in pairs(v) do radiusOrig[k] = val end
              return hit
            end
          end
        end
      end
    end
  end
  return 0
end

local function applyMagnet(R)
  if not radiusTbl then return end
  for k in pairs(radiusTbl) do radiusTbl[k] = R end
  pcall(function() require(RS.MogOrDie.Config).Spawning.CollectRadius = R end)
end

local function setMagnet(on)
  if not radiusTbl then scanMagnet() end
  if not radiusTbl then return end
  if on then
    applyMagnet(state.radius)
  elseif radiusOrig then
    for k, val in pairs(radiusOrig) do radiusTbl[k] = val end
    pcall(function() require(RS.MogOrDie.Config).Spawning.CollectRadius = 6 end)
  end
end

-- ========= Pad prompts: cache once + DescendantAdded, no GetDescendants loop =========
local padPrompts = {}
local myPlotCached

local function myPlot()
  if myPlotCached and myPlotCached.Parent then return myPlotCached end
  for _, p in ipairs(workspace.PlayerPlots:GetChildren()) do
    if p:GetAttribute("PlotOwnerUserId") == plr.UserId then
      myPlotCached = p
      return p
    end
  end
end

local function hookPlot()
  local plot = myPlot()
  if not plot then return false end
  table.clear(padPrompts)
  for _, d in ipairs(plot:GetDescendants()) do
    if d:IsA("ProximityPrompt") then table.insert(padPrompts, d) end
  end
  table.insert(conns, plot.DescendantAdded:Connect(function(d)
    if d:IsA("ProximityPrompt") then table.insert(padPrompts, d) end
  end))
  return true
end

task.spawn(function()
  while state.running and not hookPlot() do task.wait(2) end
end)

-- Pad fire loop: iterates small cached list only
task.spawn(function()
  while state.running do
    if state.pad then
      for i = #padPrompts, 1, -1 do
        local d = padPrompts[i]
        if not d.Parent then
          table.remove(padPrompts, i)
        elseif d.Enabled then
          pcall(fireproximityprompt, d, 1)
        end
      end
    end
    task.wait(2)
  end
end)

-- ========= TP-collect (cooldown scale) =========
task.spawn(function()
  while state.running do
    if state.tp then
      local char = plr.Character
      local hrp = char and char:FindFirstChild("HumanoidRootPart")
      local hum = char and char:FindFirstChildOfClass("Humanoid")
      local cc = workspace:FindFirstChild("ClientCollectibles")
      if hrp and hum and hum.Health > 0 and cc then
        local origin = hrp.CFrame
        local items = {}
        for _, v in ipairs(cc:GetChildren()) do
          if v:IsA("BasePart") and v.Name ~= "PickupBurstRig" then table.insert(items, v)
          elseif v:IsA("Model") and v.PrimaryPart then table.insert(items, v.PrimaryPart) end
        end
        table.sort(items, function(a, b)
          return (a.Position - hrp.Position).Magnitude < (b.Position - hrp.Position).Magnitude
        end)
        for i = 1, math.min(state.tpBatch, #items) do
          if not state.tp or not state.running then break end
          local it = items[i]
          if it and it.Parent then
            hrp.CFrame = it.CFrame + Vector3.new(0, 3, 0)
            task.wait(state.tpCooldown)
          end
        end
        if hrp and hrp.Parent then hrp.CFrame = origin end
      end
    end
    task.wait(0.3)
  end
end)

-- ========= Crate claim =========
local crateRF = RS:FindFirstChild("MogOrDie") and RS.MogOrDie:FindFirstChild("CrateRequest")
task.spawn(function()
  while state.running do
    if state.crate and crateRF then
      for _, act in ipairs({ "Claim", "Open", "Collect" }) do
        pcall(function() crateRF:InvokeServer(act) end)
      end
    end
    task.wait(30)
  end
end)

-- ========= Anti-AFK =========
table.insert(conns, plr.Idled:Connect(function()
  if state.antiafk then
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
  end
end))

-- ========= UI =========
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
    end)(),
  Footer = "Mog or Die",
  Center = true, AutoShow = true,
  ToggleKeybind = Enum.KeyCode.RightControl,
  Size = UDim2.fromOffset(540, 460),
})

local Tabs = { Main = Window:AddTab("Main", "house"), Settings = Window:AddTab("Settings", "settings") }
local L = Tabs.Main:AddLeftGroupbox("Collection", "gem")
local R = Tabs.Main:AddRightGroupbox("Plot / Crates", "package")
local S = Tabs.Main:AddRightGroupbox("Status", "activity")

L:AddToggle("Magnet", { Text = "Magnet (radius boost)", Default = state.magnet,
  Callback = function(v) state.magnet = v; setMagnet(v) end })
L:AddSlider("Radius", { Text = "Magnet Radius", Default = state.radius,
  Min = 20, Max = 4000, Rounding = 0, Suffix = " studs",
  Callback = function(v) state.radius = v; if state.magnet then applyMagnet(v) end end })
L:AddButton({ Text = "Rescan magnet", Tooltip = "Re-find radius table after rejoin oddities",
  Func = function()
    local n = scanMagnet()
    if state.magnet then applyMagnet(state.radius) end
    Library:Notify("Radius entries: " .. n, 3)
  end })

L:AddDivider()

L:AddToggle("TPMode", { Text = "TP-Collect", Default = state.tp,
  Tooltip = "Teleport through collectibles, nearest first",
  Callback = function(v) state.tp = v end })
L:AddSlider("TPCooldown", { Text = "TP Cooldown", Default = state.tpCooldown,
  Min = 0.01, Max = 1, Rounding = 2, Suffix = " s",
  Callback = function(v) state.tpCooldown = v end })
L:AddSlider("TPBatch", { Text = "Items per Sweep", Default = state.tpBatch,
  Min = 1, Max = 60, Rounding = 0,
  Callback = function(v) state.tpBatch = v end })

R:AddToggle("PadBuy", { Text = "Auto-buy pads", Default = state.pad,
  Callback = function(v) state.pad = v end })
R:AddToggle("CrateClaim", { Text = "Auto-claim crates", Default = state.crate,
  Callback = function(v) state.crate = v end })
R:AddToggle("AntiAFK", { Text = "Anti-AFK", Default = state.antiafk,
  Callback = function(v) state.antiafk = v end })
R:AddDivider()
R:AddButton({ Text = "Stop MogAuto", Func = function() getgenv().MogAuto_Stop() end })

-- Status: event-driven attribute labels, zero polling except 1s item count
local zoneLbl = S:AddLabel("Zone: ?")
local comboLbl = S:AddLabel("Combo: 0")
local lvlLbl = S:AddLabel("Height Lv: ?")
local itemsLbl = S:AddLabel("Collectibles: 0")

local function watchAttr(name, lbl, prefix)
  local function upd() lbl:SetText(prefix .. tostring(plr:GetAttribute(name))) end
  table.insert(conns, plr:GetAttributeChangedSignal(name):Connect(upd))
  upd()
end
watchAttr("CurrentZone", zoneLbl, "Zone: ")
watchAttr("PickupComboCount", comboLbl, "Combo: ")
watchAttr("HeightGainLevel", lvlLbl, "Height Lv: ")

task.spawn(function()
  while state.running do
    local cc = workspace:FindFirstChild("ClientCollectibles")
    itemsLbl:SetText("Collectibles: " .. (cc and #cc:GetChildren() or 0))
    task.wait(1)
  end
end)

Library:OnUnload(function()
  state.running = false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  print("[MogAuto] unloaded")
end)

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetFolder("MogAuto")
ThemeManager:SetFolder("MogAuto")
Tabs.Settings:AddLeftGroupbox("Menu", "menu"):AddButton({ Text = "Unload", Func = function() Library:Unload() end })
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:SetDefaultTheme({ BackgroundColor = "0c0a0b", MainColor = "161214", AccentColor = "e0233c", OutlineColor = "2a1d20", FontColor = "f2eded" }) -- CruelHub look
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:LoadAutoloadConfig()

-- Boot: apply magnet immediately
local n = scanMagnet()
if state.magnet then applyMagnet(state.radius) end
print("[MogAuto v2] loaded — radius entries:", n, "| RightCtrl toggles UI")
