# Pixel Conquest — spec

Roblox place 138110382920220 (GameId 10764297006), by @8Yoonie (mods by BunniGames). Released 2026-08-29; ~12.7M visits, ~8k CCU.
Port of OpenFront.io. No wiki exists. Recon done 2026-09-29: dump is in `Potassium/workspace/pc_recon/`, with decompiles in `mod/`. Recon script: `pc_recon.lua` (steps 1/2/3).

## Architecture
- **Fully server-authoritative.** The client sends intents and renders State/Delta. `Sim.lua` sits in ReplicatedStorage but runs on the server.
- Lobby and match are separate servers. `ReplicatedStorage:GetAttribute("ConquestRole")` = `"lobby"` or `"match"`; match servers are private.
- Map: 880×550 tiles, tile `idx = y*880 + x`. 10 sim ticks/s.
- **ConquestCheats/* and ConquestSim/*** are dev chat-command relays (`XRequest:FireServer(text)`). **HONEYPOT — never fire.**

## Remotes (all RemoteEvents in `ReplicatedStorage.ConquestNet`)

### Intent: `FireServer({t=..., ...})`
Verified with the spy.

| Intent | Notes |
|---|---|
| `{t="hello", tile=0}` | sent on load |
| `{t="spawn", tile}` | spawn phase, ~15 s |
| `{t="attack", tile, ratio}` | ratio 0.05..1, needs ≥250 troops, max 4 fronts |
| `{t="build", tile, kind}` | 1 city, 2 port, 3 defense, 5 SAM, 18 artillery, 19 airfield, 21 railgun (6 factory is disabled); buildings ≥15 tiles apart |
| `{t="nuke", tile, kind}` | 13 atom (750k), 17 mega (2.5M), 20 scattershot (3.75M); no silo needed |
| `{t="airstrike", from, tile}` | fired from an airfield |
| `{t="railgun", from, tile}` | fired from a railgun |
| `{t="railsite", from, tile}` | |
| `{t="movegunboat", ids={id}, tile}` | |
| `{t="reinforce"}` | BARRACKS pass; 100k gold, 30 s cooldown |
| `{t="leave"}` | back to lobby |
| `{t="revive", tile=0}` | costs Robux, so avoid |
| `{t="ally"\|"allyno"\|"unally"\|"renew"\|"target"\|"embargo", id [, stop]}` | diplomacy |
| `{t="embargoall", stop}` | diplomacy |

### LobbyIntent (lobby only; client throttles to 1 per 1.05 s)
- `("join", "slotN", tag)`, `("leave")`
- `("reward")`: one-time Mega Nuke pass + 1k Money
- Private rooms: `("create", settings6, tag)`, `("pjoin", code, tag)`, `("pstart")`
- Cosmetics: `("pattern"|"flag", "buy"|"equip", key)`

### Shop
- `("passmoney", KEY)`: buys a pass with Money
- `("money")`: asks for the balance
- `("buy", productKey)` = **Robux prompt, never automate**. The spy saw a GAME-side `Shop("buy","GOLD_MEDIUM")`.

### State / Delta (server to client)
- **State** `(kind, payload, full)`. Kinds:
  - `init`, `snapshot`, `players`, `structs`, `armies`
  - `fronts`: gold, costs, attacks
  - `phase`, `win`, `denied`, `money`, …
- **Delta**: varint buffer of (tile, owner) pairs.

## Economy
- Gold: flat 1,000/s per human, whatever the land. Trade ships pay up to 75k. Conquering a player gives 50% of their gold.
- Troop cap: `2*(tiles^0.6*1000+50000) + cityLvls*250k`.
- Troop growth peaks at 40-60% of cap.
- Build cost scaling: see the subagent table (Economy.cost:114):
  - City 25k/75k/125k…, cap 1M
  - Defense 50k·(n+1)
  - SAM from 1M
  - Artillery 150k·(n+1)
  - Airfield 500k·(n+1)
  - Railgun 2.5M·(n+1)
- Win: hold 90% of the land. After 30 min the threshold drops 2 points per minute.
- Alliances last 5 min; renew in the last 30 s. A break gives traitor status for 30 s (defense ×0.5).

## Persistent Money
- Payout = 100 + 15/min survived + 30 per land share + 54 per kill, plus placement and win bonuses scaled by minutes. **Survival time dominates.**
- Passes for Money: MEGANUKE 10k, BARRACKS 20k, SCATTERSHOT 20k, ARTILLERY 25k, AIRSTRIKE 100k, RAILGUN 250k.
- Ownership shows as `ConquestPass_*` player attributes.
- No rebirth, dailies or codes. The brainrot/rebirth store UI is template leftovers.

## Feature plan (UI tabs)
1. **Match: Expand**
   - Auto spawn. Options: far from players, coast-bias toggle.
   - Auto expand into neutral land. Options: ratio, target troop band (40-60% of cap), max fronts ≤4, neutral-only toggle.
2. **Match: Combat**
   - Auto attack weakest neighbour. Options: min troop edge, skip allies, skip players with bigger troops.
   - Auto defense post on incoming fronts.
3. **Match: Build**
   - Priority list: city > port > defense > SAM > artillery > airfield.
   - Options: gold reserve, max count per kind, spacing (auto ≥15 tiles).
4. **Match: Weapons**
   - Auto nuke, target the biggest threat's city cluster. Options: kind, min gold, skip allies, avoid SAM range.
   - Auto airstrike and auto railgun on cooldown.
   - Auto SAM when enemies hold ≥ X gold.
5. **Diplomacy**
   - Auto accept, with whitelist/blacklist.
   - Auto renew.
   - Never break (hard-locked, because traitor status costs ×0.5 defense).
   - Auto request with neighbours stronger than me.
6. **Lobby / Loop**
   - Auto requeue: `leave` on `win` or death, then `join` the fastest slot. Options: slot/mode filter.
   - Claim the one-time reward.
   - Auto buy passes with Money. Options: priority order, reserve.
7. **Info**
   - ESP overlay: troops, gold, allies/traitors.
   - Live Money payout estimate.
   - Log.
   - SaveManager.

## Redundancies / failsafes
- **Single intent queue.** All features go through one sender that dedups the same (t, tile) within 1 s (the game already spams the same attack tile ×3) and caps rate so the server doesn't deny spam.
- **Gold arbiter.** Build, nuke, SAM and reinforce share one gold budget with priority and a reserve, so they don't race on the same `fronts.gold`.
- **Expand and attack share the front limit (4).** One front scheduler owns the slots.
- **Pull state from the server.** Read gold, costs and fronts from State `fronts`; never compute them locally. On `denied{reason}`, back off that action.
- **Requeue watchdog.** If `ConquestRole` is `"match"` and there's no State for 30 s, leave. If in the lobby and not queued for 10 s, re-join.
- **Robux guard.** Never send `revive`, `topup` or `Shop "buy"`/`"pass"`. Hook-block the GAME-side auto prompts as an option.
- **Honeypot guard.** Never touch `ConquestCheats`/`ConquestSim`.
- **Reinjection.** A match→lobby hop is a teleport, so reload through `queue_on_teleport` with a newest-copy-wins token.

## Farm: pc_main.lua (v1, 2026-09-29)
- Tabs: Expand, Combat, Build, Weapons, Diplomacy, Lobby, Info, Settings. Log: `PixelConquest/log.txt`. Live state: `getgenv().PC_FARM.S`.
- Map comes from the game's own TileMap: State handler connection -> upvalue table with `terrain`+`owner` buffers (conn #6, upvalue 25 on 2026-09-29).
- My id is sent in the `init` packet. When injected mid-match there is no init, so it comes from the client's id->userId upvalue table (upvalue 31). It must be resolved BEFORE the scan gate: v1 had a chicken-and-egg bug where it waited on itself.
- Verified live: city + port built, 0 denied, structs arrive even mid-match (full resend).
- Untested yet: spawn picker, auto attack, nukes, strikes, reinforce, lobby queue/leave/reward/pass buy, teleport reinject.
- Live test 2026-09-29 18:37-18:41 verified:
  - Lobby: auto queue -> match launch -> teleport reinject.
  - Spawn picker (200 tiles from others).
  - Expand band.
  - City upgrade-in-place.
  - Port.
  - Auto attack (weakest / finish-off priority).
  - Atom nuke.
  - Names recovered from the client upvalue (largest number->string table).
- Fixed during test:
  - Double spawn pick. The "spawned" preview means the pick was accepted.
  - Stacked queue_on_teleport. Now guarded by getgenv().PC_QUEUED.
  - Log wiped on each reload.
- Combat v1.1: revenge (grudge list from fronts.inc; own ratio/threshold/edge; works with attack off), traitor and finish-off priority, hold-when-hit. Revenge is not triggered live yet: no one attacked during the test.
- **Combat math (Sim.lua:2560-2590):**
  - Attacker loss per tile ∝ clamp(defender TOTAL troops / attack troops) × terrain. Defense density = troops / tiles.
  - Sending troops out lowers my own defense.
  - v1.1 compared against a quarter of the enemy army. Revenge counterattacked a player with 4M troops, and auto nuke fired 7 Atoms at the biggest player 4 s apart, which provoked them. The user got wrecked.
- **Fixed in v1.2:**
  - Checks now compare against the enemy's full army.
  - Revenge only fires when I'm ≥1.3× stronger.
  - Troops are held when a strong player attacks me.
  - Auto nukes have a 45 s cooldown and never target an unprovoked stronger player.
  - Revenge nukes are keyed on missile `l`/`pl`/`rf` events whose `dst` is on my land, plus an anti-nuke rush after being nuked.
- **v1.3 (2026-09-29): counter attack + nuke targeting from the Sim source**
  - `OPPOSING_ATTACKS_CANCEL` (Sim launchAttack): my attack on someone attacking me cancels their attack 1:1 first, and the rest invades their home. `players.troops` = home troops, so it already excludes their outgoing attack.
  - Counter modes: cancel (1.05× their attack) or cancel+invade (+ their home × edge). Always keep `keepHome`% of my troops.
  - Can't cancel → LAST STAND:
    - Nuke the attacker. It kills troops per tile hit, including all their running attacks (Nukes.lua:1097-1133).
    - Defense post on that border.
    - Reinforce.
    - Ask them to ally.
  - Nukes remove EVERY structure within the outer radius (Nukes.lua:1153). `nukeSpot` picks the spot covering the most of their city levels (and SAM/railgun/airfield), and never covers my structures, my border or an enemy SAM. Revenge nukes are cities-only.
  - Build overshoot fix: 3 s per-kind wait, because the structs packet lags.
- **v1.4 (2026-09-29): auto anti-nuke + reclaim**
  - Anti-nuke manager:
    - Range = 150 - 480/(lv+5): Lv1 = 70, Lv10 ≈ 118.
    - Building the same kind within 15 tiles of my own one UPGRADES it (Economy:1327-1352).
    - Placement covers the most uncovered value (city Lv ×10, other buildings 3). Requires a minimum value, and pending orders are counted for 20 s.
    - Modes: Always / Once nukes fly / After I'm nuked. Being nuked always rushes one.
    - The old rush overshot live: 3 in 5 s.
  - Reclaim:
    - A neutral attack spreads only through connected open land from its seed tile (Sim.seedFrontier). A nuke hole inside my land is never reached by the expand front.
    - A new neutral attack at another tile MERGES into the existing front and seeds it there.
    - Nuke dst tiles on my land are remembered; each gets a push at the nearest open contact tile.
    - Above bandHigh it also seeds random 40×40 regions of open contact (disconnected pockets).
    - Fallout tiles defend ×(5 - 2×falloutRatio).
  - Grudge fix: the "stronger" check applies on both paths. v1.3 auto-attack tagged grudge targets "revenge" and chased a player with 7.47M troops.
  - Live: revenge nukes fired at another player ×5 (one per nuke they sent); counter "cancel + invade" fired.
- **v1.5 (2026-09-29): islands + timed bad tiles**
  - Islands:
    - The client sends a plain `attack` for any tile. For a tile I don't border, the server decides on a transport boat (`Sim.launchTransportBoat`: troops/5 whatever the ratio, max 3 at sea, needs landing and sea route).
    - The player intent handler isn't replicated. Bot AI refuses boats to open land.
    - So the farm tries once: a `notadjacent` denial right after an island send turns islands off for that match.
    - Target: random open, passable coast tile nearest to my coast within islandMaxDist.
  - Timed bad tiles: a build refused with a non-gold reason within 3 s is skipped for 30 s; permanent reasons stay blocked. Before this, a city upgrade was re-sent ×3 while still under construction.
  - Last stand seen live: defense post + ally request vs another player.
- **v1.6 (2026-09-29): anti-nuke preparation + spend limits**
  - Before this, the manager never built ahead: the default mode was reactive. It also silently gave up on dense land, where no random tile was 15+ from all buildings.
  - New default mode **Prepare**: arms after 6 min played (a real `spawn -> playing` start is tracked; a mid-match inject assumes late game) or once cities total Lv 20. Nukes seen or me being nuked always arm it.
  - Placement candidates: rings 18/28/40 tiles around the top-10 uncovered valuable buildings, plus interior tiles. If nothing fits, it upgrades instead, and the idle reason shows in the status.
  - Spend bugs seen live:
    - 4 upgrades at 3M each in 10 s (levels lag).
    - After a nuke wiped my cities (Lv 0), ALL builds paused to save 3M for an anti-nuke protecting value 6.
  - Spend fixes:
    - 15 s between anti-nuke orders; max upgrade Lv 5.
    - Upgrades only when gold ≥ 2× cost or under nuke threat.
    - Total and uncovered value must be ≥ samMinValue, even when nuked.
    - The build pause only happens under a real threat (nukes seen or me nuked).
  - Revenge nukes need ≥ revengeMinLv city levels in the blast. Seen live: an Atom was fired at a spot with 0 city levels (ports only). After the fix it hit another player for 5 city levels.
- **v1.7:** `useHudRatio` (default on) reads the game's ATTACK SIZE slider from `PlayerGui.Conquest.Bar.CapCommit.Text` ("ATTACK SIZE  33%"). Expand, attack, revenge, islands and spread use it. Counter attacks size themselves; reclaim keeps its own small %. Attack log lines show `@N%`. Islands confirmed live: the server boats to open coast (4+ boats launched, no `notadjacent`).
- **v1.8 (2026-09-29): placement strategy, islands, camera**
  - Placement:
    - Cities: lowest-level city upgraded first, up to cityMaxLv 5, then a new city ≥ citySpread 31 from others (outside one Atom blast), scored by depth from the border. One Lv 10 city = 2.5M cap in one blast.
    - Ports: far from my other ports (trade pays 50/tile of route, routes <300 debuffed), and off the front.
    - Defense posts: 6 tiles behind the attacked border (range 30), maximising the border tiles covered.
    - Artillery: 12 behind the longest enemy border (range 45).
    - Airfield: 25 behind the busiest front (range 156).
    - Railgun: deepest interior.
  - Expand test (landlocked match):
    - 0 open contacts.
    - Island boats never fired: islandMin 45% while troops sat at 20% → 0%.
    - Now: islandMinLocked 15% when no open land touches me.
    - The coast list was the first 200 tiles in scan order (north-biased); it's now reservoir-sampled.
    - Open-coast targets are collected in the scan (every 5th tile).
    - Boats skip spots within 30 tiles of a target from the last 60 s.
  - The counter war vs Andtesd108 drained troops 700K → 16K while land went +50%. keepHome was a % of current troops (shrinks to 0); added a keepCap 10% floor.
  - Camera: patched the `Camera2D.clamp`/`settle` module table (the client calls it through the table). Margin is camMargin × viewport on every side, with no spring-back. `Config.MIN/MAX_ZOOM` ×/÷ camZoom (0.35–12 → 0.175–24). Restored on unload.
- **v1.9 (2026-09-29): every pass checked + used**
  - Passes (Products.lua, id / Money price):
    - MEGANUKE 1989902339 / 10K
    - SCATTERSHOT 1999838282 / 20K
    - BARRACKS 1990256322 / 20K
    - ARTILLERY 1987550354 / 25K
    - AIRSTRIKE 1988684354 / 100K
    - RAILGUN 1998602304 / 250K
    - FAST_RELOAD 1998782486 (Robux only)
    - VIP 1983032307 (+10% growth)
    - HOST 1969592603, ADVANCED 1969906389 (private rooms)
    - PERSISTENT_LOBBY (id 0)
  - Ownership: the `ConquestPass_<KEY>` attribute (set for money passes), else `MarketplaceService:UserOwnsGamePassAsync` once at load.
  - Products granting free items: STARTER_PACK (post), STARTER_PACK2 (3 posts, city, anti-nuke), RAILGUN_BUNDLE (3 nukes, railgun, post). They show in `fronts.freeNukes`/`freeCities`/`freePosts`/`freeSams`. `useFree` fires free nukes even with auto nuke off.
  - "Best owned" nuke type (Scattershot > Mega > Atom, owned and affordable) is the default for auto, revenge and last stand.
  - Airstrike (radius 15) and railgun (radius 5, no range limit) targets are now scored by value inside the hit radius:
    - anti-nuke 40, railgun 30, airfield 25, artillery 15, defense 8, port 6, city 10×level;
    - ×2 for players attacking me or on my grudge list.
    - Before this, the target was the nearest building.
  - Passes tab: owned list, what each one unlocks, a manual "buy with Money" button (lobby only), free items, Money 2x.
  - Private-room payout is server-side and unknown, so HOST/ADVANCED are detected only.
- **v2.0 (2026-09-29): boat invasions across water**
  - The scan collects each enemy's coast tiles (every 5th tile, reservoir of 40 per owner).
  - Targets: owners NOT land-adjacent with a coast within islandMaxDist of my coast, where boat (troops/5) ≥ their army × boatEdge (1.1). A boat fights the whole army.
  - Score: troops per tile (×0.3 grudge, ×0.7 bot) + sea distance × 0.5. Lowest wins; it lands on their coast tile nearest my coast.
  - A `nobeach`/`nosearoute`/`nocoast`/`immunity`/`ally` denial right after the send → that owner is skipped 90 s. `toomanytransportboats`/`busy` → wait 20 s. Shares the 3-boat cap with island expand.
  - Live: 3 invasions in ~45 s (THEmonkey's leftover islands ×2, Canada 292K vs a 992K boat), 0 denials.
- **v2.1 (2026-09-29): city weighting + struct sync + troop units**
  - **Troops are stored ×10.** `players.troops`, `fronts.inc[].troops` and the cap formula are all ×10. The HUD shows `Numbers.formatTroops(n) = format(n/10)`. Comparisons are unit-consistent, so only displays were wrong (the user caught 11.09M vs HUD 1.11M). `fmtT` = fmt(n/10). Earlier notes quoting raw troop counts (e.g. THEmonkey 3.21M) are ×10.
  - Structure sync: the client's structures renderer holds every building in `.byTile[tile] = {ownerId, kind, level, site, ...}`, found as a State-handler upvalue with a `byTile` field. It is mirrored into S.structs every scan. After a mid-match reload the listener only knew 1 of my 20 cities; after the fix it saw 20 cities, levels 46 = fronts.levels.
  - City weighting by army fill (growth ∝ 1 - troops/cap):
    - fill ≥ cityFillHigh (55%): cities first, and auto nuke holds unless gold covers nuke + city.
    - fill ≤ cityFillLow (25%): cities only when gold ≥ citySpare 2× cost.
    - Seen live: auto nuke fired 5 Atoms in 3 min while cities starved; after the fix, "auto nuke on hold: cities first (troops at 87% of cap)".
    - The hold check must not use wantBuild (its 3 s build timer let a nuke slip through).
- **v2.2 (2026-09-29): sea siege (the 1v1 vs an island rival)**
  - Situation: me 86% of land vs local_afghani 15% on islands. No land border, and one boat (troops/5) < their whole army, so every attack rule stayed idle.
  - Game rules used:
    - Max 3 transport boats at sea, each troops/5 of what's left → 3 at once = 1 - 0.8³ = 49% of my army.
    - My attacks on the same player MERGE on landing (Sim launchAttack adds to the existing attack).
    - A nuke kills their troops per tile hit, including troops in their attacks.
  - Stages:
    - charge: hold other attacks until fill ≥ siegeFill 90%, or salvo ≥ 1.3× their army, and ≥ siegeGap 25 s since the last salvo;
    - optional siege nuke on their best spot;
    - salvo of 3 boats 0.35 s apart at ONE coast tile;
    - reinforce: a boat every 4 s while fill ≥ 30%;
    - push: once a land border exists, a land attack every 4 s above the keep-home floor.
    - Beachhead lost → back to charge. Refused landing (boatBad) → new tile.
  - Live: salvos of ~260-500K troops took their army from 358K to 154K in ~2 min; I won at 89%+ with bar 0.9 (`phase.threshold` is a FRACTION).
  - Flaw fixed after the win: v2.2a ended the siege on first land contact and handed off to normal combat, which never attacks an army that size. Beachheads died within 10 s and it re-salvoed immediately (4 waves in 80 s). The push stage and siegeGap fix that; the push stage is not tested live yet.
  - Info tab shows the win bar vs my land %.
- **v2.3 (2026-09-29): underdog mode**
  - Trigger: the biggest non-allied rival holds ≥ udRatio 1.5× my land.
  - Diplomacy:
    - `{t="target", id}` every 16 s (lasts 100 ticks, cooldown 150; Alliances.lua).
    - `{t="embargo", id, stop=false}` once.
    - Ally requests to every other human.
  - Opening strike: `players.troops` is HOME troops. When the leader's home army drops under 60% of its 60 s peak, hit their border with up to 50% of my army, keeping the keep-home floor. The strike must be ≥ their army × udEdge 1.0.
  - Nukes go at the leader, even when they're stronger. Within udDanger 8% of the win bar, fire every 12 s ("deny win"): nukes turn their tiles back into open land and knock them under the bar.
  - Defense posts on the leader's border before they attack.
  - Live 23:57: embargo + ally asks sent. Opening strike fired: "PORT's army is out (63.7K, peak 107.7K) -> hitting home with 72.5K".
  - Name bug: the mid-inject name table was "the biggest number->string upvalue". That is sometimes the building-label table ("PORT", "ANTI-NUKE", "FACTORY"). It now picks the table containing my own Name/DisplayName.
- **v2.4 (2026-09-30): rivers, bot sieges, window size**
  - `TRANSPORT_BOAT_SPEED = 1` tile per tick (~10 tiles/s): a 10-tile river is ~1 s, a 200-tile sea ~20 s.
  - Across a river (crossing ≤ riverDist 15):
    - The next boat lands before the last landing bleeds out and MERGES into it, so the needed edge is boatEdge × riverEdge 0.6.
    - Boats chain every riverEvery 4 s (vs 20 s on open sea).
    - Siege only takes a river target if even chained boats can't win.
  - `crossing()`: exact nearest pair between their coast sample (≤ 40) and my coast sample (≤ 300). It used to be 8 random tries per tile, which could miss a narrow river.
  - Why exodus wasn't dominated (bot, 13.7K tiles, 50K troops vs my 241K, no land border):
    - Siege excluded bots, and only triggered when one boat couldn't win at all.
    - It trickled single ~1× boats every 20 s.
    - Now siegeBots = on, and it sieges when 1 boat < siegeTrigger 2× their army.
  - Mid-inject names: the client id->name table is the number->string upvalue containing my Name/DisplayName.
  - All 10 Obsidian scripts now open at `Size = UDim2.fromOffset(704, 824)` (the user's pick).
