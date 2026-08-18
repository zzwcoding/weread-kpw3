# 06 — KOReader 个性化定制

三个自制插件 + 微信读书插件增强（WiFi 按需/静默同步）+ 菜单定制 + 屏保定制。除屏保消息框外全部为 KOReader 标准机制，升级 KOReader 后只有一处核心文件改动需要重打（见文末）。

## 插件总览

三个插件都在 `custom/` 下，部署方式就是拷到 `/mnt/us/koreader/plugins/`：

```sh
scp -r kafshim.koplugin powermenu.koplugin sleepmsg.koplugin root@<kindle>:/mnt/us/koreader/plugins/
```

KOReader 插件默认启用，无需额外开启。SSH 入口：KOReader 齿轮菜单 → 网络 → SSH 服务器（默认端口 **2222**，root 无密码，建议仅在调试时开启）。

### kafshim.koplugin — 电源键修复（无 framework 环境必装）

注册最小的 `com.lab126.kaf` LIPC 替身服务（`frameworkStarted=1`, `splash=0`），让 powerd 不再忽略电源键。原理见 docs/05 第 3 条。
检测到原生 framework 在运行（`/var/run/cvm.pid` 存在）时自动跳过，不会抢名。

### powermenu.koplugin — "关机"菜单项

上游 KOReader 在 Kindle 平台把 `canPowerOff` 设为 no（假定你用原生系统关机），"退出"子菜单没有关机项。本插件：
1. 补上 `canPowerOff`（函数形式，见 docs/05 第 7 条）；
2. 实现 `Device:powerOff()`（`sync && poweroff`，KOReader 以 root 运行直接可用）；
3. 在 UIManager 就绪后重注册 `PowerOff` 事件处理器（见 docs/05 第 8 条）。

效果：主菜单（≡ 标签页）→ 退出 → 关机（带确认框）。
如需"重启设备"项，照此模式加 `canReboot` + `Device:reboot()` + `Reboot` 处理器即可（本项目最终版按需求移除了重启项）。

### sleepmsg.koplugin — 屏保文案轮换

包一层 `Device:intoScreenSaver`，在屏保绘制**之前**从文案库随机挑一句写入 `screensaver_message` 设置（带"不连续重复"逻辑）。

- 文案文件：`plugins/sleepmsg.koplugin/messages.lua`，格式是一行一句的 Lua 表；
- 条数不影响性能（启动时读一次，随机取数 O(1)），本项目实测 700 条无感；
- 仓库里只放 4 条占位样例，换成你自己的即可，改完重启 KOReader 生效。

## 菜单定制（隐藏无关菜单项）

两个编排文件（都在 `custom/koreader-settings/`），拷到 `/mnt/us/koreader/settings/`：

- `filemanager_menu_order.lua`——文件管理器（书库）菜单：隐藏"搜索"整组标签、工具组 12 个无关项、主菜单的"OTA 更新"和"帮助"整组；
- `reader_menu_order.lua`——阅读界面菜单：工具组只留"进度同步"，搜索组只留全文/书签搜索，主菜单藏"OTA 更新""帮助"。

机制：MenuSorter 读取该文件作为完整编排；要隐藏的项从原分组移除并列入 `["KOMenu:disabled"]`；顶部标签整组隐藏 = 从 `KOMenu:menu_buttons` 移除该标签 id 并列入 disabled。
**两条铁律**（都是踩出来的，见 docs/05 第 16 条）：
1. 只改子项不动分组结构的话，其余分组必须原样保留，否则未引用的项会以"NEW:"前缀变成孤儿项显示出来；
2. **整组删除一个分组时，该组成员必须全部列入 disabled，且要收编所有 `sorting_hint` 指向该组的运行时注册项**（插件注册时会声明挂靠分组，如 `sorting_hint = "more_tools"`；组没了而项还在 → 菜单构建直接崩溃闪退）。注意 hint 的写法可能有变体（如 `sorting_hint = ("more_tools")`），grep 时用宽松模式 `sorting_hint[^,}]*` 全量排查。

## 微信读书插件：WiFi 按需连接 + 静默后台同步

插件在 `plugin/weread.koplugin`（kpw3-enhance 分支），两项网络行为改造：

**前台动作按需联网**（书架刷新/登录/下载/手动同步）：
- 全部经 `NetworkMgr:runWhenOnline` 收口，配合全局设置 `wifi_enable_action="turn_on"`（离线自动开 WiFi 并显示连接中）；
- 会话结束（关书架/下载完成/登录结束）调 `NetworkMgr:afterWifiAction`，配合 `wifi_disable_action="turn_off"` 自动关 WiFi；
- 归属语义：只关自己拉起的 WiFi，用户手动开的不会被误关。

**自动同步静默联网**（打开书拉进度/关书合盖传进度+阅读时长）：
- 自制 `silent_network.lua`：无 UI 后台拉起 WiFi（`NetworkMgr:enableWifi(nil)`，绕开带提示的高层封装），链路就绪后做**真实 WAN 探测**（TCP 连接 weread 网关，1.5s×3 次重试）再发请求——链路 up ≠ 路由可用，见 docs/05 第 17 条；
- 失败/超时静默放弃，进度持久化为 pending，唤醒后自动补传；全程零 UI、不阻塞熄屏；
- 后台周期 tick（进度/时长）仍只做非阻塞链路检查，离线静默跳过，绝不主动拉 WiFi。

设备侧配套设置（settings.reader.lua / 插件设置）：
```lua
["wifi_enable_action"] = "turn_on",
["wifi_disable_action"] = "turn_off",
-- 插件 weread.lua: sync.pull_on_open=true, upload_on_close=true, read_report.enabled=true
```

## 屏保定制（白底图片 + 花边消息框 + 爱心图标）

### 设置项（settings.reader.lua，或界面操作：齿轮 → 屏幕 → 屏保）

```lua
["screensaver_type"] = "random_image",          -- 随机图片模式
["screensaver_dir"] = "/mnt/us/screensaver",    -- 只放一张图 = 固定显示它
["screensaver_img_background"] = "white",       -- 白底
["screensaver_show_message"] = true,            -- 显示消息
```

图片建议按屏幕原生分辨率做（KPW3 为 758×1024），白底 PNG。注意屏保图片请自备并注意版权，本仓库不含图片。

### 花边消息框 + 宽度自适应（唯一的核心文件改动）

原生"box"样式用 InfoMessage，宽写死为 2/3 屏宽，且带 ⓘ 图标。本项目替换 `frontend/ui/screensaver.lua` 中 `message_container == "box"` 分支为自绘双层边框（外粗内细+圆角）+ 按文字实际宽度自适应，图标换爱心。

- 替换代码块：`custom/screensaver-lace-block.lua`
- 爱心图标：`custom/koreader-icons/notice-heart.svg` → 拷到 `/mnt/us/koreader/resources/icons/mdlight/`
- 替换方法：把 screensaver.lua 里 `content_widget = InfoMessage:new{ ... }` 到 `content_widget = content_widget.movable` 一段整体换为该代码块（先备份原文件）

⚠️ 这是**对 KOReader 核心文件的直接修改，升级 KOReader 会丢失**，升级后需重打。

## 验证清单

1. 短按电源键 → 白屏 + 图片 + 花边框 + 随机文案；再短按唤醒；
2. 合盖休眠/开盖唤醒；
3. ≡ 菜单 → 退出 → 有关机项；
4. 菜单只剩需要的项；
5. 重启设备 → 自动回到 KOReader。
