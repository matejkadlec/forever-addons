local _, FM = ...

-- Item tooltip lines: the latest market state and Claude's advice. Lines are added synchronously
-- with AddLine (no right column, no wrapping), so they never fight with other tooltip AddOns.
-- Below them, after a blank line, what the item costs you (trade/Cost.lua) with right-aligned values.

local Dec = FM.Dec
local math_floor = math.floor
local math_ceil = math.ceil
local string_format = string.format
local string_sub = string.sub
local type = type
local ipairs = ipairs

local cache = {}
local cacheVersion = -1

local SEP = " |cFF9D9D9D·|r "

-- Materials price now against what you paid: white within 5%, orange 5%+ cheaper, red 15%+ cheaper, green 5%+ dearer
local CHEAPER, MUCH_CHEAPER, DEARER = 0.05, 0.15, 0.05
local WHITE = { 1, 1, 1 }
local ORANGE = { 1, 0.5, 0 }
local RED = { 1, 0.2, 0.2 }
local GREEN = { 0.2, 1, 0.2 }
local LABEL = { 1, 0.82, 0 }
local COST_AGE = 10 -- seconds a cost section stays cached (your bags change)
local costCache = {}

local function MarketLine(key)
    local f = FM.LatestRecord(key)
    if not f then return nil end
    local kind = string_sub(f[1], 1, 1)
    local at = FM.Unstamp(string_sub(f[1], 2))
    local minPrice = Dec(f[2])
    local qty = Dec(f[3]) or 0
    local parts = {}
    if minPrice then
        -- random suffix items: the price is the cheapest of all variants ("of Spirit" next to "of the Eagle")
        parts[#parts + 1] = FM.FormatMoney(minPrice) .. (FM.HasVariants(key) and " (any suffix)" or "")
        parts[#parts + 1] = FM.FormatCount(qty) .. " listed"
    else
        parts[#parts + 1] = "none listed"
    end
    local perDay = FM.SoldPerDay(key)
    if perDay then
        parts[#parts + 1] = (perDay > 0 and perDay < 1 and "<1" or ("~" .. FM.FormatCount(perDay))) .. " circulating/day"
    end
    if kind == "r" then
        local own = Dec(f[8])
        if own and own > 0 then parts[#parts + 1] = "yours " .. FM.FormatCount(own) end
    end
    if at then
        parts[#parts + 1] = "|cFF9D9D9D" .. FM.FormatAge(FM.Now() - at) .. " ago|r"
    end
    return FM.COLOR.ORANGE .. "Market|r " .. table.concat(parts, SEP)
end

local function AdviceLine(key)
    local advice = FM.Advice
    local entry = advice and type(advice.items) == "table" and advice.items[key]
    if type(entry) ~= "table" then return nil end
    local parts = {}
    if type(entry.list) == "number" then
        local text = "list at " .. FM.FormatMoney(entry.list)
        if type(entry.conf) == "string" and entry.conf ~= "" then text = text .. " (" .. entry.conf .. ")" end
        parts[#parts + 1] = text
    end
    if type(entry.buyBelow) == "number" then
        parts[#parts + 1] = "buy below " .. FM.FormatMoney(entry.buyBelow)
    end
    if type(entry.note) == "string" and entry.note ~= "" then
        parts[#parts + 1] = entry.note
    end
    if #parts == 0 then return nil end
    local line = FM.COLOR.BLUE .. "Claude|r " .. table.concat(parts, SEP)
    local generated = type(advice.generated) == "number" and advice.generated or nil
    if generated and FM.Now() - generated > 12 * 3600 then
        line = line .. " |cFF9D9D9D(" .. FM.FormatAge(FM.Now() - generated) .. " old)|r"
    end
    return line
end

local function NowColor(now, paid)
    if not (now and paid and paid > 0) then return WHITE end
    local diff = (now - paid) / paid
    if diff < -MUCH_CHEAPER then return RED end
    if diff < -CHEAPER then return ORANGE end
    if diff > DEARER then return GREEN end
    return WHITE
end

local function Money(v, up)
    if not v then return "No data" end
    v = up and math_ceil(v - 0.001) or math_floor(v + 0.5)
    return FM.FormatMoney(math.max(1, v))
end

-- { label, value, color } lines of the cost section, or false
local function CostLines(key)
    local entry = costCache[key]
    if entry and GetTime() - entry.at <= COST_AGE then return entry.lines end
    local lines = false
    local info = FM.CostInfo and FM.CostInfo(key)
    if info then
        local n = FM.FormatCount(info.n)
        -- "Materials" only for a craft of 2+ different materials; anything else is its own material
        local noun = info.plural and "Materials" or "Material"
        lines = {}
        if info.vendor then
            -- a vendor item: one fixed price, nothing to compare
            lines[1] = { noun .. " price (vendor)", Money(info.now), WHITE }
        else
            lines[1] = { noun .. " price", Money(info.now), NowColor(info.now, info.paid) }
            lines[2] = { noun .. " price when bought", Money(info.paid), WHITE }
        end
        lines[#lines + 1] = { string_format("8h min. price (%s pcs)", n), Money(info.min8, true), WHITE }
        lines[#lines + 1] = { string_format("24h min. price (%s pcs)", n), Money(info.min24, true), WHITE }
    end
    costCache[key] = { lines = lines, at = GetTime() }
    return lines
end

local function LinesFor(key)
    if cacheVersion ~= FM.dataVersion then
        cache = {}
        costCache = {}
        cacheVersion = FM.dataVersion
    end
    local entry = cache[key]
    if not entry then
        entry = { market = MarketLine(key) or false, advice = AdviceLine(key) or false, at = GetTime() }
        cache[key] = entry
    elseif GetTime() - entry.at > 60 then
        entry.market = MarketLine(key) or false -- keep "x ago" fresh
        entry.at = GetTime()
    end
    return entry.market, entry.advice
end

local function KeyOfTooltip(tooltip, data)
    if tooltip.GetItem then
        local ok, _, link = pcall(tooltip.GetItem, tooltip)
        if ok and type(link) == "string" and not FM.IsSecret(link) then
            return FM.KeyFromLink(link)
        end
    end
    if type(data) == "table" and type(data.id) == "number" then
        return tostring(data.id)
    end
    return nil
end

local function OnItemTooltip(tooltip, data)
    if tooltip.__fmDone or not FM.realm then return end
    local settings = FM.GetSettings()
    if not settings.tooltip and not settings.adviceLine then return end
    local key = KeyOfTooltip(tooltip, data)
    if not key then return end
    tooltip.__fmDone = true
    local market, advice = LinesFor(key)
    if settings.tooltip and market then tooltip:AddLine(market, 1, 1, 1) end
    if settings.adviceLine and advice then tooltip:AddLine(advice, 1, 1, 1) end
    local cost = settings.tooltip and CostLines(key)
    if cost then
        tooltip:AddLine(" ")
        for _, line in ipairs(cost) do
            local c = line[3]
            tooltip:AddDoubleLine(line[1], line[2], LABEL[1], LABEL[2], LABEL[3], c[1], c[2], c[3])
        end
    end
end

local function Clear(tooltip)
    tooltip.__fmDone = nil
end

function FM.HookTooltips()
    if FM.tooltipsHooked then return end
    FM.tooltipsHooked = true
    local targets = { GameTooltip, ItemRefTooltip }
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            if tooltip == GameTooltip or tooltip == ItemRefTooltip then
                local ok, err = pcall(OnItemTooltip, tooltip, data)
                if not ok and geterrorhandler then geterrorhandler()(err) end
            end
        end)
    else
        for _, tooltip in ipairs(targets) do
            if tooltip and tooltip.HookScript then
                pcall(tooltip.HookScript, tooltip, "OnTooltipSetItem", function(self) pcall(OnItemTooltip, self) end)
            end
        end
    end
    for _, tooltip in ipairs(targets) do
        if tooltip and tooltip.HookScript then
            pcall(tooltip.HookScript, tooltip, "OnTooltipCleared", Clear)
            pcall(tooltip.HookScript, tooltip, "OnHide", Clear)
        end
    end
end

FM.On("PLAYER_LOGIN", function()
    FM.HookTooltips()
end)
