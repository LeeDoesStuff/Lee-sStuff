# Junk Crushers 2 Project

> [AUTO CLICK] Junk Crushers 2 (Roblox): jc2_main.lua auto farm and spec.md. All state lives in player attributes, remotes are flat in ReplicatedStorage, the factory and smelter are driven by prompts and position, and the rain pad is fenced off from the rest of the plot.

The game is "[AUTO CLICK] Junk Crushers 2": PlaceId 73968232750026, GameId 10656201650, created by group 3876902. The spec was verified on PlaceVersion 1616 (2026-10-10). StreamingEnabled is on, and a server has 6 plots (`workspace.Map.Plots.Plot1..6`).

[spec.md](spec.md) is the ground truth: every system, remote, gate, formula and cost table, with the decompiled source it came from. The farm script is `jc2_main.lua`. To use it, put it in the Potassium workspace and run `loadstring(readfile("jc2_main.lua"))()`.
- **UI:** Obsidian. The SaveManager and ThemeManager folder is `CruelHub/JunkCrushers2`.
- **Log:** `CruelHub/JunkCrushers2/log.txt`. It also logs the first sighting of every unverified mechanic, such as event crate structure and smelter consumption.
- **Safe boot:** setting `getgenv().CRUELHUB_SAFEBOOT = true` loads the hub without the autoload config, so nothing starts on its own.

## How the recon was done (2026-10-10)

Run in the order of [recon-quickstart](../notes/recon-quickstart.md), on a fresh account (Rebirths 0, 200 coins, Plot3).

1. **Remote inventory, before `recon.lua`.** A quick pass scanned 37,817 descendants.
   - ReplicatedStorage holds 50 RemoteEvents and 28 RemoteFunctions, all at the top level: no Knit, no Replica, no remotes folder. Next to them are about 45 config ModuleScripts.
   - `getscriptbytecode(s):find(remoteName)` over 306 candidate scripts mapped which client script fires which remote.
   - Each plot's `Crusher.ActivateCrusher` is a BindableEvent (server-internal), not a remote.
2. **`recon.lua` step 1 (static dump).** Produced `info.txt`, `tree.txt` and `remotes.txt`.
   - 7 remotes have no caller in any client script (`!NOCALLER`): `PrivatePlaytimeQuery`, `PrivatePlaytimeDevice`, `AdminPlayerStats`, `JunkRainUpgradeRequest`, `JunkRainUpgradeResult`, `ClaimGroupReward`, `SetBigJunkScale`. They are treated as honeypots.
   - The player attribute dump (`PATTR`) showed that all progress is in attributes, several as JSON strings (FactoryDataJSON, DroneInventoryJSON, JunkIndexJSON, …).
3. **`recon.lua` step 3 (spy, 120 s).** The user wasn't playing, so it only caught inbound traffic. That was still useful:
   - `FactoryTransit` / `FactoryUpgradeFX` / `FactorySale` are **broadcast for every plot**. The spy saw Plot6's line while we owned Plot3, and showed a block's value going Scanner x1.2 → Polisher x1.4 → WoodenSmelter x1.6 → Press x1.75, which matches FactoryConfig exactly.
   - `ExoticDronePulse`, `RareDroneAnnouncement` and playtime checkpoint attributes also arrived.
4. **`recon.lua` step 2 (decompile).** 128 scripts (ReplicatedStorage modules plus the player's LocalScripts) in one resumable run, with no crash.
   - Some modules did **not** decompile: JunkRainConfig, MainQuestConfig, WorldChallengeConfig, RobuxShopConfig. Their data has to be read from the GUI or replaced with try-and-back-off.
5. **Four parallel static passes over the decompiled source**, one per system: core junk loop, factory/smelter, drones/crates, and progression/claims/events. Every claim is cited file:line in [spec.md](spec.md).
6. **Anti-cheat grep:** `:Kick(`, WalkSpeed/JumpPower signals, LogService, gcinfo, debug.info and "AntiCheat" all returned nothing on the client.
   - The only sensitive surface is an **admin panel** in `WorldPurchaseAdverts`, built only for UserId 372272914. It has global announcements, flight, global coin/luck boosts and event triggers. All of its remotes are hard-blocked.
7. **Live read-only probes** (Potassium `execute_script` writing files):
   - prompts on the plot, with their ranges and hold times
   - pairwise raycasts between farm stations to find walls
   - the Base bounds versus the Unload Pad
8. **Live farm tests** of 60 s each, before and after the movement fix.

## Measured live (2026-10-10, v1616)

- **Prompts are Custom-style ProximityPrompts with HoldDuration 0.** Potassium's `fireproximityprompt` works on all of them:

  | Prompt | Range | Enabled |
  |---|---|---|
  | `LootDumpsterPrompt` | 10 | only while the dumpster has junk |
  | `Crusher.FeedBin.Panel.Button.ProximityPrompt` "Crush Junk" | 12 | |
  | `Crusher.StackPickup.CollectStack` "Pick Up All" | 12 | only while a stack exists |
  | `Smelter.InputPart.ProximityPrompt` "SMELT BLOCKS" | 10 | |
  | `DailyChest.Base.GroupChestPrompt` | 12 | |

- **Junk has ClickDetectors** at 40 studs (`JunkClickDetector`) and 48 studs (`JunkClickTarget`). The farm ignores them and uses `JunkPickupRequest`, the same call the game's click handler makes.
- **The coin board is ClickDetector hitboxes** (`JunkRainUpgrader.ButtonHitboxes.<Key>_<One|Max>`, 36 studs) in front of `CoinUpgradeRequest`.
- **Dumpster capacity was 60 at DumpsterLevel 1** on this account. The client code's fallback says 25, so read `MaxCapacity` and never assume.
- **`Inventory.JunkBlocks` is the total VALUE of the blocks you're holding, not a count.**
  - The count is `#CarriedBlockValues`, a JSON attribute listing each held block's value. `CarriedBlockAngles` holds their angles.
  - Measured 2026-10-11: 7 blocks worth 56,286 each made JunkBlocks 394,000.
  - The first test's "60 blocks unloaded" was really a value of 60, so read the counts below as values.
- **The Unload Pad takes about one block per 1.8 s while you stand on it.** Measured: 7 blocks in 12 s, which paid +756K coins (1.43M → 2.19M).
- **The full loop works:** loot → crush → Pick Up All → stand on `Factory.Start.Base` → sold. On a level-1 account that was one cycle every ~13–14 s.
  - Coins went 200 → 776 with a 1-drone, level-1 account.
  - `JunkPickupRequest` with our own sequence numbers (from 1,000,001, clear of the game's counter) was accepted.
  - Auto Claim claimed a Junk Index entry (`CupTrash:Normal`).
- **No `FactorySale` for our own plot** arrived during the test, even though coins rose. The hub counts `JunkSoldEvent` until a `FactorySale` of yours shows up. Which event pays a fresh plot is still open.
- **The rain pad is fenced on the plot side.** A collidable `Plot.Decor.MeshPart` runs along the pad's edge facing the dumpster (x ≈ -249 on Plot3). The client already sets the 4 `RainPadWalls` non-collide and non-query; the Decor fence is a different part.
  - The first farm walked straight at out-of-reach junk and ground into it (reported by the user).
  - Fix: never enter the pad. The pad is 28 studs wide against a 48-stud pickup reach, so stand 3 studs outside the fence on the dumpster side and slide along it to line up with the target (`F.padSpot`).
  - Every other walk goes through PathfindingService (agent radius 2.5, aimed just short of the target, because buttons sit inside solid parts), with stuck detection: no progress for 1 s → jump, 2 s → give up.
  - The re-test trace never came within 4 studs of the fence.
- **The crusher's feed bin is a trap** (2026-10-11).
  - What happened: the old stuck-handler jumped when a walk stalled. A jump next to the crusher landed the character in `Crusher.FeedBin`, and it couldn't walk back out.
  - The unload step then waited at the pad 13 studs away, the server took nothing, and the farm logged "Unload Pad took nothing" in a loop with 7 blocks (394K) in hand.
  - Fix:
    - No jumping when stuck. After 1 s without progress, short 4-stud CFrame steps take over within 30 studs of the target.
    - Unload checks it's really on the pad (≤2.5 studs) before waiting.
    - The wait ends after 6 s with no block taken, instead of a fixed 15 s.
- **Base is 80x80 and contains the Unload Pad.** Auto Build's client gate (standing inside your own `Plot.Base`) is therefore met wherever the farm already goes, and the pad is the walk target when a build is due.
- **Fresh-account factory:** `Layout` = Start 0:5, Conveyor 0:4, Scanner 0:3, Polisher 0:2, Sell 0:1, with 5 spare Conveyors in Stock. The tutorial gave the Polisher, and UpgraderTutorialStage was 5 (done).

## Non-obvious findings (read from code)

- **The dumpster never sells.** Coins only come from blocks that reach the factory's Sell pad. The loop is rain → dumpster → loot → crush → blocks → Unload Pad → upgraders → Sell (spec "The loop").
- **Unloading has no remote.** The server pulls blocks from your inventory while you stand at the Start pad, which is exactly what the AutoLoader pass skips. That's why the pass can be recreated by walking, but not by any remote.
- **Rain upgrades go through `CoinUpgradeRequest(plot, "Rain", "One")`.** The `JunkRainUpgradeRequest` remote looks like the obvious one but has no caller: it's a honeypot.
- **Every pass is enforced server-side** (AutoLoader, InfiniteStorage, FastRain, DoubleSell, VIP, DroneLuck2x/4x), so faking attributes does nothing. Free recreations:
  - AutoLoader → walk-to-pad unloading
  - InfiniteStorage → loot-on-full plus dumpster levels
  - FastRain (+50%) → the Rain Speed card (+300% at level 30)
  - AutoClicker card → hub pickups at ~2.5/s on top of it
- **Factory Auto Build is free and has no pass check.** It re-lays out the **entire** factory into a fixed spiral, so it overwrites custom layouts. The 6 starter conveyors are always enough for every upgrader, so conveyors never need buying.
- **Each upgrader can be owned once** (Normalize caps non-Conveyor kinds at one in Layout). Coin upgraders are lost on rebirth; rebirth-token upgraders (Refabricator, Amplifier, Ion, PowerCore) are permanent.
- **Rebirth is a flat 1M but spends the whole balance.** Tokens = 1 + floor(log5(coins/1M)), so each extra token needs 5x the coins. The first 5 rebirths each add a permanent +0.5x coins. The hub's Smart mode rebirths at 1M until 5 rebirths, then waits while the next token arrives faster than this run's average time per token.
- **Gems are the `Diamonds` attribute.** `DiamondLevel` is the Diamond *mutation* level, not anything to do with gems.
- **Crates:**
  - `PaidRandomAllowed` (PolicyService) hides every crate when false, and the hub honours it.
  - The same remotes take a Robux form (`"Robux"` first argument, or `PremiumDroneCratePurchase(count)` without `"Gems"`). The hub's `call()` argument-locks them to `"Gems"`.
  - Limited stock (Akashic/Cinder) is only a "SOLD OUT" label. Those drones come from the Smelter (weight 0.01 each), and the one limited purchase remote is Robux (Planet Eater, 699 R$).
- **Offline earnings:** `OfflineEarningsAction("Claim")` is free and `"Double"` is 29 R$. The hub argument-locks it to `"Claim"`.
- **Junk Boss:** spawns after 150 pickups and lasts 20 s. While it's up, rain pickups are blocked client-side (`JunkBossActive`); crusher blocks and diamond junk aren't.
  - `JunkBossEvent("SetEnabled", false)` is the game's own off switch.
  - Killing it faster pays more: coin multiplier clamp(ceil(t*5), 30, 100), gems up to 2x.
- **Hourly quests:** 3 of 4 active per UTC hour, rotating on `HourlyQuestHour`. **Daily quests:** 1, or 2 once the main quest stage is past 4, rotating on `DailyQuestDay`. Both rotations are reproduced exactly, with no `require()`.
- **Diamond event:** join with `DiamondEventTeleport()` while `DiamondPhase == "Joining"`, then pick up `workspace.DiamondEventJunk` with the normal pickup remote (16 studs if `PlatformDiamond`, otherwise 96). Mega Crate rain and meteor crates have **no client claim code**. The hub uses the crate's prompt if it has one, otherwise walks onto it, and logs each drop's structure for the spec.

## Rules this script keeps

From [recon-quickstart](../notes/recon-quickstart.md) section 0.

- **Never fired, blocked in `call()`:**
  - the 7 `!NOCALLER` remotes
  - the admin panel remotes
  - every Robux remote (SkipRebirthPurchase, GemPackPurchase, MegaRainPurchase, StarterPackPurchaseRequest, GamepassGifting, LimitedDronePurchase)
  - trades
- **Argument locks:**
  - crates → `"Gems"`
  - offline → `"Claim"`
  - drones → `"EquipBest"` only, so scrapping can never go out
  - FactoryAction → `"Buy"` / `"AutoBuild"` (never `"Delete"`, `"Move"` or `"Place"`)
  - `SetAutoLoaderEnabled` → pass owners only
- **Pacing:** one shared action clock for every remote and prompt, ≥0.35 s apart plus jitter. RemoteFunctions time out after 10 s, so a hung invoke can't stall a loop.
- **Server-stored settings** (ReduceLag, HideOtherDrones, MusicMuted, the AutoLoader switch) are mirrored and only written when you change them. They're excluded from saved configs.

## Open questions (the hub logs the answers)

- Which event pays a fresh plot's sales (FactorySale wasn't seen for our plot).
- Whether factory Buy, dumpster and rebirth-shop purchases need you standing at the terminal or shop. Refusals are logged with the server's message.
- What the smelter consumes (blocks or looted junk). The first feed logs before/after counts.
- How Mega Crate and meteor crates are claimed (prompt or touch). Logged per drop.
- The rebirth snap diff (`f("snap","before")` / rebirth / `f("snap","after")`). It needs the user's OK because it wipes coins.
- `SmelterBatchJSON` timestamp fields. It was empty at capture.

Other projects: [battle-bot-project](../build-a-battle-bot/notes.md), [fix-it-up-project](../fix-it-up/notes.md), [needle-haystack-project](../needle-in-a-haystack/notes.md) (the walk-instead-of-remote pass recreation, again).
