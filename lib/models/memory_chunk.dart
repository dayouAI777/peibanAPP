/// 一段被压缩过的旧对话记忆。
/// 超过上下文窗口的历史不是丢掉，而是让 AI 压成摘要存起来，继续跟着聊天走。
class MemoryChunk {
  final int? id;
  final int companionId;
  final int fromMessageId;
  final int toMessageId;
  final String summary;
  final int createdAt;

  const MemoryChunk({
    this.id,
    required this.companionId,
    required this.fromMessageId,
    required this.toMessageId,
    required this.summary,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'companion_id': companionId,
        'from_id': fromMessageId,
        'to_id': toMessageId,
        'summary': summary,
        'created_at': createdAt,
      };

  factory MemoryChunk.fromMap(Map<String, dynamic> m) => MemoryChunk(
        id: m['id'] as int?,
        companionId: (m['companion_id'] as int?) ?? 0,
        fromMessageId: (m['from_id'] as int?) ?? 0,
        toMessageId: (m['to_id'] as int?) ?? 0,
        summary: (m['summary'] as String?) ?? '',
        createdAt: (m['created_at'] as int?) ?? 0,
      );
}
