--[[--
Verified TLS client connections for LuaSocket's http.request `create` hook.

LuaSec's ssl.https defaults to verify="none" and, even with verify="peer",
never checks the certificate hostname. This module:
  * requires a CA bundle file (fail closed if missing),
  * wraps with verify={"peer","fail_if_no_peer_cert"}, sets SNI,
  * checks getpeerverification() after the handshake,
  * matches the expected host against subjectAltName dNSName entries only
    (no CN fallback, single leftmost-label wildcard only, rejects NUL/invalid).
Any failure raises before a single request byte is written.
--]]

local tls = {}

local function valid_label(label)
    return #label >= 1 and #label <= 63
        and label:match("^[a-z0-9]") and label:match("[a-z0-9]$")
        and not label:find("[^a-z0-9%-]")
end

local function split_labels(name)
    local labels = {}
    for label in (name .. "."):gmatch("([^.]*)%.") do
        labels[#labels + 1] = label
    end
    return labels
end

--- Normalizes and validates a DNS hostname. Returns lowercase name or nil.
function tls.normalize_host(host)
    if type(host) ~= "string" or host == "" or #host > 253 then return nil end
    if host:find("%z") or host:find("[^%w%.%-]") then return nil end
    host = host:lower()
    if host:match("^[%d%.]+$") then return nil end -- IP literals not supported
    local labels = split_labels(host)
    if #labels < 2 then return nil end
    for _, l in ipairs(labels) do
        if not valid_label(l) then return nil end
    end
    return host
end

--- Matches one SAN dNSName pattern against an already normalized host.
function tls.match_pattern(pattern, host)
    if type(pattern) ~= "string" or pattern:find("%z") then return false end
    if pattern:find("[^%w%.%-%*]") then return false end
    pattern = pattern:lower()
    local plabels = split_labels(pattern)
    local hlabels = split_labels(host)
    if #plabels ~= #hlabels or #plabels < 2 then return false end
    for i, pl in ipairs(plabels) do
        if pl:find("%*") then
            -- only a whole leftmost label "*", and at least 2 labels after it
            if i ~= 1 or pl ~= "*" or #plabels < 3 then return false end
            if pl:find("xn%-%-") then return false end
        else
            if not valid_label(pl) or pl ~= hlabels[i] then return false end
        end
    end
    return true
end

--- Returns true if any dNSName in `sans` matches `host`.
function tls.host_matches(sans, host)
    host = tls.normalize_host(host)
    if not host or type(sans) ~= "table" then return false end
    for _, name in ipairs(sans) do
        if tls.match_pattern(name, host) then return true end
    end
    return false
end

--- Extracts dNSName strings from a LuaSec x509 certificate object.
function tls.dns_names(cert)
    local ok, ext = pcall(function() return cert:extensions() end)
    if not ok or type(ext) ~= "table" then return {} end
    local san = ext["2.5.29.17"]
    if type(san) ~= "table" or type(san.dNSName) ~= "table" then return {} end
    return san.dNSName
end

--- Returns a LuaSocket `create` function doing verified TLS to `expected_host`.
-- deps: { socket = require("socket"), ssl = require("ssl"), cafile = path, timeout = s }
function tls.create(expected_host, deps)
    local host_ok = tls.normalize_host(expected_host)
    if not host_ok then error("tls: invalid expected host") end
    local cafile = deps.cafile
    local f = cafile and io.open(cafile, "rb")
    if not f then error("tls: CA bundle not found, refusing insecure connection") end
    f:close()
    local socket, ssl, timeout = deps.socket, deps.ssl, deps.timeout or 30
    local params = {
        mode = "client",
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
        verify = { "peer", "fail_if_no_peer_cert" },
        cafile = cafile,
    }
    return function()
        local conn = { sock = socket.try(socket.tcp()) }
        function conn:settimeout()
            return self.sock:settimeout(timeout)
        end
        function conn:connect(host, port)
            if tls.normalize_host(host) ~= host_ok then
                error("tls: connection host does not match expected host")
            end
            self.sock:settimeout(timeout)
            socket.try(self.sock:connect(host, port))
            local wrapped, err = ssl.wrap(self.sock, params)
            if not wrapped then error("tls: wrap failed: " .. tostring(err)) end
            self.sock = wrapped
            self.sock:sni(host_ok)
            self.sock:settimeout(timeout)
            local ok, herr = self.sock:dohandshake()
            if not ok then self.sock:close(); error("tls: handshake failed: " .. tostring(herr)) end
            local verified = self.sock:getpeerverification()
            if verified ~= true then
                self.sock:close(); error("tls: certificate chain not verified")
            end
            local cert = self.sock:getpeercertificate()
            if not cert or not tls.host_matches(tls.dns_names(cert), host_ok) then
                self.sock:close(); error("tls: certificate hostname mismatch")
            end
            local mt = getmetatable(self.sock).__index
            for name, method in pairs(mt) do
                if type(method) == "function" and name ~= "settimeout" and name ~= "connect" then
                    self[name] = function(s, ...) return method(s.sock, ...) end
                end
            end
            return 1
        end
        return conn
    end
end

return tls
