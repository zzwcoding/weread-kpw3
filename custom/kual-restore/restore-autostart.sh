#!/bin/sh
# restore-autostart.sh — 恢复「开机直达 KOReader」（在原生系统的 KUAL 里执行）
#
# 背景：KPW3 极简定制（见 custom/minimalize.sh）的效果由 USB 盘根目录的
# 两个开关文件控制：
#   /mnt/us/AUTOSTART_KOREADER   → /etc/upstart/koreader.conf 据此开机自启 KOReader
#   /mnt/us/DONT_START_FRAMEWORK → /etc/upstart/framework.conf 据此跳过原生 Java 界面
# 微信读书插件菜单「设置 → 启动与系统 → 重启进入原生系统」会删除这两个文件
# 并重启；本扩展做反向操作：重建开关文件并重启，回到开机直达 KOReader。
#
# 安装：把整个 kual-restore 目录拷到 Kindle 的 /mnt/us/extensions/ 下
#   （即设备上路径为 /mnt/us/extensions/kual-restore/），
#   然后在原生系统打开 KUAL →「恢复开机直达 KOReader」。

set -e
# 无论脚本中途在哪一步失败，都把 rootfs 恢复为只读（busybox ash 支持 EXIT trap）
trap 'mntroot ro 2>/dev/null || true' EXIT

EXT_DIR=$(dirname "$0")

echo "==> 清除 KOReader 自启的崩溃计数（如有）"
rm -f /var/local/koreader_last_start /var/local/koreader_start_count

if [ ! -f /etc/upstart/koreader.conf ]; then
    if [ -f "$EXT_DIR/koreader.conf" ]; then
        echo "==> /etc/upstart/koreader.conf 不存在，用扩展自带副本恢复"
        mntroot rw
        cp "$EXT_DIR/koreader.conf" /etc/upstart/koreader.conf
        mntroot ro
    else
        # koreader.conf 无法恢复：绝不能带着 DONT_START_FRAMEWORK 重启
        # （那样 framework 不起、KOReader 也不起，会停在无任何界面的状态）。
        # 安全回退：确保开关文件不存在，留在原生系统，提示用户重新定制。
        echo "!! 错误：/etc/upstart/koreader.conf 不存在，且扩展目录没有副本。"
        echo "!! 无法恢复开机直达；将留在原生系统。请重新执行 minimalize.sh。"
        rm -f /mnt/us/AUTOSTART_KOREADER /mnt/us/DONT_START_FRAMEWORK
        exit 1
    fi
fi

echo "==> 重建开机开关文件"
touch /mnt/us/AUTOSTART_KOREADER
touch /mnt/us/DONT_START_FRAMEWORK

echo "==> 完成。重启后开机直达 KOReader（微信读书在 KOReader 菜单里）。"
echo "==> 3 秒后重启……"
sync
sleep 3
reboot
