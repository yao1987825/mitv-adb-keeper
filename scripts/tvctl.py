#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""小米电视电源/状态控制（基于 ADB + 小米助手 6095 + 网络唤醒）

用法:
  tvctl.py status            查看电视在线状态、ADB 是否可用、开机时长
  tvctl.py power off         电视进入待机（熄屏关机）
  tvctl.py power reboot      重启电视
  tvctl.py power on          唤醒电视（依次尝试: ADB / 6095助手 / 网络唤醒）
  tvctl.py wake              同 power on
"""
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

TV_IP = os.environ.get("TV_IP", "192.168.6.168")
TV_PORT = int(os.environ.get("TV_PORT", "5555"))
TV_ADDR = "%s:%d" % (TV_IP, TV_PORT)
TV_MAC = os.environ.get("TV_MAC", "c8:28:32:60:2d:af")   # 小米电视4 有线网卡MAC
ASSIST_PORT = int(os.environ.get("TV_ASSIST_PORT", "6095"))
WAIT_SECONDS = int(os.environ.get("TV_WAIT_SECONDS", "180"))


def die(msg, code=1):
    print("❌ " + msg, file=sys.stderr)
    sys.exit(code)


def find_adb():
    cand = [os.environ.get("ADB"), shutil.which("adb"),
            "/home/yao/rikkahub_file/platform-tools/adb",
            os.path.expanduser("~/rikkahub_file/platform-tools/adb")]
    for c in cand:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return os.path.abspath(c)
    die("找不到 adb，请设置环境变量 ADB")


ADB = find_adb()


def sh(args, timeout=120):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def adb(*args, timeout=120):
    return sh([ADB, "-s", TV_ADDR] + list(args), timeout=timeout)


def port_open(host, port, timeout=1.0):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        s.connect((host, port))
        return True
    except Exception:
        return False
    finally:
        s.close()


def connect():
    sh([ADB, "connect", TV_ADDR], timeout=30)
    return port_open(TV_IP, TV_PORT)


def assist_get(path, params, timeout=4):
    """小米电视助手 6095 HTTP 接口"""
    url = "http://%s:%d/%s?%s" % (TV_IP, ASSIST_PORT, path, urllib.parse.urlencode(params))
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except Exception:
        return ""


def send_magic_packet(mac):
    mac = mac.replace(":", "").replace("-", "")
    if len(mac) != 12:
        return False
    magic = b"\xff" * 6 + bytes.fromhex(mac) * 16
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        for port in (9, 7):
            s.sendto(magic, ("255.255.255.255", port))
            s.sendto(magic, ("192.168.6.255", port))
        return True
    except Exception:
        return False
    finally:
        s.close()


def cmd_status():
    print("── 电视状态 ──")
    print("地址      : %s" % TV_ADDR)
    ping_ok = False
    p = subprocess.run(["ping", "-c", "1", "-W", "2", TV_IP], capture_output=True, text=True)
    ping_ok = p.returncode == 0
    print("网络      : %s" % ("✅ 在线" if ping_ok else "❌ 不在线"))
    adb_ok = port_open(TV_IP, TV_PORT)
    print("ADB 端口  : %s" % ("✅ 已开启" if adb_ok else "❌ 未开启（电视刚开机时约需 30~120 秒自动恢复）"))
    print("助手 6095 : %s" % ("✅ 在线" if port_open(TV_IP, ASSIST_PORT) else "❌ 离线"))
    if adb_ok:
        connect()
        rc, out, _ = adb("shell", "settings get global adb_enabled")
        print("adb_enabled: %s" % (out or "?"))
        rc, out, _ = adb("shell", "cat /proc/uptime")
        if out:
            print("开机时长  : %.1f 分钟" % (float(out.split()[0]) / 60))
        rc, out, _ = adb("shell", "pm list packages -3")
        pkgs = [l.replace("package:", "").strip() for l in out.splitlines() if l.strip()]
        print("第三方应用: %d 个" % len(pkgs))
        for p in sorted(pkgs):
            print("   - %s" % p)


def cmd_power(mode):
    if mode == "on":
        return power_on()
    if mode == "off":
        if not connect():
            die("ADB 不可用，无法关机（电视可能已关机）")
        adb("shell", "input keyevent 26")
        print("✅ 已发送电源键，电视进入待机")
        return
    if mode == "reboot":
        if not connect():
            die("ADB 不可用，无法重启")
        adb("reboot")
        print("✅ 电视正在重启")
        return
    die("未知电源动作：%s（可用：on / off / reboot）" % mode)


def power_on():
    print("→ 尝试唤醒电视 %s ..." % TV_ADDR)
    # 1) ADB 可用时直接唤醒屏幕
    if connect():
        adb("shell", "input keyevent 26")
        print("   ✅ 已通过 ADB 唤醒")
        return wait_adb()
    # 2) 小米电视助手 6095（电视待机但助手在线时有效）
    resp = assist_get("/controller", {"action": "keyevent", "keycode": "home"})
    if resp:
        print("   ✅ 已通过小米助手接口发送唤醒指令")
    else:
        print("   · 小米助手接口无响应（电视处于深度待机）")
    # 3) 网络唤醒（需电视开启“网络唤醒”）
    if send_magic_packet(TV_MAC):
        print("   · 已发送网络唤醒包（MAC %s）" % TV_MAC)
    return wait_adb()


def wait_adb():
    print("→ 等待 ADB 恢复（开机自启助手通常 30~120 秒内完成）...")
    for i in range(WAIT_SECONDS // 5):
        time.sleep(5)
        if port_open(TV_IP, TV_PORT):
            print("✅ 电视已就绪，ADB 可用（等待 %d 秒）" % ((i + 1) * 5))
            connect()
            return True
    print("⚠️ 等待超时：电视可能没有响应唤醒，请用遥控器手动开机")
    return False


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd = sys.argv[1]
    if cmd == "status":
        cmd_status()
    elif cmd == "power":
        if len(sys.argv) < 3:
            die("用法: tvctl.py power on|off|reboot")
        cmd_power(sys.argv[2])
    elif cmd in ("wake", "on"):
        power_on()
    else:
        die("未知命令：%s（可用：status / power on|off|reboot / wake）" % cmd)


if __name__ == "__main__":
    main()
