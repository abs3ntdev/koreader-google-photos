-- Loads the real main.lua entrypoint with mocked KOReader host modules.
-- Mock UIManager:close invokes dismiss_callback, matching upstream
-- InfoMessage:onCloseWidget (frontend/ui/widget/infomessage.lua).
local T = require("support")

local shown, scheduled, online_queue = {}, {}, {}
local function widget(kind)
    return function(_, o) o = o or {}; o.kind = kind; return o end
end
local UIManager = {}
function UIManager:show(w) shown[#shown + 1] = w end
function UIManager:close(w)
    for i, s in ipairs(shown) do if s == w then table.remove(shown, i) break end end
    if w.dismiss_callback then w.dismiss_callback() end
end
function UIManager:scheduleIn(_, fn) scheduled[#scheduled + 1] = fn end
function UIManager:unschedule(fn)
    for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end
end
local function run_scheduled()
    local n = 0
    while #scheduled > 0 and n < 1000 do table.remove(scheduled, 1)(); n = n + 1 end
end
local function last_info()
    for i = #shown, 1, -1 do if shown[i].kind == "info" then return shown[i].text end end
end

FS = {}
local data = T.tmpdir()
local mocks = {
    datastorage = { getSettingsDir = function() return data end, getFullDataDir = function() return data end,
        getDataDir = function() return data end },
    ["ui/widget/infomessage"] = { new = widget("info") },
    ["ui/widget/confirmbox"] = { new = widget("confirm") },
    ["ui/widget/buttondialog"] = { new = widget("buttons") },
    ["ui/widget/inputdialog"] = { new = widget("input") },
    ["ui/network/manager"] = { runWhenOnline = function(_, cb) online_queue[#online_queue + 1] = cb end },
    ["ui/uimanager"] = UIManager,
    -- Released fb:shot returns nothing; a write creates/overwrites the file.
    device = { screen = { shot = function(_, name)
        if name:find("RETFALSE") then return false, "EIO" end
        if not name:find("FAIL") then
            FS[name] = { mode = "file", size = 10, modification = (FS[name] and FS[name].modification or 0) + 1 }
        end
    end } },
    ["ui/widget/container/widgetcontainer"] = { extend = function(_, cls)
        cls.__index = cls
        cls.new = function(c, o) o = setmetatable(o or {}, c); if o.init then o:init() end; return o end
        return cls
    end },
    ["libs/libkoreader-lfs"] = { attributes = function() return "directory" end, mkdir = function() return true end,
        symlinkattributes = function(p) return FS[p] end },
    logger = { warn = function() end },
    gettext = setmetatable({}, { __call = function(_, s) return s end }),
    ["ffi/util"] = { template = function(s, ...)
        local a = { ... }
        return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
    end },
}
for k, v in pairs(mocks) do package.preload[k] = function() return v end end
local settings_data = {}
_G.G_reader_settings = { readSetting = function(_, k) return settings_data[k] end,
    saveSetting = function(_, k, v) settings_data[k] = v end }

local GooglePhotos = dofile((arg[0]:match("^(.*)/spec/run%.lua$") or "plugin") .. "/googlephotos.koplugin/main.lua")

local function new_plugin(ui)
    shown, scheduled, online_queue = {}, {}, {}
    local registered
    ui = ui or {}
    ui.menu = { registerToMainMenu = function(_, w) registered = w end }
    local p = GooglePhotos:new{ ui = ui }
    return p, registered
end

local function find_item(items, text)
    for _, it in ipairs(items) do
        local t = it.text or (it.text_func and it.text_func())
        if t == text then return it end
    end
end

T.test("main: registers Tools > Google Photos menu with expected entries", function()
    local p, registered = new_plugin()
    T.eq(registered, p)
    local menu = {}
    p:addToMainMenu(menu)
    T.eq(menu.googlephotos.sorting_hint, "tools")
    local items = menu.googlephotos.sub_item_table_func()
    T.ok(find_item(items, "Link Google account"))
    local up = find_item(items, "Upload screenshots folder")
    T.eq(up.enabled_func(), false, "upload disabled until linked")
end)

local function fake_job(steps)
    local j = { stats = { uploaded = 0, failed = 0, uncertain = 0, skipped = 0 }, state = "upload", n = 0, cancelled = 0 }
    function j:total() return 3 end
    function j:step() self.n = self.n + 1; return self.n < steps and "continue" or "done" end
    function j:cancel() self.cancelled = self.cancelled + 1 end
    return j
end

T.test("main: queued online callbacks start only one job; progress refresh does not cancel", function()
    local p = new_plugin()
    local job = fake_job(3)
    p.app = { newUploadJob = function() return job end,
        summarize = function() return "SUMMARY" end }
    p:uploadFolder("/shots")
    p.job = nil -- second tap before WiFi came up (job not started yet)
    p:uploadFolder("/shots")
    T.eq(#online_queue, 2)
    online_queue[1](); online_queue[2]()
    run_scheduled()
    T.eq(job.n, 3, "stepped once per tick, only one runner")
    T.eq(job.cancelled, 0, "programmatic progress close must not cancel")
    T.eq(last_info(), "SUMMARY")
    T.eq(p.job, nil)
end)

T.test("main: user dismissing progress stops job; actions blocked while running", function()
    local p = new_plugin()
    local job = fake_job(100)
    p.app = { newUploadJob = function() return job end, summarize = function(_, _, r) return "END " .. r end,
        brokerOrigin = function() return "https://b.example.com" end }
    p:uploadFolder("/shots"); online_queue[1]()
    T.eq(p.job, job)
    p:startPairing(); p:unlink(); p:resolveUncertain()
    T.ok(last_info():find("upload is running"))
    T.eq(#online_queue, 1, "no pairing/unlink queued while job active")
    local progress
    for _, w in ipairs(shown) do if w.kind == "info" and w.dismiss_callback then progress = w end end
    UIManager:close(progress) -- simulated user tap
    run_scheduled()
    T.eq(job.cancelled, 1)
    T.ok(job.n < 100)
    T.eq(p.job, nil)
end)

T.test("main: resolve uncertain surfaces save failure", function()
    local p = new_plugin()
    p.app = { uncertainCount = function() return 2 end,
        resolveUncertain = function() return nil, "EIO" end }
    p:resolveUncertain()
    local dlg = shown[#shown]
    T.eq(dlg.kind, "buttons")
    dlg.buttons[1][1].callback()
    T.ok(last_info():find("Could not save: EIO"))
end)

T.test("main: upload job creation error is shown, nothing queued", function()
    local p = new_plugin()
    p.app = { newUploadJob = function() return nil, "not linked" end }
    p:uploadFolder("/x")
    T.ok(last_info():find("Cannot upload: not linked"))
    T.eq(#online_queue, 0)
end)

-- Screenshot dialog -------------------------------------------------------
-- Screenshoter stand-in mirroring upstream onScreenshot's observable calls
-- (Screen:shot(name), then ButtonDialog:new{buttons, tap_close_callback}).
local ButtonDialog = mocks["ui/widget/buttondialog"]
local Screen = mocks.device.screen
local function screenshoter()
    local S = {}
    S.__index = S
    function S:onScreenshot(name)
        Screen:shot(name) -- released Screenshoter does not check the result
        local d = ButtonDialog:new{ buttons = {{{ text = "Delete" }, { text = "Set as book cover" }}, {{ text = "View" }}},
            tap_close_callback = function() end }
        d.onClose = function() d.closed = true end
        UIManager:show(d)
        return true
    end
    S.onKeyPressShoot = S.onScreenshot
    S.onTapDiagonal = S.onScreenshot
    S.onSwipeDiagonal = S.onScreenshot
    return setmetatable({}, S)
end
local function upload_row(d)
    for _, row in ipairs(d.buttons) do
        for _, b in ipairs(row) do if b.text == "Upload to Google Photos" then return b end end
    end
end
local function linked_app(job_for)
    local calls = {}
    return { isPaired = function() return true end, summarize = function(_, _, r) return "END " .. r end,
        newUploadFileJob = function(_, path) calls[#calls + 1] = path; return job_for(path) end }, calls
end

T.test("screenshot: dialog gets one upload row; tap uploads exactly that file after wifi", function()
    local shot = screenshoter()
    local p = new_plugin({ screenshot = shot })
    local job = fake_job(3)
    local app, calls = linked_app(function() return job end)
    p.app = app
    T.ok(shot:onTapDiagonal("/shots/a.png"))
    local d = shown[#shown]
    T.eq(#d.buttons, 3, "stock rows kept, one row added")
    T.eq(d.buttons[1][1].text, "Delete")
    upload_row(d).callback()
    T.ok(d.closed)
    T.eq(calls[1], "/shots/a.png")
    T.eq(#online_queue, 1); T.eq(job.n, 0, "no upload before online")
    online_queue[1](); run_scheduled()
    T.eq(job.n, 3); T.eq(last_info(), "END done")
    T.eq(Screen.shot ~= nil and rawget(Screen, "shot") ~= nil, true)
    T.eq(rawget(ButtonDialog, "new") ~= nil, true)
end)

T.test("screenshot: failed capture and unrelated dialogs are untouched; hooks restored", function()
    local shot = screenshoter()
    local p = new_plugin({ screenshot = shot })
    local orig_shot, orig_new = Screen.shot, ButtonDialog.new
    FS["/shots/FAIL_stale.png"] = { mode = "file", size = 5, modification = 1 }
    for _, name in ipairs({ "/shots/FAIL.png", "/shots/FAIL_stale.png", "/shots/RETFALSE.png" }) do
        shot:onScreenshot(name)
        T.eq(upload_row(shown[#shown]), nil, name .. ": silent/explicit failure or stale file must not get a button")
    end
    T.eq(Screen.shot, orig_shot); T.eq(ButtonDialog.new, orig_new)
    p:resolveUncertain() -- unrelated ButtonDialog outside a screenshot
    local other = ButtonDialog:new{ buttons = {{{ text = "x" }}}, tap_close_callback = function() end }
    T.eq(upload_row(other), nil)
end)

T.test("screenshot: reloading plugin does not double-wrap and routes to newest instance", function()
    local shot = screenshoter()
    local ui = { screenshot = shot }
    local p1 = new_plugin(ui)
    local wrapped = shot.onScreenshot
    local p2 = new_plugin(ui)
    T.eq(shot.onScreenshot, wrapped, "wrapped once")
    local job = fake_job(1)
    p2.app = linked_app(function() return job end)
    p1.app = { isPaired = function() error("stale instance used") end }
    shot:onScreenshot("/shots/b.png")
    local d = shown[#shown]
    T.eq(#d.buttons, 3)
    upload_row(d).callback()
    T.eq(#online_queue, 1)
    p2:onCloseWidget()
    shot:onScreenshot("/shots/c.png")
    T.eq(#shown[#shown].buttons, 2, "no row once owner closed")
end)

T.test("screenshot: unlinked, busy and invalid-file taps queue nothing", function()
    local shot = screenshoter()
    local p = new_plugin({ screenshot = shot })
    p.app = { isPaired = function() return false end }
    shot:onScreenshot("/shots/d.png"); upload_row(shown[#shown]).callback()
    T.ok(last_info():find("Link your Google account first"))
    p.app = linked_app(function() return nil, "not a regular file" end)
    shot:onScreenshot("/shots/e.png"); upload_row(shown[#shown]).callback()
    T.ok(last_info():find("Cannot upload: not a regular file"))
    p.job = fake_job(1)
    shot:onScreenshot("/shots/f.png"); upload_row(shown[#shown]).callback()
    T.ok(last_info():find("upload is running"))
    T.eq(#online_queue, 0)
end)

T.test("screenshot: stale online callback does not start a second job", function()
    local shot = screenshoter()
    local p = new_plugin({ screenshot = shot })
    local j1, j2 = fake_job(2), fake_job(2)
    local jobs = { j1, j2 }
    p.app = linked_app(function() return table.remove(jobs, 1) end)
    shot:onScreenshot("/shots/g.png"); upload_row(shown[#shown]).callback()
    shot:onScreenshot("/shots/h.png"); upload_row(shown[#shown]).callback()
    online_queue[1]()
    online_queue[2]() -- WiFi came up late; first job still running
    run_scheduled()
    T.eq(j1.n, 2); T.eq(j2.n, 0)
end)

T.test("screenshot: throwing screenshot handler still restores Screen.shot and ButtonDialog.new", function()
    local shot = screenshoter()
    new_plugin({ screenshot = shot })
    local orig_shot, orig_new = rawget(Screen, "shot"), rawget(ButtonDialog, "new")
    local mt = getmetatable(shot)
    local keep = mt.onScreenshot
    -- handler wrapped at init time, so throw from inside the dialog constructor instead
    local real_new = orig_new
    ButtonDialog.new = function() error("boom") end
    local ok, err = pcall(shot.onScreenshot, shot, "/shots/t.png")
    T.eq(ok, false); T.ok(tostring(err):find("boom"))
    T.eq(rawget(Screen, "shot"), orig_shot)
    ButtonDialog.new = real_new
    T.eq(mt.onScreenshot, keep)
end)

T.test("screenshot: queued WiFi callback does nothing after plugin closed", function()
    local shot = screenshoter()
    local p = new_plugin({ screenshot = shot })
    local job = fake_job(2)
    p.app = linked_app(function() return job end)
    shot:onScreenshot("/shots/z.png"); upload_row(shown[#shown]).callback()
    p:onCloseWidget()
    online_queue[1](); run_scheduled()
    T.eq(job.n, 0); T.eq(p.job, nil)
end)
