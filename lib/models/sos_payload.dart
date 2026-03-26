class SosPayload {
  const SosPayload({
    required this.protocolVersion,
    required this.bloodType,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
  });

  final int protocolVersion;
  final int bloodType;
  final double latitude;
  final double longitude;
  final int timestamp;

  DateTime get time =>
      DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }

    return other is SosPayload &&
        other.protocolVersion == protocolVersion &&
        other.bloodType == bloodType &&
        other.latitude == latitude &&
        other.longitude == longitude &&
        other.timestamp == timestamp;
  }

  @override
  int get hashCode =>
      Object.hash(protocolVersion, bloodType, latitude, longitude, timestamp);

  @override
  String toString() {
    return 'SosPayload(protocolVersion: $protocolVersion, bloodType: $bloodType, '
        'latitude: $latitude, longitude: $longitude, timestamp: $timestamp)';
  }
}
