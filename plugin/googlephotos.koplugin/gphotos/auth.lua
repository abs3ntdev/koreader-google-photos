--[[--
Device credential store + pairing flow driver (UI independent).

Credentials file: { broker_origin, device_id, device_credential, paired_at }
bound to the exact broker origin; if the configured origin differs the stored
credential is never sent (treated as unpaired, file left for the user to unlink).
Credentials are stored in plaintext JSON (mode 0600 where the filesystem
honours POSIX modes; FAT/vfat reader storage does not).
--]]

local Storage = require("gphotos/storage")

local Auth = {}

function Auth.load_creds(path, origin)
    local c, err = Storage.read_json(path)
    if not c then return nil, err end
    if type(c.device_id) ~= "string" or type(c.device_credential) ~= "string" then
        return nil, "corrupt"
    end
    if c.broker_origin ~= origin then return nil, "origin_mismatch", c end
    return c
end

function Auth.save_creds(path, origin, device, now)
    return Storage.write_json(path, {
        broker_origin = origin, device_id = device.device_id,
        device_credential = device.device_credential, paired_at = now,
    })
end

function Auth.clear_creds(path)
    os.remove(path .. ".tmp")
    return os.remove(path)
end

--- Pairing state machine. Callbacks (all required):
--   on_code(code)         show code, user must explicitly press "Codes match"
--   on_waiting(status)    status text update
--   on_complete(creds)    paired
--   on_fail(code)         terminal failure
local Pairing = {}
Pairing.__index = Pairing
Auth.Pairing = Pairing

function Pairing.new(opts)
    return setmetatable({
        broker = opts.broker, creds_path = opts.creds_path, origin = opts.origin,
        now = opts.now or os.time, cb = opts.callbacks,
        state = "new", confirmed = false, net_failures = 0,
    }, Pairing)
end

function Pairing:start()
    local p, err = self.broker:start_pairing()
    if not p then self.state = "failed"; self.cb.on_fail(err and err.code or "error"); return nil end
    self.p = p
    self.deadline = self.now() + p.expires_in
    self.state = "polling"
    return p
end

--- User pressed "Codes match". Approval of this exact code is remembered
-- BEFORE sending, so transient failures (network, 5xx, 429) are retried by
-- poll_once with the same code. Terminal errors stop the flow.
function Pairing:confirm()
    if not self.code or self.state ~= "polling" then return false end
    self.confirmed = true
    return self:_send_confirm()
end

local TERMINAL = { expired = true, not_found = true, unauthorized = true }

function Pairing:_send_confirm()
    local r, err = self.broker:confirm(self.p, self.code)
    if r then self.confirm_pending = false; return true end
    local code = err and err.code
    if TERMINAL[code] then
        self.state = "failed"; self.cb.on_fail(code); return false, code
    end
    if code == "code_mismatch" then
        -- Broker rejected this code: drop approval, user must re-check.
        self.confirmed, self.confirm_pending = false, false
        self.code = nil -- next poll re-prompts the user
        return false, code
    end
    -- Transient (network / 5xx / 429 / unknown): outcome unknown, retry on poll.
    self.confirm_pending = true
    return true
end

function Pairing:cancel()
    self.state = "cancelled"
end

--- One poll iteration. Returns "continue" (call again after poll_interval) or "stop".
function Pairing:poll_once()
    if self.state ~= "polling" and self.state ~= "acking" then return "stop" end
    if self.now() > self.deadline then
        self.state = "failed"; self.cb.on_fail("expired"); return "stop"
    end
    if self.state == "acking" then return self:_ack() end
    local r, err = self.broker:poll(self.p)
    if not r then
        if err and (err.retryable or err.code == "network") then
            self.net_failures = self.net_failures + 1
            return "continue"
        end
        self.state = "failed"; self.cb.on_fail(err and err.code or "error"); return "stop"
    end
    self.net_failures = 0
    if r.status == "complete" then
        local ok = Auth.save_creds(self.creds_path, self.origin, r.device, self.now())
        if not ok then
            -- Not durable: do not ack, the broker keeps repeating complete.
            self.cb.on_waiting("storage_error")
            return "continue"
        end
        self.device = r.device
        self.state = "acking"
        return self:_ack()
    end
    if r.confirmation_code and r.confirmation_code ~= self.code then
        -- New code: any earlier approval does not apply to it.
        self.code = r.confirmation_code
        self.confirmed = false
        self.cb.on_code(self.code)
    elseif self.confirmed and self.code and (r.status == "authorized" or r.status == "phone_confirmed"
        or (r.status == "reader_confirmed" and self.confirm_pending)) then
        -- Broker has not (durably) recorded our confirmation. The user explicitly
        -- approved exactly this code, so resend it.
        self:_send_confirm()
        if self.state ~= "polling" then return "stop" end
    end
    self.cb.on_waiting(r.status)
    return "continue"
end

function Pairing:_ack()
    local ok, err = self.broker:ack(self.p)
    if not ok and err and (err.retryable or err.code == "network") then return "continue" end
    -- 404/410 after a durable save still means we hold the credential; token call validates it.
    self.state = "complete"
    self.cb.on_complete({ broker_origin = self.origin, device_id = self.device.device_id,
        device_credential = self.device.device_credential })
    return "stop"
end

return Auth
