--[[
    Warfare drone HUD v1  (place 81748781442029)
    UI: Obsidian (deividcomsono)
    Features:
      - Drop / impact predictor: MAVIC ballistic arc (same math as the game's MavicFlight.Predict, longer
        horizon), FPV straight-line impact along velocity. ETA + height on screen.
      - Blast rings at the predicted impact: edge (r), lethal (>= 100 dmg), core (full dmg).
      - Enemy aim cones from each enemy's head + "WATCHED" warning when a cone covers your body or drone.
      - Body guard: warns when enemies get near your character while you fly.
      - Enemy drone alert: distance, closing speed, ETA to your body/drone, highlight + velocity line.
    Spec: warfare-spec.md
]]

if getgenv().WARFARE_HUD then pcall(getgenv().WARFARE_HUD.unload) end

local Players   = game:GetService("Players")
local RS        = game:GetService("ReplicatedStorage")
local Run       = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local lp        = Players.LocalPlayer

local M = 0.28 -- studs -> meters, same factor the game's drone HUD uses
local Attachments  = RS:WaitForChild("DroneSystem"):WaitForChild("Attachments")
local DroneWS      = Workspace:WaitForChild("DroneWorkspace")
-- Next grenade on a MAVIC rack; mirrors Framework.Modules.MavicFlight.GetPayload. Inlined instead of require()
-- so no game module ever runs in the executor's context (lower-level executors emulate require differently).
local function mavicPayload(m)
    local holder
    for _, c in ipairs(m:GetChildren()) do
        if c:IsA("Model") and c:GetAttribute("GrenadeHolder") then holder = c; break end
    end
    if not holder then return nil end
    local rack = holder:FindFirstChild("RGD") or holder:FindFirstChild("Grenades") or holder
    local best, bestN
    for _, c in ipairs(rack:GetChildren()) do
        local n = tonumber(c.Name)
        if c:IsA("Model") and n and not c:GetAttribute("Dropped") and (not bestN or n < bestN) then best, bestN = c, n end
    end
    if not best then return nil end
    return best.PrimaryPart or best:FindFirstChild("Grenade") or best:FindFirstChild("MeshPart") or best:FindFirstChildWhichIsA("BasePart")
end

-- Memory-reading features (muzzle aim, map ESP) need getgc + debug.getupvalue/getinfo + islclosure.
-- Detected once; missing on some executors, and a slow getgc there would freeze the client on every scan.
local HAS_GC = type(getgc) == "function" and type(islclosure) == "function"
    and type(debug) == "table" and type(debug.getupvalue) == "function" and type(debug.getinfo) == "function"

-- ExplosionFX: blast damage = full inside r/4, then dmg*(1-x)^1.7 down to 0 at r. Characters have 100 HP.
local GRENADE_DMG = { M67 = 125, RDG5 = 110, F1 = 145, RGO = 135 } -- ExplosionFX default damage per type
local learnedR = { M67 = 55 } -- explosion type -> radius, learned live from ExplosionFX.Replicate (measured M67 = 55)

local function lethalRadius(r, dmg)
    -- ponytail: plain blast curve only; ignores shrapnel (extra dmg) and any armor (less dmg)
    if dmg < 100 then return nil end
    local c = r * 0.25
    return c + (r - c) * (1 - (100 / dmg) ^ (1 / 1.7))
end
assert(math.abs(lethalRadius(55, 125) - 18.83) < 0.05 and lethalRadius(55, 90) == nil, "lethalRadius self-check")

local CFG = {
    predict = true, rings = true, horizon = 8,
    cones = true, coneLen = 60, coneAngle = 6, coneRange = 150, coneGradient = true, gradAngle = 90,
    esp = true, espNames = true, espRange = 500,
    chams = true, chamsStyle = "Per part", chamsWalls = true, chamsVisColor = true, chamsRange = 500,
    watchWarn = true, watchLOS = true, watchFacing = true,
    bodyGuard = true, bodyRadius = 15, bodyOnlyFlying = true,
    droneAlert = true, droneRange = 80, droneHighlight = true,
    mapEsp = true, mapNames = true, mapDrones = true, mapDotSize = 7, mapSpawn = true,
    aimZoom = false, zoomLevel = 3, zoomSize = 35, zoomSpeed = 14, zoomSens = true, zoomRing = true,
    memScans = HAS_GC,
}

-- every drawn element: color c + transparency t (0 = solid, 1 = invisible); edited by the pickers in the Colors tab
local COL = {
    arc       = { c = Color3.fromRGB(255, 200, 70),  t = 0,    name = "Predictor arc / line",      group = "Predictor" },
    edge      = { c = Color3.fromRGB(255, 170, 40),  t = 0.25, name = "Blast edge ring",           group = "Predictor" },
    lethal    = { c = Color3.fromRGB(255, 60, 40),   t = 0.25, name = "Lethal ring",               group = "Predictor" },
    core      = { c = Color3.fromRGB(150, 0, 0),     t = 0.25, name = "Full-damage ring",          group = "Predictor" },
    cone      = { c = Color3.fromRGB(255, 220, 90),  t = 0.3,  name = "Aim cone (no gradient)",    group = "Aim cones" },
    coneHot   = { c = Color3.fromRGB(255, 40, 40),   t = 0,    name = "Aim cone (on you)",         group = "Aim cones" },
    coneAway  = { c = Color3.fromRGB(60, 255, 110),  t = 0.4,  name = "Aim cone (looking away)",   group = "Aim cones" },
    espText   = { c = Color3.fromRGB(255, 255, 255), t = 0,    name = "ESP text",                  group = "ESP & chams" },
    espStroke = { c = Color3.fromRGB(0, 0, 0),       t = 0.4,  name = "ESP text outline",          group = "ESP & chams" },
    chamFill  = { c = Color3.fromRGB(255, 50, 50),   t = 0.6,  name = "Chams fill (behind cover)", group = "ESP & chams" },
    chamVis   = { c = Color3.fromRGB(255, 220, 60),  t = 0.5,  name = "Chams fill (in sight)",     group = "ESP & chams" },
    chamLine  = { c = Color3.fromRGB(255, 255, 255), t = 0.2,  name = "Chams outline",             group = "ESP & chams" },
    drone     = { c = Color3.fromRGB(255, 60, 200),  t = 0.4,  name = "Enemy drone fill",          group = "Enemy drones" },
    droneLine = { c = Color3.fromRGB(255, 255, 255), t = 0,    name = "Enemy drone outline",       group = "Enemy drones" },
    droneVel  = { c = Color3.fromRGB(255, 60, 200),  t = 0,    name = "Enemy drone heading line",  group = "Enemy drones" },
    warnText  = { c = Color3.fromRGB(255, 80, 60),   t = 0,    name = "Warning text",              group = "HUD text" },
    infoText  = { c = Color3.fromRGB(255, 220, 120), t = 0,    name = "Predictor text",            group = "HUD text" },
    hudStroke = { c = Color3.fromRGB(0, 0, 0),       t = 0.3,  name = "HUD text outline",          group = "HUD text" },
    mapDot    = { c = Color3.fromRGB(255, 50, 50),   t = 0,    name = "Map: enemy dot",            group = "Map" },
    mapDrone  = { c = Color3.fromRGB(255, 60, 200),  t = 0,    name = "Map: enemy drone",          group = "Map" },
    zoomRing  = { c = Color3.fromRGB(255, 255, 255), t = 0.4,  name = "Zoom ring",                 group = "Aim zoom" },
    zoomDim   = { c = Color3.fromRGB(0, 0, 0),       t = 1,    name = "Zoom: outside the ring (1 = no dim)", group = "Aim zoom" },
}
local COL_ORDER = { "arc", "edge", "lethal", "core", "cone", "coneHot", "coneAway", "espText", "espStroke", "chamFill", "chamVis",
    "chamLine", "drone", "droneLine", "droneVel", "warnText", "infoText", "hudStroke", "mapDot", "mapDrone", "zoomRing", "zoomDim" }
local COL_GROUPS = { "Predictor", "Aim cones", "ESP & chams", "Enemy drones", "HUD text", "Map", "Aim zoom" }
for _, col in pairs(COL) do col.c0, col.t0 = col.c, col.t end -- defaults for the reset button

-- ============================== drawing ==============================
local conns = {}
local root = Instance.new("Folder")
root.Name = "WarfareHUD"
root.Parent = gethui and gethui() or game:GetService("CoreGui")

local pools = {}
local function pool(class, props, init, parent)
    local p = { n = 0, list = {} }
    pools[#pools + 1] = p
    function p.get()
        p.n += 1
        local a = p.list[p.n]
        if not a then
            a = Instance.new(class)
            for k, v in pairs(props) do a[k] = v end
            if init then init(a) end
            a.Parent = parent or root
            p.list[p.n] = a
        end
        if a:IsA("HandleAdornment") or a:IsA("GuiObject") then a.Visible = true else a.Enabled = true end
        return a
    end
    function p.flush()
        for i = p.n + 1, #p.list do
            local a = p.list[i]
            if a:IsA("HandleAdornment") or a:IsA("GuiObject") then a.Visible = false else a.Enabled = false end
        end
        p.n = 0
    end
    return p
end
local terrain = Workspace.Terrain
local Lines = pool("LineHandleAdornment", { Adornee = terrain, AlwaysOnTop = true, ZIndex = 1, Thickness = 3 })
local Rings = pool("CylinderHandleAdornment", { Adornee = terrain, AlwaysOnTop = true, ZIndex = 0, Height = 0.4 })
local Marks = pool("Highlight", { DepthMode = Enum.HighlightDepthMode.AlwaysOnTop })
-- ponytail: Roblox renders at most 31 Highlights (chams + enemy drones share it); ~20 enemies fits. Nearest-first cap if it ever overflows
local Chams = pool("Highlight", {})
local Boxes = pool("BoxHandleAdornment", { ZIndex = 1 }) -- per-part chams: no instance cap, one color per part

-- fade: extra transparency on top of the element's own (cone edges are drawn fainter than the center line)
local function line(a, b, key, thick, fade)
    local d = b - a
    if d.Magnitude < 0.05 then return end
    local h, col = Lines.get(), type(key) == "table" and key or COL[key]
    h.CFrame, h.Length = CFrame.lookAt(a, b), d.Magnitude
    h.Color3, h.Thickness, h.Transparency = col.c, thick or 3, math.min(1, col.t + (fade or 0))
end

local function ring(center, normal, r, key)
    local h = Rings.get()
    h.CFrame = CFrame.lookAt(center + normal * 0.3, center + normal * 2)
    h.Radius, h.InnerRadius = r, math.max(0, r - math.max(0.35, r * 0.025))
    h.Color3, h.Transparency = COL[key].c, COL[key].t
end

local Esp = pool("BillboardGui", { AlwaysOnTop = true, LightInfluence = 0, Size = UDim2.fromOffset(220, 16),
    StudsOffset = Vector3.new(0, 2, 0), MaxDistance = math.huge, ResetOnSpawn = false }, function(b)
    local t = Instance.new("TextLabel")
    t.Name, t.Size, t.BackgroundTransparency = "T", UDim2.fromScale(1, 1), 1
    t.Font, t.TextSize, t.TextStrokeTransparency = Enum.Font.GothamMedium, 13, 0.4
    t.Parent = b
end, root.Parent)

local screen = Instance.new("ScreenGui")
screen.Name, screen.IgnoreGuiInset, screen.ResetOnSpawn, screen.DisplayOrder = "WarfareHUD", true, false, 50
screen.Parent = root.Parent
local function label(y, size)
    local t = Instance.new("TextLabel")
    t.AnchorPoint, t.Position, t.Size = Vector2.new(0.5, 0), UDim2.fromScale(0.5, y), UDim2.fromOffset(700, 20)
    t.AutomaticSize = Enum.AutomaticSize.Y
    t.BackgroundTransparency, t.TextSize = 1, size
    t.Font, t.TextStrokeTransparency, t.RichText, t.Text = Enum.Font.GothamBold, 0.3, true, ""
    t.Parent = screen
    return t
end
local warnLabel = label(0.13, 18)

-- aim zoom overlay: a centered circle sized by screen height; the dim is a huge UIStroke drawn outside it
local function zoomCircle(thick)
    local f = Instance.new("Frame")
    f.AnchorPoint, f.Position, f.SizeConstraint = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5), Enum.SizeConstraint.RelativeYY
    f.BackgroundTransparency, f.Visible = 1, false
    Instance.new("UICorner", f).CornerRadius = UDim.new(1, 0)
    local st = Instance.new("UIStroke")
    st.Thickness, st.Parent = thick, f
    f.Parent = screen
    return f, st
end
local zoomDimFrame, zoomDimStroke = zoomCircle(4000)
local zoomRingFrame, zoomRingStroke = zoomCircle(2)
local infoLabel = label(0.74, 16)

-- ============================== game state ==============================
table.insert(conns, RS.Framework.Modules.ExplosionFX:WaitForChild("Replicate").OnClientEvent:Connect(function(d)
    if type(d) == "table" and type(d.t) == "string" and tonumber(d.r) then learnedR[d.t] = tonumber(d.r) end
end))

local function myTeam() return lp:GetAttribute("Team") end
local function isEnemy(pl)
    local t = pl:GetAttribute("Team")
    return pl ~= lp and t ~= nil and t ~= myTeam() and pl:GetAttribute("InMenu") ~= true
end

local function myDrone()
    if lp:GetAttribute("InDrone") ~= true then return end
    local m = DroneWS:FindFirstChild(lp.UserId .. "_MAVIC") or DroneWS:FindFirstChild(lp.UserId .. "_FPV")
    local main = m and m:FindFirstChild("Other") and m.Other:FindFirstChild("Main")
    if main then return m, main end
end

-- radius / damage of the payload on a drone. FPV: attachment attrs Distance (= blast radius, measured) and Damage.
local function payload(m)
    local kind = m:GetAttribute("DroneType") or (m.Name:find("MAVIC") and "MAVIC" or "FPV")
    local name = m:GetAttribute("MountedWarhead")
        or (kind == "MAVIC" and lp:GetAttribute("SelectedWarheadMAVIC") or Workspace:GetAttribute("SelectedDroneAttachment"))
    local att = name and Attachments:FindFirstChild(name)
    local t = att and att:GetAttribute("Explosion") or (kind == "MAVIC" and "M67" or "FPVFrag")
    local r = att and att:GetAttribute("Distance") or learnedR[t] or 55
    local dmg = att and att:GetAttribute("Damage") or GRENADE_DMG[t] or 100
    return kind, (att and att:GetAttribute("DisplayName")) or t, r, dmg
end

local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.RespectCanCollide = true
local function refreshFilter(char)
    local ex = { DroneWS, Workspace.CurrentCamera }
    for _, n in ipairs({ "ClientTrash", "BulletPool", "ViewmodelPool" }) do
        local f = Workspace:FindFirstChild(n)
        if f then ex[#ex + 1] = f end
    end
    if char then ex[#ex + 1] = char end
    rp.FilterDescendantsInstances = ex
end

local losP = RaycastParams.new()
losP.FilterType = Enum.RaycastFilterType.Exclude
-- ponytail: any part blocks sight, incl. glass/foliage; add a transparency filter if warnings get too quiet
-- Raycast that passes through ragdoll corpses (incl. your own death ragdoll, Terrain.<you>_LocalCorpse.RagdollRig),
-- same as the game's MavicFlight predictor, which skips CollisionGroup "RagdollCorpse" / humanoid bodies.
local function isRagdoll(inst)
    return inst.CollisionGroup == "RagdollCorpse" or inst:FindFirstAncestor("RagdollRig") ~= nil
end
local function cast(origin, dir, params)
    local stop = origin + dir
    for _ = 1, 4 do
        local r = Workspace:Raycast(origin, stop - origin, params)
        if not (r and isRagdoll(r.Instance)) then return r end
        origin = r.Position + dir.Unit * 0.05
    end
    return nil
end

local function clearLOS(from, to, theirChar)
    losP.FilterDescendantsInstances = { theirChar, lp.Character, DroneWS, Workspace.CurrentCamera }
    return cast(from, to - from, losP) == nil
end

-- ============================== features ==============================
local function drawBlast(hit, r, dmg)
    if not CFG.rings then return end
    local n = hit.Normal
    ring(hit.Position, n, r, "edge")
    local lr = lethalRadius(r, dmg)
    if lr then ring(hit.Position, n, lr, "lethal") end
    ring(hit.Position, n, r * 0.25, "core")
end

local function predictor(m, main)
    if not CFG.predict then return end
    local kind, pname, r, dmg = payload(m)
    local v0 = main.AssemblyLinearVelocity
    local hit, eta
    if kind == "MAVIC" then
        local part = mavicPayload(m)
        local p0 = part and part.Position or main.Position
        local g = Vector3.new(0, -Workspace.Gravity, 0)
        local prev, last = p0, p0
        for i = 1, CFG.horizon * 30 do
            local t = i / 30
            local p = p0 + v0 * t + g * (0.5 * t * t)
            local res = cast(prev, p - prev, rp)
            if res then
                line(last, res.Position, "arc", 3)
                hit, eta = res, t
                break
            end
            if i % 3 == 0 then line(last, p, "arc", 3); last = p end
            prev = p
        end
        if not part then pname ..= " (empty)" end
    else
        local speed = v0.Magnitude
        if speed > 3 then
            local reach = math.min(speed * CFG.horizon, 3000)
            local res = cast(main.Position, v0.Unit * reach, rp)
            local stop = res and res.Position or main.Position + v0.Unit * reach
            line(main.Position, stop, "arc", 2)
            if res then hit, eta = res, (res.Position - main.Position).Magnitude / speed end
        end
    end
    local lr = lethalRadius(r, dmg)
    local text = ("%s · r %dm%s"):format(pname, r * M, lr and (" · lethal %dm"):format(lr * M) or " · not 1-shot")
    if hit then
        drawBlast(hit, r, dmg)
        text ..= ("  |  impact %.1fs · %dm away"):format(eta, (hit.Position - main.Position).Magnitude * M)
    else
        text ..= "  |  no impact in " .. CFG.horizon .. "s"
    end
    infoLabel.Text = text
end

local function coneEdges(origin, look, len, angle, key, fade)
    local cf = CFrame.lookAt(origin, origin + look)
    for k = 0, 3 do
        local dir = (cf * CFrame.Angles(0, 0, k * math.pi / 2) * CFrame.Angles(math.rad(angle), 0, 0)).LookVector
        line(origin, origin + dir * len, key, 1.5, fade)
    end
end

-- Where an enemy is aiming. Measured against live bullet tracers (2026-09-27):
--   Head LookVector: 2-10 deg off in yaw, 6-31 deg off in pitch (weapon-hold animation) -> not used.
--   HumanoidRootPart yaw: within ~2 deg of the bullet's yaw, prone included.
--   HeadMovement state .aim (weapon muzzle direction in HRP space, via the HeadMovement bridge): exact,
--   but the game only holds it for ~5-8 nearby players, and only while a gun is up (not sprinting).
-- Far players' pitch never reaches this client, so for them the cone is level and checks compare yaw only.
local aimState, aimScanAt, aimMiss = nil, 0, nil
local function aimTable()
    if aimState then
        for _, v in pairs(aimState) do
            if type(v) == "table" and os.clock() - (v.up or 0) < 3 then return aimState end
        end
    end
    -- ponytail: a getgc scan is a hitch (~100 ms on Potassium, more on slower executors). The table persists once
    -- found, so rescans only happen while it's stale, backing off 15 s -> 30 -> 60 -> ... 5 min
    if not (CFG.memScans and HAS_GC) or os.clock() < aimScanAt then return aimState end
    aimMiss = math.min((aimMiss or 7.5) * 2, 300)
    aimScanAt = os.clock() + aimMiss
    for _, g in ipairs(getgc(false)) do
        if type(g) == "function" and islclosure(g) and debug.getinfo(g).name == "OnRemoteData" then
            local t = debug.getupvalue(g, 2)
            if type(t) == "table" then aimState = t; aimMiss = nil; break end
        end
    end
    return aimState
end

-- returns direction, exact (true = muzzle, false = body yaw with unknown pitch)
local function aimOf(pl, char, head, byPlr)
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return head.CFrame.LookVector, false end
    local e = byPlr[pl]
    if e and typeof(e.aim) == "Vector3" and e.aim.Magnitude > 0.5 and os.clock() - (e.up or 0) < 1.5 then
        return hrp.CFrame:VectorToWorldSpace(e.aim.Unit), true
    end
    local l = hrp.CFrame.LookVector
    return Vector3.new(l.X, 0, l.Z).Unit, false
end

-- how directly `look` points along d (1 = dead on); yaw only when the pitch is unknown
local function facing(look, d, exact)
    if exact then return look:Dot(d.Unit) end
    local flat = Vector3.new(d.X, 0, d.Z)
    if flat.Magnitude < 0.5 then return 1 end -- straight above/below them: can't rule it out
    return look:Dot(flat.Unit)
end

-- per-part line of sight from the camera, refreshed every 0.1 s (~15 parts x ~20 enemies of raycasts)
local visCache, visAt = {}, 0
local function partVisible(part, camPos, char)
    local v = visCache[part]
    if v == nil then
        v = clearLOS(camPos, part.Position, char)
        visCache[part] = v
    end
    return v
end

local function threats(warns, body, droneMain)
    local camPos = Workspace.CurrentCamera.CFrame.Position
    local len, range = CFG.coneLen / M, CFG.coneRange / M
    local cosA = math.cos(math.rad(CFG.coneAngle))
    local flying = droneMain ~= nil
    if os.clock() - visAt > 0.1 then visCache, visAt = {}, os.clock() end -- fresh table: never holds old parts
    local byPlr = {}
    for _, v in pairs(aimTable() or {}) do
        if type(v) == "table" and v.plr then byPlr[v.plr] = v end
    end
    for _, pl in ipairs(Players:GetPlayers()) do
        local char = isEnemy(pl) and pl.Character
        local head = char and char:FindFirstChild("Head")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if head and hum and hum.Health > 0 then
            local hp = head.Position
            local look, exact = aimOf(pl, char, head, byPlr)
            local hot, bestDot = false, -1 -- bestDot: how directly they face your body or drone (1 = dead on)
            for _, tgt in ipairs({ { body, "BODY" }, { droneMain, "DRONE" } }) do
                local part = tgt[1]
                if part then
                    local d = part.Position - hp
                    local dot = facing(look, d, exact)
                    bestDot = math.max(bestDot, dot)
                    if CFG.watchWarn and (exact or CFG.watchFacing) and d.Magnitude < len and dot > cosA
                        and (not CFG.watchLOS or clearLOS(hp, part.Position, char)) then
                        hot = true
                        warns[#warns + 1] = exact
                            and { 2, ("AIMING: %s at your %s (%dm)"):format(pl.Name, tgt[2], d.Magnitude * M) }
                            or { 1.5, ("FACING: %s toward your %s (%dm)"):format(pl.Name, tgt[2], d.Magnitude * M) }
                    end
                end
            end
            local camDist = (hp - camPos).Magnitude
            if CFG.esp and camDist < CFG.espRange / M then
                local b = Esp.get()
                b.Adornee = head
                b.T.Text = CFG.espNames and ("%s  %dm"):format(pl.Name, camDist * M) or ("%dm"):format(camDist * M)
                b.T.TextColor3, b.T.TextTransparency = COL.espText.c, COL.espText.t
                b.T.TextStrokeColor3, b.T.TextStrokeTransparency = COL.espStroke.c, COL.espStroke.t
            end
            if CFG.chams and camDist < CFG.chamsRange / M and CFG.chamsStyle == "Per part" then
                for _, part in ipairs(char:GetChildren()) do
                    if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and part.Transparency < 1 then
                        local f = CFG.chamsVisColor and partVisible(part, camPos, char) and COL.chamVis or COL.chamFill
                        local b = Boxes.get()
                        b.Adornee, b.Size = part, part.Size + Vector3.new(0.06, 0.06, 0.06)
                        b.Color3, b.Transparency, b.AlwaysOnTop = f.c, f.t, CFG.chamsWalls
                    end
                end
            elseif CFG.chams and camDist < CFG.chamsRange / M then
                local hl = Chams.get()
                local f = CFG.chamsVisColor and clearLOS(camPos, hp, char) and COL.chamVis or COL.chamFill
                hl.Adornee, hl.FillColor, hl.FillTransparency = char, f.c, f.t
                hl.OutlineColor, hl.OutlineTransparency = COL.chamLine.c, COL.chamLine.t
                hl.DepthMode = CFG.chamsWalls and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
            end
            if CFG.bodyGuard and body and (flying or not CFG.bodyOnlyFlying) then
                local d = (hp - body.Position).Magnitude
                if d < CFG.bodyRadius / M then
                    warns[#warns + 1] = { 3, ("ENEMY NEAR BODY: %s %dm"):format(pl.Name, d * M) }
                end
            end
            if CFG.cones and camDist < range then
                local key = hot and "coneHot" or "cone"
                if not hot and CFG.coneGradient then
                    -- 0 at gradAngle or wider off you (away color) -> 1 inside the cone half-angle (on-you color)
                    local ang = math.deg(math.acos(math.clamp(bestDot, -1, 1)))
                    local f = 1 - math.clamp((ang - CFG.coneAngle) / math.max(1, CFG.gradAngle - CFG.coneAngle), 0, 1)
                    local a, h = COL.coneAway, COL.coneHot
                    key = { c = a.c:Lerp(h.c, f), t = a.t + (h.t - a.t) * f }
                end
                line(hp, hp + look * len, key, hot and 3 or 2)
                coneEdges(hp, look, len, CFG.coneAngle, key, 0.3)
            end
        end
    end
end

local function enemyDrones(warns, body, droneMain)
    if not CFG.droneAlert then return end
    local team = myTeam()
    for _, m in ipairs(DroneWS:GetChildren()) do
        local main = m:FindFirstChild("Other") and m.Other:FindFirstChild("Main")
        if main and m:GetAttribute("Team") ~= team and not m.Name:find("^" .. lp.UserId .. "_") then
            local v = main.AssemblyLinearVelocity
            local best
            for _, tgt in ipairs({ { body, "BODY" }, { droneMain, "DRONE" } }) do
                local part = tgt[1]
                if part then
                    local d = part.Position - main.Position
                    local dist = d.Magnitude
                    if dist < CFG.droneRange / M and (not best or dist < best.dist) then
                        local closing = (v - part.AssemblyLinearVelocity):Dot(d.Unit)
                        best = { dist = dist, closing = closing, what = tgt[2] }
                    end
                end
            end
            if best then
                local kind = m:GetAttribute("DroneType") or "DRONE"
                local eta = best.closing > 1 and (" · ETA %.1fs"):format(best.dist / best.closing) or ""
                warns[#warns + 1] = { kind == "FPV" and 4 or 1, ("ENEMY %s (%s) %dm from your %s · %s %d m/s%s"):format(
                    kind, m:GetAttribute("OwnerName") or "?", best.dist * M, best.what,
                    best.closing > 0 and "closing" or "opening", math.abs(best.closing) * M, eta) }
                if CFG.droneHighlight then
                    local hl = Marks.get()
                    hl.Adornee, hl.FillColor, hl.FillTransparency = m, COL.drone.c, COL.drone.t
                    hl.OutlineColor, hl.OutlineTransparency = COL.droneLine.c, COL.droneLine.t
                    if v.Magnitude > 3 then line(main.Position, main.Position + v * 2, "droneVel", 2) end
                end
            end
        end
    end
end

-- ============================== loop ==============================
-- ============================== map ESP ==============================
-- PlayerScripts.TacticalMap keeps one view table per map widget (minimap + full in-match map):
-- {clip, cx, cz, spp (studs per pixel), rot, iconLayer, mates, ...}. Teammate dots are placed with its toView();
-- enemy dots below use the same math, in an overlay frame inside each view's clip.
local mapViews, mapScanAt, mapLayers, mapMiss = {}, 0, {}, nil
local function findMapViews()
    if not (CFG.memScans and HAS_GC) or os.clock() < mapScanAt then return end
    -- ponytail: getgc(true) is a one-off hitch; rescans only while no live view is known, backing off 10 s -> 5 min
    mapMiss = math.min((mapMiss or 5) * 2, 300)
    mapScanAt = os.clock() + mapMiss
    local found = {}
    for _, t in ipairs(getgc(true)) do
        if type(t) == "table" and rawget(t, "spp") and rawget(t, "mates") and rawget(t, "iconLayer")
            and typeof(rawget(t, "clip")) == "Instance" then
            found[#found + 1] = t
        end
    end
    mapViews = found
    if #found > 0 then mapMiss = nil end
end

local function mapLayer(v)
    local L = mapLayers[v]
    if L and L.frame.Parent then return L end
    local f = Instance.new("Frame")
    f.Name, f.BackgroundTransparency, f.Size, f.ZIndex = "WFEnemies", 1, UDim2.fromScale(1, 1), 5
    f.Parent = v.clip
    L = pool("Frame", { BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 6 }, function(d)
        Instance.new("UICorner", d).CornerRadius = UDim.new(1, 0)
        local n = Instance.new("TextLabel")
        n.Name, n.ZIndex, n.BackgroundTransparency, n.TextScaled = "N", 6, 1, true
        n.Size, n.AnchorPoint, n.Position = UDim2.new(0, 120, 0, 12), Vector2.new(0.5, 0), UDim2.new(0.5, 0, 1, 1)
        n.Font, n.TextStrokeTransparency = Enum.Font.GothamBold, 0.3
        n.Parent = d
    end, f)
    L.frame = f
    mapLayers[v] = L
    return L
end

-- Spawn/deploy map (PlayerScripts.SatelliteDeployMap): the real camera looks straight down and map tiles are
-- laid over it; its markers use Camera:WorldToViewportPoint. Active when workspace InMenu, CurrentWindow == "Map",
-- MapLoaded, and the camera points down (LookVector.Y <= -0.95).
local SpawnDots = pool("Frame", { BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 6 }, function(d)
    Instance.new("UICorner", d).CornerRadius = UDim.new(1, 0)
    local n = Instance.new("TextLabel")
    n.Name, n.ZIndex, n.BackgroundTransparency, n.TextScaled = "N", 6, 1, true
    n.Size, n.AnchorPoint, n.Position = UDim2.new(0, 120, 0, 12), Vector2.new(0.5, 0), UDim2.new(0.5, 0, 1, 1)
    n.Font, n.TextStrokeTransparency = Enum.Font.GothamBold, 0.3
    n.Parent = d
end, screen)

local function spawnMapEsp()
    if not (CFG.mapEsp and CFG.mapSpawn and Workspace:GetAttribute("InMenu") == true
        and Workspace:GetAttribute("CurrentWindow") == "Map" and Workspace:GetAttribute("MapLoaded") == true) then return end
    local cam = Workspace.CurrentCamera
    if cam.CFrame.LookVector.Y > -0.95 then return end
    local function put(pos, col, text, size)
        local v, on = cam:WorldToViewportPoint(pos)
        if not on then return end
        local d = SpawnDots.get()
        d.Position, d.Size = UDim2.fromOffset(v.X, v.Y), UDim2.fromOffset(size, size)
        d.BackgroundColor3, d.BackgroundTransparency = col.c, col.t
        d.N.Text, d.N.TextColor3, d.N.Visible = text, col.c, CFG.mapNames and text ~= ""
    end
    for _, pl in ipairs(Players:GetPlayers()) do
        local char = isEnemy(pl) and pl.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hrp and hum and hum.Health > 0 then put(hrp.Position, COL.mapDot, pl.DisplayName:upper(), CFG.mapDotSize) end
    end
    if CFG.mapDrones then
        local team = myTeam()
        for _, m in ipairs(DroneWS:GetChildren()) do
            local main = m:FindFirstChild("Other") and m.Other:FindFirstChild("Main")
            if main and m:GetAttribute("Team") ~= team then put(main.Position, COL.mapDrone, "", CFG.mapDotSize + 2) end
        end
    end
end

local function mapEsp()
    local live = #mapViews > 0
    for _, v in ipairs(mapViews) do
        if not v.clip.Parent then live = false end
    end
    if not live then findMapViews() end
    if not CFG.mapEsp then return end
    local team = myTeam()
    for _, v in ipairs(mapViews) do
        local L = mapLayer(v)
        local w, h = math.max(v.clip.AbsoluteSize.X, 1), math.max(v.clip.AbsoluteSize.Y, 1)
        local c, sn = math.cos(v.rot or 0), math.sin(v.rot or 0)
        local function put(pos, col, text, size)
            -- TacticalMap.toView
            local x, y = (pos.X - v.cx) / v.spp, (pos.Z - v.cz) / v.spp
            x, y = w / 2 + x * c - y * sn, h / 2 + x * sn + y * c
            if x < -8 or y < -8 or x > w + 8 or y > h + 8 then return end
            local d = L.get()
            d.Position, d.Size = UDim2.fromScale(x / w, y / h), UDim2.fromOffset(size, size)
            d.BackgroundColor3, d.BackgroundTransparency = col.c, col.t
            d.N.Text, d.N.TextColor3 = text, col.c
            d.N.Visible = CFG.mapNames and text ~= "" and v.spp < 2.2 -- same zoom rule as the game's teammate names
        end
        for _, pl in ipairs(Players:GetPlayers()) do
            local char = isEnemy(pl) and pl.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hrp and hum and hum.Health > 0 then put(hrp.Position, COL.mapDot, pl.DisplayName:upper(), CFG.mapDotSize) end
        end
        if CFG.mapDrones then
            for _, m in ipairs(DroneWS:GetChildren()) do
                local main = m:FindFirstChild("Other") and m.Other:FindFirstChild("Main")
                if main and m:GetAttribute("Team") ~= team then put(main.Position, COL.mapDrone, "", CFG.mapDotSize + 2) end
            end
        end
    end
end

-- ============================== aim zoom ==============================
-- Real camera zoom while aiming (right mouse held with a gun out). Roblox has one camera, so the whole view zooms;
-- the ring marks the center and the optional dim darkens outside it. Each frame takes whatever FOV the game set
-- (equip, its own ADS tween) and narrows it; hands the game's FOV back when released.
local UIS = game:GetService("UserInputService")
local zoomNow, zoomBase, zoomSet = 1, nil, nil
local baseSens = UIS.MouseDeltaSensitivity -- the game never writes this (grep), so it's ours to scale

local function zoomStep(dt)
    local cam = Workspace.CurrentCamera
    local char = lp.Character
    local want = CFG.aimZoom and UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
        and char and char:FindFirstChildOfClass("Tool") ~= nil and lp:GetAttribute("InDrone") ~= true
        and Workspace:GetAttribute("InMenu") ~= true and not UIS:GetFocusedTextBox()
    local target = want and CFG.zoomLevel or 1
    zoomNow += (target - zoomNow) * (1 - math.exp(-CFG.zoomSpeed * dt))
    if math.abs(zoomNow - target) < 0.01 then zoomNow = target end
    if zoomNow > 1.001 then
        -- FieldOfView is stored as float32: compare with a tolerance or our own write reads as "the game changed it"
        if not zoomSet or math.abs(cam.FieldOfView - zoomSet) > 0.01 then zoomBase = cam.FieldOfView end
        zoomSet = 2 * math.deg(math.atan(math.tan(math.rad(zoomBase) / 2) / zoomNow))
        cam.FieldOfView = zoomSet
        UIS.MouseDeltaSensitivity = CFG.zoomSens and baseSens / zoomNow or baseSens
    elseif zoomSet then
        if math.abs(cam.FieldOfView - zoomSet) <= 0.01 then cam.FieldOfView = zoomBase end
        zoomSet, zoomBase = nil, nil
        UIS.MouseDeltaSensitivity = baseSens
    end
    local on = zoomNow > 1.001
    local size = UDim2.fromScale(CFG.zoomSize / 100, CFG.zoomSize / 100)
    zoomRingFrame.Visible, zoomRingFrame.Size = on and CFG.zoomRing, size
    zoomRingStroke.Color, zoomRingStroke.Transparency = COL.zoomRing.c, COL.zoomRing.t
    zoomDimFrame.Visible, zoomDimFrame.Size = on and COL.zoomDim.t < 1, size
    zoomDimStroke.Color, zoomDimStroke.Transparency = COL.zoomDim.c, COL.zoomDim.t
end

local errs = {} -- feature -> last error; also appended to WarfareHUD/errors.txt once per distinct message
local function guard(name, f, ...)
    local ok, err = pcall(f, ...)
    if not ok and errs[name] ~= err then
        errs[name] = err
        local msg, path = os.date("%H:%M:%S ") .. name .. ": " .. tostring(err) .. "\n", "WarfareHUD/errors.txt"
        pcall(function()
            if not isfolder("WarfareHUD") then makefolder("WarfareHUD") end
            if isfile(path) then appendfile(path, msg) else writefile(path, msg) end
        end)
    end
end

local filterChar
Run:BindToRenderStep("WarfareAimZoom", 999, function(dt) guard("aimZoom", zoomStep, dt) end)

table.insert(conns, Run.RenderStepped:Connect(function()
    local char = lp.Character
    if char ~= filterChar then filterChar = char; refreshFilter(char) end
    local body = char and char:FindFirstChild("HumanoidRootPart")
    local m, droneMain = myDrone()
    local warns = {}
    infoLabel.Text = ""
    if m then guard("predictor", predictor, m, droneMain) end
    guard("threats", threats, warns, body, droneMain)
    guard("enemyDrones", enemyDrones, warns, body, droneMain)
    guard("mapEsp", mapEsp)
    guard("spawnMapEsp", spawnMapEsp)
    table.sort(warns, function(a, b) return a[1] > b[1] end)
    local out = {}
    for i = 1, math.min(#warns, 5) do out[i] = warns[i][2] end
    warnLabel.Text = table.concat(out, "\n")
    warnLabel.TextColor3, warnLabel.TextTransparency = COL.warnText.c, COL.warnText.t
    infoLabel.TextColor3, infoLabel.TextTransparency = COL.infoText.c, COL.infoText.t
    for _, l in ipairs({ warnLabel, infoLabel }) do
        l.TextStrokeColor3, l.TextStrokeTransparency = COL.hudStroke.c, COL.hudStroke.t
    end
    for _, pl in ipairs(pools) do pl.flush() end
end))

local Library
local function unload()
    if getgenv().WARFARE_HUD == nil then return end
    getgenv().WARFARE_HUD = nil
    for _, c in ipairs(conns) do c:Disconnect() end
    for _, b in ipairs(Esp.list) do b:Destroy() end
    for _, L in pairs(mapLayers) do L.frame:Destroy() end
    pcall(Run.UnbindFromRenderStep, Run, "WarfareAimZoom")
    if zoomSet then Workspace.CurrentCamera.FieldOfView = zoomBase end
    UIS.MouseDeltaSensitivity = baseSens
    root:Destroy(); screen:Destroy()
    if Library then pcall(Library.Unload, Library) end
end
getgenv().WARFARE_HUD = { unload = unload, cfg = CFG, learnedR = learnedR, errs = errs, aimOf = aimOf, aimTable = aimTable,
    mapViews = function() return mapViews end }

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
    Title = "Warfare Drone HUD", Footer = "predict · blast · cones · body · drones",
    Center = true, AutoShow = true, ToggleKeybind = Enum.KeyCode.RightControl,
})
local Tabs = {
    Drone    = Window:AddTab("Drone"),
    Threats  = Window:AddTab("Threats"),
    Aim      = Window:AddTab("Aim"),
    Colors   = Window:AddTab("Colors"),
    Settings = Window:AddTab("Settings"),
}

local function toggle(box, idx, key, text, tip)
    box:AddToggle(idx, { Text = text, Tooltip = tip, Default = CFG[key], Callback = function(v) CFG[key] = v end })
end
local function slider(box, idx, key, text, min, max, suffix, tip)
    box:AddSlider(idx, { Text = text, Tooltip = tip, Default = CFG[key], Min = min, Max = max, Rounding = 0,
        Suffix = suffix, Callback = function(v) CFG[key] = v end })
end

local Pred = Tabs.Drone:AddLeftGroupbox("Impact predictor")
Pred:AddLabel("MAVIC: grenade drop arc (gravity, inherits drone velocity, like the game's own ring but longer). FPV: straight line along your velocity. First impact only: an M67 can still roll.", true)
toggle(Pred, "WF_Predict", "predict", "Show predictor")
slider(Pred, "WF_Horizon", "horizon", "Look-ahead", 2, 15, "s")
local Blast = Tabs.Drone:AddRightGroupbox("Blast rings")
Blast:AddLabel("Orange = blast edge (r). Red = one-shot (>= 100 dmg). Dark = full damage (r/4). Shrapnel and walls not modelled.", true)
toggle(Blast, "WF_Rings", "rings", "Show blast rings")

local Cones = Tabs.Threats:AddLeftGroupbox("Enemy aim cones")
toggle(Cones, "WF_Cones", "cones", "Draw aim cones")
slider(Cones, "WF_ConeLen", "coneLen", "Cone length", 10, 300, "m")
slider(Cones, "WF_ConeAngle", "coneAngle", "Cone half-angle", 2, 25, "°", "Also the WATCHED threshold")
slider(Cones, "WF_ConeRange", "coneRange", "Draw for enemies within", 20, 600, "m", "Distance from your camera")
Cones:AddLabel("Nearby enemies with a gun up: exact muzzle direction (AIMING). Others: body facing, level cone, yaw only (FACING); the game never sends their pitch.", true)
toggle(Cones, "WF_Watch", "watchWarn", "Aim warning", "When an enemy points at your body or drone within cone length")
toggle(Cones, "WF_WatchFacing", "watchFacing", "Also warn on FACING (pitch unknown)", "Yaw-only matches for far enemies; noisy when your drone hovers right above them")
toggle(Cones, "WF_WatchLOS", "watchLOS", "Require line of sight", "Skip warnings through walls")
toggle(Cones, "WF_ConeGrad", "coneGradient", "Color by aim",
    "Blend from 'looking away' to 'on you' as their aim swings toward your body or drone. Colors and opacity: Colors tab")
slider(Cones, "WF_GradAngle", "gradAngle", "Fully 'away' at", 15, 180, "°", "Angle off you where the cone is fully the away color")

local EspBox = Tabs.Threats:AddLeftGroupbox("ESP")
toggle(EspBox, "WF_Esp", "esp", "Enemy ESP", "Name + distance over each enemy's head, through walls")
toggle(EspBox, "WF_EspNames", "espNames", "Show names")
slider(EspBox, "WF_EspRange", "espRange", "Max distance", 25, 1500, "m", "From your camera (your drone while flying)")

local ChamBox = Tabs.Threats:AddLeftGroupbox("Chams")
toggle(ChamBox, "WF_Chams", "chams", "Enemy chams", "Colored body highlight. Colors and opacity: Colors tab")
toggle(ChamBox, "WF_ChamsWalls", "chamsWalls", "Show through walls")
ChamBox:AddDropdown("WF_ChamsStyle", {
    Text = "Style", Values = { "Per part", "Highlight" }, Default = CFG.chamsStyle,
    Tooltip = "Per part: a box on each body part, colored by that part's own line of sight (no outline). Highlight: body-shaped glow + outline, one color for the whole body (by head line of sight)",
    Callback = function(v) CFG.chamsStyle = v end,
})
toggle(ChamBox, "WF_ChamsVis", "chamsVisColor", "Different color when in sight", "Line of sight from your camera to each part (or the head, in Highlight style)")
slider(ChamBox, "WF_ChamsRange", "chamsRange", "Max distance", 25, 1500, "m")

local Body = Tabs.Threats:AddRightGroupbox("Body guard")
toggle(Body, "WF_Body", "bodyGuard", "Warn: enemy near body")
slider(Body, "WF_BodyR", "bodyRadius", "Radius", 5, 60, "m")
toggle(Body, "WF_BodyFly", "bodyOnlyFlying", "Only while flying a drone")

local Zoom = Tabs.Aim:AddLeftGroupbox("Aim zoom")
Zoom:AddLabel("Hold right mouse with a gun out to zoom. Roblox has one camera, so the whole view zooms; the ring marks the center (dim outside it in the Colors tab).", true)
toggle(Zoom, "WF_AimZoom", "aimZoom", "Aim zoom")
Zoom:AddSlider("WF_ZoomLevel", { Text = "Zoom", Default = CFG.zoomLevel, Min = 1.5, Max = 8, Rounding = 1, Suffix = "x",
    Callback = function(v) CFG.zoomLevel = v end })
slider(Zoom, "WF_ZoomSize", "zoomSize", "Ring size", 10, 90, "% of screen height")
slider(Zoom, "WF_ZoomSpeed", "zoomSpeed", "Zoom speed", 4, 40, "")
toggle(Zoom, "WF_ZoomRing", "zoomRing", "Show ring")
toggle(Zoom, "WF_ZoomSens", "zoomSens", "Lower mouse sensitivity while zoomed", "Divides sensitivity by the zoom so aiming feels the same")

local MapBox = Tabs.Threats:AddRightGroupbox("Map ESP")
MapBox:AddLabel("Enemy dots on the in-match map and the minimap, placed with the map's own math.", true)
toggle(MapBox, "WF_MapEsp", "mapEsp", "Enemies on map")
toggle(MapBox, "WF_MapNames", "mapNames", "Names when zoomed in", "Same zoom level where the game shows teammate names")
toggle(MapBox, "WF_MapDrones", "mapDrones", "Enemy drones on map")
toggle(MapBox, "WF_MapSpawn", "mapSpawn", "Also on the spawn map", "Deploy screen overhead map")
slider(MapBox, "WF_MapDot", "mapDotSize", "Dot size", 3, 16, "px")

local Drones = Tabs.Threats:AddRightGroupbox("Enemy drones")
toggle(Drones, "WF_DroneAlert", "droneAlert", "Enemy drone alert", "Distance, closing speed and ETA to your body or drone")
slider(Drones, "WF_DroneRange", "droneRange", "Alert range", 20, 300, "m")
toggle(Drones, "WF_DroneHL", "droneHighlight", "Highlight + velocity line")

local colorBoxes = {}
for i, g in ipairs(COL_GROUPS) do
    colorBoxes[g] = i % 2 == 1 and Tabs.Colors:AddLeftGroupbox(g) or Tabs.Colors:AddRightGroupbox(g)
end
colorBoxes.Predictor:AddLabel("Click a swatch. The bar on the picker's right sets transparency.", true)
for _, key in ipairs(COL_ORDER) do
    local col, idx = COL[key], "WF_Col_" .. key
    colorBoxes[col.group]:AddLabel(col.name):AddColorPicker(idx, {
        Default = col.c, Transparency = col.t, Title = col.name,
        Callback = function(c)
            col.c = c
            local opt = Library.Options[idx]
            if opt then col.t = opt.Transparency end
        end,
    })
end

colorBoxes["HUD text"]:AddButton({ Text = "Reset all colors", Func = function()
    for _, key in ipairs(COL_ORDER) do
        local col, opt = COL[key], Library.Options["WF_Col_" .. key]
        if opt then opt:SetValueRGB(col.c0, col.t0) end
        col.c, col.t = col.c0, col.t0
    end
end })

local Compat = Tabs.Settings:AddRightGroupbox("Executor compatibility")
Compat:AddLabel(HAS_GC and "Memory scans available (getgc / debug.getupvalue)." or
    "This executor has no getgc / debug.getupvalue: muzzle aim and in-match map dots are off (spawn map dots still work).", true)
toggle(Compat, "WF_MemScans", "memScans", "Memory scans (muzzle aim, in-match map ESP)",
    "Reads game memory with getgc. Turn off if your executor freezes or acts up; cones fall back to body facing")

local Menu = Tabs.Settings:AddLeftGroupbox("Menu")
Menu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })
Library:OnUnload(unload)
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetFolder("WarfareHUD")
ThemeManager:SetFolder("WarfareHUD")
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:LoadAutoloadConfig()
Library:Notify("Warfare Drone HUD ready — RightCtrl toggles the UI.", 4)
