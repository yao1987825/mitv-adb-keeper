#!/bin/bash
# 小米电视 ADB 快速连接脚本
# 用法: ./connect_tv.sh          连接电视
#       ./connect_tv.sh status   查看状态
#       ./connect_tv.sh shell    进入电视 shell
#       ./connect_tv.sh reboot   重启电视

BASE="$(cd "$(dirname "$0")" && pwd)"
ADB=""
for d in "$BASE/platform-tools" "$BASE/../platform-tools" "$BASE/../../platform-tools" \
         "$BASE/../../../platform-tools" "$HOME/rikkahub_file/platform-tools"; do
  [ -x "$d/adb" ] && { ADB="$d/adb"; break; }
done
[ -z "$ADB" ] && ADB="$(command -v adb)"
TV="192.168.6.168:5555"

case "$1" in
  status)
    $ADB connect $TV >/dev/null 2>&1
    if $ADB devices | grep -q "192.168.6.168:5555.*device"; then
      echo "✅ 电视 ADB 已连接"
      $ADB -s $TV shell "echo adb_enabled=[\$(settings get global adb_enabled)] usb.config=[\$(getprop persist.sys.usb.config)]"
    else
      echo "❌ 未连接（电视刚开机时请等待 1-2 分钟，助手会自动开启 ADB）"
    fi
    ;;
  shell)
    $ADB connect $TV >/dev/null 2>&1; $ADB -s $TV shell
    ;;
  reboot)
    $ADB connect $TV >/dev/null 2>&1; $ADB -s $TV reboot
    ;;
  *)
    $ADB connect $TV
    $ADB devices -l
    ;;
esac
