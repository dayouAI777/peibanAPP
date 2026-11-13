import '../data/emoji_kit.dart';
import '../models/memory_chunk.dart';
import '../models/message.dart';
import '../models/user_note.dart';

/// 把「人设 + 行为手册 + 旧事摘要 + 最近原文」拼成一次请求。
/// 为什么不把 1000 句原文全发过去：DeepSeek 上下文有限，且按输入字数计费，
/// 每次塞满会又慢又贵。做法是：旧对话压成摘要永久带着，最近原文按字符预算直发。
class ContextBuilder {
  /// 记忆窗口：最近多少句纳入记忆范围（默认 1000，可在设置里调）。
  static const int defaultWindow = 1000;

  /// 每次请求最多直发多少条原文。
  static const int maxRawTurns = 60;

  /// 直发原文的累计字符预算（中文 1 字 ≈ 1~1.5 token）。
  static const int maxRawChars = 12000;

  static String buildSystem({
    required String persona,
    required List<UserNote> notes,
    required List<MemoryChunk> chunks,
    required int window,
    int emojiLevel = 1,
  }) {
    final b = StringBuffer(persona.trim());

    if (notes.isNotEmpty) {
      b.writeln('\n\n【关于对方，你长期记住的事】');
      b.writeln('（反复确认过的稳定习惯，不是随口一提。自然地用，别生硬复述，更不要一条条报出来）');
      for (final n in notes.take(40)) {
        b.writeln('- [${n.category}] ${n.content}');
      }
    }

    if (chunks.isNotEmpty) {
      b.writeln('\n\n【更久以前的记忆摘要】');
      b.writeln('（按时间顺序，都是你们真实发生过的事，可以自然提起）');
      for (final c in chunks) {
        b.writeln('- ${c.summary}');
      }
    }

    b.writeln('\n\n【记忆范围】你记得最近约 $window 句对话，更早的事在上面摘要里。'
        '不要声称记得摘要和最近对话里都没出现的细节。');

    b.writeln('\n\n${EmojiKit.aiRules(emojiLevel)}');
    return b.toString();
  }

  /// 从窗口里取最近若干条原文，按字符预算从新往旧截，保持时间正序。
  static List<Map<String, String>> buildTurns(
    List<ChatMessage> windowMessages, {
    int maxTurns = maxRawTurns,
    int maxChars = maxRawChars,
  }) {
    final picked = <ChatMessage>[];
    var chars = 0;
    for (int i = windowMessages.length - 1; i >= 0; i--) {
      final m = windowMessages[i];
      if (m.content.trim().isEmpty) continue;
      final len = m.content.length;
      if (picked.length >= maxTurns) break;
      if (chars + len > maxChars && picked.isNotEmpty) break;
      picked.add(m);
      chars += len;
    }
    return picked.reversed
        .map((m) => <String, String>{
              'role': m.fromUser ? 'user' : 'assistant',
              'content': m.content,
            })
        .toList();
  }
}
