# Fix It Up Project

> [BRAKES] Fix It Up! (Roblox) — server hopper that hunts servers where players have few Cars Sold; stat locations + deploy path


Game "[BRAKES] Fix It Up!", PlaceId 72712036210947, GameId 7673659635, max 22 players. Script: `%USERPROFILE%\rblx\fiu_hop.lua`, deploy copy `%USERPROFILE%\AppData\Local\Potassium\workspace\fiu_hop.lua`, re-queued via queue_on_teleport as `loadstring(readfile("fiu_hop.lua"))()`. State in `fiu_hop.json` (settings + visited JobIds, 1h TTL). Obsidian UI. Built 2026-09-25.

Stats: `leaderstats["Cars Sold"]` and `leaderstats.KMs` are public per player. Full data replicated at `Player.PlayerData.Status.*` (Money, MoneyMade, CarsSold, PlayTime, KMs, Gold, RobuxSpent, AuctionsOpen) — visible for every player, not just local.

Roblox `games.roblox.com/v1/games/{place}/servers/Public` rate limit measured 2026-09-25: **3rd call within ~4s → 429**, retrying while limited keeps it limited; recovers within ~40s of silence. One request per hop, page 1 only (Asc = 100 smallest servers, 1–7 players). Use `request` (Potassium has it) for the StatusCode — `game:HttpGet` hides 429.

Potassium MCP (`mcp__potassium__*`, pass pid): `read_console` returned nothing on 2026-09-25 — use `writefile` to the workspace and read it locally instead. See [sneaker-panel-project](../sneaker-resell-simulator/notes.md), [needle-haystack-project](../needle-in-a-haystack/notes.md).
