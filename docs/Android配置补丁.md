# Android 配置补丁（已应用，备查）

> 仓库里的 `android/` 目录**已经打好下面这两处补丁**，正常编译不用再动。
> 只有在从零重建平台目录（重跑 `flutter create`）时才需要照做。

`flutter create` 生成平台目录后，只需要改 **两个文件**。不改的话：通知可能不弹、Gradle 可能编译失败。

---

## 1. `android/app/src/main/AndroidManifest.xml`

在 `<manifest ...>` 标签下面、`<application>` 标签**之前**，加这几行：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
<uses-permission android:name="android.permission.VIBRATE" />
```

完整位置示意：

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- ↓ 加在这里 ↓ -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.VIBRATE" />

    <application ...>
        ...
    </application>
</manifest>
```

> `INTERNET` 在 Flutter 的 debug/profile 模板里有、release 里常被漏掉，手动加上最保险。
> `POST_NOTIFICATIONS` 是 Android 13（API 33）以上发通知必须的，代码里已经调了运行时申请，但清单里不声明就不会弹授权框。

### 选图报错时再补这一行

`image_picker` 一般走系统照片选择器，不需要读图权限。如果你手机上报权限错误，再补：

```xml
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
```

---

## 2. `android/app/build.gradle.kts`（新版 Flutter，Kotlin DSL）

### (a) 开 desugaring

找到 `compileOptions { ... }`，加一行 `isCoreLibraryDesugaringEnabled = true`：

```kotlin
android {
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true   // ← 加这行
    }

    defaultConfig {
        minSdk = 23        // ← 建议 23（Flutter 默认 21 也能跑，23 更稳）
        ...
    }
}
```

### (b) 文件末尾加依赖

```kotlin
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

> `flutter_local_notifications` 17.x 依赖 Java 8 时间 API 的脱糖支持，不加会报
> `Dependency ':flutter_local_notifications' requires coreLibraryDesugaring to be enabled`。

### 如果你的项目是旧版 `build.gradle`（Groovy，不是 .kts）

```groovy
android {
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_11
        targetCompatibility JavaVersion.VERSION_11
        coreLibraryDesugaringEnabled true      // ← 加这行
    }
    defaultConfig {
        minSdk 23                              // ← 建议 23
    }
}

dependencies {
    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'   // ← 加这行
}
```

---

## 改完验证

```bash
flutter clean
flutter pub get
flutter run
```

能跑起来、且第一次进聊天页时弹出通知授权框，就说明两处都改对了。
