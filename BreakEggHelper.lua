--[[
    LAIKAHUB (Break A Steal Egg)  ·  run to an egg, break it, steal the animal, bring it home and place it

    How the game does it (client side):
      eggs        BasePart tagged "BreakableEgg", attributes EggType / Health / Broken / Hatching / Despawning
      hit         PlayerScripts.Client.Controllers.PickaxeController.Swing(egg) -> ReplicatedStorage.EggHitRequest
      animal      Model tagged "AnimalPickup" next to the broken egg, ProximityPrompt "StealPrompt"
      carry       LocalPlayer attribute "Carrying" / "CarryCount"; the animal is a Tool tagged "AnimalTool"
      your pen    workspace.Plots.<Base_N> with OwnerUserId == you, part "Hitbox" is the pen area
      place       ReplicatedStorage.PlaceAnimalRemote:FireServer(tool, position, seq)  (inside the Hitbox, <= 50 studs away)
      equip best  ReplicatedStorage.PetsInventoryRemote:FireServer("EquipBest", nil)
      pickaxe     ReplicatedStorage.PickaxeShopRequest:FireServer("Buy" | "Equip", tier)   attrs PickaxeTier / OwnedPickaxes "1,2,3"
      trail       ReplicatedStorage.TrailShopRequest:FireServer("Buy" | "Equip", id)       attrs EquippedTrail / OwnedTrails "1,2"
      pen         ReplicatedStorage.UpgradePlotRequest:FireServer()                       plot attr PlotLevel
      treadmill   ReplicatedStorage.UnlockTreadmillRequest / UpgradeTreadmillRequest      plot attrs TreadmillUnlocked / TreadmillLevel
                  plot child Model "<name> Treadmill" with part "Hitbox": stand on it and the server starts the run
                  (TreadmillSessionRemote tells the client: a number = running, anything else = stopped)
      money       LocalPlayer attribute "Cash"
      sell        ReplicatedStorage.BackpackSellRemote:InvokeServer({ tool, … })
      index       ReplicatedStorage.IndexRemote "Get" / "ClaimAll" / "Claim", name

    Window: side tabs (Home, Egg Farm, Treadmill, Shop, Pets, Settings), Thai / English / Indonesian,
    the cat bubble when hidden (red dot or RightShift).
    Load it with:
      loadstring(game:HttpGet("https://raw.githubusercontent.com/PoomLikeDekHot/PixelHelper/main/BreakEggHelper.lua"))()
]]

local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local CollectionService  = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local TweenService       = game:GetService("TweenService")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local HttpService        = game:GetService("HttpService")

if not game:IsLoaded() then game.Loaded:Wait() end
local LocalPlayer = Players.LocalPlayer
local Shared      = ReplicatedStorage:WaitForChild("Shared")

local SAVE_FILE = "BreakEggHelper_Settings_" .. LocalPlayer.UserId .. ".json"
local VERSION   = "2.1.1"

-- stop the previous copy of this script (its loops check this token)
local genv = (getgenv and getgenv()) or _G
local RUN_TOKEN = {}
genv.__BreakEggToken = RUN_TOKEN
local function alive() return genv.__BreakEggToken == RUN_TOKEN end

---------------------------------------------------------------- game modules
-- Requiring or calling the game's own modules drops the calling thread to the game's identity in this
-- executor, and from then on that thread can't touch our UI ("lacking capability Plugin").
-- So every require and every call into game code runs in a throwaway thread of its own.
local function isolated(fn, ...)
    local args, done, result = table.pack(...), false, nil
    task.spawn(function()
        local ok, r = pcall(fn, table.unpack(args, 1, args.n))
        if ok then result = r end
        done = true
    end)
    local t0 = os.clock()
    while not done and os.clock() - t0 < 10 do task.wait() end
    return result
end

local function tryRequire(inst)
    if not (inst and inst:IsA("ModuleScript")) then return nil end
    return isolated(require, inst)
end

-- plain data tables only; their functions are never called from here
local EggConfig     = tryRequire(Shared:FindFirstChild("EggConfig"))
local EggTypeConfig = tryRequire(Shared:FindFirstChild("EggTypeConfig"))
local PlacementCfg  = tryRequire(Shared:FindFirstChild("AnimalPlacementConfig"))
local ZonesConfig   = tryRequire(Shared:FindFirstChild("ZonesConfig"))
local ZoneDisplay   = tryRequire(Shared:FindFirstChild("ZoneDisplayInfo"))
local PICKAXES, TRAILS, PEN_COSTS, PEN_MAX, TREAD_COSTS
do -- the shop modules are only needed to build these tables
local PickaxeCfg    = tryRequire(Shared:FindFirstChild("PickaxeConfig"))
local TrailsCfg     = tryRequire(Shared:FindFirstChild("TrailsConfig"))
local PlotUpCfg     = tryRequire(Shared:FindFirstChild("PlotUpgradeConfig"))
local TreadUpCfg    = tryRequire(Shared:FindFirstChild("TreadmillUpgradeConfig"))

-- prices as shipped in the game's config modules, used when a require fails
PICKAXES = {}
if PickaxeCfg and type(PickaxeCfg.Tiers) == "table" then
    for i, t in ipairs(PickaxeCfg.Tiers) do PICKAXES[i] = { name = t.Name, price = t.Price or 0, template = t.Template } end
else
    local names = { "Wooden", "Stone", "Iron", "Golden", "Diamond", "Strawberry", "Cactus", "Lightning", "Candy", "Rainbow", "Crystal",
        "Demon", "Hacker", "Ufo", "Secret", "Cool", "Galaxy", "Celestial", "Sci Fi", "Enchanted", "Haunted" }
    local prices = { 0, 80, 800, 2e4, 1.6e5, 1.2e6, 6e6, 4e7, 4e8, 2.8e9, 2e10, 1.2e11, 1.2e12, 1.2e13, 8e13, 6e14, 4e15, 2e16, 7.5e16, 2e17, 1e18 }
    for i, n in ipairs(names) do PICKAXES[i] = { name = n .. " Pickaxe", price = prices[i], template = i .. ": " .. n .. " Pickaxe" } end
end

TRAILS = {}
if TrailsCfg and type(TrailsCfg.Trails) == "table" then
    for _, t in ipairs(TrailsCfg.Trails) do table.insert(TRAILS, { id = t.Id, name = t.Name, mult = t.Multiplier or 1, price = t.Price or 0, icon = t.Icon }) end
else
    local list = { { "White", 2, 500 }, { "Blue", 4, 7500 }, { "Green", 8, 1e5 }, { "Purple", 16, 1.25e6 }, { "Red", 40, 1.75e7 },
        { "Golden", 100, 2.5e8 }, { "Rainbow", 250, 3.5e9 }, { "Galactic", 600, 4.5e10 }, { "Secret", 1500, 6e11 },
        { "Laser", 4000, 8e12 }, { "Moonlight", 1e4, 1e14 }, { "Spooky", 2.5e4, 1.5e15 } }
    for i, t in ipairs(list) do TRAILS[i] = { id = i, name = t[1] .. " Trail", mult = t[2], price = t[3] } end
end

-- pen: cost to go from level i to i+1
PEN_COSTS = (PlotUpCfg and type(PlotUpCfg.Costs) == "table") and PlotUpCfg.Costs
    or { 1e4, 1e6, 4.5e7, 1.7e9, 6e10, 2.2e12, 5e13, 1.5e14 }
PEN_MAX = (PlotUpCfg and tonumber(PlotUpCfg.MaxLevel)) or 9

-- treadmill: cost to go from level i to i+1 (the last level has none)
TREAD_COSTS = {}
if TreadUpCfg and type(TreadUpCfg.Levels) == "table" then
    for i, l in ipairs(TreadUpCfg.Levels) do TREAD_COSTS[i] = l.UpgradeCost or false end
else
    TREAD_COSTS = { 8.5e5, 1e7, 5e8, 9.5e9, 1.2e11, 1e12, 1.5e13, 2.5e14, 4e15, false }
end
end
local TREAD_UNLOCK_COST = 100

local PickaxeController
task.spawn(function()
    local scripts = LocalPlayer:WaitForChild("PlayerScripts", 30)
    local mod = scripts and scripts:FindFirstChild("PickaxeController", true)
    PickaxeController = tryRequire(mod)
    if not PickaxeController then warn("[LAIKAHUB] PickaxeController not found, using the hit remote directly") end
end)

local EGG_TAG, PICKUP_TAG, TOOL_TAG = "BreakableEgg", "AnimalPickup", "AnimalTool"
local HIT_RANGE   = (EggConfig and tonumber(EggConfig.HitRange)) or 8
local PLACE_RANGE = (PlacementCfg and tonumber(PlacementCfg.MaxPlaceDistance)) or 50

---------------------------------------------------------------- settings
local settings = {
    farm = false,
    zone = nil,          -- zone id to farm, e.g. "Zone1"
    carry = 5,           -- animals in the bag before placing them in the pen
    placeInPen = false,  -- off: only run back over the red line (Safe Zone) after a steal
    window = 20,         -- seconds to keep breaking eggs before picking the best animal
    speedOn = false,     -- custom walk speed
    walkSpeed = 50,
    pathfind = true,     -- walk around walls (off = straight line)
    antiAfk = true,
    treadmill = false,   -- stay on your own treadmill (turns the farm off)
    autoPickaxe = false, -- buy the best pickaxe you can afford and hold it
    autoTrail = false,   -- buy the best trail you can afford and wear it
    autoPen = false,     -- upgrade the pen when the money is there
    autoTreadmill = false, -- unlock / upgrade the treadmill when the money is there
    autoEquipBest = false, -- keep the best animals in the pen, swapping weaker ones out
    autoSell = false,    -- sell Backpack animals that make less than sellBelow $/s
    sellBelow = 0,
    autoIndex = false,   -- claim Index rewards when they are ready
    lang = nil,          -- "th" / "en" / "id" (first run: follows the Roblox language)
    tab = 1,
}
pcall(function()
    if isfile and isfile(SAVE_FILE) then
        for k, v in pairs(HttpService:JSONDecode(readfile(SAVE_FILE))) do settings[k] = v end
    end
end)

if settings.farm and settings.treadmill then settings.treadmill = false end -- one or the other

local saveQueued = false
local function save()
    if saveQueued then return end
    saveQueued = true
    task.delay(0.5, function()
        saveQueued = false
        pcall(function() if writefile then writefile(SAVE_FILE, HttpService:JSONEncode(settings)) end end)
    end)
end

---------------------------------------------------------------- egg helpers
-- "Demon" -> "Demon Egg" (EggTypeConfig display names); normal eggs already carry their full name
local function displayName(eggType)
    local t = EggTypeConfig and type(EggTypeConfig.Types) == "table" and EggTypeConfig.Types[eggType]
    return (type(t) == "table" and t.DisplayName) or eggType
end

local function eggName(part)
    local inst = part
    while inst and inst ~= workspace and inst ~= game do
        local ok, t = pcall(inst.GetAttribute, inst, "EggType")
        if ok and type(t) == "string" and t ~= "" then return displayName(t) end
        inst = inst.Parent
    end
    local model = part:FindFirstAncestorOfClass("Model")
    return model and model.Name or part.Name
end

-- same rules as the game's EggTargeting.IsLive / SurfaceDistance
local function eggLive(part)
    if not (part and part.Parent) then return false end
    return not (part:GetAttribute("Broken") or part:GetAttribute("Hatching") or part:GetAttribute("Despawning"))
end

local function surfaceDistance(part, pos)
    local size = part.Size
    if part:GetAttribute("TargetShape") == "Box" then
        local p = part.CFrame:PointToObjectSpace(pos)
        local h = size * 0.5
        return Vector3.new(math.max(math.abs(p.X) - h.X, 0), math.max(math.abs(p.Y) - h.Y, 0), math.max(math.abs(p.Z) - h.Z, 0)).Magnitude
    end
    local d = pos - part.Position
    local flat = math.max(Vector3.new(d.X, 0, d.Z).Magnitude - math.max(size.X, size.Z) / 2, 0)
    local halfY = size.Y / 2
    local up = math.max(math.abs(d.Y) - halfY, 0)
    if up > 0 and d.Y < 0 then
        local below = part:GetAttribute("ReachBelow")
        if type(below) == "number" and below > 0 then up = math.max(-d.Y - halfY - below, 0) end
    end
    return math.sqrt(flat * flat + up * up)
end

---------------------------------------------------------------- zones (ZonesConfig.Zones = Zone1 … Zone11)
-- { { id = "Zone1", index = 1, name = "Forest Zone", power = 5 }, … }
local function zoneList()
    local out = {}
    for i, z in ipairs(ZonesConfig and type(ZonesConfig.Zones) == "table" and ZonesConfig.Zones or {}) do
        if type(z) == "table" and z.Id then
            local d = ZoneDisplay and ZoneDisplay[z.Id]
            table.insert(out, { id = z.Id, index = i, name = (d and d.Name) or z.Id, power = tonumber(z.RequiredPower), icon = z.Icon })
        end
    end
    if #out == 0 then -- config not readable: fall back to the zone builds in the map
        local builds = workspace:FindFirstChild("Build")
        builds = builds and builds:FindFirstChild("ZoneBuilds")
        for _, m in ipairs(builds and builds:GetChildren() or {}) do
            local i = tonumber(m.Name:match("^Zone(%d+)$"))
            if i then table.insert(out, { id = m.Name, index = i, name = m.Name }) end
        end
        table.sort(out, function(a, b) return a.index < b.index end)
    end
    return out
end

local zoneIdByIndex = {}
for _, z in ipairs(zoneList()) do zoneIdByIndex[z.index] = z.id end

-- the zone an egg sits in: its ZoneIndex attribute, else the zone hitbox under it
local function eggZone(part)
    local ok, idx = pcall(part.GetAttribute, part, "ZoneIndex")
    if ok and type(idx) == "number" and zoneIdByIndex[idx] then return zoneIdByIndex[idx] end
    -- workspace.Build.ZoneHitboxes has one part per zone, named by its index (like ZoneHitboxLookup.GetZoneAt)
    local build = workspace:FindFirstChild("Build")
    local boxes = build and build:FindFirstChild("ZoneHitboxes")
    if not boxes then return nil end
    for i, id in pairs(zoneIdByIndex) do
        local box = boxes:FindFirstChild(tostring(i))
        if box and box:IsA("BasePart") then
            local p = box.CFrame:PointToObjectSpace(part.Position)
            local h = box.Size * 0.5
            if math.abs(p.X) <= h.X and math.abs(p.Y) <= h.Y + 2 and math.abs(p.Z) <= h.Z then return id end
        end
    end
    return nil
end

-- [zone id] = live eggs in that zone right now
local function zoneCounts()
    local c = {}
    for _, p in ipairs(CollectionService:GetTagged(EGG_TAG)) do
        if p:IsA("BasePart") and eggLive(p) then
            local z = eggZone(p)
            if z then c[z] = (c[z] or 0) + 1 end
        end
    end
    return c
end

local function zoneName(id)
    for _, z in ipairs(zoneList()) do if z.id == id then return z.name end end
    return tostring(id or "—")
end

---------------------------------------------------------------- language (ไทย / English / Indonesia)
-- Keys are the English text itself, so code can write L("Running to %s", name) and get the reader's language.
-- Thai is written the way players talk, not machine translated.
local LANGS = { { code = "th", name = "ไทย" }, { code = "en", name = "English" }, { code = "id", name = "Indonesia" } }
local STR = {
    -- window and tabs
    ["General"] = { "ทั่วไป", "Umum" }, ["Automation"] = { "ระบบออโต้", "Otomatis" }, ["App"] = { "แอป", "Aplikasi" },
    ["Home"] = { "หน้าหลัก", "Beranda" },
    ["What the bot is doing, your money and stats"] = { "ดูว่าบอททำอะไรอยู่ เงินเท่าไหร่ ได้อะไรมาบ้าง", "Apa yang sedang dikerjakan bot, uang, dan statistik" },
    ["Egg Farm"] = { "ฟาร์มไข่", "Farm Telur" },
    ["Pick a zone: the bot breaks eggs, steals the best animal and runs back"] = { "เลือกด่าน แล้วบอทจะตีไข่ ขโมยตัวที่ดีที่สุด แล้ววิ่งกลับให้", "Pilih zona: bot pecahkan telur, curi hewan terbaik, lalu lari pulang" },
    ["Treadmill"] = { "ลู่วิ่ง", "Treadmill" },
    ["Run on your own treadmill to get faster"] = { "ไปวิ่งบนลู่วิ่งของเรา ให้ตัวละครเร็วขึ้น", "Lari di treadmill milikmu supaya makin cepat" },
    ["Shop"] = { "ร้านค้า", "Toko" },
    ["Buys and upgrades on its own when you can afford it"] = { "ซื้อของและอัปเกรดให้เอง ทันทีที่เงินพอ", "Beli dan upgrade sendiri begitu uangnya cukup" },
    ["Pets"] = { "สัตว์", "Hewan" },
    ["Best animals in the pen, sell the weak ones, claim the Index"] = { "ลงตัวที่ดีที่สุดในคอก ขายตัวที่อ่อน และรับรางวัล Index", "Hewan terbaik di kandang, jual yang lemah, klaim Index" },
    ["Settings"] = { "ตั้งค่า", "Pengaturan" },
    ["Language, walk speed and other options"] = { "ภาษา ความเร็วเดิน และตัวเลือกอื่นๆ", "Bahasa, kecepatan jalan, dan opsi lain" },
    ["RightShift to hide"] = { "กด RightShift เพื่อซ่อน", "Tekan RightShift untuk sembunyi" },

    -- home
    ["Status"] = { "สถานะ", "Status" },
    ["Hi, %s"] = { "สวัสดี %s", "Halo, %s" },
    ["What the bot is doing right now"] = { "ตอนนี้บอทกำลังทำอะไรอยู่", "Yang sedang dikerjakan bot sekarang" },
    ["Doing"] = { "กำลังทำ", "Sedang" }, ["Money"] = { "เงิน", "Uang" },
    ["Stolen this session"] = { "ขโมยได้รอบนี้", "Dicuri sesi ini" },
    ["Best animal"] = { "ตัวที่ดีที่สุด", "Hewan terbaik" },
    ["Quick actions"] = { "ทางลัด", "Aksi cepat" },
    ["One tap to start or stop"] = { "กดทีเดียว เริ่มหรือหยุดได้เลย", "Sekali tap untuk mulai atau berhenti" },
    ["Start farming"] = { "เริ่มฟาร์มไข่", "Mulai farm" },
    ["Farms the zone you picked last"] = { "ฟาร์มด่านที่เลือกไว้ล่าสุด", "Farm zona yang terakhir dipilih" },
    ["Stop everything"] = { "หยุดทุกอย่าง", "Hentikan semua" },
    ["Farm and treadmill off, the character stands still"] = { "ปิดฟาร์มและลู่วิ่ง ตัวละครหยุดอยู่กับที่", "Farm dan treadmill mati, karakter diam" },
    ["Start"] = { "เริ่ม", "Mulai" }, ["Go"] = { "ไป", "Pergi" }, ["Stop"] = { "หยุด", "Stop" },
    ["Pick a zone in Egg Farm first"] = { "ไปเลือกด่านในแท็บฟาร์มไข่ก่อนนะ", "Pilih zona di Farm Telur dulu" },

    -- egg farm
    ["Auto Egg"] = { "ฟาร์มไข่ออโต้", "Auto Telur" },
    ["Run to the egg, break it, bring the animal home"] = { "วิ่งไปตีไข่ ขโมยสัตว์ แล้ววิ่งกลับ", "Lari ke telur, pecahkan, bawa hewannya pulang" },
    ["Target"] = { "เป้าหมาย", "Target" }, ["This round"] = { "รอบนี้", "Ronde ini" },
    ["Round"] = { "รอบการตี", "Ronde" },
    ["How long to break eggs and where to go after a steal"] = { "ตีไข่นานแค่ไหน และขโมยแล้วจะไปไหนต่อ", "Berapa lama pecahkan telur dan ke mana setelah mencuri" },
    ["Break eggs for"] = { "ตีไข่นาน", "Pecahkan telur selama" },
    ["Seconds, then steal the best $/s"] = { "วินาที แล้วค่อยขโมยตัวที่ $/s สูงสุด", "Detik, lalu curi yang $/s tertinggi" },
    ["Place in the pen"] = { "เอาไปลงคอก", "Taruh di kandang" },
    ["Off: only run back over the red line"] = { "ปิดไว้: แค่วิ่งกลับข้ามเส้นแดง", "Mati: cuma lari balik lewati garis merah" },
    ["Place after"] = { "ลงคอกเมื่อถือครบ", "Taruh setelah bawa" },
    ["Animals in the bag before going to the pen"] = { "จำนวนสัตว์ในกระเป๋าก่อนกลับไปคอก", "Jumlah hewan di tas sebelum ke kandang" },
    ["Zones"] = { "ด่าน", "Zona" },
    ["Tap a zone: run there, break an egg, bring the animal home"] = { "กดเลือกด่าน บอทจะไปตีไข่ที่นั่นให้", "Tap zona: bot ke sana dan pecahkan telur" },
    ["Farming"] = { "กำลังฟาร์ม", "Sedang farm" }, ["Tap a zone below"] = { "กดเลือกด่านข้างล่าง", "Tap zona di bawah" },
    ["%d eggs now"] = { "มีไข่ %d ใบ", "%d telur sekarang" }, ["no eggs right now"] = { "ตอนนี้ไม่มีไข่", "lagi tidak ada telur" },
    ["power %s"] = { "พลัง %s", "power %s" },
    ["GO"] = { "ไป", "PILIH" }, ["PICKED"] = { "เลือกไว้", "DIPILIH" }, ["FARMING"] = { "กำลังฟาร์ม", "FARMING" },
    ["(off)"] = { "(ปิดอยู่)", "(mati)" },

    -- what the farm is doing
    ["Idle"] = { "ว่าง", "Diam" }, ["Off"] = { "ปิดอยู่", "Mati" },
    ["Running to %s"] = { "กำลังวิ่งไปหา %s", "Lari ke %s" }, ["Running to egg"] = { "วิ่งไปหาไข่", "Lari ke telur" },
    ["Breaking %s"] = { "กำลังตี %s", "Memecahkan %s" }, ["Breaking egg"] = { "ตีไข่อยู่", "Memecahkan telur" },
    ["Stealing %s"] = { "กำลังขโมย %s", "Mencuri %s" }, ["Stealing"] = { "ขโมยอยู่", "Mencuri" },
    ["Running to the Safe Zone"] = { "วิ่งกลับข้ามเส้นแดง", "Lari ke Safe Zone" }, ["Escaping"] = { "หนีกลับฐาน", "Kabur" },
    ["Can't find your pen"] = { "หาคอกของเราไม่เจอ", "Kandangmu tidak ketemu" }, ["No pen found"] = { "ไม่เจอคอก", "Kandang tidak ada" },
    ["Running home"] = { "วิ่งกลับคอก", "Lari pulang" },
    ["Pen is full"] = { "คอกเต็มแล้ว", "Kandang penuh" }, ["Pen full: upgrade it"] = { "คอกเต็ม อัปเกรดก่อน", "Kandang penuh: upgrade dulu" },
    ["Placing %s"] = { "กำลังลง %s", "Menaruh %s" }, ["Placing"] = { "ลงคอกอยู่", "Menaruh" },
    ["Caught! Going back for %s"] = { "โดนจับ! วิ่งกลับไปเอา %s คืน", "Ketangkap! Balik ambil %s" },
    ["Getting it back"] = { "ไปเอาคืน", "Mengambil lagi" },
    ["%s is locked for a moment, waiting next to it"] = { "%s ยังกดขโมยไม่ได้ รออยู่ข้างๆ", "%s masih terkunci, tunggu di sebelahnya" },
    ["Looking for %s where we got caught"] = { "กำลังหา %s แถวที่โดนจับ", "Mencari %s di tempat ketangkap" },
    ["Caught! Checking if %s fell off"] = { "โดนจับ! เช็กว่า %s หลุดมือไหม", "Ketangkap! Cek apa %s jatuh" },
    ["waiting for the first egg"] = { "รอตีไข่ใบแรก", "menunggu telur pertama" },
    ["%d eggs · %ds left"] = { "%d ใบ · เหลือ %d วิ", "%d telur · sisa %d dtk" },
    ["%s  %s  · %d hatched"] = { "%s  %s  · ฟักแล้ว %d ตัว", "%s  %s  · %d menetas" },
    ["waiting for a hatch"] = { "รอไข่ฟัก", "menunggu menetas" },
    ["Picking the best animal"] = { "เลือกตัวที่ดีที่สุด", "Memilih hewan terbaik" }, ["Comparing $/s"] = { "เทียบ $/s", "Bandingkan $/s" },
    ["Waiting for character"] = { "รอตัวละครเกิด", "Menunggu karakter" },
    ["No eggs in %s yet"] = { "ยังไม่มีไข่ใน %s", "Belum ada telur di %s" },
    ["Pick a zone"] = { "เลือกด่านก่อน", "Pilih zona" }, ["Waiting for eggs"] = { "รอไข่เกิด", "Menunggu telur" },
    ["Error, retrying"] = { "มีข้อผิดพลาด กำลังลองใหม่", "Error, coba lagi" },

    -- treadmill
    ["Your treadmill"] = { "ลู่วิ่งของเรา", "Treadmill-mu" },
    ["Go to my treadmill"] = { "กลับไปลู่วิ่ง", "Ke treadmill-ku" },
    ["Drops whatever it is doing, runs back and stays on it"] = { "หยุดทุกอย่างที่ทำอยู่ วิ่งกลับไปยืนวิ่งบนลู่", "Tinggalkan semua, lari balik dan tetap di sana" },
    ["Can't find your base"] = { "หาฐานของเราไม่เจอ", "Base-mu tidak ketemu" }, ["No base found"] = { "ไม่เจอฐาน", "Base tidak ada" },
    ["Treadmill not found"] = { "หาลู่วิ่งไม่เจอ", "Treadmill tidak ketemu" },
    ["Locked: unlock costs %s"] = { "ยังล็อกอยู่ ปลดล็อก %s", "Terkunci: buka %s" },
    ["Treadmill locked"] = { "ลู่วิ่งยังล็อก", "Treadmill terkunci" },
    ["Running to the treadmill"] = { "กำลังวิ่งไปลู่วิ่ง", "Lari ke treadmill" }, ["Going to treadmill"] = { "ไปลู่วิ่ง", "Ke treadmill" },
    ["Running on the treadmill"] = { "กำลังวิ่งบนลู่", "Lari di treadmill" }, ["On treadmill"] = { "อยู่บนลู่วิ่ง", "Di treadmill" },
    ["On the treadmill, waiting for it to start"] = { "ยืนบนลู่แล้ว รอมันเริ่ม", "Di treadmill, tunggu mulai" },
    ["locked"] = { "ล็อกอยู่", "terkunci" },

    -- shop
    ["Auto Buy"] = { "ซื้อออโต้", "Auto Beli" },
    ["Buys and uses the best one as soon as the money is there"] = { "เงินพอเมื่อไหร่ ซื้อและใส่อันที่ดีที่สุดให้เลย", "Begitu uang cukup, beli dan pakai yang terbaik" },
    ["Auto Pickaxe"] = { "ซื้อ Pickaxe ออโต้", "Auto Pickaxe" }, ["Auto Trail"] = { "ซื้อ Trail ออโต้", "Auto Trail" },
    ["Auto Upgrade Pen"] = { "อัปคอกออโต้", "Auto Upgrade Kandang" },
    ["Auto Upgrade Treadmill"] = { "อัปลู่วิ่งออโต้", "Auto Upgrade Treadmill" },
    ["Buying %s"] = { "กำลังซื้อ %s", "Membeli %s" },
    ["%s  ·  next %s"] = { "%s  ·  อันต่อไป %s", "%s  ·  berikutnya %s" },
    ["%s  ·  best one"] = { "%s  ·  ดีที่สุดแล้ว", "%s  ·  sudah terbaik" },
    ["none"] = { "ยังไม่มี", "belum ada" },
    ["Upgrading to Lv.%d"] = { "กำลังอัปเป็น Lv.%d", "Upgrade ke Lv.%d" },
    ["Lv.%d (max)  ·  %s"] = { "Lv.%d (สูงสุด)  ·  %s", "Lv.%d (maks)  ·  %s" },
    ["Lv.%d  ·  %s  ·  next %s"] = { "Lv.%d  ·  %s  ·  อัปต่อ %s", "Lv.%d  ·  %s  ·  berikutnya %s" },
    ["%s/%s animals"] = { "%s/%s ตัว", "%s/%s hewan" },
    ["Unlocking"] = { "กำลังปลดล็อก", "Membuka" },
    ["Locked  ·  unlock %s"] = { "ยังล็อก  ·  ปลดล็อก %s", "Terkunci  ·  buka %s" },
    ["Lv.%d  ·  max"] = { "Lv.%d  ·  สูงสุดแล้ว", "Lv.%d  ·  maks" },
    ["Lv.%d  ·  next %s"] = { "Lv.%d  ·  อัปต่อ %s", "Lv.%d  ·  berikutnya %s" },
    ["Bought %s"] = { "ซื้อ %s แล้ว", "Sudah beli %s" },
    ["Pen upgraded to Lv.%d"] = { "อัปคอกเป็น Lv.%d แล้ว", "Kandang naik ke Lv.%d" },
    ["Treadmill upgraded to Lv.%d"] = { "อัปลู่วิ่งเป็น Lv.%d แล้ว", "Treadmill naik ke Lv.%d" },

    -- pets
    ["Equip Best"] = { "ลงตัวที่ดีที่สุด", "Pasang Terbaik" },
    ["Auto Equip Best"] = { "ลงตัวที่ดีที่สุดออโต้", "Auto Pasang Terbaik" },
    ["Swaps in a better animal as soon as you get one"] = { "ได้ตัวที่ดีกว่าเมื่อไหร่ สลับลงคอกแทนตัวที่อ่อนสุดให้เลย", "Begitu dapat yang lebih bagus, langsung ditukar" },
    ["Equip Best now"] = { "ลงตัวที่ดีที่สุดเดี๋ยวนี้", "Pasang terbaik sekarang" },
    ["Fills the pen and swaps out weaker animals"] = { "เติมคอกให้เต็ม แล้วเอาตัวที่อ่อนกว่าออก", "Isi kandang dan ganti hewan yang lebih lemah" },
    ["Equip"] = { "ลง", "Pasang" },
    ["Pen"] = { "คอก", "Kandang" },
    ["Weakest in pen"] = { "ตัวที่อ่อนสุดในคอก", "Terlemah di kandang" },
    ["Best in bag"] = { "ตัวที่ดีสุดในกระเป๋า", "Terbaik di tas" },
    ["Swapped %d animal(s)"] = { "สลับไป %d ตัว", "Ditukar %d hewan" },
    ["Pen already has your best animals"] = { "ในคอกเป็นตัวที่ดีที่สุดแล้ว", "Kandang sudah berisi yang terbaik" },
    ["Auto Sell"] = { "ขายออโต้", "Auto Jual" },
    ["Sells animals in your bag that make less than this"] = { "ขายสัตว์ในกระเป๋าที่ทำเงินได้น้อยกว่าที่ตั้งไว้", "Jual hewan di tas yang hasilnya di bawah ini" },
    ["Sell below"] = { "ขายตัวที่ได้ต่ำกว่า", "Jual di bawah" },
    ["$/s per animal. Type like 500, 25K, 1.5M"] = { "$/s ต่อตัว พิมพ์ได้แบบ 500, 25K, 1.5M", "$/s per hewan. Tulis 500, 25K, 1.5M" },
    ["Sell now"] = { "ขายเดี๋ยวนี้", "Jual sekarang" }, ["Sell"] = { "ขาย", "Jual" },
    ["Never sells animals in the pen or in your hand"] = { "ไม่ขายตัวที่อยู่ในคอก หรือที่ถืออยู่ในมือ", "Tidak menjual hewan di kandang atau yang dipegang" },
    ["Sold %d animal(s)"] = { "ขายไป %d ตัว", "Terjual %d hewan" },
    ["Nothing to sell"] = { "ไม่มีตัวให้ขาย", "Tidak ada yang dijual" },
    ["Set a $/s first"] = { "ตั้งค่า $/s ก่อนนะ", "Atur $/s dulu" },
    ["Index"] = { "Index", "Index" },
    ["Auto Claim Index"] = { "รับรางวัล Index ออโต้", "Auto Klaim Index" },
    ["Claims Index rewards as soon as they are ready"] = { "รางวัล Index พร้อมเมื่อไหร่ กดรับให้เลย", "Klaim hadiah Index begitu siap" },
    ["Claim now"] = { "รับเดี๋ยวนี้", "Klaim sekarang" }, ["Claim"] = { "รับ", "Klaim" },
    ["Ready to claim"] = { "พร้อมรับ", "Siap diklaim" },
    ["Claimed the Index rewards"] = { "รับรางวัล Index แล้ว", "Hadiah Index sudah diklaim" },
    ["%d ready"] = { "พร้อมรับ %d", "%d siap" },
    ["nothing ready"] = { "ยังไม่มีให้รับ", "belum ada" },

    -- settings
    ["Language"] = { "ภาษา", "Bahasa" },
    ["Pick the language for this window"] = { "เลือกภาษาที่ใช้ในหน้าต่างนี้", "Pilih bahasa untuk jendela ini" },
    ["Walk Speed"] = { "ความเร็วเดิน", "Kecepatan Jalan" },
    ["Off: the bot runs at your normal game speed"] = { "ปิดไว้: บอทวิ่งด้วยความเร็วปกติของเรา", "Mati: bot lari dengan kecepatan normalmu" },
    ["Speed"] = { "ความเร็ว", "Kecepatan" }, ["Roblox default is 16"] = { "ค่าปกติของ Roblox คือ 16", "Bawaan Roblox 16" },
    ["Options"] = { "ตัวเลือก", "Opsi" },
    ["Movement and staying online"] = { "การเดิน และกันหลุดเกม", "Gerakan dan tetap online" },
    ["Walk around walls"] = { "เดินอ้อมกำแพง", "Jalan memutari tembok" },
    ["Off: run in a straight line"] = { "ปิดไว้: วิ่งเป็นเส้นตรง", "Mati: lari lurus" },
    ["Anti AFK"] = { "กันโดนเตะ AFK", "Anti AFK" },
    ["Stay in the server while farming"] = { "ไม่โดนเตะออกจากเซิร์ฟตอนเปิดทิ้งไว้", "Tetap di server saat farm" },
    ["Unload"] = { "ปิดสคริปต์", "Matikan" },
    ["Close the window and stop everything"] = { "ปิดหน้าต่าง แล้วหยุดทุกอย่าง", "Tutup jendela dan hentikan semua" },
    ["Unload script"] = { "ปิดสคริปต์", "Matikan skrip" },
}

local langIndex = { th = 1, en = 0, id = 2 }
if not settings.lang then -- first run: follow the Roblox language
    local loc = string.lower(tostring(LocalPlayer.LocaleId or ""))
    settings.lang = loc:find("^th") and "th" or (loc:find("^id") and "id" or "en")
end

-- L("Breaking %s", name): the text in the chosen language, formatted
local function L(key, ...)
    local i = langIndex[settings.lang] or 0
    local entry = STR[key]
    local text = (i > 0 and entry and entry[i]) or key
    if select("#", ...) > 0 then
        local ok, out = pcall(string.format, text, ...)
        return ok and out or key
    end
    return text
end

-- tr(label, key, ...): set the text now and again whenever the language changes
local translated = setmetatable({}, { __mode = "k" })
local function tr(obj, key, ...)
    translated[obj] = { key = key, args = table.pack(...) }
    obj.Text = L(key, ...)
    return obj
end
local onLanguage = {} -- extra refreshers (zone list, tab title)

---------------------------------------------------------------- theme (LAIKA tokens) + motion
-- deep purple-black surfaces, violet primary, rose highlight (matches the cat)
local T = {
    bg = Color3.fromHex("0e0d18"), side = Color3.fromHex("12111f"), card = Color3.fromHex("1a1828"),
    raised = Color3.fromHex("221f33"), raised2 = Color3.fromHex("2b2840"), text = Color3.fromHex("eeecf6"),
    muted = Color3.fromHex("9b97b0"), faint = Color3.fromHex("625e78"), accent = Color3.fromHex("8b5cf6"),
    accentT = Color3.fromHex("c4b5fd"), green = Color3.fromHex("22c55e"), red = Color3.fromHex("ef4444"),
    amber = Color3.fromHex("f59e0b"), sky = Color3.fromHex("38bdf8"), violet = Color3.fromHex("a78bfa"),
    pink = Color3.fromHex("f472b6"), rose = Color3.fromHex("f43f5e"), switchOff = Color3.fromHex("34304a"),
}
local LINE, LINE2 = 0.94, 0.89
local FONT      = Font.new("rbxasset://fonts/families/Nunito.json", Enum.FontWeight.Bold)
local FONT_SEMI = Font.new("rbxasset://fonts/families/Nunito.json", Enum.FontWeight.ExtraBold)
local FONT_BOLD = Font.new("rbxasset://fonts/families/FredokaOne.json")
local WHITE     = Color3.new(1, 1, 1)
-- decelerate when arriving, accelerate when leaving, leaving is quicker than arriving
local MOTION = {
    hover = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
    enter = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    leave = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
    pop   = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
}

---------------------------------------------------------------- ui primitives
local function new(class, props, children)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do inst[k] = v end
    for _, c in ipairs(children or {}) do c.Parent = inst end
    return inst
end
local function corner(r) return new("UICorner", { CornerRadius = UDim.new(0, r) }) end
local function line(t) return new("UIStroke", { Color = WHITE, Transparency = t or LINE, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }) end
local function pad(t, r, b, l)
    return new("UIPadding", { PaddingTop = UDim.new(0, t), PaddingRight = UDim.new(0, r), PaddingBottom = UDim.new(0, b), PaddingLeft = UDim.new(0, l) })
end
local function vlist(gap) return new("UIListLayout", { Padding = UDim.new(0, gap or 0), SortOrder = Enum.SortOrder.LayoutOrder }) end
local function tween(inst, props, info) TweenService:Create(inst, info or MOTION.enter, props):Play() end

-- text is a dictionary key (translated, follows the language) unless raw = true
local function label(parent, text, size, color, font, props, raw)
    local l = new("TextLabel", {
        Parent = parent, BackgroundTransparency = 1, Text = "",
        FontFace = font or FONT, TextSize = size or 13, TextColor3 = color or T.text,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    })
    for k, v in pairs(props or {}) do l[k] = v end
    if raw then l.Text = text else tr(l, text) end
    return l
end

local function rightAnchor(inst, w, h)
    inst.AnchorPoint = Vector2.new(1, 0.5)
    inst.Position = UDim2.new(1, 0, 0.5, 0)
    inst.Size = UDim2.fromOffset(w, h)
    return inst
end

-- hover: lighten, press: shrink a touch (feels like a real button)
local function feel(btn, base, over)
    local scale = new("UIScale", { Parent = btn })
    btn.MouseEnter:Connect(function() tween(btn, { BackgroundColor3 = over }, MOTION.hover) end)
    btn.MouseLeave:Connect(function() tween(btn, { BackgroundColor3 = base() }, MOTION.hover); tween(scale, { Scale = 1 }, MOTION.hover) end)
    btn.MouseButton1Down:Connect(function() tween(scale, { Scale = 0.94 }, MOTION.hover) end)
    btn.MouseButton1Up:Connect(function() tween(scale, { Scale = 1 }, MOTION.pop) end)
end

-- switch 42x24, returns button, refresh()
local function switch(parent, get, onToggle)
    local s = new("TextButton", { Parent = parent, AutoButtonColor = false, Text = "", BackgroundColor3 = T.switchOff, BorderSizePixel = 0 }, { corner(12) })
    rightAnchor(s, 42, 24)
    local knob = new("Frame", { Parent = s, Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = WHITE, BorderSizePixel = 0 }, { corner(9) })
    local function refresh(instant)
        local on = get()
        local bg, pos = on and T.green or T.switchOff, on and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
        if instant then s.BackgroundColor3, knob.Position = bg, pos
        else
            tween(s, { BackgroundColor3 = bg }, MOTION.hover)
            tween(knob, { Position = pos, Size = UDim2.fromOffset(22, 18) }, MOTION.hover) -- stretch while it slides
            task.delay(0.12, function() tween(knob, { Size = UDim2.fromOffset(18, 18), Position = pos }, MOTION.pop) end)
        end
    end
    s.MouseButton1Click:Connect(function() onToggle(); refresh() end)
    refresh(true)
    return s, refresh
end

-- segmented control (language picker). returns frame, refresh()
local function segmented(parent, items, getIndex, onPick)
    local bar = new("Frame", { Parent = parent, BackgroundColor3 = T.bg, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 32) }, { corner(10), line() })
    local pill = new("Frame", { Parent = bar, BackgroundColor3 = T.accent, BorderSizePixel = 0, Size = UDim2.new(1 / #items, -6, 1, -6) }, { corner(7) })
    local buttons = {}
    for i, item in ipairs(items) do
        local b = new("TextButton", {
            Parent = bar, AutoButtonColor = false, BackgroundTransparency = 1, ZIndex = 2,
            Size = UDim2.new(1 / #items, 0, 1, 0), Position = UDim2.new((i - 1) / #items, 0, 0, 0),
            Text = item, FontFace = FONT_SEMI, TextSize = 12, TextColor3 = T.muted,
        })
        buttons[i] = b
        b.MouseButton1Click:Connect(function() onPick(i) end)
    end
    local function refresh(instant)
        local i = getIndex()
        local pos = UDim2.new((i - 1) / #items, 3, 0, 3)
        if instant then pill.Position = pos else tween(pill, { Position = pos }, MOTION.pop) end
        for j, b in ipairs(buttons) do b.TextColor3 = (j == i) and T.bg or T.muted end
    end
    refresh(true)
    return bar, refresh
end

local function smallButton(parent, text, width, color)
    local base = color or T.raised
    local b = new("TextButton", {
        Parent = parent, AutoButtonColor = false, BackgroundColor3 = base, BorderSizePixel = 0,
        Size = UDim2.fromOffset(width or 70, 28), Text = "", FontFace = FONT_BOLD, TextSize = 12,
        TextColor3 = color and T.bg or T.text,
    }, { corner(8), line() })
    tr(b, text)
    feel(b, function() return base end, color and base:Lerp(WHITE, 0.25) or T.raised2)
    return b
end

---------------------------------------------------------------- window
local parentGui = (gethui and gethui()) or game:GetService("CoreGui")
do
    local old = parentGui:FindFirstChild("BreakEggHelper")
    if old then old:Destroy() end
end
local gui = new("ScreenGui", { Name = "BreakEggHelper", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999 })
if not pcall(function() gui.Parent = parentGui end) then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local SIDEBAR = 184
local window = new("Frame", {
    Name = "Window", Parent = gui, Size = UDim2.fromOffset(820, 520), Position = UDim2.new(0.5, -410, 0.5, -260),
    BackgroundColor3 = T.bg, BorderSizePixel = 0, ClipsDescendants = true,
}, { corner(14), line(LINE2) })

-- the cat picture: a file in the executor's workspace, downloaded once (same picture as PixelHelper)
local catImage = ""
pcall(function()
    local file = "PixelHelper_cat.png"
    if isfile and writefile and not isfile(file) then
        writefile(file, game:HttpGet("https://raw.githubusercontent.com/PoomLikeDekHot/PixelHelper/main/PixelHelper_cat.png"))
    end
    local getAsset = getcustomasset or getsynasset
    if getAsset and isfile and isfile(file) then catImage = getAsset(file) end
end)

-- pictures the game already uses (rbxassetid): its HUD buttons and shop cards
local IMG = {
    cat = catImage,
    eggs = "rbxassetid://82591144814984", shop = "rbxassetid://74059337340117", pets = "rbxassetid://98555742362660",
    speed = "rbxassetid://140522991306842", index = "rbxassetid://105451413936050", sell = "rbxassetid://85919207166344",
    cash = "rbxassetid://100451594632335", swing = "rbxassetid://99777146015256", tread = "rbxassetid://88793025820108",
    walk = "rbxassetid://129975899954235", boost = "rbxassetid://79732991925872", zone = "rbxassetid://84488003116697",
    gear = "rbxasset://textures/ui/Settings/MenuBarIcons/GameSettingsTab.png",
}

-- a picture with a text glyph under it; the glyph shows when the picture is empty or does not load
local function icon(parent, image, size, glyph, tint, props)
    local holder = new("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.fromOffset(size, size) })
    for k, v in pairs(props or {}) do holder[k] = v end
    local g = label(holder, glyph or "", math.floor(size * 0.6), tint or T.muted, FONT_BOLD, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center }, true)
    local img = new("ImageLabel", { Parent = holder, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Image = image or "", ScaleType = Enum.ScaleType.Fit })
    local function check()
        local ok, loaded = pcall(function() return img.IsLoaded end)
        g.Visible = img.Image == "" or (ok and not loaded)
    end
    g.Visible = img.Image == ""
    img:GetPropertyChangedSignal("Image"):Connect(function() g.Visible = img.Image == ""; task.delay(3, check) end)
    task.delay(3, check)
    return holder, img, g
end

-- the game's animal / egg renders (AnimalRenders: { Normal = { [name] = id }, Gold, Diamond, Eggs }), data only
local animalImage, eggImage, pickaxeIcon
do
    local Renders = tryRequire(Shared:FindFirstChild("AnimalRenders"))
    local index = {}
    local function key(s) return (string.gsub(string.lower(s), "[%s_%-]", "")) end
    local function find(group, name)
        if type(name) ~= "string" or not (Renders and type(Renders[group]) == "table") then return "" end
        local idx = index[group]
        if not idx then
            idx = {}
            for k, v in pairs(Renders[group]) do if type(k) == "string" then idx[key(k)] = v end end
            index[group] = idx
        end
        local id = idx[key(name)]
        return id and ("rbxassetid://" .. tostring(id)) or ""
    end
    animalImage = function(name, variant)
        local img = (type(variant) == "string" and variant ~= "Normal") and find(variant, name) or ""
        return img ~= "" and img or find("Normal", name)
    end
    eggImage = function(eggType) return find("Eggs", eggType) end
    -- the shop's pickaxe picture: the TextureId of its tool template in ReplicatedStorage.Pickaxes
    pickaxeIcon = function(tier)
        local folder = ReplicatedStorage:FindFirstChild("Pickaxes")
        local p = PICKAXES[tier]
        if not (folder and p) then return "" end
        local t = p.template and folder:FindFirstChild(p.template)
        if not t then
            for _, c in ipairs(folder:GetChildren()) do if c.Name:find(p.name, 1, true) then t = c break end end
        end
        return (t and t:IsA("Tool")) and t.TextureId or ""
    end
end

local setStatus, selectTab, tab, toast
local titleText, subtitleText
do
    ---------------- sidebar
    local sidebar = new("Frame", { Parent = window, Size = UDim2.new(0, SIDEBAR, 1, 0), BackgroundColor3 = T.side, BorderSizePixel = 0 }, {
        new("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0, 1, 1, 0), BackgroundColor3 = WHITE, BackgroundTransparency = LINE, BorderSizePixel = 0 }),
    })
    local btnHide = new("TextButton", {
        Parent = sidebar, Name = "Hide", AutoButtonColor = false, Text = "", Size = UDim2.fromOffset(13, 13),
        Position = UDim2.fromOffset(16, 16), BackgroundColor3 = T.red, BorderSizePixel = 0,
    }, { corner(7) })
    local brand = new("Frame", { Parent = sidebar, BackgroundTransparency = 1, Position = UDim2.fromOffset(16, 42), Size = UDim2.new(1, -32, 0, 40) })
    local logo = new("ImageLabel", { Parent = brand, BackgroundColor3 = T.raised, BorderSizePixel = 0, Size = UDim2.fromOffset(36, 36), Image = catImage, ScaleType = Enum.ScaleType.Fit }, { corner(10) })
    if catImage == "" then label(logo, "L", 18, T.accentT, FONT_BOLD, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center }, true) end
    do -- the cat bobs gently
        local up = true
        task.spawn(function()
            while alive() and gui.Parent do
                tween(logo, { Rotation = up and 6 or -6 }, TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut))
                up = not up
                task.wait(1.6)
            end
        end)
    end
    label(brand, "LAIKAHUB", 15, T.text, FONT_BOLD, { Position = UDim2.fromOffset(46, 1), Size = UDim2.new(1, -46, 0, 18) }, true)
    label(brand, "Break A Steal Egg · v" .. VERSION, 10, T.muted, FONT, { Position = UDim2.fromOffset(46, 20), Size = UDim2.new(1, -46, 0, 14) }, true)

    local navList = new("ScrollingFrame", {
        Parent = sidebar, BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(10, 94), Size = UDim2.new(1, -16, 1, -128),
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = 3, ScrollBarImageColor3 = T.faint,
    }, { vlist(2), pad(0, 4, 8, 0) })
    label(sidebar, "RightShift to hide", 10, T.faint, FONT, { Position = UDim2.new(0, 16, 1, -26), Size = UDim2.new(1, -32, 0, 14) })

    ---------------- main area
    local main = new("Frame", { Parent = window, BackgroundTransparency = 1, Position = UDim2.fromOffset(SIDEBAR, 0), Size = UDim2.new(1, -SIDEBAR, 1, 0) })
    new("Frame", { -- glow
        Parent = main, BackgroundColor3 = T.accent, BackgroundTransparency = 0.5, BorderSizePixel = 0, ZIndex = 0,
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.75, 0, 0, 0), Size = UDim2.fromOffset(520, 260),
    }, {
        corner(130),
        new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) }), Rotation = 90 }),
    })
    local toolbar = new("Frame", { Parent = main, Size = UDim2.new(1, 0, 0, 58), BackgroundTransparency = 1 }, {
        new("Frame", { Position = UDim2.new(0, 0, 1, -1), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = WHITE, BackgroundTransparency = LINE, BorderSizePixel = 0 }),
    })
    titleText = label(toolbar, "", 17, T.text, FONT_BOLD, { Position = UDim2.fromOffset(22, 11), Size = UDim2.new(1, -240, 0, 22) }, true)
    subtitleText = label(toolbar, "", 11, T.muted, FONT, { Position = UDim2.fromOffset(22, 34), Size = UDim2.new(1, -240, 0, 14) }, true)
    local livePill = new("Frame", {
        Parent = toolbar, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -18, 0.5, 0), Size = UDim2.fromOffset(190, 28),
        BackgroundColor3 = T.card, BorderSizePixel = 0,
    }, { corner(14), line() })
    local liveDot = new("Frame", { Parent = livePill, Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 12, 0.5, -4), BackgroundColor3 = T.faint, BorderSizePixel = 0 }, { corner(4) })
    local liveText = label(livePill, "Idle", 11, T.text, FONT_SEMI, { Position = UDim2.fromOffset(28, 0), Size = UDim2.new(1, -36, 1, 0) })
    local liveOn, lastLive = false, nil
    setStatus = function(text, on)
        if text ~= lastLive then -- a new state: the text slides in
            lastLive = text
            liveText.Position = UDim2.fromOffset(28, 6)
            liveText.TextTransparency = 0.6
            tween(liveText, { Position = UDim2.fromOffset(28, 0), TextTransparency = 0 }, MOTION.enter)
        end
        tr(liveText, text)
        liveDot.BackgroundColor3 = on and T.green or T.faint
        liveOn = on
    end
    task.spawn(function() -- the dot breathes while something is running
        while alive() and gui.Parent do
            if liveOn then
                tween(liveDot, { BackgroundTransparency = 0.6 }, TweenInfo.new(0.7, Enum.EasingStyle.Sine))
                task.wait(0.7)
                tween(liveDot, { BackgroundTransparency = 0 }, TweenInfo.new(0.7, Enum.EasingStyle.Sine))
                task.wait(0.7)
            else
                liveDot.BackgroundTransparency = 0
                task.wait(0.3)
            end
        end
    end)

    -- drag by the toolbar or the top of the sidebar
    do
        local dragging, startPos, startInput
        local function begin(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging, startPos, startInput = true, window.Position, input.Position
                input.Changed:Connect(function() if input.UserInputState == Enum.UserInputState.End then dragging = false end end)
            end
        end
        toolbar.InputBegan:Connect(begin)
        sidebar.InputBegan:Connect(function(input) if input.Position.Y - sidebar.AbsolutePosition.Y < 40 then begin(input) end end)
        UserInputService.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                local d = input.Position - startInput
                window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end)
    end

    ---------------- pages: two columns
    local function makePage()
        local page = new("ScrollingFrame", {
            Parent = main, Visible = false, BackgroundTransparency = 1, BorderSizePixel = 0,
            Position = UDim2.fromOffset(0, 58), Size = UDim2.new(1, 0, 1, -58),
            CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
            ScrollBarThickness = 4, ScrollBarImageColor3 = T.faint,
        }, { pad(16, 0, 18, 0) })
        local cols = new("Frame", { Parent = page, BackgroundTransparency = 1, Position = UDim2.fromOffset(18, 0), Size = UDim2.new(1, -36, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
        local left = new("Frame", { Parent = cols, BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(0.5, -7, 0, 0) }, { vlist(14) })
        local right = new("Frame", { Parent = cols, BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(0.5, -7, 0, 0), Position = UDim2.new(0.5, 7, 0, 0) }, { vlist(14) })
        return page, left, right
    end

    ---------------- tabs
    local tabs = {}
    tab = {}
    selectTab = function(index)
        settings.tab = index; save()
        for i, t in ipairs(tabs) do
            local on = i == index
            local arriving = on and not t.page.Visible
            t.page.Visible = on
            if arriving then -- the page rises and fades in
                t.page.Position = UDim2.fromOffset(0, 58 + 18)
                tween(t.page, { Position = UDim2.fromOffset(0, 58) }, MOTION.enter)
            end
            t.label.TextColor3 = on and T.text or T.muted
            t.glyph.TextColor3 = on and t.tint or T.faint
            tween(t.img, { ImageTransparency = on and 0 or 0.45 }, MOTION.hover)
            tween(t.button, { BackgroundTransparency = on and 0 or 1 }, MOTION.hover)
            tween(t.bar, { Size = UDim2.fromOffset(3, on and 20 or 0) }, MOTION.pop)
            tween(t.iconScale, { Scale = on and 1.15 or 1 }, MOTION.pop)
        end
        tr(titleText, tabs[index].name)
        tr(subtitleText, tabs[index].subtitle)
        titleText.TextTransparency, subtitleText.TextTransparency = 0.7, 0.7
        tween(titleText, { TextTransparency = 0 })
        tween(subtitleText, { TextTransparency = 0 })
    end
    local function addTab(id, section, image, glyph, tint, name, subtitle)
        if section then
            label(navList, section, 10, T.faint, FONT_BOLD, { LayoutOrder = #tabs * 10 + 1, Size = UDim2.new(1, 0, 0, 28), TextYAlignment = Enum.TextYAlignment.Bottom })
        end
        local b = new("TextButton", {
            Parent = navList, LayoutOrder = #tabs * 10 + 2, AutoButtonColor = false,
            Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = T.raised, BackgroundTransparency = 1, Text = "",
        }, { corner(10) })
        local bar = new("Frame", {
            Parent = b, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(3, 0),
            BackgroundColor3 = tint, BorderSizePixel = 0,
        }, { corner(2) })
        local holder, img, g = icon(b, image, 24, glyph, T.faint, { Position = UDim2.fromOffset(10, 8) })
        img.ImageTransparency = 0.45
        local iconScale = new("UIScale", { Parent = holder })
        local l = label(b, name, 14, T.muted, FONT_SEMI, { Position = UDim2.fromOffset(42, 0), Size = UDim2.new(1, -46, 1, 0) })
        local page, left, right = makePage()
        table.insert(tabs, { button = b, bar = bar, label = l, img = img, glyph = g, iconScale = iconScale, tint = tint, page = page, name = name, subtitle = subtitle })
        local index = #tabs
        b.MouseEnter:Connect(function() if settings.tab ~= index then tween(l, { TextColor3 = T.text }, MOTION.hover) end end)
        b.MouseLeave:Connect(function() if settings.tab ~= index then tween(l, { TextColor3 = T.muted }, MOTION.hover) end end)
        b.MouseButton1Click:Connect(function() selectTab(index) end)
        tab[id] = { L = left, R = right, index = index }
    end
    addTab("home",  "General",    IMG.cat,   "⌂", T.accent, "Home", "What the bot is doing, your money and stats")
    addTab("farm",  "Automation", IMG.eggs,  "◆", T.green,  "Egg Farm", "Pick a zone: the bot breaks eggs, steals the best animal and runs back")
    addTab("tread", nil,          IMG.speed, "▲", T.sky,    "Treadmill", "Run on your own treadmill to get faster")
    addTab("shop",  nil,          IMG.shop,  "$", T.amber,  "Shop", "Buys and upgrades on its own when you can afford it")
    addTab("pets",  nil,          IMG.pets,  "♣", T.pink,   "Pets", "Best animals in the pen, sell the weak ones, claim the Index")
    addTab("set",   "App",        IMG.gear,  "≡", T.violet, "Settings", "Language, walk speed and other options")
    selectTab(math.clamp(tonumber(settings.tab) or 1, 1, #tabs))

    ---------------- toasts: small cards that slide in at the top right and fade away
    local toastHolder = new("Frame", {
        Parent = gui, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 16),
        Size = UDim2.fromOffset(280, 400),
    }, { new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Right }) })
    local toastN = 0
    toast = function(text, color, image)
        image = (image and image ~= "") and image or catImage
        toastN += 1
        local holder = new("Frame", { Parent = toastHolder, LayoutOrder = -toastN, BackgroundTransparency = 1, Size = UDim2.fromOffset(280, 44), ClipsDescendants = true })
        local c = new("Frame", {
            Parent = holder, BackgroundColor3 = T.card, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Position = UDim2.fromOffset(300, 0),
        }, { corner(12), line(LINE2) })
        new("Frame", { Parent = c, BackgroundColor3 = color or T.accent, BorderSizePixel = 0, Size = UDim2.new(0, 4, 1, -16), Position = UDim2.fromOffset(10, 8) }, { corner(2) })
        new("ImageLabel", { Parent = c, BackgroundTransparency = 1, Image = image, Size = UDim2.fromOffset(28, 28), Position = UDim2.fromOffset(22, 8), ScaleType = Enum.ScaleType.Fit, Visible = image ~= "" })
        label(c, text, 12, T.text, FONT_SEMI, { Position = UDim2.fromOffset(image ~= "" and 58 or 24, 0), Size = UDim2.new(1, -70, 1, 0), TextWrapped = true }, true)
        tween(c, { Position = UDim2.fromOffset(0, 0) }, MOTION.pop)
        task.delay(3.5, function()
            tween(c, { Position = UDim2.fromOffset(300, 0) }, MOTION.leave)
            task.wait(0.2)
            holder:Destroy()
        end)
    end

    ---------------- hide into a cat bubble (red dot or RightShift), tap the bubble to come back
    local windowScale = new("UIScale", { Parent = window })
    local bubble = new("TextButton", {
        Parent = gui, AutoButtonColor = false, Text = "", Visible = false, Size = UDim2.fromOffset(58, 58),
        Position = UDim2.new(0, 24, 0.5, -29), BackgroundColor3 = T.card, BorderSizePixel = 0,
    }, { corner(29), new("UIStroke", { Color = T.accent, Thickness = 2, Transparency = 0.2 }) })
    local bubbleImg = new("ImageLabel", {
        Parent = bubble, BackgroundTransparency = 1, Image = catImage, ScaleType = Enum.ScaleType.Fit,
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.86, 0.86),
    })
    if catImage == "" then bubbleImg.Visible = false; label(bubble, "L", 22, T.accentT, FONT_BOLD, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center }, true) end
    local hideToken = 0
    local function setHidden(hidden)
        hideToken += 1
        local mine = hideToken
        if hidden then
            tween(windowScale, { Scale = 0.94 }, MOTION.leave)
            task.delay(MOTION.leave.Time, function()
                if mine ~= hideToken then return end
                window.Visible = false
                bubble.Visible = true
                bubble.Size = UDim2.fromOffset(20, 20)
                tween(bubble, { Size = UDim2.fromOffset(58, 58) }, MOTION.pop)
            end)
        else
            bubble.Visible = false
            window.Visible = true
            windowScale.Scale = 0.94
            tween(windowScale, { Scale = 1 }, MOTION.pop)
        end
    end
    btnHide.MouseButton1Click:Connect(function() setHidden(true) end)
    do -- the bubble can be dragged; a tap (no drag) opens the window
        local down, moved, startPos, startInput
        bubble.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                down, moved, startPos, startInput = true, false, bubble.Position, input.Position
            end
        end)
        UserInputService.InputChanged:Connect(function(input)
            if down and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                local d = input.Position - startInput
                if d.Magnitude > 4 then moved = true end
                bubble.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end)
        UserInputService.InputEnded:Connect(function(input)
            if down and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
                down = false
                if not moved then setHidden(false) end
            end
        end)
    end
    UserInputService.InputBegan:Connect(function(input, gp)
        if not gp and input.KeyCode == Enum.KeyCode.RightShift and gui.Parent then setHidden(window.Visible) end
    end)

    table.insert(onLanguage, function() selectTab(settings.tab or 1) end)
end

-- row counters per container, kept in Lua: the executor's UI container refuses attribute access
local rowCount = setmetatable({}, { __mode = "k" })

-- card: tinted tile (a game picture, or a glyph) + title + subtitle. returns the card and its header
local function card(parent, order, title, sub, glyph, tint)
    tint = tint or T.accent
    local stroke = line()
    local c = new("Frame", {
        Parent = parent, LayoutOrder = order, BackgroundColor3 = T.card, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
    }, { corner(14), stroke, vlist(0) })
    c.MouseEnter:Connect(function() tween(stroke, { Color = tint, Transparency = 0.6 }, MOTION.hover) end)
    c.MouseLeave:Connect(function() tween(stroke, { Color = WHITE, Transparency = LINE }, MOTION.hover) end)
    local head = new("Frame", { Parent = c, LayoutOrder = 0, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 64) }, { pad(0, 16, 0, 16) })
    local tile = new("Frame", {
        Parent = head, Size = UDim2.fromOffset(40, 40), Position = UDim2.new(0, 0, 0.5, -20),
        BackgroundColor3 = tint, BackgroundTransparency = 0.82, BorderSizePixel = 0,
    }, { corner(12), new("UIStroke", { Color = tint, Transparency = 0.55, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }) })
    if type(glyph) == "string" and glyph:find("^rbx") then
        icon(tile, glyph, 30, "•", tint, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
    else
        label(tile, glyph or "•", 18, tint, FONT_BOLD, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center }, true)
    end
    label(head, title, 15, T.text, FONT_BOLD, { Position = UDim2.fromOffset(52, 12), Size = UDim2.new(1, -110, 0, 20) })
    label(head, sub or "", 11, T.muted, FONT, { Position = UDim2.fromOffset(52, 33), Size = UDim2.new(1, -110, 0, 14) })
    rowCount[c] = 0
    return c, head
end

-- a row: title/sub on the left, a widget on the right. returns the row and its sub label
local function row(parent, title, sub, height, image)
    local n = (rowCount[parent] or 0) + 1
    rowCount[parent] = n
    local h = height or (sub and 48 or 38)
    local r = new("Frame", { Parent = parent, LayoutOrder = n, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, h) }, { pad(0, 16, 0, 16) })
    new("Frame", { Parent = r, Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = WHITE, BackgroundTransparency = LINE, BorderSizePixel = 0 })
    local x, img = 0, nil
    if image then
        local _, pic = icon(r, image, 26, "•", T.faint, { Position = UDim2.new(0, 0, 0.5, -13) })
        img, x = pic, 36
    end
    if title then label(r, title, 13, T.text, FONT_SEMI, { Position = UDim2.fromOffset(x, sub and 8 or 0), Size = UDim2.new(1, -110 - x, 0, sub and 18 or h) }) end
    local subLabel = sub and label(r, sub, 10, T.muted, FONT, { Position = UDim2.fromOffset(x, 26), Size = UDim2.new(1, -110 - x, 0, 14) })
    return r, subLabel, img
end

-- returns the value label and the row picture (when `image` is given)
local function valueRow(parent, title, color, image)
    local r, _, img = row(parent, title, nil, image and 44 or nil, image)
    return label(r, "—", 12, color or T.muted, FONT_SEMI, {
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0.6, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Right,
    }, true), img
end

local function switchRow(parent, title, sub, key, onChange, image)
    local r, subLabel, img = row(parent, title, sub, nil, image)
    local _, refresh = switch(r, function() return settings[key] end, function()
        settings[key] = not settings[key]; save()
        if onChange then onChange() end
    end)
    return subLabel, refresh, img
end

-- [ − 20 + ] box on the right of a row; the number can also be typed
local function stepperRow(parent, title, sub, key, min, max, step, fmt)
    local r = row(parent, title, sub)
    local box = new("Frame", { Parent = r, BackgroundColor3 = T.bg, BorderSizePixel = 0 }, { corner(8), line(LINE2) })
    rightAnchor(box, 96, 28)
    local function btn(text, right)
        local b = new("TextButton", {
            Parent = box, AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(right and 1 or 0, 0),
            Position = UDim2.new(right and 1 or 0, 0, 0, 0), Size = UDim2.fromOffset(24, 28),
            Text = text, FontFace = FONT_BOLD, TextSize = 14, TextColor3 = T.muted,
        })
        b.MouseEnter:Connect(function() tween(b, { TextColor3 = T.accentT }, MOTION.hover) end)
        b.MouseLeave:Connect(function() tween(b, { TextColor3 = T.muted }, MOTION.hover) end)
        return b
    end
    local minus, plus = btn("−", false), btn("+", true)
    local num = new("TextBox", {
        Parent = box, BackgroundTransparency = 1, ClearTextOnFocus = false, Position = UDim2.fromOffset(24, 0),
        Size = UDim2.new(1, -48, 1, 0), FontFace = FONT_BOLD, TextSize = 12, TextColor3 = T.text, Text = "",
    })
    local function refresh() num.Text = string.format(fmt or "%d", settings[key]) end
    local function apply(v)
        settings[key] = math.clamp(math.floor(v / step + 0.5) * step, min, max)
        save(); refresh()
        num.TextColor3 = T.accentT
        tween(num, { TextColor3 = T.text })
    end
    minus.MouseButton1Click:Connect(function() apply(settings[key] - step) end)
    plus.MouseButton1Click:Connect(function() apply(settings[key] + step) end)
    num.FocusLost:Connect(function() apply(tonumber(num.Text:match("[%d%.]+") or "") or settings[key]) end)
    refresh()
end

-- a full-width button row: title/sub on the left, the button on the right. returns the button
local function buttonRow(parent, title, sub, text, color, width)
    local r = row(parent, title, sub)
    local b = smallButton(r, text, width or 84, color)
    rightAnchor(b, width or 84, 28)
    return b
end

-- the language switch: every translated label follows at once
local function setLanguage(code)
    settings.lang = code; save()
    for obj, t in pairs(translated) do
        if obj.Parent then obj.Text = L(t.key, table.unpack(t.args, 1, t.args.n)) end
    end
    for _, f in ipairs(onLanguage) do pcall(f) end
end

-- filled in further down by the parts that own them (home tab buttons call these)
local actions = {}

---------------- egg farm tab: the Auto Egg card
local farmCard, farmHead = card(tab.farm.L, 1, "Auto Egg", "Run to the egg, break it, bring the animal home", IMG.eggs, T.green)
local refreshFarm
local onFarmChanged = function() end -- set by the zone list
local stopTreadmill = function() end -- set by the treadmill card: farming and the treadmill are one or the other
do
    local _, r = switch(farmHead, function() return settings.farm end, function()
        settings.farm = not settings.farm; save(); onFarmChanged()
        if settings.farm then stopTreadmill() end
    end)
    refreshFarm = r
end
local stepText   = valueRow(farmCard, "Doing", T.accentT)
local farmPic = {} -- pictures next to Target / Best animal
local targetText
targetText, farmPic.target = valueRow(farmCard, "Target", nil, IMG.eggs)
local roundText  = valueRow(farmCard, "This round", T.amber)
local bestText
bestText, farmPic.best = valueRow(farmCard, "Best animal", T.green, IMG.pets)
local placedText = valueRow(farmCard, "Stolen this session", T.green)
placedText.Text = "0"

do -- round options (farm tab) and the settings tab
    local roundCard = card(tab.farm.L, 2, "Round", "How long to break eggs and where to go after a steal", IMG.swing, T.amber)
    stepperRow(roundCard, "Break eggs for", "Seconds, then steal the best $/s", "window", 0, 120, 5, "%ds")
    switchRow(roundCard, "Place in the pen", "Off: only run back over the red line", "placeInPen")
    stepperRow(roundCard, "Place after", "Animals in the bag before going to the pen", "carry", 1, 50, 1)

    local langCard = card(tab.set.L, 1, "Language", "Pick the language for this window", "Aa", T.violet)
    local r = row(langCard, nil, nil, 52)
    local names, idx = {}, {}
    for i, l in ipairs(LANGS) do names[i] = l.name; idx[l.code] = i end
    local bar, refreshSeg
    bar, refreshSeg = segmented(r, names, function() return idx[settings.lang] or 2 end, function(i)
        setLanguage(LANGS[i].code); refreshSeg()
    end)
    bar.Position = UDim2.fromOffset(0, 10)

    local speedCard, speedHead = card(tab.set.L, 2, "Walk Speed", "Off: the bot runs at your normal game speed", IMG.walk, T.sky)
    switch(speedHead, function() return settings.speedOn end, function() settings.speedOn = not settings.speedOn; save() end)
    stepperRow(speedCard, "Speed", "Roblox default is 16", "walkSpeed", 16, 500, 5)

    local optCard = card(tab.set.R, 1, "Options", "Movement and staying online", "≡", T.violet)
    switchRow(optCard, "Walk around walls", "Off: run in a straight line", "pathfind")
    switchRow(optCard, "Anti AFK", "Stay in the server while farming", "antiAfk")

    local unloadCard = card(tab.set.R, 2, "Unload", "Close the window and stop everything", "×", T.red)
    local b = buttonRow(unloadCard, "Unload script", nil, "Unload", T.red, 84)
    b.MouseButton1Click:Connect(function()
        settings.farm, settings.treadmill = false, false
        genv.__BreakEggToken = nil
        gui:Destroy()
    end)
end

---------------- egg farm tab: zone picker
local renderZones -- forward
do
local zoneCard = card(tab.farm.R, 1, "Zones", "Tap a zone: run there, break an egg, bring the animal home", IMG.zone, T.green)
local zoneText = valueRow(zoneCard, "Farming", T.accentT)
local zoneScroll = new("ScrollingFrame", {
    Parent = zoneCard, LayoutOrder = 50, BackgroundTransparency = 1, BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 380), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y, ScrollBarThickness = 4, ScrollBarImageColor3 = T.faint,
}, { vlist(6), pad(4, 12, 10, 12) })

local function compact(n)
    n = tonumber(n) or 0
    for _, u in ipairs({ { 1e15, "Qa" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= u[1] then return (string.format("%.1f", n / u[1]):gsub("%.0$", "")) .. u[2] end
    end
    return tostring(math.floor(n))
end

local function pickZone(id)
    if settings.zone == id and settings.farm then
        settings.farm = false -- tapping the zone you are farming stops it
    else
        settings.zone, settings.farm = id, true
    end
    save(); refreshFarm(); renderZones()
    if settings.farm then stopTreadmill() end
end

local zoneRows = {} -- [zone id] = { button, ... } built once, updated in place (no flicker)
function renderZones()
    local counts = zoneCounts()
    for i, z in ipairs(zoneList()) do
        local picked = settings.zone == z.id
        local active = picked and settings.farm
        local n = counts[z.id] or 0
        local zr = zoneRows[z.id]
        if not zr then
            local b = new("TextButton", {
                Parent = zoneScroll, LayoutOrder = i, AutoButtonColor = false, Text = "", BorderSizePixel = 0,
                BackgroundColor3 = T.raised, Size = UDim2.new(1, 0, 0, 50),
            }, { corner(10) })
            zr = {
                b = b,
                stroke = new("UIStroke", { Parent = b, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = WHITE, Transparency = LINE, Thickness = 1 }),
                pic = select(2, icon(b, z.icon or IMG.zone, 34, tostring(z.index), T.faint, { Position = UDim2.fromOffset(10, 8) })),
                name = label(b, z.name, 13, T.text, FONT_SEMI, { Position = UDim2.fromOffset(54, 8), Size = UDim2.new(1, -150, 0, 18) }, true),
                info = label(b, "", 10, T.muted, FONT, { Position = UDim2.fromOffset(54, 27), Size = UDim2.new(1, -150, 0, 14) }, true),
                tag = label(b, "", 11, T.muted, FONT_BOLD, {
                    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 0), Size = UDim2.new(0, 90, 1, 0), TextXAlignment = Enum.TextXAlignment.Right,
                }, true),
            }
            zoneRows[z.id] = zr
            feel(b, function() return settings.zone == z.id and T.raised2 or T.raised end, T.raised2)
            b.MouseButton1Click:Connect(function() pickZone(z.id) end)
        end
        zr.b.BackgroundColor3 = picked and T.raised2 or T.raised
        zr.stroke.Color = active and T.green or (picked and T.accent or WHITE)
        zr.stroke.Transparency = picked and 0 or LINE
        zr.stroke.Thickness = picked and 2 or 1
        zr.pic.ImageTransparency = (n > 0 or picked) and 0 or 0.4
        zr.info.Text = "#" .. z.index .. "  ·  " .. (n > 0 and L("%d eggs now", n) or L("no eggs right now")) .. (z.power and ("  ·  " .. L("power %s", compact(z.power))) or "")
        zr.info.TextColor3 = n > 0 and T.green or T.muted
        zr.tag.Text = active and L("FARMING") or (picked and L("PICKED") or L("GO"))
        zr.tag.TextColor3 = active and T.green or (picked and T.accentT or T.muted)
    end
    zoneText.Text = settings.zone and (zoneName(settings.zone) .. (settings.farm and "" or ("  " .. L("(off)")))) or L("Tap a zone below")
end
end
onFarmChanged = function() pcall(renderZones) end
table.insert(onLanguage, function() pcall(renderZones) end)
do
    local ok, err = pcall(renderZones)
    if not ok then warn("[LAIKAHUB] zone list: " .. tostring(err)) end
end
task.spawn(function() -- refresh the egg counts now and then
    while alive() and gui.Parent do
        task.wait(3)
        pcall(renderZones)
    end
end)

---------------------------------------------------------------- character + movement
local function charParts()
    local c = LocalPlayer.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    local root = c and c:FindFirstChild("HumanoidRootPart")
    if hum and root and hum.Health > 0 then return c, hum, root end
end

local function farmOn() return alive() and settings.farm and gui.Parent ~= nil end
local function treadOn() return alive() and settings.treadmill and gui.Parent ~= nil end

-- Steering. Humanoid:MoveTo is slow here: the default control script sends a zero move every frame when no
-- key is held, so MoveDirection flickers and the game's GroundGrip (velocity = MoveDirection * WalkSpeed,
-- smoothed) keeps braking. Instead we press "the keys" ourselves: every frame, right after the control
-- script, Humanoid:Move toward the target. That is exactly what your keyboard does, so the bot runs at
-- your real speed (trail, potions, treadmill speed and all).
local moveTarget -- Vector3 or nil
local function steerTo(pos) moveTarget = pos end
local function stopMoving()
    moveTarget = nil
    local _, hum = charParts()
    if hum then hum:Move(Vector3.zero, false) end
end
do
    local NAME = "LAIKAHUB_Steer"
    RunService:BindToRenderStep(NAME, Enum.RenderPriority.Character.Value + 1, function()
        if not alive() then
            pcall(RunService.UnbindFromRenderStep, RunService, NAME)
            return
        end
        if not moveTarget then return end
        if not (settings.farm or settings.treadmill) or not gui.Parent then moveTarget = nil return end -- switched off mid-walk
        local _, hum, root = charParts()
        if not hum then return end
        local d = Vector3.new(moveTarget.X - root.Position.X, 0, moveTarget.Z - root.Position.Z)
        if d.Magnitude < 0.5 then hum:Move(Vector3.zero, false) return end
        hum:Move(d.Unit, false)
    end)
end

local function flat(a, b) return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude end

-- nothing solid between us and the goal (two rays: waist and knee height)
local function clearLine(from, to)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LocalPlayer.Character }
    local dir = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
    if dir.Magnitude < 1 then return true end
    for _, dy in ipairs({ 0, -1.5 }) do
        local hit = workspace:Raycast(from + Vector3.new(0, dy, 0), dir, params)
        local inst = hit and hit.Instance
        local soft = inst and (not inst.CanCollide or inst.Transparency >= 1 or CollectionService:HasTag(inst, EGG_TAG)
            or (inst.Parent and inst.Parent:FindFirstChildOfClass("Humanoid") ~= nil)) -- the egg itself, other players
        if inst and not soft and (hit.Position - from).Magnitude < dir.Magnitude - 3 then
            return false
        end
    end
    return true
end

-- Walk to a point until `arrived()` is true, at whatever WalkSpeed the character has (the game's speed, or
-- ours while the Walk Speed switch is on). Runs straight at the goal whenever nothing is in the way and only
-- uses pathfinding around walls, so the character never stops to plan. Gives up when `keepGoing()` or
-- `owner()` (farmOn by default) turns false, or after `timeout`.
local function walkTo(getGoal, arrived, keepGoing, timeout, owner)
    owner = owner or farmOn
    local started = os.clock()
    local lastPos, lastCheck, stuckFor = nil, os.clock(), 0
    local waypoints, wpIndex, forcePath = nil, 0, false
    local function going() return owner() and keepGoing() and os.clock() - started < (timeout or 40) end

    while going() do
        local _, hum, root = charParts()
        if not hum then return false end
        if arrived(root.Position) then return true end
        local goal = getGoal()
        if not goal then return false end

        local direct = not settings.pathfind or (not forcePath and clearLine(root.Position, goal))
        if direct then
            waypoints = nil
            steerTo(goal)
        else
            if not waypoints or wpIndex > #waypoints then
                local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 12 })
                local ok = pcall(function() path:ComputeAsync(root.Position, goal) end)
                if ok and path.Status == Enum.PathStatus.Success then
                    waypoints, wpIndex = path:GetWaypoints(), 2
                else
                    waypoints, wpIndex = { { Position = goal, Action = Enum.PathWaypointAction.Walk } }, 1
                end
                forcePath = false
            end
            local wp = waypoints[wpIndex]
            if wp then
                if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
                steerTo(wp.Position)
                -- close enough to move on: further when running fast, so we never brake at a waypoint
                if flat(root.Position, wp.Position) < math.max(4, hum.WalkSpeed * 0.15) then wpIndex += 1 end
            end
        end

        task.wait(0.05)

        -- stuck check every 0.5s: jump, and after a while plan a path even if the line looked clear
        if os.clock() - lastCheck >= 0.5 then
            local _, h2, r2 = charParts()
            if h2 then
                if lastPos and (r2.Position - lastPos).Magnitude < 1 then
                    stuckFor += os.clock() - lastCheck
                    if stuckFor > 1 then h2.Jump = true end
                    if stuckFor > 2 then forcePath, waypoints, stuckFor = true, nil, 0 end
                else
                    stuckFor = 0
                end
                lastPos = r2.Position
            end
            lastCheck = os.clock()
        end
    end
    return false
end

---------------------------------------------------------------- tools
local function backpack() return LocalPlayer:FindFirstChildOfClass("Backpack") end

local function animalTools()
    local out = {}
    for _, holder in ipairs({ LocalPlayer.Character, backpack() }) do
        if holder then
            for _, t in ipairs(holder:GetChildren()) do
                if t:IsA("Tool") and CollectionService:HasTag(t, TOOL_TAG) then table.insert(out, t) end
            end
        end
    end
    return out
end

-- animals in our hands right now (stolen, not banked yet). AnimalTools are the animals we already own
-- (the Backpack inventory), so they do not count here.
local function carrying()
    local n = tonumber(LocalPlayer:GetAttribute("CarryCount")) or 0
    return math.max(n, LocalPlayer:GetAttribute("Carrying") ~= nil and 1 or 0)
end

local function equip(tool)
    local c, hum = charParts()
    if not hum then return false end
    if tool.Parent == c then return true end
    hum:EquipTool(tool)
    local t0 = os.clock()
    while tool.Parent ~= c and os.clock() - t0 < 1.5 do task.wait(0.05) end
    return tool.Parent == c
end

local function equipPickaxe()
    local c = LocalPlayer.Character
    local pick = c and c:FindFirstChild("Pickaxe")
    if pick and pick:IsA("Tool") then return true end
    local bp = backpack()
    pick = bp and bp:FindFirstChild("Pickaxe")
    return pick and pick:IsA("Tool") and equip(pick) or false
end

---------------------------------------------------------------- the loop: egg -> animal -> home
local stats = { stolen = 0 }
local hitSeq = 0

local function wanted(part)
    return settings.zone ~= nil and eggZone(part) == settings.zone
end

local function findEgg()
    local _, _, root = charParts()
    if not root then return nil end
    local best, bestD
    for _, p in ipairs(CollectionService:GetTagged(EGG_TAG)) do
        if p:IsA("BasePart") and eggLive(p) and wanted(p) then
            local d = (p.Position - root.Position).Magnitude
            if not bestD or d < bestD then best, bestD = p, d end
        end
    end
    return best
end

local function hitOnce(egg)
    if PickaxeController and PickaxeController.Swing then
        task.spawn(pcall, PickaxeController.Swing, egg) -- own thread, see isolated()
        return
    end
    local remote = ReplicatedStorage:FindFirstChild("EggHitRequest")
    if remote then
        hitSeq += 1
        remote:FireServer(egg, hitSeq)
    end
end

-- deadline (os.clock time) = give up when the round runs out
local function breakEgg(egg, deadline)
    local name = eggName(egg)
    targetText.Text = name
    do -- the egg's own picture
        local ok, et = pcall(egg.GetAttribute, egg, "EggType")
        local pic = eggImage(ok and type(et) == "string" and et or name)
        if pic == "" then pic = eggImage(name) end
        farmPic.target.Image = pic ~= "" and pic or IMG.eggs
    end
    stepText.Text = L("Running to %s", name)
    setStatus("Running to egg", true)
    local inRange = function(pos) return surfaceDistance(egg, pos) <= HIT_RANGE - 2.5 end
    local keep = function() return eggLive(egg) and (not deadline or os.clock() < deadline) end
    if not walkTo(function() return egg.Position end, inRange, keep, 120) then -- far zones take a while
        return false
    end
    stopMoving()
    stepText.Text = L("Breaking %s", name)
    setStatus("Breaking egg", true)
    local t0 = os.clock()
    while farmOn() and keep() and os.clock() - t0 < 120 do
        local _, _, root = charParts()
        if not root then return false end
        if not inRange(root.Position) then -- pushed away
            walkTo(function() return egg.Position end, inRange, keep, 15)
            stopMoving()
        end
        equipPickaxe()
        hitOnce(egg)
        task.wait(0.1)
    end
    return not eggLive(egg)
end

-- where a prompt sits in the world (its parent is an Attachment, a part or a model)
local function promptPos(prompt)
    local p = prompt.Parent
    if not p then return nil end
    if p:IsA("Attachment") then return p.WorldPosition end
    if p:IsA("BasePart") then return p.Position end
    if p:IsA("Model") then return p:GetPivot().Position end
    local part = p:FindFirstAncestorWhichIsA("BasePart")
    return part and part.Position
end

local function isStealPrompt(prompt)
    if not (prompt:IsA("ProximityPrompt") and prompt.Parent) then return false end
    if prompt.Name == "StealPrompt" then return true end
    return string.lower(tostring(prompt.ActionText)):find("steal", 1, true) ~= nil
end

-- an attribute on the prompt's model (pickups keep ReservedUserId / HatchBreakerUserId / Despawning there)
local function modelAttr(prompt, name)
    local inst = prompt.Parent
    while inst and inst ~= workspace do
        local ok, v = pcall(inst.GetAttribute, inst, name)
        if ok and v ~= nil then return v end
        inst = inst.Parent
    end
end

-- every steal prompt we can find: tagged pickups, tagged SmartPrompts, and (every few seconds) the whole map
local lastFullScan, scanned = 0, {}
local function stealPrompts()
    local out, seen = {}, {}
    local function add(p) if not seen[p] and isStealPrompt(p) then seen[p] = true; table.insert(out, p) end end
    for _, m in ipairs(CollectionService:GetTagged(PICKUP_TAG)) do
        for _, d in ipairs(m:GetDescendants()) do if d:IsA("ProximityPrompt") then add(d) end end
    end
    for _, p in ipairs(CollectionService:GetTagged("SmartPrompt")) do add(p) end
    if #out == 0 and os.clock() - lastFullScan > 2 then
        lastFullScan, scanned = os.clock(), {}
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("ProximityPrompt") and isStealPrompt(d) then table.insert(scanned, d) end
        end
    end
    for _, p in ipairs(scanned) do add(p) end
    return out
end

-- what is near the egg, printed to the console when nothing stealable turns up
local function dumpNear(near)
    warn("[LAIKAHUB] no steal prompt found near the egg. Prompts within 60 studs:")
    local n = 0
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            local pos = promptPos(d)
            if pos and (pos - near).Magnitude < 60 then
                n += 1
                warn(string.format("  %s  name=%s action=%q enabled=%s reserved=%s",
                    d:GetFullName(), d.Name, tostring(d.ActionText), tostring(d.Enabled), tostring(modelAttr(d, "ReservedUserId"))))
            end
        end
    end
    if n == 0 then warn("  (none)") end
    local tags = #CollectionService:GetTagged(PICKUP_TAG)
    warn("[LAIKAHUB] AnimalPickup tagged: " .. tags .. ", SmartPrompt tagged: " .. #CollectionService:GetTagged("SmartPrompt"))
end

-- the pickup model a prompt belongs to (the AnimalPickup-tagged model, else its outermost model)
local function pickupRoot(prompt)
    local inst, best = prompt.Parent, nil
    while inst and inst ~= workspace do
        if inst:IsA("Model") then
            best = inst
            if CollectionService:HasTag(inst, PICKUP_TAG) then return inst end
        end
        inst = inst.Parent
    end
    return best
end

-- "$1.2K/s" -> 1200 (FormatNumber.Short suffixes)
local SUFFIX = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, Qa = 1e15, Qi = 1e18, Sx = 1e21, Sp = 1e24, Oc = 1e27, No = 1e30, Dc = 1e33 }
local function parseCash(text)
    text = tostring(text):gsub("<[^>]->", ""):gsub(",", "") -- strip rich text and commas
    local num, suf = text:match("%$%s*([%d%.]+)%s*(%a*)%s*/%s*s")
    if not num then return nil end
    return (tonumber(num) or 0) * (SUFFIX[suf] or 1)
end

-- Overheads ("$4/s", rarity, despawn timer) are BillboardGuis that do not have to sit inside the same
-- model as the Steal prompt, so they are matched by position: the closest one above the prompt wins.
local boards = setmetatable({}, { __mode = "k" })
local function trackBoard(d) if d:IsA("BillboardGui") then boards[d] = true end end
task.spawn(function()
    for _, d in ipairs(workspace:GetDescendants()) do trackBoard(d) end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then
        for _, d in ipairs(pg:GetDescendants()) do trackBoard(d) end
        pg.DescendantAdded:Connect(trackBoard)
    end
end)
workspace.DescendantAdded:Connect(trackBoard)

local function instPos(a)
    if not a then return nil end
    if a:IsA("Attachment") then return a.WorldPosition end
    if a:IsA("BasePart") then return a.Position end
    if a:IsA("Model") then return a:GetPivot().Position end
    local part = a:FindFirstAncestorWhichIsA("BasePart")
    return part and part.Position
end

local function boardCash(b)
    local best
    for _, d in ipairs(b:GetDescendants()) do
        if d:IsA("TextLabel") and d.Visible then
            local v = parseCash(d.ContentText ~= "" and d.ContentText or d.Text)
            if v and (not best or v > best) then best = v end
        end
    end
    return best
end

local function flatDist(a, b) return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude end

-- money per second the animal makes: the closest "$…/s" overhead to the prompt (or an attribute on its model)
local function animalCash(prompt)
    local root = pickupRoot(prompt)
    if root then
        for _, key in ipairs({ "CashPerSecond", "Cash", "Income" }) do
            local v = root:GetAttribute(key)
            if type(v) == "number" then return v end
        end
    end
    local pos = promptPos(prompt)
    if not pos then return nil end
    local best, bestD
    for b in pairs(boards) do
        if b.Parent and b.Enabled then
            local bp = instPos(b.Adornee or b.Parent)
            if bp and math.abs(bp.Y - pos.Y) < 25 then
                local d = flatDist(bp, pos)
                if d < 8 and (not bestD or d < bestD) then
                    local cash = boardCash(b)
                    if cash then best, bestD = cash, d end
                end
            end
        end
    end
    return best
end

-- the animal's name: AnimalName on its model, else the closest AnimalPickup model
local function animalLabel(prompt)
    local v = modelAttr(prompt, "AnimalName")
    if v then return tostring(v) end
    local pos = promptPos(prompt)
    local best, bestD
    for _, m in ipairs(CollectionService:GetTagged(PICKUP_TAG)) do
        if m:IsA("Model") and m.Parent and pos then
            local d = flatDist(m:GetPivot().Position, pos)
            if d < 10 and (not bestD or d < bestD) then best, bestD = m, d end
        end
    end
    if best then return tostring(best:GetAttribute("AnimalName") or best:GetAttribute("HatchAnimal") or best.Name) end
    local root = pickupRoot(prompt)
    return root and root.Name or "animal"
end

local function shortCash(n)
    if not n then return "?" end
    local units = { { 1e21, "Sx" }, { 1e18, "Qi" }, { 1e15, "Qa" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
    for _, u in ipairs(units) do
        if n >= u[1] then return "$" .. (string.format("%.1f", n / u[1]):gsub("%.0$", "")) .. u[2] .. "/s" end
    end
    return "$" .. math.floor(n) .. "/s"
end

-- every animal we may steal near the spots where our eggs broke: { prompt, cash, name }
local function candidatesNear(spots)
    local out = {}
    for _, p in ipairs(stealPrompts()) do
        local pos = promptPos(p)
        local reserved = modelAttr(p, "ReservedUserId")
        if pos and p.Enabled and not modelAttr(p, "Despawning") and (reserved == nil or reserved == LocalPlayer.UserId) then
            for _, s in ipairs(spots) do
                if (pos - s.pos).Magnitude < 40 then
                    table.insert(out, { prompt = p, cash = animalCash(p) or 0, name = animalLabel(p),
                        ours = modelAttr(p, "HatchBreakerUserId") == LocalPlayer.UserId })
                    break
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.cash ~= b.cash then return a.cash > b.cash end
        return a.ours and not b.ours
    end)
    return out
end

local function firePrompt(prompt)
    if fireproximityprompt then
        pcall(fireproximityprompt, prompt)
    else
        prompt:InputHoldBegin()
        task.wait((prompt.HoldDuration or 0) + 0.1)
        prompt:InputHoldEnd()
    end
end

-- walk to one animal and press Steal until it is ours
local function stealPrompt(prompt, name)
    stepText.Text = L("Stealing %s", name)
    setStatus("Stealing", true)
    local before = carrying()
    local reach = math.max(4, (prompt.MaxActivationDistance or 10) - 3)
    local function usable() return prompt.Parent ~= nil and not modelAttr(prompt, "Despawning") end
    walkTo(function() return promptPos(prompt) end,
        function(pos) local p = promptPos(prompt); return p and (p - pos).Magnitude <= reach end,
        usable, 20)
    stopMoving()
    local t1 = os.clock()
    while farmOn() and usable() and carrying() <= before and os.clock() - t1 < 8 do
        if prompt.Enabled then firePrompt(prompt) end
        task.wait(0.4)
    end
    local ok = carrying() > before or not prompt.Parent -- the prompt goes away once the animal is ours
    if not ok then warn("[LAIKAHUB] pressed Steal on " .. prompt:GetFullName() .. " but nothing was picked up") end
    return ok
end

-- set by the carry guard further down: true once the animal we were running home with is gone
local lostCarry = function() return false end

---------------- safe zone (the red line)
local function safeZone()
    local build = workspace:FindFirstChild("Build")
    local boxes = build and build:FindFirstChild("ZoneHitboxes")
    local s = boxes and boxes:FindFirstChild("SafeZone")
    return s and s:IsA("BasePart") and s or nil
end

-- run back over the red line: the nearest point a few studs inside the Safe Zone
local function goSafe()
    local safe = safeZone()
    if not safe then return false end
    stepText.Text = L("Running to the Safe Zone")
    setStatus("Escaping", true)
    local function inside(pos, margin)
        local p = safe.CFrame:PointToObjectSpace(pos)
        local h = safe.Size * 0.5
        return math.abs(p.X) <= h.X - margin and math.abs(p.Z) <= h.Z - margin and math.abs(p.Y) <= h.Y + 4
    end
    local function goal()
        local _, _, root = charParts()
        if not root then return nil end
        local p = safe.CFrame:PointToObjectSpace(root.Position)
        local h = safe.Size * 0.5
        local m = 8 -- studs past the line
        local x = math.clamp(p.X, -h.X + m, h.X - m)
        local z = math.clamp(p.Z, -h.Z + m, h.Z - m)
        local w = safe.CFrame:PointToWorldSpace(Vector3.new(x, 0, z))
        return Vector3.new(w.X, root.Position.Y, w.Z)
    end
    local ok = walkTo(goal, function(pos) return inside(pos, 4) end, function() return not lostCarry() end, 60)
    stopMoving()
    return ok and not lostCarry()
end

---------------- remotes
local function fire(name, ...)
    local r = ReplicatedStorage:FindFirstChild(name)
    if r and r:IsA("RemoteEvent") then r:FireServer(...) return true end
    warn("[LAIKAHUB] remote missing: " .. name)
    return false
end

-- the game's own "Equip Best" button: puts your highest $/s animals in the pen slots
local function equipBest() return fire("PetsInventoryRemote", "EquipBest", nil) end

---------------- home
local function myPlot()
    local plots = workspace:FindFirstChild("Plots")
    for _, p in ipairs(plots and plots:GetChildren() or {}) do
        if p:GetAttribute("OwnerUserId") == LocalPlayer.UserId then return p end
    end
end

local function inPart(part, pos)
    local p = part.CFrame:PointToObjectSpace(pos)
    local h = part.Size * 0.5
    return math.abs(p.X) <= h.X and math.abs(p.Y) <= h.Y + 2 and math.abs(p.Z) <= h.Z
end

local function penFull(plot)
    local placed = tonumber(plot:GetAttribute("AnimalsPlaced")) or 0
    local max = tonumber(plot:GetAttribute("MaxAnimals"))
    return max ~= nil and placed >= max
end

-- a free spot on the pen floor near us (inside the Hitbox, within place range)
local function placeSpot(hitbox, root)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LocalPlayer.Character, hitbox }
    local h = hitbox.Size * 0.5
    for _ = 1, 12 do
        local local3 = Vector3.new((math.random() * 2 - 1) * h.X * 0.7, h.Y, (math.random() * 2 - 1) * h.Z * 0.7)
        local top = hitbox.CFrame:PointToWorldSpace(local3) + Vector3.new(0, 5, 0)
        local hit = workspace:Raycast(top, Vector3.new(0, -(hitbox.Size.Y + 30), 0), params)
        local pos = hit and hit.Position or (top - Vector3.new(0, 5 + hitbox.Size.Y, 0))
        local flat = Vector3.new(pos.X - root.Position.X, 0, pos.Z - root.Position.Z)
        if inPart(hitbox, pos) and flat.Magnitude < PLACE_RANGE - 8 then return pos end
    end
    return hitbox.Position
end

local placeSeq = 100000
local placing = false
local function goHomeAndPlace()
    placing = false
    local plot = myPlot()
    local hitbox = plot and plot:FindFirstChild("Hitbox")
    if not (hitbox and hitbox:IsA("BasePart")) then
        stepText.Text = L("Can't find your pen")
        setStatus("No pen found", false)
        task.wait(2)
        return false
    end
    stepText.Text = L("Running home")
    setStatus("Running home", true)
    local center = hitbox.Position
    walkTo(function() return center end, function(pos) return inPart(hitbox, pos) and (pos - center).Magnitude < 25 end,
        function() return not lostCarry() end, 120)
    stopMoving()
    if lostCarry() then return false end
    placing = true -- the animals leaving our hands from here on are being placed, not lost

    local t0 = os.clock()
    while farmOn() and os.clock() - t0 < 6 and #animalTools() == 0 do task.wait(0.2) end -- tool shows up at the pen
    if #animalTools() == 0 then
        warn("[LAIKAHUB] at the pen but no AnimalTool in Backpack/Character (Carrying=" .. tostring(LocalPlayer:GetAttribute("Carrying"))
            .. ", CarryCount=" .. tostring(LocalPlayer:GetAttribute("CarryCount")) .. ")")
    end

    for _, tool in ipairs(animalTools()) do
        if not farmOn() then break end
        if penFull(plot) then
            stepText.Text = L("Pen is full")
            setStatus("Pen full: upgrade it", false)
            settings.farm = false; save(); refreshFarm()
            return false
        end
        stepText.Text = L("Placing %s", tool.Name)
        setStatus("Placing", true)
        for _ = 1, 4 do
            if not tool.Parent or not equip(tool) then break end
            local _, _, root = charParts()
            if not root then break end
            placeSeq += 1
            local remote = ReplicatedStorage:FindFirstChild("PlaceAnimalRemote")
            if remote then remote:FireServer(tool, placeSpot(hitbox, root), placeSeq) end
            local t1 = os.clock()
            while tool.Parent and os.clock() - t1 < 2.5 do task.wait(0.1) end
            if not tool.Parent or not tool:IsDescendantOf(game) then break end
        end
    end
    placing = false
    if settings.autoEquipBest then equipBest() end
    return true
end

---------------- carry guard
do -- (own scope: the main chunk would otherwise pass Luau's 200-register limit)
-- On the way back a zone guard can catch us (we get flung and ragdolled) or a player can hit us, and the
-- animal falls off. We notice that as "fewer animals in our hands while outside the Safe Zone, not right
-- after the game banked one and not while placing", go back to where it happened, steal the same animal
-- again (same name, same $/s) and run again.
local bankedAt = 0
task.spawn(function()
    local r = ReplicatedStorage:WaitForChild("AnimalBankedRemote", 30)
    if r and r:IsA("RemoteEvent") then r.OnClientEvent:Connect(function() bankedAt = os.clock() end) end
end)

local carryJob -- { count, name, cash, lastPos, dropPos } while we run a stolen animal home

-- Being caught, straight from the game: a zone guard bumps its CatchPulse with CaughtUserId = us, the
-- server sends CatchFlingRemote "fling", or a bat hit sets the character's Ragdolled attribute.
-- The fling throws us back over the red line, so "we are in the Safe Zone" must not count as banked then.
local caughtAt, caughtPos = -100, nil
local function carryState()
    return string.format("Carrying=%s CarryCount=%s owned=%d", tostring(LocalPlayer:GetAttribute("Carrying")),
        tostring(LocalPlayer:GetAttribute("CarryCount")), #animalTools())
end
local function onCaught(why)
    if os.clock() - caughtAt < 1 then return end
    local _, _, root = charParts()
    caughtAt = os.clock()
    caughtPos = (carryJob and carryJob.lastPos) or (root and root.Position)
    local job = carryJob
    if job then
        job.caughtAt = os.clock()
        job.hadCarrying = true -- we were running it home; the game clears Carrying before this signal arrives
        print("[LAIKAHUB] caught (" .. why .. ") while carrying " .. job.name .. "  " .. carryState())
        task.delay(2.5, function() print("[LAIKAHUB] 2.5s after the catch: " .. carryState()) end)
    end
end
task.spawn(function()
    local r = ReplicatedStorage:WaitForChild("CatchFlingRemote", 30)
    if r and r:IsA("RemoteEvent") then
        r.OnClientEvent:Connect(function(kind) if kind == "fling" then onCaught("guard fling") end end)
    end
end)
local function watchGuard(g)
    if not g:IsA("Model") then return end
    g:GetAttributeChangedSignal("CatchPulse"):Connect(function()
        if g:GetAttribute("CaughtUserId") == LocalPlayer.UserId then onCaught("guard " .. g.Name) end
    end)
end
for _, g in ipairs(CollectionService:GetTagged("ZoneGuard")) do watchGuard(g) end
CollectionService:GetInstanceAddedSignal("ZoneGuard"):Connect(watchGuard)
local function watchCharacter(c)
    c:GetAttributeChangedSignal("Ragdolled"):Connect(function()
        if c:GetAttribute("Ragdolled") then onCaught("knocked down") end
    end)
end
if LocalPlayer.Character then watchCharacter(LocalPlayer.Character) end
LocalPlayer.CharacterAdded:Connect(watchCharacter)
local function caughtRecently() return os.clock() - caughtAt < 5 end

-- the animal we were carrying, lying around again: same name or same $/s, near `where`
-- (anyEnabled = false also counts a prompt that is still switched off: a dropped animal can be locked for a moment)
local function findAgain(job, where, radius, anyEnabled)
    local best, bestScore
    for _, p in ipairs(stealPrompts()) do
        local pos = promptPos(p)
        local reserved = modelAttr(p, "ReservedUserId")
        if pos and (p.Enabled or anyEnabled) and not modelAttr(p, "Despawning") and (reserved == nil or reserved == LocalPlayer.UserId)
            and (pos - where).Magnitude < radius then
            local name, cashNow = animalLabel(p), animalCash(p) or 0
            local sameName = string.lower(name) == string.lower(job.name)
            local sameCash = (job.cash or 0) > 0 and math.abs(cashNow - job.cash) <= job.cash * 0.01
            if sameName or sameCash then
                local score = (pos - where).Magnitude - (sameName and 500 or 0) - (sameCash and 300 or 0)
                    - (reserved == LocalPlayer.UserId and 200 or 0)
                if not bestScore or score < bestScore then best, bestScore = p, score end
            end
        end
    end
    return best
end

lostCarry = function()
    local job = carryJob
    if not job then return false end
    if job.dropPos then return true end
    local _, _, root = charParts()
    if not root then -- died with it
        if job.count > 0 and job.lastPos then job.dropPos = job.lastPos return true end
        return false
    end
    if not caughtRecently() then job.lastPos = root.Position end -- keep where it happened, not where we were flung to
    if job.caughtAt and os.clock() - job.caughtAt < 12 and os.clock() - (job.lastLook or 0) > 0.25 then
        job.lastLook = os.clock()
        local where = caughtPos or job.lastPos or root.Position
        local seen = findAgain(job, where, 250, true) or (job.from and findAgain(job, job.from, 120, true))
        if seen then
            print("[LAIKAHUB] " .. job.name .. " is on the ground again after the catch  " .. carryState())
            job.dropPos = where
            return true
        end
        -- the game says our hands are empty and nothing was banked: it fell off, go look for it
        if job.hadCarrying and LocalPlayer:GetAttribute("Carrying") == nil and os.clock() - bankedAt > 1.5
            and os.clock() - job.caughtAt > 0.5 then
            print("[LAIKAHUB] hands empty after the catch, not banked: going to look for " .. job.name .. "  " .. carryState())
            job.dropPos = where
            return true
        end
    end
    local n = carrying()
    if n < job.count and caughtRecently() and os.clock() - bankedAt > 0.5 then
        job.dropPos = caughtPos or job.lastPos or root.Position
        return true
    elseif n < job.count then
        local safe = safeZone()
        local inSafe = false
        if safe then -- flat check: the zone part can be thin and we stand above it
            local lp, h = safe.CFrame:PointToObjectSpace(root.Position), safe.Size * 0.5
            inSafe = math.abs(lp.X) <= h.X + 2 and math.abs(lp.Z) <= h.Z + 2
        end
        if placing or os.clock() - bankedAt < 2 or inSafe then
            job.count = n -- banked or placed: that is the point
        else
            job.dropPos = root.Position
            return true
        end
    elseif n > job.count then
        job.count = n
    end
    return false
end


local function recoverDropped()
    local job = carryJob
    local where = job.dropPos
    stepText.Text = L("Caught! Going back for %s", job.name)
    setStatus("Getting it back", true)
    stopMoving()
    local t0 = os.clock() -- wait out the ragdoll (or the respawn)
    while farmOn() and os.clock() - t0 < 8 do
        local c = charParts()
        if c and not c:GetAttribute("Ragdolled") then break end
        task.wait(0.2)
    end
    local deadline = os.clock() + 20
    while farmOn() and os.clock() < deadline do
        local wide = os.clock() - deadline + 20 > 6 -- wider after 6s
        local best = findAgain(job, where, wide and 500 or 250) or (job.from and findAgain(job, job.from, wide and 300 or 120))
        local waiting = not best and (findAgain(job, where, 500, true) or (job.from and findAgain(job, job.from, 300, true)))
        if waiting then
            -- found but its prompt is still off: stand next to it until it can be stolen
            local pos = promptPos(waiting)
            if pos then
                stepText.Text = L("%s is locked for a moment, waiting next to it", job.name)
                walkTo(function() return pos end, function(at) return (at - pos).Magnitude < 6 end,
                    function() return not waiting.Enabled and waiting.Parent ~= nil end, 8)
            end
        end
        if best then
            local before = carrying()
            if stealPrompt(best, job.name .. " again") or carrying() > before then
                job.dropPos, job.count, job.caughtAt = nil, carrying(), nil
                caughtAt = -100 -- that catch is dealt with; banking it later is not another one
                return true
            end
        end
        stepText.Text = L("Looking for %s where we got caught", job.name)
        task.wait(0.3)
    end
    warn("[LAIKAHUB] lost " .. job.name .. " and could not find it again. Animals near the catch spot:")
    for _, m in ipairs(CollectionService:GetTagged(PICKUP_TAG)) do
        local ok, pos = pcall(function() return m:GetPivot().Position end)
        if ok and (pos - where).Magnitude < 500 then
            warn(string.format("  %s  AnimalName=%s  dist=%.0f  Reserved=%s  Despawning=%s", m:GetFullName(),
                tostring(m:GetAttribute("AnimalName")), (pos - where).Magnitude,
                tostring(m:GetAttribute("ReservedUserId")), tostring(m:GetAttribute("Despawning"))))
        end
    end
    dumpNear(where)
    return false
end

-- run the animal(s) we hold over the red line (or to the pen); if we lose it on the way, get it back and go again
local function bringHome(name, cashPerSec, from)
    if not name then
        local c = LocalPlayer:GetAttribute("Carrying")
        name = type(c) == "string" and c ~= "" and c or "your animal"
    end
    placing = false
    carryJob = { count = carrying(), name = name, cash = cashPerSec, from = from,
        hadCarrying = LocalPlayer:GetAttribute("Carrying") ~= nil }
    for attempt = 1, 5 do
        if not farmOn() then break end
        if settings.placeInPen and #animalTools() >= settings.carry then goHomeAndPlace() else goSafe() end
        if not lostCarry() and carryJob.caughtAt and os.clock() - carryJob.caughtAt < 12 then
            -- caught on the way: the animal may show up on the ground a moment later
            stepText.Text = L("Caught! Checking if %s fell off", name)
            local t = os.clock()
            while farmOn() and os.clock() - t < 4 and not lostCarry() do task.wait(0.15) end
            if not lostCarry() then
                print("[LAIKAHUB] caught, but " .. name .. " is not on the ground nearby  " .. carryState())
                if carryJob.caughtAt then dumpNear(caughtPos or carryJob.lastPos or Vector3.zero) end
            end
        end
        if not lostCarry() then break end
        print(string.format("[LAIKAHUB] dropped %s on the way back (try %d), going back for it", name, attempt))
        if attempt == 5 or not recoverDropped() then break end
    end
    carryJob = nil
end

---------------- main loop
-- A round: break eggs in the zone for `window` seconds (counted from the first egg that breaks),
-- then steal the animal with the highest $/s among the ones that hatched, run back over the red line, repeat.
local HATCH_WAIT = 10 -- seconds an egg may take to show its animal
local round = { started = nil, spots = {} }

local function resetRound()
    round = { started = nil, spots = {} }
    roundText.Text, bestText.Text = "—", "—"
    farmPic.best.Image = IMG.pets
end

local function showRound()
    if not round.started then roundText.Text = L("waiting for the first egg") return end
    local left = math.max(0, settings.window - (os.clock() - round.started))
    roundText.Text = L("%d eggs · %ds left", #round.spots, math.ceil(left))
    local c = candidatesNear(round.spots)
    bestText.Text = c[1] and L("%s  %s  · %d hatched", c[1].name, shortCash(c[1].cash), #c) or L("waiting for a hatch")
    local pic = c[1] and animalImage(c[1].name) or ""
    farmPic.best.Image = pic ~= "" and pic or IMG.pets
end

-- live "Best animal": refreshed while a round runs, and straight away when a new animal hatches
-- (its overhead can show up a moment after the pickup, so it keeps checking every half second too)
local bestDirty = false
CollectionService:GetInstanceAddedSignal(PICKUP_TAG):Connect(function() bestDirty = true end)
task.spawn(function()
    local last = 0
    while alive() and gui.Parent do
        task.wait(0.1)
        if settings.farm and round.started and (bestDirty or os.clock() - last > 0.5) then
            bestDirty, last = false, os.clock()
            pcall(showRound)
        end
    end
end)

-- after the round: wait for the late eggs to hatch, then take the best animal
local function finishRound()
    stepText.Text = L("Picking the best animal")
    setStatus("Comparing $/s", true)
    local last = 0
    for _, s in ipairs(round.spots) do last = math.max(last, s.at) end
    while farmOn() and os.clock() - last < HATCH_WAIT do
        -- every spot already shows an animal: no need to wait longer
        local c, covered = candidatesNear(round.spots), 0
        for _, s in ipairs(round.spots) do
            for _, a in ipairs(c) do
                local pos = promptPos(a.prompt)
                if pos and (pos - s.pos).Magnitude < 40 then covered += 1 break end
            end
        end
        if covered >= #round.spots then break end
        showRound()
        task.wait(0.3)
    end
    local list = candidatesNear(round.spots)
    if #list == 0 then
        dumpNear(round.spots[#round.spots].pos)
        resetRound()
        return
    end
    for i = 1, math.min(#list, 5) do
        print(string.format("[LAIKAHUB] #%d %s %s%s", i, list[i].name, shortCash(list[i].cash), list[i].ours and " (yours)" or ""))
    end
    if list[1].cash == 0 then -- no $/s matched: show what is around the prompt so it can be fixed
        local p = list[1].prompt
        local pos = promptPos(p)
        warn("[LAIKAHUB] no $/s found. Prompt: " .. p:GetFullName() .. " at " .. tostring(pos))
        for b in pairs(boards) do
            local bp = b.Parent and instPos(b.Adornee or b.Parent)
            if bp and pos and (bp - pos).Magnitude < 20 then
                local texts = {}
                for _, d in ipairs(b:GetDescendants()) do
                    if d:IsA("TextLabel") and d.Text ~= "" then table.insert(texts, d.Name .. "=" .. d.Text) end
                end
                warn(string.format("  board %s  dist=%.1f  %s", b:GetFullName(), (bp - pos).Magnitude, table.concat(texts, " | ")))
            end
        end
    end
    -- the best one first; if someone else grabs it, try the next
    for _, a in ipairs(list) do
        if not farmOn() then break end
        if a.prompt.Parent and a.prompt.Enabled then
            bestText.Text = a.name .. "  " .. shortCash(a.cash)
            local from = promptPos(a.prompt)
            if stealPrompt(a.prompt, a.name .. " " .. shortCash(a.cash)) then
                stats.stolen += 1
                placedText.Text = tostring(stats.stolen)
                bringHome(a.name, a.cash, from)
                break
            end
        end
    end
    resetRound()
end

task.spawn(function()
    while alive() and gui.Parent do
        if not settings.farm then
            if not settings.treadmill then setStatus("Idle", false) end
            stepText.Text = L("Off")
            if round.started then resetRound() end
            task.wait(0.3)
        elseif not charParts() then
            setStatus("Waiting for character", false)
            task.wait(1)
        else
            local ok, err = pcall(function()
                -- still carrying a stolen animal (e.g. after a restart): bring it over the line first
                if LocalPlayer:GetAttribute("Carrying") ~= nil and not round.started then
                    if settings.placeInPen then goHomeAndPlace() else bringHome(nil, nil) end
                    return
                end
                if round.started and os.clock() - round.started >= settings.window then
                    finishRound()
                    return
                end
                local egg = findEgg()
                if not egg then
                    stepText.Text = settings.zone and L("No eggs in %s yet", zoneName(settings.zone)) or L("Pick a zone")
                    targetText.Text = "—"
                    setStatus("Waiting for eggs", true)
                    showRound()
                    task.wait(0.5)
                    return
                end
                local where = egg.Position
                local deadline = round.started and (round.started + settings.window) or nil
                if breakEgg(egg, deadline) then
                    round.started = round.started or os.clock()
                    table.insert(round.spots, { pos = where, at = os.clock() })
                end
                showRound()
                if settings.window <= 0 and round.started then finishRound() end
            end)
            if not ok then
                warn("[LAIKAHUB] " .. tostring(err))
                stepText.Text = L("Error, retrying")
                task.wait(1)
            end
            task.wait(0.1)
        end
    end
    stopMoving()
end)

---------------- walk speed: keep our speed while the switch is on, give the game's back when it is off
do
    local gameSpeed -- what the game had set before we took over
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not (alive() and gui.Parent) then
            conn:Disconnect()
            local _, hum = charParts()
            if hum and gameSpeed then hum.WalkSpeed = gameSpeed end
            return
        end
        local _, hum = charParts()
        if not hum then gameSpeed = nil return end
        if settings.speedOn then
            if not gameSpeed then gameSpeed = hum.WalkSpeed end
            if hum.WalkSpeed ~= settings.walkSpeed then hum.WalkSpeed = settings.walkSpeed end
        elseif gameSpeed then
            hum.WalkSpeed = gameSpeed
            gameSpeed = nil
        end
    end)
end

---------------- anti AFK
LocalPlayer.Idled:Connect(function()
    if not (alive() and settings.antiAfk) then return end
    local vu = game:GetService("VirtualUser")
    vu:CaptureController()
    vu:ClickButton2(Vector2.new())
end)
end -- carry guard + main loop + walk speed + anti AFK

---------------------------------------------------------------- money helpers
do -- (own scope: the main chunk would otherwise pass Luau's 200-register limit)
local function cash() return tonumber(LocalPlayer:GetAttribute("Cash")) or 0 end
local function money(n) return (shortCash(n):gsub("/s$", "")) end

-- "1,4,7" attribute -> { [1]=true, [4]=true, [7]=true }
local function ownedSet(attr, ...)
    local set = {}
    for _, v in ipairs({ ... }) do if v then set[v] = true end end
    local s = LocalPlayer:GetAttribute(attr)
    if type(s) == "string" then
        for n in s:gmatch("[^,]+") do local v = tonumber(n) if v then set[v] = true end end
    end
    return set
end

-- one try per `gap` seconds per thing, so a refused purchase is not spammed
local lastTry = {}
local function canTry(key, gap)
    if os.clock() - (lastTry[key] or 0) < (gap or 3) then return false end
    lastTry[key] = os.clock()
    return true
end

---------------------------------------------------------------- treadmill
-- your treadmill: the plot's "<name> Treadmill" model with a Hitbox (not the TreadmillBoard)
local function myTreadmill(plot)
    for _, m in ipairs(plot:GetChildren()) do
        if m:IsA("Model") and m.Name:find("Treadmill") and m.Name ~= "TreadmillBoard" then
            local hb = m:FindFirstChild("Hitbox")
            if hb and hb:IsA("BasePart") then return m, hb end
        end
    end
end

local function treadUnlocked(plot) return plot:GetAttribute("TreadmillUnlocked") == true or myTreadmill(plot) ~= nil end

local treadLevelText -- also refreshed by the auto buy loop
do
-- the server tells us when a run starts (a number) and stops (anything else)
local treadRunning = false
task.spawn(function()
    local r = ReplicatedStorage:WaitForChild("TreadmillSessionRemote", 30)
    if r and r:IsA("RemoteEvent") then
        r.OnClientEvent:Connect(function(v) treadRunning = type(v) == "number" end)
    end
end)
LocalPlayer.CharacterAdded:Connect(function() treadRunning = false end)

local treadCard, treadHead = card(tab.tread.L, 1, "Treadmill", "Run on your own treadmill to get faster", IMG.tread, T.sky)
local treadText = valueRow(treadCard, "Doing", T.accentT)
treadLevelText = valueRow(treadCard, "Your treadmill")
local refreshTreadSwitch
do
    local _, r = switch(treadHead, function() return settings.treadmill end, function()
        settings.treadmill = not settings.treadmill; save()
        if settings.treadmill then settings.farm = false; save(); refreshFarm(); pcall(renderZones) end
    end)
    refreshTreadSwitch = r
end
actions.goTreadmill = function()
    settings.farm, settings.treadmill = false, true
    save(); refreshFarm(); refreshTreadSwitch(); pcall(renderZones)
end
buttonRow(treadCard, "Go to my treadmill", "Drops whatever it is doing, runs back and stays on it", "Go", T.green, 84)
    .MouseButton1Click:Connect(function() actions.goTreadmill() end)
stopTreadmill = function()
    if settings.treadmill then settings.treadmill = false; save(); refreshTreadSwitch() end
end

task.spawn(function()
    local standingSince
    while alive() and gui.Parent do
        if not settings.treadmill then
            standingSince = nil
            treadText.Text = L("Off")
            task.wait(0.3)
        else
            local ok, err = pcall(function()
                local _, hum, root = charParts()
                if not hum then treadText.Text = L("Waiting for character") task.wait(1) return end
                local plot = myPlot()
                if not plot then treadText.Text = L("Can't find your base") setStatus("No base found", false) task.wait(2) return end
                local _, hb = myTreadmill(plot)
                if not hb then
                    if not treadUnlocked(plot) and cash() >= TREAD_UNLOCK_COST and canTry("treadUnlock", 5) then
                        fire("UnlockTreadmillRequest")
                    end
                    treadText.Text = treadUnlocked(plot) and L("Treadmill not found") or L("Locked: unlock costs %s", money(TREAD_UNLOCK_COST))
                    setStatus("Treadmill locked", false)
                    task.wait(1)
                    return
                end
                local center = hb.Position
                local onIt = function(pos) return inPart(hb, pos) and flat(pos, center) < math.max(2.5, math.min(hb.Size.X, hb.Size.Z) * 0.3) end

                if not inPart(hb, root.Position) then
                    standingSince = nil
                    treadText.Text = L("Running to the treadmill")
                    setStatus("Going to treadmill", true)
                    walkTo(function() return center end, onIt, function() return true end, 180, treadOn)
                    stopMoving()
                    return
                end

                standingSince = standingSince or os.clock()
                if treadRunning then
                    standingSince = os.clock()
                    treadText.Text = L("Running on the treadmill")
                    setStatus("On treadmill", true)
                else
                    treadText.Text = L("On the treadmill, waiting for it to start")
                    setStatus("Treadmill", true)
                    if not onIt(root.Position) then steerTo(center) else stopMoving() end
                    -- nothing started after 4s: step off and back on so the server sees us arrive
                    if os.clock() - standingSince > 4 then
                        local out = (hb.CFrame * CFrame.new(0, 0, hb.Size.Z / 2 + 6)).Position
                        walkTo(function() return out end, function(pos) return not inPart(hb, pos) and flat(pos, out) < 3 end,
                            function() return true end, 5, treadOn)
                        standingSince = nil
                    end
                end
                task.wait(0.3)
            end)
            if not ok then warn("[LAIKAHUB] treadmill: " .. tostring(err)) task.wait(1) end
        end
    end
end)

end

---------------------------------------------------------------- auto buy / upgrade
do -- own scope: the main chunk is close to Luau's 200-locals limit
local buyCard = card(tab.shop.L, 1, "Auto Buy", "Buys and uses the best one as soon as the money is there", IMG.shop, T.amber)
local cashText = valueRow(buyCard, "Money", T.green)
local shopPic = {}
local pickSub, trailSub, penSub, treadSub
pickSub, shopPic.skip, shopPic.pick   = switchRow(buyCard, "Auto Pickaxe", "—", "autoPickaxe", nil, IMG.swing)
trailSub, shopPic.skip, shopPic.trail = switchRow(buyCard, "Auto Trail", "—", "autoTrail", nil, IMG.speed)
penSub   = switchRow(buyCard, "Auto Upgrade Pen", "—", "autoPen", nil, IMG.pets)
treadSub = switchRow(buyCard, "Auto Upgrade Treadmill", "—", "autoTreadmill", nil, IMG.tread)

-- Pickaxe: buy the dearest tier we can afford above the best we own, then hold the best we own.
-- If the shop refuses to skip tiers (nothing changes after two tries), buy them one by one instead.
local pickFails = {}
local function pickaxeStep()
    local tier = tonumber(LocalPlayer:GetAttribute("PickaxeTier")) or 1
    local owned = ownedSet("OwnedPickaxes", 1, tier)
    local top = 1
    for i in pairs(owned) do if PICKAXES[i] and i > top then top = i end end
    local nextOne = PICKAXES[top + 1]
    if settings.autoPickaxe then
        local m, buy = cash(), nil
        for i = top + 1, #PICKAXES do
            if PICKAXES[i].price <= m and (pickFails[i] or 0) < 2 then buy = i end
        end
        if not buy and nextOne and nextOne.price <= m then buy = top + 1 end -- skipping was refused
        if buy and canTry("pickaxe", 3) then
            pickFails[buy] = (pickFails[buy] or 0) + 1
            fire("PickaxeShopRequest", "Buy", buy)
            return L("Buying %s", PICKAXES[buy].name)
        end
        if tier ~= top and canTry("pickaxeEquip", 3) then fire("PickaxeShopRequest", "Equip", top) end
    end
    local name = PICKAXES[tier] and PICKAXES[tier].name or ("Tier " .. tier)
    local pic = pickaxeIcon(tier)
    if pic ~= "" and shopPic.pick.Image ~= pic then shopPic.pick.Image = pic end
    return nextOne and L("%s  ·  next %s", name, money(nextOne.price)) or L("%s  ·  best one", name)
end

-- Trail: same idea, ranked by speed multiplier
local trailFails = {}
local function trailStep()
    local worn = tonumber(LocalPlayer:GetAttribute("EquippedTrail")) or 0
    local owned = ownedSet("OwnedTrails", worn ~= 0 and worn or nil)
    local best
    for _, t in ipairs(TRAILS) do
        if owned[t.id] and (not best or t.mult > best.mult) then best = t end
    end
    local nextOne
    for _, t in ipairs(TRAILS) do
        if (not best or t.mult > best.mult) and (not nextOne or t.price < nextOne.price) then nextOne = t end
    end
    if settings.autoTrail then
        local m, buy = cash(), nil
        for _, t in ipairs(TRAILS) do
            if (not best or t.mult > best.mult) and t.price <= m and (trailFails[t.id] or 0) < 2
                and (not buy or t.mult > buy.mult) then buy = t end
        end
        if not buy and nextOne and nextOne.price <= m then buy = nextOne end
        if buy and canTry("trail", 3) then
            trailFails[buy.id] = (trailFails[buy.id] or 0) + 1
            fire("TrailShopRequest", "Buy", buy.id)
            return L("Buying %s", buy.name)
        end
        if best and worn ~= best.id and canTry("trailEquip", 3) then fire("TrailShopRequest", "Equip", best.id) end
    end
    local wornName = L("none")
    for _, t in ipairs(TRAILS) do
        if t.id == worn then
            wornName = t.name .. " x" .. t.mult
            if t.icon and shopPic.trail.Image ~= t.icon then shopPic.trail.Image = t.icon end
        end
    end
    return nextOne and L("%s  ·  next %s", wornName, money(nextOne.price)) or L("%s  ·  best one", wornName)
end

local function penStep()
    local plot = myPlot()
    if not plot then return L("Can't find your base") end
    local level = tonumber(plot:GetAttribute("PlotLevel")) or 1
    local slots = L("%s/%s animals", tostring(plot:GetAttribute("AnimalsPlaced") or "?"), tostring(plot:GetAttribute("MaxAnimals") or "?"))
    local cost = level < PEN_MAX and PEN_COSTS[level] or nil
    if not cost then return L("Lv.%d (max)  ·  %s", level, slots) end
    if settings.autoPen and cash() >= cost and canTry("pen", 3) then
        fire("UpgradePlotRequest")
        return L("Upgrading to Lv.%d", level + 1)
    end
    return L("Lv.%d  ·  %s  ·  next %s", level, slots, money(cost))
end

local function treadStep()
    local plot = myPlot()
    if not plot then return L("Can't find your base") end
    if not treadUnlocked(plot) then
        if settings.autoTreadmill and cash() >= TREAD_UNLOCK_COST and canTry("treadUnlock", 5) then
            fire("UnlockTreadmillRequest")
            return L("Unlocking")
        end
        return L("Locked  ·  unlock %s", money(TREAD_UNLOCK_COST))
    end
    local level = tonumber(plot:GetAttribute("TreadmillLevel")) or 1
    local cost = TREAD_COSTS[level]
    if not cost then return L("Lv.%d  ·  max", level) end
    if settings.autoTreadmill and cash() >= cost and canTry("tread", 3) then
        fire("UpgradeTreadmillRequest")
        return L("Upgrading to Lv.%d", level + 1)
    end
    return L("Lv.%d  ·  next %s", level, money(cost))
end

task.spawn(function()
    while alive() and gui.Parent do
        cashText.Text = money(cash())
        for _, step in ipairs({ { pickSub, pickaxeStep }, { trailSub, trailStep }, { penSub, penStep }, { treadSub, treadStep } }) do
            local ok, text = pcall(step[2])
            step[1].Text = ok and tostring(text) or ("error: " .. tostring(text))
        end
        local plot = myPlot()
        if plot then
            local level = tonumber(plot:GetAttribute("TreadmillLevel")) or 1
            local model = myTreadmill(plot)
            treadLevelText.Text = model and (model.Name .. "  ·  Lv." .. level) or L("locked")
        end
        task.wait(1)
    end
end)
end
end -- money helpers + treadmill + auto buy

---------------------------------------------------------------- PETS TAB + HOME TAB
--   equip best  PetsInventoryRemote "EquipBest" fills empty pen slots; to swap a weaker animal out we
--               send "Unequip" for it (the placed model in Plot.PlacedAnimals) and Equip Best again
--   value       EggRewards.PlacedCashPerSecond(AnimalName, SizeMult, Mutation, WeightKg, Variant), the
--               number the pen shows as "$x/s" (run in a game thread, see isolated())
--   sell        BackpackSellRemote:InvokeServer({ tool, … })  (RemoteFunction, up to 200 per call)
--   index       IndexRemote "Get" -> OnClientEvent("State", { [name] = "Ready" | "Claimed" | … }),
--               "ClaimAll" for the big Claim button, "Claim", name for each ready reward
do -- (own scope: the main chunk would otherwise pass Luau's 200-register limit)
local function cash() return tonumber(LocalPlayer:GetAttribute("Cash")) or 0 end
local function money(n) return (shortCash(n):gsub("/s$", "")) end
local EggRewards = tryRequire(Shared:FindFirstChild("EggRewards"))

-- $/s for each placed animal or Backpack tool in `list`, by the game's own formula
local function cpsOf(list)
    if #list == 0 or not (EggRewards and EggRewards.PlacedCashPerSecond) then return {} end
    return isolated(function()
        local out = {}
        for i, inst in ipairs(list) do
            local ok, v = pcall(function()
                local name = inst:GetAttribute("AnimalName")
                if type(name) ~= "string" then return 0 end
                return EggRewards.PlacedCashPerSecond(name, inst:GetAttribute("SizeMult") or 1, inst:GetAttribute("Mutation"),
                    inst:GetAttribute("WeightKg"), inst:GetAttribute("Variant"))
            end)
            out[i] = ok and tonumber(v) or 0
        end
        return out
    end) or {}
end

local function placedAnimals(plot)
    local folder = plot and plot:FindFirstChild("PlacedAnimals")
    local out = {}
    for _, m in ipairs(folder and folder:GetChildren() or {}) do
        if type(m:GetAttribute("AnimalName")) == "string" then table.insert(out, m) end
    end
    return out
end

-- animals in the Backpack (the one in your hand is left alone)
local function bagAnimals()
    local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
    local out = {}
    for _, t in ipairs(bp and bp:GetChildren() or {}) do
        if t:IsA("Tool") and type(t:GetAttribute("AnimalName")) == "string" and t.Name ~= "Pickaxe"
            and (CollectionService:HasTag(t, TOOL_TAG) or t:GetAttribute("WeightKg") ~= nil) then
            table.insert(out, t)
        end
    end
    return out
end

local function minOf(vals) local i, v = nil, math.huge for k, x in ipairs(vals) do if x > 0 and x < v then i, v = k, x end end return i, v end
local function maxOf(vals) local i, v = nil, 0 for k, x in ipairs(vals) do if x > v then i, v = k, x end end return i, v end

-- fill the pen, then keep swapping the weakest placed animal for the best one in the bag while that pays more
local busy = false
local function smartEquip()
    if busy then return 0 end
    busy = true
    local swaps = 0
    local ok, err = pcall(function()
        local plot = myPlot()
        if not plot then return end
        for _ = 1, 10 do
            if not alive() then break end
            local placed, bag = placedAnimals(plot), bagAnimals()
            if #bag == 0 then break end
            local max = tonumber(plot:GetAttribute("MaxAnimals")) or #placed
            if #placed < max then -- empty slots: the game's Equip Best fills them with the best ones
                equipBest()
                task.wait(1.2)
                if #placedAnimals(plot) <= #placed then break end
                swaps += 1
            else
                local wi, wv = minOf(cpsOf(placed))
                local _, bv = maxOf(cpsOf(bag))
                if not (wi and bv > wv) then break end
                fire("PetsInventoryRemote", "Unequip", placed[wi])
                task.wait(0.8)
                equipBest()
                task.wait(1.2)
                swaps += 1
            end
        end
    end)
    busy = false
    if not ok then warn("[LAIKAHUB] equip best: " .. tostring(err)) end
    return swaps
end

-- "25K" / "1.5m" / "$500" -> number
local function parseAmount(text)
    text = tostring(text):gsub(",", ""):gsub("%$", "")
    local num, suf = text:match("^%s*([%d%.]+)%s*(%a*)")
    if not num then return nil end
    local mult = 1
    for k, v in pairs(SUFFIX) do if string.lower(k) == string.lower(suf) then mult = v end end
    return (tonumber(num) or 0) * mult
end

-- Sell Backpack animals under the threshold. returns how many were sold, or nil + reason.
-- The server can turn a batch down, so it goes in passes: everything at once, then groups of 20, then one by
-- one for whatever is still there; it stops when nothing under the limit is left or a pass sells nothing.
-- verbose = print every animal with its $/s and what happened to it (the Sell button does that).
local function sellWeak(verbose)
    local limit = tonumber(settings.sellBelow) or 0
    if limit <= 0 then return nil, L("Set a $/s first") end
    local remote = ReplicatedStorage:FindFirstChild("BackpackSellRemote")
    if not (remote and remote:IsA("RemoteFunction")) then warn("[LAIKAHUB] BackpackSellRemote missing") return nil, "remote missing" end

    -- an animal in your hand that is under the limit goes back to the bag first (the game does the same)
    do
        local c, hum = charParts()
        local held = c and c:FindFirstChildOfClass("Tool")
        if hum and held and CollectionService:HasTag(held, TOOL_TAG) then
            local v = cpsOf({ held })[1] or 0
            if v > 0 and v < limit then hum:UnequipTools() task.wait(0.2) end
        end
    end

    local function under()
        local bag = bagAnimals()
        local vals = cpsOf(bag)
        local list, kept = {}, {}
        for i, t in ipairs(bag) do
            local v = vals[i] or 0
            if v > 0 and v < limit then table.insert(list, t) else table.insert(kept, { t, v }) end -- 0 = unknown: kept
        end
        return list, kept, vals, bag
    end
    local function sendBatch(batch)
        local ok, res = pcall(remote.InvokeServer, remote, batch)
        if not ok then warn("[LAIKAHUB] sell failed: " .. tostring(res)) end
        task.wait(0.4)
        local gone = 0
        for _, t in ipairs(batch) do if not t:IsDescendantOf(LocalPlayer) then gone += 1 end end
        if verbose then print(string.format("[LAIKAHUB] sell: sent %d, sold %d, server said %s", #batch, gone, tostring(res))) end
        return gone
    end

    local sold, size = 0, 200
    for _ = 1, 12 do
        local list = under()
        if #list == 0 then break end
        local passSold = 0
        for i = 1, #list, size do
            local batch = {}
            for j = i, math.min(i + size - 1, #list) do table.insert(batch, list[j]) end
            passSold += sendBatch(batch)
        end
        sold += passSold
        if passSold == 0 then
            if size == 1 then break end
            size = size > 20 and 20 or 1 -- the batch was turned down: smaller ones
        end
    end

    if verbose then
        local left, kept, vals, bag = under()
        print(string.format("[LAIKAHUB] sell below %s: sold %d, %d under the limit still in the bag", shortCash(limit), sold, #left))
        for i, t in ipairs(bag) do
            local v = vals[i] or 0
            print(string.format("   %-24s %-10s %s", tostring(t:GetAttribute("AnimalName")), shortCash(v),
                v == 0 and "kept: $/s unknown" or (v < limit and "STILL HERE (server kept it)" or "kept: above the limit")))
        end
        if #left > 0 then warn("[LAIKAHUB] the server did not sell " .. #left .. " animal(s) under the limit") end
        local _ = kept
    end
    return sold
end

-- index rewards
local indexState = {}
task.spawn(function()
    local r = ReplicatedStorage:WaitForChild("IndexRemote", 30)
    if r and r:IsA("RemoteEvent") then
        r.OnClientEvent:Connect(function(kind, t) if kind == "State" and type(t) == "table" then indexState = t end end)
        r:FireServer("Get", nil)
    end
end)
local function readyCount()
    local n = 0
    for _, st in pairs(indexState) do if st == "Ready" then n += 1 end end
    return n
end
local function claimIndex()
    local n = readyCount()
    fire("IndexRemote", "ClaimAll", nil)
    for name, st in pairs(indexState) do
        if st == "Ready" then fire("IndexRemote", "Claim", name) task.wait(0.15) end
    end
    task.delay(1, function() fire("IndexRemote", "Get", nil) end)
    return n
end

---------------- pets tab UI
local ui = {} -- labels the loop below keeps up to date
do local equipCard, equipHead = card(tab.pets.L, 1, "Equip Best", "Swaps in a better animal as soon as you get one", IMG.pets, T.pink)
switch(equipHead, function() return settings.autoEquipBest end, function() settings.autoEquipBest = not settings.autoEquipBest; save() end)
ui.penText  = valueRow(equipCard, "Pen", T.text)
ui.weakText, ui.weakPic = valueRow(equipCard, "Weakest in pen", T.amber, IMG.pets)
ui.bestBag, ui.bestPic  = valueRow(equipCard, "Best in bag", T.green, IMG.pets)
buttonRow(equipCard, "Equip Best now", "Fills the pen and swaps out weaker animals", "Equip", T.pink, 84).MouseButton1Click:Connect(function()
    task.spawn(function()
        local n = smartEquip()
        toast(n > 0 and L("Swapped %d animal(s)", n) or L("Pen already has your best animals"), T.pink)
    end)
end)
end

do local sellCard, sellHead = card(tab.pets.L, 2, "Auto Sell", "Sells animals in your bag that make less than this", IMG.sell, T.amber)
switch(sellHead, function() return settings.autoSell end, function() settings.autoSell = not settings.autoSell; save() end)
do
    local r = row(sellCard, "Sell below", "$/s per animal. Type like 500, 25K, 1.5M")
    local box = new("TextBox", {
        Parent = r, BackgroundColor3 = T.bg, BorderSizePixel = 0, ClearTextOnFocus = false, PlaceholderText = "25K",
        PlaceholderColor3 = T.faint, FontFace = FONT_BOLD, TextSize = 12, TextColor3 = T.text, Text = "",
    }, { corner(8), line(LINE2) })
    rightAnchor(box, 96, 28)
    local function show() box.Text = (tonumber(settings.sellBelow) or 0) > 0 and money(settings.sellBelow) .. "/s" or "" end
    box.Focused:Connect(function() tween(box, { BackgroundColor3 = T.raised }, MOTION.hover) end)
    box.FocusLost:Connect(function()
        tween(box, { BackgroundColor3 = T.bg }, MOTION.hover)
        local v = parseAmount(box.Text)
        if v then settings.sellBelow = v; save() end
        show()
    end)
    show()
end
do
    local r
    r, ui.sellStatus = row(sellCard, "Sell now", "Never sells animals in the pen or in your hand")
    local b = smallButton(r, "Sell", 84, T.amber)
    rightAnchor(b, 84, 28)
    b.MouseButton1Click:Connect(function()
        task.spawn(function()
            local n, why = sellWeak(true)
            toast(n and (n > 0 and L("Sold %d animal(s)", n) or L("Nothing to sell")) or tostring(why), T.amber, IMG.sell)
        end)
    end)
end

end
do local indexCard, indexHead = card(tab.pets.R, 1, "Index", "Claims Index rewards as soon as they are ready", IMG.index, T.sky)
switch(indexHead, function() return settings.autoIndex end, function() settings.autoIndex = not settings.autoIndex; save() end)
ui.readyText = valueRow(indexCard, "Ready to claim", T.green)
buttonRow(indexCard, "Claim now", nil, "Claim", T.sky, 84).MouseButton1Click:Connect(function()
    task.spawn(function()
        local n = claimIndex()
        toast(n > 0 and L("Claimed the Index rewards") or L("nothing ready"), T.sky)
    end)
end)
end

---------------- home tab UI
do
    local hero = new("Frame", {
        Parent = tab.home.L, LayoutOrder = 0, BackgroundColor3 = WHITE, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 156), ClipsDescendants = true,
    }, {
        corner(16),
        new("UIGradient", { Rotation = 20, Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromHex("5b21b6")),
            ColorSequenceKeypoint.new(0.6, Color3.fromHex("7c3aed")),
            ColorSequenceKeypoint.new(1, Color3.fromHex("db2777")),
        }) }),
    })
    -- soft light circles behind the cat for depth
    new("Frame", { Parent = hero, BackgroundColor3 = WHITE, BackgroundTransparency = 0.88, BorderSizePixel = 0,
        Size = UDim2.fromOffset(190, 190), Position = UDim2.new(1, -150, 0, -50) }, { corner(95) })
    new("Frame", { Parent = hero, BackgroundColor3 = WHITE, BackgroundTransparency = 0.93, BorderSizePixel = 0,
        Size = UDim2.fromOffset(110, 110), Position = UDim2.new(1, -60, 1, -70) }, { corner(55) })
    local cat = new("ImageLabel", {
        Parent = hero, BackgroundTransparency = 1, Image = IMG.cat, ScaleType = Enum.ScaleType.Fit,
        AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -6, 1, 8), Size = UDim2.fromOffset(132, 132),
    })
    task.spawn(function() -- the cat floats
        local up = true
        while alive() and gui.Parent do
            tween(cat, { Position = UDim2.new(1, -6, 1, up and 0 or 8), Rotation = up and -4 or 3 }, TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut))
            up = not up
            task.wait(1.8)
        end
    end)
    tr(label(hero, "", 20, WHITE, FONT_BOLD, { Position = UDim2.fromOffset(18, 16), Size = UDim2.new(1, -170, 0, 24) }, true), "Hi, %s", LocalPlayer.DisplayName)
    ui.homeDoing = label(hero, "", 12, WHITE, FONT_SEMI, { Position = UDim2.fromOffset(18, 42), Size = UDim2.new(1, -170, 0, 16), TextTransparency = 0.15 }, true)
    local moneyBox = new("Frame", {
        Parent = hero, BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.72, BorderSizePixel = 0,
        Position = UDim2.fromOffset(16, 92), Size = UDim2.fromOffset(200, 46),
    }, { corner(12) })
    icon(moneyBox, IMG.cash, 30, "$", T.green, { Position = UDim2.fromOffset(8, 8) })
    label(moneyBox, "Money", 10, WHITE, FONT, { Position = UDim2.fromOffset(46, 5), Size = UDim2.new(1, -52, 0, 12), TextTransparency = 0.3 })
    ui.homeMoney = label(moneyBox, "$0", 19, WHITE, FONT_BOLD, { Position = UDim2.fromOffset(46, 17), Size = UDim2.new(1, -52, 0, 24) }, true)

    -- three tiles: stolen, speed, best animal
    local tiles = new("Frame", { Parent = tab.home.L, LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 92) }, {
        new("UIGridLayout", { CellSize = UDim2.new(1 / 3, -7, 1, 0), CellPadding = UDim2.fromOffset(10, 0), SortOrder = Enum.SortOrder.LayoutOrder }),
    })
    local function tile(order, image, title, tint)
        local t = new("Frame", { Parent = tiles, LayoutOrder = order, BackgroundColor3 = T.card, BorderSizePixel = 0 }, { corner(14), line() })
        new("Frame", { Parent = t, BackgroundColor3 = tint, BorderSizePixel = 0, Size = UDim2.new(1, -24, 0, 2), Position = UDim2.fromOffset(12, 0) }, { corner(1) })
        local _, img = icon(t, image, 30, "•", tint, { Position = UDim2.fromOffset(12, 12) })
        label(t, title, 10, T.muted, FONT, { Position = UDim2.fromOffset(12, 48), Size = UDim2.new(1, -20, 0, 12) })
        local v = label(t, "—", 14, T.text, FONT_BOLD, { Position = UDim2.fromOffset(12, 62), Size = UDim2.new(1, -20, 0, 18) }, true)
        local sc = new("UIScale", { Parent = t })
        t.MouseEnter:Connect(function() tween(sc, { Scale = 1.03 }, MOTION.hover) end)
        t.MouseLeave:Connect(function() tween(sc, { Scale = 1 }, MOTION.hover) end)
        return v, img
    end
    ui.homeStolen = tile(1, IMG.eggs, "Stolen this session", T.green)
    ui.homeSpeed = tile(2, IMG.boost, "Speed", T.sky)
    ui.homeBest, ui.homeBestPic = tile(3, IMG.pets, "Best animal", T.amber)

end
do local quickCard = card(tab.home.R, 1, "Quick actions", "One tap to start or stop", "▶", T.green)
buttonRow(quickCard, "Start farming", "Farms the zone you picked last", "Start", T.green, 84).MouseButton1Click:Connect(function()
    if not settings.zone then toast(L("Pick a zone in Egg Farm first"), T.amber) selectTab(tab.farm.index) return end
    settings.farm = true; save(); refreshFarm(); pcall(renderZones); stopTreadmill()
end)
buttonRow(quickCard, "Go to my treadmill", "Drops whatever it is doing, runs back and stays on it", "Go", T.sky, 84).MouseButton1Click:Connect(function()
    if actions.goTreadmill then actions.goTreadmill() end
end)
buttonRow(quickCard, "Stop everything", "Farm and treadmill off, the character stands still", "Stop", T.red, 84).MouseButton1Click:Connect(function()
    settings.farm = false; save(); refreshFarm(); pcall(renderZones); stopTreadmill(); stopMoving()
end)
end

---------------- toasts for what the shop and the pen did
do
    local function pickName(t) return PICKAXES[t] and PICKAXES[t].name or ("Tier " .. tostring(t)) end
    local function trailName(id) for _, t in ipairs(TRAILS) do if t.id == id then return t.name end end return tostring(id) end
    LocalPlayer:GetAttributeChangedSignal("PickaxeTier"):Connect(function()
        toast(L("Bought %s", pickName(LocalPlayer:GetAttribute("PickaxeTier"))), T.amber)
    end)
    LocalPlayer:GetAttributeChangedSignal("EquippedTrail"):Connect(function()
        toast(L("Bought %s", trailName(LocalPlayer:GetAttribute("EquippedTrail"))), T.amber)
    end)
    task.spawn(function()
        local plot
        for _ = 1, 30 do plot = myPlot() if plot then break end task.wait(1) end
        if not plot then return end
        plot:GetAttributeChangedSignal("PlotLevel"):Connect(function()
            toast(L("Pen upgraded to Lv.%d", tonumber(plot:GetAttribute("PlotLevel")) or 0), T.green)
        end)
        plot:GetAttributeChangedSignal("TreadmillLevel"):Connect(function()
            toast(L("Treadmill upgraded to Lv.%d", tonumber(plot:GetAttribute("TreadmillLevel")) or 0), T.sky)
        end)
    end)
end

---------------- the loop: refresh the numbers, run the automations
task.spawn(function()
    local lastValues, lastEquip, lastSell, lastIndex, lastGet = 0, 0, 0, 0, 0
    while alive() and gui.Parent do
        ui.homeMoney.Text = money(cash())
        ui.homeStolen.Text = placedText.Text
        ui.homeBest.Text = (bestText.Text:gsub("%s+·.*$", ""))
        ui.homeBestPic.Image = farmPic.best.Image
        ui.homeSpeed.Text = (shortCash(tonumber(LocalPlayer:GetAttribute("SpeedPower")) or 0):gsub("^%$", ""):gsub("/s$", ""))
        ui.homeDoing.Text = settings.farm and stepText.Text or (settings.treadmill and L("On treadmill") or L("Idle"))
        local ready = readyCount()
        ui.readyText.Text = ready > 0 and L("%d ready", ready) or L("nothing ready")

        if os.clock() - lastValues > 5 then -- pen numbers (each needs a trip through a game thread)
            lastValues = os.clock()
            pcall(function()
                local plot = myPlot()
                local placed = placedAnimals(plot)
                ui.penText.Text = L("%s/%s animals", #placed, tostring(plot and plot:GetAttribute("MaxAnimals") or "?"))
                local bag = bagAnimals()
                local wi, wv = minOf(cpsOf(placed))
                local bi, bv = maxOf(cpsOf(bag))
                local function show(textLabel, pic, inst, value)
                    local name = inst and inst:GetAttribute("AnimalName")
                    textLabel.Text = inst and string.format("%s  %s", tostring(name), shortCash(value)) or "—"
                    local img = inst and animalImage(name, inst:GetAttribute("Variant")) or ""
                    pic.Image = img ~= "" and img or IMG.pets
                end
                show(ui.weakText, ui.weakPic, wi and placed[wi], wv)
                show(ui.bestBag, ui.bestPic, bi and bag[bi], bv)
            end)
        end
        if settings.autoEquipBest and os.clock() - lastEquip > 20 then
            lastEquip = os.clock()
            local n = smartEquip()
            if n > 0 then toast(L("Swapped %d animal(s)", n), T.pink) end
        end
        if settings.autoSell and os.clock() - lastSell > 20 and not busy then
            lastSell = os.clock()
            local n, why = sellWeak()
            if n and n > 0 then toast(L("Sold %d animal(s)", n), T.amber) end
            if ui.sellStatus then ui.sellStatus.Text = n and (n > 0 and L("Sold %d animal(s)", n) or L("Nothing to sell")) or tostring(why) end
        end
        if settings.autoIndex then
            if os.clock() - lastGet > 30 then lastGet = os.clock(); fire("IndexRemote", "Get", nil) end
            if ready > 0 and os.clock() - lastIndex > 5 then
                lastIndex = os.clock()
                claimIndex()
                toast(L("Claimed the Index rewards"), T.sky)
            end
        end
        task.wait(1)
    end
end)

toast("LAIKAHUB · Break A Steal Egg v" .. VERSION, T.accent)
end -- pets + home
