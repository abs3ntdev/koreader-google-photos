local T = require("support")
local Storage = require("gphotos/storage")

local function with_sys(sys, fn)
    local prev = Storage.sys
    Storage.sys = sys
    local ok, err = pcall(fn)
    Storage.sys = prev
    if not ok then error(err, 0) end
end

T.test("storage: atomic write round-trips and applies 0600 when supported", function()
    local d = T.tmpdir()
    local path = d .. "/device.json"
    local ok, perms = Storage.write_json(path, { a = 1 })
    T.ok(ok); T.eq(Storage.read_json(path).a, 1)
    local p = io.popen('stat -c %a "' .. path .. '"'); local mode = p:read("*l"); p:close()
    T.eq(mode, "600"); T.eq(perms, true)
    T.eq(io.open(path .. ".tmp"), nil, "no temp file left")
end)

T.test("storage: fsync failure aborts before rename (old content kept)", function()
    local d = T.tmpdir()
    local path = d .. "/device.json"
    Storage.write_json(path, { v = "old" })
    with_sys({ fsync = function() return false, "EIO" end }, function()
        local ok, err = Storage.write_json(path, { v = "new" })
        T.eq(ok, nil); T.ok(err:find("EIO"))
    end)
    T.eq(Storage.read_json(path).v, "old")
    T.eq(io.open(path .. ".tmp"), nil)
end)

T.test("storage: directory fsync failure reports non-durable", function()
    local d = T.tmpdir()
    with_sys({ fsync_dir = function() return false, "EIO" end }, function()
        T.eq(Storage.write_json(d .. "/x.json", {}), nil)
    end)
end)

T.test("storage: chmod unsupported (FAT) is reported, not claimed", function()
    local d = T.tmpdir()
    with_sys({ chmod = function() return false end }, function()
        local ok, perms = Storage.write_json(d .. "/x.json", { a = 1 })
        T.ok(ok); T.eq(perms, false)
    end)
end)

T.test("storage: missing vs unreadable vs corrupt are distinguished", function()
    local d = T.tmpdir()
    local _, e1 = Storage.read_json(d .. "/nope.json"); T.eq(e1, "missing")
    local _, e2 = Storage.read_json(d); -- directory: open ok on linux but read fails
    T.ok(e2 ~= "missing", "directory read is not 'missing': " .. tostring(e2))
    local f = io.open(d .. "/bad.json", "wb"); f:write("{not json"); f:close()
    local _, e3 = Storage.read_json(d .. "/bad.json"); T.ok(e3:find("corrupt"))
end)
