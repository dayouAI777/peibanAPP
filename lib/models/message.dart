/// 一条聊天消息。
/// role: 'user' = 用户说的，'assistant' = 角色说的。
/// isProactive: 1 = 角色主动找上门发的，界面上会带一个小标签。
class ChatMessage {
  final int? id;
  final int companionId;
  final String role;
  final String content;
  final int createdAt;
  final int isProactive;

  const ChatMessage({
    this.id,
    required this.companionId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.isProactive = 0,
  });

  bool get fromUser => role == 'user';
  bool get isProactiveMessage => isProactive == 1;

  Map<String, dynamic> toMap() => {
        'id': id,
        'companion_id': companionId,
        'role': role,
        'content': content,
        'created_at': createdAt,
        'is_proactive': isProactive,
      };

  factory ChatMessage.fromMap(Map<String, dynamic> m) => ChatMessage(
        id: m['id'] as int?,
        companionId: (m['companion_id'] as int?) ?? 0,
        role: (m['role'] as String?) ?? 'assistant',
        content: (m['content'] as String?) ?? '',
        createdAt: (m['created_at'] as int?) ?? 0,
        isProactive: (m['is_proactive'] as int?) ?? 0,
      );
}
