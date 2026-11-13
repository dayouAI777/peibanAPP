# 陪伴 · peibanAPP

一款自用的 AI 虚拟陪伴 App：填一份详细设定，生成一个专属角色，然后像发微信一样聊天；角色会记得你们聊过的事，也会偶尔主动找你说话。

- **大模型**：DeepSeek（`deepseek-chat`，OpenAI 兼容格式）
- **人物参考图**：自己从相册上传，不接文生图服务
- **API Key**：自己在设置页填，只存本机，不需要服务器
- **V1 目标平台**：Android（Dart 代码本身跨端，iOS 目录以后一条命令就能补）
- **定位**：自用 / 小范围分享，**不商用**，不做上架、不做账号体系、不做内容审核后台

> 本机开发环境没有安装 Flutter SDK，所以仓库里放的是**完整业务源码**，不含 `android/`、`ios/` 平台目录。
> 第一次跑之前按 [docs/打包指南.md](docs/打包指南.md) 执行一条 `flutter create` 生成平台壳即可，两分钟的事。

---

## 快速开始

```bash
# 1. 装好 Flutter SDK 和 Android Studio（见打包指南），然后：
cd peibanAPP

# 2. 生成 Android 平台目录（已有源码不会被删，但建议先 git status 看一眼）
flutter create --platforms=android --project-name peiban_app --org com.dayouai.peiban .

# 3. 按 docs/Android配置补丁.md 改 2 个文件（权限 + desugaring）
# 4. 拉依赖
flutter pub get

# 5. 连上手机跑起来
flutter run
```

> ⚠️ `flutter create` 有时会覆盖 `lib/main.dart`。跑完执行 `git status`，
> 如果 `lib/` 下有文件被改动，用 `git checkout -- lib/` 一键还原即可——源码都在仓库里。

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
├── pubspec.yaml                    依赖清单
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
- [Android 配置补丁](docs/Android配置补丁.md) — `flutter create` 之后要改的两个文件

## 边界

本仓库只做本地开发与本地打包，不含应用商店上架、资质审核、账号体系、内容审核后台。iOS 打包需要 macOS + Xcode + 苹果开发者账号，Windows 上做不了。
