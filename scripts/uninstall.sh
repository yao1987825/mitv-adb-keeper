#!/bin/bash
# 从电视卸载助手（会停止自动开启 ADB）
set -e
cd "$(dirname "$0")/.."
TV="${TV:-192.168.6.168:5555}"
ADB="${ADB:-$(command -v adb || echo ../platform-tools/adb)}"
"$ADB" connect "$TV" >/dev/null 2>&1
"$ADB" -s "$TV" uninstall com.example.adbkeeper
echo "==> 已卸载，电视下次开机的 ADB 将恢复为需要手动开启"
