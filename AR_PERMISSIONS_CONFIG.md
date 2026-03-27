# AR 搜救罗盘权限配置完成报告

## ✅ 已完成的权限配置

### Android 平台

已在 `android/app/src/main/AndroidManifest.xml` 中配置以下权限：

#### 1. AR 核心权限（新增）
```xml
<!-- AR Rescue Compass Permissions -->
<uses-permission android:name="android.permission.CAMERA" />
<uses-feature android:name="android.hardware.camera" />
<uses-feature android:name="android.hardware.camera.autofocus" />
<uses-permission android:name="android.permission.VIBRATE" />
```

#### 2. 蓝牙权限（已有）
```xml
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

#### 3. 位置权限（已有）
```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

#### 4. 其他必要权限（已有）
- `WAKE_LOCK` - 保持设备唤醒
- `FOREGROUND_SERVICE` - 前台服务
- `POST_NOTIFICATIONS` - 通知权限（Android 14+）
- `VIBRATE` - 震动反馈

---

### iOS 平台

已在 `ios/Runner/Info.plist` 中配置以下权限描述：

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

---

## 🔧 运行时权限处理

### 自动权限请求

在 [`ArRescueCompassPage`](lib/ar_rescue_compass_page.dart) 中已实现自动权限请求逻辑：

```dart
@override
void initState() {
  super.initState();
  _requestPermissions(); // 自动请求位置权限
  _initializeCamera();   // 初始化摄像头
  _initializeSensors();  // 初始化传感器
  // ...
}
```

### 权限请求流程

1. **首次启动时**：系统会自动弹出权限请求对话框
2. **位置权限**：使用 `geolocator` 自动请求
3. **摄像头权限**：由 `camera` 插件自动处理
4. **传感器权限**：iOS 需要 `NSMotionUsageDescription`，Android 默认允许

---

## 📋 权限用途说明

| 权限 | 平台 | 用途 | 必需性 |
|------|------|------|--------|
| **CAMERA** | Android/iOS | 摄像头实时预览作为 AR 背景 | ✅ 必需 |
| **ACCESS_FINE_LOCATION** | Android/iOS | 计算当前位置到目标的方位角 | ✅ 必需 |
| **ACCESS_COARSE_LOCATION** | Android | 粗略位置辅助定位 | ✅ 必需 |
| **VIBRATE** | Android/iOS | 目标对准时的触觉反馈 | ⚠️ 推荐 |
| **NSMotionUsageDescription** | iOS | 访问指南针/加速度计 | ✅ 必需 |
| **BLUETOOTH** | Android/iOS | 接收求救者 BLE 信号 | ✅ 必需 |

---

## 🧪 测试建议

### Android 测试步骤

1. 确保设备具有 GPS 和磁力计传感器
2. 首次运行时会弹出权限请求对话框
3. 授予所有权限以确保 AR 功能正常
4. 测试不同光线条件下的摄像头预览效果

### iOS 测试步骤

1. 在真机上测试（模拟器无磁力计）
2. 首次启动时授予位置权限（选择"使用 App 期间"）
3. 确保设备支持 ARKit（iPhone 6s 及以上）
4. 测试设备运动传感器的响应速度

---

## ⚠️ 常见问题排查

### 1. 摄像头黑屏
- 检查是否授予相机权限
- 确认设备摄像头未被其他应用占用
- 尝试重启应用

### 2. 方位角不准确
- 确保位置服务已启用
- 在开阔地带进行 8 字形校准
- 远离强磁场干扰源

### 3. 距离估算偏差大
- RSSI 受环境影响较大，需现场校准
- 调整 `txPower` 参数（默认 -59 dBm）
- 考虑使用多传感器融合算法

---

## 📱 设备兼容性

### 最低系统要求
- **Android**: API 24+ (Android 7.0)
- **iOS**: iOS 12.0+

### 硬件要求
- 后置摄像头
- GPS 模块
- 磁力计（电子罗盘）
- 加速度计/陀螺仪

---

## 🛡️ 隐私保护建议

1. **最小权限原则**：仅在需要时请求权限
2. **透明说明**：清晰告知用户权限用途
3. **本地处理**：所有传感器数据均在设备本地处理
4. **不存储敏感信息**：不保存用户位置历史

---

## ✅ 验证清单

- [x] AndroidManifest.xml 权限已添加
- [x] Info.plist 权限描述已添加
- [x] 运行时权限请求逻辑已实现
- [x] 代码通过 `flutter analyze` 检查
- [x] 依赖包版本兼容
- [x] 文档已更新

---

**配置完成时间**: 2026 年 3 月 27 日  
**版本**: v1.0.0  
**状态**: ✅ 生产就绪
