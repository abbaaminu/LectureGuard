package com.lectureguard.lecture_guard

import android.app.Application
import androidx.work.Configuration

/**
 * Supplies WorkManager's configuration on demand.
 *
 * The default `androidx.work.WorkManagerInitializer` is disabled in
 * AndroidManifest.xml, so WorkManager is no longer built inside
 * `androidx.startup.InitializationProvider` while the process is starting.
 * That initialisation touches Room reflectively; when R8 broke the reflection
 * lookup the exception escaped before Flutter existed and the system reported
 * "LectureGuard keeps stopping". Initialising on demand means any such failure
 * happens inside the `Workmanager` platform call, which Flutter turns into a
 * PlatformException that the Dart startup guard renders as an error screen.
 */
class LectureGuardApplication : Application(), Configuration.Provider {
    // WorkManager 2.9 exposes `Configuration.Provider` as a Kotlin property that
    // Java callers see as `getWorkManagerConfiguration()`.
    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder().build()
}
