---
name: tv-app-manager
description: 小米电视应用管理。当用户说「卸载某个应用」「删掉电视上的某某APP」「电视里那个XX不要了」「清理电视应用」时使用本技能——通过 ADB 按中文应用名精确定位并卸载电视上的应用，无需用户在电视上手动操作。也支持按名称查询、查看详情、停用/恢复系统应用、清除应用数据。
---

# 小米电视应用管理（tv-app-manager）

一句话卸载电视上的应用：**用户说应用的中文名 → 自动定位包名 → ADB 卸载 → 回报结果**。

## 核心工具

```bash
python3 scripts/appctl.py <命令> [参数]
```

工作区内的绝对路径：`/home/yao/rikkahub_file/mitv-adb-keeper/skills/tv-app-manager/scripts/appctl.py`

## 处理「卸载 XXX」的标准流程

**第 1 步：直接执行卸载**（脚本会自动连接电视、按中文名匹配、必要时列候选）

```bash
python3 scripts/appctl.py uninstall "云视听快TV"
```

输出示例：
```
→ 正在卸载：云视听快TV (com.kwai.tv.yst)
✅ 卸载成功：云视听快TV
```

**第 2 步：把结果回报给用户**，说明「已卸载哪个应用（包名）」。

### 匹配不到时怎么办
脚本会自动列出电视上所有用户安装的应用（含中文名），按提示用更准确的名字重试即可：

```bash
python3 scripts/appctl.py list        # 列出全部应用
python3 scripts/appctl.py find 云视听   # 关键词搜索
```

若用户只说了个模糊的名字（如「那个游戏的」「快 TV」），先 `find` 拿到候选，
再把候选列给用户确认后再卸载。

## 全部命令

| 命令 | 作用 |
|---|---|
| `list [--refresh]` | 列出所有用户安装的应用（中文名 + 包名 + 版本） |
| `find <关键词>` | 按中文名或包名搜索 |
| `info <应用名>` | 查看版本、安装时间、安装来源等详情 |
| `uninstall <应用名>` | **卸载应用**（核心功能） |
| `disable <应用名>` | 停用系统应用（对当前用户隐藏，可恢复） |
| `enable <应用名>` | 恢复被停用的应用 |
| `clear <应用名>` | 清除应用数据（回到刚安装状态） |

## 关键前提：ADB 必须可用

电视开机后 ADB 会**自动开启**（由电视端 `AdbKeeper` 助手维持，开机后约 1~2 分钟生效），
所以绝大多数时候可以直接用。

如果报「无法连接电视」，按顺序处理：

```bash
# 1) 电视刚开机？等 1~2 分钟再试（助手正在恢复 ADB）
# 2) 手动连一次
/home/yao/rikkahub_file/platform-tools/adb connect 192.168.6.168:5555
# 3) 跑一次守护器，它会尝试自动修复
/home/yao/rikkahub_file/mitv-adb-keeper/scripts/watchdog.sh
```

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `TV` | `192.168.6.168:5555` | 电视地址 |
| `ADB` | 自动探测 | adb 可执行文件路径 |
| `AAPT` | 自动探测 | aapt 路径（读中文名用，缺失时退回显示包名） |

## 注意事项

- **卸载会连同该应用的数据一起删除**，若用户只是暂时不想看，用 `disable`（系统应用）更安全。
- 应用中文名有缓存（`data/app_labels.json`），新装的应用看不到时加 `--refresh`。
- 部分应用由小米应用商店安装（`installerPackageName=com.xiaomi.mitv.appstore`），
  卸载后若被商店自动装回，属正常现象，可改用 `disable`。
- 电视上的系统应用（应用商店、系统设置等）用 `disable` 隐藏，不要硬删，否则可能影响电视功能。
