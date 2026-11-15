#!/usr/bin/env bash
# 启动电视时间守护（setsid 彻底脱离终端，后台运行）
cd "$(dirname "$0")"

# 防止重复启动（两个守护会互相覆盖状态文件）
if pgrep -f '(^|/)tv_guard\.sh' > /dev/null; then
  echo "ℹ️  守护进程已在运行 (PID: $(pgrep -f '(^|/)tv_guard\.sh' | tr '\n' ' '))"
  exit 0
fi

setsid ./tv_guard.sh >/dev/null 2>&1 < /dev/null &
sleep 1
if pgrep -f '(^|/)tv_guard\.sh' > /dev/null; then
  echo "✅ 守护已启动 (PID: $(pgrep -f '(^|/)tv_guard\.sh' | head -n1))"
else
  echo "❌ 启动失败，请查看日志: ~/.tv_guard/tv_guard.log"
  exit 1
fi
