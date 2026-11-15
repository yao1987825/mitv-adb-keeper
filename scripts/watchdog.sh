#!/bin/bash
# ============================================================================
#  AdbKeeper 电视端守护器（电脑侧，全自动 · 零人工确认）
#
#  1) 健康检查：电视 ADB(5555) 是否可用
#  2) 自愈修复：不可用时抢开机窗口，强制重启 adbd
#  3) 自动升级：本地 APK 与电视上已装版本不一致时，后台静默安装（无任何弹窗）
#  4) 状态留痕：写入 data/ 供 status.sh 查询与反馈
#
#  说明：电脑与电视之间使用已授权的 ADB 密钥，全程不需要在电视上点“允许/确认”
# ============================================================================
set -u

TV_IP="${TV_IP:-192.168.6.168}"
TV_PORT="${TV_PORT:-5555}"
TV="${TV_IP}:${TV_PORT}"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="${DATA_DIR:-$BASE_DIR/data}"
LOG="$DATA_DIR/watchdog.log"
STATUS="$DATA_DIR/status.txt"
STATE="$DATA_DIR/state.env"
LOCAL_APK="$BASE_DIR/dist/adbkeeper.apk"
PKG="com.example.adbkeeper"

mkdir -p "$DATA_DIR"

# 防重入：避免上一次未结束时再次启动
LOCK="$DATA_DIR/watchdog.lock"
exec 9>"$LOCK"
if command -v flock >/dev/null 2>&1; then
    flock -n 9 || { echo "$(date '+%F %T') 已有实例在运行，跳过" >>"$LOG"; exit 0; }
fi

# adb 路径
if command -v adb >/dev/null 2>&1; then
    ADB="$(command -v adb)"
elif [ -x "$BASE_DIR/../platform-tools/adb" ]; then
    ADB="$BASE_DIR/../platform-tools/adb"
elif [ -x "$BASE_DIR/../../platform-tools/adb" ]; then
    ADB="$BASE_DIR/../../platform-tools/adb"
else
    log "找不到 adb"; exit 2
fi

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }
port_open() { nc -z -w 2 "$TV_IP" "$TV_PORT" >/dev/null 2>&1; }
tv_alive() { ping -c 1 -W 2 "$TV_IP" >/dev/null 2>&1; }

LAST_STATE="UNKNOWN"; [ -f "$STATE" ] && . "$STATE" && LAST_STATE="${LAST_STATE:-UNKNOWN}"

# ------------------------------------------------------ 0. 电视是否在线
if ! tv_alive; then
    log "电视不可达（关机/断网），跳过"
    printf '状态: 电视离线\n时间: %s\n' "$(date '+%F %T')" >"$STATUS"
    echo "LAST_STATE=OFFLINE" >"$STATE"
    exit 0
fi


# ------------------------------------------------------ 2.5 电视端助手健康体检
# 电视端应用若被“停止”(安装更新后未拉起 / 被用户停止 / 系统回收)，
# 它就不会再被系统派发任务，开机后无法自我恢复 ADB。
# 这里主动检查并把它拉起来，让它重新注册持久化任务。
ensure_tv_app_alive() {
    local st jobs
    st="$("$ADB" -s "$TV" shell "dumpsys package $PKG 2>/dev/null | grep -m1 'User 0:'" 2>/dev/null | tr -d '\r')"
    if [ -z "$st" ]; then
        log "   · 电视端助手未安装，跳过体检"
        return 0
    fi
    if echo "$st" | grep -q "stopped=true"; then
        log "   ⚠️ 电视端助手处于「停止状态」，正在拉起以恢复自愈能力"
        "$ADB" -s "$TV" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
        sleep 3
        st2="$("$ADB" -s "$TV" shell "dumpsys package $PKG 2>/dev/null | grep -m1 'User 0:'" 2>/dev/null | tr -d '\r')"
        if echo "$st2" | grep -q "stopped=false"; then
            log "   ✅ 已拉起，助手恢复正常"
        else
            log "   ❌ 拉起未成功：$st2"
        fi
        return 0
    fi
    # 任务是否还在
    jobs="$("$ADB" -s "$TV" shell "dumpsys jobscheduler 2>/dev/null | grep -c $PKG" 2>/dev/null | tr -d '\r ')"
    if [ "${jobs:-0}" = "0" ]; then
        log "   ⚠️ 助手任务已丢失，重新拉起以注册"
        "$ADB" -s "$TV" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
        sleep 2
        log "   ✅ 已重新拉起"
    fi
}

# ------------------------------------------------------ 1. ADB 是否可用
if port_open; then
    [ "$LAST_STATE" = "FAIL" ] && log "✅ 已恢复正常：ADB 端口可用" || log "✅ 正常：ADB 端口可用"
    printf '状态: 正常\n时间: %s\n' "$(date '+%F %T')" >"$STATUS"
    echo "LAST_STATE=OK" >"$STATE"
else
    log "⚠️ ADB 端口未开启，开始自动修复..."
    # 先直接连（可能只是瞬时误判）
    if "$ADB" connect "$TV" >/dev/null 2>&1 && "$ADB" devices | grep -q "$TV.*device"; then
        log "   实际可用（此前为探测误判）"
        echo "LAST_STATE=OK" >"$STATE"
        printf '状态: 正常\n时间: %s\n' "$(date '+%F %T')" >"$STATUS"
        exit 0
    fi

    # 抢开机窗口执行强制开启（命令在电视本地跑并脱离 adbd，adbd 停掉也能跑完）
    log "   监听开机窗口（最多 120 秒）…"
    RESCUED=0
    for i in $(seq 1 60); do
        if port_open; then
            log "   捕获端口开放，执行强制开启"
            "$ADB" connect "$TV" >/dev/null 2>&1
            "$ADB" -s "$TV" shell "nohup sh -c 'service call TvService 4004 i32 0; sleep 2; service call TvService 4004 i32 1' >/data/local/tmp/adb_rescue.log 2>&1 &" >/dev/null 2>&1
            # 同时把助手拉起来（若处于停止状态则清掉），恢复其长期自愈能力
            "$ADB" -s "$TV" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
            sleep 8
            port_open && { log "   ✅ 修复成功"; RESCUED=1; }
            break
        fi
        sleep 2
    done

    if [ "$RESCUED" = "1" ]; then
        echo "LAST_STATE=OK" >"$STATE"
        printf '状态: 已自动修复\n时间: %s\n' "$(date '+%F %T')" >"$STATUS"
        exit 0
    fi

    log "❌ 自动修复未成功"
    echo "LAST_STATE=FAIL" >"$STATE"
    {
        printf '状态: ❌ 异常 - ADB 未开启且自动修复失败\n'
        printf '时间: %s\n' "$(date '+%F %T')"
        printf '电视: %s\n' "$TV_IP"
        printf '建议: 在电视上手动开一次 ADB 调试，或检查助手是否被卸载\n'
    } >"$STATUS"
    exit 1
fi

# ------------------------------------------------------ 2. 后台静默自动升级
# 比较本地 APK 与电视上已装 APK 的 md5，不一致则自动覆盖安装（无需任何确认）
if [ -f "$LOCAL_APK" ]; then
    LOCAL_MD5="$(md5sum "$LOCAL_APK" | cut -d' ' -f1)"
    REMOTE_APK="$("$ADB" -s "$TV" shell "pm path $PKG | cut -d: -f2 | tr -d '\r'" 2>/dev/null | tr -d '\r')"
    REMOTE_MD5=""
    if [ -n "$REMOTE_APK" ]; then
        REMOTE_MD5="$("$ADB" -s "$TV" shell "md5sum '$REMOTE_APK' 2>/dev/null | cut -d' ' -f1" 2>/dev/null | tr -d '\r')"
    fi
    if [ -n "$REMOTE_MD5" ] && [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
        log "🔄 检测到新版本，后台静默安装..."
        if "$ADB" -s "$TV" install -r "$LOCAL_APK" >/dev/null 2>&1; then
            "$ADB" -s "$TV" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
            log "   ✅ 新版本已静默安装并启动"
            printf '状态: 正常（已自动升级）\n时间: %s\n' "$(date '+%F %T')" >"$STATUS"
        else
            log "   ❌ 自动安装失败"
        fi
    fi
fi
exit 0
