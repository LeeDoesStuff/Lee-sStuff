# Fix It Up Project

> [BRAKES] Fix It Up! (Roblox): fiu_main.lua flip farm (junk tiers, buy/repair/sell, shop, teleports) + fiu_hop.lua server hopper; spec in fix-it-up-spec.md


Game "[BRAKES] Fix It Up!", PlaceId 72712036210947, GameId 7673659635, max 22 players.

**fiu_main.lua** was built 2026-09-27/28 to replace AltLexon's script, a Luarmor-obfuscated loader I didn't crack.
- Deployed to `Potassium\workspace\fiu_main.lua`.
- State lives in `FixItUp/` (`owned.json` = the only sellable cars, `state.json` = the learned sell timer). SaveManager folder: `FixItUp`.
- Mechanics are in `%USERPROFILE%\rblx\fix-it-up-spec.md`.
- Key calls:
  - `RemoteLoad(entry, cframe)` teleports a car.
  - `PartsEvent` `RemovePart` / `ReapplyPart` work with no distance gate.
  - Machines need the part inside the Detector plus a click.
  - The confirm hook goes through `getcallbackvalue`.

**User preferences:**
- Repair at the Dealership stations (the "secondary garage"), not the busy Pitstop.
- Teleport the car with RemoteLoad; don't drag it by sitting in it.
- Respect the sell timer after a purchase. Its length is still unmeasured; the script learns it from the refusal text.
- Wants teleports for every shop.
- NEVER sell the collector cars: see fiu-never-sell-collection.

**Garage:** the Default garage has 3 slots. As of 2026-09-28 it holds a single Merquis Maibac S650 (collection). I left that car parked at the sell NPC after a test. The script refuses to sell while it's there.

**Server hop:** merged on 2026-09-28 into the fiu_main "Server hop" tab, at the user's request.
- It keeps state in `fiu_hop.json`, and re-queues `fiu_main.lua` via queue_on_teleport.
- The standalone `fiu_hop.lua` is legacy; fiu_main unloads it if it's running.
- It hunts for servers where other players' `leaderstats["Cars Sold"]` is under a cap.
- The servers API allows at most 2 calls per 4 s (the 3rd gets a 429).

See [potassium-bridge-quirks](../notes/potassium-bridge-quirks.md), [game-recon-full-progression](../notes/game-recon-checklist.md).
