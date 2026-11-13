import '../data/emoji_kit.dart';
import '../models/memory_chunk.dart';
import '../models/message.dart';
import '../models/speech_profile.dart';
import '../models/user_note.dart';
import 'chat_images.dart';

/// 把「人设 + 行为手册 + 旧事摘要 + 说话风格 + 最近原文」拼成一次请求。
///
/// 关键约束：system 里塞太多摘要/条目会把人设指令稀释掉，模型就开始前言不搭后语。
/// 所以手册和摘要都有硬性上限，最后再补一条「把话说清楚」的强约束。
class ContextBuilder {
  /// 记忆窗口：最近多少句纳入记忆范围（默认 1000，可在设置里调）。
  static const int defaultWindow = 1000;

  /// 每次请求最多直发多少条原文。
  static const int maxRawTurns = 60;

  /// 直发原文的累计字符预算（中文 1 字 ≈ 1~1.5 token）。
  static const int maxRawChars = 12000;

  /// 行为手册最多带多少条。
  static const int maxNoteCount = 20;

  /// 旧事摘要累计字符上限，防止越聊越稀释人设。
  static const int maxSummaryChars = 3000;

  /// 最近多少张图片随请求发原图（每张图要花不少 token，更早的只留文字标记）。
  static const int maxImageAttachments = 4;

  static String buildSystem({
    required String persona,
    required List<UserNote> notes,
    required List<MemoryChunk> chunks,
    required int window,
    int emojiLevel = 2,
    SpeechProfile? speech,
  }) {
    final b = StringBuffer(persona.trim());

    if (notes.isNotEmpty) {
      b.writeln('\n\n【关于对方，你长期记住的事】');
      b.writeln('（只作为背景，不要主动提起、不要一条条报出来，也不要堆进同一句里）');
      for (final n in notes.take(maxNoteCount)) {
        b.writeln('- [${n.category}] ${n.content}');
      }
    }

    if (chunks.isNotEmpty) {
      // 摘要按时间从新往旧取，控制总字数，别把人设稀释掉
      var used = 0;
      final picked = <MemoryChunk>[];
      for (final c in chunks.reversed) {
        if (used + c.summary.length > maxSummaryChars && picked.isNotEmpty) {
          break;
        }
        picked.add(c);
        used += c.summary.length;
      }
      b.writeln('\n\n【更久以前的记忆摘要】');
      b.writeln('（按时间顺序，都是你们真实发生过的事，可以自然提起）');
      for (final c in picked.reversed) {
        b.writeln('- ${c.summary}');
      }
    }

    if (speech != null && !speech.isEmpty) {
      b.writeln('\n\n【对方平时怎么说话】');
      b.writeln('（后台默默观察到的语言习惯，只用来让对话节奏贴合；不要复述这些条目，'
          '不要当成关于 TA 的事实，更不要改变你自己定好的性格与说话方式）');
      b.writeln(speech.renderForPrompt());
      b.writeln('回复时自然贴近对方的句长和节奏，但永远保持你自己的人设。');
    }

    b.writeln('\n\n【看图】对方可能会给你发照片。看到图片就自然地聊它：'
        '说说你看到了什么、你的感受或好奇的地方，像朋友收到照片一样；'
        '看不清的地方可以问，不要硬编图片里没有的细节。');

    b.writeln('\n\n【记忆范围】你记得最近约 $window 句对话，更早的事在上面摘要里。'
        '不要声称记得摘要和最近对话里都没出现的细节。');

    b.writeln('\n\n${EmojiKit.aiRules(emojiLevel)}');

    b.writeln('\n\n【把话说清楚 · 最重要】');
    b.writeln('一次只回 1~3 句、总共不超过 60 个字，像发微信，绝对不要写成长段落。');
    b.writeln('用清楚、完整的普通话短句，一句说完再说下一句；'
        '不要跳跃、不要只说半句、不要堆无意义的词、不要突然换话题，'
        '不要编造没聊过的人名、地点、事件，不要把不相关的词拼在一起。');
    b.writeln('没听懂对方在说什么时，自然追问一句，别硬接。');

    return b.toString();
  }

  /// 从窗口里取最近若干条原文，按字符预算从新往旧截，保持时间正序。
  /// 截断后若开头是 assistant，去掉——避免模型从「接自己的话」开始。
  ///
  /// 带图片的消息：最近 maxImageAttachments 张随请求发原图（多模态数组），
  /// 更早的图片消息在文字里留个 [图片] 标记。图片读不出来就当纯文字处理。
  static Future<List<Map<String, dynamic>>> buildTurns(
    List<ChatMessage> windowMessages, {
    int maxTurns = maxRawTurns,
    int maxChars = maxRawChars,
  }) async {
    final picked = <ChatMessage>[];
    var chars = 0;
    for (int i = windowMessages.length - 1; i >= 0; i--) {
      final m = windowMessages[i];
      final len = m.content.length;
      if (picked.length >= maxTurns) break;
      if (chars + len > maxChars && picked.isNotEmpty) break;
      picked.add(m);
      chars += len;
    }

    // 只有最近几张图才真发原图
    var imageQuota = maxImageAttachments;

    final turns = <Map<String, dynamic>>[];
    for (final m in picked.reversed) {
      if (m.hasImage && imageQuota > 0) {
        imageQuota--;
        final url = await ChatImages.instance.dataUrl(m.imagePath);
        if (url != null) {
          final caption = m.content.trim();
          turns.add({
            'role': m.fromUser ? 'user' : 'assistant',
            'content': [
              {
                'type': 'text',
                'text': caption.isEmpty ? '（发了一张图片，你看看）' : caption,
              },
              {'type': 'image_url', 'image_url': {'url': url}},
            ],
          });
          continue;
        }
        // 图丢了就降级成文字
      }

      var text = m.content.trim();
      if (m.hasImage) text = '[图片] $text'.trim();
      if (text.isEmpty) continue;
      turns.add({
        'role': m.fromUser ? 'user' : 'assistant',
        'content': text,
      });
    }

    while (turns.isNotEmpty && turns.first['role'] == 'assistant') {
      turns.removeAt(0);
    }
    return turns;
  }
}
