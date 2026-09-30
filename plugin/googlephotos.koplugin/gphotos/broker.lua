--[[--
Broker API client (pairing + short-lived access tokens).
Contract: see README / service. All requests JSON, HTTPS only, no redirects.
The poll_secret and device credential are only ever sent to the broker origin.
--]]

local json = require("gphotos/json")

local Broker = {}
Broker.__index = Broker

--- http: an Http client bound to the broker origin.
function Broker.new(http)
    return setmetatable({ http = http }, Broker)
end

local function err_code(res)
    local j = res and res.json
    if type(j) == "table" and type(j.error) == "string" then return j.error end
    return "http_" .. tostring(res and res.status)
end

local function valid_id(s)
    return type(s) == "string" and #s > 0 and #s <= 200 and s:match("^[%w_%-]+$") ~= nil
end

function Broker:_post(path, bearer, body)
    local headers = { ["content-type"] = "application/json", accept = "application/json" }
    if bearer then headers.authorization = "Bearer " .. bearer end
    local res, err = self.http:request{ method = "POST", path = path, headers = headers,
        body = json.encode(body or {}) }
    if not res then return nil, { code = "network", retryable = true, detail = err } end
    return res
end

--- Starts a pairing. Returns {pairing_id, pair_url, poll_secret, expires_in, poll_interval} or nil, err.
function Broker:start_pairing()
    local res, err = self:_post("/api/pairings")
    if not res then return nil, err end
    if res.status ~= 201 or type(res.json) ~= "table" then
        return nil, { code = err_code(res), retryable = res.status >= 500 }
    end
    local j = res.json
    if not valid_id(j.pairing_id) or type(j.poll_secret) ~= "string" or type(j.pair_url) ~= "string"
        or not j.pair_url:match("^https://") then
        return nil, { code = "bad_response" }
    end
    return {
        pairing_id = j.pairing_id, pair_url = j.pair_url, poll_secret = j.poll_secret,
        expires_in = tonumber(j.expires_in) or 600,
        poll_interval = math.max(tonumber(j.poll_interval) or 3, 1),
    }
end

--- Polls. Returns {status, confirmation_code?, device?} or nil, err{code, retryable}.
function Broker:poll(p)
    local res, err = self:_post("/api/pairings/" .. p.pairing_id .. "/poll", p.poll_secret)
    if not res then return nil, err end
    if res.status ~= 200 or type(res.json) ~= "table" then
        return nil, { code = err_code(res), retryable = res.status >= 500 or res.status == 429 }
    end
    local j = res.json
    local out = { status = j.status }
    if j.status == "authorized" or j.status == "phone_confirmed" then
        if type(j.confirmation_code) ~= "string" or not j.confirmation_code:match("^%d%d%d%d%d%d$") then
            if j.status == "authorized" then return nil, { code = "bad_response" } end
        else
            out.confirmation_code = j.confirmation_code
        end
    elseif j.status == "complete" then
        local d = j.device
        if type(d) ~= "table" or not valid_id(d.device_id) or type(d.device_credential) ~= "string"
            or #d.device_credential < 16 then
            return nil, { code = "bad_response" }
        end
        out.device = { device_id = d.device_id, device_credential = d.device_credential }
    elseif j.status ~= "waiting" and j.status ~= "reader_confirmed" then
        return nil, { code = "bad_response" }
    end
    return out
end

function Broker:confirm(p, code)
    local res, err = self:_post("/api/pairings/" .. p.pairing_id .. "/confirm", p.poll_secret,
        { confirmation_code = code })
    if not res then return nil, err end
    if res.status ~= 200 then return nil, { code = err_code(res), retryable = res.status >= 500 } end
    return res.json or {}
end

function Broker:ack(p)
    local res, err = self:_post("/api/pairings/" .. p.pairing_id .. "/ack", p.poll_secret)
    if not res then return nil, err end
    if res.status ~= 204 and res.status ~= 200 then
        return nil, { code = err_code(res), retryable = res.status >= 500 }
    end
    return true
end

local function device_bearer(creds)
    return creds.device_id .. "." .. creds.device_credential
end

--- Returns {access_token, expires_in} or nil, err. err.reauth=true means re-pair needed.
function Broker:token(creds)
    local res, err = self:_post("/api/token", device_bearer(creds))
    if not res then return nil, err end
    if res.status == 401 then
        return nil, { code = err_code(res), reauth = true }
    end
    local j = res.json
    if res.status ~= 200 or type(j) ~= "table" or type(j.access_token) ~= "string" or j.access_token == "" then
        return nil, { code = err_code(res), retryable = res.status >= 500 or res.status == 200 }
    end
    return { access_token = j.access_token, expires_in = tonumber(j.expires_in) or 300 }
end

function Broker:unpair(creds)
    local res, err = self.http:request{ method = "DELETE", path = "/api/device",
        headers = { authorization = "Bearer " .. device_bearer(creds) } }
    if not res then return nil, err end
    return res.status == 204 or res.status == 200 or res.status == 401
end

return Broker
