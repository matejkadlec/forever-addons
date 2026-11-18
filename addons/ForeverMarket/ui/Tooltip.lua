local _, FM = ...

-- Item tooltip lines: Claude's advice, and below it, after a blank line, what the item costs you and
-- the least to sell it for (trade/Cost.lua), in two groups with a gold header and indented rows with
-- right-aligned values. Lines are added synchronously with AddLine (no right column, no wrapping),
-- so they never fight with other tooltip AddOns.
-- The AH price itself is Auctionator's own "Auction" line at the top of the tooltip, which
-- scan/Auctionator.lua keeps fed from every refresh of our data; where Auctionator leaves none we
-- add that line ourselves, in its own format.

local math_floor = math.floor
local math_ceil = math.ceil
local string_format = string.format
local string_sub = string.sub
local type = type
local ipairs = ipairs

local cache = {}
local cacheVersion = -1

local SEP = " |cFF9D9D9D·|r "

-- Cost now against what you paid: white within 5%, orange 5%+ cheaper, red 15%+ cheaper, green 5%+ dearer
local CHEAPER, MUCH_CHEAPER, DEARER = 0.05, 0.15, 0.05
local WHITE = { 1, 1, 1 }
local ORANGE = { 1, 0.5, 0 }
local RED = { 1, 0.2, 0.2 }
local GREEN = { 0.2, 1, 0.2 }
local LABEL = { 1, 0.82, 0 }
local ROW = { 0.8, 0.8, 0.8 }
local NONE = { 0.5, 0.5, 0.5 } -- the grey "-" of a value with nothing to show
local INDENT = "  " -- rows under a group header, like a set's items in Blizzard's item tooltip
local COST_AGE = 10 -- seconds a cost section stays cached (your bags change)
local costCache = {}

local AUCTION_LABEL = "Auction" -- Auctionator's enUS label; its own locale wins while it is loaded
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:0:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:0:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:0:0|t"

-- A copy of Auctionator's CreatePaddedMoneyString (Source/Utilities/CreatePaddedMoneyString.lua), so our
-- line looks the same whether Auctionator is installed or not. Copied, not called: without Auctionator
-- there is nothing to call.
local function PaddedMoney(amount)
    amount = math_floor(amount)
    local copper = amount % 100
    local silver = (amount % 10000 - copper) / 100
    local gold = (amount - silver * 100 - copper) / 10000
    local result = copper .. " " .. COPPER_ICON
    if (gold ~= 0 or silver ~= 0) and copper < 10 then result = "0" .. result end
    if silver ~= 0 or gold ~= 0 then result = silver .. " " .. SILVER_ICON .. " " .. result end
    if gold ~= 0 and silver < 10 then result = "0" .. result end
    if gold ~= 0 then result = gold .. " " .. GOLD_ICON .. " " .. result end
    return result
end

-- Is that label already the left text of a line on this tooltip?
local function HasLine(tooltip, label)
    local name = tooltip.GetName and tooltip:GetName()
    local lines = name and tooltip.NumLines and tooltip:NumLines() or 0
    for i = 2, lines do -- line 1 is the item's name
        local fontString = _G[name .. "TextLeft" .. i]
        local text = fontString and fontString.GetText and fontString:GetText()
        if type(text) == "string" and not FM.IsSecret(text) and string_sub(text, 1, #label) == label then
            return true
        end
    end
    return false
end

-- Our own "Auction" line, only where Auctionator leaves none: it is not installed, its auction tooltips
-- are off, or it skips the item (it bails on bound items, and on anything whose item info is not cached
-- yet, because its `cannotAuction` starts at 0, which is true in Lua).
-- Auctionator registers its tooltip post call before ours (## OptionalDeps loads it first), so its line
-- is already there when we look. For gear its key lookup is asynchronous (Item:ContinueOnItemLoad) and
-- only finishes late while the item's info is uncached, so we stay out of that case rather than risk a
-- second line; the next hover has the item cached and is right.
local function AuctionLine(tooltip, key, link)
    -- an item that can never go to the AH gets no AH price: it would only be noise. Auctionator hides
    -- its line on bound items for the same reason, so this also keeps us from filling that one in.
    if FM.NeverSellable and FM.NeverSellable(key) then return nil end
    local auctionator = _G.Auctionator
    local label = AUCTION_LABEL
    if type(auctionator) == "table" and type(auctionator.Database) == "table" then
        local apply = type(auctionator.Locales) == "table" and auctionator.Locales.Apply
        if type(apply) == "function" then
            local ok, translated = pcall(apply, "AUCTION")
            if ok and type(translated) == "string" and translated ~= "" then label = translated end
        end
        if HasLine(tooltip, label) then return nil end
        local probe = link or tonumber(key)
        if probe and C_Item and C_Item.GetItemInfo and not C_Item.GetItemInfo(probe) then return nil end
    end
    local price = FM.FreshUnitPrice and FM.FreshUnitPrice(key)
    if not price or price <= 0 then return nil end
    return label, PaddedMoney(price)
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
    v = up and math_ceil(v - 0.001) or math_floor(v + 0.5)
    return FM.FormatMoney(math.max(1, v))
end

-- An indented row: the value in its color, or a grey "-" when there is nothing to show
-- (never bought, no AH price, no deposit estimate)
local function Row(label, v, color, up)
    if not v then return { INDENT .. label, "-", NONE } end
    return { INDENT .. label, Money(v, up), color }
end

-- { label, value, color } lines of the cost section (a group header has no value), or false
local function CostLines(key)
    local entry = costCache[key]
    if entry and GetTime() - entry.at <= COST_AGE then return entry.lines end
    local lines = false
    local info = FM.CostInfo and FM.CostInfo(key)
    if info then
        local n = FM.FormatCount(info.n)
        -- what your units cost: a learned craft's materials, a vendor's fixed price, or the AH now and what you paid
        lines = { { string_format(info.crafted and "Craft cost (%s pcs)" or "Cost (%s pcs)", n) } }
        if info.vendor then
            lines[2] = Row("vendor", info.now, WHITE)
        else
            lines[2] = Row("now", info.now, NowColor(info.now, info.paid))
            lines[3] = Row("you paid", info.paid, WHITE)
        end
        -- the lowest unit price that doesn't sell under the AH value, per listing duration
        lines[#lines + 1] = { string_format("Sell at least (%s pcs)", n) }
        lines[#lines + 1] = Row("8h listing", info.min8, WHITE, true)
        lines[#lines + 1] = Row("24h listing", info.min24, WHITE, true)
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
    if entry == nil then -- false = this item has no advice
        entry = AdviceLine(key) or false
        cache[key] = entry
    end
    return entry
end

-- The item's key and, when the tooltip knows it, its link (the link also tells whether the client has
-- the item's info cached yet)
local function KeyOfTooltip(tooltip, data)
    if tooltip.GetItem then
        local ok, _, link = pcall(tooltip.GetItem, tooltip)
        if ok and type(link) == "string" and not FM.IsSecret(link) then
            return FM.KeyFromLink(link), link
        end
    end
    if type(data) == "table" and type(data.id) == "number" then
        return tostring(data.id), nil
    end
    return nil
end

local function OnItemTooltip(tooltip, data)
    if tooltip.__fmDone or not FM.realm then return end
    local settings = FM.GetSettings()
    if not settings.tooltip and not settings.adviceLine then return end
    local key, link = KeyOfTooltip(tooltip, data)
    if not key then return end
    tooltip.__fmDone = true
    if settings.tooltip then
        local label, money = AuctionLine(tooltip, key, link)
        if label then
            tooltip:AddDoubleLine(label, WHITE_FONT_COLOR and WHITE_FONT_COLOR:WrapTextInColorCode(money)
                or ("|cFFFFFFFF" .. money .. "|r"))
        end
    end
    local advice = LinesFor(key)
    if settings.adviceLine and advice then tooltip:AddLine(advice, 1, 1, 1) end
    local cost = settings.tooltip and CostLines(key)
    if cost then
        tooltip:AddLine(" ")
        for _, line in ipairs(cost) do
            local c = line[3]
            if line[2] then
                tooltip:AddDoubleLine(line[1], line[2], ROW[1], ROW[2], ROW[3], c[1], c[2], c[3])
            else
                tooltip:AddLine(line[1], LABEL[1], LABEL[2], LABEL[3])
            end
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
