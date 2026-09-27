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
- Capture the **fresh state of every purchasable**: BUY vs UPGRADE vs MAX. The first farm only ever saw mid-game "UPGRADE" billboards, so it never learned the `ENERGY STATION · BUY · 400` form and couldn't rebuild after a rebirth.
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
- **Watch for confounded signals.** The same resource can arrive from several sources: Alien crates came from raids and from event rewards, so a raid-catch counter reported a catch with no raid running. Only count a change inside the window where your action could have caused it.

## 4. Inputs: test the gate, not just the happy path

- For each action, measure **far vs near**: remote from 30+ studs, remote next to the target, and the prompt. Record which one the server accepts.
- **Client-side gates**: here the game disables a prompt unless the camera faces the sign. `fireproximityprompt` failed intermittently because of it. Prefer the game's own remote fallback, which here was `PlotSignRemote`, the billboard-click path.
- Measure whether teleports are safe for **carried items** (this game: yes; Needle in a Haystack: no).
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
