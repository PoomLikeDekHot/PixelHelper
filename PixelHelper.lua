--[[
    Pixel Lineage Helper  ·  LAIKA dark theme, two-column tabs, cat bubble when hidden

    Remotes (ReplicatedStorage.PlatformBattles.Remotes):
      RPGCommand (client -> server)
        "RunLobby"   { action = "solo" | "replay" | "replayNext" (tier) | "replayDecline" | "endingDone" (runId) }
        "RunAction"  { action = "vote" (choice) | "eventChoice" (option / item) | "eventReady" | "storyChoice" | "state",
                       runId, round, phase }
        "CombatAction"             { battleId, actionId, targetEnemyIndex? / targetUserId? }
        "DefenseTimingInput"       { battleId, token, pressedAt }
        "WarriorBladeTimingResult" { battleId, token, results = {{pressed, position}} }
        "MageRhythmResult"         { battleId, token, hits }
        "ThiefSlashResult"         { battleId, token, hits }   -- Thief / Fist / Archer / Bard / Spear
        "LightContinue"            { passage }
        "GearSellMany"             { uids = { ... } }
        "SyncBattle"
      RPGState (server -> client)
        "Profile" (gearBag, gear, vanity), "RunState", "BattleStarted" / "BattleUpdated" / "BattleEnded",
        "LightDialogue", "DefenseTimingStarted", "WarriorBladeTimingStarted", "MageRhythmStarted", "ThiefSlashStarted"
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local GuiService        = game:GetService("GuiService")
local HttpService       = game:GetService("HttpService")

-- after a teleport (Lobby <-> Fight) the script can run before the game has loaded
if not game:IsLoaded() then game.Loaded:Wait() end
while not Players.LocalPlayer do
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
end

local LocalPlayer     = Players.LocalPlayer
local PlayerGui       = LocalPlayer:WaitForChild("PlayerGui")
local PlatformBattles = ReplicatedStorage:WaitForChild("PlatformBattles")
local Remotes         = PlatformBattles:WaitForChild("Remotes")
local Shared          = PlatformBattles:WaitForChild("Shared")
local RPGCommand      = Remotes:WaitForChild("RPGCommand")
local RPGState        = Remotes:WaitForChild("RPGState")

-- files in the executor's workspace folder
local SCRIPT_FILE = "PixelHelper.lua"       -- this script (re-run after teleport)
local ICON_FILE   = "PixelHelper_cat.png"   -- bubble picture
-- one settings file per Roblox account, so several windows on one PC don't share a config
local SAVE_FILE   = "PixelHelper_Settings_" .. LocalPlayer.UserId .. ".json"
local OLD_SAVE    = "PixelHelper_Settings.json" -- shared file from older versions, used once as a starting point

-- online copy (raw links). With these set, people only need the one-line loader and always get the latest version.
local SCRIPT_URL = "https://raw.githubusercontent.com/PoomLikeDekHot/PixelHelper/main/PixelHelper.lua"
local ICON_URL   = "https://raw.githubusercontent.com/PoomLikeDekHot/PixelHelper/main/PixelHelper_cat.png"
local ONLINE     = not SCRIPT_URL:find("YOUR_NAME", 1, true)

do -- re-run this script in the next server: from the web when online, else from the local file
    local queue = queue_on_teleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
    if queue then
        if ONLINE then
            pcall(queue, string.format("loadstring(game:HttpGet(%q))()", SCRIPT_URL))
        else
            local ok, has = pcall(function() return isfile and isfile(SCRIPT_FILE) end)
            if ok and has then pcall(queue, string.format("loadstring(readfile(%q))()", SCRIPT_FILE)) end
        end
    end
end

-- the bubble picture has to be a local file for getcustomasset; download it once
if ONLINE then
    pcall(function()
        if isfile and writefile and not isfile(ICON_FILE) then
            writefile(ICON_FILE, game:HttpGet(ICON_URL))
        end
    end)
end

-- stop the previous copy of this script (its loops check this token)
local genv = (getgenv and getgenv()) or _G
local RUN_TOKEN = {}
genv.__PixelHelperToken = RUN_TOKEN
local function alive() return genv.__PixelHelperToken == RUN_TOKEN end

---------------------------------------------------------------- game data (RunConfig / HalloweenConfig / TormentConfig / GearConfig)
local MODES = {
    { id = "story", name = "Story", acts = 10,
      difficulties = { { name = "Normal", id = "normal" }, { name = "Hard", id = "hard" }, { name = "Nightmare", id = "nightmare" } } },
    { id = "halloween", name = "Halloween",
      difficulties = { { name = "Normal", id = "harvest_normal" }, { name = "Hard", id = "harvest_hard" }, { name = "Nightmare", id = "harvest_nightmare" } } },
    { id = "torment", name = "Torment", tiers = 99 },
}

-- path card types (RunConfig.Events + RunConfig.NodeTypes). "boss" is forced, "retreat" is only used to exit.
local PATH_TYPES = {
    { id = "miniboss", name = "Mini-Boss" },
    { id = "champion", name = "Hunt a Champion" },
    { id = "elite",    name = "Elite" },
    { id = "shop",     name = "Shop" },
    { id = "camp",     name = "Camp" },
    { id = "shrine",   name = "Trainer's Shrine" },
    { id = "treasure", name = "Treasure" },
    { id = "scout",    name = "Scout" },
    { id = "mystery",  name = "Mystery" },
    { id = "altar",    name = "Blood Altar" },
    { id = "fight",    name = "Fight" },
    { id = "rest",     name = "Campfire" },
}
local PATH_NAME = {}
for _, p in ipairs(PATH_TYPES) do PATH_NAME[p.id] = p.name end

local SHOP_ITEMS = {
    { id = "potion",    name = "Potion",        price = 35 },
    { id = "tonic",     name = "Healing Tonic", price = 25 },
    { id = "whetstone", name = "Whetstone",     price = 45 },
    { id = "ward",      name = "Ward Charm",    price = 45 },
}

-- GearConfig.Slots kinds and GearConfig.Rarities
local GEAR_KINDS = { "Weapon", "Helmet", "Chest", "Legs", "Relic", "Scroll" }
local RARITIES = {
    { id = "Common",    color = Color3.fromRGB(205, 207, 199) },
    { id = "Uncommon",  color = Color3.fromRGB(130, 210, 130) },
    { id = "Rare",      color = Color3.fromRGB(120, 170, 255) },
    { id = "Epic",      color = Color3.fromRGB(200, 130, 255) },
    { id = "Legendary", color = Color3.fromRGB(255, 190, 90) },
    { id = "Secret",    color = Color3.fromRGB(255, 110, 200) },
}

---------------------------------------------------------------- settings
local settings = {
    tab = 1,
    -- lobby
    mode = 1, diff = { 1, 1 }, act = 1, tier = 1, auto = false,
    autoSlot = false, slot = 1, -- pick this character on the select screen
    autoRejoin = true, rejoinAfter = 40, lobbyPlaceId = 0, -- stuck on the boot screen -> rejoin
    -- combat
    combat = false, autoAttack = true, perfectAttack = true, hideMinigame = true,
    perfectDodge = true, autoGuard = true,
    autoPotion = true, potionHp = 35,
    autoSkill = false, attackIfNoMana = true,
    bossList = true, miniAsBoss = true, skillView = 1, -- 1 normal mobs, 2 boss
    skillMode = 2, -- 1 top first, 2 rotate (next ready), 3 wait in order
    target = 1, delay = 0.8,
    priority = {}, priorityBoss = {},
    -- run
    autoRun = false, runDelay = 1.0,
    autoPath = true, pathPriority = {},
    campChoice = 2, shrineTrain = true, altarOffer = false,
    shopBuy = { potion = false, tonic = false, whetstone = false, ward = false },
    autoContinue = true, autoChest = true, autoDeath = true,
    storyNextAct = true, storyExitAct = 0,
    tormentNextTier = true, tormentExitTier = 0,
    autoReplay = true, autoCastle = true,
    -- auto sell
    autoSell = false,
    sellKinds = { Weapon = false, Helmet = false, Chest = false, Legs = false, Relic = false, Scroll = false },
    sellRarity = { Common = true, Uncommon = true, Rare = false, Epic = false, Legendary = false, Secret = false },
    keepNames = {}, -- [lowercase name] = true
    -- auto forge (Blacksmith "hone")
    autoForge = false, forgeTarget = 5, forgeReserve = 0, forgeFilter = 1,
    forgePick = {}, -- [gear uid] = true
    -- pets (Ranch + Candy Witch)
    autoHatch = false, hatchEggs = {},             -- [egg item id] = true
    autoRelease = false, releaseRarity = { Common = true }, releaseKeepLevel = 0,
    autoCandyEgg = false, candyKeep = 0,           -- buy Haunted Eggs while candy stays above this
    -- window
    winW = 820, winH = 520,
}

pcall(function()
    if not isfile then return end
    local file = isfile(SAVE_FILE) and SAVE_FILE or (isfile(OLD_SAVE) and OLD_SAVE) or nil
    if file then
        local data = HttpService:JSONDecode(readfile(file))
        for k, v in pairs(data) do settings[k] = v end
    end
end)

do -- fill in anything added since the last save
    local have = {}
    for _, p in ipairs(settings.pathPriority) do have[p.id] = true end
    for _, p in ipairs(PATH_TYPES) do
        if not have[p.id] then table.insert(settings.pathPriority, { id = p.id, on = true }) end
    end
    for _, item in ipairs(SHOP_ITEMS) do
        if settings.shopBuy[item.id] == nil then settings.shopBuy[item.id] = false end
    end
    for _, k in ipairs(GEAR_KINDS) do
        if settings.sellKinds[k] == nil then settings.sellKinds[k] = false end
    end
    for _, r in ipairs(RARITIES) do
        if settings.sellRarity[r.id] == nil then settings.sellRarity[r.id] = false end
    end
    if type(settings.keepNames) ~= "table" then settings.keepNames = {} end
    if type(settings.forgePick) ~= "table" then settings.forgePick = {} end
    if type(settings.hatchEggs) ~= "table" then settings.hatchEggs = {} end
    if type(settings.releaseRarity) ~= "table" then settings.releaseRarity = { Common = true } end
end

local saveQueued = false
local function save()
    if saveQueued then return end
    saveQueued = true
    task.delay(0.5, function()
        saveQueued = false
        pcall(function()
            if writefile then writefile(SAVE_FILE, HttpService:JSONEncode(settings)) end
        end)
    end)
end

---------------------------------------------------------------- class + skills
local GameConfig, GearConfig, PetConfig, HalloweenConfig
pcall(function() GameConfig = require(Shared:WaitForChild("GameConfig", 5)) end)
pcall(function() GearConfig = require(Shared:WaitForChild("GearConfig", 5)) end)
pcall(function() PetConfig = require(Shared:WaitForChild("PetConfig", 5)) end)
pcall(function() HalloweenConfig = require(Shared:WaitForChild("HalloweenConfig", 5)) end)

local function myClass()
    return tostring(LocalPlayer:GetAttribute("RPGClass") or "Unknown")
end

-- same rule the game uses to sort battle actions into menu tabs
local function categoryOf(action)
    local s = string.lower(tostring(action.category or action.kind or action.id or ""))
    if s == "meditate" then return "Meditate" end
    if s == "gearscroll" then return "Scroll" end
    if s:find("skill", 1, true) or s:find("spell", 1, true) or s:find("ability", 1, true) then return "Skill" end
    if s:find("item", 1, true) or s:find("bag", 1, true) or s:find("potion", 1, true) then return "Item" end
    if s:find("guard", 1, true) or s:find("defend", 1, true) or s:find("block", 1, true) then return "Guard" end
    if s:find("run", 1, true) or s:find("flee", 1, true) or s:find("escape", 1, true) then return "Run" end
    return "Attack"
end

local onSkillsChanged = function() end -- set by the UI

-- which = "normal" | "boss"
local function priorityFor(cls, which)
    local root = which == "boss" and settings.priorityBoss or settings.priority
    root[cls] = root[cls] or {}
    return root[cls]
end

local function addSkillTo(list, id, name, cost)
    for _, s in ipairs(list) do
        if s.id == id then
            if name then s.name = name end
            if cost then s.cost = cost end
            return false
        end
    end
    table.insert(list, { id = id, name = name or id, cost = cost or 0, on = true })
    return true
end

local function addSkill(cls, id, name, cost)
    local a = addSkillTo(priorityFor(cls, "normal"), id, name, cost)
    local b = addSkillTo(priorityFor(cls, "boss"), id, name, cost)
    return a or b
end

local function loadClassSkills()
    local cls = myClass()
    local changed = false
    local def = GameConfig and GameConfig.Classes and GameConfig.Classes[cls]
    if def and type(def.skills) == "table" then
        for _, s in ipairs(def.skills) do
            if type(s) == "table" and s.id and not s.passive then
                changed = addSkill(cls, s.id, s.name, tonumber(s.mpCost or s.cost) or 0) or changed
            end
        end
    end
    if changed then save() end
    onSkillsChanged()
end

-- skills unlocked later (super class, scrolls…) show up in battle; remember them
local function learnFromBattle(state)
    local cls, changed = myClass(), false
    for _, a in ipairs(type(state.actions) == "table" and state.actions or {}) do
        if type(a) == "table" and a.id and categoryOf(a) == "Skill" then
            changed = addSkill(cls, a.id, a.name, tonumber(a.cost) or 0) or changed
        end
    end
    if changed then save(); onSkillsChanged() end
end

---------------------------------------------------------------- theme (LAIKA Rejoin tokens)
local T = {
    bg      = Color3.fromHex("0c0d0f"),
    side    = Color3.fromHex("101113"),
    card    = Color3.fromHex("16171a"),
    raised  = Color3.fromHex("1d1f22"),
    raised2 = Color3.fromHex("24262a"),
    text    = Color3.fromHex("ececef"),
    muted   = Color3.fromHex("8a8d94"),
    faint   = Color3.fromHex("5d6068"),
    accent  = Color3.fromHex("8b8cff"),
    accentT = Color3.fromHex("c7c8ff"),
    green   = Color3.fromHex("22c55e"),
    red     = Color3.fromHex("ef4444"),
    amber   = Color3.fromHex("f59e0b"),
    sky     = Color3.fromHex("38bdf8"),
    violet  = Color3.fromHex("a78bfa"),
    pink    = Color3.fromHex("f472b6"),
    switchOff = Color3.fromHex("303238"),
}
local LINE, LINE2 = 0.94, 0.89 -- white at 6% / 11%
local R_CARD, R_CTL = 14, 10
local FONT      = Font.new("rbxasset://fonts/families/Nunito.json", Enum.FontWeight.Bold)
local FONT_SEMI = Font.new("rbxasset://fonts/families/Nunito.json", Enum.FontWeight.ExtraBold)
local FONT_BOLD = Font.new("rbxasset://fonts/families/FredokaOne.json")
local EASE      = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local WHITE     = Color3.new(1, 1, 1)

---------------------------------------------------------------- ui primitives
local function new(class, props, children)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do inst[k] = v end
    for _, c in ipairs(children or {}) do c.Parent = inst end
    return inst
end
local function corner(r) return new("UICorner", { CornerRadius = UDim.new(0, r) }) end
local function line(transparency)
    return new("UIStroke", { Color = WHITE, Transparency = transparency or LINE, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end
local function pad(t, r, b, l)
    return new("UIPadding", { PaddingTop = UDim.new(0, t), PaddingRight = UDim.new(0, r), PaddingBottom = UDim.new(0, b), PaddingLeft = UDim.new(0, l) })
end
local function vlist(gap) return new("UIListLayout", { Padding = UDim.new(0, gap or 0), SortOrder = Enum.SortOrder.LayoutOrder }) end
local function tween(inst, props, info) TweenService:Create(inst, info or EASE, props):Play() end

local function label(parent, text, size, color, font, props)
    local l = new("TextLabel", {
        Parent = parent, BackgroundTransparency = 1, Text = text,
        FontFace = font or FONT, TextSize = size or 13, TextColor3 = color or T.text,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    })
    for k, v in pairs(props or {}) do l[k] = v end
    return l
end

local function rightAnchor(inst, width, height)
    inst.AnchorPoint = Vector2.new(1, 0.5)
    inst.Position = UDim2.new(1, 0, 0.5, 0)
    inst.Size = UDim2.fromOffset(width, height)
    return inst
end

local function hoverFill(btn, base, over)
    btn.MouseEnter:Connect(function() tween(btn, { BackgroundColor3 = over }) end)
    btn.MouseLeave:Connect(function() tween(btn, { BackgroundColor3 = base() }) end)
end

-- switch (LAIKA: 42x24, off #303238, on green). returns button, refresh()
local function switch(parent, get, onToggle)
    local s = new("TextButton", { Parent = parent, AutoButtonColor = false, Text = "", BackgroundColor3 = T.switchOff, BorderSizePixel = 0 }, { corner(12) })
    rightAnchor(s, 42, 24)
    local knob = new("Frame", {
        Parent = s, Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = WHITE, BorderSizePixel = 0,
    }, { corner(9) })
    local function refresh(instant)
        local on = get()
        local bg, pos = on and T.green or T.switchOff, on and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
        if instant then s.BackgroundColor3, knob.Position = bg, pos
        else tween(s, { BackgroundColor3 = bg }); tween(knob, { Position = pos }) end
    end
    s.MouseButton1Click:Connect(function() onToggle(); refresh() end)
    refresh(true)
    return s, refresh
end

-- checkbox. returns button, refresh()
local function checkbox(parent, get, onToggle)
    local b = new("TextButton", {
        Parent = parent, AutoButtonColor = false, Text = "", BorderSizePixel = 0, BackgroundColor3 = T.raised,
        FontFace = FONT_BOLD, TextSize = 13, TextColor3 = T.bg,
    }, { corner(6) })
    rightAnchor(b, 20, 20)
    local st = line(LINE2); st.Parent = b
    local function refresh()
        local on = get()
        b.BackgroundColor3 = on and T.accent or T.raised
        b.Text = on and "✓" or ""
        st.Transparency = on and 1 or LINE2
    end
    b.MouseButton1Click:Connect(function() onToggle(); refresh() end)
    refresh()
    return b, refresh
end

-- segmented control. returns frame, refresh()
local function segmented(parent, items, getIndex, onPick)
    local bar = new("Frame", { Parent = parent, BackgroundColor3 = T.bg, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 30) }, { corner(R_CTL), line() })
    local pill = new("Frame", {
        Parent = bar, BackgroundColor3 = T.raised2, BorderSizePixel = 0, Size = UDim2.new(1 / #items, -6, 1, -6),
    }, { corner(R_CTL - 3), line(LINE2) })
    local buttons = {}
    for i, item in ipairs(items) do
        local b = new("TextButton", {
            Parent = bar, AutoButtonColor = false, BackgroundTransparency = 1, ZIndex = 2,
            Size = UDim2.new(1 / #items, 0, 1, 0), Position = UDim2.new((i - 1) / #items, 0, 0, 0),
            Text = item, FontFace = FONT_SEMI, TextSize = 12, TextColor3 = T.muted,
        })
        buttons[i] = b
        b.MouseEnter:Connect(function() if getIndex() ~= i then b.TextColor3 = T.text end end)
        b.MouseLeave:Connect(function() if getIndex() ~= i then b.TextColor3 = T.muted end end)
        b.MouseButton1Click:Connect(function() onPick(i) end)
    end
    local function refresh(instant)
        local i = getIndex()
        local pos = UDim2.new((i - 1) / #items, 3, 0, 3)
        if instant then pill.Position = pos else tween(pill, { Position = pos }) end
        for j, b in ipairs(buttons) do
            b.TextColor3 = (j == i) and T.text or T.muted
            b.FontFace = (j == i) and FONT_BOLD or FONT_SEMI
        end
    end
    refresh(true)
    return bar, refresh
end

-- number stepper [ 12 ▲▼ ]. returns frame, refresh()
local function stepper(parent, get, set, step, min, max, fmt)
    local box = new("Frame", { Parent = parent, BackgroundColor3 = T.bg, BorderSizePixel = 0 }, { corner(8), line(LINE2) })
    rightAnchor(box, 80, 26)
    local txt = new("TextBox", {
        Parent = box, BackgroundTransparency = 1, ClearTextOnFocus = false,
        Size = UDim2.new(1, -20, 1, 0), FontFace = FONT_SEMI, TextSize = 12, TextColor3 = T.text, Text = "",
    })
    local function btn(text, y)
        return new("TextButton", {
            Parent = box, AutoButtonColor = false, BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -3, y, 0), Size = UDim2.new(0, 16, 0.5, 0),
            Text = text, FontFace = FONT_BOLD, TextSize = 8, TextColor3 = T.muted,
        })
    end
    local up, down = btn("▲", 0), btn("▼", 0.5)
    local function refresh() txt.Text = string.format(fmt or "%d", get()) end
    local function apply(v)
        v = math.clamp(math.floor(v / step + 0.5) * step, min, max)
        set(v); refresh()
    end
    up.MouseButton1Click:Connect(function() apply(get() + step) end)
    down.MouseButton1Click:Connect(function() apply(get() - step) end)
    txt.FocusLost:Connect(function() apply(tonumber(txt.Text:match("[%d%.]+") or "") or get()) end)
    refresh()
    return box, refresh
end

-- slider (track + knob, − / + buttons; value shown on the right of the title)
local function slider(parent, get, set, min, max, step, fmt, zeroText)
    local holder = new("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), Position = UDim2.new(0, 0, 1, -26) })
    local function sbtn(text, right)
        return new("TextButton", {
            Parent = holder, AutoButtonColor = false, BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(right and 1 or 0, 0), Position = UDim2.new(right and 1 or 0, 0, 0, 0), Size = UDim2.fromOffset(16, 20),
            Text = text, FontFace = FONT_BOLD, TextSize = 14, TextColor3 = T.muted,
        })
    end
    local minus, plus = sbtn("−", false), sbtn("+", true)
    local track = new("Frame", {
        Parent = holder, BackgroundColor3 = T.raised2, BorderSizePixel = 0,
        Position = UDim2.new(0, 22, 0.5, -2), Size = UDim2.new(1, -44, 0, 4),
    }, { corner(2) })
    local fill = new("Frame", { Parent = track, BackgroundColor3 = T.accent, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1) }, { corner(2) })
    local knob = new("Frame", {
        Parent = track, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(14, 14), BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 2,
    }, { corner(7) })
    local valueText = label(parent, "", 12, T.accentT, FONT_BOLD, {
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 6), Size = UDim2.fromOffset(90, 18),
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    local function refresh()
        local v = get()
        local a = (v - min) / (max - min)
        fill.Size = UDim2.fromScale(a, 1)
        knob.Position = UDim2.fromScale(a, 0.5)
        valueText.Text = (zeroText and v == 0) and zeroText or string.format(fmt or "%d", v)
    end
    local function apply(v)
        v = math.clamp(math.floor(v / step + 0.5) * step, min, max)
        if v ~= get() then set(v) end
        refresh()
    end
    minus.MouseButton1Click:Connect(function() apply(get() - step) end)
    plus.MouseButton1Click:Connect(function() apply(get() + step) end)
    local dragging = false
    local function fromX(x)
        local a = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
        apply(min + a * (max - min))
    end
    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; fromX(input.Position.X)
        end
    end)
    knob.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = true end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            fromX(input.Position.X)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
    refresh()
    return holder, refresh
end

---------------------------------------------------------------- pixel icons
-- The game keeps its pixel art in PixelIcons.Art ({ art = { "..KK..", … }, palette = { K = Color3 } }).
-- Its own sprite renderer draws nothing when called from here, so we build the art ourselves:
-- one Frame per run of same-coloured pixels in a row.
local Icons = { mod = nil, slots = {}, onReady = {} }

-- tab / card name -> art key in PixelIcons.Art
local ICON_KEYS = {
    ["Lobby"] = "duel", ["Auto Farm"] = "sword", ["Run"] = "nodeBoss", ["Auto Sell"] = "coin",
    ["Auto Forge"] = "cauldron", ["Settings"] = "book",
    ["Stage"] = "nodeFight", ["Auto Start"] = "hourglass", ["Auto Select Character"] = "lineage",
    ["Auto Combat"] = "skull", ["Attack"] = "sword", ["Defense"] = "shield", ["Potion"] = "potion",
    ["Auto Skills"] = "star", ["Auto Run"] = "nodeBoss", ["Auto Choose Path"] = "nodeFight",
    ["Events"] = "nodeMystery", ["Flow"] = "nodeTreasure", ["When a Run Ends"] = "nodeRest",
    ["Gear Types"] = "pouch", ["Rarity"] = "star", ["Never Sell"] = "heart", ["In Your Bag"] = "pouch",
    ["Pick Gear"] = "sword", ["Window"] = "book", ["Files"] = "blueprint", ["Unload"] = "skull",
    ["Pets"] = "paw", ["Auto Hatch"] = "star", ["Haunted Egg"] = "candy", ["Auto Release"] = "paw", ["Your Pets"] = "heart",
}

-- draws art `key` centred in `parent`, as large as fits in `size` px. returns the holder or nil
function Icons.draw(parent, key, size, palette, z)
    local PI = Icons.mod
    local a = PI and type(PI.Art) == "table" and PI.Art[key]
    if type(a) ~= "table" or type(a.art) ~= "table" then return nil end
    local pal = {}
    for k, v in pairs(type(a.palette) == "table" and a.palette or {}) do pal[k] = v end
    for k, v in pairs(type(palette) == "table" and palette or {}) do pal[k] = v end
    local w, h = 0, #a.art
    for _, r in ipairs(a.art) do w = math.max(w, #tostring(r)) end
    if w == 0 or h == 0 then return nil end
    local unit = math.max(1, math.floor(size / math.max(w, h)))
    local holder = new("Frame", {
        Parent = parent, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(w * unit, h * unit), ZIndex = z or 2,
    })
    for y, rowText in ipairs(a.art) do
        rowText = tostring(rowText)
        local x = 1
        while x <= #rowText do
            local ch = rowText:sub(x, x)
            local c = pal[ch]
            if ch ~= "." and typeof(c) == "Color3" then
                local x2 = x
                while x2 < #rowText and rowText:sub(x2 + 1, x2 + 1) == ch do x2 += 1 end
                new("Frame", {
                    Parent = holder, BorderSizePixel = 0, BackgroundColor3 = c, ZIndex = z or 2,
                    Position = UDim2.fromOffset((x - 1) * unit, (y - 1) * unit), Size = UDim2.fromOffset((x2 - x + 1) * unit, unit),
                })
                x = x2 + 1
            else
                x += 1
            end
        end
    end
    return holder
end

-- a glyph now, swapped for the game's art once PixelIcons has loaded
function Icons.slot(parent, name, size, glyph, color, z)
    local fallback = label(parent, glyph, math.floor(size * 0.6), color, FONT_BOLD, {
        Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = z or 2,
    })
    local s = { parent = parent, key = ICON_KEYS[name], size = size, fallback = fallback, z = z }
    local function fill()
        if s.key and Icons.draw(s.parent, s.key, s.size, nil, s.z) then s.fallback.Visible = false end
    end
    if Icons.mod then fill() else table.insert(Icons.slots, fill) end
    return fallback
end

task.spawn(function()
    local ok, mod = pcall(function()
        local scripts = LocalPlayer:WaitForChild("PlayerScripts", 15)
        local found = scripts and scripts:FindFirstChild("PixelIcons", true)
        if not found then found = ReplicatedStorage:FindFirstChild("PixelIcons", true) end
        return found and found:IsA("ModuleScript") and require(found) or nil
    end)
    if not (ok and type(mod) == "table" and type(mod.Art) == "table") then
        warn("[PixelHelper] PixelIcons not available: " .. tostring(mod))
        return
    end
    Icons.mod = mod
    for _, fill in ipairs(Icons.slots) do pcall(fill) end
    for _, f in ipairs(Icons.onReady) do pcall(f) end
end)

local function smallButton(parent, text, x)
    local b = new("TextButton", {
        Parent = parent, AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, x, 0.5, 0), Size = UDim2.fromOffset(22, 22),
        BackgroundColor3 = T.raised, BorderSizePixel = 0,
        Text = text, FontFace = FONT_BOLD, TextSize = 9, TextColor3 = T.muted,
    }, { corner(6) })
    hoverFill(b, function() return T.raised end, T.raised2)
    return b
end

local function primaryButton(parent, text, width)
    local b = new("TextButton", {
        Parent = parent, AutoButtonColor = false, BackgroundColor3 = T.accent, BorderSizePixel = 0,
        Text = text, FontFace = FONT_BOLD, TextSize = 12, TextColor3 = T.bg,
    }, { corner(R_CTL) })
    rightAnchor(b, width or 100, 30)
    hoverFill(b, function() return T.accent end, T.accentT)
    return b
end

---------------------------------------------------------------- window
local parentGui = (gethui and gethui()) or game:GetService("CoreGui")
for _, n in ipairs({ "PixelHelperMac", "AutoStartMac", "PixelHelper" }) do
    local old = parentGui:FindFirstChild(n)
    if old then old:Destroy() end
end

local gui = new("ScreenGui", { Name = "PixelHelper", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999 })
if not pcall(function() gui.Parent = parentGui end) then gui.Parent = PlayerGui end

local SIDEBAR = 184
local MIN_W, MIN_H = 500, 320
local WIDTH  = math.max(MIN_W, tonumber(settings.winW) or 820)
local HEIGHT = math.max(MIN_H, tonumber(settings.winH) or 520)

local shadow = new("ImageLabel", {
    Parent = gui, Name = "Shadow", ZIndex = 0, BackgroundTransparency = 1, Image = "rbxassetid://6014261993",
    ImageColor3 = Color3.new(0, 0, 0), ImageTransparency = 0.35,
    ScaleType = Enum.ScaleType.Slice, SliceCenter = Rect.new(49, 49, 450, 450),
})

local window = new("Frame", {
    Name = "Window", Parent = gui, Size = UDim2.fromOffset(WIDTH, HEIGHT),
    Position = UDim2.new(0.5, -WIDTH / 2, 0.5, -HEIGHT / 2),
    BackgroundColor3 = T.bg, BorderSizePixel = 0, ClipsDescendants = true,
}, { corner(R_CARD), line(LINE2) })

local function syncShadow()
    shadow.Position = window.Position - UDim2.fromOffset(30, 26)
    shadow.Size = UDim2.fromOffset(window.AbsoluteSize.X + 60, window.AbsoluteSize.Y + 60)
    shadow.Visible = window.Visible
end
window:GetPropertyChangedSignal("Position"):Connect(syncShadow)
window:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncShadow)
window:GetPropertyChangedSignal("Visible"):Connect(syncShadow)
syncShadow()

---------------- sidebar
local sidebar = new("Frame", {
    Parent = window, Size = UDim2.new(0, SIDEBAR, 1, 0), BackgroundColor3 = T.side, BorderSizePixel = 0,
}, {
    new("Frame", {
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0, 1, 1, 0),
        BackgroundColor3 = WHITE, BackgroundTransparency = LINE, BorderSizePixel = 0,
    }),
})

-- the only window button: red = hide into the bubble
local btnHide = new("TextButton", {
    Parent = sidebar, AutoButtonColor = false, Text = "", Size = UDim2.fromOffset(13, 13),
    Position = UDim2.fromOffset(16, 16), BackgroundColor3 = T.red, BorderSizePixel = 0,
}, { corner(7) })
do
    local g = label(btnHide, "–", 11, Color3.fromRGB(90, 20, 20), FONT_BOLD, {
        Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = 1,
    })
    btnHide.MouseEnter:Connect(function() g.TextTransparency = 0 end)
    btnHide.MouseLeave:Connect(function() g.TextTransparency = 1 end)
end

local brand = new("Frame", { Parent = sidebar, BackgroundTransparency = 1, Position = UDim2.fromOffset(16, 44), Size = UDim2.new(1, -32, 0, 40) })
local brandIcon = new("ImageLabel", {
    Parent = brand, BackgroundColor3 = T.raised, BorderSizePixel = 0, Size = UDim2.fromOffset(34, 34), Image = "",
    ScaleType = Enum.ScaleType.Fit,
}, { corner(10) })
label(brand, "Pixel Helper", 14, T.text, FONT_BOLD, { Position = UDim2.fromOffset(44, 1), Size = UDim2.new(1, -44, 0, 18) })
local classBadge = label(brand, "", 11, T.muted, FONT, { Position = UDim2.fromOffset(44, 19), Size = UDim2.new(1, -44, 0, 14) })

local navList = new("Frame", {
    Parent = sidebar, BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 96), Size = UDim2.new(1, -20, 1, -106),
    ZIndex = 2, -- above the sliding highlight
}, { vlist(2) })

---------------- main area
local main = new("Frame", { Parent = window, BackgroundTransparency = 1, Position = UDim2.fromOffset(SIDEBAR, 0), Size = UDim2.new(1, -SIDEBAR, 1, 0) })
local toolbar = new("Frame", { Parent = main, Size = UDim2.new(1, 0, 0, 58), BackgroundTransparency = 1 }, {
    new("Frame", { Position = UDim2.new(0, 0, 1, -1), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = WHITE, BackgroundTransparency = LINE, BorderSizePixel = 0 }),
})
local titleText = label(toolbar, "", 17, T.text, FONT_BOLD, { Position = UDim2.fromOffset(22, 11), Size = UDim2.new(1, -230, 0, 22) })
local subtitleText = label(toolbar, "", 11, T.muted, FONT, { Position = UDim2.fromOffset(22, 34), Size = UDim2.new(1, -230, 0, 14) })
local livePill = new("Frame", {
    Parent = toolbar, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -18, 0.5, 0), Size = UDim2.fromOffset(170, 28),
    BackgroundColor3 = T.card, BorderSizePixel = 0,
}, { corner(14), line() })
local liveDot = new("Frame", { Parent = livePill, Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 12, 0.5, -4), BackgroundColor3 = T.faint, BorderSizePixel = 0 }, { corner(4) })
local liveText = label(livePill, "Idle", 11, T.text, FONT_SEMI, { Position = UDim2.fromOffset(28, 0), Size = UDim2.new(1, -36, 1, 0) })

local function setLive(text, on)
    liveText.Text = text
    liveDot.BackgroundColor3 = on and T.green or T.faint
end

-- drag by toolbar or sidebar top
do
    local dragging, startPos, startInput
    local function begin(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, startPos, startInput = true, window.Position, input.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end
    toolbar.InputBegan:Connect(begin)
    sidebar.InputBegan:Connect(function(input)
        if input.Position.Y - sidebar.AbsolutePosition.Y < 40 then begin(input) end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - startInput
            window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

---------------- pages: scrolling area with two columns (stacks into one when the window is narrow)
local STACK_BELOW = 580
local pages = {}

local function layoutPage(p)
    if main.AbsoluteSize.X < STACK_BELOW then
        p.left.Size = UDim2.new(1, 0, 0, 0)
        p.right.Size = UDim2.new(1, 0, 0, 0)
        p.right.Position = UDim2.new(0, 0, 0, p.left.AbsoluteSize.Y + 14)
    else
        p.left.Size = UDim2.new(0.5, -7, 0, 0)
        p.right.Size = UDim2.new(0.5, -7, 0, 0)
        p.right.Position = UDim2.new(0.5, 7, 0, 0)
    end
end

local function makePage()
    local page = new("ScrollingFrame", {
        Parent = main, Visible = false, BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 58), Size = UDim2.new(1, 0, 1, -58),
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
        ScrollBarThickness = 4, ScrollBarImageColor3 = T.faint,
    }, { pad(16, 0, 18, 0) })
    local cols = new("Frame", {
        Parent = page, BackgroundTransparency = 1, Position = UDim2.fromOffset(18, 0),
        Size = UDim2.new(1, -36, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
    })
    local function col()
        return new("Frame", { Parent = cols, BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y }, { vlist(14) })
    end
    local p = { page = page, left = col(), right = col() }
    table.insert(pages, p)
    p.left:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() layoutPage(p) end)
    layoutPage(p)
    return page, p.left, p.right
end
main:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
    for _, p in ipairs(pages) do layoutPage(p) end
end)

-- card: tinted icon tile + title + subtitle (+ optional switch in the header)
local function card(column, order, glyph, tint, title, sub, key, onChange)
    local c = new("Frame", {
        Parent = column, LayoutOrder = order, BackgroundColor3 = T.card, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
    }, { corner(R_CARD), line(), vlist(0) })
    local head = new("Frame", { Parent = c, LayoutOrder = 0, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 66) }, { pad(0, 16, 0, 16) })
    local tile = new("Frame", {
        Parent = head, Size = UDim2.fromOffset(42, 42), Position = UDim2.new(0, 0, 0.5, -21),
        BackgroundColor3 = tint, BackgroundTransparency = 0.8, BorderSizePixel = 0,
    }, { corner(12), new("UIStroke", { Color = tint, Transparency = 0.55, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }) })
    Icons.slot(tile, title, 30, glyph, tint, 3)
    label(head, title, 15, T.text, FONT_BOLD, { Position = UDim2.fromOffset(54, 13), Size = UDim2.new(1, -110, 0, 20) })
    label(head, sub or "", 11, T.muted, FONT, { Position = UDim2.fromOffset(54, 34), Size = UDim2.new(1, -110, 0, 14) })
    local refreshHead
    if key then
        local _, r = switch(head, function() return settings[key] end, function()
            settings[key] = not settings[key]
            save()
            if onChange then onChange() end
        end)
        refreshHead = r
    end
    c:SetAttribute("rows", 0)
    return c, refreshHead
end

-- a row inside a card: title/sub on the left, widget on the right
local function row(parent, title, sub, height)
    local n = (parent:GetAttribute("rows") or 0) + 1
    parent:SetAttribute("rows", n)
    local r = new("Frame", {
        Parent = parent, LayoutOrder = n, BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, height or (sub and 48 or 38)),
    }, { pad(0, 16, 0, 16) })
    new("Frame", { Parent = r, Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = WHITE, BackgroundTransparency = LINE, BorderSizePixel = 0 })
    if title then
        label(r, title, 13, T.text, FONT_SEMI, {
            Position = UDim2.fromOffset(0, sub and 8 or 0), Size = UDim2.new(1, -100, 0, sub and 18 or (height or 38)),
        })
    end
    if sub then
        label(r, sub, 11, T.muted, FONT, { Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, -100, 0, 14) })
    end
    return r
end

local function switchRow(parent, title, sub, key, onChange)
    local r = row(parent, title, sub)
    local _, refresh = switch(r, function() return settings[key] end, function()
        settings[key] = not settings[key]
        save()
        if onChange then onChange() end
    end)
    return r, refresh
end

local function sliderRow(parent, title, sub, key, min, max, step, fmt, zeroText, onChange)
    local r = row(parent, nil, nil, 60)
    label(r, title, 13, T.text, FONT_SEMI, { Position = UDim2.fromOffset(0, 7), Size = UDim2.new(1, -96, 0, 18) })
    if sub then label(r, sub, 10, T.muted, FONT, { Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, -96, 0, 12) }) end
    local _, refresh = slider(r, function() return settings[key] end, function(v)
        settings[key] = v; save()
        if onChange then onChange() end
    end, min, max, step, fmt, zeroText)
    return r, refresh
end

local function sectionLabel(parent, text)
    local r = row(parent, nil, nil, 28)
    label(r, string.upper(text), 10, T.faint, FONT_BOLD, { Size = UDim2.new(1, 0, 1, -2), TextYAlignment = Enum.TextYAlignment.Bottom })
    return r
end

local function footerNote(parent, text)
    local r = row(parent, nil, nil, 42)
    label(r, text, 10, T.muted, FONT, { Size = UDim2.new(1, 0, 1, 0), TextWrapped = true, TextTruncate = Enum.TextTruncate.None })
    return r
end

local function valueRow(parent, title, color)
    local r = row(parent, title, nil)
    return label(r, "", 12, color or T.muted, FONT_SEMI, {
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0.66, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Right,
    })
end

-- an ordered list with ▲▼ + switch per item. items = array of { on = bool, ... }
local function orderedList(container, items, nameOf, extraOf, onChanged)
    local function render()
        for _, c in ipairs(container:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        container:SetAttribute("rows", 0)
        if #items == 0 then
            row(container, "Nothing here yet", nil)
            return
        end
        for i, it in ipairs(items) do
            local r = row(container, nil, nil, 36)
            label(r, tostring(i), 11, T.faint, FONT_BOLD, { Size = UDim2.new(0, 18, 1, 0) })
            label(r, nameOf(it), 12, it.on and T.text or T.faint, FONT_SEMI, { Position = UDim2.fromOffset(20, 0), Size = UDim2.new(1, -160, 1, 0) })
            local extra = extraOf and extraOf(it) or ""
            if extra ~= "" then
                label(r, extra, 10, T.faint, FONT, {
                    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -104, 0, 0), Size = UDim2.new(0, 40, 1, 0), TextXAlignment = Enum.TextXAlignment.Right,
                })
            end
            local upB, downB = smallButton(r, "▲", -76), smallButton(r, "▼", -50)
            upB.Visible, downB.Visible = i > 1, i < #items
            upB.MouseButton1Click:Connect(function() items[i], items[i - 1] = items[i - 1], items[i]; save(); render(); if onChanged then onChanged() end end)
            downB.MouseButton1Click:Connect(function() items[i], items[i + 1] = items[i + 1], items[i]; save(); render(); if onChanged then onChanged() end end)
            switch(r, function() return it.on end, function() it.on = not it.on; save(); render() end)
        end
    end
    render()
    return render
end

---------------------------------------------------------------- tabs
local tabs = {}
-- highlight that glides behind the selected nav item (sits on the sidebar, outside the list layout)
local navPill = new("Frame", {
    Parent = sidebar, BackgroundColor3 = T.raised, BorderSizePixel = 0,
    Position = UDim2.fromOffset(10, 96), Size = UDim2.new(1, -20, 0, 40),
}, { corner(R_CTL) })

local function selectTab(index)
    settings.tab = index
    save()
    for i, t in ipairs(tabs) do
        local on = (i == index)
        t.page.Visible = on
        t.label.TextColor3 = on and T.text or T.muted
        t.icon.TextColor3 = on and T.accentT or T.faint
    end
    titleText.Text = tabs[index].name
    subtitleText.Text = tabs[index].subtitle
    local b = tabs[index].button
    task.defer(function()
        tween(navPill, { Position = UDim2.fromOffset(10, b.AbsolutePosition.Y - sidebar.AbsolutePosition.Y) })
    end)
end

local function addTab(section, glyph, name, subtitle)
    if section then
        label(navList, section, 10, T.faint, FONT_BOLD, {
            LayoutOrder = #tabs * 10 + 1, Size = UDim2.new(1, 0, 0, 28), TextYAlignment = Enum.TextYAlignment.Bottom,
        }, nil)
    end
    local b = new("TextButton", {
        Parent = navList, LayoutOrder = #tabs * 10 + 2, AutoButtonColor = false,
        Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, Text = "", ZIndex = 2,
    })
    local iconBox = new("Frame", {
        Parent = b, BackgroundTransparency = 1, Position = UDim2.new(0, 8, 0.5, -13), Size = UDim2.fromOffset(26, 26), ZIndex = 2,
    })
    local icon = Icons.slot(iconBox, name, 24, glyph, T.faint, 3)
    local l = label(b, name, 14, T.muted, FONT_SEMI, { Position = UDim2.fromOffset(44, 0), Size = UDim2.new(1, -48, 1, 0), ZIndex = 2 })
    local page, left, right = makePage()
    table.insert(tabs, { button = b, label = l, icon = icon, page = page, name = name, subtitle = subtitle })
    local index = #tabs
    b.MouseEnter:Connect(function() if settings.tab ~= index then l.TextColor3 = Color3.fromHex("c9cad0") end end)
    b.MouseLeave:Connect(function() if settings.tab ~= index then l.TextColor3 = T.muted end end)
    b.MouseButton1Click:Connect(function() selectTab(index) end)
    return left, right
end
local lobbyL, lobbyR   = addTab("General", "▶", "Lobby", "Pick a stage and launch it automatically")
local combatL, combatR = addTab("Automation", "◆", "Auto Farm", "Battle: attack, dodge, skills, potions")
local runL, runR       = addTab(nil, "↗", "Run", "Map paths, events and what happens when a run ends")
local sellL, sellR     = addTab("Items", "$", "Auto Sell", "Sell gear you don't want, keep what you name")
local forgeL, forgeR   = addTab(nil, "⚒", "Auto Forge", "Tick gear pictures and hone them to a target +")
local petL, petR       = addTab(nil, "♣", "Pets", "Hatch eggs, release pets, buy Haunted Eggs")
local setL, setR       = addTab("App", "≡", "Settings", "Window, files and unloading")

---------------------------------------------------------------- LOBBY TAB
local function lobbyPayload()
    local mode = MODES[settings.mode]
    if mode.id == "torment" then
        return { action = "solo", difficulty = "torment" .. settings.tier, startAct = 1 }
    end
    local diff = mode.difficulties[settings.diff[settings.mode] or 1]
    return { action = "solo", difficulty = diff.id, startAct = mode.acts and settings.act or 1 }
end

local function lobbyDescribe()
    local mode = MODES[settings.mode]
    if mode.id == "torment" then return "Torment " .. settings.tier end
    local diff = mode.difficulties[settings.diff[settings.mode] or 1]
    return mode.name .. " · " .. diff.name .. (mode.acts and (" · Act " .. settings.act) or "")
end

-- widgets the automation below needs. Each tab is built inside its own do-block
-- (Luau allows at most 200 locals in one scope).
local ui = {}

do -- LOBBY TAB widgets
local refreshLobby -- forward

local stageCard = card(lobbyL, 1, "▶", T.accent, "Stage", "Mode, difficulty and where to start")
local refreshMode
do
    local r = row(stageCard, nil, nil, 48)
    local names = {}
    for i, m in ipairs(MODES) do names[i] = m.name end
    local bar
    bar, refreshMode = segmented(r, names, function() return settings.mode end, function(i)
        settings.mode = i; save(); refreshLobby()
    end)
    bar.Position = UDim2.new(0, 0, 0.5, -15)
end

local diffRow = row(stageCard, nil, nil, 70)
label(diffRow, "Difficulty", 11, T.muted, FONT_SEMI, { Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 16) })
local diffBars = {}
for mi, m in ipairs(MODES) do
    if m.difficulties then
        local names = {}
        for i, d in ipairs(m.difficulties) do names[i] = d.name end
        local bar, refresh = segmented(diffRow, names, function() return settings.diff[mi] or 1 end, function(i)
            settings.diff[mi] = i; save(); refreshLobby()
        end)
        bar.Position = UDim2.fromOffset(0, 30)
        diffBars[mi] = { bar = bar, refresh = refresh }
    end
end

local actRow = row(stageCard, nil, nil, 104)
label(actRow, "Start Act", 11, T.muted, FONT_SEMI, { Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 16) })
local actGrid = new("Frame", {
    Parent = actRow, Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 0, 64), BackgroundTransparency = 1,
}, { new("UIGridLayout", { CellSize = UDim2.new(0.2, -5, 0, 29), CellPadding = UDim2.fromOffset(5, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
local actButtons = {}
for i = 1, MODES[1].acts do
    local b = new("TextButton", {
        Parent = actGrid, LayoutOrder = i, AutoButtonColor = false, BackgroundColor3 = T.raised, BorderSizePixel = 0,
        Text = tostring(i), FontFace = FONT_SEMI, TextSize = 13, TextColor3 = T.text,
    }, { corner(8) })
    actButtons[i] = b
    b.MouseEnter:Connect(function() if settings.act ~= i then b.BackgroundColor3 = T.raised2 end end)
    b.MouseLeave:Connect(function() b.BackgroundColor3 = settings.act == i and T.accent or T.raised end)
    b.MouseButton1Click:Connect(function() settings.act = i; save(); refreshLobby() end)
end

local tierRow = row(stageCard, "Torment Tier", "Any tier you have unlocked (1 – 99)")
local _, refreshTier = stepper(tierRow, function() return settings.tier end, function(v)
    settings.tier = v; save(); refreshLobby()
end, 1, 1, MODES[3].tiers, "%d")

local launchCard, refreshLaunchHead = card(lobbyR, 1, "↻", T.green, "Auto Start", "Start the stage whenever you are in the lobby", "auto", function() refreshLobby() end)
local summaryText = valueRow(launchCard, "Selected", T.accentT)
local statusRow = row(launchCard, nil, nil, 50)
local lobbyStatus = label(statusRow, "", 11, T.muted, FONT, { Size = UDim2.new(1, -112, 1, 0), TextWrapped = true })
local startNow = primaryButton(statusRow, "Start Now", 100)
footerNote(launchCard, "After a run, the Run tab decides Replay, Next or Castle.")

local slotCard = card(lobbyR, 2, "☺", T.violet, "Auto Select Character", "Pick a character slot when the game opens", "autoSlot")
local slotRow = row(slotCard, "Character slot", "Slot 1 is the left card")
stepper(slotRow, function() return settings.slot end, function(v) settings.slot = v; save() end, 1, 1, 10, "Slot %d")
local slotStatus = valueRow(slotCard, "Status")
slotStatus.Text = "—"
footerNote(slotCard, "Only presses a slot that already has a character. Empty or locked slots are skipped.")
switchRow(slotCard, "Rejoin if stuck", "Stuck on \"CHARACTERS READY\" with no menu: rejoin", "autoRejoin")
sliderRow(slotCard, "Stuck for", "Seconds before rejoining", "rejoinAfter", 20, 120, 5, "%ds")
ui.slotStatus = slotStatus

function refreshLobby()
    local mode = MODES[settings.mode]
    refreshMode()
    for mi, d in pairs(diffBars) do
        d.refresh()
        d.bar.Visible = (mi == settings.mode)
    end
    diffRow.Visible = mode.difficulties ~= nil
    actRow.Visible = mode.acts ~= nil
    tierRow.Visible = mode.id == "torment"
    for i, b in ipairs(actButtons) do
        local sel = (i == settings.act)
        b.BackgroundColor3 = sel and T.accent or T.raised
        b.TextColor3 = sel and T.bg or T.text
        b.FontFace = sel and FONT_BOLD or FONT_SEMI
    end
    refreshTier()
    if refreshLaunchHead then refreshLaunchHead() end
    summaryText.Text = lobbyDescribe()
    lobbyStatus.Text = settings.auto and "Auto Start is on" or "Auto Start is off"
end
refreshLobby()
ui.lobbyStatus, ui.startNow = lobbyStatus, startNow
end -- LOBBY TAB

---------------------------------------------------------------- AUTO FARM TAB
do
local combatStatusText
local masterCard = card(combatL, 1, "◆", T.accent, "Auto Combat", "Master switch for this tab", "combat", function()
    if combatStatusText then combatStatusText.Text = settings.combat and "Waiting for a battle" or "Off" end
end)
combatStatusText = valueRow(masterCard, "Status")
combatStatusText.Text = settings.combat and "Waiting for a battle" or "Off"
local classText = valueRow(masterCard, "Your class", T.accentT)
local fightKindText = valueRow(masterCard, "This battle")

local attackCard = card(combatL, 2, "⚔", T.amber, "Attack", "Your turn")
switchRow(attackCard, "Auto Attack", "Basic attack on your turn", "autoAttack")
switchRow(attackCard, "Perfect Attack", "Wins your class minigame every time", "perfectAttack")
switchRow(attackCard, "Hide Minigame UI", "Don't show the timing screens", "hideMinigame")
do
    local r = row(attackCard, "Target", nil, 44)
    local bar = segmented(r, { "Lowest HP", "First" }, function() return settings.target end, function(i) settings.target = i; save() end)
    rightAnchor(bar, 156, 28)
end
sliderRow(attackCard, "Action Delay", "Wait before acting", "delay", 0, 3, 0.1, "%.1fs")

local defenseCard = card(combatR, 1, "▲", T.sky, "Defense", "Enemy turn")
switchRow(defenseCard, "Perfect Dodge", "Press exactly as the rings meet", "perfectDodge")
switchRow(defenseCard, "Guard Boss Specials", "GUARD when a boss winds up a special", "autoGuard")

local potionCard = card(combatR, 2, "+", T.pink, "Potion", "Heal before it's too late", "autoPotion")
sliderRow(potionCard, "Drink below HP", "Uses your turn to drink a Potion", "potionHp", 5, 90, 5, "%d%%")

local skillCard = card(combatR, 3, "★", T.violet, "Auto Skills", "Top of the list is tried first", "autoSkill")
do
    local modeNotes = {
        "Always the highest skill that is ready",
        "Next ready skill after the last one, then loops",
        "Basic attack until the next skill is ready, then loops",
    }
    local r = row(skillCard, nil, nil, 84)
    label(r, "Order", 13, T.text, FONT_SEMI, { Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 18) })
    local note = label(r, "", 10, T.muted, FONT, { Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 0, 14) })
    local bar, refresh
    bar, refresh = segmented(r, { "Top first", "Rotate", "Wait in order" }, function() return settings.skillMode end, function(i)
        settings.skillMode = i; save(); refresh(); note.Text = modeNotes[i]
    end)
    bar.Position = UDim2.fromOffset(0, 46)
    note.Text = modeNotes[settings.skillMode] or ""
end
switchRow(skillCard, "Attack When Out of Energy", "Off = Meditate to refill instead", "attackIfNoMana")
switchRow(skillCard, "Separate Boss List", "Use a different order against bosses", "bossList", function() onSkillsChanged() end)
switchRow(skillCard, "Mini-Boss Uses Boss List", "Treat mini-bosses and elites as bosses", "miniAsBoss")
local skillTabsRow = row(skillCard, nil, nil, 48)
local skillTabsBar, refreshSkillTabs = segmented(skillTabsRow, { "Normal Mobs", "Boss" }, function() return settings.skillView end, function(i)
    settings.skillView = i; save(); onSkillsChanged()
end)
skillTabsBar.Position = UDim2.new(0, 0, 0.5, -15)
local skillListFrame = new("Frame", {
    Parent = skillCard, LayoutOrder = 50, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
}, { vlist(0) })
local reloadRow = row(skillCard, nil, nil, 44)
reloadRow.LayoutOrder = 60
local reloadBtn = new("TextButton", {
    Parent = reloadRow, AutoButtonColor = false, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0),
    Size = UDim2.fromOffset(120, 28), BackgroundColor3 = T.raised, BorderSizePixel = 0,
    Text = "Reload skills", FontFace = FONT_SEMI, TextSize = 12, TextColor3 = T.text,
}, { corner(R_CTL), line() })
hoverFill(reloadBtn, function() return T.raised end, T.raised2)
label(reloadRow, "New ones appear after a battle", 10, T.muted, FONT, { Position = UDim2.fromOffset(130, 0), Size = UDim2.new(1, -130, 1, 0) })

local function renderSkills()
    local cls = myClass()
    classText.Text = cls
    classBadge.Text = "Class: " .. cls
    skillTabsRow.Visible = settings.bossList
    refreshSkillTabs()
    local which = (settings.bossList and settings.skillView == 2) and "boss" or "normal"
    orderedList(skillListFrame, priorityFor(cls, which),
        function(s) return s.name or s.id end,
        function(s) return (tonumber(s.cost) or 0) > 0 and (s.cost .. " EN") or "" end)
end
onSkillsChanged = renderSkills
reloadBtn.MouseButton1Click:Connect(loadClassSkills)
LocalPlayer:GetAttributeChangedSignal("RPGClass"):Connect(loadClassSkills)
loadClassSkills()
ui.combatStatus, ui.fightKind = combatStatusText, fightKindText
end -- AUTO FARM TAB

local function setCombatStatus(text)
    ui.combatStatus.Text = text
end

---------------------------------------------------------------- RUN TAB
do
local runStatusText
local runMaster = card(runL, 1, "↗", T.accent, "Auto Run", "Master switch for this tab", "autoRun", function()
    if runStatusText then runStatusText.Text = settings.autoRun and "Waiting for a run" or "Off" end
end)
runStatusText = valueRow(runMaster, "Status")
runStatusText.Text = settings.autoRun and "Waiting for a run" or "Off"
sliderRow(runMaster, "Click Delay", "Wait before each choice", "runDelay", 0.3, 3, 0.1, "%.1fs")

local pathCard = card(runL, 2, "⇢", T.sky, "Auto Choose Path", "Takes the highest card that is offered", "autoPath")
local pathListFrame = new("Frame", {
    Parent = pathCard, LayoutOrder = 50, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
}, { vlist(0) })
orderedList(pathListFrame, settings.pathPriority, function(p) return PATH_NAME[p.id] or p.id end)
local pathFoot = footerNote(pathCard, "Boss is always taken. Turn Back is only used to leave a run.")
pathFoot.LayoutOrder = 60

local eventCard = card(runL, 3, "◎", T.amber, "Events", "What to pick at each stop")
do
    local r = row(eventCard, "Camp", nil, 44)
    local bar = segmented(r, { "Rest", "Sharpen" }, function() return settings.campChoice end, function(i) settings.campChoice = i; save() end)
    rightAnchor(bar, 156, 28)
end
switchRow(eventCard, "Shrine: Train", "Skip the Super Class pick, take XP", "shrineTrain")
do
    local r = row(eventCard, "Altar: Offer Blood", "Lose 20% HP for gold + Focus")
    checkbox(r, function() return settings.altarOffer end, function() settings.altarOffer = not settings.altarOffer; save() end)
end
sectionLabel(eventCard, "Shop: buy these")
for _, item in ipairs(SHOP_ITEMS) do
    local r = row(eventCard, item.name, item.price .. " gold")
    checkbox(r, function() return settings.shopBuy[item.id] end, function()
        settings.shopBuy[item.id] = not settings.shopBuy[item.id]; save()
    end)
end

local flowCard = card(runR, 1, "▸", T.green, "Flow", "Keep the run moving")
switchRow(flowCard, "Auto Continue", "Close victory screens and cutscenes", "autoContinue")
switchRow(flowCard, "Collect Boss Chest", "Close the loot chest after a boss", "autoChest")
switchRow(flowCard, "Continue After Death", "Press Continue in the Light", "autoDeath")

local endCard = card(runR, 2, "⚑", T.pink, "When a Run Ends", "Checked top to bottom")
sectionLabel(endCard, "Story")
switchRow(endCard, "Auto Next Act", "Keep going after each act boss", "storyNextAct")
sliderRow(endCard, "Leave after Act", "Takes Turn Back once this act is cleared", "storyExitAct", 0, 10, 1, "Act %d", "End")
sectionLabel(endCard, "Torment  ·  all 3 lands are played")
switchRow(endCard, "Auto Next Tier", "Start the next tier after land 3", "tormentNextTier")
sliderRow(endCard, "Stop after Tier", "Back to castle once this tier is cleared", "tormentExitTier", 0, 99, 1, "Tier %d", "Never")
sectionLabel(endCard, "Story · Halloween · Torment")
switchRow(endCard, "Auto Replay", "Play the same stage again", "autoReplay")
switchRow(endCard, "Auto Back to Castle", "Return to the lobby otherwise", "autoCastle")
ui.runStatus = runStatusText
end -- RUN TAB

local function setRunStatus(text)
    ui.runStatus.Text = text
end

---------------------------------------------------------------- AUTO SELL TAB
local profile           -- latest Profile from the server
local refreshSellPreview = function() end
local renderBagNames = function() end

do
local sellMaster = card(sellL, 1, "$", T.green, "Auto Sell", "Sells matching gear whenever your bag changes", "autoSell", function() refreshSellPreview() end)
local sellPreviewText = valueRow(sellMaster, "Matching now", T.accentT)
local sellStatusText = valueRow(sellMaster, "Last sale")
sellStatusText.Text = "—"
local sellNowRow = row(sellMaster, nil, nil, 50)
label(sellNowRow, "Locked, equipped, vanity and starter gear is never sold.", 10, T.muted, FONT, {
    Size = UDim2.new(1, -112, 1, 0), TextWrapped = true, TextTruncate = Enum.TextTruncate.None,
})
local sellNowBtn = primaryButton(sellNowRow, "Sell Now", 100)

local kindCard = card(sellL, 2, "▣", T.sky, "Gear Types", "Tick what may be sold")
for _, k in ipairs(GEAR_KINDS) do
    local r = row(kindCard, k, nil)
    checkbox(r, function() return settings.sellKinds[k] end, function()
        settings.sellKinds[k] = not settings.sellKinds[k]; save(); refreshSellPreview()
    end)
end

local rarityCard = card(sellL, 3, "◇", T.violet, "Rarity", "Tick which rarities may be sold")
for _, rr in ipairs(RARITIES) do
    local r = row(rarityCard, nil, nil, 38)
    label(r, rr.id, 13, rr.color, FONT_SEMI, { Size = UDim2.new(1, -100, 1, 0) })
    checkbox(r, function() return settings.sellRarity[rr.id] end, function()
        settings.sellRarity[rr.id] = not settings.sellRarity[rr.id]; save(); refreshSellPreview()
    end)
end

-- keep list: never sell anything whose name contains one of these words
local keepCard = card(sellR, 1, "♥", T.pink, "Never Sell", "Names you keep, even if ticked above")
local pickRow = row(keepCard, nil, nil, 54)
local pickBtn = new("TextButton", {
    Parent = pickRow, AutoButtonColor = false, BackgroundColor3 = T.accent, BorderSizePixel = 0,
    AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(1, 0, 0, 34),
    Text = "Choose gear from the list", FontFace = FONT_BOLD, TextSize = 13, TextColor3 = T.bg,
}, { corner(R_CTL) })
hoverFill(pickBtn, function() return T.accent end, T.accentT)
local addRow = row(keepCard, nil, nil, 50)
local keepBox = new("TextBox", {
    Parent = addRow, BackgroundColor3 = T.bg, BorderSizePixel = 0, ClearTextOnFocus = false,
    AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(1, -86, 0, 30),
    PlaceholderText = "Type a name, e.g. Sunforged", PlaceholderColor3 = T.faint,
    Text = "", FontFace = FONT, TextSize = 12, TextColor3 = T.text, TextXAlignment = Enum.TextXAlignment.Left,
}, { corner(R_CTL), line(LINE2), pad(0, 10, 0, 10) })
local addBtn = primaryButton(addRow, "Keep", 76)
local keepListFrame = new("Frame", {
    Parent = keepCard, LayoutOrder = 50, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
}, { vlist(0) })
local keepFoot = footerNote(keepCard, "Matches part of the name and ignores case, so \"sunforged\" keeps every Sunforged piece.")
keepFoot.LayoutOrder = 60

local function renderKeep()
    for _, c in ipairs(keepListFrame:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    keepListFrame:SetAttribute("rows", 0)
    local names = {}
    for n in pairs(settings.keepNames) do table.insert(names, n) end
    table.sort(names)
    if #names == 0 then
        local r = row(keepListFrame, nil, nil, 34)
        label(r, "No names yet", 12, T.faint, FONT, { Size = UDim2.new(1, 0, 1, 0) })
        return
    end
    for _, n in ipairs(names) do
        local r = row(keepListFrame, n, nil, 34)
        local x = smallButton(r, "×", 0)
        x.TextSize = 13
        x.MouseButton1Click:Connect(function()
            settings.keepNames[n] = nil; save(); renderKeep(); renderBagNames(); refreshSellPreview()
        end)
    end
end

local function addKeep(text)
    text = string.lower((text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if text == "" then return end
    settings.keepNames[text] = true
    save(); renderKeep(); renderBagNames(); refreshSellPreview()
end
addBtn.MouseButton1Click:Connect(function() addKeep(keepBox.Text); keepBox.Text = "" end)
keepBox.FocusLost:Connect(function(enter) if enter then addKeep(keepBox.Text); keepBox.Text = "" end end)

-- popup: every gear piece in the game (GearConfig.Items) with its picture; tick names to keep
do
    local overlay, listFrame, searchBox, countText, chipButtons
    local filterKind, bagOnly, limit = "All", false, 60
    local catalog

    local RARITY_COLOR = {}
    for _, r in ipairs(RARITIES) do RARITY_COLOR[r.id] = r.color end

    local function getCatalog()
        if catalog then return catalog end
        catalog = {}
        local seen = {}
        for id, it in pairs(GearConfig and type(GearConfig.Items) == "table" and GearConfig.Items or {}) do
            local kind = type(it) == "table" and (it.gearKind or it.kind)
            if kind and table.find(GEAR_KINDS, kind) and type(it.name) == "string" then
                local key = string.lower(it.name)
                if not seen[key] then
                    seen[key] = true
                    table.insert(catalog, { id = id, name = it.name, key = key, kind = kind, rarity = it.rarity })
                end
            end
        end
        local order = {}
        for i, k in ipairs(GEAR_KINDS) do order[k] = i end
        table.sort(catalog, function(a, b)
            if a.kind ~= b.kind then return (order[a.kind] or 99) < (order[b.kind] or 99) end
            return a.name < b.name
        end)
        return catalog
    end

    -- lowercase base name -> how many you own
    local function bagCounts()
        local out = {}
        if not (profile and GearConfig and type(profile.gearBag) == "table") then return out end
        for _, raw in pairs(profile.gearBag) do
            local ok, d = pcall(GearConfig.Describe, raw)
            if ok and d and d.name then
                local k = string.lower(d.name)
                out[k] = (out[k] or 0) + 1
            end
        end
        return out
    end

    local function refreshCount()
        local n = 0
        for _ in pairs(settings.keepNames) do n += 1 end
        countText.Text = n .. " kept"
    end

    local renderList
    function renderList()
        for _, c in ipairs(listFrame:GetChildren()) do
            if c:IsA("GuiObject") then c:Destroy() end
        end
        local q = string.lower(searchBox.Text or "")
        local owned = bagCounts()
        local shown, matches = 0, 0
        for _, it in ipairs(getCatalog()) do
            local ok = (filterKind == "All" or it.kind == filterKind)
                and (q == "" or it.key:find(q, 1, true) ~= nil)
                and (not bagOnly or owned[it.key] ~= nil)
            if ok then
                matches += 1
                if shown < limit then
                    shown += 1
                    local kept = settings.keepNames[it.key] == true
                    local r = new("Frame", {
                        Parent = listFrame, LayoutOrder = shown, BorderSizePixel = 0,
                        BackgroundColor3 = kept and T.raised2 or T.raised, Size = UDim2.new(1, 0, 0, 48),
                    }, { corner(R_CTL), pad(0, 12, 0, 8) })
                    local pic = new("Frame", {
                        Parent = r, BackgroundColor3 = T.bg, BorderSizePixel = 0,
                        Position = UDim2.new(0, 0, 0.5, -18), Size = UDim2.fromOffset(36, 36),
                    }, { corner(8) })
                    local drawn = false
                    if Icons.mod and Icons.mod.GearIcon then
                        pcall(function()
                            local key, palette = Icons.mod.GearIcon({ id = it.id }, it.kind)
                            drawn = Icons.draw(pic, key, 30, palette) ~= nil
                        end)
                    end
                    if not drawn then
                        label(pic, it.kind:sub(1, 1), 16, T.muted, FONT_BOLD, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center })
                    end
                    label(r, it.name, 13, RARITY_COLOR[it.rarity] or T.text, FONT_SEMI, {
                        Position = UDim2.fromOffset(46, 6), Size = UDim2.new(1, -86, 0, 18),
                    })
                    local sub = it.kind .. (it.rarity and (" · " .. it.rarity) or "") .. (owned[it.key] and (" · in bag x" .. owned[it.key]) or "")
                    label(r, sub, 10, owned[it.key] and T.green or T.muted, FONT, {
                        Position = UDim2.fromOffset(46, 25), Size = UDim2.new(1, -86, 0, 14),
                    })
                    checkbox(r, function() return settings.keepNames[it.key] == true end, function()
                        settings.keepNames[it.key] = (not settings.keepNames[it.key]) or nil
                        r.BackgroundColor3 = settings.keepNames[it.key] and T.raised2 or T.raised
                        save(); refreshCount(); renderKeep(); renderBagNames(); refreshSellPreview()
                    end)
                end
            end
        end
        if matches > shown then
            local more = new("TextButton", {
                Parent = listFrame, LayoutOrder = shown + 1, AutoButtonColor = false, BorderSizePixel = 0,
                BackgroundColor3 = T.raised, Size = UDim2.new(1, 0, 0, 38),
                Text = string.format("Show more  (%d of %d)", shown, matches), FontFace = FONT_SEMI, TextSize = 12, TextColor3 = T.text,
            }, { corner(R_CTL) })
            more.MouseButton1Click:Connect(function() limit += 60; renderList() end)
        elseif matches == 0 then
            label(listFrame, catalog and #catalog > 0 and "Nothing matches." or "Gear list isn't available yet.", 12, T.faint, FONT, {
                LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 40), TextXAlignment = Enum.TextXAlignment.Center,
            })
        end
        refreshCount()
    end

    local function build()
        overlay = new("TextButton", {
            Parent = window, Name = "KeepPicker", AutoButtonColor = false, Text = "", Visible = false, ZIndex = 60,
            BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.4, Size = UDim2.fromScale(1, 1),
        }, { corner(R_CARD) })
        local panel = new("Frame", {
            Parent = overlay, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.new(1, -48, 1, -48), BackgroundColor3 = T.card, BorderSizePixel = 0, Active = true,
        }, { corner(R_CARD), line(LINE2) })
        -- header
        local tile = new("Frame", {
            Parent = panel, Position = UDim2.fromOffset(18, 16), Size = UDim2.fromOffset(42, 42),
            BackgroundColor3 = T.pink, BackgroundTransparency = 0.8, BorderSizePixel = 0,
        }, { corner(12) })
        Icons.slot(tile, "Never Sell", 30, "♥", T.pink, 2)
        label(panel, "Choose gear to keep", 16, T.text, FONT_BOLD, { Position = UDim2.fromOffset(72, 18), Size = UDim2.new(1, -130, 0, 20) })
        label(panel, "Ticked names are never sold", 11, T.muted, FONT, { Position = UDim2.fromOffset(72, 40), Size = UDim2.new(1, -130, 0, 14) })
        local close = new("TextButton", {
            Parent = panel, AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 18),
            Size = UDim2.fromOffset(30, 30), BackgroundColor3 = T.raised, BorderSizePixel = 0,
            Text = "×", FontFace = FONT_BOLD, TextSize = 18, TextColor3 = T.muted,
        }, { corner(15) })
        hoverFill(close, function() return T.raised end, T.raised2)
        -- search
        searchBox = new("TextBox", {
            Parent = panel, BackgroundColor3 = T.bg, BorderSizePixel = 0, ClearTextOnFocus = false,
            Position = UDim2.fromOffset(18, 70), Size = UDim2.new(1, -36, 0, 34),
            PlaceholderText = "Search gear name…", PlaceholderColor3 = T.faint, Text = "",
            FontFace = FONT, TextSize = 13, TextColor3 = T.text, TextXAlignment = Enum.TextXAlignment.Left,
        }, { corner(R_CTL), line(LINE2), pad(0, 12, 0, 12) })
        -- type chips
        local chips = new("ScrollingFrame", {
            Parent = panel, BackgroundTransparency = 1, BorderSizePixel = 0,
            Position = UDim2.fromOffset(18, 112), Size = UDim2.new(1, -36, 0, 34),
            CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.X, ScrollingDirection = Enum.ScrollingDirection.X,
            ScrollBarThickness = 0,
        }, { new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
        chipButtons = {}
        local function refreshChips()
            for name, b in pairs(chipButtons) do
                local on = (name == "In my bag") and bagOnly or (name == filterKind)
                b.BackgroundColor3 = on and T.accent or T.raised
                b.TextColor3 = on and T.bg or T.text
            end
        end
        local names = { "All" }
        for _, k in ipairs(GEAR_KINDS) do table.insert(names, k) end
        table.insert(names, "In my bag")
        for i, name in ipairs(names) do
            local b = new("TextButton", {
                Parent = chips, LayoutOrder = i, AutoButtonColor = false, BorderSizePixel = 0, BackgroundColor3 = T.raised,
                Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X,
                Text = name, FontFace = FONT_SEMI, TextSize = 12, TextColor3 = T.text,
            }, { corner(15), pad(0, 12, 0, 12) })
            chipButtons[name] = b
            b.MouseButton1Click:Connect(function()
                if name == "In my bag" then bagOnly = not bagOnly else filterKind = name end
                limit = 60
                refreshChips(); renderList()
            end)
        end
        refreshChips()
        -- list
        listFrame = new("ScrollingFrame", {
            Parent = panel, BackgroundTransparency = 1, BorderSizePixel = 0,
            Position = UDim2.fromOffset(18, 154), Size = UDim2.new(1, -36, 1, -214),
            CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
            VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar, ScrollBarThickness = 4, ScrollBarImageColor3 = T.faint,
        }, { vlist(6) })
        -- footer
        countText = label(panel, "", 12, T.muted, FONT_SEMI, {
            AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 18, 1, -18), Size = UDim2.new(1, -150, 0, 30),
        })
        local doneRow = new("Frame", {
            Parent = panel, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1),
            Position = UDim2.new(1, -18, 1, -16), Size = UDim2.fromOffset(110, 34),
        })
        local done = primaryButton(doneRow, "Done", 110)

        local function hide() overlay.Visible = false end
        close.MouseButton1Click:Connect(hide)
        done.MouseButton1Click:Connect(hide)
        overlay.MouseButton1Click:Connect(hide) -- click outside the panel
        local searchSeq = 0
        searchBox:GetPropertyChangedSignal("Text"):Connect(function()
            searchSeq += 1
            local mySeq = searchSeq
            task.delay(0.25, function() -- wait until typing pauses
                if mySeq == searchSeq then limit = 60; renderList() end
            end)
        end)
    end

    pickBtn.MouseButton1Click:Connect(function()
        if not overlay then build() end
        overlay.Visible = true
        limit = 60
        renderList()
    end)
end

-- names currently in the bag, tick to keep
local bagCard = card(sellR, 2, "☰", T.amber, "In Your Bag", "Tick a name to keep it")
local bagListFrame = new("Frame", {
    Parent = bagCard, LayoutOrder = 50, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
}, { vlist(0) })

renderKeep()
ui.sellPreview, ui.sellStatus, ui.sellNowBtn, ui.bagList, ui.renderKeep =
    sellPreviewText, sellStatusText, sellNowBtn, bagListFrame, renderKeep
end -- AUTO SELL TAB

---------------------------------------------------------------- AUTO FORGE TAB
local renderForge = function() end -- set by the forge logic

do
local forgeMaster = card(forgeL, 1, "⚒", T.amber, "Auto Forge", "Hones every ticked piece up to the target", "autoForge")
sliderRow(forgeMaster, "Stop at", "Hone each ticked piece up to this +", "forgeTarget", 1, 10, 1, "+%d")
sliderRow(forgeMaster, "Keep gold above", "Never spend gold below this", "forgeReserve", 0, 100000, 500, "%d")
local goldText = valueRow(forgeMaster, "Gold", T.amber)
local stoneText = valueRow(forgeMaster, "Whetstones")
local statusText = valueRow(forgeMaster, "Last hone")
statusText.Text = "—"
local onceRow = row(forgeMaster, nil, nil, 50)
label(onceRow, "From +5 a failed hone can drop the piece by 1.", 10, T.muted, FONT, {
    Size = UDim2.new(1, -116, 1, 0), TextWrapped = true, TextTruncate = Enum.TextTruncate.None,
})
local onceBtn = primaryButton(onceRow, "Hone Once", 104)
footerNote(forgeMaster, "Works in the lobby once the Blacksmith is repaired. Each hone costs 1 whetstone of the piece's rarity plus gold.")

local pickCard = card(forgeR, 1, "▦", T.violet, "Pick Gear", "Tap a picture to tick it")
do
    local r = row(pickCard, nil, nil, 48)
    local bar, refresh
    bar, refresh = segmented(r, { "All", "Equipped", "Ticked" }, function() return settings.forgeFilter end, function(i)
        settings.forgeFilter = i; save(); refresh(); renderForge(true)
    end)
    bar.Position = UDim2.new(0, 0, 0.5, -15)
end
local grid = new("Frame", {
    Parent = pickCard, LayoutOrder = 50, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
}, {
    pad(8, 14, 16, 14),
    new("UIGridLayout", { CellSize = UDim2.fromOffset(84, 116), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
})
local emptyText = label(pickCard, "", 12, T.faint, FONT, { LayoutOrder = 60, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true })
new("UIPadding", { Parent = emptyText, PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16), PaddingBottom = UDim.new(0, 14) })

ui.forge = { gold = goldText, stones = stoneText, status = statusText, onceBtn = onceBtn, grid = grid, empty = emptyText }
end -- AUTO FORGE TAB

---------------------------------------------------------------- PETS TAB
local renderPets = function() end -- set by the pets logic

do
local hatchCard = card(petL, 1, "◎", T.green, "Auto Hatch", "Hatches the ticked eggs while the ranch has room", "autoHatch")
local hatchStatus = valueRow(hatchCard, "Status")
hatchStatus.Text = "—"
local ranchText = valueRow(hatchCard, "Ranch")
ranchText.Text = "—"
sectionLabel(hatchCard, "Eggs to hatch")
local eggList = new("Frame", {
    Parent = hatchCard, LayoutOrder = 50, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
}, { vlist(0) })
local hatchFoot = footerNote(hatchCard, "Eggs rarer than your ranch allows are skipped. Release or upgrade the ranch when it is full.")
hatchFoot.LayoutOrder = 60

local candyCard = card(petL, 2, "♦", T.amber, "Haunted Egg", "Candy Witch: buy Haunted Eggs with candy", "autoCandyEgg")
local candyText = valueRow(candyCard, "Candy", T.amber)
candyText.Text = "—"
local candyStatus = valueRow(candyCard, "Status")
candyStatus.Text = "—"
sliderRow(candyCard, "Keep candy above", "Stops buying before candy drops below this", "candyKeep", 0, 20000, 100, "%d")
footerNote(candyCard, "Each Haunted Egg costs 220 candy. Only while the Halloween stall is open; you can hold 99 eggs.")

local releaseCard = card(petR, 1, "✕", T.pink, "Auto Release", "Lets go of pets of the ticked rarities", "autoRelease")
local releaseStatus = valueRow(releaseCard, "Status")
releaseStatus.Text = "—"
sectionLabel(releaseCard, "Release these rarities")
for _, id in ipairs({ "Common", "Uncommon", "Rare", "Legendary", "Divine", "Mythic" }) do
    local r = row(releaseCard, id, nil)
    checkbox(r, function() return settings.releaseRarity[id] == true end, function()
        settings.releaseRarity[id] = (not settings.releaseRarity[id]) or nil
        save(); renderPets()
    end)
end
sliderRow(releaseCard, "Keep from level", "Never release a pet at or above this level", "releaseKeepLevel", 0, 100, 1, "Lv %d", "Off")
footerNote(releaseCard, "Locked pets, your active pet and bound pets (Mochi, Party Slime) are never released.")

local petsCard = card(petR, 2, "♥", T.violet, "Your Pets", "What is in the ranch right now")
local petList = new("Frame", {
    Parent = petsCard, LayoutOrder = 50, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
}, { vlist(0) })

ui.pets = {
    hatchStatus = hatchStatus, ranch = ranchText, eggList = eggList,
    candy = candyText, candyStatus = candyStatus,
    releaseStatus = releaseStatus, petList = petList,
}
end -- PETS TAB

---------------------------------------------------------------- SETTINGS TAB
do
local winCard = card(setL, 1, "▢", T.accent, "Window", "Size and visibility")
footerNote(winCard, "Red dot (top left) hides the window into the cat bubble. Click the bubble to bring it back. RightShift does the same.")
footerNote(winCard, "Drag the right edge, bottom edge or corner to resize. The size is remembered.")
do
    local r = row(winCard, "Reset size", "Back to 820 × 520")
    local b = primaryButton(r, "Reset", 76)
    b.MouseButton1Click:Connect(function()
        WIDTH, HEIGHT = 820, 520
        settings.winW, settings.winH = WIDTH, HEIGHT
        save()
        window.Size = UDim2.fromOffset(WIDTH, HEIGHT)
        window.Position = UDim2.new(0.5, -WIDTH / 2, 0.5, -HEIGHT / 2)
    end)
end

local fileCard = card(setR, 1, "⌂", T.sky, "Files", "In your executor's workspace folder")
valueRow(fileCard, "Script").Text = ONLINE and "Online (latest)" or SCRIPT_FILE
valueRow(fileCard, "Bubble picture").Text = ICON_FILE
valueRow(fileCard, "Settings").Text = SAVE_FILE
footerNote(fileCard, ONLINE and "Loaded from the web, so it updates itself and restarts after every teleport."
    or "Keep the script file there so it starts again by itself after every teleport.")

local unloadCard = card(setR, 2, "×", T.red, "Unload", "Stop everything and remove the window")
local unloadRow = row(unloadCard, "Unload script", "Turns off all automation")
local unloadBtn = primaryButton(unloadRow, "Unload", 86)
unloadBtn.BackgroundColor3 = T.red
unloadBtn.TextColor3 = WHITE
ui.unloadBtn = unloadBtn
end -- SETTINGS TAB

selectTab(math.clamp(settings.tab or 1, 1, #tabs))

---------------------------------------------------------------- shared helpers
local function serverNow()
    local ok, t = pcall(function() return workspace:GetServerTimeNow() end)
    return ok and t or os.clock()
end

local function waitUntilServer(t)
    while serverNow() < t do
        local left = t - serverNow()
        if left > 0.05 then task.wait(left - 0.03) else RunService.Heartbeat:Wait() end
    end
end

-- press a game button (the game's own handlers run)
local function press(btn)
    if not (btn and btn.Parent) then return false end
    local ok = false
    if firesignal then
        ok = pcall(firesignal, btn.Activated)
        if not ok then ok = pcall(firesignal, btn.MouseButton1Click) end
    end
    if not ok and getconnections then
        for _, sig in ipairs({ btn.Activated, btn.MouseButton1Click }) do
            for _, c in ipairs(getconnections(sig)) do
                if pcall(function() c:Fire() end) then ok = true end
            end
        end
    end
    return ok
end

local function shownOnScreen(inst)
    local g = inst
    while g and g ~= PlayerGui do
        if g:IsA("GuiObject") and not g.Visible then return false end
        if g:IsA("ScreenGui") and not g.Enabled then return false end
        g = g.Parent
    end
    return g == PlayerGui
end

local done = {} -- one-shot keys so each step is sent once (retried after a while)
local function once(key, retryAfter)
    local t = done[key]
    if t and os.clock() - t < (retryAfter or 1e9) then return false end
    done[key] = os.clock()
    return true
end

local function inAdventure()
    return LocalPlayer:GetAttribute("PBInRun") == true or workspace:GetAttribute("PBAdventureServer") == true
end

local function inBattleNow()
    return LocalPlayer:GetAttribute("PlatformBattleActive") == true or LocalPlayer:GetAttribute("InTurnBattle") == true
end

---------------------------------------------------------------- LOBBY LOGIC
local L = {} -- lobby functions the event loop calls
do
local lastLobbyFire = 0
local LOBBY_COOLDOWN = 8

-- After a teleport the game reloads your last character by itself. If that load doesn't finish it
-- leaves you on the boot screen ("CHARACTERS READY / CHOOSE YOUR ROAD") and never shows the menu.
local stuckSince

local function rejoin()
    local placeId = workspace:GetAttribute("PBAdventureServer") == true and tonumber(settings.lobbyPlaceId) or game.PlaceId
    if not placeId or placeId == 0 then placeId = game.PlaceId end
    ui.slotStatus.Text = "Stuck — rejoining…"
    pcall(function() game:GetService("TeleportService"):Teleport(placeId, LocalPlayer) end)
end

local function watchStuck(menuShown)
    if menuShown or LocalPlayer:GetAttribute("RPGGameplayReady") == true then
        stuckSince = nil
        return
    end
    stuckSince = stuckSince or os.clock()
    local stuckFor = os.clock() - stuckSince
    if settings.autoRejoin and stuckFor >= settings.rejoinAfter and once("rejoin", 90) then
        rejoin()
    elseif stuckFor >= 5 then
        ui.slotStatus.Text = string.format("No menu for %ds%s", math.floor(stuckFor), settings.autoRejoin and string.format(" (rejoin at %ds)", settings.rejoinAfter) or "")
    end
end

-- character select screen: PlayerGui … SlotCards / Slot<n> / … / Action (the card button the game listens to)
local function trySelectSlot()
    if LocalPlayer:GetAttribute("RPGGameplayReady") == true then
        stuckSince = nil
        if workspace:GetAttribute("PBAdventureServer") ~= true and settings.lobbyPlaceId ~= game.PlaceId then
            settings.lobbyPlaceId = game.PlaceId; save() -- remembered so an adventure server can rejoin the lobby
        end
        return
    end
    if not settings.autoSlot then return end
    local cards, menuButton
    for _, d in ipairs(PlayerGui:GetDescendants()) do
        if d.Name == "SlotCards" and d:IsA("GuiObject") then cards = d end
        if d.Name == "CharacterSelect" and d:IsA("TextButton") then menuButton = d end
    end
    local cardsShown = cards and shownOnScreen(cards)
    local menuShown = menuButton and shownOnScreen(menuButton)
    watchStuck(cardsShown or menuShown)
    if not cardsShown then
        -- title menu: press CHARACTER SELECT first so the slot cards open
        -- (the game only reacts once its menu data has loaded, so keep retrying)
        if menuShown and once("charSelect", 3) then
            press(menuButton)
            ui.slotStatus.Text = "Opening Character Select…"
        end
        return
    end
    local slotFrame = cards:FindFirstChild("Slot" .. settings.slot, true)
    local action = slotFrame and slotFrame:FindFirstChild("Action", true)
    if not (action and action:IsA("TextButton")) then
        ui.slotStatus.Text = "Slot " .. settings.slot .. " not found"
        return
    end
    local text = string.upper(action.Text)
    if text:find("NEW CHARACTER", 1, true) or text:find("LOCKED", 1, true) or action:GetAttribute("Enabled") == false then
        ui.slotStatus.Text = "Slot " .. settings.slot .. " is empty or locked"
        return
    end
    if once("slot:" .. settings.slot, 6) then
        press(action)
        ui.slotStatus.Text = "Selected slot " .. settings.slot
    end
end

local function canStart()
    if workspace:GetAttribute("PBAdventureServer") == true then return false, "In the adventure server" end
    if LocalPlayer:GetAttribute("RPGGameplayReady") ~= true then return false, "Waiting for game to load" end
    if LocalPlayer:GetAttribute("PBInRun") == true then return false, "In a run" end
    if LocalPlayer:GetAttribute("PBGoingHome") == true or LocalPlayer:GetAttribute("PBTraveling") == true then return false, "Travelling" end
    return true
end

local function fireStart()
    lastLobbyFire = os.clock()
    RPGCommand:FireServer("RunLobby", lobbyPayload())
    ui.lobbyStatus.Text = "Sent: " .. lobbyDescribe()
end

ui.startNow.MouseButton1Click:Connect(function()
    local ok, why = canStart()
    if not ok then ui.lobbyStatus.Text = why return end
    fireStart()
end)

L.trySelectSlot = trySelectSlot
-- auto start: fires when the cooldown has passed and the lobby is ready
function L.autoStart()
    if os.clock() - lastLobbyFire < LOBBY_COOLDOWN then return end
    local ok, why = canStart()
    if ok then fireStart() else ui.lobbyStatus.Text = "Auto Start: " .. why end
end
end -- LOBBY LOGIC

---------------------------------------------------------------- COMBAT LOGIC
local battle, battleAt = nil, 0
local C = {} -- combat functions the event loop calls
do
local actedRevision, actedAt = nil, 0
local busyUntil = 0

local function combatOn(key) return settings.combat and (key == nil or settings[key]) end

local function snapshotOf(data)
    if type(data) ~= "table" then return nil end
    return data.snapshot or data.battle or data
end

local function aliveEnemies(state)
    local out = {}
    for _, e in ipairs(type(state.enemies) == "table" and state.enemies or {}) do
        local actor = type(e) == "table" and e.actor
        if actor and not e.defeated and (tonumber(actor.hp) or 0) > 0 then table.insert(out, e) end
    end
    return out
end

-- "boss" | "miniboss" | "normal" (state.boss / actor.boss / actor.miniBoss / actor.elite)
local function fightKind(state)
    if state.boss == true then return "boss" end
    local mini = state.miniBoss == true or state.miniboss == true or state.elite == true
    for _, e in ipairs(type(state.enemies) == "table" and state.enemies or {}) do
        local a = type(e) == "table" and e.actor
        if type(a) == "table" then
            if a.boss == true then return "boss" end
            if a.miniBoss == true or a.miniboss == true or a.elite == true then mini = true end
        end
    end
    return mini and "miniboss" or "normal"
end

local function pickEnemyIndex(state)
    local enemies = aliveEnemies(state)
    if #enemies == 0 then return tonumber(state.activeEnemyIndex) or 1 end
    local best = enemies[1]
    if settings.target == 1 then
        for _, e in ipairs(enemies) do
            if (tonumber(e.actor.hp) or 0) < (tonumber(best.actor.hp) or 0) then best = e end
        end
    end
    return tonumber(best.index) or 1
end

local function pickAllyUserId(state, action)
    local best, bestPct
    for _, p in ipairs(type(state.party) == "table" and state.party or {}) do
        if type(p) == "table" and p.userId then
            local hp, maxHp = tonumber(p.hp) or 0, math.max(1, tonumber(p.maxHp) or 1)
            local ok
            if action.targetDowned then ok = p.reviveAvailable == true else ok = hp > 0 end
            if ok and (not bestPct or hp / maxHp < bestPct) then best, bestPct = p, hp / maxHp end
        end
    end
    return best and best.userId or LocalPlayer.UserId
end

local function myHpPercent(state)
    local me = type(state.player) == "table" and state.player or nil
    if not (me and me.hp) then
        for _, p in ipairs(type(state.party) == "table" and state.party or {}) do
            if type(p) == "table" and p.userId == LocalPlayer.UserId then me = p break end
        end
    end
    if not (me and me.hp) then return nil end
    return 100 * (tonumber(me.hp) or 0) / math.max(1, tonumber(me.maxHp) or 1)
end

-- boss/miniboss winding up a special (game shows a telegraph / "HITS ON ITS NEXT TURN")
local function bossSpecialIncoming(state)
    for _, e in ipairs(aliveEnemies(state)) do
        local actor = e.actor
        local tele = actor.telegraph
        if type(tele) == "table" then
            local target = tonumber(tele.targetUserId)
            if target == nil or target == LocalPlayer.UserId then return true, actor.name end
        end
        local statuses = type(actor.statuses) == "table" and actor.statuses or {}
        if statuses.BossBrace then return true, actor.name end
        for _, s in pairs(statuses) do
            if type(s) == "table" and s.id == "BossBrace" then return true, actor.name end
        end
    end
    return false
end

local function findAction(state, predicate)
    for _, a in ipairs(type(state.actions) == "table" and state.actions or {}) do
        if type(a) == "table" and a.id and predicate(a) then return a end
    end
end

local function usable(a) return a and a.enabled ~= false end

local function isPotion(a)
    if categoryOf(a) ~= "Item" then return false end
    local s = string.lower(tostring(a.id) .. " " .. tostring(a.name or ""))
    return s:find("potion", 1, true) ~= nil or s:find("tonic", 1, true) ~= nil
end

local function sendAction(state, action, why)
    local payload = { battleId = state.id, actionId = action.id }
    local tt = tostring(action.targetType or "Self")
    if tt == "Enemy" or (tt == "Self" and categoryOf(action) == "Attack") then
        payload.targetEnemyIndex = pickEnemyIndex(state)
    elseif tt == "Ally" then
        payload.targetUserId = pickAllyUserId(state, action)
    end
    RPGCommand:FireServer("CombatAction", payload)
    setCombatStatus(why .. ": " .. tostring(action.name or action.id))
end

local function skillListFor(state)
    local kind = fightKind(state)
    local useBoss = settings.bossList and (kind == "boss" or (kind == "miniboss" and settings.miniAsBoss))
    return priorityFor(myClass(), useBoss and "boss" or "normal"), useBoss
end

-- where each list is in its rotation, per battle
local skillCursor = {}

-- returns skill (or nil), whether any listed skill exists in this battle, and the skill being waited for
local function pickSkill(state, list, byId, listKey)
    local ready = {} -- ticked skills this unit has in this battle, in list order
    for _, s in ipairs(list) do
        local a = s.on and byId[s.id]
        if a then table.insert(ready, a) end
    end
    if #ready == 0 then return nil, false end

    if settings.skillMode == 1 then -- top first
        for _, a in ipairs(ready) do
            if usable(a) then return a, true end
        end
        return nil, true
    end

    local key = tostring(state.id) .. ":" .. listKey
    local at = skillCursor[key] or 1
    if at > #ready then at = 1 end

    if settings.skillMode == 3 then -- wait in order: basic attack until this one is ready
        local a = ready[at]
        if usable(a) then
            skillCursor[key] = at % #ready + 1
            return a, true
        end
        return nil, true, a
    end

    for step = 0, #ready - 1 do -- rotate: next ready skill from where we left off
        local i = (at - 1 + step) % #ready + 1
        if usable(ready[i]) then
            skillCursor[key] = i % #ready + 1
            return ready[i], true
        end
    end
    return nil, true
end

local function chooseMove(state)
    local companion = state.activeUnit == "Companion"

    -- 1) low HP -> potion (uses the turn)
    if combatOn("autoPotion") and not companion then
        local hp = myHpPercent(state)
        if hp and hp < settings.potionHp then
            local potion = findAction(state, function(a) return isPotion(a) and usable(a) end)
            if potion then return potion, string.format("Potion (%d%% HP)", hp) end
        end
    end

    -- 2) boss special coming -> guard this turn
    if combatOn("autoGuard") then
        local incoming, who = bossSpecialIncoming(state)
        if incoming then
            local guard = findAction(state, function(a) return categoryOf(a) == "Guard" end)
            if usable(guard) then return guard, "Guard (" .. tostring(who or "boss") .. ")" end
        end
    end

    local attack = findAction(state, function(a) return categoryOf(a) == "Attack" and usable(a) end)

    -- 3) skills by priority (boss list or normal list)
    if combatOn("autoSkill") and not companion then
        local byId = {}
        for _, a in ipairs(type(state.actions) == "table" and state.actions or {}) do
            if type(a) == "table" and a.id then byId[a.id] = a end
        end
        local list, isBoss = skillListFor(state)
        local tag = isBoss and "Boss skill" or "Skill"
        local skill, wanted, waitingFor = pickSkill(state, list, byId, isBoss and "boss" or "normal")
        if skill then return skill, tag end
        if wanted then
            if settings.attackIfNoMana then
                local why = waitingFor and ("Attack (waiting for " .. tostring(waitingFor.name or waitingFor.id) .. ")") or "Attack (no skill ready)"
                if attack then return attack, why end
            else
                local meditate = findAction(state, function(a) return categoryOf(a) == "Meditate" and usable(a) end)
                if meditate then return meditate, "Meditate" end
            end
        end
    end

    -- 4) basic attack
    if combatOn("autoAttack") and attack then return attack, "Attack" end
    return nil
end

local function tryAct()
    local state = battle
    if not (settings.combat and state and state.canAct == true) then return end
    if os.clock() < busyUntil then return end
    if os.clock() - battleAt < settings.delay then return end
    local rev = tostring(state.id) .. ":" .. tostring(state.revision) .. ":" .. tostring(state.activeUnit)
    if actedRevision == rev and os.clock() - actedAt < 6 then return end
    local action, why = chooseMove(state)
    if action then
        actedRevision, actedAt = rev, os.clock()
        sendAction(state, action, why)
    end
end

---------------- minigames
local function warriorAnswer(data)
    local rounds, results, wait = {}, {}, 0
    for i, r in ipairs(type(data.rounds) == "table" and data.rounds or {}) do
        if i > 5 or type(r) ~= "table" then break end
        rounds[i] = r
    end
    if #rounds == 0 then rounds[1] = { targetPosition = 0.5, sweepSeconds = 1 } end
    for i, r in ipairs(rounds) do
        local target = tonumber(r.targetPosition) or 0.5
        local sweep = math.max(0.15, tonumber(r.sweepSeconds) or 1)
        local travel = r.reverse == true and (1 - target) or target
        wait += travel * sweep + 0.35
        results[i] = { pressed = true, position = target }
    end
    return results, wait
end

local function onMinigame(name, data)
    if not combatOn("perfectAttack") or type(data) ~= "table" or data.preview then return end
    local battleId, token = tostring(data.battleId or (battle and battle.id) or ""), tostring(data.token or "")
    if name == "WarriorBladeTimingStarted" then
        local results, wait = warriorAnswer(data)
        busyUntil = os.clock() + wait + 0.5
        task.delay(wait, function()
            RPGCommand:FireServer("WarriorBladeTimingResult", { battleId = battleId, token = token, results = results })
            setCombatStatus("Perfect blade x" .. #results)
        end)
    elseif name == "MageRhythmStarted" then
        local circles = type(data.circles) == "table" and #data.circles or 1
        local hits = math.max(1, math.min(3, circles))
        local secs = math.clamp(tonumber(data.circleSeconds) or 0.95, 0.15, 1.5)
        local wait = math.max(1.35, hits * (secs * 0.7 + 0.25))
        busyUntil = os.clock() + wait + 0.5
        task.delay(wait, function()
            RPGCommand:FireServer("MageRhythmResult", { battleId = battleId, token = token, hits = hits })
            setCombatStatus("Perfect cast " .. hits .. "/" .. hits)
        end)
    elseif name == "ThiefSlashStarted" then -- Thief, Fist, Archer, Bard, Spear
        local targets = type(data.targets) == "table" and #data.targets or 1
        local maxHits = math.floor(tonumber(data.maximumHits) or targets)
        local hits = math.max(1, math.min(math.clamp(maxHits, 1, 6), targets))
        local secs = math.clamp(tonumber(data.targetSeconds) or 0.78, 0.15, 1.25)
        local wait = math.max(1.1, hits * secs * 0.46) + 0.08 + hits * 0.15
        busyUntil = os.clock() + wait + 0.5
        task.delay(wait, function()
            RPGCommand:FireServer("ThiefSlashResult", { battleId = battleId, token = token, hits = hits })
            setCombatStatus("Perfect " .. tostring(data.style or "slash") .. " " .. hits .. "/" .. hits)
        end)
    end
end

local function onDefense(data)
    if not combatOn("perfectDodge") or type(data) ~= "table" then return end
    local who = tonumber(data.userId or data.targetUserId)
    if who and who ~= LocalPlayer.UserId then return end
    local startedAt, duration = tonumber(data.startedAt), tonumber(data.duration) or 0.85
    if not startedAt then return end
    local times = {}
    if type(data.marks) == "table" then
        for _, m in ipairs(data.marks) do table.insert(times, startedAt + (tonumber(m) or 0) * duration) end
    else
        table.insert(times, startedAt + (tonumber(data.target) or 0.5) * duration)
    end
    task.spawn(function()
        for _, t in ipairs(times) do
            waitUntilServer(t)
            -- pressedAt is the exact perfect moment; the server credits it back within its latency window
            RPGCommand:FireServer("DefenseTimingInput", { battleId = data.battleId, token = data.token, pressedAt = t })
        end
        setCombatStatus(#times > 1 and ("Perfect dodge x" .. #times) or "Perfect dodge")
    end)
end

-- block the game's own answer while we answer for it (otherwise it may send "0 hits" after ours)
local BLOCK = {
    WarriorBladeTimingResult = "perfectAttack",
    MageRhythmResult         = "perfectAttack",
    ThiefSlashResult         = "perfectAttack",
    DefenseTimingInput       = "perfectDodge",
}
pcall(function()
    if not (hookmetamethod and checkcaller and getnamecallmethod) then return end
    local wrap = newcclosure or function(f) return f end
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", wrap(function(self, ...)
        if self == RPGCommand and not checkcaller() and getnamecallmethod() == "FireServer" then
            local name, data = ...
            local key = BLOCK[name]
            if key and alive() and settings.combat and settings[key] and not (type(data) == "table" and data.preview) then
                return nil
            end
        end
        return oldNamecall(self, ...)
    end))
end)

---------------- hide minigame UI
local qteFrames = {}
local function trackQte(inst)
    if inst.Name == "PixelQTE" and inst:IsA("GuiObject") then table.insert(qteFrames, inst) end
end
for _, d in ipairs(PlayerGui:GetDescendants()) do trackQte(d) end
PlayerGui.DescendantAdded:Connect(trackQte)

local function hideMinigames()
    if not (settings.combat and settings.hideMinigame and (settings.perfectAttack or settings.perfectDodge)) then return end
    for i = #qteFrames, 1, -1 do
        local f = qteFrames[i]
        if not f.Parent then table.remove(qteFrames, i)
        elseif f.Visible then f.Visible = false end
    end
end

C.snapshotOf, C.fightKind, C.tryAct = snapshotOf, fightKind, tryAct
C.onMinigame, C.onDefense, C.hideMinigames = onMinigame, onDefense, hideMinigames
end -- COMBAT LOGIC

---------------------------------------------------------------- RUN LOGIC
local run         -- latest RunState
local runAt = 0
local R = {} -- run functions the event loop calls
do

local function runOn(key) return settings.autoRun and (key == nil or settings[key]) end

local function runSend(state, payload)
    payload.runId, payload.round, payload.phase = state.id, state.round, state.phase
    RPGCommand:FireServer("RunAction", payload)
end

local function modeOf(state)
    if state.tormentTier or type(state.gauntlet) == "table" then return "torment" end
    if state.land == "haunted" then return "halloween" end
    return "story"
end

local function storyExitAct(state)
    if not settings.storyNextAct then return tonumber(state.startAct) or 1 end
    return settings.storyExitAct -- 0 = never
end

local function wantsToLeave(state)
    if modeOf(state) ~= "story" then return false end
    local exitAct = storyExitAct(state)
    return exitAct > 0 and (tonumber(state.act) or 1) > exitAct
end

local function choosePath(state)
    local cards = type(state.choices) == "table" and state.choices or {}
    if #cards == 0 then return nil end
    local function indexOf(t)
        for i, c in ipairs(cards) do
            local ct = c.type == "dungeonReturn" and "retreat" or c.type
            if ct == t then return i end
        end
    end
    if indexOf("boss") then return indexOf("boss"), "Boss" end
    if wantsToLeave(state) and indexOf("retreat") then return indexOf("retreat"), "Turn Back (leaving)" end
    for _, p in ipairs(settings.pathPriority) do
        if p.on then
            local i = indexOf(p.id)
            if i then return i, PATH_NAME[p.id] or p.id end
        end
    end
    for i, c in ipairs(cards) do
        if c.type ~= "retreat" and c.type ~= "dungeonReturn" then return i, PATH_NAME[c.type] or tostring(c.type) end
    end
    return 1, "First card"
end

local function myMember(state)
    for _, m in ipairs(type(state.members) == "table" and state.members or {}) do
        if type(m) == "table" and m.userId == LocalPlayer.UserId then return m end
    end
    return {}
end

local function iAmReady(state)
    for _, id in ipairs(type(state.eventReady) == "table" and state.eventReady or {}) do
        if tonumber(id) == LocalPlayer.UserId or (type(id) == "table" and tonumber(id.userId) == LocalPlayer.UserId) then return true end
    end
    return false
end

local function handleEvent(state)
    local ev = type(state.eventData) == "table" and state.eventData or {}
    local kind = ev.kind
    local key = tostring(state.id) .. ":" .. tostring(state.round)

    if kind == "camp" then
        if once(key .. ":camp", 5) then
            runSend(state, { action = "eventChoice", option = settings.campChoice == 1 and "rest" or "sharpen" })
            setRunStatus("Camp: " .. (settings.campChoice == 1 and "Rest" or "Sharpen"))
            return
        end
    elseif kind == "shrine" then
        if settings.shrineTrain and once(key .. ":shrine", 5) then
            runSend(state, { action = "eventChoice", option = "train" })
            setRunStatus("Shrine: Train")
            return
        end
        if not settings.shrineTrain then setRunStatus("Shrine: waiting for you") return end
    elseif kind == "altar" then
        if once(key .. ":altar", 5) then
            runSend(state, { action = "eventChoice", option = settings.altarOffer and "offer" or "leave" })
            setRunStatus("Altar: " .. (settings.altarOffer and "Offer Blood" or "Walk Away"))
            return
        end
    elseif kind == "shop" then
        local gold = tonumber(myMember(state).gold) or math.huge
        for _, item in ipairs(type(ev.items) == "table" and ev.items or {}) do
            local price = tonumber(item.price) or 0
            if settings.shopBuy[item.id] and price <= gold and once(key .. ":buy:" .. tostring(item.id)) then
                runSend(state, { action = "eventChoice", item = item.id })
                setRunStatus("Shop: bought " .. tostring(item.label or item.id))
                return -- one purchase per tick; the next tick buys the next one
            end
        end
    end

    if not iAmReady(state) and once(key .. ":ready", 5) then
        runSend(state, { action = "eventReady" })
        setRunStatus("Event done: " .. tostring(kind or "?"))
    end
end

-- "next" | "replay" | "castle" | nil. state may be nil (then the lobby tab's mode is used)
local function endDecision(state, victory)
    local mode = state and modeOf(state) or MODES[settings.mode].id
    local decision
    if victory and mode == "torment" then
        local tier = tonumber(state and state.tormentTier) or settings.tier
        local nextTier = state and tonumber(state.tormentNext)
        if settings.tormentExitTier > 0 and tier >= settings.tormentExitTier then
            decision = "castle"
        elseif settings.tormentNextTier and (state == nil or (nextTier and nextTier == tier + 1)) then
            decision = "next"
        elseif settings.autoReplay then
            decision = "replay"
        end
    elseif victory then
        if settings.autoReplay then decision = "replay" end
    end
    if not decision and settings.autoCastle then decision = "castle" end
    return decision
end

local endSentAt = 0

local function handleEnd(state)
    local id = tostring(state.id)
    if state.finalVictory == true and once(id .. ":ending") then
        RPGCommand:FireServer("RunLobby", { action = "endingDone", runId = state.id })
    end
    if not once(id .. ":end", 12) then return end
    endSentAt = os.clock()

    local decision = endDecision(state, state.result == "victory")
    if decision == "next" then
        RPGCommand:FireServer("RunLobby", { action = "replayNext", tier = tonumber(state.tormentNext) })
        setRunStatus("Next tier: Torment " .. tostring(state.tormentNext))
    elseif decision == "replay" then
        RPGCommand:FireServer("RunLobby", { action = "replay" })
        setRunStatus("Replay")
    elseif decision == "castle" then
        RPGCommand:FireServer("RunLobby", { action = "replayDecline" })
        setRunStatus("Back to castle")
    else
        setRunStatus("Run over: waiting for you")
    end
end

local function tickRun()
    local state = run
    if not (settings.autoRun and state) then return end
    if os.clock() - runAt < settings.runDelay then return end
    local phase = state.phase
    if phase == "choose" and runOn("autoPath") then
        for _, v in ipairs(type(state.votes) == "table" and state.votes or {}) do
            if type(v) == "table" and v.userId == LocalPlayer.UserId then return end
        end
        if once(tostring(state.id) .. ":" .. tostring(state.round) .. ":vote", 6) then
            local i, why = choosePath(state)
            if i then
                runSend(state, { action = "vote", choice = i })
                setRunStatus("Path: " .. why)
            end
        end
    elseif phase == "event" then
        handleEvent(state)
    elseif phase == "story" and runOn("autoContinue") then
        if once(tostring(state.id) .. ":story", 6) then
            runSend(state, { action = "storyChoice", choice = "continue" })
            setRunStatus("Story: continue")
        end
    elseif phase == "ended" then
        handleEnd(state)
    end
end

-- click through the game's own screens while in a run:
--   "CONTINUE" (victory, chest) and, as a fallback, the end-of-run buttons
local function clickThrough()
    if not settings.autoRun then return end
    if not inAdventure() and not battle then return end
    local endButtons = {}
    for _, d in ipairs(PlayerGui:GetDescendants()) do
        if d:IsA("TextButton") and d.Visible then
            local text = string.upper(d.Text)
            if text:find("RETURN TO CASTLE", 1, true) then endButtons.castle = d
            elseif text:find("PLAY AGAIN", 1, true) then endButtons.replay = d
            elseif text:sub(1, 6) == "NEXT: " then endButtons.next = d end
            local isChest = d:FindFirstAncestor("ChestShade") ~= nil
            local isContinue = text:sub(1, 8) == "CONTINUE" and not text:find("CREATION", 1, true)
            if isContinue and ((isChest and settings.autoChest) or (not isChest and settings.autoContinue)) then
                if shownOnScreen(d) and once("click:" .. d:GetFullName(), 2) then
                    press(d)
                    setRunStatus(isChest and "Boss chest collected" or "Continue")
                end
            end
        end
    end

    -- end screen still up: either we never got the run state, or the remote didn't take. press the button.
    local castle = endButtons.castle
    if castle and shownOnScreen(castle) and (run == nil or run.phase ~= "ended" or os.clock() - endSentAt > 5) then
        local victory = endButtons.replay ~= nil
        local decision = endDecision(run and run.phase == "ended" and run or nil, victory)
        local btn = (decision == "next" and (endButtons.next or (settings.autoReplay and endButtons.replay)))
            or (decision == "replay" and endButtons.replay)
            or (decision == "castle" and castle)
        if btn and once("endbtn:" .. btn:GetFullName(), 6) then
            press(btn)
            setRunStatus("Pressed " .. string.lower(btn.Text))
        end
    end
end

R.runOn, R.tickRun, R.clickThrough = runOn, tickRun, clickThrough
end -- RUN LOGIC

---------------------------------------------------------------- AUTO SELL LOGIC
local sellNow -- set below
do
local function describeGear(raw)
    if not GearConfig then return nil end
    local ok, d = pcall(GearConfig.Describe, raw)
    return ok and d or nil
end

local function wornSet()
    local worn = {}
    if not profile then return worn end
    for _, uid in pairs(type(profile.gear) == "table" and profile.gear or {}) do worn[uid] = true end
    for _, uid in pairs(type(profile.vanity) == "table" and profile.vanity or {}) do worn[uid] = true end
    return worn
end

local function keptByName(name)
    local n = string.lower(tostring(name or ""))
    for k in pairs(settings.keepNames) do
        if n:find(k, 1, true) then return true end
    end
    return false
end

-- every bag item: { uid, name, kind, rarity, price, sell = bool }
local function scanBag()
    local out = {}
    if not (profile and type(profile.gearBag) == "table") then return out end
    local worn = wornSet()
    for uid, raw in pairs(profile.gearBag) do
        local d = describeGear(raw)
        if d then
            local canSell = true
            pcall(function() canSell = GearConfig.CanSell(raw) == true end)
            local price = 0
            pcall(function() price = tonumber(GearConfig.SellPrice(raw)) or 0 end)
            local entry = {
                uid = d.uid or uid, name = d.displayName or d.name or "?", baseName = d.name or "?",
                kind = d.gearKind, rarity = d.rarity, price = price,
            }
            entry.sell = canSell and not worn[uid] and not worn[entry.uid] and d.locked ~= true and d.starter ~= true
                and settings.sellKinds[entry.kind or ""] == true
                and settings.sellRarity[entry.rarity or ""] == true
                and not keptByName(entry.name)
            table.insert(out, entry)
        end
    end
    return out
end

local function toSell()
    local uids, gold = {}, 0
    for _, e in ipairs(scanBag()) do
        if e.sell then table.insert(uids, e.uid); gold += e.price end
    end
    return uids, gold
end

function refreshSellPreview()
    if not profile then
        ui.sellPreview.Text = "Waiting for your bag…"
        return
    end
    local uids, gold = toSell()
    ui.sellPreview.Text = string.format("%d items  (+%d gold)", #uids, gold)
end

function renderBagNames()
    for _, c in ipairs(ui.bagList:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    ui.bagList:SetAttribute("rows", 0)
    local byName, names = {}, {}
    for _, e in ipairs(scanBag()) do
        local key = string.lower(e.baseName)
        if not byName[key] then
            byName[key] = { name = e.baseName, count = 0, rarity = e.rarity, kind = e.kind }
            table.insert(names, key)
        end
        byName[key].count += 1
    end
    table.sort(names)
    if #names == 0 then
        row(ui.bagList, profile and "Bag is empty" or "Waiting for your bag…", profile and nil or "Loads a few seconds after you reach the lobby")
        return
    end
    local rarityColor = {}
    for _, r in ipairs(RARITIES) do rarityColor[r.id] = r.color end
    for _, key in ipairs(names) do
        local info = byName[key]
        local r = row(ui.bagList, nil, nil, 40)
        label(r, info.name, 12, rarityColor[info.rarity] or T.text, FONT_SEMI, { Position = UDim2.fromOffset(0, 5), Size = UDim2.new(1, -40, 0, 16) })
        label(r, string.format("%s · %s · x%d", tostring(info.kind or "?"), tostring(info.rarity or "?"), info.count), 10, T.muted, FONT, {
            Position = UDim2.fromOffset(0, 21), Size = UDim2.new(1, -40, 0, 14),
        })
        checkbox(r, function() return settings.keepNames[key] == true end, function()
            settings.keepNames[key] = (not settings.keepNames[key]) or nil
            save(); ui.renderKeep(); refreshSellPreview()
        end)
    end
end

local lastSellKey, lastSellAt = nil, 0
function sellNow(manual)
    if not profile then ui.sellStatus.Text = "No bag data yet" return end
    local uids, gold = toSell()
    if #uids == 0 then
        if manual then ui.sellStatus.Text = "Nothing matches" end
        return
    end
    table.sort(uids)
    local key = table.concat(uids, ",")
    -- don't spam the same request if the server ignored it
    if not manual and key == lastSellKey and os.clock() - lastSellAt < 30 then return end
    lastSellKey, lastSellAt = key, os.clock()
    for i = 1, #uids, 50 do -- chunks, in case the server limits the list
        local chunk = {}
        for j = i, math.min(i + 49, #uids) do table.insert(chunk, uids[j]) end
        RPGCommand:FireServer("GearSellMany", { uids = chunk })
    end
    ui.sellStatus.Text = string.format("Sold %d (+%d gold)", #uids, gold)
end
ui.sellNowBtn.MouseButton1Click:Connect(function() sellNow(true) end)
end -- AUTO SELL LOGIC

---------------------------------------------------------------- AUTO FORGE LOGIC
-- Blacksmith hone: ProfileRequest:InvokeServer("Village", { action = "hone", item = <gear uid>, hero = <heroSlot> })
-- reply { ok, profile, message = "SUCCESS! …" | "FAILED! …" }
local forgeTick -- set below
local villageBusy = false -- the Village service answers "One thing at a time." to overlapping requests
do
-- redraw with real pictures once the game's art has loaded (tiles show a letter until then)
table.insert(Icons.onReady, function() renderForge(true) end)

local RARITY_ORDER, RARITY_COLOR = {}, {}
for i, r in ipairs(RARITIES) do RARITY_ORDER[r.id], RARITY_COLOR[r.id] = i, r.color end

local function maxPlus() return (GearConfig and tonumber(GearConfig.MaxPlus)) or 10 end

local function whetstoneId(rarity)
    local ok, w = pcall(function() return GearConfig.WhetstoneFor(rarity) end)
    return ok and type(w) == "table" and w.id or nil
end

local function honeGold(rarity, plus)
    local ok, g = pcall(function() return GearConfig.HoneGold(rarity, plus) end)
    return ok and tonumber(g) or 0
end

local function stonesOf(id)
    local inv = profile and type(profile.inventory) == "table" and profile.inventory or {}
    return id and (tonumber(inv[id]) or 0) or 0
end

local function gold() return math.floor(tonumber(profile and profile.gold) or 0) end

-- gear pieces in the bag: { uid, desc, raw, name, kind, rarity, plus, worn }
local function forgeItems()
    local out = {}
    if not (profile and GearConfig and type(profile.gearBag) == "table") then return out end
    local worn = {}
    for _, uid in pairs(type(profile.gear) == "table" and profile.gear or {}) do worn[uid] = true end
    for uid, raw in pairs(profile.gearBag) do
        local ok, d = pcall(GearConfig.Describe, raw)
        if ok and d then
            table.insert(out, {
                uid = uid, desc = d, name = d.name or "?", kind = d.gearKind, rarity = d.rarity,
                plus = tonumber(d.plus) or 0, worn = worn[uid] == true,
            })
        end
    end
    table.sort(out, function(a, b)
        if a.worn ~= b.worn then return a.worn end
        local ra, rb = RARITY_ORDER[a.rarity] or 0, RARITY_ORDER[b.rarity] or 0
        if ra ~= rb then return ra > rb end
        if a.plus ~= b.plus then return a.plus > b.plus end
        return a.name < b.name
    end)
    return out
end

-- the game picks the art + colours for a piece with PixelIcons.GearIcon; we draw it with Icons.draw
local function drawPicture(parent, entry)
    local PI = Icons.mod
    local drawn = false
    if PI and PI.GearIcon then
        local ok, err = pcall(function()
            local key, palette = PI.GearIcon(entry.desc, entry.kind)
            drawn = Icons.draw(parent, key, 52, palette, parent.ZIndex + 1) ~= nil
        end)
        if not ok then warn("[PixelHelper] gear picture: " .. tostring(err)) end
    end
    if not drawn then
        label(parent, string.sub(entry.kind or "?", 1, 1), 22, RARITY_COLOR[entry.rarity] or T.text, FONT_BOLD, {
            Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = parent.ZIndex + 1,
        })
    end
end

local MAX_TILES = 60
local lastKey

function renderForge(force)
    local f = ui.forge
    f.gold.Text = profile and tostring(gold()) or "—"
    local items = forgeItems()

    -- whetstones by rarity, e.g. "Common 3 · Rare 1"
    local parts = {}
    for _, r in ipairs(RARITIES) do
        local n = stonesOf(whetstoneId(r.id))
        if n > 0 then table.insert(parts, r.id .. " " .. n) end
    end
    f.stones.Text = #parts > 0 and table.concat(parts, " · ") or (profile and "none" or "—")

    -- only rebuild the grid when something visible changed
    local keyParts = { tostring(settings.forgeFilter) }
    for _, e in ipairs(items) do
        table.insert(keyParts, e.uid .. ":" .. e.plus .. (settings.forgePick[e.uid] and "*" or ""))
    end
    local key = table.concat(keyParts, ",")
    if key == lastKey and not force then return end
    lastKey = key

    for _, c in ipairs(f.grid:GetChildren()) do
        if c:IsA("GuiObject") then c:Destroy() end
    end
    local shown = 0
    for _, e in ipairs(items) do
        local ticked = settings.forgePick[e.uid] == true
        local visible = settings.forgeFilter == 1 or (settings.forgeFilter == 2 and e.worn) or (settings.forgeFilter == 3 and ticked)
        if visible and shown < MAX_TILES then
            shown += 1
            local rc = RARITY_COLOR[e.rarity] or T.text
            local tile = new("TextButton", {
                Parent = f.grid, LayoutOrder = shown, AutoButtonColor = false, Text = "",
                BackgroundColor3 = ticked and T.raised2 or T.raised, BorderSizePixel = 0,
            }, { corner(12) })
            new("UIStroke", {
                Parent = tile, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
                Color = ticked and T.accent or rc, Thickness = ticked and 2 or 1, Transparency = ticked and 0 or 0.6,
            })
            local pic = new("Frame", {
                Parent = tile, BackgroundColor3 = T.bg, BorderSizePixel = 0,
                Position = UDim2.fromOffset(10, 8), Size = UDim2.new(1, -20, 0, 60), ZIndex = 2,
            }, { corner(10) })
            pcall(drawPicture, pic, e)
            label(tile, "+" .. e.plus, 11, e.plus >= maxPlus() and T.amber or T.text, FONT_BOLD, {
                Position = UDim2.fromOffset(14, 10), Size = UDim2.fromOffset(30, 14), ZIndex = 5,
            })
            if e.worn then
                label(tile, "E", 10, T.green, FONT_BOLD, {
                    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 52), Size = UDim2.fromOffset(12, 12),
                    TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 5,
                })
            end
            if ticked then
                local check = new("Frame", {
                    Parent = tile, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 6),
                    Size = UDim2.fromOffset(18, 18), BackgroundColor3 = T.accent, BorderSizePixel = 0, ZIndex = 6,
                }, { corner(9) })
                label(check, "✓", 11, T.bg, FONT_BOLD, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 7 })
            end
            label(tile, e.name, 11, rc, FONT_SEMI, {
                Position = UDim2.fromOffset(6, 72), Size = UDim2.new(1, -12, 0, 26),
                TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top,
                TextTruncate = Enum.TextTruncate.AtEnd,
            })
            label(tile, tostring(e.kind or "?"), 9, T.muted, FONT, {
                Position = UDim2.fromOffset(6, 99), Size = UDim2.new(1, -12, 0, 12), TextXAlignment = Enum.TextXAlignment.Center,
            })
            tile.MouseButton1Click:Connect(function()
                settings.forgePick[e.uid] = (not settings.forgePick[e.uid]) or nil
                save(); renderForge(true)
            end)
        end
    end
    if not profile then
        f.empty.Text = "Waiting for your bag… it loads a few seconds after you reach the lobby."
    elseif shown == 0 then
        f.empty.Text = settings.forgeFilter == 3 and "Nothing ticked yet. Switch to All and tap a picture." or "No gear here."
    else
        f.empty.Text = ""
    end
end


-- next ticked piece we can afford, or nil + reason
local function nextForge()
    local target = math.min(settings.forgeTarget, maxPlus())
    local reason = "Nothing ticked"
    for _, e in ipairs(forgeItems()) do
        if settings.forgePick[e.uid] then
            if e.plus >= target then
                reason = "All ticked gear is at +" .. target
            else
                local stone = whetstoneId(e.rarity)
                local cost = honeGold(e.rarity, e.plus)
                if stonesOf(stone) < 1 then
                    reason = "Need a " .. tostring(e.rarity) .. " whetstone"
                elseif gold() - cost < settings.forgeReserve then
                    reason = "Not enough gold (" .. cost .. ")"
                else
                    return e
                end
            end
        end
    end
    return nil, reason
end

local function hone(e)
    local req = Remotes:FindFirstChild("ProfileRequest")
    if not req then ui.forge.status.Text = "Blacksmith not available here" return end
    villageBusy = true
    local before = e.plus
    local ok, result = pcall(function()
        return req:InvokeServer("Village", {
            action = "hone", item = e.uid,
            hero = profile and profile.heroSlot ~= nil and tostring(profile.heroSlot) or nil,
        })
    end)
    villageBusy = false
    if not ok or type(result) ~= "table" then
        ui.forge.status.Text = "No answer from the server"
        return
    end
    if type(result.profile) == "table" then
        profile = result.profile
        refreshSellPreview()
        renderBagNames()
    end
    local msg = tostring(result.message or result.error or (result.ok == false and "Refused" or "Done"))
    local success = msg:sub(1, 8) == "SUCCESS!"
    ui.forge.status.Text = string.format("%s +%d: %s", e.name, before, success and "success" or (msg:sub(1, 7) == "FAILED!" and "failed" or msg))
    renderForge()
end

local lastHone = 0
function forgeTick()
    if not (settings.autoForge and profile) or villageBusy then return end
    if battle or inAdventure() then return end
    if os.clock() - lastHone < 1.2 then return end
    local e, why = nextForge()
    if not e then ui.forge.status.Text = why return end
    lastHone = os.clock()
    task.spawn(hone, e)
end

ui.forge.onceBtn.MouseButton1Click:Connect(function()
    if villageBusy then return end
    if not profile then ui.forge.status.Text = "No bag data yet" return end
    local e, why = nextForge()
    if not e then ui.forge.status.Text = why return end
    task.spawn(hone, e)
end)
end -- AUTO FORGE LOGIC

---------------------------------------------------------------- PROFILE (bag, gold, whetstones)
-- The game only pushes "Profile" after loot or menus, so once the lobby screen is up we ask the
-- Village service ourselves: ProfileRequest:InvokeServer("Village", { action = "status" }) -> { profile = … }.
-- During a battle it answers { ok = false, status = "Busy" }; overlapping calls get "One thing at a time."
local setProfile, requestProfile
do
local function looksLikeProfile(t)
    return type(t) == "table" and t.gold ~= nil and (t.inventory ~= nil or t.gearBag ~= nil)
end

-- search a few levels deep in case the reply shape changes
local function findProfile(data, depth, seen)
    depth, seen = depth or 0, seen or {}
    if type(data) ~= "table" or depth > 5 or seen[data] then return nil end
    seen[data] = true
    if looksLikeProfile(data.profile) then return data.profile end
    if looksLikeProfile(data) then return data end
    for _, v in pairs(data) do
        local found = findProfile(v, depth + 1, seen)
        if found then return found end
    end
end

function setProfile(p)
    profile = p
    refreshSellPreview()
    renderBagNames()
    renderForge()
    renderPets()
end

local lastAsk = -math.huge
function requestProfile(force)
    if villageBusy then return end
    if not force and os.clock() - lastAsk < (profile and 30 or 6) then return end
    if LocalPlayer:GetAttribute("RPGGameplayReady") ~= true or LocalPlayer:GetAttribute("PBProfileGate") == true then return end
    if battle or inBattleNow() then return end
    local req = Remotes:FindFirstChild("ProfileRequest")
    if not req then return end
    lastAsk, villageBusy = os.clock(), true
    task.spawn(function()
        local ok, res = pcall(function() return req:InvokeServer("Village", { action = "status" }) end)
        villageBusy = false
        local p = ok and findProfile(res)
        if p then
            setProfile(p)
        elseif ok and type(res) == "table" and res.ok == false then
            lastAsk = os.clock() - (profile and 30 or 6) + 6 -- busy / one thing at a time: try again in ~6s
        end
    end)
end
end -- PROFILE

---------------------------------------------------------------- PETS LOGIC
-- Ranch:  RPGCommand:FireServer("Ranch", { action = "hatch", itemId = <egg item> })
--         RPGCommand:FireServer("Ranch", { action = "release", petId = <pet id> })
-- Candy:  ProfileRequest:InvokeServer("Village", { action = "candy_buy", item = "EggHaunted", hero = <heroSlot> })
-- profile.pets = { { id, s = species, r = rarity index, lv, locked } }, profile.petId = active pet,
-- profile.ranch = ranch tier, profile.inventory[<egg item>] / [HarvestCandy] = counts
local petTick -- set below
do
local HAUNTED_EGG, EGG_PRICE, EGG_MAX = "EggHaunted", 220, 99
local RARITY_NAMES = { "Common", "Uncommon", "Rare", "Legendary", "Divine", "Mythic" }
local RARITY_COLORS = {
    Color3.fromRGB(205, 207, 199), Color3.fromRGB(110, 210, 110), Color3.fromRGB(90, 160, 255),
    Color3.fromRGB(255, 176, 50), Color3.fromRGB(255, 110, 200), Color3.fromRGB(255, 214, 90),
}

local function inv() return profile and type(profile.inventory) == "table" and profile.inventory or {} end
local function count(id) return math.max(0, math.floor(tonumber(inv()[id]) or 0)) end
local function candy() return count(HalloweenConfig and HalloweenConfig.CandyId or "HarvestCandy") end

local function pets()
    local out = {}
    for _, p in ipairs(profile and type(profile.pets) == "table" and profile.pets or {}) do
        if type(p) == "table" and p.id ~= nil then table.insert(out, p) end
    end
    return out
end

local function ranch()
    local tiers = PetConfig and PetConfig.Ranch or {}
    local tier = math.clamp(math.floor(tonumber(profile and profile.ranch) or 1), 1, math.max(1, #tiers))
    return tiers[tier] or { slots = 0, maxRarity = 1 }
end

-- every egg the game knows: { id, name, rarityIndex, odds }
local eggDefs
local function eggs()
    if eggDefs then return eggDefs end
    eggDefs = {}
    local defs = {}
    pcall(function() defs = PetConfig.ItemDefinitions() end)
    for id, d in pairs(defs) do
        local e = PetConfig.EggByItem[id]
        local shown = 1
        pcall(function() shown = PetConfig.EggShownRarity(e) end)
        table.insert(eggDefs, {
            id = id, name = d.name or id, rarityIndex = PetConfig.RarityIndex[e and e.rarity or ""] or 1,
            shown = shown, special = PetConfig.EggOdds and PetConfig.EggOdds[id] ~= nil,
        })
    end
    table.sort(eggDefs, function(a, b)
        if a.shown ~= b.shown then return a.shown < b.shown end
        return a.name < b.name
    end)
    return eggDefs
end

local function speciesName(p)
    local s = PetConfig and PetConfig.Species and PetConfig.Species[tostring(p.s)]
    return s and s.name or tostring(p.s or "Pet")
end

local function isBound(p)
    local ok, b = pcall(function() return PetConfig.Bound(p) end)
    return ok and b == true
end

local function canRelease(p)
    if p.locked or p.id == (profile and profile.petId) or isBound(p) then return false end
    local rarity = RARITY_NAMES[tonumber(p.r) or 1]
    if not settings.releaseRarity[rarity or ""] then return false end
    if settings.releaseKeepLevel > 0 and (tonumber(p.lv) or 1) >= settings.releaseKeepLevel then return false end
    return true
end

local function drawIcon(parent, key, fallback, color)
    local holder = Icons.draw(parent, key, 30, nil, 3)
    if not holder then
        label(parent, fallback, 15, color or T.muted, FONT_BOLD, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 3 })
    end
end

function renderPets()
    local P = ui.pets
    local r = ranch()
    local list = pets()
    P.ranch.Text = profile and string.format("%d / %d pets  ·  hatches up to %s", #list, r.slots or 0, RARITY_NAMES[r.maxRarity or 1] or "?") or "—"
    P.candy.Text = profile and tostring(candy()) or "—"

    -- egg list: picture, name, owned count, tick to hatch
    for _, c in ipairs(P.eggList:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
    P.eggList:SetAttribute("rows", 0)
    local any = false
    for _, e in ipairs(eggs()) do
        local owned = count(e.id)
        if owned > 0 or settings.hatchEggs[e.id] then
            any = true
            local rr = row(P.eggList, nil, nil, 46)
            local pic = new("Frame", { Parent = rr, BackgroundColor3 = T.bg, BorderSizePixel = 0, Position = UDim2.new(0, 0, 0.5, -17), Size = UDim2.fromOffset(34, 34), ZIndex = 2 }, { corner(8) })
            drawIcon(pic, e.id, "E", RARITY_COLORS[e.shown])
            label(rr, e.name, 12, RARITY_COLORS[e.shown] or T.text, FONT_SEMI, { Position = UDim2.fromOffset(44, 6), Size = UDim2.new(1, -90, 0, 18) })
            local tooRare = not e.special and e.rarityIndex > (r.maxRarity or 1)
            label(rr, "x" .. owned .. (tooRare and "  ·  ranch too small" or ""), 10, tooRare and T.red or T.muted, FONT, {
                Position = UDim2.fromOffset(44, 24), Size = UDim2.new(1, -90, 0, 14),
            })
            checkbox(rr, function() return settings.hatchEggs[e.id] == true end, function()
                settings.hatchEggs[e.id] = (not settings.hatchEggs[e.id]) or nil
                save()
            end)
        end
    end
    if not any then
        local rr = row(P.eggList, nil, nil, 34)
        label(rr, profile and "You have no eggs right now." or "Waiting for your bag…", 12, T.faint, FONT, { Size = UDim2.fromScale(1, 1) })
    end

    -- pets list
    for _, c in ipairs(P.petList:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
    P.petList:SetAttribute("rows", 0)
    table.sort(list, function(a, b)
        if (a.r or 1) ~= (b.r or 1) then return (a.r or 1) > (b.r or 1) end
        return (a.lv or 1) > (b.lv or 1)
    end)
    for i, p in ipairs(list) do
        if i > 40 then break end
        local rarity = tonumber(p.r) or 1
        local rr = row(P.petList, nil, nil, 40)
        local pic = new("Frame", { Parent = rr, BackgroundColor3 = T.bg, BorderSizePixel = 0, Position = UDim2.new(0, 0, 0.5, -15), Size = UDim2.fromOffset(30, 30), ZIndex = 2 }, { corner(8) })
        drawIcon(pic, "paw", "P", RARITY_COLORS[rarity])
        label(rr, speciesName(p), 12, RARITY_COLORS[rarity] or T.text, FONT_SEMI, { Position = UDim2.fromOffset(40, 4), Size = UDim2.new(1, -110, 0, 16) })
        label(rr, (RARITY_NAMES[rarity] or "?") .. "  ·  Lv " .. tostring(p.lv or 1), 10, T.muted, FONT, { Position = UDim2.fromOffset(40, 21), Size = UDim2.new(1, -110, 0, 14) })
        local tag = (p.id == profile.petId and "ACTIVE") or (p.locked and "LOCKED") or (isBound(p) and "BOUND") or (canRelease(p) and "RELEASE") or ""
        label(rr, tag, 10, tag == "RELEASE" and T.red or T.green, FONT_BOLD, {
            AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0, 70, 1, 0), TextXAlignment = Enum.TextXAlignment.Right,
        })
    end
    if #list == 0 then
        local rr = row(P.petList, nil, nil, 34)
        label(rr, profile and "No pets yet." or "Waiting for your bag…", 12, T.faint, FONT, { Size = UDim2.fromScale(1, 1) })
    end
end

local lastAction = 0

local function refreshSoon()
    task.delay(1.5, function() requestProfile(true) end)
end

local function tryRelease()
    if not settings.autoRelease then return false end
    for _, p in ipairs(pets()) do
        if canRelease(p) and once("release:" .. tostring(p.id), 6) then
            RPGCommand:FireServer("Ranch", { action = "release", petId = p.id })
            ui.pets.releaseStatus.Text = string.format("Released %s (%s Lv %s)", speciesName(p), RARITY_NAMES[tonumber(p.r) or 1] or "?", tostring(p.lv or 1))
            refreshSoon()
            return true
        end
    end
    ui.pets.releaseStatus.Text = "Nothing to release"
    return false
end

local function tryHatch()
    if not settings.autoHatch then return false end
    local r = ranch()
    if #pets() >= (r.slots or 0) then ui.pets.hatchStatus.Text = "Ranch full" return false end
    for _, e in ipairs(eggs()) do
        if settings.hatchEggs[e.id] and count(e.id) > 0 and (e.special or e.rarityIndex <= (r.maxRarity or 1)) then
            if once("hatch:" .. e.id, 3) then
                RPGCommand:FireServer("Ranch", { action = "hatch", itemId = e.id })
                ui.pets.hatchStatus.Text = "Hatching " .. e.name
                refreshSoon()
                return true
            end
            return false
        end
    end
    ui.pets.hatchStatus.Text = "No ticked eggs left"
    return false
end

local function tryBuyEgg()
    if not settings.autoCandyEgg or villageBusy then return false end
    local open = true
    pcall(function() open = HalloweenConfig.Active(workspace:GetServerTimeNow()) end)
    if not open then ui.pets.candyStatus.Text = "Candy Witch stall is closed" return false end
    if count(HAUNTED_EGG) >= EGG_MAX then ui.pets.candyStatus.Text = "Holding 99 eggs" return false end
    if candy() - EGG_PRICE < settings.candyKeep then
        ui.pets.candyStatus.Text = string.format("Stopped: keeping %d candy", settings.candyKeep)
        return false
    end
    local req = Remotes:FindFirstChild("ProfileRequest")
    if not req then return false end
    villageBusy = true
    task.spawn(function()
        local ok, res = pcall(function()
            return req:InvokeServer("Village", {
                action = "candy_buy", item = HAUNTED_EGG,
                hero = profile and profile.heroSlot ~= nil and tostring(profile.heroSlot) or nil,
            })
        end)
        villageBusy = false
        if ok and type(res) == "table" then
            if type(res.profile) == "table" then setProfile(res.profile) end
            ui.pets.candyStatus.Text = res.ok == false and tostring(res.message or "Refused") or "Bought a Haunted Egg"
        else
            ui.pets.candyStatus.Text = "No answer from the server"
        end
    end)
    return true
end

function petTick()
    if not profile or battle or inAdventure() then return end
    if os.clock() - lastAction < 1.5 then return end
    -- release first so a hatch has room; one action per tick
    if tryRelease() or tryHatch() or tryBuyEgg() then lastAction = os.clock() end
end
end -- PETS LOGIC

---------------------------------------------------------------- events
RPGState.OnClientEvent:Connect(function(name, data)
    if not alive() then return end
    if name == "BattleStarted" or name == "BattleUpdated" then
        local state = C.snapshotOf(data)
        if type(state) == "table" and state.id ~= nil then
            if battle and battle.id == state.id and tonumber(battle.revision) and tonumber(state.revision)
                and tonumber(state.revision) < tonumber(battle.revision) then
                return -- stale
            end
            local first = battle == nil or battle.id ~= state.id
            battle, battleAt = state, os.clock()
            learnFromBattle(state)
            if first then
                setCombatStatus(settings.combat and "In battle" or "Off")
                local k = C.fightKind(state)
                ui.fightKind.Text = k == "boss" and "Boss" or (k == "miniboss" and "Mini-boss / Elite" or "Normal mobs")
            end
        end
    elseif name == "BattleEnded" then
        battle = nil
        ui.fightKind.Text = "—"
        setCombatStatus(settings.combat and "Battle ended" or "Off")
    elseif name == "DefenseTimingStarted" then
        C.onDefense(data)
    elseif name == "WarriorBladeTimingStarted" or name == "MageRhythmStarted" or name == "ThiefSlashStarted" then
        C.onMinigame(name, data)
    elseif name == "RunState" and type(data) == "table" then
        if not run or run.id ~= data.id or run.round ~= data.round or run.phase ~= data.phase then runAt = os.clock() end
        run = data
    elseif name == "Profile" and type(data) == "table" then
        local p = data.profile or data
        if type(p) == "table" and (p.gearBag or p.gear) then
            setProfile(p)
        end
    elseif name == "LightDialogue" and R.runOn("autoDeath") then
        local payload = type(data) == "table" and data or {}
        task.delay(math.max(1, settings.runDelay), function()
            RPGCommand:FireServer("LightContinue", { passage = payload.passageRequired == true })
            setRunStatus("Continued after death")
        end)
    end
end)

pcall(function() RPGCommand:FireServer("RunAction", { action = "state" }) end)
ui.fightKind.Text = "—"
refreshSellPreview()
renderBagNames()
renderForge(true)
renderPets()

task.spawn(function()
    local lastClick, lastSync, lastRunSync, lastSell = 0, 0, 0, 0
    while alive() and gui.Parent do
        pcall(L.trySelectSlot)
        if settings.auto then pcall(L.autoStart) end
        -- in a run but no RunState yet (script loaded after it was sent): ask for it
        if settings.autoRun and inAdventure() and os.clock() - lastRunSync > 3 and (run == nil or os.clock() - runAt > 20) then
            lastRunSync = os.clock()
            pcall(function() RPGCommand:FireServer("RunAction", { action = "state" }) end)
        end
        -- started the script mid-battle (or missed the snapshot): ask the server to resend it
        if not battle and inBattleNow() and os.clock() - lastSync > 3 then
            lastSync = os.clock()
            pcall(function() RPGCommand:FireServer("SyncBattle") end)
            if settings.combat then setCombatStatus("In battle: syncing…") end
        elseif battle and not inBattleNow() and os.clock() - battleAt > 10 then
            battle = nil -- battle ended without a BattleEnded we saw
            setCombatStatus(settings.combat and "Waiting for a battle" or "Off")
        end
        pcall(C.tryAct)
        pcall(R.tickRun)
        if os.clock() - lastClick > 0.8 then
            lastClick = os.clock()
            pcall(R.clickThrough)
        end
        if settings.autoSell and not battle and os.clock() - lastSell > 5 then
            lastSell = os.clock()
            pcall(sellNow, false)
        end
        pcall(requestProfile)
        pcall(forgeTick)
        pcall(petTick)
        if (battle or inBattleNow()) and settings.combat then setLive("In battle", true)
        elseif inAdventure() and settings.autoRun then setLive("Run: " .. tostring(run and run.phase or "syncing"), true)
        elseif inAdventure() then setLive("Auto Run is off", false)
        elseif settings.auto then setLive("Auto Start armed", true)
        else setLive("Idle", false) end
        task.wait(0.2)
    end
end)

---------------------------------------------------------------- bubble, resize, cursor
do
local iconImage = ""
pcall(function()
    local getAsset = getcustomasset or getsynasset
    if getAsset and isfile and isfile(ICON_FILE) then iconImage = getAsset(ICON_FILE) end
end)
brandIcon.Image = iconImage

local bubble = new("TextButton", {
    Parent = gui, Name = "Bubble", AutoButtonColor = false, Text = "", Visible = false, ZIndex = 20,
    Size = UDim2.fromOffset(58, 58), Position = UDim2.new(0, 24, 0.5, -29),
    BackgroundColor3 = T.card, BorderSizePixel = 0,
}, { corner(29), new("UIStroke", { Color = T.accent, Thickness = 2, Transparency = 0.2 }) })
local bubbleImg = new("ImageLabel", {
    Parent = bubble, BackgroundTransparency = 1, Image = iconImage, ScaleType = Enum.ScaleType.Fit, ZIndex = 21,
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.86, 0.86),
})
if iconImage == "" then -- no picture file: a simple letter instead
    bubbleImg.Visible = false
    label(bubble, "P", 22, T.accentT, FONT_BOLD, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 21 })
end
local bubbleDot = new("Frame", {
    Parent = bubble, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -2, 0, 2), Size = UDim2.fromOffset(12, 12),
    BackgroundColor3 = T.faint, BorderSizePixel = 0, ZIndex = 22,
}, { corner(6), new("UIStroke", { Color = T.card, Thickness = 2 }) })

local function setHidden(hidden)
    if hidden then
        window.Visible = false
        bubble.Visible = true
        bubble.Size = UDim2.fromOffset(20, 20)
        tween(bubble, { Size = UDim2.fromOffset(58, 58) }, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
    else
        bubble.Visible = false
        window.Visible = true
    end
end
btnHide.MouseButton1Click:Connect(function() setHidden(true) end)

do -- drag the bubble; a click without dragging opens the window
    local dragging, moved, startPos, startInput
    bubble.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, moved, startPos, startInput = true, false, bubble.Position, input.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - startInput
            if d.Magnitude > 4 then moved = true end
            bubble.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
            dragging = false
            if not moved then setHidden(false) end
        end
    end)
    bubble.MouseEnter:Connect(function() tween(bubble, { Size = UDim2.fromOffset(64, 64) }) end)
    bubble.MouseLeave:Connect(function() tween(bubble, { Size = UDim2.fromOffset(58, 58) }) end)
end

---------------- unload
local function unload()
    if genv.__PixelHelperToken == RUN_TOKEN then genv.__PixelHelperToken = nil end
    gui:Destroy()
end
ui.unloadBtn.MouseButton1Click:Connect(unload)

---------------- resize: drag the right edge, bottom edge or bottom-right corner
do
    local function grip(name, props, dx, dy)
        local g = new("TextButton", { Parent = window, Name = name, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, ZIndex = 50 })
        for k, v in pairs(props) do g[k] = v end
        local dragging, startSize, startMouse
        g.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging, startSize, startMouse = true, Vector2.new(WIDTH, HEIGHT), input.Position
            end
        end)
        UserInputService.InputChanged:Connect(function(input)
            if not dragging then return end
            if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
            local d = input.Position - startMouse
            local screen = gui.AbsoluteSize
            WIDTH  = math.clamp(startSize.X + d.X * dx, MIN_W, math.max(MIN_W, screen.X - 20))
            HEIGHT = math.clamp(startSize.Y + d.Y * dy, MIN_H, math.max(MIN_H, screen.Y - 20))
            window.Size = UDim2.fromOffset(WIDTH, HEIGHT)
        end)
        UserInputService.InputEnded:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
                dragging = false
                settings.winW, settings.winH = WIDTH, HEIGHT
                save()
            end
        end)
        return g
    end
    grip("ResizeRight",  { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0, 6, 1, -16) }, 1, 0)
    grip("ResizeBottom", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, -16, 0, 6) }, 0, 1)
    local cornerGrip = grip("ResizeCorner", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, 0, 1, 0), Size = UDim2.fromOffset(16, 16) }, 1, 1)
    for i = 0, 2 do -- small marks so the corner is discoverable
        new("Frame", {
            Parent = cornerGrip, BackgroundColor3 = T.faint, BorderSizePixel = 0, ZIndex = 51,
            AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -3 - i * 3, 1, -3), Size = UDim2.fromOffset(2, 2 + i * 3),
        })
    end
end

---------------------------------------------------------------- cursor + per-frame work
-- The game hides the system mouse and draws its own cursor in a lower ScreenGui,
-- so over this window that cursor is covered. Draw our own on top.
local cursor = new("ImageLabel", {
    Parent = gui, Name = "Cursor", ZIndex = 1000, BackgroundTransparency = 1,
    Image = "rbxasset://textures/Cursors/KeyboardMouse/ArrowFarCursor.png",
    AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(64, 64), Visible = false,
})

local function over(frame, p)
    if not frame.Visible then return false end
    local a, s = frame.AbsolutePosition, frame.AbsoluteSize
    return p.X >= a.X and p.X <= a.X + s.X and p.Y >= a.Y and p.Y <= a.Y + s.Y
end

local renderConn
renderConn = RunService.RenderStepped:Connect(function()
    if not gui.Parent or not alive() then renderConn:Disconnect() return end
    local p = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
    local show = UserInputService.MouseEnabled and (over(window, p) or over(bubble, p))
    cursor.Visible = show
    if show then cursor.Position = UDim2.fromOffset(p.X, p.Y) end
    bubbleDot.BackgroundColor3 = liveDot.BackgroundColor3
    C.hideMinigames()
end)

-- RightShift: hide / show
UserInputService.InputBegan:Connect(function(input, gp)
    if not gp and input.KeyCode == Enum.KeyCode.RightShift and gui.Parent then
        setHidden(window.Visible)
    end
end)
end -- bubble, resize, cursor
