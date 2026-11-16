#!/usr/bin/env bash
# ============================================================================
#  被禁APP统一处理（供各守护脚本 source 使用）
#   需求：孩子会反复通过应用商店下载安装被禁APP，
#         只要 ADB 一连通就必须立刻卸载掉。
# ============================================================================

BANNED_APPS_FILE="${BANNED_APPS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/banned_apps.txt}"

# 读取清单（忽略空行与注释）
banned_apps_list() {
    [ -f "$BANNED_APPS_FILE" ] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$BANNED_APPS_FILE" | sed 's/#.*//' | tr -d ' \t' | grep -v '^$'
}

# 检查电视上是否出现被禁APP，出现就立刻卸载
# 参数: $1=adb可执行文件  $2=设备地址(192.168.6.168:5555)  $3=日志函数名(可选)
uninstall_banned_apps() {
    local adb_bin="$1" target="$2" logger="${3:-}"
    local pkg
    for pkg in $(banned_apps_list); do
        # 先确认是否真的装着
        if timeout 15 "$adb_bin" -s "$target" shell "pm path $pkg" 2>/dev/null | grep -q "$pkg"; then
            if timeout 60 "$adb_bin" -s "$target" uninstall "$pkg" >/dev/null 2>&1; then
                if [ -n "$logger" ] && command -v "$logger" >/dev/null 2>&1; then
                    "$logger" "🚫 检测到被禁App「$pkg」已重新安装，已立即自动卸载"
                else
                    echo "🚫 检测到被禁App「$pkg」已重新安装，已立即自动卸载"
                fi
            else
                if [ -n "$logger" ] && command -v "$logger" >/dev/null 2>&1; then
                    "$logger" "⚠️ 被禁App「$pkg」卸载失败"
                fi
            fi
        fi
    done
}
