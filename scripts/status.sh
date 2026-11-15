#!/bin/bash
# 打印 AdbKeeper 运行状态摘要（供人工检查 / 助手读取后反馈）
set -u
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="${DATA_DIR:-$BASE_DIR/data}"
LOG="$DATA_DIR/watchdog.log"
STATUS="$DATA_DIR/status.txt"
TV_IP="${TV_IP:-192.168.6.168}"
TV_PORT="${TV_PORT:-5555}"

echo "══════════════════════════════════════"
echo " AdbKeeper 电视 ADB 守护状态"
echo " 时间: $(date '+%F %T')"
echo " 电视: $TV_IP:$TV_PORT"
echo "══════════════════════════════════════"

if [ -f "$STATUS" ]; then
    echo "── 当前状态 ──"
    cat "$STATUS"
else
    echo "── 当前状态 ──\n(尚无记录)"
fi

if nc -z -w 2 "$TV_IP" "$TV_PORT" >/dev/null 2>&1; then
    echo "── 实时探测 ──"
    echo "ADB 端口: ✅ 可用"
else
    echo "── 实时探测 ──"
    echo "ADB 端口: ❌ 不可用"
fi

if [ -f "$LOG" ]; then
    echo "── 近 7 天统计 ──"
    total=$(wc -l <"$LOG")
    ok=$(grep -c '✅' "$LOG" || true)
    warn=$(grep -c '⚠️' "$LOG" || true)
    err=$(grep -c '❌' "$LOG" || true)
    echo "日志总条数: $total   正常: $ok   告警: $warn   失败: $err"
    last_fail=$(grep '❌' "$LOG" | tail -1)
    [ -n "$last_fail" ] && echo "最近一次失败: $last_fail"
    last_fix=$(grep '修复成功' "$LOG" | tail -1)
    [ -n "$last_fix" ] && echo "最近一次修复: $last_fix"
    echo "── 最近 10 条日志 ──"
    tail -10 "$LOG"
fi
