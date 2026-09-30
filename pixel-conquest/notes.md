# Pixel Conquest Project

> Pixel Conquest (OpenFront.io port) — pc_main.lua v3.x "chess bot" (brain posture/threat/deny, siege, leech, sea-distance, nuke sizing) published; spec has every rule + review


Recon done 2026-09-29. Spec with the full protocol, economy, Money payout and feature plan: rblx/pixel-conquest-spec.md. Decompiled modules are in Potassium/workspace/pc_recon/mod/.
- All actions go through `ConquestNet.Intent:FireServer({t=...})`, and the server is authoritative. The lobby and matches are separate servers (RS attr ConquestRole).
- ConquestCheats/ConquestSim remotes are dev chat relays. Never fire them.
- Persistent Money scales with minutes survived, so the farm should aim to survive long, not win fast.
- pc_recon.lua v1 froze the game: about 2,000 unyielded getscriptbytecode calls plus game:GetDescendants. It now runs in 3 steps and yields every script.

**Why:** the user got freezes and rejoins from the first recon; recon must be light.
**How to apply:** follow [game-recon-full-progression](../notes/game-recon-checklist.md) and [potassium-bridge-quirks](../notes/potassium-bridge-quirks.md); farm = rblx/pc_main.lua (deploy to Potassium workspace); untested parts listed in spec.
- Combat heuristics must follow the game's real loss formula (enemy full army vs attack troops; my defense = troops at home) and never provoke stronger players. v1.1 revenge/nuke spam got the user wrecked (2026-09-29).
- v3.x (2026-09-30) design: one brain (doBrain) reads the position first (posture from pressure with hysteresis, main enemy = threat not size, deny near win bar, troop budget); every feature obeys it. Match reviews use PixelConquest/match_<jobid>.csv + log.txt. Game facts that drive it: troops stored x10, captured buildings kept, opposing attacks cancel 1:1, attacks on same target merge, nukes remove buildings + make land open.
- User prefs: never auto send/accept alliances (renew + block-break yes); window 704x824 on all Obsidian scripts; auto queue off for new users.
