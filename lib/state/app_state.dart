import 'package:flutter/foundation.dart';

import '../data/db_helper.dart';
import '../data/prefs.dart';
import '../models/companion.dart';
import '../models/message.dart';
import '../models/setup_form.dart';
import '../services/deepseek.dart';
import '../services/persona_builder.dart';
import '../services/proactive_service.dart';

/// 全局状态：当前角色、聊天记录、加载中、报错。
/// 页面只负责显示和点按钮，所有「脏活」都在这里。
class AppState extends ChangeNotifier {
  final DeepSeekService _llm = DeepSeekService();

  Companion? companion;
  List<ChatMessage> messages = [];
  bool busy = false;
  String? error;

  Future<void> load() async {
    companion = await DbHelper.instance.firstCompanion();
    messages = companion == null
        ? []
        : await DbHelper.instance.messages(companion!.id!);
    notifyListeners();
  }

  /// 设定页点「生成 TA」→ 先出草稿，不落库。
  Future<GeneratedPersona> generateDraft(SetupForm form) async {
    return _llm.buildPersona(apiKey: await Prefs.apiKey(), form: form);
  }

  /// 结果页点「就开始聊天吧」→ 真正落库、发第一句、排主动消息。
  Future<Companion> saveCompanion(
      SetupForm form, GeneratedPersona draft) async {
    await DbHelper.instance.deleteEverything();
    final id = await DbHelper.instance.insertCompanion(
      Companion(
        name: form.name.trim().isEmpty ? 'TA' : form.name.trim(),
        persona: draft.persona,
        greeting: draft.greeting,
        avatarPath: form.avatarPath,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    final c = (await DbHelper.instance.firstCompanion())!;
    final first = ChatMessage(
      companionId: id,
      role: 'assistant',
      content: draft.greeting,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await DbHelper.instance.insertMessage(first);

    companion = c;
    messages = [first];
    error = null;
    notifyListeners();

    await ProactiveService.reschedule(name: c.name);
    return c;
  }

  List<Map<String, String>> _recent(int limit) {
    final start = messages.length > limit ? messages.length - limit : 0;
    return messages
        .sublist(start)
        .where((m) => m.content.trim().isNotEmpty)
        .map((m) => {
              'role': m.fromUser ? 'user' : 'assistant',
              'content': m.content,
            })
        .toList();
  }

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
    busy = true;
    error = null;
    notifyListeners();

    try {
      final answer = await _llm.reply(
        apiKey: await Prefs.apiKey(),
        persona: c.persona,
        history: _recent(20),
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
  }

  /// 从通知点进来时调一次，生成一条「角色主动找你」的消息。
  /// 失败就静默跳过——主动消息不该变成一次报错打扰。
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
        persona: c.persona,
        history: _recent(12),
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

  Future<void> applySettings() async {
    if (companion != null) {
      await ProactiveService.reschedule(name: companion!.name);
    }
  }

  Future<void> clearMessages() async {
    final c = companion;
    if (c == null) return;
    await DbHelper.instance.clearMessages(c.id!);
    messages = [];
    error = null;
    notifyListeners();
  }

  Future<void> deleteCompanion() async {
    await DbHelper.instance.deleteEverything();
    await ProactiveService.cancelAll();
    companion = null;
    messages = [];
    error = null;
    notifyListeners();
  }

  void dismissError() {
    error = null;
    notifyListeners();
  }
}
