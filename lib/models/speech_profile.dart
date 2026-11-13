import 'dart:convert';

/// 用户「说话方式」画像。后台静默学习，只描摹语言习惯，不记具体聊了什么。
/// 用途：让角色的回复节奏更贴合用户，但绝不改变角色自己的人设与性格。
class SpeechProfile {
  final int samples; // 已观察过的用户消息条数
  final String sentenceLength; // 句子长短
  final String tone; // 语气
  final List<String> catchphrases; // 口头禅 / 高频词
  final String punctuation; // 标点与表情习惯
  final String rhythm; // 句式与节奏
  final String notes; // 其他观察
  final int updatedAt;

  const SpeechProfile({
    this.samples = 0,
    this.sentenceLength = '',
    this.tone = '',
    this.catchphrases = const <String>[],
    this.punctuation = '',
    this.rhythm = '',
    this.notes = '',
    this.updatedAt = 0,
  });

  bool get isEmpty => samples == 0 || sentenceLength.isEmpty;

  static SpeechProfile empty() => const SpeechProfile();

  String renderForPrompt() {
    final b = StringBuffer();
    if (sentenceLength.isNotEmpty) b.writeln('- 句子长短：$sentenceLength');
    if (tone.isNotEmpty) b.writeln('- 语气：$tone');
    if (catchphrases.isNotEmpty) {
      b.writeln('- 常说的话 / 口头禅：${catchphrases.join('、')}');
    }
    if (punctuation.isNotEmpty) b.writeln('- 标点与表情习惯：$punctuation');
    if (rhythm.isNotEmpty) b.writeln('- 说话节奏：$rhythm');
    if (notes.isNotEmpty) b.writeln('- 其他：$notes');
    return b.toString();
  }

  Map<String, dynamic> toMap() => {
        'samples': samples,
        'sentence_length': sentenceLength,
        'tone': tone,
        'catchphrases': catchphrases,
        'punctuation': punctuation,
        'rhythm': rhythm,
        'notes': notes,
        'updated_at': updatedAt,
      };

  factory SpeechProfile.fromMap(Map<String, dynamic> m) => SpeechProfile(
        samples: (m['samples'] as num?)?.toInt() ?? 0,
        sentenceLength: (m['sentence_length'] as String?) ?? '',
        tone: (m['tone'] as String?) ?? '',
        catchphrases: (m['catchphrases'] as List?) == null
            ? const <String>[]
            : List<String>.from(m['catchphrases'] as List),
        punctuation: (m['punctuation'] as String?) ?? '',
        rhythm: (m['rhythm'] as String?) ?? '',
        notes: (m['notes'] as String?) ?? '',
        updatedAt: (m['updated_at'] as int?) ?? 0,
      );

  String encode() => jsonEncode(toMap());

  static SpeechProfile decode(String raw) => SpeechProfile.fromMap(
        jsonDecode(raw) as Map<String, dynamic>,
      );
}
