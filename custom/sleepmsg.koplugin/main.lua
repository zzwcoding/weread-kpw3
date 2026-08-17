-- sleepmsg.koplugin — 休眠文案轮换
--
-- 原理：包一层 Device:intoScreenSaver，在屏保显示之前从
-- messages.lua 随机挑一句写入 screensaver_message 设置。
-- 避免连续两次显示同一句。文案文件：
--   /mnt/us/koreader/plugins/sleepmsg.koplugin/messages.lua

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local SleepMsg = WidgetContainer:extend{
    name = "sleepmsg",
    is_doc_only = false,
}

local DEFAULT_MESSAGES = { "Sleeping" }
local messages = DEFAULT_MESSAGES
local last_index = 0

local function load_messages()
    local ok, t = pcall(dofile, "/mnt/us/koreader/plugins/sleepmsg.koplugin/messages.lua")
    if ok and type(t) == "table" and #t > 0 then
        messages = t
    end
end

local function pick_message()
    if #messages == 0 then
        return nil
    end
    if #messages == 1 then
        return messages[1]
    end
    local idx
    repeat
        idx = math.random(#messages)
    until idx ~= last_index
    last_index = idx
    return messages[idx]
end

function SleepMsg:init()
    local Device = require("device")
    if not Device:isKindle() then
        return
    end
    math.randomseed(os.time())
    load_messages()
    local orig = Device.intoScreenSaver
    if type(orig) ~= "function" then
        logger.warn("sleepmsg: intoScreenSaver 不存在")
        return
    end
    Device.intoScreenSaver = function(self, source)
        local msg = pick_message()
        if msg then
            G_reader_settings:saveSetting("screensaver_message", msg)
        end
        return orig(self, source)
    end
    logger.info("sleepmsg: 已挂载, 共 " .. #messages .. " 条文案")
end

return SleepMsg
