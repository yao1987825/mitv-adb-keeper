---
name: mitv-adb-keeper
description: 小米电视助手。当用户要「控制小米电视」「卸载电视上的某个应用」「限制孩子看电视时长」「开机自动进入 TVBox」「电视 ADB 连不上/自动开启」时使用本技能。通过 ADB 远程管理小米电视：按中文名卸载应用、设定观看时间限制与夜间禁用、Kiosk 模式（开机进 TVBox 并屏蔽其它应用）、以及开机自动开启 ADB 与自动卸载被禁应用。
---

# 小米电视助手 (mitv-adb-keeper)

一套工具远程管理小米电视（型号 MiTV4-ANSM0，Android 6.0.1，地址 192.168.6.168:5555）。

包含四个模块：

| 模块 | 位置 | 能力 |
|---|---|---|
| **应用管理** | `skills/tv-app-manager/` | 按中文名卸载/查询/停用/清数据电视应用 |
| **儿童守护** | `child-guard/` | 观看时长限制、休息强制中断、夜间禁用、自动卸载被禁App |
| **Kiosk 模式** | `kiosk/` | 开机自动进入 TVBox，其余应用一律屏蔽 |
| **ADB 自动开启** | `app/` + `scripts/watchdog.sh` | 电视开机后 ADB 自动可用，无需手动开启 |

---

## 0. 前置：ADB 连不上怎么办

电视的 ADB 由电视端助手自动开启（开机后约 1~2 分钟），电脑侧还有守护器兜底。

```bash
/home/yao/rikkahub_file/mitv-adb-keeper/scripts/status.sh   # 看状态
/home/yao/rikkahub_file/mitv-adb-keeper/scripts/watchdog.sh  # 立即巡检 + 尝试修复
```

若仍连不上，等电视重启时机会自动恢复；紧急时在电视上手动开一次「ADB 调试」。

---

## 1. 卸载电视应用（最常用）

```bash
cd /home/yao/rikkahub_file/mitv-adb-keeper/skills/tv-app-manager
python3 scripts/appctl.py list                  # 列出全部应用（中文名）
python3 scripts/appctl.py find 云视听            # 搜索
python3 scripts/appctl.py uninstall 云视听快TV    # 按中文名卸载
python3 scripts/appctl.py info 咪咕游戏TV版       # 查看详情
```

**处理「卸载 XXX」的标准流程**：直接执行 `uninstall "<中文名>"`，然后把结果回报给用户。
匹配不到时脚本会列出电视上所有应用，照着改个词重试即可。

系统应用请用 `disable`（可 `enable` 恢复），不要硬删。

## 2. 儿童观看时长管理

```bash
cd /home/yao/rikkahub_file/mitv-adb-keeper/child-guard
./start_tv_guard.sh      # 启动守护
./stop_tv_guard.sh       # 停止
tail -f ~/.tv_guard/tv_guard.log     # 实时日志
cat ~/.tv_guard/daily_usage.txt      # 今日已看时长
```

- 规则（`child-guard/tv_guard.sh` 配置区可改）：
  单次连续 30 分钟 → 强停并强制休息 30 分钟；每天累计 120 分钟 → 当天禁止；
  **夜间 20:00–次日 08:00 直接禁止**受控 APP
- 受控 APP 在 `tv_guard.sh` 的 `WATCH_PACKAGES`
- **被禁APP清单**在仓库根 `banned_apps.txt`：一旦在电视上被发现即自动卸载
  （当前含快手/云视听快TV，防止孩子反复下载）

## 3. Kiosk 模式（开机进 TVBox，屏蔽其它应用）

```bash
cd /home/yao/rikkahub_file/mitv-adb-keeper/kiosk
./start_kiosk.sh     # 启动
./stop_kiosk.sh      # 停止（家长退出用）
```

配置见 `kiosk/kiosk.conf`：目标 App、白名单、检测间隔、是否服从休息时段。
详见 [kiosk/README.md](kiosk/README.md)。

## 4. ADB 自动开启助手（电视端）

- 源码：`app/`（Java），构建：`scripts/build.sh`，安装：`scripts/install.sh`
- 电脑侧守护器 `scripts/watchdog.sh`：每 5 分钟巡检，自动修复 ADB、自动体检助手、
  发现本地 APK 有新版就**后台静默安装**（无任何弹窗）
- 助手 APK 预编译件在 `dist/adbkeeper.apk`

---

## 常用命令速查

```bash
cd /home/yao/rikkahub_file/mitv-adb-keeper
./connect_tv.sh status      # 电视连接状态
./connect_tv.sh shell       # 进入电视 shell
./connect_tv.sh reboot      # 重启电视
```

## 注意

- 卸载会连同应用数据一起删除；系统应用建议用 `disable`。
- 电视上的 ADB 密钥已永久授权，全程不会出现「允许 USB 调试」确认框。
- 助手会让 ADB 保持常开：手动关掉也会被自动恢复（彻底关闭：`adb uninstall com.example.adbkeeper`）。
