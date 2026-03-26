# Rescue Mesh App

离线救援通信系统 - 基于 BLE Mesh 的"数据骡子"模式，在无网络环境下实现 SOS 信号中继与同步。

## 🚀 核心特性

- **BLE Mesh 自组网**: 设备间自动中继 SOS 广播，形成去中心化救援网络
- **声呐雷达可视化**: 基于 Riverpod 的高性能 60fps 雷达动画，实时显示周围求救设备
- **数据骡子模式**: 高频接收周围 BLE SOS 广播包，智能去重与缓存
- **离线优先架构**: 本地 SQLite 存储，网络恢复后自动同步至云端
- **极致省电优化**: 动态调整扫描频率与广播间隔，支持后台运行

## 📦 技术栈

**移动端 (Flutter)**
- Riverpod 状态管理
- BLE (flutter_blue_plus)
- SQLite (drift)
- 本地 AI 推理 (llama_cpp_dart / fcllama)
- 高性能 CustomPainter 动画

**后端**
- Node.js + Express
- MongoDB (GeoJSON 空间索引)
- Socket.IO 实时推送

**指挥大屏**
- Vue 3 + Vite
- ECharts 数据可视化
- Leaflet 地图

## 🎯 快速开始

### 1. 安装依赖

```bash
flutter pub get
```

### 2. 运行应用

```bash
# 查看所有可用设备
flutter devices

# 运行到 Android 设备
flutter run -d <device_id>

# 运行雷达演示页面
flutter run --target=lib/radar_demo_page.dart
```

> **Android 权限提示：** 首次运行需在手机上允许蓝牙、定位权限。部分 Android 12+ 设备需要同时开启"附近设备"权限。

### 3. 启动后端服务（可选）

```bash
cd server
npm install
node src/index.js
```

### 4. 打开指挥大屏（可选）

```bash
cd dashboard
npm install
npm run dev
```

## 📚 文档

- [开发者指南](DEVELOPER_GUIDE.md) - 详细架构说明、联调步骤、优化任务
- [前台服务配置](FOREGROUND_SERVICE_GUIDE.md) - Android 后台运行配置

## 🎨 Riverpod 状态管理与雷达组件

本项目采用 Riverpod 进行全局状态管理，实现高性能声呐雷达可视化：

**核心文件：**
- [`lib/models/mesh_state_provider.dart`](lib/models/mesh_state_provider.dart) - 状态定义与去重逻辑
- [`lib/widgets/sonar_radar_widget.dart`](lib/widgets/sonar_radar_widget.dart) - 60fps 雷达动画组件
- [`lib/radar_demo_page.dart`](lib/radar_demo_page.dart) - 完整使用示例

**主要特性：**
- 基于 MAC 地址的智能去重
- RSSI 信号强度估算距离
- 淡入淡出动画过渡
- 脉冲呼吸灯效果
- 自动清理过期设备

详见 [开发者指南](DEVELOPER_GUIDE.md#-riverpod-状态管理与声呐雷达)。

## 🗺️ 架构概览

```
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│  求救设备 A  │ ───► │  数据骡子 B  │ ◄─── │  求救设备 C  │
│  (BLE 广播)  │      │ (中继 + 缓存) │      │  (BLE 广播)  │
└─────────────┘      └──────┬───────┘      └─────────────┘
                             │
                             ▼ (网络恢复时)
                      ┌──────────────┐
                      │   云端后端   │
                      │ (MongoDB)    │
                      └──────┬───────┘
                             │
                             ▼ (Socket.IO 推送)
                      ┌──────────────┐
                      │  指挥大屏    │
                      │ (Vue + Map)  │
                      └──────────────┘
```

## 🔧 开发规范

详见 [开发者指南](DEVELOPER_GUIDE.md#-开发规范速记)。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本项目仅供学习与技术交流使用。
