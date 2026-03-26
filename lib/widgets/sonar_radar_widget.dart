import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/mesh_state_provider.dart';
import '../theme/rescue_theme.dart';

/// 高性能声呐雷达组件
///
/// 特性：
/// - 使用 CustomPainter 实现 60fps 流畅动画
/// - 局部刷新，不影响父组件
/// - 根据 RSSI 信号强度绘制设备光点
/// - 淡入淡出动画过渡
class SonarRadarWidget extends ConsumerStatefulWidget {
  const SonarRadarWidget({super.key, this.size = 320});

  /// 雷达尺寸（宽高相等）
  final double size;

  @override
  ConsumerState<SonarRadarWidget> createState() => _SonarRadarWidgetState();
}

class _SonarRadarWidgetState extends ConsumerState<SonarRadarWidget>
    with TickerProviderStateMixin {
  late AnimationController _scanController;
  late Animation<double> _scanAnimation;

  // 用于跟踪已显示的设备，实现淡入动画
  final Set<String> _displayedDevices = {};
  final Map<String, AnimationController> _deviceAnimationControllers = {};
  final Map<String, Animation<double>> _deviceFadeAnimations = {};

  @override
  void initState() {
    super.initState();
    _setupScanAnimation();
  }

  void _setupScanAnimation() {
    _scanController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();

    _scanAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _scanController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _scanController.dispose();
    for (final controller in _deviceAnimationControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 为设备创建淡入动画控制器
  AnimationController _getOrCreateDeviceAnimationController(String deviceId) {
    if (!_deviceAnimationControllers.containsKey(deviceId)) {
      final controller = AnimationController(
        duration: const Duration(milliseconds: 600),
        vsync: this,
      );

      _deviceAnimationControllers[deviceId] = controller;
      _deviceFadeAnimations[deviceId] = Tween<double>(
        begin: 0,
        end: 1,
      ).animate(CurvedAnimation(parent: controller, curve: Curves.easeIn));

      controller.forward();
    }
    return _deviceAnimationControllers[deviceId]!;
  }

  /// 清理已消失的设备动画控制器
  void _cleanupDeviceAnimations(Set<String> activeDeviceIds) {
    final toRemove = <String>[];

    for (final deviceId in _deviceAnimationControllers.keys) {
      if (!activeDeviceIds.contains(deviceId)) {
        _deviceAnimationControllers[deviceId]?.dispose();
        toRemove.add(deviceId);
      }
    }

    for (final deviceId in toRemove) {
      _deviceAnimationControllers.remove(deviceId);
      _deviceFadeAnimations.remove(deviceId);
      _displayedDevices.remove(deviceId);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 监听 Mesh 状态，但只提取需要的数据
    final meshState = ref.watch(meshStateProvider);
    final devices = meshState.sortedDevices;

    // 更新设备动画
    final activeDeviceIds = devices.map((d) => d.macAddress).toSet();
    _cleanupDeviceAnimations(activeDeviceIds);

    for (final device in devices) {
      if (!_displayedDevices.contains(device.macAddress)) {
        _displayedDevices.add(device.macAddress);
      }
      _getOrCreateDeviceAnimationController(device.macAddress);
    }

    return Center(
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              const Color(0xFF0A1628),
              const Color(0xFF050B14),
              Colors.black,
            ],
            stops: const [0.0, 0.6, 1.0],
          ),
          border: Border.all(
            color: RescuePalette.accent.withValues(alpha: 0.3),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: RescuePalette.accent.withValues(alpha: 0.2),
              blurRadius: 20,
              spreadRadius: 5,
            ),
          ],
        ),
        child: ClipOval(
          child: CustomPaint(
            painter: RadarPainter(
              scanProgress: _scanAnimation.value,
              devices: devices,
              deviceFadeAnimations: _deviceFadeAnimations,
              centerX: widget.size / 2,
              centerY: widget.size / 2,
              radius: widget.size / 2 - 10,
            ),
          ),
        ),
      ),
    );
  }
}

/// 雷达绘制器
class RadarPainter extends CustomPainter {
  RadarPainter({
    required this.scanProgress,
    required this.devices,
    required this.deviceFadeAnimations,
    required this.centerX,
    required this.centerY,
    required this.radius,
  });

  final double scanProgress;
  final List<DiscoveredDevice> devices;
  final Map<String, Animation<double>> deviceFadeAnimations;
  final double centerX;
  final double centerY;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    // 绘制同心圆网格
    _drawConcentricCircles(canvas);

    // 绘制扫描线
    _drawScanLine(canvas);

    // 绘制设备光点
    _drawDeviceDots(canvas);
  }

  void _drawConcentricCircles(Canvas canvas) {
    final paint = Paint()
      ..color = RescuePalette.accent.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // 绘制 3 个同心圆
    for (int i = 1; i <= 3; i++) {
      final circleRadius = radius * i / 3;
      canvas.drawCircle(Offset(centerX, centerY), circleRadius, paint);
    }

    // 绘制十字线
    canvas.drawLine(
      Offset(centerX, centerY - radius),
      Offset(centerX, centerY + radius),
      paint,
    );
    canvas.drawLine(
      Offset(centerX - radius, centerY),
      Offset(centerX + radius, centerY),
      paint,
    );
  }

  void _drawScanLine(Canvas canvas) {
    final sweepAngle = scanProgress * 2 * math.pi;

    // 扫描渐变效果
    final gradient = SweepGradient(
      startAngle: -math.pi / 2,
      endAngle: sweepAngle - math.pi / 2,
      colors: [
        RescuePalette.success.withValues(alpha: 0),
        RescuePalette.success.withValues(alpha: 0.6),
        RescuePalette.success.withValues(alpha: 0.8),
      ],
      stops: const [0.0, 0.8, 1.0],
    );

    final paint = Paint()
      ..shader = gradient.createShader(
        Rect.fromCircle(center: Offset(centerX, centerY), radius: radius),
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);

    canvas.drawArc(
      Rect.fromCircle(center: Offset(centerX, centerY), radius: radius),
      -math.pi / 2,
      sweepAngle,
      false,
      paint,
    );
  }

  void _drawDeviceDots(Canvas canvas) {
    for (final device in devices) {
      final fadeAnimation = deviceFadeAnimations[device.macAddress];
      if (fadeAnimation == null) continue;

      final opacity = fadeAnimation.value;
      if (opacity <= 0.01) continue;

      // 根据距离计算位置
      final distance = device.estimatedDistance.clamp(0, 100);
      final normalizedDistance = distance / 100;

      // 随机角度（实际应用中可以使用方位角数据）
      final angle = _getDeviceAngle(device.macAddress);

      final dotX = centerX + normalizedDistance * radius * math.cos(angle);
      final dotY = centerY + normalizedDistance * radius * math.sin(angle);

      // 根据 RSSI 确定颜色和大小
      final rssi = device.rssi;
      final (dotColor, dotSize) = _getDotProperties(rssi, opacity);

      // 绘制光点
      final paint = Paint()
        ..color = dotColor
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4);

      canvas.drawCircle(Offset(dotX, dotY), dotSize, paint);

      // 绘制外圈光晕
      final haloPaint = Paint()
        ..color = dotColor.withValues(alpha: 0.3 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      canvas.drawCircle(Offset(dotX, dotY), dotSize * 2, haloPaint);

      // 绘制脉冲效果
      _drawPulseEffect(canvas, Offset(dotX, dotY), dotColor, opacity);
    }
  }

  (Color, double) _getDotProperties(int rssi, double opacity) {
    // RSSI 越强（越接近 0），颜色越红，点越大
    final normalizedRssi = ((rssi + 100).clamp(0, 100) / 100);

    final red = 255;
    final green = (50 * (1 - normalizedRssi)).toInt();
    final blue = (50 * (1 - normalizedRssi)).toInt();

    final baseSize = 4.0 + (normalizedRssi * 4); // 4-8px

    return (Color.fromRGBO(red, green, blue, opacity), baseSize);
  }

  void _drawPulseEffect(
    Canvas canvas,
    Offset center,
    Color color,
    double opacity,
  ) {
    final pulseProgress = (scanProgress * 2) % 1.0;
    if (pulseProgress < 0.1) return;

    final pulseRadius = 8 + (pulseProgress * 16);
    final pulseOpacity = (1 - pulseProgress) * 0.3 * opacity;

    final pulsePaint = Paint()
      ..color = color.withValues(alpha: pulseOpacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawCircle(center, pulseRadius, pulsePaint);
  }

  double _getDeviceAngle(String macAddress) {
    // 使用 MAC 地址生成确定性的伪随机角度
    final hash = macAddress.hashCode;
    return (hash % 360) * math.pi / 180;
  }

  @override
  bool shouldRepaint(covariant RadarPainter oldDelegate) {
    return scanProgress != oldDelegate.scanProgress ||
        devices != oldDelegate.devices;
  }
}

/// 简化的雷达显示组件（用于仪表盘等场景）
class MiniSonarRadarWidget extends ConsumerWidget {
  const MiniSonarRadarWidget({super.key, this.size = 160});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meshState = ref.watch(meshStateProvider);
    final activeDevices = meshState.activeDevices.length;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF0A1628),
        border: Border.all(
          color: RescuePalette.accent.withOpacity(0.3),
          width: 2,
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 同心圆
          ...List.generate(3, (index) {
            final scale = (index + 1) / 3;
            return Container(
              width: size * scale,
              height: size * scale,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: RescuePalette.accent.withValues(alpha: 0.2),
                  width: 1,
                ),
              ),
            );
          }),

          // 设备数量
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.bluetooth_searching,
                color: RescuePalette.success,
                size: 32,
              ),
              const SizedBox(height: 4),
              Text(
                '$activeDevices',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '设备',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
