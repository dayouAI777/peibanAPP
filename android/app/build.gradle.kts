import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名从 android/key.properties 读，**key 文件不进仓库**（由持有者自己带、自己分发）。
// 换电脑要做的：把 peiban-signing.jks 放好，再照 key.properties 的格式写一份。
val keyPropsFile = rootProject.file("key.properties")
val keyProps = Properties().apply {
    if (keyPropsFile.exists()) {
        keyPropsFile.inputStream().use { load(it) }
    }
}
val signingReady = keyProps.getProperty("storeFile")?.isNotBlank() == true

// 只在真的要打 release 包时报错，别把 debug 构建和 flutter run 一起挡死。
val buildingRelease = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true)
}
if (!signingReady && buildingRelease) {
    throw GradleException(
        "找不到发布签名配置：请在 android/ 下建 key.properties，" +
            "写 storeFile / storePassword / keyAlias / keyPassword 四项。" +
            "签名文件不在仓库里，要单独拿。"
    )
}

android {
    namespace = "com.dayouai.peiban.peiban_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 需要 Java 8 时间 API 脱糖
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dayouai.peiban.peiban_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (signingReady) {
            create("peiban") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 签名文件**不进仓库**，从 android/key.properties 指定的位置读（见文件头的检查）。
            // 血泪教训：以前用 ~/.android/debug.keystore，换电脑 debug key 会重新生成，
            // 签出来的包跟手机上那个签名不一致，安装时报「应用未安装」，只能卸载重装、数据全丢。
            // 现在这把 key 从 1.6.1 起固定，持有者自己保管，别再重新生成。
            signingConfig = if (signingReady) signingConfigs.getByName("peiban") else null
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
