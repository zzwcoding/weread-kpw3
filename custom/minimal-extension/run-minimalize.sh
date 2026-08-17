#!/bin/sh
# KUAL 入口包装：执行极简定制，输出写入 last-run.log 供事后查看
EXT_DIR=$(dirname "$0")
sh "$EXT_DIR/minimalize.sh" > "$EXT_DIR/last-run.log" 2>&1
