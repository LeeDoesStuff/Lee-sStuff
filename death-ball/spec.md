# Death Ball — spec (recon 2026-10-08, measured live on Potassium)

GameId **5166944221**. Places (from `ReplicatedStorage.DataBins.GamemodeData`):

| Mode | PlaceId | Notes |
|---|---|---|
| Tutorial | 109661515411512 | 1 player, stages 1–13, ends with teleport to the beginner lobby |
| StandardBeginner "Lobby" | 83678792452277 | where the tutorial sends new accounts; 10 players; lobby + arena in one server |
| Standard "Classic" | 71000936793663 | 10 players, reservable |
| Hub "Death Ball" | 15002061926 | 25 players |
| Pro | 89775940525999 | 2x ball speed |
| Ranked / TeamRanked | 88291399743932 / 100666561668685 | ServerOnly (matchmade) |
| AFK | 137287008696758 | abilities off |
| Raids lobby | 127511272823254 | 30 players |
| Others | Randomizer 86767747022414, Lava 93854473225025, Smash 120016501071969, OneLifeTDM 121088873145157, Trading 119260352090770 |

## Round loop (StandardBeginner, measured)
- Walk into `workspace["New Lobby"].ReadyArea.ReadyZone` (70×32×32 part) → `Values.IS_READY` = true.
- `Values.GAME_STATE`: `Intermission` (INTERMISSION_TIME counts 20→0) → `Waiting` → `Started` → back to `Intermission`.
- At start: `IS_READY` false, `PLAYER_ACTIVE_STATE` true, player attribute `IsInGame` = true. Dead/spectating = `IsInGame` false. You must re-enter the zone every round.
- `PLAYER_HEALTH_CURRENT` 3 in this mode (tutorial MaxHealth 1).
- Results: `Inventory:Get().Statistics` → `Wins:Total`, `Kills:Total`, `Deflects:Total`, `Matches:Total`, `PlayerXP:Total`. `Values.PLAYERS_KILLS_WINS[userId]` = {TotalWins, TotalKills} for the server.
- First real round with auto parry: 22 presses, 0 damage, won (Wins 1, Kills 3, Deflects 21).

`require(ReplicatedStorage.Values)` and `require(ReplicatedFirst.Core.Inventory)` are safe from an executor (used all session, no trap).

## Deflect
- Input: `ReplicatedFirst.Core.Inputs.Deflect` binds **F**, MouseButton1, ButtonR1. Dash Q, Ability 1 = key One.
- Character attribute `isDeflecting` true for **0.7 s** after a press (BallDeflectBlockTime). Cooldown `BallDeflectCooldown` 1.3 (tutorial config).
- `RoundSettings.Configuration` attrs: BallStartSpeed 50, BallMaxSpeed 400, BallSpeedIncreasePerHit 1, Hit1/2/3Speed 130/75/90, BallSpeedReductionOnDamage 30.
- `SharedData`: BALL_INTERP_DELAY 0.048, BALL_PERFECT_PARRY_WINDOW 0.1 (≤300 speed).
- Pressing F via VirtualInputManager when time-to-impact ≤ 0.45 s + ping works: tutorial stages 3→6 and a full real round.

## Ball — ANTI-CHEAT (read this before touching the ball)
`ReplicatedFirst.Classes.lBall` is heavily guarded:
- **Never `require` lBall** (or lBall2 HUD): its returned function checks the caller with `debug.info` and on a bad caller fires `Actions[N]` (report) and starts `while true do end` (freeze).
- The ball object's metatable `__index` checks callers for `Position`/`_last`/`_sPosition` and `C*`/`A*` keys → same trap. `__tostring` on the class, the offset table and the store table → trap. **Only `rawget` ball tables; never `tostring`/print them.**
- The visible ball `Body` (workspace child `Part`, a clone of `Assets.Balls[Type]`, has a Highlight + Trail) has its **position scrambled** at every frame phase (PreSim/Heartbeat/RenderStepped/PreRender all random; PreAnimation is mostly right). Don't read Body.Position for logic.
- Highlight `FillTransparency` 0.2 = ball targets you, 1 = not (still a valid fallback signal).
- Replication folder `ReplicatedStorage.Folder` (renamed BallReplicationFolder): per-ball child folder is re-parented to nil; attrs `_TargetUserId`, `_Speed`, `_Anchored`, `_Radius`, `_GroundHeight`… readable via `getnilinstances()`. Positions arrive bit-packed on a nil-parented RemoteEvent `Action` ("Update", ~60/s).

**Working read (getgc, verified):**
- Ball table: `getgc(true)` table with `rawget(t,"Body")` Instance + `rawget(t,"Id")` + `rawget(t,"interpolatorSpring")`. Plain fields: `Velocity`, `Speed`, `Target` (HumanoidRootPart), `isTargettingLocalPlayer`, `Anchored`, `Radius`, `TargetUserId`.
- Position is stored obfuscated: offset table = gc table with numeric `Position`, `_last`, `_sPosition`; store = gc table whose `[ballId]` is a string of length 9 + (max offset + 24) + 15. Decode: `buffer.fromstring(s:sub(10, #s-15))`, `readf64` ×3 at `offs.Position`.
- getgc scan ≈ 10 ms; rescan when `Values.CURRENT_BALL_ID` changes.

## Tutorial (PlaceId 109661515411512), automated and verified 2026-10-08
Stage = `require(ReplicatedFirst.Core.Inventory):Get().TutorialStage`.
1. PROMPT `PromptFirstTimeChampionClaim` → click its CloseButton; 3 cards appear in `workspace.FX.Model.Card` → click one (WorldToViewportPoint of the card part).
2. Walk to (17.64, 55.33, -122.28) → round starts (stage 3).
3–5. Deflect 3 times (auto parry).
6. "Use Ability! (Press 1)" → key One.
7. Bot round ends by itself.
8. PromptClaimCrystals → CloseButton.
9. Walk to `workspace.Summon["Standard Pack"].SummonPageTutorial` and press E (ProximityPrompt, 20 studs).
11. "Click To Close" summon reveal → click the screen.
12. PromptTutorialComplete → CloseButton → teleports to StandardBeginner (83678792452277).

Clicks: VirtualInputManager mouse events at `AbsolutePosition + AbsoluteSize/2 + GuiInset` (when the ScreenGui doesn't IgnoreGuiInset). Only buttons whose ancestors are all Visible/Enabled (the PROMPT gui holds invisible templates like `PromptDefault`).

## Other notes
- Workspace attrs in the beginner lobby include `GodMode true`, `AbilityNoCooldowns true` (server test flags, not ours).
- `Values.MM_QUEUE_SIZE` {FFA, 1v1} = ranked queue sizes.
- D7RewardGui (7-day free offer) pops on first lobby join; it doesn't block walking.

## Economy and progression (read from `ReplicatedStorage.DataBins`, 2026-10-08)
- **Currencies:** Gems (soft; shop tiers up to 2,000,000), Diamonds (Robux; 1,350 / 2,800 / 5,400 tiers), Crystals (tutorial gives free ones), Champion XP, Player XP.
- **PlayerLevelToXP:** L2 200, L3 420, L5 920, L10 2,520, L20 4,835 (cumulative-ish curve, ~+250/level early). The first won round took a fresh account to level 3 (560 XP).
- **StatisticRewards** pay per stat event, but **only with permit `3PlayersAndPublicGame`** (≥3 players, public server):
  - Kills:Total → 1,500 Gems, 50 PlayerXP, 50 ChampionXP (gems ×0.5 after 1,000,000 gems).
  - Deflects:Total → 5 PlayerXP; AbilityUses 5 PlayerXP / 10 ChampionXP; Top3 10/20; DoubleElim 40/40.
  - Swarm consequence: a private 2-account server earns nothing. Run swarms in public servers with ≥3 players.
- **Quests** (`QuestData`/`QuestPoolData`): pools Beginner (4 quests, no expiry), Daily (2, 24 h), Weekly (3, 7 days), VIP (2). Each is a statistic target like `Deflects:<Champion>`, `Kills:<Champion>`, `AbilityUses:<Champion>`; auto play progresses them, claiming is UI.
- **SessionGiftData:** playtime gifts at 300 s ×1.2, 600 s ×1.5, 1,200 s ×2.
- **Summon banners** (`SummonBannerData`): gem banners cost 50,000–1,500,000 gems per pull; Robux banners (e.g. Arctic: rarity 3 32 %, rarity 4 48 %, rarity 5 finisher/emote 7.5 % each, with pity). Free Standard Pack in the tutorial.
- **Ranked** (`RankedData`): tiers Bronze/Silver/Gold/Diamond/Celestial; modes FFA (solo), 1v1 (5 rounds, retire champion on win), 2v2 (3 rounds, max elo spread 300). Matchmade (ServerOnly); `Values.MM_QUEUE_SIZE`.
- Other systems present (not dug): Battlepass seasons (gift skip 10 tiers), swords (storage +50 for Robux, enchants, ascension, engraving, kill trackers), potions (luck), limited shop, contracts, raids, clans, trading place, titles, sprays, emotes, finishers.

## Script: `deathball.lua` (CruelHub · Death Ball)
- **Parry:** exact reader (getgc + rawget, see Ball section). Presses F when `time-to-impact ≤ timing + ping` or distance ≤ "always parry within"; 0.5 s between normal presses, skipped while `isDeflecting`. Clash spam: every 0.12 s while the ball is yours, within N studs and above speed S. Random delay 0–N ms option.
- **Fallback reader** (no getgc, by design, not live-tested): Body position sampled at PreAnimation with a jump filter, target from Highlight transparency.
- **Auto ready:** MoveTo the ReadyZone whenever not in a round and `IS_READY` is false (jump if stuck).
- **Tutorial:** state machine above, plus "click any visible PROMPT CloseButton".
- **Swarm:** same-PC accounts share `workspace/CruelHub/DeathBall/swarm/`:
  - `role_<UserId>.txt` (Off/Host/Swarm, per account, not in the shared config).
  - `acc_<UserId>.json` heartbeat every 1 s (place, job, inGame, ready, wins, parries, tutorial stage).
  - `host.json` from the Host: `cmds` (last 10, id/kind/args/t), `autoplay` {ready, parry}, `rules`, `perf`.
  - `seen_<UserId>.txt` = last command id run, so a teleporting alt doesn't replay `join`. Commands older than 60 s are ignored.
  - Commands: join (TeleportToPlaceInstance host job), scatter (host fetches one page of public servers and assigns a distinct job per alt), rejoin, mode (send to a place), reset, close.
  - Rules (alts stop parrying = lose): host alive, alive ≤ N, ball speed ≥ S, survived ≥ T s; final 1v1: Always / Never / Not vs host / Not vs swarm.
  - Performance push: FPS cap (setfpscap), 3D rendering off, quality level 1, master volume 0.
  - `queue_on_teleport` re-runs the local `deathball.lua` if present, else the public LuaLoader.
- **Verified live 2026-10-08:** tutorial 1→13 (steps run by hand with the same calls), real round won with 0 damage, hub loads clean, user's own test: host "join" pulled the alt into the host's Classic server and the alt auto-parried (42 presses).
