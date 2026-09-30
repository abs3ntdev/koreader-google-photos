local T = require("support")
local Photos = require("gphotos/photos")

local function photos(handler)
    local http = T.fake_http(Photos.ORIGIN, { ["POST /v1/mediaItems:batchCreate"] = handler })
    return Photos.new(http, function() return "AT" end), http
end
local items = { { upload_token = "t1", file_name = "a.png" }, { upload_token = "t2", file_name = "b.png" } }

T.test("photos: batchCreate result classification", function()
    local cases = {
        { "success by token", { newMediaItemResults = {
            { uploadToken = "t2", status = { message = "Success" }, mediaItem = { id = "m2" } },
            { uploadToken = "t1", status = { message = "Success" }, mediaItem = { id = "m1" } } } },
          { "ok:m1", "ok:m2" } },
        { "explicit error code => failed", { newMediaItemResults = {
            { uploadToken = "t1", status = { code = 3, message = "bad" } },
            { uploadToken = "t2", status = { code = 0 }, mediaItem = { id = "m2" } } } },
          { "failed", "ok:m2" } },
        { "success status w/o mediaItem => uncertain", { newMediaItemResults = {
            { uploadToken = "t1", status = { code = 0 } },
            { uploadToken = "t2", status = { code = 0 }, mediaItem = { id = "m2" } } } },
          { "uncertain", "ok:m2" } },
        { "mismatched token not index-fallback => uncertain", { newMediaItemResults = {
            { uploadToken = "zzz", mediaItem = { id = "mx" } },
            { uploadToken = "t2", mediaItem = { id = "m2" } } } },
          { "uncertain", "ok:m2" } },
        { "empty result object => uncertain", { newMediaItemResults = { {}, {} } }, { "uncertain", "uncertain" } },
        { "no tokens, full ordered list => index", { newMediaItemResults = {
            { mediaItem = { id = "m1" } }, { mediaItem = { id = "m2" } } } }, { "ok:m1", "ok:m2" } },
    }
    for _, c in ipairs(cases) do
        local p = photos(function() return T.json_res(200, c[2]) end)
        local out = p:batch_create("alb", items)
        for i, want in ipairs(c[3]) do
            local got = out[i].ok and ("ok:" .. out[i].media_id) or (out[i].uncertain and "uncertain" or "failed")
            T.eq(got, want, c[1] .. " item " .. i)
        end
    end
end)

T.test("photos: batchCreate transport outcomes", function()
    local p, http = photos(function() return nil, { kind = "network", message = "timeout" } end)
    local r, e = p:batch_create("alb", items); T.eq(r, nil); T.ok(e.uncertain)
    p = photos(function() return nil, { kind = "tls" } end)
    r, e = p:batch_create("alb", items); T.ok(not e.uncertain, "tls = never sent")
    p = photos(function() return T.json_res(500, {}) end)
    r, e = p:batch_create("alb", items); T.ok(e.uncertain)
    p = photos(function() return T.json_res(400, { error = { message = "bad" } }) end)
    r, e = p:batch_create("alb", items); T.ok(not e.uncertain)
end)

T.test("photos: request shape (albumId, raw upload headers, token only to Google)", function()
    local seen
    local p, http = photos(function(req) seen = req; return T.json_res(200, { newMediaItemResults = {} }) end)
    p:batch_create("alb", items)
    T.ok(seen.body:find('"albumId":"alb"')); T.eq(seen.headers.authorization, "Bearer AT")
    http.handlers["POST /v1/uploads"] = function(req)
        T.eq(req.headers["x-goog-upload-protocol"], "raw")
        T.eq(req.headers["x-goog-upload-content-type"], "image/png")
        T.eq(req.body_file, "/x/a b.png"); T.eq(req.headers["x-goog-upload-file-name"], "a_b.png")
        return { status = 200, headers = {}, body = "UPTOKEN" }
    end
    T.eq(p:upload("/x/a b.png", "a b.png", 3), "UPTOKEN")
    T.eq(Photos.mime_for("x.txt"), nil)
end)
