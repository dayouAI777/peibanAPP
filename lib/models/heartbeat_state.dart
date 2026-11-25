import 'life_state.dart';

/// `state` 行 `data.event` 的允许值（设计 §3.1 白名单枚举 + 空串）。
///
/// **不许自由文本、不许自由 JSON、不许"先塞进去以后再整理"**：新取值必须先改
/// §3.1 表 + 两端同批 + capability 才能加，所以这里是一张封闭的表而不是注释约定。
/// 要记别的东西，那是新 journal type 的事，去 §3.1 矩阵表态。
const Set<String> kHeartbeatEvents = <String>{
  '',
  'travel',
  'overtime',
  'party',
  'out',
  'sick',
  'family',
};

/// 「这次要不要追加一行」的原因（设计 §3.6 的 `reason` 取值）。
///
/// 只有 [none] 表示"状态算出来了，但没有值得记的变化"——此时**只更新本机缓存**，
/// 不追加 journal 行。其余四个都是真变化。
class HeartbeatReasons {
  /// 时段/处境变了（上班 → 下班、白天 → 深夜）。
  static const String period = 'period';

  /// 她进入了/结束了某个真实安排（旅行、加班…）。
  static const String event = 'event';

  /// 情绪档位跨了一档（平静 → 有点不高兴 → 生气 → 冷战）。
  static const String moodLevel = 'mood_level';

  /// 隔了太久没说话（> 3 小时），她开始想找人说话。
  static const String longGap = 'long_gap';

  /// 没有值得记的变化：只更新本机缓存，不追加行。
  static const String none = 'none';

  const HeartbeatReasons._();
}

/// 她此刻的状态快照——就是 `state` 行 `data` 的全部内容（单赢家，key 固定 `state:v1`）。
///
/// 字段集合是**封闭**的：`activity` / `energy` / `moodLeft` / `wantTalk` /
/// `lastPulseAt` / `event`。设计 §3.1 的表把 `cap` 也算在 data 里，但那是**协议自描述
/// 字段**，由 `JournalLine` 层注入（见 [toData] 注释），不是状态的一部分。
class HeartbeatState {
  /// 这个点她大概在干什么（沿用 [LifeState.shortStatus]，有真实安排时用安排标题）。
  final String activity;

  /// 精力 0~100。深夜 20 / 上班 45 / 刚下班 55，再按 event 加减（见 [HeartbeatReducer.energyFor]）。
  final int energy;

  /// 还剩多少好脾气 0~100 = `100 - mood.anger`（**不改 MoodState**，只读它）。
  final int moodLeft;

  /// 想不想说话：隔太久 或 有没被消费的 intent。
  final bool wantTalk;

  /// 状态时刻（毫秒）。**判过期用这个，不用行的 `ts`**（ts 是写入时刻）。
  final int lastPulseAt;

  /// 真实安排的种类，白名单枚举或空串。
  final String event;

  const HeartbeatState({
    this.activity = '',
    this.energy = 50,
    this.moodLeft = 100,
    this.wantTalk = false,
    this.lastPulseAt = 0,
    this.event = '',
  });

  /// 上行/缓存用的 data。
  ///
  /// **这里不写 `cap`**：`cap` 是协议能力自描述，唯一来源是
  /// `journal.dart` 的 [injectCapIfNeeded]（判据：HeartbeatService 源码里
  /// grep 不到手写 `cap:`）。写了就等于把协议版本号抄进业务代码，
  /// 将来升 cap 要改十几处，漏一处就是"这行声明了自己是旧版本"。
  Map<String, dynamic> toData() => <String, dynamic>{
        'activity': activity,
        'energy': energy,
        'moodLeft': moodLeft,
        'wantTalk': wantTalk,
        'lastPulseAt': lastPulseAt,
        'event': event,
      };

  /// 从 data（本机缓存 / 云端行）还原。字段缺失或类型不对一律按默认值兜底，绝不抛。
  ///
  /// `cap` 读进来也**不保留**：它描述的是写这行的人支持哪个协议版本，
  /// 不是"她现在的状态"，混进状态对象会让"内容有没有变"的比较永远不等。
  factory HeartbeatState.fromData(Map<String, dynamic> m) => HeartbeatState(
        activity: m['activity'] is String ? m['activity'] as String : '',
        energy: _intInRange(m['energy'], 50),
        moodLeft: _intInRange(m['moodLeft'], 100),
        wantTalk: m['wantTalk'] == true,
        lastPulseAt: m['lastPulseAt'] is int ? m['lastPulseAt'] as int : 0,
        event: _normalizeEvent(m['event']),
      );

  /// 只换 event（`markEvent` 用：用户显式标记的安排压过推算出来的那个）。
  HeartbeatState copyWith({String? event}) => HeartbeatState(
        activity: activity,
        energy: energy,
        moodLeft: moodLeft,
        wantTalk: wantTalk,
        lastPulseAt: lastPulseAt,
        event: event ?? this.event,
      );

  static int _intInRange(Object? raw, int fallback) {
    if (raw is int) return raw.clamp(0, 100);
    if (raw is num) return raw.round().clamp(0, 100);
    return fallback;
  }

  static String _normalizeEvent(Object? raw) {
    if (raw is! String) return '';
    return kHeartbeatEvents.contains(raw) ? raw : '';
  }

  @override
  String toString() => 'HeartbeatState(activity: $activity, energy: $energy, '
      'moodLeft: $moodLeft, wantTalk: $wantTalk, lastPulseAt: $lastPulseAt, '
      'event: $event)';
}

/// reducer 的产出：算出来的新状态 + 这次该不该追加一行。
class HeartbeatDecision {
  final HeartbeatState state;

  /// 见 [HeartbeatReasons]。
  final String reason;

  const HeartbeatDecision(this.state, this.reason);

  /// 只有 [HeartbeatReasons.none] 不追加（只更新本机缓存）。
  bool get shouldAppend => reason != HeartbeatReasons.none;
}

/// `state` 的**纯 reducer**（设计 §3.6）。零 IO、零随机、零时钟调用：
/// 时间和输入全部由调用方传进来，所以同一组输入永远得到同一组输出。
///
/// 为什么强调纯：App 被杀期间不产生行，下次启动要靠它按 `lastPulseAt` 与当前
/// 时间**推算**自然回复——如果这里面有 `DateTime.now()` 或随机数，"推算"就没法验。
class HeartbeatReducer {
  /// 超过这个间隔就算「她开始想说话」。
  static const Duration longGap = Duration(hours: 3);

  const HeartbeatReducer._();

  /// 算下一个状态。
  ///
  /// [prev] 为 null 表示本机从来没有过 state（首次心跳）。
  /// [lastMsgAt] 为 null 表示一条聊天记录都没有（按"隔了很久"处理）。
  /// [unconsumedIntents] 由调用方给（T07 不读 intents 链路，保持可注入）。
  static HeartbeatDecision next({
    required HeartbeatState? prev,
    required LifeState life,
    required MoodState mood,
    int? lastMsgAt,
    int unconsumedIntents = 0,
    required int nowMs,
  }) {
    final event = activeEventOf(life);
    final state = HeartbeatState(
      activity: life.shortStatus,
      energy: energyFor(
        hour: life.now.hour,
        activity: life.shortStatus,
        event: event,
      ),
      moodLeft: (100 - mood.anger).clamp(0, 100),
      wantTalk: _wantTalk(
        lastMsgAt: lastMsgAt,
        nowMs: nowMs,
        unconsumedIntents: unconsumedIntents,
      ),
      lastPulseAt: nowMs,
      event: event,
    );
    return HeartbeatDecision(
      state,
      // `_reasonFor` 只需要前后两份状态：**长间隔的判据是"跨过阈值的那一刻"**
      // （prev.wantTalk == false → next.wantTalk == true），不是"当前仍处于长间隔"。
      // 写成后者的话，只要她半天没说话，每 5 分钟 tick 都会算"长间隔变了"，
      // 4 行/天的额度上午就见底，而且日志里全是同一句"她想说话"。
      _reasonFor(prev: prev, next: state),
    );
  }

  /// 当前真正生效的 event（只有"覆盖此刻"的安排才算数：明天才出发的旅行今天不提）。
  static String activeEventOf(LifeState life) {
    final e = life.event;
    if (e == null || !e.covers(life.now)) return '';
    return kHeartbeatEvents.contains(e.kind) ? e.kind : '';
  }

  /// 精力：`f(小时, 处境, event)` 的确定性映射。
  ///
  /// 参照值按设计写死（深夜 20 / 上班时段 45 / 刚下班 55 / 晚上回落），
  /// 再加 event 的增减：旅行走动多 +10、加班 -10、生病 -20。
  /// 结果一律夹在 0~100，且**同一组入参永远同一个数**。
  static int energyFor({
    required int hour,
    required String activity,
    required String event,
  }) {
    final int base;
    if (hour >= 23 || hour < 5) {
      base = 20; // 深夜：正常人已经睡了
    } else if (hour < 7) {
      base = 30; // 清晨
    } else if (hour < 9) {
      base = 40; // 早上
    } else if (hour < 18) {
      base = 45; // 上班时段
    } else if (hour < 20) {
      base = 55; // 刚下班，一天里最松的时候
    } else {
      base = 40; // 晚上开始回落
    }
    // 已经睡着了就别装精神：activity 里明确写"睡"时以睡眠为准。
    final asleep = activity.contains('睡') ? 15 : base;
    return (asleep + _eventEnergyDelta(event)).clamp(0, 100);
  }

  static int _eventEnergyDelta(String event) {
    switch (event) {
      case 'travel':
        return 10;
      case 'party':
        return 5;
      case 'out':
        return 5;
      case 'overtime':
        return -10;
      case 'sick':
        return -20;
      default:
        return 0; // family / '' / 未知（未知已在 activeEventOf 里被挡成 ''）
    }
  }

  static bool _wantTalk({
    required int? lastMsgAt,
    required int nowMs,
    required int unconsumedIntents,
  }) {
    if (unconsumedIntents > 0) return true;
    if (lastMsgAt == null) return true; // 一条都没聊过：当然想说话
    return nowMs - lastMsgAt > longGap.inMilliseconds;
  }

  /// 判定顺序是**契约**（写死，别改顺序）：首次 → event → 情绪档 → 长间隔 → 时段。
  /// 越靠前越"值得单独记一行"：进了旅行状态比"到了晚上"重要得多。
  ///
  /// `long_gap` 的两点口径（别写成"当前隔了很久"）：
  /// 1. 只在**跨过 3 小时的那一刻**记一行（`wantTalk` 由 false 变 true）；
  /// 2. 一条聊天记录都没有时（冷启动、读库失败）也算"跨过"——但只在**首次**之后
  ///    的第一次出现，之后 `prev.wantTalk` 已经是 true，不会每 5 分钟重复记。
  static String _reasonFor({
    required HeartbeatState? prev,
    required HeartbeatState next,
  }) {
    if (prev == null) return HeartbeatReasons.period;
    if (prev.event != next.event) return HeartbeatReasons.event;
    if (_moodBand(prev.moodLeft) != _moodBand(next.moodLeft)) {
      return HeartbeatReasons.moodLevel;
    }
    if (!prev.wantTalk && next.wantTalk) return HeartbeatReasons.longGap;
    if (prev.activity != next.activity) return HeartbeatReasons.period;
    return HeartbeatReasons.none;
  }

  /// 情绪档位（沿用 [MoodState] 的 20/50/75 三档，换算成"还剩多少好脾气"）。
  static int _moodBand(int moodLeft) {
    if (moodLeft >= 80) return 0; // 平静
    if (moodLeft >= 50) return 1; // 有点不高兴（anger 20~50）
    if (moodLeft >= 25) return 2; // 生气（anger 50~75）
    return 3; // 冷战
  }
}
