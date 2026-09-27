# Warfare Project

> Warfare (place 81748781442029) drone HUD overlay project — MAVIC/FPV drones, game already has a MAVIC landing predictor, team = player attr \"Team\", aim via HeadMovement bridge


Started 2026-09-27. User owns the drone gamepass and wants a **drone HUD feature list**, not a farm: trajectory predict, explosion radius, enemy aim cones / "someone is looking at you" warning, plus more they're brainstorming. Spec: `%USERPROFILE%\rblx\warfare-spec.md`.

- The game **already ships a MAVIC drop predictor** (`MavicFlight.Predict`, fixed 7.5-stud ring, 3.2 s, no drag). Build on it; don't duplicate it blindly.
- Team check is the **player attribute `Team`**, not `Player.Team`, which is nil.
- Decompiled client dump lives in the Potassium workspace `warfare_src\`.
- **v1 built 2026-09-27: `%USERPROFILE%\rblx\warfare_hud.lua`**. Deploy by copying it to the Potassium workspace. It has the predictor, blast rings, aim cones with WATCHED warnings, body guard, enemy drone alert (which the user added to v1), and color/opacity pickers for each element (asked for mid-build).
- The FPV attachment `Distance` attribute is the blast radius (measured). Radii are also learned live from `ExplosionFX.Replicate`.
- The user denied screen access to Roblox (Fishstrap), so verify with state probes (`writefile`), not screenshots. The flight features still need the user's own in-drone test.

See [game-recon-full-progression](../notes/game-recon-checklist.md), [potassium-bridge-quirks](../notes/potassium-bridge-quirks.md).
