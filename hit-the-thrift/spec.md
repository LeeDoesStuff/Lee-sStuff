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
- **ESP:** `%USERPROFILE%\rblx\thrift_esp.lua` (v1). Loader: `loadstring(readfile("thrift_esp.lua"))()`. It shows a dot per item colored by rarity, a per-rack summary, an outline in the best rarity's color, and a Finds list, with toggles and colors per rarity. Config folder: `ThriftESP`.

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
