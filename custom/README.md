# KPW3 极简定制包：开机直达微信读书

目标：开机 → KOReader → 微信读书书架，其他原生服务全部静默。
依据：`docs/01-固件分析.md`（基于官方固件 5.16.2.1.1 rootfs 的完整分析）。

## 最终效果

- 按电源键 → 约 30 秒 → 直接进入 KOReader（Java framework、KPP 首页/商店、
  遥测、OTA、推送、心跳等后台服务全部不启动，512MB 内存基本全留给阅读）
- 原生系统完好保留在机器里，只是默认不加载；执行 restore.sh 可完整还原
- 所有改动 = 加 3 个文件 + 改名 18 个 conf，`restore.sh` 一键还原

## 前提

1. KPW3 已越狱（LanguageBreak，固件 ≤ 5.16.2.1.1）并刷了 KindleModding 通用 hotfix
2. 已装 KUAL + MRPI（越狱后标准流程）
3. 已装 KOReader 到 /mnt/us/koreader（官方 Kindle 安装包）
4. SSH 入口：KOReader 齿轮菜单 → 网络 → SSH 服务器（端口 2222）

## 安装步骤

1. 把整个 `custom/` 目录改名为 `minimal` 拷到 Kindle USB 盘根目录
   （即设备上路径为 /mnt/us/minimal/）
2. SSH 进 Kindle（或 kterm），执行：

   ```sh
   sh /mnt/us/minimal/minimalize.sh
   ```

3. 重启。之后每次开机自动进 KOReader。

## 禁用了什么（18 个 job）

| 类别 | job |
|---|---|
| 原生界面 | kppmainapp（首页+商店）、kfxreader、kfxview、statusbar、webreader（浏览器引擎） |
| OTA 后台 | otaupd、otav3（保留手动刷包入口 ota-update/otaup） |
| 遥测/心跳 | tmd、iohwlogs、printklogs、last_debug_info、phd（30秒UDP心跳） |
| 推送/内容管理 | todo、maruinstall、wfmupdate、wfmdelete |
| 调试通道 | testd、sshd（KOReader 自带 SSH，不受影响） |

另外通过官方开关 /mnt/us/DONT_START_FRAMEWORK 禁用 Java framework，
连带下游 scanner、stored、dmld、clickstream_logging、fastmetrics、
whisperstore 等全部自然不启动。

**三个不能禁的（血泪教训，详见 docs/04、05）：**
- `demd`——lab126.conf 依赖 `started demd`，禁了软砖；
- `pillow`——屏保/休眠守护，禁了合盖和电源键都不休眠；
- 任何被其他 job `start on started xxx` 引用的服务。

**保留的核心**：powerd（休眠/电源键/前光）、wifid（联网）、pillow、
触屏、EPDC 显示、lipcd/dbus、volumd（USB 导出）、X/blanket、
contentpackd（原生系统回退路径需要）、bootactions（开机进度条）。

## 注意事项

- **屏保/休眠图**：framework 禁用后原生屏保不再显示，休眠画面由 KOReader
  自己管理（屏保定制见 docs/06）。不需要装 ScreenSavers Hack。
- **回退**：插电脑删 USB 盘根目录的 `AUTOSTART_KOREADER`，下次开机即回
  原生界面；或执行 `restore.sh` 完全还原。
  注意：还原后才是一个完整的原生系统（直接删开关文件回原生会缺主页应用，
  见 docs/06 关于"重启进入原生系统"菜单项为何被隐藏）。
- **系统菜单"更新您的 Kindle"**：otaupd 禁用后在线更新失效（这正是目的），
  手动刷 update_*.bin 包仍然可用。
- **WiFi 设置**：首次使用前先完成本定制再连 WiFi，或先连好 WiFi 再定制
  均可；KOReader 内管理 WiFi（换网络：短按"Wi-Fi 连接"关闭后**长按**该项，
  扫描列表即出）。
- 调试期若 KOReader 自启失败：看 /tmp/koreader.err；连续 3 次快速崩溃会
  自动停止自启（防死循环），排查后删掉 /var/local/koreader_start_count
  再重启（restore.sh 和 KUAL 恢复扩展已会自动清除）。
- **重要：恢复出厂设置前必须先跑 restore.sh 完全还原**。出厂重置会删掉
  locale 配置，此时系统的语言选择流程依赖被禁用的组件，会卡在向导页。
  先还原再重置就没有任何影响。

## 微信读书部分

KOReader 里装本仓库的 weread 插件（`plugin/weread.koplugin`，基于开源
微信读书插件深度增强：断点续传/低内存/自动书架/WiFi 按需连接/静默多端同步）。
安装后路径：KOReader 菜单 → 工具 → 微信读书 → 扫码登录 → 书架。
开机自动展开书架、WiFi 按需连接与自动同步的默认配置见 docs/06。
