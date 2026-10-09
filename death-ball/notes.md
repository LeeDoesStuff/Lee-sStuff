# Death Ball Project

> Death Ball (GameId 5166944221) — deathball.lua CruelHub hub: exact auto parry via getgc+rawget (lBall is trap-guarded), tutorial auto, file-bus swarm (host/alts); spec deathball-spec.md


Started 2026-10-08. Script `%USERPROFILE%\rblx\deathball.lua` (Obsidian, CruelHub theme). Spec with every measurement: `%USERPROFILE%\rblx\deathball-spec.md`. Deploy copy: Potassium workspace `deathball.lua` (queue_on_teleport prefers it over the public loader).

- **Anti-cheat:** never `require` ReplicatedFirst.Classes.lBall, never tostring/print ball tables or the offset/store tables (trap → report + freeze). Ball Part position is scrambled; real position is decoded from gc tables (spec "Ball" section).
- Auto parry = press F at tti ≤ 0.45 s + ping. Verified: tutorial deflects, a full real round won at 0 damage.
- Tutorial PlaceId 109661515411512, 13 stages, all automated; ends in StandardBeginner 83678792452277.
- Swarm = same-PC file bus in `workspace/CruelHub/DeathBall/swarm/` (role per UserId file, acc heartbeats, host.json commands/rules/perf). User tested it themselves 2026-10-08: my main account Host, an alt Swarm; join + autoplay worked.
- Gem/XP stat rewards need ≥3 players in a public server (permit `3PlayersAndPublicGame`).

- v2 (same day): aim = camera lookAt before F (verified 4/4), per-slot champion moves from AbilityData tags, Human movement from measured real players, copy vote, lock host + auto add, swarm tutorial + keep-in-server. Test pair: my main account host (pid changes), an alt swarm.
- User wants LOTS of swarm features; keep adding ideas, measure moves per champion live before trusting tags.

Open / not verified: copy vote in a real voting phase; Follow modes; Spam/Save me on other champions; fallback reader (no getgc) and scatter/mode/close commands not live-tested; quest claiming, playtime gifts, D7 reward not automated.

See [potassium-bridge-quirks](../notes/potassium-bridge-quirks.md), [game-recon-full-progression](../notes/game-recon-checklist.md), executor-compat-blind.
