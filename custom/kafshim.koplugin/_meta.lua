local _ = require("gettext")
return {
    name = "kafshim",
    fullname = _("Kaf Shim"),
    description = _("注册一个最小的 com.lab126.kaf LIPC 服务（frameworkStarted=1, splash=0），让 powerd 不再误以为开机动画还在显示，从而恢复电源键短按休眠。仅在无 Java framework 的 KOReader 自启模式下需要。"),
}
