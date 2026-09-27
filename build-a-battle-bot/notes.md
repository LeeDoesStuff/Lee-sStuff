# Battle Bot Project

> Build A Battle Bot (Roblox) — bbb_farm.lua auto farm + bbb-spec.md; remote-first game, plot signs range-gated, rebirth wipes stations+workshop


Game "Build A Battle Bot", PlaceId 106382692972340, GameId 10765666801. Ground truth is `%USERPROFILE%\rblx\bbb-spec.md`, measured live. Farm script is `%USERPROFILE%\rblx\bbb_farm.lua`, deployed as `%USERPROFILE%\AppData\Local\Potassium\workspace\bbb_farm.lua` and loaded with `loadstring(readfile("bbb_farm.lua"))()`. Obsidian UI, SaveManager folder `BattleBotFarm`, autoload config `farm`. The user's older `yes` config uses pre-v3 option ids. The farm writes `bbb_farm_log.txt` to the workspace; read that to verify. Decompiled sources are in workspace `bbb_src/`.

Non-obvious findings (measured 2026-09-26):
- The bot fights server-side; the player only sets its mode via BotCommandRemote. `toArena` is ignored from the Depths (send `depthsStop` first). `toPlot` is the resting state; the server never follows it with `plot`, and a rebirth sends its own `toPlot`.
- Depths pays money only. Bot XP only accrues at the plot, from station buffers holding 120 s of fuel.
- `CrateRemote "claim"` and `GarageRemote "equip" {buildId, uid}` work from anywhere.
- `PlotSignRemote` (station buy/upgrade, workshop, scrapper) is range-checked: ignored from 30+ studs, works when standing next to the sign. Sign prompts are camera-gated by the WorkshopSign client.
- A rebirth wipes the stations (pads show "ENERGY STATION · BUY · 400") and resets the workshop (2 pads) and the scrapper to LV.1, on top of what the panel lists. The fabricator survives.
- Scrap is a parallel character farm. Hard teleports keep the load, unlike [needle-haystack-project](../needle-in-a-haystack/notes.md).
- Pit event tiers are server-wide totals; `joined` survives leaving.

Lessons from the first farm's misses: [game-recon-full-progression](../notes/game-recon-checklist.md). Other projects: [fix-it-up-project](../fix-it-up/notes.md), [sneaker-panel-project](../sneaker-resell-simulator/notes.md).
