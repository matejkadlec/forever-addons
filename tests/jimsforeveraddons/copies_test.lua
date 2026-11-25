local H = require("harness")

-- The shared file JimsForeverAddOns.lua (FRV-120, FRV-180): every first-party AddOn carries an identical copy as
-- the first file of its .toc, lists JimsForeverAddOnsDB in its ## SavedVariables and prints no "loaded" line of
-- its own (the shared file prints the one [JFA] line). ForeverMarket and ForeverCampFeatures get the file with
-- their tickets; until then they are the only AddOns without it.

local FILE = "JimsForeverAddOns.lua"
local PENDING = { ForeverMarket = "FRV-176", ForeverCampFeatures = "FRV-177" }

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
        if PENDING[addon.name] then
            -- not yet: its ticket adds the file, this list then loses the AddOn
            H.eq(carries, false, addon.name .. " carries the file: remove it from PENDING (" .. PENDING[addon.name] .. ")")
        else
            H.eq(carries, true, addon.name .. " has " .. FILE)
            H.eq(files[1], FILE, addon.name .. ".toc's first file")
            H.eq(saved:find("JimsForeverAddOnsDB", 1, true) ~= nil, true, addon.name .. " saves JimsForeverAddOnsDB")
        end
    end
end)

H.test("an AddOn that carries it prints no loaded line of its own", function()
    for _, addon in ipairs(FirstPartyAddOns()) do
        if not PENDING[addon.name] then
            for _, file in ipairs(TocFiles(addon.toc)) do
                local text = Read("addons/" .. addon.name .. "/" .. file) or ""
                if file ~= FILE and text:find("v%s loaded", 1, true) then
                    error(addon.name .. "/" .. file .. " still prints its own \"loaded\" line")
                end
            end
        end
    end
end)
