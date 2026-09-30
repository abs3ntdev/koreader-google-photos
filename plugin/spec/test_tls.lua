local T = require("support")
local tls = require("gphotos/tls")

T.test("tls: SAN hostname matching rules", function()
    local cases = {
        { { "api.example.com" }, "api.example.com", true },
        { { "API.Example.com" }, "api.example.com", true },
        { { "*.example.com" }, "api.example.com", true },
        { { "*.example.com" }, "a.b.example.com", false },   -- single label only
        { { "*.example.com" }, "example.com", false },
        { { "*.com" }, "example.com", false },               -- too broad
        { { "a*.example.com" }, "ab.example.com", false },   -- partial wildcard
        { { "api.*.com" }, "api.example.com", false },
        { { "api.example.com\0.evil.com" }, "api.example.com", false },
        { { "other.example.com" }, "api.example.com", false },
        { {}, "api.example.com", false },
        { { "1.2.3.4" }, "1.2.3.4", false },                 -- IP literal unsupported
    }
    for i, c in ipairs(cases) do
        T.eq(tls.host_matches(c[1], c[2]), c[3], "case " .. i)
    end
end)

T.test("tls: dns_names reads only subjectAltName dNSName (no CN fallback)", function()
    local cert = { extensions = function() return { ["2.5.29.17"] = { dNSName = { "a.example.com" } } } end }
    T.eq(tls.dns_names(cert)[1], "a.example.com")
    local cn_only = { extensions = function() return {} end, subject = function() return { { name = "CN", value = "a.example.com" } } end }
    T.eq(#tls.dns_names(cn_only), 0)
end)

T.test("tls: create fails closed without CA bundle", function()
    local ok, err = pcall(tls.create, "api.example.com", { cafile = "/nonexistent/ca.crt" })
    T.ok(not ok and tostring(err):find("CA bundle"), tostring(err))
end)

-- Fake LuaSec socket to drive the post-handshake checks.
local function fake_env(opts)
    local log = {}
    local sslsock = {}
    sslsock.__index = sslsock
    function sslsock:sni(h) log.sni = h end
    function sslsock:settimeout() end
    function sslsock:dohandshake() return true end
    function sslsock:getpeerverification() return opts.verified end
    function sslsock:getpeercertificate()
        return { extensions = function() return { ["2.5.29.17"] = { dNSName = opts.sans } } end }
    end
    function sslsock:close() log.closed = true end
    function sslsock:send() log.sent = true; return 1 end
    local tcp = { settimeout = function() end, connect = function() return 1 end }
    local socket = { tcp = function() return tcp end, try = function(v, e) if not v then error(e) end return v end }
    local ssl = { wrap = function(_, params) log.params = params; return setmetatable({}, sslsock) end }
    local ca = os.tmpname()
    return { socket = socket, ssl = ssl, cafile = ca }, log
end

T.test("tls: connect verifies chain + hostname before returning", function()
    local deps, log = fake_env({ verified = true, sans = { "api.example.com" } })
    local conn = tls.create("api.example.com", deps)()
    T.eq(conn:connect("api.example.com", 443), 1)
    T.eq(log.sni, "api.example.com")
    T.eq(log.params.verify[1], "peer")
    T.eq(log.params.cafile, deps.cafile)

    deps, log = fake_env({ verified = false, sans = { "api.example.com" } })
    local ok, err = pcall(function() tls.create("api.example.com", deps)():connect("api.example.com", 443) end)
    T.ok(not ok and tostring(err):find("not verified") and log.closed and not log.sent)

    deps, log = fake_env({ verified = true, sans = { "evil.example.org" } })
    ok, err = pcall(function() tls.create("api.example.com", deps)():connect("api.example.com", 443) end)
    T.ok(not ok and tostring(err):find("hostname mismatch") and not log.sent)

    deps = fake_env({ verified = true, sans = { "api.example.com" } })
    ok = pcall(function() tls.create("api.example.com", deps)():connect("other.example.com", 443) end)
    T.ok(not ok, "connect host must equal expected host")
end)
