-- Minimal test harness + mocked boundaries (clearly fakes, not real transport).
local json = require("gphotos/json")

local T = { passed = 0, failed = 0 }

function T.test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        T.passed = T.passed + 1
        io.write("ok   ", name, "\n")
    else
        T.failed = T.failed + 1
        io.write("FAIL ", name, "\n  ", tostring(err), "\n")
    end
end

function T.ok(v, msg) if not v then error(msg or "expected truthy", 2) end end
function T.eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end
end

function T.finish()
    io.write(string.format("\n%d passed, %d failed\n", T.passed, T.failed))
    return T.failed == 0
end

function T.tmpdir()
    local d = os.tmpname()
    os.remove(d)
    assert(os.execute('mkdir -p "' .. d .. '"'))
    return d
end

--- Scripted fake of Http:request (the network boundary). `routes` is a list of
-- handlers: function(req) -> res | nil, err. Requests are recorded.
function T.fake_http(origin, handlers)
    local h = { origin = origin, calls = {}, handlers = handlers or {} }
    function h:request(req)
        self.calls[#self.calls + 1] = req
        local fn = self.handlers[req.method .. " " .. req.path]
        if not fn then error("unexpected request " .. req.method .. " " .. req.path) end
        return fn(req, #self.calls)
    end
    function h:count(key)
        local n = 0
        for _, c in ipairs(self.calls) do if c.method .. " " .. c.path == key then n = n + 1 end end
        return n
    end
    return h
end

function T.json_res(status, tbl)
    local body = tbl and json.encode(tbl) or ""
    return { status = status, headers = { ["content-type"] = "application/json" }, body = body,
        json = tbl and json.decode(body) or nil }
end

--- In-memory lfs stand-in (only symlinkattributes/attributes/dir/mkdir used).
function T.fake_lfs(tree)
    local lfs = {}
    function lfs.symlinkattributes(path) return tree[path] end
    function lfs.attributes(path, key)
        local a = tree[path]
        if a and a.mode == "link" then a = tree[a.target] end
        if key then return a and a[key] end
        return a
    end
    function lfs.dir(path)
        local names = {}
        for p in pairs(tree) do
            local parent, name = p:match("^(.*)/([^/]+)$")
            if parent == path then names[#names + 1] = name end
        end
        table.sort(names)
        names[#names + 1] = "."
        local i = 0
        return function() i = i + 1; return names[i] end
    end
    function lfs.mkdir(path) tree[path] = { mode = "directory" }; return true end
    return lfs
end

return T
