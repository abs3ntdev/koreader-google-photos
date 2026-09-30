local T = require("support")
local App = require("gphotos/app")
local Auth = require("gphotos/auth")

local ORIGIN = "https://broker.example.com"

local function app(unpair_result)
    local d = T.tmpdir()
    local settings = { data = {} }
    function settings:readSetting(k) return self.data[k] end
    function settings:saveSetting(k, v) self.data[k] = v end
    local lfs = {
        attributes = function(p, key)
            local f = io.open(p, "rb")
            if f then f:close(); return key and "file" or { mode = "file" } end
            return key and (p == d and "directory" or nil) or nil
        end,
        mkdir = function() return true end,
    }
    local a = App.new{ data_dir = d, settings = settings, lfs = lfs, now = function() return 1 end,
        net_deps = function() return {} end }
    a._broker = function() return { unpair = function() return unpair_result[1], unpair_result[2] end } end
    return a
end

T.test("app: broker URL must be https origin", function()
    local a = app({ true })
    T.eq(a:setBrokerOrigin("http://broker.example.com"), nil)
    T.ok(a:setBrokerOrigin(" https://broker.example.com/ "))
    T.eq(a:brokerOrigin(), ORIGIN)
end)

T.test("app: credential from another broker is never used or sent", function()
    local a = app({ true })
    a:setBrokerOrigin(ORIGIN)
    Auth.save_creds(a.creds_path, "https://old.example.com", { device_id = "d", device_credential = "c_0123456789abcdef" }, 1)
    T.eq(a:isPaired(), false)
    local ok, err = a:unlink()
    T.eq(ok, nil); T.ok(err:find("old.example.com"))
    T.ok(io.open(a.creds_path), "kept")
end)

T.test("app: unlink keeps credential on server failure, deletes on success", function()
    local a = app({ nil, { kind = "network", message = "timeout" } })
    a:setBrokerOrigin(ORIGIN)
    Auth.save_creds(a.creds_path, ORIGIN, { device_id = "d", device_credential = "c_0123456789abcdef" }, 1)
    T.eq(a:unlink(), nil); T.ok(io.open(a.creds_path))
    a._broker = function() return { unpair = function() return true end } end
    T.ok(a:unlink()); T.eq(io.open(a.creds_path), nil)
end)

T.test("app: corrupt credential file is preserved on unlink", function()
    local a = app({ true })
    a:setBrokerOrigin(ORIGIN)
    local f = io.open(a.creds_path, "wb"); f:write("garbage"); f:close()
    local ok, err = a:unlink()
    T.eq(ok, nil); T.ok(err:find("unreadable"))
    T.ok(io.open(a.creds_path))
end)

T.test("app: status tells the user the credential is stored unencrypted", function()
    local a = app({ true })
    a:setBrokerOrigin(ORIGIN)
    Auth.save_creds(a.creds_path, ORIGIN, { device_id = "d", device_credential = "c_0123456789abcdef" }, 1)
    T.ok(a:statusText():find("unencrypted"))
end)
