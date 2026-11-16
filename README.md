# 小米电视助手 (mitv-adb-keeper)

一套工具解决小米电视的两件事：

1. **ADB 开机自动开启** —— 以后不用再手动到电视设置里打开 ADB 调试
2. **儿童观看时间管理** —— 限定少数 APP 的观看时长，到点自动强制休息

全部后台静默运行，不弹出任何界面；日常使用无需任何人工确认。

> 本仓库由原 `tv-child-guard`（儿童观看时间管理）与 ADB 自动开启方案合并而成。

> 适用机型：小米电视 4（MiTV4-ANSM0，代号 xmen），Android 6.0.1 / MIUI TV 固件 20.3.6.2057
> 其他小米电视（Mi TV 4A/4C、小米盒子等）同属该机制，大概率同样适用。

---

## 问题根因

小米电视开机时，系统设置应用 `com.xiaomi.mitv.settings` 的
`SystemInitService` → `SettingsUtil.checkInitSettings()` 会强制执行：

```java
if (!SystemProperties.getBoolean("sys.set_adb_disabled", false)) {
    setADBEnable(0);                            // Settings.Global.adb_enabled = 0
    SystemProperties.set("sys.set_adb_disabled", "true");
}
```

`sys.*` 属性每次重启都会被清空，因此**每次开机它都会再把 ADB 关一次**。
系统日志可以清楚看到这一过程：

```
UsbDeviceManager: Setting USB config to mtp        ← 系统关闭 ADB
UsbDeviceManager: Setting USB config to mtp,adb    ← ADB 恢复
```

> 注：该逻辑位于 SDK ≥ 23 分支，调用 `setADBStatus()` 写入 `Settings.Global.adb_enabled`；
> SDK < 23 的旧机型则走 `persist.sys.usb.netadb.config` 属性分支。

## 解决方案原理

`AdbKeeper` 是一个零界面后台应用，用三件事绕开上述限制：

1. **JobScheduler 持久化任务**（`setPersisted(true)`）
   任务由系统保存，重启后自动恢复执行，**不依赖应用能否收到 `BOOT_COMPLETED` 广播**
   （电视上通过 `adb install` 安装的应用默认处于“停止状态”，收不到开机广播）。

2. **真实端口探测**
   每次任务直接连接 `127.0.0.1:5555`，判断 ADB 网络调试是否真的可用，
   而不是依赖容易失真的系统属性。

3. **调用小米自己的系统服务 `TvService`**
   该服务由 `mitv.service` 注册到 ServiceManager，binder 事务号 `4004` 即“启用 ADB”命令：
   ```bash
   service call TvService 4004 i32 1     # 1=开启  0=关闭
   ```
   它以系统身份写入 `Settings.Global.adb_enabled=1` 与 `sys.mitv.adb.default=true`，
   框架随即把 USB 配置切回 `mtp,adb`，**adbd 重新监听 5555 端口**。

任务执行完会再排入 60 秒后的下一次任务，形成自续期链，
保证系统关闭 ADB 后总能被自动恢复。

### 实测效果

```
02:13:32  电视开机
02:13:42  ADB 端口自动开启
02:14:02  系统关闭 ADB      ← 以前每次都要手动处理这一步
02:14:52  ✅ AdbKeeper 自动重新开启（全程无人工干预）
```

开机后约 **1～2 分钟**内 ADB 自动可用。

### v1.6 重要修正：助手长时间不运行导致 ADB 无法自恢复（2026-11-16）

**现象**：电视重启后，ADB 端口要 6 分钟才恢复，甚至**永远不恢复**（连不上电视）。
日志显示助手有 **16.6 小时完全没有运行**的空白。

**根因（3 个叠加的 bug）**：

| # | Bug | 说明 |
|---|---|---|
| 1 | **链式任务会静默断链** | 原代码先干活、后排下一次任务。进程若在两步之间被系统回收，链条永久断掉且无任何痕迹 |
| 2 | **"保险"反而顶掉了兜底** | 每次运行都重新注册 5 分钟周期任务 → 计时器被反复重置 → 这个兜底**永远等不到 5 分钟**，形同虚设 |
| 3 | **恢复太慢** | 链式间隔 60 秒 + 调度抖动 → 系统关掉 ADB 后要等数分钟 |

**修复**：
1. `onStartJob` 里**先排下一次任务、再干活** —— 进程中途被杀链也不会断
2. `onStopJob`（被系统中断）时立刻重排
3. 周期任务改为**最多 10 分钟才重排一次**，不再每次运行都重置计时器
4. 链式间隔 60 秒 → **30 秒**；两个任务都加 `NETWORK_TYPE_NONE`（不等网络）

**实测对比**：
```
修复前：12:01:22 系统关闭 ADB → 12:07:24 助手恢复   （空窗 6 分钟 / 可能永不恢复）
修复后：12:19:14 系统关闭 ADB → 12:19:41 助手恢复   （空窗 27 秒）
```


---

## 全自动守护（无需任何人工确认）

整套方案由三层组成，**从开机到日常运行，全程不需要在电视或电脑上点任何“允许/确认/安装”**：

| 层级 | 位置 | 职责 |
|---|---|---|
| ① 电视端助手 | 电视上的 `com.example.adbkeeper` | 开机后自动开启 ADB；每 60 秒自检一次 |
| ② 电脑侧守护器 | 本仓库 `scripts/watchdog.sh` | 探测 ADB、异常时自动修复、**静默自动升级助手** |
| ③ 定时任务 | crontab（每 5 分钟） | 让守护器在服务器上持续运行 |

### 为什么以后不会再弹授权框
电脑首次连接时，电视会把本机的 ADB 公钥写入 `/data/misc/adb/adb_keys`（电视端
`dumpsys usb` 的 `User keys` 可查，已含 `yao@server`）。该授权**永久有效**，
重启电视不会失效，也不会再弹“允许 USB 调试”。

### 静默自动升级
守护器会比较本地 `dist/adbkeeper.apk` 与电视上已安装 APK 的 **md5**：

```
2026-11-15 02:28:01 🔄 检测到新版本，后台静默安装...
2026-11-15 02:28:10    ✅ 新版本已静默安装并启动
```

差异则用 `adb install -r` 覆盖安装并重新拉起，**全程无弹窗、无需点击**。
所以以后更新助手只要替换掉 `dist/adbkeeper.apk`，下一次巡检会自动完成升级。

### 状态查询与反馈

```bash
./scripts/status.sh
```

输出包含：当前状态、实时端口探测、近 7 天正常/告警/失败统计、最近一次失败与修复记录、最近 10 条日志。

状态数据全部落在本项目 `data/` 目录：

| 文件 | 内容 |
|---|---|
| `data/status.txt` | 当前状态快照 |
| `data/watchdog.log` | 每次巡检的完整流水（追加写） |
| `data/state.env` | 上次状态（用于识别“恢复”并单独记录） |

### 手动巡检 / 修复

```bash
./scripts/watchdog.sh     # 立即执行一次巡检（发现异常会自动尝试修复）
```

异常时守护器会：先重连排除误判 → 再守候开机窗口（最长 120 秒）→ 捕获端口开启的瞬间，
在电视本地执行 `service call TvService 4004 i32 0` + `i32 1` 强制重启 adbd →
验证端口恢复。

### 故障自愈演练

```bash
# 人为关闭电视 ADB，验证守护器能自动修回来
adb -s 192.168.6.168:5555 shell \
  "nohup sh -c 'service call TvService 4004 i32 0' >/data/local/tmp/break.log 2>&1 &"
./scripts/watchdog.sh
```

---

## 实现要点与踩坑记录

### 1. `sys.*` 属性重启即清空
小米电视用 `sys.set_adb_disabled` 记录“本次开机已处理过”，但它不是持久化属性，
每次开机都会清空 → 于是每次都把 ADB 再关一次。这也是为什么单纯改
`Settings.Global.adb_enabled` 或 `persist.sys.usb.netadb.config` 都无效。

### 2. `adb install` 的应用收不到开机广播
通过 `adb install` 安装的应用默认处于 **stopped 状态**，系统不会向其投递
`BOOT_COMPLETED`。解决办法是用 `am start` 启动一次让应用脱离该状态，
并改用 **JobScheduler 持久化任务**（`setPersisted(true)`）兜底——
该机制由系统保存并恢复，不依赖应用自身的广播接收器。

### 3. 端口探测必须声明 `INTERNET` 权限
用 `Socket` 连 `127.0.0.1:5555` 探测时，若清单未声明
`android.permission.INTERNET`，连接会被系统直接拒绝（抛 `SecurityException`）。
早期版本因此**永远误判“ADB 未开启”**，日志失真、且会无谓打断正在使用的连接。
加上权限后探测才准确，日志与行为都恢复正常。

### 4. adbd 的监听地址
`/proc/net/tcp` 显示 adbd 监听 `0.0.0.0:5555`（uid 2000），
因此应用内用 `127.0.0.1` 探测是可行的。

### 5. 有效的“开启”动作是 0→1
只有 `adb_enabled` 发生 0→1 变化时，框架才会把 USB 配置切回 `mtp,adb`
并重启 adbd。若其已是 1，调用开启命令是空操作——所以端口不可用时需要
先 `0` 再 `1` 强制翻转。


---

## 附：技能包 tv-app-manager（一句话卸载应用）

`skills/tv-app-manager/` 是一个独立的技能包，可导入 RikkaHub / opencode 使用。

**能力**：用户说「卸载云视听快TV」→ 自动按中文名定位包名 → ADB 卸载 → 回报结果，
全程不需要用户在电视上做任何操作。

```bash
cd skills/tv-app-manager
python3 scripts/appctl.py list                  # 列出电视上所有应用（中文名）
python3 scripts/appctl.py find 云视听            # 按名字搜索
python3 scripts/appctl.py uninstall 云视听小电视  # 按中文名卸载
python3 scripts/appctl.py info 咪咕游戏TV版       # 查看详情
python3 scripts/appctl.py disable <应用名>        # 系统应用隐藏（可恢复）
```

打包成可导入的 zip：

```bash
python3 scripts/package_skill.py
# → skills/tv-app-manager-rikkahub.zip
# RikkaHub：设置 → 扩展管理 → 技能 → + → 从文件导入
```

**实现要点**：应用中文名藏在 APK 的 `resources.arsc` 里，直接整包拉取动辄几十 MB。
脚本改为在电视端用 `busybox unzip -p` 只抽出 `resources.arsc` 与 `AndroidManifest.xml`
（几十 KB），在电脑上拼成最小 APK 再用 `aapt dump badging` 取名，速度提升一个数量级；
取到的名字缓存在 `data/app_labels.json`，之后查询几乎瞬时。


---

## 模块二：child-guard —— 儿童观看时间管理

原独立的 `tv-child-guard` 项目已并入本仓库（`child-guard/`），共用同一套 ADB 工具链。

**能力**：限定每天/单次的观看时长，到点强制休息；只管控指定的少数 APP，其余功能不受影响。

```bash
cd child-guard
./start_tv_guard.sh     # 启动守护（后台运行，防重复启动）
./stop_tv_guard.sh      # 停止守护
./watchdog.sh           # 看门狗：守护挂了自动拉起（cron 每分钟已自动执行）
tail -f ~/.tv_guard/tv_guard.log    # 实时日志
cat ~/.tv_guard/daily_usage.txt     # 今日已看时长
```

**当前管控的 3 个 APP**（`com.kwai.tv.yst` 云视听快TV、`com.duokan.videodaily` 云视听、`com.cmgame.gamehalltv` 游戏大厅），
其它 APP 一律不受影响：不会被计时、不会被强停、不会被提醒页盖住。

**规则**：白天（08:00–20:00）单次连续 30 分钟 → 强停并强制休息 30 分钟；每天累计 120 分钟 → 当天禁止；
**夜间（20:00–次日 08:00）直接禁止**这 3 个受控 APP，到点自动恢复。
**禁止重新安装**：孩子反复下载的快手/云视听快TV（`com.kwai.tv.yst`）一旦出现，看门狗每分钟自动卸载。
计时数据保存在电脑 `~/.tv_guard/`，关机、重启、拔电源都不会清零（跨天才归零）。

### v1.3 重要修正（2026-11-15）
之前电视重启后**整个屏幕被"禁止观看"封面盖住**，看起来像电视完全不能用，实测确认是三个问题叠加：

| 问题 | 原因 | 修复 |
|---|---|---|
| 开机后全屏封面挡住电视 | 旧逻辑「孩子**回到桌面(空闲)**就自动重新弹封面」，开机正停在桌面 → 立刻盖满全屏 | 改为**只有真去开那 3 个受控 APP 才弹** |
| 提醒页关不掉像被锁死 | 提醒页吞掉返回键/菜单键，还设了 `FLAG_KEEP_SCREEN_ON` 阻止熄屏 | 返回键可正常退出；去掉常亮标志 |
| 提醒页弹不出来 | 强停 APP 后按了 HOME 键，桌面在提醒页**之后**才切前台，把提醒页盖住了 | 去掉多余 HOME 键，强停后稍等再弹 |

修正后的实测行为：
```
打开受控APP →  ≤5秒内被强停  →  弹出提醒页（带剩余时间倒计时）
按返回键     →  关闭提醒页回到桌面，电视其它功能完全可用
回到桌面     →  不再自动弹（除非又去开受控APP）
```

详见 [`child-guard/使用说明.md`](child-guard/使用说明.md)。


---

## 模块三：kiosk —— 开机自动进 TVBox，其余应用屏蔽

`kiosk/` 模块：电视开机自动进入 **TVBox**，其余应用每 2 秒检测一次，
不在白名单就强制关闭并拉回 TVBox（按主页键也回不去）。

```bash
cd kiosk
./start_kiosk.sh     # 启动
./stop_kiosk.sh      # 停止（家长退出用）
```

- 开机拉起 TVBox 是**双保险**：电视端助手开机直接拉起（不依赖电脑）+ 电脑端守护补拉
- 与儿童守护联动：休息时段不抢屏，交给提醒页
- 进程挂了由儿童守护看门狗（每分钟）自动拉起
- 详细说明见 [`kiosk/README.md`](kiosk/README.md)


---

## 目录结构

```
mitv-adb-keeper/
├── app/                         # Android 应用源码
│   ├── AndroidManifest.xml
│   ├── res/values/strings.xml
│   └── src/com/example/adbkeeper/
│       ├── AdbHelper.java       # 端口探测 + 调用 TvService(4004)
│       ├── AdbJobService.java   # 持久化任务（周期 + 链式单次）
│       ├── BootReceiver.java    # 开机广播（补充触发）
│       └── MainActivity.java    # 启动入口（解除停止状态、注册任务）
├── scripts/
│   ├── build.sh                 # 编译 APK
│   ├── install.sh               # 安装到电视并配置
│   ├── uninstall.sh             # 从电视卸载
│   ├── watchdog.sh              # 电脑侧守护器：巡检 / 自愈 / 静默自动升级
│   └── status.sh                # 状态摘要（反馈查询）
├── data/                        # 守护器运行数据（状态 / 日志）
│   ├── status.txt
│   ├── watchdog.log
│   └── state.env
├── dist/
│   ├── adbkeeper.apk            # 已签名可直接安装的 APK
│   └── adbkeeper.keystore       # 签名证书（个人开发用，见下方说明）
├── connect_tv.sh                # 电脑端快速连接脚本
└── README.md
```

## 使用方法

### 1. 安装到电视

```bash
cd mitv-adb-keeper
TV=192.168.6.168:5555 ./scripts/install.sh
```

或手动：

```bash
adb connect 192.168.6.168:5555
adb -s 192.168.6.168:5555 install -r dist/adbkeeper.apk
adb -s 192.168.6.168:5555 shell am start -n com.example.adbkeeper/.MainActivity
```

> 首次连接电视时会弹出“允许 USB 调试”授权框，勾选“一律允许”后确定；
> 之后电脑端的 ADB 密钥已授权，重启无需再次确认。

### 2. 电脑端连接

```bash
./connect_tv.sh            # 连接电视
./connect_tv.sh status     # 查看状态
./connect_tv.sh shell      # 进入电视 shell
./connect_tv.sh reboot     # 重启电视
```

### 3. 验证是否生效

```bash
adb -s 192.168.6.168:5555 reboot
# 等待 1~2 分钟后
adb connect 192.168.6.168:5555   # 应能直接连上
```

查看助手运行日志：

```bash
adb -s 192.168.6.168:5555 shell "run-as com.example.adbkeeper cat files/adbkeeper.log"
```

## 从源码构建

需要 Android build-tools（aapt2 / d8 / zipalign / apksigner）、
android-6.0 平台库（android.jar）、JDK 17、Python 3。

```bash
export ANDROID_SDK=/path/to/android_sdk
export JAVA_HOME=/path/to/jdk
./scripts/build.sh
```

## 卸载 / 关闭自动开启

```bash
./scripts/uninstall.sh
# 或
adb -s 192.168.6.168:5555 uninstall com.example.adbkeeper
```

> ⚠️ **注意**：助手会让 ADB 保持常开——在电视上手动关闭 ADB 调试也会被自动恢复。
> 若要彻底关闭，请卸载应用。

## 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 重启后约 2 分钟才连上 | 正常表现。系统先关、助手再开，稍等即可 |
| 一直连不上 | 检查助手是否安装：`adb shell pm list packages \| grep adbkeeper`；再运行 `scripts/install.sh` |
| 助手没运行 | 确认 `stopped=false`：`adb shell "dumpsys package com.example.adbkeeper \| grep stopped"`；必要时重新执行一次 `am start` |
| 想改成别的电视 IP | 修改 `connect_tv.sh` 与 `scripts/*.sh` 里的 `TV` 变量 |
| 应用启动后电视会跳设置页 | 本方案**不含**任何界面操作，不会跳转（早期版本的无障碍方案已废弃） |

## 安全说明

- `dist/adbkeeper.keystore` 是本项目专用的**自签名开发证书**，仅用于保证应用可原地升级，
  不涉及任何真实账号凭据。如需自行构建，请生成自己的 keystore 并修改 `scripts/build.sh`。
- 助手不会上传任何数据、不联网，仅在本机调用系统服务。

## 许可

MIT License，见 [LICENSE](LICENSE)。
