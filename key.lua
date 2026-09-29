local okLib, src = pcall(game.HttpGet, game, "https://secure.pandauth.com/pv4/lib")
local PUSL = okLib and src and loadstring(src)()
if not PUSL or type(PUSL.configure) ~= "function" then
	return warn("[Panda] library failed to load")
end
PUSL.configure({
	serviceId    = "cruelhubkeysys",
	debug        = false,
	kickOnDetect = false,
})

local function tryKey(key)
	local ok, result = pcall(PUSL.validate, key)
	if ok and result and result.success then
		getgenv().SCRIPT_KEY = key
		return true, result.isPremium and "PREMIUM_KEY_VALID" or "KEY_VALID"
	end
	return false, ok and result and (result.error or result.reason) or "no response"
end

if getgenv().SCRIPT_KEY and not select(1, tryKey(getgenv().SCRIPT_KEY)) then
	getgenv().SCRIPT_KEY = nil
end

if not getgenv().SCRIPT_KEY then
	local parent = (pcall(gethui) and gethui()) or game:GetService("CoreGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "JJBIKeyUI"
	gui.ResetOnSpawn = false

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(300, 150)
	frame.Position = UDim2.new(0.5, -150, 0.5, -75)
	frame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	frame.Parent = gui
	Instance.new("UICorner", frame)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 28)
	title.BackgroundTransparency = 1
	title.Text = "Cruel Hub — Enter Key"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.Parent = frame

	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, -20, 0, 30)
	box.Position = UDim2.new(0, 10, 0, 34)
	box.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
	box.TextColor3 = Color3.new(1, 1, 1)
	box.PlaceholderText = "paste key here"
	box.ClearTextOnFocus = false
	box.Text = ""
	box.Font = Enum.Font.Gotham
	box.TextSize = 14
	box.Parent = frame
	Instance.new("UICorner", box)

	local status = Instance.new("TextLabel")
	status.Size = UDim2.new(1, -20, 0, 20)
	status.Position = UDim2.new(0, 10, 0, 68)
	status.BackgroundTransparency = 1
	status.Text = ""
	status.TextColor3 = Color3.fromRGB(255, 120, 120)
	status.Font = Enum.Font.Gotham
	status.TextSize = 13
	status.TextTruncate = Enum.TextTruncate.AtEnd
	status.Parent = frame

	local function mkBtn(text, x)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.5, -15, 0, 32)
		b.Position = UDim2.new(x, x == 0 and 10 or 5, 1, -42)
		b.BackgroundColor3 = Color3.fromRGB(60, 60, 75)
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Text = text
		b.Font = Enum.Font.GothamBold
		b.TextSize = 14
		b.Parent = frame
		Instance.new("UICorner", b)
		return b
	end
	local submitBtn = mkBtn("Submit", 0)
	local getKeyBtn = mkBtn("Get Key", 0.5)

	local busy = false
	submitBtn.MouseButton1Click:Connect(function()
		if busy or #box.Text == 0 then return end
		busy = true
		status.TextColor3 = Color3.fromRGB(200, 200, 200)
		status.Text = "checking..."
		local ok, msg = tryKey(box.Text:match("^%s*(.-)%s*$"))
		if ok then
			status.TextColor3 = Color3.fromRGB(120, 255, 120)
			status.Text = "valid — loading hub..."
			task.wait(0.5)
			gui:Destroy()
		else
			status.TextColor3 = Color3.fromRGB(255, 120, 120)
			status.Text = tostring(msg)
			task.wait(2)
		end
		busy = false
	end)

	local lastLink = 0
	getKeyBtn.MouseButton1Click:Connect(function()
		if os.clock() - lastLink < 10 then return end
		lastLink = os.clock()
		local ok, link = pcall(PUSL.getKeyUrl)
		if ok and link then
			pcall(setclipboard, link)
			status.TextColor3 = Color3.fromRGB(120, 255, 120)
			status.Text = "key link copied to clipboard"
		else
			status.TextColor3 = Color3.fromRGB(255, 120, 120)
			status.Text = "could not get key link"
		end
	end)

	gui.Parent = parent
end

while not getgenv().SCRIPT_KEY do
	task.wait(0.1)
end

loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/loader.lua"))()
