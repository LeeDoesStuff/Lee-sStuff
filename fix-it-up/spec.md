# Fix It Up! — game spec

Place 72712036210947. Script: `fiu_main.lua` (junkyard tiers, auto flip, repair, shop, teleports). Server hopper: `fiu_hop.lua`.
Everything here was measured live on 2026-09-27, unless it says "from code".

## Core loop

1. Buy a junk car at the junkyard.
2. Repair its worn engine parts, or replace them.
3. Sell it at the Used Cars NPC.

The sale pays `BuyPrice × (1 + ProfitMultiplier)` at 100 % condition. For example, 9,750 × 1.3 = 12,675.

## Junk cars

- Junk cars live in `workspace.Vehicles[<GUID>]` with `Junkyard=true`.
- The name is hidden: `Model` = the GUID, and the body is a `STOP_DEX_PLEASE` model.
- Useful attributes:
  - `Price` (NumberRange: the random buy price range)
  - `ProfitMultiplier`
  - `SpawnChance` (%)
  - `ExclusivePrice` (only on the exclusive car)
- **Name recovery:** match `(Price.Min, Price.Max, ProfitMultiplier, SpawnChance)` against the attributes of `ReplicatedStorage.Cache.CarList[<name>]`. This was unique for every junk car seen.
- **Buying:**
  - The car has a `ClickDetector` (32 studs).
  - The server then invokes `Events.HUD.Confirmation` with `"Do you want to buy <Name> for 9,750€?"`, which is the real name and the exact price.
  - Our `OnClientInvoke` decides the answer. The original callback comes from `getcallbackvalue`.
- After a buy:
  - The junk model is destroyed.
  - A new owned car spawns with a new GUID and `Model=<real name>`.
  - A `PlayerData.Garage[<GUID>]` entry holds `Model`, `BuyPrice`, `BoughtAt` and `Values`.
- The garage size is `#Garages[PlayerData.GarageModel].CarPositions`. Default = 3.
- **Server broadcasts** (`Events.DisplayMessage`):
  - `"[System] A rare car has appeared! <Name> — Chance: 7%"`
  - `"An exclusive car has appeared around the map!"`
- Tiers used by the script are by SpawnChance: S ≤0.1, A ≤1, B ≤5, C ≤15, D >15, EX = exclusive/0.

## Moving cars

- `Events.Vehicles.RemoteLoad:InvokeServer(garageEntry, anyCFrame)` spawns the car at that CFrame, server-side.
- The old instance gets replaced.
- No network ownership is needed. This is how the game's own garage exit works.
- Moving a car by sitting in the `DriveSeat` and calling `:PivotTo` also works, but it drags the character along. The user asked for RemoteLoad instead.

## Engine, wear and condition

- `car.Values.Engine.<Slot>` = `"<Category>|<PartName>"`, or `""` for an empty slot.
- `car.Values.Engine.Wear.<Slot>` = 0–100.
- Condition = 100 − average wear of the installed slots, from the `A-Chassis Interface.Parts` code.
- The engine bay models are `car.Body.EngineBay.<Slot>`, with attributes `PartName`, `Category` and `RepairMachine` (GrindingMachine / PartsWasher / BatteryCharger, or none).

## Repair

1. **Hood:** click `car.Misc.Hood.Detector.ClickDetector`, which has a **10-stud range**; stand beside the hood, not the car center. This sets `Values.Cache.IsHoodOpen` (the value can be missing before the hood is first used). A car spawned by RemoteLoad ignores the first click for about a second, so retry (measured 2026-09-28).
2. **Remove:** `car.PartsEvent:FireServer("RemovePart", "<Slot>")`.
   - It works from 230+ studs.
   - The part appears in `workspace.MoveableParts` with `Owner`, `Wear`, `PartName`, `Category`, `RepairMachine` and `DroppedAt`.
   - Removing `EngineBlock` also drops AirIntake, CylinderHead, ExhaustManifold and Sparkplugs. The server sends the notify "The following parts connected to the engine were removed: …".
   - A transmission shows up named after its `PartName` (for example "5-Speed Manual"), not "Transmission".
3. **Machine:**
   - Each machine has an invisible `Detector` part (TouchInterest). The BatteryCharger's has a `BatteryPosition` attachment.
   - Hold the part inside it with a Heartbeat `PivotTo`; we get network ownership of our own parts, even ~900 studs away.
   - Then click the machine's ClickDetector: GrindingMachine `Button` (14.3 studs), PartsWasher `Faucet` (12), BatteryCharger `Button` (10).
   - Wear goes to 0 after about: washer 10 s, charger 13 s, grinder 16 s. Machines run in parallel.
   - Re-measured 2026-09-29 after the clicks: washer 8 s, charger 11 s, grinder 14–16 s. The `Wear` attribute jumps straight to 0 at the end with no countdown, so you can't tell early whether a click took. All 7 first clicks landed with a 0.25 s wait after each teleport.
   - The buttons only reach 10–14 studs and the server checks that distance, so you have to teleport to each machine. The teleport itself is instant.
   - Clicking an empty machine gives "There is no part to grind".
4. **Install:** `car.PartsEvent:FireServer("ReapplyPart", partModel)`. It works from 546 studs.
5. **Replace** parts with no RepairMachine (Sparkplugs, Injectors, TimingBelt, …):
   - Click `workspace.PartsStore.SpareParts.Parts[<Category>][<PartName>]`, then confirm "Do you want to buy  i3 1.0 Sparkplugs for 30€?".
   - The new part spawns at `SpareParts.SpawnPosition`.
   - Install it, then `Events.PartsEvent:FireServer("DeletePart", oldPart)`.

**Repair spot:** the user wants the car on the open floor of the Dealership shop at about (-533.6, 1.8, -799), not up on a lift. The script spawns it there with RemoteLoad. A full repair (3 parts + 1 replacement) took 30 s.

**Repair timeline (2026-09-29, Ontel Astron, 7 machine parts + 1 replacement): 34 s in total.**

| Seconds | Step |
| --- | --- |
| 0–7 | Teleport, spawn, hood (the hood ignores clicks for about 4.5 s after a spawn) |
| 7–11 | Buy the replacement, place the parts |
| 11–14 | Clicks |
| 14–30 | Machines |
| 30–34 | Install |

During the streaming jam, the same flow took 70–75 s.

**Never reload fiu_main mid-repair.** Unloading drops the Heartbeat pins, and the game's client deletes loose parts 90 s after `DroppedAt`. Wait until the status isn't "busy: repairing/selling/buying"; "farming distance" is safe.

**Repair shops:**
- `Buildings.Dealership.Folder.Station1/2`: 6 grinders, 3 washers, 3 chargers, and lifts at about (-563, 7, -800). The user calls this the "secondary garage" and prefers it because it's quiet.
- `Buildings["Pitstop(Large)"].Station1–5` is the busy one.

**Loose-part cleanup** (from PartMoverClient code):
- The game's **own client** fires `DeletePart` 90 s after `DroppedAt`, unless the part sits inside a `NoCleanup`-tagged zone. Parts touching a trash zone go after 15 s.
- The machines count as NoCleanup zones: a part placed there gets `NoCleanup=true`.
- We lost a transmission to this during testing. Keep parts in machines, or clear `DroppedAt` locally each frame.

## Sell

- `workspace.Utils.SellCar.Prompt.ProximityPrompt` ("Sell your car", 10 studs, 0.5 s hold).
- The car must be within about 12 studs of the NPC. Otherwise the server notifies "Car is too far from the sell zone".
- Confirm text: `"Do you want to sell your <Name> for 12,675€?"`.
- **Sell timer:** the server refuses a sale for some time after the purchase. The user confirmed it exists. The length and the refusal text are not measured yet; the script learns them from the first refusal.
- **Collector cars:** the user locks them by hand in the script's Favorites section (`FixItUp/favorites.json`). Favorites are never sold, and the auto loop never touches them. Auto sell only sells GUIDs the script recorded at purchase (`FixItUp/owned.json`). The manual Sell button (double-click) works on any car that isn't a favorite. Nothing is sold while another of the user's cars is within 40 studs of the NPC.

## Streaming

StreamingEnabled is on. Machines, the sell NPC and far junk cars exist as empty models until streamed in. Use `LocalPlayer:RequestStreamAroundAsync(pos)` before touching them.

**RequestStreamAroundAsync can jam for the whole session (2026-09-29).** From about 11:27 every call hung forever, timeout argument or not, even calls aimed at the player's own spot. The first hang froze auto on "busy: selling". A per-call timeout then made every teleport cost 3 s and every spawn or machine scan 5 s, and a repair took 70 s instead of 35 s. Flows still worked during the jam with no streaming, because the sell NPC, the Dealership stations and the home interior were there anyway. fiu_main's `streamAt` now:
- skips streaming after one timeout, until a stuck call returns;
- skips it for hops under 64 studs.

## Other remotes seen

- `Events.HUD.Notifiy` (server → client toasts)
- `Events.HUD.SetInGarage`
- `Events.PartsEvent` (`GetJack`, `GetSponge`, `TakeOut`, `StoreItem`, `DeletePart`)
- `Events.Vehicles.Contract` (sell a car to a player; the Contract tool costs 25,000)
- `Events.Exchange` (money↔gold)
- `Events.JobEvent("EndShift")`

## Shop and place coordinates

These are in the `PLACES` table in `fiu_main.lua`: junkyard, spare parts, Used Cars, auctions, premium dealership, repair shops, paint/tint, gas stations, car washes, plate, tire/rim, brake, underglow, bank, clothes, RodEx, body parts (far map at -10840, 5742), jobs, races, and every garage `ExitPos`.

## Clean, paint, and remote clicks (measured 2026-09-28)

- **Store parts can be clicked from anywhere.** `fireclickdetector` on a `PartsStore.SpareParts.Parts` item worked from 452 studs away. The confirm arrives and the part spawns at SpawnPosition, with no teleport. Buying a replacement takes about 0.5 s.
- **Junk cars can't:** a click from about 1,700 studs gave no confirm. Buying still needs the character within the 32-stud range.
- **Car wash:** the prompt has a 10-stud range, and it gave no tool on the first tries. `workspace.Map.CarWashes` holds 6 washes, each with a `Detector` bay (16×9.6×23).
  - The dirt value is `car.Values.DirtLevel` (0–100).
  - The client sends `Events.Vehicles.SetDirt:FireServer(level)` for the player's own car, from the `PressureWasher` tool (10 s) or the `Sponge` tool (15 s), stepping the level down every 0.25 s.
  - A car spawned into the bay read dirt 0. Whether the bay itself cleans cars, or the earlier stepped SetDirt did it, isn't settled yet.
- **Paint:**
  - With the car inside `Pitstop(Large).Model.CarPaint.Detector` (16×9.6×19), `Events.Vehicles.SetPaint:FireServer("Car", car, Color3, material)` repaints it. Money goes down by the material price and `Values.PaintColor` becomes `"<material>_r, g, b"`.
  - Prices (`Assets.CarMaterials` attr Price): Rust 0, Normal 200, Shiny 500, Matte 700, Aluminum 1200, Metallic 1500. Underglow costs 2500 (`ReplicatedStorage` attr UnderglowPrice).
- **Sell price depends on condition:** an unrepaired Fia-Te Ponto bought for €1.6K sold for €1.1K. The repaired Ontel got the full ×(1+PM).
- **Sell timer:** 184 s after purchase. The refusal text is `You need to wait N seconds to sell this car`.
- **Sell zone:** a car freshly respawned 9 studs from the NPC was once "too far". Retrying 6 studs out worked.

## Other players (measured 2026-09-28)

- Every player's `PlayerData` replicates to everyone:
  - `Garage.<GUID>` with `Model`, `BuyPrice`, `BoughtAt` and the full `Values` (engine wear included);
  - `GarageModel` (their garage type);
  - `Status` (Money, CarsSold, …).

  The script's Players tab shows any player's garage from this data: tier, price, condition, and whether the car is spawned.
- Spawned cars in `workspace.Vehicles` carry `Owner=<Name>`, `Model` and `SpawnChance`. That's enough to title other players' cars with their tier.
- **Hood after spawn:** a freshly RemoteLoad-spawned car ignores hood clicks for about 4.5 s (measured twice: 4.8 s and 4.4 s). The script clicks every 0.5 s for up to 10 s.
- **Junk offer timing:** after a teleport, wait about 0.8 s before clicking. At 0.3 s one of five offers didn't come; at 0.8 s all did (offers arrive about 0.05 s after the click). Junk cars vanish when another player buys them, so re-check `model.Parent`.
- **Don't show the game's own confirm dialog from a script.** Calling the captured `Confirmation` OnClientInvoke callback from the executor showed the dialog, but the player's Confirm click never answered it; only firing the button's connection did. The script's buy is now two steps: **Get price** (click the car, decline, read the price), then **Confirm purchase** (click again, accept only at that price or lower). A junk car's price stays the same across clicks.

## Gold, distance, highway (measured 2026-09-28)

- **Gold:** `Events.Exchange:FireServer("mtg", amount)` buys gold at `floor(Cache.GoldPrice + 0.5)` each. It worked from wherever the player stood, with no bank needed; 1 gold cost €20,147. `"gtm"` sells gold back at 80 % (20 % tax). GoldPrice drifts slowly: 20171 → 20147 over about 3 h. Gold has no in-game sink in the client code.
- **Distance (`Status.KMs`) is counted by the server from the car really moving.** The client's fuel script tracks distance locally but never sends it. A car moved by a client-side `PivotTo` loop while the player sits in the DriveSeat **is counted in full**: 0.60 km moved → 0.59 km counted. At 60 studs/s that's about 0.9 km/min.
  - Driving also pays money: about €3.7/s at 60 studs/s (+€151 in 40 s).
  - 3937 studs = 1 km, from the game's own fuel script.
  - The user set the km-per-car rule by hand (5.5, later lower). The server's actual refusal text for a km shortfall hasn't been seen yet.
- **Traffic lanes** (`ReplicatedStorage.Assets.TrafficNodes.Lane1-3`) are real world positions on a highway north of town. Lane1 runs 3.45 km out and Lane3 3.59 km back. Node 1 sits inside a tunnel mouth.
- **Farm route:** the long straight highway section `Workspace.Map.Map.Model.Road.Road`, 101 × 1121 studs, centre (-984.8, 0.52, 2100.2). Its ends, one lane in, are (-1076.83, 1.02, 2612.93) and (-843.24, 1.02, 1598.84). The user picked it because town was crowded.
- **RemoteLoad** can come back without moving the car: the auto repair after a fresh junkyard buy ran with the car still at the junkyard. `spawnCar` now checks the car arrived within 40 studs of the target, and retries up to 3 times.
- **Car dropdown:** rebuilding the dropdown's values cleared the player's pick. The script now restores the same car after each rebuild.
- **Any car's data on demand:** `Events.Vehicles.GetModel:InvokeServer(name, true)` returns `(modelName, descendantCount)`. The server then puts a preview copy of the car in `PlayerGui[modelName]`; the client fires its `ForceDelete` when done, which is how the garage does it. The copy's `A-Chassis Tune` holds `DefaultEngines`, `DefaultTransmission`, `MaxEngineSize`, `Weight`, `DefaultEngineParts` and `StartBody`. `require` on a loose copy errors, so the script decompiles it and parses the text instead. Engine stats (EngineSize, PeakTorque, Redline, HPLimit, Fuel) come the same way from `PartsStore.SpareParts.Parts[<engine>].EngineBlock.PartInfo`.
- **One car out at a time:** spawning one of your garage cars (RemoteLoad) puts away the one that was out. Parts pulled into `MoveableParts` stay in the world when their car is put away, which is what makes car-to-car transfers possible. Keep clearing their `DroppedAt` locally so the game's 90 s cleanup doesn't delete them in the meantime.
- **Distance is counted from the wheels turning, not from the car's position** (measured 2026-09-28). With the tyres floated 0.6 studs above the road, the car moved 0.07 km and 0 km was counted. With the tyres on the road and each wheel's `AssemblyAngularVelocity` set to `(dir × up) · speed / radius` (rolling, no slip, no screech), counting came back. The server credits distance in bursts every 5–10 s. Throughput by farm speed (40 s runs):

  | Speed (studs/s) | km/min counted | Share of moved distance counted |
  |---|---|---|
  | 60 | ~0.81 | ~98 % |
  | 85 | ~1.15 | ~90 % |
  | 120 | ~0.92 | ~57 % |

  So the server caps the counted rate somewhere around 85–100 studs/s. The farm defaults to 85.
- **Wheels** (measured 2026-09-28):
  - **Removal:** `car.PartsEvent:FireServer("RemovePart", "FL"|"FR"|"RL"|"RR")` only works while the car has `OnLift=true`; the server refuses it on the floor. It returns one rim+tyre model named `Parts` (`IsWheel`, `RimName`, `TireName`, `Diameter`, `Width`, `Category="Rim|Tire|None|diam|width"`).
  - **Install** works without a lift: `RenamePart(part, corner)`, then `ReapplyPart(part)`.
  - **Lift** (Dealership `Folder.Lift`): spawn the car at `lift:GetPivot()*CFrame.new(0,4,0)` (inside the lift's `Detector`), then press the `Up` ClickDetector (14.3-stud range) **once**. `OnLift` becomes true within ~0.3 s, and the platform (`Holder`) rises from y 2.35 to 3.85 in ~3.5 s. Presses while the platform is moving are ignored, and pressing Up every 0.5 s kept `OnLift` from ever being set. `Down` takes ~3 s.
  - A car-to-car tyre swap once left car A without wheels when the lift failed for car B. The transfer now puts A's wheels straight back on A if B's pull fails.
- **Tyre shops** (`PartsStore["PitWheels WEST"/"EAST"].Wheels.Rims/Tires`) sell rims and tyres separately (MeshParts with `Price`, ClickDetector 32 studs). After the click, the server calls `Events.HUD.WheelBuy:InvokeClient(label, priceFactor)`, and the client returns `(diameter 12–24, width/200 [0.5–2], x4 bool)`. Price = factor × diameter × width / 200. Buying isn't implemented yet.
- **Fuel** (measured 2026-09-28): `Events.Vehicles.GasStation:FireServer(car, liters, pricePerLiter)` refuels from anywhere, not just at a pump: +1 L cost €2 (rounded). Each station keeps its prices as `PetrolPrice` / `DieselPrice` attributes on its `Prompts` object (€1.59–1.63 petrol, €1.52–1.54 diesel). The tank size is `A-Chassis Tune.TuneChanges.MaxFuel` and the fuel type is `TuneChanges.Fuel`. The farm doesn't burn fuel: the fuel script only runs with the engine on.
- **Selling locked cars:** the script's confirm hook now also answers the game's *own* sell prompt (a player at the Used Cars NPC). It declines if the car named in the prompt is a favorite that's out within 60 studs of the NPC.

- 2026-09-28: sellCar saves the player CFrame before the sell and teleports back afterwards, whether the sale succeeds or fails (auto and manual). The "Car" tab is renamed "Garage".
- 2026-09-28: a separate "Auto lock by spawn chance" toggle plus a % input (default 0.5) locks script-bought cars at or under that SpawnChance, independent of the tier lock. Five A-tier cars sit between 0.1 and 0.25%: Four Mustank Relby SP500, Lanca Status FR4 and Fia-Te 10026p at 0.2, Merquis Maibac S650 at 0.25, Merquis 560 SEC Koenig at 0.15. The Drive farm has a "No limit" toggle that ignores the debt and extra km.
- 2026-09-28: the server hop has a "Hard block big sellers" toggle (HOP.hard, and HOP.hardMax which defaults to 1500, both in fiu_hop.json). Anyone at or over hardMax fails the server even when the "players allowed over" allowance would pass them. Players whose stats never loaded ("?") count only toward the normal limit.
- 2026-09-28: Auto tab has a Home section. STATE.home = {x,y,z,lookX,lookZ} in state.json. "Return home after auto actions" sends you home after each auto buy, repair or sell (straight to the repair when one follows a buy). "Return after tp" goes home after any button or queued action that called tpTo (tpTo stamps CFG.lastTp); the teleport buttons and Hood are exempt. It also goes home when the distance farm stops. Obsidian DoubleClick buttons ignore fired MouseButton1Click connections, so test scripts cannot press them.
- 2026-09-28 reorg: Shop tab renamed Parts (Spare parts, Tools, Spec swap, Car to car). Car lookup moved to Junkyard. Clean/Paint after auto repair moved to Auto > Flip loop. "Return home after auto actions" removed, since "Return after tp" covers it. Load: scanPlayers returns early when ESP is off and cleaned up; the label loop skips SetText when text is unchanged and no longer builds unused junk rich-text lines.
- 2026-09-28: repair shops. Four buildings have Station1..N machine folders: Dealership.Folder (12 machines, 1 Lift, floor spot), Pitstop(Large) (20 machines, 4 lifts), and two Pitstop(Small) (12 machines, 3 lifts each; south at -557,-1617, west at -1130,-1546). The two small ones share a name, so tell them apart by pivot distance. They stream out, so find first, then RequestStreamAroundAsync(anchor) and search again. liftCF picks a Pitstop lift with no other player's car within 8 studs. "Quietest" picks the shop with the fewest other players within 80 studs and re-picks at most every 90 s. The old saved value "Pitstop" maps to "Pitstop (large)".
- 2026-09-28 clean/paint recon on a script-bought car:
  - SetDirt is ignored with the car out of a bay (player far, no tool), with the car in a bay and the player 949 studs away, and with the player next to the car in the bay but no tool. The PressureWasher tool is needed.
  - SetPaint is ignored with the car outside a booth and the player far, and with the car in the booth and the player far (no prompt).
  - Paint booths: there are two Pitstop(Large).Model.CarPaint booths (-998,-384 and -988,-364); the old code only used the first.
  - Washes: 6 bays in 2 clusters (west ~-1540,-824 and south-east ~-260,-1210).
  - Still open: whether the tool must be equipped, whether one big SetDirt jump is accepted, and whether the player must stay after the prompt.
  - Test scripts must pause the auto toggles first: the running auto loop sold the test car (its sell timer ran out) in the middle of a test.
- 2026-09-28 anti-mod: the game group is ".workspace" (12249805). Roles: Guest 0, Member 1 (regular), Tester 2, Content Creator 3, Analytics 4, Contributor 130, Developers/Anti-Cheat 150, Builder 151, Moderator 249, Senior Moderator 250, Admin 251, Senior Admin 252, Manager 253, Owners 254, Holder 255. STAFF.check runs on PlayerAdded and on load, using GetRankInGroup with one retry. It triggers at rank >= HOP.modRank (default 2) and then either Kicks (leave) or Teleports to a random server with RELOAD queued, kicking after 12 s if the teleport fails. Settings live in fiu_hop.json (antiMod, modRank, modAction).
- 2026-09-28: the auto buy filter has "Buy by" set to Tier or Spawn chance, and only the chosen control is shown. Spawn chance mode buys junk with 0 < SpawnChance <= buyMaxPct (%), skipping unknown or exclusive cars.
- 2026-09-28 settings persistence: SaveManager only saved on a manual "Save config". A polling autosave now compares SaveManager:SaveJSON (timestamp stripped) every 5 s and writes to the autoload config when it changes, making and setting an "autosave" config if none exists. Obsidian :OnChanged replaces an element's single callback, so do not hook it for autosave. The farm car is in SaveManager's ignore list (its labels rebuild), so it is kept as a car GUID in drive.json (D.car).
- 2026-09-28 buy/sell breakage:
  - The game's HUD script (PlayerGui.HUD.Frames.Confirmation.ConfirmationClient) sets Confirmation.OnClientInvoke itself and sets it again when the HUD rebuilds. That silently replaced the script's hook, so script buys and sells never saw their prompt ("server never offered the car"). Fix: HOOK.install() runs every 1 s, adopts the game's newest callback as the pass-through, and never adopts a hook from any script copy (weak set getgenv().FIU_HOOKS).
  - Double load: the user's Potassium autoexec loads fiu_main from GitHub on every join, and the hop reload queues it too, so 2 copies start. getgenv().FIU_TOKEN means the newest copy wins: an older copy returns after the load wait, unloads via the watchdog, or unloads itself right after CreateWindow (otherwise it left a dead menu).
  - The main chunk is at the 200-local limit, so new top-level state goes into tables (HOOK, STAFF, ST).
  - Trial: bought an Ontel Costa for 2728 and sold it after 195 s for 2.7K; both work.
