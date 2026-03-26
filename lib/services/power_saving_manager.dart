import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:location/location.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef SharedPreferencesLoader = Future<SharedPreferences> Function();

class GpsUpdatePolicy {
  const GpsUpdatePolicy({
    required this.interval,
    required this.accuracy,
    required this.continuousTracking,
    required this.singleFixOnly,
    required this.distanceFilter,
    required this.description,
  });

  final Duration interval;
  final LocationAccuracy accuracy;
  final bool continuousTracking;
  final bool singleFixOnly;
  final double distanceFilter;
  final String description;
}

abstract class BrightnessController {
  Future<void> setMinimumBrightness();

  Future<void> restoreDefaultBrightness();
}

class ScreenBrightnessController implements BrightnessController {
  const ScreenBrightnessController();

  static const double minimumBrightness = 0.05;

  @override
  Future<void> setMinimumBrightness() {
    return ScreenBrightness.instance.setApplicationScreenBrightness(
      minimumBrightness,
    );
  }

  @override
  Future<void> restoreDefaultBrightness() {
    return ScreenBrightness.instance.resetApplicationScreenBrightness();
  }
}

class PowerSavingManager extends ChangeNotifier with WidgetsBindingObserver {
  PowerSavingManager({
    BrightnessController? brightnessController,
    SharedPreferencesLoader? preferencesLoader,
  }) : _brightnessController =
           brightnessController ?? const ScreenBrightnessController(),
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const String _ultraPowerSavingModeKey = 'is_ultra_power_saving_mode';
  static const Duration _normalBleAdvertiseInterval = Duration(seconds: 1);
  static const Duration _ultraBleAdvertiseInterval = Duration(seconds: 5);
  static const Duration _normalGpsUpdateInterval = Duration(seconds: 1);
  static const Duration _ultraGpsUpdateInterval = Duration(minutes: 5);
  static const GpsUpdatePolicy _normalGpsPolicy = GpsUpdatePolicy(
    interval: _normalGpsUpdateInterval,
    accuracy: LocationAccuracy.high,
    continuousTracking: true,
    singleFixOnly: false,
    distanceFilter: 0,
    description: '高精度持续监听',
  );
  static const GpsUpdatePolicy _ultraGpsPolicy = GpsUpdatePolicy(
    interval: _ultraGpsUpdateInterval,
    accuracy: LocationAccuracy.powerSave,
    continuousTracking: false,
    singleFixOnly: true,
    distanceFilter: 250,
    description: '每 5 分钟单次唤醒并复用坐标缓存',
  );

  final BrightnessController _brightnessController;
  final SharedPreferencesLoader _preferencesLoader;

  Future<void>? _initFuture;
  SharedPreferences? _preferences;
  bool _isUltraPowerSavingMode = false;
  bool _isInitialized = false;
  bool _isApplyingMode = false;
  bool _isObserverRegistered = false;
  String? _lastBrightnessError;
  LocationData? _cachedLocation;
  DateTime? _cachedLocationUpdatedAt;

  bool get isUltraPowerSavingMode => _isUltraPowerSavingMode;
  bool get isInitialized => _isInitialized;
  bool get isApplyingMode => _isApplyingMode;
  String? get lastBrightnessError => _lastBrightnessError;
  bool get hasRecentLocationCache => _hasFreshLocationCache();

  Future<void> initialize() {
    if (!_isObserverRegistered) {
      WidgetsBinding.instance.addObserver(this);
      _isObserverRegistered = true;
    }

    return _initFuture ??= _performInitialize().whenComplete(() {
      _initFuture = null;
    });
  }

  Future<void> _performInitialize() async {
    _preferences ??= await _preferencesLoader();
    _isUltraPowerSavingMode =
        _preferences?.getBool(_ultraPowerSavingModeKey) ?? false;
    _isInitialized = true;
    await _applyBrightnessPolicy();
    notifyListeners();
  }

  Future<void> setUltraPowerSavingMode(bool enabled) async {
    await initialize();
    if (_isUltraPowerSavingMode == enabled) {
      return;
    }

    _isApplyingMode = true;
    _isUltraPowerSavingMode = enabled;
    notifyListeners();

    await _preferences?.setBool(_ultraPowerSavingModeKey, enabled);
    await _applyBrightnessPolicy();

    _isApplyingMode = false;
    notifyListeners();
  }

  Future<void> toggleUltraPowerSavingMode() {
    return setUltraPowerSavingMode(!_isUltraPowerSavingMode);
  }

  Duration getBleAdvertiseInterval() {
    return _isUltraPowerSavingMode
        ? _ultraBleAdvertiseInterval
        : _normalBleAdvertiseInterval;
  }

  Duration getGpsUpdateInterval() {
    return _isUltraPowerSavingMode
        ? _ultraGpsUpdateInterval
        : _normalGpsUpdateInterval;
  }

  GpsUpdatePolicy getGpsUpdatePolicy() {
    return _isUltraPowerSavingMode ? _ultraGpsPolicy : _normalGpsPolicy;
  }

  bool shouldEnableLocalAi() => !_isUltraPowerSavingMode;

  bool shouldUseContinuousGpsTracking() {
    return getGpsUpdatePolicy().continuousTracking;
  }

  Future<LocationData> acquireLocationFix({Location? location}) async {
    await initialize();

    final locationClient = location ?? Location.instance;
    final gpsPolicy = getGpsUpdatePolicy();
    await locationClient.changeSettings(
      accuracy: gpsPolicy.accuracy,
      interval: gpsPolicy.interval.inMilliseconds,
      distanceFilter: gpsPolicy.distanceFilter,
    );

    if (_isUltraPowerSavingMode && _hasFreshLocationCache()) {
      return _cachedLocation!;
    }

    final locationData = await locationClient.getLocation();
    cacheLocationFix(locationData);
    return locationData;
  }

  void cacheLocationFix(LocationData locationData) {
    if (locationData.latitude == null || locationData.longitude == null) {
      return;
    }

    _cachedLocation = locationData;
    _cachedLocationUpdatedAt = DateTime.now();
  }

  bool _hasFreshLocationCache() {
    if (_cachedLocation == null || _cachedLocationUpdatedAt == null) {
      return false;
    }

    return DateTime.now().difference(_cachedLocationUpdatedAt!) <
        _ultraGpsUpdateInterval;
  }

  Future<void> _applyBrightnessPolicy() async {
    if (kIsWeb) {
      _lastBrightnessError = null;
      return;
    }

    try {
      if (_isUltraPowerSavingMode) {
        await _brightnessController.setMinimumBrightness();
      } else {
        await _brightnessController.restoreDefaultBrightness();
      }
      _lastBrightnessError = null;
    } on PlatformException catch (error) {
      _lastBrightnessError = error.message ?? error.code;
    } on MissingPluginException catch (error) {
      _lastBrightnessError = '$error';
    } catch (error) {
      _lastBrightnessError = '$error';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isUltraPowerSavingMode) {
      unawaited(_applyBrightnessPolicy());
    }
  }

  @override
  void dispose() {
    if (_isObserverRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _isObserverRegistered = false;
    }
    super.dispose();
  }
}

final powerSavingManager = PowerSavingManager();
