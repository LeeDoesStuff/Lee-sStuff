# Junk Crushers 2 spec

PlaceId 73968232750026 · GameId 10656201650 · PlaceVersion **1616**, verified 2026-10-10 · creator: group 3876902 · framework: custom (flat remotes at the ReplicatedStorage root, state in player attributes) · StreamingEnabled **true** · 6 plots

**Sources.** Citations are `Script:line` into the decompiled client (`recon_73968232750026/src/`). Player scripts are `Players.<you>.PlayerScripts.<Name>` unless the path says PlayerGui. ReplicatedStorage modules are named as `RS.<Module>`.

**Status tags.** **measured** = observed live on v1616. Everything else is read from code. **UNVERIFIED** = server-side or not in the dump.

Not decompiled: `JunkRainConfig`, `MainQuestConfig`, `WorldChallengeConfig`, `RobuxShopConfig`. Their data is read from the GUI, or the hub tries the action and backs off.

---

## The loop

```
rain junk (Plot.Junk) --JunkPickupRequest--> dumpster --"Loot Dumpster" prompt--> InventoryFolder.Junk
  --"Crush Junk" prompt--> junk blocks roll out --"Pick Up All" / JunkPickupRequest--> Inventory.JunkBlocks
  --stand on Factory.Start.Base (no remote)--> conveyor --> each upgrader multiplies once --> Sell pad --> coins
```
- The tutorial's step list is literally `Pick8Cups, LootDumpster, CrushYourJunk, PutYourJunkBlockOnConveyor, BuyNewDumpster, UpgradeRain` (`PlayerGui.NewTutorialGui.NewTutorialClient:18`). `TutorialGuidanceClient:98-305` is a full "what to do next" state machine over the same loop.
- **The dumpster never sells by itself.** Coins only come from blocks reaching the Sell pad.
- **measured:** loot 60 → crush 60 → 60 blocks → Pick Up All → unload, about 13–14 s per cycle on a level-1 account.

## State source

- **Load gate:** `CoinDataReady == true` and `DataLoadState == "Ready"`.
- **Pause on:** `RebirthPending` (set while a rebirth saves; pickups are blocked: `JunkPickupClient:161`), `DroneSavePending` (blocks equips and buys), and `SkipPurchasePending`.
- **Values:**
  - `PlayerBalances.Coins` / `PlayerBalances.Junk` (numbers)
  - `leaderstats.Coins/Junk` (strings)
  - `InventoryFolder.Junk` (looted junk, not crushed yet)
  - `Inventory.JunkBlocks` (blocks carried)
- **JSON attributes** (decode with `HttpService:JSONDecode`, never `require` a module):
  - `FactoryDataJSON`: `{Version, StarterLayoutVersion, LoaderLayoutVersion, UpgraderOwnershipVersion, Stock={Kind=n}, Layout={["x:z"]={Kind, Rotation}}}`
  - `DroneInventoryJSON`: `{[droneId]=type}`
  - `DroneXPJSON`: `{[droneId]=xp}`
  - `JunkIndexJSON` / `JunkIndexClaimsJSON`: keys `"<Id>:<Variant>"`
  - `IndexMilestonesJSON`: string keys `"10".."200"`
  - `SmelterBatchJSON`
  - All of them are `"[]"` when empty.
- **Plot:** `workspace.Map.Plots[LP:GetAttribute("PlotName")]`, which must have `OwnerUserId == LP.UserId`. Plot attributes mirror the coin-board levels so other players' boards can render them.
- **Server time:** every timer uses `workspace:GetServerTimeNow()`.

### Plot anatomy

| Path | What | Source |
|---|---|---|
| `Plot.Junk` | rain junk and crusher blocks, as direct children | JunkPickupClient:178 |
| `Plot.RainSpawnPad` | rain area, 28 × 81 studs (**measured**) | MagnetRadiusClient:116 |
| `Plot.RainPadWalls` (4 parts) | made non-collide and non-query on the client | RainWallClickThrough:1-39 |
| `Plot.Decor.MeshPart` (fence) | **collidable**, along the pad edge facing the dumpster (**measured**) | live raycast |
| `Plot.Base` | plot floor, 80 × 80 (**measured**); build-mode gate | FactoryBuildClient:2027-2035 |
| `Plot.Dumpster.Dumpster` | attrs `CurrentCapacity`, `MaxCapacity`, `InfiniteStorage`; prompt `LootDumpsterPrompt` | JunkPickupClient:84-95 |
| `Plot.Crusher` | attrs `CycleStartedAt`, `CycleDuration` (7), `StackCount`, `LastCrushedJunk`, `ControllerReady`; `FeedBin.Panel.Button` (prompt), `StackPickup` (prompt), `ActivateCrusher` (server BindableEvent: useless from the client) | CrusherFeedVisualClient:204; **measured** attrs |
| `Plot.JunkRainUpgrader.ButtonHitboxes.<Key>_<One/Max>` | coin board ClickDetectors, 36 studs (**measured**) | CoinUpgradeBoardClient:423-466 |
| `Plot.CrusherUpgradePart` | crusher upgrade SurfaceGui | CrusherUpgradeClient:116 |
| `Plot.Factory.Start.Base` | Unload Pad, inside Base (**measured**) | TutorialGuidanceClient:253-261 |
| `Plot.Factory.Pieces` | placed pieces with `GridX`/`GridZ` | FactoryBuildClient:1343-1381 |
| `Plot.Smelter` | attrs `Smelting`, `PendingRewards`; `InputPart` prompt, claim prompts | SmelterClient:79-98 |
| `Plot.DailyChest` | group chest model; `Base.GroupChestPrompt` | SupportGameClient:111,561 |
| `Plot.PersonalJunkBoss` | boss model (attrs `Health`, `MaxHealth`, `BossName`) | JunkBossClient:232-240 |
| `Plot.AutoLoaderPassAd` | gamepass advert prompt: **never** | WorldPurchaseAdverts:406-580 |

**Junk instance attributes:**
- `Collected`, `Claimed`
- `ProducedByCrusher`, `RollingOut`, `StackedCrusherBlock`, `OnConveyor`
- `HandPlacementStartedAt/From/Target`
- `PlanetCollectAt`, `JunkSize` ("Planetary"…), `PlanetFallFrom/To/StartedAt`
- `PlatformDiamond`

The child ObjectValue `OriginalJunk` maps a click proxy to the real junk (JunkPickupClient:252-256). **measured:** each junk has a `JunkClickDetector` (40 studs) and a `JunkClickTarget.ClickDetector` (48 studs).

---

## Currencies

| currency | where | faucet | sink | survives rebirth? | Robux-buyable? |
|---|---|---|---|---|---|
| Coins | `PlayerBalances.Coins` | Sell pad, quests, daily reward, offline, boss | coin board, crusher, dumpster, factory upgraders, rebirth (whole balance) | no | yes: packs (never touched) |
| Gems | attr **`Diamonds`** | rebirth (~50/token), index, quests, smelter, events, boss, Afterburner/Harbringer drones | drone crates, event upgrades | yes | yes: gem packs (never touched) |
| Rebirth tokens | attr `RebirthCoins` | rebirth | rebirth shop, rebirth crate | yes | no |

`DiamondLevel` is the Diamond **mutation** level. It has nothing to do with gems.

---

## Core junk loop

### Rain
- Junk spawns in `Plot.Junk` over the rain pad.
- Drops/sec as shown on the board = `MeteorRainMultiplier (RS attr) * (FastRain and 1.5 or 1) * (1 + 0.1*RainSpeedLevel + IndexRainBonus)` (CoinUpgradeBoardClient:631).
- The junk tier follows `JunkRainLevel` through JunkRainConfig (not decompiled).
- Planetary junk falls for 1.4 s and can't be picked up before `PlanetCollectAt` (PlanetaryRainClient:14,45; JunkPickupClient:220).
- Meteor/rainbow sky is cosmetic (MeteorSkyClient:34). `RS.MeteorRainMultiplier` is the global meteor boost (1.5 at capture).

### Pickup: `JunkPickupRequest:FireServer(target, predictId?)`
Called at JunkPickupClient:308. Client gates (:161-233):
- humanoid alive, `CoinDataReady`, not `RebirthPending`
- target is a direct child of your `Plot.Junk` (owner = you) or of `workspace.DiamondEventJunk`, and is not `Collected`/`Claimed`

Ranges are measured from the HRP to the closest point of the target's bounding box (`inRange` :58-78):

| target | range | extra conditions |
|---|---|---|
| rain junk | 48 | not `JunkBossActive`, and `GetServerTimeNow() >= PlanetCollectAt` |
| crusher block (`ProducedByCrusher`) | 12 | not `RollingOut` / `StackedCrusherBlock` |
| diamond-event junk | 96 | 16 if `PlatformDiamond` |

- `predictId` is a per-session counter (:100-101). It's **nil** when the dumpster is full and InfiniteStorage is off, for normal junk only (:95-96).
- The server answers `DiamondPickupFeedback(predictId, accepted)`.
- **measured:** our own counter starting at 1,000,001 is accepted.
- The client picks targets by raycasting from the mouse and retrying 8 offsets at 7/14 px (24 on touch) (:236-305). The server can't see any of that.

### Dumpster
- The `LootDumpsterPrompt` prompt moves the dumpster's junk to `InventoryFolder.Junk` and resets `CurrentCapacity`. The server then sends `DumpsterLootVisual`.
- Partial loots are allowed: the tutorial says "loot" whenever capacity > 0 (TutorialGuidanceClient:199-216).
- Full → the server sends `DumpsterFullWarning` (FullDumpsterNotifier:11).
- **measured:** `MaxCapacity` was 60 at `DumpsterLevel` 1. The client's fallback is 25, so always read the attribute.
- Levels via `DumpsterPurchaseRequest:FireServer(level)` with level = `DumpsterLevel+1` (DumpsterPurchasesClient:57; the client only refuses `level <= DumpsterLevel`).
  - Result: `DumpsterPurchaseResult(level, ok, reason)`, reason ∈ `AlreadyOwned`, `Busy`, `NotEnoughCoins`, `NoPlot`, `MissingCoins` (:99-118).
  - Costs (DumpsterPurchasesClient:18-36): L2 30, L3 500, L4 4.5K, L5 20K, L6 60K, L7 180K, L8 550K, L9 1.5M, L10 4.5M, L11 13M, L12 120M, L13 1B, L14 5B, L15 100B, L16 1T, L17 10T, L18 500QD.
  - `RS.DumpsterMaxAvailable` = 17. L2 is free during tutorial step 5 (:73-84).
  - **Never** the `BuyNextRobux` button (product 3712535016).

### Crusher
- **measured:** "Crush Junk" is a ProximityPrompt at 12 studs, hold 0, under `Crusher.FeedBin.Panel.Button`.
- The cycle sets `CycleStartedAt` and lasts `7 - CrusherSpeedLevel` s (CrusherUpgradeConfig:20-23).
- Too little looted junk → `Need10JunkWarning` ("Collect junk from your dumpster first!"). The name suggests a minimum of 10 (UNVERIFIED).
- **measured:** crushing 60 looted junk produced 60 blocks.
- Upgrade: `CrusherUpgradeRequest:FireServer(plotName)` (CrusherUpgradeClient:164).
  - Gates: owner, `CoinDataReady`, not pending.
  - 4 levels: 1K / 10K / 100K / 1M.
  - Result: `CrusherUpgradeResult(plotName, ok, text)`.

### Blocks
- Blocks appear in `Plot.Junk` with `ProducedByCrusher`. While `RollingOut` they show "Wait for your block".
- **measured:** `Crusher.StackPickup.CollectStack` "Pick Up All" (12 studs, enabled only while a stack exists) takes the whole stack.
- Single blocks use `JunkPickupRequest` within 12 studs. `StackedCrusherBlock` blocks are excluded from single pickup.

### Unload (no remote)
- "Stand near the start to unload your blocks" (TutorialGuidanceClient:253-262). The server pulls blocks from `Inventory.JunkBlocks` onto the conveyor.
- It broadcasts `FactoryTransit(block|nil, fromCF=hand, toCF=start cell, 0.45, true)` and stamps `HandPlacementStartedAt/From/Target` (FactoryBuildClient:1593-1665).
- **measured:** standing within 1.5 studs of `Factory.Start.Base`'s centre unloaded 60 blocks in about 5 s.

### Coin board: `CoinUpgradeRequest:FireServer(plotName, key, mode)`
Called at CoinUpgradeBoardClient:410. key ∈ `Rain, Speed, Slots, DroneSpeed, AutoClicker`; mode ∈ `"One"`/`"Max"` (`Slots` is One only, :318-319). Client gates:
- owner, not pending, 0.3 s debounce (:388)
- not rebirth-locked (every `RequiredRebirths` is 0)
- cost ≠ nil, not `RebirthPending`

The result comes back as `CoinUpgradeResult(plotName, key, ok, text, count, mode)` (:749). Pending times out after 4 s.

| key | level attr | costs | effect |
|---|---|---|---|
| Rain | `JunkRainLevel` (from 1) | JunkRainConfig[level+1].Cost (**not decompiled**; read from the `Rain` card text or try and back off) | next junk tier, likely in JunkIndexConfig order |
| Speed | `RainSpeedLevel` 0..30 | 100, 1K, 10K, 100K, 1M, 20M, 200M, 2B, 4B, 8B, 16B, 32B, 64B, 128B, 256B, 308B, 368B, 444B, 532B, 640B, 9.6T, 11.55T, 13.85T, 16.65T, 20T, 24T, 28.85T, 34.65T, 41.65T, 50T | +0.1 rain mult per level |
| Slots | `DroneSlots` 1..3 | slot 2 = 10K, slot 3 = 10M (cap `RebirthConfig.DroneSlotCap` = 3) | drone slots |
| DroneSpeed | `DroneSpeedLevel` 0..20 | 5K, 15K, 45K, 200K, 1M, 10M, 50M, 100M, 1B, 10B, then x20 each up to 1.024e23 | +5% drone collection speed |
| AutoClicker | `AutoClickerLevel` 0..16 | 5K, 150K, 2.25M, 6.75M, 20.25M, 60.75M, 182.25M, 546.75M, 1.64B, 4.92B, 14.76B, 44.29B, 132.86B, 398.58B, 1.196T, 3.587T | server auto-pickup every `max(0.5, (21-L)/10)` s |

Sources: CoinUpgradeConfig:8-58.

### Junk values (JunkIndexConfig:6-281, value order = tier order)
- Cup 5 · Plank 8 · Pipe 15 · Table 25 · Tire 50 · Dumbbell 80 · Bench Press 120 · Tuk Tuk 200
- Small Boat 400 · Forklift 1K · Roof 1.8K · Tent 2.7K · Excavator 4K · Camper 6K
- Mining Dump Truck 10K · Locomotive 16K · Bulldozer 25K · Cargo Helicopter 40K · Garbage Truck 80K
- Cargo Ship 160K · Skyscraper 320K · Airplane 640K · Road 1.28M · Crane 2.56M
- Exotic: Nuclear Reactor 5.12M … Rocket 81.92M
- Alien: 163.84M … 1.31B
- Angelic: 2.62B … 41.9B
- Infernal: 83.9B, 167.8B
- plus 6 Planetary entries

There are 50 ids. The variants Normal / Gold / Diamond / Atomic give 200 index keys. Mutations multiply junk value by 3 / 10 / 30 (RebirthConfig:12-37).

### Magnet
`JunkMagnetLevel` 0–3 gives a server-side radius pickup of 0 / 6 / 10 / 14 studs. It costs 4 / 8 / 16 rebirth tokens and is permanent (RebirthShopClient:331,459-507; MagnetRadiusClient:7,44-46).

---

## Factory

### Grid and flow (RS.FactoryConfig)
- **Grid:** 6×6 cells of 6 studs (FC:4-6). Cells are `(x,z)` 0..5 and layout keys are `"x:z"` (FC:214-216).
- **World frame:** the top of `Base`, facing `BuyRainUpgrade.CFrame.LookVector` (FC:218-250).
- **Rotation r** (0..3) gives the exit offset `{0,-1},{1,0},{0,1},{-1,0}` (FC:515-626).
- **`CanEnter` (FC:191-212):**
  - Start can never be entered.
  - Sell can always be entered.
  - An upgrader (Mult > 1) can only be entered straight (same rotation), so upgraders can't sit on corners.
  - A conveyor accepts anything except head-on input.
- **Start:** picks the direction with the longest valid route, preferring routes that reach Sell (FC:573-626).
- **Movement:** a block hops one cell per 0.9 s (`FactoryTransit(block, fromCF, toCF, 0.9)`).
- **Upgraders:** each fires `FactoryUpgradeFX(block, kind, cf, before, after)`.
- **Sale:** `FactorySale(plot, cf…, value)`.
- **All three are broadcast for every plot.** The spy saw Plot6's line while we owned Plot3, so filter by plot.
- **Final value** = base × the product of the multipliers of every upgrader on the route. Off-route upgraders add nothing.
- **Normalize (FC:425-513):**
  - Stock is clamped to 0..100 and Conveyor to 0..136.
  - **Each non-Conveyor kind appears in the Layout at most once.**
  - A missing Sell is re-added.

### Upgraders (FC:7-167)

| Id | Name | Price | Currency | Mult | Notes |
|---|---|---|---|---|---|
| Conveyor | Conveyor | 100 | Coins | 1 | starter kit has 6, always enough |
| Scanner | Scrap Scanner | 5K | Coins | 1.2 | hidden from shop, always granted |
| Polisher | Twin Polisher | 1K | Coins | 1.4 | free at UpgraderTutorialStage 1–2 |
| WoodenSmelter | Wooden Smelter | 25K | Coins | 1.6 | |
| Laser | Laser Refiner | 100K | Coins | 1.5 | |
| Press | Power Press | 2.5M | Coins | 1.75 | |
| Furnace | Spectrum Upgrader | 100M | Coins | 2 | |
| IndustrialSmoker | Industrial Smoker | 5B | Coins | 1.5 | |
| DrumRefiner | Drum Refiner | 10T | Coins | 1.8 | |
| PrismaticReactor | Refabricator | 6 | tokens | 2.5 | permanent |
| RebirthAmplifier | Rebirth Amplifier | 15 | tokens | 3 | permanent |
| IonAccelerator | Ion Accelerator | 20 | tokens | 1.5 | permanent |
| NewRebirthConveyor | PowerCore Boosters | 30 | tokens | 2.5 | permanent |
| EventUpgrader / AngelicPowerCore | Volcanic Forge / Angelic PowerCore | — | — | 1.5 | retired (legacy grants) |
| CityUpgrader | City Upgrader | 1000 | Diamonds | 1.5 | no client buy path |

`FactoryConfig.ProductIds` covers Robux versions of Polisher, WoodenSmelter, Laser, Press and Furnace (FC:168-174). **Never.**

### FactoryAction (RemoteFunction) → `(ok, message)`
Wrapper `request()` at FactoryBuildClient:801-867, single-flight.

| verb | args | notes |
|---|---|---|
| `"Buy"` | id | coin items only. RebirthCoins items are sent as `RebirthShopAction(id)` instead (:813-815). The shop opens on server `FactoryOpen` (a parts terminal); whether Buy needs it is UNVERIFIED |
| `"Place"` | kind, x, z, rot | Stock ≥ 1 and cell empty |
| `"Delete"` | nil, x, z | returns the piece to Stock (doesn't sell it) |
| `"Move"` | … | **no UI reaches it: never** |
| `"AutoBuild"` | — | free, no pass check. Retries on `"Please wait."` / `"Data is loading."` every 0.35 s for up to 8 s (:829-846) |

- **Build-mode gate:** the HRP must be inside your own `Plot.Base` bounds, no modal may be open, and the main tutorial must be complete (:2004-2063).
- **Auto Build (FC:628-793)** lays everything owned along a fixed inward spiral:
  - The spiral: `(0,5..0) → (1..5,0) → (5,1..5) → (4..1,5) → (1,4..1) → (2..4,1) → (4,2..4) → (3..2,4) → (2,3..2) → (3,2) → (3,3)`.
  - Start comes first, then a conveyor; every corner is a conveyor.
  - Straight cells take upgraders in Items order, with Sell after the last one.
  - There are 23 straight slots.
  - **It overwrites any custom layout.**
- **Rebirth (`AfterRebirth`, FC:370-399):**
  - The factory resets to 6 Conveyors + Scanner + Sell + one of each owned permanent, in a Prebuilt layout (Start 0:5 … Sell).
  - Coin upgraders are lost.
- **measured, fresh account:** Layout = Start 0:5, Conveyor 0:4, Scanner 0:3, Polisher 0:2, Sell 0:1. Stock: Conveyor 5, everything else 0. `UpgraderTutorialStage` 5.

### Upgrader tutorial
`UpgraderTutorialStage` 1 → GO button `UpgraderTutorialGo:InvokeServer()`. Stage 2 → the free Polisher. Stage 3 → Hammer → Auto Build. Reward: +2000 coins (`UpgraderTutorialRewardFX`). Source: UpgraderTutorialClient:192-535.

### AutoLoader pass (1982252451)
- Attributes `AutoLoader` (owned) and `AutoLoaderDisabled` (the owner's setting).
- Owners toggle it with `SetAutoLoaderEnabled:FireServer(enable)`. The game sends `AutoLoaderDisabled == true`, which means "turn it back on" (SettingsClient:304-327).
- Inferred: the server unloads `JunkBlocks` without the player standing on the pad. It does **not** press the crusher.
- **Free recreation:** walk to `Factory.Start.Base` and stand there (that's how the hub does it).

### Smelter
- **No remote.** Prompts under `Plot.Smelter`:
  - the input prompt on `InputPart` ("SMELT BLOCKS", 10 studs: **measured**)
  - claim prompts, enabled when owned and not `ClaimInProgress`
  - the input is disabled while `Smelting` (SmelterClient:270-306)
- **Batch:** 600 s. Pays 2 / 3 / 4 / 5 rewards at 50 / 30 / 15 / 5 %.
- **Rolls** (SmelterConfig:6-79):
  - CoinPotion and LuckPotion 2x for 5 / 10 / 15 min, weights 10 / 5 / 2.5
  - Gems (weight 10, 100–1000)
  - Drone1–2 (10 each), Drone3–4 (5), Drone5 (3), Drone6 (2), Drone7 "Halo" (0.01), Cinder (0.01)
- Long potions scale down when the input value is low (`LongPotionScale`: floor 10K, cap 5B).
- **Potions apply on claim** and set `SmelterCoinBoostUntil` / `SmelterLuckBoostUntil` (epoch). There's no inventory and no "use" remote.
- The server fires `SmelterInputFX` with junk visual names on input, so the smelter may take raw junk. The prompt text says blocks. UNVERIFIED: the hub logs before/after counts.

---

## Rebirth

- **Request:** `RebirthRequest:FireServer()` (RebirthClient:746). Result `RebirthResult(success, msg, rebirths)`.
- **Client gate:** coins ≥ **1,000,000**, `CoinDataReady`, not `RebirthPending` / `SkipPurchasePending`. The cost is flat (`RebirthCost` = 1e6, RebirthConfig:71-73) but **the whole balance is spent**.
- **Rewards (RebirthConfig:75-119):**
  - **Tokens** `RebirthCoinReward(c)` = 0 below 1M, else `1 + floor(log5(c/1e6))`, capped at 100. So 1M→1, 5M→2, 25M→3, 125M→4, 625M→5…
  - **Gems** = `round((min(t,30)*100 + max(0,t-30)*50) * 0.5 * G)`, with G = `1 + 0.2*EventGemLevel` (VIP raises it).
  - **Permanent coin multiplier** `1 + 0.5*min(Rebirths, 5)`, so 3.5x after 5 rebirths.
- **Resets:** coins, coin-board levels, dumpster, junk, blocks, coin upgraders (the factory goes back to Prebuilt).
- **Keeps:** gems, drones, passes, rebirth-shop purchases, magnet, mutations (RebirthClient:400-401).
- **Never** `SkipRebirthPurchase` (Robux product 3712171291).
- **Optimal timing, as the hub's Smart mode does it:**
  1. Rebirth at 1M until you have 5 rebirths (+0.5x each).
  2. After that, rebirth when `(1e6*5^k - coins) / income > timeThisRun / k`, i.e. when the next token would take longer than the average time per token so far.
  3. Hold off during the boss, the diamond platform, or any event trip.

### Rebirth shop: `RebirthShopAction:InvokeServer(id)` → (ok, msg)
Source: RebirthShopClient:329-524,664. The UI opens on `RebirthShopOpen` near `workspace.RebirthShop.RebirthRig`. Whether the server checks distance is UNVERIFIED.

| id | cost (tokens) | max | effect |
|---|---|---|---|
| JunkMagnet | 4 / 8 / 16 | 3 | magnet 6 / 10 / 14 studs |
| Gold / Diamond / Atomic | unlock 1 / 3 / 6, then `2^level` (`MutationTokenCost`, RebirthConfig:135-140) | level 10 | mutation chance (5+level)%, value x3 / x10 / x30 |
| PrismaticReactor | 6 | once | factory x2.5 |
| RebirthAmplifier | 15 | once | factory x3 |
| IonAccelerator | 20 | once | factory x1.5 |
| NewRebirthConveyor | 30 | once | factory x2.5 |
| DroneLuck | `2^(lvl+1)` = 2 / 4 / 8 / 16 | 4 | +0.5x crate luck |

---

## Drones

- **Collection is entirely server-driven.**
  - Models live in `workspace.EquippedDrones.<UserId>_<slot>`.
  - The server writes `MoveFrom/MoveTo/MoveStart/MoveDuration/MoveSequence` and the target ObjectValue `TargetJunk`. The client only interpolates (DroneFlightClient:152-389).
  - During the boss, drones orbit it and hit it.
- **Collection time:** `Times[size] / (1 + 0.05*DroneSpeedLevel)` (DroneConfig:276-283).
- **XP and levels:** levels 1–10 at `{75,150,300,600,900,1200,1500,1800,3000}` XP (max 9525), +5% strength per level (DroneProgressionConfig). XP is granted server-side; there's no client booster.
- **Equip:** `DroneEquipRequest:FireServer(id, "Equip"|"Unequip")`.
  - The game's own **Equip Best** is `DroneEquipRequest:FireServer("", "EquipBest")` (DroneInventoryClient:1013).
  - Gate: `CoinDataReady`, not `DroneSavePending`.
  - **`(id, "Scrap", 1|5|10|"All")` destroys drones: never** (the hub's argument lock refuses it).
- **Slots** = `DroneSlots` (coins, max 3) + `PaidDroneSlots` (Robux) + `GiftedDroneSlots` + VIP (DroneSlotConfig:8-22). Equipped ids are in `EquippedDrone`, `EquippedDrone2`, `EquippedDrone3`, …
- **Strength (DroneConfig:320-337), the game's `Best()` ranking:**

  | Drone | Strength |
  |---|---|
  | PlanetEater | 350 |
  | Harbringer | 300 |
  | Halo (Drone7) / Cinder | 137.6 |
  | Drone6 / PrismLeviathan / Reforge | 106.5 |
  | Drone5 / VoidDrone / Afterburner | 77.6 |
  | GildedGriffin | 42.3 |
  | Drone4 | 41.0 |
  | AmethystMantis | 16 |
  | Drone3 | 14.4 |
  | Drone2 / CobaltScout | 7.5 |
  | Drone1 | 5 |

  x1.45 at level 10. `Best()` ignores PrismLeviathan's +30 `TeamStrengthBonus` per equipped drone, pickup counts (Drone7 x2, Cinder x4), Drone5's x1.25 value, and the pulse abilities.

### Crates (in-game currency only)

| crate | call | cost | odds (luck x1) |
|---|---|---|---|
| Normal | `NormalDroneCratePurchase:InvokeServer("Gems", 1\|3)` | 100 gems | Bin Tracker 56.69 · Industrialist 25 · Heavy Duty 13 · Junk Hunter 4 · Colossus 1 · Reactor Overlord 0.3 |
| Infernal | `NormalDroneCratePurchase:InvokeServer("Gems", 1\|3, "Infernal")` | 300 gems | Cobalt Scout 54.77 · Amethyst Mantis 38.63 · Gilded Griffin 5 · Prism Leviathan 1.5 |
| Rebirth | `RebirthDroneCratePurchase:InvokeServer(1\|3)` | 10 tokens | Reforge 70 · Afterburner 28 · Harbringer 2 (no luck) |
| Mega | `PremiumDroneCratePurchase:InvokeServer(1, "Gems")` → (ok, msg) | 10,000 gems | Colossus 40 · Afterburner 40 · Drone6 8 · Prism 8 · Planet Eater 2 · Harbringer 2 (no luck) |

Sources: NormalCratePurchaseClient, InfernalCratePurchaseClient, RebirthCratePurchaseClient, MegaCrateDisplayClient; RS.DroneConfig:285-297, InfernalDroneCrateConfig, RebirthDroneCrateConfig, PremiumDroneCrateConfig.

- **Results** arrive on `DroneResult` (`"Unboxed"` {Id, Type, Crate}, `"UnboxedBatch"` {Results}, or `"Error"` {Message, Cost}) and `PremiumDroneCrateResult` {[id]=type}.
- **Gates:**
  - `PaidRandomAllowed == true` (PolicyService; otherwise every crate UI is hidden).
  - Debounce: 0.8 s for crates, 1 s for mega.
  - Billboards show within 18 studs of `workspace.DroneShop.DroneCrate` / `InfernalDroneCrate` / `RebirthShop.RebirthCrate.RebirthDroneCrate`, and within 40 of `MegaDroneCrate`. A proximity check on the server is UNVERIFIED, so the hub stands near the crate.
- **Robux forms (never; the hub's argument lock refuses them):**
  - `"Robux"` as the first argument
  - `PremiumDroneCratePurchase(count)` without `"Gems"`
  - `LimitedDronePurchase` (Planet Eater, 699 R$)
- **Limited stock** (`AkashicRemaining`, `CinderRemaining` on RS) only drives "SOLD OUT" labels. Halo and Cinder come only from the Smelter.

**Luck (DroneLuckConfig):**
- `Personal = max(1,Pass) + 0.5*DroneLuckLevel + 0.1*EventLuckLevel + PremiumLuckBonus`
- Every outcome except the first is multiplied by Personal.
- Welcome or smelter luck shifts mass from Common/Rare/Epic into Legendary+.
- `AdminGlobalLuckMultiplier` stacks on top.

---

## Claims, quests, timers

| claim | call | gate | clock |
|---|---|---|---|
| Welcome boost | `ClaimWelcomeBoost:InvokeServer()` | `WelcomeBoostReady and WelcomeBoostPending` | per session; sets `WelcomeBoostUntil` (2x coins + 2x luck) |
| Daily reward | `ClaimDailyReward:InvokeServer()` | `DailyRewardsReady and DailyNextClaim <= now` | 86400 s cooldown (not calendar). Day `DailyRewardCount % 7 + 1`: 200 coins · Junk Hunter · 1K gems · 1B coins · 3K gems · 100B coins · Reactor Overlord |
| Offline | `OfflineEarningsAction:InvokeServer("Claim")` | `OfflineCoins > 0` | `"Double"` is **29 R$: never**. A free double credit is used automatically if `OfflineDoubleCredits > 0` |
| Hourly quest | `ClaimCollect1K:InvokeServer(Kind)` | `Hourly<Kind>Progress >= Target`, not claimed, active this hour | top of the UTC hour |
| Daily quest | `ClaimDailyQuest:InvokeServer(Kind)` | progress ≥ target, not claimed | UTC midnight |
| Main quest | `ClaimMainQuest:InvokeServer(stage)` | `MainQuestDone<stage>`, stage ≤ 4 | one-time chain |
| Junk index entry | `JunkIndexClaim:FireServer(id, variant)` | key discovered and unclaimed | wait for `JunkIndexResult(ok, msg)`. Pays 10 / 20 / 30 / 40 gems (Normal / Gold / Diamond / Atomic) |
| Index milestone | `JunkIndexClaim:FireServer("__milestone", "N")` | N = lowest unclaimed multiple of 10 ≤ discovered count (max 200) | 80 → 500 gems · 90 → +0.1x coins · 100 → +1 drone slot · 110–150 → 1K gems · 160–190 → 2K gems · 200 → Mega Crate · 10–70 → seeded random of {100/250 gems, +0.1x coins, +10% rain} |
| Group chest | `ClaimGroupChest:InvokeServer(Plot.DailyChest)` | `GroupChestNextClaim <= now` | returns (ok, msg, status). `"JoinGroup"` means you're not in group 3876902. **Not `ClaimGroupReward` (honeypot)** |
| World challenge | prompt `workspace.WorldChallenge.RewardPromptPart.ClaimWorldReward` | `prompt.Enabled` (global goal reached) and not `WorldChallengeRewardClaimed` | one-time, 1,000 gems |
| Skip tutorial | `SkipTutorial:InvokeServer()` | tutorial steps 1–6 | may forfeit the tutorial drone crate (not automated) |

**Quest rotation (RS.QuestRotationConfig):**
- **Hourly** = `{Coins "Collect 1K Junk" 1000, Diamond "Pick Up 10 Diamond Junk" 10, Playtime "Play 30 Minutes" 1800, Blocks "Pick Up 30 Junk Blocks" 30}`. Active: `Hourly[(HourlyQuestHour+i) % 4 + 1]` for i = 0..2.
- **Daily** = `{Crates "Open 15 Drone Crates" 15, Rebirth 1, Mega "Open a Mega Crate" 1, Rain "Buy 20 Junk Rain Upgrades" 20}`.
  - Slot 1 = `Daily[D % 4 + 1]`, tracked in `DailyQuestProgress` / `DailyQuestClaimed`.
  - Once `MainQuestStage > 4`, slot 2 = `Daily[(D+1) % 4 + 1]`, tracked in `Daily<Kind>Progress` / `Daily<Kind>Claimed`.
- Main quest objectives are in MainQuestConfig (not decompiled). Read them from the Quest GUI.

---

## Events

- **Junk Boss (RS.JunkBossConfig):**
  - The meter is `JunkBossProgress` out of 150 pickups.
  - On/off: `JunkBossEvent:FireServer("SetEnabled", bool)` (attr `JunkBossEnabled`).
  - Server events: `"Start"(model, endsAt, maxHp)`, `"Hit"`, `"Victory"`, `"Reward"(coins, gems)`, `"Failed"`, `"End"`. It lasts 20 s.
  - Damage: `JunkBossEvent:FireServer("Click", Plot.PersonalJunkBoss)`. The client only checks that a mouse ray hits the boss.
  - HP(L) = `round(100*L*1.03^(L-1) * (0.5 if 2≤L≤20))`. Click damage = `5*L`, with L ≈ JunkRainLevel.
  - Reward multipliers by time left t: coins `clamp(ceil(5t), 30, 100)`; gems 2.0 if t ≥ 18, scaling down to 0.6.
  - While it's up, `JunkBossActive` blocks rain pickup. It doesn't block blocks or diamonds.
- **`RS.DiamondEventState`:** attributes `Active`, `EventType` (Diamond/Meteor), `EndsAt` (next start when inactive), `DiamondPhase` (Joining / collecting / Returning), `JoinEndsAt`, `ReturnAt`, `CollectedDrops`, `PlannedDrops` (40) (DiamondTimerClient:21-77).
  - **Diamond:**
    - Join with `DiamondEventTeleport:InvokeServer()` while Joining (EventAnnouncementClient:186-224). That sets `AtDiamondPlatform`.
    - Collect `workspace.DiamondEventJunk` children with `JunkPickupRequest`. The dumpster cap doesn't apply, and they aren't blocked by the boss.
    - On the platform, `BuyDiamondUpgrade:InvokeServer("Gems"|"Luck")` (DiamondPlatformClient:276-299):
      - Gems: `EventGemLevel` ≤ 10, cost (L+1)*50, +0.2x rebirth gems.
      - Luck: `EventLuckLevel` ≤ 30, cost (L+1)*100, +0.1x crate luck.
  - **Meteor:** +50% rain (`MeteorRainMultiplier`) and "Loot the falling Drone Crates!" at `workspace.MeteorEventDrops.Meteor<N>.RewardDroneCrate`. **No client claim code.**
- **`RS.MegaCrateEventState.Active`:** "Grab the 4 FREE Mega Crates!". Models go into `workspace.MegaCrateEventDrops` with attrs `FallStart` and `FallTarget`, and land at `FallStart + 1.35 s` (MegaCrateDropMotion). **No client claim code**, so it's a prompt or a touch on the server. `workspace.MegaDroneCrate` is the shop crate, not a drop.

---

## Gamepasses
Every pass effect is server-side, so faking ownership attributes does nothing.

| pass | effect | free recreation in jc2_main.lua |
|---|---|---|
| AutoLoader (1982252451) | server unloads blocks | Unload blocks: walk to the Unload Pad |
| InfiniteStorage | dumpster attr `InfiniteStorage` | loot-on-full + Bigger dumpster |
| FastRain | 1.5x rain | Rain Speed card (+300% at 30) |
| DoubleSell | 2x sale value | none. Stack the free 2x coin boosts (welcome, smelter potion, daily quest), rebirth multiplier, index +0.1x |
| VIP | +1 slot, gem/coin boosts | none |
| DroneLuck2x / 4x | crate luck | DroneLuck from the rebirth shop, event Luck, welcome/smelter luck windows |
| ExtraDroneSlot | +1 slot | coin slots (max 3), index milestone 100 |

---

## Remotes

| remote | shape | caller | honeypot / forbidden? |
|---|---|---|---|
| JunkPickupRequest | (inst, seq) | JunkPickupClient:308 | no |
| CoinUpgradeRequest | (plot, key, mode) | CoinUpgradeBoardClient:410 | no |
| CrusherUpgradeRequest | (plot) | CrusherUpgradeClient:164 | no |
| DumpsterPurchaseRequest | (level) | DumpsterPurchasesClient:57 | no |
| FactoryAction | (verb, …) | FactoryBuildClient:817 | Move: never |
| RebirthRequest | () | RebirthClient:746 | no |
| RebirthShopAction | (id) | RebirthShopClient:664 | no |
| DroneEquipRequest | (id, op) | DroneInventoryClient:825-1054 | Scrap: never |
| Normal/RebirthDroneCratePurchase, PremiumDroneCratePurchase | see Crates | crate clients | Robux forms: never |
| BuyDiamondUpgrade, DiamondEventTeleport | see Events | DiamondPlatformClient, EventAnnouncementClient | no |
| JunkBossEvent | ("Click", boss) / ("SetEnabled", b) | JunkBossClient:536, BossProgressClient:74 | no |
| ClaimCollect1K / ClaimDailyQuest / ClaimMainQuest / ClaimDailyReward / ClaimWelcomeBoost / ClaimGroupChest / JunkIndexClaim | see Claims | their clients | no |
| OfflineEarningsAction | ("Claim") | OfflineEarningsClient:393 | "Double": Robux |
| TeleportToBase / TeleportToShops | () | BaseTpGui / TpGui | no |
| UpdatePlayerSetting | (key, bool) | SettingsClient | no |
| SetAutoLoaderEnabled | (bool) | SettingsClient:322 | pass owners only |
| UpgraderTutorialGo / SkipTutorial | () | UpgraderTutorialClient:202 / NewTutorialClient:371 | no |
| PrivatePlaytimeQuery, PrivatePlaytimeDevice, AdminPlayerStats, JunkRainUpgradeRequest, JunkRainUpgradeResult, ClaimGroupReward, SetBigJunkScale | — | **no caller** | **honeypot: never** |
| AdminActivateEvent, AdminSetGlobalBoost, AdminToggleFlight, SendAdminAnnouncement | — | admin panel (UserId 372272914 only) | **never** |
| SkipRebirthPurchase, GemPackPurchase, MegaRainPurchase, StarterPackPurchaseRequest, GamepassGifting, LimitedDronePurchase | — | Robux shop | **never** |
| DroneTradeInvite / DroneTradeSession | — | trade UI | not automated |

**Server → client only:**
- Junk: JunkCollectVisual, JunkClickSound, DiamondPickupFeedback, DumpsterFullWarning, Need10JunkWarning, DumpsterLootVisual, JunkSoldEvent
- Factory: FactorySale, FactoryTransit, FactoryUpgradeFX, FactoryOpen
- Upgrade results: CoinUpgradeResult, CrusherUpgradeResult, DumpsterPurchaseResult, RebirthResult, JunkIndexResult
- Drones: DroneResult, PremiumDroneCrateResult, RareDroneAnnouncement, ExoticDronePulse
- Smelter: SmelterInputFX, SmelterRewardSound
- Rewards and boosts: OfflineRewardFX, UpgraderTutorialRewardFX, EventUpgraderResult, AdminAnnouncement, AdminBoostAnnouncement

## Anti-cheat / risks
- **Client:** none. No kicks, WalkSpeed/JumpPower watchers, LogService, gcinfo or debug.info.
- **Server:** distance checks on pickups are almost certain (48 / 12 / 96 / 16). Rate limits are unknown. The hub paces every remote and prompt ≥0.35 s apart.
- **Staff:** the admin panel means staff can trigger events and global boosts.

## Rebirth diff
Not measured yet: it needs the user's OK, since it wipes coins. From code, see "Rebirth". Rebuild order after a rebirth: crusher → dumpster → Polisher (Auto Build) → coin cards.

## Open questions
- Which event pays a fresh plot's sales (no FactorySale was seen for our plot while coins rose).
- Purchase distance checks (factory terminal, dumpster shop, rebirth shop, crates).
- What the smelter consumes, and the `SmelterBatchJSON` fields.
- How Mega / meteor crates are claimed.
- The Rain card cost table (JunkRainConfig).
- Main quest objectives (MainQuestConfig).
- The rebirth snap diff.
