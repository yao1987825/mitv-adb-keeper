#!/usr/bin/env bash
# ============================================================================
#  一键部署：小米电视 ADB 自动开启 + 电视控制技能
#  用法: bash install.sh [电视IP]
#  依赖: adb（自动在 ../platform-tools、~/rikkahub_file/platform-tools 中查找）
# ============================================================================
set -e
BASE="$(cd "$(dirname "$0")" && pwd)"
TV_IP="${1:-192.168.6.168}"
TV="$TV_IP:5555"

find_adb() {
    local c
    for c in "${ADB:-}" "$(command -v adb || true)" \
             "$BASE/../../platform-tools/adb" "$BASE/../platform-tools/adb" \
             "$HOME/rikkahub_file/platform-tools/adb"; do
        [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
    done
    echo ""
}
ADB_BIN="$(find_adb)"
[ -z "$ADB_BIN" ] && { echo "❌ 找不到 adb，请设置环境变量 ADB"; exit 1; }
echo "==> adb: $ADB_BIN"

echo "==> 连接电视 $TV"
"$ADB_BIN" connect "$TV" || true
sleep 2
if ! "$ADB_BIN" -s "$TV" get-state >/dev/null 2>&1; then
    echo "❌ 连不上电视 $TV"
    echo "   · 确认电视已开机"
    echo "   · 若 ADB 未开：电视 设置 → 账户与安全 → ADB调试 打开，等 1 分钟再试"
    exit 1
fi

echo "==> 安装 AdbKeeper 助手（开机自动开 ADB）"
"$ADB_BIN" -s "$TV" install -r "$BASE/adbkeeper/dist/adbkeeper.apk" 2>&1 | tail -1
# 关键：安装后必须拉起一次，否则 Android 会把应用置为「停止状态」，
# 其排定任务会被取消，ADB 就不会自动开启了。
"$ADB_BIN" -s "$TV" shell "am start -n com.example.adbkeeper/.MainActivity" >/dev/null 2>&1
sleep 4
STATE=$("$ADB_BIN" -s "$TV" shell "dumpsys package com.example.adbkeeper | grep 'User 0'" | tr -d '\r')
echo "$STATE" | grep -q "stopped=false" \
    && echo "   ✅ 助手运行正常（stopped=false）" \
    || echo "   ⚠️ 助手仍处于停止状态，请手动执行: adb -s $TV shell am start -n com.example.adbkeeper/.MainActivity"

echo "==> 注册看门狗（cron 每分钟体检，助手被系统置停时自动修复）"
CRON_LINE="* * * * * $BASE/scripts/keeper_watchdog.sh >> $HOME/.tv_control/watchdog.log 2>&1"
( crontab -l 2>/dev/null | grep -v 'keeper_watchdog.sh'; echo "$CRON_LINE" ) | crontab -
echo "   ✅ 已注册 cron"

echo "==> 打包技能"
bash "$BASE/build_zip.sh" "${2:-$BASE/../../tv-control-rikkahub.zip}" || true

echo
echo "✅ 部署完成！"
echo "   · 电视每次开机后约 1 分钟 ADB 自动开启"
echo "   · 技能包: ${2:-$BASE/../../tv-control-rikkahub.zip}（RikkaHub → 设置 → 扩展管理 → 技能 → + → 从文件导入）"
echo "   · 常用命令: python3 $BASE/scripts/tvctl.py status"
