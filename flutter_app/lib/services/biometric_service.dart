import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth/error_codes.dart' as auth_error;

class BiometricVerificationResult {
  final bool verified;
  final String method; // 'fingerprint' | 'face_id' | 'biometric'
  final String? errorMessage;

  const BiometricVerificationResult({
    required this.verified,
    required this.method,
    this.errorMessage,
  });
}

class BiometricService {
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> isHardwareAvailable() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final isSupported = await _auth.isDeviceSupported();
      return canCheck && isSupported;
    } on PlatformException {
      return false;
    }
  }

  Future<List<BiometricType>> getEnrolledTypes() async {
    try {
      return await _auth.getAvailableBiometrics();
    } on PlatformException {
      return const [];
    }
  }

  /// Strictly enforces local hardware biometric verification (biometricOnly: true)
  /// so students cannot bypass with a device passcode.
  Future<BiometricVerificationResult> verifyStudentIdentity({
    required String studentName,
  }) async {
    try {
      final available = await isHardwareAvailable();
      if (!available) {
        return const BiometricVerificationResult(
          verified: false,
          method: 'unavailable',
          errorMessage: 'Biometric hardware not enrolled on this device.',
        );
      }

      final types = await getEnrolledTypes();
      final methodLabel = types.contains(BiometricType.face)
          ? 'face_id'
          : types.contains(BiometricType.fingerprint)
              ? 'fingerprint'
              : 'biometric';

      final didAuthenticate = await _auth.authenticate(
        localizedReason: 'Verify identity to check in $studentName',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: true,
          sensitiveTransaction: true,
        ),
      );

      return BiometricVerificationResult(
        verified: didAuthenticate,
        method: methodLabel,
        errorMessage: didAuthenticate ? null : 'Biometric verification cancelled.',
      );
    } on PlatformException catch (e) {
      String message = 'Biometric check failed.';
      if (e.code == auth_error.lockedOut || e.code == auth_error.permanentlyLockedOut) {
        message = 'Sensor temporarily locked due to too many failed attempts.';
      } else if (e.code == auth_error.notEnrolled) {
        message = 'No biometrics enrolled on this device.';
      }
      return BiometricVerificationResult(
        verified: false,
        method: 'error',
        errorMessage: message,
      );
    }
  }
}
