import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/prefs.dart';
import 'proactive_diag.dart';

/// 三通道在某一时刻的取舍（T06 · 三通道分级）。
///
/// - [notify]：L1 本地定时通知（`zonedSchedule`）；
/// - [pushplus]：L2 外部 HTTP 推送；
/// - [unread]：L3 未读盒兜底（**永远保留**：前两条都不出声时它是唯一痕迹）。
///
/// `cloudProactive == 'on'` ⇒ L1/L2 全关、只留 L3（云端负责出声）。
class ChannelPlan {
  final bool notify;
  final bool pushplus;
  final bool unread;

  const ChannelPlan({
    required this.notify,
    required this.pushplus,
    required this.unread,
  });

  @override
  String toString() =>
      'ChannelPlan(notify: $notify, pushplus: $pushplus, unread: $unread)';
}

/// 主动消息 = 提前预约好的「本地通知」。
/// 通知本身不联网、不需要服务器：用户点开通知打开 App 的那一刻，
/// 才去请求 DeepSeek 现场生成一条符合人设的话，插进聊天记录。
/// 这是移动端最稳的做法（iOS 不允许 App 常驻后台偷偷联网，Android 也常被省电策略掐掉）。
class ProactiveService {
  ProactiveService._();

  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();

  static const String payload = 'proactive';
  static bool _initialized = false;

  /// 通知上那句引子。必须跟着时间走——上午十点发「睡了吗」会把人问懵。
  static List<String> linesFor(DateTime at) {
    final h = at.hour;
    if (h >= 23 || h < 6) {
      return ['还没睡？', '睡不着，忽然想起你', '你也没睡啊'];
    }
    if (h < 9) return ['早', '醒了吗', '今天起得比闹钟早'];
    if (h < 12) return ['在忙吗', '上午好难熬', '摸鱼中，跟你说句话'];
    if (h < 14) return ['吃了吗', '在吃饭吗'];
    if (h < 18) return ['下午好困', '在干嘛呢', '有点想跟你说说话'];
    if (h < 20) return ['下班了吗', '吃了吗', '刚到家的样子'];
    return ['在吗，刚想到你', '今天过得怎么样呀', '忙完了吗？', '忽然有点惦记你'];
  }

  static Future<void> init() async {
    if (_initialized) return;
    // timezone 0.10+ 把初始化函数放到了 data/latest.dart
    tzdata.initializeTimeZones();
    // 国内自用；人在国外把这一行改成当地时区，例如 'America/Los_Angeles'
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    // 插件 20.0.0 起 initialize 的位置参数改成命名参数
    await plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
      // T02 纯观测：只记「用户确实点了通知」的时刻。
      // 不跳转、不生成消息、不改 payload —— 接手投递是 T03 的事。
      onDidReceiveNotificationResponse: (response) {
        ProactiveDiag.recordFired();
      },
    );
    _initialized = true;
  }

  static Future<void> requestPermission() async {
    final androidImpl = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();
    final iosImpl = plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    await iosImpl?.requestPermissions(alert: true, badge: true, sound: true);
  }

  /// 本地三通道的取舍（纯函数，T06 · 三通道分级）。
  ///
  /// 云端通道（`cloudProactive == 'on'`）接管投递时，**L1（本地定时通知）与
  /// L2（pushplus）必须停用、只留 L3（未读盒兜底）**：否则一天会收到云端一条 +
  /// 本地一条，用户看到的是"她一天找我两次，内容还不一样"。
  ///
  /// 这是"哪条通道该出声"的唯一判定处。`off` / 脏数据一律按"本地照旧"处理——
  /// **"不知道"不许当成 on**（那会让用户在该收到的时候什么都收不到）。
  static ChannelPlan channelPlanFor(String cloudProactive) {
    final cloudOnly = cloudProactive == Prefs.cloudProactiveOn;
    return ChannelPlan(
      notify: !cloudOnly,
      pushplus: !cloudOnly,
      unread: true,
    );
  }

  /// 读当前开关并算出通道计划（IO 版，供 `reschedule` 用）。
  static Future<ChannelPlan> currentChannelPlan() async =>
      channelPlanFor(await Prefs.cloudProactive());

  /// 把未来 7 天的通知重排一遍。
  /// 每次保存设置、每次新建角色、每次冷启动都调一次，保证不过期、不重复。
  ///
  /// 返回实际排成功的条数（T06 的判据要断言"云端接管时是 0 条"）。
  /// 旧调用方忽略返回值，行为一字节不变。
  static Future<int> reschedule({required String name}) async {
    final plan = await currentChannelPlan();
    if (!plan.notify) {
      // 云端接管：把既有的本地通知全部撤掉（否则切到 on 之后旧的还会响）。
      // 撤不掉只记诊断、**不抛**：此时"不再排新的"已经达成，抛异常只会让
      // 用户点开关时报错，而真正的问题（插件不可用）已经在 diag 里。
      try {
        await init();
        await plugin.cancelAll();
      } catch (e) {
        await ProactiveDiag.recordError('云端接管时取消本地通知失败：$e');
      }
      try {
        await ProactiveDiag.beginSchedule(targetCount: 0, plugin: plugin);
      } catch (_) {
        // 观测本身失败不影响"不排本地通知"这个结果，绝不能因此让开关报错。
      }
      return 0;
    }

    await init();
    try {
      await plugin.cancelAll();
    } catch (e) {
      await ProactiveDiag.recordError('取消旧排程失败：$e');
      rethrow;
    }

    final s = await Prefs.proactiveSettings();
    if (!s.enabled) return 0;
    try {
      await requestPermission();
    } catch (e) {
      await ProactiveDiag.recordError('申请通知权限失败：$e');
      rethrow;
    }
    // 观测点在权限申请之后：读到的是申请完的真实状态。
    await ProactiveDiag.beginSchedule(targetCount: s.perDay, plugin: plugin);

    final rnd = Random();
    final nowLocal = tz.TZDateTime.now(tz.local);
    int id = 1000;

    for (int day = 0; day < 7; day++) {
      // 用普通 DateTime 取年月日，再构造带时区的 TZDateTime，避开跨时区坑
      final date = DateTime.now().add(Duration(days: day));
      final taken = <int>{};

      for (int i = 0; i < s.perDay; i++) {
        int minuteOfDay = 0;
        for (int guard = 0; guard < 24; guard++) {
          minuteOfDay = s.startHour * 60 + rnd.nextInt(s.spanHours * 60);
          if (!taken.contains(minuteOfDay)) break;
        }
        taken.add(minuteOfDay);

        final when = tz
            .TZDateTime(tz.local, date.year, date.month, date.day, 0, 0)
            .add(Duration(minutes: minuteOfDay));

        // 已经过去的时间点直接跳过
        if (when.isBefore(nowLocal.add(const Duration(minutes: 2)))) continue;

        // 观测：先记「计划」，再记「排成功」；两者差额就是被系统拒掉的部分。
        await ProactiveDiag.recordPlanned(when);
        // 插件 20.0.0 起全部改为命名参数；19.0.0 起移除了
        // uiLocalNotificationDateInterpretation，不要再传。
        final pool = linesFor(when);
        try {
          await plugin.zonedSchedule(
            id: id++,
            title: name,
            body: pool[rnd.nextInt(pool.length)],
            scheduledDate: when,
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'proactive',
                'TA 的消息',
                channelDescription: '角色偶尔主动发来的消息',
                importance: Importance.high,
                priority: Priority.high,
                icon: '@mipmap/ic_launcher',
              ),
              iOS: DarwinNotificationDetails(
                presentAlert: true,
                presentSound: true,
                presentBadge: true,
              ),
            ),
            payload: payload,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          );
          await ProactiveDiag.recordScheduled(when);
        } catch (e) {
          await ProactiveDiag.recordError('第 $day 天 ${ProactiveDiag.formatTime(when)} 排程失败：$e');
          rethrow; // 行为零改动：原来抛就抛，绝不吞异常。
        }
      }
    }
    // 排成功的条数（id 从 1000 起，一个自增一次）。
    return id - 1000;
  }

  /// 「测试一条（3 分钟后）」：独立排一条，不 cancelAll、不碰原有 7 天排程。
  ///
  /// 用 999999 这个独立 id，避开正常排程从 1000 开始的号段；
  /// 通道 / 模式与正常通知完全一致，所以它验的就是同一条通道是不是通的。
  /// 权限没开时这条也会「排上但不显示」——那正是要拿的证据，不在这里偷偷申请权限。
  static Future<void> testIn3Minutes({required String name}) async {
    await init();
    final when = tz.TZDateTime.now(tz.local).add(const Duration(minutes: 3));
    final pool = linesFor(when);
    final body = pool[Random().nextInt(pool.length)];
    await plugin.zonedSchedule(
      id: 999999,
      title: name,
      body: body,
      scheduledDate: when,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'proactive',
          'TA 的消息',
          channelDescription: '角色偶尔主动发来的消息',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: true,
        ),
      ),
      payload: payload,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
    await ProactiveDiag.recordTestScheduled(when);
  }

  /// 删掉角色时把排好的通知全部撤掉，别留下空标题的幽灵通知。
  static Future<void> cancelAll() async {
    await init();
    await plugin.cancelAll();
  }

  /// App 是被通知点开的吗？用于决定要不要自动生成一条主动消息。
  static Future<String?> launchPayload() async {
    final detail = await plugin.getNotificationAppLaunchDetails();
    if (detail?.didNotificationLaunchApp ?? false) {
      // 纯观测：冷启动被通知点开也算一次「确实触发」。返回值原样不动。
      await ProactiveDiag.recordFired(at: DateTime.now());
      return detail?.notificationResponse?.payload;
    }
    return null;
  }
}
