#!/usr/bin/env bash
##############################################################
#  电视儿童观看时间管理 (ADB版)  v1.4
#  适用：小米电视4 (192.168.6.168, Android 6.0.1)
#
#  功能：
#    1. 单次连续观看达到 WATCH_LIMIT_MIN 分钟 -> 强停App并强制休息
#    2. 休息 BREAK_MIN 分钟后方可继续观看
#    3. 每天累计观看达到 DAILY_LIMIT_MIN 分钟 -> 当天禁止观看
#    4. 可选：只允许在指定时间段内观看
#    5. 可选：到时直接熄屏
#
#  用法：
#    chmod +x tv_guard.sh
#    ./tv_guard.sh
#    后台运行: nohup ./tv_guard.sh > /dev/null 2>&1 &
#    停止:     pkill -f tv_guard.sh
##############################################################

set -u

# ================= 配置区（按需修改） =================
# ADB 可执行文件（自动探测）
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

ADB_BIN="${ADB_BIN:-$(resolve_adb)}"

# 所有 adb 调用都加超时：电视关机/断网时命令会悬空，
# 不加超时会把守护循环卡死（v1.7 修正）
ADB_TIMEOUT="${ADB_TIMEOUT:-10}"
adb_do() { timeout "$ADB_TIMEOUT" "$ADB_BIN" "$@"; }

TV_IP="192.168.6.168"        # 小米电视IP
ADB_PORT="5555"
ADB_TARGET="$TV_IP:$ADB_PORT"

# 观看规则与时段表统一放在 schedule.conf（家长直接改那个文件即可）
SCHED_CONF="$(dirname "$0")/schedule.conf"
[ -f "$SCHED_CONF" ] || { echo "缺少配置: $SCHED_CONF"; exit 1; }
# shellcheck disable=SC1091
. "$SCHED_CONF"
# 说明：当前为严格累计模式，切App/关机都不重置计时；
#       完成一次休息或跨天后才归零。
CHECK_INTERVAL=5             # 正常检测间隔（秒）
BREAK_CHECK_INTERVAL=2       # 休息/禁用期间的检测间隔（秒），越短拦截越快

# 注意：本电视是 Android 6.0.1，不支持 pm suspend，必须保持 0
SUSPEND_MODE=0
TURN_OFF_SCREEN=0            # 1=到时直接熄屏，0=只回桌面

# ====================================================

STATE_DIR="${HOME}/.tv_guard"
STATE_FILE="$STATE_DIR/daily_usage.txt"
SESSION_FILE="$STATE_DIR/session.txt"
LOG_FILE="$STATE_DIR/tv_guard.log"
mkdir -p "$STATE_DIR"

# ---------------- 工具函数 ----------------
# 时间统一用中国时区（Asia/Shanghai），与电视/家庭作息一致
TZ_CHINA="Asia/Shanghai"
log() { echo "[$(TZ=$TZ_CHINA date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
today() { TZ=$TZ_CHINA date +%F; }
now_sec() { date +%s; }

# 确保ADB已连接
ensure_adb() {
  if ! adb_do devices 2>/dev/null | grep -qw "$ADB_TARGET"; then
    adb_do connect "$ADB_TARGET" >/dev/null 2>&1
    sleep 1
  fi
  adb_do -s "$ADB_TARGET" get-state >/dev/null 2>&1 || adb_do connect "$ADB_TARGET" >/dev/null 2>&1
}

# 获取当前前台App包名
# 当前前台完整组件（包名/Activity），用于识别模式切换等特定界面
get_foreground_component() {
  local line
  line=$(adb_do -s "$ADB_TARGET" shell "dumpsys activity activities 2>/dev/null | grep -E 'mResumedActivity|topResumedActivity'" 2>/dev/null | head -n1)
  [ -z "$line" ] && line=$(adb_do -s "$ADB_TARGET" shell "dumpsys window windows 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp'" 2>/dev/null | head -n1)
  echo "$line" | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.]+' | head -n1
}

get_foreground_package() {
  local line pkg
  line=$(adb_do -s "$ADB_TARGET" shell "dumpsys window windows 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp'" 2>/dev/null | head -n1)
  [ -z "$line" ] && line=$(adb_do -s "$ADB_TARGET" shell "dumpsys activity activities 2>/dev/null | grep -E 'mResumedActivity|topResumedActivity'" 2>/dev/null | head -n1)
  pkg=$(echo "$line" | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.]+' | head -n1 | cut -d'/' -f1)
  echo "$pkg"
}


# ============================================================================
#  时段表判定
#  current_block_period → 命中禁止时段时输出 "名称|剩余秒数"，未命中返回 1
# ============================================================================
current_block_period() {
  local cur p s e name sv sm ev emin smin hit remain
  cur=$(( 10#$(TZ=$TZ_CHINA date +%H) * 60 + 10#$(TZ=$TZ_CHINA date +%M) ))
  for p in "${BLOCK_PERIODS[@]}"; do
    read -r s e name <<< "$p"
    [ -z "$s" ] && continue
    sv=${s%%:*}; sm=${s##*:}; ev=${e%%:*}; em=${e##*:}
    smin=$(( 10#$sv * 60 + 10#$sm ))
    emin=$(( 10#$ev * 60 + 10#$em ))
    hit=0
    if [ "$smin" -lt "$emin" ]; then
      if [ "$cur" -ge "$smin" ] && [ "$cur" -lt "$emin" ]; then hit=1; fi
    else
      if [ "$cur" -ge "$smin" ] || [ "$cur" -lt "$emin" ]; then hit=1; fi
    fi
    if [ "$hit" = "1" ]; then
      if [ "$smin" -lt "$emin" ]; then
        remain=$(( (emin - cur) * 60 ))
      elif [ "$cur" -ge "$smin" ]; then
        remain=$(( (1440 - cur + emin) * 60 ))
      else
        remain=$(( (emin - cur) * 60 ))
      fi
      echo "$name|$remain"
      return 0
    fi
  done
  return 1
}

# 睡觉时段（名称含"睡"）是否需要熄屏
is_sleep_period() {
  case "$1" in *睡*) return 0;; esac
  return 1
}

# 引入被禁APP统一处理（发现即卸载）
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")/.." && pwd)/banned_apps.sh"

# 判断是否受管控App
is_watch_app() {
  local pkg="$1" p
  [ -z "$pkg" ] && return 1
  for p in "${WATCH_PACKAGES[@]}"; do
    [ "$pkg" = "$p" ] && return 0
  done
  return 1
}

# 强停所有受管控App
# 注意：这里不再按 HOME 键。
# 之前按 HOME 键后，桌面会在「提醒页」之后才切到前台，把提醒页整个盖住，
# 结果孩子只看到桌面、看不到提醒（v1.3 修正）。
# 强停前台App后系统本就会自动回到桌面，无需再按 HOME。
force_stop_all() {
  local pkg
  for pkg in "${WATCH_PACKAGES[@]}"; do
    adb_do -s "$ADB_TARGET" shell "am force-stop $pkg" >/dev/null 2>&1
  done
}

# 提醒页包名
REMINDER_PKG="com.example.reminder"

# 显示/隐藏休息提醒页（全屏封面）
# 参数1: 剩余休息秒数；-1 表示"今天不能再看了"
show_reminder() {
  local remain="${1:--1}" night="${2:-0}" period="${3:-}"
  adb_do -s "$ADB_TARGET" shell "am start -n $REMINDER_PKG/.MainActivity --ei remain_sec $remain --ei night_mode $night --es period '$period'" >/dev/null 2>&1
}
hide_reminder() {
  adb_do -s "$ADB_TARGET" shell "am force-stop com.example.reminder" >/dev/null 2>&1
}

# 电视桌面(启动器)包名
LAUNCHER_PKG="com.mitv.tvhome"

# 判断是否需要重新弹出提醒页
# v1.3 修正：只在「受控App被打开」时才弹提醒页。
#   之前是「孩子回到桌面(空闲)就弹」→ 开机后电视停在桌面，封面立刻盖满全屏，
#   看起来像整个电视都被禁用。现在回到桌面、打开其它App 都不会再弹，
#   只有真的去开那 3 个受控App 才会被拦下并看到提醒页。
should_reshow_reminder() {
  local fg="$1"
  [ -z "$fg" ] && return 1
  [ "$fg" = "$REMINDER_PKG" ] && return 1
  return 1          # 任何其它情况都不再自动弹出
}

# 到时执行：强停 + 弹出提醒页 + 可选熄屏
block_action() {
  local remain="${1:--1}" night="${2:-0}"
  force_stop_all
  sleep 1
  show_reminder "$remain" "$night"
  adb_do -s "$ADB_TARGET" shell "cmd notification post -t '时间管理提醒' guard '小朋友休息一下，让眼睛放松放松吧~'" >/dev/null 2>&1 || true
  if [ "$TURN_OFF_SCREEN" = "1" ]; then
    adb_do -s "$ADB_TARGET" shell "input keyevent KEYCODE_SLEEP" >/dev/null 2>&1
  fi
  log "已强制暂停观看"
}

# 解除禁用（本电视用不到，保留兼容）
release_action() {
  hide_reminder
}

# 读取当天已观看秒数（兼容旧格式：日期+分钟）
load_daily_used() {
  local t d m
  t=$(today)
  if [ -f "$STATE_FILE" ]; then
    if grep -q 'seconds=' "$STATE_FILE" 2>/dev/null; then
      d=$(grep -o 'date=[^ ]*' "$STATE_FILE" | head -n1 | cut -d= -f2)
      m=$(grep -o 'seconds=[^ ]*' "$STATE_FILE" | head -n1 | cut -d= -f2)
      if [ "$d" = "$t" ]; then echo "${m:-0}"; else echo 0; fi
    else
      read -r d m < "$STATE_FILE" 2>/dev/null || { d=""; m=0; }
      if [ "$d" = "$t" ]; then echo $(( m * 60 )); else echo 0; fi
    fi
  else
    echo 0
  fi
}

# 保存当天已观看秒数（同时写出分钟数方便人看）
save_daily_used() {
  local sec=$1
  printf 'date=%s seconds=%d minutes=%d\n' "$(today)" "$sec" "$(( (sec + 59) / 60 ))" > "$STATE_FILE"
}

# 读取持久化的会话状态（防止关机/重启清空计时）
load_session() {
  local d m w b
  if [ -f "$SESSION_FILE" ]; then
    read -r d m w b < "$SESSION_FILE" 2>/dev/null || return
    if [ "$d" = "$(today)" ]; then
      [ -n "$m" ] && mode="$m"
      [ -n "$w" ] && watch_elapsed="${w:-0}"
      [ -n "$b" ] && break_elapsed="${b:-0}"
    fi
  fi
}

# 保存会话状态
save_session() {
  printf '%s %s %s %s\n' "$(today)" "$mode" "$watch_elapsed" "$break_elapsed" > "$SESSION_FILE"
}

# ---------------- 退出处理 ----------------
cleanup() {
  save_session
  log "脚本退出（会话状态已保存）"
}
# 注意：EXIT 负责正常退出时保存状态；
# INT/TERM 必须显式 exit，否则 bash 执行完 trap 会继续跑，进程停不掉！
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

# ---------------- 主循环 ----------------
main() {
  local daily_used away_elapsed prev_mode fg is_watch last_day current_day current_hm last_block_log

  mode="watch"
  watch_elapsed=0
  break_elapsed=0
  daily_used=$(load_daily_used)
  load_session
  away_elapsed=0
  prev_mode=""
  last_day="$(today)"
  last_block_log=0

  log "=== 电视时间守护启动 ==="
  log "恢复状态: 模式=$mode 本次已看=$((watch_elapsed/60))分钟 休息已过=$((break_elapsed/60))分钟"
  log "电视 $ADB_TARGET | 单次 ${WATCH_LIMIT_MIN}分钟 / 休息 ${BREAK_MIN}分钟 / 每日上限 ${DAILY_LIMIT_MIN}分钟 / 检测间隔 ${CHECK_INTERVAL}秒"

  while true; do
    ensure_adb
    # 孩子反复下载被禁APP -> ADB 一连通就立刻卸载
    uninstall_banned_apps "$ADB_BIN" "$ADB_TARGET" log
    fg=$(get_foreground_package)

    # 桌面模式切换防护：孩子一旦进入“模式选择”界面（试图退出长辈/儿童模式），
    # 立即按返回键踢回桌面，防止切回标准模式看到短视频/短剧
    fg_comp=$(get_foreground_component)
    if echo "$fg_comp" | grep -q 'com.mitv.tvhome/.*ModeSwitch'; then
      log "⚠️ 检测到尝试切换桌面模式（$fg_comp），已拦截踢回"
      adb_do -s "$ADB_TARGET" shell "input keyevent KEYCODE_BACK" >/dev/null 2>&1
      sleep 2
      continue
    fi

    # 跨天则重置
    current_day=$(today)
    if [ "$current_day" != "$last_day" ]; then
      daily_used=$(load_daily_used)
      watch_elapsed=0; break_elapsed=0; away_elapsed=0
      if [ "$mode" = "off" ]; then
        log "新的一天，恢复允许观看"
        hide_reminder
      fi
      mode="watch"
      last_day="$current_day"
      save_session
    fi

    # 时段表：命中禁止时段就停止受控App并提醒（支持多个时段、跨零点）
    BLOCK_INFO="$(current_block_period)" || BLOCK_INFO=""
    if [ -n "$BLOCK_INFO" ]; then
      period_name="${BLOCK_INFO%%|*}"
      period_left="${BLOCK_INFO##*|}"
      # 睡觉时段：进入时熄屏，离开时唤醒
      if [ "$SCREEN_OFF_ON_SLEEP" = "1" ] && is_sleep_period "$period_name"; then
        if [ "$(cat "$STATE_DIR/screen_off" 2>/dev/null)" != "1" ]; then
          log "进入「$period_name」时段，熄屏"
          adb_do -s "$ADB_TARGET" shell "input keyevent KEYCODE_SLEEP" >/dev/null 2>&1
          echo 1 > "$STATE_DIR/screen_off"
        fi
      fi
      if is_watch_app "$fg"; then
        log "处于「$period_name」时段，已停止观看"
        force_stop_all
        sleep 1
        show_reminder "$period_left" 2 "$period_name"
      fi
      break_elapsed=$((break_elapsed + CHECK_INTERVAL))
      save_session
      sleep "$CHECK_INTERVAL"
      continue
    fi
    # 离开禁止时段 → 唤醒屏幕
    if [ "$SCREEN_OFF_ON_SLEEP" = "1" ] && [ "$(cat "$STATE_DIR/screen_off" 2>/dev/null)" = "1" ]; then
      log "离开禁止时段，唤醒屏幕"
      adb_do -s "$ADB_TARGET" shell "input keyevent KEYCODE_WAKEUP" >/dev/null 2>&1
      rm -f "$STATE_DIR/screen_off"
    fi

    is_watch=0
    is_watch_app "$fg" && is_watch=1

    case "$mode" in
      watch)
        if [ "$is_watch" = "1" ]; then
          away_elapsed=0
          watch_elapsed=$((watch_elapsed + CHECK_INTERVAL))
          daily_used=$((daily_used + CHECK_INTERVAL))
          save_daily_used "$daily_used"

          if [ "$DAILY_LIMIT_MIN" -gt 0 ] && [ "$daily_used" -ge $((DAILY_LIMIT_MIN * 60)) ]; then
            log "今日累计观看已达 ${DAILY_LIMIT_MIN} 分钟，今天不能再看了！"
            block_action
            mode="off"
            watch_elapsed=0
          elif [ "$watch_elapsed" -ge $((WATCH_LIMIT_MIN * 60)) ]; then
            log "连续观看已达 ${WATCH_LIMIT_MIN} 分钟，强制休息 ${BREAK_MIN} 分钟"
            block_action
            mode="break"
            watch_elapsed=0
            break_elapsed=0
          fi
        else
          # 严格累计模式：切到其它App / 电视关机都不会重置本段计时，
          # 只有完成一次休息或跨天后才归零，防止用切App/关机绕过30分钟规则
          away_elapsed=0
        fi
        ;;

      break)
        if [ "$is_watch" = "1" ]; then
          # 日志限流：30秒内只记一次，避免刷屏
          if [ $(( $(now_sec) - ${last_block_log:-0} )) -ge 30 ]; then
            last_block_log=$(now_sec)
            log "休息期间想偷看？已停止！"
          fi
          force_stop_all
          sleep 1
          show_reminder $((BREAK_MIN * 60 - break_elapsed))
        elif should_reshow_reminder "$fg"; then
          :   # v1.3：不再因回到桌面而重复弹出提醒页
        fi
        break_elapsed=$((break_elapsed + BREAK_CHECK_INTERVAL))
        if [ "$break_elapsed" -ge $((BREAK_MIN * 60)) ]; then
          log "休息结束，可以继续看啦"
          hide_reminder
          mode="watch"
          watch_elapsed=0
          away_elapsed=0
        fi
        ;;

      off)
        if [ "$is_watch" = "1" ]; then
          log "今日已禁用，停止打开的视频"
          force_stop_all
          sleep 1
          show_reminder -1
        elif should_reshow_reminder "$fg"; then
          :   # v1.3：不再因回到桌面而重复弹出提醒页
        fi
        ;;
    esac

    if [ "$mode" != "$prev_mode" ]; then
      log "状态切换 -> $mode"
      prev_mode="$mode"
    fi

    save_session
    if [ "$mode" = "watch" ]; then
      sleep "$CHECK_INTERVAL"
    else
      sleep "$BREAK_CHECK_INTERVAL"
    fi
  done
}

main "$@"
