import 'dart:math';

import '../models/life_state.dart';

/// 她的作息类型。从人设的「身份」和「生活习惯」里认，认不出来按上班族算。
enum Rhythm { student, office, freelance, shift }

/// 把「现在几点」翻译成她能理解的生活处境，并提供两件事：
///   1. 这个点她大概在干什么（activity）；
///   2. 这个点绝对不能说什么（rules）——这是防她「晚上八点还在公司摸鱼」的关键。
///
/// 纯函数，不读磁盘、不联网，方便写测试。
class ClockService {
  // ——— 时间格式化 ———

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String weekdayCn(int w) =>
      const ['', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'][w];

  static String periodOf(int hour) {
    if (hour < 5) return '凌晨';
    if (hour < 7) return '清晨';
    if (hour < 9) return '早上';
    if (hour < 11) return '上午';
    if (hour < 13) return '中午';
    if (hour < 17) return '下午';
    if (hour < 19) return '傍晚';
    if (hour < 23) return '晚上';
    return '深夜';
  }

  static String stampOf(DateTime t) =>
      '${t.month}月${t.day}日 ${weekdayCn(t.weekday)} '
      '${_two(t.hour)}:${_two(t.minute)}';

  static String dayKey(DateTime t) =>
      '${t.year}${_two(t.month)}${_two(t.day)}';

  // ——— 作息类型 ———

  static Rhythm rhythmOf(String identity, String habits) {
    final s = '$identity $habits';
    bool has(List<String> keys) => keys.any(s.contains);

    if (has(['夜班', '晚班', '倒班', '轮班', '值夜'])) return Rhythm.shift;
    if (has(['学生', '大学', '研究生', '读研', '考研', '大二', '大三', '大四',
        '高中', '上课', '宿舍', '图书馆'])) {
      return Rhythm.student;
    }
    if (has(['自由职业', '自由撰稿', '在家办公', '远程', '博主', '作家',
        '自媒体', '开网店', '接单', '画师', '设计师'])) {
      return Rhythm.freelance;
    }
    return Rhythm.office;
  }

  // ——— 此刻快照 ———

  static LifeState describe({
    required DateTime now,
    LifeEvent? event,
    String identity = '',
    String habits = '',
  }) {
    final rhythm = rhythmOf(identity, habits);
    final workday = now.weekday <= 5;

    // 只有真正覆盖当前时刻的安排才算数（明天才出发的旅行，今天不提）
    final active = (event != null && event.covers(now)) ? event : null;

    final h = now.hour + now.minute / 60.0;
    // 同一天内状态要稳定，不能每分钟换一种说法 → 用日期做种子
    final seed = now.year * 10000 + now.month * 100 + now.day;

    final activity = _activityOf(
      rhythm: rhythm,
      h: h,
      workday: workday,
      event: active,
      seed: seed,
    );

    final rules = <String>[];
    rules.add('你有一个真实的作息：该上班上班、该吃饭吃饭、该睡觉睡觉。'
        '你是人，不是 24 小时在线的客服，也不会一直守在手机前面。');

    if (active != null) {
      rules.add('你这会儿的实际情况是「${active.title}」：${active.detail}。'
          '聊到的时候自然带出来就行，不要反复强调，更不要主动汇报行程。');
      if (active.isTravel) {
        rules.add('这几天你不在家、也不在工作。绝对不要提上班、开会、加班、回家做饭。');
      }
      if (active.kind == 'sick') {
        rules.add('你身体不太舒服，说话会短、没力气，别装活力，也别一直强调自己病了。');
      }
      if (active.kind == 'overtime') {
        rules.add('今天被事情拖住了，这个点还在公司是合理的，可以说累、说想走。');
      }
    }

    final overtime = active != null && active.kind == 'overtime';

    if (h >= 23.5 || h < 6) {
      rules.add('现在是深夜，正常人这个点已经睡了。你多半是被消息吵醒的：'
          '回复要短、带困意，别突然长篇大论，更别声称自己在忙工作。');
    }
    if (workday && h >= 19 && !overtime) {
      rules.add('这个点早就下班了——不许说自己在公司、在开会、在加班。'
          '（除非「刚才的实际情况」里明确写了加班）');
    }
    if (workday && h >= 9 && h < 18 && active == null) {
      rules.add('现在是上班时间，你不是随时能秒回的，回得短一点、慢一点很正常。');
    }
    if (!workday) {
      rules.add('今天是周末，不要说自己在上班、开会、通勤。');
    }
    if (h >= 11.5 && h < 13) {
      rules.add('现在是饭点，可以自然提到在吃饭。');
    }
    if (h >= 17.8 && h < 19.6) {
      rules.add('现在是饭点或是刚下班，可以自然提到在吃饭、在路上。');
    }

    return LifeState(
      now: now,
      stamp: stampOf(now),
      period: periodOf(now.hour),
      workday: workday,
      activity: activity,
      rules: rules,
      event: active,
    );
  }

  static String _activityOf({
    required Rhythm rhythm,
    required double h,
    required bool workday,
    required LifeEvent? event,
    required int seed,
  }) {
    if (event != null) {
      switch (event.kind) {
        case 'overtime':
          return '还在公司加班，走不开';
        case 'travel':
          return '在外面玩，${event.title}';
        case 'party':
          return '在外面跟朋友吃饭';
        case 'sick':
          return '在家躺着，不太舒服';
        case 'family':
          return '回老家了，在家里';
        case 'out':
          return event.title;
      }
    }

    final pick = _Picker(seed);

    switch (rhythm) {
      case Rhythm.student:
        if (workday) {
          if (h < 6.8) return '睡得正沉';
          if (h < 7.8) return '刚被闹钟叫起来，在洗漱';
          if (h < 8.4) return '在去教室的路上';
          if (h < 12) return '在上课';
          if (h < 14) return '在食堂吃饭，顺便歇会儿';
          if (h < 17.5) return pick.one(['在上课', '在图书馆']); 
          if (h < 19) return '在食堂吃饭';
          if (h < 23) return pick.one(['在宿舍待着', '在宿舍刷手机', '刚从图书馆回来']);
          return '准备睡了';
        }
        if (h < 9.5) return '还在睡';
        if (h < 11) return '刚醒，赖在床上';
        if (h < 13) return pick.one(['在食堂吃早午饭', '在宿舍慢慢收拾']);
        if (h < 18) {
          return pick.one(['在外面逛', '在宿舍躺平', '在咖啡店坐着', '在图书馆']);
        }
        if (h < 20) return '在吃饭';
        return pick.one(['在宿舍追剧', '躺在床上刷手机', '刚洗完澡']);

      case Rhythm.freelance:
        if (h < 9) return '还在睡';
        if (h < 10) return '刚起，还没进入状态';
        if (h < 12) return '在电脑前干活';
        if (h < 13.5) return '在吃饭';
        if (h < 19) return '在干活';
        if (h < 21) return pick.one(['在吃饭', '出去走了一圈']);
        return pick.one(['瘫在沙发上', '在追剧', '在电脑前瞎逛']);

      case Rhythm.shift:
      case Rhythm.office:
        if (workday) {
          if (h < 6.5) return '睡得正沉';
          if (h < 7.6) return '刚被闹钟叫起来，在洗漱';
          if (h < 8.6) return '在上班路上';
          if (h < 12) return '在上班';
          if (h < 13.5) {
            return pick.one(['在吃午饭', '在吃午饭，顺便刷会儿手机', '趴桌上眯了一会儿']);
          }
          if (h < 18) return '在上班';
          if (h < 19) return '刚下班，在路上';
          if (h < 20.5) return pick.one(['在吃饭', '点了外卖，在吃', '在楼下随便吃点']);
          if (h < 23) return pick.one(['瘫在沙发上刷手机', '刚洗完澡', '在追剧']);
          return '准备睡了';
        }
        if (h < 9.5) return '还在睡';
        if (h < 11) return '刚醒，赖在床上没起';
        if (h < 13) return pick.one(['在弄早饭', '在楼下吃了个粉', '在家慢慢收拾']);
        if (h < 18) {
          // 周末两天要有区别：一天出门，一天躺平
          final goOut = seed % 2 == 0;
          return goOut
              ? pick.one(['在外面逛街', '在咖啡店坐着', '跟朋友在外面', '去看了个展'])
              : pick.one(['在家躺平', '在追剧', '在打扫屋子', '在床上刷手机']);
        }
        if (h < 20) return '在吃饭';
        return pick.one(['在追剧', '瘫在沙发上', '洗过澡了，躺床上', '在打游戏']);
    }
  }

  // ——— 时间断层：这是「像正在发生」的核心 ———

  static Duration gapOf(DateTime now, DateTime? last) =>
      last == null ? const Duration(days: 9999) : now.difference(last);

  /// 这段时间主要是夜间睡眠，不算「被冷落」。
  static bool looksLikeOvernight(DateTime last, DateTime now) {
    final d = now.difference(last);
    if (d > const Duration(hours: 20)) return false;
    final lastH = last.hour;
    final nowH = now.hour;
    return (lastH >= 21 || lastH < 3) && nowH >= 6 && nowH <= 12;
  }

  /// 给人看的时间间隔描述。
  static String gapPhrase(Duration d) {
    if (d.inMinutes < 3) return '刚刚';
    if (d.inMinutes < 40) return '${d.inMinutes} 分钟前';
    if (d.inHours < 1) return '半个多小时前';
    if (d.inHours < 4) return '${d.inHours} 小时前';
    if (d.inHours < 10) return '${d.inHours} 小时前';
    if (d.inHours < 20) return '十几个小时前';
    if (d.inDays < 2) return '一天前';
    if (d.inDays < 8) return '${d.inDays} 天前';
    return '${d.inDays} 天前';
  }

  /// 给模型的行为约束：隔了这么久，应该怎么开口。
  /// 这段是「她以为我一直在跟她说话」那个毛病的解药。
  static String gapRule({
    required Duration d,
    required bool overnight,
    required bool sheSpokeLast,
  }) {
    if (d.inMinutes < 3) {
      return '你们正在同一轮对话里，接着刚才那句说，不要重新打招呼。';
    }
    if (d.inMinutes < 40) {
      return '刚才还在聊，隔了不到半小时，顺着说就行，别当新的开场。';
    }
    if (d.inHours < 3) {
      return '隔了一两个小时。可以带一句你刚才在干嘛（吃饭、走开、忙），'
          '但别装作一直在聊，也别为这点时间道歉。';
    }
    if (d.inHours < 8) {
      return '隔了几个小时。不要接着几小时前的话题问「然后呢」；'
          '先按现在这个时间点重新开口，可以顺口说一句你刚才在忙什么。';
    }
    if (overnight) {
      return '中间过了一夜。别把昨晚的话当成刚刚说的：现在是新的一天，'
          '你可能是刚醒、在通勤、在上班。语气正常就行，不用道歉，也不用解释。';
    }
    if (d.inHours < 30) {
      return '隔了大半天到一天。**不要假装你们一直在聊**：不要续上次的话题、'
          '不要问「后来呢」。先意识到中间隔了这么久——可以顺口说一句你干嘛去了，'
          '也可以轻轻抱怨他怎么才出现，但别夸张。';
    }
    if (d.inDays < 4) {
      return '隔了两三天。你要当成「好久没联系」来处理：不要续上次的话题，'
          '可以有一点点不高兴或者有点想他，但按你的性格来，别演。';
    }
    return '隔了 ${d.inDays} 天没说过话。这么长时间，你不可能还记得上次聊的细节——'
        '不要装记得，也不要问上次那件事怎么样了。就当重新开始聊，'
        '可以有距离感，也可以直接问他这些天去哪了。';
  }

  // ——— 临时安排抽签 ———

  static const List<List<String>> _trips = [
    ['大理', '请了两天假，在大理，住古城边上'],
    ['厦门', '在海边待几天，住的地方离海很近'],
    ['成都', '去成都了，主要为了吃'],
    ['杭州', '在杭州玩两天，绕着西湖走'],
    ['青岛', '去青岛看海了，风挺大'],
    ['西安', '在西安，天天吃面'],
    ['长沙', '在长沙，晚上出去吃夜宵'],
    ['苏州', '在苏州，逛园子逛得腿酸'],
  ];

  /// 抽一个「今天/这几天有什么特别安排」。
  ///
  /// 只在每天第一次打开时抽一次（由 AppState 控制），所以不会每次聊天都变。
  /// 概率刻意压低：真人的日子大部分是重复的，天天旅游反而假。
  static LifeEvent? plan({
    required DateTime now,
    LifeEvent? current,
    int lastTripMs = 0,
    Random? rnd,
    String identity = '',
  }) {
    final r = rnd ?? Random();
    if (current != null && !current.isExpired(now)) return current;

    final workday = now.weekday <= 5;
    final startOfDay = DateTime(now.year, now.month, now.day);

    // 旅行：至少隔 21 天，落在周末，2~3 天
    final sinceTrip = lastTripMs == 0
        ? 999
        : now.difference(DateTime.fromMillisecondsSinceEpoch(lastTripMs)).inDays;
    final toSaturday = 6 - now.weekday;
    if (sinceTrip >= 21 && toSaturday >= 0 && toSaturday <= 2 && r.nextDouble() < 0.55) {
      final t = _trips[r.nextInt(_trips.length)];
      final begin = startOfDay.add(Duration(days: toSaturday, hours: 8));
      final days = 2 + r.nextInt(2);
      return LifeEvent(
        kind: 'travel',
        title: '在${t[0]}玩',
        detail: t[1],
        startMs: begin.millisecondsSinceEpoch,
        endMs: begin.add(Duration(days: days)).millisecondsSinceEpoch,
      );
    }

    if (workday) {
      final x = r.nextDouble();
      if (x < 0.10) {
        final begin = startOfDay.add(const Duration(hours: 18, minutes: 30));
        return LifeEvent(
          kind: 'overtime',
          title: '今晚要加班',
          detail: '临时来了活，估计得弄到十点多',
          startMs: begin.millisecondsSinceEpoch,
          endMs: begin.add(const Duration(hours: 4)).millisecondsSinceEpoch,
        );
      }
      if (x < 0.15) {
        final begin = startOfDay.add(const Duration(hours: 19, minutes: 30));
        return LifeEvent(
          kind: 'party',
          title: '晚上跟朋友吃饭',
          detail: '好久没见的朋友约了饭，可能会晚点回',
          startMs: begin.millisecondsSinceEpoch,
          endMs: begin.add(const Duration(hours: 3, minutes: 30)).millisecondsSinceEpoch,
        );
      }
      if (x < 0.18) {
        return LifeEvent(
          kind: 'sick',
          title: '有点不舒服',
          detail: '肚子不太对劲，请了假在家躺着',
          startMs: startOfDay.millisecondsSinceEpoch,
          endMs: startOfDay.add(const Duration(hours: 23, minutes: 59)).millisecondsSinceEpoch,
        );
      }
      return null;
    }

    final y = r.nextDouble();
    if (y < 0.30) {
      final begin = startOfDay.add(const Duration(hours: 11));
      return LifeEvent(
        kind: 'out',
        title: r.nextBool() ? '出门逛街了' : '出门见朋友了',
        detail: '周末出来转转，不在家',
        startMs: begin.millisecondsSinceEpoch,
        endMs: startOfDay.add(const Duration(hours: 19)).millisecondsSinceEpoch,
      );
    }
    if (y < 0.34) {
      return LifeEvent(
        kind: 'sick',
        title: '有点不舒服',
        detail: '嗓子疼，在家歇着',
        startMs: startOfDay.millisecondsSinceEpoch,
        endMs: startOfDay.add(const Duration(hours: 23, minutes: 59)).millisecondsSinceEpoch,
      );
    }
    return null;
  }
}

/// 同一天要给出同一个答案（不然每分钟刷新状态都在变），所以用日期做种子。
class _Picker {
  final int seed;
  _Picker(this.seed);

  String one(List<String> options) =>
      options[Random(seed * 31 + options.length).nextInt(options.length)];
}
