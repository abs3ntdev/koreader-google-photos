-- Test runner: `luajit plugin/spec/run.lua` from the repository root.
-- Loads real plugin modules; KOReader/network boundaries are mocked (see spec/support.lua).
local root = arg[0]:match("^(.*)/spec/run%.lua$") or "plugin"
package.path = table.concat({
    root .. "/googlephotos.koplugin/?.lua",
    root .. "/spec/?.lua",
    root .. "/spec/vendor/?.lua", -- dkjson 2.10 (same release KOReader ships)
    package.path,
}, ";")

local T = require("support")

-- 1. Syntax check every plugin Lua file (loadfile compiles without running).
local files = {}
local p = io.popen('find "' .. root .. '/googlephotos.koplugin" -name "*.lua" | sort')
for f in p:lines() do files[#files + 1] = f end
p:close()
T.test("syntax: all plugin files compile", function()
    T.ok(#files > 0, "no plugin files found")
    for _, f in ipairs(files) do
        local fn, err = loadfile(f)
        T.ok(fn ~= nil, err)
    end
end)

for _, name in ipairs({ "test_json", "test_tls", "test_http", "test_storage", "test_scanner",
    "test_broker_auth", "test_photos", "test_uploader", "test_app", "test_main" }) do
    require(name)
end

os.exit(T.finish() and 0 or 1)
