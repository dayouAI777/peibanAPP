import 'dart:convert';

/// 「她」的说话方式档案：把用户历次手工修改的范例（style_examples）
/// 用模型蒸馏成的一份稳定长期描述。
///
/// 三层分工（别混）：
/// - [SpeechProfile]：后台静默学**用户**怎么说话（抽象描述，全量注入）；
/// - StyleExample：用户亲手改的**她**该怎么说（具体范例，只带最新 12 条）；
/// - 这里：把全部范例蒸馏成**她的**长期说话习惯（机器产物，全量注入）。
///   更早的范例 AI 原本看不到（窗口只有 12 条），这份档案补上「教了但忘了」的洞。
///
/// 存储：Prefs 的 `style_profile` key（JSON 字符串），全局一份——当前项目
/// 常态单角色，与 speech_profile 同口径；将来支持多角色再按角色拆 key。
/// 档案是机器蒸馏产物，不提供任何手工编辑入口（与「人设定稿不改」同一精神）。
class StyleProfile {
  /// 已蒸馏消化掉的范例条数。触发增量判断用：
  /// `范例总数 - digested >= 阈值` 就再蒸馏一轮。
  final int digested;

  /// 最近一次蒸馏完成时间（毫秒）。
  final int updatedAt;

  /// 语气与态度。
  final String tone;

  /// 句子长短。
  final String sentenceLength;

  /// 口头禅与高频用词。
  final List<String> catchphrases;

  /// 标点与表情习惯。
  final String punctuation;

  /// 句式节奏。
  final String rhythm;

  /// 底线雷区：用户改掉的都是她不该说的（如「不连发长段」「不自称某某」）。
  /// 这是全部字段里信号价值最高的一块——错句不会进 prompt，但「为什么被改」会。
  final String taboos;

  /// 其他值得注意的说话习惯。
  final String notes;

  const StyleProfile({
    this.digested = 0,
    this.updatedAt = 0,
    this.tone = '',
    this.sentenceLength = '',
    this.catchphrases = const <String>[],
    this.punctuation = '',
    this.rhythm = '',
    this.taboos = '',
    this.notes = '',
  });

  /// 空档案：一条范例都没消化过、且所有字段都是空的。
  /// 只要有任何一个字段有值（哪怕 digested 还是 0）就不算空，
  /// 因为 prompt 注入判断只看「有没有内容可给模型」。
  bool get isEmpty =>
      digested == 0 &&
      tone.isEmpty &&
      sentenceLength.isEmpty &&
      catchphrases.isEmpty &&
      punctuation.isEmpty &&
      rhythm.isEmpty &&
      taboos.isEmpty &&
      notes.isEmpty;

  static StyleProfile empty() => const StyleProfile();

  /// 拼 system prompt 用：有值的字段才输出，全空返回空串。
  String renderForPrompt() {
    final b = StringBuffer();
    if (tone.isNotEmpty) b.writeln('- 语气与态度：$tone');
    if (sentenceLength.isNotEmpty) b.writeln('- 句子长短：$sentenceLength');
    if (catchphrases.isNotEmpty) {
      b.writeln('- 口头禅与用词：${catchphrases.join('、')}');
    }
    if (punctuation.isNotEmpty) b.writeln('- 标点与表情：$punctuation');
    if (rhythm.isNotEmpty) b.writeln('- 句式节奏：$rhythm');
    if (taboos.isNotEmpty) b.writeln('- 底线雷区（这些绝不能说）：$taboos');
    if (notes.isNotEmpty) b.writeln('- 其他：$notes');
    return b.toString();
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'digested': digested,
        'updated_at': updatedAt,
        'tone': tone,
        'sentence_length': sentenceLength,
        'catchphrases': catchphrases,
        'punctuation': punctuation,
        'rhythm': rhythm,
        'taboos': taboos,
        'notes': notes,
      };

  /// 单字段容错小工具：数字字段类型不对就兜 0，绝不因一个坏字段
  /// 毒死整个档案（坏数据降级，不抛异常）。
  static int _intOf(Object? v, [int fallback = 0]) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? fallback;
    return fallback;
  }

  /// 字符串字段：只有真的是 String 才采用，其余一律兜空串。
  static String _strOf(Object? v) => v is String ? v : '';

  /// 宽容解析：字段缺了兜默认值，类型不对降级成空，绝不抛。
  factory StyleProfile.fromMap(Map<String, dynamic> m) => StyleProfile(
        digested: _intOf(m['digested']),
        updatedAt: _intOf(m['updated_at']),
        tone: _strOf(m['tone']),
        sentenceLength: _strOf(m['sentence_length']),
        catchphrases: _phraseList(m['catchphrases']),
        punctuation: _strOf(m['punctuation']),
        rhythm: _strOf(m['rhythm']),
        taboos: _strOf(m['taboos']),
        notes: _strOf(m['notes']),
      );

  /// 口头禅列表的安全解析：非字符串元素转字符串、空的和重复的丢掉、
  /// 超长的截断（模型偶尔会违约束写长句，档案里不能塞进整段话）。
  static List<String> _phraseList(Object? raw, {int max = 12, int maxLen = 16}) {
    if (raw is! List) return const <String>[];
    final out = <String>[];
    for (final e in raw) {
      var v = e?.toString().trim() ?? '';
      if (v.isEmpty) continue;
      if (v.length > maxLen) v = v.substring(0, maxLen);
      if (out.contains(v)) continue;
      out.add(v);
      if (out.length >= max) break;
    }
    return out;
  }

  String encode() => jsonEncode(toMap());

  /// 安全解码：坏 JSON / 不是对象 → 返回空档案，绝不抛
  /// （档案读坏了就当没有，绝不能让它崩掉聊天加载）。
  static StyleProfile decode(String raw) {
    if (raw.trim().isEmpty) return empty();
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return StyleProfile.fromMap(v);
      if (v is Map) return StyleProfile.fromMap(v.cast<String, dynamic>());
    } catch (_) {
      // 掉进这里说明存的数据坏了：降级成空档案
    }
    return empty();
  }
}
