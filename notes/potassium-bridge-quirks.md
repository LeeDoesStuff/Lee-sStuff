# Potassium Bridge Quirks

> Potassium MCP (mcp__potassium__*) quirks: no console output, PIDs change on restart, execute queue can jam silently — how to detect and what to ask the user


Quirks of the Potassium MCP execute bridge (`mcp__potassium__execute_script` / `list_clients` / `read_console`):
- `read_console` returns nothing. Have scripts `writefile("x.txt", ...)` into `%USERPROFILE%\AppData\Local\Potassium\workspace\` and read that file locally. Wrap the script in `pcall` and write the error too, or failures are silent.
- A game restart gives a new PID; call `list_clients` again. Stale PIDs from other clients can linger in the list.
- **The execute queue can jam silently.** Seen 2026-09-26 ~20:56 right after a script reload that also `HttpGet`s the Obsidian library. After that, every `execute_script` still returned "dispatched", but nothing ran, not even a one-line `writefile` ping, for 10+ minutes. Scripts already running in-game kept going. Detect it with a timestamped ping file. The fix needs the user: re-attach Potassium, or run the loader by hand. Queued scripts `readfile()` at execution time, so redeploying the file before they run is fine.

See [battle-bot-project](../build-a-battle-bot/notes.md).
