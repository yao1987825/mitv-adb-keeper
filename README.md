# 小米电视控制与 ADB 常开（tv-control）

一套面向**小米电视 4（MiTV4-ANSM0 / Android 6.0.1 / MIUI TV 20.3.6.2057）**的轻量工具：

1. **ADB 开机自动开启** —— 以后不用再手动到电视设置里打开 ADB 调试
2. **电视远程控制** —— 开关机、重启、查状态
3. **应用远程管理** —— 按中文名安装 / 卸载 / 停用 / 查详情

全部后台静默运行，不弹出任何界面；日常使用无需任何人工确认。

> 本仓库原是 `mitv-adb-keeper` 的**儿童观看时间管理**项目（含路由器 DNS 黑洞），
> 现已重写为**纯 ADB 常开 + 电视控制**工具，原管控功能全部废弃。
> 原项目的「儿童观看时间管控」「强制长辈模式」「路由器屏蔽短视频接口」等
> 功能已**全部废弃并从电视/路由器上还原**，详见文末「历史与废弃说明」。

---

## 快速开始

```bash
git clone git@github.com:yao1987825/mitv-adb-keeper.git
cd tv-control
bash install.sh                 # 装助手 + 注册看门狗 + 打包技能
```

`install.sh` 会自动完成：

| 步骤 | 说明 |
|---|---|
| 连接电视 | `192.168.6.168:5555`（可用参数覆盖：`bash install.sh <电视IP>`）|
| 安装 AdbKeeper | 零界面后台助手，只做一件事：开机自动开 ADB |
| 拉起一次 | **必须**：否则 Android 会把应用置为「停止状态」，定时任务被取消 |
| 注册 cron 看门狗 | 每分钟体检，助手被系统置停时自动拉起修复 |
| 打包技能 | 生成 `tv-control-rikkahub.zip`，供 RikkaHub 导入 |

卸载（恢复电视原状）：`bash uninstall.sh`

---

## 为什么需要 AdbKeeper 助手

小米电视每次开机，系统设置应用 `com.xiaomi.mitv.settings` 的
`SystemInitService` → `SettingsUtil.checkInitSettings()` 都会强制执行：

```java
if (!SystemProperties.getBoolean("sys.set_adb_disabled", false)) {
    setADBEnable(0);                                  // Settings.Global.adb_enabled = 0
    SystemProperties.set("sys.set_adb_disabled", "true");
}
```

`sys.*` 属性每次重启都会被清空，因此**每次开机它都会再把 ADB 关一次**。

### 助手的破解思路

`AdbKeeper` 用三件事绕开这个限制：

1. **JobScheduler 持久化任务**（`setPersisted(true)`）
   任务由系统保存，重启后自动恢复执行，不依赖应用能否收到 `BOOT_COMPLETED` 广播。
2. **真实端口探测**
   直接连接 `127.0.0.1:5555` 判断 ADB 是否真的可用，而不是依赖容易失真的系统属性。
3. **调用小米自己的系统服务 `TvService`**
   该服务由 `mitv.service` 注册到 ServiceManager，binder 事务号 `4004` 即「启用 ADB」：

   ```bash
   service call TvService 4004 i32 1     # 1=开启  0=关闭
   ```

   它以系统身份写入 `Settings.Global.adb_enabled=1` 与 `sys.mitv.adb.default=true`，
   框架随即把 USB 配置切回 `mtp,adb`，**adbd 重新监听 5555 端口**。

### 实测效果

```
电视开机
  ↓ 约 60~90 秒
AdbKeeper 检测到 5555 未开 → callTvService(4004) → ok=true → ADB 恢复
```

---

## 目录结构

```
tv-control/
├── README.md                     本文档
├── SKILL.md                      RikkaHub 技能说明（随 zip 导入）
├── install.sh                    一键部署
├── uninstall.sh                  一键卸载 / 还原
├── build_zip.sh                  打包技能 zip
├── scripts/
│   ├── appctl.py                 应用管理：装/卸/停用/查（支持中文名）
│   ├── tvctl.py                  电源控制 + 状态查询
│   └── keeper_watchdog.sh        AdbKeeper 健康看门狗（cron 每分钟）
└── adbkeeper/                    助手 App 工程
    ├── app/AndroidManifest.xml   无 LAUNCHER 入口（桌面无图标）
    ├── app/res/values/strings.xml 应用名 = 系统服务
    ├── app/src/.../AdbHelper.java  调用 TvService 4004 开启 ADB
    ├── app/src/.../AdbJobService.java 持久化任务 + 链式自续期
    ├── app/src/.../BootReceiver.java 开机广播兜底
    ├── dist/adbkeeper.apk        成品
    ├── dist/adbkeeper.keystore   签名证书
    └── scripts/build.sh          重新构建
```

### 重新构建助手

```bash
export JAVA_HOME=~/rikkahub_file/tools/jdk
bash adbkeeper/scripts/build.sh
```

---

## 使用方法

### 电视控制

```bash
python3 scripts/tvctl.py status            # 在线状态 / ADB 是否可用 / 开机时长 / 已装应用
python3 scripts/tvctl.py power off         # 关机（待机）
python3 scripts/tvctl.py power reboot      # 重启
python3 scripts/tvctl.py power on          # 唤醒（ADB → 小米助手 6095 → 网络唤醒 依次尝试）
```

### 应用管理

```bash
python3 scripts/appctl.py list             # 列出所有用户安装的应用（中文名 + 包名 + 版本）
python3 scripts/appctl.py find <关键词>     # 按中文名或包名搜索
python3 scripts/appctl.py info <应用名>     # 版本、安装时间、来源
python3 scripts/appctl.py uninstall <应用名>  # 卸载
python3 scripts/appctl.py install <本地apk>   # 安装（自动拉起，避免停在停止状态）
python3 scripts/appctl.py disable <应用名>   # 停用系统应用
python3 scripts/appctl.py enable <应用名>    # 恢复
python3 scripts/appctl.py clear <应用名>     # 清除数据
```

### 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `TV` / `TV_IP` | `192.168.6.168` | 电视地址 |
| `TV_PORT` | `5555` | ADB 端口 |
| `TV_MAC` | `c8:28:32:60:2d:af` | 电视 MAC（网络唤醒用）|
| `ADB` | 自动探测 | adb 路径 |
| `AAPT` | 自动探测 | aapt 路径（读中文应用名用）|

---

## 隐藏与防卸载

助手在电视上**完全隐形**，小孩不会去动它：

| 项 | 值 |
|---|---|
| 包名 | `com.example.adbkeeper` |
| 电视上显示名 | **系统服务**（像系统组件）|
| 桌面图标 | **没有**（已移除 MAIN/LAUNCHER 入口，桌面和应用列表都找不到）|
| 可见入口 | 仅「设置 → 应用管理」里一个不起眼的条目 |

> ⚠️ **重新安装助手后必须立刻执行一次**
> `adb shell am start -n com.example.adbkeeper/.MainActivity`
> 否则 Android 会把它置为「停止状态」，排定任务被取消，ADB 不会自动开启。
> 看门狗会在 1 分钟内自动修复这一状态。

---

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| ADB 连不上，电视在线 | 电视刚开机，等 1~2 分钟助手恢复；或手动开一次「设置 → 账户与安全 → ADB调试」|
| 助手在应用列表里显示「系统服务」但无法启动 | 正常现象 —— 它本就不该被手动启动 |
| 看门狗日志出现「🔧 检测到助手处于『停止状态』」| MIUI 把应用置停了，看门狗已自动拉起修复 |
| 电视彻底关机后无法远程唤醒 | 小米电视 4 **不支持网络唤醒**，需用遥控器手动开机 |
| `pm install` 报 `INSTALL_FAILED_INVALID_URI` | 先 `adb push` 再 `adb shell pm install`（大包推送易断）|

看门狗日志：`~/.tv_control/watchdog.log`

---

## 历史与废弃说明

本仓库前身是 `mitv-adb-keeper`，曾包含「儿童观看时间管理」功能：

- 电视端 `tv_guard.sh` 守护：限时看视频、强停 App、弹休息提醒页
- 电视端自动切换并锁定「长辈模式」，拦截孩子手动切回标准模式
- 路由器 `/etc/hosts` 加黑洞，屏蔽 PatchWall 的短视频/短剧内容接口
- 自动卸载「白名单外」的 App、被禁 App 自动卸载
- 摄像头/语音提醒页 APK

**这些功能已全部废弃并从设备上还原**：

| 还原项 | 现状 |
|---|---|
| 电视桌面模式 | 已从「长辈模式」(`user_mode=2`) 恢复为**标准模式** (`user_mode=0`) |
| 路由器 `/etc/hosts` | 项目加入的 20 条 PatchWall 黑洞域名**已全部删除**，dnsmasq 已重启 |
| 电视端管控 App | 提醒页等 APK 已卸载，无残留进程 |
| 电脑端守护 | `~/.tv_guard` 运行数据、cron 任务已清理 |
| 开发者设置 | 项目写入的 `developer_status` / `development_settings_enabled` 已清除 |

保留的只有 **AdbKeeper 助手**（开机自动开 ADB）这一项，因为它与「管控」无关，
而是后续所有远程操作的基础设施。

旧代码与历史保留在 `legacy/child-guard` 分支，仅作归档参考。
