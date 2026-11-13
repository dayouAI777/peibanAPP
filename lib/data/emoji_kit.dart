/// 内置表情库。用系统 emoji 实现，不需要图片资源，双端显示一致。
/// 同一套表情既给用户点选，也作为 AI 回复时的可用池，风格才统一。
class EmojiGroup {
  final String label;
  final List<String> emojis;

  const EmojiGroup(this.label, this.emojis);
}

class EmojiKit {
  static const List<EmojiGroup> groups = [
    EmojiGroup('开心', ['😊', '😄', '🥰', '😆', '✨', '🌸', '🎉', '🍀']),
    EmojiGroup('撒娇', ['🥺', '😚', '🫣', '💕', '🐾', '🙈', '🍡', '🫶']),
    EmojiGroup('想你', ['💭', '💌', '🌙', '🌠', '💗', '⭐', '🌌', '🕯️']),
    EmojiGroup('委屈', ['😢', '😞', '🥲', '💧', '😿', '🫥', '🌧️', '🩹']),
    EmojiGroup('闹别扭', ['😤', '😠', '🙄', '💢', '😾', '🔥', '🫤', '⚡']),
    EmojiGroup('害羞', ['😳', '☺️', '🫠', '🌷', '💞', '😌', '🍬', '🍓']),
    EmojiGroup('无语', ['😑', '😐', '😶', '🙃', '🫡', '😴', '💤', '🪨']),
    EmojiGroup('日常', ['☕', '🍃', '🎧', '📖', '🛋️', '🧸', '🍜', '🚶']),
  ];

  static List<String> get all => [
        for (final g in groups) ...g.emojis,
      ];

  /// 0 = 关，1 = 偶尔（默认），2 = 常用。
  static String labelOf(int level) => const ['不用表情', '偶尔用', '常用'][level];

  /// 注入 system prompt 的规矩：让角色会带表情，但不滥用。
  static String aiRules(int level) {
    final pool = all.join(' ');
    if (level <= 0) {
      return '【表情】这一版不要用任何表情符号，纯文字说话。';
    }
    if (level >= 2) {
      return '''
【表情】你可以自然地使用表情，让语气更像发微信。
可用表情（优先从这里挑）：$pool
规矩：一条消息最多带 1~2 个，放在句末或语气停顿处；贴合当下的情绪，不要随机乱贴；
不要用表情代替要说的话，不要连着堆一串，不要每句都带；不要解释自己为什么用表情。''';
    }
    return '''
【表情】可以偶尔用表情，让语气更活一点，但别滥用。
可用表情（优先从这里挑）：$pool
规矩：不是每条都要带，大约三四条里带一条就够；一条最多 1 个，放在句末；
要贴合当下情绪；不要用表情代替要说的话，不要连着堆一串，不要解释自己为什么用表情。''';
  }
}
