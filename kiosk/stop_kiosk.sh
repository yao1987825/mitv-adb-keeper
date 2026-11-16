#!/usr/bin/env bash
# 停止 Kiosk 模式
pids=$(pgrep -f '(^|/)kiosk\.sh' | tr '\n' ' ')
if [ -n "$pids" ]; then
  pkill -f '(^|/)kiosk\.sh'
  sleep 1
  echo "✅ Kiosk 已停止 (PID: $pids)"
else
  echo "ℹ️  Kiosk 未在运行"
fi
