--[[--
Per-device upload manifest (one file per broker device_id).

File states:
  done        batchCreate reported success (media_id recorded)
  creating    written BEFORE batchCreate is sent; if still present on load,
              the outcome is unknown and it is surfaced as "uncertain"
  uncertain   batchCreate outcome unknown (response lost / 5xx). Not retried
              automatically, to avoid duplicates. User may mark it as uploaded
              or explicitly re-queue it (which may create a duplicate).
  failed      definite failure (retried on next run)
There is NO exactly-once guarantee: Google Photos offers no idempotency key.
Source files are never modified or deleted.
--]]

local Storage = require("gphotos/storage")

local Manifest = {}
Manifest.__index = Manifest

Manifest.STATES = { done = true, creating = true, uncertain = true, failed = true }

function Manifest.path_for(dir, device_id)
    return dir .. "/manifest-" .. device_id:gsub("[^%w_%-]", "_") .. ".json"
end

--- Loads (or creates) the manifest. Returns manifest or nil, err for corrupt files
-- (corrupt manifests are never overwritten silently).
function Manifest.load(dir, device_id)
    local path = Manifest.path_for(dir, device_id)
    local data, err = Storage.read_json(path)
    if not data then
        if err ~= "missing" then return nil, "manifest corrupt: " .. tostring(err) end
        data = { version = 1, device_id = device_id, files = {} }
    end
    if data.version ~= 1 then return nil, "manifest version unsupported" end
    if data.device_id ~= device_id or type(data.files) ~= "table" then
        return nil, "manifest does not belong to this device"
    end
    for key, rec in pairs(data.files) do
        if type(key) ~= "string" or type(rec) ~= "table" or not Manifest.STATES[rec.state] then
            return nil, "manifest corrupt: bad record"
        end
    end
    if data.album_id ~= nil and type(data.album_id) ~= "string" then
        return nil, "manifest corrupt: bad album"
    end
    local m = setmetatable({ path = path, data = data }, Manifest)
    for _, rec in pairs(data.files) do
        if rec.state == "creating" then rec.state = "uncertain" end
    end
    return m
end

function Manifest:save()
    return Storage.write_json(self.path, self.data)
end

function Manifest:album_id() return self.data.album_id end
function Manifest:set_album(id, title)
    self.data.album_id, self.data.album_title = id, title
end

function Manifest:get(key) return self.data.files[key] end

function Manifest:set(key, rec)
    self.data.files[key] = rec
end

--- True if the file should be (re)tried in this run.
function Manifest:wants(key)
    local r = self.data.files[key]
    return r == nil or r.state == "failed"
end

function Manifest:list(state)
    local out = {}
    for k, r in pairs(self.data.files) do
        if r.state == state then out[#out + 1] = k end
    end
    table.sort(out)
    return out
end

function Manifest:counts()
    local c = { done = 0, uncertain = 0, failed = 0 }
    for _, r in pairs(self.data.files) do
        c[r.state] = (c[r.state] or 0) + 1
    end
    return c
end

--- User recovery: resolve every uncertain record. action = "done" | "retry".
function Manifest:resolve_uncertain(action)
    local n = 0
    for _, r in pairs(self.data.files) do
        if r.state == "uncertain" then
            r.state = action == "done" and "done" or "failed"
            r.resolved_by_user = true
            n = n + 1
        end
    end
    return n
end

return Manifest
