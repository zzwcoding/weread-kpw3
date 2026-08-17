-- WiFi-on-demand coverage: runOnlineTask defers to NetworkMgr:runWhenOnline
-- when offline, afterWifiAction releases session-raised WiFi, the downloader
-- releases WiFi when the queue goes idle, QR login validates the login page
-- strictly and retries transient early-connection failures without releasing
-- WiFi, and the bookshelf refresh retries an early-connection failure once.

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
local last_delay = nil
local shown = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = callback
            last_delay = delay
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
package.preload["ui/widget/buttondialog"] = function() return {} end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["ui/widget/menu"] = function() return {} end
package.preload["ui/widget/progressbardialog"] = function() return {} end
package.preload["ui/widget/qrmessage"] = function() return {} end
package.preload["ui/widget/textviewer"] = function() return {} end
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
        file_exists = function() return false end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.cookie"] = function()
    return {
        merge_set_cookie = function(cookies, set_cookie)
            cookies = cookies or {}
            cookies[#cookies + 1] = set_cookie
            return cookies
        end,
        to_header = function(cookies)
            return table.concat(cookies or {}, "; ")
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = function() return {} end
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
expect(last_delay == 0.1, "online task was delayed as if WiFi was raised")
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

-- A task accepted while the link is down lets a just-raised connection
-- settle before its first request.
host.isNetworkConnected = function() return false end
network_mgr.online = false
expect(host:runOnlineTask("Settle", function() end) == true,
    "settle task was not accepted")
network_mgr.online = true
network_mgr.deferred()
expect(last_delay == 1.5,
    "task on a just-raised link did not wait for WAN to settle")
flush_scheduled()
host.isNetworkConnected = nil
for key, value in pairs(Common) do
    if host[key] == nil then host[key] = value end
end

local before_after = network_mgr.after_calls
host:afterWifiAction()
expect(network_mgr.after_calls == before_after + 1,
    "afterWifiAction was not forwarded to NetworkMgr")

-- A failing task is reported, not propagated.
accepted = host:runOnlineTask("Boom", function() error("boom") end)
flush_scheduled()
expect(accepted == true, "failing task changed the accepted result")

-- Part 1b: early-connection classifier and single retry helper.
expect(host:isEarlyConnectionError("HTTP nil content_type=unknown"),
    "HTTP nil was not classified as an early-connection error")
expect(host:isEarlyConnectionError("socket: wantread"),
    "wantread was not classified as an early-connection error")
expect(host:isEarlyConnectionError("connection timeout"),
    "timeout was not classified as an early-connection error")
expect(not host:isEarlyConnectionError("HTTP 401 content_type=json"),
    "HTTP 401 must not be classified as an early-connection error")
expect(not host:isEarlyConnectionError("WeRead API key is not configured"),
    "configuration errors must not be classified as early-connection errors")

local retry_attempts = 0
local retry_ok, retry_result = host:callWithConnectionRetry(function()
    retry_attempts = retry_attempts + 1
    if retry_attempts == 1 then error("wantread") end
    return "shelf-data"
end)
expect(retry_ok == true and retry_result == "shelf-data" and retry_attempts == 2,
    "early-connection failure was not retried once")
local fail_attempts = 0
local fail_ok, fail_err = host:callWithConnectionRetry(function()
    fail_attempts = fail_attempts + 1
    error("HTTP 401 content_type=json")
end)
expect(fail_ok == false and fail_attempts == 1,
    "deterministic HTTP failure was retried")
expect(tostring(fail_err):find("HTTP 401", 1, true) ~= nil,
    "deterministic failure did not propagate the original error")

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
scheduled = {} -- drop the captured follow-up start callback

-- Without the callback the finish path stays silent.
local plain = Downloader:new{}
local plain_job = { book = {}, chapters = {} }
plain._active_job = plain_job
plain:_finishJob(plain_job)
expect(plain._active_job == nil, "plain downloader job was not cleared")

-- Part 4: QR login strict begin validation, transient retries, WiFi release.
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

-- Transient begin failures retry without ending the session (WiFi stays up).
qr._begin_protocol = function() error("no route to host") end
qr:start()
expect(#login_tasks == 1, "login did not schedule its first network task")
expect(login_offline == 0,
    "login must defer connectivity to runOnlineTask instead of pre-checking")
login_tasks[1].callback() -- attempt 1
expect(login_released == 0 and login_infos == 0,
    "first transient begin failure ended the login session")
expect(#scheduled == 1, "transient begin failure did not schedule a retry")
flush_scheduled() -- attempt 2
expect(login_released == 0 and login_infos == 0,
    "second transient begin failure ended the login session too early")
expect(#scheduled == 1, "second begin failure did not schedule a final retry")
flush_scheduled() -- attempt 3, exhausted
expect(login_infos == 1, "exhausted begin retries did not report the failure")
expect(login_released == 1, "exhausted begin retries did not release WiFi")
expect(qr.started_at == nil, "failed login session was not reset")

-- Cancelling while a retry is pending releases WiFi and disarms the retry.
qr:start()
login_tasks[#login_tasks].callback() -- attempt 1, retry pending
expect(#scheduled == 1, "retried login did not schedule its retry")
qr:cancel()
expect(login_released == 2, "cancelling a retrying login did not release WiFi")
flush_scheduled()
expect(login_infos == 1, "stale begin retry ran after the login was cancelled")

-- A deterministic begin failure (HTTP 4xx) does not retry.
qr._begin_protocol = function()
    error("Unable to open WeRead login page (HTTP 403)")
end
qr:start()
login_tasks[#login_tasks].callback()
expect(#scheduled == 0, "deterministic begin failure was retried")
expect(login_infos == 2 and login_released == 3,
    "deterministic begin failure did not fail the session immediately")

-- Login page validation: HTTP 200 + a UUID-shaped uid passes even when the
-- page sets no cookies (the real WeRead login page never sets any).
local function make_login_client(page_headers, uid_data, uid_headers, uid_status)
    return {
        request_follow = function() return "page", 200, page_headers end,
        request = function()
            if uid_data == nil then
                return nil, nil, uid_headers or {}, uid_status or "wantread"
            end
            return "json", 200, uid_headers or {}, "OK"
        end,
        decode_http_json = function() return uid_data end,
    }
end
local VALID_UID = "5d124ff5-1234-4abc-8def-0123456789ab"
local qr_no_cookies = QRLogin:new(login_host,
    make_login_client({}, { uid = VALID_UID }), {})
local ok_no_cookies, no_cookies_uid = pcall(function()
    return qr_no_cookies:_begin_protocol()
end)
expect(ok_no_cookies and no_cookies_uid == VALID_UID,
    "cookie-less login page with a valid uid was rejected")

-- A uid that is not UUID-shaped must not reach the poll stage: it comes from
-- an error/captive page and would fail polling with HTTP 401.
local qr_bad_uid = QRLogin:new(login_host,
    make_login_client({ ["set-cookie"] = "wr_gid=1" }, { uid = "u1" }), {})
local ok_bad_uid, bad_uid_err = pcall(function()
    return qr_bad_uid:_begin_protocol()
end)
expect(ok_bad_uid == false
    and tostring(bad_uid_err):find("malformed login UID", 1, true) ~= nil,
    "malformed login uid was accepted")

-- Transport failure on getLoginUid surfaces as a retryable error, not a Lua
-- indexing error.
local qr_transport = QRLogin:new(login_host,
    make_login_client({ ["set-cookie"] = "wr_gid=1" }, nil), {})
local ok_transport, transport_err = pcall(function()
    return qr_transport:_begin_protocol()
end)
expect(ok_transport == false
    and tostring(transport_err):find("wantread", 1, true) ~= nil,
    "transport failure on getLoginUid was not reported as a request error")

-- A valid page with cookies and a uid passes validation.
local qr_good = QRLogin:new(login_host,
    make_login_client({ ["set-cookie"] = "wr_gid=1" }, { uid = VALID_UID }), {})
local ok_good, good_uid = pcall(function()
    return qr_good:_begin_protocol()
end)
expect(ok_good and good_uid == VALID_UID,
    "valid login page did not produce a uid")

-- Successful completion also ends the session.
qr_good._complete_protocol = function() return { name = "Tester" } end
qr_good.started_at = os.time()
qr_good:_complete({ succeed = true }, qr_good.generation)
login_tasks[#login_tasks].callback()
expect(login_released == 4, "successful login did not release WiFi")
expect(qr_good.started_at == nil, "successful login did not clear the session")

-- Part 5: bookshelf refresh retries an early-connection failure once.
local shelf_view_data
package.preload["weread.ui.library_view"] = function()
    return {
        show = function(data)
            shelf_view_data = data
            return { id = "shelf" }
        end,
    }
end
local Library = require("weread.ui.library")
local shelf_infos = 0
local shelf_host = {
    settings = {
        get = function(_self, key, default)
            if key == "shelf" then return {} end
            if key == "books" then return {} end
            return default
        end,
        set = function() end,
        flush = function() end,
    },
    library_db = nil,
    requireLogin = function() return true end,
    showBusy = function() end,
    closeBusy = function() end,
    showInfo = function() shelf_infos = shelf_infos + 1 end,
    runOnlineTask = function(_self, _label, callback)
        callback()
        return true
    end,
    shelfSortSummary = function() return "" end,
    shelfFilterSummary = function() return "" end,
    bookMatchesFilters = function() return true end,
    isBookDownloaded = function() return false end,
}
for key, value in pairs(Common) do
    if shelf_host[key] == nil then shelf_host[key] = value end
end
for key, value in pairs(Library) do
    if shelf_host[key] == nil then shelf_host[key] = value end
end

local shelf_attempts = 0
shelf_host.client = {
    get_shelf = function()
        shelf_attempts = shelf_attempts + 1
        if shelf_attempts == 1 then error("HTTP nil content_type=unknown") end
        return { books = { { book_id = "b1", title = "Book" } } }
    end,
}
shelf_host:refreshBookshelf()
expect(shelf_attempts == 2,
    "early-connection shelf failure was not retried")
expect(shelf_infos == 0 and shelf_view_data ~= nil
    and #shelf_view_data.books == 1,
    "retried shelf refresh did not show the bookshelf")

shelf_view_data = nil
local shelf_fail_attempts = 0
shelf_host.client = {
    get_shelf = function()
        shelf_fail_attempts = shelf_fail_attempts + 1
        error("HTTP 401 content_type=json")
    end,
}
shelf_host:refreshBookshelf()
expect(shelf_fail_attempts == 1,
    "deterministic shelf failure was retried")
expect(shelf_infos == 1 and shelf_view_data == nil,
    "deterministic shelf failure did not report the error")

print(("wifi_on_demand_spec: %d checks"):format(checks))
