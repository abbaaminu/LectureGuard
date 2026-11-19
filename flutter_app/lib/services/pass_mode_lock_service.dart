import 'dart:io';

import 'package:flutter/services.dart';

class PassModeLockService {
  static const MethodChannel _channel =
      MethodChannel('lecture_guard/pass_mode_lock');

  Future<void> start() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('startLockTask');
    }
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('stopLockTask');
    }
  }
}
