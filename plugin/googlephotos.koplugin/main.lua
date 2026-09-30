--[[--
Google Photos uploader for KOReader.

Menu: Tools > Google Photos
  * Link Google account (QR phone pairing via broker)
  * Upload screenshots folder
  * Upload a folder... (PathChooser)
  * Resolve uncertain uploads
  * Status / Unlink
Uploads are manual, one folder level, never delete or modify source files.

@module koplugin.GooglePhotos
--]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local App = require("gphotos/app")

local GooglePhotos = WidgetContainer:extend{
    name = "googlephotos",
    is_doc_only = false,
}

function GooglePhotos:init()
    self.app = App.new{
        data_dir = DataStorage:getSettingsDir() .. "/googlephotos",
        settings = G_reader_settings,
        lfs = lfs,
        now = os.time,
        net_deps = function() return App.default_net_deps() end,
    }
    self.ui.menu:registerToMainMenu(self)
end

local function info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

function GooglePhotos:addToMainMenu(menu_items)
    menu_items.googlephotos = {
        text = _("Google Photos"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:getSubMenu() end,
    }
end

function GooglePhotos:getSubMenu()
    return {
        {
            text_func = function()
                return self.app:isPaired() and _("Relink Google account") or _("Link Google account")
            end,
            callback = function() self:startPairing() end,
        },
        {
            text = _("Upload screenshots folder"),
            enabled_func = function() return self.app:isPaired() end,
            callback = function() self:uploadFolder(self:getScreenshotDir()) end,
        },
        {
            text = _("Upload a folder…"),
            enabled_func = function() return self.app:isPaired() end,
            callback = function() self:chooseFolder() end,
        },
        {
            text = _("Resolve uncertain uploads"),
            enabled_func = function() return self.app:isPaired() end,
            callback = function() self:resolveUncertain() end,
        },
        {
            text = _("Status"),
            callback = function() info(self.app:statusText()) end,
        },
        {
            text = _("Broker server URL"),
            keep_menu_open = true,
            callback = function() self:editBrokerOrigin() end,
        },
        {
            text = _("Unlink this device"),
            enabled_func = function() return self.app:hasCredentialFile() end,
            callback = function() self:unlink() end,
        },
    }
end

-- Mirrors upstream Screenshoter:getScreenshotDir() (frontend/ui/widget/screenshoter.lua).
function GooglePhotos:getScreenshotDir()
    local shot = self.ui and self.ui.screenshot
    if shot and shot.getScreenshotDir then return shot:getScreenshotDir() end
    local dir = G_reader_settings:readSetting("screenshot_dir")
    if dir then return (dir:gsub("/$", "")) end
    return DataStorage:getFullDataDir() .. "/screenshots"
end

function GooglePhotos:editBrokerOrigin()
    if self:busy() then return end
    local dialog
    dialog = InputDialog:new{
        title = _("Broker server URL (https://host[:port])"),
        input = self.app:brokerOrigin() or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local ok, err = self.app:setBrokerOrigin(dialog:getInputText())
                UIManager:close(dialog)
                info(ok and _("Saved. Link your account again if the server changed.")
                    or T(_("Invalid URL: %1"), err))
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GooglePhotos:chooseFolder()
    local PathChooser = require("ui/widget/pathchooser")
    local chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        show_files = true,
        path = self.app:lastFolder() or self:getScreenshotDir(),
        onConfirm = function(path)
            self.app:setLastFolder(path)
            self:uploadFolder(path)
        end,
    }
    UIManager:show(chooser)
end

-- Pairing ------------------------------------------------------------------

function GooglePhotos:startPairing()
    if self:busy() then return end
    if not self.app:brokerOrigin() then
        info(_("Set the broker server URL first."))
        return
    end
    NetworkMgr:runWhenOnline(function() self:_doPairing() end)
end

function GooglePhotos:_doPairing()
    local QRMessage = require("ui/widget/qrmessage")
    local qr, code_box
    local pairing
    local function close_all()
        if qr then UIManager:close(qr); qr = nil end
        if code_box then UIManager:close(code_box); code_box = nil end
    end
    local poll
    if self.pairing then
        -- Only one active pairing: cancel the previous flow before starting anew.
        self.pairing:cancel()
        if self.pairing_poll then UIManager:unschedule(self.pairing_poll) end
    end
    pairing = self.app:newPairing{
        on_code = function(code)
            close_all()
            code_box = ConfirmBox:new{
                text = T(_("Confirmation code:\n\n%1\n\nDoes this match the code shown on your phone?"), code),
                ok_text = _("Codes match"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    code_box = nil
                    local ok, err = pairing:confirm()
                    if not ok and err then info(T(_("Confirmation failed: %1"), err)) end
                    if ok then info(_("Confirmed. Finishing on the phone…"), 3) end
                end,
                cancel_callback = function()
                    code_box = nil
                    pairing:cancel()
                end,
            }
            UIManager:show(code_box)
        end,
        on_waiting = function(status)
            if status == "storage_error" then
                logger.warn("googlephotos: could not save credential, will retry")
            end
        end,
        on_complete = function()
            close_all()
            UIManager:unschedule(poll)
            info(_("Google Photos linked."))
        end,
        on_fail = function(code)
            close_all()
            UIManager:unschedule(poll)
            info(T(_("Linking failed: %1"), code))
        end,
    }
    local p = pairing:start()
    if not p then return end
    self.pairing = pairing
    qr = QRMessage:new{
        text = p.pair_url,
        width = math.floor(require("device").screen:getWidth() * 0.8),
        height = math.floor(require("device").screen:getWidth() * 0.8),
        dismiss_callback = function()
            qr = nil
            -- Dismissing the QR does not cancel: polling continues until a code arrives.
        end,
    }
    UIManager:show(qr)
    poll = function()
        if pairing:poll_once() == "continue" then
            UIManager:scheduleIn(p.poll_interval, poll)
        elseif self.pairing == pairing then
            self.pairing, self.pairing_poll = nil, nil
        end
    end
    self.pairing_poll = poll
    UIManager:scheduleIn(p.poll_interval, poll)
end

-- Upload -------------------------------------------------------------------

function GooglePhotos:busy()
    if self.job then info(_("An upload is running. Wait for it to finish or stop it first.")); return true end
    return false
end

function GooglePhotos:uploadFolder(dir)
    if self:busy() then return end
    local job, err = self.app:newUploadJob(dir)
    if not job then info(T(_("Cannot upload: %1"), err)); return end
    if job:total() == 0 then
        info(T(_("Nothing new to upload (%1 already handled)."), job.stats.skipped))
        return
    end
    NetworkMgr:runWhenOnline(function() self:_runJob(job) end)
end

function GooglePhotos:_runJob(job)
    -- runWhenOnline may queue callbacks until WiFi is up: only one ledger writer.
    if self.job then return end
    self.job = job
    local progress
    local cancelled = false
    -- NOTE: upstream InfoMessage:onCloseWidget() calls dismiss_callback on ANY
    -- close, including programmatic UIManager:close, so we mark our own closes.
    local closing_ourselves = false
    local function close_progress()
        if progress then
            closing_ourselves = true
            UIManager:close(progress)
            closing_ourselves = false
            progress = nil
        end
    end
    local function show_progress()
        close_progress()
        progress = InfoMessage:new{
            text = T(_("Uploading to Google Photos…\n%1 / %2 uploaded, %3 failed\n\nTap to stop after current file."),
                job.stats.uploaded, job:total(), job.stats.failed),
            dismiss_callback = function()
                if not closing_ourselves then progress = nil; cancelled = true end
            end,
        }
        UIManager:show(progress)
    end
    show_progress()
    local tick
    tick = function()
        local r = cancelled and "cancelled" or job:step()
        if r == "continue" then
            if progress and job.state == "upload" then show_progress() end
            UIManager:scheduleIn(0.05, tick)
            return
        end
        if cancelled then job:cancel() end
        close_progress()
        self.job = nil
        info(self.app:summarize(job, r))
    end
    UIManager:scheduleIn(0.05, tick)
end

function GooglePhotos:resolveUncertain()
    if self:busy() then return end
    local n, list = self.app:uncertainCount()
    if not n then info(list); return end
    if n == 0 then info(_("No uncertain uploads.")); return end
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("%1 file(s) may or may not have been added to Google Photos (connection lost during creation). Check the album on your phone, then choose:"), n),
        buttons = {
            {{ text = _("They are in Google Photos"), callback = function()
                UIManager:close(dialog)
                local ok, err = self.app:resolveUncertain("done")
                info(ok and _("Marked as uploaded.") or T(_("Could not save: %1"), err))
            end }},
            {{ text = _("Upload again (may duplicate)"), callback = function()
                UIManager:close(dialog)
                local ok, err = self.app:resolveUncertain("retry")
                info(ok and _("Will retry on next upload.") or T(_("Could not save: %1"), err))
            end }},
            {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

function GooglePhotos:unlink()
    if self:busy() then return end
    UIManager:show(ConfirmBox:new{
        text = _("Unlink this reader from Google Photos? Upload history is kept."),
        ok_text = _("Unlink"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function()
                local ok, err = self.app:unlink()
                info(ok and _("Unlinked.") or T(_("Unlink failed, credential kept so you can retry: %1"), err))
            end)
        end,
    })
end

return GooglePhotos
