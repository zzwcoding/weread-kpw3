-- powermenu.koplugin — 解锁 Kindle 的"关机"菜单项
--
-- 上游 KOReader 在 Kindle 平台把 canPowerOff 设为 no
-- （官方假设你用原生系统关机），"退出"子菜单因此没有"关机"。
-- 本插件在 KOReader 启动后（device 模块就绪后）补上标志位和实现。
-- 注意1：KOReader 的 yes/no 约定是可调用函数，不能赋布尔值。
-- 注意2：PowerOff 事件处理器是在 device 初始化时按当时的
--   canPowerOff 注册的（那时还是 no，注册的是空操作），
--   所以仅改标志位不够，必须在 UIManager 就绪后重新注册处理器。
-- （不要做成 patches/1- 早期补丁：那时 require("device") 会让 device
--   模块在 G_reader_settings 初始化前加载失败并中毒，KOReader 起不来。）

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local PowerMenu = WidgetContainer:extend{
    name = "powermenu",
    is_doc_only = false,
}

function PowerMenu:init()
    local Device = require("device")
    if not Device:isKindle() then
        return
    end
    Device.canPowerOff = function() return true end
    function Device:powerOff()
        -- 走原生关机路径（runlevel 0 → shutdown.conf → 完整关机流程），
        -- 而不是直接 busybox poweroff：裸 poweroff 会跳过 powerd 的关机准备
        -- （PMIC/服务收尾），实测导致下次开机需短按两次才启动。
        os.execute("sync && /sbin/shutdown -h now")
    end

    -- UIManager 就绪后再覆盖事件处理器（确保在 generic 注册的空操作之后）
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        local ConfirmBox = require("ui/widget/confirmbox")
        local _ = require("gettext")
        UIManager.event_handlers.PowerOff = function(message_text)
            UIManager:show(ConfirmBox:new{
                text = message_text or _("确定要关机吗？"),
                ok_text = _("关机"),
                ok_callback = function()
                    UIManager:nextTick(UIManager.poweroff_action)
                end,
            })
        end
        logger.info("powermenu: PowerOff 事件处理器已注册")
    end)
    logger.info("powermenu: 已解锁 关机 菜单项")
end

return PowerMenu
