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
    ["ui/widget/container/widgetcontainer"] = { extend = function(_, cls)
        cls.__index = cls
        cls.new = function(c, o) o = setmetatable(o or {}, c); if o.init then o:init() end; return o end
        return cls
    end },
    ["libs/libkoreader-lfs"] = { attributes = function() return "directory" end, mkdir = function() return true end,
        symlinkattributes = function() return nil end },
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

local function new_plugin()
    shown, scheduled, online_queue = {}, {}, {}
    local registered
    local p = GooglePhotos:new{ ui = { menu = { registerToMainMenu = function(_, w) registered = w end } } }
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
