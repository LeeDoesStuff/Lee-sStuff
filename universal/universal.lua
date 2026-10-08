-- CruelHub Universal: the fallback script for games without a dedicated one (games.json "default").
-- Basics most games support: player ESP (box + name + distance), fullbright, walkspeed, jump, infinite jump.
-- Re-exec safe (guards getgenv().CruelHubUniversal) and ships an Unload button that restores everything.
if getgenv().CruelHubUniversal then getgenv().CruelHubUniversal.destroy() end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInput = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local lp = Players.LocalPlayer
local cam = Workspace.CurrentCamera

local state = {
    esp = false, espNames = true, espDistance = true, teamCheck = false,
    fullbright = false, infJump = false, walk = 16, jump = 50,
}
local conns, drawings = {}, {}
local self = {}
getgenv().CruelHubUniversal = self

-- ESP via the Drawing API (RenderStepped). Each player gets a box + name + distance text, hidden when off-screen.
local function espFor(plr)
    local box = Drawing.new("Square"); box.Thickness = 1; box.Filled = false; box.Color = Color3.fromRGB(224, 35, 60)
    local name = Drawing.new("Text"); name.Size = 13; name.Center = true; name.Outline = true; name.Color = Color3.new(1, 1, 1)
    local dist = Drawing.new("Text"); dist.Size = 12; dist.Center = true; dist.Outline = true; dist.Color = Color3.fromRGB(200, 200, 200)
    drawings[plr] = { box, name, dist }
end
local function clearEsp(plr)
    if drawings[plr] then for _, d in ipairs(drawings[plr]) do d:Remove() end drawings[plr] = nil end
end

conns.playerAdded = Players.PlayerAdded:Connect(function(p) if p ~= lp then espFor(p) end end)
conns.playerRemoving = Players.PlayerRemoving:Connect(clearEsp)
for _, p in ipairs(Players:GetPlayers()) do if p ~= lp then espFor(p) end end

conns.render = RunService.RenderStepped:Connect(function()
    for plr, d in pairs(drawings) do
        local box, name, dist = d[1], d[2], d[3]
        local char = plr.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local head = char and char:FindFirstChild("Head")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local show = state.esp and hrp and head and hum and hum.Health > 0
        if show and state.teamCheck and plr.Team == lp.Team then show = false end
        if show then
            local top, onTop = cam:WorldToViewportPoint((head.CFrame + Vector3.new(0, 0.6, 0)).Position)
            local bot = cam:WorldToViewportPoint((hrp.CFrame - Vector3.new(0, 3.2, 0)).Position)
            if onTop then
                local h = math.abs(top.Y - bot.Y)
                local w = h * 0.55
                box.Size = Vector2.new(w, h)
                box.Position = Vector2.new(top.X - w / 2, top.Y)
                box.Color = (state.teamCheck and plr.Team == lp.Team) and Color3.fromRGB(90, 200, 120) or Color3.fromRGB(224, 35, 60)
                box.Visible = true
                name.Text = plr.Name; name.Position = Vector2.new(top.X, top.Y - 16); name.Visible = state.espNames
                local mag = (hrp.Position - (lp.Character and lp.Character:FindFirstChild("HumanoidRootPart") and lp.Character.HumanoidRootPart.Position or cam.CFrame.Position)).Magnitude
                dist.Text = ("%dm"):format(mag); dist.Position = Vector2.new(top.X, bot.Y + 2); dist.Visible = state.espDistance
            else
                box.Visible, name.Visible, dist.Visible = false, false, false
            end
        else
            box.Visible, name.Visible, dist.Visible = false, false, false
        end
    end
end)

-- Fullbright: lift ambient + brightness while on; snapshot restores the original on toggle off / unload.
local Lighting = game:GetService("Lighting")
local lightSnap
local function setFullbright(on)
    if on and not lightSnap then
        lightSnap = { Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd, Ambient = Lighting.Ambient }
        Lighting.Brightness = 2; Lighting.ClockTime = 14; Lighting.FogEnd = 1e9; Lighting.Ambient = Color3.new(1, 1, 1)
    elseif not on and lightSnap then
        Lighting.Brightness, Lighting.ClockTime, Lighting.FogEnd, Lighting.Ambient = lightSnap.Brightness, lightSnap.ClockTime, lightSnap.FogEnd, lightSnap.Ambient
        lightSnap = nil
    end
end

-- Movement: re-applied on respawn via CharacterAdded; infinite jump listens for the jump input.
local function applyChar(char)
    local hum = char:WaitForChild("Humanoid", 5)
    if hum then hum.WalkSpeed = state.walk; hum.JumpPower = state.jump; hum.UseJumpPower = true end
end
conns.charAdded = lp.CharacterAdded:Connect(applyChar)
if lp.Character then applyChar(lp.Character) end

conns.jump = UserInput.JumpRequest:Connect(function()
    if state.infJump and lp.Character then
        local hum = lp.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end)

--==================== UI (CruelHub theme) ====================
local BG, MAIN, ACCENT, OUTLINE, FONT, MUTED = Color3.fromHex("0c0a0b"), Color3.fromHex("161214"), Color3.fromHex("e0233c"), Color3.fromHex("2a1d20"), Color3.fromHex("f2eded"), Color3.fromHex("8a7d80")
local function mk(class, props, parent) local o = Instance.new(class) for k, v in pairs(props) do o[k] = v end o.Parent = parent return o end
local function round(o, r) mk("UICorner", { CornerRadius = UDim.new(0, r or 6) }, o) end

local gui = mk("ScreenGui", { Name = "CruelHubUniversal", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local frame = mk("Frame", { Size = UDim2.fromOffset(240, 316), Position = UDim2.new(0, 20, 0.5, -158), BackgroundColor3 = BG, BorderSizePixel = 0, Active = true }, gui)
round(frame, 8); mk("UIStroke", { Color = OUTLINE }, frame)
mk("Frame", { Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, frame)

local bar = mk("Frame", { Size = UDim2.new(1, 0, 0, 40), Position = UDim2.fromOffset(0, 3), BackgroundTransparency = 1 }, frame)
mk("TextLabel", { Size = UDim2.new(1, -16, 0, 20), Position = UDim2.fromOffset(14, 6), BackgroundTransparency = 1, Text = "CruelHub", TextColor3 = FONT, Font = Enum.Font.GothamBold, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left }, bar)
mk("TextLabel", { Size = UDim2.new(1, -16, 0, 13), Position = UDim2.fromOffset(14, 23), BackgroundTransparency = 1, Text = "Universal", TextColor3 = MUTED, Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left }, bar)

local list = mk("Frame", { Size = UDim2.new(1, -20, 1, -92), Position = UDim2.fromOffset(10, 46), BackgroundTransparency = 1 }, frame)
mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, list)

local function toggle(text, key)
    local row = mk("TextButton", { Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = MAIN, Text = "", AutoButtonColor = false }, list)
    round(row)
    mk("TextLabel", { Size = UDim2.new(1, -56, 1, 0), Position = UDim2.fromOffset(12, 0), BackgroundTransparency = 1, Text = text, TextColor3 = FONT, Font = Enum.Font.Gotham, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left }, row)
    local pill = mk("Frame", { Size = UDim2.fromOffset(34, 18), Position = UDim2.new(1, -44, 0.5, -9), BackgroundColor3 = OUTLINE, BorderSizePixel = 0 }, row)
    round(pill, 9)
    local knob = mk("Frame", { Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(2, 2), BackgroundColor3 = FONT, BorderSizePixel = 0 }, pill)
    round(knob, 7)
    local function paint() pill.BackgroundColor3 = state[key] and ACCENT or OUTLINE; knob.Position = state[key] and UDim2.fromOffset(18, 2) or UDim2.fromOffset(2, 2) end
    paint()
    row.MouseButton1Click:Connect(function()
        state[key] = not state[key]; paint()
        if key == "fullbright" then setFullbright(state[key]) end
    end)
end

local function slider(text, key, min, max, apply)
    local row = mk("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = MAIN }, list)
    round(row)
    local lbl = mk("TextLabel", { Size = UDim2.new(1, -16, 0, 16), Position = UDim2.fromOffset(12, 5), BackgroundTransparency = 1, Text = text .. ": " .. state[key], TextColor3 = FONT, Font = Enum.Font.Gotham, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left }, row)
    local track = mk("Frame", { Size = UDim2.new(1, -24, 0, 6), Position = UDim2.fromOffset(12, 26), BackgroundColor3 = OUTLINE, BorderSizePixel = 0 }, row)
    round(track, 3)
    local fill = mk("Frame", { Size = UDim2.fromScale((state[key] - min) / (max - min), 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, track)
    round(fill, 3)
    local dragging = false
    local function set(x)
        local a = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        state[key] = math.floor(min + a * (max - min) + 0.5)
        fill.Size = UDim2.fromScale(a, 1); lbl.Text = text .. ": " .. state[key]; apply(state[key])
    end
    track.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = true; set(i.Position.X) end end)
    UserInput.InputChanged:Connect(function(i) if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then set(i.Position.X) end end)
    UserInput.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end end)
end

toggle("Player ESP", "esp")
toggle("ESP names", "espNames")
toggle("ESP distance", "espDistance")
toggle("Team check", "teamCheck")
toggle("Fullbright", "fullbright")
toggle("Infinite jump", "infJump")
slider("WalkSpeed", "walk", 16, 200, function(v) if lp.Character then local h = lp.Character:FindFirstChildOfClass("Humanoid") if h then h.WalkSpeed = v end end end)
slider("JumpPower", "jump", 50, 350, function(v) if lp.Character then local h = lp.Character:FindFirstChildOfClass("Humanoid") if h then h.JumpPower = v; h.UseJumpPower = true end end end)

local unload = mk("TextButton", { Size = UDim2.new(1, -20, 0, 30), Position = UDim2.new(0, 10, 1, -40), BackgroundColor3 = ACCENT, Text = "Unload", TextColor3 = FONT, Font = Enum.Font.GothamBold, TextSize = 13, AutoButtonColor = false }, frame)
round(unload)

-- drag by the title bar
local dragging, dragStart, startPos
bar.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging, dragStart, startPos = true, i.Position, frame.Position end end)
UserInput.InputChanged:Connect(function(i) if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then local d = i.Position - dragStart; frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y) end end)
UserInput.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end end)

function self.destroy()
    for _, c in pairs(conns) do pcall(function() c:Disconnect() end) end
    for plr in pairs(drawings) do clearEsp(plr) end
    setFullbright(false)
    if lp.Character then local h = lp.Character:FindFirstChildOfClass("Humanoid") if h then h.WalkSpeed = 16; h.JumpPower = 50 end end
    pcall(function() gui:Destroy() end)
    getgenv().CruelHubUniversal = nil
end
unload.MouseButton1Click:Connect(self.destroy)
