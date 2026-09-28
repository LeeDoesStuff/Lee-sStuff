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

1. **Hood:** click `car.Misc.Hood.Detector.ClickDetector`. This sets `Values.Cache.IsHoodOpen`.
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
- **Collector cars:** the user's pre-existing cars must never be sold. The script only sells GUIDs it recorded at purchase (`FixItUp/owned.json`). It also refuses to sell while any other car of the user is within 40 studs of the NPC.

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
