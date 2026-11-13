import 'dart:convert';

import '../models/speech_profile.dart';
import 'deepseek.dart';

/// 后台静默学习「用户平时怎么说话」。
///
/// 与行为记录手册的分工：
/// - 行为手册记的是「这个人的事实与稳定习惯」（吃什么、作息、重要关系）；
/// - 这里只记「语言风格」（句长、语气、口头禅、标点、节奏），不记具体内容。
///
/// 全程后台跑，不弹窗、不打扰、失败静默；结果只存本机。
class SpeechProfileService {
  SpeechProfileService({DeepSeekService? llm})
      : _llm = llm ?? DeepSeekService();
  final DeepSeekService _llm;

  /// 每积累多少条用户消息学一次。
  static const int reviewEvery = 8;

  Future<SpeechProfile> review({
    required String apiKey,
    required List<String> userLines,
    required SpeechProfile current,
  }) async {
    if (apiKey.trim().isEmpty || userLines.length < 3) return current;

    try {
      final m = await _llm.completeJson(
        apiKey: apiKey,
        system: '''
你是「语言风格观察员」。只给你【用户本人说的话】，请归纳这个人的**说话方式**，
用于让另一个 AI 把回复的节奏调得更贴合。

只输出一个 JSON 对象，不要 markdown 代码块，不要解释：
{
  "sentence_length": "句子长短，例如：多为 5~12 字短句 / 长句为主",
  "tone": "语气，例如：随意、偏冷淡、爱开玩笑、温柔、直接",
  "catchphrases": ["高频词或口头禅，最多 6 个"],
  "punctuation": "标点与表情习惯，例如：几乎不用标点 / 常用省略号 / 爱带 emoji",
  "rhythm": "句式与节奏，例如：先结论后补充 / 爱连问 / 很少用问句",
  "notes": "其他值得注意的语言习惯，一句话"
}

铁律：
- 只看说话方式，不要复述或记录具体事件、人名、地点、时间、隐私信息。
- 不要把某一次的情绪当成长期风格；拿不准就写「暂不明确」。
- 可以结合 previous 里已有的观察做平滑更新，不要每次都推倒重来。
- 每项控制在 30 字以内，catchphrases 最多 6 条、每条不超过 8 个字。
- 只输出 JSON。
''',
        user: jsonEncode({
          '用户本人说的话': userLines,
          'previous': current.toMap(),
        }),
        temperature: 0.2,
        maxTokens: 700,
      );

      String s(String key, [int max = 80]) {
        final v = (m[key] as String?)?.trim() ?? '';
        return v.length > max ? v.substring(0, max) : v;
      }

      final phrases = <String>[];
      final raw = (m['catchphrases'] as List?) ?? <dynamic>[];
      for (final e in raw) {
        final v = e.toString().trim();
        if (v.isEmpty || v.length > 12) continue;
        if (phrases.contains(v)) continue;
        if (phrases.length >= 6) break;
        phrases.add(v);
      }
      // 旧口头禅做保留上限，避免无限累积
      for (final old in current.catchphrases) {
        if (phrases.length >= 8) break;
        if (!phrases.contains(old)) phrases.add(old);
      }

      return SpeechProfile(
        samples: current.samples + userLines.length,
        sentenceLength: s('sentence_length').isEmpty
            ? current.sentenceLength
            : s('sentence_length'),
        tone: s('tone').isEmpty ? current.tone : s('tone'),
        catchphrases: phrases,
        punctuation: s('punctuation').isEmpty
            ? current.punctuation
            : s('punctuation'),
        rhythm: s('rhythm').isEmpty ? current.rhythm : s('rhythm'),
        notes: s('notes').isEmpty ? current.notes : s('notes'),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      // 静默失败，下次再学
      return current;
    }
  }
}
