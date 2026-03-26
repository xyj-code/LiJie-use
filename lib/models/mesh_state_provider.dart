import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/sos_payload.dart';

part 'mesh_state_provider.g.dart';

/// 设备发现记录，包含 SOS 负载和元数据
@immutable
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.macAddress,
    required this.payload,
    required this.rssi,
    required this.firstDiscoveredAt,
    required this.lastUpdatedAt,
  });

  final String macAddress;
  final SosPayload payload;
  final int rssi;
  final DateTime firstDiscoveredAt;
  final DateTime lastUpdatedAt;

  /// 根据 RSSI 估算距离（米），仅供参考
  /// RSSI 越接近 0 表示信号越强，通常在 -100 到 -20 之间
  double get estimatedDistance {
    const int txPower = -59; // 假设发射功率为 -59dBm
    final rssiDouble = rssi.toDouble();

    if (rssiDouble == 0) {
      return double.infinity;
    }

    final ratio = rssiDouble / txPower;
    if (ratio < 1.0) {
      return math.pow(ratio, 10).toDouble();
    } else {
      return (0.89976 * math.pow(ratio, 7.7095) + 0.111);
    }
  }

  DiscoveredDevice copyWith({
    String? macAddress,
    SosPayload? payload,
    int? rssi,
    DateTime? firstDiscoveredAt,
    DateTime? lastUpdatedAt,
  }) {
    return DiscoveredDevice(
      macAddress: macAddress ?? this.macAddress,
      payload: payload ?? this.payload,
      rssi: rssi ?? this.rssi,
      firstDiscoveredAt: firstDiscoveredAt ?? this.firstDiscoveredAt,
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DiscoveredDevice &&
        other.macAddress == macAddress &&
        other.payload == payload &&
        other.rssi == rssi &&
        other.firstDiscoveredAt == firstDiscoveredAt &&
        other.lastUpdatedAt == lastUpdatedAt;
  }

  @override
  int get hashCode =>
      Object.hash(macAddress, payload, rssi, firstDiscoveredAt, lastUpdatedAt);
}

/// 网格网络状态
@immutable
class MeshState {
  const MeshState({
    required this.discoveredDevices,
    this.lastScanTime,
    this.isScanning = false,
  });

  final Map<String, DiscoveredDevice> discoveredDevices;
  final DateTime? lastScanTime;
  final bool isScanning;

  /// 获取按最后更新时间排序的设备列表
  List<DiscoveredDevice> get sortedDevices =>
      discoveredDevices.values.toList()
        ..sort((a, b) => b.lastUpdatedAt.compareTo(a.lastUpdatedAt));

  /// 获取最近 30 秒内活跃的设备
  List<DiscoveredDevice> get activeDevices {
    final now = DateTime.now();
    return discoveredDevices.values.where((device) {
      return now.difference(device.lastUpdatedAt).inSeconds <= 30;
    }).toList();
  }

  MeshState copyWith({
    Map<String, DiscoveredDevice>? discoveredDevices,
    DateTime? lastScanTime,
    bool? isScanning,
  }) {
    return MeshState(
      discoveredDevices: discoveredDevices ?? this.discoveredDevices,
      lastScanTime: lastScanTime ?? this.lastScanTime,
      isScanning: isScanning ?? this.isScanning,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MeshState &&
        other.discoveredDevices == discoveredDevices &&
        other.lastScanTime == lastScanTime &&
        other.isScanning == isScanning;
  }

  @override
  int get hashCode => Object.hash(discoveredDevices, lastScanTime, isScanning);
}

/// Mesh 状态通知器
@riverpod
class MeshStateNotifier extends _$MeshStateNotifier {
  @override
  MeshState build() {
    return const MeshState(discoveredDevices: {}, isScanning: false);
  }

  /// 添加或更新设备
  ///
  /// 核心优化逻辑：
  /// 1. 通过 MAC 地址去重
  /// 2. 只有当设备是新的，或者时间戳/信号强度有显著变化时才更新
  /// 3. 避免无效的频繁重绘
  void addOrUpdateDevice(String macAddress, SosPayload payload, int rssi) {
    final now = DateTime.now();
    final currentState = state;
    final existingDevice = currentState.discoveredDevices[macAddress];

    // 如果设备已存在，检查是否需要更新
    if (existingDevice != null) {
      // 只有当时间戳更新或 RSSI 变化超过阈值时才更新
      final hasNewerTimestamp =
          payload.timestamp > existingDevice.payload.timestamp;
      final hasSignificantRssiChange = (existingDevice.rssi - rssi).abs() > 5;

      if (!hasNewerTimestamp && !hasSignificantRssiChange) {
        // 无需更新，避免触发不必要的重建
        return;
      }

      // 更新现有设备
      final updatedDevice = existingDevice.copyWith(
        payload: payload,
        rssi: rssi,
        lastUpdatedAt: now,
      );

      state = currentState.copyWith(
        discoveredDevices: {
          ...currentState.discoveredDevices,
          macAddress: updatedDevice,
        },
        lastScanTime: now,
      );
    } else {
      // 添加新设备
      final newDevice = DiscoveredDevice(
        macAddress: macAddress,
        payload: payload,
        rssi: rssi,
        firstDiscoveredAt: now,
        lastUpdatedAt: now,
      );

      state = currentState.copyWith(
        discoveredDevices: {
          ...currentState.discoveredDevices,
          macAddress: newDevice,
        },
        lastScanTime: now,
      );
    }
  }

  /// 清除所有发现的设备
  void clearDevices() {
    state = state.copyWith(discoveredDevices: {}, lastScanTime: DateTime.now());
  }

  /// 设置扫描状态
  void setScanning(bool scanning) {
    state = state.copyWith(isScanning: scanning);
  }

  /// 移除过期设备（超过指定秒数未更新）
  void removeStaleDevices(int staleThresholdSeconds) {
    final now = DateTime.now();
    final activeDevices = <String, DiscoveredDevice>{};

    for (final entry in state.discoveredDevices.entries) {
      final age = now.difference(entry.value.lastUpdatedAt).inSeconds;
      if (age <= staleThresholdSeconds) {
        activeDevices[entry.key] = entry.value;
      }
    }

    if (activeDevices.length != state.discoveredDevices.length) {
      state = state.copyWith(
        discoveredDevices: activeDevices,
        lastScanTime: now,
      );
    }
  }
}
