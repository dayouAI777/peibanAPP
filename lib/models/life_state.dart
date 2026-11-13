import 'dart:convert';

/// 她的临时安排：出门玩、加班、聚会、生病、回老家。
///
/// 一律带明确的起止时间，过期自动失效——绝不让她连着三周"在大理玩"。
/// 存本机，不联网。
class LifeEvent {
  /// travel 出门旅行 / overtime 加班 / party 聚会 / out 周末出门
  /// sick 不舒服 / family 回老家
  final String kind;

  /// 给她看的一句话：「在大理玩」「在公司加班」
  final String title;

  /// 更具体一点：「请了两天假，跟朋友在大理，住古城边上」
  final String detail;

  final int startMs;
  final int endMs;

  const LifeEvent({
    required this.kind,
    required this.title,
    required this.detail,
    required this.startMs,
    required this.endMs,
  });

  bool covers(DateTime t) {
    final ms = t.millisecondsSinceEpoch;
    return ms >= startMs && ms < endMs;
  }

  bool isExpired(DateTime t) => t.millisecondsSinceEpoch >= endMs;

  bool get isTravel => kind == 'travel';

  Map<String, dynamic> toMap() => {
        'kind': kind,
        'title': title,
        'detail': detail,
        'start': startMs,
        'end': endMs,
      };

  factory LifeEvent.fromMap(Map<String, dynamic> m) => LifeEvent(
        kind: (m['kind'] as String?) ?? 'out',
        title: (m['title'] as String?) ?? '',
        detail: (m['detail'] as String?) ?? '',
        startMs: (m['start'] as int?) ?? 0,
        endMs: (m['end'] as int?) ?? 0,
      );

  String encode() => jsonEncode(toMap());

  static LifeEvent? decode(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      return LifeEvent.fromMap(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

/// 「此刻」的快照：现在几点、这个点她大概在干什么、哪些话不能说。
///
/// 全部由本地时间推算，不调模型。规则写死在这里，是为了让她不可能
/// 在晚上八点还说自己在公司摸鱼——那是模型最容易犯的错。
class LifeState {
  final DateTime now;

  /// 「11月13日 星期五 20:47」
  final String stamp;

  /// 深夜 / 清晨 / 早上 / 上午 / 中午 / 下午 / 傍晚 / 晚上
  final String period;

  final bool workday;

  /// 这个点她在干嘛：「刚下班，在地铁上」
  final String activity;

  /// 这个点绝不能出现的话（硬约束，直接进 prompt）
  final List<String> rules;

  final LifeEvent? event;

  const LifeState({
    required this.now,
    required this.stamp,
    required this.period,
    required this.workday,
    required this.activity,
    required this.rules,
    this.event,
  });

  /// AppBar 上的那一行状态（短）。
  String get shortStatus {
    if (event != null && event!.covers(now)) return event!.title;
    return activity;
  }
}

/// 她的情绪。用 0~100 的怒气值驱动，档位由数值派生，
/// 好处是「哄」和「被冷落」可以叠加，不会一有风吹草动就翻脸。
class MoodState {
  /// 0 平静，100 爆炸
  final int anger;

  /// 为什么生气（会写进 prompt，让她说得有理有据）
  final String reason;

  /// 这一轮情绪从什么时候开始
  final int sinceMs;

  /// 冷战期间已经冷了几轮（决定这次要不要甩表情）
  final int coldTurns;

  /// 累计被哄了几次
  final int coaxCount;

  const MoodState({
    this.anger = 0,
    this.reason = '',
    this.sinceMs = 0,
    this.coldTurns = 0,
    this.coaxCount = 0,
  });

  static const int annoyedAt = 20;
  static const int angryAt = 50;
  static const int coldAt = 75;

  bool get isCold => anger >= coldAt;
  bool get isAngry => anger >= angryAt && anger < coldAt;
  bool get isAnnoyed => anger >= annoyedAt && anger < angryAt;

  String get levelName {
    if (isCold) return 'cold';
    if (isAngry) return 'angry';
    if (isAnnoyed) return 'annoyed';
    return 'calm';
  }

  /// AppBar 上她名字下面那行：她现在的脸色。
  String get faceLabel {
    if (isCold) return '生气中，不想说话';
    if (isAngry) return '还在生气';
    if (isAnnoyed) return '有点不高兴';
    return '';
  }

  MoodState copyWith({
    int? anger,
    String? reason,
    int? sinceMs,
    int? coldTurns,
    int? coaxCount,
  }) =>
      MoodState(
        anger: anger ?? this.anger,
        reason: reason ?? this.reason,
        sinceMs: sinceMs ?? this.sinceMs,
        coldTurns: coldTurns ?? this.coldTurns,
        coaxCount: coaxCount ?? this.coaxCount,
      );

  Map<String, dynamic> toMap() => {
        'anger': anger,
        'reason': reason,
        'since': sinceMs,
        'cold': coldTurns,
        'coax': coaxCount,
      };

  factory MoodState.fromMap(Map<String, dynamic> m) => MoodState(
        anger: ((m['anger'] as num?) ?? 0).round().clamp(0, 100),
        reason: (m['reason'] as String?) ?? '',
        sinceMs: (m['since'] as int?) ?? 0,
        coldTurns: (m['cold'] as int?) ?? 0,
        coaxCount: (m['coax'] as int?) ?? 0,
      );

  String encode() => jsonEncode(toMap());

  static MoodState decode(String raw) {
    if (raw.trim().isEmpty) return const MoodState();
    try {
      return MoodState.fromMap(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const MoodState();
    }
  }
}
