--[[
    Needle in a Haystack — "Sell On Drop" gamepass recreation
    UI: Obsidian (deividcomsono)

    MECHANISM (measured live, not guessed):
      * Currency is the player attribute "StrawBalance". Carried count is "Carrying".
      * Payment is SERVER-side and position-gated: when you are within ~8 studs of
        workspace.vent carrying straws, the server deposits them and credits
        StrawBalance. There is no deposit remote to call.
      * DropRequest/DropAllRequest only LITTER: a drop away from the vent is
        accepted (Carrying -> 0) but pays nothing. A drop CFrame far from your
        character is rejected outright. So the pass cannot be faked via remotes.
      * A hard CFrame teleport to the vent LOSES the load (server force-drops on a
        large position jump) — measured twice: carry 8 -> 0, zero credit.
      * A STEPPED move (small increments) keeps the load and pays normally:
            ARRIVED at vent, carry=8 dist=3.0
            BAL -> 2128 | carry=0     (2120 -> 2128 = +8)

    So this recreates the pass's OUTCOME — sell from anywhere, no manual vent trip —
    by doing a fast stepped round trip to the vent and back, not by faking ownership.
]]

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local UIS        = game:GetService("UserInputService")
local LP         = Players.LocalPlayer

-- Re-exec safe: tear down a previous load (and the recon watcher, if present)
if getgenv().NIH_SOD then pcall(getgenv().NIH_SOD.unload) end
if getgenv().NIH_WATCH then pcall(getgenv().NIH_WATCH.stop) end

local STATE = {
    alive      = true,
    busy       = false,
    auto       = false,
    threshold  = 1,      -- sell once carrying >= this
    stepSize   = 8,      -- studs per step; 8 is the measured-safe value
    stepDelay  = 0.06,   -- seconds between steps
    returnHome = true,
    lastGain   = 0,
    totalGain  = 0,
    status     = "idle",
    unload     = function() end,
}
getgenv().NIH_SOD = STATE

local function hrp()   local c = LP.Character return c and c:FindFirstChild("HumanoidRootPart") end
local function carry() return LP:GetAttribute("Carrying") or 0 end
local function bal()   return LP:GetAttribute("StrawBalance") or 0 end

-- The sell spot is stored RELATIVE to the vent pivot (right/look/up), so it stays
-- correct if the vent moves or the world resets. Defaults captured from a player
-- standing on the working spot: world (50.891, 2.779, 82.417).
local SPOT_FILE = "nih_sellspot.json"
STATE.spot = { right = 6.91, look = 0.53, y = 2.78 }
pcall(function()
    if isfile and isfile(SPOT_FILE) then
        local t = game:GetService("HttpService"):JSONDecode(readfile(SPOT_FILE))
        if t and t.right and t.look and t.y then STATE.spot = t end
    end
end)

local function ventPivot()
    local vent = workspace:FindFirstChild("vent")
    return vent and vent:GetPivot() or nil
end

-- World position of the sell spot
local function sellPos()
    local pv = ventPivot()
    if not pv then return nil end
    return pv.Position
        + pv.RightVector * STATE.spot.right
        + pv.LookVector  * STATE.spot.look
        + Vector3.new(0, STATE.spot.y, 0)
end

-- Re-derive the offsets from where the character currently stands
local function captureSpot()
    local pv = ventPivot()
    local c  = LP.Character
    local h  = c and c:FindFirstChild("HumanoidRootPart")
    if not (pv and h) then return false end
    local rel = h.Position - pv.Position
    STATE.spot = {
        right = rel:Dot(pv.RightVector),
        look  = rel:Dot(pv.LookVector),
        y     = rel.Y,
    }
    pcall(function()
        writefile(SPOT_FILE, game:GetService("HttpService"):JSONEncode(STATE.spot))
    end)
    return true
end

-- Incremental move. Big jumps make the server force-drop the load, so we walk it
-- in stepSize chunks. Rotation is preserved so the camera doesn't snap.
local function stepTo(targetPos)
    for _ = 1, 600 do
        if not STATE.alive then return false end
        local h = hrp()
        if not h then return false end
        local cur = h.CFrame
        local rot = cur - cur.Position
        local d   = targetPos - cur.Position
        if d.Magnitude <= STATE.stepSize then
            h.CFrame = CFrame.new(targetPos) * rot
            return true
        end
        h.CFrame = CFrame.new(cur.Position + d.Unit * STATE.stepSize) * rot
        task.wait(STATE.stepDelay)
    end
    return false
end

local function waitDeposit(timeout)
    local t0 = os.clock()
    while carry() > 0 and os.clock() - t0 < timeout do task.wait(0.05) end
    return carry() <= 0
end

-- One sell run: dash to the sell spot, let the server pay, dash back.
local function sellRun()
    if STATE.busy then return false, "busy" end
    local c0 = carry()
    if c0 <= 0 then return false, "carrying nothing" end
    local h = hrp()
    if not h then return false, "no character" end
    local sp = sellPos()
    if not sp then return false, "vent not found" end

    STATE.busy   = true
    STATE.status = "selling…"
    local origin = h.CFrame
    local b0     = bal()

    pcall(function()
        stepTo(sp)
        local hh = hrp()
        if hh then hh.CFrame = CFrame.new(sp) * (hh.CFrame - hh.CFrame.Position) end

        -- Park and let the server take it. If it doesn't bite, nudge around the
        -- spot a little — the trigger volume is small and landing exactly on the
        -- captured point isn't always enough.
        if not waitDeposit(2) then
            for _, off in ipairs({
                Vector3.new(0, 0, 0), Vector3.new(1.5, 0, 0), Vector3.new(-1.5, 0, 0),
                Vector3.new(0, 0, 1.5), Vector3.new(0, 0, -1.5), Vector3.new(0, 1.5, 0),
            }) do
                if carry() <= 0 then break end
                local hn = hrp()
                if hn then hn.CFrame = CFrame.new(sp + off) * (hn.CFrame - hn.CFrame.Position) end
                if waitDeposit(0.8) then break end
            end
        end

        task.wait(0.15)
        if STATE.returnHome then
            stepTo(origin.Position)
            local hb = hrp()
            if hb then hb.CFrame = origin end
        end
    end)

    STATE.lastGain  = bal() - b0
    STATE.totalGain = STATE.totalGain + STATE.lastGain
    STATE.busy      = false
    STATE.status    = "idle"
    return true
end

-- Auto loop (sellRun yields, so it lives in its own thread)
task.spawn(function()
    while STATE.alive do
        if STATE.auto and not STATE.busy and carry() >= STATE.threshold then
            pcall(sellRun)
        end
        task.wait(0.25)
    end
end)

-- ============================== Obsidian UI ==============================
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua"))()

for k, v in pairs({ BackgroundColor = "0c0a0b", MainColor = "161214", AccentColor = "e0233c", OutlineColor = "2a1d20", FontColor = "f2eded" }) do Library.Scheme[k] = Color3.fromHex(v) end -- CruelHub look

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
    Footer = "Needle in a Haystack · vent run · recreated pass",
    Center   = true,
    AutoShow = true,
})

local Tab  = Window:AddTab("Main", "house")
local Sell = Tab:AddLeftGroupbox("Sell On Drop", "badge-dollar-sign")

Sell:AddButton({
    Text = "Sell Now  [V]",
    Func = function()
        local ok, why = sellRun()
        Library:Notify(ok and ("Sold — +" .. STATE.lastGain) or ("Can't sell: " .. tostring(why)), 3)
    end,
})

local autoToggle = Sell:AddToggle("NIH_Auto", {
    Text     = "Auto Sell",
    Tooltip  = "Automatically do a sell run once you're carrying enough",
    Default  = false,
    Callback = function(v) STATE.auto = v end,
})
autoToggle:AddKeyPicker("NIH_AutoKey", {
    Default         = "P",
    SyncToggleState = true,
    Mode            = "Toggle",
    Text            = "Auto Sell",
})

Sell:AddSlider("NIH_Threshold", {
    Text = "Sell at carry >=", Default = 1, Min = 1, Max = 60, Rounding = 0,
    Callback = function(v) STATE.threshold = v end,
})

Sell:AddToggle("NIH_Return", {
    Text = "Return to start", Default = true,
    Callback = function(v) STATE.returnHome = v end,
})

local statusLabel = Sell:AddLabel("carrying 0 · balance 0", true)

local Spot = Tab:AddLeftGroupbox("Sell Spot", "map-pin")
Spot:AddLabel("Stored relative to the vent. If selling stops working, stand where it does work and capture it.", true)
Spot:AddButton({
    Text = "Capture spot = my position",
    Func = function()
        if captureSpot() then
            Library:Notify(("Spot set: right %.2f, look %.2f, y %.2f")
                :format(STATE.spot.right, STATE.spot.look, STATE.spot.y), 4)
        else
            Library:Notify("Capture failed (no vent or character).", 3)
        end
    end,
})
Spot:AddButton({
    Text = "Walk me to the spot",
    Func = function()
        local sp = sellPos()
        if not sp then Library:Notify("Vent not found.", 3) return end
        task.spawn(function()
            STATE.busy = true
            stepTo(sp)
            local h = hrp()
            if h then h.CFrame = CFrame.new(sp) * (h.CFrame - h.CFrame.Position) end
            STATE.busy = false
        end)
    end,
})

local Tune = Tab:AddRightGroupbox("Tuning", "sliders-horizontal")
Tune:AddLabel("Bigger steps = faster, but too big and the server force-drops your load. 8 is measured-safe.", true)
Tune:AddSlider("NIH_Step", {
    Text = "Step size", Default = 8, Min = 2, Max = 20, Rounding = 0, Suffix = " studs",
    Callback = function(v) STATE.stepSize = v end,
})
Tune:AddSlider("NIH_Delay", {
    Text = "Step delay", Default = 0.06, Min = 0.02, Max = 0.2, Rounding = 2, Suffix = "s",
    Callback = function(v) STATE.stepDelay = v end,
})

local Menu = Tab:AddRightGroupbox("Menu", "menu")
Menu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })

-- Live status
task.spawn(function()
    while STATE.alive do
        pcall(function()
            statusLabel:SetText(("carrying %d · balance %d\n%s · last +%d · total +%d")
                :format(carry(), bal(), STATE.status, STATE.lastGain, STATE.totalGain))
        end)
        task.wait(0.2)
    end
end)

-- Manual hotkey (V)
local inputConn = UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.V then task.spawn(sellRun) end
end)

Library:OnUnload(function()
    STATE.alive = false
    STATE.auto  = false
    pcall(function() inputConn:Disconnect() end)
    getgenv().NIH_SOD = nil
end)
STATE.unload = function() pcall(function() Library:Unload() end) end

Library:Notify("Sell On Drop ready — V to sell, P for auto.", 4)
