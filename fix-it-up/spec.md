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
   - Clicking an empty machine gives "There is no part to grind".
4. **Install:** `car.PartsEvent:FireServer("ReapplyPart", partModel)`. It works from 546 studs.
5. **Replace** parts with no RepairMachine (Sparkplugs, Injectors, TimingBelt, …):
   - Click `workspace.PartsStore.SpareParts.Parts[<Category>][<PartName>]`, then confirm "Do you want to buy  i3 1.0 Sparkplugs for 30€?".
   - The new part spawns at `SpareParts.SpawnPosition`.
   - Install it, then `Events.PartsEvent:FireServer("DeletePart", oldPart)`.

**Repair spot:** the user wants the car on the open floor of the Dealership shop at about (-533.6, 1.8, -799), not up on a lift. The script spawns it there with RemoteLoad. A full repair (3 parts + 1 replacement) took 30 s.

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
