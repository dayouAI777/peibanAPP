// 统一限额闸门（设计 §8.1 / v1.4.1）——Flutter 端实现。
//
// 纯函数、零 IO、零副作用。与 peiban-core/src/quota_gate.mjs 逐条对应，
// 同一份 test/fixtures/quota-v1.json 两端对拍必须完全同结果。
//
// 语义（铁律）：超限**直接丢弃、不排队**。云母库只增不删，超限时若还写入，
// 那一行就再也删不掉。QuotaGate 只回答两件事：
//   1. allowed —— 这次能不能写（超限=false，调用方应立即丢弃，不许落库）；
//   2. nextTodayCount / nextWeekCount —— 通过时 +1 后的计数，调用方写回本机 prefs。
// 过闸与自增都发生在**构造行之前**（T04 / T05 / P1 Heartbeat 接线）。

/// 计数键名常量（T01 独占；写入方不许另写字符串字面量）。对应 prefs §3.3。
class QuotaKeys {
  static const String selfLastDistillAt = 'self_last_distill_at';
  static const String selfFactWeek = 'self_fact_week';
  static const String stateDay = 'state_day';
  static const String stateDayCount = 'state_day_count';
  static const String noteNeartermDay = 'note_nearterm_day';

  const QuotaKeys._();
}

/// 单条限额规则：上限 + 计数周期（day / week / none）。
class QuotaRule {
  final int limit;
  final String period;

  const QuotaRule(this.limit, this.period);

  @override
  bool operator ==(Object other) =>
      other is QuotaRule && other.limit == limit && other.period == period;

  @override
  int get hashCode => Object.hash(limit, period);

  @override
  String toString() => 'QuotaRule(limit: $limit, period: $period)';
}

/// 限额表。`self_fact` 按自然周（周一起算，周期切换由调用方重置计数）；
/// 其余按天。超限行为由调用方按 §8.1 处理（缓存生效 / 丢弃候选 / 当天不再生成）。
const Map<String, QuotaRule> kQuotaLimits = <String, QuotaRule>{
  'self': QuotaRule(1, 'day'),
  'self_fact': QuotaRule(3, 'week'),
  'self_note': QuotaRule(1, 'day'),
  'state': QuotaRule(4, 'day'),
  // 近况 note 是 note 的一个 category，用虚拟 type 名区分（不新增云母库 type）。
  'note_nearterm': QuotaRule(1, 'day'),
};

const QuotaRule _unbounded = QuotaRule(0, 'none');

/// 查询某 type 的限额规则。未登记返回 limit=0 / period=none（不设限、放行）。
QuotaRule quotaLimitFor(String type) => kQuotaLimits[type] ?? _unbounded;

/// 一次过闸结论（字段与 Node quotaAllow 返回对象同名同值）。
class QuotaDecision {
  final bool allowed;
  final int nextTodayCount;
  final int nextWeekCount;
  final int limit;
  final String period;

  const QuotaDecision({
    required this.allowed,
    required this.nextTodayCount,
    required this.nextWeekCount,
    required this.limit,
    required this.period,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'allowed': allowed,
        'nextTodayCount': nextTodayCount,
        'nextWeekCount': nextWeekCount,
        'limit': limit,
        'period': period,
      };

  @override
  bool operator ==(Object other) =>
      other is QuotaDecision &&
      other.allowed == allowed &&
      other.nextTodayCount == nextTodayCount &&
      other.nextWeekCount == nextWeekCount &&
      other.limit == limit &&
      other.period == period;

  @override
  int get hashCode =>
      Object.hash(allowed, nextTodayCount, nextWeekCount, limit, period);

  @override
  String toString() => 'QuotaDecision(${toJson()})';
}

/// 纯函数：判断本次写入是否放行，并给出通过后的新计数。
///
/// - 超限：allowed=false，两个 nextCount 保持原值（不排队、不自增）。
/// - 通过：allowed=true，按 period 给对应计数 +1，另一个原样透传。
/// - 未登记 type：allowed=true，limit=0，计数原样透传。
QuotaDecision quotaAllow(
  String type,
  int todayCount,
  int weekCount,
) {
  final t = todayCount >= 0 ? todayCount : 0;
  final w = weekCount >= 0 ? weekCount : 0;
  final rule = quotaLimitFor(type);

  if (rule.limit == 0) {
    return QuotaDecision(
      allowed: true,
      nextTodayCount: t,
      nextWeekCount: w,
      limit: 0,
      period: 'none',
    );
  }

  final used = rule.period == 'week' ? w : t;
  if (used >= rule.limit) {
    return QuotaDecision(
      allowed: false,
      nextTodayCount: t,
      nextWeekCount: w,
      limit: rule.limit,
      period: rule.period,
    );
  }

  return QuotaDecision(
    allowed: true,
    nextTodayCount: rule.period == 'day' ? t + 1 : t,
    nextWeekCount: rule.period == 'week' ? w + 1 : w,
    limit: rule.limit,
    period: rule.period,
  );
}

/// QuotaGate 命名空间（Node 侧是同名对象，调用形态一致）。
class QuotaGate {
  const QuotaGate._();

  static const Map<String, QuotaRule> limits = kQuotaLimits;
  static QuotaDecision allow(String type, int todayCount, int weekCount) =>
      quotaAllow(type, todayCount, weekCount);
  static QuotaRule limitFor(String type) => quotaLimitFor(type);
}
