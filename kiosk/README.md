# Kiosk 模式（开机自动进 TVBox，其余应用屏蔽）

开机后电视自动进入 **TVBox**，其余应用一律被强制关闭并拉回 TVBox。

## 工作方式

| 环节 | 做法 |
|---|---|
| 开机拉起 TVBox | **双保险**：① 电视端助手（AdbKeeper）开机后用 `MAIN/LAUNCHER` 意图直接拉起（不依赖电脑）；② 电脑端 Kiosk 守护补拉一次 |
| 屏蔽其它应用 | 每 2 秒检测前台应用，不在白名单 → `am force-stop` 强停 → 立刻拉回 TVBox |
| 按主页键 | 桌面（tvhome）同样不在白名单 → 会被强停并拉回 TVBox |
| 休息时段 | 儿童守护进入 break/off 模式时**不抢屏**，交给提醒页显示 |
| 进程挂了 | 儿童守护看门狗（每分钟）自动重新拉起 |

## 使用

```bash
cd kiosk
./start_kiosk.sh     # 启动
./stop_kiosk.sh      # 停止（家长退出 Kiosk 用这个）
tail -f ~/.tv_guard/kiosk.log
```

## 配置 kiosk/kiosk.conf

| 配置项 | 说明 |
|---|---|
| `KIOSK_PACKAGE` | 开机进入哪个 App（默认 TVBox `com.github.tvbox.osc.tk`） |
| `KIOSK_ACTIVITY` | 启动页 Activity，留空自动解析 |
| `ALLOWED_PACKAGES` | 允许停留在屏幕上的应用（TVBox、休息提醒页、系统广告页） |
| `EXTRA_ALLOWED_PACKAGES` | 家长可临时打开的应用（系统设置、小米设置、应用商店） |
| `CHECK_INTERVAL` | 检测间隔秒数（默认 2） |
| `BOOT_DELAY` | 开机后延迟多少秒拉起（等系统启动完成，默认 45） |
| `RESPECT_BREAK_MODE` | 是否服从儿童守护的休息时段（默认 1） |

> 注意：把 `com.xiaomi.mitv.appstore`（应用商店）放进 `EXTRA_ALLOWED_PACKAGES`
> 等于允许孩子下载安装新应用——默认是放行的，按需收紧。

## 家长退出方式

1. SSH 到这台服务器执行 `kiosk/stop_kiosk.sh`（最稳妥）
2. 或临时把 `kiosk.conf` 里 `EXTRA_ALLOWED_PACKAGES` 加上需要的包

## 已知限制

- 无 root，无法真正「禁用」其它应用，只能在前台时强停（孩子打开的瞬间会被关掉）
- 系统弹窗（如权限请求、输入法）归属宿主应用，不会误杀
- 电视关机时守护会等待，ADB 恢复后立即生效
