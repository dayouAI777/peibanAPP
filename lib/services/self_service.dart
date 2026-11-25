import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../data/prefs.dart';
import '../models/journal.dart';
import '../models/persona_space.dart';
import '../models/self_models.dart';
import 'capability.dart';
import 'deepseek.dart';
import 'quota_gate.dart';
import 'self_prompt.dart';

/// R2 自我认知的**有副作用编排层**（设计 T04）：重蒸 + 速率锁 + 删除 + 缓存 +
/// 每日自述。纯函数全在 [SelfPrompt] / [SelfGuard]，这里只负责 IO 与编排。
///
/// 硬纪律：
/// - 构造任何 journal 行都走 [buildJournalLine]，cap 由协议层注入，本文件不写 cap。
/// - 构造行之前先过 [QuotaGate.allow] 并自增计数；超限直接丢弃不排队。
/// - 删除只写本机 `deleted_self_facts.json`（sha16 + ts），**绝不改 journal**。
class SelfService {
  final DeepSeekService _llm;

  SelfService({DeepSeekService? llm}) : _llm = llm ?? DeepSeekService();

  /// 本机删除清单文件名（设计 §3.2）。永久保留本机；换机失效（已知限制）。
  static const String deletedFileName = 'deleted_self_facts.json';

  SelfProfile profile = const SelfProfile();
  List<SelfFact> facts = <SelfFact>[];
  List<SelfNote> notes = <SelfNote>[];
  DeletedFactList deleted = const DeletedFactList();

  /// 生效事实：排除本机删除清单命中的（展示期 + prompt 注入都用这个）。
  List<SelfFact> get effectiveFacts =>
      facts.where((f) => !deleted.containsHash(f.hash)).toList();

  /// 本机可投影的派生事实（persona 定稿只读，重蒸现算、不落库）。
  static List<String> derive(PersonaSpace space) {
    final f = space.fields;
    String pick(String key) => (f[key] ?? '').trim();
    final out = <String>[
      if (pick('identity').isNotEmpty) '我是${pick('identity')}。',
      if (pick('personality').isNotEmpty) '我的性子是${pick('personality')}。',
      if (pick('values').isNotEmpty) '我在意${pick('values')}。',
      if (pick('boundaries').isNotEmpty) '我受不了${pick('boundaries')}。',
      '我不会做违背我自己设定的事。',
    ];
    return out;
  }

  // ——— 本机删除清单 IO ———

  static Future<File> _deletedFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$deletedFileName');
  }

  Future<File> _deletedFile() => _deletedFilePath();

  /// 供 cloud_sync 推送前过滤：本机已删事实的 sha16 集合。
  /// 读文件失败按空处理（最多让一条已删事实被推上去，已知限制 B10）。
  static Future<List<String>> instanceDeletedHashes() async {
    try {
      final f = await _deletedFilePath();
      if (!f.existsSync()) return const <String>[];
      final list = DeletedFactList.fromJson(jsonDecode(await f.readAsString()));
      return list.items.map((e) => e.sha16).where((s) => s.isNotEmpty).toList();
    } catch (_) {
      return const <String>[];
    }
  }

  /// 读清单：文件不存在/损坏 → 空清单，不抛。关键词不落盘，重启后为空
  /// （PRD 已知缺口一：近似措辞拦不住，不算缺陷）。
  Future<DeletedFactList> loadDeleted() async {
    try {
      final f = await _deletedFile();
      if (!f.existsSync()) return const DeletedFactList();
      return DeletedFactList.fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {
      return const DeletedFactList();
    }
  }

  Future<void> _saveDeleted(DeletedFactList list) async {
    try {
      final f = await _deletedFile();
      await f.writeAsString(jsonEncode(list.toJson()));
    } catch (_) {
      // 写清单失败不抛给界面：最坏是本次删除不持久，下次启动复现（已知限制）。
    }
  }

  // ——— 加载 / 缓存 ———

  /// 从 prefs 缓存恢复 self 三块 + 本机删除清单。任何一块坏掉都按空处理。
  Future<void> load() async {
    deleted = await loadDeleted();
    try {
      final raw = await Prefs.selfCache();
      if (raw.trim().isNotEmpty) {
        profile = SelfProfile.fromData(
            jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {}
    facts = _decodeList<SelfFact>(await Prefs.selfFactsCache(), SelfFact.fromData);
    notes = _decodeList<SelfNote>(await Prefs.selfNotesCache(), SelfNote.fromData);
    // 缓存里若混进了已删事实，加载时也过滤一次（即时删除的持久化兜底）。
    facts = effectiveFacts;
  }

  static List<T> _decodeList<T>(
    String raw,
    T Function(Map<String, dynamic>) from,
  ) {
    final out = <T>[];
    if (raw.trim().isEmpty) return out;
    try {
      final v = jsonDecode(raw);
      if (v is List) {
        for (final e in v) {
          if (e is Map<String, dynamic>) out.add(from(e));
        }
      }
    } catch (_) {}
    return out;
  }

  Future<void> _cacheFacts() async => setCachedFacts(facts);

  Future<void> _cacheNotes() async => setCachedNotes(notes);

  Future<void> _cacheProfile() async => setCachedProfile(profile);

  // ——— 静态缓存桥：cloud_sync 读写 self 数据用，不需要 LLM 依赖 ———

  /// 读本机 self_fact 缓存（data 列表）。坏数据按空处理。
  static Future<List<Map<String, dynamic>>> cachedFactData() async =>
      _decodeMaps(await Prefs.selfFactsCache());

  static Future<List<Map<String, dynamic>>> cachedNoteData() async =>
      _decodeMaps(await Prefs.selfNotesCache());

  static Future<Map<String, dynamic>> cachedProfileData() async {
    final raw = await Prefs.selfCache();
    if (raw.trim().isEmpty) return const <String, dynamic>{};
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  static Future<void> setCachedFacts(List<SelfFact> list) =>
      Prefs.setSelfFactsCache(jsonEncode(list.map((f) => f.toData()).toList()));

  static Future<void> setCachedNotes(List<SelfNote> list) =>
      Prefs.setSelfNotesCache(jsonEncode(list.map((n) => n.toData()).toList()));

  static Future<void> setCachedProfile(SelfProfile p) =>
      Prefs.setSelfCache(jsonEncode(p.toData()));

  /// 从云端采用 self 三块到本机缓存（拉取段用）。被本机清单删掉的 fact 过滤掉。
  static Future<void> adoptFromCloud({
    Map<String, dynamic>? profileData,
    required List<Map<String, dynamic>> factData,
    required List<Map<String, dynamic>> noteData,
    required DeletedFactList deleted,
  }) async {
    final facts = factData
        .map(SelfFact.fromData)
        .where((f) => !deleted.containsHash(f.hash))
        .toList();
    if (factData.isNotEmpty) await setCachedFacts(facts);
    if (noteData.isNotEmpty) {
      await setCachedNotes(noteData.map(SelfNote.fromData).toList());
    }
    if (profileData != null && profileData.isNotEmpty) {
      await setCachedProfile(SelfProfile.fromData(profileData));
    }
  }

  static List<Map<String, dynamic>> _decodeMaps(String raw) {
    final out = <Map<String, dynamic>>[];
    if (raw.trim().isEmpty) return out;
    try {
      final v = jsonDecode(raw);
      if (v is List) {
        for (final e in v) {
          if (e is Map<String, dynamic>) out.add(e);
        }
      }
    } catch (_) {}
    return out;
  }

  // ——— 计数（跨天 / 跨周由这里重置）———

  /// ISO 周键 `YYYYWN`（周一起算）。与 Node `src/state_view.mjs` 同一口径。
  static String weekKeyOf(DateTime now) {
    // 以本地日期取出「本周四」，ISO 年 = 本周四所在年（跨年周归上一年/下一年）。
    final date = DateTime(now.year, now.month, now.day);
    final thursday = date.add(Duration(days: 4 - date.weekday));
    final year = thursday.year;
    final yearStart = DateTime(year);
    final firstThursday = yearStart.add(Duration(days: 4 - yearStart.weekday));
    final week = ((thursday.difference(firstThursday).inDays) / 7).floor() + 1;
    return '${year}W$week';
  }

  static String dayKeyOf(DateTime now) =>
      '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';

  /// buildJournalLine 产出的是 JSONL 文本（cap 由协议层注入），解析回对象交给
  /// cloud_sync 追加。cap 经由 fromMap 原样保留，不在这里手写。
  static JournalLine _line(String jsonl) => parseJournalLines(jsonl).single;

  /// 从 prefs 的 `self_fact_week`（形如 `2026W47:2`）读本周已写条数；
  /// 周键不匹配 → 视为新的一周，计数归零（跨周边界）。
  static int weekFactCount(String raw, String weekKey) {
    if (raw.trim().isEmpty) return 0;
    final parts = raw.split(':');
    if (parts.length != 2 || parts[0].trim() != weekKey) return 0;
    return int.tryParse(parts[1].trim()) ?? 0;
  }

  /// self 的当天计数：上次重蒸落在今天则 1，否则 0（跨天自动归零）。
  static int selfTodayCount(int lastDistillAt, DateTime now) {
    if (lastDistillAt <= 0) return 0;
    final last = DateTime.fromMillisecondsSinceEpoch(lastDistillAt);
    return dayKeyOf(last) == dayKeyOf(now) ? 1 : 0;
  }

  /// self_note 的当天计数：本机缓存里已有当天的自述则 1，否则 0。
  int noteTodayCount(DateTime now) {
    final k = dayKeyOf(now);
    return notes.any((n) => n.dayKey == k) ? 1 : 0;
  }

  // ——— 能力门禁 ———

  /// 本端能否写 self：cap 不足 / 云端有敏感 type / 云端 cap 更高 → 只读。
  static bool canWrite({
    required Set<String> cloudTypes,
    required int cloudSelfCap,
    int localCap = kPhoneCapability,
  }) =>
      decideCapability(
        cloudTypes: cloudTypes,
        cloudSelfCap: cloudSelfCap,
        localCap: localCap,
      ).canWriteSelf;

  // ——— 重蒸（唯一有副作用、必须过门禁的路径）———

  /// 每 7 天重蒸 self，顺带产出 ≤3 条 self_fact 候选。
  ///
  /// [cloudTypes] / [cloudSelfCap] 由调用方从云端原文探测后传入（探测在 cloud_sync
  /// 侧完成，本文件不额外发请求）。返回本次新增的 journal 行（调用方负责 append）。
  Future<List<JournalLine>> maybeDistill({
    required String apiKey,
    required String personaSpace,
    required List<String> recentLines,
    required List<String> nearNotes,
    required Set<String> cloudTypes,
    required int cloudSelfCap,
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    // 能力门禁：不满足就只读，什么都不写（设计序列图 alt 分支）。
    if (!canWrite(
        cloudTypes: cloudTypes, cloudSelfCap: cloudSelfCap)) {
      return const <JournalLine>[];
    }

    // 硬事实守卫开关：`docs/待裁决-T04.md` 的 D 条已**定稿**为
    // 「不设 UI 开关，取值只由代码常量决定（当前 false），绝不改恒 true」。
    // 理由（实测口径）：`isHardFact` 与 `isRealLifeFact` **同一份标记表**
    // （职业/年龄/家人/城市/学历/身体），恒 true 等于把「我在广州做设计」
    // 「我妈住院了」这类最自然的事实全部丢弃 ⇒ R2 的"能长"当场变空转，
    // 同时 B9 的「涉及你的现实生活」标记与筛选也再没有可标记的对象（变死代码）。
    // 所以这里老老实实读 prefs（默认 false），**不拿它当策略位之外的任何东西**。
    final guardOn = await Prefs.hardFactGuardEnabled();
    final existingHashes = facts.map((f) => f.hash).toSet();

    // 过闸 ①：self 每天 ≤1（重蒸本就 7 天一次，这里仍真实过闸，防手抖连点）。
    final selfGate = quotaAllow(
      'self', selfTodayCount(await Prefs.selfLastDistillAt(), t), 0);
    if (!selfGate.allowed) return const <JournalLine>[];

    // 过闸 ②：self_fact 每周 ≤3；跨周由 weekKey 不匹配归零。
    final wk = weekKeyOf(t);
    final weekCount = weekFactCount(await Prefs.selfFactWeek(), wk);
    var nextWeekCount = weekCount;

    // 生成 prompt（删除清单关键词 ≤50 字在 buildUserInput 内处理）。
    final input = SelfPrompt.buildUserInput(
      personaProjection: personaSpace,
      recentLines: recentLines,
      nearNotes: nearNotes,
      deleted: deleted,
    );
    final raw = await _llm.completeJson(
      apiKey: apiKey,
      system: SelfPrompt.systemPrompt,
      user: input,
      maxTokens: 1200,
    );

    final candidates = SelfPrompt.factsFromMap(raw);
    final added = <JournalLine>[];
    for (final cand in candidates) {
      final gate = quotaAllow('self_fact', 0, nextWeekCount);
      if (!gate.allowed) break; // 超限直接丢弃，不排队
      final verdict = SelfGuard.check(
        text: cand.text,
        existingHashes: existingHashes,
        deleted: deleted,
        hardFactGuardEnabled: guardOn,
      );
      if (!verdict.keep) continue; // 三重拦截：逐字 sha16 → 关键词 contains → 硬事实
      final fact = SelfFact(
        hash: cand.hash,
        text: cand.text,
        source: cand.source,
        createdAt: cand.createdAt == 0 ? t.millisecondsSinceEpoch : cand.createdAt,
        weekKey: wk,
      );
      // cap 由 buildJournalLine 自动注入，业务层不写。
      added.add(_line(buildJournalLine(
        type: JournalLine.typeSelfFact,
        key: fact.key,
        ts: fact.createdAt,
        data: fact.toData(),
      )));
      facts.add(fact);
      existingHashes.add(fact.hash);
      nextWeekCount = gate.nextWeekCount;
    }

    // 聚合 self 文本 = 派生事实 + 生效的自生长事实（删除清单已排除）。
    final derived = derive(PersonaSpace.decode(personaSpace));
    final text = SelfComposer.compose(derived, effectiveFacts);
    final profileLine = _line(buildJournalLine(
      type: JournalLine.typeSelf,
      key: journalKeySelf,
      ts: t.millisecondsSinceEpoch,
      data: SelfProfile(
        text: text,
        facts: effectiveFacts.map((f) => f.hash).toList(),
        derivedAt: t.millisecondsSinceEpoch,
        reason: facts.isEmpty ? 'init' : 'distill',
      ).toData(),
    ));
    added.add(profileLine);

    profile = SelfProfile(
      text: text,
      facts: effectiveFacts.map((f) => f.hash).toList(),
      derivedAt: t.millisecondsSinceEpoch,
      reason: 'distill',
    );

    // 写回缓存 + 计数（跨周边界：周键变了就重写为新键:计数）。
    await _cacheFacts();
    await _cacheProfile();
    await Prefs.setSelfFactWeek('$wk:$nextWeekCount');
    await Prefs.setSelfLastDistillAt(t.millisecondsSinceEpoch);
    return added;
  }

  /// 每日自述 self_note：每天 ≤1 条、≤60 字第一人称；当天已生成则跳过。
  Future<List<JournalLine>> maybeWriteDailyNote({
    required String apiKey,
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    final gate = quotaAllow('self_note', noteTodayCount(t), 0);
    if (!gate.allowed) return const <JournalLine>[];

    final raw = await _llm.completeJson(
      apiKey: apiKey,
      system: '用第一人称写一句今天的心情/状态，≤60 字，像随手记一句，'
          '不要出现"AI/助手/模型/程序"。只输出 JSON：{"text":"..."}',
      user: '写一句你今天的状态。',
      maxTokens: 120,
    );
    final textVal = raw['text'];
    var text = textVal is String ? textVal.trim() : '';
    if (text.isEmpty) return const <JournalLine>[];
    if (text.length > 60) text = text.substring(0, 60);
    final note = SelfNote(
      dayKey: dayKeyOf(t),
      text: text,
      createdAt: t.millisecondsSinceEpoch,
    );
    final line = _line(buildJournalLine(
      type: JournalLine.typeSelfNote,
      key: note.key,
      ts: note.createdAt,
      data: note.toData(),
    ));
    notes.add(note);
    await _cacheNotes();
    return <JournalLine>[line];
  }

  /// 删除一条自生长事实：本机清单追加 {sha16, ts}，生效集合立即剔除，
  /// self.text 立即用 exclude 剔除该段——**不碰 journal 一行**（B8②）。
  Future<void> deleteFact(SelfFact fact) async {
    deleted = deleted.add(
      fact,
      SelfGuard.keywordsOf(fact.text),
      DateTime.now().millisecondsSinceEpoch,
    );
    await _saveDeleted(deleted);
    facts = effectiveFacts;
    profile = SelfProfile(
      text: SelfComposer.exclude(profile.text, fact).trim(),
      facts: profile.facts.where((h) => h != fact.hash).toList(),
      derivedAt: profile.derivedAt,
      reason: profile.reason,
    );
    await _cacheFacts();
    await _cacheProfile();
  }
}
