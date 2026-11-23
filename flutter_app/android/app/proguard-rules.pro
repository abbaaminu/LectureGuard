# LectureGuard R8 keep rules (release builds only; debug builds are not shrunk).
#
# The Flutter Gradle plugin enables R8 for every release build and only ships
# rules for the Flutter engine's JNI entry points. Everything below keeps the
# reflection-based lookups the Android dependencies perform at startup, so a
# release APK behaves like the debug build.

# WorkManager opens its own Room database and creates the generated
# implementation reflectively from `RoomDatabase#canonicalName + "_Impl"`.
# R8 obfuscates `androidx.work.impl.WorkDatabase` and `WorkDatabase_Impl` to
# unrelated names, so that lookup throws during
# `androidx.startup.InitializationProvider` and the process dies before Flutter
# runs ("Failed to create an instance of class
# androidx.work.impl.WorkDatabase"). Keeping both class names (and the no-arg
# constructor Room invokes) is what prevents the crash on launch.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keepnames class * extends androidx.room.RoomDatabase
-keepclassmembers class * extends androidx.room.RoomDatabase {
    public <init>();
}

# Room generates DAO adapters and entity helpers whose names are also resolved
# at runtime; keeping the generated database implementation intact covers both.
-keep class androidx.work.impl.WorkDatabase_Impl { *; }

# Workers are instantiated from class names persisted in WorkManager's database,
# so their names and constructors have to survive shrinking.
-keep class * extends androidx.work.ListenableWorker { <init>(...); }
-keepnames class * extends androidx.work.ListenableWorker

# Keep the persistence layer's annotations readable for tooling/debugging.
-keepattributes *Annotation*
