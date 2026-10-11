<title>Recon Quickstart</title>

# Recon Quickstart: reverse engineer a new game fast

This is the short runbook. Follow it in order. `game-recon-checklist.md` is the long reference (~70K tokens, too big to read whole). **Never read it top to bottom.** Open only the sections that the routing table in step 6 points you to, using Grep with `-A`.

Output of a recon: `<game>-spec.md` in `%USERPROFILE%\rblx\`, filled from the template in step 7.

---

## 0. Hard rules (each one cost something real)

1. **Never sell, trade, gift, delete, reset or re-equip the user's items or builds.** Test sells only on items the test bought itself. Trades need the user's OK per action. (Fix It Up: user furious. Death Ball: alt banned.)
2. **Scripted inputs at human pace:** ≥300 ms apart, no bursts. Input spam got an alt banned.
3. **Never fire a remote that no client script fires** (`!NOCALLER` in `remotes.txt`), especially names with Admin/Dev/Test/Give/Ban/Money. They're honeypots.
4. **Never send a Robux path:** DevProduct/Gamepass buttons, `PromptProductPurchase`, `devBuy`, premium payment modes.
5. **Never `require`, `tostring` or print a game table with a metatable.** Trap-guarded classes freeze the client (Death Ball). Use `rawget`.
6. **Every recon loop yields** (`task.wait()` every ~25 scripts / 500 instances). Never decompile every script in one go: it crashed Fix It Up.
7. **Don't trust UI text** (reset panels, prices, OWNED cards, cooldown timers). Confirm with server data: attributes, sync payloads, currency deltas.
8. **Write findings into the spec in the same turn**, then run `python %USERPROFILE%\rblx\sync_notes.py --push`. Commit messages are one line, no trailer.

## 1. Tools

- **Bridge:** `mcp__potassium__list_clients`, then `mcp__potassium__execute_script` with `{pid, source}`. Always pass one pid, never `all`.
- **No console.** Scripts write into `%USERPROFILE%\AppData\Local\Potassium\workspace\`. Read the files there with Read/Grep.
- **Ping first** to detect a jammed queue:
  ```lua
  writefile("ping.txt", tostring(os.time()))
  ```
  If `ping.txt` doesn't update within ~5 s, the queue is jammed. Ask the user to re-attach (rejoin + attach). Don't keep sending.
- **Run a workspace file with a compile check:**
  ```lua
  local f, e = loadstring(readfile("recon.lua")) if not f then writefile("err.txt", e) else f(1) end
  ```
- **Deploy:** copy `%USERPROFILE%\rblx\recon.lua` into the Potassium workspace folder first. The copy is the one `readfile` sees.
- **Several clients:** identify yours with a probe that writes `probe_<UserId>.txt`, then use that pid.
- **Bridge down (ECONNREFUSED)** → tell the user and stop. Recon can't continue without it.

## 2. Static dump: `recon.lua` step 1

Run `f(1)`. Poll `recon_<PlaceId>/status_1.txt` until it says `done` or `ERROR …`. Then read:

| File | Look for |
|---|---|
| `info.txt` | PlaceId/GameId/PlaceVersion, `PLACE` lines (sub-places = separate dumps), `PATTR`/`GUIATTR`/`WATTR` attributes (state, perks `Perk_*`/`Pass_*`, admin multipliers, `Loading`/`OpenPanel` gates), `PVAL` values (leaderstats, PlayerData) |
| `tree.txt` | framework (Knit `Services`, `ReplicaRemoteEvents`, a remotes folder), config modules, workspace folders (Plots, Mobs, Drops, Zones) |
| `remotes.txt` | every remote and the scripts that reference it. `!NOCALLER` = honeypot candidate (rule 3) |

## 3. Decompile: step 2

- Run `f(2)` for everything in ReplicatedStorage plus the player's LocalScripts. It does at most 300 per run and is resumable: if status says `paused`, run it again.
- For a narrow pass, pass a name filter: `f(2, "Shop")`.
- Files land in `recon_<PlaceId>/src/`. Grep them locally:

```
Grep pattern="cost|price|reward|mult|percent|rebirth" path=<src> output_mode=files_with_matches        # configs
Grep pattern="rebirth|requiredWave|needRebirths|LOCKED|REACH|REQUIRE|unlock" -i path=<src>             # gates
Grep pattern="\"[^\"]*AUTO" path=<src>                                                                 # built-in automation (use it, don't rebuild it)
Grep pattern="setSetting|Perk_|Pass_|UserOwnsGamePassAsync" path=<src>                                # settings and passes
Grep pattern=":Kick\(|GetPropertyChangedSignal\(\"WalkSpeed|LogService|gcinfo|debug\.info|AntiCheat" path=<src>   # anti-cheat (step 6, S4)
Grep pattern="daily|weekly|quest|playtime|code|redeem|group|guild|event" -i path=<src> output_mode=files_with_matches
```

## 4. Live spy: step 3

- Run `f(3, 120)`, then **ask the user to play normally for 2 minutes**: buy something, collect, rebirth if they can, open each menu.
- Read `spy.txt`:
  - `GAME` lines are the exact argument shapes the real client sends. These are the only shapes the farm may send.
  - `ME` lines are your own calls.
  - `IN` lines are server → client payloads. Look for `"sync"` tables, which carry the whole state.
  - `ATTR` lines are state changes.
- The user's own clicks show up as GAME. Before concluding "X works", match each call to what the user did.

## 5. Rebirth / rejoin diff: step "snap"

1. Run `f("snap", "before")`.
2. Have the user rebirth (or rejoin).
3. Run `f("snap", "after")`.
4. Diff the two files.

**The reset panel lies.** In BBB, stations, workshop and scrapper were all wiped and the panel didn't say so. Note which values reset and what the fresh BUY state of each purchasable looks like.

## 6. Routing: open only the checklist sections this game has

Read a section with `Grep pattern="<heading>" path=%USERPROFILE%\rblx\game-recon-checklist.md -A 25`. Raise `-A` if the section continues past the output.

| If the game has… | Grep heading |
|---|---|
| any economy (always) | `#### E1 ·` |
| several currencies | `#### E2 ·` |
| big or abbreviated numbers | `#### E3 ·` |
| multipliers / boosts | `#### E4 ·`, `#### E10 ·` |
| upgrade levels, skill tree, tycoon buttons | `#### E5 ·` |
| income piling up until collected | `#### E6 ·` |
| unlock gates | `#### E7 ·` |
| rebirth / prestige | `#### E8 ·`, `## 2. Run a full reset` |
| offline / AFK earnings | `#### E9 ·`, `#### S13 ·` |
| gamepasses | `#### E11 ·` |
| spending choices | `#### E12 ·`, `## 4b.` |
| sell / exchange | `#### E14 ·` |
| rotations / restocks / dailies | `#### E15 ·`, `#### Daily & weekly quests` |
| inventory, pets, eggs, crates | `### 8.2` → its `####` headings (open call, odds, equip, locks, inventory cap) |
| mobs, bosses, waves, dungeons, PvP | `#### C1 ·` … `#### C14 ·` (C2 hit path and C3 gate matrix first) |
| prompts, clicks, touches | `#### The input ladder` |
| teleports / movement checks | `#### Getting there`, `#### S7 ·`, `#### S8 ·` |
| StreamingEnabled = true | `#### StreamingEnabled` |
| plots / bases / tycoon | `#### Plots / bases`, `#### Tycoon` |
| carry-and-deliver | `#### Carry-and-deliver loops` |
| minigames / QTEs | `#### Minigames the server drives` |
| vehicles | `#### Vehicles & mounts` |
| anti-cheat hits in step 3's grep | `#### S4 ·`, `#### S19 ·` |
| several places | `#### S10 ·` |
| server hopping | `#### S11 ·`, `#### S14 ·`, `#### S15 ·` |
| events / admin events | `#### Scheduled events`, `#### Admin-triggered events` |
| popups / panels | `#### Screen-blocking popups` |
| faking GUI clicks | `## 4d.`, and the Death Ball notes under `#### S3 ·` |

## 7. Spec template (`<game>-spec.md`)

Fill in every heading. Write `none found (grep: …)` instead of leaving one empty. Mark each fact as **measured** or **read from code**.

```markdown
# <Game> spec
PlaceId · GameId · PlaceVersion verified on · framework (Knit/Replica/custom) · StreamingEnabled
## State source
where money/levels/inventory live (attr / sync remote / PlayerData / getgc) + load gate
## Currencies
| currency | faucet | sink | survives rebirth? | Robux-buyable? |
## Sinks
| sink | remote + GAME arg shape | cost formula (config fn) | fresh BUY / UPGRADE / MAX states seen? |
## Farms
| farm | actor (unit / character / timer) | remote or input rung | rate measured | runs in parallel with |
## Gates
| gate | stat it reads | re-closes on rebirth? |
## Built-in automation
| game setting / pass | free? | farm mirrors or replaces it |
## Rebirth diff
what reset (from snap diff), what the panel claims, rebuild order
## Remotes
| remote | verb/args (GAME) | range far/near | rate floor | reaction to bad call | honeypot? |
## Anti-cheat / risks
kicks, reports, heartbeats, trap classes, movement checks, staff
## Timers & claims
quests, dailies, playtime, events: clock type (session/calendar/uptime) + claim remote
## Open questions
what still needs a live test, and who has to do it
```

## 8. Stop and hand back to the user when

- The bridge is jammed or down.
- The next test would spend real currency, sell, trade, rebirth, or touch the user's builds. Ask first and say what it costs.
- The game has trap-guarded classes, obfuscated buffers or a heartbeat anti-cheat. Write what you found into the spec and recommend a stronger model for the farm itself.
- A test needs over-the-limit rates (C3/S1/S8). Those runs go on an alt, with the user's OK.

## 9. Done when

- [ ] The spec template is filled in; every empty section says what was grepped.
- [ ] Every remote the farm will use has a GAME-tagged arg shape from `spy.txt`.
- [ ] The rebirth (or rejoin) snap diff is recorded.
- [ ] Built-in AUTO features are listed.
- [ ] `!NOCALLER` remotes are listed as off-limits.
- [ ] Notes are pushed (`sync_notes.py --push`), and any new reusable lesson is added to `game-recon-checklist.md` under the right section.
