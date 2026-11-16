#!/usr/bin/env bash
##############################################################
#  电视 Kiosk 模式  v1.0
#  开机自动进入 TVBox，其余应用一律屏蔽：
#    · 检测到非白名单应用在前台 → 立即强停，并拉回 TVBox
#    · 按主页键也回不去（桌面同样被屏蔽）
#    · 休息时段（儿童守护进入休息模式）不抢屏，交给提醒页
#
#  用法:
#    ./kiosk.sh                  前台运行
#    ./start_kiosk.sh            后台常驻
#    ./stop_kiosk.sh             停止
##############################################################
set -u
cd "$(dirname "$0")"

CONF="$(dirname "$0")/kiosk.conf"
[ -f "$CONF" ] || { echo "缺少配置: $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
LAUNCHER_PKG="${LAUNCHER_PKG:-com.mitv.tvhome}"

TV_IP="${TV_IP:-192.168.6.168}"
TV_PORT="${TV_PORT:-5555}"
ADB_TARGET="$TV_IP:$TV_PORT"
LOG="${KIOSK_LOG:-$HOME/.tv_guard/kiosk.log}"
SESSION_FILE="${HOME}/.tv_guard/session.txt"
mkdir -p "$(dirname "$LOG")"

# adb 定位
resolve_adb() {
  local base d
  base="$(cd "$(dirname "$0")" && pwd)"
  for d in "$base/../platform-tools" "$base/../../platform-tools" "$base/../../../platform-tools" \
           "$HOME/rikkahub_file/platform-tools"; do
    [ -x "$d/adb" ] && { echo "$d/adb"; return 0; }
  done
  command -v adb
}
ADB_BIN="${ADB_BIN:-$(resolve_adb)}"
ADB_TIMEOUT="${ADB_TIMEOUT:-10}"
adb_do() { timeout "$ADB_TIMEOUT" "$ADB_BIN" "$@"; }

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

ensure_adb() {
  adb_do devices 2>/dev/null | grep -qw "$ADB_TARGET" || adb_do connect "$ADB_TARGET" >/dev/null 2>&1
}

# 当前前台包名
# 注意：这台电视上 mCurrentFocus 经常是 null（屏幕空闲/切换时），
# 必须优先用 mResumedActivity，否则会误判成“未知”而反复拉 TVBox（v1.1 修正）
get_foreground_package() {
  local line pkg
  line=$(adb_do -s "$ADB_TARGET" shell "dumpsys activity activities 2>/dev/null | grep -E 'mResumedActivity|topResumedActivity'" 2>/dev/null | head -n1)
  [ -z "$line" ] && line=$(adb_do -s "$ADB_TARGET" shell "dumpsys window windows 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp'" 2>/dev/null | head -n1)
  pkg=$(echo "$line" | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.]+' | head -n1 | cut -d'/' -f1)
  echo "$pkg"
}

# 解析 TVBox 的启动 Activity（配置里没写死时自动找）
resolve_kiosk_activity() {
  if [ -n "$KIOSK_ACTIVITY" ]; then echo "$KIOSK_ACTIVITY"; return; fi
  local act
  act=$(adb_do -s "$ADB_TARGET" shell "dumpsys package $KIOSK_PACKAGE 2>/dev/null | grep -A3 'android.intent.action.MAIN' | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.]+' | head -n1" 2>/dev/null | tr -d '\r')
  [ -z "$act" ] && act=$(adb_do -s "$ADB_TARGET" shell "pm dump $KIOSK_PACKAGE 2>/dev/null | grep -A3 'android.intent.action.MAIN' | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.]+' | head -n1" 2>/dev/null | tr -d '\r')
  echo "$act"
}

is_allowed() {
  local pkg="$1" p
  [ -z "$pkg" ] && return 1
  for p in "${ALLOWED_PACKAGES[@]}" "${EXTRA_ALLOWED_PACKAGES[@]}"; do
    [ "$pkg" = "$p" ] && return 0
  done
  return 1
}

# 儿童守护是否处于休息/禁用时段（此时不抢屏）
in_break_mode() {
  [ "$RESPECT_BREAK_MODE" = "1" ] || return 1
  local mode
  [ -f "$SESSION_FILE" ] && mode=$(awk '{print $2}' "$SESSION_FILE")
  [ "$mode" = "break" ] || [ "$mode" = "off" ]
}

launch_kiosk() {
  local act
  act=$(resolve_kiosk_activity)
  if [ -z "$act" ]; then
    # 兜底：用包名方式启动（部分ROM支持 -p 过滤）
    adb_do -s "$ADB_TARGET" shell "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p $KIOSK_PACKAGE" >/dev/null 2>&1
    return
  fi
  # act 可能已经是「包名/Activity」，也可能是纯「Activity」；
  # 不能直接拼成 $KIOSK_PACKAGE/$act，否则会变成 包名/包名/Activity（v1.1 修正）
  case "$act" in
    *"$KIOSK_PACKAGE"/*) : ;;
    *) act="$KIOSK_PACKAGE/$act" ;;
  esac
  adb_do -s "$ADB_TARGET" shell "am start -n $act" >/dev/null 2>&1
}

block_and_return() {
  local fg="$1"
  # 桌面(home)不要强停：强停会让系统立即重启它，反而和 Kiosk 反复争夺前台（v1.2 修正）。
  # 其它应用（孩子想打开/已打开的）才强停。
  case "$fg" in
    ""|"$LAUNCHER_PKG") : ;;
    *) adb_do -s "$ADB_TARGET" shell "am force-stop $fg" >/dev/null 2>&1 ;;
  esac
  sleep 1
  launch_kiosk
}

main() {
  log "=== Kiosk 模式启动：$KIOSK_PACKAGE ==="
  sleep "$BOOT_DELAY"
  launch_kiosk
  while true; do
    ensure_adb
    if in_break_mode; then
      # 休息时段：交由儿童守护的提醒页处理，不抢屏
      sleep 5
      continue
    fi
    fg=$(get_foreground_package)
    if ! is_allowed "$fg"; then
      log "检测到非白名单应用「${fg:-未知}」，已屏蔽并拉回 TVBox"
      block_and_return "$fg"
    fi
    sleep "$CHECK_INTERVAL"
  done
}

main "$@"
