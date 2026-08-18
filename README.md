# weread-kpw3 — Kindle Paperwhite 3 极简微信读书阅读器改造全记录

把一台 KPW3（第 7 代 Kindle，固件 5.16.2.1.1 已停更）改造成**开机直达微信读书**的专用阅读器：越狱 → KOReader → 微信读书插件（增强版）→ 精简原生系统 → 个性化屏保。

**本仓库面向 AI Agent 交付**：文档按"另一个 Agent 拿到本仓库即可复刻"的标准编写，包含全部操作步骤、命令、参数和踩坑记录。人类读者同样适用。

## 最终效果

- 开机自动进入 KOReader（不经过原生系统界面）
- 微信读书插件增强：断点续传、低内存模式、启动自动开书架、一键重启回原生系统
- **WiFi 按需连接**：前台动作自动连、用完自动关；自动同步（进度+阅读时长）静默后台联网，绝不主动叫醒 WiFi
- **多端进度同步**：打开书自动拉远端进度，合书/合盖自动上传，休眠打断唤醒后补传
- 合盖休眠 / 电源键短按休眠唤醒（正常功耗）
- 极简系统：禁用 18 个无关原生服务（OTA 遥测推送、30 秒心跳等）
- 自定义屏保：白底图片 + 双层花边消息框（宽度自适应）+ 随机文案轮换
- 精简菜单：文件管理器与阅读界面两套菜单均按需隐藏，新增"关机"项

## 硬件与版本前提

| 项 | 值 | 说明 |
|---|---|---|
| 设备 | Kindle Paperwhite 3 (KPW3, 代号 muscat) | i.MX6SL / 512MB RAM / 758×1024 |
| 固件 | 5.16.2.1.1（最终版，官方已停更） | 本仓库全部分析基于此版本 |
| 越狱方式 | LanguageBreak | 固件 ≤ 5.16.2.1.1 适用 |
| KOReader | v2026.07.1 (kindlepw2 包) | |
| hotfix | KindleModding 通用 hotfix 2.5.0 | 注意：不是 LanguageBreak 自带 hotfix，原因见 docs/02 |

其他型号/固件不要直接照抄命令，但 docs/05 踩坑记录里的分析方法是通用的。

## 目录结构

```
docs/                    # 全过程文档（按顺序读）
  01-固件分析.md          # 官方固件完整拆解：分区/启动链/服务清单
  02-越狱与部署.md        # LanguageBreak 越狱 → hotfix → KUAL → KOReader → 插件
  03-极简定制.md          # 服务精简 + 开机自启 KOReader 的原理与操作
  04-串口救砖全记录.md    # 软砖 → 串口 → u-boot → init=/bin/sh 修复全过程
  05-踩坑记录.md          # ★ 所有坑的汇总（复刻前必读）
  06-KOReader个性化.md    # kafshim/powermenu/sleepmsg 插件、菜单定制、屏保定制
  附录-部署前评审报告.md   # 改动上机前的风险评审样例
  assets/bootlog-excerpt.txt  # 真实启动日志（序列号已脱敏），供比对
custom/                  # 所有自制文件（可直接部署）
  minimalize.sh          # 极简定制脚本（★ 已修复 demd 致命坑的版本）
  restore.sh             # 一键还原
  files/etc/upstart/koreader.conf   # KOReader 开机自启 upstart job
  kafshim.koplugin/      # 电源键修复插件（替代 framework 向 powerd 报到）
  powermenu.koplugin/    # "关机"菜单项解锁
  sleepmsg.koplugin/     # 屏保文案轮换（附样例文案，自行替换）
  koreader-settings/filemanager_menu_order.lua   # 菜单定制
  koreader-icons/notice-heart.svg                # 屏保爱心图标
  screensaver-lace-block.lua                     # 屏保花边消息框代码块
plugin/weread.koplugin/  # 微信读书插件（增强版，本项目的配套核心）
```

**不包含**（需自行准备，文档里有获取方式）：官方固件、KOReader/LanguageBreak/hotfix/KUAL 安装包、屏保图片。

## 快速复刻路线（Agent 用）

1. 读 `docs/01` 确认目标设备固件版本与分区结构一致；
2. 按 `docs/02` 完成越狱与基础部署；
3. 按 `docs/03` 做极简定制——**必须使用本仓库的 minimalize.sh**（官方清单里的 `demd` 禁用会让设备变砖，见 docs/04/05）；
4. 按 `docs/06` 安装三个自制 KOReader 插件（kafshim 是电源键能用的前提）；
5. 任何一步与预期不符，先查 `docs/05`。

## 免责与许可

- 操作设备有风险，本项目造成的后果自负；救砖方法见 docs/04。
- 第三方组件（KOReader、LanguageBreak、hotfix、KUAL、KindleTool 等）版权归各自作者，遵循其原始许可。
- `plugin/weread.koplugin` 基于开源微信读书插件二次开发，版权归原作者所有。
- 本仓库自制部分（文档、脚本、插件）可自由使用。
