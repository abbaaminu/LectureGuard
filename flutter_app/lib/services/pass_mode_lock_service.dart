import 'dart:io';

import 'package:flutter/services.dart';

/// Result of asking the platform to lock the app into Pass Mode.
enum PassModeLockState {
  /// Android lock-task mode is `LOCKED`: the device is a real kiosk (device
  /// owner / MDM provisioned) and the operator cannot leave the app from the
  /// Recents screen.
  locked,

  /// Screen pinning is active (`LOCK_TASK_MODE_PINNED`). It keeps the app in
  /// front, but the operator can dismiss it from Recents without a PIN, so it
  /// is a deterrent rather than a kiosk.
  pinned,

  /// The platform refused to lock, or the lock did not engage.
  failed,

  /// The platform has no lock-task support (iOS relies on Guided Access).
  unsupported,
}

class PassModeLockService {
  static const MethodChannel _channel =
      MethodChannel('lecture_guard/pass_mode_lock');

  /// Locks the app into Pass Mode and reports how strong the result is.
  ///
  /// Never throws: a platform failure is reported as [PassModeLockState.failed]
  /// so the caller can surface a persistent warning instead of a transient
  /// snackbar.
  Future<PassModeLockState> start() async {
    if (!Platform.isAndroid) return PassModeLockState.unsupported;
    try {
      final state = await _channel.invokeMethod<String>('startLockTask');
      switch (state) {
        case 'locked':
          return PassModeLockState.locked;
        case 'pinned':
          return PassModeLockState.pinned;
        default:
          return PassModeLockState.failed;
      }
    } on PlatformException {
      return PassModeLockState.failed;
    } on MissingPluginException {
      return PassModeLockState.failed;
    }
  }

  /// Leaves lock-task / pinned mode.
  ///
  /// Never throws: the exit path calls this after the admin PIN has already been
  /// verified, so a platform failure must not be reported as a failed unlock or
  /// leave the operator stuck inside a session that has already ended. The
  /// platform side is idempotent when no task is locked.
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stopLockTask');
    } on PlatformException {
      // Nothing to do: the screen-pinning state is gone or was never engaged.
    } on MissingPluginException {
      // Host platform without the channel (tests, iOS fallback).
    }
  }
}
