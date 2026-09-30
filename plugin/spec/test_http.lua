local T = require("support")
local Http = require("gphotos/http")

local function deps(respond)
    local d = { calls = {} }
    d.http = { request = function(req)
        d.calls[#d.calls + 1] = req
        if req.source then
            local parts = {}
            while true do local c = req.source(); if not c then break end; parts[#parts + 1] = c end
            req.sent_body = table.concat(parts)
        end
        return respond(req)
    end }
    d.ltn12 = { source = { string = function(s) local done; return function() if done then return nil end; done = true; return s end end } }
    d.socket, d.ssl = {}, {}
    d.cafile = os.tmpname()
    return d
end

T.test("http: only https origins accepted", function()
    T.ok(Http.parse_origin("https://broker.example.com"))
    T.ok(Http.parse_origin("https://broker.example.com:8443"))
    for _, bad in ipairs({ "http://broker.example.com", "https://broker.example.com/path",
        "https://user@broker.example.com", "https://1.2.3.4", "ftp://x.example.com" }) do
        T.eq(Http.parse_origin(bad), nil, bad)
    end
end)

T.test("http: request disables redirects, pins create, refuses 3xx", function()
    local d = deps(function(req)
        req.sink('{"ok":true}')
        return 1, 302, { location = "https://evil.example.org/", ["content-type"] = "application/json" }
    end)
    local c = Http.new("https://broker.example.com", d)
    local res, err = c:request{ method = "POST", path = "/api/token", headers = { Authorization = "Bearer x" }, body = "{}" }
    T.eq(res, nil); T.eq(err.message, "redirect refused")
    local req = d.calls[1]
    T.eq(req.redirect, false)
    T.ok(type(req.create) == "function")
    T.eq(req.url, "https://broker.example.com:443/api/token")
    T.eq(req.headers.authorization, "Bearer x")
end)

T.test("http: body_file is streamed and closed; response size bounded", function()
    local f = os.tmpname()
    local fh = io.open(f, "wb"); fh:write("IMAGEBYTES"); fh:close()
    local d = deps(function(req)
        local ok = req.sink(string.rep("a", 100))
        if not ok then return nil, "response too large" end
        return 1, 200, {}
    end)
    local c = Http.new("https://photoslibrary.googleapis.com", d)
    local res, err = c:request{ method = "POST", path = "/v1/uploads", body_file = f, body_size = 10, max_response = 10 }
    T.eq(res, nil); T.eq(err.kind, "network")
    T.eq(d.calls[1].sent_body, "IMAGEBYTES")
    T.eq(d.calls[1].headers["content-length"], "10")
    res = c:request{ method = "POST", path = "/v1/uploads", body_file = f, body_size = 10 }
    T.eq(res.status, 200)
end)

T.test("http: TLS failure classified as tls (pre-send)", function()
    local d = deps(function() error("tls: certificate hostname mismatch") end)
    local _, err = Http.new("https://broker.example.com", d):request{ method = "POST", path = "/x", body = "{}" }
    T.eq(err.kind, "tls")
end)
