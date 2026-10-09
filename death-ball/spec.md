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

## Aim (verified 2026-10-08)
- `PlayerScripts.LocalCamLookReplicator.CamLookReplicator` fires `ReplicatedStorage.ReplicateCamLook(lookX, lookY, lookZ, serverTime)` every Stepped at 60 Hz while `PlayerControl.isInGame`. The server sends your deflect toward where the camera looks.
- `ReplicatedFirst.Classes.MouseReplicator` raycasts the mouse (500 studs, excludes FX/camera/char) and sends `Remotes.ReplicateMouse(pos)` (20 Hz, only while an ability asks for it) — ability aim.
- Test: `BindToRenderStep(Last+50)` setting `Camera.CFrame = lookAt(cam, targetHRP)` for 0.3 s, F pressed 1–2 frames later → ball's next `Target` was the aimed player **4/4**. When Extend-o Arm fired first, the ball went elsewhere (the move deflects with its own timing/aim).

## Champions and moves (`DataBins.ChampionData` / `AbilityData`)
- Inventory: `EquippedChampions[1]` = champion GUID → `Champions[guid]` {Type, Level, XP, Abilities = chosen option per slot}. Slot i is key `i` (Ability1..4 = One..Four). A move unlocks at **champion** level ≥ `AbilityData[name].LevelRequirement`.
- `AbilityData[name]`: Cooldown, ActiveTime, LevelRequirement, Range, and `HoverData` tags: AutoDeflect, Movement, Passive, CreatesCollidables, Untargetable, ExtraHealth, FaceoffDisabled.
- Champions (slot1 | slot2 | slot3 | slot4, gem price):
  - Lufus (50): Extend-o Arm | Gum Gum Balloon | Glass Wall | Time Haki
  - Gazo (500): Fake Ball | Phase Dash | Blindfold/Cursed Blue | Astral Portal
  - Saito (500): Upper Cut | Super Jump | Sonic Slide | Ground Walls/Aftershock
  - Foxuro (20k): Ninja Run | Shadow Clone | Tree Jump | Fox Armour
  - Kameki (20k): Dragon Rush | Instant Travel | Ki Blast | Death Ball
  - Keilo (20k): Zap Freeze/Zap Deflect | Godspeed | Assassin Invisibility | Lightning Intercept
  - Koju (20k): Leap Strike | Spirit Wall | Chain Spear | Handgun
  - Senshu (20k): Egoist Warp | Charged Kick | Yellow Card | Juggling Blast
  - Torokai (20k): Activate Fire | Ice Slide | Ice Zone | Ice Shield
  - Denjin (50k): Jet Dash | Gravity Hold | Orbital Cannon | Overheat
  - Gloom (50k): Shadow Rampage | Dark Reversal | Dread Sphere | Phantom Grasp
  - Jiro (50k): Bomb Jump | Bonk | Side Step | Bungee
  - Dr (100k): Juice Up | Sentry Gun | Tank | Stone Freeze
  - Friera (100k): Sky Glide | Mana Shot | Runeguard | Singularity
  - JJ (100k): Phantom Slap | Revenge | Fist Barrage | Standoff
  - Misaki (100k): Scout Hook | Titan's Spear/Spear Storm | Titan Rush | Thunderfall
  - Wu (100k): Dagger Dash | Blink | Rulers Hold | Arise
  - Gemtoki (special): Gem Hunt | Double or Nothing | Cash Out | Donate
- Selected cooldowns (s) / unlock level: Extend-o Arm 25/0 (AutoDeflect, measured: deflects the ball from ~0.7–1.2 s out), Gum Gum Balloon 25/5 (Movement+Passive, measured: speed bursts to 70), Glass Wall 35/50, Time Haki 30/90, Assassin Invisibility 35/50 (Untargetable), Fox Armour 80/90 (ExtraHealth), Blink 0.3/20, Jet Dash 0.25/0, Handgun 0.4/89, Spear Storm 0.05/101, Singularity 1.25/85. Full list of 76 in AbilityData.
- Script "Smart" rule: AutoDeflect → "Save me" (fire when F is on cooldown and tti < 1.1 s); Untargetable/ExtraHealth → "When targeted" (tti < 1.5 s); pure Movement → off; everything else → on cooldown.

## Real player movement (measured 2026-10-08, Classic, 7 players × ~2 min at 10 Hz)
| stat | median |
|---|---|
| time moving (>2 studs/s) | 84 % |
| walk speed | 25 (WalkSpeed); boosts 40; dash spikes 170–230 |
| samples above 45 studs/s (dash) | 1 % (range 0–8.5 %) |
| jumps | ~0–2 / min (Humanoid states: Running 91 %, Freefall 8 %) |
| heading change > 45° | 37 / min (every ~1.6 s) |
| move burst / stop length | 1.2 s / 0.6 s |
| distance to ball, not targeted / targeted | 86 / 44 studs |
Script "Human" mode: random waypoint inside the map Floor (15–70 % of half-size), ≥ 0.6 × band from the ball, segments 0.6–2.5 s, 30 % chance of a 0.25–0.95 s stop, dash (Q) chance per long move, ~2 % jump per segment, WASD from the user pauses it 1.5 s.

## Votes (2026-10-08)
- `Values.GAMEMODE_VOTES` / `MAP_VOTES` are server tallies only (no per-player record). `GAMEMODE_VOTING_ACTIVE`, `MAP_VOTING_ACTIVE`, `AVAILABLE_GAMEMODES` {Gamemodes {Standard "Classic", OneLife "One Life", Team, Randomizer "Cyber Brawl"}, Maps}.
- Pages `PlayerGui.PAGES.GamemodeSelectPage` / `MapSelectPage`: `Content.ListFrame` holds clones (LayoutOrder = mode/map LayoutOrder) whose `ImageButton` fires `Actions.SELECT_GAMEMODE` / `SELECT_MAP`. The chosen one shows `ImageButton.VotedFrame.Visible`. Gamemode page opens only while ready and voting is active (and 20 s after your last vote).
- Copy vote: the host publishes its VotedFrame pick (LayoutOrder + label); alts in the same server click the matching button when it's on screen (not live-tested in a voting phase yet).

## Swarm v2 (2026-10-08)
- host.json `play`: aimMode/aimName (Own, Player, Nearest, Farthest, Random, Not swarm, Swarm, Host), moves (Own/Smart all/Spam all/Off all), moveKind (Own/Off/Human/Follow host/Follow player) + followName/followDist, spread, copyVote, tutorial, stayWithHost; `lock`; `vote`.
- **Lock host + auto add:** while a locked host is online, any account running the hub with role Off becomes Swarm, and an account set to Host is demoted (opt-out file `noauto_<UserId>.txt`).
- Swarm tutorial: alts follow the host's "auto complete tutorial"; "Keep alts in my server" teleports alts (between rounds, ≤ every 30 s) to the host's job, which also pulls fresh accounts in after the tutorial teleport.
- Live 2026-10-08: my main account host (locked), an alt swarm in the same Classic server: alt walked the arena at 25 studs/s with Balloon bursts, used Gum Gum Balloon on cooldown, aimed parries at non-swarm players.
- **Double load guard:** a teleport can start two copies (queue_on_teleport + autoexec/loader). `CruelHubDB_GEN` increments per load; a stale copy unloads itself, names its aim RenderStep binding with its generation, and doesn't reset the newer copy's performance settings.


## Ball flight model (fitted 2026-10-08 on 12 real hits, 592 samples)
- Recorder: an alt with parry OFF logs ball pos/vel/speed + own root every frame while targeted, until the hit. "No HP loss but the ball retargets within 5–13 studs" is also a hit (spawn/i-frame protection); counting those gave 12 approaches.
- The client's own step (`lBall._predictionUpdate`) under-steers vs the server: best fit is **gain 6/s** (×1.25 above speed 500), **no 25-stud snap**, **hit at ~12 studs from the root**, target = your root moving at your current horizontal velocity.
- Mean timing error: straight line 1.54 s (useless on curves), client formula 0.31 s, fitted 0.25 s.
- **Fly-by trap:** a fast ball heading almost at you can sweep past and curve back ~1 s later. A press then burns the 0.7 s block and the cooldown, and the return hits you. Gate: only press on the prediction when the ball closes at ≥ 50 % of its speed or is within 25 studs.
- Decision test (press when predicted tti ≤ 0.45 s): fitted+gate pressed with 0.18–0.62 s left on 11 of 12 approaches (inside the 0.7 s block). The 12th started inside the window.
- Hub lead = timing slider + ping + `_currentInterpolationDelay` (~0.08 s; the drawn ball runs behind the server).

## Clicking in background windows (measured 2026-10-08)
- With 7–8 clients open, VirtualInputManager mouse clicks on a **background** Roblox window do nothing (the click hit the right button, per `GetGuiObjectsAtPosition`, but no reaction). Key events (F, 1–4, Q) still work.
- Game buttons (Prompt CloseButton, summon InputSinker, card SurfaceGui buttons, vote buttons) listen on `InputBegan`/`InputEnded` only (Activated/MouseButton1Click have 0 connections). Firing those connections via `getconnections` with a fake input table `{UserInputType=MouseButton1, UserInputState=Begin/End, Position}` works in the background. The hub does that first and falls back to a VIM click.
- With this, a fresh account (an alt) did the whole tutorial 1→13 by itself and landed in the beginner lobby.

## Frozen local animations (2026-10-08, cause not found)
- Symptom: your own character slides without walk/run animation on your screen; others see you animate normally.
- Animator had 60+ tracks of a bare `Animation` (asset **68645**, parent nil, Length 0, Action priority) replayed ~8×/s. Not caused by F/Q/jump/MoveTo, not reproducible in the lobby with every hub feature on, and it also showed up on an account sitting at tutorial stage 1. Not in any decompiled game script (the id isn't a string constant).
- Hub fix (Misc → Animation fix, default on): every 0.5 s stops tracks of asset 68645 with Length 0 (only that asset: real tracks also have Length 0 while loading) and writes `CruelHub/DeathBall/anim_freeze.txt` with what the hub was doing the first time.

## Swarm v3 (2026-10-08)
- **Auto join (waits for a slot):** host.json carries `slots` = MaxPlayers − players. Alts outside the host's job queue by UserId; only as many alts as there are free slots try (every 8 s at most), the rest show "waiting in line". At slots 0 nobody teleports. Verified: two alts took slots as they opened in a full 10-player Classic server.
- **Personalities:** Average (the measured numbers), Calm, Twitchy, Runner, Camper, Jumper. Auto = one per account from UserId, plus ±15 % jitter on every number from `Random.new(UserId)`. Host toggle forces Auto on alts. Fields: stop chance, stop length, segment length, dash, jump, air dash (jump then Q 0.2–0.35 s later), ball band, arena radius range, AFK scale.
- **Idle (lobby) movement:** walks between `workspace.LobbyWalkToPoints` (16 parts), pauses, AFK spells capped by "Max AFK" (scaled by personality); once ready it wanders inside the ReadyZone.
- **Spacing slider:** local "Distance from swarm" and host "Distance between alts" (8–120 studs, default 25).
- **Coordinated attack:** while the ball is slower than "Pump to speed", the holder passes it to a teammate; above it, to one victim (host picks: a named player, or one random non-swarm player kept until out). Passes go only to teammates ≥ 35 studs away whom the ball needs ≥ 0.75 s to reach (one of the 2 farthest). Closer passes killed alts. With no safe pass it attacks.
- Host performance push FPS cap now 5–240. Copy host parry settings: button + "Keep host parry settings" (publishes timing, ping, close range, delay, clash, prediction).
- Safe boot: `getgenv().CRUELHUB_SAFEBOOT = true` before loading skips the autoload config.
- **Whitelist (host, Swarm Play → Swarm aim):** "Whitelist me" (default on) and a multi-player whitelist. Alts never aim, pass or pick an attack victim that is whitelisted; the host's own aim skips its whitelist too.
- Auto join is toggleable on both sides: host "Auto join (alts join my server)" (Swarm tab → Servers, top) and per alt "Auto join host" (Swarm → Identity, Swarm role). An alt joins only when both are on.

## Real players' shots (recorded 2026-10-09, 110 deflects, Classic, 6 real players)
- Recorder (`db_shots.lua`): on every ball target change, 4 frames later log shooter, new target, ball pos, launch velocity, everyone's positions (server time stamped).
- Launch yaw off the straight line to the new target: median 14°, quartiles 5° / 14° / 26°, 10 % over 70°. Per player: pjWL5 12° mixed sides, jodog101 12° leaning right (53 % right / 27 % left), Sally19348 16°, Alexarudyy 23° wide, azul00000000 10°. The swarm launched dead straight (1–4°), an easy tell.
- Pitch: basically flat (median −0.1°); ~10 % aimed down ~20°; almost no lobs.
- Return to sender 14–50 % per player; nearest target 0–40 %; farthest ~0 %.
- The new target is the player closest to the launch direction only 59/109 times, so the server's pick isn't just "nearest to the look ray" (measured launch is 4 frames in, already bending).

## Targeting styles (hub, 2026-10-09)
- Straight, Curve right, Curve left, Mixer, Wild, Returner, Bully: yaw range, side bias, chance to aim down, and target weights (return to sender / nearest / farthest, rest random). Auto = one per account; host toggle "Different shot style per alt".
- The aim turns the camera onto the target, then rotates it by the style's yaw/pitch. "Log my aims (debug)" writes `CruelHub/DeathBall/aimlog_<name>.txt` (server time, target, yaw, pitch) to join with the recorder.

## Moves desync (2026-10-09)
- Bots fired "On cooldown" moves (e.g. Lufus' passive float) at the same instant: all ready at round start, same cooldown. Now: random 1.5–13.5 s before the first use each round, random extra 0.5–(3 + 0.4·cd) s after every use, and a 12 % chance per 0.1 s check once allowed. Spam interval 0.2–0.6 s.

## Personality traits (2026-10-09)
- 10 base styles (adds Bunny jump 40 %, Dasher dash 50 %, Strafer short twitchy segments, Lazy long stops). Every account then gets its own multiplier exp(U(−0.9, 0.9)) ≈ 0.4×–2.5× on jump, dash, air dash, stop chance and segment lengths (capped), so same-style bots still differ. The Movement tab shows the account's numbers.

## Luau limit hit (2026-10-09)
- "Out of local registers ... exceeded limit 200" at compile: the main chunk had > 200 locals. UI groupbox handles now live in one table `B`. Keep new top-level state in tables, not new locals.
