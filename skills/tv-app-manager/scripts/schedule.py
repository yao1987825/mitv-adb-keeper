#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
应用上网时间管理（定时下线/上线）

为每个应用设定“允许运行（上网）”的时段：
  · 处于允许时段 → 应用启用，可正常启动联网
  · 处于禁止时段 → 应用被禁用（pm disable-user），不能启动，也就无法联网
  · 到点自动切换，由 cron 每分钟执行一次

用法:
  schedule.py list                     查看所有计划
  schedule.py set <应用名> <开始> <结束>  设定允许运行时段，如 set 咪咕游戏TV版 08:00 22:00
  schedule.py off <应用名>              永久下线（立即禁用）
  schedule.py on <应用名>               永久上线（立即启用，取消计划）
  schedule.py remove <应用名>           删除计划并恢复常开
  schedule.py apply                     立即按计划执行一次（cron 用的就是这个）

时段跨午夜也支持，例如 22:00 → 07:00 表示夜间禁用。

⚠️ 权限说明（实测于小米电视 Android 6.0.1）:
  · 用 adb shell(uid 2000) 执行 pm disable-user 禁用「普通用户应用」会被系统拒绝：
    Permission Denial: attempt to change component state ... package uid 10076
  · 因此本工具的定时禁用只对「系统应用」有效；
    普通用户应用请用强停(am force-stop)或由系统身份的应用来操作。
  · 电视端的 com.example.adbkeeper 以系统身份(uid 1000)运行，可禁用普通应用。
"""
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from appctl import (adb, sh_on_tv, connect, collect, load_cache, save_cache,
                    PROJECT, die, adb as _adb)

SCHED_FILE = os.path.join(PROJECT, "data", "schedules.json")
PKG = "com.example.adbkeeper"


def load_sched():
    if os.path.isfile(SCHED_FILE):
        try:
            with open(SCHED_FILE, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def save_sched(s):
    os.makedirs(os.path.dirname(SCHED_FILE), exist_ok=True)
    with open(SCHED_FILE, "w", encoding="utf-8") as f:
        json.dump(s, f, ensure_ascii=False, indent=2)


def to_min(hhmm):
    h, m = hhmm.strip().split(":")
    return int(h) * 60 + int(m)


def in_window(now_min, start, end):
    s, e = to_min(start), to_min(end)
    if s == e:
        return False
    if s < e:
        return s <= now_min < e
    return now_min >= s or now_min < e     # 跨午夜


def desired_enabled(entry, now_min):
    """根据计划算出该应用此刻应不应该启用"""
    windows = entry.get("windows") or []
    if not windows:
        return False                      # 没有时段 = 永久下线
    for w in windows:
        if in_window(now_min, w[0], w[1]):
            return True
    return False


def is_disabled(pkg):
    """判断应用当前是否处于禁用状态"""
    rc, out, _ = sh_on_tv("pm list packages -d")
    for line in out.splitlines():
        if line.strip() == "package:" + pkg:
            return True
    return False


def is_installed(pkg):
    rc, out, _ = sh_on_tv("pm path %s" % pkg)
    return "/data/app" in out or "/system/" in out


def apply_state(pkg, enable):
    """把应用切到目标状态；禁用前先强杀正在运行的进程"""
    disabled = is_disabled(pkg)
    if enable and not disabled:
        return "已是启用状态"
    if not enable and disabled:
        return "已是禁用状态"
    if not enable:
        sh_on_tv("am force-stop %s" % pkg)
        rc, out, err = sh_on_tv("pm disable-user --user 0 %s" % pkg)
    else:
        rc, out, err = sh_on_tv("pm install-existing --user 0 %s" % pkg)
    if "Success" in out:
        return "已%s" % ("启用" if enable else "禁用")
    return "操作失败：%s %s" % (out, err)


def cmd_list(args):
    sched = load_sched()
    apps = {a["pkg"]: a for a in collect()}
    if not sched:
        print("当前没有任何上网时间计划。")
        print("设定示例： schedule.py set 咪咕游戏TV版 08:00 22:00")
        return
    now = datetime.datetime.now()
    print("当前时间：%s" % now.strftime("%H:%M"))
    print("-" * 72)
    for pkg, e in sched.items():
        label = e.get("label") or apps.get(pkg, {}).get("label") or pkg
        wins = e.get("windows") or []
        if wins:
            desc = "、".join("%s-%s" % (w[0], w[1]) for w in wins)
        else:
            desc = "永久下线"
        want = desired_enabled(e, now.hour * 60 + now.minute)
        state = "启用(可上网)" if want else "禁用(已下线)"
        real = "禁用" if is_disabled(pkg) else "启用"
        print("  %-22s %-26s 计划:%-16s 期望:%s 实际:%s" % (label, pkg, desc, state, real))


def resolve_pkg(keyword):
    apps = collect()
    kw = keyword.strip().lower()
    for a in apps:
        if (a.get("label") or "").lower() == kw or a["pkg"].lower() == kw:
            return a
    for a in apps:
        if kw and (kw in (a.get("label") or "").lower() or kw in a["pkg"].lower()):
            return a
    return None


def cmd_set(args):
    if len(args) < 3:
        die("用法: schedule.py set <应用名> <开始> <结束>   例: set 咪咕游戏TV版 08:00 22:00")
    app = resolve_pkg(args[0])
    if not app:
        die("没找到应用：%s" % args[0])
    start, end = args[1], args[2]
    try:
        to_min(start); to_min(end)
    except Exception:
        die("时间格式应为 HH:MM，例如 08:00")
    sched = load_sched()
    sched[app["pkg"]] = {"label": app.get("label"), "windows": [[start, end]]}
    save_sched(sched)
    print("✅ 已设定：%s (%s) 允许运行时段 %s - %s" % (app.get("label"), app["pkg"], start, end))
    print("   （到点自动切换；可执行 apply 立即生效）")


def cmd_off(args):
    if not args:
        die("用法: schedule.py off <应用名>")
    app = resolve_pkg(args[0])
    if not app:
        die("没找到应用：%s" % args[0])
    sched = load_sched()
    sched[app["pkg"]] = {"label": app.get("label"), "windows": []}
    save_sched(sched)
    print("✅ 已设为永久下线：%s" % app.get("label"))
    print("   " + apply_state(app["pkg"], False))


def cmd_on(args):
    if not args:
        die("用法: schedule.py on <应用名>")
    app = resolve_pkg(args[0])
    if not app:
        die("没找到应用：%s" % args[0])
    sched = load_sched()
    sched.pop(app["pkg"], None)
    save_sched(sched)
    print("✅ 已取消计划，恢复常开：%s" % app.get("label"))
    print("   " + apply_state(app["pkg"], True))


def cmd_remove(args):
    cmd_on(args)


def cmd_apply(args):
    sched = load_sched()
    if not sched:
        return
    now = datetime.datetime.now()
    cur = now.hour * 60 + now.minute
    for pkg, e in sched.items():
        want = desired_enabled(e, cur)
        try:
            if not is_installed(pkg):
                continue
            res = apply_state(pkg, want)
            if res.startswith("已"):
                label = e.get("label") or pkg
                print("%s %s → %s" % (now.strftime("%H:%M"), label, res))
        except Exception as ex:
            print("处理 %s 失败: %s" % (pkg, ex))


CMDS = {"list": cmd_list, "set": cmd_set, "off": cmd_off,
        "on": cmd_on, "remove": cmd_remove, "apply": cmd_apply}


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return
    cmd = sys.argv[1]
    if cmd not in CMDS:
        die("未知命令：%s（可用：%s）" % (cmd, ", ".join(CMDS)))
    connect()
    CMDS[cmd](sys.argv[2:])


if __name__ == "__main__":
    main()
