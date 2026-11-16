#!/usr/bin/env bash
# 启动 Kiosk 模式（后台常驻，防重复启动）
cd "$(dirname "$0")"

if pgrep -f '(^|/)kiosk\.sh' > /dev/null; then
  echo "ℹ️  Kiosk 已在运行 (PID: $(pgrep -f '(^|/)kiosk\.sh' | tr '\n' ' '))"
  exit 0
fi

setsid ./kiosk.sh >/dev/null 2>&1 < /dev/null &
sleep 1
if pgrep -f '(^|/)kiosk\.sh' > /dev/null; then
  echo "✅ Kiosk 已启动 (PID: $(pgrep -f '(^|/)kiosk\.sh' | head -n1))"
else
  echo "❌ 启动失败，日志: ~/.tv_guard/kiosk.log"
  exit 1
fi
