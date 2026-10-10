-- CruelHub key system (Panda Auth): asks for a key, then loads the Kryptic Vault script.
-- The obfuscated LuaLoader/loader.lua loads this from the main repo (synced by sync_notes.py). Vault URL: VAULT below.

local SERVICE = "cruelhubkeysys"
local VAULT = "https://vss.pandauth.com/kv/f50aaaf4f8afc66f"
local KEY_FILE = "cruelhub_key.txt" -- a valid key is remembered, so it's asked for once until it expires
local LOGO_URL = "https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/assets/cruelhub.jpg"
local DISCORD = "wAq3hhH8E" -- discord.gg invite

-- Opens the invite in the Discord app through its local RPC (ports 6463-6472). Without the app (or without request),
-- the link goes to the clipboard instead. Returns "opened", "copied" or nil.
local function openDiscord()
    local http = game:GetService("HttpService")
    local req = request or http_request or (syn and syn.request) or (fluxus and fluxus.request)
    for port = 6463, 6472 do
        local ok, res = pcall(req or error, {
            Url = ("http://127.0.0.1:%d/rpc?v=1"):format(port), Method = "POST",
            Headers = { ["Content-Type"] = "application/json", Origin = "https://discord.com" },
            Body = http:JSONEncode({ cmd = "INVITE_BROWSER", nonce = http:GenerateGUID(false), args = { code = DISCORD } }),
        })
        if ok and type(res) == "table" and res.StatusCode == 200 then return "opened" end
        if not req then break end
    end
    return pcall(setclipboard, "https://discord.gg/" .. DISCORD) and "copied" or nil
end
if not getgenv().__cruelDiscord then -- once per game session, not on every execute
    getgenv().__cruelDiscord = true
    task.spawn(function()
        local how = openDiscord()
        local join = Instance.new("BindableFunction")
        join.OnInvoke = function() openDiscord() end
        local note = {
            Title = "CruelHub", Duration = 10, Button1 = "Join",
            Text = "Please join our Discord for support, updates and new scripts!"
                .. (how == "copied" and " (invite copied to clipboard)" or ""),
            Callback = join,
        }
        for _ = 1, 10 do -- SetCore errors until the core scripts have registered it
            if pcall(game:GetService("StarterGui").SetCore, game:GetService("StarterGui"), "SendNotification", note) then break end
            task.wait(1)
        end
    end)
end

-- CruelHub look: near-black with a crimson accent (same palette as the script menus)
local c = Color3.fromHex
local BG, MAIN, ACCENT, OUTLINE, FONT = c("0c0a0b"), c("161214"), c("e0233c"), c("2a1d20"), c("f2eded")
local MUTED, GOOD, BAD = c("8a7d80"), c("5fd68a"), c("ff5a6e")

local function loadVault()
    local ok, src = pcall(game.HttpGet, game, VAULT)
    if not ok or type(src) ~= "string" then return warn("[CruelHub] couldn't reach the key vault") end
    local fn, err = loadstring(src)
    if not fn then return warn("[CruelHub] vault script failed to compile: " .. tostring(err)) end
    fn()
end

local function savedKey()
    if getgenv().SCRIPT_KEY then return getgenv().SCRIPT_KEY end
    local ok, has = pcall(isfile, KEY_FILE)
    return ok and has and readfile(KEY_FILE) or nil
end

-- The vault decides whether a key is needed; it sets __chv only when it wants one. Nothing here knows the rule.
getgenv().SCRIPT_KEY, getgenv().__chv = savedKey(), nil
loadVault()
if not getgenv().__chv then return end

local okLib, src = pcall(game.HttpGet, game, "https://secure.pandauth.com/pv4/lib")
local libFn = okLib and type(src) == "string" and loadstring(src) -- nil on a bad download: don't call it
local okRun, PUSL = pcall(function() return libFn and libFn() end)
PUSL = okRun and PUSL or nil
if not PUSL or type(PUSL.configure) ~= "function" then
    return warn("[CruelHub] key library failed to load")
end
PUSL.configure({ serviceId = SERVICE, debug = false, kickOnDetect = false })

local function tryKey(key)
    if type(key) ~= "string" or #key == 0 then return false, "no key" end
    local ok, result = pcall(PUSL.validate, key)
    if ok and result and result.success then
        getgenv().SCRIPT_KEY = key
        pcall(writefile, KEY_FILE, key)
        return true
    end
    return false, ok and result and (result.error or result.reason) or "no response"
end

getgenv().SCRIPT_KEY = nil
do

    local function logo() -- CruelHub logo from the repo, cached in the workspace; nil if the executor can't load it
        local ok, id = pcall(function()
            local f = "CruelHub/logo.jpg"
            if not isfolder("CruelHub") then makefolder("CruelHub") end
            if not isfile(f) then
                local img = game:HttpGet(LOGO_URL)
                assert(img:sub(1, 2) == "\255\216", "not a jpeg")
                writefile(f, img)
            end
            return getcustomasset(f)
        end)
        return ok and id or nil
    end

    local function make(class, props, parent)
        local o = Instance.new(class)
        for k, v in pairs(props) do o[k] = v end
        o.Parent = parent
        return o
    end
    local function round(o, r) return make("UICorner", { CornerRadius = UDim.new(0, r or 8) }, o) end
    local function stroke(o, col, t) return make("UIStroke", { Color = col or OUTLINE, Thickness = t or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o) end

    local parent = (pcall(gethui) and gethui()) or game:GetService("CoreGui")
    local gui = make("ScreenGui", { Name = "CruelHubKey", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling })

    local frame = make("Frame", {
        Size = UDim2.fromOffset(340, 230), Position = UDim2.new(0.5, -170, 0.5, -115),
        BackgroundColor3 = BG, BorderSizePixel = 0, Active = true,
    }, gui)
    round(frame, 10); stroke(frame)

    -- crimson accent strip along the top edge
    local strip = make("Frame", { Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, frame)
    round(strip, 10)

    -- title bar (drag handle)
    local bar = make("Frame", { Size = UDim2.new(1, 0, 0, 48), Position = UDim2.fromOffset(0, 3), BackgroundTransparency = 1 }, frame)
    local img = logo()
    if img then
        local icon = make("ImageLabel", { Size = UDim2.fromOffset(28, 28), Position = UDim2.fromOffset(14, 10), BackgroundColor3 = MAIN, Image = img }, bar)
        round(icon, 6)
    end
    make("TextLabel", {
        Size = UDim2.new(1, -110, 0, 20), Position = UDim2.fromOffset(img and 50 or 16, 8), BackgroundTransparency = 1,
        Text = "CruelHub", TextColor3 = FONT, Font = Enum.Font.GothamBold, TextSize = 17, TextXAlignment = Enum.TextXAlignment.Left,
    }, bar)
    make("TextLabel", {
        Size = UDim2.new(1, -110, 0, 14), Position = UDim2.fromOffset(img and 50 or 16, 27), BackgroundTransparency = 1,
        Text = "Key system", TextColor3 = MUTED, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
    }, bar)
    local closeBtn = make("TextButton", {
        Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -40, 0, 10), BackgroundColor3 = MAIN, AutoButtonColor = false,
        Text = "×", TextColor3 = MUTED, Font = Enum.Font.GothamBold, TextSize = 18,
    }, bar)
    round(closeBtn, 6)

    -- key box
    local boxHolder = make("Frame", { Size = UDim2.new(1, -28, 0, 38), Position = UDim2.fromOffset(14, 62), BackgroundColor3 = MAIN }, frame)
    round(boxHolder, 8)
    local boxStroke = stroke(boxHolder)
    local box = make("TextBox", {
        Size = UDim2.new(1, -20, 1, 0), Position = UDim2.fromOffset(10, 0), BackgroundTransparency = 1, Text = "",
        PlaceholderText = "paste your key here", PlaceholderColor3 = MUTED, TextColor3 = FONT, ClearTextOnFocus = false,
        Font = Enum.Font.Gotham, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left,
    }, boxHolder)
    box.Focused:Connect(function() boxStroke.Color = ACCENT end)
    box.FocusLost:Connect(function() boxStroke.Color = OUTLINE end)

    local status = make("TextLabel", {
        Size = UDim2.new(1, -28, 0, 18), Position = UDim2.fromOffset(14, 108), BackgroundTransparency = 1,
        Text = "finish the checkpoints, then paste the key", TextColor3 = MUTED, Font = Enum.Font.Gotham, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, frame)
    local function say(text, col) status.Text, status.TextColor3 = text, col or MUTED end

    local function mkBtn(text, x, primary)
        local b = make("TextButton", {
            Size = UDim2.new(0.5, -21, 0, 38), Position = UDim2.new(x, x == 0 and 14 or 7, 0, 138),
            BackgroundColor3 = primary and ACCENT or MAIN, AutoButtonColor = false,
            Text = text, TextColor3 = FONT, Font = Enum.Font.GothamBold, TextSize = 14,
        }, frame)
        round(b, 8)
        if not primary then stroke(b) end
        local rest = b.BackgroundColor3
        local hover = primary and c("f0384f") or c("201a1c")
        b.MouseEnter:Connect(function() b.BackgroundColor3 = hover end)
        b.MouseLeave:Connect(function() b.BackgroundColor3 = rest end)
        return b
    end
    local submitBtn, getKeyBtn = mkBtn("Submit", 0, true), mkBtn("Get Key", 0.5, false)

    make("TextLabel", {
        Size = UDim2.new(1, -90, 0, 14), Position = UDim2.new(0, 14, 1, -26), BackgroundTransparency = 1,
        Text = "a valid key is remembered until it expires", TextColor3 = MUTED, Font = Enum.Font.Gotham, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, frame)
    local dcBtn = make("TextButton", {
        Size = UDim2.fromOffset(64, 14), Position = UDim2.new(1, -78, 1, -26), BackgroundTransparency = 1,
        Text = "discord", TextColor3 = ACCENT, Font = Enum.Font.GothamBold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right,
    }, frame)

    -- drag by the title bar
    local UIS = game:GetService("UserInputService")
    local dragging, dragStart, startPos
    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, i.Position, frame.Position
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)

    local closed = false
    closeBtn.MouseButton1Click:Connect(function() closed = true; gui:Destroy() end)

    local busy = false
    local function submit()
        if busy or #box.Text == 0 then return end
        busy = true
        say("checking...", FONT)
        local ok, msg = tryKey(box.Text:match("^%s*(.-)%s*$"))
        if ok then
            say("valid — loading...", GOOD)
            task.wait(0.5)
            gui:Destroy()
        else
            say(tostring(msg), BAD)
            task.wait(2)
        end
        busy = false
    end
    submitBtn.MouseButton1Click:Connect(submit)
    box.FocusLost:Connect(function(enter) if enter then submit() end end)

    local lastLink = -math.huge
    getKeyBtn.MouseButton1Click:Connect(function()
        if os.clock() - lastLink < 10 then return end
        lastLink = os.clock()
        local ok, link = pcall(PUSL.getKeyUrl)
        if ok and link then
            pcall(setclipboard, link)
            say("key link copied to clipboard", GOOD)
        else
            say("could not get key link", BAD)
        end
    end)

    local lastDc = -math.huge
    dcBtn.MouseButton1Click:Connect(function()
        if os.clock() - lastDc < 5 then return end
        lastDc = os.clock()
        local how = openDiscord()
        say(how == "opened" and "discord invite opened" or how == "copied" and "discord invite copied to clipboard"
            or "discord.gg/" .. DISCORD, how and GOOD or FONT)
    end)

    gui.Parent = parent
    repeat task.wait(0.1) until getgenv().SCRIPT_KEY or closed
    if closed then return end
end

loadVault()
