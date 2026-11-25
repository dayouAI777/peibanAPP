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
  static const _kEmojiHistory = 'emoji_picker_history';
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

  // 记忆上云 V1：匿名登录 + 同步口令。云端路径按口令哈希分目录，
  // 路径本身即凭证。口令明文存本机可接受（它只是同步凭证），
  // 没有密码、没有账号，会话由 cloudbase SDK 自己持久化。
  static const _kCloudPassphrase = 'cloud_passphrase';
  static const _kCloudSync = 'cloud_sync';
  static const _kCloudLastSyncAt = 'cloud_last_sync_at';

  /// 换机出口：用户明确点「我在旧手机上有记录」后写下的"允许本次按新库初始化"确认。
  /// 存的是派生的 deviceId（32 位 hex），**不存口令明文**。
  static const _kCloudLibraryAck = 'cloud_library_ack';

  static Future<String> cloudLibraryAck() async =>
      (await SharedPreferences.getInstance()).getString(_kCloudLibraryAck) ??
      '';

  static Future<void> setCloudLibraryAck(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kCloudLibraryAck, v);

  static Future<void> clearCloudLibraryAck() async =>
      (await SharedPreferences.getInstance()).remove(_kCloudLibraryAck);

  // ——— T01：设计 §3.3 新增键（一次列全，后续任务不再散落加键）———
  // R10 的 _kCloudLibraryAck 在上方，保持原位不动。
  static const _kProactiveDebug = 'proactive_debug';
  static const _kPushplusToken = 'pushplus_token';
  static const _kPushplusEnabled = 'pushplus_enabled';
  static const _kPushplusDay = 'pushplus_day';
  static const _kPushplusDayCount = 'pushplus_day_count';
  static const _kPushplusFailStreak = 'pushplus_fail_streak';
  static const _kUnreadCount = 'unread_count';
  static const _kUnreadLast = 'unread_last';
  static const _kSelfCache = 'self_cache';
  static const _kSelfLastDistillAt = 'self_last_distill_at';
  static const _kSelfFactWeek = 'self_fact_week';
  /// 自生长事实 / 每日自述的本机缓存（journal 行 data 的 JSON 列表）。
  /// 云端是权威，缓存只为离线可读与即时删除；删一条时本机立刻重算。
  static const _kSelfFactsCache = 'self_facts_cache';
  static const _kSelfNotesCache = 'self_notes_cache';
  /// 硬事实拦截开关（B9：默认 false，只控制"丢弃候选"那一层，绝不关掉标记）。
  static const _kHardFactGuardEnabled = 'hard_fact_guard_enabled';
  static const _kStateDay = 'state_day';
  static const _kStateDayCount = 'state_day_count';

  /// 上一次写 `state` 行的时间（**毫秒时间戳**，字符串形式；只做时间语义）。
  static const _kStateLast = 'state_last';

  /// 当前 `state` 行的 data JSON（**载荷**，与上面那个时间戳键分开）。
  ///
  /// 为什么不复用 `state_last`（v1.4.5 / T07 裁决）：一个键装两种载荷是这个
  /// 项目最典型的坏法——下一个人把它当时间戳，拿到一段 JSON，`int.parse` 或
  /// 比大小会崩或静默得 0，然后 5 分钟去抖失效，且**没有任何测试会红**。
  static const _kStateData = 'state_data';
  static const _kHeartbeatLastTickAt = 'heartbeat_last_tick_at';
  static const _kIntentDay = 'intent_day';
  static const _kIntentDayCount = 'intent_day_count';
  static const _kNoteNeartermDay = 'note_nearterm_day';

  /// 最近一次成功对齐云端的时间（C5② 与 R2 能力门禁共用的同一事实）。
  static const _kCloudAlignedOnce = 'cloud_aligned_once';

  /// 同步口令（空 = 还没开启）。云端目录 = sha256('peiban-sync-v1:' + 口令)。
  static Future<String> cloudPassphrase() async =>
      (await SharedPreferences.getInstance()).getString(_kCloudPassphrase) ??
      '';

  static Future<void> setCloudPassphrase(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kCloudPassphrase, v);

  /// 云同步开关：开了才会发完消息延迟推送、退后台补推。
  /// 拉取没有自动入口——只有设置页的手动「对齐云端 / 从云端恢复」。
  static Future<bool> cloudSync() async =>
      (await SharedPreferences.getInstance()).getBool(_kCloudSync) ?? false;

  static Future<void> setCloudSync(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kCloudSync, v);

  /// 云端按时送达（T06）：**只有 `'off'` / `'on'` 两值，默认 `'off'`**。
  ///
  /// 与 `cloudSync` 同构（§12.2 铁律 12），但**不许做成 bool / tri-state**：
  /// - bool 表达不了"用户还没表过态"，将来想加"要不要提示"之类会没地方放；
  /// - 出现第三个取值就等于多一个分支，而 `on` 的语义是**停用 L1/L2、只留 L3**，
  ///   分支一多就必然有人忘记在某条路径上停用本地通知，表现是"一天收到两条"。
  static const String _kCloudProactive = 'cloud_proactive';
  static const String cloudProactiveOff = 'off';
  static const String cloudProactiveOn = 'on';

  static Future<String> cloudProactive() async {
    final v = (await SharedPreferences.getInstance()).getString(_kCloudProactive) ??
        '';
    // 脏数据（空 / 大写 / 别的词）一律按 off：**"不知道"不许当成 on**。
    return v == cloudProactiveOn ? cloudProactiveOn : cloudProactiveOff;
  }

  static Future<void> setCloudProactive(String v) async {
    final normalized = v == cloudProactiveOn ? cloudProactiveOn : cloudProactiveOff;
    await (await SharedPreferences.getInstance())
        .setString(_kCloudProactive, normalized);
  }

  /// 候选句池「今天已经尝试生成过一次」的日期标记（yyyyMMdd）。
  ///
  /// 语义是**「失败即今天没有」，不是「失败就再试」**：池子读不到（网络抖动 /
  /// 对象还没建）时 `CosObjectPoolStore.read` 返回空池，不区分"空"和"读失败"，
  /// 于是每一轮同步都会再生成一次、再调一次模型。一天活跃 12 小时、每 5 分钟
  /// 一次会话 ⇒ 最坏上百次模型调用，**一次故障会自己放大成账单**。
  /// 所以这个键**成功失败都写**：它记的是"试过"，不是"成功"。
  static const _kProactivePoolAttemptDay = 'proactive_pool_attempt_day';

  static Future<String> proactivePoolAttemptDay() async =>
      (await SharedPreferences.getInstance())
          .getString(_kProactivePoolAttemptDay) ??
      '';

  static Future<void> setProactivePoolAttemptDay(String v) async =>
      (await SharedPreferences.getInstance())
          .setString(_kProactivePoolAttemptDay, v);

  /// 云端按时送达是否开启（读侧唯一入口，避免各处自己比字符串）。
  static Future<bool> cloudProactiveEnabled() async =>
      await cloudProactive() == cloudProactiveOn;

  /// 最近一次成功上传/恢复的时间（毫秒）。
  static Future<int> cloudLastSyncAt() async =>
      (await SharedPreferences.getInstance()).getInt(_kCloudLastSyncAt) ?? 0;

  static Future<void> setCloudLastSyncAt(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kCloudLastSyncAt, v);

  /// 授权码：销毁云母库等高危操作的本地凭证。
  /// 与同步口令是两个完全独立的东西（改口令不影响授权码，反之亦然）；
  /// 只在 App 本机保存，**永不入云、永不进 journal/快照**。
  static const _kCloudAuthCode = 'cloud_auth_code';

  static Future<String> cloudAuthCode() async =>
      (await SharedPreferences.getInstance()).getString(_kCloudAuthCode) ??
      '';

  static Future<void> setCloudAuthCode(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kCloudAuthCode, v);

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

  /// 她的说话方式档案（JSON，机器蒸馏产物，不让手改）。全局一份：
  /// 当前项目常态单角色，与 speech_profile 同口径；将来支持多角色再拆 key。
  static const _kStyleProfile = 'style_profile';

  static Future<String> styleProfile() async =>
      (await SharedPreferences.getInstance()).getString(_kStyleProfile) ?? '';

  static Future<void> setStyleProfile(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kStyleProfile, v);

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

  static const emojiHistoryLimit = 120;

  static Future<List<String>> emojiHistory() async =>
      (await SharedPreferences.getInstance()).getStringList(_kEmojiHistory) ??
      const [];

  static Future<void> recordEmojiUse(String emoji) async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList(_kEmojiHistory) ?? const <String>[];
    await prefs.setStringList(_kEmojiHistory, [emoji, ...history.take(emojiHistoryLimit - 1)]);
  }

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

  // ——— T01：设计 §3.3 键的读写（只存本机）———

  /// 主动消息纯观测数据（JSON，只写不读，除诊断页）。
  static Future<String> proactiveDebug() async =>
      (await SharedPreferences.getInstance()).getString(_kProactiveDebug) ?? '';

  static Future<void> setProactiveDebug(String raw) async =>
      (await SharedPreferences.getInstance()).setString(_kProactiveDebug, raw);

  /// pushplus token 脱敏：日志 / 导出 / 诊断一律只留后 4 位。
  static String maskPushplusToken(String token) {
    if (token.length <= 4) return 'pus***';
    return 'pus***${token.substring(token.length - 4)}';
  }

  static Future<String> pushplusToken() async =>
      (await SharedPreferences.getInstance()).getString(_kPushplusToken) ?? '';

  static Future<void> setPushplusToken(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kPushplusToken, v);

  /// 默认关（开启时由设置页弹一次告知）。
  static Future<bool> pushplusEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kPushplusEnabled) ?? false;

  static Future<void> setPushplusEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kPushplusEnabled, v);

  static Future<String> pushplusDay() async =>
      (await SharedPreferences.getInstance()).getString(_kPushplusDay) ?? '';

  static Future<void> setPushplusDay(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kPushplusDay, v);

  static Future<int> pushplusDayCount() async =>
      (await SharedPreferences.getInstance()).getInt(_kPushplusDayCount) ?? 0;

  static Future<void> setPushplusDayCount(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kPushplusDayCount, v);

  /// 连续失败 ≥3 当日熔断，不许重试打爆第三方额度。
  static Future<int> pushplusFailStreak() async =>
      (await SharedPreferences.getInstance()).getInt(_kPushplusFailStreak) ?? 0;

  static Future<void> setPushplusFailStreak(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kPushplusFailStreak, v);

  static Future<int> unreadCount() async =>
      (await SharedPreferences.getInstance()).getInt(_kUnreadCount) ?? 0;

  static Future<void> setUnreadCount(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kUnreadCount, v);

  static Future<String> unreadLast() async =>
      (await SharedPreferences.getInstance()).getString(_kUnreadLast) ?? '';

  static Future<void> setUnreadLast(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kUnreadLast, v);

  /// self 行 data 的本机缓存（免每次读云端）。
  static Future<String> selfCache() async =>
      (await SharedPreferences.getInstance()).getString(_kSelfCache) ?? '';

  static Future<void> setSelfCache(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kSelfCache, v);

  static Future<int> selfLastDistillAt() async =>
      (await SharedPreferences.getInstance()).getInt(_kSelfLastDistillAt) ?? 0;

  static Future<void> setSelfLastDistillAt(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kSelfLastDistillAt, v);

  /// 周额度：`2026W47` + 本周已写条数（JSON）。
  static Future<String> selfFactWeek() async =>
      (await SharedPreferences.getInstance()).getString(_kSelfFactWeek) ?? '';

  static Future<void> setSelfFactWeek(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kSelfFactWeek, v);

  static Future<String> selfFactsCache() async =>
      (await SharedPreferences.getInstance()).getString(_kSelfFactsCache) ?? '';

  static Future<void> setSelfFactsCache(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kSelfFactsCache, v);

  static Future<String> selfNotesCache() async =>
      (await SharedPreferences.getInstance()).getString(_kSelfNotesCache) ?? '';

  static Future<void> setSelfNotesCache(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kSelfNotesCache, v);

  /// B9：默认 false。只控制"是否丢弃硬事实候选"，与标记/筛选完全无关。
  static Future<bool> hardFactGuardEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kHardFactGuardEnabled) ?? false;

  static Future<void> setHardFactGuardEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kHardFactGuardEnabled, v);

  static Future<String> stateDay() async =>
      (await SharedPreferences.getInstance()).getString(_kStateDay) ?? '';

  static Future<void> setStateDay(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kStateDay, v);

  static Future<int> stateDayCount() async =>
      (await SharedPreferences.getInstance()).getInt(_kStateDayCount) ?? 0;

  static Future<void> setStateDayCount(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kStateDayCount, v);

  static Future<String> stateLast() async =>
      (await SharedPreferences.getInstance()).getString(_kStateLast) ?? '';

  static Future<void> setStateLast(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kStateLast, v);

  /// 当前 state 行的 data JSON（空串 = 还没有过有效心跳）。
  /// **载荷只在 `state_data`**：`state_last` 永远是时间戳，两者不许混用。
  static Future<String> stateData() async =>
      (await SharedPreferences.getInstance()).getString(_kStateData) ?? '';

  static Future<void> setStateData(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kStateData, v);

  static Future<int> heartbeatLastTickAt() async =>
      (await SharedPreferences.getInstance()).getInt(_kHeartbeatLastTickAt) ?? 0;

  static Future<void> setHeartbeatLastTickAt(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kHeartbeatLastTickAt, v);

  static Future<String> intentDay() async =>
      (await SharedPreferences.getInstance()).getString(_kIntentDay) ?? '';

  static Future<void> setIntentDay(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kIntentDay, v);

  static Future<int> intentDayCount() async =>
      (await SharedPreferences.getInstance()).getInt(_kIntentDayCount) ?? 0;

  static Future<void> setIntentDayCount(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kIntentDayCount, v);

  /// 近况 note 当天是否已尝试生成（一天只尝试一次）。
  static Future<String> noteNeartermDay() async =>
      (await SharedPreferences.getInstance()).getString(_kNoteNeartermDay) ?? '';

  static Future<void> setNoteNeartermDay(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kNoteNeartermDay, v);

  /// 最近一次**成功**读到云端 journal 的时间（毫秒，0 = 从来没对齐成功过）。
  ///
  /// 键名沿用设计的 `cloud_aligned_once`（`docs/待裁决-T04.md` B 条 / §7.2 判定），
  /// 两个消费者共用这一个事实：
  /// - 导出的 C5②：判断"我们到底知不知道本机是不是云端的全量"；
  /// - R2 能力门禁（只认本次运行，见 `CloudSync.canWriteSelfNow`）。
  ///
  /// **必须落盘**——放内存里重启就没了，会变成"昨天对齐过，今天导出又说不完整"
  /// 的狼来了。**只在成功那条路径写，失败一律不写**（见 `CloudSync._run` 收尾段）。
  /// 值存时间戳而不是 bool：`>0` 与 bool 等价，但将来要显示"上次对齐时间"时
  /// bool 不够用，多存一个键才是真的乱。
  static Future<int> cloudAlignedOnce() async =>
      (await SharedPreferences.getInstance()).getInt(_kCloudAlignedOnce) ?? 0;

  static Future<void> setCloudAlignedOnce(int v) async =>
      (await SharedPreferences.getInstance()).setInt(_kCloudAlignedOnce, v);
}
