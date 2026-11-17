---
name: tv-control
description: 小米电视控制与��用管理。当用户说「打开电视/关电视/电视重启」「卸载电视上的某个APP」「电视里那个XX不要了」「装个APK到电视」「看看电视现在什么状态」时使用本技能——通过 ADB 远程控制小米电视的开机、关机、重启、安装、卸载、停用、查询，无需用户在电视上手动操作。
---

# 小米电视控制与应用管理（tv-control）

一台小米电视 4（MiTV4-ANSM0，Android 6.0.1），地址 `192.168.6.168`。

**ADB 默认开机自动开启**：电视端常驻 `AdbKeeper` 助手（`com.example.adbkeeper`），
每次开机系统关掉 ADB 后，助手会在 **30~120 秒**内自动重新开启（实测冷启动约 67 秒）。
所以大多数时候直接用即可；刚开机时如果连不上，等一会儿再试。

> 小米电视每次开机都会主动关闭 ADB（系统机制，靠 `AdbKeeper` 助手对抗）。
> 另外 MIUI 偶尔会把助手置为「停止状态」从而取消它的定时任务，
> 电脑端有 cron 看门狗每分钟检查一次并自动拉起修复：

## 工具

```bash
# 电视控制（开关机/重启/状态）
python3 scripts/tvctl.py status            # 电视在线状态、ADB 是否可用、开机时长、已装应用
python3 scripts/tvctl.py power off         # 电视进入待机
python3 scripts/tvctl.py power reboot      # 重启电视
python3 scripts/tvctl.py power on          # 唤醒电视（ADB → 小米助手6095 → 网络唤醒 依次尝试）
python3 scripts/tvctl.py wake              # 同 power on

# 应用管理
python3 scripts/appctl.py list             # 列出所有用户安装的应用（中文名 + 包名 + 版本）
python3 scripts/appctl.py find <关键词>     # 按中文名或包名搜索
python3 scripts/appctl.py info <应用名>     # 查看版本、安装时间、来源
python3 scripts/appctl.py uninstall <应用名>  # 卸载应用
python3 scripts/appctl.py install <本地apk路径>  # 安装 APK
python3 scripts/appctl.py disable <应用名>  # 停用系统应用（可恢复）
python3 scripts/appctl.py enable <应用名>   # 恢复被停用的应用
python3 scripts/appctl.py clear <应用名>    # 清除应用数据

# AdbKeeper 健康看门狗（cron 每分钟自动执行，一般无需手动跑）
python3 scripts/keeper_watchdog.sh         # 手动执行一次体检
```

看门狗日志：`~/.tv_control/watchdog.log`

## AdbKeeper 助手（已隐藏，防小孩卸载）

电视端常驻一个零界面后台 App，负责每次开机自动打开 ADB。

| 项 | 值 |
|---|---|
| 包名 | `com.example.adbkeeper` |
| 电视上显示名 | **系统服务**（看起来像系统组件，小孩不会去动） |
| 桌面图标 | **没有**（已移除 MAIN/LAUNCHER 入口，桌面和应用列表都找不到它） |
| 源码/构建 | `adbkeeper/` 目录，`bash adbkeeper/scripts/build.sh` 可重新编译 |
| 成品 | `adbkeeper/dist/adbkeeper.apk` |

⚠️ 重要：重新安装这个 App 后必须立刻执行
`adb shell am start -n com.example.adbkeeper/.MainActivity`，
否则 Android 会把它置为「停止状态」，其定时任务会被取消，ADB 就不会自动恢复了
（看门狗会在 1 分钟内自动修复）。

绝对路径：`/home/yao/rikkahub_file/skills/tv-control/scripts/`

## 标准处理流程

**「卸载电视上的 XX」**
1. 直接执行：`python3 scripts/appctl.py uninstall "XX"`
   脚本会自动连接电视、按中文名匹配包名；匹配不到时列出候选。
2. 回报结果：卸载了哪个应用（中文名 + 包名）。
3. 若用户只说了模糊名字，先 `find XX` 拿候选，再让用户确认。

**「把电视打开 / 关掉 / 重启」**
- 打开：`python3 scripts/tvctl.py power on`（若电视深度待机且网络唤醒未开启，需用户用遥控器手动开机）
- 关掉：`python3 scripts/tvctl.py power off`
- 重启：`python3 scripts/tvctl.py power reboot`

**「把 XX 装到电视上」**
1. `python3 scripts/appctl.py install /路径/xxx.apk`
2. 脚本会自动拉起应用，避免停留在“停止状态”。

**「电视现在什么状态」**
`python3 scripts/tvctl.py status`

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `TV` / `TV_IP` | `192.168.6.168` | 电视 IP（appctl 用 `IP:5555`，tvctl 分开设置） |
| `TV_PORT` | `5555` | ADB 端口 |
| `TV_MAC` | `c8:28:32:60:2d:af` | 电视 MAC（网络唤醒用） |
| `ADB` | 自动探测 | adb 可执行文件路径 |
| `AAPT` | 自动探测 | aapt 路径（读中文应用名用，缺失时只显示包名） |

## 注意事项

- 电视刚开机时 ADB 可能还没恢复，先 `tvctl.py status` 看一眼再操作。
- `uninstall` 只针对用户安装的应用；系统应用用 `disable`（可 `enable` 恢复）。
- 不要动 `com.example.adbkeeper`（AdbKeeper），它负责开机自动开 ADB，卸载后 ADB 就不会自动恢复了。
- 也不要用 `pm disable` 停用它，被停用后定时任务会失效。
- 如果 `tvctl.py status` 显示 ADB 一直没开，看门狗日志里会有提示，
  多数情况是助手被置为「停止状态」，看门狗会在 1 分钟内自动修复；仍不行就手动开一次 ADB。
- 电视系统本身每次开机都会把 ADB 关掉，这是小米电视的机制，靠 AdbKeeper 助手对抗，不需要改电视设置。
