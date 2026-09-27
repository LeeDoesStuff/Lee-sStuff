<title>Sneaker Panel Spec</title>

# Sneaker Resell Simulator — Automation Spec

Verified against the live client (PlaceId `12991635726`), decompiled `PCLocalScript`, `GuiClientScript`, `CashierLocalScript`, `PhoneScript`, `ItemShopScript`. Every formula below was checked against the running world, not inferred.

---

## 1. How the game actually works

The economy is a **buy-low / sell-high loop with four separate buy faucets and two separate sell drains.** Each has different rules. Automating the wrong one first wastes the build.

### Sneaker data model

Every sneaker is one entry in `ReplicatedStorage.SneakerModule.sneakers` (499 entries):

```lua
["Air Bogdan 4 Red Thunder"] = {
    Name = "Air Bogdan 4 Red Thunder",
    Rarity = "Uncommon",        -- Common/Uncommon/Epic/Legendary/Special/Grail/Limited/Legacy
    MaxBuyPrice = 500,
    MaxSellPrice = 1000,
    ImageLink = 15198448934,
    -- [1] = "Unsellable"       -- array slot 1 present => cannot be sold for cash
    -- LimitedPrice = 200000    -- only on Limited-shop sneakers
}
```

Two inventories, and **the split governs everything**:

| Inventory | Contents | Usable for |
|---|---|---|
| `Player.Inventory.SellableInventory` | normal sneakers | cash (cashier, NPC bar sell) |
| `Player.Inventory.UnsellableInventory` | Limited / mystery-box / event sneakers | **trade-ups only**, index, display |

Mystery-box sneakers are all `Unsellable` with `MaxSellPrice` of 1–70. **Boxes are not a cash play** — they are trade-up fodder and index completion. Any auto-box feature is a collection tool, not a money printer.

### The four buy faucets

| Faucet | Currency | Call | Gate |
|---|---|---|---|
| **PC / eBuy** | cash | `BuySneakerFunction:InvokeServer("OfferN")` | slot unlocked, enough money |
| **Limited Shop** | cash | ProximityPrompt (server-side) | **must stand within 7 studs** |
| **Mystery Box** | cash or Robux | ProximityPrompt (server-side) | proximity |
| **SHOES app (drops)** | cash | `BuyShoesApp:InvokeServer(sneakerName)` | `os.time() >= tm`, stock left, `CanBuyShoesApp` cooldown |

### The two sell drains

| Drain | Call | Payout | Interaction |
|---|---|---|---|
| **Fast Sell (cashier stall)** | `CashierEvents.SellAllEvent` / `SellAllButOneEvent` / `SingleSellEvent(name, amount)` | **0.55 × `MaxSellPrice`**, flat | none, and **no proximity** — fires from 150+ studs |
| **NPC bar sell** | prompt → server → `SellSneakerAnimFunction` invoked *on the client* | `MaxSellPrice × band`, ×2 while `MultiplierTime > 0` | timing minigame |

Bar bands, from the decompile:

```lua
local u14 = { Perfect = 1.1, Good = 1.0, Miss = 0.85 }
```

**Perfect is only +10% over Good — but the comparison that matters is against the cashier.**

Measured, three clean samples, zero variance ($525→$289, $1400→$770, $700→$385):

| Exit | Multiplier on `MaxSellPrice` | Cost |
|---|---|---|
| Cashier fast sell | **0.55** | one remote, from anywhere |
| NPC bar sell, Miss | 0.85 | walk to NPC + minigame |
| NPC bar sell, Good | 1.00 | walk to NPC + minigame |
| NPC bar sell, Perfect | **1.10** | walk to NPC + minigame |

**The bar minigame pays 2.0× what the cashier pays** (1.10 ÷ 0.55). The cashier is a convenience tax: instant, remote-only, works at 150 studs, and costs you half the value.

Two consequences that change how you read every other number here:

1. **A listed ROI is not a realised ROI.** A PC offer at 2.20× `MaxSellPrice` returns `2.20 × 0.55 = 1.21×` through the cashier, or `2.20 × 1.10 = 2.42×` through a Perfect bar sell.
2. **Break-even through the cashier is ROI 1.82×.** Buy below that and fast-selling loses money on every unit. A `MinROI` of 2.0 is a ~10% margin via cashier, not the 100% it appears to be.

Guard any re-measurement against concurrent buying: an early sample of this same figure read 0.096 because auto-buy fired inside the measurement window.

---

## 2. Everything on a clock is a pure function of UTC time

This is the biggest finding. The rotations are **not** server-random — they are seeded by the UTC calendar, computed identically on every client:

```lua
-- ReplicatedStorage.PlayerGui.PhoneScript, updateRotationsApp()
limitedShoe = SneakerModule.LimitedShopSneaker[ utcHour % 6 + 1 ]
grailShoe   = SneakerModule.GrailRotationSneaker[ utcHour % 8 + 1 ]
moneyBox    = MysteryBoxModule.MoneyBoxes[ Random.new(yday + utcHour*utcHour):NextInteger(1, #MoneyBoxes) ]
robuxBox    = MysteryBoxModule.chooseBox( Random.new(yday + (utcHour*utcHour + 1)):NextInteger(1, 10000) )
```

Verified live: at UTC hour 1 the prompt in-world read `Air Bogdan 11 Concord | Purchase For 200.0K` and `Super Dunk Mystery Box | Buy For 500K$` — exactly what the formulas predict. Rotation flips on the UTC hour; the in-game countdown is just `3600 - (min*60 + sec)`.

**Consequence: you never poll for a rotation. You compute the schedule for the next week and set alarms.**

Limited shop, 6-hour cycle:

| UTC hours | Sneaker | Price |
|---|---|---|
| 00, 06, 12, 18 | Air Bogdan 3 Fire Red | $1,000,000 |
| 01, 07, 13, 19 | Air Bogdan 11 Concord | $200,000 |
| 02, 08, 14, 20 | Mike SB Dunk Low London | $2,000,000 |
| 03, 09, 15, 21 | Air Bogdan 5 DJ Khalid Court Purple | $10,000,000 |
| 04, 10, 16, 22 | Mike Dunk Low Setsubun | $350,000 |
| 05, 11, 17, 23 | Air Bogdan 4 Trevor Scott | $5,000,000 |

Money-box schedule is computable the same way, 24h ahead, from `yday`.

---

## 3. Auto-buy with rarity filter

**Fully solved, no proximity needed, works from anywhere.**

```lua
local offers = RefreshPageFunction:InvokeServer()   -- {"Mike Air Force 1 White", ...} one per unlocked slot
BuySneakerFunction:InvokeServer("Offer3")           -- returns true on success
```

Mechanics that matter:

- The scrolling frame carries live attributes per offer: `SneakerPrice` (number) and `Sneaker` (name). Read those, not the label text.
- **`Sneaker` can be the sentinel string `"Bought"`.** The server writes it after a purchase; it is not a sneaker name and is absent from `SneakerModule.sneakers`. Treat it as "slot consumed", not as an unknown item.
- **Buying via the remote leaves the card stale.** The server rerolls the slot and writes new attributes immediately, but text is only repainted inside `newOfferAppear`, which runs on refresh. Vanilla hides the gap by showing the `BoughtFrame` overlay:
  ```lua
  if BuySneakerFunction:InvokeServer(child.Name) == true then
      child.BoughtFrame.Visible = true   -- masks the now-stale card
  end
  ```
  Skip that and the PC advertises a sneaker and price that no longer exist, while your buy loop happily re-buys the same slot. Mirror it, or repaint from the attributes.
- **Do not press the refresh button. Call the remote.** Three separate traps here, all confirmed the hard way:
  1. `PCScreenGui.ScreenFrame.TopFrame.RefreshButton` is a **decoy** — PCLocalScript reads it into `_` and never binds it. The live handler is on the PC model in the world: `PC.RefreshButton.SurfaceGui.RefreshButton`.
  2. The decoy still *looks* wired, because `SoundScript` blanket-connects a click sound to every `TextButton`/`ImageButton` under `MainScreenGui`. `getconnections()` returns a non-empty list for buttons that do nothing.
  3. Even the real button is unsafe to fire: `refreshfunction` sets `AutoButtonColor = false`, calls `refreshPageLocal()`, then **yields** (`task.wait(1)`) before restoring it. Driving it through `getconnections():Fire()` dies at the yield, so the flag and the internal `u9` lock are never released — bricking refresh for the rest of the session, for the player too. Recoverable with `debug.setupvalue(fn, 1, false)` on that connection (upvalue 1 is `u9`; verify `up[6]` is an ImageButton and `up[10]` a function first).
- **The 1s/5s figures are the button's client-side lock, not a server cooldown.** Measured clean: `RefreshPageFunction:InvokeServer()` returned a table **6/6 at 1.5s spacing**, ~0.11s latency. The server does refuse sometimes with `nil` at ~0.03s (an explicit refusal, not a timeout), but it is far more permissive than the button implies. Call the remote and repaint the cards yourself — `repaintOffer` only has to mirror `newOfferAppear`.
- Slot count = `Player.PcProgressOffer` (currently 4, max 16). Unlock costs are hardcoded: `{500, 3000, 8000, 15000, 35000, 75000, 100000, 160000, 300000, 500000, 850000, 1250000, 2000000, 4500000, 7500000, 15000000, 25000000, 50000000}`.
- Rarity roll weights, `SneakerModule.rarities`: `Common 54, Uncommon 30, Epic 15, Legendary 1` (per 100).

**Rarity-filter math:** with 4 slots, a Legendary shows on ~4% of pages → ~25 refreshes ≈ 25s of hunting per Legendary. With 16 slots, ~15% per page ≈ 7s. Slot unlocks are the highest-leverage purchase in the whole game for this feature — worth surfacing in the panel as its own recommendation.

Observed live ROI on ordinary offers: **2.1×–2.3×** `MaxSellPrice / offerPrice`. Buy rule should be a ratio threshold, not a flat cap — a flat cap ignores that a $334 Epic at 2.10× and an $88 Common at 2.27× are near-identical trades.

---

## 4. Auto-buy limited shop for a specific shoe

**Solved on the data side, blocked on the movement side.**

Purchase is a server-owned `ProximityPrompt` at `Workspace.LimitedShop.Boxes.BoxN.HoldPart.BuyPrompt`, `MaxActivationDistance = 7`.

**Distance is enforced server-side.** Tested directly: `fireproximityprompt` on an NPC 139 studs away did nothing — no UI, no state change. So a remote-fire from across the map is not available; the character has to be there.

Design that works:

1. Compute from §2 the exact UTC hour your target shoe appears.
2. At `T-30s`, `TeleportPlayer:FireServer()` (the Home button, no args, server-side, legitimate) then walk/CFrame to the shop.
3. On the hour, `fireproximityprompt(box.HoldPart.BuyPrompt)`.
4. Verify by watching `UnsellableInventory` for the new child.

Only real unknown: whether the server rubber-bands a CFrame'd character. Cheap to test — move 20 studs, wait 2s, re-read position.

---

## 5. Auto-sell: bar sell vs fast sell

### Fast sell (cashier stall) — the easy one

Pure remotes, no minigame:

```lua
CashierEvents.SellAllEvent:FireServer()               -- everything
CashierEvents.SellAllButOneEvent:FireServer()         -- keeps 1 of each (index safety)
CashierEvents.SingleSellEvent:FireServer(name, count) -- targeted
```

The cashier rotates through 6 personalities (`CashierModule.cashiers`), each with 4–5 "Best Picks" exposed live at `Workspace.CashierShop.Cashier.Pick1/2/3`. Currently `Bogdan` → Skyline / Thunder / Patent Bred. Picks almost certainly pay a bonus — that is the second number worth measuring (§8). If they do, the panel should hold Pick sneakers back and dump the rest.

`SellAllButOneEvent` is the safe default for any automation: it never empties a line you still need for the index.

### NPC bar sell — the involved one

Flow, exactly as decompiled:

1. NPC `ProximityPrompt` ("Sell Sneaker", distance 10) → server.
2. Server invokes **the client**: `SellSneakerAnimFunction.OnClientInvoke = SellSneakerAnimationFunction(npcModel)`.
3. Client shows a carousel (player picks the sneaker, `u2`), tweens `Line` across `BarAndLine` on a 1.5s reversing Quad tween.
4. On StopButton, the client reads which band it landed on via `GetGuiObjectsAtPosition` matching frames named `COLORX_<band>`.
5. Client returns `(sneakerName, band, cancelled)`; the server pays.

Automating it **without touching the RemoteFunction callback**:

- Read `LineColorsFrame`'s `COLORX_Perfect` child `AbsolutePosition`/`AbsoluteSize` each frame.
- Fire the existing button connections when `Line` overlaps it: `for _,c in getconnections(StopButton.MouseButton1Down) do c:Fire() end`.
- Pick the carousel entry by highest `MaxSellPrice` before stopping.

Do **not** replace `OnClientInvoke` — that freezes the game, and it is unnecessary since the StopButton path gives full control.

Two traps found in the code that a naive build would hit:
- The Perfect band **moves after every sale**: `LineColorsFrame:TweenPosition(UDim2.new(math.random(30,70)/100, ...))`. Hardcoding a timing offset breaks on sale #2.
- If the client can't resolve a band it logs `warn("GotRewardNil", ...)` with the player's name — a client-side warn, so whether it reaches the devs is unknown (see §10). Regardless, the band string is the one value the server takes on trust, which makes it the one value worth earning honestly: time the real bar rather than returning a fabricated "Perfect".

---

## 6. Auto mystery box

Buy is a server prompt at `Workspace.MysteryBoxFolder.MoneyBox.MainPart.ProximityPrompt` — same proximity constraint as §4.

Opening is already automated by the game: `MainScreenGui.MysteryBoxAutoOpen.IsTurnedOn` (BoolValue), which drives `OpenBoxEvent:FireServer()`. Don't rebuild it, just toggle it.

The panel's actual job is **the schedule**, since the box cycles hourly and predictably. Sample of the computed next 24h (yday 234):

| UTC | Money box | Cost |
|---|---|---|
| 01:00 | SuperDunkMysteryBox | $500,000 |
| 03:00 | PandaMoniumMysteryBoxMoney | $1,000,000 |
| 05:00 | AmbushAirForce1Box | $300,000 |
| 07:00 | SixRingsBox | $50,000 |
| 10:00 | VomeroBox | $200,000 |
| 16:00 | PurpleBogdanMysteryBox | $150,000 |

Box contents are flat weight tables, e.g.:

```lua
SuperDunkMysteryBox = {
    ["Mike SB Dunk Low Super Panda"]       = 4000,
    ["Mike SB Dunk Low Super Barkroot Brown"] = 3000,
    ["Mike SB Dunk Low Super Hyper Royal"] = 2000,
    ["Mike SB Dunk Low Super Mean Green"]  =  990,
    ["Mike SB Dunk Low Super Cammellzee"]  =   10,   -- 0.1%
}
```

So "wait for the box that contains the one sneaker I'm missing, at the hour it appears, and buy N" is a precise, computable feature. Frame it as **index completion + trade-up fodder**, and show the honest number: the chase item in that box is 1-in-1000.

---

## 7. Auto trade-up

**The cleanest automation target in the whole game — one remote call, no GUI, no proximity.**

```lua
local reward = TradeUpEvent:InvokeServer(recipeKey, { "SneakerA", "SneakerB", ... })
```

`recipeKey` is a key of `SneakerModule.TradeUps`, and the list is names drawn from `UnsellableInventory`:

| Key | Consumes | Produces |
|---|---|---|
| `CommonExchange` | 5 Common | 1 Common |
| `UncommonExchange` | 5 Uncommon | 1 Uncommon |
| `EpicExchange` | 5 Epic | 1 Epic |
| `LegendaryExchange` | 5 Legendary | 1 Legendary |
| `SigmaExchange` | 10 Special | 1 Special |
| `UncommonTradeUp` | 15 Common | 1 Uncommon |
| `EpicTradeUp` | 15 Uncommon | 1 Epic |
| `LegendaryTradeUp` | 15 Epic | 1 Legendary |
| `SigmaTradeUp` | **100 Legendary** | 1 Special |

`SneakerModule.TradeUpChances` gives the weighted output pool for the top tier:

```
Air Bogdan 3 A Ma Maniere ............ 2400
Air Bogdan 11 Cool Grey .............. 2400
Mike Air Zeezy 2 Solar Red ........... 1500
Air Bogdan 4 Emenem Carhartt ......... 1700
Mike Air Max 1/97 Sean Wotherspoon ... 1200
Kanye East Batesta ................... 500
Bogdan Jumpman Jack Trevor Univ. Red . 300
```

A panel can compute the full ladder: "you hold 47 Uncommon → 3× `EpicTradeUp` → 3 Epic, 2 left over" and execute it in three calls. Exchanges (5→1 same tier) are the reroll mechanic — useful for dumping duplicates you already have in the index.

Note the current save has **0 items in UnsellableInventory**, so this feature has nothing to chew on until boxes/limiteds start flowing. Build it after §6.

---

## 8. Open questions — measure before building

Two numbers change the build order and neither can be read from client code, because the payout math lives server-side.

1. ~~**What multiplier does the cashier pay vs `MaxSellPrice`?**~~ **ANSWERED: 0.55, flat.** See §1. The bar sell is worth 2.0× the cashier per unit, so walking pays for itself on anything valuable. Fast-sell stays right for bulk dumping and for refilling buying power from across the map.
2. **Do the cashier's Best Picks pay a bonus?** If yes, the sell logic splits into "route Picks here, dump the rest there." *(Still unmeasured — needs 2+ of a current Pick held, so a test unit can be sold without losing the index line.)*

One-line test for both, cost is a single cheap sneaker:

```lua
local m = game.Players.LocalPlayer.leaderstats.Money.Value
game:GetService("ReplicatedStorage").RemoteEvents.CashierEvents.SingleSellEvent:FireServer("Mike Air Force 1 White", 1)
task.wait(1)
print("paid:", game.Players.LocalPlayer.leaderstats.Money.Value - m, "vs MaxSellPrice 150")
```

Third, smaller: does the server accept a CFrame'd character (§4), or rubber-band it?

---

## 9. Build order

1. **Kill switch + spending cap.** Every later feature registers with it. Non-negotiable first.
2. **Measure §8.** Three minutes, decides item 4.
3. **Auto-buy w/ rarity + ROI filter** (§3). No proximity, no unknowns, highest cash-per-second.
4. **Auto-sell**, whichever §8 says wins. Fast-sell if it's close; bar-sell only if the gap is real.
5. **Rotation scheduler** (§2). One computed table feeding limited-shop and mystery-box alarms — the same clock powers both, so build it once.
6. **Limited-shop sniper** (§4) on top of the scheduler, once movement is proven.
7. **Auto trade-up** (§7). One call, but needs box/limited inventory to exist first.
8. **SHOES drop sniper.** `BuyShoesApp:InvokeServer(name)` gated on `os.time() >= tm`; `GetShoesAppData` already hands you `tm`, `Pc`, and `Cw = "Stock: 3"` per drop.

---

## 10. Risk notes

- **`BanEvent` is a manual moderation tool, not detection.** Verified: it has zero game-side listeners, and `MainScreenGui.BanFrame` is a two-child form — a TextBox reading `"Enter UserName"` and a "Ban" button, parked at position `0.98, 0.02` and hidden. The button's only connection is `SoundScript`, which attaches a click sound to *every* button in `MainScreenGui` indiscriminately. A GC-wide constant scan for `BanFrame` / `BanEvent` / `Enter UserName` found no game script referencing them. This is a moderator typing a scammer's name, and it implies nothing about automated detection.
- `DailyBoughtSneakers` is tracked per day and throttles PC refresh from 1s to 5s at 5,000 buys. That is a real, observable rate limit to design around — read it as a throttle, not as evidence of monitoring.
- The `warn("GotRewardNil", ..., LocalPlayer.Name)` path fires when a sell result can't resolve a band. It is a client-side `warn`, so it reaches the developers only if they run a log-collection service — unknown either way. Worth not tripping, not worth fearing.

### Lesson from the build

Every "the server is rate-limiting us" conclusion in this project turned out to be a client-side bug wearing a server-side costume. Before blaming a remote, confirm the call is actually reaching it — `getconnections()` returning a non-empty list is not evidence that a button does anything.

Nothing here needs a fabricated value to work — every feature above drives the same remotes a fast player drives. Keep it that way and the panel is an operator, not an exploit: the throttles, cooldowns, and proximity checks are all still doing their job.
