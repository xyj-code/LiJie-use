# AR 搜救罗盘使用指南

## 概述

`ArRescueCompassPage` 是一个高级 AR 搜救罗盘页面，集成了：
- 📷 摄像头实时预览背景
- 🧭 磁力计/指南针传感器融合
- 📍 GPS 方位角计算
- 📶 BLE RSSI 信号强度测距
- 🎯 AR 战术标靶可视化
- 📳 触觉反馈（震动）

## 安装依赖

确保 `pubspec.yaml` 中包含以下依赖：

```yaml
dependencies:
  camera: ^0.11.0
  sensors_plus: ^6.1.1
  geolocator: ^13.0.2
  vibration: ^2.0.1
```

运行：
```bash
flutter pub get
```

## 平台配置

### Android

#### 1. AndroidManifest.xml 权限配置

在 `android/app/src/main/AndroidManifest.xml` 中添加以下权限（已完成）：

```xml
<!-- AR Rescue Compass Permissions -->
<uses-permission android:name="android.permission.CAMERA" />
<uses-feature android:name="android.hardware.camera" />
<uses-feature android:name="android.hardware.camera.autofocus" />
<uses-permission android:name="android.permission.VIBRATE" />

<!-- Bluetooth Permissions (已有) -->
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

<!-- Location Permissions (已有) -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

> ✅ **注意**：以上权限已在项目中配置完成，无需手动添加。

### iOS

#### 1. Info.plist 权限配置

在 `ios/Runner/Info.plist` 中添加以下权限描述（已完成）：

```xml
<!-- AR Rescue Compass Permissions -->
<key>NSCameraUsageDescription</key>
<string>需要使用摄像头进行 AR 搜救导航，在屏幕上显示实时画面以叠加救援标靶</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>需要获取您的位置来计算目标求救者的方位角和距离</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>需要获取您的位置来计算目标求救者的方位角和距离</string>
<key>NSMotionUsageDescription</key>
<string>需要访问设备运动传感器（指南针/加速度计）以提供精确的方向指引</string>
```

> ✅ **注意**：以上权限描述已在项目中配置完成，无需手动添加。

## 基本用法

### 1. 从雷达页面跳转

```dart
import 'ar_rescue_compass_page.dart';
import 'models/sos_target.dart'; // 假设的目标模型

// 在雷达页面或其他页面的按钮点击事件中
void _onTargetSelected(SosTarget target) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => ArRescueCompassPage(
        targetLatitude: target.latitude,
        targetLongitude: target.longitude,
        targetRssi: target.rssi, // 可选，默认 -70
        targetName: target.name ?? '求救者', // 可选，默认 '求救者'
      ),
    ),
  );
}
```

### 2. 从 SOS 调度管理器跳转

```dart
// 在 SOS 调度管理器中
void _navigateToArMode() {
  final target = _selectedSosTarget;
  
  Navigator.pushReplacement(
    context,
    MaterialPageRoute(
      builder: (context) => ArRescueCompassPage(
        targetLatitude: target.latitude,
        targetLongitude: target.longitude,
        targetRssi: target.lastRssi,
        targetName: 'SOS-${target.deviceId.substring(0, 6)}',
      ),
    ),
  );
}
```

### 3. 与 Mesh 状态集成（推荐）

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ar_rescue_compass_page.dart';
import 'services/mesh_state_provider.dart';

class RadarPage extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meshState = ref.watch(meshStateProvider);
    
    return ListView.builder(
      itemCount: meshState.activeDevices.length,
      itemBuilder: (context, index) {
        final device = meshState.activeDevices[index];
        
        return ListTile(
          title: Text('设备 ${device.id}'),
          subtitle: Text('RSSI: ${device.rssi}'),
          trailing: const Icon(Icons.navigation),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ArRescueCompassPage(
                  targetLatitude: device.latitude,
                  targetLongitude: device.longitude,
                  targetRssi: device.rssi,
                  targetName: '救援目标 #${index + 1}',
                ),
              ),
            );
          },
        );
      },
    );
  }
}
```

## 工作原理

### 1. 传感器融合算法

```dart
// 1. 磁力计提供原始地磁数据
final heading = atan2(magnetometer.y, magnetometer.x);

// 2. 转换为 0-360 度方位角
var degrees = heading * (180 / π);
if (degrees < 0) degrees += 360;

// 3. GPS 计算目标方位角
final targetBearing = Geolocator.bearingBetween(
  currentLat, currentLng,
  targetLat, targetLng,
);

// 4. 计算视场角偏差
final fovDelta = targetBearing - currentHeading;
```

### 2. RSSI 距离估算

使用对数距离路径损耗模型：

```dart
final txPower = -59.0; // 发射功率 (dBm)
final n = 2.0;         // 环境因子（开阔地带）
final ratio = (txPower - rssi) / (10 * n);
final distance = 10^ratio; // 单位：米
```

### 3. AR 标靶渲染

- **水平偏移**: 基于 FOV 偏差（假设水平视场角 60°）
- **标靶大小**: 基于 RSSI 强度和距离
- **颜色变化**: 居中对准时变为绿色，否则为橙色
- **震动反馈**: 偏差 < 5° 时触发双脉冲震动

## 高级功能

### 1. 自定义标靶样式

可以通过继承 `ArTargetPainter` 来自定义标靶外观：

```dart
class CustomArTargetPainter extends ArTargetPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // 自定义绘制逻辑
    // 例如：添加动画效果、改变颜色方案等
  }
}
```

### 2. 添加动画效果

```dart
// 在 ArTargetPainter 中添加动画控制器
class _ArRescueCompassPageState extends State<ArRescueCompassPage>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  
  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    )..repeat(reverse: true);
  }
  
  // 在 painter 中使用动画值
  ArTargetPainter(
    fovDelta: _fovDelta,
    pulseAnimation: _pulseController.value,
  );
}
```

### 3. 设备姿态补偿（高级）

目前实现使用了简化的 2D 指南针模型。如需更精确的 3D 姿态补偿：

```dart
// 结合加速度计和陀螺仪数据
final pitch = atan2(acc.y, sqrt(acc.x * acc.x + acc.z * acc.z));
final roll = atan2(acc.x, acc.y);

// 使用四元数或旋转矩阵进行坐标变换
// 这需要更复杂的传感器融合算法（如 Madgwick 或 Mahony 滤波器）
```

### 4. 多目标追踪

修改代码以支持同时显示多个目标：

```dart
class ArMultiTargetPage extends StatelessWidget {
  final List<TargetInfo> targets;
  
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: targets.map((target) {
        return ArTargetOverlay(
          bearing: calculateBearing(target),
          rssi: target.rssi,
        );
      }).toList(),
    );
  }
}
```

## 性能优化建议

### 1. 传感器采样率

```dart
// 使用 UI 间隔（约 60Hz）以平衡性能和精度
magnetometerEventStream(
  sensorInterval: SensorInterval.uiInterval,
);

// 如需省电，可使用游戏间隔（约 20Hz）
sensorInterval: SensorInterval.gameInterval,
```

### 2. 摄像头分辨率

```dart
// 根据设备性能选择合适的分辨率
ResolutionPreset.medium; // 720p - 推荐
ResolutionPreset.high;   // 1080p - 高质量
ResolutionPreset.ultraHigh; // 4K - 谨慎使用
```

### 3. 位置更新频率

```dart
// 仅在初始化时获取一次位置
await Geolocator.getCurrentPosition(
  desiredAccuracy: LocationAccuracy.high,
);

// 或使用持续监听（更耗电）
Geolocator.getPositionStream(
  locationSettings: LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 5, // 5 米更新一次
  ),
);
```

## 故障排查

### 问题：摄像头黑屏

**解决方案**:
1. 检查权限是否正确配置
2. 确保在真机上测试（模拟器可能不支持摄像头）
3. 添加错误处理：

```dart
try {
  await _cameraController!.initialize();
} catch (e) {
  print('摄像头初始化失败：$e');
  // 显示降级 UI（例如纯罗盘模式）
}
```

### 问题：方位角不准确

**解决方案**:
1. 校准设备磁力计（8 字校准）
2. 远离磁场干扰源（金属物体、电磁设备）
3. 添加加速度计补偿：

```dart
final accel = await accelerometer.first;
// 使用 tilt-compensated compass 算法
```

### 问题：距离估算偏差大

**解决方案**:
1. 根据实际环境校准 RSSI 参数：

```dart
// 在不同距离测量 RSSI，拟合 N 值
final n = 2.7; // 室内环境
final txPower = -65.0; // 实测发射功率
```

2. 使用多传感器融合（UWB、WiFi RTT 等）
3. 显示距离范围而非精确值（例如 "10-20 米"）

## 测试建议

### 1. 单元测试

```dart
test('计算方位角偏差', () {
  final targetBearing = 90.0; // 正东
  final currentHeading = 45.0; // 东北
  
  final delta = normalizeAngle(targetBearing - currentHeading);
  
  expect(delta, 45.0);
});

test('RSSI 距离估算', () {
  final rssi = -70;
  final distance = estimateDistance(rssi);
  
  expect(distance, inRange(5.0, 20.0)); // 应该在 5-20 米范围
});
```

### 2. 集成测试

```dart
testWidgets('AR 标靶居中时显示绿色', (tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ArRescueCompassPage(
        targetLatitude: 39.9,
        targetLongitude: 116.4,
        targetRssi: -50,
      ),
    ),
  );
  
  // 模拟设备朝向目标
  // 验证标靶颜色变为绿色
  // 验证触发震动反馈
});
```

## 最佳实践

1. **始终请求必要权限**: 在页面加载前检查并请求权限
2. **优雅降级**: 如果摄像头不可用，切换到纯罗盘模式
3. **省电模式**: 在后台时暂停传感器和摄像头
4. **用户引导**: 首次使用时显示简短教程
5. **错误处理**: 捕获所有传感器异常并提示用户

## 未来扩展

- [ ] 添加 SLAM 空间定位（ARCore/ARKit）
- [ ] 集成红外热成像（专业设备）
- [ ] 多人协同 AR 标注
- [ ] 历史轨迹回放
- [ ] 语音导航指引
- [ ] 夜间模式（夜视增强）

## 相关资源

- [Flutter Camera Plugin](https://pub.dev/packages/camera)
- [Sensors Plus Plugin](https://pub.dev/packages/sensors_plus)
- [Geolocator Plugin](https://pub.dev/packages/geolocator)
- [CustomPainter 官方文档](https://api.flutter.dev/flutter/rendering/CustomPainter-class.html)
