package com.lectureguard.lecture_guard

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val passModeChannel = "lecture_guard/pass_mode_lock"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, passModeChannel)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startLockTask" -> {
                            val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || !manager.isInLockTaskMode) {
                                startLockTask()
                            }
                            result.success(null)
                        }
                        "stopLockTask" -> {
                            val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || manager.isInLockTaskMode) {
                                stopLockTask()
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("PASS_MODE_LOCK_FAILED", error.message, null)
                }
            }
    }
}
