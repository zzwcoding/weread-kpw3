-- WiFi-on-demand coverage: runOnlineTask defers to NetworkMgr:runWhenOnline
-- when offline, afterWifiAction releases session-raised WiFi, the downloader
-- releases WiFi when the queue goes idle, and QR login releases it when the
-- login session ends.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

-- Controllable NetworkMgr fake. runWhenOnline runs the callback immediately
-- while online and captures it while offline (as KOReader does once WiFi is
-- connected); afterWifiAction only counts calls.
local network_mgr = {
    online = true,
    deferred = nil,
    run_calls = 0,
    after_calls = 0,
}
function network_mgr:runWhenOnline(callback)
    self.run_calls = self.run_calls + 1
    if self.online then
        callback()
    else
        self.deferred = callback
    end
end
function network_mgr:afterWifiAction()
    self.after_calls = self.after_calls + 1
end
package.preload["ui/network/manager"] = function() return network_mgr end

local scheduled = {}
local shown = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
        show = function(_self, widget) shown[#shown + 1] = widget end,
        close = function() end,
    }
end
local function flush_scheduled()
    local queue = scheduled
    scheduled = {}
    for _i, callback in ipairs(queue) do callback() end
end

package.preload["ui/bidi"] = function()
    return { dirpath = tostring }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["ui/widget/menu"] = function() return {} end
package.preload["ui/widget/qrmessage"] = function() return {} end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
local fake_logger = {
    info = function() end,
    warn = function() end,
    err = function() end,
}
fake_logger.scoped = function() return fake_logger end
package.preload["logger"] = function() return fake_logger end
package.preload["weread.lib.logger"] = function() return fake_logger end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
        log_error = tostring,
        display_error = tostring,
        unpack_args = function(args) return unpack(args) end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.cookie"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["weread.ui.download_dialog"] = function()
    return { new = function(_self, options) return options end }
end

-- Part 1: runOnlineTask goes through NetworkMgr:runWhenOnline.
local Common = require("weread.ui.common")
local host = {}
for key, value in pairs(Common) do host[key] = value end

local ran = 0
local accepted = host:runOnlineTask("Test", function() ran = ran + 1 end)
expect(accepted == true, "online task was not accepted")
expect(network_mgr.run_calls == 1, "runWhenOnline was not used")
flush_scheduled()
expect(ran == 1, "online task did not run")

network_mgr.online = false
local offline_ran = 0
accepted = host:runOnlineTask("Deferred", function() offline_ran = offline_ran + 1 end)
expect(accepted == true, "deferred task should be accepted, not failed")
expect(offline_ran == 0 and network_mgr.deferred ~= nil,
    "offline task was not deferred until WiFi connects")
network_mgr.online = true
network_mgr.deferred()
flush_scheduled()
expect(offline_ran == 1, "deferred task did not run after connecting")

local before_after = network_mgr.after_calls
host:afterWifiAction()
expect(network_mgr.after_calls == before_after + 1,
    "afterWifiAction was not forwarded to NetworkMgr")

-- A failing task is reported, not propagated.
accepted = host:runOnlineTask("Boom", function() error("boom") end)
flush_scheduled()
expect(accepted == true, "failing task changed the accepted result")

-- Part 2: fallback when ui/network/manager is unavailable.
package.loaded["ui/network/manager"] = nil
package.preload["ui/network/manager"] = function() error("module missing") end
host.isNetworkOnline = function() return false end
local offline_shown = #shown
accepted = host:runOnlineTask("Legacy", function() end)
expect(accepted == false, "fallback offline task should report failure")
expect(#shown > offline_shown, "fallback offline task did not notify the user")
host.isNetworkOnline = function() return true end
local legacy_ran = 0
accepted = host:runOnlineTask("Legacy", function() legacy_ran = legacy_ran + 1 end)
flush_scheduled()
expect(accepted == true and legacy_ran == 1,
    "fallback online task did not run")
host:afterWifiAction() -- must not raise without NetworkMgr

-- Part 3: the downloader releases WiFi once the queue is fully idle.
local Downloader = require("weread.lib.downloader")
local wifi_released = 0
local downloader = Downloader:new{
    after_wifi_action = function() wifi_released = wifi_released + 1 end,
}
local job = { book = {}, chapters = {} }
downloader._active_job = job
downloader:_finishJob(job)
expect(downloader._active_job == nil, "active job was not cleared")
expect(wifi_released == 1, "idle downloader did not release WiFi")

-- A follow-up job keeps the session (and WiFi) alive.
local pending_job = { book = {}, chapters = {} }
downloader._active_job = pending_job
downloader._pending_start = {
    book = {},
    chapters = {},
    suffix = "book",
    options = {},
}
downloader:_finishJob(pending_job)
expect(wifi_released == 1,
    "downloader released WiFi while a follow-up job was scheduled")
expect(downloader._scheduled_start ~= nil,
    "follow-up download was not scheduled")
downloader._scheduled_start = nil

-- Without the callback the finish path stays silent.
local plain = Downloader:new{}
local plain_job = { book = {}, chapters = {} }
plain._active_job = plain_job
plain:_finishJob(plain_job)
expect(plain._active_job == nil, "plain downloader job was not cleared")

-- Part 4: QR login releases WiFi when the session ends.
local QRLogin = require("weread.lib.qr_login")
local login_released = 0
local login_infos = 0
local login_offline = 0
local login_tasks = {}
local login_host = {
    afterWifiAction = function() login_released = login_released + 1 end,
    showBusy = function() end,
    closeBusy = function() end,
    showInfo = function() login_infos = login_infos + 1 end,
    showTransientInfo = function() end,
    showOffline = function() login_offline = login_offline + 1 end,
    isNetworkOnline = function() return false end,
    refreshLoginMenu = function() end,
    runOnlineTask = function(_self, label, callback)
        login_tasks[#login_tasks + 1] = { label = label, callback = callback }
        return true
    end,
}
local qr = QRLogin:new(login_host, {}, {})

qr:cancel()
expect(login_released == 0, "cancel without a session released WiFi")

qr:start()
expect(#login_tasks == 1, "login did not schedule its first network task")
expect(login_offline == 0,
    "login must defer connectivity to runOnlineTask instead of pre-checking")
qr._begin_protocol = function() error("no route to host") end
login_tasks[1].callback()
expect(login_infos == 1, "login failure was not reported")
expect(login_released == 1, "failed login session did not release WiFi")
expect(qr.started_at == nil, "failed login session was not reset")

-- Successful completion also ends the session.
qr._complete_protocol = function() return { name = "Tester" } end
qr.started_at = os.time()
qr:_complete({ succeed = true }, qr.generation)
expect(#login_tasks == 2, "login completion did not schedule its task")
login_tasks[2].callback()
expect(login_released == 2, "successful login did not release WiFi")
expect(qr.started_at == nil, "successful login did not clear the session")

print(("wifi_on_demand_spec: %d checks"):format(checks))
