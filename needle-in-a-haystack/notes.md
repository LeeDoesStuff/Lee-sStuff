# Needle Haystack Project

> Needle in a Haystack (Roblox) — Sell On Drop pass recreation; economy is position-gated server-side, stepped movement beats the anti-teleport force-drop


Game "Needle in a Haystack", PlaceId 73903875561291. Panel: `%USERPROFILE%\rblx\needle_selldrop.lua`, deploy copy at `%USERPROFILE%\AppData\Local\Potassium\workspace\nih_selldrop.lua` (client runs `loadstring(readfile("nih_selldrop.lua"))`). Obsidian UI. State in `getgenv().NIH_SOD`.

Mechanics measured live 2026-09-05 (all server-authoritative, no server access — derived empirically):

- Currency = player attribute **`StrawBalance`**. Carried count = **`Carrying`**. There is no Cash/Money attr and no leaderstats. `StrawsMoved` is a noisy lifetime counter, useless as a payment signal — drones deposit continuously (~13 per 3s), so always attribute payment via `StrawBalance` delta, never `StrawsMoved`.
- **Payment is position-gated**: standing on the vent's sell spot while `Carrying > 0` makes the server deposit and credit. There is NO deposit remote to call.
- **The sell spot is beside the vent, not on top of it.** Vent-local offsets: `right 6.91, look 0.53, y 2.78` off `workspace.vent:GetPivot()` (world ≈ 50.891, 2.779, 82.417). Parking above `Vent_Mouth` puts the character inside `Vent_Ring` geometry — that reads as "in the floor" and deposits only intermittently. Panel stores the spot vent-relative in `nih_sellspot.json` and has a "capture spot = my position" button. Fastest way to find the spot again: read another player's HRP position while they sell.
- `DropRequest` / `DropAllRequest` `:FireServer(CFrame, lookVector)` only LITTER. A drop away from the vent is accepted (`Carrying`→0) but pays **nothing**. A drop CFrame far from your character is **rejected outright** (Carrying unchanged). So the pass cannot be faked through remotes.
- **A hard CFrame teleport loses the load** — server force-drops on a large position jump. Measured twice: carry 8→0, zero credit.
- **A stepped move preserves it**: 8 studs per 0.06s walks the character to the vent and pays normally. This is the whole trick behind the recreation.

Gamepasses are real Robux passes gated by server-set `Pass_<key>` attributes. "SELL ON DROP" = card key **`pocket`** (249 R$), effect "DROP becomes SELL: dropped straws pay on the spot, no vent trips". `Pass_pocket` is nil on this account (not owned); the shop cards showing `T=OWNED` are misleading — trust the attribute. Client only uses `Pass_pocket` to relabel DROP→SELL in the HUD.

Recon tips for this game: `decompile()` works; dump big client scripts with `writefile` into the Potassium workspace and read them locally instead of fighting log truncation. `execute_lua` return values are NOT captured — only `print` output, and `captured_output` truncates, so poll `get_logs`. Pulls need the player within ~50 studs of a tile and each `(tile, slot)` only works once.

See [sneaker-panel-project](../sneaker-resell-simulator/notes.md) for the other panel; same generic-mode bridge quirks apply (pass `clients: ["an alt"]` explicitly).
