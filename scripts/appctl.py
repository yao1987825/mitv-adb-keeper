#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tv-app-manager —— 小米电视应用管理工具（基于 ADB）

一句话完成：列出 / 查找 / 安装 / 卸载 / 停用 / 启用 / 清数据

用法:
  appctl.py list                     列出所有用户安装的应用（含中文名）
  appctl.py find <关键词>            按中文名或包名搜索
  appctl.py info <应用名>             查看应用详情
  appctl.py uninstall <应用名>        卸载应用
  appctl.py install <本地apk路径>      安装应用
  appctl.py disable <应用名>          停用（系统应用隐藏）
  appctl.py enable <应用名>           恢复被停用的应用
  appctl.py clear <应用名>            清除应用数据

环境变量:
  TV      电视地址，默认 192.168.6.168:5555
  ADB     adb 可执行文件路径（默认自动探测）
  AAPT    aapt 可执行文件路径（默认自动探测）
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

TV = os.environ.get("TV", "192.168.6.168:5555")
BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.dirname(os.path.dirname(BASE))
CACHE = os.environ.get("TV_APP_CACHE", os.path.join(os.path.expanduser("~"), ".cache", "tv-app-manager", "app_labels.json"))


def die(msg, code=1):
    print("❌ " + msg, file=sys.stderr)
    sys.exit(code)


def find_adb():
    cand = [os.environ.get("ADB"), shutil.which("adb"),
            os.path.join(PROJECT, "platform-tools", "adb"),
            os.path.join(PROJECT, "..", "platform-tools", "adb"),
            os.path.join(os.path.expanduser("~"), "rikkahub_file", "platform-tools", "adb")]
    for c in cand:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return os.path.abspath(c)
    die("找不到 adb，请设置环境变量 ADB")


def find_aapt():
    cand = [os.environ.get("AAPT"), shutil.which("aapt"),
            os.path.join(PROJECT, "android_sdk", "android-14", "aapt"),
            os.path.join(os.path.expanduser("~"), "rikkahub_file", "android_sdk", "android-14", "aapt")]
    for c in cand:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return os.path.abspath(c)
    return None


ADB = find_adb()
AAPT = find_aapt()


def sh(args, timeout=180):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def adb(*args, timeout=180):
    return sh([ADB] + list(args), timeout)


def connect():
    rc, out, _ = adb("connect", TV, timeout=30)
    if "connected" in out.lower() or "already" in out.lower():
        return
    time_out = out or "连接失败"
    die("无法连接电视 %s（%s）" % (TV, time_out))


def sh_on_tv(cmd, timeout=120):
    return adb("-s", TV, "shell", cmd, timeout=timeout)


def load_cache():
    if os.path.isfile(CACHE):
        try:
            with open(CACHE, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def save_cache(cache):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    with open(CACHE, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=2)


def third_party_packages():
    rc, out, _ = sh_on_tv("pm list packages -3")
    pkgs = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("package:"):
            pkgs.append(line[len("package:"):].strip())
    return pkgs


def apk_path(pkg):
    rc, out, _ = sh_on_tv("pm path %s | cut -d: -f2 | tr -d '\\r'" % pkg)
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("/"):
            return line
    return ""


def label_of(pkg, path):
    """读取应用中文名：优先只抽取 resources.arsc + AndroidManifest.xml（快）"""
    if not AAPT:
        return pkg
    tmpdir = tempfile.mkdtemp(prefix="applabel_")
    try:
        mini = os.path.join(tmpdir, "base.apk")
        ok = False
        # 方式1：设备端只抽取两个小文件（避免拉几十 MB 的整包）
        rc, out, err = sh_on_tv(
            "busybox unzip -p %s resources.arsc > /data/local/tmp/_l.arsc 2>/dev/null; "
            "busybox unzip -p %s AndroidManifest.xml > /data/local/tmp/_l.xml 2>/dev/null; "
            "ls -la /data/local/tmp/_l.arsc /data/local/tmp/_l.xml 2>/dev/null" % (path, path))
        if rc == 0 and "_l.arsc" in out:
            adb("pull", "/data/local/tmp/_l.arsc", os.path.join(tmpdir, "resources.arsc"), timeout=60)
            adb("pull", "/data/local/tmp/_l.xml", os.path.join(tmpdir, "AndroidManifest.xml"), timeout=60)
            if os.path.isfile(os.path.join(tmpdir, "resources.arsc")) and \
               os.path.isfile(os.path.join(tmpdir, "AndroidManifest.xml")):
                with zipfile.ZipFile(mini, "w", zipfile.ZIP_DEFLATED) as z:
                    z.write(os.path.join(tmpdir, "resources.arsc"), "resources.arsc")
                    z.write(os.path.join(tmpdir, "AndroidManifest.xml"), "AndroidManifest.xml")
                ok = os.path.isfile(mini)
        # 方式2：兜底，整包拉取
        if not ok:
            rc2, _, _ = adb("pull", path, os.path.join(tmpdir, "full.apk"), timeout=600)
            full = os.path.join(tmpdir, "full.apk")
            if os.path.isfile(full) and os.path.getsize(full) > 0:
                mini = full
                ok = True
        if not ok:
            return pkg
        rc, out, _ = sh([AAPT, "dump", "badging", mini], timeout=180)
        m = re.search(r"application-label:'([^']*)'", out)
        if m and m.group(1):
            return m.group(1)
        m = re.search(r"application-label:([^\r\n]+)", out)
        if m:
            return m.group(1).strip()
        return pkg
    except Exception:
        return pkg
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def collect(refresh=False, only=None):
    cache = load_cache()
    pkgs = only if only else third_party_packages()
    result = []
    for pkg in pkgs:
        path = apk_path(pkg)
        info = cache.get(pkg, {})
        if refresh or not info.get("label") or not path:
            label = label_of(pkg, path)
            rc, out, _ = sh_on_tv("dumpsys package %s | grep -m1 versionName" % pkg)
            vn = out.split("=", 1)[1].strip() if "=" in out else ""
            info = {"label": label, "versionName": vn, "path": path}
            cache[pkg] = info
        else:
            info.setdefault("path", path)
        result.append({"pkg": pkg, **info})
    save_cache(cache)
    return result


def match(apps, keyword):
    kw = keyword.strip().lower()
    exact, fuzzy = [], []
    for a in apps:
        label = (a.get("label") or "").lower()
        pkg = a["pkg"].lower()
        if label == kw or pkg == kw:
            exact.append(a)
        elif kw and (kw in label or kw in pkg):
            fuzzy.append(a)
    return exact, fuzzy


def resolve(keyword, auto=False):
    apps = collect()
    exact, fuzzy = match(apps, keyword)
    if exact:
        return exact[0], apps
    if fuzzy:
        if auto and len(fuzzy) == 1:
            return fuzzy[0], apps
        print("找到 %d 个匹配项：" % len(fuzzy))
        for a in fuzzy:
            print("  · %-24s %s" % (a["pkg"], a.get("label")))
        return None, apps
    print("❌ 没找到匹配「%s」的应用。当前已安装的应用：" % keyword)
    for a in apps:
        print("  · %-24s %s" % (a["pkg"], a.get("label")))
    return None, apps


def cmd_list(args):
    apps = collect(refresh="--refresh" in args)
    print("电视 %s 上共 %d 个用户安装的应用：" % (TV, len(apps)))
    print("-" * 64)
    for a in sorted(apps, key=lambda x: (x.get("label") or "")):
        print("  %-26s %-24s %s" % (a.get("label") or "-", a["pkg"], a.get("versionName") or ""))


def cmd_find(args):
    if not args:
        die("用法: appctl.py find <关键词>")
    apps = collect()
    _, fuzzy = match(apps, args[0])
    if not fuzzy:
        print("没有匹配「%s」的应用" % args[0])
        return
    print("匹配 %d 项：" % len(fuzzy))
    for a in fuzzy:
        print("  · %-26s %s" % (a.get("label") or "-", a["pkg"]))


def cmd_info(args):
    if not args:
        die("用法: appctl.py info <应用名>")
    app, _ = resolve(args[0])
    if not app:
        sys.exit(1)
    pkg = app["pkg"]
    rc, out, _ = sh_on_tv("dumpsys package %s | grep -E 'versionName|versionCode|firstInstallTime|lastUpdateTime|codePath|installerPackageName'" % pkg)
    print("名称: %s\n包名: %s\n路径: %s\n" % (app.get("label"), pkg, app.get("path")))
    print(out)


def cmd_uninstall(args):
    if not args:
        die("用法: appctl.py uninstall <应用名>")
    app, _ = resolve(args[0], auto=("--yes" in args or "-y" in args))
    if not app:
        sys.exit(1)
    pkg = app["pkg"]
    print("→ 正在卸载：%s (%s)" % (app.get("label"), pkg))
    rc, out, err = adb("uninstall", pkg, timeout=300)
    if "Success" in out:
        print("✅ 卸载成功：%s" % app.get("label"))
        c = load_cache()
        c.pop(pkg, None)
        save_cache(c)
    else:
        print("❌ 卸载失败：%s %s" % (out, err))
        print("   若为系统应用，请改用： appctl.py disable %s" % app.get("label"))
        sys.exit(1)


def cmd_disable(args):
    if not args:
        die("用法: appctl.py disable <应用名>")
    app, _ = resolve(args[0])
    if not app:
        sys.exit(1)
    pkg = app["pkg"]
    print("→ 正在停用：%s (%s)" % (app.get("label"), pkg))
    rc, out, err = sh_on_tv("pm uninstall --user 0 %s" % pkg)
    print("✅ 已停用（对当前用户隐藏，可随时恢复）" if "Success" in out else "❌ 失败：%s %s" % (out, err))


def cmd_enable(args):
    if not args:
        die("用法: appctl.py enable <应用名>")
    app, _ = resolve(args[0])
    if not app:
        sys.exit(1)
    pkg = app["pkg"]
    rc, out, err = sh_on_tv("pm install-existing --user 0 %s" % pkg)
    print("✅ 已恢复" if "Success" in out else "❌ 失败：%s %s" % (out, err))


def cmd_clear(args):
    if not args:
        die("用法: appctl.py clear <应用名>")
    app, _ = resolve(args[0])
    if not app:
        sys.exit(1)
    rc, out, err = sh_on_tv("pm clear %s" % app["pkg"])
    print("✅ 已清除数据：%s" % app.get("label") if "Success" in out else "❌ %s %s" % (out, err))


def cmd_install(args):
    apks = [a for a in args if not a.startswith("-")]
    if not apks:
        die("用法: appctl.py install <本地apk路径>")
    for src in apks:
        if not os.path.isfile(src):
            die("找不到文件：%s" % src)
        print("→ 正在安装：%s" % src)
        rc, out, err = adb("install", "-r", src, timeout=900)
        if "Success" not in out:
            print("❌ 安装失败：%s %s" % (out, err))
            continue
        print("✅ 安装成功：%s" % src)
        # 关键：安装/更新后应用会进入「停止状态」，系统不再给它派发任何任务，
        # 必须主动拉起一次，否则应用等于“死了”。
        pkg = apk_package_of(src)
        if pkg:
            adb("shell", "am", "start", "-n", "%s/.MainActivity" % pkg, timeout=120)
            print("   ↻ 已拉起 %s（避免停留在停止状态）" % pkg)


def apk_package_of(apk_path):
    """读取本地 APK 的包名"""
    if not AAPT:
        return None
    rc, out, _ = sh([AAPT, "dump", "badging", apk_path], timeout=120)
    m = re.search(r"package: name='([^']+)'", out)
    return m.group(1) if m else None


CMDS = {"list": cmd_list, "find": cmd_find, "info": cmd_info,
        "uninstall": cmd_uninstall, "disable": cmd_disable,
        "enable": cmd_enable, "clear": cmd_clear, "install": cmd_install}


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
        print(__doc__)
        return
    cmd = sys.argv[1]
    if cmd not in CMDS:
        die("未知命令：%s（可用：%s）" % (cmd, ", ".join(CMDS)))
    connect()
    CMDS[cmd](sys.argv[2:])


if __name__ == "__main__":
    main()
