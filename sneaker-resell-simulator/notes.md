# Sneaker Panel Project

> Sneaker Resell Simulator automation panel — active file is panel/panel_v2.lua, v1 is superseded, deploy copy lives in Potassium workspace


Active panel: `%USERPROFILE%\rblx\panel\panel_v2.lua` (~3720 lines, CRLF). `sneaker_panel.lua` (v1) and its .bak files are superseded, so don't fix bugs there. Ground truth for game mechanics is `%USERPROFILE%\rblx\sneaker-panel-spec.md`: every number in it was measured live, so trust it over guesses.

Deploy path: copy panel_v2.lua to `%USERPROFILE%\AppData\Local\Potassium\workspace\panel_v2.lua`. The client loads it via `readfile("panel_v2.lua")`, and armRejoin depends on that name.

Test loop that works (2026-09-29): use the `mcp__potassium__*` tools (execute_script/list_clients). read_console returns nothing, so write results with `writefile("claude_probe.txt")` and read the file from the workspace. Stage the new build as `panel_v2_next.lua`. Compile-check with `loadstring(readfile(...))`: nil+err gives the line number. `getgenv().SNEAKER_PANEL_SAFEBOOT = true` now also skips the autoload config, so nothing starts. Reload without it afterwards to restore the user's config. When editing via python heredoc, `\\` gets mangled: use `chr(92)` for backslashes in Lua strings.

UI layout (refined 2026-09-29): Home (Director, Safety/kill/spend cap, Live, Loops) / Buy (PC offers, Profit filter, Offer slots) / Sell (Cashier, Value routing, NPC bar, Travel) / Market (Rotations, Limited shop, SHOES drops) / Craft (Mystery boxes, Trade up, Plan, Unsellable) / System (Store plot, Performance, Log) / Settings. Every auto/manual pair uses Obsidian `AddDependencyBox():SetupDependencies({{Toggle, value}})`, so only the active half shows. The sliders the Director/tuner write are re-synced in repaintLabels.

Fixed 2026-09-29 (review + live test):
- a loop generation token (`newGen`/`live`)
- setFeature `gated`, so AutoSell permission is no longer revoked
- move lock in tweenRootTo
- Keep-One `sellableUnits()`
- snipe/drops go through canSpend/recordSpend
- a blank snipe target buys once and then disarms
- the Director no longer writes TargetSlots
- a watchdog restart doesn't re-arm ArmOnStart
- presets never set AutoUpgrade; their dials survive phase baselines
- LimitedSnipe/AutoDrops are no longer saved

Open, unfixed (medium): the bar carousel pick only runs once per frame-open; pressButton can "succeed" on SoundScript alone; the AutoBarValue median split is positive feedback; ClaimHop loses AutoClaim after the hop; the bar-grade buy floor loses money if the stock ends up cashier-dumped.

Test account on the client was an alt (low bankroll, 1 slot, Store2).
