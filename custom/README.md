# KPW3 极简定制包：开机直达微信读书

目标：开机 → KOReader → 微信读书书架，其他原生服务全部静默。
依据：`notes/firmware-analysis.md`（基于官方固件 5.16.2.1.1 rootfs 的完整分析）。

## 最终效果

- 按电源键 → 约 30 秒 → 直接进入 KOReader（Java framework、KPP 首页/商店、
  遥测、OTA、推送等后台服务全部不启动，512MB 内存基本全留给阅读）
- 原生系统完好保留在机器里，只是默认不加载；删掉开关文件即可随时回去
- 所有改动 = 加 3 个文件 + 改名 18 个 conf，`restore.sh` 一键还原

## 前提

1. KPW3 已越狱（LanguageBreak，固件 ≤ 5.16.2.1.1）并装了 hotfix
2. 已装 KUAL + MRPI（越狱后标准流程）
3. 已装 KOReader 到 /mnt/us/koreader（官方 Kindle 安装包）
4. 已装 usbnet 插件（KUAL 扩展，提供 SSH 入口）—— 也可以用 KUAL 的
   终端/kterm 手动敲命令代替 SSH

## 安装步骤

1. 把整个 `custom/` 目录改名为 `minimal` 拷到 Kindle USB 盘根目录
   （即设备上路径为 /mnt/us/minimal/）
2. 通过 usbnet SSH 进 Kindle（或 kterm），执行：

   ```sh
   sh /mnt/us/minimal/minimalize.sh
   ```

3. 重启。之后每次开机自动进 KOReader。

## 禁用了什么（18 个 job）

| 类别 | job |
|---|---|
| 原生界面 | kppmainapp（首页+商店）、kfxreader、kfxview、pillow（webkit 渲染）、statusbar |
| OTA 后台 | otaupd、otav3（保留手动刷包入口 ota-update/otaup） |
| 遥测日志 | demd、tmd、iohwlogs、printklogs、last_debug_info |
| 推送/内容管理 | todo、maruinstall、wfmupdate、wfmdelete |
| 调试通道 | testd、sshd（usbnet 自带 SSH，不受影响） |

另外通过官方开关 /mnt/us/DONT_START_FRAMEWORK 禁用 Java framework，
连带下游 webreader、scanner、stored、dmld、clickstream_logging、
fastmetrics、whisperstore 等全部自然不启动。

**保留的核心**：powerd（休眠/电源键/前光）、wifid（微信读书要联网）、
触屏、EPDC 显示、lipcd/dbus、volumd（USB 导出）、X/blanket、
contentpackd（原生系统回退路径需要）、bootactions（开机进度条）。

## 注意事项

- **屏保/休眠图**：framework 禁用后原生屏保不再显示，休眠画面由 KOReader
  自己管理（设置 → 屏幕 → 睡眠屏图片，支持书籍封面）。不需要装
  ScreenSavers Hack。
- **回退**：插电脑删 USB 盘根目录的 `AUTOSTART_KOREADER`，下次开机即回
  原生界面；或 SSH 执行 `sh /mnt/us/minimal/restore.sh` 完全还原。
- **系统菜单"更新您的 Kindle"**：otaupd 禁用后在线更新失效（这正是目的），
  手动刷 update_*.bin 包仍然可用。
- **WiFi 设置**：首次使用前先完成本定制再连 WiFi，或先连好 WiFi 再定制
  均可；KOReader 内可管理 WiFi 开关。
- 调试期若 KOReader 自启失败：看 /tmp/koreader.err；连续 3 次快速崩溃会
  自动停止自启（防死循环），排查后删掉 /var/local/koreader_start_count
  再重启（restore.sh 和 KUAL 恢复扩展已会自动清除）。
- **重要：恢复出厂设置前必须先跑 restore.sh 完全还原**。出厂重置会删掉
  locale 配置，此时系统的语言选择流程依赖 pillow，而 pillow 已被禁用，
  会导致开机卡在语言选择。先还原再重置就没有任何影响。

## 微信读书部分

KOReader 里装我们的 weread 插件（开发中，基于 finlater/weread.koplugin）。
安装后路径：KOReader 菜单 → 工具 → 微信读书 → 扫码登录 → 书架。
"KOReader 启动后自动打开微信读书书架"会作为插件功能实现。
