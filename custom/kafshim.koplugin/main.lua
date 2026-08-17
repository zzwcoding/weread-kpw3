-- kafshim.koplugin — 最小 com.lab126.kaf 替身服务
--
-- 背景：极简定制（DONT_START_FRAMEWORK）后 Java framework 不启动，
-- com.lab126.kaf 无人注册。powerd 每次收到电源键事件都会去查 kaf，
-- 查询失败 → 认为"splash 还在显示" → 永远忽略电源键
-- （日志：pbisplash: Splash screen is on. Ignoring power button）。
--
-- 本插件在 KOReader 启动时注册 kaf 服务名，并写入 powerd 需要的
-- 两个属性（存进 lipcd 的属性库，get 时直接由 lipcd 应答）：
--   frameworkStarted = 1   （框架已启动）
--   splash = 0             （splash 已结束）
-- handle 保存在 self 上，随 KOReader 进程存活，服务名持续有效。

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local KafShim = WidgetContainer:extend{
    name = "kafshim",
    is_doc_only = false,
}

function KafShim:init()
    local Device = require("device")
    if not Device:isKindle() then
        return
    end
    local haslipc, lipc = pcall(require, "liblipclua")
    if not haslipc then
        logger.warn("kafshim: liblipclua 不可用")
        return
    end
    -- 调试: 枚举模块能力
    local keys = {}
    for k in pairs(lipc) do keys[#keys+1] = tostring(k) end
    table.sort(keys)
    logger.info("kafshim: liblipclua 方法: " .. table.concat(keys, ","))
    -- 原生 framework 在运行时（cvm 已持有 kaf 名），不要抢注
    local f = io.open("/var/run/cvm.pid", "r")
    if f then
        f:close()
        logger.info("kafshim: 检测到原生 framework，跳过")
        return
    end
    local kaf = lipc.init("com.lab126.kaf")
    if not kaf then
        logger.warn("kafshim: 注册 com.lab126.kaf 失败")
        return
    end
    -- 调试: 枚举handle方法
    local mt = getmetatable(kaf)
    local idx = mt and mt.__index
    if type(idx) == "table" then
        local ks = {}
        for k in pairs(idx) do ks[#ks+1] = tostring(k) end
        table.sort(ks)
        logger.info("kafshim: handle 方法: " .. table.concat(ks, ","))
    end
    local ok1, err1 = pcall(function()
        kaf:register_int_property("frameworkStarted", "rw", 1)
    end)
    local ok2, err2 = pcall(function()
        kaf:register_int_property("splash", "rw", 0)
    end)
    -- register 后再显式 set 一次
    pcall(function() kaf:set_int_property("com.lab126.kaf", "frameworkStarted", 1) end)
    pcall(function() kaf:set_int_property("com.lab126.kaf", "splash", 0) end)
    -- 自测: 从内部 get 看看
    local v1, e1 = pcall(function() return kaf:get_int_property("com.lab126.kaf", "frameworkStarted") end)
    logger.info("kafshim: 内部get frameworkStarted =", v1, e1)
    logger.info("kafshim: register frameworkStarted:", ok1, err1, " splash:", ok2, err2)
    -- 再发一次 FrameworkStarted 事件(大小写两个版本都发, 覆盖监听方)
    pcall(function() kaf:send_event("FrameworkStarted") end)
    pcall(function() kaf:send_event("frameworkStarted") end)
    self.kaf_handle = kaf
    logger.info("kafshim: com.lab126.kaf 已注册, frameworkStarted=1 splash=0")
end

return KafShim
