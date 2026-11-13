import 'dart:math';

import '../models/life_state.dart';

/// 一次消息处理完之后的情绪结果。
class MoodResult {
  final MoodState mood;

  /// 这条消息算不算「哄」
  final bool coaxed;

  /// 刚从生气/冷战里缓过来（用来让她说一句不情愿的软话）
  final bool justRecovered;

  const MoodResult({
    required this.mood,
    this.coaxed = false,
    this.justRecovered = false,
  });
}

/// 她的情绪状态机。
///
/// 设计原则：**怒气由「发生了什么」决定，不由模型自由发挥**。
/// 模型只负责「用生气的语气说话」，不负责决定要不要生气——
/// 否则它会在你问「吃饭了吗」的时候突然翻脸，那不像人，像坏掉的玩具。
///
/// 三种来源，都会落到同一个 0~100 的怒气值上：
///   1. 被晾着：她说过话，你很久没回（最符合真实情侣的生气理由）；
///   2. 被伤到：说了难听的话；
///   3. 被敷衍：连着几句「哦」「嗯」。
/// 哄（认错、解释、示弱）会降怒气，时间也会降怒气。
class MoodService {
  // ——— 词表：宁可窄，不要误伤 ———

  /// 真正会扎人的话
  static const List<String> _hurtWords = [
    '滚', '烦不烦', '闭嘴', '别烦我', '讨厌你', '分手',
    '不想理你', '少烦', '跟你说不通', '你很烦', '别来烦',
  ];

  /// 冷暴力型的，没那么扎人但同样让人不舒服
  static const List<String> _coldWords = [
    '随便你', '懒得跟你说', '无所谓', '爱怎样怎样', '你高兴就好',
  ];

  /// 算作哄的说法
  static const List<String> _coaxWords = [
    '对不起', '我错', '别气', '不气', '我哄', '抱抱', '亲亲',
    '抱歉', '原谅', '听我说', '是我不好', '我不该', '别这样',
    '我陪你', '我请你', '带你去', '买给', '想你了', '我改',
  ];

  static bool _hasAny(String text, List<String> words) =>
      words.any(text.contains);

  /// 时间流逝带来的自然消气 + 被晾着带来的怒气。
  ///
  /// 这个函数是**幂等**的：同一次间隔反复调用结果不变，
  /// 所以可以在冷启动、每次发送前都放心调用。
  static MoodState syncWithGap(
    MoodState m, {
    required Duration gap,
    required bool sheSpokeLast,
    required bool overnight,
    int? nowMs,
  }) {
    var anger = m.anger;
    var reason = m.reason;
    var since = m.sinceMs;

    // 1) 时间会消气：每 6 小时降 8，最多降 30
    if (gap.inHours >= 6 && anger > 0) {
      final steps = min(3, gap.inHours ~/ 6);
      anger = max(0, anger - steps * 8);
    }

    // 2) 她说过话、你又很久没回 → 生气。
    //    只在她最后开口的情况下成立：你发完消息去忙了，她没理由怪你。
    if (sheSpokeLast && !overnight) {
      int target = 0;
      String why = '';
      if (gap.inHours >= 72) {
        target = 78;
        why = '你消失了三天才回来';
      } else if (gap.inHours >= 36) {
        target = 62;
        why = '你一天多都没回我';
      } else if (gap.inHours >= 12) {
        target = 44;
        why = '你半天没回我';
      } else if (gap.inHours >= 6) {
        target = 26;
        why = '你大半天没理我';
      }
      if (target > anger) {
        anger = target;
        reason = why;
        since = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      }
    }

    return m.copyWith(anger: anger, reason: reason, sinceMs: since);
  }

  /// 用户发来一条消息之后，情绪怎么变。
  ///
  /// [recentUserTexts] 传最近几条用户消息（不含刚发的这条），用来判断「连续敷衍」。
  static MoodResult afterUserMessage(
    MoodState m, {
    required String text,
    required List<String> recentUserTexts,
  }) {
    final t = text.trim();
    final wasUpset = m.anger >= MoodState.annoyedAt;
    var anger = m.anger;
    var reason = m.reason;
    var coax = m.coaxCount;

    final hurt = _hasAny(t, _hurtWords);
    final coldTone = _hasAny(t, _coldWords);
    final coaxHit = _hasAny(t, _coaxWords);
    final len = t.runes.length;

    // 连着几句都只有三四个字 → 敷衍
    final shortCount =
        recentUserTexts.take(3).where((x) => x.trim().runes.length <= 4).length;
    final slacking = len <= 4 && shortCount >= 2;

    if (hurt) {
      anger += 55;
      reason = '你刚才那句话很伤人';
    } else if (coldTone) {
      anger += 28;
      reason = '你一副无所谓的样子';
    }

    if (coaxHit) {
      // 哄：认真程度跟长度有关，但只要有认错的意思就算数
      anger -= len >= 12 ? 40 : 32;
      coax += 1;
    } else if (hurt || coldTone) {
      // 正在骂人的时候，不因为句子长就给她消气
    } else if (slacking) {
      anger += 10;
      if (reason.trim().isEmpty) reason = '你就这么嗯嗯哦哦地敷衍我';
    } else if (len >= 20) {
      anger -= 16;
    } else if (len >= 8) {
      anger -= 10;
    } else {
      anger -= 6;
    }

    anger = anger.clamp(0, 100);

    // 彻底不气了：清掉理由，避免下次一上来就带着旧账
    if (anger == 0) reason = '';

    final justRecovered = wasUpset && anger < MoodState.annoyedAt;

    return MoodResult(
      mood: m.copyWith(anger: anger, reason: reason, coaxCount: coax),
      coaxed: coaxHit,
      justRecovered: justRecovered,
    );
  }

  /// 冷战期间，这次到底要不要甩一个表情，还是干脆一声不吭。
  ///
  /// 轮次是从「刚开始生气」算起的：
  ///   1 → 😤（明确告诉你她生气了）
  ///   2 → 不回（真晾着）
  ///   3 → 😑（你要是还没反应，她再哼一声）
  ///   4+ → 每三轮一个表情，其余不回
  static String? coldSticker({
    required int coldTurns,
    required bool coaxed,
  }) {
    if (coaxed) {
      // 哄了但还是气：给一个松动信号（🥺），但依然不说话
      return coldTurns <= 2 ? '🥺' : null;
    }
    if (coldTurns == 1) return '😤';
    if (coldTurns == 3) return '😑';
    if (coldTurns > 3 && coldTurns % 3 == 0) return '🙄';
    return null;
  }

  /// 写进 system prompt 的情绪段落。空字符串 = 不注入。
  static String promptBlock(MoodState m, {bool justRecovered = false}) {
    // 冷战时不调模型，这里不该被用到；兜底也返回空
    if (m.isCold) return '';

    if (justRecovered) {
      return '''
【你此刻的情绪】
你刚被他哄好，其实还有点别扭。别一下子热情起来，可以说一句不情愿的软话
（「算了」「这次就饶了你」这种），然后正常聊。不要提「我在生气」，也不要复盘刚才的争执。
''';
    }

    final why = m.reason.trim().isEmpty ? '说不上具体为什么，就是有点不痛快' : m.reason;

    if (m.isAngry) {
      return '''
【你此刻的情绪】
你现在在生气。原因：$why。
- 回得比平时短，最多一两句，不要成段。
- 不主动关心他，不主动找新话题。
- 不要解释自己为什么生气，也不要出现「我在生气」这几个字。
- 他认真哄你，可以松一点，但还是别扭；他敷衍，你就更冷。
- 可以阴阳一句、可以只回「哦」「行吧」，但不许骂人、不许说教、不许讲道理。
''';
    }

    if (m.isAnnoyed) {
      return '''
【你此刻的情绪】
你有点不爽。原因：$why。
语气比平时冷一点、短一点，别主动找话题；他哄一两句就恢复正常，不用一直端着。
''';
    }

    return '';
  }

  /// AppBar 上那行状态字。
  static String faceLabel(MoodState m) => m.faceLabel;
}
