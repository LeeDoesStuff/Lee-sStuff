# Command An Army Project

> Command An Army (GameId 10258991999) recon — Tutorial place runs an OLDER build, recon the New Player Server (caa_main dump); state = player attributes (JSON, others' replicate too); Remotes.Admin + TesterMenu = honeypots; anti-cheat ships disabled


Started 2026-09-27. The user had never played it and asked for a deep recon of the gameplay loop with many agents, categorized, to maximize the feature set ("make no mistakes"). Spec: `%USERPROFILE%\rblx\command-an-army-spec.md`. Source of truth: Potassium workspace `caa_main\`, which holds the New Player Server decompile plus live dumps (`cfg.txt`, `attrs.txt`, `tree_*.txt`, `spy_live_sample.txt`), `_CONTEXT.md` for agents, and per-system reports in `_sections\`.

- Universe 10258991999, max 12 players. Places: root 101770480176177, "New Player Server (Below LVL 10)" 92949164250558 (PlaceVersion 54, where the user plays now), "Ranked Match" 71653970264206, "Tutorial" 85398883184159.
- **The Tutorial place runs an older, smaller build.** It lacks about 60 scripts and 40 remotes: guilds, ranked, traits, shop, gifts, inventory UI and the anti-cheat. The first workflow ran on it and was stopped and rerun on `caa_main`. The root place's build hasn't been dumped; the user must be level 10+ to get there.
- Player state lives in **LocalPlayer attributes** (Gems, Tickets, luck, UnitsInventory/PlayerClassInventory/MountInventory JSON, Lifetime*, *EndsAt cooldowns). **Other players' attributes replicate too**, which makes them an intel source.
- **Never fire:**
  - `Remotes.Admin.*`: no client reference, so treat them as honeypots.
  - `Remotes.TesterMenu.*`: tester-gated.
- `ClientIntegrityController` ships with `ClientSecurityProtocol.AntiCheatEnabled=false` and its CoreGui-asset and debug.info-timing probes off. A script must check the flag at runtime.
- Movement is validated server-side: `PlayerMovementRequest`, `PlayerMovementState` and `MovementCorrection` handle stamina, sprint and roll.
- A passive spy (`caa_spy.lua`) logs the real client's payloads to `caa_spy_<place>_<job>.txt`. Seen in it: `BannerRequest {Type="Summon",BannerId="Standard",Count=10,SummonKey,RequestId}` and `AscensionRequest {MainCopyId,DuplicateCopyId,RequestId}`.

**Script v1: `%USERPROFILE%\rblx\caa_farm.lua`** (Obsidian, config folder `CommandArmy`, log `CommandArmy/log.txt`). Loader: `loadstring(readfile("caa_farm.lua"))()`. It was built before the recon workflow finished, from shapes I read myself. Loaded clean on 2026-09-27; none of its features have been turned on live yet.

Measured live 2026-09-27:
- `QuestRequest {Type="GetState"}` returns `State.Periods.Daily|Weekly.Quests[]`, each with Id, Goal, Progress, Completed, Claimed and Rewards {XP, Gems}.
- `DailyRewardRequest` returns `State.CanClaim` / `NextClaimAt`, plus `Status="Cooldown"` when not claimable.
- Lobby stations are `workspace.Lobby.Interactable.<Summon|Ascension|Evolve|Quest|Traits|Guild|StarterPack|ExclusivePack>`, each with a ProximityPrompt. `Icons.Like` has "Claim Reward" and `Icons.Event` has "Join Event".
- The game's own lobby teleports: `LobbyMarkerTeleportRequest("Play"|"Upgrade"|"Guild"|"Leaderboard"|"Summon"|"SummonSidebar")`.
- **Banner GetState went unanswered.** No reply came to my requests, and none to the game's own `SummonController` GetState either (its `_pending` held the GUID). That included after `InteractableUIManager.Get():Open("SummonUI")`.
  - Maybe a server throttle. Maybe my first probe's non-GUID `RequestId="probe-1"` wedged the handler.
  - **Always use `HttpService:GenerateGUID(false)` RequestIds.**
  - **Resolved by a rejoin.** After the rejoin, GetState answered within 5 s from anywhere in the lobby with the UI closed: GemCost=50, Available=73, CurrencyKind=Gems, reply keys State/Code/Success/RequestId. **Stations are not range-gated for requests.** v1 now fires summon, ascend and evolve directly; `useStation` is kept but unused.
  - **Auto-ascend worked on its first live run** (2026-09-27 22:00): 27 → 11 units, merged up to A2, no station needed. Every AscensionResponse still said "Invalid Ascension request.", so the reply text is misleading; judge by UnitsInventory. There's a server cooldown ("Please wait before trying to Ascend again") at about 2 s spacing. Auto attack fired 37 times in a match without issues.
  - **The root place (101770480176177, PlaceVersion 7874) has a different build from the New Player Server.** It has 91 remotes; TraitRerollRequest, TroopMotionSnapshot and TroopVisualMotion are missing. The user reached it at level ~10 on 2026-09-27. Its code hasn't been dumped yet.
  - The user restarted because of "issues". Likely causes: the triple-queued spy's lag and the stuck banner.
- The cached banner state holds Pool (TroopId, Stars, Weight, Featured), `VisualizerPool[].OddsByLuckTier` {Normal, Luck, SuperLuck}, `RefreshEndsAt` (rotation) and `Inventory.Available`.
- `fireproximityprompt` on the Summon prompt didn't open the UI. `InteractableUIOpen` stayed false even after `Open()`.
- The spy flooded to 11 MB, mostly PlayerMovementState at ~3 Hz. It had been queued 3×. Next time throttle every S2C channel, not a hand-picked list.

**v1.1 (2026-09-29)**: army actions + ESP rewrite, loaded clean live (root place, in match).
- Army actions copied from TroopHudClient: `TroopStateRequest("Formation1..3")` (client fallback), `RushRequest(flatDir.Unit, groundEndPos)` (max 300 studs, cooldown = troop `RushCooldown`, needs `RushState ~= false`), archer volley = `AimVolleyState(true, pos, 9)` + per still troop `AimArrowFire(troop, AimAttackTick, origin, apex, landing, dist/150)` every AttackInterval for 10 s, then `AimVolleyState(false)`. Only for troops with `AimState == true`. Rush/volley fired live not yet verified — user tests the buttons.
- `TroopControllerInputActive` is client-only and measured **stuck true while idle** (desktop + mobile HUD copies share it). Don't gate on it.
- Troop layout: `workspace.Troops/<UserId>` (player army, no Team attr on folder) or `AI_<Team>_<n>_<id>` (`AIControlled=true`, `Team`, `TroopId`). Logical `Troop_NN` has `VisualProxy` ObjectValue → `Troop_NN_Visual`; alive = `MotionHealth > 0`. Player attrs `CurrentUnitAliveCount/MaxCount` replicate for everyone.
- ESP flicker causes: 31-Highlight engine cap shared with the game's per-hit `HitHighlight`s, and TroopVisualProxyClient strips far troops to their root part. Fix: Highlights only for players; armies = HandleAdornments on the visual root (no cap). Labels pinned to a sticky anchor troop. Measured: 5 highlights, 109 cubes, 146 AI spheres, 0 label anchor switches in 3 s.
- Auto heal spammed 291× in 2 s (IsHealing replicates late); now 3 s local lockout.

See [game-recon-full-progression](../notes/game-recon-checklist.md), [potassium-bridge-quirks](../notes/potassium-bridge-quirks.md).

**v1.2 (2026-09-29)**: Battle tab "AUTO RESPAWN AT CAMP (all-in-one)" toggle (`CFG.campLoop`) turns on death respawn + resupply + walk-to-camp together. Walk-to-camp now follows PathfindingService waypoints (recomputed every 3 s / when stuck, jumps on Jump waypoints, straight MoveTo fallback) instead of a straight line, and keeps walking while the camp is on cooldown. Not tested live yet.

**v1.3 (2026-09-29)**: Battle → "Which unit" now reads the unlocked loadout slots and lists each one's unit (`Slot N · TroopId ★S A2`). "Prefer this unit" + multi-select "Units it may spawn" (none ticked = all) are built from it and rebuilt when the loadout changes. The unlocked-slot count field isn't known yet: the script tries `UnlockedSlots/LoadoutSlots/MaxLoadout/LoadoutSize/MaxEquipped/UnlockedLoadoutSlots/SlotCount` on UnitsInventory and the player, else counts the `Loadout[]` entries. Check live and pin the real field name.
New Spectate tab: camera-only (CameraSubject) on a player's Humanoid or the troop nearest an army's centre; filter All/Enemies/Teammates, optional AI armies, next/previous cycling; holds through deaths/respawns; the dropdowns are excluded from SaveManager. Not tested live yet.
