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

## 实机调试记录（2026-11-16，电视开机后）

上线时修了 4 个实测问题：

| # | Bug | 修复 |
|---|---|---|
| 1 | `ensure_adb` 里误用了未定义的 `$TV_TARGET`，`set -u` 下进程每分钟退出 | 改为 `$ADB_TARGET` |
| 2 | 电视 `mCurrentFocus` 常为 `null`，导致前台被误判为「未知」 | 优先用 `mResumedActivity` |
| 3 | `launch_kiosk` 把组件拼成 `包名/包名/Activity`（非法），启动失败 | 判重后只保留一份包名 |
| 4 | 强停桌面会触发系统立即重启它，造成反复争夺前台 | 桌面(home)不再强停，只把 TVBox 盖上去；真正想逃的应用才强停 |

### 实机效果（2026-11-16 07:00）
- 打开非白名单应用（Aerial）→ **2 秒内**被拦截并拉回 TVBox
- 按主页键 → **2 秒内**拉回 TVBox
- 孩子下载安装快手 → **约 3 秒**自动卸载


## 已知限制

- 无 root，无法真正「禁用」其它应用，只能在前台时强停（孩子打开的瞬间会被关掉）
- 系统弹窗（如权限请求、输入法）归属宿主应用，不会误杀
- 电视关机时守护会等待，ADB 恢复后立即生效
