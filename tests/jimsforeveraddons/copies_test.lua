local H = require("harness")

-- The shared file JimsForeverAddOns.lua (FRV-120, FRV-180): every first-party AddOn carries an identical copy as
-- the first file of its .toc, lists JimsForeverAddOnsDB in its ## SavedVariables and prints no "loaded" line of
-- its own (the shared file prints the one [JFA] line). Each carrier also ships the same icon of the minimap button
-- (FRV-245), and no AddOn's code points into another AddOn's folder.

local FILE = "JimsForeverAddOns.lua"
local ICON = "Media/JimsForeverAddOns.tga"

local function Read(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local text = handle:read("*a")
    handle:close()
    return text
end

-- The AddOn folders of addons/ that have a .toc named after the folder
local function FirstPartyAddOns()
    local list = {}
    local listing = assert(io.popen("ls addons"))
    for name in listing:lines() do
        local toc = Read("addons/" .. name .. "/" .. name .. ".toc")
        if toc then
            list[#list + 1] = { name = name, toc = toc:gsub("\r\n", "\n") }
        end
    end
    listing:close()
    return list
end

-- The file list of a .toc (lines that are neither empty nor ## fields nor comments)
local function TocFiles(toc)
    local files = {}
    for line in toc:gmatch("[^\n]+") do
        line = line:gsub("%s+$", "")
        if line ~= "" and not line:match("^#") then
            files[#files + 1] = line:gsub("\\", "/")
        end
    end
    return files
end

H.test("every copy of the shared file is the same", function()
    local first, firstName
    local copies = 0
    for _, addon in ipairs(FirstPartyAddOns()) do
        local text = Read("addons/" .. addon.name .. "/" .. FILE)
        if text then
            copies = copies + 1
            if not first then
                first, firstName = text, addon.name
            elseif text ~= first then
                error(addon.name .. "/" .. FILE .. " differs from " .. firstName .. "/" .. FILE
                    .. ": copy the changed file into every AddOn (and raise its VERSION)")
            end
        end
    end
    assert(copies >= 2, "expected the shared file in several AddOns, found " .. copies)
end)

H.test("every first-party AddOn carries it first in its .toc, with JimsForeverAddOnsDB saved", function()
    for _, addon in ipairs(FirstPartyAddOns()) do
        local carries = Read("addons/" .. addon.name .. "/" .. FILE) ~= nil
        local files = TocFiles(addon.toc)
        local saved = addon.toc:match("\n## SavedVariables:([^\n]*)") or ""
        H.eq(carries, true, addon.name .. " has " .. FILE)
        H.eq(files[1], FILE, addon.name .. ".toc's first file")
        H.eq(saved:find("JimsForeverAddOnsDB", 1, true) ~= nil, true, addon.name .. " saves JimsForeverAddOnsDB")
    end
end)

H.test("every AddOn that carries it ships the same icon, a 64 x 64 32-bit uncompressed TGA", function()
    local first, firstName
    local carriers = 0
    for _, addon in ipairs(FirstPartyAddOns()) do
        if Read("addons/" .. addon.name .. "/" .. FILE) then
            carriers = carriers + 1
            local icon = Read("addons/" .. addon.name .. "/" .. ICON)
            if not icon then
                error(addon.name .. " carries " .. FILE .. " but has no " .. ICON
                    .. ": copy it from an AddOn that has it (the copy that runs takes the icon from its own AddOn)")
            elseif not first then
                first, firstName = icon, addon.name
            elseif icon ~= first then
                error(addon.name .. "/" .. ICON .. " differs from " .. firstName .. "/" .. ICON
                    .. ": copy the changed icon into every AddOn (and bump their versions)")
            end
        end
    end
    assert(carriers >= 2, "expected the shared file in several AddOns, found " .. carriers)
    -- the TGA header: image type 2 (uncompressed true color), width and height 64, 32 bits a pixel, 8 of them alpha
    H.eq(first:byte(3), 2, "image type")
    H.eq(first:byte(13) + first:byte(14) * 256, 64, "width")
    H.eq(first:byte(15) + first:byte(16) * 256, 64, "height")
    H.eq(first:byte(17), 32, "bits per pixel")
    H.eq(first:byte(18) % 16, 8, "alpha bits")
end)

H.test("no AddOn's code points into another AddOn's folder", function()
    for _, addon in ipairs(FirstPartyAddOns()) do
        local listing = assert(io.popen("cd addons/" .. addon.name .. " && find . -name '*.lua' -o -name '*.xml'"))
        for file in listing:lines() do
            local text = Read("addons/" .. addon.name .. "/" .. file) or ""
            -- a path written out: Interface\AddOns\<folder> (a path built from addonName names no folder here)
            for folder in text:gmatch("[Ii]nterface[\\/]+[Aa]dd[Oo]ns[\\/]+([%w_%-]+)") do
                if folder ~= addon.name then
                    error(addon.name .. "/" .. file:gsub("^%./", "") .. " points into " .. folder
                        .. "'s folder: every AddOn stays standalone")
                end
            end
        end
        listing:close()
    end
end)

H.test("an AddOn that carries it prints no loaded line of its own", function()
    for _, addon in ipairs(FirstPartyAddOns()) do
        for _, file in ipairs(TocFiles(addon.toc)) do
            local text = Read("addons/" .. addon.name .. "/" .. file) or ""
            if file ~= FILE and text:find("v%s loaded", 1, true) then
                error(addon.name .. "/" .. file .. " still prints its own \"loaded\" line")
            end
        end
    end
end)
