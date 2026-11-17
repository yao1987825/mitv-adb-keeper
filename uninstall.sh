#!/usr/bin/env bash
# 一键卸载：移除看门狗、AdbKeeper 助手，并把电视恢复原状
set -e
BASE="$(cd "$(dirname "$0")" && pwd)"
TV="${TV:-192.168.6.168:5555}"
ADB_BIN="${ADB:-$(command -v adb || echo $HOME/rikkahub_file/platform-tools/adb)}"

echo "==> 移除 cron 看门狗"
crontab -l 2>/dev/null | grep -v 'keeper_watchdog.sh' | crontab - || true
echo "   ✅ 已移除"

echo "==> 卸载 AdbKeeper 助手（电视恢复为「开机需手动开 ADB」）"
"$ADB_BIN" connect "$TV" >/dev/null 2>&1 || true
"$ADB_BIN" -s "$TV" uninstall com.example.adbkeeper 2>&1 | tail -1 || true
echo "   ✅ 已卸载"

rm -rf "$HOME/.tv_control"
echo "✅ 卸载完成（电视端已恢复原状：系统每次开机会关闭 ADB）"
