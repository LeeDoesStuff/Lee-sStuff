-- Lee's loader: runs the right script for the current game.
-- Keyed by universe id (game.GameId) so every place in a game matches.
local BASE = "https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/"

-- ponytail: JJBI and Mog or Die have no recorded ids yet; add them here when known
local SCRIPTS = {
    [10765666801] = "build-a-battle-bot/bbb_farm.lua",
    [10383565741] = "warfare/warfare_hud.lua",
    [8391342266]  = "hit-the-thrift/thrift_esp.lua",
    [10258991999] = "command-an-army/caa_farm.lua",
    [7673659635]  = "fix-it-up/fiu_main.lua",
    [4542048826]  = "sneaker-resell-simulator/panel_v2.lua",
    [10761200080] = "needle-in-a-haystack/needle_selldrop.lua",
}

local path = SCRIPTS[game.GameId]
if not path then
    warn(("[loader] no script for this game (GameId %d, PlaceId %d)"):format(game.GameId, game.PlaceId))
    return
end
loadstring(game:HttpGet(BASE .. path))()
