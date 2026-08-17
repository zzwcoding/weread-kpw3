-- Quiet (UI-free) on-demand WiFi sessions for background sync.
--
-- Unlike NetworkMgr:runWhenOnline / beforeWifiAction, raising WiFi through
-- this module never shows KOReader's "Connecting…" UI: the caller injects
-- quiet backend hooks (NetworkMgr:enableWifi/disableWifi without the
-- interactive flag, which never display widgets). A session polls the link
-- state until it is up (bounded by a timeout), runs the queued tasks, then
-- releases WiFi only when this session raised it — WiFi the user enabled
-- manually is never touched. Every failure is silent: errors are logged,
-- never surfaced to the UI.

local logger = require("weread.lib.logger").scoped("SilentNetwork")

local SilentNetwork = {}
SilentNetwork.__index = SilentNetwork

local CONNECT_TIMEOUT_SECONDS = 10
local POLL_INTERVAL_SECONDS = 0.5
-- The link being up does not mean WAN/DNS is usable yet; give the
-- connection a moment before the first request (same lesson as QR login).
local SETTLE_SECONDS = 1.0

-- options = {
--   scheduler,          -- UIManager-compatible scheduleIn
--   is_connected(),     -- non-blocking link-state check
--   turn_wifi_on(),     -- quiet WiFi raise; return false when unavailable
--   turn_wifi_off(),    -- quiet WiFi release
--   connect_timeout,    -- optional seconds, default 10
-- }
function SilentNetwork:new(options)
    options = options or {}
    assert(type(options.scheduler) == "table", "silent network scheduler is required")
    assert(type(options.is_connected) == "function", "is_connected callback is required")
    assert(type(options.turn_wifi_on) == "function", "turn_wifi_on callback is required")
    assert(type(options.turn_wifi_off) == "function", "turn_wifi_off callback is required")
    local object = {
        scheduler = options.scheduler,
        is_connected = options.is_connected,
        turn_wifi_on = options.turn_wifi_on,
        turn_wifi_off = options.turn_wifi_off,
        connect_timeout = tonumber(options.connect_timeout)
            or CONNECT_TIMEOUT_SECONDS,
        generation = 0,
        active = false,
        owns_wifi = false,
        tasks = nil,
    }
    return setmetatable(object, self)
end

function SilentNetwork:_release()
    if not self.owns_wifi then return end
    self.owns_wifi = false
    local ok, err = pcall(self.turn_wifi_off)
    if not ok then
        logger.warn("silent wifi release failed:", tostring(err))
    else
        logger.info("silent session released wifi")
    end
end

-- End the session without running the queued tasks (connect timeout or an
-- explicit cancel). Each entry's on_drop runs so callers can reset their
-- in-flight state; the data itself is expected to be retried later.
function SilentNetwork:_abort(reason)
    if not self.active then return end
    local tasks = self.tasks or {}
    self.tasks = nil
    self.active = false
    self:_release()
    logger.info("silent session aborted:", tostring(reason))
    for _i, entry in ipairs(tasks) do
        if type(entry.on_drop) == "function" then
            local ok, err = pcall(entry.on_drop)
            if not ok then
                logger.warn("silent task drop handler failed:", tostring(err))
            end
        end
    end
end

function SilentNetwork:_drain(generation)
    if generation ~= self.generation or not self.active then return end
    while self.tasks and #self.tasks > 0 do
        local entry = table.remove(self.tasks, 1)
        local ok, err = pcall(entry.run)
        if not ok then
            -- Silent by design: background sync failures are retried by the
            -- caller's own pending mechanisms, never reported to the UI.
            logger.warn("silent task failed:", tostring(err))
        end
    end
    self.tasks = nil
    self.active = false
    self:_release()
end

function SilentNetwork:_poll(generation, attempt)
    if generation ~= self.generation or not self.active then return end
    if self.is_connected() then
        logger.info("silent session connected:",
            "waited=", string.format("%.1f", attempt * POLL_INTERVAL_SECONDS))
        self.scheduler:scheduleIn(SETTLE_SECONDS, function()
            self:_drain(generation)
        end)
        return
    end
    if attempt * POLL_INTERVAL_SECONDS >= self.connect_timeout then
        self:_abort("connect_timeout")
        return
    end
    self.scheduler:scheduleIn(POLL_INTERVAL_SECONDS, function()
        self:_poll(generation, attempt + 1)
    end)
end

-- Queue a task for a quiet connected session. When a session is already
-- active the task joins it and shares its WiFi raise/release. on_drop runs
-- only when the session ends before the task could run; it must stay UI-free
-- as well. Returns true when the task was accepted.
function SilentNetwork:run(task, on_drop)
    assert(type(task) == "function", "silent task must be a function")
    self.tasks = self.tasks or {}
    table.insert(self.tasks, { run = task, on_drop = on_drop })
    if self.active then
        return true
    end
    self.active = true
    self.generation = self.generation + 1
    local generation = self.generation
    if self.is_connected() then
        self.scheduler:scheduleIn(0.1, function()
            self:_drain(generation)
        end)
        return true
    end
    local ok, err = pcall(self.turn_wifi_on)
    if not ok then
        logger.warn("silent wifi raise failed:", tostring(err))
    end
    -- Only own (and later release) WiFi when the raise was actually
    -- attempted; a failed raise leaves the radio off and the release no-ops.
    self.owns_wifi = ok == true
    self:_poll(generation, 1)
    return true
end

-- Abort the current session (if any): scheduled callbacks are disarmed,
-- queued tasks are dropped via on_drop, and WiFi is released when this
-- session raised it.
function SilentNetwork:cancel(reason)
    self.generation = self.generation + 1
    self:_abort(reason or "cancelled")
end

return SilentNetwork
