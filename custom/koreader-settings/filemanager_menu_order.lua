-- filemanager_menu_order.lua — KOReader 菜单定制（用户选择版）
-- 位置: /mnt/us/koreader/settings/filemanager_menu_order.lua
-- 机制: 完整覆盖默认编排; 列入 KOMenu:disabled 的项被隐藏。
-- 用户选择(2026-08-17):
--   ③ 工具: 隐藏 阅读计时器/Calibre/导出笔记/阅读统计/云存储/移动到归档/
--            Wallabag/新闻下载/文本编辑器/配置方案/QR剪贴板 (保留"更多工具")
--   ④ 搜索: 整组隐藏
local Device = require("device")

local order = {
    ["KOMenu:menu_buttons"] = {
        "filemanager_settings",
        "setting",
        "tools",
        "plus_menu",
        "main",
    },
    filemanager_settings = {
        "filemanager_display_mode",
        "filebrowser_settings",
        "----------------------------",
        "show_filter",
        "sort_by",
        "reverse_sorting",
        "sort_mixed",
        "----------------------------",
        "start_with",
    },
    setting = {
        "frontlight",
        "night_mode",
        "----------------------------",
        "network",
        "screen",
        "----------------------------",
        "taps_and_gestures",
        "navigation",
        "document",
        "----------------------------",
        "language",
        "device",
    },
    document = {
        "document_metadata_location",
        "document_metadata_location_move",
        "document_auto_save",
        "document_metadata_arc",
        "document_end_action",
        "language_support",
    },
    device = {
        "keyboard_layout",
        "external_keyboard",
        "font_ui_fallbacks",
        "----------------------------",
        "time",
        "units",
        "device_status_alarm",
        "charging_led",
        "autostandby",
        "autosuspend",
        "autoshutdown",
        "pageturn_power",
        "ignore_sleepcover",
        "ignore_open_sleepcover",
        "cover_events",
        "ignore_battery_optimizations",
        "mass_storage_settings",
        "file_ext_assoc",
        "screenshot",
    },
    navigation = {
        "back_to_exit",
        "back_in_filemanager",
        "back_in_reader",
        "backspace_as_back",
        "----------------------------",
        "physical_buttons_setup",
        "----------------------------",
        "android_volume_keys",
        "android_haptic_feedback",
        "android_back_button",
        "----------------------------",
        "opening_page_location_stack",
        "skim_dialog_position",
    },
    network = {
        "network_wifi",
        "network_proxy",
        "network_powersave",
        "network_restore",
        "network_info",
        "network_before_wifi_action",
        "network_after_wifi_action",
        "network_dismiss_scan",
        "----------------------------",
        "ssh",
    },
    screen = {
        "screensaver",
        "autodim",
        "----------------------------",
        "screen_rotation",
        "----------------------------",
        "screen_dpi",
        "screen_eink_opt",
        "autowarmth",
        "color_rendering",
        "----------------------------",
        "screen_timeout",
        "fullscreen",
        "----------------------------",
        "screen_notification",
    },
    taps_and_gestures = {
        "gesture_manager",
        "gesture_overview",
        "gesture_intervals",
        "----------------------------",
        "ignore_hold_corners",
        "screen_disable_double_tap",
        "----------------------------",
        "menu_activate",
    },
    tools = {
        "more_tools",
    },
    more_tools = {
        "auto_frontlight",
        "battery_statistics",
        "book_shortcuts",
        "synchronize_time",
        "keep_alive",
        "doc_setting_tweak",
        "terminal",
        "----------------------------",
        "plugin_management",
        "patch_management",
        "advanced_settings",
        "developer_options",
    },
    search = {
        "search_settings",
        "----------------------------",
        "dictionary_lookup",
        "dictionary_lookup_history",
        "vocabbuilder",
        "----------------------------",
        "wikipedia_lookup",
        "wikipedia_history",
        "----------------------------",
        "file_search",
        "file_search_results",
        "find_book_in_calibre_catalog",
        "----------------------------",
        "opds",
    },
    search_settings = {
        "dictionary_settings",
        "wikipedia_settings",
    },
    main = {
        "history",
        "open_last_document",
        "----------------------------",
        "favorites",
        "collections",
        "bookmark_browser",
        "----------------------------",
        "mass_storage_actions",
        "----------------------------",
        "ota_update",
        "help",
        "----------------------------",
        "exit_menu",
    },
    help = {
        "quickstart_guide",
        "----------------------------",
        "search_menu",
        "----------------------------",
        "report_bug",
        "plugins_disable_external",
        "----------------------------",
        "system_statistics",
        "version",
        "about",
    },
    plus_menu = {},
    exit_menu = {
        "restart_koreader",
        "----------------------------",
        "sleep",
        "poweroff",
        "reboot",
        "----------------------------",
        "start_bq",
        "exit",
    },
    -- 隐藏清单(从原属分组移除并列入此处)
    ["KOMenu:disabled"] = {
        "search",              -- ④ 搜索标签整组
        "read_timer",          -- ③ 阅读计时器
        "calibre",             -- ③ Calibre
        "exporter",            -- ③ 导出笔记
        "statistics",          -- ③ 阅读统计
        "cloud_storage",       -- ③ 云存储
        "cloudstorage",        -- ③ 云存储(别名)
        "move_to_archive",     -- ③ 移动到归档
        "wallabag",            -- ③ Wallabag
        "news_downloader",     -- ③ 新闻下载
        "text_editor",         -- ③ 文本编辑器
        "profiles",            -- ③ 配置方案
        "qrclipboard",         -- ③ QR剪贴板
    },
}

if not Device:hasExitOptions() then
    order.exit_menu = nil
end
return order
