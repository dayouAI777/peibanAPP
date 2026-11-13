/// 一条聊天消息。
/// role: 'user' = 用户说的，'assistant' = 角色说的。
/// isProactive: 1 = 角色主动找上门发的，界面上会带一个小标签。
/// imagePath: 用户随消息发的图片（已拷进 App 沙盒），空串 = 没有图。
class ChatMessage {
  final int? id;
  final int companionId;
  final String role;
  final String content;
  final int createdAt;
  final int isProactive;
  final String imagePath;

  const ChatMessage({
    this.id,
    required this.companionId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.isProactive = 0,
    this.imagePath = '',
  });

  bool get fromUser => role == 'user';
  bool get isProactiveMessage => isProactive == 1;
  bool get hasImage => imagePath.isNotEmpty;

  Map<String, dynamic> toMap() => {
        'id': id,
        'companion_id': companionId,
        'role': role,
        'content': content,
        'created_at': createdAt,
        'is_proactive': isProactive,
        'image_path': imagePath,
      };

  factory ChatMessage.fromMap(Map<String, dynamic> m) => ChatMessage(
        id: m['id'] as int?,
        companionId: (m['companion_id'] as int?) ?? 0,
        role: (m['role'] as String?) ?? 'assistant',
        content: (m['content'] as String?) ?? '',
        createdAt: (m['created_at'] as int?) ?? 0,
        isProactive: (m['is_proactive'] as int?) ?? 0,
        imagePath: (m['image_path'] as String?) ?? '',
      );
}
