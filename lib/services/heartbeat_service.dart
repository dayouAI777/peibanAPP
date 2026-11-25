import 'dart:convert';

import '../data/db_helper.dart';
import '../data/prefs.dart';
import '../models/heartbeat_state.dart';
import '../models/journal.dart';
import '../models/life_state.dart';
import '../models/persona_space.dart';
import 'clock_service.dart';
import 'quota_gate.dart';

/// `state` 的写入方（T07）。
///
/// ## 挂接点：`CloudSync._runLockedOnce()` 的 push 段开头（C 位置）
///
/// 设计原文（T07 节）说的是「`app_state.dart` 里 `CloudSync.align()` 的汇聚方法」——
/// **那个方法在代码里不存在**：`app_state.dart` 全文 `align` 出现 0 次，唯一调用
/// `align()` 的地方是设置页按钮 `_cloudAlign()`。四个时机（防抖 5min / 退后台 /
/// 手动对齐 / 重蒸后）真正的汇聚点是 `CloudSync._run()`，三条入口
/// `align()` / `pushOnly()` / `pullOnly()` 全走它。
///
/// 所以本服务挂在 `_runLockedOnce()` 的 `if (doPush) {` 块开头、`_exportLocal()`
/// 之前。**为什么不是 `_run()`（B 位置）**：
/// - B 在早退路径（MISSING / BLOCKED / 网络错）上也会开会话标志，于是 state 行
///   写进本机、却没有机会上云 —— 而 state **不参与对齐判定**，这种分叉永远不会
///   被发现，直到某天她突然用上一个一周前的状态说话。
/// - C 只在"真的准备推送"时才 drain，drain 出来的行**同一次会话内就被推上去**。
///   代价只是早退那一次不写 state（一天 4 次上限里少一次），完全可接受。
///
/// **为什么不是"在 4 个时机各自埋点"**：埋 4 处 = 4 个挂接点，将来必对不齐。
///
/// ## 三条硬约束
/// 1. 写必须**寄生在既有的同步会话里**（边际桶 ≈ 0）：独立开会话写 = 4 桶/天
///    = 1710 点/月，三个月打成半个月。链外调 [writeState] 一律返回
///    [reasonNotInSyncSession]，**真的不落云**。
/// 2. `cap` 由协议层注入（`journal.dart` 的 [injectCapIfNeeded]），本文件源码里
///    **没有手写 `cap:`**。
/// 3. `state` 是单赢家类型：key 固定 `state:v1`、跨天不换；每次写 append 一行新
///    `ts`，旧行保留但永不生效（读侧取 `ts` 最大那条）。
class HeartbeatService {
  HeartbeatService._();

  /// 唯一实例（调用方写 `HeartbeatService.instance.drainToJournal()`）。
  static final HeartbeatService instance = HeartbeatService._();

  // ——— 结果原因（测试按字符串断言，别改字面量） ———
  static const String reasonOk = 'ok';
  static const String reasonNotInSyncSession = 'not_in_sync_session';
  static const String reasonQuota = 'quota';
  static const String reasonDebounce = 'debounce';
  static const String reasonUnchanged = 'unchanged';
  static const String reasonInvalidEvent = 'invalid_event';
  static const String reasonError = 'error';

  /// 同一 5 分钟窗口内最多落 1 行（判据 6 的去抖，键 `state_day_count` 之外的第二道）。
  static const Duration dedupeWindow = Duration(minutes: 5);

  // ——— 会话标志 ———
  static bool _inSyncSession = false;

  /// 当前是否在同步会话内（[writeState] 的门禁）。
  static bool get inSyncSession => _inSyncSession;

  /// 由 `CloudSync._run()` 在拿到 `_busy` 之后调用。
  static void beginSyncSession() {
    _inSyncSession = true;
  }

  /// 由 `CloudSync._run()` 的 `finally` 调用（异常路径也必须走到）。
  static void endSyncSession() {
    _inSyncSession = false;
  }

  /// 会话内的主动 drain（挂在 `_runLockedOnce` 的 push 段开头）。
  ///
  /// **永不抛**：这是同步主路径，一个心跳异常把整次云同步带崩，代价远大于少一行 state。
  Future<HeartbeatDrainResult> drainToJournal({int? nowMs}) async {
    return _write(nowMs: nowMs);
  }

  /// 链外写入入口。
  ///
  /// 不在同步会话内 → 直接返回 [reasonNotInSyncSession]，**不写行、不落云、
  /// 也不偷偷写本机缓存**（否则就是"本机有一行、云上永远没有"的静默分叉）。
  Future<HeartbeatDrainResult> writeState({int? nowMs}) async {
    if (!_inSyncSession) {
      return const HeartbeatDrainResult(
        wrote: false,
        reason: reasonNotInSyncSession,
      );
    }
    return _write(nowMs: nowMs);
  }

  /// 用户显式标记一个真实安排（travel / overtime…）时立刻写。
  ///
  /// **只留 API，UI 挂接列 T07 B 阶段**（避免新增第三处挂接点、碰 T04/T05 的页面）。
  /// [kind] 必须在 [kHeartbeatEvents] 里：`event` 取值是封闭枚举，不许自由文本。
  Future<HeartbeatDrainResult> markEvent(String kind, {int? nowMs}) async {
    if (kind.isEmpty || !kHeartbeatEvents.contains(kind)) {
      return const HeartbeatDrainResult(
        wrote: false,
        reason: reasonInvalidEvent,
      );
    }
    if (!_inSyncSession) {
      return const HeartbeatDrainResult(
        wrote: false,
        reason: reasonNotInSyncSession,
      );
    }
    return _write(nowMs: nowMs, forcedEvent: kind);
  }

  /// 核心写入流程：去抖 → reducer → （reason==none 只留缓存）→ 过闸 → 构造行 → 落缓存。
  ///
  /// **过闸与自增都在构造行之前**（§8.1 铁律）：超限直接丢弃、不排队、不自增，
  /// 一旦写了就再也删不掉（云母库只增不删）。
  Future<HeartbeatDrainResult> _write({
    int? nowMs,
    String? forcedEvent,
  }) async {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    try {
      // ① 去抖：同一 5 分钟窗口多次 tick ≤ 1 行。
      //    markEvent 是用户显式动作，允许越过这个窗口（但照样受日限额约束）。
      final lastTick = await Prefs.heartbeatLastTickAt();
      if (forcedEvent == null &&
          lastTick > 0 &&
          now - lastTick < dedupeWindow.inMilliseconds) {
        return const HeartbeatDrainResult(
          wrote: false,
          reason: reasonDebounce,
        );
      }

      // ② 收集输入 + 纯 reducer。
      final inputs = await collectInputs(nowMs: now);
      final prev = await readCachedState();
      final computed = HeartbeatReducer.next(
        prev: prev,
        life: inputs.life,
        mood: inputs.mood,
        lastMsgAt: inputs.lastMsgAt,
        unconsumedIntents: inputs.unconsumedIntents,
        nowMs: now,
      );
      final decision = forcedEvent == null
          ? computed
          : HeartbeatDecision(
              computed.state.copyWith(event: forcedEvent),
              HeartbeatReasons.event,
            );

      // 无论这次写不写，tick 都算数：否则 5 分钟窗口形同虚设
      // （同一次会话里的重试会连着 drain 两次，第二道闸就是靠这个键挡住的）。
      await Prefs.setHeartbeatLastTickAt(now);

      // ③ reason == none：只是算了一遍，没有值得记的变化 → 不追加任何行。
      //    **这里不碰 `state_data`**：那个键是"下一次要推上去的载荷"，
      //    往里写就等于绕过闸门偷偷排了一条上行，日限额会当场失效。
      if (!decision.shouldAppend) {
        return HeartbeatDrainResult(
          wrote: false,
          reason: reasonUnchanged,
          state: decision.state,
        );
      }

      // ④ 过闸（在构造行之前）。跨天要先把计数归零。
      final dayKey =
          ClockService.dayKey(DateTime.fromMillisecondsSinceEpoch(now));
      final storedDay = await Prefs.stateDay();
      final usedToday = storedDay == dayKey ? await Prefs.stateDayCount() : 0;
      final gate = QuotaGate.allow(JournalLine.typeState, usedToday, 0);
      if (!gate.allowed) {
        // 超限：不抛、不写行、不自增。
        return HeartbeatDrainResult(
          wrote: false,
          reason: reasonQuota,
          state: decision.state,
        );
      }

      // ⑤ 构造载荷。cap 由协议层注入，本文件不出现手写的 cap。
      final data =
          injectCapIfNeeded(JournalLine.typeState, decision.state.toData());

      await Prefs.setStateDay(dayKey);
      await Prefs.setStateDayCount(gate.nextTodayCount);
      await Prefs.setStateData(jsonEncode(data));
      // `state_last` 保持**时间戳语义**（毫秒字符串），载荷只在 `state_data`。
      await Prefs.setStateLast('$now');

      return HeartbeatDrainResult(
        wrote: true,
        reason: reasonOk,
        state: decision.state,
        line: JournalLine(
          type: JournalLine.typeState,
          key: journalKeyState,
          ts: now,
          data: data,
        ),
      );
    } catch (_) {
      // 心跳失败静默（§12.3 后台行为口径）：绝不能把同步主路径带崩。
      return const HeartbeatDrainResult(wrote: false, reason: reasonError);
    }
  }

  /// 上一次真正写出去（过闸）的 state。没有则 null（首次心跳）。
  static Future<HeartbeatState?> readCachedState() async {
    final raw = await Prefs.stateData();
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return HeartbeatState.fromData(copyStringMap(decoded));
    } catch (_) {
      // 缓存坏了当没有：下一行照样能写出来（单赢家，读者取 ts 最大那条）。
    }
    return null;
  }

  /// 收集 reducer 的输入。全部失败安全：任何一块读不出来就按"没有"处理。
  ///
  /// 为什么不用 `AppState`（那样能直接拿 `life` / `mood`）：`HeartbeatService`
  /// 是从 `CloudSync` 里被调的，反向依赖 `AppState` 会形成环（`AppState` 已经
  /// 依赖 `CloudSync`）。所以这里按同一份口径（`ClockService.describe` + prefs）
  /// 自己读——口径也就只有这一处会漂，改的时候一起改。
  static Future<HeartbeatInputs> collectInputs({required int nowMs}) async {
    final now = DateTime.fromMillisecondsSinceEpoch(nowMs);

    var event = LifeEvent.decode(await Prefs.lifeEvent());
    if (event != null && event.isExpired(now)) event = null;

    Map<String, String> fields = const <String, String>{};
    int? lastMsgAt;
    try {
      final c = await DbHelper.instance.firstCompanion();
      if (c != null) {
        fields = PersonaSpace.decode(c.personaSpace).fields;
        final latest = await DbHelper.instance.messages(c.id!, limit: 1);
        if (latest.isNotEmpty) lastMsgAt = latest.last.createdAt;
      }
    } catch (_) {
      // 没库 / 没伴侣：当成"刚装好还没开始聊"，reducer 会按长间隔处理。
    }

    var mood = const MoodState();
    try {
      mood = MoodState.decode(await Prefs.mood());
    } catch (_) {
      mood = const MoodState();
    }

    final life = ClockService.describe(
      now: now,
      event: event,
      identity: fields['identity'] ?? '',
      habits: fields['habits'] ?? '',
    );

    return HeartbeatInputs(
      life: life,
      mood: mood,
      lastMsgAt: lastMsgAt,
      // T07 不读 intents 链路（那是 T02/T03 的事）：保持可注入，默认 0。
      unconsumedIntents: 0,
    );
  }
}

/// reducer 的一组输入（把"从哪读"和"怎么算"分开，测试可以只喂值）。
class HeartbeatInputs {
  final LifeState life;
  final MoodState mood;
  final int? lastMsgAt;
  final int unconsumedIntents;

  const HeartbeatInputs({
    required this.life,
    required this.mood,
    this.lastMsgAt,
    this.unconsumedIntents = 0,
  });
}

/// 一次 drain / write 的结果。
class HeartbeatDrainResult {
  /// 是否真的产出了一行（并写了本机缓存）。
  final bool wrote;

  /// 见 `HeartbeatService.reasonXxx`：
  /// `ok` / `not_in_sync_session` / `quota` / `debounce` / `unchanged` /
  /// `invalid_event` / `error`。
  final String reason;

  /// 算出来的状态（`quota` / `unchanged` 时也有，方便诊断）。
  final HeartbeatState? state;

  /// 这次要追加的行（含协议层注入的 `cap`）；没写时为 null。
  final JournalLine? line;

  const HeartbeatDrainResult({
    required this.wrote,
    required this.reason,
    this.state,
    this.line,
  });

  @override
  String toString() => 'HeartbeatDrainResult(wrote: $wrote, reason: $reason)';
}
