#!/bin/sh
# restore.sh — 还原 minimalize.sh 的全部改动（在 Kindle 上执行，需 root）

set -e
# 无论中途在哪一步失败，退出时都把 rootfs 恢复为只读
trap 'mntroot ro 2>/dev/null || true' EXIT

echo "==> 重挂载 rootfs 为可写"
mntroot rw

echo "==> 清除 KOReader 自启的崩溃计数（如有）"
rm -f /var/local/koreader_last_start /var/local/koreader_start_count

echo "==> 恢复 upstart jobs"
for f in /etc/upstart/*.conf.disabled; do
    [ -f "$f" ] || continue
    orig=$(echo "$f" | sed 's/\.disabled$//')
    mv "$f" "$orig"
    echo "    恢复 $(basename $orig)"
done

echo "==> 移除 KOReader 自启 job 与开关文件"
rm -f /etc/upstart/koreader.conf
rm -f /mnt/us/AUTOSTART_KOREADER
rm -f /mnt/us/DONT_START_FRAMEWORK

echo "==> 重挂载 rootfs 为只读"
mntroot ro

echo ""
echo "已完全还原。重启后回到原生系统。"
