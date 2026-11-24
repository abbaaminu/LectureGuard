# LectureGuard R8 keep rules (release builds only; debug builds are not shrunk).
#
# The Flutter Gradle plugin enables R8 for every release build and only ships
# rules for the Flutter engine's JNI entry points. Everything below keeps the
# reflection-based lookups the Android dependencies perform at startup, so a
# release APK behaves like the debug build.

# WorkManager opens its own Room database and creates the generated
# implementation by reflection from `RoomDatabase#canonicalName + "_Impl"`.
# R8 renamed `androidx.work.impl.WorkDatabase_Impl` in the v1.0.0 release, so
# that lookup threw during `androidx.startup.InitializationProvider` and the
# process died before Flutter ran ("Failed to create an instance of class
# androidx.work.impl.WorkDatabase"). Keeping every Room database class, its
# name and all of its members (including the no-arg constructor Room invokes)
# is what prevents the crash on launch.
-keep class * extends androidx.room.RoomDatabase { *; }
-keepnames class * extends androidx.room.RoomDatabase
-keep class androidx.work.impl.WorkDatabase_Impl { *; }

# Workers are instantiated from class names persisted in WorkManager's database,
# so their names and constructors have to survive shrinking. The Flutter
# workmanager plugin registers `dev.fluttercommunity.workmanager.BackgroundWorker`
# by name; keeping the package also means work enqueued by an older install can
# still be resolved after an app update re-obfuscates the rest of the APK.
-keep class * extends androidx.work.ListenableWorker { <init>(...); }
-keepnames class * extends androidx.work.ListenableWorker
-keep class dev.fluttercommunity.workmanager.** { *; }

# Room and WorkManager read generic signatures and annotations reflectively.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

