#!/bin/bash
# 安装到电视并完成配置
set -e
cd "$(dirname "$0")/.."
TV="${TV:-192.168.6.168:5555}"
ADB="${ADB:-$(command -v adb || echo ../platform-tools/adb)}"

"$ADB" connect "$TV"
sleep 1
"$ADB" -s "$TV" install -r dist/adbkeeper.apk

# 启动一次：解除“停止状态”并注册持久化任务
"$ADB" -s "$TV" shell am start -n com.example.adbkeeper/.MainActivity
sleep 6

# 确保 ADB 关键设置已打开
"$ADB" -s "$TV" shell settings put global adb_enabled 1
"$ADB" -s "$TV" shell settings put global developer_status 1
"$ADB" -s "$TV" shell settings put global development_settings_enabled 1

echo "==> 安装完成。重启电视验证："
echo "    adb -s $TV reboot"
