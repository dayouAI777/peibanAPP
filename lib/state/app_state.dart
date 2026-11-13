import 'package:flutter/foundation.dart';

import '../data/db_helper.dart';
import '../data/prefs.dart';
import '../models/chat_background.dart';
import '../models/companion.dart';
import '../models/memory_chunk.dart';
import '../models/message.dart';
import '../models/persona_space.dart';
import '../models/speech_profile.dart';
import '../models/style_example.dart';
import '../models/user_note.dart';
import '../services/chat_images.dart';
import '../services/context_builder.dart';
import '../services/deepseek.dart';
import '../services/memory_service.dart';
import '../services/persona_analyst.dart';
import '../services/proactive_service.dart';
import '../services/speech_profile_service.dart';
import '../services/user_manual.dart';

/// 全局状态。页面只管显示和点按钮，脏活都在这里。
class AppState extends ChangeNotifier {
  final DeepSeekService _llm = DeepSeekService();
  final PersonaAnalyst _analyst = PersonaAnalyst();
  final MemoryService _memory = MemoryService();
  final UserManualService _manual = UserManualService();
  final SpeechProfileService _speechService = SpeechProfileService();

  Companion? companion;
  List<ChatMessage> messages = [];
  List<UserNote> notes = [];
  List<MemoryChunk> chunks = [];

  /// 用户亲手改过的「她该这么说」范例，直接进 system prompt。
  List<StyleExample> styleExamples = [];
  SpeechProfile speech = SpeechProfile.empty();
  ChatBackground chatBg = ChatBackground.initial;
  bool busy = false;
  bool configured = false;
  int contextWindow = ContextBuilder.defaultWindow;
  String? error;

  int _userMessageCount = 0;
  bool _maintaining = false;

  Future<void> load() async {
    configured = await Prefs.configured();
    contextWindow = await Prefs.contextLimit();
    chatBg = await Prefs.chatBackground();
    companion = await DbHelper.instance.firstCompanion();
    messages = companion == null
        ? []
        : await DbHelper.instance.messages(companion!.id!, limit: contextWindow);
    chunks = companion == null
        ? []
        : await DbHelper.instance.memoryChunks(companion!.id!);
    styleExamples = companion == null
        ? []
        : await DbHelper.instance.styleExamples(companion!.id!);
    notes = await DbHelper.instance.userNotes();
    try {
      final raw = await Prefs.speechProfile();
      if (raw.isNotEmpty) speech = SpeechProfile.decode(raw);
    } catch (_) {
      speech = SpeechProfile.empty();
    }
    notifyListeners();
  }

  /// 旧版本（v1）创建的人设没有「人设空间」，按新规则必须删除重建。
  bool get needsRebuild => companion != null && !companion!.hasPersonaSpace;

  // ——— 配置门禁 ———

  Future<void> testConnection(String key) async {
    await _llm.testConnection(key);
  }

  Future<void> markConfigured(String key) async {
    await Prefs.setApiKey(key);
    await Prefs.setConfigured(true);
    configured = true;
    notifyListeners();
  }

  // ——— 人设：唯一、定稿不可改 ———

  Future<PersonaAnalysis> analyzePersona(
      String rawInput, PersonaSpace current) async {
    return _analyst.analyze(
      apiKey: await Prefs.apiKey(),
      rawInput: rawInput,
      current: current,
    );
  }

  Future<Companion> finalizePersona(
      PersonaSpace space, String avatarPath) async {
    final finalized = await _analyst.finalize(
      apiKey: await Prefs.apiKey(),
      space: space,
    );

    final name = (finalized.fields['name'] ?? '').trim().isEmpty
        ? 'TA'
        : finalized.fields['name']!.trim();

    await DbHelper.instance.deleteEverything();
    final id = await DbHelper.instance.insertCompanion(Companion(
      name: name,
      persona: finalized.systemPrompt,
      greeting: finalized.greeting,
      avatarPath: avatarPath,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      personaSpace: finalized.encode(),
    ));

    final first = ChatMessage(
      companionId: id,
      role: 'assistant',
      content: finalized.greeting,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await DbHelper.instance.insertMessage(first);

    companion = (await DbHelper.instance.firstCompanion())!;
    messages = [first];
    chunks = [];
    notes = [];
    styleExamples = [];
    _userMessageCount = 0;
    error = null;
    notifyListeners();

    await ProactiveService.reschedule(name: companion!.name);
    return companion!;
  }

  // ——— 聊天 ———

  /// 人设里的外貌描述：让她知道"自己长什么样"，认照片不认错人。
  String _appearanceOf(Companion c) {
    if (c.personaSpace.isEmpty) return '';
    try {
      return PersonaSpace.decode(c.personaSpace).fields['appearance'] ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 头像压成的定妆照 data url（有头像才给，失败返回 null 走纯文字描述）。
  Future<String?> _selfieUrl(Companion c) async {
    if (c.avatarPath.isEmpty) return null;
    return ChatImages.instance.selfieDataUrl(c.avatarPath);
  }

  Future<String> _systemPrompt(Companion c) async => ContextBuilder.buildSystem(
        persona: c.persona,
        notes: notes,
        chunks: chunks,
        window: contextWindow,
        emojiLevel: await Prefs.emojiLevel(),
        speech: speech,
        appearance: _appearanceOf(c),
        styleExamples: styleExamples,
      );

  Future<void> send(String text, {String? imagePath}) async {
    final c = companion;
    final content = text.trim();
    final img = imagePath ?? '';
    if (c == null || busy) return;
    if (content.isEmpty && img.isEmpty) return;

    final userMsg = ChatMessage(
      companionId: c.id!,
      role: 'user',
      content: content,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      imagePath: img,
    );
    await DbHelper.instance.insertMessage(userMsg);
    messages.add(userMsg);
    _userMessageCount++;
    busy = true;
    error = null;
    notifyListeners();

    try {
      final answer = await _llm.reply(
        apiKey: await Prefs.apiKey(),
        system: await _systemPrompt(c),
        history: await ContextBuilder.buildTurns(
          messages,
          selfieUrl: await _selfieUrl(c),
        ),
        temperature: await Prefs.temperature(),
      );
      final botMsg = ChatMessage(
        companionId: c.id!,
        role: 'assistant',
        content: answer,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      await DbHelper.instance.insertMessage(botMsg);
      messages.add(botMsg);
    } catch (e) {
      error = e.toString();
    } finally {
      busy = false;
      notifyListeners();
    }

    // 压缩旧对话、评审行为手册，都在后台做，不挡回复
    _backgroundMaintenance();
  }

  Future<void> _backgroundMaintenance() async {
    if (_maintaining || companion == null) return;
    _maintaining = true;
    try {
      final key = await Prefs.apiKey();
      if (key.trim().isEmpty) return;

      await _memory.compressIfNeeded(
          apiKey: key, companionId: companion!.id!);
      chunks = await DbHelper.instance.memoryChunks(companion!.id!);

      if (await Prefs.manualEnabled() &&
          _userMessageCount % UserManualService.reviewEvery == 0) {
        final start =
            messages.length > 24 ? messages.length - 24 : 0;
        final added = await _manual.review(
          apiKey: key,
          recent: messages.sublist(start),
        );
        if (added > 0) notes = await DbHelper.instance.userNotes();
      }

      // 说话方式：后台静默学习，不弹窗、不打扰、失败静默
      if (_userMessageCount % SpeechProfileService.reviewEvery == 0) {
        final start = messages.length > 24 ? messages.length - 24 : 0;
        final userLines = messages
            .sublist(start)
            .where((m) => m.fromUser)
            .map((m) => m.content.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        final learned = await _speechService.review(
          apiKey: key,
          userLines: userLines,
          current: speech,
        );
        if (learned.samples != speech.samples) {
          speech = learned;
          await Prefs.setSpeechProfile(learned.encode());
        }
      }
      notifyListeners();
    } catch (_) {
      // 后台维护失败不打扰用户
    } finally {
      _maintaining = false;
    }
  }

  /// 从通知点进来时，现场生成一条「TA 主动找你」的消息。
  Future<void> generateProactiveMessage() async {
    final c = companion;
    if (c == null || busy) return;
    final key = await Prefs.apiKey();
    if (key.trim().isEmpty) return;

    busy = true;
    notifyListeners();
    try {
      final line = await _llm.proactiveLine(
        apiKey: key,
        system: await _systemPrompt(c),
        history: await ContextBuilder.buildTurns(
          messages,
          selfieUrl: await _selfieUrl(c),
        ),
        temperature: await Prefs.temperature(),
      );
      final m = ChatMessage(
        companionId: c.id!,
        role: 'assistant',
        content: line,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        isProactive: 1,
      );
      await DbHelper.instance.insertMessage(m);
      messages.add(m);
    } catch (_) {
      // 静默
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  // ——— 亲手改她的说法 ———

  /// 长按她的某条消息 → 用户写出「她本来该这么说」。
  ///
  /// 存下来的是具体范例（触发句 → 错答 → 正答），会进 system prompt 当示范；
  /// [replaceMessage] 为真时顺手把这条历史消息也换成用户写的版本，
  /// 这样上下文里留着的也是对的，而不是让她继续照着自己的错话往下聊。
  Future<void> correctReply({
    required ChatMessage msg,
    required String preferred,
    bool replaceMessage = true,
  }) async {
    final c = companion;
    final id = msg.id;
    final text = preferred.trim();
    if (c == null || id == null || text.isEmpty) return;

    // 触发句：这条之前最近一句用户说的话
    String trigger = '';
    final at = messages.indexWhere((m) => m.id == id);
    if (at > 0) {
      for (int i = at - 1; i >= 0; i--) {
        if (messages[i].fromUser) {
          trigger = messages[i].content.trim();
          break;
        }
      }
    }

    final original = msg.content.trim();
    // 同一条原话 + 同一个改法只记一次，避免反复长按把 prompt 塞满重复项
    final dup = styleExamples.any(
        (e) => e.original == original && e.preferred == text);
    if (!dup) {
      await DbHelper.instance.insertStyleExample(StyleExample(
        companionId: c.id!,
        trigger: trigger,
        original: original,
        preferred: text,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      styleExamples = await DbHelper.instance.styleExamples(c.id!);
    }

    if (replaceMessage) {
      await DbHelper.instance.updateMessageContent(id, text);
      if (at >= 0) {
        messages[at] = ChatMessage(
          id: msg.id,
          companionId: msg.companionId,
          role: msg.role,
          content: text,
          createdAt: msg.createdAt,
          isProactive: msg.isProactive,
          imagePath: msg.imagePath,
        );
      }
    }
    notifyListeners();
  }

  Future<void> deleteStyleExample(int id) async {
    await DbHelper.instance.deleteStyleExample(id);
    if (companion != null) {
      styleExamples = await DbHelper.instance.styleExamples(companion!.id!);
    }
    notifyListeners();
  }

  // ——— 设置 / 数据管理 ———

  Future<void> setChatBackground(ChatBackground b) async {
    chatBg = b;
    await Prefs.setChatBackground(b);
    notifyListeners();
  }

  /// 只改外观：头像 + 昵称。性格字段绝不触碰。
  Future<void> updateAppearance({
    required String name,
    required String avatarPath,
  }) async {
    final c = companion;
    if (c == null || c.id == null) return;
    final newName = name.trim().isEmpty ? c.name : name.trim();
    await DbHelper.instance.updateAppearance(
      id: c.id!,
      name: newName,
      avatarPath: avatarPath,
    );
    companion = c.withAppearance(name: newName, avatarPath: avatarPath);
    notifyListeners();
    await ProactiveService.reschedule(name: newName);
  }

  Future<void> applySettings() async {
    contextWindow = await Prefs.contextLimit();
    if (companion != null) {
      messages = await DbHelper.instance
          .messages(companion!.id!, limit: contextWindow);
      await ProactiveService.reschedule(name: companion!.name);
    }
    notifyListeners();
  }

  Future<void> refreshNotes() async {
    notes = await DbHelper.instance.userNotes();
    notifyListeners();
  }

  Future<void> clearMessages() async {
    final c = companion;
    if (c == null) return;
    await DbHelper.instance.clearMessages(c.id!);
    messages = [];
    chunks = [];
    _userMessageCount = 0;
    error = null;
    notifyListeners();
  }

  /// 删除角色 = 清空人设、聊天、摘要、行为手册，回到「重建人设」。
  /// 配置（API Key / 测试结果）保留，不用重测。
  Future<void> deleteCompanion() async {
    await DbHelper.instance.deleteEverything();
    await ProactiveService.cancelAll();
    companion = null;
    messages = [];
    chunks = [];
    notes = [];
    styleExamples = [];
    _userMessageCount = 0;
    error = null;
    notifyListeners();
  }

  void dismissError() {
    error = null;
    notifyListeners();
  }
}
