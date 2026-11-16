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

# ============================================================================
#  安装白名单：不在允许清单里的 App 一旦被安装就自动卸载
#  受控 App 被孩子卸载后，从备份 APK 自动装回
# ============================================================================
ALLOWED_FILE="$DIR/allowed_apps.txt"
BACKUP_DIR="$DIR/apps"

allowed_list() {
  [ -f "$ALLOWED_FILE" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$ALLOWED_FILE" | sed 's/#.*//' | tr -d ' \t' | grep -v '^$'
}

# 1) 清理不在白名单里的新装 App
enforce_install_whitelist() {
  local pkg allowed
  allowed="$(allowed_list | tr '\n' ' ')"
  for pkg in $(adb_do -s "$TV" shell "pm list packages -3" 2>/dev/null | tr -d '\r' | sed 's/package://'); do
    [ -z "$pkg" ] && continue
    case " $allowed " in *" $pkg "*) continue;; esac
    if adb_do -s "$TV" uninstall "$pkg" >/dev/null 2>&1; then
      logger_watchdog "🚫 检测到白名单外的App「$pkg」已被安装，已自动卸载"
    fi
  done
}

# 2) 受控 App 消失 -> 用备份 APK 装回
restore_watched_apps() {
  local pkg apk
  for pkg in "$@"; do
    apk="$BACKUP_DIR/$pkg.apk"
    [ -f "$apk" ] || continue
    if ! adb_do -s "$TV" shell "pm path $pkg" 2>/dev/null | grep -q "$pkg"; then
      if adb_do -s "$TV" install -r "$apk" >/dev/null 2>&1; then
        logger_watchdog "♻️ 受控App「$pkg」被卸载，已从备份自动装回"
      else
        logger_watchdog "⚠️ 受控App「$pkg」自动装回失败"
      fi
    fi
  done
}

logger_watchdog() {
  echo "[$(date '+%F %T')] $1" >> "$LOG"
}

# 1) 守护进程自愈
if ! pgrep -f '(^|/)tv_guard\.sh' > /dev/null; then
  setsid ./tv_guard.sh >/dev/null 2>&1 < /dev/null &
  echo "[$(date '+%F %T')] 看门狗：守护进程不存在，已自动拉起" >> "$LOG"
fi

# 2) 提醒页APK自愈（电视管家/清理工具可能把它删掉）
if adb_do connect "$TV" >/dev/null 2>&1; then
  if ! adb_do -s "$TV" shell pm path com.example.reminder 2>/dev/null | grep -q "reminder"; then
    if adb_do -s "$TV" install -r reminder/reminder.apk >/dev/null 2>&1; then
      echo "[$(date '+%F %T')] 看门狗：提醒页APK缺失，已自动重装" >> "$LOG"
    fi
  fi

  # 3) 自动卸载禁止的App
  uninstall_banned_apps "$ADB" "$TV" logger_watchdog

  # 4) 安装白名单：新装的App一律卸载
  enforce_install_whitelist

  # 5) 受控App被孩子卸载后自动装回
  restore_watched_apps $(grep -oE 'com\.[A-Za-z0-9_.]+' "$DIR/schedule.conf" 2>/dev/null | sort -u)
fi
exit 0
