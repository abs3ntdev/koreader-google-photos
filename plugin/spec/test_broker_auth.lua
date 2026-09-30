local T = require("support")
local Broker = require("gphotos/broker")
local Auth = require("gphotos/auth")
local Storage = require("gphotos/storage")

local ORIGIN = "https://broker.example.com"
local CRED = { device_id = "dev_1", device_credential = "c_0123456789abcdef" }

local function pairing_setup(poll_script, extra)
    local d = T.tmpdir()
    local polls = 0
    local handlers = {
        ["POST /api/pairings"] = function() return T.json_res(201, { pairing_id = "p1",
            pair_url = "https://broker.example.com/pair/p1", poll_secret = "SECRET", expires_in = 600, poll_interval = 3 }) end,
        ["POST /api/pairings/p1/poll"] = function(req)
            polls = polls + 1
            return poll_script(polls, req)
        end,
        ["POST /api/pairings/p1/ack"] = function() return { status = 204, headers = {}, body = "" } end,
        ["POST /api/pairings/p1/confirm"] = function() return T.json_res(200, { status = "reader_confirmed" }) end,
    }
    for k, v in pairs(extra or {}) do handlers[k] = v end
    local http = T.fake_http(ORIGIN, handlers)
    local ev = { codes = {}, complete = nil, fail = nil }
    local pairing = Auth.Pairing.new{
        broker = Broker.new(http), creds_path = d .. "/device.json", origin = ORIGIN,
        now = function() return 1000 end,
        callbacks = {
            on_code = function(c) ev.codes[#ev.codes + 1] = c end,
            on_waiting = function(s) ev.waiting = s end,
            on_complete = function(c) ev.complete = c end,
            on_fail = function(c) ev.fail = c end,
        },
    }
    return pairing, http, ev, d
end

T.test("pairing: QR shows pair_url only; secret only in Authorization to broker", function()
    local pairing, http = pairing_setup(function() return T.json_res(200, { status = "waiting" }) end)
    local p = pairing:start()
    T.eq(p.pair_url, "https://broker.example.com/pair/p1")
    T.ok(not p.pair_url:find("SECRET"))
    pairing:poll_once()
    T.eq(http.calls[2].headers.authorization, "Bearer SECRET")
end)

T.test("pairing: code shown, never auto-confirmed; confirm only on user action", function()
    local pairing, http, ev = pairing_setup(function(n)
        return T.json_res(200, { status = "authorized", confirmation_code = "123456" })
    end)
    pairing:start()
    pairing:poll_once(); pairing:poll_once()
    T.eq(#ev.codes, 1); T.eq(ev.codes[1], "123456")
    T.eq(http:count("POST /api/pairings/p1/confirm"), 0)
    T.ok(pairing:confirm())
    local body = http.calls[#http.calls].body
    T.ok(body:find('"confirmation_code":"123456"'))
end)

T.test("pairing: credential durably saved BEFORE ack; complete -> paired", function()
    local order = {}
    local pairing, http, ev, d
    pairing, http, ev, d = pairing_setup(function()
        return T.json_res(200, { status = "complete", device = CRED })
    end, { ["POST /api/pairings/p1/ack"] = function()
        order[#order + 1] = Storage.read_json(d .. "/device.json") and "saved" or "not_saved"
        return { status = 204, headers = {}, body = "" }
    end })
    pairing:start()
    T.eq(pairing:poll_once(), "stop")
    T.eq(order[1], "saved")
    T.eq(ev.complete.device_id, "dev_1")
    local c = Auth.load_creds(d .. "/device.json", ORIGIN)
    T.eq(c.device_credential, CRED.device_credential); T.eq(c.broker_origin, ORIGIN)
end)

T.test("pairing: failed credential save does not ack; retried on next poll", function()
    local pairing, http = pairing_setup(function()
        return T.json_res(200, { status = "complete", device = CRED })
    end)
    pairing:start()
    local prev = Storage.sys
    Storage.sys = { fsync = function() return false, "ENOSPC" end }
    T.eq(pairing:poll_once(), "continue")
    Storage.sys = prev
    T.eq(http:count("POST /api/pairings/p1/ack"), 0)
    T.eq(pairing:poll_once(), "stop")
    T.eq(http:count("POST /api/pairings/p1/ack"), 1)
end)

T.test("pairing: ack network loss is retried, no credential loss", function()
    local acks = 0
    local pairing, http, ev = pairing_setup(function()
        return T.json_res(200, { status = "complete", device = CRED })
    end, { ["POST /api/pairings/p1/ack"] = function()
        acks = acks + 1
        if acks == 1 then return nil, { kind = "network", message = "timeout" } end
        return { status = 204, headers = {}, body = "" }
    end })
    pairing:start()
    T.eq(pairing:poll_once(), "continue")
    T.eq(ev.complete, nil)
    T.eq(pairing:poll_once(), "stop")
    T.ok(ev.complete)
end)

T.test("pairing: confirm request lost before delivery is resent for same approved code", function()
    local confirms = 0
    local pairing, http = pairing_setup(function()
        return T.json_res(200, { status = "authorized", confirmation_code = "123456" })
    end, { ["POST /api/pairings/p1/confirm"] = function()
        confirms = confirms + 1
        if confirms == 1 then return nil, { kind = "network" } end
        return T.json_res(200, { status = "reader_confirmed" })
    end })
    pairing:start(); pairing:poll_once()
    T.ok(pairing:confirm())          -- lost request
    pairing:poll_once()              -- broker still 'authorized' -> resend
    T.eq(confirms, 2)
end)

T.test("pairing: confirm response lost but applied -> one idempotent resend of same code, then stops", function()
    local confirms = 0
    local state = "authorized"
    local pairing, _, ev = pairing_setup(function()
        return T.json_res(200, { status = state, confirmation_code = state == "authorized" and "123456" or nil })
    end, { ["POST /api/pairings/p1/confirm"] = function(req)
        confirms = confirms + 1; state = "reader_confirmed"
        T.ok(req.body:find("123456"))
        if confirms == 1 then return nil, { kind = "network" } end
        return T.json_res(200, { status = "reader_confirmed" })
    end })
    pairing:start(); pairing:poll_once()
    T.ok(pairing:confirm())
    T.eq(pairing:poll_once(), "continue")
    T.eq(pairing:poll_once(), "continue")
    T.eq(confirms, 2)
    T.eq(#ev.codes, 1, "user not re-prompted")
end)

T.test("pairing: expired/unauthorized poll is terminal", function()
    local pairing, _, ev = pairing_setup(function() return T.json_res(410, { error = "expired" }) end)
    pairing:start()
    T.eq(pairing:poll_once(), "stop"); T.eq(ev.fail, "expired")
end)

T.test("broker: token bearer is device_id.credential; 401 => reauth; 502 retryable", function()
    local status = 200
    local http = T.fake_http(ORIGIN, { ["POST /api/token"] = function(req)
        T.eq(req.headers.authorization, "Bearer dev_1.c_0123456789abcdef")
        if status == 200 then return T.json_res(200, { access_token = "AT", expires_in = 3600, token_type = "Bearer" }) end
        return T.json_res(status, { error = status == 401 and "reauth_required" or "upstream_error" })
    end })
    local b = Broker.new(http)
    T.eq(b:token(CRED).access_token, "AT")
    status = 401; local _, e = b:token(CRED); T.ok(e.reauth); T.eq(e.code, "reauth_required")
    status = 502; _, e = b:token(CRED); T.ok(e.retryable and not e.reauth)
end)

T.test("auth: credential bound to broker origin", function()
    local d = T.tmpdir()
    Auth.save_creds(d .. "/device.json", ORIGIN, CRED, 1)
    T.ok(Auth.load_creds(d .. "/device.json", ORIGIN))
    local c, err, stored = Auth.load_creds(d .. "/device.json", "https://other.example.com")
    T.eq(c, nil); T.eq(err, "origin_mismatch"); T.eq(stored.device_id, "dev_1")
end)

T.test("pairing: transient 500 on confirm keeps approval and retries same code", function()
    local confirms, state = 0, "authorized"
    local pairing = pairing_setup(function()
        return T.json_res(200, { status = state, confirmation_code = "123456" })
    end, { ["POST /api/pairings/p1/confirm"] = function(req)
        confirms = confirms + 1
        T.ok(req.body:find("123456"))
        if confirms == 1 then state = "reader_confirmed"; return T.json_res(500, { error = "internal" }) end
        return T.json_res(200, { status = "reader_confirmed" })
    end })
    pairing:start(); pairing:poll_once()
    T.ok(pairing:confirm())
    pairing:poll_once()            -- reader_confirmed but last attempt failed -> resend
    T.eq(confirms, 2)
    pairing:poll_once()            -- succeeded, no more resends
    T.eq(confirms, 2)
end)

T.test("pairing: code_mismatch drops approval and re-prompts", function()
    local pairing, _, ev = pairing_setup(function()
        return T.json_res(200, { status = "authorized", confirmation_code = "123456" })
    end, { ["POST /api/pairings/p1/confirm"] = function() return T.json_res(400, { error = "code_mismatch" }) end })
    pairing:start(); pairing:poll_once()
    T.eq(select(2, pairing:confirm()), "code_mismatch")
    pairing:poll_once()
    T.eq(#ev.codes, 2)
end)
