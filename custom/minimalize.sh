#!/bin/sh
# minimalize.sh — KPW3 极简系统定制（从 KUAL 菜单执行，或 SSH 手动执行）
#
# 作用：禁用一切与"KOReader + 微信读书"无关的原生服务，安装开机自启 job。
# 依据：notes/firmware-analysis.md 第 4 节可精简服务清单。
# 原则：只改名/加文件，不删文件；restore.sh 一键还原。
#
# 参数：--keep-ssh  保留系统自带 SSH（默认禁用；usbnet 插件自带 SSH 不受影响）

set -e
# 无论中途在哪一步失败，退出时都把 rootfs 恢复为只读
trap 'mntroot ro 2>/dev/null || true' EXIT

KEEP_SSH=0
[ "$1" = "--keep-ssh" ] && KEEP_SSH=1

EXT_DIR=$(dirname "$0")
BACKUP="$EXT_DIR/backup"
mkdir -p "$BACKUP"

echo "==> 重挂载 rootfs 为可写"
mntroot rw

echo "==> 清除 KOReader 自启的崩溃计数（如有）"
rm -f /var/local/koreader_last_start /var/local/koreader_start_count

# --- 1. 禁用的 upstart job 清单（改名 .conf → .conf.disabled） ---
# 原生界面全家桶（独立于 framework，必须显式禁）
JOBS="kppmainapp kfxreader kfxview pillow statusbar"
# OTA 后台（保留 ota-update.conf 和 otaup，手动刷包仍可用）
JOBS="$JOBS otaupd otav3"
# 遥测/日志收集（注意：demd 不能禁！lab126.conf 的启动条件是
# "start on ... and started demd"，禁了 demd 会导致 lab126 及整个
# 电源/USB/WiFi 守护层永不启动，开机卡死在树标画面）
JOBS="$JOBS tmd iohwlogs printklogs last_debug_info"
# 亚马逊后台推送/内容管理
JOBS="$JOBS todo maruinstall wfmupdate wfmdelete wfm_forceupdate"
# 工厂测试守护
JOBS="$JOBS testd"
# 系统自带 SSH（usbnet 插件自带 dropbear，不需要系统的）
[ $KEEP_SSH -eq 0 ] && JOBS="$JOBS sshd"

echo "==> 禁用 upstart jobs"
for j in $JOBS; do
    conf=/etc/upstart/$j.conf
    if [ -f "$conf" ]; then
        cp -n "$conf" "$BACKUP/$j.conf"
        mv "$conf" "$conf.disabled"
        echo "    禁用 $j"
    else
        echo "    跳过 $j（不存在，可能已禁用）"
    fi
done

# --- 2. 掐掉 Java framework（官方开关，一行系统文件都不用改）---
# framework.conf 的 pre-start 检查此文件；framework 不启动，则下游
# webreader/scanner/stored/dmld/clickstream/fastmetrics/whisperstore 全不起
echo "==> 创建 DONT_START_FRAMEWORK 开关（禁用 Java framework）"
touch /mnt/us/DONT_START_FRAMEWORK

# --- 3. 安装 KOReader 开机自启 job + 开关 ---
echo "==> 安装 koreader.conf"
cp "$EXT_DIR/files/etc/upstart/koreader.conf" /etc/upstart/koreader.conf
touch /mnt/us/AUTOSTART_KOREADER

# --- 4. 收尾 ---
echo "==> 重挂载 rootfs 为只读"
mntroot ro

echo ""
echo "完成。重启后生效："
echo "  开机 → KOReader（微信读书在 KOReader 菜单里）"
echo ""
echo "回退方法（任选）："
echo "  A. 插电脑，删掉 USB 盘根目录的 AUTOSTART_KOREADER → 下次开机回原生界面"
echo "  B. 执行 restore.sh → 完全还原所有改动"
