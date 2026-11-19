import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class PinSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PinLockoutStatus {
  final int failedAttempts;
  final Duration? remaining;

  const PinLockoutStatus({
    required this.failedAttempts,
    required this.remaining,
  });
}

typedef PinHashFunction = Future<List<int>> Function(
  String pin,
  List<int> salt,
);

class PinSecurityService {
  static const int _hashIterations = 100000;
  static const int _failuresBeforeLockout = 5;
  static const int _baseLockoutSeconds = 30;
  static const int _hashBits = 256;
  static const _pinHashKey = 'lg_lecturer_pin_hash';
  static const _pinSaltKey = 'lg_lecturer_pin_salt';
  static const _pinIterationsKey = 'lg_lecturer_pin_iterations';
  static const _pinFormatKey = 'lg_lecturer_pin_format';
  static const _formatVersion = 'pbkdf2-hmac-sha256-v1';
  static const _failedAttemptsKey = 'lg_lecturer_pin_failed_attempts';
  static const _lockoutLevelKey = 'lg_lecturer_pin_lockout_level';
  static const _lockedUntilKey = 'lg_lecturer_pin_locked_until';

  final PinSecretStore _storage;
  final DateTime Function() _now;
  final PinHashFunction? _hashFunction;

  PinSecurityService({
    PinSecretStore? storage,
    DateTime Function()? clock,
    @visibleForTesting PinHashFunction? hashFunction,
  })  : _storage = storage ??
            _FlutterPinSecretStore(
              const FlutterSecureStorage(
                aOptions: AndroidOptions(encryptedSharedPreferences: true),
                iOptions: IOSOptions(
                  accessibility: KeychainAccessibility.first_unlock,
                ),
              ),
            ),
        _now = clock ?? DateTime.now,
        _hashFunction = hashFunction;

  static String? validatePin(String pin) {
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      return 'Choose a PIN containing exactly 4 digits.';
    }
    if (pin == '0000' ||
        pin == '1234' ||
        RegExp(r'^(\d)\1{3}$').hasMatch(pin)) {
      return 'Choose a less predictable PIN; repeated digits and 1234 are not allowed.';
    }
    return null;
  }

  Future<bool> ensurePinInitialized() async {
    final format = await _storage.read(_pinFormatKey);
    final hash = await _storage.read(_pinHashKey);
    final salt = await _storage.read(_pinSaltKey);
    final iterations =
        int.tryParse(await _storage.read(_pinIterationsKey) ?? '');

    if (format == _formatVersion &&
        hash != null &&
        salt != null &&
        iterations != null &&
        iterations >= _hashIterations) {
      return true;
    }

    if (format != null || hash != null || salt != null || iterations != null) {
      await _clearPinData();
    }
    return false;
  }

  Future<void> setLecturerPin(String pin) async {
    final validationError = validatePin(pin);
    if (validationError != null) throw ArgumentError(validationError);
    if (await ensurePinInitialized()) {
      throw StateError('Use the current PIN to change lecturer PIN settings.');
    }

    await _storePin(pin);
  }

  Future<void> _storePin(String pin) async {
    final salt = await SecretKeyData.random(length: 16).extractBytes();
    final hash = await _deriveHash(pin, salt);
    await _storage.write(_pinSaltKey, base64UrlEncode(salt));
    await _storage.write(_pinIterationsKey, '$_hashIterations');
    await _storage.write(_pinHashKey, base64UrlEncode(hash));
    await _storage.write(_pinFormatKey, _formatVersion);
    await _resetLockout();
  }

  Future<bool> changeLecturerPin({
    required String oldPin,
    required String newPin,
  }) async {
    final validationError = validatePin(newPin);
    if (validationError != null) throw ArgumentError(validationError);
    if (!await verifyLecturerPin(oldPin)) return false;
    await _storePin(newPin);
    return true;
  }

  Future<bool> verifyLecturerPin(String candidatePin) async {
    if (!await ensurePinInitialized()) {
      throw StateError('Set a lecturer PIN before verifying one.');
    }

    final lockout = await getLockoutStatus();
    if (lockout.remaining != null) return false;
    if (await _storage.read(_lockedUntilKey) != null) {
      await _storage.delete(_lockedUntilKey);
      await _storage.write(_failedAttemptsKey, '0');
    }

    if (!RegExp(r'^\d{4}$').hasMatch(candidatePin)) {
      return _recordFailedAttempt();
    }

    final salt = base64Url.decode((await _storage.read(_pinSaltKey))!);
    final storedHash = base64Url.decode((await _storage.read(_pinHashKey))!);
    final iterations = int.parse((await _storage.read(_pinIterationsKey))!);
    final candidateHash = await _deriveHash(
      candidatePin,
      salt,
      iterations: iterations,
    );
    if (_constantTimeEquals(candidateHash, storedHash)) {
      await _resetLockout();
      return true;
    }

    return _recordFailedAttempt();
  }

  Future<bool> _recordFailedAttempt() async {
    final failedAttempts = _readCounter(
      await _storage.read(_failedAttemptsKey),
      key: _failedAttemptsKey,
    );
    final updatedAttempts = failedAttempts + 1;
    if (updatedAttempts < _failuresBeforeLockout) {
      await _storage.write(_failedAttemptsKey, '$updatedAttempts');
      return false;
    }

    final lockoutLevel = _readCounter(
      await _storage.read(_lockoutLevelKey),
      key: _lockoutLevelKey,
    );
    final durationSeconds = _baseLockoutSeconds * (1 << lockoutLevel);
    final lockedUntil = _now()
        .toUtc()
        .add(Duration(seconds: durationSeconds))
        .millisecondsSinceEpoch;
    await _storage.write(_failedAttemptsKey, '0');
    await _storage.write(_lockoutLevelKey, '${lockoutLevel + 1}');
    await _storage.write(_lockedUntilKey, '$lockedUntil');
    return false;
  }

  Future<PinLockoutStatus> getLockoutStatus() async {
    final failedAttempts = _readCounter(
      await _storage.read(_failedAttemptsKey),
      key: _failedAttemptsKey,
    );
    final lockedUntilText = await _storage.read(_lockedUntilKey);
    if (lockedUntilText == null) {
      return PinLockoutStatus(
        failedAttempts: failedAttempts,
        remaining: null,
      );
    }

    final lockedUntil = int.tryParse(lockedUntilText);
    if (lockedUntil == null) {
      throw StateError('Stored lecturer PIN lockout time is invalid.');
    }
    final remainingMillis = lockedUntil - _now().toUtc().millisecondsSinceEpoch;
    return PinLockoutStatus(
      failedAttempts: failedAttempts,
      remaining:
          remainingMillis > 0 ? Duration(milliseconds: remainingMillis) : null,
    );
  }

  Future<void> _resetLockout() async {
    await _storage.delete(_failedAttemptsKey);
    await _storage.delete(_lockoutLevelKey);
    await _storage.delete(_lockedUntilKey);
  }

  Future<void> _clearPinData() async {
    await _storage.delete(_pinHashKey);
    await _storage.delete(_pinSaltKey);
    await _storage.delete(_pinIterationsKey);
    await _storage.delete(_pinFormatKey);
    await _resetLockout();
  }

  int _readCounter(String? value, {required String key}) {
    if (value == null) return 0;
    final counter = int.tryParse(value);
    if (counter == null || counter < 0) {
      throw StateError('Stored lecturer PIN value "$key" is invalid.');
    }
    return counter;
  }

  Future<List<int>> _deriveHash(
    String pin,
    List<int> salt, {
    int iterations = _hashIterations,
  }) async {
    final hashFunction = _hashFunction;
    if (hashFunction != null) return hashFunction(pin, salt);
    final pbkdf2 = Pbkdf2.hmacSha256(
      iterations: iterations,
      bits: _hashBits,
    );
    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    return secretKey.extractBytes();
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

class _FlutterPinSecretStore implements PinSecretStore {
  final FlutterSecureStorage _storage;

  const _FlutterPinSecretStore(this._storage);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
