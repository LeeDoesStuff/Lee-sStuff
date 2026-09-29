# Slayers2 Project

> Slayers 2 (Ouw Productions, Demon Slayer RPG) — web recon done 2026-09-29, spec rblx/slayers2-spec.md; in-game recon script s2_recon.lua ready in Potassium workspace


Slayers 2 recon began 2026-09-29. The user asked to keep it token-efficient and wanted the web searched before the in-game recon.
- Web facts (leveling route, gates at 25/45/65, spins, codes, weapons) and the planned tabs are in `rblx/slayers2-spec.md`.
- `Potassium/workspace/s2_recon.lua` is a one-pass dump: stats, attributes, remotes, RS tree, UI strings, prompts, script keyword hits. It writes `s2_recon.txt`. It hasn't run yet: no client was attached.
- Next steps: run the dump, decompile only the scripts it flags (combat/quest/spin), and answer the spec's open questions.

**Why:** the user knows nothing about the game and wants features, options and redundancies derived from recon.
**How to apply:** follow [game-recon-full-progression](../notes/game-recon-checklist.md) and [potassium-bridge-quirks](../notes/potassium-bridge-quirks.md), and mark facts as [web] or [live] in the spec.
