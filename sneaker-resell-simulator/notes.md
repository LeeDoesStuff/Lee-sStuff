# Sneaker Panel Project

> Sneaker Resell Simulator automation panel — active file is panel/panel_v2.lua, v1 is superseded, deploy copy lives in Potassium workspace


Active panel: `%USERPROFILE%\rblx\panel\panel_v2.lua` (~3540 lines). `sneaker_panel.lua` (v1) and its .bak files are superseded — don't fix bugs there. Ground truth for game mechanics: `%USERPROFILE%\rblx\sneaker-panel-spec.md` (every number measured live; trust it over guesses).

Deploy path: copy panel_v2.lua to `%USERPROFILE%\AppData\Local\Potassium\workspace\panel_v2.lua` — the client loads it via `readfile("panel_v2.lua")` (armRejoin depends on this name).

xeno-mcp bridge runs in **generic mode** (Potassium executor, not Xeno — never say "Xeno" to the user). Quirk: execute_lua with no `clients` fails with "Client not found: Name(undefined)"; pass `clients: ["<username>"]` explicitly. Compile-only syntax check that works: execute `loadstring(readfile("panel_v2.lua"))` on the client and read the printed result from captured_output.

Fixed 2026-08-31: limited-sniper early-travel was firing BuyPrompt before the hour (bought wrong rotation); Director was overriding a manually-enabled AutoBar when BarApproach off; Bar.SellOne double-counted Econ bar-rate samples; stopAll missed AutoClaim toggle; offer cards need `rbxthumb://` not `rbxassetid://`.
