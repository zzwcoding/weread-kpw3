-- Unit tests for weread/lib/silent_network.lua: quiet on-demand WiFi sessions
-- for background sync (no UI, own-bookkeeping release, bounded connect wait).

package.path = "./?.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local fake_logger = {
    info = function() end,
    warn = function() end,
    err = function() end,
}
fake_logger.scoped = function() return fake_logger end
package.preload["weread.lib.logger"] = function() return fake_logger end

local SilentNetwork = require("weread.lib.silent_network")

local function fixture(connected, probe)
    local state = {
        connected = connected == true,
        on_calls = 0,
        off_calls = 0,
        fail_raise = false,
    }
    local queue = {}
    local net = SilentNetwork:new{
        scheduler = {
            scheduleIn = function(_self, _delay, callback)
                queue[#queue + 1] = callback
            end,
        },
        is_connected = function() return state.connected end,
        turn_wifi_on = function()
            if state.fail_raise then error("no wifi backend") end
            state.on_calls = state.on_calls + 1
        end,
        turn_wifi_off = function()
            state.off_calls = state.off_calls + 1
        end,
        probe = probe,
        connect_timeout = 2,
    }
    local function step()
        local callback = table.remove(queue, 1)
        if callback then callback() end
        return callback ~= nil
    end
    local function drain()
        local count = 0
        while step() do
            count = count + 1
            assert(count < 200, "scheduler did not quiesce")
        end
    end
    return state, net, drain, step
end

-- Already connected (user's WiFi): run the task, never touch the radio.
do
    local state, net, drain = fixture(true)
    local ran = 0
    net:run(function() ran = ran + 1 end)
    drain()
    expect(ran == 1, "online task did not run")
    expect(state.on_calls == 0, "online session raised WiFi")
    expect(state.off_calls == 0, "user-enabled WiFi was turned off")
end

-- Offline: raise quietly, poll until connected, settle, run, release own WiFi.
do
    local state, net, _, step = fixture(false)
    local ran = 0
    net:run(function() ran = ran + 1 end)
    expect(state.on_calls == 1, "offline session did not raise WiFi")
    expect(ran == 0, "task ran before connecting")
    step() -- poll: still down, reschedules
    expect(ran == 0, "task ran while the link was down")
    state.connected = true
    step() -- poll: link up, schedules the settle drain
    step() -- settle elapsed: drain runs the task and releases
    expect(ran == 1, "connected session did not run the task")
    expect(state.off_calls == 1, "session-raised WiFi was not released")
end

-- Connect timeout: drop the task via on_drop, release, no residue.
do
    local state, net, drain = fixture(false)
    local ran = 0
    local dropped = 0
    net:run(function() ran = ran + 1 end, function() dropped = dropped + 1 end)
    drain()
    expect(ran == 0, "timed-out session ran its task")
    expect(dropped == 1, "timed-out task was not dropped through on_drop")
    expect(state.off_calls == 1, "timed-out session did not release WiFi")
    expect(net.active == false and net.tasks == nil,
        "timed-out session left residue behind")
end

-- A second run() joins the active session: one raise, one release.
do
    local state, net, drain = fixture(false)
    local order = {}
    net:run(function() order[#order + 1] = "a" end)
    net:run(function() order[#order + 1] = "b" end)
    state.connected = true
    drain()
    expect(#order == 2 and order[1] == "a" and order[2] == "b",
        "queued tasks did not share the session in order")
    expect(state.on_calls == 1 and state.off_calls == 1,
        "shared session raised or released WiFi more than once")
end

-- A failing task is logged, not propagated, and WiFi is still released.
do
    local state, net, drain = fixture(false)
    net:run(function() error("sync boom") end)
    state.connected = true
    drain()
    expect(state.off_calls == 1, "failing task leaked the WiFi release")
end

-- A failed raise owns nothing: timeout drops the task without a release.
do
    local state, net, drain = fixture(false)
    state.fail_raise = true
    local dropped = 0
    net:run(function() end, function() dropped = dropped + 1 end)
    drain()
    expect(dropped == 1, "task was not dropped after a failed raise")
    expect(state.off_calls == 0, "failed raise released WiFi it never owned")
end

-- Cancel: disarms scheduled callbacks, drops tasks, releases own WiFi.
do
    local state, net, drain, step = fixture(false)
    local ran = 0
    local dropped = 0
    net:run(function() ran = ran + 1 end, function() dropped = dropped + 1 end)
    net:cancel("test_cancel")
    expect(dropped == 1, "cancelled task was not dropped through on_drop")
    expect(state.off_calls == 1, "cancelled session did not release WiFi")
    state.connected = true
    while step() do end
    expect(ran == 0, "stale session callbacks ran after cancel")
    drain()
end

-- WAN probe: link up but route not working yet (EHOSTUNREACH) — the task
-- waits for real connectivity, retried probes succeed on the third attempt.
do
    local probe_calls = 0
    local state, net, drain = fixture(false, function()
        probe_calls = probe_calls + 1
        return probe_calls >= 3
    end)
    local ran = 0
    net:run(function() ran = ran + 1 end)
    state.connected = true
    drain()
    expect(probe_calls == 3, "WAN probe did not retry until ready")
    expect(ran == 1, "task did not run after the probe passed")
    expect(state.on_calls == 1 and state.off_calls == 1,
        "probed session did not raise/release WiFi exactly once")
end

-- WAN never becomes usable: the task never runs, on_drop fires, own WiFi is
-- released, no residue.
do
    local probe_calls = 0
    local state, net, drain = fixture(false, function()
        probe_calls = probe_calls + 1
        return false
    end)
    local ran = 0
    local dropped = 0
    net:run(function() ran = ran + 1 end, function() dropped = dropped + 1 end)
    state.connected = true
    drain()
    expect(probe_calls == 3, "WAN probe did not exhaust its budget")
    expect(ran == 0, "task ran without a usable WAN")
    expect(dropped == 1, "probe-starved task was not dropped through on_drop")
    expect(state.off_calls == 1, "probe-starved session did not release WiFi")
    expect(net.active == false and net.tasks == nil,
        "probe-starved session left residue behind")
end

-- A throwing probe counts as "not ready" and never crashes the session.
do
    local state, net, drain = fixture(true, function()
        error("probe boom")
    end)
    local dropped = 0
    net:run(function() end, function() dropped = dropped + 1 end)
    drain()
    expect(dropped == 1, "throwing probe did not drop the task quietly")
    expect(state.off_calls == 0,
        "probe failure turned off WiFi the session never raised")
end

print(("silent_network_spec: %d checks"):format(checks))
