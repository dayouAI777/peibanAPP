/// 用户行为记录手册里的一条。
/// 只记「稳定的、值得长期记住的」行为习惯，不记闲聊和临时情绪。
class UserNote {
  static const List<String> categories = [
    '稳定偏好',
    '生活习惯',
    '身份事实',
    '重要关系',
    '明确好恶',
    '反复模式',
    '重要日期',
  ];

  final int? id;
  final String category;
  final String content;
  final double confidence;
  final String evidence;
  final int createdAt;

  const UserNote({
    this.id,
    required this.category,
    required this.content,
    required this.confidence,
    required this.evidence,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'category': category,
        'content': content,
        'confidence': confidence,
        'evidence': evidence,
        'created_at': createdAt,
      };

  factory UserNote.fromMap(Map<String, dynamic> m) => UserNote(
        id: m['id'] as int?,
        category: (m['category'] as String?) ?? '稳定偏好',
        content: (m['content'] as String?) ?? '',
        confidence: (m['confidence'] as num?)?.toDouble() ?? 0,
        evidence: (m['evidence'] as String?) ?? '',
        createdAt: (m['created_at'] as int?) ?? 0,
      );
}
