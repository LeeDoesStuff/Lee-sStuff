# Trade UI Recon (Pending)

## Goal

Map the visible trade UI for transferring a chosen gem amount from a swarm account to the host. Keep the offer visible and leave final trade confirmation to the user.

## Observations

- The trade inventory has an **Add Item** action. Its selection view includes a **Gems** tile.
- The Gems view shows an available count of `109,100x`, an amount initially at `0`, a slider, minus/plus controls, and an offer-slot count of `0/1`.
- The trade log showed gem amount changes (`11548`, then `5137`), Gems removed, and Phoenix Axe added then removed.
- The user toggled ready/unready while exploring. The screenshots do not show a completed trade or establish the current offer state.
- Chat is disabled by age policy in the shown view.

## Pending

- Map the normal visible interaction from selecting Gems through setting the amount and displaying it in the offer.
- Confirm how the UI indicates each side's current offer and ready state before any manual completion.
- Do not discover or invoke hidden game remotes, automate acceptance, or assume a trade completed from offer-log entries alone.
