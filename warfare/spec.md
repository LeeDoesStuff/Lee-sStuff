# Warfare — drone HUD spec (recon 2026-09-27)

Place `81748781442029`, game `10383565741`. Squad PvP (tickets, capture points), ~40 players. Goal is a **drone HUD overlay**, not a farm. Everything below is read from the decompiled client unless marked *measured*.

Source dump: `%USERPROFILE%\AppData\Local\Potassium\workspace\warfare_src\` (549 scripts, `decompile` works on Potassium).

## Drones

Two types, models in `ReplicatedStorage.DroneSystem` (Actor), live drones in `workspace.DroneWorkspace` named `<UserId>_<TYPE>` (e.g. `9953813191_FPV`). Every drone model carries a `Team` attribute.

| Type | Role | Payload |
|---|---|---|
| **MAVIC** | hover + drop grenades | rack from `DroneSystem.Attachments`, chosen by player attr `SelectedWarheadMAVIC` |
| **FPV** | kamikaze | warhead chosen by workspace attr `SelectedDroneAttachment` |

- Client: `PlayerScripts.DroneClient.DroneClient` (4.5k lines). Talks to the server via BridgeNet2 `ReferenceBridge("DroneEvent")`, e.g. `{Action = "DropMavic"}`.
- Drone state: player attr `InDrone == true`; `NoSignal` frame = jammed/out of range.
- MAVIC flight = `BodyVelocity` + `BodyGyro` on `Main`; FPV = `VectorForce` Lift/AntiGravity/Aerodynamics + `AngularVelocity` Motion.

### Payload attributes (on `DroneSystem.Attachments.<name>`)

| Attachment | Type | DisplayName | Explosion | Damage | Distance | Weight | Pass |
|---|---|---|---|---|---|---|---|
| M67_HOLDER | MAVIC | M67 Rack (1) | M67 | — | — | 1 | free |
| RGO_HOLDER | MAVIC | RGO Rack (1, impact fuse + timed backup) | RGO | — | — | 1 | free |
| RGO_TRIPLE_HOLDER | MAVIC | RGO Triple Rack | RGO | — | — | 1.15 | 1905384578 |
| RGD_HOLDER | MAVIC | RGD-5 Triple Rack | RDG5 | — | — | 1.15 | 1905384578 |
| For_Kamikaze | FPV | Standard Frag (free default) | FPVFrag | 170 | 110 | 1 | |
| Rocket | FPV | Light Rocket | FPVFrag | 160 | 105 | 0.9 | |
| TBG7B | FPV | TBG-7B Thermobaric | FPVHeat | 190 | 150 | 1.4 | |
| PG7VS | FPV | PG-7VS Shaped | FPVThermo | 280 | 65 | 1.1 | |
| PG7VSwithWire | FPV | PG-7VS Thermo | FPVThermo | 220 | 95 | 1.2 | |

**`Distance` = blast radius r** (*measured* 2026-09-27 from `ExplosionFX.Replicate` broadcasts: FPVFrag r=110, FPVHeat r=150, FPVThermo r=65, M67 r=55). The client never reads it; the server passes it to `Explode`. Live drones also carry `MountedWarhead`, `DroneType`, `OwnerName`, `Team`, `FlightWeightMult` attributes.

## Built-in MAVIC drop predictor (game already has one)

`Framework.Modules.MavicFlight.Predict` / `Draw`, driven from DroneClient each frame:
- Ballistic only: `pos + v*t + ½g t²`, step 1/30 s, 96 steps (3.2 s horizon), **no drag**, starts at the payload's position with the drone's `AssemblyLinearVelocity`.
- Draws a fixed **7.5-stud** orange neon ring (64 parts, folder `MavicLandingEstimate`) at the hit. Ring size is cosmetic, not the blast.
- Gated by workspace attr `ShowDroneLandingGuide ~= false` (settings toggle, currently true). MAVIC only; FPV has no predictor.
- Our add-on value: draw the arc itself, extend past 3.2 s, real blast/frag rings instead of the 7.5 ring, and an FPV impact line.

## Explosion model (`Framework.Modules.ExplosionFX.Explode`)

- Called with radius `r` (default 45). Frag search radius = `max(r, min(55, r*2.5))`.
- Shrapnel sim: 650 virtual frags, `BaseDamage 27`, falloff starts at **15 studs**, min falloff 0.3, head ×1.5, limbs ×0.6, max 6 frags/victim. Frags are **raycast**, so cover blocks them.
- `Framework.Config`: `GrenadeStats.Radius = 55`; launchers RPG-7 45/130, RPG-26 40/120, AT4 48/145 (radius/damage).
- **Blast damage** (`ComputeBlastDamage(d, r, dmg)`): full `dmg` inside `r/4`, then `dmg*(1-(d-r/4)/(r-r/4))^1.7`, 0 at r. Line of sight to the HumanoidRootPart is raycast; teammates are skipped (no friendly fire). Characters have **100 HP**, so one-shot radius = `r/4 + (3r/4)*(1-(100/dmg)^(1/1.7))`: M67 ≈ 18.8 studs, Standard Frag ≈ 49.6.
- Default damage per type (`ExplosionFX` u13): M67 125, RDG5 110, F1 145, RGO 135. FPV damage = attachment `Damage` attr.
- The server broadcasts every blast on `Framework.Modules.ExplosionFX.Replicate` as `{p = pos, t = type, r = radius, s = scale, u = ...}`. Listening to it learns radii live.

## Other players: look direction + team

- Head/torso aim replicates through BridgeNet2 `ReferenceBridge("HeadMovement")`: payload `{fromUserId, neck, waist, p = pitch, aim = Vector3}` every 0.1 s. `aim` is the **weapon muzzle's LookVector in the sender's HumanoidRootPart space**. It's only sent while a gun is equipped and the player isn't sprinting or jogging (`Core.SetAimSource`).
- The receiving client keeps `{plr, aim, p, n, w, up = os.clock(), ...}` per UserId in upvalue 2 of the `OnRemoteData` closure; get it with `getgc` + `debug.getupvalue`. *Measured:* it only holds about 5–8 players at a time, the nearby ones, so the server culls by distance. Far players get no pitch at all. Neck C0 changes don't replicate, so their Head pose is animation only.
- The remote `Head.CameraHead.Base` joint (3P gun mount) is aimed along `aim` for nearby players. *Measured:* it matched the head (0.0° apart).
- **Head LookVector is NOT the aim** (*measured against BulletPool tracers*, 27 shots): 2–10° off in yaw and 6–31° off in pitch, because the weapon-hold animation pitches the head down. **HRP LookVector yaw was within ~1° of the bullet yaw** on most shots, prone included.
- HUD aim model (v1.3): the muzzle `aim` when it's fresh (< 1.5 s), else HRP yaw with a level cone. Checks compare yaw only then, and the warning says "FACING" instead of "AIMING".
- Team = **player attribute `Team`** (not `Player.Team`, which is nil). Drones: `model:GetAttribute("Team")`. Same check as `TeamTags.isSameTeam`.

## Feature ideas mapped to data

| Feature | Data source | Status |
|---|---|---|
| Trajectory predict (MAVIC) | own drone velocity + gravity, `MavicFlight.GetPayload` for the start point | v1 |
| FPV impact line | FPV `Main` velocity, raycast ahead | v1 |
| Explosion radius rings (edge / one-shot / full) | payload attrs + ExplosionFX formula | v1 |
| Enemy aim cones / "being watched" | remote Head LookVector, `Team` attr, LOS raycast | v1 |
| Body guard (enemy near idle body) | enemy HRP distance while `InDrone` | v1 |
| Enemy drone alert | `workspace.DroneWorkspace` children with other `Team`: distance, closing speed, ETA, Highlight | v1 |
| Color + opacity per element | Obsidian color pickers with `Transparency` (saved by SaveManager), 18 of them in 5 groupboxes, plus a reset button. No hardcoded colors outside the `COL` table (text outlines and drone outline/heading line included) | v1.2, verified live |
| ESP (name + distance) | BillboardGui on enemy Head, distance from camera (= drone while flying) | v1.1, verified live (18 labels) |
| Cone color by aim | blend "looking away" → "on you" color + opacity by angle between their look and your body/drone; fully away at `gradAngle` (90°) | v1.1, verified live |
| Chams | Style "Per part" (default): a BoxHandleAdornment on each body part, colored by that part's own camera LOS (refreshed every 0.1 s), no instance cap, no outline. Style "Highlight": whole-body Highlight colored by head LOS, with outline; shares Roblox's 31-Highlight cap with enemy-drone marks | v1.4, verified live: a peeking enemy showed Head = in-sight color, 14 parts = cover color |
| Map ESP | `PlayerScripts.TacticalMap` makes 2 view tables via `newView(clip, opts)`: `{clip, cx, cz, spp, rot, iconLayer, mates, drones, ...}`. They're found with `getgc(true)` (fields spp + mates + iconLayer + clip). Minimap clip = `PlayerGui.TacticalMinimap.Frame.Clip` (disabled unless the `Minimap` setting is on); full map = `PlayerGui.TacticalMap.Panel`. Enemy dots go in an overlay frame `WFEnemies` (ZIndex 5, above the game's Icons layer 4), placed with its `toView`: `((X-cx)/spp, (Z-cz)/spp)`, rotated by `rot`, plus half the clip size. The game only refreshes view fields and teammate dots **while the map is open**. *Verified:* the same math matches the game's teammate dots to **0 px** once the open animation settles; the 57–87 px uniform offset only shows during the open tween | v1.5 |
| Spawn map ESP | `PlayerScripts.SatelliteDeployMap`: the real camera looks straight down and map tiles (ScreenGui `SatelliteMap`, DisplayOrder -2, grid -1) sit over it. Markers use `Camera:WorldToViewportPoint`. Active when workspace attrs `InMenu == true`, `CurrentWindow == "Map"` and `MapLoaded`, with camera `LookVector.Y <= -0.95`. Enemy dots go in the HUD ScreenGui at viewport coords | v1.6 |
| Ragdoll pass-through | LOS and predictor raycasts skip `CollisionGroup "RagdollCorpse"` / `RagdollRig` parts, like the game's MavicFlight predictor. *Measured:* your own death ragdoll (`Terrain.<you>_LocalCorpse.RagdollRig.RagdollCollider`) blocked every LOS check while dead | v1.4 |

## Script: `warfare_hud.lua` (v1, 2026-09-27)

- Loader: `loadstring(readfile("warfare_hud.lua"))()` (file in the Potassium workspace). Re-exec safe via `getgenv().WARFARE_HUD.unload`.
- Draws with HandleAdornments (Line/Cylinder, `Adornee = Terrain`, AlwaysOnTop) pooled in a Folder under `gethui()`; Highlights for enemy drones. Obsidian UI tabs: Drone, Threats, Colors, Settings. Config folder `WarfareHUD`.
- Runtime errors per feature append to `WarfareHUD/errors.txt` (once per distinct message).
- Not yet verified in flight (recon account wasn't flying): predictor arc/rings and the LineHandleAdornment direction need a real MAVIC/FPV run.

## Executor compatibility (2026-09-27)

A tester on **Xeno** reported that their gun wouldn't come out after respawning with the HUD loaded. Not reproducible here (Potassium only).
- **Game side:** `Core.Equipment.Equip` has a **6 s watchdog**. If equipping hasn't finished (viewmodel pool, `GetSecureSettings` server round-trip, ammo sync, animation load), it calls `_equipFail`, which prints `[Core] equip failed: <reason>` (e.g. `watchdog: ... wedged at: <stage>`) to the F9 console and unbinds weapon input. **That console line names the stage; get it from the tester.**
- **HUD parts that touch game internals:** `require(MavicFlight)` (now removed, inlined), `getgc(false)` + `debug.getupvalue` for the HeadMovement aim table, and `getgc(true)` for the map views. *Measured* on Potassium: getgc(false) 850k objects in 15 ms plus a 70 ms scan; getgc(true) 1.5M objects in 21 ms plus a 96 ms scan. The old code rescanned every 10–15 s for as long as nothing was found. On an executor with a slow or partial getgc, that's a repeating freeze, which can trip the equip watchdog.
- **v1.6 hardening:** getgc support is checked once (`HAS_GC`); failed scans back off 15 s → 5 min; a Settings toggle turns memory scans off; no game module is required. *Verified:* with getgc/islclosure/debug.getupvalue/gethui hidden, the HUD loads with no errors and ESP runs; muzzle aim and in-match map dots switch off, and spawn-map dots still work.
