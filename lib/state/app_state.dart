import 'package:flutter/foundation.dart';

import '../data/db_helper.dart';
import '../data/prefs.dart';
import '../models/companion.dart';
import '../models/memory_chunk.dart';
import '../models/message.dart';
import '../models/persona_space.dart';
import '../models/speech_profile.dart';
import '../models/user_note.dart';
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
  SpeechProfile speech = SpeechProfile.empty();
  bool busy = false;
  bool configured = false;
  int contextWindow = ContextBuilder.defaultWindow;
  String? error;

  int _userMessageCount = 0;
  bool _maintaining = false;

  Future<void> load() async {
    configured = await Prefs.configured();
    contextWindow = await Prefs.contextLimit();
    companion = await DbHelper.instance.firstCompanion();
    messages = companion == null
        ? []
        : await DbHelper.instance.messages(companion!.id!, limit: contextWindow);
    chunks = companion == null
        ? []
        : await DbHelper.instance.memoryChunks(companion!.id!);
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
    _userMessageCount = 0;
    error = null;
    notifyListeners();

    await ProactiveService.reschedule(name: companion!.name);
    return companion!;
  }

  // ——— 聊天 ———

  Future<String> _systemPrompt(Companion c) async => ContextBuilder.buildSystem(
        persona: c.persona,
        notes: notes,
        chunks: chunks,
        window: contextWindow,
        emojiLevel: await Prefs.emojiLevel(),
        speech: speech,
      );

  Future<void> send(String text) async {
    final c = companion;
    final content = text.trim();
    if (c == null || content.isEmpty || busy) return;

    final userMsg = ChatMessage(
      companionId: c.id!,
      role: 'user',
      content: content,
      createdAt: DateTime.now().millisecondsSinceEpoch,
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
        history: ContextBuilder.buildTurns(messages),
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
        history: ContextBuilder.buildTurns(messages),
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

  // ——— 设置 / 数据管理 ———

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
    _userMessageCount = 0;
    error = null;
    notifyListeners();
  }

  void dismissError() {
    error = null;
    notifyListeners();
  }
}
