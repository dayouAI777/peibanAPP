import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
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
          minuteOfDay = s.startHour * 60 + rnd.nextInt(s.spanHours * 60);
          if (!taken.contains(minuteOfDay)) break;
        }
        taken.add(minuteOfDay);

        final when = tz
            .TZDateTime(tz.local, date.year, date.month, date.day, 0, 0)
            .add(Duration(minutes: minuteOfDay));

        // 已经过去的时间点直接跳过
        if (when.isBefore(nowLocal.add(const Duration(minutes: 2)))) continue;

        // 插件 20.0.0 起全部改为命名参数；19.0.0 起移除了
        // uiLocalNotificationDateInterpretation，不要再传。
        final pool = linesFor(when);
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
