# 小米电视 BLE 遥控器 —— 硬件与部署指南

> 目标：用一块 ESP32 伪装成小米电视的**蓝牙遥控器**，实现「电视关机状态下远程开机」，
> 并把所有按键接入 Home Assistant / `tv-control` 技能。
>
> 依据：[shammysha/esphome-ble-mi-remote](https://github.com/shammysha/esphome-ble-mi-remote)
> （代码已克隆到 `~/rikkahub_file/esphome-ble-mi-remote`）

---

## 1. 要补齐的最后一环

目前对电视的远程控制能力：

| 通道 | 状态 | 说明 |
|---|---|---|
| ADB (5555) | ✅ 可用 | 电视开机后约 1 分钟自动开启，但**关机后就没了** |
| 小米助手 6095 | ⚠️ 半可用 | 电视浅待机时能响应，**深度待机/关机后完全不响应** |
| WoL 网络唤醒 | ❌ 不可用 | 小米电视 4 不支持，实测发唤醒包无反应 |
| 路由器红外发射 | ❌ 没有 | Kwrt 路由器无红外模块 |
| **BLE 遥控器** | 🔜 **本指南** | 电视待机时蓝牙射频仍在，能被"敲醒" |

**为什么 BLE 有戏**：小米电视 4 的原厂遥控器**本来就是蓝牙的**（没有红外），
电视在待机时 BLE 射频保持工作 —— 这是唯一还没试过的唤醒通道。

---

## 2. 整体链路

```
┌──────────┐  BLE(已配对)  ┌─────────────┐
│  ESP32   │◄─────────────►│  小米电视    │
│ C3/ESP32 │   HID 报告     │ MiTV4-ANSM0 │
└────┬─────┘                └─────────────┘
     │ WiFi
     ▼
┌──────────┐   API    ┌────────────────┐
│ Home     │◄────────►│ ESPHome / 技能   │
│ Assistant│          │ tv-control      │
└──────────┘          └────────────────┘
```

链路要求：**ESP32 必须常电**（见 §3.3），否则电视关机时它也关了，没法唤醒。

---

## 3. 硬件采购清单

### 3.1 主板选型

| 芯片 | 能否用 | Flash | 备注 |
|---|---|---|---|
| **ESP32-C3 SuperMini** | ✅ **首选** | 4MB | 合宙出品，¥8~15，尺寸小（21×18mm），USB-C 直插 |
| ESP32-WROOM-32（DOIT DevKit V1）| ✅ 备选 | 4MB | ¥15~25，Micro-USB，需杜邦线供电 |
| ESP32-S3 | ✅ | 8/16MB | 内存宽裕，ESPHome 支持成熟 |
| ESP32-S2 | ✅ | 4MB | 无 PSRAM 也够用 |
| ESP32-C6 | ⚠️ | 4/8MB | BLE 5.3 可用，但 ESPHome 支持较新，暂不建议 |
| **ESP32-C2** | ❌ | 2MB | **没有 BLE**，直接淘汰 |
| **ESP32-H2** | ❌ | 2MB | 只有 BLE 没有 WiFi，跑不了 ESPHome |

### 3.2 下单关键词

- 搜「**ESP32-C3 SuperMini**」或「合宙 ESP32-C3 SuperMini」
- 到货后确认：板上有 **USB-C 口**、**两颗按键（BOOT/RESET）**、**陶瓷天线在板子末端**

### 3.3 ⚠️ 供电方案（最容易踩的坑）

ESP32 **必须一直有电**，否则电视关机时它跟着关机，唤醒就无从谈起。

| 方案 | 是否推荐 | 说明 |
|---|---|---|
| **路由器 USB 口** | ✅ **最佳** | 本机 Kwrt 路由器有 USB 口且常电（`blue:usb` 指示灯），一根线搞定，还不用占插座 |
| 独立 USB 充电头 | ✅ 稳妥 | 5V/1A，插墙充 |
| 电视 USB 口 | ❌ **绝对不行** | 电视待机时 USB 口断电，ESP32 一起死 |
| 电池 | ⚠️ 不建议 | 深度睡眠会破坏自动重连；浅睡眠又费电 |

路由器 USB 供电注意：USB 2.0 标称 500mA，ESP32-C3 满负载约 130mA，**完全够**。
接线时用**数据线**（也用于烧录），插上后路由器的 `blue:usb` 灯会亮。

### 3.4 配件清单

| 物品 | 数量 | 用途 |
|---|---|---|
| ESP32-C3 SuperMini | 1 | 主体 |
| USB 数据线（**不能是纯充电线**）| 1 | 烧录 + 供电 |
| USB-A 转 USB-C 线（若用路由器供电）| 1 | 接到路由器 |
| 杜邦线/面包板（可选）| 若干 | 调试用 |

**不需要**：红外发射模块、继电器、额外的电源适配器。

---

## 4. 工作原理（够用就行）

### 4.1 模拟 BLE HID 遥控器

ESP32 把自己伪装成一个 **BLE HID 键盘设备**，实现小米电视的 HID 报告描述符：

- **Consumer Control 页**：24 个按键（Menu Pick/Up/Down/Left/Right、Power、Voice、音量±、Back…）
- **Keyboard 页**：标准键盘（打字用）
- **3 个厂商自定义 report（0x06/0x07/0x08，各 120 字节）**：小米私有协议，
  电视靠它确认「这是官方遥控器」而不是普通键盘

> 这部分小米私有协议**上游仓库（T-vK / dmamontov）完全没有**，
> 是 esphome-ble-mi-remote 作者自己 sniff 原厂遥控器逆出来的，是这个项目最值钱的部分。

### 4.2 四个关键机制

| 机制 | 作用 |
|---|---|
| **bond 学习** | 首次连上电视时记住它的 MAC，存进 flash（ESP preferences）|
| **HD 定向广播重连** | 断线后用 High-Duty-Cycle 定向广播对着电视 MAC 猛发 30 秒（每 1.3s 一轮），让睡眠中的电视第一时间发现 ESP32 |
| **connectWake** | 反过来当 BLE Central 主动去连已配对的电视 MAC，连上即断 —— 相当于"敲一下"电视 |
| **电源唤醒广播** | 电视**彻底关机**时，发一包小米专用的厂商数据 `46 00 e7 12 97 30 35 f2 78 ff ff ff 30 43 52 4b 54 4d` 试图唤醒 |

### 4.3 已知坑（代码里都注释了）

- **配对后 18.5~20.5 秒被电视主动断开**（reason=0x213）→ 作者为此把 NimBLE 版本一路二分，
  最终锁定在**自己的 fork 的定制分支** `shammysha/esp-nimble-cpp@ble-mi-remote-hd-directed`。
  **编译时必须用这个分支，用上游版不行。**
- 广告负载卡在 31 字节上限 → `setManufacturerData()` 会失败 → 所以电源唤醒广播要用
  「先停广播 → 换精简数据 → 再开」的方式发。
- 必须 `setName()`，否则设备在电视的「添加设备」列表里**没有名字、根本看不到**。

---

## 5. 软件环境准备

### 5.1 ESPHome（Docker 方案，不污染系统 Python）

```bash
mkdir -p /home/yao/esphome
docker run -d --name esphome \
  --network=host \
  -v /home/yao/esphome:/esphome \
  -v /dev:/dev \
  -v /home/yao/rikkahub_file/esphome-ble-mi-remote:/work/esphome-ble-mi-remote \
  esphome/esphome:latest
```

> `-v /dev:/dev` 是为了能烧录串口设备；`--network=host` 让 ESPHome 直接出现在局域网里。

验证：

```bash
docker exec -it esphome esphome version
```

### 5.2 环境要求

| 项 | 要求 | 本机情况 |
|---|---|---|
| Python | ≥3.10 | ✅ 3.12.3 |
| Docker | 任意近期版本 | ✅ 29.9 |
| 磁盘 | **额外 3~5GB**（ESP-IDF 工具链）| ⚠️ 只剩 8.5G，够但别再囤大文件 |
| 网络 | 编译时要能访问 github（拉定制 NimBLE 分支）| ✅ |

### 5.3 首次编译会下载什么

- ESP-IDF 工具链（~2~3GB）
- `h2zero/esp-nimble-cpp` 定制分支源码（编译时自动拉）

**建议**：第一次编译放慢一点，别中断；后续增量编译很快。

---

## 6. 完整配置文件

存到 `/home/yao/esphome/mi-remote.yaml`：

```yaml
substitutions:
  device_name: mi-remote
  wifi_ssid: "你的WiFi"
  wifi_password: "你的WiFi密码"
  ota_password: "自己设一个"

external_components:
  - source: github://shammysha/esphome-ble-mi-remote
  # 本地已 clone，想改代码时用本地路径：
  # - source:
  #     type: local
  #     path: /work/esphome-ble-mi-remote

esphome:
  name: ${device_name}
  friendly_name: "MI TV 遥控器"
  platformio_options:
    board_build.flash_mode: dio      # ESP32-C3 必须 dio，qio 会开不了机
  on_boot:
    priority: -100
    then:
      - ble_mi_remote.start: mi_remote

esp32:
  board: esp32-c3-devkitm-1
  variant: esp32c3
  framework:
    type: esp-idf                    # ★必需：上游是 arduino，本组件必须 esp-idf

logger:
  level: DEBUG                       # 首次调试用 DEBUG，稳定后改 INFO

api:
ota:
  - platform: esphome
    password: ${ota_password}

wifi:
  ssid: ${wifi_ssid}
  password: ${wifi_password}
  ap:
    ssid: "mi-remote-备用"
    password: "12345678"

web_server:
  port: 80                          # 方便直接看状态/触发

ble_mi_remote:
  id: mi_remote
  name: "MI Remote"
  manufacturer_id: "Shammysha"
  battery_level: 100
  reconnect: true
```

> ⚠️ README 里给的示例**直接抄会编译失败**，因为它漏了 `framework: type: esp-idf`。
> `dio` flash mode 是 ESP32-C3 的硬性要求（来自上游 `examples/esp32c3.yaml`）。

---

## 7. 编译与烧录

### 7.1 编译

```bash
cd /home/yao/esphome
docker exec -it esphome esphome compile mi-remote.yaml
```

首次会拉 ESP-IDF 工具链，**耐心等 10~30 分钟**。

### 7.2 烧录（USB 直插）

```bash
# 插上 ESP32 前先看看设备号
ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null

# 烧录
docker exec -it esphome esphome run mi-remote.yaml --device /dev/ttyUSB0
```

如果识别不到：按住 **BOOT** 键 → 点一下 **RESET** → 松开 BOOT，进入下载模式再试。

烧录完成后建议**拔掉数据线，改用路由器 USB 口常供电**（见 §3.3）。

### 7.3 常见编译错误

| 报错 | 原因 | 处理 |
|---|---|---|
| `add_idf_component` 报错 | 没写 `framework: type: esp-idf` | 补上 |
| 拉不到 `ble-mi-remote-hd-directed` 分支 | 网络到 github 不通 / 分支被作者删了 | 用代理；或改用 `origin/esp-nimble-cpp` 分支试编译 |
| `ble_gap_adv_validate rc=3` 刷屏 | NimBLE 版本差异 | 用定制分支（默认就是）|
| C3 刷完不启动 | flash mode 不是 dio | 改 `board_build.flash_mode: dio` 重新编译 |

---

## 8. 电视端配对

1. ESP32 上电，等待串口日志出现 `Advertising started!`
2. 电视：`设置 → 蓝牙`（部分 MIUI 叫「遥控器和配件」）→ 添加设备
3. 在列表里找到名字为 **`MI Remote`**（= ESPHome 的 `friendly_name`）的设备
   - ⚠️ 如果**列表里根本找不到**，先看 §9 的排查
4. 配对（可能要求输入配对码，BLE 常见为 `0000` 或 `123456`）
5. 配对成功，串口日志应出现：
   ```
   onConnect: not bonded, requesting security: startSecurity()=OK rc=0
   learnTargetMac: learned peer XX:XX:XX:XX:XX:XX, saved to flash=OK
   ```
6. 之后 ESP32 就会用 **HD 定向广播**对着这个 MAC 重连，电视睡眠时也能秒连

---

## 9. 验证

### 9.1 串口日志（关键行）

```bash
docker exec -it esphome esphome logs mi-remote.yaml
```

正常应看到：

```
Advertising started!
onConnect: not bonded, requesting security: startSecurity()=OK
learnTargetMac: learned peer AA:BB:CC:DD:EE:FF, saved to flash=OK
Disconnected: AA:BB:CC:DD:EE:FF, reason=0x13     ← 18~20 秒后断开是已知现象
startReconnectAdvert: bonded to AA:BB:CC:DD:EE:FF -> starting HD-burst retry (30s window)
fireDirectedBurst: HD directed burst to AA:BB:CC:DD:EE:FF, stop=OK start=OK
```

### 9.2 Home Assistant

添加集成 → ESPHome → 填 ESP32 的 IP →
会出现 **24 个 button 实体**（名字形如 `ble-mi-remote-enter`、`ble-mi-remote-power`…）
和一个 **connected 二进制传感器**。

### 9.3 端到端测试

| 测试 | 预期 |
|---|---|
| HA 点 `ble-mi-remote-power` | 电视关机 → **开机** ⭐ |
| HA 点 `ble-mi-remote-up/down/enter` | 电视菜单移动/确认 |
| HA 点 `ble-mi-remote-back` | 返回 |
| HA 点 `ble-mi-remote-volumeup` | 音量加 |
| 电视关机 5 分钟后同上 | 仍能唤醒（靠 HD 定向广播）|

---

## 10. 接入 `tv-control` 技能（兜底逻辑）

建议把 `tvctl.py power on` 改成**三级递进**：

```
1. ADB 5555 可用   → adb shell input keyevent 26        （电视开着，最快）
2. ADB 不可用但电视在线 → BLE 电源键（新增）
3. 都不行          → 明确提示「需人工按遥控器」
```

实现方式二选一：
- **简单**：技能里直接 `curl http://<esp32-ip>/...`（需 ESPHome web_server 支持触发 button）
- **正规**：HA 里写自动化 → 调用 HA REST API → `button.press`

> ESPHome 的 `web_server` REST 接口对 button 的支持有限，需实测；
> 若不通则走 HA 的 `POST /api/services/button/press`。

---

## 11. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 电视「添加设备」里找不到 | 广播没带名字 | 确认用 Mi 版（已修 `setName()`）；确认 `enableScanResponse(true)` |
| 配对后 18~20 秒必断 | **已知现象**，电视主动断 | 正常，用定制 NimBLE 分支；靠 HD 定向广播维持重连 |
| 一直连不上 | 电视没开蓝牙 / 没配对 / MAC 学错了 | HA 里看 `connected` 传感器；必要时删掉 ESP32 的 bond 重新配对 |
| 电视关机后唤醒不了 | ESP32 没常电 / 电视不支持该唤醒包 | 确认供电方案（§3.3）；确认电视确实支持 BLE 遥控 |
| ESP32 反复重启 / 变砖 | 供电不足 | 换独立电源，别用劣质 USB 线 |
| HA 里没有实体 | api 配错 / ESP32 没连上 WiFi | 看日志 `IP:xxx` 那行 |
| `powerAdvert` 发了但电视没醒 | 电视不支持关机态唤醒 | MiTV4 可能只支持待机唤醒；**彻底关机后仍需人工** |

---

## 12. 实施 checklist

```
□ 买 ESP32-C3 SuperMini（合宙，4MB，USB-C）
□ 确认有 USB 数据线（非充电线）
□ 决定供电：路由器 USB 口（推荐）/ 独立充电头
□ docker 跑 ESPHome
□ 写 mi-remote.yaml（照 §6 抄）
□ 编译（首次 10~30 分钟）
□ 烧录（BOOT+RESET 进下载模式）
□ 改用常供电方式，插到路由器 USB 口
□ 电视 设置→蓝牙→添加设备→配对
□ HA 里看到 24 个 button 实体
□ 测试：电视关机 → HA 点 power → 电视开机
□ 把 BLE 能力接进 tvctl.py power on
```

---

## 13. 如果 BLE 也不行，退路

| 方案 | 可行性 | 成本 |
|---|---|---|
| 给电视供电回路加个 WiFi 智能插座，遥控器信号用 ESP32 发红外 | MiTV4 若无红外接收头则无效 | 低 |
| 用 `bluetoothctl` 在 Linux 上直接连电视 BLE 发 HID 报告 | 可行但要电视保持可发现 | 零 |
| 改造电视系统：把 AdbKeeper 装成开机自启的常驻服务 | 需 root（这台没有）| - |
| 接受现状：电视关机需人工，电视开着时全部远程可控 | 零成本 | 零 |

---

## 附：相关仓库

| 仓库 | 作用 |
|---|---|
| `shammysha/esphome-ble-mi-remote` | **主项目**（小米私有协议都在这）|
| `shammysha/esp-nimble-cpp` | 定制 NimBLE 分支（编译必需）|
| `T-vK/ESP32-BLE-Keyboard` | 上游：Arduino BLE 键盘库 |
| `dmamontov/esphome-blekeyboard` | 上游：ESPHome 封装（含 esp32c3.yaml 范例）|
| `DenizOner/MiPower` | 开机唤醒技巧的灵感来源（未 clone）|
