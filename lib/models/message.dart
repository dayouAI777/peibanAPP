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

  /// 只有表情、没有字：生气时她只甩一个 😤，这种消息在界面上要放大显示，
  /// 不能塞进一个小气泡里像条文字。
  static final RegExp _emojiOnly = RegExp(
    r'^[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}\u{2764}\u{2049}\u{203C}]+$',
    unicode: true,
  );

  bool get isSticker {
    final t = content.trim();
    if (t.isEmpty || t.runes.length > 3) return false;
    return _emojiOnly.hasMatch(t);
  }

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
