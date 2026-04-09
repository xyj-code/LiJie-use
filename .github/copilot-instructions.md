# Rescue Mesh App - AI Assistant Instructions

离线救援通信系统 - 基于 BLE Mesh 的"数据骡子"模式，在无网络环境下实现 SOS 信号中继与同步。

## 🚀 快速命令

### Flutter 开发
```bash
flutter pub get                              # 安装依赖
dart run build_runner build                  # 生成 Drift + Riverpod 代码（修改数据库或 Provider 后必须执行）
flutter test                                 # 运行所有测试
flutter test test/<file>.dart                # 运行单个测试文件
flutter analyze                              # 代码质量检查
flutter run                                  # 在连接的设备上运行
flutter build apk --release                  # 构建发布版 APK
```

### 后端服务
```bash
cd server
npm install
npm run dev                                  # 开发模式（nodemon）
npm start                                    # 生产模式
```

### 指挥大屏
```bash
cd dashboard
npm install
npm run dev
```

> **重要：** 修改 [`lib/database.dart`](lib/database.dart) 或任何带 `@riverpod` 注解的文件后，**必须**运行 `dart run build_runner build`，否则会导致运行时错误。

---

## 🏗️ 架构概览

### BLE Mesh "数据骡子"模式
- **核心理念**：设备作为移动中继，即使无网络也通过 BLE 广播转发 SOS 信号
- **双重角色**：每个设备既广播自己的 SOS，也中继他人的消息
- **交错广播**：自有 SOS 和队列中的中继消息每 1.5 秒交替广播，平衡优先级
- **去重机制**：基于 MAC 地址过滤，30 秒窗口内防止重复处理

### 数据流
```
用户触发 SOS → 获取位置 → 编码载荷（10 字节）→ 存入 SQLite (Drift) 
→ BLE 广播启动 → 网络同步监控连通性 → 在线时 HTTP POST 到服务器 
→ MongoDB 存储 → WebSocket 推送到指挥大屏
```

### 关键组件
- **[`BleMeshService`](lib/services/ble_mesh_service.dart)**：管理 BLE 广播，通过平台通道调用原生 Android
- **[`BleScannerService`](lib/services/ble_scanner_service.dart)**：扫描附近 SOS 信标，解码载荷
- **[`NetworkSyncService`](lib/services/network_sync_service.dart)**：监控网络连接，在线时上传待处理记录
- **[`AppDatabase`](lib/database.dart)**：Drift ORM 管理本地 SQLite 持久化
- **[`SosDispatchManager`](lib/services/sos_dispatch_manager.dart)**：统一调度器，实现回退策略（云端 → BLE mesh）

---

## 📁 项目结构

```
lib/
├── main.dart                          # 应用入口
├── database.dart                      # Drift 表定义（修改后需重新生成）
├── database.g.dart                    # 自动生成（禁止手动编辑）
│
├── **页面（主屏幕）**
├── sos_page.dart                      # SOS 触发界面
├── mesh_dashboard_page.dart           # 网络可视化仪表板
├── ai_chat_page.dart                  # LLM 聊天助手
├── ar_rescue_compass_page.dart        # AR 导航叠加层
├── message_page.dart                  # 消息历史
├── profile_page.dart                  # 用户设置
├── medical_profile_page.dart          # 紧急医疗信息
├── radar_demo_page.dart               # 雷达演示/测试
│
├── **模型**
├── models/
│   ├── sos_message.dart               # 核心 SOS 数据结构
│   ├── sos_payload.dart               # 编码后的二进制载荷
│   ├── sos_advertisement_payload.dart # BLE 广播包装
│   ├── emergency_profile.dart         # 用户医疗档案
│   ├── mesh_state_provider.dart       # Riverpod mesh 状态
│   └── mesh_state_provider.g.dart     # 生成的 Provider
│
├── **服务（业务逻辑）**
├── services/
│   ├── ble_mesh_service.dart          # BLE 广播控制器
│   ├── ble_scanner_service.dart       # 信标扫描器
│   ├── ble_payload_encoder.dart       # 二进制编解码工具
│   ├── network_sync_service.dart      # 云同步服务
│   ├── sos_dispatch_manager.dart      # 统一 SOS 调度器
│   ├── background_service_manager.dart # 前台服务控制
│   ├── power_saving_manager.dart      # 电池优化
│   ├── mbtiles_reader.dart            # 离线地图瓦片读取器
│   ├── ble_mesh_exceptions.dart       # 自定义异常类型
│   └── network_sync_exceptions.dart   # 网络异常类型
│
├── **小部件（可复用组件）**
├── widgets/
│   ├── sonar_radar_widget.dart        # 60fps 动画雷达显示
│   ├── offline_tactical_map_view.dart # MBTiles 地图渲染器
│   └── ultra_power_switch_widget.dart # 省电开关
│
└── **主题**
    └── theme/
        └── rescue_theme.dart          # 全局样式
```

---

## 💡 开发约定

### 状态管理（混合模式）
本项目使用**四种不同的状态管理模式**，根据场景选择：

1. **Riverpod**（最新，推荐用于新特性）
   - 用于 mesh 状态等复杂共享状态
   - 使用 `@riverpod` 注解，生成 `.g.dart` 文件
   - 示例：[`mesh_state_provider.dart`](lib/models/mesh_state_provider.dart)

2. **ChangeNotifier**（广泛用于服务层）
   - 用于长期运行的服务类
   - 示例：[`BleMeshService`](lib/services/ble_mesh_service.dart)、[`BleScannerService`](lib/services/ble_scanner_service.dart)

3. **ValueNotifier**（简单响应式数据）
   - 用于轻量级状态，如 [`EmergencyProfile`](lib/models/emergency_profile.dart)

4. **setState**（遗留 UI 代码）
   - 旧页面中仍大量使用，逐步迁移中

> **规则**：新增功能优先使用 Riverpod；服务层保持 ChangeNotifier；避免在新代码中使用 setState。

### 二进制协议设计
SOS 载荷严格为 **10 字节**：
```
字节 0:     SOS 标志（布尔值转 uint8）
字节 1-4:   纬度（int32 微度，小端序）
字节 5-8:   经度（int32 微度，小端序）
字节 9:     血型代码（int8）
```

编码器仅产生 int32 格式，但解码器兼容 float32 格式（见测试用例）。

### 异常处理层次结构
- **BLE 相关**：[`ble_mesh_exceptions.dart`](lib/services/ble_mesh_exceptions.dart)
  - `BleMeshException`（基类）
  - `BleMeshBluetoothDisabledException`
  - `BleMeshPermissionDeniedException`
  - `BleMeshInvalidPayloadException`
  - `BleMeshPlatformException`

- **网络相关**：[`network_sync_exceptions.dart`](lib/services/network_sync_exceptions.dart)

> **规则**：始终抛出自定义异常而非通用 Exception，便于上层精确捕获和处理。

### 命名规范
- 服务类以 `*Service` 或 `*Manager` 结尾
- Provider 使用 `*Provider` 后缀，对应 `.g.dart` 生成文件
- 页面文件为 `*_page.dart`
- 模型平铺在 `models/` 目录中

---

## ⚠️ 常见陷阱与注意事项

### Android 权限复杂性
需要多层权限配置：
- **运行时权限**：`BLUETOOTH_SCAN`、`BLUETOOTH_ADVERTISE`、`ACCESS_FINE_LOCATION`
- **清单声明**：AndroidManifest.xml 中需正确配置 `usesPermissionFlags="neverForLocation"`
- **版本差异**：Android 12+ (API 31+) 与旧版本权限模型显著不同
- **前台服务**：需要 `FOREGROUND_SERVICE_CONNECTED_DEVICE` + `FOREGROUND_SERVICE_LOCATION`

详见：[`android/app/src/main/AndroidManifest.xml`](android/app/src/main/AndroidManifest.xml)

### BLE 广播限制
- 总载荷限制约 31 字节（公司 ID 占 2 字节，仅剩 10 字节用于数据）
- 低功耗模式会降低范围但节省电量
- 部分设备不支持同时扫描 + 广播
- 后台广播需要前台服务通知

### 数据库生成工作流
修改 [`database.dart`](lib/database.dart) 后**必须**执行：
```bash
dart run build_runner build
```
常见问题：忘记重新生成会导致运行时缺少表的错误。

### 坐标编码不一致
存在两种竞争格式：
- **Int32 微度**：`latitude * 1000000`（生产环境使用）
- **Float32 度**：直接浮点表示（仅在测试中出现）

解码器尝试两种格式，但编码器只产生 int32 格式。这种双支持增加了复杂度。

### 前台服务生命周期
参考 [`FOREGROUND_SERVICE_GUIDE.md`](FOREGROUND_SERVICE_GUIDE.md)：
- 必须在 UI 构建前在主隔离线程中初始化
- 后台隔离线程独立于 UI 运行
- 停止服务时必须同时取消 BLE 广播
- 通知会持续存在直到显式关闭

### 测试挑战
- BLE 操作需要物理设备（模拟器缺乏蓝牙）
- 测试广泛使用模拟数据库
- 由于硬件依赖，集成测试困难
- UI 组件测试覆盖率有限

---

## 🧪 测试模式

### 测试组织
```
test/
├── ble_scanner_service_test.dart      # 载荷解码
├── ble_payload_encoder_test.dart      # 二进制编码验证
├── database_test.dart                 # Drift CRUD 操作
├── network_sync_service_test.dart     # 同步逻辑模拟
├── sos_advertisement_payload_test.dart # 广播格式
└── widget_test.dart                   # 基础小部件冒烟测试
```

### 常用测试模式

**1. 使用内存 SQLite 进行数据库测试**
```dart
setUp(() {
  database = AppDatabase.forTesting(NativeDatabase.memory());
});

tearDown(() async {
  await database.close();
});
```

**2. 纯函数单元测试**
```dart
test('decodes float32 payload', () {
  final byteData = ByteData(10);
  byteData.setUint8(0, 1);
  byteData.setFloat32(1, 31.2304, Endian.little);
  
  final message = service.decodeSosPayload(payload, remoteId: 'device-a');
  
  expect(message.latitude, closeTo(31.2304, 0.0001));
});
```

**3. 去重验证**
```dart
test('saveIncomingSos deduplicates same sender within 5 minutes', () async {
  final firstId = await database.saveIncomingSos(first);
  final secondId = await database.saveIncomingSos(second);
  
  expect(firstId, secondId);  // 返回相同 ID
  expect(pending.length, 1);  // 仅存在一条记录
});
```

### 缺失的测试覆盖
- 无完整 BLE 流程的集成测试
- UI 组件测试有限
- 无端到端场景（触发 SOS → 中继 → 同步 → 大屏）
- 边缘情况的错误路径测试最少

---

## 🔌 离线优先架构

### SQLite 本地存储策略
使用 Drift ORM，遵循以下原则：

1. **本地写入优先**：无论是否有网络，所有 SOS 消息立即保存到 SQLite
2. **待上传队列**：标记为 `uploaded = false` 的记录单独跟踪
3. **智能去重**：同一发送者在 5 分钟窗口内更新现有记录而非创建重复项
4. **批量同步**：检测到网络时，单次 HTTP 请求上传所有待处理记录

### 云同步机制
[`NetworkSyncService`](lib/services/network_sync_service.dart) 工作流：
```
检测到连接变化 
→ 检查是否有可用网络
→ 从数据库查询待上传记录
→ 将医疗档案附加到第一条记录
→ POST 到 http://SERVER_IP:3000/api/sos/sync
→ 成功：标记记录为已上传
→ 失败：保留待处理状态，稍后重试
```

### 离线地图瓦片
MBTiles 格式存储在 `assets/maps/tactical.mbtiles`：
- 自包含的地图瓦片 SQLite 数据库
- 无需互联网即可渲染地图
- 瓦片不可用时提供降级 UI
- 详见 [`OFFLINE_MAP_QUICKSTART.md`](OFFLINE_MAP_QUICKSTART.md)

---

## 🎯 新功能开发指南

### 添加新的 Riverpod Provider
1. 在 `lib/models/` 或 `lib/services/` 中创建文件
2. 使用 `@riverpod` 注解定义 provider
3. 运行 `dart run build_runner build` 生成代码
4. 在 UI 中通过 `ref.watch(yourProvider)` 访问

### 添加新的服务（ChangeNotifier）
1. 在 `lib/services/` 中创建类，继承 `ChangeNotifier`
2. 在需要时调用 `notifyListeners()`
3. 在页面中使用 `context.read<YourService>()` 或 Provider 注入

### 修改数据库 Schema
1. 编辑 [`lib/database.dart`](lib/database.dart) 中的表定义
2. 运行 `dart run build_runner build`
3. 如有必要，编写迁移脚本（当前项目未实现自动迁移）
4. 更新相关测试

### 添加 BLE 功能
1. 优先考虑功耗影响
2. 确保正确处理权限请求
3. 添加适当的异常处理（使用自定义异常）
4. 在物理设备上测试（模拟器不支持 BLE）

### 添加 UI 组件
1. 优先使用 Riverpod 而非 setState
2. 对于复杂动画，考虑 CustomPainter
3. 确保在小屏幕上响应式布局
4. 遵循 [`rescue_theme.dart`](lib/theme/rescue_theme.dart) 中的设计规范

---

## 📚 相关文档

- **[开发者指南](DEVELOPER_GUIDE.md)** - 详细架构说明、联调步骤、优化任务
- **[前台服务配置](FOREGROUND_SERVICE_GUIDE.md)** - Android 后台运行配置
- **[AR 救援罗盘指南](AR_RESCUE_COMPASS_GUIDE.md)** - AR 功能详细说明
- **[BLE 中继队列指南](BLE_RELAY_QUEUE_GUIDE.md)** - 中继机制详解
- **[离线地图快速入门](OFFLINE_MAP_QUICKSTART.md)** - MBTiles 配置步骤
- **[SOS 调度指南](SOS_DISPATCH_GUIDE.md)** - 统一调度器工作原理
- **[用户数据持久化指南](USER_DATA_PERSISTENCE_GUIDE.md)** - 本地数据存储策略

---

## 🔍 调试技巧

### BLE 调试
```dart
// 启用详细日志
FlutterBluePlus.setLogLevel(LogLevel.verbose);

// 查看扫描结果
print('Found device: ${device.name} (${device.remoteId}), RSSI: ${rssi}');
```

### 数据库调试
```dart
// 查询所有待上传记录
final pending = await database.select(database.sosMessages)
  .where((tbl) => tbl.uploaded.equals(false))
  .get();
print('Pending uploads: ${pending.length}');
```

### 网络同步调试
```dart
// 监听连接状态
connectivity.onConnectivityChanged.listen((result) {
  print('Connectivity changed: $result');
});
```

---

## 🛠️ 环境变量配置

服务器 IP 需要在多个位置配置：
- [`lib/services/network_sync_service.dart`](lib/services/network_sync_service.dart) 第 32 行
- [`server/.env`](server/.env) 文件（如果存在）

确保移动端和后端使用相同的 IP 地址进行通信。

---

## ✨ 最佳实践总结

1. **始终先搜索现有代码**：避免重复实现已有功能
2. **遵循链接原则**：引用现有文档而非复制内容
3. **优先使用 Riverpod**：新状态管理代码首选 Riverpod
4. **处理边界情况**：特别是 BLE 权限、网络断开、低电量场景
5. **保持向后兼容**：修改协议时需考虑旧版本设备
6. **测试物理设备**：BLE 功能无法在模拟器中测试
7. **关注功耗**：救援应用可能长时间运行，优化电池使用
8. **文档变更**：修改核心逻辑时更新相关指南文档
