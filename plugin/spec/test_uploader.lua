local T = require("support")
local Job = require("gphotos/uploader")
local Manifest = require("gphotos/manifest")
local Photos = require("gphotos/photos")
local Storage = require("gphotos/storage")
local json = require("gphotos/json")

local CREDS = { device_id = "dev_1", device_credential = "c_0123456789abcdef" }

local function files(n)
    local out = {}
    for i = 1, n do
        out[i] = { path = "/s/f" .. i .. ".png", name = "f" .. i .. ".png", size = 3, key = "/s/f" .. i .. ".png|3|0" }
    end
    return out
end

-- Fake Photos HTTP: uploads return "tok:<file>", batchCreate per `create` fn.
local function env(opts)
    opts = opts or {}
    local dir = T.tmpdir()
    local token_calls = 0
    local broker = { token = function()
        token_calls = token_calls + 1
        if opts.token_err then return nil, opts.token_err end
        return { access_token = "AT" .. token_calls, expires_in = 3600 }
    end }
    local http = T.fake_http(Photos.ORIGIN, {
        ["POST /v1/albums"] = opts.album or function() return T.json_res(200, { id = "ALBUM1" }) end,
        ["POST /v1/uploads"] = opts.upload or function(req)
            return { status = 200, headers = {}, body = "tok:" .. req.body_file }
        end,
        ["POST /v1/mediaItems:batchCreate"] = opts.create or function(req)
            local body = json.decode(req.body)
            local res = {}
            for i, it in ipairs(body.newMediaItems) do
                res[i] = { uploadToken = it.simpleMediaItem.uploadToken, status = { message = "Success" },
                    mediaItem = { id = "m:" .. it.simpleMediaItem.fileName } }
            end
            return T.json_res(200, { newMediaItemResults = res })
        end,
    })
    local m = assert(Manifest.load(dir, "dev_1"))
    return { dir = dir, http = http, manifest = m, broker = broker,
        token_calls = function() return token_calls end,
        job = function(fs)
            return Job.new{ broker = broker, creds = CREDS, photos_http = http, manifest = m,
                files = fs, now = function() return 100 end }
        end }
end

T.test("uploader: album created once and saved before batchCreate; 120 files => 3 batches, 1 token call", function()
    local e = env()
    local j = e.job(files(120))
    T.eq(j:run(), "done")
    T.eq(j.stats.uploaded, 120)
    T.eq(e.http:count("POST /v1/albums"), 1)
    T.eq(e.http:count("POST /v1/mediaItems:batchCreate"), 3)
    T.eq(e.token_calls(), 1, "access token cached for the job")
    local m2 = Manifest.load(e.dir, "dev_1")
    T.eq(m2:album_id(), "ALBUM1")
    T.eq(m2:get("/s/f7.png|3|0").state, "done")
    -- second run: nothing re-uploaded, album reused
    local j2 = Job.new{ broker = e.broker, creds = CREDS, photos_http = e.http, manifest = m2, files = files(120) }
    T.eq(j2:total(), 0); T.eq(j2.stats.skipped, 120)
end)

T.test("uploader: 'creating' persisted before batchCreate is sent", function()
    local e
    e = env({ create = function()
        local on_disk = Storage.read_json(Manifest.path_for(e.dir, "dev_1"))
        T.eq(on_disk.files["/s/f1.png|3|0"].state, "creating")
        return nil, { kind = "network" }
    end })
    e.job(files(1)):run()
end)

T.test("uploader: lost batchCreate response => uncertain, not auto-retried, user recovery", function()
    local e = env({ create = function() return nil, { kind = "network", message = "timeout" } end })
    local j = e.job(files(2))
    T.eq(j:run(), "aborted"); T.eq(j.abort_reason, "uncertain")
    T.eq(j.stats.uncertain, 2)
    local m = Manifest.load(e.dir, "dev_1")
    T.eq(#m:list("uncertain"), 2)
    local j2 = Job.new{ broker = e.broker, creds = CREDS, photos_http = e.http, manifest = m, files = files(2) }
    T.eq(j2:total(), 0, "uncertain files are not replayed automatically")
    m:resolve_uncertain("retry"); m:save()
    local j3 = Job.new{ broker = e.broker, creds = CREDS, photos_http = e.http, manifest = m, files = files(2) }
    T.eq(j3:total(), 2, "explicit user retry re-queues")
end)

T.test("uploader: crash while 'creating' => uncertain on reload", function()
    local e = env()
    e.manifest:set("k", { state = "creating", name = "x" }); e.manifest:save()
    T.eq(Manifest.load(e.dir, "dev_1"):get("k").state, "uncertain")
end)

T.test("uploader: offline during upload aborts, files marked failed and retried next run", function()
    local e = env({ upload = function() return nil, { kind = "network" } end })
    local j = e.job(files(3))
    T.eq(j:run(), "aborted"); T.eq(j.abort_reason, "offline")
    T.eq(e.http:count("POST /v1/mediaItems:batchCreate"), 0)
    T.ok(e.manifest:wants("/s/f1.png|3|0"))
end)

T.test("uploader: broker reauth_required aborts with reauth and keeps history", function()
    local e = env({ token_err = { code = "reauth_required", reauth = true } })
    e.manifest:set("old", { state = "done", name = "o" })
    local j = e.job(files(1))
    T.eq(j:run(), "aborted"); T.eq(j.abort_reason, "reauth")
    T.eq(Manifest.load(e.dir, "dev_1"):get("old").state, "done")
end)

T.test("uploader: Photos 401 refreshes access token once", function()
    local n = 0
    local e = env({ upload = function(req)
        n = n + 1
        if n == 1 then return T.json_res(401, {}) end
        T.eq(req.headers.authorization, "Bearer AT2")
        return { status = 200, headers = {}, body = "tok" }
    end })
    T.eq(e.job(files(1)):run(), "done")
end)

T.test("uploader: manifest save failure before batchCreate => nothing created", function()
    local e = env()
    local j = e.job(files(1))
    T.eq(j:step(), "continue") -- album
    T.eq(j:step(), "continue") -- upload
    T.eq(j:step(), "continue") -- -> create
    local prev = Storage.sys
    Storage.sys = { fsync = function() return false, "EIO" end }
    local r = j:step()
    Storage.sys = prev
    T.eq(r, "aborted"); T.eq(j.abort_reason, "storage")
    T.eq(e.http:count("POST /v1/mediaItems:batchCreate"), 0)
end)

T.test("manifest: unknown version / malformed record / other device fail closed", function()
    local d = T.tmpdir()
    local path = Manifest.path_for(d, "dev_1")
    for _, bad in ipairs({
        { version = 2, device_id = "dev_1", files = {} },
        { version = 1, device_id = "dev_1", files = { k = "x" } },
        { version = 1, device_id = "dev_1", files = { k = { state = "weird" } } },
        { version = 1, device_id = "dev_2", files = {} },
    }) do
        Storage.write_json(path, bad)
        T.eq(Manifest.load(d, "dev_1"), nil)
    end
    local f = io.open(path, "wb"); f:write("{"); f:close()
    T.eq(Manifest.load(d, "dev_1"), nil)
    local f2 = io.open(path, "rb"); T.eq(f2:read("*a"), "{", "corrupt manifest not overwritten"); f2:close()
end)

T.test("uploader: batchCreate 429 aborts (no further uploads) with rate_limited", function()
    local e = env({ create = function() return T.json_res(429, {}) end })
    local j = e.job(files(60))
    T.eq(j:run(), "aborted"); T.eq(j.abort_reason, "rate_limited")
    T.eq(e.http:count("POST /v1/uploads"), 50)
end)

T.test("uploader: all-fail run persists failed records", function()
    local e = env({ upload = function() return T.json_res(400, {}) end })
    T.eq(e.job(files(2)):run(), "done")
    T.eq(Manifest.load(e.dir, "dev_1"):get("/s/f1.png|3|0").state, "failed")
end)
