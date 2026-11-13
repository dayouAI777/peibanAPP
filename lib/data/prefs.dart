import 'package:shared_preferences/shared_preferences.dart';

/// 主动消息的一组设置。
class ProactiveSettings {
  final bool enabled;
  final int perDay;
  final int startHour;
  final int endHour;

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

  // v2 新增
  static const _kConfigured = 'configured';
  static const _kManualEnabled = 'manual_enabled';
  static const _kContextLimit = 'context_limit';
  static const _kAutoUpdate = 'auto_update_check';
  static const _kIgnoredBuild = 'ignored_build';
  static const _kLastUpdateCheck = 'last_update_check';
  static const _kEmojiLevel = 'emoji_level';
  static const _kSpeechProfile = 'speech_profile';

  /// 后台静默学习的说话方式画像（JSON），只存本机。
  static Future<String> speechProfile() async =>
      (await SharedPreferences.getInstance()).getString(_kSpeechProfile) ?? '';

  static Future<void> setSpeechProfile(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kSpeechProfile, v);

  static Future<String> apiKey() async =>
      (await SharedPreferences.getInstance()).getString(_kApiKey) ?? '';

  static Future<void> setApiKey(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kApiKey, v.trim());

  /// 配置门禁：只有「填了 Key + 测试链接通过」才为 true。
  static Future<bool> configured() async =>
      (await SharedPreferences.getInstance()).getBool(_kConfigured) ?? false;

  static Future<void> setConfigured(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kConfigured, v);

  /// 随机度。上限锁在 1.0：实测 1.25 以上 deepseek-chat 容易输出语义崩坏的长段落。
  /// 旧版存过 1.25 / 1.5 的，升级后在这里一并钳回来，不依赖用户手动改。
  static Future<double> temperature() async {
    final v = (await SharedPreferences.getInstance())
            .getDouble(_kTemperature) ??
        0.8;
    return v.clamp(0.4, 1.0);
  }

  static Future<void> setTemperature(double v) async =>
      (await SharedPreferences.getInstance())
          .setDouble(_kTemperature, v.clamp(0.4, 1.0));

  /// 记忆窗口：最近多少句纳入上下文，默认 1000，超出的压缩成摘要。
  static Future<int> contextLimit() async =>
      (await SharedPreferences.getInstance()).getInt(_kContextLimit) ?? 1000;

  static Future<void> setContextLimit(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kContextLimit, v.clamp(200, 5000));

  static Future<bool> manualEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kManualEnabled) ?? true;

  static Future<void> setManualEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kManualEnabled, v);

  static Future<bool> autoUpdateCheck() async =>
      (await SharedPreferences.getInstance()).getBool(_kAutoUpdate) ?? true;

  static Future<void> setAutoUpdateCheck(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kAutoUpdate, v);

  static Future<int> ignoredBuild() async =>
      (await SharedPreferences.getInstance()).getInt(_kIgnoredBuild) ?? 0;

  static Future<void> setIgnoredBuild(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kIgnoredBuild, v);

  static Future<int> lastUpdateCheck() async =>
      (await SharedPreferences.getInstance()).getInt(_kLastUpdateCheck) ?? 0;

  static Future<void> setLastUpdateCheck(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kLastUpdateCheck, v);

  /// 角色用表情的频率：0 关 / 1 偶尔 / 2 常用（默认，回复更生动）。
  static Future<int> emojiLevel() async =>
      (await SharedPreferences.getInstance()).getInt(_kEmojiLevel) ?? 2;

  static Future<void> setEmojiLevel(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kEmojiLevel, v.clamp(0, 2));

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
