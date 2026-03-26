import 'dart:typed_data';

import '../models/sos_payload.dart';

class BlePayloadEncoder {
  BlePayloadEncoder._();

  static const int protocolVersion = 0x01;
  static const int payloadLength = 14;
  static const Endian byteOrder = Endian.little;

  static List<int> encodeSosData({
    required double lat,
    required double lon,
    required int bloodType,
    required DateTime time,
  }) {
    _validateCoordinate(lat, isLatitude: true);
    _validateCoordinate(lon, isLatitude: false);

    if (bloodType < 0 || bloodType > 0xFF) {
      throw RangeError.range(bloodType, 0, 0xFF, 'bloodType');
    }

    final timestamp = time.toUtc().millisecondsSinceEpoch ~/ 1000;
    if (timestamp < 0 || timestamp > 0xFFFFFFFF) {
      throw RangeError.range(timestamp, 0, 0xFFFFFFFF, 'time');
    }

    final byteData = ByteData(payloadLength);
    byteData.setUint8(0, protocolVersion);
    byteData.setUint8(1, bloodType);
    byteData.setFloat32(2, lat, byteOrder);
    byteData.setFloat32(6, lon, byteOrder);
    byteData.setUint32(10, timestamp, byteOrder);

    return byteData.buffer.asUint8List();
  }

  static SosPayload? decodeSosData(List<int> rawBytes) {
    if (rawBytes.length != payloadLength) {
      throw FormatException(
        'Invalid BLE SOS payload length: expected $payloadLength bytes, got '
        '${rawBytes.length}.',
      );
    }

    final bytes = Uint8List.fromList(rawBytes);
    final byteData = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );

    final version = byteData.getUint8(0);
    if (version != protocolVersion) {
      return null;
    }

    final bloodType = byteData.getUint8(1);
    final latitude = byteData.getFloat32(2, byteOrder);
    final longitude = byteData.getFloat32(6, byteOrder);
    final timestamp = byteData.getUint32(10, byteOrder);

    _validateCoordinate(latitude, isLatitude: true);
    _validateCoordinate(longitude, isLatitude: false);

    return SosPayload(
      protocolVersion: version,
      bloodType: bloodType,
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
    );
  }

  static void _validateCoordinate(double value, {required bool isLatitude}) {
    if (!value.isFinite) {
      throw FormatException(
        isLatitude ? 'Latitude is not finite.' : 'Longitude is not finite.',
      );
    }

    final isValid = isLatitude
        ? value >= -90.0 && value <= 90.0
        : value >= -180.0 && value <= 180.0;
    if (!isValid) {
      throw RangeError.value(
        value,
        isLatitude ? 'lat' : 'lon',
        isLatitude
            ? 'Latitude must be between -90 and 90 degrees.'
            : 'Longitude must be between -180 and 180 degrees.',
      );
    }
  }
}
