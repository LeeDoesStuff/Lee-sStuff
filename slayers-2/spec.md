# Slayers 2 — Spec

Open-world Demon Slayer RPG by Ouw Productions, released 2026-09-19. Status: **web recon only (2026-09-29)**. Nothing below has been checked in-game yet. `[web]` = from guides, `[live]` = measured.

## Known from the web [web]

**Sides:** Slayer (the default) or Demon. The Demon branch opens at level 25: drop Reputation to -40, meet Muzan at night, collect 9 Spider Lilies, capture Dr. Higoshima, then drink Muzan's Blood.

**Currencies / items:** Cash/Wen (quest turn-ins), Spins, Refinement Ore, skill points (skill tree), Reputation (can go negative). Drops: accessories, orbs, costumes, weapons.

**Codes (Sep 2026):** Release26 (100 Wen, 30 Spins, 1 Refinement Ore; requires the Ouw Productions group), SPINS50, SkillTreeReset, BREATHRESET. Expired: EVILARTSPINS, SORRYFORSHUTDOWN.

**Spins:** reroll clan (41 clans; S tier: Kamado, Rengoku, Uzui, Soyama, Shinazugawa, Himejima). What else they roll is still unknown.

**Leveling route (quest NPC → target):**

| Lvl | NPC / area | Target |
|---|---|---|
| 1–7 | Krue, Windy Peak (spawn) | 3 bandits (loop) |
| 7–~20 | Krue → Zuko, Wilderness | Bandit Boss (drops Cutlass + Quick Draw skill), fast repeat |
| 13–26 | Tom, Bamboo Grove | Bear Cubs, Mother Bear boss |
| 26–40 | Chaka | Kaiden's subordinates, then Kaiden |
| 40–60 | Wagwan | guards, then Hoyuzo |

**Gates:**

| Lvl | Unlock |
|---|---|
| 25 | Breathing: pick a style, gather materials, do the training tasks, beat the style's Trainee. Styles: Water, Thunder, Flame, Stone, Sound, Serpent, Insect. |
| 45 | Final Selection (Butterfly Estate, The Sisters); 60 recommended for solo. It is a timed ordered trial: fruit → 5 Lesser Demons → Nichirin Katana → help Rika → Submerged Key → 4 checkpoints → hold camp → Hand Demon → return. Rewards: Ore + Kasugai Crow. |
| 65 | The Forge quest (Blacksmith Togane) |

**Weapons:** four sources — boss drop, Tier 2/3 raid chest, craft at Togane, or Black Market (100k Cash). Raze sells a katana for 500 early on.

**Combat:** 1 = fists, M1 punch, hold F = block, dash.

## Planned feature set (to be confirmed by in-game recon)

| Tab | Features | Settings |
|---|---|---|
| Farm | auto-quest by level (routing table above), mob kill aura / tween-to-mob, auto turn-in, boss farm (Zuko, Mother Bear, Kaiden, Hoyuzo) with respawn wait | target override, height offset, attack mode (M1/skills), block on low HP, HP flee threshold |
| Combat | auto M1, skill rotation, auto block/dash, breathing skill use | skill order, cooldown buffer |
| Progression | auto stat/skill-tree points, auto-equip best weapon, breathing unlock steps, Final Selection runner | point priorities, tree path |
| Spins | clan auto-spin until target list | stop-on list, keep min spins |
| Items | auto pickup drops/chests, auto craft (Togane), Black Market buy | rarity filter, cash floor |
| Raids | auto join/clear raid tiers, chest open | tier pick |
| Misc | code redeem, ESP (bosses/NPC/players/items), teleports (NPCs/areas), anti-AFK, server hop (boss hunting) | — |
| Status | log, uptime, level/cash/hour | SaveManager autoload |

**Redundancies to build in:** quest-state resync from the server (not local counters), respawn/death recovery, stuck-target timeout, boss-despawn fallback to the regular quest, re-hook on HUD rebuild, newest-copy-wins loader token.

## Open questions for in-game recon

- Remote layout: is combat server-validated (range / cooldown / animation)? Does a far M1 register?
- Anti-cheat: teleport/tween speed limits, kick strings.
- Where state lives: player attributes vs a data folder vs a sync remote.
- Quest accept/turn-in remotes, and whether they are distance-gated.
- What a spin rolls, and the spin remote.
- Death penalty. Is there any rebirth/prestige past lvl 60?
- Built-in auto features and gamepasses (check before building our own).
- Day/night cycle (Muzan night-only, demon sun damage?).
