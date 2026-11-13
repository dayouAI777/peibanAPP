/// 一条「她这么说是错的，这么说才对」的真人修正记录。
///
/// 和自动学习的 [SpeechProfile] 分工不同：
/// - SpeechProfile 学的是**用户**怎么说话，靠模型自己归纳，是抽象描述；
/// - StyleExample 记的是**她**该怎么说话，由用户亲手写，是具体范例。
///
/// 模型对「一句具体的话」的模仿能力，远强于对一段抽象描述的遵守能力，
/// 所以这里存的是原话对照，直接塞进 system prompt 当示范。
class StyleExample {
  final int? id;
  final int companionId;

  /// 触发这句话时对方说了什么（找得到就存，找不到留空）。
  final String trigger;

  /// 她当时原原本本说的那句（错的）。
  final String original;

  /// 对方亲手改成的那句（对的）。
  final String preferred;

  final int createdAt;

  const StyleExample({
    this.id,
    required this.companionId,
    this.trigger = '',
    required this.original,
    required this.preferred,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'companion_id': companionId,
        'trigger_text': trigger,
        'original': original,
        'preferred': preferred,
        'created_at': createdAt,
      };

  factory StyleExample.fromMap(Map<String, dynamic> m) => StyleExample(
        id: m['id'] as int?,
        companionId: (m['companion_id'] as int?) ?? 0,
        trigger: (m['trigger_text'] as String?) ?? '',
        original: (m['original'] as String?) ?? '',
        preferred: (m['preferred'] as String?) ?? '',
        createdAt: (m['created_at'] as int?) ?? 0,
      );
}
