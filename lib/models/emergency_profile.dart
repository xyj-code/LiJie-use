import 'package:flutter/foundation.dart';

enum BloodType {
  unknown(-1),
  a(0),
  b(1),
  ab(2),
  o(3);

  const BloodType(this.code);

  final int code;

  String get label {
    switch (this) {
      case BloodType.a:
        return 'A 型';
      case BloodType.b:
        return 'B 型';
      case BloodType.ab:
        return 'AB 型';
      case BloodType.o:
        return 'O 型';
      case BloodType.unknown:
        return '未知';
    }
  }
}

class EmergencyProfile {
  const EmergencyProfile({
    required this.callsign,
    required this.bloodType,
    required this.allergies,
    required this.emergencyContact,
  });

  final String callsign;
  final BloodType bloodType;
  final String allergies;
  final String emergencyContact;

  /// 使用 ValueNotifier 实现响应式更新
  static final emergencyProfile = ValueNotifier<EmergencyProfile>(
    const EmergencyProfile(
      callsign: 'Rescuer A007',
      bloodType: BloodType.o,
      allergies: 'Penicillin',
      emergencyContact: '138-XXXX-1234',
    ),
  );

  /// 方便访问当前值
  static EmergencyProfile get current => emergencyProfile.value;

  /// 从 SharedPreferences 加载数据
  static Future<void> loadFromPrefs() async {
    // 这里暂时不实现，保持向后兼容
    // 后续可以从 SharedPreferences 加载真实数据
  }

  /// 更新档案数据
  static void updateProfile({
    String? callsign,
    BloodType? bloodType,
    String? allergies,
    String? emergencyContact,
  }) {
    emergencyProfile.value = EmergencyProfile(
      callsign: callsign ?? current.callsign,
      bloodType: bloodType ?? current.bloodType,
      allergies: allergies ?? current.allergies,
      emergencyContact: emergencyContact ?? current.emergencyContact,
    );
  }
}
