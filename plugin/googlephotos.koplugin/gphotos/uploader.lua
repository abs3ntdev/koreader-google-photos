--[[--
Upload job: step-driven so the UI can yield between steps (UIManager:scheduleIn).
Network requests are synchronous; the UI yields between steps.

Order per batch (<= 50 files):
  1. ensure app-created album exists (album id saved in manifest before use)
  2. upload bytes for each file -> upload token (kept in memory only)
  3. mark batch "creating" and SAVE manifest before sending batchCreate
  4. batchCreate into album; mark done / failed / uncertain; save
Access token is cached for the job (one /api/token call per ~expires_in),
avoiding the broker rate limit on large folders.
--]]

local Photos = require("gphotos/photos")

local Job = {}
Job.__index = Job

--- opts: { broker, creds, photos_http, manifest, files, album_title, now = os.time }
function Job.new(opts)
    local self = setmetatable({
        broker = opts.broker, creds = opts.creds, manifest = opts.manifest,
        album_title = opts.album_title or "KOReader",
        now = opts.now or os.time,
        queue = {}, pending = {}, idx = 1,
        stats = { uploaded = 0, failed = 0, uncertain = 0, skipped = 0 },
        state = "album",
    }, Job)
    for _, f in ipairs(opts.files) do
        if opts.manifest:wants(f.key) then
            self.queue[#self.queue + 1] = f
        else
            self.stats.skipped = self.stats.skipped + 1
        end
    end
    self.photos = Photos.new(opts.photos_http, function() return self:_token() end)
    return self
end

function Job:_token()
    if self.token and self.token_expiry - self.now() > 60 then return self.token end
    local t, err = self.broker:token(self.creds)
    if not t then
        self.token = nil
        return nil, err
    end
    self.token, self.token_expiry = t.access_token, self.now() + t.expires_in
    return self.token
end

function Job:total() return #self.queue end

function Job:_abort(reason, err)
    self.state = "aborted"
    self.abort_reason = reason
    self.abort_error = err
    -- Tokens of files uploaded but not yet created are simply dropped (not created).
    for _, p in ipairs(self.pending) do
        self.manifest:set(p.file.key, { state = "failed", name = p.file.name, error = reason })
    end
    self.pending = {}
    self.manifest:save()
    return "aborted"
end

local function reason_of(err)
    if type(err) ~= "table" then return "error" end
    if err.reauth then return "reauth" end
    if err.code == "network" then return "offline" end
    return err.code or "error"
end

--- Performs one step. Returns "continue", "done" or "aborted".
function Job:step()
    if self.state == "album" then
        if #self.queue == 0 then self.state = "done"; return "done" end
        if not self.manifest:album_id() then
            local id, err = self.photos:create_album(self.album_title)
            if not id then return self:_abort(reason_of(err), err) end
            self.manifest:set_album(id, self.album_title)
            local ok, serr = self.manifest:save()
            if not ok then return self:_abort("storage", serr) end
        end
        self.state = "upload"
        return "continue"
    elseif self.state == "upload" then
        local f = self.queue[self.idx]
        if not f or #self.pending >= Photos.MAX_BATCH then
            if #self.pending > 0 then self.state = "create"; return "continue" end
            -- Persist definite failures so history survives all-fail runs.
            local ok, serr = self.manifest:save()
            if not ok then return self:_abort("storage", serr) end
            self.state = "done"
            return "done"
        end
        self.idx = self.idx + 1
        local token, err = self.photos:upload(f.path, f.name, f.size)
        if not token and type(err) == "table" and err.token_rejected then
            self.token = nil -- access token rejected: refresh once and retry
            token, err = self.photos:upload(f.path, f.name, f.size)
        end
        if token then
            self.pending[#self.pending + 1] = { file = f, upload_token = token }
            return "continue"
        end
        local reason = reason_of(err)
        self.manifest:set(f.key, { state = "failed", name = f.name, error = reason })
        self.stats.failed = self.stats.failed + 1
        if type(err) == "table" and err.status == 429 then return self:_abort("rate_limited", err) end
        if reason == "offline" or reason == "reauth" then
            return self:_abort(reason, err)
        end
        return "continue"
    elseif self.state == "create" then
        local items = {}
        for i, p in ipairs(self.pending) do
            items[i] = { upload_token = p.upload_token, file_name = p.file.name }
            self.manifest:set(p.file.key, { state = "creating", name = p.file.name, at = self.now() })
        end
        local ok, serr = self.manifest:save()
        if not ok then
            -- Could not durably record intent: do not send batchCreate.
            for _, p in ipairs(self.pending) do self.manifest:set(p.file.key, nil) end
            self.pending = {}
            return self:_abort("storage", serr)
        end
        local results, err = self.photos:batch_create(self.manifest:album_id(), items)
        local batch = self.pending
        self.pending = {}
        for i, p in ipairs(batch) do
            local key, rec = p.file.key, nil
            if results then
                local r = results[i]
                if r.ok then
                    rec = { state = "done", name = p.file.name, media_id = r.media_id, at = self.now() }
                    self.stats.uploaded = self.stats.uploaded + 1
                elseif r.uncertain then
                    rec = { state = "uncertain", name = p.file.name, error = r.message }
                    self.stats.uncertain = self.stats.uncertain + 1
                else
                    rec = { state = "failed", name = p.file.name, error = r.message }
                    self.stats.failed = self.stats.failed + 1
                end
            elseif err and err.uncertain then
                rec = { state = "uncertain", name = p.file.name, error = reason_of(err) }
                self.stats.uncertain = self.stats.uncertain + 1
            else
                rec = { state = "failed", name = p.file.name, error = reason_of(err) }
                self.stats.failed = self.stats.failed + 1
            end
            self.manifest:set(key, rec)
        end
        local sok, serr2 = self.manifest:save()
        if not sok then return self:_abort("storage", serr2) end
        if not results then
            local reason = reason_of(err)
            if err and (err.uncertain or reason == "offline" or reason == "reauth" or err.status == 429) then
                return self:_abort(err.uncertain and "uncertain" or (err.status == 429 and "rate_limited" or reason), err)
            end
        end
        self.state = "upload"
        return "continue"
    end
    return self.state == "done" and "done" or "aborted"
end

--- User stop: nothing in flight (steps are synchronous); drop uncreated tokens.
function Job:cancel()
    if self.state ~= "done" and self.state ~= "aborted" then
        return self:_abort("cancelled")
    end
end

--- Runs to completion synchronously (tests / non-UI use).
function Job:run()
    local r
    repeat r = self:step() until r ~= "continue"
    return r
end

return Job
