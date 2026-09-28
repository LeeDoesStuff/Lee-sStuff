# Hit The Thrift Project

> Hit The Thrift (place 122454884469606) recon — MRKET is the Ropop laptop in your own 500k apartment; Craig pays full value only to $1M, then 20%; spec hit-the-thrift-spec.md


Started 2026-09-27. The user's first question was where **MRKET** is. They typed "MRKT" and corrected it; the game spells it MRKET. Spec: `%USERPROFILE%\rblx\hit-the-thrift-spec.md`. No farm yet; run [game-recon-full-progression](../notes/game-recon-checklist.md) before building one.

- MRKET isn't a map spot or a phone app. It's the **Ropop laptop inside your own apartment**.
  - Apartments unlock server-side. When they do, the poster on the thrift's 3rd floor gets an orange highlight.
  - An apartment costs 500k. Then you open a MRKET account, whose store name is permanent.
  - Offers come in through phone Messages. You pack the order at the apartment station and deliver it to the buyer NPC.
- **Craig's wallet cap:** full value up to $1M, then 20% of the rest. Detergents push a tool's `Value` far past the catalog `Resale`, and the user carries Legendary pieces worth over $6M, so selling those to Craig loses most of their value. MRKET's Legendary rate is x1.25.
- State on 2026-09-27: apartments were unlocked for the user but not bought, and they had about 637k.
- **`%USERPROFILE%\rblx\thrift_esp.lua`** (Obsidian, config folder `ThriftESP`; the name stayed so the loader didn't change). Deploy by copying it to the Potassium workspace; the loader is `loadstring(readfile("thrift_esp.lua"))()`.
  - v1 rack ESP: items are the children of parts with `Main=true` that carry `ItemKey`. Defaults: Rare and up shown, outline from Epic, Finds list from Legendary.
  - v2 (2026-09-27, the user asked for these): a **Matcha tab** (auto buy + collect at Kat by teleporting there and back) and a **Laundry tab** (auto buy picked pods on restock; auto pop bubbles). A spending reserve sits in Settings.
  - All three were verified live with one small real buy each. Bubbles were only tested with a fake button; a real wash is untested.
- User pattern: they asked for features mid-build ("add a category for matcha", then laundry). Each system gets its own tab.
- Decompiled sources: Potassium workspace `thrift_src_*.lua`.

See [potassium-bridge-quirks](../notes/potassium-bridge-quirks.md).
