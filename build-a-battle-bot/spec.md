<title>Battle Bot Spec</title>

# Build A Battle Bot — Automation Spec

PlaceId `106382692972340`, GameId `10765666801`. Verified live 2026-09-26 on `my main account` (plot 6, rebirth 4, bot TURBO lv 37→57) with a namecall spy + `OnClientEvent` logger (≈18 min of real play, `bbb_log_2026-09-26.txt`), plus a decompile of all 36 client scripts and 60 shared modules (Potassium workspace `bbb_src/`). ✅ = measured live, 📄 = read from decompiled code only.

---

## 0. TL;DR — best input per farm

**Nothing in this game needs VirtualInputManager, mouse clicks or GUI signal firing.** Combat is 100% server-side and autonomous; the player only picks *where* the bot is. Almost everything is a plain `RemoteEvent:FireServer` from anywhere on the map. Only three things are position-gated, and hard teleport is **not punished** (no kick, no force-drop — unlike Needle in a Haystack).

| Farm | Best input | Gate | Status |
|---|---|---|---|
| Depths money | `BotCommandRemote:FireServer("depthsStart")` / `("depthsStop")` | none | ✅ |
| Pit events (crates, boosts, coins) | `BotCommandRemote:FireServer("toArena")`, leave once `joined` | bot must land 1 hit | ✅ |
| Bot XP | bot parked at plot (`"toWorkshop"` / `"depthsStop"`) | stations cap at 120 s of fuel | ✅ |
| Claim fabricator crates | `CrateRemote:FireServer("claim")` | **none — worked from 64 studs** | ✅ |
| Open crates | `CrateRemote:FireServer("open", {crateId=, count=1..5})` | inventory slots | ✅ |
| Auto-sell junk | `RewardRemote:FireServer("setSetting", "AutoSell<rarity>", true)` | server does the selling | ✅ |
| Equip parts | `GarageRemote:FireServer("equip", {buildId=, uid=})` | **none — no garage walk needed** | ✅ |
| Station buy/upgrade, workshop level, scrapper level | teleport ≤ 10–12 studs → `PlotSignRemote:FireServer(signPart)` | **range-checked**: ignored from 30+ studs | ✅ |
| Scrap (parallel character farm) | teleport onto `workspace.Materials` model, then to plot `Scrapper.Mouth` | 4.5 pickup / 10 deposit | ✅ |
| Rewards / quests / guild / rebirth / skills | their remotes (§2) | eligibility only | ✅ / 📄 |

---

## 1. How the game actually works

The bot is always in exactly one place, and **each place pays a different resource**:

| Mode (`BotCommandRemote "mode"`) | Pays | Notes |
|---|---|---|
| `depths` (`toDepths` in transit) | **money only** | endless PvE waves, your own shaft behind your plot |
| `plot` (`toPlot` in transit) | **XP only** | bot drains your Energy Stations; `GarageRemote "xp"` stream |
| `arena` (`toArena` in transit) — "the Pit" | **event tiers** (coins + crates + 2× boosts) | shared, **PvP**: other players' bots KO yours (`arenaKo {cause="bot"}`), it then rebuilds at plot |
| `bay` | nothing | garage cinematic for part swaps; blocked while bot is in the Depths ("YOUR BOT IS IN THE DEPTHS") |

Measured: bot level sat frozen at **37 for the whole 94 s Depths run**, then went **37 → 57 in ~60 s** after returning to plot. Station billboards read `3.4K/3.4K` (full) while the bot was in the Pit — production past the buffer is **wasted**.

Progression chain: Depths money → station upgrades → fuel/s → XP → bot level (`1.27^(lvl-1)` combat mult) → deeper waves (pay scales with enemy level) → rebirth (+100 % money, +115 % energy, skill points).

### Progression map (all currencies, sinks, farms, gates)

| Currency | Source | Spent on |
|---|---|---|
| Money (`leaderstats.Money`) | Depths waves, event tiers, scrap deposits, part sales, rewards | stations, workshop, fabricator, scrapper, depths skip, guild creation (10K) |
| Skill points (`SkillPoints` attr) | every rebirth: `2 + floor((r-1)/8)` | skill tree (`SkillRemote "buy"`) |
| Bot XP | station fuel, only while the bot is at the plot | bot level, capped at 500 |
| Scrap (carried `Material_*`) | Pit ground spawns (max 12, every 4 s), 2 per kill in Scrap Frenzy | Scrapper → money × `1.24^(lvl-1)` |
| Crates → parts | fabricator deliveries, events, quests, daily/playtime, guild chests, offline | equip (stats) or sell (`{150 … 40000}` by rarity) |
| Timed boosts | events, quests, daily/playtime | 2× money / 2× energy |

| Sink | Level range | Gate | Input |
|---|---|---|---|
| Energy station pad (buy) | new pad = LV.1, 5 fuel/s | free pad slot | `PlotSignRemote(StationAnchor)` near |
| Station level | 1 → 100 (+1/s ≤30, +5/s after) | money | same |
| Workshop level (= pad count 2→6) | 1 → 5 | money (`4000·2^(lvl-2)`) | `PlotSignRemote(WorkshopSign_<n>)` near |
| Fabricator level (delivery rate, box size, luck) | 1 → 10 | **rebirths `{0,0,2,4,7,11,16,22,30,40}`** | `CrateRemote "upgrade"` anywhere |
| Scrapper level | 1 → 18, **resets on rebirth** | **Depths waves `(lvl-1)·2`** | `PlotSignRemote(ScrapperSignHolder)` near |
| Skill tree | 50 nodes (core + 6 arms + 6 tips), `requires` chain, cost `cost·tier` | skill points | `SkillRemote "buy", id` |
| Rebirth | 0 → 100 (Ascension "coming soon") | best wave ≥ `requiredWave(r)` | `RebirthRemote "rebirth"` |
| Guild bosses | — | **"COMING SOON"** in the guild panel | — |

---

## 2. Remote API (all `RemoteEvent`s — the client never calls `InvokeServer`)

### Bot control — `ReplicatedStorage.BotCommandRemote`

| Call | Effect | Status |
|---|---|---|
| `FireServer("depthsStart")` | Depths from wave 1 | ✅ |
| `FireServer("depthsStart", {skip = true})` | start at `DepthsSkipWave` for `DepthsSkipCost` (player attrs); denied → `"skipDenied"` | 📄 |
| `FireServer("depthsStop")` | end run, bot drives home | ✅ |
| `FireServer("toArena")` | send to Pit. **Ignored while in the Depths** — `depthsStop` first (works right away in `toPlot`) | ✅ |
| `FireServer("toWorkshop")` | Pit → plot | ✅ |

`toPlot` is the resting state after `toWorkshop`/`depthsStop` — the server never follows it with `plot` (only a KO or bay exit sends `plot`). `depthsStart` works straight from the Pit.
| `FireServer("reviveHold")` | holds the 90 s revive window (Robux revive) — don't use | 📄 |

Server → client: `"mode", <state>`, `"depthsDefeat", {wave, record, earned}`, `"depthsRevived"`, `"arenaKo", {cause="bot"|"titan"|"champion"}`, `"skipDenied"`.
On `depthsDefeat` fire `depthsStop` immediately — otherwise the bot idles in the 90 s revive window.

### Crates & parts

| Call | Effect | Status |
|---|---|---|
| `CrateRemote:FireServer("claim")` | fabricator pile → inventory. **No range check** (fired from 63.7 studs, pending emptied) | ✅ |
| `CrateRemote:FireServer("open", {crateId = "Galaxy", count = 1..5})` | → `"opened", {results = {{uid, partId, rarity}|{coins, sold=true}}}` | ✅ |
| `CrateRemote:FireServer("request")` | → `"sync", {counts = {Normal=…}}` + `"garage", {pending, timer, capacity, level, cost, locked, needRebirths, luckPercent}` (also pushed every 1 s) | ✅ |
| `CrateRemote:FireServer("upgrade")` | fabricator level (rebirth-locked: `GARAGE_REBIRTHS = {0,0,2,4,7,11,16,22,30,40}`) | ✅ |
| `RewardRemote:FireServer("setSetting", "AutoSell1", true)` | server auto-sells that rarity on open (1..7) | ✅ |
| `GarageRemote:FireServer("sell", uid, true)` / `("sellMany", {uid, …}, true)` | sell; values `{150, 400, 1000, 2500, 6000, 15000, 40000}` by rarity | ✅ |
| `GarageRemote:FireServer("lock", {uid =, locked = true})` | protect a part | 📄 |
| `GarageRemote:FireServer("equip", {buildId =, uid =})` | equip onto any of the 3 builds, **from anywhere** (build #2 rev 2→3 while bot was in the Pit) | ✅ |
| `GarageRemote:FireServer("deploy", buildId)` | switch active build | 📄 |
| `GarageRemote:FireServer("request")` | → `"sync", {builds = {{id, name, level, xp, rev, parts = {Weapon, Body, Head, Wheels, Satellite → uid}}}, parts = {{id, uid}}, deployedId}` | ✅ |
| `WorkshopBayRemote:FireServer("swap", {uid =})` / `("deploy")` | bay path (needs garage prompt + bot at plot) — `equip` makes it unnecessary | ✅ |

Stats per part: `BotParts.PARTS[partId].stat` (weapon→attack, body→health, head→crit, wheels→attackSpeed), × `CrateConfig.partStatMult(crateId) = 1 + (tier-1)·0.06`. Compute bests locally from `require(ReplicatedStorage.Shared.BotParts)`.

### Rewards, quests, progression

| Call | Status |
|---|---|
| `RewardRemote:FireServer("claimPlaytime", index)` → `"claimed", {kind="playtime", index}` | ✅ |
| `RewardRemote:FireServer("claimDaily")` | 📄 |
| `RewardRemote:FireServer("redeemCode", "BUILDABOT")` (1.5K + 2 Cage) | 📄 |
| `RewardRemote:FireServer("request")` → `"sync", {daily = {claimable, day, streak}, playtime = {claimed, elapsed}, settings, group}` | ✅ |
| `QuestRemote:FireServer("claim", questId)` (`d_waves`, `d_pit`, `w_rebirth`, …) | 📄 |
| `GuildRemote:FireServer("claim", {period = "day"})` / `{period = "week"}` → 60K + Void / 40K + Void | ✅ |
| `RebirthRemote:FireServer("rebirth")` when `BestDepthWave >= requiredWave` | 📄 |
| `SkillRemote:FireServer("buy", "wealth_2")` — ids `{wealth,energy,luck,scrap,power,armor}_{n}` + tips | 📄 |
| `OfflineRemote:FireServer("request")` → then `("seen", id)` | 📄 |

`RebirthRemote("auto", true)` is gated by the `Perk_AutoRebirth` pass; the fabricator's auto-claim is the `AutoClaim` pass — both are replaced for free by firing `rebirth` / `claim` yourself.

Not probed on purpose: `AdminRemote`, `ShopRemote "devBuy"`, `MarketplaceService` prompts.

---

## 3. Position-gated actions

### Plot signs (the only prompts in the game)

Every interactable is a `PlotSign`-tagged part under `workspace.Map.Plots.Plot<PlotIndex>` with a `ProximityPrompt` (hold 0, no line-of-sight) and a `SignActionRange` attribute:

| Part | Action | Range |
|---|---|---|
| `Stations.StationAnchor` (×6) | buy / **UPGRADE STATION** | 10 |
| `Scrapper.ScrapperSignHolder` | upgrade scrapper | 12 |
| `Sign.WorkshopSign_<n>` | workshop upgrade (station slots 2→6) | 12 |
| `Fabricator.KitButtonHolder` | open collect UI (use `CrateRemote "claim"` instead) | 12 |
| `Garage.KitButtonHolder` | enter bay (use `GarageRemote "equip"` instead) | 12 |

Measured on the fabricator: `fireproximityprompt` from **71 studs → ignored**, from **9.5 studs → `openUi`** ✅. So the server range-checks prompt triggers.

**But don't use the prompts for upgrades.** The `WorkshopSign` client disables the shown prompt every frame unless the camera faces the sign (dot ≥ 0.899), so `fireproximityprompt` after a teleport fails whenever the camera points elsewhere. The first farm saw ~10 "didn't take" in a row this way.

**Use `PlotSignRemote:FireServer(part)`** instead. It's the game's own billboard-click fallback, and it handles stations (buy and upgrade), `WorkshopSign_<n>` and `ScrapperSignHolder`. It's **range-checked** ✅: ignored from 30+ studs, reliable when standing 4 studs off the sign. It does nothing for Fabricator/Garage.

Read the state from the server-written labels:

| Target | Where | Text |
|---|---|---|
| Built station | `PlayerGui.PlotSignBillboard` (Adornee = `StationAnchor`) | `ENERGY STATION LV.25` · `29/s · 3.0K/3.5K` |
| Station upgrade | `PlayerGui.PlotSignActionBillboard` | `UPGRADE STATION` · `CostLabel 63.5K` |
| **Empty pad** (fresh / after rebirth) | `PlayerGui.PlotSignBillboard` | `ENERGY STATION` · `BUY` · `CostLabel 400` |
| Workshop (pad count 2→6) | workspace `Sign.…WorkshopSignScreen` SurfaceGui | `WORKSHOP LV.3` · `UPGRADE` · `16.0K` (`MAX LEVEL` at LV.5) |
| Scrapper | `PlayerGui.PlotSignBillboard` (Adornee = `ScrapperSignHolder`) | `SCRAPPER LV.9` · `25.6K` · `×5.59` |

### Scrap

Materials (`workspace.Materials.Material_{Bolt|Pipe|Gear|Plate|Cell}`, values 8/15/26/42/67) spawn in the central Pit, at most 12 on the ground, respawning every 4 s. Measured:

- Teleport HRP to a material's position + 3 Y → **picked up in 0.21 s** (model appears inside the character). ✅
- Hard teleport to `Scrapper.Mouth + (4,3,0)` → `ScrapperRemote "deposit", pos, value`, **no force-drop**. ✅
- Deposit ticks 0.1–0.2 s per piece while you're in range. Carry max is 20.
- Payout ≈ value × scrapper mult (`1.24^(lvl-1)`, lv 9 = ×5.59, max LV18 = ×38.7) × money boosts. That's ~300 per piece at LV9, vs ~26–31K per Depths wave.
- **It's still worth running.** Scrap is the character's farm, so it **stacks on top of** whatever the bot is doing. It also feeds `d_scrap` (40) and `w_scrap` (400), and Scrap Frenzy drops 2 per kill. The farm delivered 51 pieces in its first ~3 minutes.

Materials sometimes sit at y≈20–33 (on pit structure); skip anything with `Y > 3`.

### Alien Raid

Config: every 600 s, lasts 240 s, drops a crate every 8 s (crates live 45 s), `CAPTURE_RADIUS 6`, `CAPTURE_TIME 60`. Lasers fire 3 at a time every 5 s: 35 damage, radius 6, 0.9 s warning. Server → `AlienShipRemote "start"/"state"/"end" {caught}`. Crates appear as `workspace.AlienShip.Crate_Alien_<n>`.

- **Touching a crate doesn't catch it.** Measured: touch-and-leave caught 0 in one raid.
- Per the player: **the character must stay in the arena with the crate for the whole capture timer** until it's delivered. A delivery shows up as `CrateRemote "sync"` `counts.Alien` rising.
- The farm's catcher parks within the capture radius, hopping 2.5 studs every 1.5 s to beat the laser warning. It pauses all other character teleports and logs the raid's `"state"` fields the first time. **First live run still pending.**

---

## 4. Measured mechanics & formulas

### Depths

- Enemy level: `L(w) = max(1, floor(w + 0.0444·max(0, w-14)² + 0.5))`
- Pay per wave: `100 · L(w) · moneyMult`. Measured moneyMult ≈ **11.4** at rebirth 4 with a 2× boost (wave 27 skip cost 236,394 = ½·Σpay).
- Pace: ~2.7 s per wave early, 4–12 s per wave near the bot's limit. It stalled at wave 27 (enemy L35) at bot lv 37, so **reach ≈ bot level**.
- Skip costs ½ of waves 1..S. That only pays when the bot can go far past S in the time available — for money, a fresh run usually wins. Use skip to hit a rebirth wave fast.
- Rebirth wave: `10 + 2·min(r,19) + max(0, r-19)/3` → r4 needs **18**, r10 needs 30, r20 needs 48. The panel says it **keeps bots/parts/garage/decor, resets money/bot levels/best wave**. That's incomplete. It **also wipes every Energy Station** (pads go back to `BUY · 400`), **resets the workshop to LV.1** (2 pads) **and resets the scrapper to LV.1** ✅ (LV.11 → LV.1 at rebirth 10). The fabricator level survives (still LV.5 at rebirth 9).

| wave | enemy L | base pay | cumulative |
|---:|---:|---:|---:|
| 10 | 10 | 1,000 | 5,500 |
| 20 | 22 | 2,200 | 21,400 |
| 30 | 41 | 4,100 | 53,100 |
| 40 | 70 | 7,000 | 109,500 |
| 50 | 108 | 10,800 | 199,300 |

### Energy stations → XP

- Rate `5 + (min(L,30)-1) + 5·max(0, L-30)` fuel/s. Matched the billboards (LV25 = 29/s, LV29 = 33/s).
- Buffer = rate × **120 s**; the bot drains it only in `plot` mode. 1 fuel = 1 XP × energy mult.
- Upgrade L→L+1 costs `300·1.25^(L-1)` (×1.18 per level past 40).
- **Buy order: cheapest cost per +1 fuel/s.** The step jumps from +1/s to **+5/s past LV30**, so 30→31 is 4× better value than 29→30:

| upgrade | cost | +rate | cost per +1/s |
|---|---:|---:|---:|
| 25→26 | 63.5K | +1 | 63.5K |
| 29→30 | 155K | +1 | 155K |
| **30→31** | **194K** | **+5** | **38.8K** |
| 35→36 | 592K | +5 | 118K |
| 40→41 | 1.70M | +5 | 341K |

- XP to next level: `500·1.075^(lvl-1)` (lv 57 needs 28.7K).

### Pit events

The cycle seen was Elite → (150 s gap) → Frenzy 150 s → gap → **Pit Titan** 240 s → gap → **Depths Rush** 180 s. `workspace.NextEventBoard` text labels read `NEXT EVENT | <NAME> | IN m:ss`, so that's your scheduler clock.

- **Tiers are server-wide totals** (swarm kills, titan damage), not yours. You only need `joined`.
- Swarm variants report `SwarmRemote "state" {joined, myKills, kills, wave, endsIn, kind}`. The Titan has no flag; one hit presumably counts.
- **`joined` survives leaving.** The bot left for plot at t=1008, `joined` stayed true, and Rush rewards landed at t=1048. Re-confirmed cleanly by `bbb_farm.lua`: joined a swarm, left the same second, and 46 s later got 6 tiers (15.5K + 5 crates). ✅
- Observed payouts (with ~11× money mult):

| event | tiers | coins | crates | boosts |
|---|---:|---:|---|---|
| Elite (0 own kills) | 7 | 116,000 | Lava, Void, Space, Alien, Golden, Galaxy | 2× energy 2 m, 2× money 3 m + 5 m |
| Frenzy | 6 | 25,000 | Cage, Lava, Toxic, Void, Space | 2× energy 3 m, 2× money 3 m |
| Titan | 5 | 12,000 | Cage, Lava, Toxic, Void | 2× energy 2 m, 2× money 3 m |
| Rush | 5 | 16,000 | Cage, Lava, Toxic, Void | 2× energy 3 m, 2× money 3 m |

- About 13 s from `toArena` (sent from home) to `joined` for a swarm.

### Fabricator & crates — what they are and what to do with them

**The fabricator** is a timer that drops crates into a pile at your plot. It survives rebirths.

| LV | rebirths | cost | delivery | storage | crates/h (luck 0 → 100 %) |
|---:|---:|---:|---:|---:|---:|
| 1 | 0 | — | 180 s | 10 | 20 |
| 4 | 4 | 16K | 153 s | 19 | 40 → 39 |
| 5 | 7 | 32K | 144 s | 22 | 42 → 41 |
| 6 | 11 | 64K | 135 s | 25 | 48 → 47 |
| 7 | 16 | 128K | 126 s | 28 | 69 → 67 |
| 8 | 22 | 256K | 117 s | 31 | 73 → 71 |
| 10 | 40 | 1.02M | 99 s | 37 | 104 |

- Each delivery rolls **one crate type**, then bulk copies:
  - Type odds interpolate from `{55, 24, 10, 6, 3, 1.5, 0.4, 0.09, 0.01}` at LV1 to `{30, 26, 18, 11, 7, 4.5, 2.2, 1, 0.3}` at LV10 (Normal → Galaxy).
  - Bulk copies (Normal and Cage every 3 levels, Lava every 5): e.g. LV5 = ×2 Normal/Cage, LV7 = ×3.
- **Luck bar**: play time this session / 100 min, from `garage.luckSeconds`. It resets when you rejoin; the `LuckyStart` pass starts it at 25 %, and the skill-tree luck arm adds +8 % per node. A full bar is worth **+2 fabricator levels** of crate-type odds (LV5 Lava+ goes from 31 % to 36 %). It does nothing at LV10. **Long sessions give better crates**, so don't rejoin or hop needlessly.
- **The pile stops at storage.** Claim promptly (`CrateRemote "claim"`, from anywhere). Offline deliveries run at 0.25× speed, up to half the storage.
- Admin **"CRATE LUCK"** events (`workspace.AdminLuckMult` / `AdminLuckEndsAt`) raise `EVENT_LUCK`, which scales the rarer rows of **both** the delivery roll and the part roll when you open. They're rare and unscheduled.

**Crates → parts.** Opening is the only use for a crate. Part odds by crate:

| crate | Epic+ | Legendary+ | Mythic | Godly | EV if sold |
|---|---:|---:|---:|---:|---:|
| Normal | 3.9 % | 2.6 % | — | — | 430 |
| Cage | 4.5 % | 2.9 % | — | — | 547 |
| Lava | 9.8 % | 5.3 % | 1.60 % | 0.53 % | 1,170 |
| Void | 17.6 % | 6.5 % | 1.95 % | 0.65 % | 1,566 |
| Alien | 36.1 % | 7.5 % | 2.25 % | 0.75 % | 2,120 |
| Galaxy | 50.9 % | 8.7 % | 2.60 % | 0.87 % | 2,516 |

- **Rarity decides power.** Each rarity step is about ×1.45 stat, while a better crate adds only +6 % per tier (baked into `BotParts.PARTS[id].stat`, `pool` = crate). For example, a Normal Legendary weapon is 24 ATK and a Galaxy Godly is 71.
- **Mythic and Godly only drop from Lava+ crates.** The richest Lava+ source is Pit events (Elite paid 6 crates from Lava to Galaxy), then quests and daily, then the fabricator (about 31 % Lava+ at LV5).
- Satellites carry per-crate specials at r3/r5/r6/r7 (Normal r5 = SatelliteStrike … Galaxy r7 = BigBang). Rank them by rarity, with crate tier as the tie-break.
- Sell values are `{150, 400, 1000, 2500, 6000, 15000, 40000}` by rarity, × the sell skill. Selling pays the flat value with no money multipliers, so it's pocket change except Mythic/Godly. **Sell for inventory space, not income.** The inventory holds 100 (+50 with the pass, + skill slots), and when it's full, opening stops (`CrateRemote "full"`).
- The Index is a viewer only: no rewards, and discovery survives selling. There's no reason to keep duplicates.

**So:**
1. Claim instantly.
2. Open everything as it arrives. Holding for a CRATE LUCK event is optional and only sensible for Lava+.
3. Equip the best part per slot.
4. Sell the rest except the best 1–2 per slot and anything Mythic+.
5. Upgrade the fabricator the moment each level unlocks, since it's cheap next to stations.
6. Join every Pit event, because that's where the good crates come from.

### Multipliers seen (`BoostRemote "sync"`)

Group +20 % money/energy (claimed), Friends +20 % (10 % per friend on server), Guild +16 %, plus quest/event timed 2× boosts. Rebirth: +100 % money, +115 % energy each.

---

## 5. The farm — `bbb_farm.lua` features & settings

Deploy: `%USERPROFILE%\AppData\Local\Potassium\workspace\bbb_farm.lua`, run `loadstring(readfile("bbb_farm.lua"))()`. RightCtrl toggles the UI. Config `farm` (SaveManager folder `BattleBotFarm`) is the autoload. The live log goes to `bbb_farm_log.txt`.

| Tab | Feature | Settings (default) |
|---|---|---|
| **Bot** | Auto Depths: run → defeat → `depthsStop` at once (skips the 90 s revive window) → drain stations at home → restart | Max run length (0 = until defeat) · Leave plot at station fill (15 %) · Max plot stay (30 s) · Use wave skip (off) · Skip only if cost ≤ (25 % of money) |
| | Auto Pit Events: `depthsStop` if in Depths → `toArena` → leave once joined; retries after a KO | Events to join (swarm, elite, frenzy, rush, titan) · In the Pit (Join, then leave / Stay whole event) · Titan: time in Pit (20 s) · Pause after a manual command (90 s; server `toPlot` after a rebirth is not counted) |
| **Crates & Parts** | Auto Claim (from anywhere) · Auto Fabricator · Auto Open | Crate types to open (all) · Hide reveal animation (on) · Hold crates for CRATE LUCK events (off) + Hold crates from (Lava). Status: fabricator LV, pile, next delivery, luck bar, unopened crates |
| | Auto Sell Junk (off; irreversible) + "Sell junk now" | Keep best per slot (2) · Never sell (Mythic+). Always keeps locked parts and parts on any build. Status: parts/slots and junk preview |
| | Auto Equip Best, only while the bot is home | Slots to manage (all five) |
| **Upgrades** | Auto Stations & Workshop: buys empty pads, workshop levels and station levels by lowest coins per fuel/s | Workshop first (on) · Station level cap (0 = none) · Keep in reserve (0 % of money) |
| | Auto Fabricator | shares the reserve |
| | Auto Skill Tree | Focus (Economy / Combat / Crates / Cheapest) · Save points for top pick (on) |
| | Auto Rebirth | Extra waves before rebirth (0) · Stop at rebirth (0 = no limit) |
| **Rewards** | Playtime · Daily login · Quests · Guild chests, each its own toggle | Redeem BUILDABOT button |
| **Scrap** | Auto Collect Scrap: sweep the Pit nearest-first → Scrapper → back | Only during Scrap Frenzy (off) · Start a trip at (1 piece) · Return to start (on) · Auto Upgrade Scrapper |
| | Alien Raid catcher: hold in the Pit with the crate for its whole capture timer | Status: raid state, crates in the Pit, caught this session |
| **Status** | Live counters + log | — |
| **Settings** | Anti-AFK (on) · Unload · configs · themes | — |

Verified live with the farm: swarm joined, left the same second, 6 tiers paid; post-rebirth rebuild went 2 BUY pads → workshop LV.1→2→…→5 → new pads → upgrades; 51 scrap pieces delivered in ~3 min; scrapper LV.1→6; skills bought on rebirth.

---

## 6. Open questions

- Alien Raid capture rules (teleport vs stepped, carry-to-plot?). The farm logs the raid folder the first time it sees one.
- Whether playtime `claimed` resets on rejoin (`elapsed` is per-session; if it does, rejoin-farming the 1-min 2× Cage tier is possible).
- `GarageRemote "equip"` on the **deployed** build while it's in the Depths (only tested on idle build #2 — note build #2 now holds spare `CageWeapon2`).
