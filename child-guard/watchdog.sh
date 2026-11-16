#!/usr/bin/env bash
# 看门狗（cron 每分钟执行）：
#   1) 守护进程不存在 -> 自动拉起
#   2) 提醒页APK被系统清理/卸载 -> 自动重装
#   3) 禁止安装的APP一旦出现 -> 自动卸载（防止孩子反复下载安装）
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
LOG="$HOME/.tv_guard/watchdog.log"
TV="192.168.6.168:5555"

# 引入被禁APP统一处理
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")/.." && pwd)/banned_apps.sh"

# 自动定位 adb（兼容项目内/上级目录/系统 PATH）
resolve_adb() {
  local base d
  base="$(cd "$(dirname "$0")" && pwd)"
  for d in "$base/platform-tools" "$base/../platform-tools" "$base/../../platform-tools" \
           "$base/../../../platform-tools" "$HOME/rikkahub_file/platform-tools"; do
    if [ -x "$d/adb" ]; then echo "$d/adb"; return 0; fi
  done
  command -v adb
}

ADB="$(resolve_adb)"
ADB_TIMEOUT="${ADB_TIMEOUT:-10}"
adb_do() { timeout "$ADB_TIMEOUT" "$ADB" "$@"; }

logger_watchdog() {
  echo "[$(date '+%F %T')] $1" >> "$LOG"
}

# 1) 守护进程自愈
if ! pgrep -f '(^|/)tv_guard\.sh' > /dev/null; then
  setsid ./tv_guard.sh >/dev/null 2>&1 < /dev/null &
  echo "[$(date '+%F %T')] 看门狗：守护进程不存在，已自动拉起" >> "$LOG"
fi

# 2) Kiosk 模式自愈（电视重启/进程被杀后自动拉起）
if [ -f "$DIR/../kiosk/start_kiosk.sh" ]; then
  if ! pgrep -f '(^|/)kiosk\.sh' > /dev/null; then
    setsid "$DIR/../kiosk/start_kiosk.sh" >/dev/null 2>&1 < /dev/null &
    echo "[$(date '+%F %T')] 看门狗：Kiosk 进程不存在，已自动拉起" >> "$LOG"
  fi
fi

# 3) 提醒页APK自愈（电视管家/清理工具可能把它删掉）
if adb_do connect "$TV" >/dev/null 2>&1; then
  if ! adb_do -s "$TV" shell pm path com.example.reminder 2>/dev/null | grep -q "reminder"; then
    if adb_do -s "$TV" install -r reminder/reminder.apk >/dev/null 2>&1; then
      echo "[$(date '+%F %T')] 看门狗：提醒页APK缺失，已自动重装" >> "$LOG"
    fi
  fi

  # 4) 自动卸载禁止的App
  uninstall_banned_apps "$ADB" "$TV" logger_watchdog
fi
exit 0
