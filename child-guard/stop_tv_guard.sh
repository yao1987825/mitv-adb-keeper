#!/usr/bin/env bash
# 停止电视时间守护脚本
# 用法: ./stop_tv_guard.sh
cd "$(dirname "$0")"

# 用 PID 精确匹配，避免误杀 stop/start/watchdog 自身
# 模式 (^|/)tv_guard\.sh 可匹配 "bash ./tv_guard.sh" 和 "bash /abs/path/tv_guard.sh"，
# 但不会匹配 stop_tv_guard.sh / start_tv_guard.sh / watchdog.sh
PIDS=$(pgrep -f '(^|/)tv_guard\.sh' | tr '\n' ' ')
if [ -z "$PIDS" ]; then
  echo "ℹ️  守护进程本来就没有在运行"
  exit 0
fi

echo "正在停止守护进程: $PIDS"
# 先发 SIGTERM（脚本会保存状态后退出），5秒后还活着就强制杀掉
kill $PIDS 2>/dev/null
for i in 1 2 3 4 5; do
  sleep 1
  LEFT=$(pgrep -f '(^|/)tv_guard\.sh' | tr '\n' ' ')
  [ -z "$LEFT" ] && break
done
LEFT=$(pgrep -f '(^|/)tv_guard\.sh' | tr '\n' ' ')
if [ -n "$LEFT" ]; then
  echo "⚠️  未响应 SIGTERM，强制结束: $LEFT"
  kill -9 $LEFT 2>/dev/null
  sleep 1
fi

if pgrep -f '(^|/)tv_guard\.sh' > /dev/null; then
  echo "❌ 停止失败"
  exit 1
else
  echo "✅ 电视时间守护已停止（会话状态已保存）"
fi
