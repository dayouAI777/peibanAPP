import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 云端投递排期（Dart 侧移植，T06 · §5A）。
///
/// **与 `peiban-core/cloudfunctions/proactive-tick/lib/plan.js` 逐条对应**：
/// 同一个 `dayKey` 在两端必须算出同一个 `dayCount` / `slots` / `sendAt`，
/// 否则 App 对账（`CloudProactiveService.reconcile`）会按错误的窗口数推算
/// "云端今天应该发了几条"。`test/cloud_proactive_test.dart` 里有 Node 端实算的
/// 固定向量逐字对拍——**改算法必须两端同批改，改完向量会红**。
///
/// 排期只来自 `sha256(dayKey)`（铁律 10：云端不做 PG 状态存储）：
/// - 窗口 7 个，从 9:00 起每 2 小时一个（9/11/13/15/17/19/21）；
/// - 抖动 `[0, 30)` 分钟 ⇒ 相邻两窗最小间隔 120 − 30 = 90 分钟，恒成立；
/// - 末条最晚 21:30，绝不越 23:00；
/// - 时区口径：全天按 **+08:00** 计算，`dayKey` 为该时区的 yyyyMMdd。
class CloudPlan {
  CloudPlan._();

  /// 排期盐。写死，不许改成配置项（改了等于换一套日历）。
  static const String salt = 'peiban-proactive-v1';

  /// 抖动上界（分钟），区间 `[0, jitterMaxMin)`。
  static const int jitterMaxMin = 30;

  /// 投递窗口起点（+08:00）。窗口数只在这里，改窗口不动算法。
  static const List<int> windows = <int>[9, 11, 13, 15, 17, 19, 21];

  /// 窗口内"来得及送到"的判定余量（分钟）：定时器 5 分钟一发，5 分钟内必命中一次。
  static const int graceMin = 5;

  static const int tzOffsetMs = 8 * 60 * 60 * 1000;
  static const int msPerMin = 60 * 1000;
  static const int msPerDay = 24 * 60 * msPerMin;

  /// 当天排期的确定性字节流：`sha256("$salt:$dayKey")`。
  static List<int> hashBytes(String dayKey) =>
      sha256.convert(utf8.encode('$salt:$dayKey')).bytes;

  /// 某时刻在 +08:00 的 `dayKey`（yyyyMMdd）。
  static String dayKeyOf(int nowMs) {
    final ms = nowMs + tzOffsetMs;
    final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y$m$day';
  }

  /// `dayKey`（yyyyMMdd）对应的 +08:00 当天零点的 epoch 毫秒。
  static int chinaDayStartMs(String dayKey) {
    final s = dayKey.trim();
    final y = int.parse(s.substring(0, 4));
    final m = int.parse(s.substring(4, 6));
    final d = int.parse(s.substring(6, 8));
    return DateTime.utc(y, m, d).millisecondsSinceEpoch - tzOffsetMs;
  }

  /// 某时刻在 +08:00 的当天分钟序号（0..1439）。
  static int minuteOfDayOf(int nowMs) {
    final inDay = (nowMs + tzOffsetMs) % msPerDay;
    return inDay ~/ msPerMin;
  }

  /// 当天目标条数：`3 + 首字节 % 3 ∈ [3, 5]`。
  ///
  /// 均匀分布 ⇒ 长期均值 4.0；测试按"逐日值域"断言，不按平均值放水。
  static int dayCount(String dayKey) => 3 + hashBytes(dayKey)[0] % 3;

  /// 当天的投递时刻表（当天分钟序号，升序、互不相同）。
  ///
  /// 构造法：用哈希字节做 Fisher-Yates 洗牌选 `count` 个窗口（按窗口先后排序），
  /// 每个窗口内取确定性抖动 `[0, 30)`。窗口间隔 ≥120 分钟 ⇒ 任意两条间隔
  /// ≥90 分钟由构造成立，不需要重抽。
  static List<int> slots(String dayKey) {
    final bytes = hashBytes(dayKey);
    final count = dayCount(dayKey);
    final idx = <int>[for (var i = 0; i < windows.length; i++) i];
    for (var i = idx.length - 1, bi = 1; i > 0; i--, bi++) {
      final j = bytes[bi % bytes.length] % (i + 1);
      final t = idx[i];
      idx[i] = idx[j];
      idx[j] = t;
    }
    final chosen = idx.take(count).toList()..sort();
    final out = <int>[];
    for (var k = 0; k < chosen.length; k++) {
      final jitter = (bytes[(8 + k) % bytes.length] * jitterMaxMin) ~/ 256;
      out.add(windows[chosen[k]] * 60 + jitter);
    }
    return out;
  }

  /// 第 i 条的投递时刻（epoch 毫秒）。越界返回 null（对应 Node 的 `NaN`）。
  static int? sendAt(String dayKey, int i) {
    final s = slots(dayKey);
    if (i < 0 || i >= s.length) return null;
    return chinaDayStartMs(dayKey) + s[i] * msPerMin;
  }

  /// 第 i 条此刻该不该投：`nowMs ∈ [sendAt, sendAt + grace)`。
  static bool shouldSend(String dayKey, int i, int nowMs) {
    final at = sendAt(dayKey, i);
    if (at == null) return false;
    return nowMs >= at && nowMs < at + graceMin * msPerMin;
  }

  /// 到 [nowMs] 为止**已经过了投递时刻**的窗口序号（含刚过的那个）。
  ///
  /// App 对账用它算"云端今天应该已经发了几条"：过了时刻就算该发，
  /// 不等 [graceMin] 的宽限——宽限是云端"还来不来得及"的判定，不是对账口径。
  static List<int> passedWindowIndexes(String dayKey, int nowMs) {
    final out = <int>[];
    final s = slots(dayKey);
    final start = chinaDayStartMs(dayKey);
    for (var i = 0; i < s.length; i++) {
      if (nowMs >= start + s[i] * msPerMin) out.add(i);
    }
    return out;
  }

  /// 全部窗口序号（0..count-1）。
  static List<int> allWindowIndexes(String dayKey) =>
      <int>[for (var i = 0; i < slots(dayKey).length; i++) i];

  /// 窗口的身份串：`<dayKey>#<窗口序号>`。
  ///
  /// 云端幂等游标按**窗口序号**记（`cursor.sent[winIndex]`），所以 App 侧对齐
  /// 也用序号；`dayKey` 前缀是为了让"跨天同一序号"不会被误当成同一条。
  static String windowKeyOf(String dayKey, int index) => '$dayKey#$index';
}
