import 'dart:convert';

import '../data/db_helper.dart';
import '../data/prefs.dart';
import '../models/user_note.dart';
import 'deepseek.dart';
import 'prompt_budget.dart';
import 'quota_gate.dart';

/// R4 中期层：生成 `note(category=近况)`（设计 §6.1 / PRD v1.2.4 R4）。
///
/// 规则（**固定，不改断言结构**）：
/// - **当晚 [kNearTermHour] 点之后、且当天还没生成过**时，第一次打开 App（需 Key）
///   用最近 3 天对话生成 1 条 `note(category=近况)`；
/// - 写前**必须过 T01 的 [QuotaGate]**（`note_nearterm` ≤1/天）；超限**直接丢弃、
///   不排队**（云母库只增不删，写进去就删不掉）；
/// - `note_nearterm_day` 保证**一天只尝试一次**（即使模型失败也不反复重试）；
/// - key 是内容哈希 → 同内容天然幂等（D4 通过）。
///
/// 钟点做成常量 [kNearTermHour]，改一个数即可、不动断言结构；验收 D4 不依赖具体钟点。
class NearTermNoteService {
  NearTermNoteService({DeepSeekService? llm}) : _llm = llm ?? DeepSeekService();
  final DeepSeekService _llm;

  /// 当晚几点之后才生成近况（常量，验收不依赖具体值）。
  static const int kNearTermHour = 20;

  /// 用最近几天的对话生成（设计：最近 3 天）。
  static const int lookbackDays = 3;

  static String _dayKey(DateTime t) =>
      '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}';

  /// 纯函数：现在是否到了「可以尝试生成近况」的时间/日期条件。
  /// 不含网络、不含限额（限额在 [maybeGenerate] 里过闸）。
  static bool shouldAttempt({
    required DateTime now,
    required String lastDayKey,
  }) {
    if (now.hour < kNearTermHour) return false;
    return lastDayKey != _dayKey(now);
  }

  /// 尝试生成一条近况 note。返回新增条数（0 或 1）。失败静默返回 0。
  ///
  /// [recentMessages] 是最近几天（调用方按 [lookbackDays] 过滤）的对话文本行。
  Future<int> maybeGenerate({
    required String apiKey,
    required List<String> recentMessages,
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    if (apiKey.trim().isEmpty) return 0;
    if (recentMessages.isEmpty) return 0;

    // 时间 + 当天去重：一天只尝试一次。
    final lastDay = await Prefs.noteNeartermDay();
    if (!shouldAttempt(now: t, lastDayKey: lastDay)) return 0;

    // 过闸：note_nearterm ≤1/天。当天尚未生成（lastDay 不是今天）⇒ todayCount=0；
    // 即便并发重复触发，这里也只会放行一次。
    final gate = quotaAllow(
      'note_nearterm',
      lastDay == _dayKey(t) ? 1 : 0,
      0,
    );
    if (!gate.allowed) return 0;

    // 先落「今天已尝试」，避免模型失败后反复重试打爆 key。
    await Prefs.setNoteNeartermDay(_dayKey(t));

    String content;
    try {
      final m = await _llm.completeJson(
        apiKey: apiKey,
        system: _systemPrompt,
        user: jsonEncode({'最近三天的对话': recentMessages}),
        temperature: 0.3,
        maxTokens: 300,
      );
      content = (m['content'] as String?)?.trim() ?? '';
    } catch (_) {
      return 0;
    }
    if (content.isEmpty) return 0;
    if (content.length > 60) content = content.substring(0, 60);

    // 幂等：同内容已存在则不重复写（key = 内容哈希由 DB 侧/调用方保证）。
    final existing = await DbHelper.instance.userNotes();
    final dup = existing.any((n) =>
        n.category == PromptBudget.nearTermCategory && n.content == content);
    if (dup) return 0;

    await DbHelper.instance.insertNote(UserNote(
      category: PromptBudget.nearTermCategory,
      content: content,
      confidence: 0.8,
      evidence: '最近三天对话',
      createdAt: t.millisecondsSinceEpoch,
    ));
    return 1;
  }

  static const String _systemPrompt = '''
你在帮一个女孩回忆「最近这几天在跟对方聊什么」。只输出一个 JSON 对象，不要 markdown：
{"content": "一句第一人称的近况，40字以内"}

要求：
- 第一人称，像她自己随口想的：「这几天他一直在忙那个项目」「他最近好像有点累」。
- 只描述最近几天真实出现的主题，不要编造没聊过的事、人名、地名。
- 不评判、不说教、不总结成「我们的关系」这种大词。
- 一句就够，不要分点、不要引号、结尾不要句号也可以。
- 只输出 JSON。
''';
}
