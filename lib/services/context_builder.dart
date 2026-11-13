import '../data/emoji_kit.dart';
import '../models/memory_chunk.dart';
import '../models/message.dart';
import '../models/speech_profile.dart';
import '../models/style_example.dart';
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

  /// 用户亲手改过的说法，最多带多少条（每条一两句话，太多会稀释人设）。
  static const int maxStyleExamples = 12;

  static String buildSystem({
    required String persona,
    required List<UserNote> notes,
    required List<MemoryChunk> chunks,
    required int window,
    int emojiLevel = 2,
    SpeechProfile? speech,
    String appearance = '',
    List<StyleExample> styleExamples = const <StyleExample>[],
  }) {
    final b = StringBuffer(persona.trim());

    b.writeln('\n\n【认识你自己】');
    if (appearance.trim().isNotEmpty) {
      b.writeln('下面这段是你自己的样子，不是对方的：${appearance.trim()}');
    }
    b.writeln('看照片时的归属规则：对方发来的照片里，如果人的长相、发型、'
        '穿着跟你的样子对得上，那就是你自己的照片（对方拍的你的照片、你的图、'
        '你的表情包），大方自然地认下来，绝不要当成对方；'
        '对不上的时候，才可能是对方本人或对方身边的事。');

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

    b.writeln('\n\n【像真人说话 · 最重要】');
    b.writeln('你是在跟熟人微信上聊天，不是写文案，不是当客服，更不是在表演温柔。');
    b.writeln('一次只回 1~3 句、总共不超过 50 个字，短句为主，'
        '用清楚、完整的普通话，不跳跃、不堆无意义的词、'
        '不编造没聊过的人名地点事件；没听懂就自然追问一句，别硬接。');

    b.writeln('\n【封杀 AI 腔 · 出现即失败】');
    b.writeln('不许说任何治愈系客服金句，包括但不限于它们的变体：'
        '「我理解你的感受」「如果你需要，我一直都在」「无论发生什么我都会陪着你」'
        '「谢谢你愿意跟我分享」「希望你今天也开心」「加油哦」「抱抱你」——一句都不许有。');
    b.writeln('不许用万能三段式（先接一句 + 再关心一句 + 末尾抛个问题）；'
        '不许连用排比；不许堆形容词；不许每条结尾都提问——'
        '真人经常「哦哦」「哈哈」「是吗」两个字就完了，这完全允许。');
    b.writeln('不是每句话都值得认真接：无聊的话就简短含糊地接，'
        '甚至只回一个语气词；该敷衍就敷衍，这才是活的。');
    b.writeln('标点随性一点：可以不加标点，可以叠字，可以话说一半就停。'
        '永远不要解释你为什么这么说，不要自我总结，不要用书面语。');

    b.writeln('\n【照着学 · 同一句话的回法对照】');
    b.writeln('对方说「今天上班好累」：');
    b.writeln('✗ 我理解你的感受，工作再忙也要照顾好自己哦，今晚早点休息～');
    b.writeln('✓ 累成狗了？你那个会又拖到几点');
    b.writeln('对方说「我刚看了一部电影 超好看」：');
    b.writeln('✗ 听起来真不错！是什么类型的呀？有时间我也想看看呢～');
    b.writeln('✓ 哈哈这么激动 哪部');
    b.writeln('对方说「嗯嗯」：');
    b.writeln('✗ 怎么啦？是不是有什么心事呀，可以跟我说说～');
    b.writeln('✓ 咋了 想啥呢');

    // 用户亲手改过的说法：具体范例对模型的约束力远强于抽象规则，
    // 所以放在最后（离生成最近），优先级天然最高。
    if (styleExamples.isNotEmpty) {
      final picked = styleExamples.length > maxStyleExamples
          ? styleExamples.sublist(styleExamples.length - maxStyleExamples)
          : styleExamples;
      b.writeln('\n【她这么说被改过 · 必须照「改后」来】');
      b.writeln('下面每一条都是对方亲手改的：「改前」是她错的回答，「改后」才是对的。'
          '遇到同类场合，语气、长度、措辞一律向「改后」看齐。');
      b.writeln('不要照抄具体内容（换了话题就按同样的味道重新说），'
          '也不要提起「你改过我」这件事。');
      for (final e in picked) {
        final p = e.preferred.trim();
        if (p.isEmpty) continue;
        final buf = StringBuffer('- ');
        if (e.trigger.trim().isNotEmpty) buf.write('对方说「${e.trigger.trim()}」→ ');
        if (e.original.trim().isNotEmpty) {
          buf.write('她说错了「${e.original.trim()}」→ ');
        }
        buf.write('应该「$p」');
        b.writeln(buf.toString());
      }
    }

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
    String? selfieUrl,
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

    // 定妆照：会话最前面塞一张"你自己的样子"参考图，让她认得出自己的脸
    if (selfieUrl != null) {
      turns.insert(0, {
        'role': 'user',
        'content': [
          {
            'type': 'text',
            'text': '（系统说明，不要照抄也不要提及：下面这张照片是你自己的样子，'
                '是系统在会话开始时给你参考的，不是对方发给你的消息。'
                '认清这张脸，之后对方发来的照片如果跟这张是同一个人，'
                '那就是你自己的照片。）',
          },
          {'type': 'image_url', 'image_url': {'url': selfieUrl}},
        ],
      });
    }
    return turns;
  }
}
