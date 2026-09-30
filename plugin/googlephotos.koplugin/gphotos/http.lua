--[[--
HTTPS-only JSON/bytes client built on LuaSocket http.request with the
verified TLS `create` from gphotos/tls.lua.

Policy: https scheme only, exact origin allowlist per client, redirect=false,
3xx treated as error, bounded response size, bearer tokens only ever sent to
the origin the client was built for.
--]]

local json = require("gphotos/json")
local tls = require("gphotos/tls")

local Http = {}
Http.__index = Http

local MAX_RESPONSE = 1024 * 1024

--- Parses an https origin "https://host[:port]" (no path). Returns host, port.
function Http.parse_origin(origin)
    if type(origin) ~= "string" then return nil end
    local host, port = origin:match("^https://([%w%.%-]+):?(%d*)$")
    if not host then return nil end
    host = tls.normalize_host(host)
    if not host then return nil end
    port = tonumber(port ~= "" and port or "443")
    if not port or port < 1 or port > 65535 then return nil end
    return host, port
end

--- deps: { http = socket.http, ltn12 = ltn12, socket = socket, ssl = ssl, cafile = path, timeout = s }
function Http.new(origin, deps)
    local host, port = Http.parse_origin(origin)
    if not host then error("http: origin must be https://host[:port]") end
    return setmetatable({ origin = origin, host = host, port = port, deps = deps }, Http)
end

local function limited_sink(t, limit, ltn12)
    local size = 0
    return function(chunk, err)
        if chunk then
            size = size + #chunk
            if size > limit then return nil, "response too large" end
            t[#t + 1] = chunk
        end
        return 1
    end
end

--- Performs a request. opts: { method, path, headers, body (string) | body_file + body_size }
-- Returns { status, headers, body, json } or nil, { kind = "network"|"tls"|"http", message }.
function Http:request(opts)
    local path = opts.path or "/"
    if path:sub(1, 1) ~= "/" or path:find("[%s%z]") or path:find("^//") then
        return nil, { kind = "usage", message = "invalid path" }
    end
    local d = self.deps
    local headers = { ["host"] = self.port == 443 and self.host or (self.host .. ":" .. self.port) }
    for k, v in pairs(opts.headers or {}) do headers[k:lower()] = v end
    local chunks = {}
    local ok, create = pcall(tls.create, self.host, {
        socket = d.socket, ssl = d.ssl, cafile = d.cafile, timeout = d.timeout,
    })
    if not ok then return nil, { kind = "tls", message = tostring(create) } end
    local source, fh
    if opts.body_file then
        local ferr
        fh, ferr = io.open(opts.body_file, "rb")
        if not fh then return nil, { kind = "file", message = tostring(ferr) } end
        -- Do not let ltn12 own the handle: we close it ourselves on every path.
        source = function()
            local chunk = fh:read(8192)
            if chunk then return chunk end
            return nil
        end
        headers["content-length"] = tostring(opts.body_size)
    elseif opts.body then
        source = d.ltn12.source.string(opts.body)
        headers["content-length"] = tostring(#opts.body)
    elseif opts.method ~= "GET" and opts.method ~= "DELETE" then
        headers["content-length"] = "0"
    end
    local call_ok, res, code, rheaders = pcall(d.http.request, {
        url = "https://" .. self.host .. ":" .. self.port .. path,
        method = opts.method or "GET",
        headers = headers,
        source = source,
        sink = limited_sink(chunks, opts.max_response or MAX_RESPONSE, d.ltn12),
        redirect = false,
        create = create,
    })
    if fh then pcall(fh.close, fh) end
    if not call_ok then
        local msg = tostring(res)
        return nil, { kind = msg:find("tls:", 1, true) and "tls" or "network", message = msg }
    end
    if not res or type(code) ~= "number" then
        local msg = tostring(code)
        return nil, { kind = msg:find("tls:", 1, true) and "tls" or "network", message = msg }
    end
    local body = table.concat(chunks)
    local out = { status = code, headers = rheaders or {}, body = body }
    if code >= 300 and code < 400 then
        return nil, { kind = "http", status = code, message = "redirect refused" }
    end
    local ctype = out.headers["content-type"] or ""
    if body ~= "" and ctype:find("json", 1, true) then
        out.json = json.decode(body)
    end
    return out
end

return Http
