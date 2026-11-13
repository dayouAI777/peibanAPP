import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/prefs.dart';

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

  /// 通知上那句引子，自用版写得有温度一点，不用客服腔。
  static const List<String> lines = [
    '在吗，刚想到你',
    '有点想跟你说说话',
    '忙完了吗？',
    '刚走神了一下，想起你',
    '今天过得怎么样呀',
    '有空的话，陪我聊两句',
    '睡了吗',
    '忽然有点惦记你',
  ];

  static Future<void> init() async {
    if (_initialized) return;
    tz.initializeTimeZones();
    // 国内自用；人在国外把这一行改成当地时区，例如 'America/Los_Angeles'
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
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

  /// 把未来 7 天的通知重排一遍。
  /// 每次保存设置、每次新建角色、每次冷启动都调一次，保证不过期、不重复。
  static Future<void> reschedule({required String name}) async {
    await init();
    await plugin.cancelAll();

    final s = await Prefs.proactiveSettings();
    if (!s.enabled) return;
    await requestPermission();

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
          minuteOfDay =
              s.startHour * 60 + rnd.nextInt(s.spanHours * 60);
          if (!taken.contains(minuteOfDay)) break;
        }
        taken.add(minuteOfDay);

        final when = tz.TZDateTime(
          tz.local,
          date.year,
          date.month,
          date.day,
          0,
          0,
        ).add(Duration(minutes: minuteOfDay));

        // 已经过去的时间点直接跳过
        if (when.isBefore(nowLocal.add(const Duration(minutes: 2)))) continue;

        await plugin.zonedSchedule(
          id++,
          name,
          lines[rnd.nextInt(lines.length)],
          when,
          const NotificationDetails(
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
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
    }
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
      return detail?.notificationResponse?.payload;
    }
    return null;
  }
}
