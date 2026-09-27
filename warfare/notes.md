# Warfare Project

> Warfare (place 81748781442029) drone HUD overlay project — MAVIC/FPV drones, game already has a MAVIC landing predictor, team = player attr \"Team\", aim via HeadMovement bridge


Started 2026-09-27. User owns the drone gamepass and wants a **drone HUD feature list**, not a farm: trajectory predict, explosion radius, enemy aim cones / "someone is looking at you" warning, plus more they're brainstorming. Spec: `%USERPROFILE%\rblx\warfare-spec.md`.

- The game **already ships a MAVIC drop predictor** (`MavicFlight.Predict`, fixed 7.5-stud ring, 3.2 s, no drag). Build on it; don't duplicate it blindly.
- Team check is the **player attribute `Team`**, not `Player.Team`, which is nil.
- Decompiled client dump lives in the Potassium workspace `warfare_src\`.

See [game-recon-full-progression](../notes/game-recon-checklist.md), [potassium-bridge-quirks](../notes/potassium-bridge-quirks.md).
