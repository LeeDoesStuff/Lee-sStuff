<title>Hit The Thrift Spec</title>

# Hit The Thrift — spec

Place `122454884469606` · GameId `8391342266` · `StreamingEnabled = true`. Started 2026-09-27. **Recon only so far.** The first question was where **MRKET** is (the user typed "MRKT"; the game spells it MRKET). No farm yet: run the full recon checklist before building one.

Decompiled client sources are in the Potassium workspace as `thrift_src_*.lua`. Tags: *(code)* = read from client code, *(measured)* = seen live.

## Where to sell clothes

| Outlet | Where | Pays | Gate |
|---|---|---|---|
| **Craig** (`Workspace.Misc.SellNPC`) | outside the thrift, about (-94, 97, 73) | item `Value` up to $1M, then **only 20% of the part above $1M**: `min(v, 1e6) + max(v - 1e6, 0) * 0.2` *(code: `showWalletConfirm`)* | clean items only |
| Craig, "Sell requested" | same | `Tasks.Craig.SaleMultiplier = 2` on items matching his two tags *(config, not measured)* | his current objective |
| **Isaac** (`Misc.HypeBeastNPC`) | inside | `SaleMultiplier = 2` on his "(Tag1) (Tag2)" item, `Cooldown = 30` *(config)* | `RequiredAura = 15000`; Robux skip `SkipIsaacTimer` |
| Sophie | not live: `Tasks.AvailableNPCs = {Craig, Isaac}` | 1.75 on RoflLangford / HouseMorieli / SilverSpades | `RequiredAura = 150000` |
| **MRKET** | **the Ropop laptop inside your own apartment** (not on the map, not on the phone home screen) | "Rich buyers on MRKET pay full price" (game string), times BUYER RATES: Rare x1.05, Epic x1.12, Legendary x1.25, Mythical x1.45, Divine x1.75. Common and Uncommon: "no sale" *(code)* | an apartment (500k) plus a MRKET account |

When a Craig sale is over $1M, the client pops "Craig can't afford this! … Rich buyers on MRKET pay full price." Declining it makes Craig say "try MRKET". Accepting sells at the capped price.

## MRKET: how to get there *(code; apartment state measured)*

1. **Apartments unlock** server-side. The server sends `ApartmentEvent "Unlocked"`, which shows "Apartments Unlocked! Check out the third floor to purchase." and turns on an orange `PosterUnlockHighlight` on `workspace.ApartmentPoster`. The poster is on the thrift's 3rd floor, about (-23, 131, 13). The unlock condition isn't in any client config.
2. **Buy:** the poster's prompt asks "Buy apartment … (Cost: 500k thrift bucks)", then fires `ApartmentEvent:FireServer("Purchase")`. There are 8 slots, `workspace.Apartments.Positions.Apartment1..8`. The owner is stored in the `Owner` attribute (a UserId). After buying you get "Check out the spawn area to access it". The entrance is `Apartments.Entrance.tpPart` at about (-171, 102, 96), and `Teleportations.Apartment` is a teleport point.
3. **Open the account:** the Ropop laptop's prompt (`<apartment>.Ropop.Prox`, 5 studs) runs `PlayerApartmentModule.HandleRopop("OpenMRKET")`. The first time, it asks "Open a MRKET account? This action cannot be undone.", then asks for a store name (permanent, filtered; "Invalid name!" on a filtered name). That fires `RopopEvent "Make"`, then `"Name", name`.
4. **List:** the dashboard is `MainGUI.ScreenFrame.MRKETSellerFrame` (UIController key `MRKETSeller`). Drag an item onto a slot, then press LIST, which fires `RopopEvent "ListItem", ItemInstanceId`.
   - An item is listable when it's a Shirt, Hoodie, Pants, Shoes or Accessory, has `Condition == "Clean"`, isn't `Favorite`, and is Rare or better.
   - There are 3 slots (`maxListings`). More slots are sold for Robux (product `MRKETListingSlot`).
   - Take back fires `"UnlistItem", id`. It only works until an offer is accepted.
5. **Offers** arrive as DMs in the phone's **Messages** app, which gets an `MRKETNotification` badge.
   - Buyer personas: Lowballer, Fair buyer, HYPE BUYER. Each offer line shows "(N% of value)".
   - Actions: `AcceptMRKETOffer`, `HoldMRKETOffer`, and counter-offers via `StartMRKETCounter`, then `ResolveMRKETCounter` or `CancelMRKETCounter`. `ReadMRKETOffer` marks one read, `GetMRKETMessages` fetches them.
6. **Pack:** go to your apartment's pack station (`Ropop.Packaging.BoxPos`, prompt "Pack Orders", object text MRKET). With no accepted offer it says "Accept an offer on your phone first!". Packing fires `RopopEvent "PackOrder"` and gives you a box tool (attributes `MRKETBox`, `MRKETListingId`).
7. **Deliver:** the buyer NPC waits at one of the `workspace.MeetingPlaces`: Matcha Shop, Apartments, Jewelry, Furniture Shop or Laundromat. While you hold their box, the buyer gets an orange highlight. The server sends `MRKETDeliveryWarning` and `MRKETDeliveryComplete`.

**Automation (script v3, 2026-09-27). Read from code, not yet run on a live order:**
- **Pack:** your station is `Workspace.Apartments.<you>.Structure.Ropop.Packaging`. Its attribute `HasOrder` is set from the server's `Station` push. The "Pack Orders" prompt at `BoxPos` is created client-side by `MRKETModule.SetupApartment`, 5 studs, only for your own apartment. Its handler checks `HasOrder`, fires `RopopEvent("PackOrder")`, moves you to `PlrPos` and plays the pack animation. The result is a box tool (`MRKETBox`, `OrderId`, `MRKETListingId`).
- **Getting in:** the game's own route is `ApartmentEvent:FireServer("Enter")` (the Teleport app). The server answers `"Entered"` and `TpToApartment` moves you inside. Leaving through the exit fires `ApartmentEvent("LeftApartment", owner)`.
- **Deliver:** the box tool's only script (`toolHandler`) fires `ToolEvent:FireServer(box, true)` on use. There's no other client delivery call, so the server decides by where you are: `MRKETDeliveryComplete {Buyer, Price}` or `MRKETDeliveryWarning "<text>"`. Buyer NPCs are client-only models (`workspace.MRKETBuyerNPCs_Local`, prompts stripped) that walk from the `MeetingPlaces[place].Start` part to `Final`.
- **List:** `RopopEvent("ListItem", tool.ItemInstanceId)`, which is what the dashboard's LIST button sends. The server answers `"ItemListed"` or `"ListingError" <text>`.
  - Measured 2026-09-27: from outside the apartment, a matcha drink got `ListingError "That item cannot be listed."` straight back, and the tool stayed in the backpack. So the server handles list requests away from the laptop, but a real listing from afar isn't confirmed yet.
  - The dashboard's filter (`ToolInfo`) takes clothing types Shirt / InnerLayerTop / OuterLayerTop / Pants / Shoes / Accessory that are Clean, not Favorite, not a box, and Rare or better.
  - The script's "List held item" button checks those rules, then sends `ListItem` from where you are. It retries once from the laptop only if the server stays silent.
  - The button has an optional hotkey: an Obsidian `Press`-mode key picker, unbound by default, ignored while typing, and saved with the config. The result also appears as a toast.
- **Offers** (Messages): `{Id, Buyer, BuyerId, BuyerType, Price, ItemValue, ItemName, Status (Accepted/Packaged/Sold/HeldOut/Lost), MeetingPlace, FinalPrice}`. Accept with `AcceptMRKETOffer id`, hold out with `HoldMRKETOffer`, counter with the timing minigame `StartMRKETCounter` → `ResolveMRKETCounter {Id, ClickTime = GetServerTimeNow()}`.
- **State on 2026-09-27:** you own Apartment1, your MRKET store is "OFN", and you have 0 listings and 0 offers. MRKET slots: 3, plus 3 more for Robux.

`ReplicatedStorage.Events.DataEvents.RopopEvent` carries all of it, in both directions. Server → client verbs:
- `Data`
- `Listings{listings, maxListings, purchasedSlots, maxPurchasableSlots}`
- `ItemListed`, `ListingError`
- `Station`
- `MRKETBuyerPackage`, `MRKETBuyerSay`, `MRKETBuyerLeave`
- `MRKETMessages`, `MRKETOfferPing`, `MRKETCounterStart`
- `Filtered`

## Item values *(measured 2026-09-27)*

- Tool attributes: `ItemKey`, `Value`, `Condition` (Clean / Dirty), `Favorite`, `ItemInstanceId`, `Color`.
- **`Value` includes detergent effects, so it can run far above the catalog `Resale`:**
  - Silver Spades Hoodie: `Resale` 2.55M, `Value` 6.375M.
  - Onyx Cargo Jeans: `Resale` 2.55M, `Value` 6.12M.
  - Locker entries record a `DetergentEffect` (e.g. `SupremeDetergent`, `GoldPod`).
- MRKET's listing card shows the tool's `Value` as the "base resale".
- Example, a 6.375M Legendary: Craig pays about 2.075M. MRKET is 6.375M × 1.25 ≈ 7.97M before buyer-persona variance (the variance isn't measured yet).
- Catalog `Resale` by rarity:

  | Rarity | Items | Resale |
  |---|---|---|
  | Common | 11 | 17–100 |
  | Uncommon | 18 | 63–7.5k |
  | Rare | 29 | ≤ 510k |
  | Epic | 14 | ≤ 1.19M |
  | Legendary | 14 | ≤ 2.55M |
  | Mythical | 20 | ≤ 5.95M |
  | Divine | 1 | 13.6M |

## Racks, shelves and displays *(code + measured 2026-09-27)*

- **One format for every item holder:** a part with attribute `Main = true` (`Rack_Main`, `Shelf_Main`, `Display_Main`). Each child slot (a Model named `1`–`9`, or a MeshPart for jewelry) carries `ItemKey`, either `"Key"` or `"Key_Color=Blue"`. Rarity is `ClothingModule.Items[Key].Rarity`. The rack UI also resolves numeric IDs through `GetItem`.
- The holder's rack Model carries `ID`, `Location` (`Floor1`, `Floor2`, `Floor3-1`, `Floor3-2`, `Basement`, `Jewelry`), `ItemType` (Clothing / Shoes / Glasses / Chain), `Aura` (the gate: 0, 1k, 15k, 75k, 150k, 1M, 5M), and on some `RarityPool` (`JewelryRarity`, `Supreme`) or `MaxItems`.
- Holders: 18 in `workspace.Thrift.Racks` (clothing racks hold 9, shoe shelves 6, glasses shelves 6) and 3 in `workspace.JewelryStore.Displays` (4 each; `JewelryDisplay3` sits in the basement behind 5M Aura). The flea market stalls have a `Main` part but no item models; their stock comes through `getFleaStock`.
- `ClothingModule.Rarities`: Common 72, Uncommon 25, Rare 2.5, Epic 0.5 (`Chance`); Legendary, Mythical and Divine have 0, so those come only from rack `RarityPool`s. Colors are in the same table.
- **Purchases are per player:** the rack payload's `PurchasedItems` filters your own buys out of the menu, and `ClothingDeleteEvent` deletes the bought slot model on your client only. After a rejoin, the models of items you already bought reappear until the next restock (not tested).
- `RestockEvent(prompt, items)` swaps rack stock. The rack price is `Item.Price`, or 80% of it for Morieli members (`MorieliPricing.DisplayPrice`, attribute `MorieliMember`).
- Example (measured): Silver Spades Hoodie on Rack24 costs $1.5M, with catalog `Resale` 2.55M. Detergent can push the finished piece to about $6.4M.
- **Script:** `%USERPROFILE%\rblx\thrift_esp.lua` (v3). Loader: `loadstring(readfile("thrift_esp.lua"))()`. Config folder: `ThriftESP`.
  - ESP tab: a dot per item colored by rarity, a per-rack summary and an outline in the best rarity's color, with toggles and colors per rarity.
  - Finds tab: a list of items at or above a chosen rarity.
  - Matcha, Laundry and MRKET tabs: see their sections.
  - Settings: a spending reserve.

## Matcha *(code + measured 2026-09-27)*

- `MatchaItems`: Culinary $500 (aura x1.3, 60 s), Strawberry $10k (x2, 90 s), Ceremonial $250k (x3, 150 s), Gold 99 R$ (x4, 250 s); Gingerbread Latte $199 (x1.1). Drinking one (tool attribute `UsesLeft = 4`) gives a timed aura multiplier. Aura comes from the outfit you wear, per Griff.
- **Order:** `MatchaOrderEvent:FireServer(itemKey, os.time())`. It's ignored from 90 studs but works 6 studs in front of Kat (the customer side of her counter, floor y = 92.35). The client menu closes past 15 studs from Kat's HumanoidRootPart.
- **Flow:**
  1. The server sends `MatchaAnimationEvent "StartMaking"`. `"StartDrinkSoon"` means your order is queued.
  2. The client's own Kat clone walks off and animates for about 8 s. Kat is a client-side clone, and the server's placed NPC is destroyed locally.
  3. The client sends `MatchaOrderEvent("AnimationComplete")`.
  4. The server spawns `Workspace.<Kind>_Clickable` (e.g. `Culinary_Clickable`) at `DrinkReferencePoint`, about (-63, 95.5, 118.5), and sends `"OrderReady", model`. The client adds a `SelectedHighlight` to it.
  5. `fireclickdetector` on its ClickDetector (range 32) collects the drink.
  About 10 s per drink in total.
- **Limit:** 15 matcha drinks of any kind; the server replies `"Limit"`.
- The game moves you client-side itself: Teleport app (gamepass) `Character:PivotTo`, MRKET pack station. No client anti-cheat scripts. The teleports used for matcha haven't triggered anything.
- **Auto (v2):** teleport to the spot, order, click, repeat to the target count, teleport back. Walking more than 8 studs from the spot pauses it for 2 min. If Kat's animation never runs (she's already busy), the server waits forever for `AnimationComplete`, so the run sends it itself 20 s after `StartMaking`.

## Laundry *(code + measured 2026-09-27)*

- **Pods** (`DetergentModule`), price → resale multiplier / aura multiplier: Basic $25 → x1.5 / 1.1, Premium $250 → x2, Gold $2.5k → x2.5, Onyx $5k → x3, Supreme $50k → x4.5 / 1.75, Phoenix $100k → x5 / 2, Amethyst $250k → x5.5 / 2.25. Each restock rolls a stock count per pod: Supreme is 0 at 97.9%, Phoenix 0 at 99%, Amethyst 0 at 99.5%, Onyx 0 at 95.6%; Basic rolls 14–16.
- **Buy:** `DetergentEvent:FireServer(key, true)` works from anywhere (45 studs from Franklin was fine).
  - A success answers `PodEvent("Stock", stock, boughtThisRestock)`. Stock is per player: what's left for you is stock minus your buys.
  - A pod with no stock is silently ignored and costs nothing.
  - The client refuses a 16th pod of one kind ("Too many in Inventory").
  - The Robux path is `DetergentTransaction("Single", key)`.
- **Restock:** every 300 s, shared with the racks. At the restock the server pushes `PodEvent("Stock", newStock, {})`, then `RestockTimerEvent(300)`, in the same frame, unasked. `getRestockTime:InvokeServer()` returns the seconds left.
- **Bubbles:** while you're `WASHING` and within 20 studs of the machine, `LaundryClientModule` spawns a `BubbleButton` (ImageButton) in `MainGUI.ScreenFrame.BubbleGameFrame` every 0.75 s. A pop runs `BubbleEvent:FireServer()` and `WasherTimerEvent:Fire("Decrement")`, taking 1 s off the wash. Auto-pop fires each new button's own `Activated` handler with `firesignal`, in its own thread. Verified with a fake button, not yet during a real wash.

## Currencies and systems seen (not mapped yet)

- leaderstats: `Thrift Bucks` (a StringValue, abbreviated like "636.7K") and `Aura`.
- `Player.Stats` holds the exact numbers: `Thrift Bucks`, `Aura`, `Likes`, `Collection` (JSON), `Locker` (JSON), `LockerSize`, `MaxInventorySize = 30`.
- Systems:
  - thrift racks on 4 floors, with restock timers
  - laundromat and detergents (value effects)
  - weekly flea market with a countdown sign
  - jewelry store
  - furniture shop (15-minute rotation)
  - apartment furniture and washing machines
  - matcha shop
  - Crazy Roll (`CrazyRollProgress` / `CrazyRollThreshold` attributes)
  - Morieli basement
  - Codes app
  - ThriftFeed social app
  - VIP and rewarded ads
