import 'dart:convert';
import 'dart:math';

import '../models/style_example.dart';
import '../models/style_profile.dart';
import 'deepseek.dart';

/// 「她的说话方式档案」蒸馏服务。
///
/// 把全部 style_examples（现在是 29 条，将来上百）定期用 DeepSeek
/// **增量合并**成一份稳定的档案：现有档案 + 新增范例 → 更新后的档案，
/// 不是每次全量重写（省 token、保稳定）。
///
/// 范例窗口机制（最新 12 条直接进 prompt）保持不变；这份档案补的是
/// 更早范例「教了但忘了」的洞。全程后台跑，失败静默、绝不阻塞聊天。
class StyleProfileService {
  StyleProfileService({DeepSeekService? llm}) : _llm = llm ?? DeepSeekService();
  final DeepSeekService _llm;

  /// digested 落后范例总数多少条才触发一次蒸馏。
  /// 3 条起蒸：太小会频繁调 API，太大则「教了但忘了」的窗口期太长。
  static const int triggerThreshold = 3;

  /// 手改范例后的防抖：连续改几条只蒸馏最后一次
  /// （与云备份 uploadDebounce 同款 5 分钟口径）。
  static const Duration debounce = Duration(minutes: 5);

  /// 冷启动补漏的延迟：避开首帧，启动一分钟后才查漏蒸馏。
  static const Duration coldStartDelay = Duration(minutes: 1);

  /// 一轮最多消化多少条新范例（超出部分下一轮再合，防单次 prompt 失控）。
  static const int maxNewExamplesPerRound = 60;

  /// 旧范例抽样条数：给模型一点已消化部分的长期背景，帮助平滑合并。
  static const int sampleOldCount = 6;

  /// 口头禅上限（与 SpeechProfileService 的量级一致）。
  static const int maxCatchphrases = 8;

  /// 触发判断（纯函数，可测）：digested 落后范例总数 ≥ threshold 条 → 触发。
  /// digested 超前（范例被删过）时差值为负，不触发——等新范例攒够再说。
  static bool shouldDistill({
    required int digested,
    required int total,
    int threshold = triggerThreshold,
  }) =>
      total - digested >= threshold;

  /// 蒸馏 system prompt（纯常量，可测、可审查）。
  ///
  /// 要点：
  /// - 输入 = 现有档案 + 新增范例（trigger/original/preferred）+ 旧范例抽样；
  /// - preferred（改后句）优先于 original（改前句）；
  /// - original 只用来提炼「底线雷区」，绝不照抄错句进其他字段；
  /// - 每字段短句 ≤40 字；只输出 JSON。
  static String get distillSystemPrompt => '''
你是「说话方式档案整理员」。用户长期在聊天里手工修改一个 AI 角色的说话方式
（把她说得不对的话改成认可的样子），你要把这些修改蒸馏成一份稳定的
「她的说话方式档案」，供聊天 prompt 长期注入。

你会收到三份输入：
- current：现有档案（可能还没有）；
- new_examples：上次蒸馏之后新增的修改。每条三个字段：
  trigger=当时对方说的话，original=她原来被改掉的错句，preferred=用户改成的正句；
- old_sample：更早的旧范例抽样，只做长期背景参考。

任务：把 current 与 new_examples 合并成更新后的档案。
这是**增量合并，不是重写**：current 里仍然成立的条目原样保留，
只修订被新例子推翻或补充的部分；不要推倒重来。

只输出一个 JSON 对象，不要 markdown 代码块，不要解释：
{
  "tone": "语气与态度",
  "sentence_length": "句子长短",
  "catchphrases": ["口头禅与高频用词"],
  "punctuation": "标点与表情习惯",
  "rhythm": "句式节奏",
  "taboos": "底线雷区：她绝不能怎么说的清单",
  "notes": "其他值得注意的说话习惯"
}

铁律：
- preferred（改后句）永远优先于 original（改前句）：语气、长短、用词一律向 preferred 归纳。
- original 只有一处用处：提炼进 taboos（例如「不连发长段」「不自称某某」），
  绝不把错句原样照抄进任何其他字段。
- 每个字段一句短话，不超过 40 字；catchphrases 最多 8 条、每条不超过 8 个字。
- 不复述具体事件、人名、地点、时间等隐私内容，只提炼说话方式本身。
- 拿不准就保留 current 对应字段原值，或写「暂不明确」，不要瞎编。
- 只输出 JSON。''';

  /// 蒸馏 user 输入（纯函数，可测、可审查）：
  /// 现有档案 JSON + 新增范例 + 旧范例抽样。
  static String buildDistillUserInput({
    required StyleProfile current,
    required List<StyleExample> newExamples,
    required List<StyleExample> sampleOld,
  }) {
    Map<String, dynamic> ex(StyleExample e) => <String, dynamic>{
          'trigger': e.trigger,
          'original': e.original,
          'preferred': e.preferred,
        };
    return jsonEncode(<String, dynamic>{
      'current': current.isEmpty ? '（还没有档案，这是第一次蒸馏）' : current.toMap(),
      'new_examples': [for (final e in newExamples) ex(e)],
      'old_sample': [for (final e in sampleOld) ex(e)],
    });
  }

  /// 跑一次蒸馏。任何失败（没 Key / 网络 / 超时 / 坏 JSON / 字段缺失）
  /// 都静默降级：返回 current 原样、状态不变，下一轮再试。
  ///
  /// 成功时 digested = min(totalExamples, current.digested + newExamples.length)
  /// ——正常流程 newExamples 就是全部未消化条数，所以等于范例总数；
  /// 一轮被 [maxNewExamplesPerRound] 截断时只前进实际消化的条数，
  /// 剩下的留给下一轮（绝不虚报消化进度）。
  Future<StyleProfile> distill({
    required String apiKey,
    required StyleProfile current,
    required List<StyleExample> newExamples,
    required List<StyleExample> sampleOld,
    required int totalExamples,
  }) async {
    if (apiKey.trim().isEmpty || newExamples.isEmpty) return current;

    try {
      final m = await _llm.completeJson(
        apiKey: apiKey,
        system: distillSystemPrompt,
        user: buildDistillUserInput(
          current: current,
          newExamples: newExamples,
          sampleOld: sampleOld,
        ),
        temperature: 0.2,
        maxTokens: 700,
      );

      String s(String key, [int max = 80]) {
        final v = (m[key] as String?)?.trim() ?? '';
        return v.length > max ? v.substring(0, max) : v;
      }

      final phrases = <String>[];
      final raw = (m['catchphrases'] as List?) ?? const <dynamic>[];
      for (final e in raw) {
        final v = e?.toString().trim() ?? '';
        if (v.isEmpty || v.length > 12) continue;
        if (phrases.contains(v)) continue;
        if (phrases.length >= maxCatchphrases) break;
        phrases.add(v);
      }
      // 旧口头禅保底保留：模型某一轮漏掉也不至于永远丢失（有总量上限防膨胀）
      for (final old in current.catchphrases) {
        if (phrases.length >= maxCatchphrases + 4) break;
        if (!phrases.contains(old)) phrases.add(old);
      }

      // 模型没给的字段保留 current 原值（增量合并的兜底）
      return StyleProfile(
        digested: min(totalExamples, current.digested + newExamples.length),
        tone: s('tone').isEmpty ? current.tone : s('tone'),
        sentenceLength: s('sentence_length').isEmpty
            ? current.sentenceLength
            : s('sentence_length'),
        catchphrases: phrases,
        punctuation: s('punctuation').isEmpty
            ? current.punctuation
            : s('punctuation'),
        rhythm: s('rhythm').isEmpty ? current.rhythm : s('rhythm'),
        // 底线雷区是最高价值信号，放宽到 160 字
        taboos: s('taboos', 160).isEmpty ? current.taboos : s('taboos', 160),
        notes: s('notes').isEmpty ? current.notes : s('notes'),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      // 静默失败，状态不变，下一轮重试
      return current;
    }
  }
}
