import 'package:shared_preferences/shared_preferences.dart';

/// 主动消息的一组设置。
class ProactiveSettings {
  final bool enabled;
  final int perDay; // 每天几条，1~3
  final int startHour; // 允许时段（含）
  final int endHour; // 允许时段（不含）

  const ProactiveSettings({
    this.enabled = true,
    this.perDay = 1,
    this.startHour = 9,
    this.endHour = 23,
  });

  int get spanHours => endHour > startHour ? endHour - startHour : 1;
}

/// 轻量设置。API Key 只写进本机，永不上报、永不打包进 APK。
class Prefs {
  static const _kApiKey = 'deepseek_api_key';
  static const _kEnabled = 'proactive_enabled';
  static const _kPerDay = 'proactive_per_day';
  static const _kStart = 'proactive_start_hour';
  static const _kEnd = 'proactive_end_hour';
  static const _kTemperature = 'temperature';

  static Future<String> apiKey() async =>
      (await SharedPreferences.getInstance()).getString(_kApiKey) ?? '';

  static Future<void> setApiKey(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kApiKey, v.trim());

  static Future<double> temperature() async =>
      (await SharedPreferences.getInstance()).getDouble(_kTemperature) ?? 1.25;

  static Future<void> setTemperature(double v) async =>
      (await SharedPreferences.getInstance()).setDouble(_kTemperature, v);

  static Future<ProactiveSettings> proactiveSettings() async {
    final sp = await SharedPreferences.getInstance();
    final start = sp.getInt(_kStart) ?? 9;
    var end = sp.getInt(_kEnd) ?? 23;
    if (end <= start) end = start + 1;
    return ProactiveSettings(
      enabled: sp.getBool(_kEnabled) ?? true,
      perDay: sp.getInt(_kPerDay) ?? 1,
      startHour: start,
      endHour: end,
    );
  }

  static Future<void> saveProactiveSettings(ProactiveSettings s) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kEnabled, s.enabled);
    await sp.setInt(_kPerDay, s.perDay.clamp(1, 3));
    await sp.setInt(_kStart, s.startHour.clamp(0, 23));
    await sp.setInt(_kEnd, s.endHour.clamp(1, 24));
  }
}
