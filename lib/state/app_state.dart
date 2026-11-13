import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/db_helper.dart';
import '../data/prefs.dart';
import '../models/chat_background.dart';
import '../models/companion.dart';
import '../models/life_state.dart';
import '../models/memory_chunk.dart';
import '../models/message.dart';
import '../models/persona_space.dart';
import '../models/speech_profile.dart';
import '../models/style_example.dart';
import '../models/user_note.dart';
import '../services/chat_images.dart';
import '../services/clock_service.dart';
import '../services/context_builder.dart';
import '../services/deepseek.dart';
import '../services/memory_service.dart';
import '../services/mood_service.dart';
import '../services/persona_analyst.dart';
import '../services/proactive_service.dart';
import '../services/speech_profile_service.dart';
import '../services/user_manual.dart';

/// 一次请求要用到的「时间上下文」。
///
/// 必须在把用户这条消息写进 messages **之前**算出来，
/// 否则「距上次说话多久」永远等于 0，她就会以为你们一直在聊。
class _Timing {
  final LifeState life;
  final Duration gap;
  final bool sheSpokeLast;
  final bool overnight;
  final String nowBlock;
  final String gapBlock;

  const _Timing({
    required this.life,
    required this.gap,
    required this.sheSpokeLast,
    required this.overnight,
    required this.nowBlock,
    required this.gapBlock,
  });
}

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

  /// 她这几天的临时安排（旅行 / 加班 / 聚会 / 生病），过期自动失效。
  LifeEvent? lifeEvent;

  /// 她此刻的情绪。0 平静 → 100 爆炸，>75 就冷战不理人。
  MoodState mood = const MoodState();
  bool moodEnabled = true;

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

    moodEnabled = await Prefs.moodEnabled();
    await _refreshLife();
    await _loadMood();

    notifyListeners();
  }

  // ——— 她的时间感 ———

  /// 人设字段解析一次就缓存起来：状态行每 20 秒刷一次，没必要反复解 JSON。
  String _fieldsKey = '';
  Map<String, String> _fieldsCache = const <String, String>{};

  Map<String, String> get _fields {
    final c = companion;
    if (c == null || c.personaSpace.isEmpty) return const <String, String>{};
    if (c.personaSpace == _fieldsKey) return _fieldsCache;
    try {
      _fieldsCache = PersonaSpace.decode(c.personaSpace).fields;
      _fieldsKey = c.personaSpace;
      return _fieldsCache;
    } catch (_) {
      return const <String, String>{};
    }
  }

  /// 每天第一次打开时抽一次「今天有什么特别安排」。
  /// 抽签结果存起来，一天之内不变——不然她一天能去三趟大理。
  Future<void> _refreshLife() async {
    final now = DateTime.now();
    var ev = LifeEvent.decode(await Prefs.lifeEvent());
    if (ev != null && ev.isExpired(now)) ev = null;

    final today = ClockService.dayKey(now);
    final planned = await Prefs.lifePlanDay();
    if (planned != today) {
      final next = ClockService.plan(
        now: now,
        current: ev,
        lastTripMs: await Prefs.lastTripAt(),
        rnd: Random(),
        identity: _fields['identity'] ?? '',
      );
      ev = next;
      await Prefs.setLifePlanDay(today);
      await Prefs.setLifeEvent(next?.encode() ?? '');
      if (next != null && next.isTravel) {
        await Prefs.setLastTripAt(next.startMs);
      }
    }
    lifeEvent = ev;
  }

  /// 读情绪，并让「隔了多久」先作用一次（幂等，冷启动也安全）。
  Future<void> _loadMood() async {
    if (!moodEnabled) {
      mood = const MoodState();
      return;
    }
    mood = MoodState.decode(await Prefs.mood());
    if (messages.isEmpty) {
      mood = const MoodState();
      return;
    }
    final now = DateTime.now();
    final last = DateTime.fromMillisecondsSinceEpoch(messages.last.createdAt);
    final gap = ClockService.gapOf(now, last);
    mood = MoodService.syncWithGap(
      mood,
      gap: gap,
      sheSpokeLast: !messages.last.fromUser,
      overnight: ClockService.looksLikeOvernight(last, now),
      nowMs: now.millisecondsSinceEpoch,
    );
    await Prefs.setMood(mood.encode());
  }

  /// AppBar 上那行字：她在干嘛 / 她在气什么。
  String statusLabel(DateTime now) {
    if (busy) return '正在输入…';
    if (moodEnabled && mood.faceLabel.isNotEmpty) return mood.faceLabel;
    final life = ClockService.describe(
      now: now,
      event: lifeEvent,
      identity: _fields['identity'] ?? '',
      habits: _fields['habits'] ?? '',
    );
    return life.shortStatus;
  }

  /// 拼出「现在几点 / 隔了多久」两块 prompt 文本。
  _Timing _buildTiming(DateTime now, DateTime? last) {
    final life = ClockService.describe(
      now: now,
      event: lifeEvent,
      identity: _fields['identity'] ?? '',
      habits: _fields['habits'] ?? '',
    );
    final gap = last == null
        ? const Duration(days: 9999)
        : now.difference(last);
    final overnight =
        last != null && ClockService.looksLikeOvernight(last, now);
    final sheSpokeLast = messages.isNotEmpty && !messages.last.fromUser;

    final nb = StringBuffer()
      ..writeln('【现在 · 这是真的时间，不是设定】')
      ..writeln('现在是 ${life.stamp}，${life.period}。')
      ..writeln('这个点你大概在：${life.activity}。')
      ..writeln('这就是你当下的处境。凡是提到时间、吃饭、睡觉、上班、下班、周末，'
          '一律以上面为准，不要另编一个时间和状态。');
    for (final r in life.rules) {
      nb.writeln('- $r');
    }

    final gb = StringBuffer();
    if (last == null) {
      gb.writeln('你们还没聊过，这是开头。');
    } else {
      gb.writeln('上一次说话是 ${ClockService.gapPhrase(gap)}'
          '（${ClockService.stampOf(last.toLocal())}）。');
      gb.writeln(ClockService.gapRule(
        d: gap,
        overnight: overnight,
        sheSpokeLast: sheSpokeLast,
      ));
    }

    return _Timing(
      life: life,
      gap: gap,
      sheSpokeLast: sheSpokeLast,
      overnight: overnight,
      nowBlock: nb.toString().trim(),
      gapBlock: gb.toString().trim(),
    );
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
    mood = const MoodState();
    await Prefs.setMood('');
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

  Future<String> _systemPrompt(
    Companion c, {
    required _Timing timing,
    String moodBlock = '',
  }) async =>
      ContextBuilder.buildSystem(
        persona: c.persona,
        notes: notes,
        chunks: chunks,
        window: contextWindow,
        emojiLevel: await Prefs.emojiLevel(),
        speech: speech,
        appearance: _appearanceOf(c),
        styleExamples: styleExamples,
        nowBlock: timing.nowBlock,
        gapBlock: timing.gapBlock,
        moodBlock: moodBlock,
      );

  Future<void> send(String text, {String? imagePath}) async {
    final c = companion;
    final content = text.trim();
    final img = imagePath ?? '';
    if (c == null || busy) return;
    if (content.isEmpty && img.isEmpty) return;

    final now = DateTime.now();
    // 关键：这里必须在插入新消息之前取上一条，时间差才是真的
    final last = messages.isEmpty
        ? null
        : DateTime.fromMillisecondsSinceEpoch(messages.last.createdAt);
    final timing = _buildTiming(now, last);

    // 情绪先被「隔了多久」影响一次，再被这条消息本身影响
    var m = moodEnabled
        ? MoodService.syncWithGap(
            mood,
            gap: timing.gap,
            sheSpokeLast: timing.sheSpokeLast,
            overnight: timing.overnight,
            nowMs: now.millisecondsSinceEpoch,
          )
        : const MoodState();

    final userLines =
        messages.where((x) => x.fromUser).map((x) => x.content).toList();
    final recent = userLines.length <= 4
        ? userLines
        : userLines.sublist(userLines.length - 4);

    final res = moodEnabled
        ? MoodService.afterUserMessage(m, text: content, recentUserTexts: recent)
        : MoodResult(mood: m);

    // 这条消息进来之前她是不是已经在冷战
    final wasCold = moodEnabled && m.isCold;
    m = res.mood;

    final userMsg = ChatMessage(
      companionId: c.id!,
      role: 'user',
      content: content,
      createdAt: now.millisecondsSinceEpoch,
      imagePath: img,
    );
    await DbHelper.instance.insertMessage(userMsg);
    messages.add(userMsg);
    _userMessageCount++;
    error = null;

    // ——— 冷战：不理人，最多甩个表情 ———
    if (moodEnabled && m.isCold) {
      final turns = m.coldTurns + 1;
      final sticker =
          MoodService.coldSticker(coldTurns: turns, coaxed: res.coaxed);
      mood = m.copyWith(coldTurns: turns);
      await Prefs.setMood(mood.encode());
      if (sticker != null) {
        final sm = ChatMessage(
          companionId: c.id!,
          role: 'assistant',
          content: sticker,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        await DbHelper.instance.insertMessage(sm);
        messages.add(sm);
      }
      notifyListeners();
      return;
    }

    // 刚从冷战里被哄：先给一个松动的表情，这一句还是不开口。
    // 这样「生气 → 哄 → 软化 → 开口」才有过程，不是一句道歉就翻篇。
    if (moodEnabled && wasCold && res.coaxed) {
      mood = m.copyWith(coldTurns: m.coldTurns + 1);
      await Prefs.setMood(mood.encode());
      final soften = ChatMessage(
        companionId: c.id!,
        role: 'assistant',
        content: '🥺',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      await DbHelper.instance.insertMessage(soften);
      messages.add(soften);
      notifyListeners();
      return;
    }

    // 从冷战里走出来，轮次清零，下次再冷从 😤 开始
    if (m.coldTurns != 0) m = m.copyWith(coldTurns: 0);
    mood = m;
    await Prefs.setMood(mood.encode());

    busy = true;
    notifyListeners();

    try {
      final moodBlock = moodEnabled
          ? MoodService.promptBlock(m, justRecovered: res.justRecovered)
          : '';
      final answer = await _llm.reply(
        apiKey: await Prefs.apiKey(),
        system: await _systemPrompt(c, timing: timing, moodBlock: moodBlock),
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

    // 冷战期间不主动找你——这才是真生气
    if (moodEnabled && mood.isCold) return;

    final now = DateTime.now();
    final last = messages.isEmpty
        ? null
        : DateTime.fromMillisecondsSinceEpoch(messages.last.createdAt);
    final timing = _buildTiming(now, last);

    busy = true;
    notifyListeners();
    try {
      final line = await _llm.proactiveLine(
        apiKey: key,
        system: await _systemPrompt(
          c,
          timing: timing,
          moodBlock: moodEnabled ? MoodService.promptBlock(mood) : '',
        ),
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
    // 先刷新界面再落盘：滑杆拖动时体感是跟手的，不等磁盘写完
    notifyListeners();
    await Prefs.setChatBackground(b);
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
    moodEnabled = await Prefs.moodEnabled();
    if (companion != null) {
      messages = await DbHelper.instance
          .messages(companion!.id!, limit: contextWindow);
      await _loadMood();
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
    // 记录清空了，气也该顺了——不然她还在为一件已经不存在的旧账冷战
    mood = const MoodState();
    await Prefs.setMood('');
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
    mood = const MoodState();
    lifeEvent = null;
    await Prefs.setMood('');
    await Prefs.setLifeEvent('');
    error = null;
    notifyListeners();
  }

  void dismissError() {
    error = null;
    notifyListeners();
  }
}
