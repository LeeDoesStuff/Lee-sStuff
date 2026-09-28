# Potassium Bridge Quirks

> Potassium MCP (mcp__potassium__*) quirks: no console output, PIDs change on restart, execute queue can jam silently — how to detect and what to ask the user


Quirks of the Potassium MCP execute bridge (`mcp__potassium__execute_script` / `list_clients` / `read_console`):
- `read_console` returns nothing. Have scripts `writefile("x.txt", ...)` into `%USERPROFILE%\AppData\Local\Potassium\workspace\` and read that file locally. Wrap the script in `pcall` and write the error too, or failures are silent.
- A game restart gives a new PID; call `list_clients` again. Stale PIDs from other clients can linger in the list.
- With several clients listed, find the farm's one with a probe that writes a uniquely named file per client (JobId + UserId + `getgenv()` flag), then pass that `pid` explicitly. `pid = all` would start a second farm writing the same log and autosaving the same config. A listed client that never writes the probe is stale or jammed.
- **The execute queue can jam silently.** Seen 2026-09-26 ~20:56 right after a script reload that also `HttpGet`s the Obsidian library. After that, every `execute_script` still returned "dispatched", but nothing ran, not even a one-line `writefile` ping, for 10+ minutes. Scripts already running in-game kept going. Detect it with a timestamped ping file. The fix needs the user: re-attach Potassium, or run the loader by hand. Queued scripts `readfile()` at execution time, so redeploying the file before they run is fine.
- **Reload with a compile check:** `local f, e = loadstring(readfile(x)); if f then pcall(f) end`, and write `e` to a file. A bare `pcall(function() loadstring(...)() end)` only reports "attempt to call a nil value" on a syntax error. On Warfare (2026-09-27) that hid a broken build while the old instance kept running and looked healthy.
- **Calling a game module's function drops the thread's capabilities until it yields.** Measured 2026-09-27 on Hit The Thrift: after `require(MorieliPricing).DisplayPrice(x)`, `gethui()` errors (`cloneref` got nil), and touching CoreGui instances or Obsidian labels throws "The current thread cannot access 'Instance' (lacking capability Plugin)". A `task.wait()` restores them. `require` itself and reading module tables are fine. Inline small game helpers, or yield before touching UI.
- **`appendfile` fails silently when the file doesn't exist yet** (measured 2026-09-27). `writefile(f, "")` first.
- A `queue_on_teleport` payload of "spy, then decompile dump" re-armed the spy after a Tutorial → lobby teleport, but the dump half never ran (2026-09-27, cause unknown). Check each step's output file after a hop; don't assume the queue ran everything.
- **Don't patch Lua through shell heredocs that contain `"\n"`.** The escaping turned it into a real newline inside a string literal, and the file stopped compiling. Write the patch script to a file with the Write tool, or use Edit.

See [battle-bot-project](../build-a-battle-bot/notes.md), [warfare-project](../warfare/notes.md).
