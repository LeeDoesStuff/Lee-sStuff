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
    aimZoom = false, zoomLevel = 3, zoomSize = 35, zoomSpeed = 14, zoomSens = true,
    droneDot = true, droneDotAimOnly = false, droneDotRange = 150, droneDotSize = 8, droneDotLine = true,
    hitMarker = true, hitMarkerSize = 22, droneDotArea = true,
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
    zoomDim   = { c = Color3.fromRGB(0, 0, 0),       t = 1,    name = "Zoom: outside the ring (1 = no dim)", group = "Aim zoom" },
    leadDot   = { c = Color3.fromRGB(170, 255, 0),   t = 0,    name = "Drone aim dot (lead)",      group = "Enemy drones" },
    leadLine  = { c = Color3.fromRGB(170, 255, 0),   t = 0.5,  name = "Drone -> aim dot line",     group = "Enemy drones" },
    leadArea  = { c = Color3.fromRGB(170, 255, 0),   t = 0.7,  name = "Drone hit area (at the lead)", group = "Enemy drones" },
    hitMark   = { c = Color3.fromRGB(255, 255, 255), t = 0,    name = "Drone hit marker",          group = "Enemy drones" },
    killMark  = { c = Color3.fromRGB(255, 50, 50),   t = 0,    name = "Drone kill marker",         group = "Enemy drones" },
}
local COL_ORDER = { "arc", "edge", "lethal", "core", "cone", "coneHot", "coneAway", "espText", "espStroke", "chamFill", "chamVis",
    "chamLine", "drone", "droneLine", "droneVel", "warnText", "infoText", "hudStroke", "mapDot", "mapDrone", "zoomDim", "leadDot", "leadLine", "leadArea", "hitMark", "killMark" }
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
local zoomNow, zoomSet = 1, nil
local baseSens = UIS.MouseDeltaSensitivity -- the game never writes this (grep), so it's ours to scale
local TweenService = game:GetService("TweenService")
local instant = TweenInfo.new(0)

-- The game's ADS tween (Core FOV setter) writes FieldOfView after our render step, so the view flipped between
-- its value and ours every frame. While we own the zoom: re-apply ours the moment anything else writes it, and
-- play a 0 s tween on the same property, which makes Roblox cancel the game's running FOV tween.
local zoomCam = Workspace.CurrentCamera
table.insert(conns, zoomCam:GetPropertyChangedSignal("FieldOfView"):Connect(function()
    -- float32 property: compare with a tolerance, or our own write looks foreign
    if zoomSet and math.abs(zoomCam.FieldOfView - zoomSet) > 0.01 then zoomCam.FieldOfView = zoomSet end
end))

local function baseFov()
    -- ponytail: zoom is relative to the player's FOV setting, not the game's in-flight ADS value (that fed back
    -- into itself); the game's own ~1.2x ADS narrowing is replaced by ours while zoomed
    return math.clamp(tonumber(Workspace:GetAttribute("FieldOfView")) or 80, 20, 120)
end

local function zoomStep(dt)
    local cam = Workspace.CurrentCamera
    local char = lp.Character
    local want = CFG.aimZoom and UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
        and char and char:FindFirstChildOfClass("Tool") ~= nil and lp:GetAttribute("InDrone") ~= true
        and Workspace:GetAttribute("InMenu") ~= true and not UIS:GetFocusedTextBox()
    local target = want and CFG.zoomLevel or 1
    zoomNow += (target - zoomNow) * (1 - math.exp(-CFG.zoomSpeed * dt))
    if math.abs(zoomNow - target) < 0.005 then zoomNow = target end
    if zoomNow > 1 or zoomSet then
        local base = baseFov()
        local fov = 2 * math.deg(math.atan(math.tan(math.rad(base) / 2) / zoomNow))
        if zoomSet and math.abs(cam.FieldOfView - zoomSet) > 0.01 then
            TweenService:Create(cam, instant, { FieldOfView = fov }):Play() -- cancels the game's FOV tween
        end
        zoomSet = fov
        cam.FieldOfView = fov
        UIS.MouseDeltaSensitivity = CFG.zoomSens and baseSens / zoomNow or baseSens
        if zoomNow <= 1 then -- fully back out: hand the camera back to the game at the player's FOV
            zoomSet = nil
            cam.FieldOfView = base
            UIS.MouseDeltaSensitivity = baseSens
        end
    end
    local on = zoomNow > 1
    local size = UDim2.fromScale(CFG.zoomSize / 100, CFG.zoomSize / 100)
    zoomDimFrame.Visible, zoomDimFrame.Size = on and COL.zoomDim.t < 1, size
    zoomDimStroke.Color, zoomDimStroke.Transparency = COL.zoomDim.c, COL.zoomDim.t
end

-- ============================== enemy drone aim dot ==============================
-- Where to put your sights so the bullet meets a moving enemy drone. Game ballistics (Framework.Modules.BulletSimulator):
-- gravity 35.04 studs/s^2, launch speed = the weapon's SettingsGun.BSpeed (server-sent; e.g. SVD 2554, AK-74 ~3000,
-- AS Val ~1000), sights zeroed at SettingsGun.ZeroDistance or 357 studs (launch angle atan(0.5*g*Z/v^2) up).
local BULLET_G = 35.04
-- G1 drag table {Mach, Cd} copied from BulletSimulator (u29); every BulletData ammo type uses G1 (none sets DragModel)
local G1 = { {0,0.2629},{0.05,0.2558},{0.1,0.2487},{0.15,0.2413},{0.2,0.2344},{0.25,0.2278},{0.3,0.2214},{0.35,0.2155},
    {0.4,0.2104},{0.45,0.2061},{0.5,0.2032},{0.55,0.202},{0.6,0.2034},{0.65,0.2165},{0.7,0.223},{0.75,0.2313},{0.8,0.2417},
    {0.85,0.2546},{0.875,0.2706},{0.9,0.2866},{0.925,0.3091},{0.95,0.3379},{0.975,0.3785},{1,0.4032},{1.025,0.4147},
    {1.05,0.4201},{1.075,0.4278},{1.1,0.4338},{1.125,0.4373},{1.15,0.4392},{1.2,0.4403},{1.25,0.4406},{1.3,0.4401},
    {1.35,0.4386},{1.4,0.4362},{1.45,0.4328},{1.5,0.4286},{1.55,0.4237},{1.6,0.4182},{1.65,0.4121},{1.7,0.4057},
    {1.75,0.3991},{1.8,0.3926},{1.85,0.3861},{1.9,0.38},{1.95,0.3741},{2,0.3684},{2.05,0.363},{2.1,0.3578},{2.15,0.3529},
    {2.2,0.3481},{2.25,0.3435},{2.3,0.3391},{2.35,0.3349},{2.4,0.3269},{2.5,0.3147},{2.6,0.3049},{2.7,0.2956},{2.8,0.288},
    {2.9,0.2809},{3,0.2725},{3.5,0.2449},{4,0.2257},{4.5,0.2108},{5,0.2003} }
local function g1Cd(mach)
    if mach <= G1[1][1] then return G1[1][2] end
    for i = 2, #G1 do
        if mach <= G1[i][1] then
            local a, b = G1[i - 1], G1[i]
            return a[2] + (b[2] - a[2]) * (mach - a[1]) / (b[1] - a[1])
        end
    end
    return G1[#G1][2]
end
-- BulletSimulator air model: ISA temperature lapse by altitude (studs * 0.28 = m), density, speed of sound
local AIR_M, AIR_R, LAPSE, T0 = 0.0289644, 8.31447, 0.0065, 288.15
local RHO_EXP, M_OVER_R, GAMMA_R = 9.80665 * AIR_M / (AIR_R * LAPSE), AIR_M / AIR_R, 1.4 * AIR_R / AIR_M
local function ammoData(t) -- BulletSimulator.BuildBulletData
    local mass, bc, cal = tonumber(t.Mass) or 0.004, tonumber(t.Drag) or 0.295, tonumber(t.Caliber) or 0.00556
    return { mass = mass, cross = math.pi * (cal * 0.5) ^ 2, form = mass / (703.0674 * bc * cal * cal) }
end
local GRAV = Vector3.new(0, -BULLET_G, 0)
local function accel(pos, vel, bd)
    if not bd then return GRAV end
    local sp = vel.Magnitude
    if sp <= 1 then return GRAV end
    local T = T0 - LAPSE * (pos.Y > 0 and pos.Y * 0.28 or 0)
    local rho = 101325 * (T / T0) ^ RHO_EXP * M_OVER_R / T
    local cd = g1Cd(sp * 0.28 / math.sqrt(T * GAMMA_R))
    return GRAV - vel * (0.5 * rho * (sp * 0.28) * cd * bd.cross * bd.form / bd.mass)
end
-- Fly a bullet from origin with velocity v0 until it has gone `dist` along u; returns time and position there.
local STEP = 1 / 240
local function fly(origin, v0, u, dist, bd)
    local pos, vel, t = origin, v0, 0
    while t < 3 do
        local a = accel(pos, vel, bd)
        local np = pos + vel * STEP + a * (0.5 * STEP * STEP)
        local nd = (np - origin):Dot(u)
        if nd >= dist then
            local pd = (pos - origin):Dot(u)
            local f = (dist - pd) / math.max(nd - pd, 1e-6)
            return t + STEP * f, pos:Lerp(np, f)
        end
        pos, vel, t = np, vel + a * STEP, t + STEP
    end
    return nil
end
-- Where to put your sights so the bullet meets a target at p moving at vel. The game launches along the sights
-- pitched up by its zero angle atan(0.5*g*Z/v^2); this flies that bullet with gravity + drag and corrects the aim
-- point by the miss until they meet. bd = nil -> no drag.
local function leadPoint(origin, p, vel, v, zeroD, bd)
    -- ponytail: assumes the drone keeps its velocity (no acceleration); spin drift / transonic wobble ignored
    local theta = math.atan(0.5 * BULLET_G * zeroD / (v * v))
    local q, t = p, 0
    for _ = 1, 4 do
        local u = (q - origin).Unit
        local up = math.abs(u.Y) > 0.99 and Vector3.xAxis or Vector3.yAxis
        local w = (CFrame.lookAt(origin, origin + u, up) * CFrame.Angles(theta, 0, 0)).LookVector
        local tt, b = fly(origin, w * v, u, (q - origin).Magnitude, bd)
        if not tt then return nil end
        t = tt
        q += (p + vel * t) - b
    end
    return q, t
end
do -- self-checks: vacuum matches the closed form (still target 100 studs, v=1000: -0.45; moving 10 studs/s: ~1 stud);
   -- drag makes a real round slower (7.62x54mmR-like at 2554 studs/s needs more time than vacuum over 400 studs)
    local a = leadPoint(Vector3.zero, Vector3.new(0, 0, -100), Vector3.zero, 1000, 357)
    local b = leadPoint(Vector3.zero, Vector3.new(0, 0, -100), Vector3.new(10, 0, 0), 1000, 357)
    assert(math.abs(a.Y + 0.45) < 0.02 and math.abs(b.X - 1.0) < 0.03, "leadPoint vacuum self-check")
    local bd = ammoData({ Mass = 0.0096, Caliber = 0.00782, Drag = 0.4 })
    local _, tv = leadPoint(Vector3.zero, Vector3.new(0, 0, -400), Vector3.zero, 2554, 357)
    local _, td = leadPoint(Vector3.zero, Vector3.new(0, 0, -400), Vector3.zero, 2554, 357, bd)
    assert(td > tv * 1.01 and td < tv * 1.5, "leadPoint drag self-check")
end

-- bullet speed: exact from the weapon client's Assets table (memory scan), else learned from your own tracers
local weaponAssets, assetsScanAt, assetsMiss, assetsWrongSince = nil, 0, nil, nil
local ammoTypes, ammoCache = nil, {} -- BulletSimulator.BulletData.Types (per-ammo Mass/Caliber/Drag), from the same scan
local ownSpeeds, bulletSeen, learnAt = {}, {}, 0
local function learnOwnSpeed(toolName)
    -- ponytail: median of your own tracer speeds per weapon (BulletPool parts, 30 Hz); only runs without memory scans
    local now = os.clock()
    if now < learnAt then return end
    learnAt = now + 1 / 30
    local head = lp.Character and lp.Character:FindFirstChild("Head")
    local pool = Workspace:FindFirstChild("BulletPool")
    if not (head and pool) then return end
    for _, b in ipairs(pool:GetChildren()) do
        if b:IsA("BasePart") then
            local prev, pos = bulletSeen[b], b.Position
            local d = prev and (pos - prev.p).Magnitude or 0
            if prev and not prev.done and d > 5 and d < 3000 then
                local dir = (pos - prev.p).Unit
                local rel = head.Position - prev.p
                local along = rel:Dot(dir)
                if along < 2 and along > -200 and (rel - dir * along).Magnitude < 2 then
                    local l = ownSpeeds[toolName] or {}
                    l[#l + 1] = d / (now - prev.t)
                    if #l > 15 then table.remove(l, 1) end
                    ownSpeeds[toolName] = l
                end
            end
            bulletSeen[b] = { p = pos, t = now, done = prev and (prev.done or d > 5) and d > 1 }
        end
    end
end
local function bulletSpeed(tool)
    if CFG.memScans and HAS_GC then
        local gm = weaponAssets and rawget(weaponAssets, "GunModel")
        local match = gm and typeof(gm) == "Instance" and gm.Name == tool.Name
        if match then assetsWrongSince = nil else assetsWrongSince = assetsWrongSince or os.clock() end
        -- rescan only when nothing is cached, or it has pointed at another gun for 5 s (e.g. a new life's table)
        if (not weaponAssets or not ammoTypes or os.clock() - (assetsWrongSince or math.huge) > 5) and os.clock() >= assetsScanAt then
            assetsMiss = math.min((assetsMiss or 2.5) * 2, 120)
            assetsScanAt = os.clock() + assetsMiss
            for _, t in ipairs(getgc(true)) do
                if type(t) == "table" then
                    if rawget(t, "SettingsGun") ~= nil and rawget(t, "GunModel") ~= nil then
                        weaponAssets = t
                        assetsMiss = nil
                    elseif type(rawget(t, "Types")) == "table" and rawget(t, "DamageScale") ~= nil then
                        ammoTypes = rawget(t, "Types")
                    end
                    if weaponAssets and ammoTypes then break end
                end
            end
        end
        local sg = match and rawget(weaponAssets, "SettingsGun")
        if type(sg) == "table" and tonumber(sg.BSpeed) then
            local ammo = sg.BulletType
            local bd = ammoCache[ammo]
            if bd == nil and ammoTypes and type(ammoTypes[ammo]) == "table" then
                bd = ammoData(ammoTypes[ammo])
                ammoCache[ammo] = bd
            end
            return tonumber(sg.BSpeed), tonumber(sg.ZeroDistance) or 357,
                bd and ("%s, drag on"):format(tostring(ammo)) or "weapon settings, no ammo data", bd
        end
    else
        learnOwnSpeed(tool.Name)
    end
    -- memory scans on but this gun's settings not matched yet (mid-equip): wait up to 5 s rather than guess
    if CFG.memScans and HAS_GC and os.clock() - (assetsWrongSince or 0) < 5 then
        return nil, nil, "loading this gun's settings..."
    end
    learnOwnSpeed(tool.Name) -- also covers memory scans that never find this gun (throttled to 30 Hz)
    local l = ownSpeeds[tool.Name]
    if l and #l >= 3 then
        local c = table.clone(l)
        table.sort(c)
        return c[math.ceil(#c / 2)], 357, ("learned from %d shots"):format(#l)
    end
    return nil, nil, "unknown: fire a few shots to learn it (dot hidden until then)"
end

local LeadDots = pool("Frame", { BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 8 }, function(d)
    Instance.new("UICorner", d).CornerRadius = UDim.new(1, 0)
    local st = Instance.new("UIStroke")
    st.Thickness, st.Color, st.Parent = 1, Color3.new(0, 0, 0), d
end, screen)
local LeadLines = pool("Frame", { BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 7 }, nil, screen)
local LeadAreas = pool("Frame", { BorderSizePixel = 0, ZIndex = 6 }, function(d)
    Instance.new("UICorner", d).CornerRadius = UDim.new(0, 3)
end, screen)

-- On-screen area a bullet can hit: the drone's DroneHitbox parts (bullets only register on those; measured FPV
-- DroneBase 3x1x4 + Warhead 1x1x4, MAVIC DroneBase 2.5x1x2.5 studs) moved to the lead point and projected.
-- ponytail: screen-space bounding box of the corners; slightly generous at the corners of a tilted plate
local CORNERS = {}
for _, x in ipairs({ -0.5, 0.5 }) do for _, y in ipairs({ -0.5, 0.5 }) do for _, z in ipairs({ -0.5, 0.5 }) do
    CORNERS[#CORNERS + 1] = Vector3.new(x, y, z)
end end end
local function hitArea(cam, m, shift)
    local x0, y0, x1, y1
    for _, d in ipairs(m:GetDescendants()) do
        if d:IsA("BasePart") and d:GetAttribute("DroneHitbox") ~= nil then
            local cf = d.CFrame + shift
            for _, c in ipairs(CORNERS) do
                local sp, on = cam:WorldToViewportPoint(cf * (c * d.Size))
                if not on then return nil end
                x0, y0 = math.min(x0 or sp.X, sp.X), math.min(y0 or sp.Y, sp.Y)
                x1, y1 = math.max(x1 or sp.X, sp.X), math.max(y1 or sp.Y, sp.Y)
            end
        end
    end
    return x0 and { x0, y0, x1, y1 }
end
local leadStatus = "no gun equipped"

local function droneLead()
    if not CFG.droneDot then return end
    local char = lp.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    if not tool then leadStatus = "no gun equipped"; return end
    if lp:GetAttribute("InDrone") == true then return end
    local v, zeroD, src, bd = bulletSpeed(tool)
    if not v then leadStatus = ("%s: %s"):format(tool.Name, src); return end -- no guessed dot
    leadStatus = ("%s: %d studs/s (%s)"):format(tool.Name, v, src)
    if CFG.droneDotAimOnly and not UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then return end
    local cam = Workspace.CurrentCamera
    local origin, team = cam.CFrame.Position, myTeam()
    for _, m in ipairs(DroneWS:GetChildren()) do
        local main = m:FindFirstChild("Other") and m.Other:FindFirstChild("Main")
        if main and m:GetAttribute("Team") ~= team and (main.Position - origin).Magnitude < CFG.droneDotRange / M then
            local aim = leadPoint(origin, main.Position, main.AssemblyLinearVelocity, v, zeroD, bd)
            local s, on
            if aim then s, on = cam:WorldToViewportPoint(aim) end
            local box = on and CFG.droneDotArea and hitArea(cam, m, aim - main.Position)
            if box then
                local a = LeadAreas.get()
                a.Position, a.Size = UDim2.fromOffset(box[1], box[2]), UDim2.fromOffset(box[3] - box[1], box[4] - box[2])
                a.BackgroundColor3, a.BackgroundTransparency = COL.leadArea.c, COL.leadArea.t
            end
            if on then
                local d = LeadDots.get()
                d.Position, d.Size = UDim2.fromOffset(s.X, s.Y), UDim2.fromOffset(CFG.droneDotSize, CFG.droneDotSize)
                d.BackgroundColor3, d.BackgroundTransparency = COL.leadDot.c, COL.leadDot.t
                local s2, on2 = cam:WorldToViewportPoint(main.Position)
                local dx, dy = s.X - s2.X, s.Y - s2.Y
                local len = math.sqrt(dx * dx + dy * dy)
                if CFG.droneDotLine and on2 and len > 3 then
                    local l = LeadLines.get()
                    l.Position = UDim2.fromOffset((s.X + s2.X) / 2, (s.Y + s2.Y) / 2)
                    l.Size, l.Rotation = UDim2.fromOffset(len, 1.5), math.deg(math.atan2(dy, dx))
                    l.BackgroundColor3, l.BackgroundTransparency = COL.leadLine.c, COL.leadLine.t
                end
            end
        end
    end
end

-- ============================== drone hit marker ==============================
-- The game has no drone health or hit confirm: the shooter's own (non-cosmetic) bullet claims the hit on a part with
-- a DroneHitbox attribute (BulletSimulator -> "GlassShatter" bridge) and a downed drone gets attribute Crashing = true.
-- So: track your own tracers in workspace.BulletPool (appear at your camera, fly along your view), ray-test each
-- frame's travel against enemy drone hitboxes, and upgrade to a kill marker if that drone starts Crashing.
local TweenSvc = game:GetService("TweenService")
local markHolder = Instance.new("Frame")
markHolder.AnchorPoint, markHolder.Position, markHolder.BackgroundTransparency = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5), 1
markHolder.ZIndex, markHolder.Parent = 20, screen
local markBars = {}
for i, rot in ipairs({ 45, -45 }) do
    local b = Instance.new("Frame")
    b.AnchorPoint, b.Position, b.BorderSizePixel, b.Rotation = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5), 0, rot
    b.BackgroundTransparency, b.ZIndex, b.Parent = 1, 20, markHolder
    markBars[i] = b
end
local hitLog = {} -- recent hits, for probes
local function showMarker(kill)
    local col = kill and COL.killMark or COL.hitMark
    local size = CFG.hitMarkerSize * (kill and 1.5 or 1)
    markHolder.Size = UDim2.fromOffset(size, size)
    for _, b in ipairs(markBars) do
        b.Size, b.BackgroundColor3, b.BackgroundTransparency = UDim2.fromOffset(size, kill and 3 or 2), col.c, col.t
        TweenSvc:Create(b, TweenInfo.new(kill and 0.6 or 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            { BackgroundTransparency = 1 }):Play()
    end
end

local myBullets = {} -- pooled tracer part -> {p, t, mine (nil = unconfirmed), hit}
local hitParams = RaycastParams.new()
hitParams.FilterType = Enum.RaycastFilterType.Include
local function droneHits()
    if not CFG.hitMarker then return end
    local pool = Workspace:FindFirstChild("BulletPool")
    local char = lp.Character
    if not (pool and char and char:FindFirstChildOfClass("Tool")) then return end
    local cam = Workspace.CurrentCamera
    local camPos, look, now, team = cam.CFrame.Position, cam.CFrame.LookVector, os.clock(), myTeam()
    local boxes, owner = {}, {}
    for _, m in ipairs(DroneWS:GetChildren()) do
        if m:GetAttribute("Team") ~= team and m:GetAttribute("Crashing") ~= true then
            for _, d in ipairs(m:GetDescendants()) do
                if d:IsA("BasePart") and d:GetAttribute("DroneHitbox") ~= nil then boxes[#boxes + 1] = d; owner[d] = m end
            end
        end
    end
    hitParams.FilterDescendantsInstances = boxes
    for _, b in ipairs(pool:GetChildren()) do
        if b:IsA("BasePart") then
            local pos, st = b.Position, myBullets[b]
            if st then
                local seg = pos - st.p
                local d = seg.Magnitude
                if st.mine == nil and d > 0.5 then st.mine = seg.Unit:Dot(look) > 0.8 end -- first move: along my view?
                if st.mine and not st.hit and d > 0.05 and d < 3000 and #boxes > 0 then
                    local r = Workspace:Raycast(st.p, seg, hitParams)
                    if r then
                        st.hit = true
                        local m = owner[r.Instance]
                        showMarker(false)
                        table.insert(hitLog, 1, { t = now, drone = m and m.Name, part = r.Instance.Name })
                        if #hitLog > 10 then table.remove(hitLog) end
                        task.spawn(function()
                            local t0 = os.clock()
                            while m and os.clock() - t0 < 1.5 do
                                if m.Parent == nil or m:GetAttribute("Crashing") == true then
                                    showMarker(true)
                                    hitLog[1].kill = true
                                    return
                                end
                                task.wait(0.05)
                            end
                        end)
                    end
                end
                st.p = pos
                if now - st.t > 3 or st.mine == false then myBullets[b] = nil end
            elseif (pos - camPos).Magnitude < 12 then
                myBullets[b] = { p = pos, t = now } -- a tracer at my muzzle; ownership decided by its first move
            end
        end
    end
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
    guard("droneLead", droneLead)
    guard("droneHits", droneHits)
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
    if zoomSet then zoomSet = nil; Workspace.CurrentCamera.FieldOfView = baseFov() end
    UIS.MouseDeltaSensitivity = baseSens
    root:Destroy(); screen:Destroy()
    if Library then pcall(Library.Unload, Library) end
end
getgenv().WARFARE_HUD = { unload = unload, cfg = CFG, learnedR = learnedR, errs = errs, aimOf = aimOf, aimTable = aimTable,
    mapViews = function() return mapViews end, hitLog = hitLog, showMarker = function(k) showMarker(k) end }

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
Zoom:AddLabel("Hold right mouse with a gun out to zoom (CapsLock turns Aim zoom on/off; click the key box to change it). Roblox has one camera, so the whole view zooms (optional dim outside a center circle: Colors tab).", true)
toggle(Zoom, "WF_AimZoom", "aimZoom", "Aim zoom")
-- keybind flips the Aim zoom toggle (SyncToggleState); change the key or clear it in the picker, saved with the config
Library.Toggles.WF_AimZoom:AddKeyPicker("WF_AimZoomKey", {
    Default = "CapsLock", Mode = "Toggle", SyncToggleState = true, Text = "Aim zoom",
})
Zoom:AddSlider("WF_ZoomLevel", { Text = "Zoom", Default = CFG.zoomLevel, Min = 1.5, Max = 8, Rounding = 1, Suffix = "x",
    Callback = function(v) CFG.zoomLevel = v end })
slider(Zoom, "WF_ZoomSize", "zoomSize", "Dim circle size", 10, 90, "% of screen height")
slider(Zoom, "WF_ZoomSpeed", "zoomSpeed", "Zoom speed", 4, 40, "")
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
toggle(Drones, "WF_DroneDot", "droneDot", "Aim dot (lead) on enemy drones", "Put your sights on the dot: it leads the drone by your bullet's flight time, plus drop")
toggle(Drones, "WF_DroneDotAim", "droneDotAimOnly", "Only while aiming (right mouse)")
toggle(Drones, "WF_DroneDotLine", "droneDotLine", "Line from drone to its dot")
slider(Drones, "WF_DroneDotRange", "droneDotRange", "Aim dot range", 20, 400, "m")
slider(Drones, "WF_DroneDotSize", "droneDotSize", "Aim dot size", 4, 20, "px")
toggle(Drones, "WF_DroneDotArea", "droneDotArea", "Show the hittable area", "The drone's real hitbox, shifted to the lead point: anywhere inside it hits. The dot is its center")
toggle(Drones, "WF_HitMarker", "hitMarker", "Hit marker on drone hits", "White X when your bullet hits an enemy drone, big red X if it goes down")
slider(Drones, "WF_HitMarkerSize", "hitMarkerSize", "Hit marker size", 10, 60, "px")
local leadLabel = Drones:AddLabel("Bullet speed: -", true)
task.spawn(function()
    while getgenv().WARFARE_HUD do
        pcall(function() leadLabel:SetText("Bullet speed: " .. leadStatus) end)
        task.wait(1)
    end
end)

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
