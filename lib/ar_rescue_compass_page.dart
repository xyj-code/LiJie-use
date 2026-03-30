import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';

import '../theme/rescue_theme.dart';

/// AR 搜救罗盘页面
///
/// 集成摄像头实时预览、传感器融合（指南针/陀螺仪）、GPS 方位角计算
/// 以及 BLE RSSI 信号强度，提供直观的 AR 战术标靶指引
class ArRescueCompassPage extends StatefulWidget {
  const ArRescueCompassPage({
    super.key,
    required this.targetLatitude,
    required this.targetLongitude,
    this.targetRssi = -70,
    this.targetName = '求救者',
  });

  /// 目标求救者纬度
  final double targetLatitude;

  /// 目标求救者经度
  final double targetLongitude;

  /// 蓝牙 RSSI 信号强度（用于估算距离）
  final int targetRssi;

  /// 目标名称
  final String targetName;

  @override
  State<ArRescueCompassPage> createState() => _ArRescueCompassPageState();
}

class _ArRescueCompassPageState extends State<ArRescueCompassPage> {
  CameraController? _cameraController;
  StreamSubscription<MagnetometerEvent>? _magnetometerSubscription;
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;

  // 当前设备朝向（方位角，单位：度）
  double _currentHeading = 0.0;

  // 目标相对于正北的方位角（单位：度）
  double _targetBearing = 0.0;

  // 视场角偏差（目标方位角 - 当前朝向）
  double _fovDelta = 0.0;

  // 估算距离（单位：米）
  double _estimatedDistance = 0.0;

  // 当前位置
  Position? _currentPosition;

  // 是否已定位
  bool _isPositioned = false;

  // 摄像头是否可用
  bool _isCameraInitialized = false;

  // 标靶是否居中（偏差角 < 5 度）
  bool _isTargetCentered = false;

  // RSSI 估算的距离准确性
  bool _isRssiAccurate = false;

  @override
  void initState() {
    super.initState();
    _checkAndRequestPermissions();
  }

  /// 检查并请求权限
  Future<void> _checkAndRequestPermissions() async {
    try {
      // 请求位置权限
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          _showPermissionDialog('位置权限', '需要位置权限来计算目标方位角。请在设置中开启位置权限。');
        }
        return;
      }

      // 检查位置服务是否启用
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          _showPermissionDialog('位置服务', '位置服务未启用。请开启位置服务以使用 AR 导航功能。');
        }
        return;
      }

      // 权限已获得，初始化所有功能
      _initializeAll();
    } catch (e) {
      debugPrint('权限检查失败：$e');
      if (mounted) {
        _showPermissionDialog('权限错误', '无法获取必要权限：$e');
      }
    }
  }

  /// 显示权限提示对话框
  void _showPermissionDialog(String title, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: RescuePalette.warning),
            const SizedBox(width: 8),
            Text(title),
          ],
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              Geolocator.openAppSettings();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: RescuePalette.accent,
            ),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  /// 初始化所有功能
  Future<void> _initializeAll() async {
    await _initializeCamera();
    _initializeSensors();
    await _calculateTargetBearing();
    _estimateDistanceFromRssi();
  }

  /// 初始化摄像头
  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final backCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();

      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
      });
    } catch (e) {
      debugPrint('摄像头初始化失败：$e');
    }
  }

  /// 初始化传感器
  void _initializeSensors() {
    // 监听指南针数据
    _magnetometerSubscription = magnetometerEventStream().listen((
      MagnetometerEvent event,
    ) {
      // 计算方位角（0-360 度）
      final heading = _calculateHeadingFromMagnetometer(event);

      if (!mounted) return;

      setState(() {
        _currentHeading = heading;
        _updateFovDelta();
        _checkTargetAlignment();
      });
    });

    // 监听加速度计数据（用于设备姿态补偿）
    _accelerometerSubscription = accelerometerEventStream().listen((
      AccelerometerEvent event,
    ) {
      // 可以在这里添加设备倾斜补偿逻辑
      // 目前简化处理，仅使用指南针数据
    });
  }

  /// 从磁力计数据计算方位角
  double _calculateHeadingFromMagnetometer(MagnetometerEvent event) {
    final x = event.x;
    final y = event.y;

    // 计算方位角（弧度）
    var heading = math.atan2(y, x);

    // 转换为角度并确保在 0-360 范围内
    var degrees = heading * (180.0 / math.pi);
    if (degrees < 0) {
      degrees += 360;
    }

    return degrees;
  }

  /// 计算目标方位角
  Future<void> _calculateTargetBearing() async {
    try {
      // 获取当前位置
      _currentPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      if (!mounted) return;

      // 计算两点之间的方位角
      _targetBearing = Geolocator.bearingBetween(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
        widget.targetLatitude,
        widget.targetLongitude,
      );

      setState(() {
        _isPositioned = true;
        _updateFovDelta();
      });
    } catch (e) {
      debugPrint('获取位置失败：$e');
      // 如果无法获取位置，使用默认值
      setState(() {
        _isPositioned = false;
      });
    }
  }

  /// 根据 RSSI 估算距离
  void _estimateDistanceFromRssi() {
    // 简化的 RSSI 到距离转换公式
    // 实际应用中需要根据环境校准（N 值、发射功率等）
    final rssi = widget.targetRssi.toDouble();
    const txPower = -59.0; // 典型发射功率（dBm）
    const n = 2.0; // 环境因子（2.0 表示开阔地带）

    // 对数距离路径损耗模型
    final ratio = (txPower - rssi) / (10 * n);
    final distance = math.pow(10, ratio).toDouble();

    setState(() {
      _estimatedDistance = distance;
    });
  }

  /// 更新视场角偏差
  void _updateFovDelta() {
    if (!_isPositioned) {
      _fovDelta = 0;
      return;
    }

    // 计算角度差（考虑 360 度循环）
    var delta = _targetBearing - _currentHeading;

    // 规范化到 [-180, 180] 范围
    while (delta > 180) {
      delta -= 360;
    }
    while (delta < -180) {
      delta += 360;
    }

    _fovDelta = delta;
  }

  /// 检查目标是否对准
  void _checkTargetAlignment() {
    final isCentered = _fovDelta.abs() < 5.0;

    if (isCentered != _isTargetCentered) {
      setState(() {
        _isTargetCentered = isCentered;
      });

      // 触发震动反馈
      if (isCentered) {
        _triggerHapticFeedback();
      }
    }
  }

  /// 触发触觉反馈
  Future<void> _triggerHapticFeedback() async {
    try {
      if (await Vibration.hasVibrator()) {
        // 短促的双脉冲震动
        await Vibration.vibrate(duration: 50, amplitude: 128);

        // 短暂延迟后第二次震动
        await Future.delayed(const Duration(milliseconds: 100));

        await Vibration.vibrate(duration: 50, amplitude: 128);
      } else {
        // 如果没有震动马达，使用系统 HapticFeedback
        await HapticFeedback.mediumImpact();
      }
    } catch (e) {
      debugPrint('震动反馈失败：$e');
    }
  }

  /// 打开地图导航
  Future<void> _openNavigation() async {
    try {
      // 构造 Google Maps 链接
      final googleMapsUrl =
          'https://www.google.com/maps/dir/?api=1&destination=${widget.targetLatitude},${widget.targetLongitude}';

      // 构造高德地图链接（中国地区）
      final gaodeMapUrl =
          'https://uri.amap.com/marker?position=${widget.targetLongitude},${widget.targetLatitude}&name=${Uri.encodeComponent(widget.targetName)}';

      // 优先使用高德地图（中国地区）
      final uri = Uri.parse(gaodeMapUrl);

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        // 降级到 Google Maps
        final fallbackUri = Uri.parse(googleMapsUrl);
        if (await canLaunchUrl(fallbackUri)) {
          await launchUrl(fallbackUri, mode: LaunchMode.externalApplication);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('无法打开地图应用，请检查是否已安装'),
                backgroundColor: RescuePalette.warning,
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('打开导航失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导航失败：${e.toString()}'),
            backgroundColor: RescuePalette.critical,
          ),
        );
      }
    }
  }

  /// 分享求救者位置
  Future<void> _shareLocation() async {
    try {
      // 构造分享文本
      final shareText =
          '🆘 SOS 求救位置\\n'
          '目标：${widget.targetName}\\n'
          '纬度：${widget.targetLatitude.toStringAsFixed(6)}\\n'
          '经度：${widget.targetLongitude.toStringAsFixed(6)}\\n'
          '距离：约${_estimatedDistance.toStringAsFixed(1)}米\\n'
          'Google Maps: https://www.google.com/maps?q=${widget.targetLatitude},${widget.targetLongitude}\\n'
          '时间：${DateTime.now().toString()}\\n'
          '\\n#RescueMesh #SOS';

      // 使用 share_plus 分享
      await Share.share(shareText, subject: 'SOS 求救位置 - ${widget.targetName}');
    } catch (e) {
      debugPrint('分享失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('分享失败：${e.toString()}'),
            backgroundColor: RescuePalette.warning,
          ),
        );
      }
    }
  }

  /// 显示分享和导航操作菜单
  void _showActionMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: RescuePalette.panel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 12),
              decoration: BoxDecoration(
                color: RescuePalette.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: RescuePalette.successSoft,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.navigation,
                  color: RescuePalette.success,
                ),
              ),
              title: const Text('地图导航'),
              subtitle: const Text('使用外部地图应用导航到目标位置'),
              onTap: () {
                Navigator.pop(context);
                _openNavigation();
              },
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: RescuePalette.accentSoft,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.share, color: RescuePalette.accent),
              ),
              title: const Text('分享位置'),
              subtitle: const Text('通过短信、微信等分享求救者位置'),
              onTap: () {
                Navigator.pop(context);
                _shareLocation();
              },
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: RescuePalette.warning.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.info_outline,
                  color: RescuePalette.warning,
                ),
              ),
              title: const Text('目标信息'),
              subtitle: const Text('查看详细的求救者信息'),
              onTap: () {
                Navigator.pop(context);
                _showTargetDetails();
              },
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  /// 显示目标详情对话框
  void _showTargetDetails() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: RescuePalette.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: RescuePalette.criticalSoft,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.sos, color: RescuePalette.critical),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(widget.targetName)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDetailRow(
                icon: Icons.my_location,
                label: '纬度',
                value: widget.targetLatitude.toStringAsFixed(6),
              ),
              _buildDetailRow(
                icon: Icons.location_on,
                label: '经度',
                value: widget.targetLongitude.toStringAsFixed(6),
              ),
              _buildDetailRow(
                icon: Icons.straighten,
                label: '估算距离',
                value: '${_estimatedDistance.toStringAsFixed(1)} 米',
              ),
              _buildDetailRow(
                icon: Icons.wifi,
                label: '信号强度',
                value: '${widget.targetRssi} dBm',
              ),
              _buildDetailRow(
                icon: Icons.access_time,
                label: '更新时间',
                value: DateTime.now().toString(),
              ),
              const Divider(height: 24),
              const Text(
                '提示：以上距离为基于信号强度的估算值，实际距离可能因环境因素有所不同。',
                style: TextStyle(
                  fontSize: 12,
                  color: RescuePalette.textMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _openNavigation();
            },
            icon: const Icon(Icons.navigation),
            label: const Text('开始导航'),
            style: ElevatedButton.styleFrom(
              backgroundColor: RescuePalette.success,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建详情行
  Widget _buildDetailRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: RescuePalette.accent),
          const SizedBox(width: 12),
          Text(
            label,
            style: const TextStyle(
              color: RescuePalette.textMuted,
              fontSize: 14,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: RescuePalette.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _magnetometerSubscription?.cancel();
    _accelerometerSubscription?.cancel();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.6),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.navigation, size: 24),
            const SizedBox(width: 8),
            Text(widget.targetName),
          ],
        ),
        actions: [
          // 更多操作按钮
          IconButton(
            icon: const Icon(Icons.menu),
            tooltip: '更多操作',
            onPressed: _showActionMenu,
          ),
          // 显示当前朝向
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: RescuePalette.accent.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${_currentHeading.toStringAsFixed(0)}°',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          // 1. 摄像头预览层
          if (_isCameraInitialized && _cameraController != null)
            Positioned.fill(child: CameraPreview(_cameraController!))
          else
            Container(
              color: Colors.black,
              child: const Center(child: CircularProgressIndicator()),
            ),

          // 2. AR 叠加层
          Positioned.fill(
            child: CustomPaint(
              painter: ArTargetPainter(
                fovDelta: _fovDelta,
                isCentered: _isTargetCentered,
                distance: _estimatedDistance,
                rssi: widget.targetRssi,
              ),
            ),
          ),

          // 3. 底部信息面板
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.9),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 距离信息
                  _buildDistanceCard(),

                  const SizedBox(height: 12),

                  // 方向指引
                  _buildDirectionIndicator(),

                  const SizedBox(height: 16),

                  // 操作按钮
                  _buildActionButtons(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建距离信息卡片
  Widget _buildDistanceCard() {
    final distanceText = _estimatedDistance > 1000
        ? '${(_estimatedDistance / 1000).toStringAsFixed(2)} km'
        : '${_estimatedDistance.toStringAsFixed(1)} m';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: RescuePalette.accent.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: RescuePalette.accent.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.straighten, color: RescuePalette.accent, size: 24),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '预估距离',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Text(
                distanceText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _getRssiColor(widget.targetRssi),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'RSSI: ${widget.targetRssi}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建方向指引指示器
  Widget _buildDirectionIndicator() {
    final directionText = _getDirectionText();
    final arrowIcon = _getDirectionArrow();

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          arrowIcon,
          color: _isTargetCentered
              ? RescuePalette.success
              : RescuePalette.warning,
          size: 32,
        ),
        const SizedBox(width: 8),
        Text(
          directionText,
          style: TextStyle(
            color: _isTargetCentered ? RescuePalette.success : Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  /// 构建操作按钮
  Widget _buildActionButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        ElevatedButton.icon(
          icon: const Icon(Icons.share),
          label: const Text('分享位置'),
          style: ElevatedButton.styleFrom(
            backgroundColor: RescuePalette.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _shareLocation,
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.navigation),
          label: const Text('导航'),
          style: ElevatedButton.styleFrom(
            backgroundColor: RescuePalette.success,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _openNavigation,
        ),
      ],
    );
  }

  /// 获取方向指引文字
  String _getDirectionText() {
    if (_isTargetCentered) {
      return '✓ 目标已锁定';
    }

    final absDelta = _fovDelta.abs();
    if (_fovDelta > 0) {
      if (absDelta < 15) {
        return '稍向右转';
      } else if (absDelta < 45) {
        return '向右转';
      } else if (absDelta < 135) {
        return '大幅向右转';
      } else {
        return '向后转';
      }
    } else {
      if (absDelta < 15) {
        return '稍向左转';
      } else if (absDelta < 45) {
        return '向左转';
      } else if (absDelta < 135) {
        return '大幅向左转';
      } else {
        return '向后转';
      }
    }
  }

  /// 获取方向箭头图标
  IconData _getDirectionArrow() {
    if (_isTargetCentered) {
      return Icons.check_circle;
    }

    if (_fovDelta > 0) {
      return Icons.arrow_forward;
    } else {
      return Icons.arrow_back;
    }
  }

  /// 根据 RSSI 获取颜色
  Color _getRssiColor(int rssi) {
    if (rssi >= -50) {
      return RescuePalette.success;
    } else if (rssi >= -70) {
      return RescuePalette.warning;
    } else {
      return RescuePalette.critical;
    }
  }
}

/// AR 标靶绘制器
///
/// 负责在摄像头画面上绘制战术光圈标靶
class ArTargetPainter extends CustomPainter {
  ArTargetPainter({
    required this.fovDelta,
    required this.isCentered,
    required this.distance,
    required this.rssi,
  });

  /// 视场角偏差（度）
  final double fovDelta;

  /// 是否已居中锁定
  final bool isCentered;

  /// 估算距离（米）
  final double distance;

  /// RSSI 信号强度
  final int rssi;

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    // 根据 FOV 偏差计算标靶的水平偏移
    // 假设手机水平视场角约为 60 度
    const horizontalFov = 60.0;
    final normalizedOffset = fovDelta / horizontalFov;
    final targetX = centerX + (normalizedOffset * size.width * 0.4);

    // 限制标靶不超出屏幕边界
    final clampedX = targetX.clamp(50.0, size.width - 50.0);

    // 根据距离和 RSSI 计算标靶大小
    const baseRadius = 40.0;
    final rssiFactor = ((rssi + 100) / 70).clamp(0.5, 1.5);
    final distanceFactor = (100 / (distance + 1)).clamp(0.3, 1.2);
    final radius = baseRadius * rssiFactor * distanceFactor;

    // 绘制标靶外圈
    final outerPaint = Paint()
      ..color = isCentered
          ? RescuePalette.accent.withValues(alpha: 0.8)
          : RescuePalette.accent.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);

    canvas.drawCircle(Offset(clampedX, centerY), radius, outerPaint);

    // 绘制标靶内圈
    final innerPaint = Paint()
      ..color = isCentered
          ? RescuePalette.success.withValues(alpha: 0.6)
          : RescuePalette.accent.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawCircle(Offset(clampedX, centerY), radius * 0.6, innerPaint);

    // 绘制中心点
    final centerPaint = Paint()
      ..color = isCentered ? RescuePalette.success : RescuePalette.accent
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(clampedX, centerY), 4, centerPaint);

    // 绘制十字准星
    final crossPaint = Paint()
      ..color = isCentered
          ? RescuePalette.success.withValues(alpha: 0.8)
          : RescuePalette.accent.withValues(alpha: 0.5)
      ..strokeWidth = 2;

    // 横线
    canvas.drawLine(
      Offset(clampedX - radius * 0.8, centerY),
      Offset(clampedX + radius * 0.8, centerY),
      crossPaint,
    );

    // 竖线
    canvas.drawLine(
      Offset(clampedX, centerY - radius * 0.8),
      Offset(clampedX, centerY + radius * 0.8),
      crossPaint,
    );

    // 绘制方位角刻度（装饰性）
    _drawAngleMarkers(canvas, size, clampedX, centerY, radius);
  }

  /// 绘制方位角刻度标记
  void _drawAngleMarkers(
    Canvas canvas,
    Size size,
    double centerX,
    double centerY,
    double radius,
  ) {
    final markerPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..strokeWidth = 1;

    // 四个方向的刻度线
    const angles = [0, 45, 90, 135, 180, 225, 270, 315];

    for (final angle in angles) {
      final radians = angle * (math.pi / 180);
      const innerRadiusMultiplier = 1.1;
      const outerRadiusMultiplier = 1.2;
      final innerRadius = radius * innerRadiusMultiplier;
      final outerRadius = radius * outerRadiusMultiplier;

      final startX = centerX + innerRadius * math.cos(radians);
      final startY = centerY + innerRadius * math.sin(radians);
      final endX = centerX + outerRadius * math.cos(radians);
      final endY = centerY + outerRadius * math.sin(radians);

      canvas.drawLine(Offset(startX, startY), Offset(endX, endY), markerPaint);
    }
  }

  @override
  bool shouldRepaint(ArTargetPainter oldDelegate) {
    return oldDelegate.fovDelta != fovDelta ||
        oldDelegate.isCentered != isCentered ||
        oldDelegate.distance != distance ||
        oldDelegate.rssi != rssi;
  }
}
