import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../data/prefs.dart';

/// 主动消息纯观测层（T02 / R1 第一步）。
///
/// 这里只读系统状态、只把结果写进本机 `proactive_debug`，**不参与任何调度决策**。
/// 调度方在关键节点调用本文件的 record* 方法；本文件的任何异常都被调用方隔离，
/// 不允许因为「装摄像头」把原来的通知链路弄坏。
///
/// 所有字段一律显示真实结果：读不到就写「未知 / 读取失败 / 尚未发生」，
/// 绝不写「已开启」「正常」这类没有证据的断言（PRD L4）。
class ProactiveDiag {
  ProactiveDiag._();

  /// 插件通道名。T03 若要在 MainActivity.kt 里实现精确闹钟查询，请沿用这个契约。
  static const String exactAlarmChannel = 'com.peiban.proactive/diag';
  static const String exactAlarmMethod = 'canScheduleExactAlarms';

  /// 被观测的通知通道 id（与 ProactiveService 里 zonedSchedule 的通道一致）。
  static const String channelId = 'proactive';

  static const MethodChannel _diagChannel = MethodChannel(exactAlarmChannel);

  /// 一次观测记录。字段全部可序列化，方便原样落到 prefs 给设置页读。
  ///
  /// 前 9 个字段是 T02 的必答项；后面几个是 PRD L4 里顺手就能拿到的旁证，
  /// 不改变调度行为，只是为了 3~7 天的诊断证据更完整。
  static const ProactiveDiagSnapshot empty = ProactiveDiagSnapshot();

  /// 读本机观测记录。没有记录 / 坏 JSON 一律返回 null，让界面说「尚无记录」。
  static Future<ProactiveDiagSnapshot?> load() async {
    try {
      final raw = await Prefs.proactiveDebug();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return ProactiveDiagSnapshot.fromJson(decoded);
    } catch (_) {
      // 读不到就当没有记录；观测层任何异常都不许冒泡到通知链路。
      return null;
    }
  }

  /// 读-改-写。观测点与界面刷新都走这里，避免两个字段互相覆盖。
  static Future<ProactiveDiagSnapshot> patch(
    ProactiveDiagSnapshot Function(ProactiveDiagSnapshot old) update,
  ) async {
    final old = await load() ?? empty;
    final next = update(old);
    try {
      await Prefs.setProactiveDebug(jsonEncode(next.toJson()));
    } catch (_) {
      // 写诊断失败绝不能影响通知本身；下一次观测会重新攒证据。
    }
    return next;
  }

  /// 本地时间戳。不用 intl，省一个依赖；格式固定，方便老板照着看系统时间。
  static String formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// 把已排成功的时刻列表折成「下次触发」。已经过去的时刻不算数。
  static String nextFireFrom(List<String> scheduledTimes) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final upcoming = <DateTime>[];
    for (final s in scheduledTimes) {
      try {
        final t = DateTime.parse(s.replaceFirst(' ', 'T'));
        if (t.millisecondsSinceEpoch > nowMs) upcoming.add(t);
      } catch (_) {
        // 旧版本写进来的坏格式直接跳过，不猜。
      }
    }
    if (upcoming.isEmpty) return '无（没有排程成功或已全部过期）';
    upcoming.sort();
    return formatTime(upcoming.first);
  }

  /// 开始一轮重排：先把上一轮的计数清零，再记下这一轮的开始时间。
  ///
  /// 只在 `reschedule` 确认 enabled 之后调用；关闭主动消息时不清空历史证据。
  static Future<void> beginSchedule({
    required int targetCount,
    required FlutterLocalNotificationsPlugin plugin,
  }) async {
    await patch((s) => s.copyWith(
          lastScheduleAt: formatTime(DateTime.now()),
          targetCount: targetCount,
          planned: 0,
          scheduled: 0,
          plannedTimes: const <String>[],
          scheduledTimes: const <String>[],
          nextFireAt: '无（本轮还没有排程成功）',
          lastError: '',
        ));
    await collectEnvironment(plugin: plugin);
  }

  /// 采一个「计划排」的时刻（通过了过期跳过判断，但还没交给插件）。
  static Future<void> recordPlanned(DateTime when) async {
    await patch((s) {
      final times = List<String>.from(s.plannedTimes)..add(formatTime(when));
      return s.copyWith(planned: times.length, plannedTimes: times);
    });
  }

  /// 采一个「真的排成功」的时刻。`zonedSchedule` 没抛异常才算成功。
  static Future<void> recordScheduled(DateTime when) async {
    await patch((s) {
      final times = List<String>.from(s.scheduledTimes)..add(formatTime(when));
      return s.copyWith(
        scheduled: s.scheduled + 1,
        scheduledTimes: times,
        nextFireAt: nextFireFrom(times),
      );
    });
  }

  /// 记录异常原文（截断防 prefs 膨胀），调用方必须自己 rethrow，不能吞。
  static Future<void> recordError(String message) async {
    await patch((s) => s.copyWith(lastError: _clip(message)));
  }

  /// 记录一次「确实被点开 / 确实触发」的时刻。
  ///
  /// 本轮没有原生 receiver，最可靠的旁证是「用户点了通知」：
  /// 前台点按回调与冷启动 payload 都会走到这里。界面上会写明这个口径，
  /// 不会把它伪装成「系统实际投递时刻」。
  static Future<void> recordFired({DateTime? at}) async {
    await patch((s) => s.copyWith(lastFiredAt: formatTime(at ?? DateTime.now())));
  }

  /// 「测试一条（3 分钟后）」的排程留痕，单独存，不混进 scheduled。
  static Future<void> recordTestScheduled(DateTime when) async {
    await patch((s) => s.copyWith(testScheduledAt: formatTime(when)));
  }

  /// 只读地收集权限 / 通道 / 精确闹钟状态。绝不申请权限、绝不改通道。
  static Future<void> collectEnvironment({
    required FlutterLocalNotificationsPlugin plugin,
  }) async {
    String permission = '未知（本平台没有读取接口）';
    String channel = '未知（本平台没有通知通道）';
    String exactAlarm = '未接入（T03 需在 MainActivity.kt 实现 MethodChannel）';
    String pushplus = '关';

    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      try {
        final enabled = await android.areNotificationsEnabled();
        permission = enabled == null
            ? '未知（插件未返回）'
            : (enabled ? '已开启' : '未开启');
      } catch (e) {
        permission = '读取失败：${_clip(e.toString(), 60)}';
      }
      try {
        final channels = await android.getNotificationChannels();
        final found =
            channels?.where((c) => c.id == channelId).toList(growable: false);
        if (found == null || found.isEmpty) {
          channel = '通道尚未创建（尚无通知发出过）';
        } else {
          final c = found.first;
          channel = '${c.importance.name}（值 ${c.importance.value}）'
              '${c.description == null || c.description!.isEmpty ? '' : ' · ${c.description}'}';
        }
      } catch (e) {
        channel = '读取失败：${_clip(e.toString(), 60)}';
      }
    }

    try {
      final granted = await _diagChannel
          .invokeMethod<bool>(exactAlarmMethod)
          .timeout(const Duration(seconds: 2));
      if (granted == null) {
        exactAlarm = '未知（原生未返回布尔值）';
      } else {
        exactAlarm = granted ? '已授予' : '未授予（当前用 inexact，不受影响）';
      }
    } catch (e) {
      exactAlarm = '未接入（T03 需在 MainActivity.kt 实现 MethodChannel）';
    }

    try {
      final enabled = await Prefs.pushplusEnabled();
      final token = await Prefs.pushplusToken();
      pushplus = !enabled
          ? '关'
          : (token.isEmpty
              ? '开（未配 token）'
              : '开（token ${Prefs.maskPushplusToken(token)}）');
    } catch (e) {
      pushplus = '读取失败：${_clip(e.toString(), 60)}';
    }

    await patch((s) => s.copyWith(
          permissionState: permission,
          channelImportance: channel,
          exactAlarm: exactAlarm,
          pushplusState: pushplus,
        ));
  }

  static String _clip(String s, [int max = 200]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  // ——— 界面用的纯函数（可单测，不依赖 Flutter binding）———

  /// `scheduled == 0` 必须说人话，不许显示空白或「正常」。
  static String scheduledLabel(int scheduled) => scheduled == 0
      ? '0 条：排程没成功'
      : '$scheduled 条：排程已成功';

  /// 设置页状态行。没有记录时如实说没有，不拿默认值冒充「正常」。
  static String summary(ProactiveDiagSnapshot? s) {
    if (s == null) return '尚无观测记录（打开 App 重排后刷新）';
    return '计划 ${s.planned} 条 / 已排 ${s.scheduled} 条 · ${scheduledLabel(s.scheduled)}';
  }

  /// 空字段的统一显示口径。
  static String display(String value) =>
      value.trim().isEmpty ? '尚无记录' : value;

  /// 时刻列表：多行展示，空就写「无」，不显示空白。
  static String displayTimes(List<String> times) =>
      times.isEmpty ? '无' : times.join('\n');
}

/// 一次观测的不可变快照。所有集合都在构造时拷贝，避免外部改动污染记录。
class ProactiveDiagSnapshot {
  /// 通知权限（Android: areNotificationsEnabled）。
  final String permissionState;

  /// 精确闹钟权限。本轮原生侧未接入，写「未接入」，不猜。
  final String exactAlarm;

  /// 通道 `proactive` 的 importance；通道不存在时明说「尚未创建」。
  final String channelImportance;

  /// 本轮计划排几条（已通过过期跳过判断）。
  final int planned;

  /// 本轮 `zonedSchedule` 没抛异常的次数。
  final int scheduled;

  /// 本轮计划时刻（本地时间字符串）。
  final List<String> plannedTimes;

  /// 已排成功且尚未过去的时刻里最早的一个。
  final String nextFireAt;

  /// 上次「确实被点 / 确实触发」的时间（见 ProactiveDiag.recordFired 说明）。
  final String lastFiredAt;

  /// 最近一次异常原文（截断）。
  final String lastError;

  // ——— 辅助旁证（PRD L4，能顺手拿到就留着）———
  final String lastScheduleAt;
  final int targetCount;
  final List<String> scheduledTimes;
  final String pushplusState;
  final String testScheduledAt;

  const ProactiveDiagSnapshot({
    this.permissionState = '',
    this.exactAlarm = '',
    this.channelImportance = '',
    this.planned = 0,
    this.scheduled = 0,
    this.plannedTimes = const <String>[],
    this.nextFireAt = '',
    this.lastFiredAt = '',
    this.lastError = '',
    this.lastScheduleAt = '',
    this.targetCount = 0,
    this.scheduledTimes = const <String>[],
    this.pushplusState = '',
    this.testScheduledAt = '',
  });

  ProactiveDiagSnapshot copyWith({
    String? permissionState,
    String? exactAlarm,
    String? channelImportance,
    int? planned,
    int? scheduled,
    List<String>? plannedTimes,
    String? nextFireAt,
    String? lastFiredAt,
    String? lastError,
    String? lastScheduleAt,
    int? targetCount,
    List<String>? scheduledTimes,
    String? pushplusState,
    String? testScheduledAt,
  }) {
    return ProactiveDiagSnapshot(
      permissionState: permissionState ?? this.permissionState,
      exactAlarm: exactAlarm ?? this.exactAlarm,
      channelImportance: channelImportance ?? this.channelImportance,
      planned: planned ?? this.planned,
      scheduled: scheduled ?? this.scheduled,
      plannedTimes: plannedTimes ?? this.plannedTimes,
      nextFireAt: nextFireAt ?? this.nextFireAt,
      lastFiredAt: lastFiredAt ?? this.lastFiredAt,
      lastError: lastError ?? this.lastError,
      lastScheduleAt: lastScheduleAt ?? this.lastScheduleAt,
      targetCount: targetCount ?? this.targetCount,
      scheduledTimes: scheduledTimes ?? this.scheduledTimes,
      pushplusState: pushplusState ?? this.pushplusState,
      testScheduledAt: testScheduledAt ?? this.testScheduledAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'permissionState': permissionState,
        'exactAlarm': exactAlarm,
        'channelImportance': channelImportance,
        'planned': planned,
        'scheduled': scheduled,
        'plannedTimes': plannedTimes,
        'nextFireAt': nextFireAt,
        'lastFiredAt': lastFiredAt,
        'lastError': lastError,
        'lastScheduleAt': lastScheduleAt,
        'targetCount': targetCount,
        'scheduledTimes': scheduledTimes,
        'pushplusState': pushplusState,
        'testScheduledAt': testScheduledAt,
      };

  factory ProactiveDiagSnapshot.fromJson(Map<String, dynamic> json) {
    return ProactiveDiagSnapshot(
      permissionState: _str(json['permissionState']),
      exactAlarm: _str(json['exactAlarm']),
      channelImportance: _str(json['channelImportance']),
      planned: _int(json['planned']),
      scheduled: _int(json['scheduled']),
      plannedTimes: _strs(json['plannedTimes']),
      nextFireAt: _str(json['nextFireAt']),
      lastFiredAt: _str(json['lastFiredAt']),
      lastError: _str(json['lastError']),
      lastScheduleAt: _str(json['lastScheduleAt']),
      targetCount: _int(json['targetCount']),
      scheduledTimes: _strs(json['scheduledTimes']),
      pushplusState: _str(json['pushplusState']),
      testScheduledAt: _str(json['testScheduledAt']),
    );
  }

  static String _str(dynamic v) => v is String ? v : '';

  static int _int(dynamic v) => v is int ? v : 0;

  static List<String> _strs(dynamic v) {
    if (v is! List) return const <String>[];
    return v.whereType<String>().toList(growable: false);
  }
}
