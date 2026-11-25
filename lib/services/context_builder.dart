import '../data/emoji_kit.dart';
import '../models/memory_chunk.dart';
import '../models/message.dart';
import '../models/speech_profile.dart';
import '../models/style_example.dart';
import '../models/style_profile.dart';
import '../models/user_note.dart';
import 'chat_images.dart';
import 'prompt_budget.dart';
import 'speech_profile_service.dart';

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

  /// 用过滤后的口头禅渲染说话方式段（其余字段与 SpeechProfile.renderForPrompt 一致）。
  static String _renderSpeechWithPhrases(
    SpeechProfile s,
    List<String> phrases,
  ) {
    final b = StringBuffer();
    if (s.sentenceLength.isNotEmpty) b.writeln('- 句子长短：${s.sentenceLength}');
    if (s.tone.isNotEmpty) b.writeln('- 语气：${s.tone}');
    if (phrases.isNotEmpty) {
      b.writeln('- 常说的话 / 口头禅：${phrases.join('、')}');
    }
    if (s.punctuation.isNotEmpty) b.writeln('- 标点与表情习惯：${s.punctuation}');
    if (s.rhythm.isNotEmpty) b.writeln('- 说话节奏：${s.rhythm}');
    if (s.notes.isNotEmpty) b.writeln('- 其他：${s.notes}');
    return b.toString();
  }

  static String buildSystem({
    required String persona,
    required List<UserNote> notes,
    required List<MemoryChunk> chunks,
    required int window,
    int emojiLevel = 2,
    SpeechProfile? speech,
    String appearance = '',
    List<StyleExample> styleExamples = const <StyleExample>[],
    StyleProfile? styleProfile,
    String nowBlock = '',
    String gapBlock = '',
    String moodBlock = '',
    String selfBlock = '',
    /// 仅供 D3 诊断/测试：`false` = 拼「改动前」的口径（不带 self 段、不带 R5 三行）。
    bool withNewBlocks = true,
  }) {
    String compose({required int dropOldestChunks, required bool newBlocks}) =>
        _compose(
          persona: persona,
          notes: notes,
          chunks: chunks,
          window: window,
          emojiLevel: emojiLevel,
          speech: speech,
          appearance: appearance,
          styleExamples: styleExamples,
          styleProfile: styleProfile,
          nowBlock: nowBlock,
          gapBlock: gapBlock,
          moodBlock: moodBlock,
          selfBlock: selfBlock,
          dropOldestChunks: dropOldestChunks,
          withNewBlocks: newBlocks,
        );

    // 「改动前」在运行时算得出来：同样的输入、不带新加的三处再拼一遍。
    final base = compose(dropOldestChunks: 0, newBlocks: false);
    if (!withNewBlocks) return base;

    // ——— D3 收口：总字数 ≤ baseline × 1.10，不放宽 ———
    //
    // 超线**只丢最旧的旧事摘要（chunk）**，绝不砍 persona / self / notes——那三样
    // 是"她是谁"的根据，砍了就等于换了个人。摘要丢光还超线（正常不会发生）就如实
    // 留着，不偷偷动人设。
    //
    // ⚠️ **"砍光还超线就留着"是有意的，不许改成"那就砍 self"**。
    // 这条约束防的是"新增块把 prompt 撑爆"，不是"必须在任何输入下都 ≤110%"：
    // 真到了摘要砍光还超线的地步，说明 baseline 本来就小得离谱（比如 0 条摘要 +
    // 极短人设），这时候**宁可超线也不许动 self**——动 self 就是拿"她是谁"去换一个
    // 字数指标，那是本末倒置。改这里之前请先看 `context_budget_test.dart` 的
    // "砍到线内为止"那条测试，它同时钉了上界（不许砍太多）。
    final cap = base.length * PromptBudget.maxPromptRatio;
    var out = compose(dropOldestChunks: 0, newBlocks: true);
    var drop = 0;
    while (out.length > cap && drop < chunks.length) {
      drop++;
      final retried = compose(dropOldestChunks: drop, newBlocks: true);
      // 丢一条摘要省不出字（摘要已被预算挡在门外）→ 长度不变，别死循环。
      if (retried.length >= out.length) {
        out = retried;
        break;
      }
      out = retried;
    }
    return out;
  }

  /// 真正的拼装。`dropOldestChunks` = 为了 D3 从摘要里**从旧到新**丢掉几条；
  /// `withNewBlocks=false` 表示「改动前」的口径（不带 self 段、不带 R5 三行）。
  static String _compose({
    required String persona,
    required List<UserNote> notes,
    required List<MemoryChunk> chunks,
    required int window,
    int emojiLevel = 2,
    SpeechProfile? speech,
    String appearance = '',
    List<StyleExample> styleExamples = const <StyleExample>[],
    /// 她的说话方式档案：全部范例的长期蒸馏结果（机器产物，全量注入）。
    StyleProfile? styleProfile,
    /// 【现在】这一段：几号、几点、这个点在干嘛、这个点不能说什么。
    String nowBlock = '',
    /// 距上次说话隔了多久，以及该怎么开口。
    String gapBlock = '',
    /// 她此刻的情绪（生气/不爽/刚被哄好）。
    String moodBlock = '',
    /// R2 自我认知段（self 聚合视图，≤360 字）。位置在【认识你自己】之前：
    /// persona → 【现在】 → 【我知道我是谁】 → 原【认识你自己】 → 关于对方…
    /// 内容由 SelfService 生成，调用方传进来；这里只负责位置与收尾句。
    String selfBlock = '',
    required int dropOldestChunks,
    required bool withNewBlocks,
  }) {
    final b = StringBuffer(persona.trim());

    if (nowBlock.trim().isNotEmpty) {
      b.writeln('\n\n$nowBlock');
    }

    // R2：自我描述独立成段，硬上限 360 字由 SelfComposer 保证；这里只截断兜底，
    // 绝不碰 persona 正文（B3：注入前后 prompt 首 200 字一致）。
    if (withNewBlocks && selfBlock.trim().isNotEmpty) {
      b.writeln('\n\n【我知道我是谁】');
      final s = selfBlock.trim();
      b.writeln(s.length > 360 ? s.substring(0, 360) : s);
      b.writeln('以上是你的自我描述。你不需要向对方解释、复述或朗读它；'
          '被问到时用你自己的话随口说，不要背。');
    }

    b.writeln('\n\n【认识你自己】');
    if (appearance.trim().isNotEmpty) {
      b.writeln('下面这段是你自己的样子，不是对方的：${appearance.trim()}');
    }
    b.writeln('看照片时的归属规则：对方发来的照片里，如果人的长相、发型、'
        '穿着跟你的样子对得上，那就是你自己的照片（对方拍的你的照片、你的图、'
        '你的表情包），大方自然地认下来，绝不要当成对方；'
        '对不上的时候，才可能是对方本人或对方身边的事。');

    // 关于对方长期记住的事：排序责任在 pickNotes 内部（设计 §6.1）。
    // 这里**传原始顺序**，绝不预排序——乱序是合法输入，函数自己给出确定结果。
    // 近况（category=近况）前 ≤5 条优先占位，其余补足到 20，总数永不超过 20。
    final pickedNotes = PromptBudget.pickNotes(notes);
    if (pickedNotes.isNotEmpty) {
      b.writeln('\n\n【关于对方，你长期记住的事】');
      b.writeln('（只作为背景，不要主动提起、不要一条条报出来，也不要堆进同一句里）');
      for (final n in pickedNotes) {
        final content = n.content.length > PromptBudget.maxNoteContentChars
            ? n.content.substring(0, PromptBudget.maxNoteContentChars)
            : n.content;
        b.writeln('- [${n.category}] $content');
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
      // D3 收口：从**最旧**的开始丢（picked 是新→旧，所以丢尾部几条）。
      final keepCount = dropOldestChunks >= picked.length
          ? 0
          : picked.length - dropOldestChunks;
      final kept = keepCount == 0 ? <MemoryChunk>[] : picked.sublist(0, keepCount);
      if (kept.isNotEmpty) {
        b.writeln('\n\n【更久以前的记忆摘要】');
        b.writeln('（按时间顺序，都是你们真实发生过的事，可以自然提起）');
        for (final c in kept.reversed) {
          b.writeln('- ${c.summary}');
        }
      }
    }

    if (speech != null && !speech.isEmpty) {
      b.writeln('\n\n【对方平时怎么说话】');
      b.writeln('（后台默默观察到的语言习惯，只用来让对话节奏贴合；不要复述这些条目，'
          '不要当成关于 TA 的事实，更不要改变你自己定好的性格与说话方式）');
      // R5/E4：口头禅与人设冲突过滤（纯字符串规则，不调模型）。
      // persona 里出现「话少/不撒娇/冷淡/直接」等词时，丢掉「宝宝/绝绝子」这类
      // 撒娇叠词，避免她一边冷一边卖萌。渲染的还是同一个 SpeechProfile 结构。
      final keptPhrases = SpeechProfileService.filterCatchphrases(
          speech.catchphrases, persona);
      b.writeln(_renderSpeechWithPhrases(speech, keptPhrases));
      b.writeln('回复时自然贴近对方的句长和节奏，但永远保持你自己的人设。');
      if (withNewBlocks) {
        // R5 / E2 两条硬约束：照设计 §R5 的**断言原文**写，一个字不加。
        // （"你和 TA 是两个人" 已经在句子里，不为迁就断言把句子写啰嗦。）
        b.writeln('【只对齐节奏】只对齐句长和节奏，不模仿对方的用词、情绪和态度；'
            '你和 TA 是两个人。');
        b.writeln('和上面的自我描述冲突时，以你自己的描述为准。');
      }
    }

    b.writeln('\n\n【看图】对方可能会给你发照片。看到图片就自然地聊它：'
        '说说你看到了什么、你的感受或好奇的地方，像朋友收到照片一样；'
        '看不清的地方可以问，不要硬编图片里没有的细节。');

    b.writeln('\n\n【记忆范围】你记得最近约 $window 句对话，更早的事在上面摘要里。'
        '不要声称记得摘要和最近对话里都没出现的细节。');

    b.writeln('\n\n${EmojiKit.aiRules(emojiLevel)}');

    if (gapBlock.trim().isNotEmpty) {
      b.writeln('\n\n【你们上次说话是什么时候】');
      b.writeln(gapBlock.trim());
      b.writeln('（时间标记说明：history 里形如 [11-12 21:30] 的前缀是那句话的真实发送时间。'
          '只有间隔超过两小时的地方才会出现标记。）');
    }

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

    if (moodBlock.trim().isNotEmpty) {
      b.writeln('\n\n${moodBlock.trim()}');
    }

    // R5 信号优先级与降权：prompt 内显式写入裁决顺序（PRD 原文口径）。
    if (withNewBlocks) {
      b.writeln('\n【信号优先级 · 冲突时怎么取舍】');
      b.writeln('几处信息互相打架时，优先级从高到低：'
          'style_example > self > style_profile > speech_profile。'
          '自下而上让位，不得反过来。');
    }

    // 她的说话方式档案：全部 style_examples 的长期蒸馏产物（前面会定期用
    // 模型把用户历次手工修改合并成这份档案）。档案是长期规律，范例是最新鲜
    // 标杆——所以档案在前、范例在后，冲突时以范例为准。
    if (styleProfile != null && !styleProfile.isEmpty) {
      b.writeln('\n【她的说话方式 · 长期形成的习惯（从对方历次修改中学到的）】');
      b.writeln('（下面是对方在一次次亲手修改里长期沉淀出的你的说话规律，'
          '照这个习惯说话。学的是味道，不是答案：换个话题也照这个习惯说新话。'
          '不要复述这些条目，也不要提起「你被修改过」；'
          '它和后面最新的范例不一致时，以范例为准。）');
      b.writeln(styleProfile.renderForPrompt().trimRight());
    }

    // 用户亲手改过的说法：具体范例对模型的约束力远强于抽象规则，
    // 所以放在最后（离生成最近），优先级天然最高。
    //
    // 这里刻意**只给「该怎么说」，不给「她原来那句错的」**：
    // 把错句也塞进来，模型很容易把错句的表面特征复读一遍（尤其短上下文里），
    // 而且对照表形式会让它误以为是「遇到这句话就答那句话」的检索题。
    // 用户要的是学会说话方式，不是固定回答——所以范例只当语气标杆。
    if (styleExamples.isNotEmpty) {
      final picked = styleExamples.length > maxStyleExamples
          ? styleExamples.sublist(styleExamples.length - maxStyleExamples)
          : styleExamples;
      b.writeln('\n【她这个人的说话方式 · 照这个味道说，别背答案】');
      b.writeln('下面每一条，都是对方亲手把她的话改成了自己认的样子。'
          '学的是**语气、长度、用词、态度**，不是把这句当标准答案存起来。');
      b.writeln('换个话题、换个说法，也要用同样的味道说新的话：'
          '该短就短，该糙就糙，该不接话就不接话。'
          '不要照抄原句，也不要提起「你改过我」。');
      for (final e in picked) {
        final p = e.preferred.trim();
        if (p.isEmpty) continue;
        final t = e.trigger.trim();
        if (t.isEmpty) {
          b.writeln('- 她会这么说：「$p」');
        } else {
          b.writeln('- 对方说「$t」这种话的时候，她会这么说：「$p」');
        }
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
    bool showTimeMarks = true,
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
    int? prevMs;

    /// 间隔超过两小时才打时间戳：正常连着聊的地方保持干净，
    /// 只在「隔了很久」的位置提醒模型——这是"像正在发生"的关键线索。
    String markFor(ChatMessage m) {
      final prev = prevMs;
      prevMs = m.createdAt;
      if (!showTimeMarks || prev == null) return '';
      if (m.createdAt - prev < const Duration(hours: 2).inMilliseconds) {
        return '';
      }
      final t = DateTime.fromMillisecondsSinceEpoch(m.createdAt);
      final mm = t.month.toString().padLeft(2, '0');
      final dd = t.day.toString().padLeft(2, '0');
      final hh = t.hour.toString().padLeft(2, '0');
      final mi = t.minute.toString().padLeft(2, '0');
      return '[$mm-$dd $hh:$mi] ';
    }

    for (final m in picked.reversed) {
      final mark = markFor(m);

      if (m.hasImage && imageQuota > 0) {
        imageQuota--;
        final url = await ChatImages.instance.dataUrl(m.imagePath);
        if (url != null) {
          final caption = m.content.trim();
          final text = caption.isEmpty ? '（发了一张图片，你看看）' : caption;
          turns.add({
            'role': m.fromUser ? 'user' : 'assistant',
            'content': [
              {
                'type': 'text',
                'text': '$mark$text',
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
        'content': '$mark$text',
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
