import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_background.dart';

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
  static const _kChatBackground = 'chat_background';

  // v1.6 新增：升级链路
  static const _kCachedVersionJson = 'cached_version_json';
  static const _kCachedVersionAt = 'cached_version_at';
  static const _kSilentUpdateEnabled = 'silent_update_enabled';
  static const _kSilentUpdateAt = 'silent_update_at';
  static const _kPendingApk = 'pending_apk';

  // v1.6 新增：她的时间感与情绪
  static const _kLifeEvent = 'life_event';
  static const _kLifePlanDay = 'life_plan_day';
  static const _kLastTripAt = 'last_trip_at';
  static const _kMood = 'mood_state';
  static const _kMoodEnabled = 'mood_enabled';

  /// 最近一次成功拉到的 version.json 原文（秒开用）。
  static Future<String> cachedVersionJson() async =>
      (await SharedPreferences.getInstance()).getString(_kCachedVersionJson) ??
      '';

  static Future<void> cacheVersionJson(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kCachedVersionJson, v);
    await sp.setInt(_kCachedVersionAt, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<int> cachedVersionAt() async =>
      (await SharedPreferences.getInstance()).getInt(_kCachedVersionAt) ?? 0;

  /// 后台静默升级：默认开启（启动后自己下好，不打扰）。
  static Future<bool> silentUpdateEnabled() async =>
      (await SharedPreferences.getInstance())
          .getBool(_kSilentUpdateEnabled) ??
      true;

  static Future<void> setSilentUpdateEnabled(bool v) async =>
      (await SharedPreferences.getInstance())
          .setBool(_kSilentUpdateEnabled, v);

  /// 上次尝试静默升级的时间，用来做失败退避，避免每次都白跑一次。
  static Future<int> silentUpdateAt() async =>
      (await SharedPreferences.getInstance()).getInt(_kSilentUpdateAt) ?? 0;

  static Future<void> setSilentUpdateAt(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kSilentUpdateAt, v);

  /// 已经下好、等着安装的包：{"path":..,"build":..,"version":..,"at":..}
  static Future<String> pendingApk() async =>
      (await SharedPreferences.getInstance()).getString(_kPendingApk) ?? '';

  static Future<void> setPendingApk(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kPendingApk, v);

  // ——— 她的时间感 ———

  /// 当前这段临时安排（出差/加班/旅行…）的 JSON，过期就没意义了。
  static Future<String> lifeEvent() async =>
      (await SharedPreferences.getInstance()).getString(_kLifeEvent) ?? '';

  static Future<void> setLifeEvent(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kLifeEvent, v);

  /// 已经为哪一天排过安排（yyyyMMdd），同一天不重复抽签。
  static Future<String> lifePlanDay() async =>
      (await SharedPreferences.getInstance()).getString(_kLifePlanDay) ?? '';

  static Future<void> setLifePlanDay(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kLifePlanDay, v);

  /// 上次出门旅行的时间，控制频率（太频繁就不像过日子了）。
  static Future<int> lastTripAt() async =>
      (await SharedPreferences.getInstance()).getInt(_kLastTripAt) ?? 0;

  static Future<void> setLastTripAt(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kLastTripAt, v);

  // ——— 她的情绪 ———

  static Future<String> mood() async =>
      (await SharedPreferences.getInstance()).getString(_kMood) ?? '';

  static Future<void> setMood(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kMood, v);

  static Future<bool> moodEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kMoodEnabled) ?? true;

  static Future<void> setMoodEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kMoodEnabled, v);

  /// 聊天背景（JSON）。存不了或读坏了都退回默认，绝不让聊天页白屏。
  static Future<ChatBackground> chatBackground() async {
    final raw =
        (await SharedPreferences.getInstance()).getString(_kChatBackground) ??
            '';
    return ChatBackground.decode(raw);
  }

  static Future<void> setChatBackground(ChatBackground b) async =>
      (await SharedPreferences.getInstance())
          .setString(_kChatBackground, b.encode());

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
