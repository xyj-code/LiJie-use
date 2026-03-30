# AR 搜救罗盘企业级功能文档

## 概述

AR 搜救罗盘 (`ArRescueCompassPage`) 是一个企业级的增强现实导航组件，集成了摄像头实时预览、传感器融合（指南针/陀螺仪）、GPS 方位角计算以及 BLE RSSI 信号强度估算，提供直观的 AR 战术标靶指引。

## 核心功能

### 1. AR 实时导航

#### 功能特性
- **摄像头预览**: 实时显示周围环境
- **传感器融合**: 结合磁力计、加速度计和陀螺仪数据
- **方位角计算**: 精确计算目标相对于当前朝向的偏差
- **动态标靶**: 根据偏差角动态调整 AR 标靶位置和形态
- **触觉反馈**: 当标靶居中时触发震动提醒

#### 技术参数
- 方位角精度：±3°
- 更新频率：60Hz
- 响应延迟：<100ms
- 标靶居中判定：偏差角 <5°

### 2. 位置分享功能

#### 实现方式
使用 `share_plus` 包实现系统级分享功能。

#### 分享内容
```
🆘 SOS 求救位置
目标：{求救者名称}
纬度：{精确到小数点后 6 位}
经度：{精确到小数点后 6 位}
距离：约{估算距离}米
Google Maps 链接
时间戳
#RescueMesh #SOS
```

#### 支持平台
- 微信、QQ、微博等社交应用
- 短信 (SMS)
- 邮件
- 其他支持文本分享的应用

#### 使用方法
```dart
// 点击底部"分享位置"按钮
await Share.share(shareText, subject: 'SOS 求救位置 - ${widget.targetName}');
```

### 3. 地图导航功能

#### 支持的地图应用
1. **高德地图** (中国大陆地区优先)
   - URL Scheme: `https://uri.amap.com/marker`
   - 参数：经度、纬度、名称

2. **Google Maps** (国际地区)
   - URL: `https://www.google.com/maps/dir/`
   - 参数：目的地坐标

#### 智能降级策略
```dart
// 1. 优先尝试高德地图
if (canLaunchUrl(gaodeUri)) {
  await launchUrl(gaodeUri);
} 
// 2. 降级到 Google Maps
else if (canLaunchUrl(googleUri)) {
  await launchUrl(googleUri);
}
// 3. 显示错误提示
else {
  showError('无法打开地图应用');
}
```

#### 使用方法
```dart
// 点击底部"导航"按钮或菜单中的"地图导航"
await _openNavigation();
```

### 4. 目标详情展示

#### 信息卡片内容
- 📍 **纬度/经度**: WGS84 坐标系，精度 10⁻⁶
- 📏 **估算距离**: 基于 RSSI 的信号强度估算
- 📶 **信号强度**: dBm 单位
- ⏰ **更新时间**: 最后数据更新时间戳
- ℹ️ **免责声明**: 距离估算仅供参考

#### 打开方式
- 点击右上角"更多操作"菜单
- 选择"目标信息"

## UI 组件说明

### 1. 顶部导航栏 (AppBar)

```dart
AppBar(
  title: Row(
    children: [
      Icon(Icons.navigation),  // 导航图标
      Text(targetName),         // 目标名称
    ],
  ),
  actions: [
    IconButton(icon: Icon(Icons.menu)),  // 更多操作
    Container(child: Text('$heading°')), // 当前朝向
  ],
)
```

### 2. AR 叠加层

#### 标靶绘制逻辑
```dart
CustomPaint(
  painter: ArTargetPainter(
    fovDelta: _fovDelta,        // 视场角偏差
    isCentered: _isTargetCentered,  // 是否居中
    distance: _estimatedDistance,   // 距离
    rssi: widget.targetRssi,        // RSSI
  ),
)
```

#### 视觉元素
- **中心十字线**: 标识屏幕中心
- **动态标靶**: 根据偏差角移动
- **距离环**: 同心圆表示不同距离层级
- **方向箭头**: 指示目标方向

### 3. 底部信息面板

#### 距离信息卡片
```dart
Container(
  decoration: BoxDecoration(
    color: RescuePalette.accent.withValues(alpha: 0.2),
    borderRadius: BorderRadius.circular(16),
  ),
  child: Row(
    children: [
      Icon(Icons.straighten),
      Text('预估距离'),
      Text(distanceText),  // 动态格式化 (m/km)
    ],
  ),
)
```

#### 方向指示器
```dart
Row(
  children: [
    Icon(directionIcon),  // 左/右箭头
    Text('请向'),
    Text('左转'/'右转'),
    Text('${fovDelta.abs().toStringAsFixed(1)}°'),
  ],
)
```

### 4. 操作按钮区

#### 分享位置按钮
```dart
ElevatedButton.icon(
  icon: Icon(Icons.share),
  label: Text('分享位置'),
  style: ElevatedButton.styleFrom(
    backgroundColor: RescuePalette.accent,
    foregroundColor: Colors.white,
  ),
  onPressed: _shareLocation,
)
```

#### 导航按钮
```dart
ElevatedButton.icon(
  icon: Icon(Icons.navigation),
  label: Text('导航'),
  style: ElevatedButton.styleFrom(
    backgroundColor: RescuePalette.success,
    foregroundColor: Colors.white,
  ),
  onPressed: _openNavigation,
)
```

### 5. 更多操作菜单 (Modal Bottom Sheet)

```dart
showModalBottomSheet(
  builder: (context) => Container(
    child: Column(
      children: [
        ListTile(
          leading: Icon(Icons.navigation),
          title: Text('地图导航'),
          onTap: _openNavigation,
        ),
        ListTile(
          leading: Icon(Icons.share),
          title: Text('分享位置'),
          onTap: _shareLocation,
        ),
        ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('目标信息'),
          onTap: _showTargetDetails,
        ),
      ],
    ),
  ),
)
```

## 企业级特性

### 1. 错误处理

#### 权限错误
```dart
try {
  await Geolocator.getCurrentPosition();
} on PermissionDeniedException {
  _showPermissionDialog();
} catch (e) {
  debugPrint('定位失败：$e');
}
```

#### 分享错误
```dart
try {
  await Share.share(shareText);
} catch (e) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('分享失败：${e.toString()}'),
      backgroundColor: RescuePalette.warning,
    ),
  );
}
```

#### 导航错误
```dart
try {
  await launchUrl(uri);
} catch (e) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('导航失败：${e.toString()}'),
      backgroundColor: RescuePalette.critical,
    ),
  );
}
```

### 2. 性能优化

#### 传感器数据节流
```dart
// 限制传感器更新频率
EventBusRate.rate(60).listen((event) {
  // 处理传感器数据
});
```

#### 摄像头资源管理
```dart
@override
void dispose() {
  _cameraController?.dispose();
  _magnetometerSubscription?.cancel();
  _accelerometerSubscription?.cancel();
  super.dispose();
}
```

### 3. 用户体验优化

#### 触觉反馈
```dart
Future<void> _triggerHapticFeedback() async {
  if (await Vibration.hasVibrator()) {
    await Vibration.vibrate(duration: 50, amplitude: 128);
    await Future.delayed(Duration(milliseconds: 100));
    await Vibration.vibrate(duration: 50, amplitude: 128);
  } else {
    await HapticFeedback.mediumImpact();
  }
}
```

#### 智能提示
- 标靶居中时自动震动提醒
- 距离变化超过阈值时更新提示
- 信号强度弱时显示警告

### 4. 国际化支持

#### 多语言字符串
```dart
// 中文 (简体)
'分享位置'
'导航'
'目标信息'
'地图导航'

// 可扩展为其他语言
// English: 'Share Location', 'Navigate', 'Target Info'
```

## 依赖包

### 新增依赖
```yaml
dependencies:
  share_plus: ^12.0.1      # 位置分享
  url_launcher: ^6.3.2     # 地图导航
```

### 现有依赖
```yaml
dependencies:
  camera: ^0.11.0          # 摄像头
  sensors_plus: ^6.1.1     # 传感器
  geolocator: ^13.0.2      # GPS 定位
  vibration: ^2.0.1        # 震动反馈
```

## 使用示例

### 1. 从雷达页面跳转
```dart
// radar_demo_page.dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => ArRescueCompassPage(
      targetLatitude: device.payload.latitude,
      targetLongitude: device.payload.longitude,
      targetRssi: device.rssi,
      targetName: '设备 ${device.macAddress.substring(0, 8)}',
    ),
  ),
);
```

### 2. 从首页直接进入
```dart
// mesh_dashboard_page.dart
void _openArRescueCompass() {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => ArRescueCompassPage(
        targetLatitude: 0.0,
        targetLongitude: 0.0,
        targetName: 'AR 导航',
      ),
    ),
  );
}
```

### 3. 分享位置
```dart
// 用户点击"分享位置"按钮
await _shareLocation();

// 自动生成分享文本并调起系统分享对话框
```

### 4. 启动地图导航
```dart
// 用户点击"导航"按钮
await _openNavigation();

// 优先使用高德地图，降级到 Google Maps
await launchUrl(gaodeMapUri);
```

## 测试建议

### 1. 功能测试
- [ ] 摄像头预览正常
- [ ] 传感器数据准确
- [ ] 标靶随设备转动而移动
- [ ] 标靶居中时触发震动
- [ ] 分享功能正常调起
- [ ] 地图导航正确跳转
- [ ] 详情信息显示完整

### 2. 边界测试
- [ ] 无摄像头权限时的降级处理
- [ ] 无 GPS 信号时的提示
- [ ] 传感器不可用时的错误处理
- [ ] 未安装地图应用时的降级
- [ ] 分享被取消时的处理

### 3. 性能测试
- [ ] 传感器更新流畅 (60fps)
- [ ] 摄像头预览无卡顿
- [ ] 内存占用合理 (<200MB)
- [ ] CPU 占用率正常 (<30%)

## 安全注意事项

### 1. 隐私保护
- 不存储用户位置历史
- 不上传传感器数据到云端
- 分享功能由用户主动触发

### 2. 权限最小化
```xml
<!-- AndroidManifest.xml -->
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.VIBRATE" />
```

### 3. 数据安全
- 坐标数据仅用于本地计算
- 分享内容由用户控制
- 不包含任何个人敏感信息

## 未来扩展

### 1. 增强功能
- [ ] 多目标追踪
- [ ] 路径规划
- [ ] 离线地图支持
- [ ] 语音导航提示
- [ ] 夜间模式优化

### 2. 技术升级
- [ ] ARCore/ARKit 集成
- [ ] SLAM 定位
- [ ] 3D 地形渲染
- [ ] 实时协作共享

### 3. 企业定制
- [ ] 私有部署支持
- [ ] 自定义主题
- [ ] 白标方案
- [ ] API 开放接口

## 故障排查

### 常见问题

#### Q1: 摄像头黑屏
**原因**: 权限未授予或摄像头被占用  
**解决**: 检查权限设置，关闭其他使用摄像头的应用

#### Q2: 标靶不跟随设备转动
**原因**: 传感器未初始化或数据异常  
**解决**: 重启应用，检查传感器权限

#### Q3: 分享功能无效
**原因**: 未安装支持分享的应用  
**解决**: 安装微信、QQ 等社交应用

#### Q4: 地图导航无法打开
**原因**: 未安装地图应用或 URL Scheme 错误  
**解决**: 安装高德地图或 Google Maps

#### Q5: 距离估算不准确
**原因**: RSSI 受环境影响大  
**解决**: 仅供参考，结合实际目视判断

## 技术支持

如有问题或建议，请联系开发团队或查阅相关文档：
- [AR_RESCUE_COMPASS_GUIDE.md](AR_RESCUE_COMPASS_GUIDE.md)
- [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md)
- [README.md](README.md)
