plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.lanpair.lanpair"
    compileSdk {
        version = release(37) { minorApiLevel = 0 }
    }
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.lanpair.lanpair"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 37
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        val keystorePath = System.getenv("LANPAIR_KEYSTORE_PATH")
        if (!keystorePath.isNullOrBlank()) {
            create("distribution") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("LANPAIR_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("LANPAIR_KEY_ALIAS")
                keyPassword = System.getenv("LANPAIR_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // A missing distribution keystore produces an unsigned artifact, never a debug-signed release.
            signingConfig = signingConfigs.findByName("distribution")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
