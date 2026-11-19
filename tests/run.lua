-- Runs the Lua test files given as arguments (tests/run.sh passes every tests/*/*_test.lua).
-- Usage from the repository root: lua5.1 tests/run.lua tests/forevermarket/diff_test.lua ...
-- Exits with 1 when a test fails or no test file was given.

package.path = "tests/lib/?.lua;" .. package.path

local H = require("harness")

if #arg == 0 then
    print("No test files given. Run tests/run.sh from the repository root.")
    os.exit(1)
end

for _, file in ipairs(arg) do
    H.currentFile = file
    dofile(file)
end

os.exit(H.Run() == 0 and 0 or 1)
