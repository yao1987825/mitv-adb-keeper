# 小米电视 ADB 开机自动开启助手 (AdbKeeper)

让小米电视**每次开机后自动开启 ADB 调试**，无需再手动到电视设置里打开。
后台静默运行，不弹出任何界面。

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
│   └── uninstall.sh             # 从电视卸载
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
