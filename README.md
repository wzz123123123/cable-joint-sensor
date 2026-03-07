# 电缆接头检测 (Cable Joint Sensor)

> 本文档由 AI 辅助创作。

基于 Flutter 的电缆接头多节点监测应用，通过 Modbus TCP / RS485 采集现场传感器数据，实现实时监测、历史查询与告警管理。

---

## 功能概览

- **实时监测**：多节点（1–5 节点）温度、湿度等测点实时展示，按系统状态着色
- **通信协议**：Modbus TCP 客户端/服务端、RS485 协议解析，支持 PT100 温度与计算温度
- **历史数据**：按日/按条件查询历史记录，支持详情与图表展示（fl_chart）
- **数据导出**：CSV 日志记录与文件管理，支持导出与查看
- **告警与故障**：告警服务、故障码解析、忽略规则配置
- **设置与安全**：本地设置持久化、密码保护、测点与通信参数配置

---

## 技术栈

| 类别     | 说明                    |
|----------|-------------------------|
| 框架     | Flutter (SDK ^3.5.4)   |
| 状态管理 | Provider                |
| 图表     | fl_chart                |
| 存储     | shared_preferences、path_provider、file_picker |
| 通信     | 自研 Modbus TCP / RS485 协议封装 |

---

## 项目结构（简要）

```
lib/
├── main.dart              # 应用入口、路由
├── models/                # 数据模型（如 node_data、ignore_rule）
├── pages/                 # 页面（首页、历史、日历史、详情、文件管理）
├── providers/             # Provider 状态（如 sensor_provider）
└── services/              # 业务服务（Modbus、RS485、告警、CSV、设置、密码等）
docs/                      # 协议与测点文档（如 rs485_message_spec.md、测点表）
assets/media/              # 图标与媒体资源
```

---

## 快速开始

### 环境要求

- Flutter SDK ^3.5.4
- Dart ^3.5.4

### 运行步骤

```bash
# 克隆仓库
git clone https://github.com/wzz123123123/cable-joint-sensor.git
cd cable-joint-sensor

# 安装依赖
flutter pub get

# 运行（按需选择平台）
flutter run          # 默认设备
flutter run -d windows
flutter run -d chrome
```

### 构建

```bash
# Windows
flutter build windows

# Android
flutter build apk
```

---

## 文档

- `docs/rs485_message_spec.md` — RS485 报文格式与测点说明  
- `docs/` 下测点表等 — 协议与测点定义

---

## 仓库与分支

- 仓库：[cable-joint-sensor](https://github.com/wzz123123123/cable-joint-sensor)
- 当前主开发分支：`1-5节点`

---

*README 由 AI 辅助生成，如有出入以项目实际代码与文档为准。*
