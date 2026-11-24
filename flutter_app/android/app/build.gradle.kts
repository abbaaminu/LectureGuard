import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.lectureguard.lecture_guard"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.lectureguard.lecture_guard"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Never ship this APK: a debug-signed release has a different
                // signature from the Play upload key, so updates fail to install
                // and the artifact cannot be uploaded. Create android/key.properties
                // (see the README) before publishing. Printed at quiet level so
                // the message survives `flutter build`'s `-q` Gradle invocation.
                println(
                    "WARNING: LectureGuard android/key.properties is missing; the release " +
                        "APK is signed with the debug key and must not be published.",
                )
                signingConfigs.getByName("debug")
            }
            // R8 runs for every Flutter release build. The Flutter engine rules
            // are appended by the Flutter Gradle plugin; these app rules keep the
            // reflection-based Android dependencies (Room/WorkManager) working.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // `LectureGuardApplication` implements `androidx.work.Configuration.Provider`
    // so WorkManager is created on demand instead of in
    // `androidx.startup.InitializationProvider`. The Flutter workmanager plugin
    // depends on WorkManager with `implementation`, so it is not on this
    // module's compile classpath; declare the same artifact (and version the
    // plugin resolves, see workmanager/android/build.gradle) to reach the API.
    implementation("androidx.work:work-runtime:2.9.0")
}

flutter {
    source = "../.."
}