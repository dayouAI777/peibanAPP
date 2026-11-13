# 陪伴 · peibanAPP

一款自用的 AI 虚拟陪伴 App：填一份详细设定，生成一个专属角色，然后像发微信一样聊天；角色会记得你们聊过的事，也会偶尔主动找你说话。

- **大模型**：DeepSeek（`deepseek-chat`，OpenAI 兼容格式）
- **人物参考图**：自己从相册上传，不接文生图服务
- **API Key**：自己在设置页填，只存本机，不需要服务器
- **V1 目标平台**：Android（Dart 代码本身跨端，iOS 目录以后一条命令就能补）
- **定位**：自用 / 小范围分享，**不商用**，不做上架、不做账号体系、不做内容审核后台

> 仓库**已含完整的 Android 平台工程**（`android/`，通知权限与 desugaring 补丁已打好），
> clone 下来装好 Flutter 环境就能直接编译，不用再跑 `flutter create`。
> 本机这套工具链装在 `C:\Users\Administrator\.peiban-tools\`，环境细节见 [打包指南](docs/打包指南.md)。

**已验证的工具链**：Flutter 3.50.0 / Dart 3.14.0 · JDK 21 · Android SDK 36 · Gradle 9.5.0 · AGP 9.3.1。

---

## 快速开始

```bash
cd peibanAPP
flutter pub get

# 出安装包
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk

# 或连真机边看边改（手机开 USB 调试）
flutter run
```

> 换一台新电脑时：按 [打包指南](docs/打包指南.md) 装 Flutter + Android SDK，
> 然后改 `android/local.properties` 里的 `sdk.dir` / `flutter.sdk` 两个路径（该文件不进仓库）。
> **不要重复跑 `flutter create`**，它可能覆盖 `lib/main.dart`；万一跑了，`git checkout -- lib/` 还原。

## 第一次使用

1. 打开 App → 「创建我的陪伴者」，三步填设定（TA 是谁 / 你们俩 / 边界）。
2. 第一步里从相册选一张人物参考图。
3. 「生成 TA」→ 看一眼开场白 → 「就开始聊天吧」。
4. 去「设置」填 DeepSeek API Key（[platform.deepseek.com](https://platform.deepseek.com) 申请），保存。
5. 想让 TA 主动找你，把「偶尔让 TA 主动找我」打开，设好每天条数和时段。

没填 Key 也能先把角色建起来（用本地模板人设），只是还聊不了天。

## 「主动发消息」是怎么做的

这是这个 App 最容易被做复杂的一块，V1 用的是最稳的做法：

```
预约本地通知（不联网、不用服务器）
   ↓ 到了随机时间点，手机弹一条「在吗，刚想到你」
用户点开通知 → 打开 App
   ↓
这一刻才请求 DeepSeek，按人设现场生成一句主动的话，插进聊天记录
```

为什么不在后台直接生成好？因为 iOS 不允许 App 常驻后台偷偷联网，Android 也常被厂商省电策略掐掉，硬做会变成「时灵时不灵」。现在这样两端都能跑，而且每次点开的话都是新鲜的、贴着最近聊天内容的。

通知按未来 7 天滚动重排，时间点在设定时段内随机，不是准点闹钟。设置保存、新建角色、冷启动都会重排一次。

> 国内安卓（小米 / 华为 / OPPO / vivo）如果通知不响，多半是省电策略：去系统设置里给这个 App 开「自启动」+「忽略电池优化」。详见打包指南的报错排查。

## 目录结构

```
peibanAPP/
├── pubspec.yaml / pubspec.lock      依赖清单与锁版本
├── android/                         【已生成、补丁已打好的 Android 工程】
│   ├── app/src/main/AndroidManifest.xml   通知 / 网络权限
│   └── app/build.gradle.kts               desugaring + 签名配置
├── test/widget_test.dart            人设兜底逻辑的冒烟测试
├── lib/
│   ├── main.dart                   入口、路由、通知冷启动判定
│   ├── theme.dart                  配色
│   ├── models/                     【数据模型层】
│   │   ├── companion.dart          角色卡
│   │   ├── message.dart            聊天消息
│   │   └── setup_form.dart         设定表单
│   ├── data/                       【本地存储层】
│   │   ├── db_helper.dart          sqflite：角色 + 聊天记录
│   │   └── prefs.dart              SharedPreferences：Key / 设置
│   ├── services/                   【业务逻辑 + 网络层】
│   │   ├── deepseek.dart           DeepSeek API（人设 / 聊天 / 主动消息）
│   │   ├── persona_builder.dart    人设 prompt 拼接 + 断网兜底
│   │   └── proactive_service.dart  本地通知预约
│   ├── state/
│   │   └── app_state.dart          全局状态，页面只管显示
│   └── pages/                      【页面层】
│       ├── welcome_page.dart       欢迎页
│       ├── setup_page.dart         三步设定页
│       ├── result_page.dart        生成结果页
│       ├── chat_page.dart          聊天页
│       └── settings_page.dart      设置页
└── docs/
    ├── 需求规格说明书.md
    ├── 打包指南.md
    └── Android配置补丁.md
```

## 数据都放哪

| 数据 | 位置 |
|---|---|
| 角色设定、人设、聊天记录 | 本机 SQLite（`peiban.db`） |
| API Key、主动消息设置、随机度 | 本机 SharedPreferences |
| 人物参考图 | 复制到 App 私有目录 `avatars/`，不依赖相册临时路径 |

**没有任何数据出这台手机**，除了聊天时发往 DeepSeek 的那段对话文字（这是大模型服务本身必需的）。

## 小范围分享要注意

把 `app-release.apk` 直接发给朋友装就行。但 **API Key 是各人填各人的**——Key 存在本机，不会跟着 APK 走，对方打开后去设置页填自己的 Key 即可。别把自己的 Key 截图发过去。

## 文档

- [需求规格说明书](docs/需求规格说明书.md) — 八大模块定稿版，含版本规划与页面原型
- [打包指南](docs/打包指南.md) — 环境安装、APK 打包、签名、真机安装、报错排查、iOS 说明
- [Android 配置补丁](docs/Android配置补丁.md) — 已应用的补丁备查；只有从零重建平台目录时才需要照做

## 边界

本仓库只做本地开发与本地打包，不含应用商店上架、资质审核、账号体系、内容审核后台。iOS 打包需要 macOS + Xcode + 苹果开发者账号，Windows 上做不了。
