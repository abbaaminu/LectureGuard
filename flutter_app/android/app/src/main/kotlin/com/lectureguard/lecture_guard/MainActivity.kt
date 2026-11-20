package com.lectureguard.lecture_guard

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
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
                            val manager =
                                getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                                !manager.isInLockTaskMode
                            ) {
                                startLockTask()
                            }
                            // The window manager applies the transition
                            // asynchronously, so report the state one frame later
                            // instead of racing it.
                            Handler(Looper.getMainLooper()).postDelayed({
                                result.success(lockTaskState(manager))
                            }, LOCK_TASK_SETTLE_MILLIS)
                        }
                        "stopLockTask" -> {
                            val manager =
                                getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                                manager.isInLockTaskMode
                            ) {
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

    /**
     * Reports how strongly the app is locked.
     *
     * "locked" means a device-owner / MDM provisioned kiosk (LOCK_TASK_MODE_LOCKED)
     * and "pinned" means plain screen pinning, which the operator can dismiss
     * from the Recents screen without a PIN.
     */
    private fun lockTaskState(manager: ActivityManager): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return if (manager.isInLockTaskMode) "pinned" else "none"
        }
        return when (manager.lockTaskModeState) {
            ActivityManager.LOCK_TASK_MODE_LOCKED -> "locked"
            ActivityManager.LOCK_TASK_MODE_PINNED -> "pinned"
            else -> "none"
        }
    }

    private companion object {
        const val LOCK_TASK_SETTLE_MILLIS = 400L
    }
}
