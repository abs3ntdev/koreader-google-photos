--[[--
Google Photos Library API client (app-created data only).
  POST /v1/uploads            raw bytes -> upload token (text body)
  POST /v1/mediaItems:batchCreate  (max 50 items)
  POST /v1/albums              create the app-owned album
Access tokens come from the broker; sent only to photoslibrary.googleapis.com.
--]]

local json = require("gphotos/json")

local Photos = {}
Photos.__index = Photos

Photos.ORIGIN = "https://photoslibrary.googleapis.com"
Photos.MAX_BATCH = 50

local MIME = {
    jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png", gif = "image/gif",
    webp = "image/webp", bmp = "image/bmp", tif = "image/tiff", tiff = "image/tiff",
    heic = "image/heic",
}

function Photos.mime_for(name)
    local ext = name:match("%.([%w]+)$")
    return ext and MIME[ext:lower()]
end

--- http: Http client bound to Photos.ORIGIN. get_token(): returns access token or nil, err.
function Photos.new(http, get_token)
    return setmetatable({ http = http, get_token = get_token }, Photos)
end

local function classify(res)
    local s = res.status
    local msg = type(res.json) == "table" and type(res.json.error) == "table" and res.json.error.message
    return { code = "http_" .. s, status = s, message = msg,
        retryable = s == 429 or s >= 500, token_rejected = s == 401 }
end

function Photos:_auth_headers(extra)
    local token, err = self.get_token()
    if not token then return nil, err end
    local h = { authorization = "Bearer " .. token }
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
end

--- Creates an album. Returns album id or nil, err.
function Photos:create_album(title)
    local h, terr = self:_auth_headers({ ["content-type"] = "application/json" })
    if not h then return nil, terr end
    local res, err = self.http:request{ method = "POST", path = "/v1/albums", headers = h,
        body = json.encode({ album = { title = title } }) }
    if not res then return nil, { code = "network", retryable = true, detail = err } end
    if res.status ~= 200 then return nil, classify(res) end
    local id = type(res.json) == "table" and res.json.id
    if type(id) ~= "string" or id == "" then return nil, { code = "bad_response" } end
    return id
end

--- Uploads bytes of a file. Returns upload token or nil, err.
function Photos:upload(path, name, size)
    local mime = Photos.mime_for(name)
    if not mime then return nil, { code = "unsupported_type" } end
    local h, terr = self:_auth_headers({
        ["content-type"] = "application/octet-stream",
        ["x-goog-upload-content-type"] = mime,
        ["x-goog-upload-protocol"] = "raw",
        ["x-goog-upload-file-name"] = name:gsub("[^%w%._%-]", "_"),
    })
    if not h then return nil, terr end
    local res, err = self.http:request{ method = "POST", path = "/v1/uploads", headers = h,
        body_file = path, body_size = size, max_response = 64 * 1024 }
    if not res then return nil, { code = "network", retryable = true, detail = err } end
    if res.status ~= 200 then return nil, classify(res) end
    local token = res.body
    if type(token) ~= "string" or token == "" or #token > 16384 then return nil, { code = "bad_response" } end
    return token
end

--- items: { {upload_token, file_name} }. Returns results aligned by index:
-- { {ok=true, media_id} | {ok=false, message} } or nil, err.
-- err.uncertain = true means the request may have been applied (response lost).
function Photos:batch_create(album_id, items)
    assert(#items >= 1 and #items <= Photos.MAX_BATCH)
    local h, terr = self:_auth_headers({ ["content-type"] = "application/json" })
    if not h then return nil, terr end
    local new_items = json.array({})
    for i, it in ipairs(items) do
        new_items[i] = { simpleMediaItem = { uploadToken = it.upload_token, fileName = it.file_name } }
    end
    local res, err = self.http:request{ method = "POST", path = "/v1/mediaItems:batchCreate",
        headers = h, body = json.encode({ albumId = album_id, newMediaItems = new_items }) }
    if not res then
        -- Request bytes may have reached Google: outcome unknown.
        local pre_send = err and (err.kind == "tls" or err.kind == "usage")
        return nil, { code = "network", uncertain = not pre_send, retryable = pre_send, detail = err }
    end
    if res.status ~= 200 and res.status ~= 207 then
        local e = classify(res)
        -- 5xx may have partially applied; treat as uncertain. 4xx did not create.
        e.uncertain = res.status >= 500
        return nil, e
    end
    local results = type(res.json) == "table" and res.json.newMediaItemResults
    if type(results) ~= "table" then return nil, { code = "bad_response", uncertain = true } end
    local by_token, any_token = {}, false
    for _, r in ipairs(results) do
        if type(r) == "table" and type(r.uploadToken) == "string" then
            by_token[r.uploadToken] = r
            any_token = true
        end
    end
    local out = {}
    for i, it in ipairs(items) do
        local r
        if any_token then
            r = by_token[it.upload_token]
        elseif #results == #items then
            r = results[i] -- documented order fallback only when no tokens echoed
        end
        local st = type(r) == "table" and r.status or nil
        local code = type(st) == "table" and tonumber(st.code) or nil
        local media = type(r) == "table" and r.mediaItem or nil
        if type(media) == "table" and type(media.id) == "string" and media.id ~= ""
            and (code == nil or code == 0) then
            out[i] = { ok = true, media_id = media.id }
        elseif code and code ~= 0 then
            -- explicit per-item error status: definitely not created
            out[i] = { ok = false, message = type(st.message) == "string" and st.message or ("status " .. code) }
        else
            -- missing / malformed result: outcome unknown
            out[i] = { ok = false, uncertain = true, message = "unrecognized result" }
        end
    end
    return out
end

return Photos
