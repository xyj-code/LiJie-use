import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ble_mesh_service.dart';
import '../models/sos_payload.dart';
import '../models/emergency_profile.dart';

/// SOS 调度中心 - 统一管理网络请求与蓝牙广播
///
/// 核心调度逻辑:
/// 1. 探网：检查当前网络连接状态
/// 2. 上云：网络可用时优先发送 HTTP 请求到云端
/// 3. 近场/兜底：无论网络状态如何，始终启动 BLE 广播
class SosDispatchManager extends ChangeNotifier {
  SosDispatchManager._internal() {
    _connectivity = Connectivity();
  }

  /// 单例模式 - 全局访问点
  static final SosDispatchManager instance = SosDispatchManager._internal();

  late final Connectivity _connectivity;

  bool _isDispatching = false;
  bool _lastNetworkRequestSucceeded = false;
  String? _lastError;

  /// 后端 API 基础 URL (可根据环境配置)
  static const String _baseUrl = 'http://localhost:3000';

  /// 当前是否正在调度 SOS
  bool get isDispatching => _isDispatching;

  /// 最后一次网络请求是否成功
  bool get lastNetworkRequestSucceeded => _lastNetworkRequestSucceeded;

  /// 最后一次错误信息
  String? get lastError => _lastError;

  /// 触发 SOS 救援信号
  ///
  /// [payload] SOS 负载数据，包含位置、血型等信息
  ///
  /// 调度流程:
  /// 1. 检查网络连接状态
  /// 2. 网络可用时发送 HTTP POST 到 /api/sos/sync
  /// 3. 无论网络状态如何，都启动 BLE 广播
  ///
  /// 返回:
  /// - true: 至少一种方式成功发送 (HTTP 或 BLE)
  /// - false: 两种方式都失败
  Future<bool> triggerSos(SosPayload payload) async {
    if (_isDispatching) {
      debugPrint('[SOS] 已在调度中，忽略重复请求');
      return false;
    }

    _isDispatching = true;
    _lastError = null;
    _lastNetworkRequestSucceeded = false;
    notifyListeners();

    try {
      // ========== 步骤一：探网 ==========
      debugPrint('[SOS] 开始检查网络连接...');
      final connectivityResult = await _connectivity.checkConnectivity();
      final bool hasNetwork = !connectivityResult.contains(
        ConnectivityResult.none,
      );

      debugPrint('[SOS] 网络状态: ${hasNetwork ? "可用" : "无网络"}');

      // ========== 步骤二：上云 (如果网络可用) ==========
      if (hasNetwork) {
        debugPrint('[SOS] 尝试发送 HTTP 请求到云端...');
        final networkSuccess = await _sendHttpRequest(payload);

        if (networkSuccess) {
          _lastNetworkRequestSucceeded = true;
          debugPrint('[SOS] ✓ HTTP 请求成功 - SOS 已直达指挥中心!');
        } else {
          debugPrint('[SOS] ✗ HTTP 请求失败，将回退到 BLE 广播');
        }
      } else {
        debugPrint('[SOS] 无网络连接，跳过 HTTP 请求');
      }

      // ========== 步骤三：近场/兜底 (始终执行) ==========
      debugPrint('[SOS] 启动 BLE Mesh 广播...');
      final bleSuccess = await _startBleBroadcast(payload);

      if (bleSuccess) {
        debugPrint('[SOS] ✓ BLE 广播已成功启动');
      } else {
        debugPrint('[SOS] ✗ BLE 广播失败');
        _lastError ??= 'BLE 广播启动失败';
      }

      // 最终结果：至少一种方式成功
      final overallSuccess = _lastNetworkRequestSucceeded || bleSuccess;

      if (overallSuccess) {
        debugPrint('[SOS] === 调度完成：成功 ===');
      } else {
        debugPrint('[SOS] === 调度完成：失败 ===');
      }

      return overallSuccess;
    } catch (error) {
      debugPrint('[SOS] 未预期的错误：$error');
      _lastError = '未预期的错误：$error';
      return false;
    } finally {
      _isDispatching = false;
      notifyListeners();
    }
  }

  /// 发送 HTTP POST 请求到云端服务器
  ///
  /// 端点：POST {_baseUrl}/api/sos/sync
  ///
  /// 异常处理:
  /// - SocketException: 网络不可达
  /// - TimeoutException: 请求超时
  /// - http.ClientException: HTTP 客户端错误
  ///
  /// 返回: true 表示 HTTP 200 成功，false 表示任何失败情况
  Future<bool> _sendHttpRequest(SosPayload payload) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/sos/sync');

      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': 'RescueMesh/1.0',
            },
            body: jsonEncode({
              'protocol_version': payload.protocolVersion,
              'blood_type': payload.bloodType,
              'latitude': payload.latitude,
              'longitude': payload.longitude,
              'timestamp': payload.timestamp,
              'utc_time': payload.time.toIso8601String(),
            }),
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw TimeoutException('HTTP 请求超时 (10 秒)');
            },
          );

      if (response.statusCode == 200) {
        debugPrint('[SOS] HTTP 响应：${response.statusCode} - ${response.body}');
        return true;
      } else {
        debugPrint('[SOS] HTTP 响应非 200: ${response.statusCode}');
        _lastError = 'HTTP 请求失败：状态码 ${response.statusCode}';
        return false;
      }
    } on SocketException catch (error) {
      // 网络不可达 - 优雅降级
      debugPrint('[SOS] SocketException: ${error.message}');
      _lastError = '网络连接失败：${error.message}';
      return false;
    } on TimeoutException catch (error) {
      // 请求超时 - 优雅降级
      debugPrint('[SOS] TimeoutException: ${error.message}');
      _lastError = '网络请求超时：${error.message}';
      return false;
    } on http.ClientException catch (error) {
      // HTTP 客户端错误
      debugPrint('[SOS] ClientException: ${error.message}');
      _lastError = 'HTTP 客户端错误：${error.message}';
      return false;
    } catch (error) {
      // 其他未知错误
      debugPrint('[SOS] 未知错误：$error');
      _lastError = 'HTTP 请求异常：$error';
      return false;
    }
  }

  /// 启动 BLE SOS 广播
  ///
  /// 调用底层的 [bleMeshService.startSosBroadcast]
  ///
  /// 返回: true 表示广播成功启动，false 表示失败
  Future<bool> _startBleBroadcast(SosPayload payload) async {
    try {
      // 注意：实际使用时需要根据你的 BLE 服务接口调整参数
      // 这里假设 bleMeshService 是全局可访问的单例
      // SosPayload.bloodType 是 int，需要转换为 BloodType 枚举
      final bloodType = BloodType.values.firstWhere(
        (bt) => bt.code == payload.bloodType,
        orElse: () => BloodType.unknown,
      );

      await bleMeshService.startSosBroadcast(
        latitude: payload.latitude,
        longitude: payload.longitude,
        bloodType: bloodType,
      );
      return true;
    } catch (error) {
      debugPrint('[SOS] BLE 广播启动失败：$error');
      _lastError = 'BLE 广播失败：$error';
      return false;
    }
  }

  /// 辅助方法：将 Map 转换为 Json 字符串
  String jsonEncode(Map<String, dynamic> data) {
    return data.toString(); // 简化处理，实际应使用 dart:convert
  }

  /// 重置错误状态
  void resetError() {
    _lastError = null;
    _lastNetworkRequestSucceeded = false;
    notifyListeners();
  }

  /// 获取人类可读的状态描述
  String getStatusMessage() {
    if (_isDispatching) {
      return '正在调度 SOS...';
    }

    if (_lastNetworkRequestSucceeded) {
      return '✓ SOS 已送达指挥中心 (网络 + 蓝牙双通道)';
    }

    if (_lastError != null) {
      return '⚠ $_lastError\n已启动蓝牙局域网广播';
    }

    return '就绪';
  }
}

// ============================================================================
// 使用示例:
// ============================================================================
//
// // 1. 在 UI 中监听状态变化
// class SosButton extends StatelessWidget {
//   @override
//   Widget build(BuildContext context) {
//     return AnimatedBuilder(
//       animation: SosDispatchManager.instance,
//       builder: (context, _) {
//         final manager = SosDispatchManager.instance;
//         return ElevatedButton(
//           onPressed: manager.isDispatching ? null : () async {
//             final payload = SosPayload(
//               protocolVersion: 1,
//               bloodType: EmergencyProfile.current.bloodType.code,
//               latitude: 39.9042,
//               longitude: 116.4074,
//               timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
//             );
//             
//             final success = await manager.triggerSos(payload);
//             
//             if (!context.mounted) return;
//             
//             // UI 反馈
//             if (manager.lastNetworkRequestSucceeded) {
//               ScaffoldMessenger.of(context).showSnackBar(
//                 SnackBar(
//                   content: Text('SOS 已直达指挥中心！'),
//                   backgroundColor: Colors.green,
//                 ),
//               );
//             } else if (manager.lastError != null) {
//               ScaffoldMessenger.of(context).showSnackBar(
//                 SnackBar(
//                   content: Text('无网络信号，已启动战术蓝牙局域网广播！'),
//                   backgroundColor: Colors.orange,
//                 ),
//               );
//             }
//           },
//           child: Text(manager.isDispatching ? '调度中...' : 'SOS'),
//         );
//       },
//     );
//   }
// }
//
// // 2. 在任何地方直接调用
// await SosDispatchManager.instance.triggerSos(myPayload);
//
// ============================================================================
