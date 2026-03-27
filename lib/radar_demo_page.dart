import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ar_rescue_compass_page.dart';
import '../models/mesh_state_provider.dart';
import '../theme/rescue_theme.dart';
import '../widgets/sonar_radar_widget.dart';

/// 雷达扫描演示页面
///
/// 展示如何使用 SonarRadarWidget 和 Riverpod 状态管理
class RadarDemoPage extends ConsumerWidget {
  const RadarDemoPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meshState = ref.watch(meshStateProvider);
    final activeDevices = meshState.activeDevices;

    return Scaffold(
      backgroundColor: const Color(0xFF050B14),
      appBar: AppBar(
        title: const Text('声呐雷达扫描'),
        backgroundColor: const Color(0xFF0A1628),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          // 清除设备按钮
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: '清除所有设备',
            onPressed: () {
              ref.read(meshStateProvider.notifier).clearDevices();
            },
          ),
          // 刷新按钮
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新设备列表',
            onPressed: () {
              ref.read(meshStateProvider.notifier).removeStaleDevices(0);
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 声呐雷达
            Card(
              color: const Color(0xFF0A1628),
              elevation: 8,
              shadowColor: RescuePalette.accent.withValues(alpha: 0.3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Center(child: SonarRadarWidget(size: 320)),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _StatCard(
                          icon: Icons.bluetooth_searching,
                          label: '总设备数',
                          value: meshState.discoveredDevices.length.toString(),
                          color: RescuePalette.accent,
                        ),
                        _StatCard(
                          icon: Icons.signal_cellular_alt,
                          label: '活跃设备',
                          value: activeDevices.length.toString(),
                          color: RescuePalette.success,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // 设备列表
            Card(
              color: const Color(0xFF0A1628),
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '发现设备 (${activeDevices.length})',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (activeDevices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          '暂无设备\n周围没有检测到 SOS 信号',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 14),
                        ),
                      ),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: activeDevices.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: Colors.white12),
                      itemBuilder: (context, index) {
                        final device = activeDevices[index];
                        return _DeviceListTile(device: device);
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 32),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }
}

class _DeviceListTile extends StatelessWidget {
  const _DeviceListTile({required this.device});

  final DiscoveredDevice device;

  @override
  Widget build(BuildContext context) {
    final signalStrength = _getSignalStrength(device.rssi);
    final signalColor = _getSignalColor(device.rssi);

    return ListTile(
      onTap: () {
        // 跳转到 AR 搜救罗盘页面
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ArRescueCompassPage(
              targetLatitude: device.payload.latitude,
              targetLongitude: device.payload.longitude,
              targetRssi: device.rssi,
              targetName:
                  '设备 ${device.macAddress.substring(0, 8).toUpperCase()}',
            ),
          ),
        );
      },
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: signalColor.withValues(alpha: 0.2),
          shape: BoxShape.circle,
          border: Border.all(color: signalColor, width: 2),
        ),
        child: Icon(Icons.bluetooth_connected, color: signalColor, size: 20),
      ),
      title: Text(
        '设备 ${device.macAddress.substring(0, 8).toUpperCase()}',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            '距离：${device.estimatedDistance.toStringAsFixed(1)} 米',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 2),
          Text(
            '血型：${_getBloodTypeLabel(device.payload.bloodType)}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            signalStrength,
            style: TextStyle(
              color: signalColor,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          Text(
            '${device.rssi} dBm',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }

  String _getSignalStrength(int rssi) {
    if (rssi >= -60) return '强';
    if (rssi >= -75) return '中';
    return '弱';
  }

  Color _getSignalColor(int rssi) {
    if (rssi >= -60) return RescuePalette.success;
    if (rssi >= -75) return RescuePalette.accent;
    return RescuePalette.critical;
  }

  String _getBloodTypeLabel(int bloodTypeCode) {
    const types = ['A 型', 'B 型', 'AB 型', 'O 型', '未知'];
    if (bloodTypeCode >= 0 && bloodTypeCode < types.length) {
      return types[bloodTypeCode];
    }
    return '未知';
  }
}
