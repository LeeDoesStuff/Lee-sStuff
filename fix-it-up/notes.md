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
- Respect the sell timer after a purchase: measured at 184 s. The refusal text is "You need to wait N seconds to sell this car".
- Wants teleports for every shop.
- NEVER sell the collector cars: see fiu-never-sell-collection.

**Distance farm (Drive tab):** spawning the car on the highway takes about 20 s. The first RemoteLoad often drops it at the garage, where it rolls out, and the retry lands it. Toggling off/on during that window used to start a 2nd thread, which the 1st then switched off (stuck on "waiting for farming distance"). Fixed 2026-09-29: one `farm.worker` at a time, with a live status for each step. The server counts only about 40% of the distance moved at 150 studs/s.

**Repair speed (2026-09-29):**
- A repair takes about 34 s, and the machines (grinder 16 s) are most of it.
- The user saw 70–75 s. The cause was the RequestStreamAroundAsync jam: each teleport paid a 3 s stream timeout. See [potassium-bridge-quirks](../notes/potassium-bridge-quirks.md).
- Teleporting to each machine is required, because the button range is 10–14 studs.

**Contested cars** (Junkyard tab, 2026-09-29):
- Auto buy skips a junk car another player is standing at, unless it's at the snipe tier or rarer (the user's idea).
- `FIU_MAIN.contested` is exported for tests.
- fiu_main is at Luau's 200-local limit, so new top-level helpers go in a table or a do-block.

**Reloading:** reload only when auto isn't busy repairing, selling or buying. Unpinned parts get deleted after 90 s. "Busy: farming distance" is fine. After a reload, turn FIU_DriveFarm back on; its default is off.

**Garage:** the Default garage has 3 slots. The user's Merquis Maibac S650 is locked as a favorite and is no longer parked at the sell NPC.

**Server hop:** merged on 2026-09-28 into the fiu_main "Server hop" tab, at the user's request.
- It keeps state in `fiu_hop.json`, and re-queues `fiu_main.lua` via queue_on_teleport.
- The standalone `fiu_hop.lua` is legacy; fiu_main unloads it if it's running.
- It hunts for servers where other players' `leaderstats["Cars Sold"]` is under a cap.
- The servers API allows at most 2 calls per 4 s (the 3rd gets a 429).

See [potassium-bridge-quirks](../notes/potassium-bridge-quirks.md), [game-recon-full-progression](../notes/game-recon-checklist.md).
