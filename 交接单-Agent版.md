# 陪伴 App · 工作交接单（Agent 接手版）

> **给接手的 Agent**：这是一份可以直接执行的交接单。你的第一件事是把本文件和同目录的
> `交接文档.md`（更全的技术细节、坑位备忘）都读完，再动手做任何事。
> 交接时间：2026-11-17 · 交接人：上一个开发会话（阿Q）

---

## 0. 一句话使命

维护并迭代「陪伴」App——Flutter 安卓 AI 聊天伴侣，接 DeepSeek API，
仓库 `github.com/dayouAI777/peibanAPP`（公开），本地 SQLite 存全部用户数据。

## 1. 现状快照（2026-11-17）

| 项 | 状态 |
|---|---|
| 最新版本 | **V1.6.3 / build 15** 已发布（分架构 APK，升级清单在仓库根 version.json） |
| 本机同步 | ✅ 已 `git pull` 对齐远端（本地曾分叉，已 `reset --hard origin/main`） |
| 签名 | ✅ 新 key 已在本机安置并**实打包验签通过**（指纹 e6a72fee… 与密钥说明一致） |
| 代码健康 | ✅ analyze 0 error；**27 个测试全过** |
| 测试规模 | 27 个（V1.4 时代只有 5 个，后续补齐；改代码必须保持全绿） |

版本演进速览：1.1 人设系统 → 1.3 稳定性 → 1.4 图片识别/去AI腔 → 1.5 手工纠正+背景 →
1.6 时间感/情绪状态机/静默升级/多源下载/正式签名。逐版明细见 `交接文档.md` 第二节。

## 2. 本机（公司机）环境，已配好可直接构建

| 组件 | 路径 |
|---|---|
| Flutter/JDK/SDK/Gradle | `C:/Users/Administrator/.peiban-tools/`（env.sh 一键设全） |
| 签名 jks | `C:/Users/Administrator/.peiban-keys/peiban-signing.jks` |
| key.properties | `android/key.properties`（已配好，**不进 git**） |
| 推送/发版脚本 | `C:/Users/Administrator/.peiban-tools/gh_api_push.py`、`gh_release_upload.py` |

家里机（C:\dev\flutter 那套）的环境写法见 `交接文档.md` 第三节。新机器照那个清单重建。

构建命令（Git Bash）：

```bash
cd peibanAPP
source ~/.peiban-tools/env.sh    # 家里机用交接文档里的 export 四件套
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY   # 代理会拦测试和 gradle，必须 unset
flutter analyze        # 0 error 才继续（18 个 info 级 deprecation 噪音可无视）
flutter test           # 27 个全过才继续
flutter build apk --release --split-per-abi   # 产物 build/app/outputs/flutter-apk/
```

## 3. 签名铁律（最高优先级，踩过一次大坑）

1. jks 和口令**永不进仓库**（公开仓库！旧 key 就是这么泄露作废的，V1.6.1 全员卸载重装）
2. 口令和指纹在用户桌面的 `陪伴App-签名密钥.zip` 里（含 签名说明.txt），不在任何代码/文档里
3. 永不重新生成这把 key——一换，所有设备卸载重装、本地数据全丢
4. 验签命令：
   `apksigner verify --print-certs <apk>`，SHA-256 须为
   `E6:A7:2F:EE:B2:0B:7A:FE:2F:98:60:CE:65:A4:50:83:21:8A:06:95:0C:33:22:BA:FA:82:7D:4A:E0:4E:F6:83`

## 4. 发新版本 SOP（照抄，别创新）

1. `pubspec.yaml` 升 version（如 `1.6.4+16`；**注意**：分架构打包后 versionCode 会被加 ABI 偏移，
   升级判断必须先比版本名再比归一化 build——V1.6.3 刚修完这个，别退回去）
2. `version.json` 升 version/build/apk_url/changelog（用户在 App 里看到的就是这个）
3. commit
4. 推送：`python ~/.peiban-tools/gh_api_push.py`（GitHub contents API 传对象字节，本地/远端 SHA 不同属正常）
5. 发版：`python ~/.peiban-tools/gh_release_upload.py vX.Y.Z <arm64-v8a apk 绝对路径>`
6. 桌面交付：**不要拷 APK 给用户**——用户直接 App 内检查升级（2026-11-13 明令）

## 5. 已定稿的用户规矩（锁死，违反会被纠正）

- 人设（persona）定稿后**永不修改**，只能删除重建；只有头像/昵称可改
- 不要自检改稿、不要反复重试美化结果——交付原始结果让用户挑
- 定下的口径要「锁死、以后照办」，写进记忆而不是口头答应
- API Key 严禁进仓库/文档/日志
- 用户会亲自实测并贴截图纠错，说「修好了」之前先自己验过（V1.5.1/1.6.2/1.6.3 都是
  「以为修好了实际没好」的教训：消息落库要回填 id、界面弹成功 ≠ 逻辑成功）

## 6. 进行中/待办的路线图

**A. Agent 端聊天（上次讨论停在待确认，需求草案已给过）**
- 用户想在电脑聊天界面里也能跟"她"聊
- V1：App 加「导出人设档案」按钮（人设 12 维+行为手册+说话方式+记忆摘要 → JSON）
  → 电脑端做成专属 Agent 角色加载档案。局限：导出后两边记忆各自生长
- V2：记忆上云，手机/Agent 共用一份（需账号+云存储，工程 2~3 天）
- V3：语音/发图/主动消息全打通
- 等用户确认走哪版，未确认前不写代码

**B. TTS 语音（讨论很多轮，尚未动手）**
- 关键约束：素材只有 **1 分钟 AI 合成声音**（无真人录音）；云端克隆路线因
  "AI 角色无法过真人授权验证"**已被用户否掉**
- 剩余两条本地路线：
  1. **ZipVoice 零样本克隆**（sherpa-onnx 有安卓 SDK，参考音频即用，免训练免验证）
     ——最新最没把握，先在电脑上试音再谈上手机
  2. **蒸馏训练**：用该 AI 音色批量合成 1.5h 语料 → VITS 单音色微调（4060 8G 可跑，
     batch 压 8~12 + fp16，约 12~24h）→ ONNX 上手机。音质上限=原音色再降一档
- 用户显卡：RTX 4060 8G；先试音后决策，别直接开训

**C. 曾讨论、已被替代/搁置**
- 去 AI 腔策略三/四（人设语言习惯维度、说话风格趋同）→ V1.5.0 的手工纠正功能是低成本替代，
  先观察，不够再上
- iOS 端：完全没做，用户没提需求
- 从零训 TTS 底座 / LoRA 生图：讨论过，判定不现实/不适用

## 7. 接手后第一步清单

1. 读 `交接文档.md`（221 行，全是细节和坑位，一条别跳）
2. 确认本机构建链路通：analyze + test + 一次 release 构建验签
3. 用户提出新需求时：按 mobile-app-dev 专家流程先出需求草案，确认后再写码
4. 改完代码：27 个测试必须全绿 + 自己真验过逻辑（弹窗成功≠逻辑成功）
5. 发版走第 4 节 SOP，一字不改

## 8. 历史坑位速查（详见交接文档第九节，这里只列新增）

- `--split-per-abi` 的 versionCode 有 ABI 偏移，比较版本先比名字（V1.6.3 教训）
- 内存消息没有 id，落库后必须回填，否则「存范例」类功能静默失效（V1.6.2 教训）
- 清单竞速要挑 build 最大的源，防 CDN 吐旧版（V1.6.1 教训）
- 测试挂 WebSocketException ≠ 代码错，是代理拦了本地端口，unset 代理再跑
- 分析器的 18 个 info 是 deprecation 噪音（package:flutter/material 被标记过时），
  已确认无害，别为清零去大改 import
