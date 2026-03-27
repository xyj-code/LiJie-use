import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../database.dart';
import '../models/emergency_profile.dart';
import '../models/sos_advertisement_payload.dart';
import 'ble_mesh_exceptions.dart';
import 'power_saving_manager.dart';

class BleMeshService extends ChangeNotifier {
  BleMeshService() {
    if (Platform.isAndroid) {
      _adapterSubscription = FlutterBluePlus.adapterState.listen((state) {
        _adapterState = state;
        notifyListeners();
      });
      _broadcastSubscription = _broadcastStateChannel
          .receiveBroadcastStream()
          .listen(_handleBroadcastState, onError: _handleBroadcastStateError);
    }
  }

  static const MethodChannel _broadcastChannel = MethodChannel(
    'rescue_mesh/advertiser',
  );
  static const EventChannel _broadcastStateChannel = EventChannel(
    'rescue_mesh/advertiser_state',
  );

  final StreamController<bool> _isBroadcastingController =
      StreamController<bool>.broadcast();

  StreamSubscription<BluetoothAdapterState>? _adapterSubscription;
  StreamSubscription<dynamic>? _broadcastSubscription;
  Future<void>? _initFuture;

  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  BleMeshException? _lastException;
  bool _isInitializing = false;
  bool _isBroadcastingNow = false;
  bool _permissionsGranted = false;
  bool _relayEnabled = true;

  // Relay Queue mechanism
  Timer? _interleavedBroadcastTimer;
  final List<List<int>> _broadcastQueue = [];
  int _currentBroadcastIndex = 0;
  bool _isOwnSosActive = false;
  List<int>? _ownSosPayload;

  // Constants for relay mechanism
  static const Duration _relayFetchInterval = Duration(minutes: 1);
  static const Duration _relayMaxAge = Duration(hours: 2);
  static const int _maxRelayPayloads = 5;
  static const Duration _broadcastSwitchInterval = Duration(milliseconds: 1500);

  Timer? _relayFetchTimer;

  BluetoothAdapterState get adapterState => _adapterState;
  bool get permissionsGranted => _permissionsGranted;
  bool get isInitializing => _isInitializing;
  bool get isBroadcastingNow => _isBroadcastingNow;
  bool get isAdvertising => _isBroadcastingNow;
  bool get relayEnabled => _relayEnabled;
  bool get isRelayActive => _broadcastQueue.isNotEmpty;
  int get queueLength => _broadcastQueue.length;
  BleMeshException? get lastException => _lastException;
  String? get lastError => _lastException?.message;
  bool get isAdapterReady => _adapterState == BluetoothAdapterState.on;
  Stream<bool> get isBroadcasting => _isBroadcastingController.stream;

  @Deprecated('Use init() instead.')
  Future<void> initialize() => init();

  @Deprecated('Use startSosBroadcast() instead.')
  Future<void> startSosAdvertising(SosAdvertisementPayload payload) {
    return startSosBroadcast(
      latitude: payload.latitude,
      longitude: payload.longitude,
      bloodType: payload.bloodType,
      sosFlag: payload.sosFlag,
      companyId: payload.companyId,
    );
  }

  @Deprecated('Use stopSosBroadcast() instead.')
  Future<void> stopSosAdvertising() => stopSosBroadcast();

  @Deprecated('Use isBroadcasting instead.')
  Stream<bool> get advertisingState => isBroadcasting;

  Future<void> init() {
    if (!Platform.isAndroid) {
      _permissionsGranted = true;
      _lastException = null;
      notifyListeners();
      return Future.value();
    }
    return _initFuture ??= _performInit().whenComplete(() {
      _initFuture = null;
    });
  }

  Future<void> refresh() async {
    await init();
  }

  @Deprecated('Use init() instead.')
  Future<bool> ensureRuntimePermissions() async {
    await init();
    return _permissionsGranted;
  }

  Future<void> startSosBroadcast({
    required double latitude,
    required double longitude,
    required BloodType bloodType,
    bool sosFlag = true,
    int companyId = 0xFFFF,
  }) async {
    await init();
    if (!Platform.isAndroid) {
      throw const BleMeshUnsupportedException('当前仅实现了 Android 端的 SOS BLE 广播。');
    }
    if (!isAdapterReady) {
      final exception = const BleMeshBluetoothDisabledException();
      _setException(exception);
      throw exception;
    }

    final payload = SosAdvertisementPayload(
      companyId: companyId,
      longitude: longitude,
      latitude: latitude,
      bloodType: bloodType,
      sosFlag: sosFlag,
    );

    try {
      // Store own SOS payload
      _ownSosPayload = payload.rawManufacturerData;
      _isOwnSosActive = true;

      // Stop any existing broadcast first
      await _stopNativeBroadcast();

      // Start interleaved broadcast with relay queue
      await _startInterleavedBroadcast();

      _setException(null);
    } on PlatformException catch (error) {
      final exception = _mapPlatformException(error);
      _setException(exception);
      throw exception;
    } on BleMeshException catch (error) {
      _setException(error);
      rethrow;
    } catch (error) {
      final exception = BleMeshPlatformException(
        platformCode: 'start_broadcast_failed',
        message: '启动 SOS 广播失败：$error',
        details: error,
      );
      _setException(exception);
      throw exception;
    }
  }

  Future<void> stopSosBroadcast() async {
    // Stop the interleaved broadcast timer
    _interleavedBroadcastTimer?.cancel();
    _interleavedBroadcastTimer = null;

    // Stop the relay fetch timer
    _relayFetchTimer?.cancel();
    _relayFetchTimer = null;

    // Clear the broadcast queue
    _broadcastQueue.clear();
    _currentBroadcastIndex = 0;
    _ownSosPayload = null;
    _isOwnSosActive = false;

    // Stop the native broadcast
    await _stopNativeBroadcast();

    if (!Platform.isAndroid) {
      _isBroadcastingNow = false;
      _isBroadcastingController.add(false);
      notifyListeners();
      return;
    }

    _setException(null);
  }

  Future<void> setRelayEnabled(bool value) async {
    _relayEnabled = value;
    notifyListeners();
  }

  Future<void> _performInit() async {
    if (_isInitializing) return;

    _isInitializing = true;
    _setException(null);
    notifyListeners();

    try {
      final supported = await FlutterBluePlus.isSupported;
      if (!supported) {
        throw const BleMeshUnsupportedException();
      }

      await _ensureRuntimePermissions();
      if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.unknown) {
        _adapterState = await FlutterBluePlus.adapterState.first;
      } else {
        _adapterState = FlutterBluePlus.adapterStateNow;
      }
      _permissionsGranted = true;
    } on BleMeshException catch (error) {
      if (error is BleMeshPermissionDeniedException) {
        _permissionsGranted = false;
      }
      _setException(error);
      rethrow;
    } catch (error) {
      _permissionsGranted = false;
      final exception = BleMeshPlatformException(
        platformCode: 'init_failed',
        message: 'BLE 初始化失败。',
        details: error,
      );
      _setException(exception);
      throw exception;
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  Future<void> _ensureRuntimePermissions() async {
    final statuses = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final deniedPermissions = <Permission>[];
    final permanentlyDeniedPermissions = <Permission>[];

    for (final entry in statuses.entries) {
      if (!entry.value.isGranted) {
        deniedPermissions.add(entry.key);
      }
      if (entry.value.isPermanentlyDenied) {
        permanentlyDeniedPermissions.add(entry.key);
      }
    }

    if (deniedPermissions.isNotEmpty) {
      throw BleMeshPermissionDeniedException(
        deniedPermissions: deniedPermissions,
        permanentlyDeniedPermissions: permanentlyDeniedPermissions,
        message: permanentlyDeniedPermissions.isNotEmpty
            ? '部分蓝牙或定位权限被永久拒绝，请前往系统设置手动开启。'
            : '蓝牙或定位权限被拒绝，无法继续执行 SOS 广播。',
      );
    }

    _permissionsGranted = true;
  }

  void _handleBroadcastState(dynamic value) {
    if (value is bool) {
      _isBroadcastingNow = value;
      _isBroadcastingController.add(value);
      notifyListeners();
    }
  }

  void _handleBroadcastStateError(Object error) {
    final exception = BleMeshPlatformException(
      platformCode: 'state_stream_failed',
      message: '广播状态监听失败。',
      details: error,
    );
    _setException(exception);
  }

  BleMeshException _mapPlatformException(PlatformException error) {
    switch (error.code) {
      case 'unsupported':
        return BleMeshUnsupportedException(error.message);
      case 'permission':
        return BleMeshPermissionDeniedException(
          deniedPermissions: [
            Permission.bluetoothScan,
            Permission.bluetoothAdvertise,
            Permission.bluetoothConnect,
            Permission.locationWhenInUse,
          ],
          permanentlyDeniedPermissions: [],
          message: error.message ?? '广播权限不足，请先授权蓝牙与定位权限。',
        );
      case 'disabled':
        return BleMeshBluetoothDisabledException(error.message);
      case 'unavailable':
        return BleMeshAdapterUnavailableException(error.message);
      case 'invalid_args':
        return BleMeshInvalidPayloadException(error.message);
      case 'broadcast_failed':
      case 'advertise_failed':
        return BleMeshBroadcastFailedException(
          platformCode: error.code,
          message: error.message ?? 'SOS 广播启动失败。',
          details: error.details,
        );
      default:
        return BleMeshPlatformException(
          platformCode: error.code,
          message: error.message ?? '发生未预期的 BLE 平台错误。',
          details: error.details,
        );
    }
  }

  void _setException(BleMeshException? exception) {
    _lastException = exception;
    notifyListeners();
  }

  // ============================================================================
  // Relay Queue Mechanism - Core Implementation
  // ============================================================================

  /// Start the interleaved broadcast mechanism with relay queue
  ///
  /// This implements the "Store & Forward" multi-hop relay algorithm:
  /// 1. Broadcast own SOS signal (priority 0)
  /// 2. Cycle through relay payloads from other devices
  /// 3. Switch every 1.5 seconds to simulate round-robin broadcasting
  Future<void> _startInterleavedBroadcast() async {
    if (!Platform.isAndroid) {
      debugPrint(
        '[BLE Relay] Interleaved broadcast not supported on this platform',
      );
      return;
    }

    try {
      // Fetch initial relay payloads from database
      await _fetchRelayPayloads();

      // Build initial broadcast queue
      await _rebuildBroadcastQueue();

      // Start the periodic timer to switch broadcasts
      _interleavedBroadcastTimer?.cancel();
      _interleavedBroadcastTimer = Timer.periodic(
        _broadcastSwitchInterval,
        (_) => _switchBroadcastPayload(),
      );

      // Start periodic relay payload refresh
      _relayFetchTimer?.cancel();
      _relayFetchTimer = Timer.periodic(
        _relayFetchInterval,
        (_) => _refreshRelayPayloads(),
      );

      // Set broadcasting state to true
      _isBroadcastingNow = true;
      _isBroadcastingController.add(true);
      notifyListeners();

      debugPrint(
        '[BLE Relay] Interleaved broadcast started with ${_broadcastQueue.length} payloads',
      );
    } catch (error) {
      debugPrint('[BLE Relay] Failed to start interleaved broadcast: $error');
      rethrow;
    }
  }

  /// Fetch unuploaded SOS records from database for relay
  ///
  /// Storm prevention mechanisms:
  /// - Only fetch records from last 2 hours (prevent infinite broadcast)
  /// - Limit to 5 most recent records (prevent Bluetooth payload overload)
  Future<List<StoredSosMessage>> _fetchRelayPayloads() async {
    if (!_relayEnabled) {
      debugPrint('[BLE Relay] Relay is disabled, skipping fetch');
      return [];
    }

    try {
      final now = DateTime.now();
      final threshold = now.subtract(_relayMaxAge);

      // Query database for unuploaded recent SOS messages
      final messages = await appDb
          .customSelect(
            '''
        SELECT id, sender_mac, latitude, longitude, blood_type, timestamp, is_uploaded
        FROM sos_messages
        WHERE is_uploaded = 0 AND timestamp >= ?
        ORDER BY timestamp DESC
        LIMIT ?
        ''',
            variables: [
              Variable<DateTime>(threshold),
              Variable<int>(_maxRelayPayloads),
            ],
            readsFrom: const {},
          )
          .get();

      final storedMessages = messages.map((row) {
        return StoredSosMessage(
          id: row.read<int>('id'),
          senderMac: row.read<String>('sender_mac'),
          latitude: row.read<double>('latitude'),
          longitude: row.read<double>('longitude'),
          bloodType: row.read<int>('blood_type'),
          timestamp: row.read<DateTime>('timestamp'),
          isUploaded: row.read<bool>('is_uploaded'),
        );
      }).toList();

      debugPrint(
        '[BLE Relay] Fetched ${storedMessages.length} relay payloads from database',
      );
      return storedMessages;
    } catch (error) {
      debugPrint('[BLE Relay] Failed to fetch relay payloads: $error');
      return [];
    }
  }

  /// Refresh relay payloads periodically
  Future<void> _refreshRelayPayloads() async {
    debugPrint('[BLE Relay] Refreshing relay payloads...');
    await _fetchRelayPayloads();
    await _rebuildBroadcastQueue();
  }

  /// Rebuild the broadcast queue with own SOS + relay payloads
  ///
  /// Queue structure:
  /// - Index 0: Own SOS payload (if active)
  /// - Index 1..N: Relay payloads from other devices
  Future<void> _rebuildBroadcastQueue() async {
    _broadcastQueue.clear();
    _currentBroadcastIndex = 0;

    // Add own SOS payload as priority 0
    if (_isOwnSosActive && _ownSosPayload != null) {
      _broadcastQueue.add(_ownSosPayload!);
      debugPrint('[BLE Relay] Added own SOS to queue');
    }

    // Fetch and add relay payloads
    final relayMessages = await _fetchRelayPayloads();

    for (final message in relayMessages) {
      try {
        final bloodType = BloodType.values.firstWhere(
          (bt) => bt.code == message.bloodType,
          orElse: () => BloodType.unknown,
        );

        final payload = SosAdvertisementPayload(
          companyId: 0xFFFF,
          longitude: message.longitude,
          latitude: message.latitude,
          bloodType: bloodType,
          sosFlag: true,
        );

        _broadcastQueue.add(payload.rawManufacturerData);
        debugPrint('[BLE Relay] Added relay payload from ${message.senderMac}');
      } catch (error) {
        debugPrint('[BLE Relay] Failed to encode relay payload: $error');
      }
    }

    debugPrint(
      '[BLE Relay] Queue rebuilt with ${_broadcastQueue.length} total payloads',
    );
    notifyListeners();
  }

  /// Switch to the next broadcast payload in round-robin fashion
  ///
  /// This is the "interleaved" part of the algorithm:
  /// - Stop current broadcast
  /// - Wait for completion
  /// - Start new broadcast with next payload
  Future<void> _switchBroadcastPayload() async {
    if (_broadcastQueue.isEmpty) {
      debugPrint('[BLE Relay] Queue empty, skipping switch');
      return;
    }

    try {
      // Calculate next index (round-robin)
      _currentBroadcastIndex =
          (_currentBroadcastIndex + 1) % _broadcastQueue.length;
      final nextPayload = _broadcastQueue[_currentBroadcastIndex];

      debugPrint('[BLE Relay] Switching to payload #$_currentBroadcastIndex');

      // Ensure we stop before starting new broadcast
      await _stopNativeBroadcast();

      // Small delay to ensure Bluetooth hardware is ready
      await Future.delayed(const Duration(milliseconds: 100));

      // Start new broadcast with next payload
      await _startNativeBroadcast(nextPayload);
    } catch (error) {
      debugPrint('[BLE Relay] Error switching payload: $error');
      // Don't rethrow - continue trying to switch
    }
  }

  /// Stop the native BLE broadcast (Android platform)
  Future<void> _stopNativeBroadcast() async {
    if (!Platform.isAndroid) {
      _isBroadcastingNow = false;
      _isBroadcastingController.add(false);
      notifyListeners();
      return;
    }

    try {
      await _broadcastChannel.invokeMethod<void>('stopSosBroadcast');
      _isBroadcastingNow = false;
      _isBroadcastingController.add(false);
      notifyListeners();
      debugPrint('[BLE Relay] Native broadcast stopped');
    } on PlatformException catch (error) {
      debugPrint('[BLE Relay] Error stopping broadcast: ${error.code}');
      // Don't throw - continue anyway
    } catch (error) {
      debugPrint('[BLE Relay] Unexpected error stopping broadcast: $error');
      // Don't throw - continue anyway
    }
  }

  /// Start native BLE broadcast with specific payload (Android platform)
  Future<void> _startNativeBroadcast(List<int> payloadBytes) async {
    if (!Platform.isAndroid) {
      _isBroadcastingNow = true;
      _isBroadcastingController.add(true);
      notifyListeners();
      return;
    }

    try {
      // Extract manufacturer ID and payload from the full data
      final manufacturerId = (payloadBytes[1] << 8) | payloadBytes[0];
      final actualPayload = payloadBytes.sublist(2);

      await _broadcastChannel.invokeMethod<void>('startSosBroadcast', {
        'manufacturerId': manufacturerId,
        'payload': actualPayload,
        'advertiseIntervalMs': powerSavingManager
            .getBleAdvertiseInterval()
            .inMilliseconds,
      });

      _isBroadcastingNow = true;
      _isBroadcastingController.add(true);
      notifyListeners();
      debugPrint(
        '[BLE Relay] Native broadcast started with payload length ${actualPayload.length}',
      );
    } on PlatformException catch (error) {
      debugPrint('[BLE Relay] Error starting broadcast: ${error.code}');
      _isBroadcastingNow = false;
      _isBroadcastingController.add(false);
      notifyListeners();
      rethrow;
    } catch (error) {
      debugPrint('[BLE Relay] Unexpected error starting broadcast: $error');
      _isBroadcastingNow = false;
      _isBroadcastingController.add(false);
      notifyListeners();
      rethrow;
    }
  }

  /// Manually add a relay payload to the queue (for real-time relay)
  ///
  /// This can be called by the BLE scanner service when it discovers
  /// a new SOS message from another device
  void addRelayPayload(SosAdvertisementPayload payload) {
    if (_broadcastQueue.length >= _maxRelayPayloads + 1) {
      debugPrint('[BLE Relay] Queue full, dropping oldest relay payload');
      // Remove oldest relay payload (keep own SOS at index 0)
      if (_broadcastQueue.length > 1) {
        _broadcastQueue.removeAt(1);
      }
    }

    _broadcastQueue.add(payload.rawManufacturerData);
    debugPrint(
      '[BLE Relay] Added new relay payload, queue size: ${_broadcastQueue.length}',
    );
    notifyListeners();
  }

  /// Mark a relay payload as uploaded (will be removed from queue)
  Future<void> markRelayAsUploaded(int messageId) async {
    try {
      await appDb.customUpdate(
        '''
        UPDATE sos_messages
        SET is_uploaded = 1
        WHERE id = ?
        ''',
        variables: [Variable<int>(messageId)],
        updates: const {},
      );
      debugPrint('[BLE Relay] Marked message $messageId as uploaded');

      // Rebuild queue to remove uploaded message
      await _rebuildBroadcastQueue();
    } catch (error) {
      debugPrint('[BLE Relay] Failed to mark message as uploaded: $error');
    }
  }

  @override
  void dispose() {
    // Clean up relay timers
    _interleavedBroadcastTimer?.cancel();
    _interleavedBroadcastTimer = null;
    _relayFetchTimer?.cancel();
    _relayFetchTimer = null;

    _adapterSubscription?.cancel();
    _broadcastSubscription?.cancel();
    _isBroadcastingController.close();
    super.dispose();
  }
}

final bleMeshService = BleMeshService();
