local _, FM = ...

-- Item tooltip lines: after a blank line, what the item costs you and the least to sell it for
-- (trade/Cost.lua), in two groups with a gold header and indented rows with right-aligned values.
-- Lines are added synchronously with AddLine (no right column, no wrapping), so they never fight with
-- other tooltip AddOns.
-- The AH price itself is Auctionator's own "Auction" line at the top of the tooltip, which
-- scan/Auctionator.lua keeps fed from every refresh of our data; where Auctionator leaves none we
-- add that line ourselves, with the same label and the price in Blizzard's coin format.

local math_floor = math.floor
local math_ceil = math.ceil
local string_format = string.format
local string_sub = string.sub
local type = type
local ipairs = ipairs

local cacheVersion = -1

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

-- The price with coin icons: Blizzard's own formatter (Blizzard_SharedXML/FormattingUtil.lua), the one its AH
-- dialogs use; our plain text format only if it is ever missing
local function CoinMoney(amount)
    amount = math_floor(amount)
    if GetMoneyString then return GetMoneyString(amount, true) end
    return FM.FormatMoney(amount)
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
    return label, CoinMoney(price)
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

-- One group of units (trade/Cost.lua, FM.CostInfo): its header, now and what you paid. Crafted units are
-- "Material cost"; when your units are partly crafted and partly bought each group says how many of them it holds.
-- "you paid (3 of 5)" when your craft lines give a basis for only some of the crafted units, then the materials
-- that had no price at a craft.
local function GroupLines(lines, group, total, single)
    local title = group.kind == "crafted" and "Material cost" or "Cost"
    if single then
        lines[#lines + 1] = { string_format("%s (%s pcs)", title, total) }
    else
        lines[#lines + 1] = { string_format("%s (%s of %s pcs)", title, FM.FormatCount(group.n), total) }
    end
    -- each row says what it is based on (FRV-134): today's prices of the AH (crafted: of the materials), what you paid
    lines[#lines + 1] = Row("today's prices", group.now, NowColor(group.now, group.paid))
    local label = "you paid"
    if (group.kind == "crafted" or group.pool) and group.paid and group.paidN < group.n then
        label = string_format("you paid (%s of %s)", FM.FormatCount(group.paidN), FM.FormatCount(group.n))
    end
    lines[#lines + 1] = Row(label, group.paid, WHITE)
    -- Shift: where your pool's units came from (FRV-88): "80 bought this week at 2s 21c, 67 older at 3s 60c"
    if group.parts and FM.PoolText and IsShiftKeyDown and IsShiftKeyDown() then
        local text = FM.PoolText(group)
        if text then lines[#lines + 1] = { INDENT .. INDENT .. text, note = true, wrap = true } end
    end
    if group.missing and group.missing[1] then
        local names = {}
        for i, key in ipairs(group.missing) do names[i] = FM.GetName(key) end
        lines[#lines + 1] = { INDENT .. "no price at the craft: " .. table.concat(names, ", "), note = true }
    end
end

-- { label, value, color } lines of the cost section (a group header has no value, a note line only text), or false
local function CostLines(key)
    -- with Shift held the section has one more line (where the units came from): kept apart
    local id = key .. ((IsShiftKeyDown and IsShiftKeyDown()) and "+" or "")
    local entry = costCache[id]
    if entry and GetTime() - entry.at <= COST_AGE then return entry.lines end
    local lines = false
    local info = FM.CostInfo and FM.CostInfo(key)
    if info then
        local n = FM.FormatCount(info.n)
        -- what your units cost: a vendor's fixed price, or per group (crafted, bought) now and what you paid
        if info.vendor then
            lines = { { string_format("Cost (%s pcs)", n) }, Row("vendor", info.now, WHITE) }
        else
            lines = {}
            for _, group in ipairs(info.groups) do GroupLines(lines, group, n, #info.groups == 1) end
        end
        -- the lowest unit price that nets what your units cost you after the cut and one lost deposit, per listing
        -- duration (FRV-134): what you paid where the logs tell, today's AH price of the item for the rest
        local basis = info.basisN or 0
        local from
        if basis >= info.n then
            from = "from what you paid"
        elseif basis <= 0 then
            from = "from today's AH price"
        else
            from = string_format("%s at what you paid, %s at today's AH price", FM.FormatCount(basis), FM.FormatCount(info.n - basis))
        end
        lines[#lines + 1] = { string_format("Sell at least (%s pcs, %s)", n, from) }
        lines[#lines + 1] = Row("8h listing", info.min8, WHITE, true)
        lines[#lines + 1] = Row("24h listing", info.min24, WHITE, true)
    end
    costCache[id] = { lines = lines, at = GetTime() }
    return lines
end

-- New data (a scan, a setting) empties the cost cache
local function CheckCache()
    if cacheVersion ~= FM.dataVersion then
        costCache = {}
        cacheVersion = FM.dataVersion
    end
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
    if not settings.tooltip then return end
    local key, link = KeyOfTooltip(tooltip, data)
    if not key then return end
    tooltip.__fmDone = true
    local label, money = AuctionLine(tooltip, key, link)
    if label then
        tooltip:AddDoubleLine(label, WHITE_FONT_COLOR and WHITE_FONT_COLOR:WrapTextInColorCode(money)
            or ("|cFFFFFFFF" .. money .. "|r"))
    end
    CheckCache()
    local cost = CostLines(key)
    if cost then
        tooltip:AddLine(" ")
        for _, line in ipairs(cost) do
            local c = line[3]
            if line.note then
                tooltip:AddLine(line[1], NONE[1], NONE[2], NONE[3], line.wrap)
            elseif line[2] then
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
