#!/usr/bin/env bash
# ============================================================================
#  AdbKeeper 健康看门狗（cron 每分钟执行）
#  作用：确保电视开机后 ADB 能自动开启。
#  原理：电视系统每次开机都会关掉 ADB，必须靠电视端 com.example.adbkeeper
#        助手重新打开。若助手被系统置为「停止状态」(stopped=true)，其排定
#        任务会被取消，就再也开不了 ADB —— 本脚本负责发现并修复这一状态。
# ============================================================================
TV_IP="${TV_IP:-192.168.6.168}"
TV="$TV_IP:5555"
PKG="com.example.adbkeeper"
LOG="${KEEPER_LOG:-$HOME/.tv_control/watchdog.log}"
ADB="${ADB:-/home/yao/rikkahub_file/platform-tools/adb}"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%F %T')] $1" >> "$LOG"; }

timeout 20 "$ADB" connect "$TV" >/dev/null 2>&1
if ! timeout 15 "$ADB" -s "$TV" get-state >/dev/null 2>&1; then
    # ADB 不可用：电视可能关机，或开机后助手尚未恢复 ADB（助手一般 30~120 秒内恢复）
    if ping -c 1 -W 2 "$TV_IP" >/dev/null 2>&1; then
        log "⚠️ 电视在线但 ADB 未开，等待助手自动恢复（若长时间未恢复需手动开 ADB）"
    fi
    exit 0
fi

# ADB 可用：检查助手健康度
if ! timeout 15 "$ADB" -s "$TV" shell "pm path $PKG" 2>/dev/null | grep -q "$PKG"; then
    log "❌ 助手未安装（com.example.adbkeeper），ADB 开机将无法自动恢复"
    exit 0
fi

STATE=$(timeout 15 "$ADB" -s "$TV" shell "dumpsys package $PKG | grep 'User 0'" 2>/dev/null | tr -d '\r')
if echo "$STATE" | grep -q "stopped=true"; then
    log "🔧 检测到助手处于「停止状态」，正在拉起修复…"
    timeout 20 "$ADB" -s "$TV" shell "am start -n $PKG/.MainActivity" >/dev/null 2>&1
    sleep 4
    NEW=$(timeout 15 "$ADB" -s "$TV" shell "dumpsys package $PKG | grep 'User 0'" 2>/dev/null | tr -d '\r')
    if echo "$NEW" | grep -q "stopped=false"; then
        log "✅ 助手已恢复运行（stopped=false），开机自启能力已恢复"
    else
        log "❌ 助手拉起失败"
    fi
    exit 0
fi

# 任务是否还在
JOBS=$(timeout 20 "$ADB" -s "$TV" shell "dumpsys jobscheduler 2>/dev/null | grep -c $PKG" 2>/dev/null | tr -d '\r')
if [ "${JOBS:-0}" = "0" ]; then
    log "🔧 助手任务丢失，重新拉起以恢复排定任务…"
    timeout 20 "$ADB" -s "$TV" shell "am start -n $PKG/.MainActivity" >/dev/null 2>&1
    log "✅ 已重新拉起助手"
fi
