--[[--
Application glue: config, credentials, manifests, job creation.
UI independent so it can be tested with mocked KOReader boundaries.
--]]

local Http = require("gphotos/http")
local Broker = require("gphotos/broker")
local Photos = require("gphotos/photos")
local Auth = require("gphotos/auth")
local Manifest = require("gphotos/manifest")
local Scanner = require("gphotos/scanner")
local Job = require("gphotos/uploader")

local App = {}
App.__index = App

App.SETTING_ORIGIN = "googlephotos_broker_origin"
App.SETTING_LAST = "googlephotos_last_folder"
App.NET_TIMEOUT = 30
App.CREDENTIAL_NOTE = "Note: the device link credential is stored unencrypted on this reader. "
    .. "On FAT/vfat storage file permissions are not enforced, so anyone with access to the "
    .. "device or its USB storage can read it. Use Unlink if the reader is lost or shared."

--- Real network deps on device. CA bundle shipped by KOReader (koreader-base
-- thirdparty/certifi -> data/ca-bundle.crt, relative to KOReader's cwd).
function App.default_net_deps()
    local DataStorage = require("datastorage")
    local cafile = "data/ca-bundle.crt"
    local f = io.open(cafile, "rb")
    if f then f:close() else cafile = DataStorage:getDataDir() .. "/data/ca-bundle.crt" end
    return {
        http = require("socket.http"), ltn12 = require("ltn12"),
        socket = require("socket"), ssl = require("ssl"),
        cafile = cafile, timeout = App.NET_TIMEOUT,
    }
end

--- opts: { data_dir, settings (LuaSettings-like), lfs, now, net_deps = fn() }
function App.new(opts)
    local self = setmetatable(opts, App)
    if self.lfs.attributes(self.data_dir, "mode") ~= "directory" then
        self.lfs.mkdir(self.data_dir)
    end
    self.creds_path = self.data_dir .. "/device.json"
    return self
end

function App:brokerOrigin()
    local o = self.settings:readSetting(App.SETTING_ORIGIN)
    return Http.parse_origin(o) and o or nil
end

function App:setBrokerOrigin(o)
    o = (o or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    if not Http.parse_origin(o) then return nil, "must be https://host[:port]" end
    self.settings:saveSetting(App.SETTING_ORIGIN, o)
    return true
end

function App:lastFolder() return self.settings:readSetting(App.SETTING_LAST) end
function App:setLastFolder(p) self.settings:saveSetting(App.SETTING_LAST, p) end

function App:creds()
    local origin = self:brokerOrigin()
    if not origin then return nil, "no_broker" end
    return Auth.load_creds(self.creds_path, origin)
end

function App:isPaired() return self:creds() ~= nil end

function App:hasCredentialFile()
    return self.lfs.attributes(self.creds_path, "mode") == "file"
end

function App:_broker(origin)
    return Broker.new(Http.new(origin, self.net_deps()))
end

function App:newPairing(callbacks)
    local origin = self:brokerOrigin()
    return Auth.Pairing.new{
        broker = self:_broker(origin), creds_path = self.creds_path,
        origin = origin, now = self.now, callbacks = callbacks,
    }
end

function App:_manifest(creds)
    return Manifest.load(self.data_dir, creds.device_id)
end

function App:newUploadJob(dir)
    local creds, cerr = self:creds()
    if not creds then return nil, "not linked (" .. tostring(cerr) .. ")" end
    local files, serr = Scanner.scan(self.lfs, dir)
    if not files then return nil, serr end
    local manifest, merr = self:_manifest(creds)
    if not manifest then return nil, merr end
    local job = Job.new{
        broker = self:_broker(creds.broker_origin), creds = creds,
        photos_http = Http.new(Photos.ORIGIN, self.net_deps()),
        manifest = manifest, files = files, album_title = "KOReader", now = self.now,
    }
    job.scan_skipped = serr
    return job
end

local REASONS = {
    offline = "network unavailable, try again later",
    reauth = "device link revoked or expired: link your account again (history kept)",
    uncertain = "connection lost while creating items; use 'Resolve uncertain uploads'",
    storage = "could not save upload history; nothing further was sent",
    cancelled = "stopped by user",
    rate_limited = "Google Photos rate limit reached; run the upload again later",
}

function App:summarize(job, result)
    local s = job.stats
    local text = string.format("Uploaded: %d\nFailed: %d\nUncertain: %d\nAlready handled: %d",
        s.uploaded, s.failed, s.uncertain, s.skipped)
    if result == "aborted" or result == "cancelled" then
        local r = job.abort_reason or "cancelled"
        text = text .. "\n\nStopped: " .. (REASONS[r] or r)
    end
    return text
end

function App:uncertainCount()
    local creds = self:creds()
    if not creds then return nil, "not linked" end
    local m, err = self:_manifest(creds)
    if not m then return nil, err end
    return #m:list("uncertain")
end

function App:resolveUncertain(action)
    local creds = self:creds()
    if not creds then return nil, "not linked" end
    local m, err = self:_manifest(creds)
    if not m then return nil, err end
    local n = m:resolve_uncertain(action)
    local ok, serr = m:save()
    if not ok then return nil, serr end
    return n
end

function App:statusText()
    local origin = self:brokerOrigin()
    if not origin then return "Broker server URL not set." end
    local creds, err = self:creds()
    if not creds then
        if err == "origin_mismatch" then
            return "Stored link belongs to a different broker URL. Link again or unlink."
        end
        return "Not linked. Broker: " .. origin
    end
    local m, merr = self:_manifest(creds)
    if not m then return "Linked (" .. creds.device_id .. ")\nHistory error: " .. tostring(merr) end
    local c = m:counts()
    return string.format("Linked device: %s\nBroker: %s\nAlbum: %s\nDone: %d  Failed: %d  Uncertain: %d\n\n%s",
        creds.device_id, origin, m:album_id() and "created" or "not yet created",
        c.done, c.failed, c.uncertain, App.CREDENTIAL_NOTE)
end

--- Revokes on the broker, then deletes the local credential. On network/5xx
-- failure the credential is kept so the user can retry. Manifests are kept.
function App:unlink()
    local origin = self:brokerOrigin()
    local ok_c, cerr, stored = self:creds()
    local creds = ok_c or stored
    if not creds then
        if cerr == "missing" or not self:hasCredentialFile() then return true end
        if cerr == "no_broker" then return nil, "set the broker URL the device was linked with, then unlink" end
        -- Corrupt/unreadable credential: keep it for manual recovery.
        return nil, "credential file unreadable (" .. tostring(cerr) .. "): " .. self.creds_path
    end
    if not origin or creds.broker_origin ~= origin then
        -- Never send a credential to a different broker; revoke must be done there.
        return nil, "credential belongs to " .. tostring(creds.broker_origin) .. "; set that URL to unlink"
    end
    local ok, err = self:_broker(origin):unpair(creds)
    if not ok then return nil, type(err) == "table" and (err.message or err.kind) or "server error" end
    local removed, rerr = Auth.clear_creds(self.creds_path)
    if not removed then
        return nil, "revoked on server, but could not delete local file " .. self.creds_path .. ": " .. tostring(rerr)
    end
    return true
end

return App
