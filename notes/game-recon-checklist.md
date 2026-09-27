<title>Game Recon Checklist</title>

# Game Recon Checklist — before building any auto farm

Written after Build A Battle Bot (2026-09-26). The first farm shipped with gaps the player found in minutes:

- It never re-bought Energy Stations after a rebirth.
- It botched auto-joining Pit events.
- It skipped whole upgrade systems (workshop, skills, scrapper) and dismissed the scrap farm.
- It reimplemented selling without checking that the game already has AUTO SELL.
- It treated "workshop first" as "when affordable", not "save for it".
- It caught zero alien crates by touching them instead of staying for the capture timer.

Each item below is a miss that actually happened. Run the whole list before writing the farm, not after the player reports it.

---

## 1. Map the entire progression, not just the money faucet

Finding where money comes from is step one, not the analysis. Before writing code, produce four lists from the decompile, then confirm each one live.

| List | What to find | Where it hides |
|---|---|---|
| **Currencies** | money, second currencies (skill points, scrap, tokens, gems), crates/parts, timed boosts, guild/clan chests | leaderstats, **player attributes**, `"sync"` payloads, HUD labels |
| **Sinks** | every purchase and upgrade: plot objects, levels, slots, skills, skips, rebirth | signs/billboards in `PlayerGui`, SurfaceGuis in workspace, every remote with a cost |
| **Farms** | everything that produces value, per actor: **the bot/pet/unit**, **the character**, and **timers** (deliveries, offline, playtime) | modes, pickup folders (`workspace.Materials`), events, delivery timers |
| **Gates** | what's locked behind rebirths, waves, levels or passes | `grep -i "rebirth\|requiredWave\|needRebirths\|locked\|unlock\|REQUIRE"` in the configs, `"LOCKED"` / `"REACH REBIRTH"` UI strings |
| **Built-in automation** | what the game already automates: free settings (e.g. AUTO SELL by rarity) and pass-gated perks (AUTO REBIRTH, AUTO CLAIM) | `grep '"[^"]*AUTO'` in client strings, every `setSetting` key, every `Perk_*` attribute, the shop's pass list |

- **Use the game's own automation before writing your own.** Put its switches in the menu:
  - The **server is the source of truth**: mirror its state into the menu (`"sync"` payloads).
  - **Never write on load or autoload.** Write back only what the player changes.
  - **Exclude those options from SaveManager** (`SetIgnoreIndexes`), or a saved copy fights the server.
  - For a pass the player doesn't own, show a note that the farm's own version covers it.

- Farms that run **in parallel** stack. A character farm (scrap) worth ~1 % of the main faucet still matters when the bot is farming at the same time, and it usually feeds quests too. Don't dismiss a farm on per-action value alone.
- Every upgrade system gets its own automation, not just the obvious one. In this game that meant station pads, workshop level (pad count), fabricator level, scrapper level and the skill tree.

## 2. Run a full reset (rebirth / prestige) during recon

- Snapshot the plot and progression state, rebirth once, snapshot again, and diff the two. **Don't trust the reset panel's text.** It said "RESETS: MONEY · BOT LEVELS · BEST WAVE", but the stations were wiped and the workshop and scrapper both dropped back to LV.1 as well.
- Capture the **fresh state of every purchasable**: BUY vs UPGRADE vs MAX. The first farm only ever saw mid-game "UPGRADE" billboards, so it never learned the `ENERGY STATION · BUY · 400` form and couldn't rebuild after a rebirth. MAX is its own layout too: the price label is hidden but keeps its old text (E5).
- The farm must be able to rebuild from zero unattended (buy pads, then workshop levels, then upgrades) and resume.

## 3. Verify every state machine from the server's side

- Run a namecall spy that tags each call as **GAME vs ME** (`checkcaller()`). The player's own clicks will show up in your traces. The first "toArena works from the Depths" conclusion was really the player clicking `depthsStop` and then `toArena`, while mine was silently ignored.
- Log every transition message the server sends. Look for:
  - **Resting states**: `toPlot` was never followed by `plot`.
  - **Commands ignored in some states**: `toArena` from the Depths.
  - **Server-initiated transitions**: a rebirth sends `toPlot` on its own.
- Test each loop through one **full cycle**, end to end:
  - Depths: start, defeat, stop, restart.
  - Events: start, join, leave, rewards arrive.
  - Rebirth: rebirth, rebuild, resume.
- **Learn the full completion condition of timed or capture mechanics.** Touching an alien crate for 1.5 s and leaving caught 0. The crate needs the character to stay with it in the arena for the whole capture timer. Judge success by the **actual delivery signal** (the inventory count rising), not by "the thing disappeared".
- **Capture mechanics usually have three parts: *acquire*, *hold*, *survive*.** Each needs its own input:
  - **Acquire** needs a real touch (`firetouchinterest` on the object's part). Standing near it lost the crate to a player who walked into it.
  - **Hold** means staying in the zone until a countdown ends. Read the countdown from the object's BillboardGui.
  - **Survive** means not getting hit, because a hit drops what you carry. Read ownership from how the server marks it, here a `WeldConstraint` from the object to the carrier's `HumanoidRootPart`.
  - **Find out what the event's end does to a hold in progress.** BBB's raid end delivered a crate held for only 26 s of its 60, so the last crate is always worth grabbing, and a raid fits one more catch than full holds alone suggest (4, not 3).
- **In hostile or contested zones, list every threat and its telegraph before building the hold loop:**
  - **Environmental attacks:** find their warning visuals (here, flat 12-stud discs spawned about 0.9 s before a 6-stud hit) and scan them at ≥10 Hz.
  - **Other players' units and event NPCs:** they attack characters, so keep distance.
  - **Dodge:** move to the point farthest from all threats (sample several candidates) the moment one is in range. Hops smaller than the hit radius don't dodge anything.
- **Watch for confounded signals.** The same resource can arrive from several sources: Alien crates came from raids and from event rewards, so a raid-catch counter reported a catch with no raid running. Only count a change inside the window where your action could have caused it.

## 4. Inputs: test the gate, not just the happy path

- For each action, measure **far vs near**: remote from 30+ studs, remote next to the target, and the prompt. Record which one the server accepts.
- **Client-side gates**: here the game disables a prompt unless the camera faces the sign. `fireproximityprompt` failed intermittently because of it. Prefer the game's own remote fallback, which here was `PlotSignRemote`, the billboard-click path.
- Measure whether teleports are safe for **carried items** (this game: yes; Needle in a Haystack: no).
- **Check gates you can read before attempting.** If config exposes the requirement (e.g. `scrapperWaveRequirement(level)`, `GARAGE_REBIRTHS`), compare it locally first. Failure backoff alone still cost a teleport and a log line every 1–2 minutes, and a rebirth that recreates the sign resets any backoff keyed on that instance.
- **Never key backoffs (or any state you need to keep) by Instance in a weak table.** Roblox drops an Instance's Lua wrapper once no script holds it, even while the part still exists, and a weak-keyed entry goes with it. The farm's `setmetatable({}, {__mode = "k"})` backoff made a 2-minute retry fire after 16 s. Use a plain table (prune it if it can grow), or key by a stable string.
- **A failure that repeats on schedule is a bug report, not bad luck.** "Scrapper didn't take" every 2 min turned out to be a maxed sign (E5); the backoff only hid it.
- **Success checks must survive a label redraw.** A blank or missing reading is "unknown", not "changed". A `nil ~= 2` comparison logged a phantom `workshop LV.2 -> LV.2`. Pair the label with a second signal, such as money dropping by about the cost.

## 4b. Priority settings mean *saving up*, not "prefer when affordable"

- "X first" must block cheaper spends until X is bought. Otherwise the cheap purchases drain the money and X keeps slipping.
- The first "Workshop first" bought station levels while the workshop was unaffordable and delayed it. The fix was a strict rebuild order: empty pads, then the next workshop level (saving for it), then station levels only once the workshop is maxed.
- Per-unit scores (coins per fuel/s) undervalue unlocks, because a new slot opens a run of cheap follow-ups. Treat unlocks as gates, not as one more scored item.

## 5. Co-existing with a player who's playing

- Assume the player plays while the farm runs. Detect manual commands (a transition you didn't cause) and **pause** instead of fighting them.
- Don't count server-initiated transitions (rebirth, KO) as manual. Doing so paused the farm for 90 s after every rebirth, and it missed events.
- Never spend, reset, or re-equip the player's build during testing without saying so first.
- The player will change settings and re-save the autoload config (here: Auto Equip on, "Stay whole event"). **Read their config before testing and don't overwrite it.**
- Farm loops start before the UI's autoload applies. Every default must be safe (all automation off), or the first seconds run on defaults.
- **A rejoin changes the server, so plot index, PID, and even which plot you own all change.** Resolve them every session; never hardcode them.
- **"The player is using a panel" pauses need a timeout.** The game opens panels by itself too (an update log after an update), and nobody closes them on an unattended client. The farm now ignores an `OpenPanel` older than 90 s (§8.6 *popups*).

## 5b. Tooling: the executor can fail, so make the farm verifiable without it

- **Potassium's execute bridge can jam silently.** Every call still says "dispatched" but nothing runs, even a one-line `writefile` ping. Here it survived a re-attach and needed a **rejoin + attach**, which gave a new PID.
  - Detect it with a **timestamped ping file**.
  - Use **unique result filenames per run**. Deleting the result file after dispatching lost a result to a race.
- **Vendor UI libraries into the workspace** (`readfile`, with `HttpGet` only as fallback). A hung GitHub fetch at load stalls the reload, and the whole script queue with it.
- **Have the farm report itself:** a log file plus a **heartbeat status line every 60 s**, and one-time dry-run previews (e.g. "junk by current rules: 33 parts"). Then every test can be read from the log alone, with no bridge needed.
- Queued scripts `readfile()` at execution time, so redeploying the file before a jammed queue drains is safe.

## 6. Build the UI categorized from the first version

- One tab per system (Bot / Crates & Parts / Upgrades / Rewards / character farms / Status / Settings).
- **Every auto feature gets its settings**: thresholds, filters (which events, which crates, which slots), priorities (skill focus), caps and reserves, and pause timers.
- A Status tab with live counters plus a log. Also write the log to a workspace file, because Potassium's `read_console` returns nothing.
- SaveManager with an autoload config, so reloads keep the player's toggles. Keep option ids stable across versions, or say which ones changed.

## 7. Before calling it done

- [ ] All four lists (currencies, sinks, farms, gates) are written into the game's spec.
- [ ] Rebirth diffed, and rebuild from zero verified live.
- [ ] Every event type joined at least once, with rewards received.
- [ ] Every upgrade path hit at least once, **from its fresh/BUY state**.
- [ ] Manual-override pause verified, and rebirth/KO transitions don't trigger it.
- [ ] Every feature has its settings; config saved as autoload.
- [ ] The game's built-in auto features are found and mirrored in the menu, and nothing gets written on load.
- [ ] Priority settings verified to save up (e.g. the workshop reaches max before any station level).
- [ ] Timed/capture mechanics verified by the real delivery signal.
- [ ] Heartbeat and preview lines in the log file, so the farm can be verified without the bridge.
- [ ] For every §8 system the game has, its "Done when" list is ticked.

---

## 8. If the game has … — decision trees by system

The trees below were researched separately per system family, then merged here. Walk every family that applies to the game.

| § | Family | Ids |
|---|---|---|
| 8.1 | Economy & progression: currencies, multipliers, cost curves, gates, rebirth, offline, boosts, passes, spend priority | E1–E15 |
| 8.2 | Collection, gacha & inventory: item data, opens, odds, luck, equip, conversions, caps, auto-delete | — |
| 8.3 | Combat, PvE & PvP: hit paths, validation matrix, credit, bosses, dungeons, waves, capture zones, units | C1–C14 |
| 8.4 | World & interaction: the input ladder, movement, streaming, plots, tycoons, nodes, pickups, NPCs, minigames | — |
| 8.5 | Server, anti-cheat & infrastructure: validation, honeypots, kicks, rejoin, hops, saves, staff, watchdogs | S1–S20 |
| 8.6 | Time-based, social & meta: quests, playtime, dailies, events, codes, groups, guilds, trading, popups | — |

Each entry runs **Detect → Automate → Watch out → Verify**. Indented **→** lines are the rabbit holes. *BBB:* notes are what Build A Battle Bot actually did; other games are named in full or as SRS / Sneaker (Sneaker Resell Simulator), NIH / Needle (Needle in a Haystack), MoD (Mog or Die), FIU (Fix It Up!).

### 8.1 Economy & progression

Run this after §1. Do E1 first: once the configs and the replicated save data are found, most checks below become reads instead of HUD scraping. Sneaker = Sneaker Resell Simulator, Needle = Needle in a Haystack. Data persistence across rejoins is in §8.5 (S15).

#### E1 · Always: find where the rules and the state live
- **Rules:** decompile every `ReplicatedStorage` ModuleScript into the workspace, then run `grep -liE 'cost|price|coins|money|percent|mult|reward|boost|rebirth'`.
  - On BBB this cut 61 modules to 27. It kept every config the spec uses (`WorkshopConfig`, `RebirthConfig`, `BoostConfig`, `OfflineConfig`, `SkillConfig`, `ShopConfig`, `RewardConfig`, `EconomyConfig`) plus `NumberFormat`.
  - `require` the modules live instead of retyping their formulas.
  - `;dex` browses modules, values and attributes in place.
  - Press each buy button once under `;remotespy` to map sink → remote → args.
- **State:** use the first of these that exists:
  - `ReplicatedStorage.ReplicaRemoteEvents` (ReplicaService: `Replica_ReplicaSetValue`, …).
  - Knit's `…knit.Services.<Name>Service.RP` (replicated properties).
  - A `Player.PlayerData` folder (Fix It Up: `PlayerData.Status.Money`).
  - A `"sync"` push that carries a whole table (BBB `RewardRemote "sync"`, which ends with `loaded=true`).
  - None of these: search `getgc(true)` for a table that holds both the money key and `Rebirths`.
- **Automate:** read numbers from the state, never from HUD labels. Labels are rounded (E3), partial (E4) and late.
  - If you attached after the last push, the HUD script still caches it: `getconnections(Remote.OnClientEvent)[i].Function` → `debug.getupvalues`.
  - `writefile` a `JSONEncode` dump before and after every rebirth and every hop, then diff the dumps locally.
- **Verify:** buy one cheap level. The state field and the money should move by exactly the config's numbers.
- ↳ **and if nothing replicates** → rebuild the state from server-written billboards plus money deltas. Tie each number to its config formula, so a missed redraw can be recomputed.

#### E2 · If the game has more than one currency
- **Detect:** besides §1's places, check the `currency`/`kind` field on every shop and cost entry, and the HUD's icon names. For each currency, record: faucet → sink → survives a reset? → sold for Robux?
- **Automate:** keep one spend queue per currency. Spend a currency with a single sink (BBB skill points) as soon as it arrives, unless the farm is saving for a named pick.
- **Watch:** a currency with no visible sink is usually gated (E7) or spent in a panel you haven't opened. Find its sink before calling it useless.
- ↳ **and if it's also sold for Robux** (gems, diamonds) → farm the free trickle (daily, quests, codes, rebirth rewards), but **never auto-spend it by default**. Allow-list its sinks in settings.
- ↳ **and if it's an event currency** → find when the event ends (`"EVENT ENDS IN"`, a config `endsAt`) and whether leftovers convert or vanish. Spend it down before then.
- **Verify:** log every currency delta with its cause. A delta the farm didn't cause means an unmapped faucet or sink.

#### E3 · If numbers get big or labels are abbreviated
- **Detect** the storage type:
  - `IntValue` caps at 2^63 ≈ 9.22e18.
  - `NumberValue` is a double, exact only up to 2^53 ≈ 9.0e15.
  - A `StringValue` or a `{mantissa, exponent}` table means a big-number module (InfiniteMath, EternityNum).
- **Automate:** compare values with the game's own module (`require` it), and take suffixes from its formatter (BBB `NumberFormat`: `K M B T Qa Qi Sx…`; other games use `Qd Qn`). Never `tonumber("1.5Qa")`.
- **Watch:** labels are rounded to one decimal. `924.4K` is 924,446, but `1.2M` is 1,155,557: off by 44K, and the error grows with the suffix. A `money >= label` check either waits too long or fires buys the server denies (then a backoff). Take exact costs from the config; use the label only to learn *whether* a price exists (BUY / UPGRADE / hidden at MAX, E5). Treat a deny as "re-read", not "retry".
  - *BBB farm:* every sign is priced from `WorkshopConfig` (`stationUpgradeCost(lv+1)`, `upgradeCost(lv+1)`, `scrapperUpgradeCost(lv+1)`); the argument is the level being bought.
- **Verify:** on one purchase, the formula's cost equals the money drop.

#### E4 · If income has multipliers
- **Detect** every source:
  - Sync rows: BBB `BoostRemote "sync"` sends `{source, kind, percent, remaining}`; `remaining = -1` means permanent.
  - Player attributes (`FriendsOnServer`, `Perk_Vip`) and server-wide `workspace` attributes (BBB `AdminCoinsMult`/`AdminCoinsEndsAt`, `AdminEnergyMult`, `AdminLuckMult`).
  - Config constants (`RebirthConfig.MONEY_PERCENT = 100`) and skill fields (`*Percent` vs `*Mult`). BBB's `moneyPercent` lands in the pool as `source="Skills"`.
  - `MembershipType` checks (a Premium bonus) and pass blurbs (`"+10% MONEY AND ENERGY"`).
- **Automate:** model `pay = base × (1 + Σ pool %) × Π factors`. Fit it to one number the server computed with your multiplier inside.
  - BBB worked example: `DepthsSkipCost` at wave 27 was 236,394, which is ½ × 41,400 base × **11.42**.
  - The sync listed .20 group + .20 friends + .16 guild + 4.00 rebirth + .15 skills, a pool of 5.71. Times the 2× timed quest boost, that's **11.42**.
  - An all-additive model predicts 6.71; an all-multiplicative one, 19.2.
- **Watch:**
  - In an additive pool, every new % is worth less. At BBB rebirth 4, one more rebirth (+100 %) is ×1.18 and a +20 % perk is ×1.035. A "2X" pass that lands in the pool is nowhere near ×2. A timed boost outside the pool keeps its full value.
  - HUD totals leave sources out: BBB's PERMANENT row skips Rebirth, Friends and Guild.
  - Some faucets get no multiplier at all: BBB part sales pay a flat `{150 … 40000}`.
- **Verify:** let one source change (a boost expires, a friend leaves) and check that pay moves by the predicted ratio.
- ↳ **and if there are free permanent sources** (group, like/favorite/community, codes, guild) → their claim flags are in the sync (BBB `group={claimed, inGroup}`, `Social2_like`). The farm claims them and lists unclaimed ones in Status. Joining the group or adding friends is the player's call (§8.6).

#### E5 · If upgrades have levels and cost curves
- **Detect:**
  - Config fields: `BASE_COST`, `COST_MULT`, `*_PIVOT`, `*_STEP_EARLY/LATE`, `*_LATE_FROM`, `MAX_LEVEL`.
  - Breakpoint arrays (`STATION_SKIN_LEVELS`) and hardcoded cost arrays (Sneaker PC slots `{500, 3000, …}`).
  - `LV.n` / `MAX LEVEL` billboards.
- **Automate:** call the config's own functions (`stationUpgradeCost`, `stationRate`). Rank by cost per unit of output, **looking ahead past step changes**.
  - BBB stations add +1/s per level up to LV30, then +5/s per level.
  - On its own, 29→30 costs 155K for +1/s. But 29→31 costs 349K for +6/s (58K per /s), which beats 25→26 (63.5K per /s).
- **Watch:**
  - Cost pivots reorder late picks (BBB: ×1.25 per level, then ×1.18 past LV40).
  - Cosmetic tiers can look functional, so grep what reads them (BBB `stationSkinTier` is read only by `StationModel`).
  - Output beyond what the consumer drains is wasted. BBB stations buffer 120 s of fuel, and the bot drains them only at the plot.
  - **The MAX state is its own sign layout.** BBB's scrapper at LV.18 read `SCRAPPER MAX` (no `LV.n`), and its `CostLabel` went `Visible = false` but **kept the last price** (656.8K). The farm read the hidden text, found no level to gate on, and retried a maxed sign every 2 min. Read labels only when `Visible`, and check every `MAX_LEVEL` in the config against the sign once.
- **Verify:** after each buy, the rate label and money move by the formula's Δ (LV25→26: `29/s` → `30/s`, −63,527).
- ↳ **and if it's a skill tree** → map the `requires` chains, the cost × tier and the points per reset (BBB `2 + floor((r-1)/8)`). Look for a respec: BBB's `SkillRemote "reset"` is free but has a 2 h `RESET_COOLDOWN`, so hold one allocation and respec only when the strategy changes.
- ↳ **and if it's a button tycoon** (Zednov kit: `Buttons.<btn>` with `Price`, `Object`, `Dependency`, `Gamepass`, `DevProduct`) → `Dependency` is the tree (inputs in §8.4 *Tycoon*).
  - Buttons appear only once their dependency is bought, so rescan after every buy.
  - Never touch a button with `Gamepass` or `DevProduct`: it opens a Robux prompt.

#### E6 · If income sits in a pile until it's collected
- **Detect:**
  - Zednov `CurrencyToCollect` + `Essentials.Giver` (touching the Giver pays out).
  - The BBB fabricator pile (`CrateRemote "garage"`: `pending`, `capacity`) and buffers (`3.0K/3.5K`).
  - `*ToCollect`/`Pending`/`Stored` values and `COLLECT`/`CLAIM` prompts.
- **Automate:** collect more often than capacity ÷ fill rate, with the cheapest input the server accepts. BBB `CrateRemote "claim"` works from anywhere. A Giver takes `firetouchinterest`, or a teleport onto it if touches are range-checked.
- **Watch:** a full pile stops production without any error (BBB's pile stops at storage).
- ↳ **and if multipliers apply at collection rather than production** → hold the pile for a 2× window when the cap allows. Test it by collecting equal piles with and without a boost.
- **Verify:** the heartbeat log never shows a full pile.

#### E7 · If things unlock behind gates
- **Detect:**
  - Gate tables and functions: BBB `GARAGE_REBIRTHS = {0,0,2,4,7,11,16,22,30,40}`, `requiredWave(r)`, `scrapperWaveRequirement(lvl) = (lvl-1)·2`.
  - Sync fields: `locked`, `needRebirths`, `maxed`.
  - Strings: `"REACH WAVE"`, `"LOCKED"`, `"REQUIRES"`, `"SOON"`.
- **Automate:** re-rank spending when the gate stat changes (`GetAttributeChangedSignal("Rebirths")`) instead of polling. The newly opened item goes first (§4b).
- **Watch:** which stat does the gate read?
  - Lifetime stats (`Rebirths`) never re-close.
  - Best or current stats that a reset wipes re-close their gates on every rebirth, and the rebuild must push the stat again before it can re-buy. *BBB:* the scrapper gate reads `BestDepthWave`, and a rebirth wipes both the stat and the scrapper.
  - A gate check needs a level to compare. When the level can't be read (MAX layout, E5), don't treat it as "no gate".
  - `"COMING SOON"` / `"ASCENSION SOON"`: record it, skip it, and re-check after updates (`UpdateLogConfig`).
- **Verify:** fire the gated action once below the gate and once at it, and log the reply (`skipDenied`, `"full"`, or no change). A deny means re-read the gate; never retry in a loop.

#### E8 · If there's a rebirth or prestige (§2 covers the diff)
- **Detect:**
  - `RebirthConfig` (BBB `MONEY_PERCENT`, `ENERGY_PERCENT`, `requiredWave`, `REBIRTH_CAP = 100`).
  - `RebirthRemote` `"rebirth"`/`"auto"`/`"sync"` and attr `Rebirths`.
  - Strings: `"KEEPS:"`, `"RESETS:"`, `"YOU CAN REBIRTH!"`, `"ASCENSION"`.
- **When to rebirth depends on the reward:**
  - **Fixed reward + a gate** (BBB: +100 % money and `2 + floor((r-1)/8)` skill points once best wave ≥ `requiredWave(r)`) → rebirth as soon as you're eligible. Extra run time only pays if what it earns survives the reset.
  - **Reward that grows with the run** (a `"+N"` / `"YOU WILL GET"` preview) → track `pending ÷ minutes into the run`, and rebirth once it drops below its peak.
  - **Money cost with batch buttons** (x1/x5/x25…, bought with gems in clicker sims) → press the largest one you can afford. Bigger buttons are worth saving gems for.
- **Before firing:** put money into sinks that survive the reset (BBB: fabricator levels survive, stations don't), claim the piles, and run the claim sweep (§8.6: scaled quest goals move with rebirths). Money spent on wiped sinks in the last minutes is lost (E12).
- **After firing, in order:**
  1. Spend the new prestige currency first. BBB skill points on `moneyPercent` nodes speed up the rebuild.
  2. Rebuild from zero (§2) in dependency order (§4b).
  3. Re-push any wiped gate stat before re-buying what it gates (E7).
- **Watch:** the diff must cover boosts, quest progress, session bars and gate stats, not just the plot. Run `;savegame` before and after for two copies to diff in Studio.
- **Verify:** after the rebuild, pay per unit ≈ old pay × (pool + reward) ÷ pool (E4).
- ↳ **and if there's a layer above** (ascension, super rebirth, a `REBIRTH_CAP`) → auto-rebirth stops at the cap. Never auto-fire the higher layer; weigh its reward against the pool it wipes.

#### E9 · If there are offline or idle earnings
- **Detect:**
  - An `OfflineConfig`. BBB: `MIN_MINUTES = 10`, `MAX_HOURS = 24`, `COINS_PER_HOUR = 600`, and offline crates at `TIME_MULT = 0.25` up to `CAPACITY_FRACTION = 0.5` of storage.
  - `OfflineRemote "request"` → `"seen", id`.
  - Strings: `"YOU WERE AWAY"`, `"OFFLINE"`.
- **Automate:** acknowledge the popup on join, then claim whatever filled while you were away.
- **Watch:**
  - Compare rates before planning around offline. BBB pays 600 coins/h base offline, against ~26–31K per Depths wave online, so offline earnings are noise.
  - A rejoin inside `MIN_MINUTES` pays nothing, and nothing accrues past `MAX_HOURS`.
  - Session-based progress restarts on every rejoin (BBB luck bar `luckSeconds`, playtime `elapsed`), so each hop costs something (S14).
  - Roblox disconnects after 20 idle minutes. IY `;antiafk` (or the farm's own anti-AFK) keeps you earning at the online rate (S13).
- ↳ **and if there's an AFK zone** that pays per minute (`"AFK"` strings, a zone part) → it usually pays a small trickle of tokens. Park the character there only when it has no parallel farm (§1).
- **Verify:** rejoin once below `MIN_MINUTES` (expect nothing) and once above (expect the config's `rewardFor`).

#### E10 · If there are timed boosts
- **Detect:**
  - Boost rows in a sync (BBB `BoostRemote "sync"`: `remaining` in seconds, `-1` = permanent).
  - `*EndsAt`/`*Expires` attributes, potions in the inventory, and server-wide `workspace` attributes (E4).
  - Strings: `"2X"`, `"BOOST"`, `"POTION"`.
- **Automate:**
  - Separate boosts that start on their own (BBB: event, quest, daily and playtime rewards) from stored ones.
  - Use a stored boost only when its currency is the bottleneck **and** the loop that earns it is running. Not during a rebuild, travel or a defeat window.
  - A boost that pays in one mode only is wasted in the other: BBB 2× Money is mostly wasted on a bot parked at the plot, 2× Energy on a bot in the Depths (XP accrues only at the plot). Schedule the mode around the boost.
  - While a server-wide multiplier is active, run its loop flat out.
- **Test stacking once:** grant a boost of a kind that's already running, then diff the row.
  - → **it extends `remaining`** → claim immediately. BBB **time-stacks**: Elite's "2× money 3 m + 5 m" added +180 s and +300 s to the running 2× row, never ×3 or ×4.
  - → **it overwrites, or the stronger one wins** → using one while another runs wastes the overlap, so queue stored boosts.
  - → **it adds `percent`** → bank them and fire them together in the best farm window.
  - → **boosts can be paused** (a `"PAUSE"` toggle) → pause them during rebuilds, travel and defeat windows.
- **Watch the timer:**
  - Does `remaining` tick only while you're online, or is it an `endsAt` wall clock that burns offline? Note `remaining`, leave for 5 min, rejoin.
  - Buy duration upgrades before spending stockpiled boosts (BBB "BOOST TIME" +15 %/node).
- **Verify:** `remaining`/`percent` in the next sync, and pay during the boost vs after it matches E4's model.

#### E11 · If there are gamepasses
- **Detect:**
  - The shop config (`kind = "Pass"`, `key`, price, blurb).
  - Server-set ownership attributes (BBB `Perk_AutoRebirth`, `Perk_Vip`; Needle `Pass_pocket`).
  - `UserOwnsGamePassAsync` calls in client scripts.
- **Automate:** sort each pass:
  - **Automation perk** → free equivalent: fire the same remote yourself (BBB Auto Rebirth → `RebirthRemote "rebirth"`; Auto Claim → `CrateRemote "claim"`).
  - **Mechanic perk** → sometimes recreatable with legal movement (Needle Sell On Drop → a stepped walk to the vent).
  - **Stat perk** (2× money, +slots, Lucky Start) → no free equivalent. If it's owned, feed it into E4's model.
- **Watch:**
  - Trust the attribute, not the shop card. Needle showed `OWNED` for a pass the account didn't own.
  - Setting `Perk_*` or `Pass_*` locally doesn't replicate. It only fools the client and your own farm.
  - Remove every Robux path from the sink list: `DevProduct`/`Gamepass` buttons, `PromptProductPurchase`, BBB `ShopRemote "devBuy"`.
- **Verify:** each free equivalent produces the server signal the perk would. In BBB, your `claim` empties `pending` just as `"autoClaimed"` does.

#### E12 · Spending priority (beyond §4b's saving up)
- **Detect:** each sink's cost function (E5) and its *realised* Δincome after multipliers (E4), consumer caps (E5) and drains (E14). The game's own "better" hints are a free cross-check (BBB `hasBetterPart`, behind the garage `!` badge).
- **Automate:** rank by payback = cost ÷ Δincome per second, or by cost per unit of whatever is the bottleneck (XP, crates). Skip any **reset-wiped** buy whose payback runs past the next rebirth. A 1.7M BBB station level bought 60 s before a rebirth is simply lost.
- ↳ **and if a scheduled sink is coming** (a rotation, an event shop, a gate opening within minutes) → hold a reserve for it. Sneaker's limited shop sells a known shoe at a known UTC hour and price.
- **Verify:** the log prints each pick, its price and the predicted Δ, and income over the next minutes matches.

#### E13 · If a sink looks useless
Check these before skipping one:
- **Caps and slots often beat rates.**
  - BBB's workshop sets the pad count (2→6), and a full inventory stops crate opening (`CrateRemote "full"`).
  - Sneaker PC slots 4→16 cut the wait per Legendary from ~25 s to ~7 s.
- **Quest counters count actions, not value.**
  - BBB `d_stations` ("UPGRADE ENERGY STATIONS 10 TIMES" → 30 min of 2× money) costs 4,920 right after a rebirth (two pads, LV1→6).
  - Do action-count quests when the action is cheapest.
  - A `scale = true` goal (BBB `d_money`) moves with you; check what it scales by.
- **Social sinks pay.** BBB guild creation costs 10K. It gives +5 % per mate (up to 5) and +1 % per level (up to 10), and its chests paid 60K + Void daily and 40K + Void weekly.
- **Decor, index, cosmetics:** grep what reads the purchased field. Some indexes pay a permanent %; BBB's pays nothing.
- **Tycoon walls and floors** are often the `Dependency` of the next dropper (E5).
- **Verify:** every skipped sink gets a one-line reason in the spec.

#### E14 · If items convert to money (sell drains, exchanges, gacha)
- **Detect** every exit for the same item, and its rate:
  - Sneaker's cashier pays 0.55 × `MaxSellPrice` from anywhere. Its NPC bar pays 0.85–1.10 × after a walk and a minigame.
  - Sell tables (BBB `{150 … 40000}`).
  - Unsellable flags (Sneaker `[1] = "Unsellable"` → only usable in trade-ups).
  - Exchange shops and trade-up recipes.
- **Automate:** measure each drain with one unit (money before and after). Route each item by value × rate minus time cost; bulk junk goes to the instant drain.
- **Watch:**
  - Listed ROI isn't realised ROI. Through Sneaker's cashier, you break even only on buys at 1.82× or more.
  - Flat drains get no multipliers, so they fade as rebirths stack up (E4).
  - Exchanging premium currency for soft currency is rarely worth it.
- ↳ **and if there's gacha** → §8.2 covers opening, odds, luck and pity.

#### E15 · If anything runs on a clock (rotations, restocks, dailies, caps)
- **Detect:**
  - In client scripts: `os.time()`, `os.date("!*t")`, `DateTime.now()`, `workspace:GetServerTimeNow()`, or a date-seeded `Random.new(yday + …)`.
  - Strings: `"RESETS IN"`, `"RESTOCK"`, `"NEXT"`.
  - `Daily*` counters.
- **Automate:** a date-seeded rotation can be computed, so build the schedule instead of polling (Sneaker: `LimitedShopSneaker[utcHour % 6 + 1]`). Claim dailies on join and at the reset boundary (§8.6).
- **Watch:**
  - The boundary can be UTC midnight, 24 h after the last claim, or server-local time. Read it from the sync (BBB `daily={claimable, day, streak}`).
  - Daily caps change the best action mid-day. Sneaker's `DailyBoughtSneakers` ≥ 5,000 slows PC refresh from 1 s to 5 s, so run high-value actions before the cap.
- **Verify:** predict the next rotation or reset, then log what the game shows at that boundary.

#### Done when
- [ ] Configs are `require`d live and the state source is found (E1); no farm decision reads a rounded label where a formula exists (E3).
- [ ] Every currency has faucet → sink → survives reset → Robux? written down (E2).
- [ ] The multiplier model predicts one server-computed number (E4).
- [ ] Every upgrade's cost function matches one real purchase, and every `MAX_LEVEL` has been seen on its sign (E5).
- [ ] Each gate names the stat it reads and whether a reset re-closes it (E7).
- [ ] Rebirth timing rule and the pre-rebirth sweep are in the spec (E8).
- [ ] Boost stacking tested once (E10); every pass sorted into automation / mechanic / stat (E11).
- [ ] Every skipped sink has a one-line reason (E13).
### 8.2 Collection, gacha & inventory

#### Any inventory at all: find the item data first
- **Detect →** find where the server sends per-item state (`uid, id, rarity, level, variant, locked, equipped`). Places to look:
  - a `"sync"`/`"request"` reply (*BBB:* `GarageRemote "request"` → `builds`, `parts`, `deployedId`);
  - Knit remotes under `…knit.Services.<Name>Service.RF` / `.RE` (look for a `Get…`/`…Changed` pair);
  - a ReplicaService `ReplicatedStorage.ReplicaRemoteEvents` folder. The client keeps a live copy of the data in `replica.Data`;
  - value folders (`ReplicatedStorage.PlayerData.<UserId>`, `player.Pets`);
  - if none of those exist, search `getgc(true)` for a table that is keyed by, or holds, a uid you saw in the spy.
- **Automate →** build one `inventory()` from that source and re-read it after every mutation. Never scrape the inventory frame: it is paged, virtualized and gets redrawn.
  - **→ if** items are addressed by **array index** rather than a stable uid, every sell or fuse shifts the rest. Do one mutation, wait for the sync, re-read, then do the next. Never batch.
- **Verify →** the count from `inventory()` matches the game's own `x/100` label, and a freshly opened item shows up by its uid.

#### Items with stats: what actually drives power
- **Detect →** dump every item def and measure what one step on each axis is worth: rarity, source (egg/crate tier), variant (golden/shiny/rainbow/huge/mutation), level, stars/evolution, enchant. *BBB:* one rarity step is ×1.45 and one crate tier is +6 %, so rarity decides.
- **Automate →** rank each uid by its **final** value (`base × variant × level × …`, taken from the item data), not by the base stat in the config. Any axis you can't compute becomes a tie-break after the dominant one.
  - **→ if** a variant step is worth more than a rarity step (golden ×2 vs ×1.45), a golden Rare outranks a plain Epic. A rarity-first sort gets this wrong.
  - **→ if** items level up while equipped, an old levelled item can beat a new level-1 one. Compare current values and use the max-level value as the tie-break.
- **Watch out →** some multipliers live in functions, not in table fields (*BBB:* the +6 % per crate tier comes from `CrateConfig.partStatMult`). Grep where the stat is **read**, not only where it is defined.
- **Verify →** after one swap, the game's own power readout (leaderstat, attribute or `"POWER"` label) moves the way your ranking predicted.

#### Eggs, crates, summons, rolls: the open call
- **Detect →** do one open by hand under the §3 spy (IY `;rspy` works for a first look). Record the remote, the payload (*BBB:* `CrateRemote "open", {crateId, count}`) and how results come back: a reply event (`"opened", {results}`) or a Knit `RF` whose `InvokeServer` returns them. Also run `grep -rniE "hatch|egg|summon|gacha|roll|crate"` over the decompile.
- **Automate →** make the loop ack-driven: fire one open, wait for its results (3 s timeout), then fire the next. Take the pace from the game's own auto loop (its `task.wait(…)`) or its cooldown constant. If there is neither, ramp up until results stop matching calls, then back off.
  - **→ if** you hold **stock** (crates, keys, tickets; *BBB*), you can hold it for luck (see *Luck*). **If** it's **pay-per-open** (coins at the egg), you can only hold currency, and hatching competes with every other sink (§4b). Read the price live, because it often scales with zone or rebirth.
  - **→ if** the egg is a world model, expect a range check (§4). The character has to park at the egg, which clashes with every character farm, so schedule hatch sessions instead of mixing in single opens.
  - **→ if** opening is a timer (place the egg, it hatches in N minutes: incubators, garden plots), the limit is slots × time. Keep every slot busy, put the best egg in first, and collect the moment it's ready.
  - **→ if** the payload has a payment mode (`"Gems"`/`"Robux"`/`useTicket`), never send the premium one. If gems can also be bought for Robux, spending them gets its own opt-in and reserve.
- **Watch out →** server cooldowns drop extra calls without saying so. `InvokeServer` can hang, so wrap it in `pcall` inside `task.spawn` with a timeout.
- **Verify →** results are read from the reply, including auto-sold ones (*BBB:* `{coins, sold=true}`), and stock or currency drops by exactly count × cost.

#### Open animations & reveal overlays
- **Detect →** open one by hand and note what happens:
  - which ScreenGui appears (IY `;dex` on `PlayerGui` shows its name);
  - whether `CurrentCamera.CameraType` switches to `Scriptable`;
  - whether controls are turned off (`GetControls():Disable()`, WalkSpeed 0);
  - whether there's a client `isOpening` debounce.
  
  `getconnections(remote.OnClientEvent)` plus `debug.info(c.Function, "s")` tells you which script plays it.
- **Automate →** use the game's own skip/fast-open setting first (`grep -i '"skip'`, and mirror it per §1). Otherwise hide the overlay with `gui.Enabled = false` and restore it on unload. *BBB farm:* "Hide reveal animation", on by default.
  - **→ if** reveals **queue** up (one per result) and the farm opens faster than they play, the queue keeps growing until the screen is covered for good and FPS collapses. Turn the play function into a no-op. `require(mod).Play = function() end` only works if callers look `Play` up at call time. If they saved it in a local, find it with `getgc` (by name or constants) and `hookfunction` it.
  - **→ if** the animation takes over the **camera or controls**, camera-facing prompt gates (§4, *BBB* WorkshopSign) and walk/teleport farms fail while it plays. Suppress it, or pause character farms during opens.
- **Watch out →** don't `:Disable()` the whole `OnClientEvent` connection. The same handler usually refreshes the inventory UI and clears the debounce, so the game's own open button stops working.
- **Verify →** after 50 opens in a row, FPS is steady, `#PlayerGui:GetChildren()` hasn't changed, and the game's own open button still works.

#### Multi-open & auto-open passes
- **Detect →** a `count`/`amount` field (*BBB:* 1..5) and whatever gates it in attrs, passes or upgrades: `grep -iE "triple|multi|hatchamount|maxopen|autohatch|fasthatch|Perk_"`.
- **Automate →** always open the maximum allowed count. Probe once with cap+1 to see whether the server clamps it, rejects it or errors.
  - **→ if** you can't afford a full batch, the server usually rejects the whole call. Drop to the largest count you can afford instead of stalling.
  - **→ if** Auto Hatch is a pass, check which kind it is:
    - a **server toggle** (`setSetting`, state in the sync) only works for owners, so mirror it if the player owns it (§1);
    - a **client loop** over the same remote is exactly what your own loop already does.
- **Watch out →** "Fast Hatch" may shorten a **server** cooldown, not just the animation. Measure the accepted pace without the pass; don't copy an owner's pace.
- **Verify →** each call returns as many results as its count, and items/min shows in the heartbeat.

#### Odds tables: what to open
- **Detect →** find the odds module (*BBB:* `CrateConfig`, `BotParts`) with `grep -rliE "weight|chance|odds|rarit"`, `require` it, and `writefile` a dump. Rows are either raw weights (normalize them) or percents, and they can interpolate by level (*BBB:* fabricator LV1→LV10). Note which tiers each source can produce at all (*BBB:* Mythic/Godly only come from Lava+ crates).
- **Automate →** choose the egg by **expected gain over your worst equipped item ÷ cost**, where a result below that item counts as 0. Don't just pick the priciest one you can afford. While hunting the Index, choose by **P(undiscovered) ÷ cost** instead.
  - **→ if** the odds table only exists on the server, the client has display strings only (`"1 in 250"`, `"0.4%"` on the egg's BillboardGui). Parse those, and expect rounding and no luck applied.
  - **→ if** the shown odds don't match what you observe, keep logging results per egg. Past about 200 results, trust the log.
- **Verify →** logged rarity counts land within ~2σ of the table.

#### Luck
| Source | Signal | Farm rule |
|---|---|---|
| Session bar | `luckSeconds`/`luckPercent` in the sync (*BBB*: resets on rejoin) | don't hop servers or rejoin without need |
| Roll counter (every Nth roll gets ×2) | `RollCount`-style attr, UI `x/10` | use the boosted roll on the best egg |
| Potion / timed boost | an item with `EndsAt` or `Remaining` | use it right before a hatch burst |
| Server luck (bought by a player) / admin event | an attribute plus an end time (*BBB:* `workspace.AdminLuckMult` / `AdminLuckEndsAt`) | open held stock; hatch only the best egg |
| Biome / weather / time of day | a workspace attribute or value | schedule hatch sessions into it |

- **Know what luck does →** read the roll function. Luck might multiply only the rare rows and renormalize (*BBB:* `EVENT_LUCK`), divide the roll, shift a threshold, or roll N times and keep the best. "×2 luck" rarely doubles the top row. Compute the effective table at the current luck and show it in the UI.
- **Hold vs open now →** hold only when all four are true:
  - (a) the boost is announced with an end time or a schedule;
  - (b) it scales the rows you care about (*BBB:* Lava+ only);
  - (c) storage can hold the stock without blocking new deliveries;
  - (d) leaving those items unequipped in the meantime costs little.
  
  For unscheduled admin events, open now and hold only the top tier.
  - **→ when** the boost starts, open held stock top tier first, and check that held count ÷ open rate is less than the time left.
  - **→ if** a boost timer runs on `EndsAt` (wall clock), it burns while you're offline; one on `Remaining` pauses. **If** using a second potion only refreshes the timer, the second one is wasted. Test once by using two back-to-back.
- **Verify →** log the luck value next to each result. During an event the rare-row rate should clearly beat the baseline.

#### Banners, restocks & pity
- **Detect →** `grep -iE "banner|pity|featured|rateup|rotation|restock|guarantee"`. The pity count lives in the item data (`Pity`, `summonsSince…`). Rotations and restocks are often seeded from the clock (`Random.new(math.floor(os.time()/1800))`), and then the client can **predict** upcoming banners or stock.
- **Automate →** save currency until the target is on the banner, summon in the biggest batch (check for a 10-pull discount or guarantee), and stop on a hit. For restock shops, read the stock at each restock tick and buy targets immediately; be fast if the stock is shared across the server.
  - **→ if** pity is per banner, don't split summons across banners. **If** pity carries over between rotations, it's safe to leave it partly filled.
  - **→ if** there's soft pity (rates climb after N pulls), count to hard pity, because that's the cheapest guarantee.
- **Watch out →** a featured rate-up is often a share of the tier's rate, not something added on top.
- **Verify →** the pity counter in the data rises with each summon and resets on a hit at the configured number.

#### Equip best & team slots
- **Detect →** look for:
  - an `"EQUIP BEST"` string or an `EquipBest`/`equipBest` remote;
  - a per-uid equip remote (*BBB:* `GarageRemote "equip", {buildId, uid}`, which works from anywhere);
  - a slot cap attribute (`MaxEquipped`/`PetSlots`/`EquipLimit`);
  - typed slots (*BBB:* 5 part slots) versus any-slot teams (pets: top N).
- **Automate →** use the game's Equip Best if its comparator matches what actually drives power. It's usually readable on the client, as a `table.sort` before it fires `equip`. Otherwise equip per uid using your own ranking. Run it after each batch of opens or conversions, not after every item.
  - **→ if** equipping is only allowed in some states (in a match, in the Depths, while trading), queue it for the next free window (*BBB farm:* equips only while the bot is home).
- **Watch out →** avoid churn. Unequipping can reset per-item state (XP target, assigned coin pile), so only swap when the new item is at least X % better (make X a setting). An extra slot is worth your best unequipped item, which often makes it the best buy in the game, so treat slot unlocks as gates (§4b).
- **Verify →** the power readout never drops after an auto-equip. Log each swap as `slot: old → new (+x %)`.

#### Special abilities & set bonuses: when one number can't rank it
- **Detect →** ability or set fields in item defs (`ability`, `passive`, `special`, `set`, `SetBonus`) and UI strings like `"2/4"`. *BBB:* satellites carry per-crate specials at r3/r5/r6/r7.
- **Automate →** tag each ability with the activity it helps (coins, damage, luck, hatch speed, XP) and score it only for that activity (this feeds *Loadouts*). For abilities that are text only, rank by rarity, then by source tier (*BBB:* satellites).
  - **→ if** sets exist, score whole teams. Compare greedy best-per-slot against every combo that completes a set at each breakpoint (2/4/6 pieces) and keep the best. A per-slot ranker can't see set bonuses.
- **Watch out →** add a per-slot **pin** setting so auto-equip only touches unpinned slots. The player knows synergies the config doesn't show.
- **Verify →** for anything scored by a guess, measure it: coins/min or waves/min over 2 minutes, before and after.

#### Loadouts & multi-builds
- **Detect →** build or team arrays in the sync (*BBB:* `builds = {{id, name, level, xp, rev, parts}}`, `deployedId`) and `deploy`/`loadTeam`/`saveTeam` remotes.
- **Automate →** keep one loadout per activity (farming = coins, hatching = luck/hatch speed, fighting = damage). Switch at the boundary between activities, never mid-action. Fill the idle build ahead of time (*BBB:* `equip` works on a non-deployed build from anywhere), then `deploy` it.
  - **→ if** each build has its own level and XP (*BBB*), a fresh build is weak and switching costs power. Don't switch for small gains.
  - **→ if** one item can sit in several builds, every consumer has to check **all** builds, not just the deployed one (*BBB farm* does this).
- **Watch out →** switch cooldowns and state gates. Builds the player uses by hand are off-limits unless they tick them in a "builds the farm may touch" setting.
- **Verify →** after each switch, `deployedId` in the sync matches. Measure once that switching actually beats not switching.

#### Locks, favorites & keep rules: one guard for every consumer
- **Detect →** the lock/favorite field and its remote (*BBB:* `GarageRemote "lock", {uid, locked}`), and whether the game's own Sell All, fuse and trade respect it.
- **Automate →** write one `isProtected(item)` that every sell, delete, fuse, reroll and craft calls. It must read **fresh** server data, because the player locks things mid-run. An item is protected if it is any of these:
  - locked or favorited;
  - equipped on **any** build;
  - pinned;
  - limited, or of unknown rarity;
  - the first copy for the Index;
  - named in a rebirth, quest or recipe requirement (`grep -iE "requires|needItems"` in those configs);
  - inside the keep-K count.
  - **→ optional:** auto-lock new items on arrival (Mythic+, limited, shiny). It's cheap insurance against your own bugs and against the player's own Sell All misclick. Off by default, and every lock is logged.
- **Watch out →** the farm never **unlocks** anything.
- **Verify →** the junk preview (§5b) contains no protected uid, and the sell function refuses a protected item on the client before firing anything.

#### Duplicates
- **Detect →** list everything that uses copies: fuse/golden inputs, star-up/awaken ("3 copies → 2-star"), feeding for XP, shard exchange, variant Index pages. *BBB:* nothing uses them. The Index is a viewer only and discovery survives selling, so sell everything beyond keep-K.
- **Automate →** send copies down this order: equip, then star-up, then conversion, then feed, then sell. Set keep-K per **id** to the largest recipe that uses that id.
- **Watch out →** a keep-K-per-**slot** rule sells the same-id copies that star-up needs.
- **Verify →** the junk preview lists no id that a recipe still needs.

#### Conversions that consume items: fuse, merge, golden/rainbow, craft, evolve
- **Detect →** `grep -iE "fuse|merge|golden|rainbow|shiny|craft|recipe|evolve|combine|machine"`. Find the required counts, the success chance, whether the output is random or fixed, and what carries over (level, enchant).
- **Automate →** send explicit uids, none of them `isProtected`, then run Equip Best again because the output may be better.
  - **→ if** the remote takes **an id and a count** instead of uids, the server picks which copies to use. Test with a throwaway set to see which ones it takes (oldest? lowest level? equipped?). If it can take an equipped or enchanted copy, lock those first or don't automate it.
  - **→ if** a conversion can fail and still consume the inputs (for example golden machines whose chance grows with how many you feed), its value is chance × output − inputs. Only feed copies worth about nothing to you.
  - **→ if** it consumes the item you'd equip (evolving the equipped unit), do an explicit, logged unequip → convert → re-equip. Never let it get around the guard silently.
  - **→ if** the output loses the inputs' level or enchant, compare it with the best input, not with the base item.
- **Watch out →** "finish now" and "guarantee" options paid in gems or Robux on craft timers stay off by default.
- **Verify →** print a dry-run line (`would fuse 10× Cat → Golden Cat, keep 2`) before the first real call, and check that the inventory diff afterwards matches it exactly.

#### Rerolls on owned items: enchants, traits, stat rolls
- **Detect →** `grep -iE "enchant|trait|reroll|reforge|potential|mutation"`, the roll field in the item data (`trait`, `enchants`), and the token each roll costs (crystals, books).
- **Automate →** roll strictly one at a time: fire, wait for the new value in the reply or data, check it against the target set, and stop on a hit. Stop conditions: target hit, spend cap reached, or token reserve reached.
  - **→ never pipeline:** a second call already in flight overwrites the hit.
  - **→ if** the server returns a pending roll you accept or decline, accept it only when it beats the current one. **If** rolls apply automatically, you can't keep the better of two, so set targets conservatively.
  - **→ if** there's a lock (keep one trait while rerolling another), include it in the cost. Locks usually multiply the price.
- **Verify →** read the trait from the data after each roll (not from the popup) and log it with the tokens left.

#### An inventory cap: what "full" does
- **Detect →** the cap and count (`MaxPets`, `InventorySize`, `Storage`, `capacity`, the `x/100` label), what raises the cap (*BBB:* 100, +50 with the pass, plus skill slots), and what counts toward it (unopened crates? equipped items? other builds?). Find the code path for "full" with `grep -iE "full|capacity|no space|maxstorage"`.
- **Then find out what full does**, because each case needs a different farm:
  - **→ opens are refused** (*BBB:* `CrateRemote "full"`): the open loop waits until a cleanup frees room. Don't hot-loop on "full" replies.
  - **→ items overflow to a mailbox, storage or bank:** claim them back once there's room.
  - **→ new items are silently deleted or sold, or rewards are dropped** (event or quest crates arriving while full): before events, keep free space of at least the biggest reward burst (*BBB:* Elite paid 6 crates).
- **Automate →** keep free space of max batch × items per open + the next event's payout. Run the cleanup pass before multi-opens and before events.
- **Verify →** read the "full" code path in the decompile, then confirm it once with the cheapest item (open one at the cap) and log the reply. The status line shows `count/cap`.

#### Auto-delete & auto-sell: the game's vs yours
§1 already says to use the game's own and mirror it. This part is specific to items.
- **Detect →** how fine-grained the filter is and where it is stored.
  - Granularity: per rarity (*BBB:* `AutoSell<1..7>`), per egg per item (checkboxes on the egg UI, `"AUTO DELETE"`), or per variant.
  - Storage: a server setting in the sync, or client-only state that resets on rejoin.
- **Automate →** let the game's filter handle the bottom rarities that are always junk. It runs before the item takes a slot, so it's the only filter that works when the inventory is full. Use your own for the rules it can't express (keep-K per slot or id, recipe inputs, `isProtected`).
  - **→ if** the game's filter is **client-side** (a LocalScript that fires `delete` after each result), it only runs while that script runs. Killing the reveal handler (see *Open animations*) can kill the filter too.
  - **→ if** the filter is per egg, mirror it per egg. A new egg starts with nothing ticked.
  - **→ if** sell values are flat with no multipliers (*BBB*), you sell for space, not income. Don't let sell value decide what you keep.
- **Watch out →** check three things: does it spare shiny/golden/huge/limited items? Does an auto-deleted item still register in the Index? Does it pay the sell value or delete for 0? Read the code, or test once on the cheapest egg.
- **Verify →** results for those rarities come back flagged in the reply (*BBB:* `sold=true`), and the inventory count doesn't rise for them.

#### An index or collection: does it pay?
- **Detect →** `grep -iE "index|collection|discover|bestiary|album"`, then look for any of: reward tables (milestones like "collect 25 → +1 slot"), a claim remote, a `"CLAIM"` string in the index frame, or a passive "+x % per entry". *BBB:* a viewer only, and discovery survives selling.
- **If it pays →**
  - pick eggs by P(undiscovered) ÷ cost until each page is complete. Variant pages make conversions a source too.
  - keep the first copy until the discovered flag flips in the data. Check whether discovery registers on hatch, on keeping the item, or even on auto-delete.
  - auto-claim milestone rewards, since they usually need a manual claim.
  - **→ if** discovery doesn't survive deletion, one of each has to stay forever, so auto-lock it.
- **Verify →** the discovered count in the data rises by one on a new hatch, and a claimed milestone pays out.

#### Limited & event-only items
- **Detect →** item flags (`Limited`, `Exclusive`, `Event`, `Secret`, `Huge`, `Titanic`, `OffSale`), event eggs and currencies with time windows (`StartsAt`/`EndsAt` in config, event folders in workspace), and what event currency becomes when the event ends (wiped, or converted at what rate).
- **Automate →** make limited items `isProtected` whatever their rarity. Spend event currency on a schedule that finishes before `EndsAt` with some margin, and hatch the event egg first while it still exists.
  - **→ if** rarity ranks come from a lookup (`RANK[item.rarity]`), an event tier that's missing from it returns nil. `nil < 3` then errors, and an `or 0` default gets the item sold. Treat unknown rarity as protected.
- **Verify →** the junk preview contains no limited items, and the heartbeat shows event currency and time left.

#### Trading, mail & gifting: don't automate trades
- **Why not →**
  - trades are irreversible;
  - the other player controls half of each trade and can swap items in the last second before accept;
  - trade remotes are where dupe detection and logging concentrate;
  - item value depends on demand, not on a stat.
  
  A bug here means permanent loss.
- **Detect anyway →** `grep -iE "trade|mail|gift|inbox"`, and the trade state (an `InTrade` attribute, or the trade frame being visible).
- **Automate around it →** pause every inventory mutation (sell, fuse, equip, reroll) while a trade is open, and resume when it closes.
  - **→** claiming mail or an inbox is fine because it only adds items. Never send, gift or accept.
- **Verify →** the status line shows `paused: trade open` while the trade UI is up.

#### Done when
- [ ] Item data is read from the server's copy, and it's known whether items are addressed by uid or by index.
- [ ] What drives power is measured per axis, and the ranking is confirmed against the game's own power readout.
- [ ] Odds tables and the luck formula are dumped to files, and effective odds at the current luck are shown in the UI.
- [ ] The open loop waits for each result and runs at the game's own pace; 50 opens cause no overlay pile-up.
- [ ] What "full" does is known, and free space is kept before events.
- [ ] The game's auto-delete is mirrored, and what it spares (variants, limited items, Index entries) is known.
- [ ] Every consumer uses `isProtected`, and the dry-run preview shows items equipped on any build, locked items, limited items and unknown-rarity items all excluded.
- [ ] The hold-for-luck rule and the signal it waits for are written into the spec.
### 8.3 Combat, PvE & PvP

Follow only the branches the game has. Only count something as working when a **server-owned signal** confirms it:
- mob HP as the server replicates it (`Humanoid.Health` or the game's HP attribute),
- currency, XP or inventory deltas,
- the server's own state echoes.

Hit sparks and damage numbers are often drawn on the client before the server decides, so they appear even for hits the server rejected. IY commands are tagged *(local)* when only your client sees the effect, and *(replicated)* when the server and other players see it.

#### C1 · Respawning mobs
- **Detect:**
  - Models with a `Humanoid` that aren't players (`Players:GetPlayerFromCharacter(m) == nil`), under `workspace.Enemies` / `Mobs` / `NPCs` / `Live` / `Entities`.
  - `CollectionService:GetAllTags()` for tags like `Enemy`, `Mob`, `Boss`.
  - Spawner parts with `MobName` / `RespawnTime` attributes.
  - A `MobConfig` / `EnemyData` module (`Health`, `Level`, `XP`, `Drops`, `RespawnTime`, `AggroRange`).
- → **`Humanoid.Health` stays at 100 while the HP bar drops** → HP lives in an attribute or `NumberValue`. Base the whole farm on that value. `Humanoid.Died` won't fire, so find the game's own death signal.
- → **`workspace.StreamingEnabled` is on** → scanning the folder undercounts (§8.4 *StreamingEnabled*). Take positions from the spawners or config.
- **Measure respawn times; don't trust the config.** Log `ChildAdded` / `ChildRemoved` per spawner, with timestamps, for 5 min.
  - → A spawner stays empty while you stand on it → it's blocked by nearby players. Wait just outside it.
  - → Mobs vanish before you arrive and kills/min falls → other players are farming the same spawners. Change servers (hop costs in S11/S14).
- **Automate:** pick a target (C4) → stand inside C3's limits → hit until the **server** HP reaches 0 → move to the next spawner that has a mob. Never wait at an empty one.
- **Verify:** logged kills/min × pay per kill should at least match a minute of manual play.
- **IY:** `;freecam` *(local)* looks at spawners without moving your character, but only inside the stream radius. `;partesp <PartName>` *(local)* boxes every BasePart with exactly that name.

#### C2 · The hit path: how damage is actually dealt
- **Detect:** attack by hand with the GAME-vs-ME spy (§3) running. Grep the decompile for `RaycastHitbox`, `ClientCast`, `MuchachoHitbox`, `FastCast`, `GetPartBoundsInBox`, `GetPartsInPart` and `.Touched`. Classify **each weapon class separately** (sword, gun and magic often work differently):
  - **No remote, only `Tool.Activated`** → the server deals damage on `Handle.Touched`. Call `tool:Activate()`, then `firetouchinterest(tool.Handle, mobPart, 0)` / `1` inside the swing window.
  - **Remote with a target argument** (`Hit:FireServer(mob, …)`) → hit detection runs on the client. Easiest to farm: call the remote directly, then map its limits (C3).
  - **Remote without a target** (`M1:FireServer(comboIndex)`) → the server builds the hitbox from your HRP. Your position **and facing** are the input: `hrp.CFrame = CFrame.lookAt(stand, Vector3.new(m.X, stand.Y, m.Z))`.
  - **Projectile** → client-simulated (`ProjectileHit:FireServer(id, part, pos)`) or server-simulated. For server-simulated you only send an aim point, so aim ahead by `AssemblyLinearVelocity × travelTime`.
  - **Contact or click** → `firetouchinterest(hrp, mobPart, …)` / `fireclickdetector(cd)`. The server usually enforces `MaxActivationDistance`.
- **Watch out:**
  - A spy that filters on `IsA("RemoteEvent")` misses hits sent over `UnreliableRemoteEvent`. Filter on `BaseRemoteEvent`.
  - Arguments packed into a `buffer` (ByteNet / Blink / Zap) → replay the captured buffer unchanged before trying to decode anything.
  - → **Arguments include a counter, timestamp or hash** → don't build them yourself. Call the game's own attack function so it builds valid arguments: `getconnections(tool.Activated)[1].Function`, or a `getgc` function whose `debug.getconstants` include the remote's name (S2).
  - → Only real input works → `VirtualInputManager`, as a last resort.
- → **Combos:** the last hit often knocks the mob out of range. Stop at hit N−1 so the combo resets, or move back to the mob after that hit.
- **Verify:** one hit on a lone mob lowers server HP by the config's `Damage` × your multipliers.
- IY `;hitboxes` *(local)* also draws invisible parts. A part appearing on every swing means a part-based hitbox (`Touched` / `GetPartsInPart`); nothing means a spatial query or a raycast.

#### C3 · What the server validates: §4's far/near test as a gate matrix
- Fire the C2 hit path at a live mob and read **only server HP**. About 20 tries per case:
  - distance: 3 / 10 / 30 / 100 studs
  - rate: 1× / 2× / 5× / 10× the manual rate
  - through a wall (line of sight); facing away; tool unequipped; while stunned or at 0 stamina
  - a far mob instead of the nearest one; several targets in one call
  - a spoofed origin argument, if the remote carries your CFrame (Needle rejected drop CFrames far from the character)
  - a projectile hit reported before the projectile could have arrived
- **The farm's constants are the accepted limits minus a margin**, e.g. "≤ 12 studs, ≤ 4 hits/s, needs line of sight".
  - The target's i-frames after each hit (`IFrames` / `Invulnerable` switching on briefly) also cap the useful rate.
  - The player's own clicks count against the same rate budget.
- → **Hits sent right after a teleport** can be checked against your *old* server position. Wait at least one ping (~0.2 s) before hitting (S1).
- → **Rubber-banding** means the server validates movement (S7/S8).
- **Watch out: punishment is often silent or delayed.** Hits quietly start doing 0 (a shadow nerf), a kick arrives minutes later, or a ban wave hits. Log kick messages (S5), run over-the-limit tests on an alt, and back off at the first run of zero-damage hits.
- **IY:** `;tppos x y z` *(replicated hard teleport)* puts you at exact test distances. `;reach <len>` / `;boxreach <n>` resize your tool's Handle *(local)*, but the touches reach the server: if you still deal damage at 20 studs, the server trusts client touches. Re-equip the tool afterwards.

#### C4 · Target selection, aggro and leash
- **Rank targets by measured pay per second, not by distance:** `pay ÷ (hp ÷ myDps + travel + respawnWait)`. Take `myDps` from C3 and `hp` from the config or attributes. Re-rank after level or gear changes.
- **Hard filters:** level gates (0 damage, or reduced XP, outside your level band); `Weakness` / `Resist` attributes; active kill quests first, since the quest reward often pays more than the kills.
- **Skip mobs someone else is fighting** (their `creator` tag or `Target` value is set, or the HP is already falling). The credit goes to them (C5), and kill-stealing gets you reported.
- **Leash:** a mob pulled past its `LeashRange` / `ChaseRange` resets to full HP. Fight at the spawner and never pull. Teleporting away mid-fight usually wipes the damage done.
- → **Mobs are melee-only and C3's range allows it** → stand where they can't reach you: on a ledge, or hovering `h` studs up (reset your CFrame every `Heartbeat` and zero `AssemblyLinearVelocity`).
  - → Long hovers can trip the server's fly checks. Test on an alt. Box hitboxes in front of the HRP (C2) need you at the mob's height.
- → **You own the mobs' physics** (`isnetworkowner(mob.HumanoidRootPart)`, or `ReceiveAge == 0` on an unanchored part) → you can stack a group on one spot and hit them all with one area attack.
  - → Games often take ownership back with `SetNetworkOwner(nil)` on aggro, or snap mobs back past the leash. Only server HP proves it worked.
- **Verify:** farm each candidate mob type for 10 min. Choose by logged coins/min, not by the formula.

#### C5 · Kill credit: who gets paid
- **Detect:** a `creator` ObjectValue under the mob's Humanoid (`Value` is the Player); attributes such as `LastHitBy`, `Tagged`, `Killer`; a per-player damage folder (`Mob.Damage.<Name>`); config keys `CREDIT_WINDOW`, `ASSIST`, `MinDamage`.
- **Run the credit test matrix**, reading currency, XP and quest deltas each time:
  1. solo kill
  2. you hit once, someone else finishes
  3. someone else does most of the damage, you land the last hit
  4. you hit, then the mob dies from a fall, the void or a hazard
  5. you hit, walk 100 studs away, then it dies
- **Branches:**
  - → Last hit only → be the finisher: let area attacks or units do the damage, and never split targets.
  - → Any hit within N s → one cheap area attack tags a whole group, and tagging then leaving pays. Same shape as BBB's event tiers.
  - → Damage share or minimum % → one target at a time; tags alone pay nothing.
  - → Test 5 pays nothing → you must be in range when the mob dies. Stay until `Died`.
- **Where the pay lands:** straight into currency at death; as a drop in `workspace.Drops` / `Loot` with an `Owner` attribute and a despawn timer (pickup rules, §8.4); or only as a quest counter.
- **Verify:** count a reward only inside the time window right after your kill (§3, confounded signals).

#### C6 · Abilities and cooldowns
- **Detect:** skill keys via `ContextActionService:GetAllBoundActionInfo()` or `getconnections(UserInputService.InputBegan)`. Their handlers fire calls like `Skill:FireServer("Q", aim)` or `UseAbility:InvokeServer(id, cf)`. `SkillConfig` holds `Cooldown`, `Damage`, `Cost`, `Range`, `CastTime`. Server cooldowns show up as `CD_<id>` attributes or in the InvokeServer reply.
- **The cooldown UI is client-side.** Measure the server's real cooldown: fire at 2× the rate and count the casts that change server HP.
- **Aim explicitly:** pass the target position (`mob.HumanoidRootPart.Position`); lead projectiles by velocity × travel time.
  - → If you call the game's own cast function and it reads `Mouse.Hit` or the camera: answer `mouse.Hit` with the target's CFrame through `hookmetamethod(game, "__index", …)`, only for the game's code (`not checkcaller()`), or point `workspace.CurrentCamera.CFrame` at the target first. Games check the camera on the client, as BBB did with its sign prompts.
- **Rotation:** cast whichever ready skill has the best damage per cooldown. Area skills only on groups; save burst for a boss's vulnerable phase (C7).
- → A skill that roots you (`WalkSpeed = 0`) or dashes you off a safe spot → return to the spot after the cast, or leave that skill out.
- → Mana or stamina costs limit the rotation (C14).
- **Verify:** logged casts/min and HP change per cast roughly match the config's cooldown and damage.

#### C7 · Bosses
- **Detect:** `workspace.Bosses` / `WorldBoss` models; a spawn clock (in-world countdown, a `SpawnAt` attribute compared with `workspace:GetServerTimeNow()`, or `BossConfig.RespawnTime`); a damage leaderboard in `PlayerGui` (the game tracks damage per player); a reward remote at death (`{damage, rank, tier}`).
- **The reward model decides the strategy:**
  - → **Server-wide tiers or a shared pool** → **join and leave**. Land the participation hit (or get the `joined` flag), then go farm elsewhere. With no flag at all (BBB's Titan), count time in the zone and confirm by the rewards.
  - → **Personal share or minimum** (`MinDamagePercent`, top-N) → stay until your leaderboard line passes the threshold, then test whether leaving early still pays when the boss dies.
  - → **You must be alive or inside `RewardRadius` at death** → wait at the edge of the radius until the reward arrives.
  - → **Last hit only** → skip it unless you're alone on the server.
- **Kill-time check:** sample boss HP for 20 s and estimate HP ÷ server DPS. If that's longer than the despawn or enrage timer, nobody gets paid, so don't go.
- **Watch out:** `Invulnerable` / `Shield` attributes or a `ForceField` → stop hitting (wasted cooldowns, counts toward rate limits). Attack warnings appear as named parts (`Warning`, `Indicator`) under `workspace.Effects` / `Debris`; leave their area before they fire. Parry and block windows stun attackers.
- → **One boss per server** → hopping has a cost (S11 rate limits, S14 session resets such as BBB's luck bar).
- **Verify:** rewards from at least 3 spawns using the chosen leave timing.
- **IY:** `;view <player>` *(local)* shows where the top damagers stand; `;antifling` *(local)* helps in crowded fights.

#### C8 · Raids, dungeons and instanced sub-places
- **Detect:** queue pads or elevators (a player count plus a countdown SurfaceGui; you usually have to *stay inside* until it fires); UI queues (`Dungeon:InvokeServer("Create", {map, difficulty, private = true})` → `"Start"`); entry costs (keys, tickets, energy); the destination, from `LocalPlayer.OnTeleport(state, placeId)`.
- **A new PlaceId is a different game.** `game.GameId` stays but `game.PlaceId` changes, and the lobby decompile usually has none of the dungeon's combat code. Decompile again inside (one dump per PlaceId) and redo C2–C3 there. Teleport survival (loader, `queue_on_teleport`, settings in a file) is S10.
- → **Party minimum above 1** → use a solo or private difficulty if one exists. Public queues bring random players who leave: handle "party disbanded" and queue again. A second account can follow with `;loopgoto <main>` *(replicated; obvious, so private servers only)*.
- **The loot often needs one last action:** an end-chest `ProximityPrompt`, a `Claim` / `Replay` vote, or walking into the exit portal. Miss it and the run pays nothing.
- **Watchdogs:** `TeleportService.TeleportInitFailed`, or no arrival within ~60 s → back to the lobby. Too slow for the dungeon timer → abandon early. The game can send you back to the lobby at any point, so handle arriving there mid-run. A jammed executor bridge (§5b) looks exactly like a lost teleport queue: check the ping file first.
- **Verify:** 3 unattended cycles (lobby → queue → clear → loot → return → queue again), all in one log file with the PlaceId on every line.

#### C9 · Wave and survival modes
- **Detect:** `Wave` / `EnemiesLeft` attributes or values (in `workspace` or `ReplicatedStorage.GameState`); wave and defeat remotes (`{wave, record, earned}`); a revive window (a countdown plus a Robux button); skip offers (`SkipWave` / `SkipCost`).
- **Defeat:** leave or restart the moment the defeat signal fires; the revive window is dead time. In BBB, firing `depthsStop` on `depthsDefeat` skips a 90 s window every run. Never auto-press a Robux revive; take a free revive only if the run is still paying.
- **Pay per minute peaks before your power limit.** The waves near your limit take the longest (BBB: 2.7 s per wave early, 4–12 s near the limit). For money, "restart after wave N / after T seconds" beats "run until defeat". Run until defeat only when the goal is a best-wave record (a rebirth gate, E7).
- **Skipping waves:** pays only if the waves past the skip point that you'll clear in the remaining time earn more than it costs. Mostly a way to reach a gate wave quickly.
- **Stall detector:** the wave hasn't changed for 2× the slowest wave time → a mob is probably stuck in the map, or the mode softlocked. Find the mob (ESP on the enemy folder) or restart.
- → **Shared lives in public wave servers** → other players can end your run. Prefer solo or private servers (S12).
- **Verify:** 3 full start → defeat → restart cycles in the log, with pay/min for each.

#### C10 · PvP zones and KO risk
- **Detect whether PvP is on:** PvP or safe regions (`workspace.Zones.*`, `SafeZone` parts, config boxes); attributes `PvP`, `InSafeZone`, `CombatTag`; spawn protection (a `ForceField` lasting `SpawnLocation.Duration`); `SAFE ZONE` / `IN COMBAT` HUD labels.
- **Work out what a death costs before farming there:** what drops or resets (a % of money, carried items dropped into `workspace.Drops`, durability, a streak or bounty); `Players.RespawnTime` plus the trip back; unit rebuild time (BBB: a knocked-out bot rebuilds at the plot). Deaths per hour × cost must stay below the zone's extra pay.
- **Keep exposure short:** join and leave when participation is just a flag; farm at the edge of the safe zone; leave when a stronger player (public leaderstats) comes within R studs.
- **Combat tag:** leaving, teleporting or rejoining while tagged often counts as a death (combat logging). Don't hop, rejoin or teleport until it clears.
- **Everyone can see your teleports here** (they're replicated), and some players report them. Walk where you can: IY `;walktopos x y z` sets `Humanoid.WalkToPoint` (real walking, no pathfinding); `;ttppos` tweens in a straight line (smooth, but speed checks still see it).
- **IY:** `;esp` *(local)* shows nearby players. `;antifling` *(local)* stops collision flings, not server knockback. Never `;loopgoto` here.
- **Verify:** 30 min in the zone (KO count, net earnings) vs 30 min of the safe alternative.

#### C11 · Capture and hold zones (beyond §3's acquire / hold / survive)
- **Detect:** a progress signal (`Progress` / `CaptureProgress` / `Owner` attributes, or a SurfaceGui bar); the radius or volume (`CAPTURE_RADIUS`, the zone part's size); how presence is checked (grep for `Touched`, `GetPartsInPart`, `.Magnitude <`).
- → **Contested zones** (an enemy inside pauses or reverses progress) → hold only when uncontested; otherwise skip it.
- → **Progress resets (instead of pausing) when you step out** → never leave the zone, even to dodge; dodge *inside* it. *BBB:* the alien crate's 60 s `CAPTURE_TIME` needs the carrier in the Pit throughout. Lasers warn 0.9 s ahead (`LASER_WARNING`) and hit 6 studs (`LASER_RADIUS`) for 35; other players' bots, `BotSwarm` and `PitBoss` also hit characters, and any hit drops the crate. The catcher scans threats at 10 Hz and hops to the safest of 16 sampled Pit spots when one comes in range.
- → **`Touched`-based zones need continuous contact.** A hovering or anchored character, or a single `firetouchinterest` "begin", flickers in and out. Stand on the floor inside the part (`Humanoid.FloorMaterial ~= Enum.Material.Air`). Never run `;firetouchinterests` *(replicated)* without a name: it touches every TouchTransmitter in workspace, including kill bricks and queue pads.
- → **The zone requires you alive, on the ground and not seated** → dying or sitting (`Humanoid.SeatPart` set) resets the capture.
- → **The event's end completes a capture in progress** (BBB: a 26 s hold paid at raid end) → never skip a late pickup. Plan the round as "full holds + one at the end".
- **Verify:** the progress value only goes up in the log, and then the delivery signal arrives. *BBB:* 4 of 4 possible crates in one raid with the threat-aware catcher.

#### C12 · Death and respawn inside farm loops
- **Never cache the character.** Look up `Character`, `HumanoidRootPart`, `Humanoid` and the equipped `Tool` on every tick. On `LocalPlayer.CharacterAdded`, reconnect `Humanoid.Died` and re-equip with `Humanoid:EquipTool(tool)`; the Backpack is rebuilt on every spawn.
- **Alive isn't just `Health > 0`.** Knocked, ragdolled and stunned states also stop you: `Humanoid:GetState()` is `Physics`, `Ragdoll`, `PlatformStanding` or `FallingDown`; attributes `Knocked`, `Downed`, `Ragdolled`, `Stunned`; `WalkSpeed == 0`. Pause all input in these states; hits sent while stunned are wasted or flagged.
- **After a spawn,** wait for the HRP and the game's own ready signal (a `Loaded` attribute, or the loading screen closing) before teleporting. A teleport while the character loads can fling you or drop you into the void.
- → **No automatic respawn** (you stay dead past `Players.RespawnTime`, or there's a RESPAWN button) → fire the button's remote, or the loop waits forever.
- → **Death is expensive** (C10's cost, or a far spawn) → retreat below X % HP to a safe zone, potion or regen spot instead of dying.
- **Break death loops:** 3+ deaths in 5 minutes at one spot → mark the spot unsafe, move on, and log the last damage source (from `HealthChanged` deltas).
- **IY:** `;spawnpoint [delay]` / `;flashback` *(replicated hard teleports)* return to a saved spot or where you died; fine for testing. **Avoid `;god`**: it replaces your Humanoid with a clone, which breaks anything server-side that looks up your Humanoid, does nothing where HP is an attribute, and in 6.4.2 references undefined `char` / `pos`, leaves `LocalPlayer.Character = nil` and errors, stalling every loop that reads the character.
- **Verify:** reset mid-farm 3 times; the loop resumes on its own within one respawn each time.

#### C13 · Autonomous units (pets, bots, summons, towers)
- The player only chooses **where** the units go (sometimes **what** they attack); the server runs the fight.
- **Detect:** unit models (`workspace.Pets.<UserId>`, `workspace.Bots`, tower placements); target and mode remotes (`SetTarget`, `Mode`, `Send`, `Recall`, `Place`); the server's `mode` / `state` echo.
- **Build the state machine from the server's echoes (§3):** act on the echo, never on "command sent". After a timeout, treat an in-transit state as arrived, because some never resolve (BBB: `toPlot` is never followed by `plot`). Record which commands each state ignores (BBB: `toArena` is ignored in the Depths).
- → **Each mode pays something different** (BBB: Depths = money, plot = XP, Pit = event tiers) → schedule time across modes, not just one best spot.
- → **Units stay near the character** → the character's position is part of the command. Park it where the units need to fight.
- → **Units have HP and can be knocked out** → count rebuild or recall time as downtime. Keep them out of PvP they can't win (BBB's Pit: join the event, then leave).
- → **Kills drop orbs or coins near the target** → the character has to collect them.
- → **Pay goes straight to you** → the character is free for a parallel farm (BBB's scrap), and the two stack.
- Unit power comes from equipment and levels. Rank gear by the config's numbers, not the UI's power label (§8.2).
- **Verify:** unit rewards per minute are about the same with the character idle as with it running its parallel farm.

#### C14 · Stamina, hunger, durability and HP regen
- **Detect:** attributes on the player or character (`Stamina`, `Energy`, `Mana`, `Hunger`, `Thirst`); tool attributes (`Durability`, `Uses`); HUD bar sizes; config rates (`STAMINA_REGEN`, `HUNGER_DECAY`, `REPAIR_COST`). Default characters regen 1 % of `MaxHealth` per second via the `Health` script; without that script, regen is custom or absent.
- **Check who owns the value.** A variable only in a LocalScript, with no replicated attribute, is often unchecked by the server. Attack at 0 stamina and read server HP.
- → **Server-owned stamina or mana** → attack down to X %, then rest. Learn what triggers regen (idle only? N s out of combat? sitting?) and pick X to minimise rest time.
- → **Hunger or thirst** → eat below Y with the cheapest food per point. At 0 hunger HP usually drains, which can kill an unattended farm.
- → **Durability** → repair before 0. Test on a cheap tool whether a broken tool is **deleted** (permanent loss) or just disabled.
- **Verify:** a 30-minute log of each resource shows a steady cycle that never reaches 0.

#### Done when
- [ ] The hit path is classified per weapon class, and the gate matrix (distance, rate, line of sight, facing, delay after a teleport) is filled in from **server HP**, not hit effects.
- [ ] The kill-credit matrix has been run, and targeting matches it (finisher, tagger or single target).
- [ ] Every boss and event reward model is known, and the leave timing is verified by rewards on ≥ 3 spawns.
- [ ] A forced death mid-farm, a wave defeat and a PvP KO each recover without help.
- [ ] The sub-place cycle ran 3 times unattended.
- [ ] In-transit states time out and count as arrived; no loop waits for an echo that never comes.
- [ ] Resource curves (stamina, hunger, durability, HP) stay stable over 30 minutes.
- [ ] Over-the-limit tests ran on an alt, and the main farms a notch inside every measured limit.
### 8.4 World, map & interaction

Every system below comes down to one **input rung** and one **movement rung**. Use the highest rung the *server* accepts, prove it far vs near (§4), and judge it by the delivery signal (§3). SRS = Sneaker Resell Simulator, NIH = Needle in a Haystack, MoD = Mog or Die, FIU = Fix It Up!.

#### The input ladder: stop at the first rung the server accepts

| # | Rung | Call | Server still checks | Traps |
|---|---|---|---|---|
| 1 | Direct remote | `R:FireServer(…)` / `R:InvokeServer(…)`, with the exact arg shape a GAME-tagged spy (§3) caught during one manual use | args, ownership, cost, cooldown, call order (talk → accept), and **your server-side position** for anything in the world | Only fire arg shapes the game's own client sends (S2). A remote no client script fires is a honeypot candidate (S3). An `InvokeServer` return is a free success signal (SRS buy returns `true`). |
| 2 | Game's fallback remote | The other path in the prompt's script: billboard click, mobile/gamepad button (BBB `PlotSignRemote(part)`) | usually the prompt's own range (BBB: ignored at ≥ 30 studs, fine at 4) | If it takes an Instance, the part must be streamed in. |
| 3 | ProximityPrompt | `fireproximityprompt(pp)`. Hold prompts: stand in range, `pp:InputHoldBegin()` → `task.wait(pp.HoldDuration + 0.1)` → `pp:InputHoldEnd()` | range (far fires ignored in both games measured: BBB 71 studs, SRS 139), the server's own `Enabled`, then the game's handler | `fireproximityprompt` sends `Triggered` with no `PromptButtonHoldBegan`, the standard server-side flag on hold prompts. Triggering a prompt the *server* disabled is another flag. Client-only gates (camera, LOS, a client script toggling `Enabled`) only block the local fire. |
| 4 | ClickDetector | `fireclickdetector(cd, 0, "MouseHoverEnter")`, then `(cd, 0, "MouseClick")` | the engine's range check isn't dependable (2020 engine bug: the server's `MouseClick` fired past `MaxActivationDistance`), so only the game's own distance check applies | Anti-cheats flag a click with no hover before it. |
| 5 | Touch | `firetouchinterest(hrp, part, 0)`, `task.wait()`, `firetouchinterest(hrp, part, 1)`. The part needs a `TouchInterest` | **no engine range check** (Feb 2025 engine-bug report), so only the game's handler | No `TouchInterest` but it reacts when you walk on it → spatial query or ZonePlus: go there and dwell. `CanTouch = false` = dead pad. |
| 6 | GUI button | `for _, c in getconnections(btn.Activated) do c:Fire() end` (also `MouseButton1Click`), or `firesignal` | whatever the handler's remote checks, so call that remote instead | SRS: a click-sound script connects to every button, so a non-empty list doesn't mean it's wired. Real handlers can bind only once the frame opens. A yield inside a fired handler left the game's lock stuck. |
| 7 | VirtualInputManager | `SendMouseButtonEvent(x, y + GuiInset.Y, 0, down, game, 0)`, `SendKeyEvent` | same as real input | Only reaches the **focused** window (SRS: failed on 5 of 6 clients). The UI must be on-screen. Last resort. |

- Never run IY's fire-all forms (`;firepp`, `;firecd`, `;touchinterests` with no name). They hit every streamed-in buy pad, kill brick, place teleporter and hidden honeypot prompt. The name filter also matches the **parent's** name.
- `;nopplimits` / `;nocdlimits` only raise the client's `MaxActivationDistance`. Server range checks are unchanged.

#### ProximityPrompt rabbit holes
- → **The client handles `Triggered`** (`getconnections(pp.Triggered)` isn't empty and fires a remote) → that remote is rung 1. Its checks are whatever the game wrote, not the prompt's range, so measure far vs near.
- → **A client script keeps disabling the prompt** (camera-facing or LOS gate, §4) and there's no fallback remote → set `cam.CameraType = Scriptable`, `cam.CFrame = CFrame.lookAt(cam.CFrame.Position, part.Position)`, let the game's script enable the prompt, fire it, restore the camera.
  - To find the gate, hook `__newindex` and log writes to `Enabled` where `not checkcaller()`. If no game script writes `Enabled`, the server disabled it: leave it alone.
- → **`Style = Custom`** → the game draws its own UI from `ProximityPromptService.PromptShown`. The prompt still triggers normally.
- → **Nothing triggers locally** → check `ProximityPromptService.Enabled` and `MaxPromptsVisible`. Menus and cutscenes switch prompts off globally.
- → **Several prompts on one part** → pick by `ActionText`/`ObjectText`, never by index. A prompt no player can see (hidden, underground, blank text) is a trap.

#### Getting there: pick the movement rung once per game
- **Use the game's own travel first.** Home, plot and world buttons and portals move you server-side, so its anti-teleport expects the move (SRS `TeleportPlayer:FireServer()` is the Home button).
- **Test a hard teleport, empty-handed and while carrying:** `hrp.CFrame = target` 50+ studs away, wait 2 s, re-read your position. Rubber-band, kick, or lost load (NIH yes, BBB no)? Reactions and the step-size protocol are S7/S8.
  - → Fails → stepped CFrame moves (NIH: 8 studs every 0.06 s kept the load), with step and delay as settings.
  - → Stepped moves also fail (a server speed cap) → walk with `Humanoid:MoveTo` + PathfindingService (IY `;pathfindwalktowp`), or tween at about walk speed.
  - IY's `;tweenspeed` is a **duration** (default 1 s), not a speed: a 1,000-stud `;tgotopart` moves at 1,000 studs/s.
- **After arriving, wait ~0.3 s** before a range-checked call (BBB used 0.35 s; S1: ping + 0.1 s).
- **Unsit first** (`Humanoid.Sit = false`). A seat weld drags the seat along or pins you.
- IY `;gotopart <name>` hard-teleports into *every* part with that exact name in turn (`;gotopartdelay`, default 0.1 s). A quick rubber-band / force-drop test, not a farm.

#### StreamingEnabled: far parts don't exist on your client
- **Detect:** `workspace.StreamingEnabled` (plus `StreamingMinRadius`, default 64, and `StreamingTargetRadius`, default 1024), and folder child counts changing as you move. A far model can render as a low-detail stand-in (`Model.LevelOfDetail`) with none of its parts. The symptom is a farm that decides there's nothing to do.
- **Automate:** before each move:
  1. `LP:RequestStreamAroundAsync(pos, 5)` (the client may call it for LocalPlayer).
  2. `WaitForChild` the target with a timeout.
  3. Act.

  Look targets up again by path or id on every use. A streamed-out part is parented to `nil`, not destroyed, so a cached reference goes stale **without an error**.
  - → A teleport sets `LP.GameplayPaused` (a `StreamingIntegrityMode` pause) → wait for it to clear. It looks like a freeze or a rubber-band, but isn't anti-cheat.
  - → Targets far away and unknown → get positions from the server (a sync remote with ids and positions, config modules, attributes on a persistent model). Failing that, sweep the map once in a grid and save a position file (static maps only).
- **Watch out:** `GetDescendants`, `CollectionService:GetTagged` and every IY fire/goto command only see streamed-in instances. Models with `ModelStreamingMode` `Persistent` / `PersistentPerPlayer` are always present; check whether your plot is one. A teleport into an unloaded area can drop you through missing floor.
- **Verify:** log `#folder:GetChildren()` at home and at the target; they match after the request, and you act only once the target resolves.

#### Plots / bases: ownership per server
- **Detect which plot is yours every session** (it changes per server, §5): an `Owner` ObjectValue, an `OwnerUserId` / `PlotOwnerUserId` attribute (MoD), a player attribute such as `PlotIndex` (BBB), or the owner's name on a sign.
- **Automate:** resolve the plot on join, respawn and rebirth. Wait for a load flag (`Loaded` / `DataLoaded`, or the plot's contents to stop growing) before buying or placing: a plot still loading reads as fresh (S15).
  - → Plots differ in position or rotation → store every spot **relative to the plot**: save `plot:GetPivot():ToObjectSpace(hrp.CFrame)`, use `plot:GetPivot() * rel`. NIH stored its sell spot relative to the vent.
  - → You have to claim a plot → fire the claim remote or prompt once, on an empty plot (`Owner` nil).
  - → You place items → the place remote checks bounds, grid and collisions. Send plot-relative CFrames snapped to the game's grid.
- IY `;partname` (click a part) gives names and paths. `;swp` / `;wp` waypoints are absolute, floored to whole studs and saved per PlaceId: fine for a fixed hub, wrong for your plot on the next server.
- **Verify:** the owner field reads you, and one saved spot lands correctly on two different servers.

#### Tycoon: droppers, conveyors, collectors, touch-pad buttons
- **Detect:** each tycoon has `Buttons` (pads with `Price` and `Dependency`), `PurchasedObjects`, `Owner`, a dropper → conveyor → collector chain, and a collect pad backed by `CurrencyToCollect`. Common kit names; grep the decompile. Economy side: E5/E6.
- **Claim:** touch an unowned tycoon's entrance once (`Owner` empty).
- **Buy:** `firetouchinterest(hrp, button.Head, 0/1)`. There's no engine range check, so try from far away first.
  - → Buttons appear only after their dependency is bought → watch `Buttons.DescendantAdded`, buy in dependency order, save up (§4b).
  - → Skip Robux buttons (a gamepass or product id, or `R$` on the billboard). Touching one opens a real purchase prompt.
- **Income** needs only a touch of the collect pad on a timer.
  - → Drops are unanchored and your client simulates them (`isnetworkowner`) → moving them onto the collector pays at once. Server-owned: moving them does nothing.
- **Watch out:** IY `;touchinterests` only handles pads of class `Part`, so MeshPart and Union buttons are missed. Run without a name, it also touches other players' claim doors.
- **Verify:** the button is gone, money fell by about the price, and the object appeared in `PurchasedObjects`.

#### Zones / areas / worlds behind unlock gates
- **Detect:** barrier walls with price or "LOCKED" billboards, `Zones`/`Areas`/`Worlds` folders, an unlock remote, a current-zone attribute (`Zone`/`Area`/`World`), or a ZonePlus `Zone` module.
- **Automate:** unlock with the game's remote. Travel to each area once through the game's own portal or remote, then move locally inside it.
  - → Entry is a region check (ZonePlus / `GetPartBoundsInBox`) that sets the zone attribute → wait for the attribute before farming. The check polls, so passing through with a teleport may never register.
  - → The server tracks which world you're in → hits and pickups in a world you teleported into yourself may not count. Use the game's travel.
  - → The wall only exists on the client (IY `;noclip` walks through it) → check whether *payouts* inside need the unlock. They usually do, and farming there pays 0.
- **Passive zones** (AFK or training pads): staying there is the input. Park inside, re-enter after every respawn, count reward ticks (E9).
- **Verify:** the zone attribute changes and a reward tick arrives in the new area.

#### Resource nodes: mining, chopping, breakables
- **Detect:** node folders (`Ores`/`Trees`/`Nodes`/`Breakables`) with `Health`, `MaxHealth`, `Tier` or `RequiredLevel`. The tool's LocalScript shows how hits are sent: a remote carrying the node, or a server hitbox (C2).
- **Automate:** prefer the hit remote with the game's own args. Next best: `tool:Activate()` with the tool equipped (`Humanoid:EquipTool`), which runs the game's swing, cooldown and remote.
  - → The tool aims with `Mouse.Target`/`Mouse.Hit` or a camera ray → aim the camera at the node, or `hookmetamethod(game, "__index", …)` to return the node for `Target`/`Hit` when `not checkcaller()`.
  - → Damage comes from a server-side `Handle.Touched` → stand within reach and swing. Swinging faster than the cooldown only loses hits.
  - → The node's `Tier` is above your tool's → skip it (0 damage or a "need better tool" reply).
- **Respawn:** log each node's break-to-reappear time (attribute, `Transparency`, re-parenting) and rotate. Find out whether nodes are per player (rendered on your client) or shared. IY `;partesp <NodeName>` shows the layout through walls.
- **Verify:** `Health` drops per hit and inventory rises; hits per second match a normal player's swing rate.

#### Pickups / drops: coins, orbs, gems
- **Detect** where they live (`workspace.Drops`/`Coins`, or client-only folders like MoD's `workspace.ClientCollectibles`) and what decides the collect:
  - → **A server part with a `TouchInterest`** → touch it (try from far away first) or stand on it.
  - → **A client-side visual plus `Collect:FireServer(id)`** → take the ids from the spawn event (`OnClientEvent`) and fire the collect. The server usually checks your distance to the drop; find the radius by moving closer until it accepts.
  - → **A magnet radius in a config** → often copied into an upvalue at start. In MoD that copy had to be patched through `getgc`; setting `Config.CollectRadius` did nothing. If coins fly to you but currency doesn't rise, the server checks distance: revert.
- **Watch out:** drops locked to their owner for N seconds, drop lifetimes (skip ones about to expire), and the game's own auto-collect pass (mirror it, §1). IY `;gotopart Coin` is a crude hard-teleport sweep, only where hard teleports are safe.
- **Verify:** the currency change per pickup, not the drop disappearing (expiry or another player also removes it).

#### World-anchored stations: egg stands, shops, crafting benches, upgrade machines
- **Detect:** a remote carrying the station's id (`Hatch(eggId, n)`, `Craft(recipe)`) that fires after its prompt or UI, and a range in the config or an attribute (BBB `SignActionRange` 10–12).
- **Automate:** move to the station, fire the remote, keep the prompt as fallback.
  - → Works from anywhere (BBB `CrateRemote "claim"` from 64 studs, SRS cashier from 150+) → skip the trip. Measure it; don't assume.
  - → Range-checked → stand about half the range away on open ground (BBB: 4 studs off a 10–12 range).
  - → The server wants the station's UI "session" open first → open it through its own remote, then buy.
- **Watch out:** Robux options on the same station (a product id that opens a `MarketplaceService` prompt). Filter them out.
- **Verify:** money drops by the cost and inventory rises within the same window.

#### NPC dialogs & quest givers
- **Detect:** a Talk prompt or ClickDetector on the NPC, a dialog tree in a module (`Dialogues`, `Quests`) or sent by the server, and quest progress in attributes or folders.
- **Automate:** log one real conversation start to finish (namecall spy plus `OnClientEvent`; IY `;remotespy`). Replay only the calls that change state: accept, turn in, claim.
  - → Accept or turn-in is ignored unless you talked first → the server keeps a conversation session. Talk (prompt, in range), wait for the dialog event, then accept.
  - → The objective is "talk to X" / "deliver to X" → a position-gated action at X: stream it in, move there, fire the prompt.
  - → A typewriter UI with Continue → skip to the remote it ends in, or fire the button (GUI rung).
- Read the quest configs and prefer quests the farm already feeds (BBB's scrap farm fed `d_scrap`/`w_scrap`; quest table in §8.6).
- **Verify:** the quest state changes on the server (a progress attribute or quest-list event), not just the dialog closing.

#### Minigames the server drives: timing bars, QTEs, fishing, lockpicks
- **Detect:** the server invokes a client callback (`RemoteFunction.OnClientInvoke`, e.g. SRS `SellSneakerAnimFunction`), a needle or bar UI, and a result (band or score) going back to the server.
- **Automate by playing it:** read the UI every frame (the needle's `AbsolutePosition` against the target band) and fire the game's own stop handler at the right moment. In SRS: fire the `StopButton.MouseButton1Down` connections when `Line` overlaps `COLORX_Perfect`.
  - → The target moves each round (SRS: random 30–70 %) → re-read it each round. A fixed delay breaks on round 2.
  - → Never replace `OnClientInvoke` (in SRS that froze the game), and never return a made-up result. The returned band is the one value the server trusts without checking.
- **Verify:** pay per band vs the expected multiplier (SRS: Perfect 1.10 / Good 1.00 / Miss 0.85 × value).

#### Vehicles & mounts
- **Detect:** `VehicleSeat`/`Seat`, a spawn remote, prompt or GUI, `Humanoid.SeatPart` while seated, mount attributes.
- **Automate:** spawn with the game's remote and get in with its prompt or remote. Failing that, touch the seat (`firetouchinterest(hrp, seat, 0)`); the engine seats you unless it's `Disabled` or occupied.
  - → Seated, your client controls the vehicle's physics, so `car:PivotTo(cf)` moves you with it. Some anti-teleports only watch characters on foot; others cap vehicle speed. Test it like the hard teleport.
  - → Pay per distance (FIU tracks `KMs`) → drive a loop at normal speed and compare the stat gain to the path length before trying anything faster.
  - → Delivering by vehicle → find out whether the drop-off checks the vehicle or the driver.
- **Watch out:** unsit before any character teleport. Vehicles despawn when you leave the seat.
- **Verify:** `SeatPart` is set, then pay per trip.

#### Obbies & checkpoints: anti-skip
- **Detect:** numbered checkpoints (`Checkpoints/1..N`, or SpawnLocations with `AllowTeamChangeOnTouch`), `leaderstats.Stage`, the win pad, kill bricks (a `TouchInterest` on `Kill`/`Lava` parts).
- **Automate:** touch checkpoints strictly in order: `firetouchinterest(hrp, cp[n], 0/1)`, wait for `Stage == n`, then move on.
  - → Touching from a distance doesn't change `Stage` → step onto each checkpoint.
  - → A minimum time per stage or max speed → pace to your fastest measured normal run.
  - → Hazards on the route: your client reports your character's touches, so deleting a kill part's `TouchInterest` locally stops them. Spatial-query hazards aren't affected.
- **Watch out:** IY `;touchinterests Checkpoint` fires in instance-tree order, not stage order, so an in-order check rejects most. Win pads usually check `Stage == N` too.
- **Verify:** `Stage` rises by exactly 1 per touch and the win reward arrives.

#### Doors, keys & locked passages
- **Detect:** `Locked`/`RequiredKey` attributes, key Tools in the `Backpack`, door prompts or pads. A door that opens only on your screen is client-side.
- **Automate:** equip the key first (`Humanoid:EquipTool(key)`), then use the door's rung. Servers usually check `Character:FindFirstChild(keyName)`, not the Backpack.
  - → The door is per player or client-side → it only blocks movement. What matters is what the server checks behind it (a zone attribute, reward eligibility).
  - → Keys get used up → they're a currency: add them to the §1 lists and budget them.
  - → The door closes on a timer → finish the trip inside the window or reopen it on the way back.
- **Verify:** the door is open for other players too (server-side), or the thing behind it pays.

#### Carry-and-deliver loops
- **Detect** the carry state: an attribute (NIH `Carrying`), a model inside your character (BBB scrap) or a held Tool. Find the carry cap (BBB: 20).
- **Automate:** fill up, move, dwell at the drop-off, return.
  - → Test the movement rung **while carrying**. NIH force-dropped the load on a hard teleport (carry 8 → 0, no pay); BBB didn't.
  - → Pay depends on position and there's no deposit remote (NIH) → find the exact spot by watching a real deposit. IY `;copypos <player>` works while another player sells, but rounds to whole studs. NIH's spot was *beside* the vent, not on it. Store it relative to the vent or plot.
  - → Deposits tick per piece while in range (BBB: 0.1–0.2 s each) → stay until the carry count is 0, not a fixed time.
  - → Drop/litter remotes don't pay: NIH `DropRequest` was accepted but paid 0, and a drop far from the character was rejected.
- **Watch out:** death, sitting or water can drop the load. A carried item that's its own physics object (a cart, a crate on the ground) doesn't follow a teleport.
- **Verify:** currency change per trip against pieces carried. Never a lifetime counter (NIH's `StrawsMoved` also counted drones).

#### Click-and-hold / repeated-click interactions
- **Detect:** prompts with `HoldDuration > 0`, custom hold bars (a LocalScript fills a bar while input is held, then fires "complete"), "click N times" detectors or buttons, channel attributes.
- **Automate:**
  - → Prompt holds → `InputHoldBegin`, wait `HoldDuration`, `InputHoldEnd`, in range. That sends the genuine `PromptButtonHoldBegan` → `Triggered` pair.
  - → Custom bars → find the start and complete remotes. If the server timestamps start → complete, wait the full time. If it only takes "complete", measure the shortest accepted gap before shortening anything.
  - → Click N times → measure how many clicks per second the server counts. Extras are dropped or flagged.
  - → Channels that moving or damage cancels → don't teleport mid-channel.
- IY `;instantpp` only helps when *you* press the key, and produces exactly the too-short hold timing checks catch.
- **Verify:** the server's completion signal (inventory or currency), not the bar filling.

#### Random world spawns: chests, meteors, bosses, supply drops
- **Detect:** a spawn folder that gains children, an announcement remote carrying a position or zone, or a countdown board (BBB `NextEventBoard`).
- **Automate:** listen for the announcement (remotes reach you anywhere, even with streaming), `RequestStreamAroundAsync(pos)`, move there, use the spawn's rung (usually a hold prompt or shared damage).
  - → No announcement and streaming hides spawns → poll the known spawn points (map them once with IY `;partesp`).
  - → Players compete (first to open wins) → pre-stream the known points and keep the trip short.
  - → Rewards are tiers shared across the server → one join or hit may be enough (BBB Pit: `joined` stayed true after leaving).
- **Verify:** count only reward changes inside the event window (§3, confounded signals).

#### Done when
- [ ] Every action has its rung measured far vs near, judged by the delivery signal, and written in the spec.
- [ ] The movement rung is chosen from a loaded and an empty hard-teleport test (and S8's step search, if needed).
- [ ] Streaming checked; no far target is cached across moves.
- [ ] Plot ownership resolves on join, respawn and rebirth, and one plot-relative spot lands right on two servers.
- [ ] No fire-all IY command and no Robux button is reachable from any farm path.

Engine-behaviour sources: [spoofed touches aren't range-checked (2025)](https://devforum.roblox.com/t/touched-call-a-client-can-use-an-exploit-to-spoof-the-engine-to-think-that-a-part-is-being-touched-on-server-even-if-the-person-is-nowhere-near-it/3448084) · [ClickDetector ignores the server's range (2020)](https://devforum.roblox.com/t/clickdetectormaxactivationdistance-does-not-respect-filteringenabled/570955) · [prompt hold/Enabled detection](https://devforum.roblox.com/t/server-sided-proximity-prompt-exploit-detections/2271600) · [click/hover detection](https://devforum.roblox.com/t/fireclickdetector-and-fireproximityprompt-exploit-detection/2182072) · [sUNC `fireclickdetector`](https://docs.sunc.io/Instances/fireclickdetector/) · [RequestStreamAroundAsync](https://create.roblox.com/docs/reference/engine/classes/Player#RequestStreamAroundAsync)
### 8.5 Server, anti-cheat & infrastructure

#### S1 · If the farm fires remotes → learn what the server validates
- **Detect →** one spec row per remote: **range** (far vs near, §4) · **rate** (fire at 2 / 1 / 0.5 / 0.25 s spacing, count real deliveries) · **cooldown** · **ownership** (your plot's instances only) · **args** (S2) · and the reaction: dropped silently, error reply, or kick.
- **Automate →** every call goes through one fire helper with a per-remote minimum interval.
  - → extra calls are dropped silently → interval = 1.5× the measured floor, scheduled from "now" so a stall never turns into a catch-up burst.
  - → the rate test kicked → that's the ceiling; ship at ≤ ½ of it.
- **Watch out →** a client debounce isn't a server cooldown. Sneaker's "1 s / 5 s" refresh lock was client-side; the remote took 6/6 at 1.5 s.
- **Watch out →** right after a teleport the server may still hold your old position. Wait ≥ ping + 0.1 s (`LP:GetNetworkPing()`, round trip in seconds; IY `;notifyping`) before a range-checked call.
- **Watch out →** `InvokeServer` has no timeout, so a refused or handler-less RemoteFunction hangs the loop forever. Call it in a task with a deadline and log timeouts.
- **Verify →** the heartbeat logs `fired / delivered` per remote; a falling ratio means you hit a limit.

#### S2 · If the server checks call shape → send only what the real client sends
- **Detect →** the spy's GAME-tagged calls (§3) are the whitelist: same remote and verb, arg types, table keys, value ranges (BBB's `open` count is 1..5, so never 6) and preceding calls (a UI-open or prompt event before "buy").
- **Automate →** log the farm's own calls through the same spy (ME tag) and diff signatures (remote + arg types + keys). A signature the GAME side never produced is a flag risk.
  - → the game fires a remote when its UI opens or closes (`"view"`, `"openUi"`) → fire it too, in the same order.
  - → an arg changes on every call (a counter, a hash-like key) → it's a nonce. Call through the game's live network module (found with `getgc(true)`; a fresh `require` can be a separate copy that restarts the counter), then check in the spy that the sequence stays valid.
- **Watch out →** floats where the UI sends ints, extra or missing args, other players' instances, states the UI can't reach (buying with the shop closed), and metronome timing (exactly 1.000 s for hours; add ±20 % jitter).
- **Verify →** the signature diff is empty after a 30-minute run.

#### S3 · If some remotes have no client caller → treat them as honeypots
- **Detect →** list every `RemoteEvent` / `RemoteFunction` / `UnreliableRemoteEvent` and find each one's client callers: grep the decompile for its name and scan `getgc(true)` function constants (`debug.getconstants`). Sneaker's `BanEvent` scan found 0 holders.
- **Mitigate →** zero client callers plus a tempting name (Give / Add / Money / Admin / Dev / Test / Ban) means never fire it. BBB left `AdminRemote` and `ShopRemote "devBuy"` alone.
- **Automate →** the fire helper refuses any remote + verb that isn't on a whitelist built from GAME-side spy traces.
- **Watch out →** spy buttons that re-fire or block calls, "fire every remote" scripts, and remotes created at runtime under random names (admin frameworks such as Adonis). Spamming a remote with no server handler also prints `Remote event invocation queue exhausted for <path>` in the server's output.
- **Verify →** the farm's whitelist ⊆ remotes the GAME side was seen firing.

#### S4 · If the game ships a client-side anti-cheat → find out what it does when it trips
- **Detect →** grep the decompile for `:Kick(`, `GetPropertyChangedSignal("WalkSpeed")` (and `JumpPower`, `HipHeight`), `Gravity`, `LogService` / `MessageOut`, `ScriptContext`, `gcinfo` / `collectgarbage("count")`, `CoreGui`, `debug.info`, `getfenv`, `Idled`. Sort each hit: kicks locally, reports through a remote, or answers a heartbeat.
  - → only kicks locally → hook `Kick` yourself (`__namecall` with self == LP, plus `hookfunction` for `LP.Kick(LP)`): block it **and log** the reason, `debug.traceback()` and `getcallingscript()`, which tells you what tripped it. IY `;antikick` blocks the same kicks but logs nothing, and server kicks get through either way.
  - → reports through a remote → don't block the remote (the server may expect that traffic). Stop doing what trips it, e.g. leave `WalkSpeed` alone.
  - → answers a heartbeat (an `OnClientInvoke` callback, or a periodic ping the script replies to) → never destroy or disable that script or `:Disable()` its connections. The server kicks when the answers stop, often many seconds later, which hides the cause.
- **Verify →** a 30-minute farm run with the logging Kick hook shows 0 blocked kicks.

#### S5 · If you get disconnected → read the code before reacting
- **Detect →** on `GuiService.ErrorMessageChanged`, read `GuiService:GetErrorCode()` (`Enum.ConnectionError`) and the message. Scripts keep running behind the prompt, so `writefile` the code, message, `JobId`, `PlaceVersion` and the farm's last 20 actions to `kick_<UserId>.txt`.
- **Codes →** **267** a game script kicked you (server or LocalScript; if your S4 hook didn't see it, it was the server) · **268** "unexpected client behavior" = Roblox's engine anti-tamper, not the game · **273** the same account joined somewhere else · **274** the dev shut the servers down (usually an update, S18) · **277** connection lost · **278** idle 20 min (S13 failed) · **286** removed from a private server · **288** server shut down · **600** on (re)join = Ban API ban · **772 / 773 / 774** teleport target full / unauthorized / flooded.
- **Watch out →** a server kick's reason text is written by the dev. Log it verbatim; it's often the only statement of which check you hit.
- **Verify →** `LP:Kick("test")` from your own script (your hook lets `checkcaller()` calls through) writes the file.

#### S6 · If you want auto-rejoin → only for disconnects that aren't about you
- **IY `;autorejoin`** runs `;rejoin` on **any** error prompt. With other players present that's `TeleportToPlaceInstance` into the **same JobId** (alone: a self-kick, then `Teleport`). No code filter, no backoff, it can fail after a shutdown (that JobId is gone), and it doesn't reload your farm (`;keepiy` re-queues only IY).
- **Automate →** branch on S5's code: 274 / 277 / 278 / 288 → rejoin with backoff (30 s → 5 min, at most ~6 per hour) · 267 → pause, read the reason, then join a *different* server · 268 / 600 → stop.
- **Watch out →** rejoining the server that just kicked you, again and again, is the loudest signal a farm can send.
- **Watch out →** arm `queue_on_teleport` (or autoexec, S10) before the rejoin, and act only after the data-loaded gate (S15). A rejoin after an update can open a popup that holds a UI-state gate (§8.6 *popups*).
- **Verify →** a forced 267 test lands in a new JobId, and the log shows the farm resuming.

#### S7 · If moving the character gets punished → identify the check and its reaction
- **Typical checks →** the server samples the HRP every Heartbeat or every ~1 s and compares the distance with `WalkSpeed` + a tolerance (a common DevForum pattern is `WalkSpeed + 3` studs per 1 s window). It raycasts old → new position for noclip, and checks ground distance over time for fly.
- **Detect the reaction →** poll the HRP for 1–2 s after each move: snapped back near the origin = rubber-band · carry count → 0 = force-drop (NIH) · the character ignores input = the server took network ownership (`isnetworkowner(hrp)`) · death or respawn · kick · or nothing visible (a silent flag for a later ban wave is still possible).
  - → hard teleports are punished → step-move and measure the step (S8).
  - → you got snapped back → stand still 3–5 s before moving again; some checks keep snapping you back until you stop.
  - → every CFrame change is undone, even 1 stud → server-authoritative movement: Roblox Server Authority (`workspace.AuthorityMode` = `Server`; RobloxScriptSecurity, so pcall-read it or infer it from this test) or a custom controller. Only input moves you (`VirtualInputManager` key presses, the game's `InputAction`s), so every position gate becomes a walk.
- **Watch out →** `LP.GameplayPaused == true` is a streaming pause (§8.4), not a rubber-band.
- **Verify →** 20 round trips carrying items, with snaps and drops logged per trip → 0.

#### S8 · If you have to step-move → measure the max safe step
- **Protocol (on an alt) →** hold the delay at 0.1 s and try 4 → 8 → 16 → 32-stud steps over a 100+ stud path, 3 loaded runs each, judged by S7's signal. Then binary-search between the last pass and the first fail.
- **Classify the check →** repeat at the same speed with half the step and half the delay.
  - → passes → a per-jump check: tune the step. NIH kept its load at 8 studs / 0.06 s ≈ 130 studs/s, about 8× default walk speed, so its check can't be a walk-speed window.
  - → fails → a speed window: the real cap is ≈ `WalkSpeed` + tolerance, so just walk (`Humanoid:MoveTo` along `PathfindingService` waypoints).
  - → small steps still flagged → you're crossing walls (noclip raycast) or rising through the air (fly check; falling is usually tolerated) → step between pathfinding waypoints and hug the floor (floor + 3).
- **Watch out →** the server only receives your position at the network send rate, so steps under ~0.05 s apart can merge into one bigger jump. Measure at the delay and FPS you'll ship (S20).
- **Automate →** ship at ~60 % of the measured max, as sliders (NIH: step 8, delay 0.06 s). On the first snap or drop, halve the step and log it.
- **Verify →** 20 loaded round trips at the shipped values with 0 drops; re-run after every game update (S18).

#### S9 · If the game has StreamingEnabled → §8.4 *StreamingEnabled*

#### S10 · If the game spans several places (lobby → match, sub-places)
- **Detect →** `AssetService:GetGamePlacesAsync()` lists the universe's places (it works from the client); grep the decompile for `Teleport`, `TeleportAsync`, `ReserveServer`, `PlaceId ==`. Log `PlaceId`, `GameId`, `JobId`, `PrivateServerId`, `PrivateServerOwnerId` and `TeleportService:GetLocalPlayerTeleportData()` on every load. Each place has its own scripts and remotes: decompile each (C8).
- **Automate →** one loader gated on `game.GameId` that dispatches on `PlaceId` (lobby logic vs match logic). Queue through the game's pad or remote; use the solo-start remote where there is one.
- **Survive teleports →** `queue_on_teleport` is one-shot: the queued run must queue itself again, and queuing twice starts two farms (guard with a `getgenv()` flag or unload hook). `getgenv()` is wiped on teleport, so settings and run state live in a file. Potassium's `autoexec` folder, where the bridge loader and IY already live, also covers crashes and manual relaunches; that's only safe because every default is off (§5).
- **Watch out →** reserved match servers (`PrivateServerId ~= ""`, `PrivateServerOwnerId == 0`) can't be rejoined by JobId; recovery means going back to the lobby. IY `;antiteleport` blocks only LocalScript teleports (same-place rejoins still pass); a server `TeleportAsync`, which most lobby → match and soft-shutdown flows use, can't be blocked. On `TeleportInitFailed`, retry with backoff.
- **Watch out →** the Potassium PID changes after every hop (§5b). Rewards granted as you leave arrive after the hop, so check them on the other side.
- **Verify →** a lobby → match → lobby round trip, with the log showing each PlaceId and the farm resuming.

#### S11 · If you need to server-hop → one API call per hop
- **Measured (Fix It Up) →** `games.roblox.com/v1/games/{place}/servers/Public` returned 429 on the 3rd call within ~4 s. Retrying while limited kept it limited; ~40 s of silence cleared it. `game:HttpGet` hides the 429, so use `request` and read `StatusCode`.
- **Automate →** one fetch per hop (`sortOrder=Asc|Desc&excludeFullGames=true&limit=100`). Cache the page to a file and walk its candidates across hops, keep visited JobIds with a TTL, and on 429 go silent 60 s → 300 s.
- **Pick →** rows carry `playing`, `maxPlayers`, `ping` and `fps` but no player list (`playerTokens` is empty), so who's inside is only visible after joining. Skip low-fps servers; remotes and physics run slow there.
- **Watch out →** `TeleportInitFailed` with `GameFull` → next candidate; `Flooded` → too many teleports, back off. IY `;serverhop` is one `HttpGet` (a 429 shows up as "Couldn't find a server"), a random pick and no visited list, so it bounces between the same few servers.
- **Watch out →** every hop costs session state (S14) and risks unsaved progress (S15).
- **Verify →** 10 hops in a row, each logging its HTTP code, with no two fetches less than 10 s apart.

#### S12 · If private or reserved servers exist
- **Detect →** `game.PrivateServerId ~= ""` means a private server: `PrivateServerOwnerId ~= 0` is someone's VIP server (removal shows as 286), `== 0` is a reserved one (matches, soft shutdowns).
- **Watch out →** grep the decompile for `PrivateServerId` / `VIPServer`. Games often switch off events, leaderboards, trading or some rewards in private servers, so compare one event cycle's payout before moving the farm there.
- **Upside →** no strangers or staff by default, and no competition for shared spawns or PvP.
- **Watch out →** hops, auto-rejoin and IY `;serverhop` only reach public servers. Getting back takes the private server's link and an external relaunch.
- **Verify →** the payout log from one full cycle in a private server vs a public one.

#### S13 · If the game kicks idle players
- **Engine →** `LP.Idled` fires ~2 min after the last input, then every 30 s; Roblox disconnects at 20 min (code 278). Fix: on `Idled`, `VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new())` (BBB). IY `;antiafk` instead disables every `Idled` connection via `getconnections` and clicks with `VirtualInputManager`.
  - → first list the sources in `getconnections(LP.Idled)`. A game LocalScript there means the game has its own AFK logic (reports to the server, pauses rewards, moves you to an AFK zone). IY's blanket disable silences that too; know it before relying on it.
  - → AFK judged server-side (no movement or remotes for N min → kick, AFK tag, rewards stop) → client clicks never reach the server. Do a real action every few minutes: a short walk, a jump, or a harmless remote the game itself fires.
  - → some games **pay** for AFK (an AFK zone or world); compare that with the active farm (E9).
- **Verify →** 45 min unattended with no 278, and playtime or AFK-gated rewards still ticking in the log.

#### S14 · If progress lives only as long as the session
- **Detect →** diff a rejoin like a rebirth (§2): snapshot `LP:GetAttributes()`, leaderstats and every `"sync"` payload, rejoin, snapshot again, diff.
- **Typical resets →** luck bars (BBB `garage.luckSeconds` → 0; a full bar is worth about +2 fabricator levels), playtime tiers and `elapsed`, event `joined` flags, server boosts other players bought, friends-on-server multipliers, some cooldowns.
- **Automate →** give every voluntary hop or rejoin a cost (the session value it throws away) and a minimum session length. Claim every ready playtime tier before a planned hop.
  - → something resets in your favour (a tier you can claim again every session; still open for BBB) → rejoin-farming may pay, but only once S15 says the gains are saved.
- **Verify →** a "resets on rejoin: yes / no" column for every value in the spec.

#### S15 · If you leave soon after a gain → saves can roll back; if you act too soon after a join → you act on defaults
- **How games save →** on leave plus an autosave. ProfileService autosaves every 30 s; ProfileStore every 300 s, and a new server that finds the old session lock retries every 10 s and steals it after ~40 s, so a fast rejoin can wait that long at the load gate. Hand-rolled DataStore code often saves only on leave or shutdown. `ReplicaRemoteEvents` on the client hints at ProfileService/ProfileStore (both Mad Studio).
- **Failure modes →** a crash or shutdown loses everything since the last autosave · games without session locking can load stale data on a fast rejoin and later overwrite the newer save · until the new server loads your data, the client shows defaults (0 money, nothing owned), and a farm will happily act on them. **Zeros mean "not loaded", not "fresh account":** a junk filter run before the builds sync sees nothing equipped and marks everything as junk.
- **Detect the load gate →** a flag the client waits on (BBB `PlayerGui` attr `Loading`, `RewardRemote "sync"` `loaded=true`; elsewhere `DataLoaded` / `Loaded` / `ProfileLoaded`, a "Saving…" label), leaderstats that appear with defaults first, a loading screen. Leaderstats existing isn't enough.
- **Measure →** make one distinctive change (a cheap level, a rare item), leave or `;serverhop` at once, check it stuck; repeat after 30 s and after 5 min. If a fast hop rolls it back, the game has no session lock.
- **Automate →** no action until the gate fires. After a big gain (rebirth, rare drop, big purchase), hold voluntary hops for one autosave period. Auto-rejoin into a still-locked profile can hang or get kicked again: back off 40–60 s between tries. After a shutdown notice (BBB `"SERVER RESTART IN 5 MINUTES — YOUR PROGRESS IS SAVED"`), no rebirths or big spends until the new server has loaded you.
- **Verify →** the marker results are in the spec; the load-gate time is logged on every join, and the E1 state dump from before a hop diffs clean against the one after.

#### S16 · If staff or admins might join → watch the player list yourself
- **IY `;staffwatch`** only works in group-owned games (`game.CreatorType == Enum.CreatorType.Group`). It matches each player's role in the creator group against mod / admin / staff / dev / founder / owner / manager / director…, plus Roblox employees (group 1200769), and only notifies. `;rolewatch <group> <role>` needs the exact role name, and `;rolewatchleave` self-kicks on a match. (`;unrolewatch` is wired to that leave toggle, not to stop; use `;rolewatchstop`.)
- **Misses →** user-owned games (check `UserId == game.CreatorId`), role names without those words ("Tester", "Contributor", "Helper"), moderators from an admin system's own rank list (HD Admin, Adonis, Kohl's), and spectators: admin spectating only moves the watcher's own camera, so nothing reaches you.
- **Automate →** your own `PlayerAdded` watcher: `GetRankInGroup(game.CreatorId)` ≥ the lowest staff rank (read the ranks once from `groups.roblox.com/v1/groups/{id}/roles`) or a UserId list. On a hit, pause teleports and non-routine remotes, log it, and hop only after a delay; leaving the instant staff joins is a pattern too. Your name next to "hack" / "exploit" / "report" in chat (`TextChatService.MessageReceived`) is worth a pause as well.
- **Watch out →** watchers can't be detected reliably, so the farm has to look legitimate even when nothing fires.
- **Verify →** put an alt's UserId on the list, join with it, and confirm the pause and the log line.

#### S17 · If admins can start events live → §8.6 *Admin-triggered events*
Log every `AttributeChanged` on `workspace`, `ReplicatedStorage`, `Lighting` and `LP` for a whole session to find them. Compare `*EndsAt` with `workspace:GetServerTimeNow()`, never the PC's `os.time()`.

#### S18 · If the farm runs unattended for hours (beyond §5b), or the game updates
- **Heartbeat line →** time · `PlaceId` · `JobId` · `game.PlaceVersion` · ping · fps · `Stats:GetTotalMemoryUsageMb()`. A new JobId means a rejoin happened; a new PlaceVersion means the dev shipped an update.
  - → PlaceVersion differs from the one the spec was verified on → safe mode (no spending, no teleports, claims only) until the S2 signature diff and the S3 whitelist pass again. Updates rename remotes and add checks.
  - → at load, check that every remote, config key and sync field the farm uses still exists. Disable and log only the features whose check fails; never run blind on a renamed remote.
- **Update signals →** the update log's dates give the cadence (BBB `UpdateLogConfig`: launch Sep 10, updates Sep 12, 13, 17, 25); "SERVER RESTARTING" messages and soft-shutdown teleports; version constants (BBB's `SOCIAL_PROMPT_VERSION` is part of every social flag like `Social2_like`, so a bump re-opens them all; `UpdateLog_<n>` is marked seen once per version). Updates bring a fresh update-log popup (§8.6), may rename quest ids, and often line up with admin events. After each one, diff the new decompile of `ReplicatedStorage.Shared` against the last and rerun the §1 sweep.
- **Survive restarts →** autoexec or `queue_on_teleport` re-runs the farm; `autorj` alone doesn't.
- **IY in `autoexec`** is `loadstring(game:HttpGet(<GitHub>))` on every join: the same hang risk as the Obsidian fetch (§5b). Vendor it and `readfile` it.
- **External watchdog →** a scheduled task on the PC. A heartbeat file older than 3 min means the client is dead, kicked or jammed → alert, or relaunch with a `roblox://placeId=…&gameInstanceId=…` link (the format IY `;jobid` copies).
- **In-game watchdog →** every loop stamps `lastProgress`; a separate thread restarts a loop stuck for N min (`task.cancel`, then respawn) and logs it.
- **Verify →** kill the Roblox process mid-run; the watchdog notices within 3 min.

#### S19 · If you use IY, remote spies or other tools → they're detectable too
- **Your output is readable →** game LocalScripts can read `LogService.MessageOut` / `GetLogHistory()`, including every `print`, `warn` and error from your scripts. Log to files, `pcall` loop bodies, and never print anything identifying.
- **IY's GUI** goes into `gethui()` when present (otherwise CoreGui via `protect_gui`). Since Release 686 game scripts get `nil` for `CoreGui`, which killed the `PreloadAsync(CoreGui)` asset scan. **Chat is not private, though:** IY runs `;commands` typed in chat by reading your own message from `TextChatService.MessageReceived`, so the message has already gone to the server and its chat logs. Drive IY through its command bar only (the BBB farm's `iy()` helper does).
- **Hooks →** `;antikick`, `;antiteleport` and the remote spies (`;simplespy`, `;remotespy`) install a global `__namecall` hook that every script's method call passes through; the changed timing and error behaviour are the fingerprints. Keep spies to recon sessions. The farm listens passively (`OnClientEvent`) and hooks only what it must.
- **Memory spikes →** `gcinfo()` / `collectgarbage("count")` jumps are a known injection heuristic. Decompiling everything, `getgc(true)` scans, Dex and `saveinstance` are the loudest things you do; do them on an alt (S20 says what that protects).
- **Verify →** grep AC-looking scripts for `LogService`, `MessageOut`, `gcinfo`, `collectgarbage`, `CoreGui` and `TextChatService`, and note in the spec which vectors this game actually watches.

#### S20 · If you run several accounts or clients
- **Per-client state →** all clients share one Potassium workspace, so suffix every file with the account (the existing `*_<name>.txt` pattern), keep one SaveManager config per account (two clients autosaving one config fight), and address bridge calls to one client/PID.
- **Friends-on-server multipliers** (BBB: +10 % per friend on the server) need the alts to be Roblox friends **and** in the same JobId (`TeleportToPlaceInstance(PlaceId, jobId)` from a shared file). Server-wide totals (BBB Pit tiers) reward stacking; shared spawns (scrap cap 12) and PvP (alts' bots KO each other in the Pit) cut the other way. Decide per farm.
- **Watch out →** the same account in two clients: 273 evicts the older one.
- **Ban radius →** the Ban API extends a ban to suspected alt accounts by default (`ExcludeAltAccounts = false`) and can cover the whole universe. An alt shields the main from kicks and in-game flags, not from a game ban.
- **CPU →** IY `;norender` and `setfpscap(15)` on background clients. Then re-measure S8's step timing at that FPS.
- **Verify →** N clients, N heartbeat files ticking, and the multiplier visible in the game's boost sync.

#### Done when
- [ ] Every remote the farm fires has a spec row (range, rate, cooldown, ownership, args, reaction), and the farm's signatures ⊆ GAME-side signatures (S1–S3).
- [ ] Client anti-cheat scripts are sorted (local kick / report / heartbeat), and a logging Kick hook ran 30 min with 0 blocks (S4).
- [ ] Disconnects are logged with their code, and auto-rejoin branches on it with backoff (S5/S6).
- [ ] The movement rung survived 20 loaded round trips (S7/S8).
- [ ] The load gate is known and nothing acts before it; rollback markers measured (S15).
- [ ] The heartbeat carries JobId and PlaceVersion, and a version change drops the farm into safe mode (S18).
- [ ] Multi-client runs have per-account files and configs (S20).

Sources: [IY source](https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source) · [ConnectionError codes](https://robloxapi.github.io/ref/enum/ConnectionError.html) · [Player API](https://create.roblox.com/docs/reference/engine/classes/Player) · [Instance streaming](https://create.roblox.com/docs/workspace/streaming) · [Server authority](https://create.roblox.com/docs/projects/server-authority) · [Ban API & alt detection](https://devforum.roblox.com/t/introducing-the-ban-api-and-alt-account-detection/3039740) · [ProfileService](https://github.com/MadStudioRoblox/ProfileService/blob/master/ProfileService.lua) · [ProfileStore](https://madstudioroblox.github.io/ProfileStore/) · [ReplicaService](https://github.com/MadStudioRoblox/ReplicaService) · [Magnitude anti-teleport pattern](https://devforum.roblox.com/t/can-i-improve-this-server-side-anti-exploit-magnitude-checker/2020510) · [Bait remotes](https://devforum.roblox.com/t/are-making-bait-remote-events-for-exploiters-worth-the-trouble/1529696) · [CoreGui/PreloadAsync change](https://devforum.roblox.com/t/coregui-preloadasync-and-exploiters/4010695) · [Remote queue exhausted](https://devforum.roblox.com/t/remote-event-invocation-queue-exhausted-for-remoteevent-did-you-forget-to-implement-onserverevent/2394939)
### 8.6 Time-based, social & meta

Every system here is a clock, a counter or other players. Before automating any of them:

- **Sweep once.**
  - Grep the decompile with `grep -i -E "daily|weekly|quest|playtime|streak|offline|code|redeem|group|friend|guild|clan|season|pass|spin|wheel|gift|achiev|badge|leaderboard|trade|market|auction|mail|admin|announce|restock|merchant|afk|idle"`.
  - Dump `GetAttributes()` on `workspace`, `ReplicatedStorage`, `LocalPlayer` and `PlayerGui`.
  - Log every remote's verbs (`request` / `sync` / `claim*` / `redeem*`) for 10 min.
- **Name each timer's clock.** There are three kinds:
  - **Session:** resets on rejoin (BBB playtime `elapsed`, the luck bar).
  - **Calendar:** a UTC day or week key (BBB quests, daily login, guild ladders).
  - **Server uptime:** `FIRST_DELAY` + `INTERVAL` (BBB Titan, Alien Raid) — but see *Scheduled events*.
  - A rejoin or hop resets session clocks, re-rolls uptime clocks and drops on-server boosts (friends, guild mates). IY `autorj` after a kick counts as a rejoin. Only calendar clocks survive.
- **Take time from the server.** Use the payload's `…In` countdowns (`dailyIn`, `endsIn`), or compare `…At` stamps against `workspace:GetServerTimeNow()`. Never a UI label or the client's `os.time()`.
- **Claim like a transaction.**
  - Fire one claim and wait for the reply (BBB `claimed` / `refused`). Re-`request`, then fire the next.
  - No reply: stop and log, don't re-fire. Games throttle (BBB guild `ACTION_COOLDOWN = 0.6`).
  - Run a claim sweep ~60 s before every reset boundary and before every rebirth.
- **Show the clocks.** Status lists each timer's next boundary and each claim's last result, so a missed claim shows in the log alone.
- **Read and claim; don't socialize.** Joining or leaving groups and guilds, friending, inviting, trading and chatting are visible, often irreversible, and the player's call. The farm reports what's missing ("not in group: −20 % money") and leaves the action to the player.

#### Daily & weekly quests
- **Detect:** `QuestRemote "sync"` → `{daily = {{id, name, goal, progress, claimed}}, weekly, dailyIn, weeklyIn}`. The pool and goals sit in a shared config (BBB `QuestConfig`: 10 dailies and 8 weeklies; 4 + 3 are drawn).
- **Automate:** claim when `progress >= goal and not claimed` (BBB `QuestRemote "claim", id`). The pushed `"complete"` is a free trigger.
- → **Map every quest's metric to a farm feature** (a table in the spec). In BBB:
  - `d_crates`, `d_collect`, `d_play`, `d_waves`, `d_money` and `d_scrap` ride on existing features.
  - `d_kills` needs "stay whole event", not join-and-leave.
  - `d_pit` needs PvP wins. It sat at 1/5 all session.
  - `d_stations` stalls while a level cap or the workshop save-up blocks station levels.
  - → **A quest needs a behavior change** → a per-quest "chase" toggle that switches mode only until that quest completes. Price it: the reward vs the faucet time lost.
    - → **It needs PvP wins** → skip it, reroll it, or fight main vs alt in a private server. That's win-trading, and games that log opponents flag it.
  - → **Rerolls exist** (`"reroll", slot`, free daily or paid) → reroll only quests the farm can't do that are under 50 % done.
- → **The rotation is a seeded shuffle in a shared module** (BBB `QuestConfig.pick(pool, n, seed)`, day key UTC `os.date("!%Y-%m-%d")`) → call it in-game with candidate seeds (`dayKey`, `userId .. dayKey`) until one reproduces today's sync. Tomorrow's set is then known.
- **Watch out:**
  - Scaled goals move. BBB `d_money` = 60K × (rebirths + 1), and it went 300K → 360K after a mid-day rebirth. Claim before rebirthing.
  - BBB weeks count from 1 January (`(yday - 1) // 7`), not from Monday.
- **Verify:** a whole day's log shows every farmable quest claimed before `dailyIn` hit 0.

#### Playtime & session rewards
- **Detect:** a tier table (BBB `RewardConfig.PLAYTIME`: 1 · 5 · 10 · 15 · 20 · 30 · 45 · 60 · 90 · 120 min) and the sync `playtime = {claimed, elapsed}`. Offline pay on join is E9.
- **Automate:** claim a tier once `elapsed + (os.clock() - syncAt) >= minutes · 60` (BBB `claimPlaytime, i`).
- → **Classify it with one `;rj`:** note `claimed` and `elapsed`, rejoin, then `request`.
  - BBB so far: `elapsed` tracks the session luck clock to 0.1 s. Whether `claimed` resets is still open (spec §6).
  - → **Both reset** → a session ladder. Rejoin-farming the early tiers works, but a rejoin also throws away session perks (BBB's full luck bar = +2 fabricator levels of odds).
  - → **Only `elapsed` resets** → every kick or `autorj` costs progress toward the next tier. A rejoin gains nothing.
  - → **Nothing resets** → a calendar ladder, and rejoins are free.
- → **The game tracks idleness** (an `AFK` attribute or tag, a "YOU ARE AFK" overlay, an activity-ping remote) → send the minimum signal it reads. `;antiafk` only stops Roblox's 20-minute kick (S13).
- **Verify:** 30 input-free minutes still move `w_play` / `d_play` by 30.

#### Daily login streak
- **Detect:** the sync `daily = {claimable, day, streak}` and an N-day table (BBB `RewardConfig.DAILY`: 7 days; day 7 = 20K + Galaxy + 3 Golden + 2 h of 2× money).
- **Automate:** claim when `claimable` (BBB `RewardRemote "claimDaily"`, works from anywhere). BBB's own client re-`request`s every `REFRESH_SECONDS` (30), so a running farm sees the day flip without a rejoin.
- → **Calendar reset (UTC key)** → claimable ~30 s after 00:00 UTC. A 24/7 farm needs nothing more.
- → **Rolling 24 h since the last claim** → the claim time creeps later every day.
  - → **A grace window (e.g. 48 h) and the account isn't always on** → schedule a daily join inside it (Task Scheduler + autoexec).
- **Watch out:** does day 7 wrap to day 1 or hold? That decides what a broken streak costs. `day` ≠ `streak`; BBB sends both. A `DAILY_VERSION` bump can reset the ladder.
- **Verify:** the log shows `claimDaily` within a minute of the boundary; Status shows "streak N · next HH:MM UTC".

#### Timed boosts & consumables → E10 (stacking test, mode-matched use)

#### Scheduled events
- **Detect the clock source:**
  - a board (BBB `workspace.NextEventBoard`: `NEXT EVENT | <NAME> | IN m:ss`);
  - attributes (`NextEventAt` / `EndsAt`, unix, compared against `GetServerTimeNow()`);
  - remotes (`"start"` / `"state"` / `"end"` / `"rewards"`);
  - config (`FIRST_DELAY` + `INTERVAL`, or `os.time() % CYCLE`).
- → **`FIRST_DELAY` + `INTERVAL`** usually means a **server-uptime clock**: each server runs its own phase. Re-read the board after every hop; a hopper can pick a server whose wanted event starts within a minute.
  - → **But log real start times before scheduling around config constants.** BBB's `AlienShipConfig` says `FIRST_DELAY = 390`, `INTERVAL = 600`, `DURATION = 240`, yet one server's raids started at 20:54:39, 22:14:39 and 22:54:39: **every 2400 s**, 4 × `INTERVAL`, with none at the 600 s marks between. The server's loop adds rules the client config doesn't show (here probably a rotation of four events). Two consecutive starts give you the real period. The client can't read server uptime either: `workspace.DistributedGameTime` counts from *your* join, not the server's start.
- → **`os.time()`-based** ("every hour at :00") → a global clock. Schedule by wall clock; hopping gains nothing.
- **Join rules:**
  - Find the minimum that pays: a `joined` flag, one hit, N seconds in the zone, or a damage share.
  - Find the entry gates: zone at start, late-join lockout, level or rebirth gate, ticket cost.
  - → **Pays on server totals** (BBB tiers) → join, then leave. Alts on the server raise the totals for everyone.
  - → **Pays on personal share** (`myKills`, damage %) → stay, and price that against the main faucet (C7).
- **Watch out:** overlapping events need a priority list. Payouts scale with your multipliers, so re-measure an event before writing it off.
- **Verify:** the predicted start matches the real `start` within seconds, on two different servers.

#### Admin-triggered events
- **Detect:** workspace attributes (BBB `Admin<Luck|Coins|Energy>Mult` plus `…StartsAt` / `…EndsAt`, and `AdminEventBy`); drops (`AdminDropAt` / `Crate` / `Amount` / `By`); banners (`AdminRemote "announce"`) and system chat; "ADMIN ABUSE" UI.
- **Automate:** `GetAttributeChangedSignal` switches into event mode until `EndsAt`. In BBB: CRATE LUCK → open held Lava+ crates; COINS → bias to the Depths; ENERGY → park at the plot.
- → **Scope test:** local (an attribute on one server) or global (MessagingService)? Check an alt on another server at that moment.
  - → **Local** → it happens where an admin is. The hot server is the watched one.
  - → **Global** → nothing to hunt.
- **Watch out:** an admin event means an admin is present. Use `;staffwatch` / `;rolewatch <group> <role>` or your own watcher (S16), and add a setting "during admin events: normal / remote-only (no teleports) / pause". `AdminEventBy` names the admin.
- **Verify:** log each flip with its values, then check the effect (the Lava+ share of crates opened during luck vs outside it).

#### Limited-time shops & event currencies
- **Detect:** a stock sync (`restockIn`, `stock`, `rotation`); a merchant model appearing (`workspace.ChildAdded`, a `LeavesAt` attribute); an `os.time() // ROTATION` seed in config; "RESTOCK IN" / "LEAVES IN" / "LIMITED" / "SOLD OUT"; event currencies with an end date (E2).
- **Automate:** buy on each restock from a wishlist (item or rarity, with a max price).
  - → **Seeded rotation** → precompute it and log "next wanted item at HH:MM" (E15).
  - → **Server-wide stock** → a race, so fire as the restock lands. Per-player stock is no rush.
- **Watch out:** wishlist buys still obey the save-up priorities (§4b). Robux rows sit next to currency rows; use `;noprompts`.
- **Verify:** log the stock over a few rotations. A seeded prediction must match before you trust it.

#### Codes
- **Detect:** client-visible tables (BBB `RewardConfig.CODES`); update-log text (BBB `UpdateLogConfig`: "codes (try BUILDABOT)"); `StringValue`s; the game description via `MarketplaceService:GetProductInfo(game.PlaceId).Description`.
- **Automate:** "Redeem all known" fires each code once (BBB `RewardRemote "redeemCode", code`) and logs the reply (BBB `"code" {ok, message, reward}`). Redeemed codes go in a workspace JSON so reloads don't re-fire them.
- → **The client has only a textbox** (the list is server-side) → the sources are the description, the update log and off-platform posts. Re-read the description every session; like-goal codes show up later.
- **Watch out:** case, expiry, one use per account, level or group requirements, and redeem cooldowns. Stop at the first "too fast".
- **Verify:** the delta matches `reward`. "Invalid" and "expired" are logged, never retried.

#### Group & social rewards
- **Detect:** a group config (BBB `RewardConfig.GROUP`: permanent +20 % money and energy, plus a Golden crate); the sync `group = {id, inGroup, claimed}`; calls to `GroupService:PromptJoinAsync`, `AvatarEditorService:PromptSetFavorite`, `SocialService:PromptGameInvite`; LIKE / FAVORITE / JOIN / FOLLOW rows.
- → **Verified row** (the server checks membership) → joining is the player's step; the farm reports the missing boost. `IsInGroup` is cached from join: re-check through the game's remote (BBB `RewardRemote "joinedGroup"`) or rejoin, then claim (BBB `"claimGroup"`).
- → **Honor-system row** (a game can't read likes) → the button only sets a flag (BBB `setSetting "Social2_like", true`), and BBB's gift wants all four rows. A one-time click for the player, not a farm feature.
- → **Group or VIP chests and doors** → they check membership on touch. Same fix, then run the §4 input tests.
- **Watch out:** Premium-only perks (`MembershipType`) are out of reach. Note them and move on.
- **Verify:** `inGroup` and `claimed` flip, and a `source = "Group"` row appears in the boost sync.

#### Spin wheels, free gifts & chests
- **Detect:** `Spin` / `Wheel` / `Gift` remotes (often a RemoteFunction that returns the slot; the wheel only animates the server's roll); `FreeSpins` / `NextSpinAt` attributes and "FREE SPIN IN" labels; map chests (`TouchInterest` / `ProximityPrompt` / `ClickDetector`) with a cooldown label.
- **Automate:** spin when `FreeSpins > 0` or `GetServerTimeNow() >= NextSpinAt`, without opening the UI. If the server refuses a spin without the UI, fire the button's own handler via `getconnections(btn.Activated)`.
  - → **Chests** → the §4 far-vs-near test with `firetouchinterest` / `fireproximityprompt` / `fireclickdetector` (input ladder, §8.4), or `;firetouchinterests <name>`.
- **Watch out:** "SPIN ×10" and "2× LUCK" Robux buttons sit beside the free one; use `;noprompts`. Spins often come from playtime or quests.
- **Verify:** the spin count drops by 1, and the reward delta matches the returned slot.

#### Battle / season passes
- **Detect:** a pass sync (e.g. `SeasonRemote "sync"` → `{xp, tier, claimed, premium, endsAt}`); a tier-XP table; "SEASON ENDS IN" with FREE / PREMIUM rows.
- **Automate:** claim free-track tiers as they unlock. Log the XP sources; usually that's quests, which doubles their value.
  - → **The player owns premium** (an attribute or `UserOwnsGamePassAsync`) → claim both tracks.
  - → **They don't** → never fire premium claims. The server refuses them and may log it.
- **Watch out:** unclaimed tiers can vanish at `endsAt`, so sweep on the last day. Tier skips cost Robux. A new season can reset XP boosts.
- **Verify:** `tier` and the claimed flags advance, and nothing is left claimable after the last-day sweep.

#### Achievements & badges
- **Detect:** an achievements config or remote (tiered goals 100 / 1K / 10K, a claim per tier); `BadgeService`, which pays nothing in-game unless a config maps badges to rewards. Collection indexes are §8.2.
- **Automate:** sweep everything claimable once, then claim on each sync.
- → **Use the list as a coverage check.** Every ladder names a system. One the farm never touches (fusing, rerolling, trading) is missing from §1's lists.
- **Watch out:** social and purchase achievements stay manual.
- **Verify:** nothing is left claimable after the sweep.

#### Guilds / clans
- **Detect:** `GuildRemote "sync"` and `GuildConfig`. The BBB sync carries `day` / `week` ladders `{progress, myShare, claimable, endsIn}`, `boost = {level, percent, mates}`, and members with `daily` / `weekly` / `online`.
- **Automate:** claim each period when `claimable > 0` (BBB `GuildRemote "claim", {period = "day" | "week"}` paid 60K + Void for the day, 40K + Void for the week). Keep feeding the ladder metric (BBB `WEEKLY_METRIC = "depthsWaves"`).
- → **Tiers need a personal share** (BBB `DAILY_MIN_SHARE 2`, `DAILY_SHARE_FRACTION 0.04`; UI "NEED n WAVES" / "CLEAR YOUR SHARE FIRST") → a member who doesn't contribute can't claim, so alts must farm the metric too.
- → **The boost counts mates on this server** (BBB: 5 % each up to 5, plus 1 % per guild level; 3 mates = 16 %, measured) → a hop loses it, so guild-mate alts belong on the main's server.
- → **Not in a guild** → creating one (BBB 10K) or joining one is the player's call. Report the missing boost.
- **Watch out:** ladders reset at `endsIn`, so sweep before it. BBB pushes the guild sync every few seconds (207 in 18 min); don't log each push.
- **Verify:** `GuildRemote "claimed" {period, tiers, coins, crates}` arrives for both periods.

#### Leaderboards
- **Detect:** SurfaceGuis with rank rows (OrderedDataStore boards); topbar panels (BBB "THIS SERVER" / "ALL TIME"); board remotes (BBB `GuildRemote "board" {scope = "alltime" | "week"}`); `leaderstats` and replicated per-player data (FiU `PlayerData.Status.*` for every player).
- **Use:** the top rows show what's reachable (best wave, rebirths). Public per-player stats let a hopper pick weak servers (`fiu_hop.lua`).
  - → **The board pays the top N weekly** (a rewards column, a mailbox) → check that the farm can place before optimizing for it.
- **Watch out:** an account climbing a public board draws reports; offer a pace cap. Boards cache and flush late (BBB guild board `LEADERBOARD_CACHE 60`, `FLUSH_INTERVAL 45`). Weekly boards follow the game's own week key.
- **Verify:** your row updates after the cache window, and the pace cap holds over a day.

#### Friend / party boosts & alt accounts
- **Detect:** an attribute or boost row (BBB `FriendsOnServer` × `BoostConfig.FRIEND_PERCENT = 10`, `source = "Friends"`); "FRIEND BOOST" UI; party remotes (`"invite"` / `"accept"`); `;findfriendgroups`, which shows who's friends with whom on the server.
- → **Friends on the same server** (Roblox friends, same JobId) → an alt counts only if it's already the main's friend (friending is the player's step). Move alts in with `TeleportService:TeleportToPlaceInstance(placeId, jobId)`; `;jobid` copies the id. In BBB, an alt that's both friend and guild mate adds +15 % to the main, and the main adds the same to it.
- → **In-game parties** → check whether the boost needs the same server.
- → **Invite or referral ladders** (`PromptGameInvite`, "INVITE n FRIENDS") → they usually count only new accounts joining through the invite. One-time value, and the player's call.
- **Watch out:** caps are common (e.g. +10 %/friend up to 30 %); add alts until the % stops rising. Some games count only active friends. Every alt takes a server slot or plot and must clear the tutorial first (BBB `TutorialActive` holds popups). Account-age gates (`Player.AccountAge`) are common. Funnelling alt loot to the main is the classic ban trigger. Multi-client setup is S20.
- **Verify:** the boost row steps up when the alt joins and back down when it leaves.

#### Trading, markets, auction houses & mail
Inventory safety while a trade is open is §8.2 (*Trading, mail & gifting*). The social side:
- **Detect:** trade, market, auction and mail remotes; "TRADE REQUEST FROM" / "LIST" / "BID" / "INBOX"; a separate trade-hub PlaceId; tradeable flags in the item config.
- **Automate defensively:** auto-decline incoming trade and party requests (their modals stack while AFK, and they're how AFK accounts get worked). Claim-all the mailbox each session; prizes and gifts often land there. Never auto-accept or auto-send.
  - → **The market sync has prices** → an opt-in "list surplus above X" can beat NPC selling (BBB part sales pay a flat value with no multipliers). Mind taxes and listing caps.
- **Watch out:** trade locks on new accounts or items, last-second item swaps, and outbid refunds that arrive by mail.
- **Verify:** an alt's trade request is declined within seconds and leaves no modal; mail claims show up as an inventory delta.

#### Chat-driven mechanics
- **Detect:** `TextChatCommand`s (walk `TextChatService:GetDescendants()` for `PrimaryAlias` / `SecondaryAlias`, e.g. `/claim`, `/code`); system messages (a remote calling `TextChannel:DisplaySystemMessage`) and banners (BBB `AdminRemote "announce"`); trivia and "first to type" events; admin kits (HD Admin, Adonis folders), whose notices go full-screen.
- **Automate: listen, don't talk.** Log `TextChatService.MessageReceived` messages with no `TextSource`, or use `;chatlogs`. Turn "event in 5 minutes" lines into scheduler triggers.
  - → **A mechanic truly needs typing** → `TextChatService.TextChannels.RBXGeneral:SendAsync(text)` (legacy: `DefaultChatSystemChatEvents.SayMessageRequest`), rate-limited and behind an off-by-default toggle.
- **Watch out:** chat is filtered, visible and reportable. An account that answers trivia instantly gets reported. IY commands typed in chat reach the server too (S19).
- **Verify:** the parsed trigger appears in the log before the event's `start`.

#### Game updates & server restarts → S18

#### Screen-blocking popups (they queue up while AFK)
- **Detect the modals:** the offline card, the update log (once per version), the daily popup, level-up and rebirth cutscenes; CoreGui prompts (purchase, group, favorite, invite, RSVP: BBB calls `SocialService:PromptRsvpToEventAsync` 90 s after join, and `AdminRemote "rsvp"` asks again); trade and party invites; admin notices.
- **Detect the gates:** the UI-state attributes these modals wait on and set (BBB `PlayerGui`: `OpenPanel`, `TutorialActive`, `Loading`, `CutsceneHide`, `IntroShowing`).
- **Automate:** close each one the game's own way: the remote its close button fires (BBB offline card `OfflineRemote "seen", stamp`; update log `setSetting "UpdateLog_<n>"`), or `getconnections(closeBtn.Activated)[1]:Fire()`; `;noprompts` for Robux prompts; `;clearerror` / `;antigameplaypaused` for the kick blur and the pause box.
- **Watch out: the farm's own UI-state pauses become permanent stalls.** BBB's update log opens itself on the first join after an update and holds `OpenPanel = "UpdateLog"` until someone clicks X. The farm paused scrap and upgrades while `OpenPanel ~= nil`, so an `autorj` rejoin after an update would have stalled them for good. *Fixed:* a panel open 90 s+ is logged once and ignored. Give every UI-state pause a timeout that ends in dismiss-or-ignore.
  - → **Input-driven farms** (clicks, VirtualInputManager) → any modal eats the clicks. Remote-driven farms only care about the gates they check.
- **Verify:** after a rejoin plus an unattended hour, `OpenPanel` is nil or ignored, no modal blocks input, and the heartbeat shows every loop ticking.

#### Done when
- [ ] Every timer's clock (session / calendar / uptime) and reset boundary is in the spec, one rejoin has been diffed, and scheduled events' real start times are logged.
- [ ] The quest table maps each id → metric → farm feature → AFK-completable. The rest each get a chase setting or a reason to skip.
- [ ] Claim sweeps run before every reset boundary and before every rebirth.
- [ ] Every popup source closes the game's way, and every UI-state pause has a timeout. An unattended hour after a rejoin shows no stall.
- [ ] Admin presence has a setting (normal / remote-only / pause). No social action (join, leave, invite, trade, chat) runs unless the player turned it on.
