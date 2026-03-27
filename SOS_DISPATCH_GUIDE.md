# SosDispatchManager 使用指南

## 概述

`SosDispatchManager` 是一个统一的 SOS 调度中心，整合了网络请求与蓝牙广播，确保救援信号能够可靠地发送出去。

## 核心特性

### 三级调度策略

1. **探网** - 使用 `Connectivity().checkConnectivity()` 检测网络状态
2. **上云** - 网络可用时优先发送 HTTP POST 到 `/api/sos/sync`
3. **近场/兜底** - 无论网络状态如何，始终启动 BLE Mesh 广播

### 健壮性保障

- ✅ 自动捕获 `SocketException` (网络不可达)
- ✅ 自动捕获 `TimeoutException` (请求超时)
- ✅ 自动捕获 `http.ClientException` (HTTP 客户端错误)
- ✅ 网络失败时平滑降级到蓝牙广播
- ✅ 不会因网络问题导致应用崩溃

## 快速开始

### 1. 基本用法

```dart
import 'services/sos_dispatch_manager.dart';
import 'models/sos_payload.dart';
import 'models/emergency_profile.dart';

// 在任何需要的地方调用
final payload = SosPayload(
  protocolVersion: 1,
  bloodType: EmergencyProfile.current.bloodType.code,
  latitude: 39.9042,
  longitude: 116.4074,
  timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
);

final success = await SosDispatchManager.instance.triggerSos(payload);
```

### 2. 在 UI 中使用 (推荐)

```dart
class SosButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SosDispatchManager.instance,
      builder: (context, _) {
        final manager = SosDispatchManager.instance;
        
        return ElevatedButton(
          onPressed: manager.isDispatching ? null : () async {
            // 构建 SOS 数据包
            final payload = SosPayload(
              protocolVersion: 1,
              bloodType: EmergencyProfile.current.bloodType.code,
              latitude: 39.9042,
              longitude: 116.4074,
              timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            );
            
            // 触发调度
            await manager.triggerSos(payload);
            
            if (!context.mounted) return;
            
            // UI 反馈
            if (manager.lastNetworkRequestSucceeded) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('✅ SOS 已直达指挥中心！'),
                  backgroundColor: Colors.green,
                  duration: Duration(seconds: 3),
                ),
              );
            } else if (manager.lastError != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('📡 无网络信号，已启动战术蓝牙局域网广播！'),
                  backgroundColor: Colors.orange,
                  duration: Duration(seconds: 3),
                ),
              );
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: manager.isDispatching ? Colors.grey : Colors.red,
            padding: EdgeInsets.symmetric(horizontal: 40, vertical: 20),
          ),
          child: Text(
            manager.isDispatching ? '调度中...' : 'SOS 求救',
            style: TextStyle(fontSize: 18, color: Colors.white),
          ),
        );
      },
    );
  }
}
```

### 3. 监听状态变化

```dart
class SosStatusWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SosDispatchManager.instance,
      builder: (context, _) {
        final manager = SosDispatchManager.instance;
        
        return Column(
          children: [
            // 状态文本
            Text(
              manager.getStatusMessage(),
              style: TextStyle(
                fontSize: 14,
                color: manager.lastNetworkRequestSucceeded 
                    ? Colors.green 
                    : Colors.orange,
              ),
              textAlign: TextAlign.center,
            ),
            
            // 详细错误信息
            if (manager.lastError != null)
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '错误：${manager.lastError}',
                  style: TextStyle(fontSize: 12, color: Colors.red[700]),
                ),
              ),
          ],
        );
      },
    );
  }
}
```

## 集成到现有 SOS 页面

### 修改 sos_page.dart

在现有的 `sos_page.dart` 中，替换 `_triggerSos()` 方法：

```dart
Future<void> _triggerSos() async {
  if (_isLocating || SosDispatchManager.instance.isDispatching) {
    return;
  }

  setState(() {
    _isLocating = true;
    _statusText = '正在获取定位并打包 SOS 信标数据...';
  });

  try {
    // ... 获取定位的代码保持不变 ...
    final locationData = await powerSavingManager.acquireLocationFix(
      location: location,
    );
    
    // ... 保存数据库记录保持不变 ...
    await appDb.addRecord(
      SosRecordsCompanion.insert(
        latitude: latitude.toString(),
        longitude: longitude.toString(),
      ),
    );

    // 构建 SOS 负载
    final payload = SosPayload(
      protocolVersion: 1,
      bloodType: EmergencyProfile.current.bloodType.code,
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    // 使用新的调度管理器
    final success = await SosDispatchManager.instance.triggerSos(payload);
    
    if (!mounted) return;

    // 根据结果更新 UI
    final manager = SosDispatchManager.instance;
    if (manager.lastNetworkRequestSucceeded) {
      setState(() {
        _statusText = '✅ SOS 已直达指挥中心！\n纬度：$latitude\n经度：$longitude\n网络 + 蓝牙双通道发送成功。';
      });
    } else if (success) {
      setState(() {
        _statusText = '📡 无网络信号，已启动战术蓝牙局域网广播！\n纬度：$latitude\n经度：$longitude\nBLE 广播持续发射中。';
      });
    } else {
      setState(() {
        _statusText = '❌ SOS 发送失败\n${manager.lastError ?? "未知错误"}';
      });
    }
  } catch (error) {
    if (!mounted) return;
    setState(() {
      _statusText = '出现未预期错误：$error';
    });
  } finally {
    if (mounted) {
      setState(() {
        _isLocating = false;
      });
    }
  }
}
```

## API 参考

### SosDispatchManager.instance

单例模式的调度管理器实例。

#### 属性

- `bool isDispatching` - 是否正在调度中
- `bool lastNetworkRequestSucceeded` - 最后一次网络请求是否成功
- `String? lastError` - 最后一次错误信息

#### 方法

##### triggerSos(SosPayload payload)

触发 SOS 救援信号调度。

**参数:**
- `payload`: SOS 负载数据

**返回:**
- `Future<bool>`: 至少一种方式成功返回 true，否则返回 false

**调度流程:**
1. 检查网络连接状态
2. 网络可用时发送 HTTP POST 到 `/api/sos/sync`
3. 无论网络状态如何，都启动 BLE 广播

##### getStatusMessage()

获取人类可读的状态描述。

**返回:**
- `String`: 状态描述文本

##### resetError()

重置错误状态。

## 后端接口要求

### POST /api/sos/sync

**请求头:**
```
Content-Type: application/json
User-Agent: RescueMesh/1.0
```

**请求体:**
```json
{
  "protocol_version": 1,
  "blood_type": 3,
  "latitude": 39.9042,
  "longitude": 116.4074,
  "timestamp": 1679875200,
  "utc_time": "2026-03-27T12:00:00.000Z"
}
```

**响应:**
- `200 OK`: 接收成功
- 其他状态码：视为失败

## 自定义配置

### 修改后端 API 地址

编辑 `sos_dispatch_manager.dart`:

```dart
// 默认配置
static const String _baseUrl = 'http://localhost:3000';

// 生产环境
static const String _baseUrl = 'https://api.rescuemesh.com';

// 或使用环境变量
static const String _baseUrl = String.fromEnvironment('API_BASE_URL');
```

### 调整超时时间

```dart
.timeout(
  const Duration(seconds: 15), // 从 10 秒改为 15 秒
  onTimeout: () {
    throw TimeoutException('HTTP 请求超时 (15 秒)', uri);
  },
);
```

## 最佳实践

1. **全局唯一实例**: 始终使用 `SosDispatchManager.instance`，不要创建新实例
2. **UI 反馈**: 根据 `lastNetworkRequestSucceeded` 和 `lastError` 提供清晰的用户反馈
3. **防重复点击**: 检查 `isDispatching` 状态，避免用户频繁点击
4. **错误处理**: 即使调度失败也要告知用户原因
5. **日志记录**: 使用 `debugPrint` 输出调试信息，便于排查问题

## 故障排查

### 网络请求总是失败

1. 检查后端服务是否运行
2. 确认 `_baseUrl` 配置正确
3. 查看设备是否有网络权限
4. 检查防火墙/安全组设置

### BLE 广播无法启动

1. 确认已授予蓝牙权限
2. 检查设备是否支持 BLE
3. 查看 `ble_mesh_service.dart` 的实现

### 状态不更新

确保使用 `AnimatedBuilder` 或 `ListenableBuilder` 监听 `SosDispatchManager.instance` 的变化。

## 测试建议

```dart
void main() {
  test('SOS 调度 - 网络可用场景', () async {
    final payload = SosPayload(
      protocolVersion: 1,
      bloodType: 3,
      latitude: 39.9042,
      longitude: 116.4074,
      timestamp: 1679875200,
    );
    
    final success = await SosDispatchManager.instance.triggerSos(payload);
    expect(success, true);
    expect(SosDispatchManager.instance.lastNetworkRequestSucceeded, true);
  });
  
  test('SOS 调度 - 无网络降级场景', () async {
    // 模拟无网络环境
    // ...
  });
}
```
