-- Minimal test harness: test files register cases with H.test, run.lua runs them and counts failures.
-- Paths are relative to the repository root (tests/run.sh changes into it).

local Stubs = require("wow_stubs")

local H = {}
local cases = {}

-- Register a test case; fn raises an error to fail
function H.test(name, fn)
    cases[#cases + 1] = { name = name, fn = fn, file = H.currentFile }
end

local function Show(value)
    if type(value) == "string" then return string.format("%q", value) end
    return tostring(value)
end

-- actual == expected, else fail with both values
function H.eq(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", what or "value", Show(expected), Show(actual)), 2)
    end
end

-- Deep equality of plain tables (keys and values), else fail naming the first difference
local function Compare(actual, expected, path)
    if type(actual) ~= "table" or type(expected) ~= "table" then
        if actual ~= expected then
            return string.format("%s: expected %s, got %s", path, Show(expected), Show(actual))
        end
        return nil
    end
    for key, value in pairs(expected) do
        local diff = Compare(actual[key], value, path .. "." .. tostring(key))
        if diff then return diff end
    end
    for key, value in pairs(actual) do
        if expected[key] == nil then
            return string.format("%s.%s: not expected, got %s", path, tostring(key), Show(value))
        end
    end
    return nil
end

function H.same(actual, expected, what)
    local diff = Compare(actual, expected, what or "value")
    if diff then error(diff, 2) end
end

-- Load AddOn files the way the client does: each file gets (addonName, namespace) as its varargs.
-- Returns the namespace and the fresh global environment the files ran in.
function H.LoadAddon(folder, files)
    local env = Stubs.NewEnvironment()
    local addonName = folder:match("([^/]+)$")
    local ns = {}
    for _, file in ipairs(files) do
        local chunk = assert(loadfile(folder .. "/" .. file))
        setfenv(chunk, env)
        chunk(addonName, ns)
    end
    return ns, env
end

-- Run every registered case; returns the number of failures
function H.Run()
    local failed = 0
    for _, case in ipairs(cases) do
        local ok, err = pcall(case.fn)
        if ok then
            print("ok    " .. case.file .. ": " .. case.name)
        else
            failed = failed + 1
            print("FAIL  " .. case.file .. ": " .. case.name)
            print("      " .. tostring(err))
        end
    end
    print(string.format("%d tests, %d failed", #cases, failed))
    return failed
end

return H
