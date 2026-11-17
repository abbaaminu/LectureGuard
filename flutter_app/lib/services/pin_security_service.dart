import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PinSecurityService {
  static const _pinHashKey = 'lg_lecturer_pin_hash';
  static const _pinSaltKey = 'lg_lecturer_pin_salt';
  static const _defaultDemoPin = '2468';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  Future<void> ensurePinInitialized() async {
    final existingHash = await _secureStorage.read(key: _pinHashKey);
    if (existingHash == null) {
      await setLecturerPin(_defaultDemoPin);
    }
  }

  Future<void> setLecturerPin(String pin) async {
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      throw ArgumentError('Lecturer PIN must be exactly 4 digits.');
    }
    final salt = _generateSalt();
    final hash = _hashPin(pin, salt);
    await _secureStorage.write(key: _pinSaltKey, value: salt);
    await _secureStorage.write(key: _pinHashKey, value: hash);
  }

  Future<bool> verifyLecturerPin(String candidatePin) async {
    final salt = await _secureStorage.read(key: _pinSaltKey);
    final storedHash = await _secureStorage.read(key: _pinHashKey);
    if (salt == null || storedHash == null) {
      return candidatePin == _defaultDemoPin;
    }
    final candidateHash = _hashPin(candidatePin, salt);
    return _constantTimeEquals(candidateHash, storedHash);
  }

  String _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  String _hashPin(String pin, String salt) {
    final bytes = utf8.encode('$salt::$pin::lectureguard_v1');
    return sha256.convert(bytes).toString();
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
