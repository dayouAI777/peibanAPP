import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/data/prefs.dart';
import 'package:peiban_app/models/heartbeat_state.dart';
import 'package:peiban_app/models/journal.dart';
import 'package:peiban_app/models/life_state.dart';
import 'package:peiban_app/services/clock_service.dart';
import 'package:peiban_app/services/cloud_sync.dart';
import 'package:peiban_app/services/heartbeat_service.dart';
import 'package:peiban_app/services/quota_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 固定"现在"：2026-11-25（周三）14:00 —— 上班时段，energy 走 45 那一档。
/// **不用 `DateTime.now()`**：reducer 的每一条断言都要能复现。
final int _now = DateTime(2026, 11, 25, 14, 0).millisecondsSinceEpoch;

String _dayKeyOf(int ms) =>
    ClockService.dayKey(DateTime.fromMillisecondsSinceEpoch(ms));

/// 造一个 LocalExport（只有 state 有内容，其余空）。生产代码只经 `_exportLocal()`
/// 产出它；这里构造 fixture 是为了断言"上行请求体里到底有什么"。
LocalExport _localWithState(Map<String, dynamic> state) => LocalExport(
      companion: const <String, dynamic>{},
      speechProfile: const <String, dynamic>{},
      styleProfile: const <String, dynamic>{},
      notes: const <Map<String, dynamic>>[],
      styleExamples: const <Map<String, dynamic>>[],
      memoryChunks: const <Map<String, dynamic>>[],
      messages: const <Map<String, dynamic>>[],
      selfProfile: const <String, dynamic>{},
      selfFacts: const <Map<String, dynamic>>[],
      selfNotes: const <Map<String, dynamic>>[],
      state: state,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    HeartbeatService.endSyncSession();
  });

  tearDown(() {
    HeartbeatService.endSyncSession();
  });

  // ————————————————————————————————————————————————————————————
  group('1. 日限额（≤4/天，超限直接丢弃、不排队、不自增）', () {
    test('QuotaGate：第 5 次不放行（allow(state,4,0) == false）', () {
      expect(QuotaGate.allow(JournalLine.typeState, 4, 0).allowed, isFalse);
      expect(QuotaGate.allow(JournalLine.typeState, 3, 0).allowed, isTrue);
    });

    test('第 5 次写被拒：不抛异常、不写行、不上缓存、reason == quota', () async {
      // 今天已经写了 4 行
      SharedPreferences.setMockInitialValues(<String, Object>{
        'state_day': _dayKeyOf(_now),
        'state_day_count': 4,
      });
      HeartbeatService.beginSyncSession();

      final r = await HeartbeatService.instance.drainToJournal(nowMs: _now);

      expect(r.wrote, isFalse);
      expect(r.reason, HeartbeatService.reasonQuota);
      expect(r.line, isNull, reason: '被拒时不许构造行，哪怕构造了不推也不行');
      expect(await Prefs.stateData(), isEmpty, reason: '不许偷偷排一条载荷等着下次推');
      expect(await Prefs.stateDayCount(), 4, reason: '被拒时不许自增');
    });
  });

  // ————————————————————————————————————————————————————————————
  group('2. 单赢家：state:v1 只取 ts 最大的那行（跨天也不换 key）', () {
    test('两行不同 ts → resolveEffectiveLines 只剩 ts 大的那条', () {
      final older = JournalLine(
        type: JournalLine.typeState,
        key: journalKeyState,
        ts: 100,
        data: const <String, dynamic>{'energy': 20, 'lastPulseAt': 100},
      );
      final newer = JournalLine(
        type: JournalLine.typeState,
        key: journalKeyState,
        ts: 200,
        data: const <String, dynamic>{'energy': 55, 'lastPulseAt': 200},
      );
      final effective = resolveEffectiveLines(<JournalLine>[older, newer]);
      final states = effective.where((l) => l.type == JournalLine.typeState);
      expect(states.length, 1);
      expect(states.first.ts, 200);
      expect(states.first.data['energy'], 55);
    });

    test('跨天同 key（昨天一行、今天一行）→ 仍然只剩 1 行，取今天的', () {
      final yesterday = JournalLine(
        type: JournalLine.typeState,
        key: journalKeyState, // key 不按天换
        ts: DateTime(2026, 11, 24, 22).millisecondsSinceEpoch,
        data: const <String, dynamic>{'energy': 40},
      );
      final today = JournalLine(
        type: JournalLine.typeState,
        key: journalKeyState,
        ts: _now,
        data: const <String, dynamic>{'energy': 45},
      );
      final effective = resolveEffectiveLines(<JournalLine>[yesterday, today]);
      expect(effective.where((l) => l.key == journalKeyState).length, 1);
      expect(effective.firstWhere((l) => l.key == journalKeyState).ts, _now);
    });
  });

  // ————————————————————————————————————————————————————————————
  group('3. cap 注入：值只有一个来源，业务侧不许手写', () {
    test('写出来的行 data.cap == 2（由协议层注入）', () async {
      HeartbeatService.beginSyncSession();
      final r = await HeartbeatService.instance.drainToJournal(nowMs: _now);
      expect(r.wrote, isTrue, reason: '首次心跳必须能写');
      expect(r.line, isNotNull);
      expect(r.line!.data['cap'], kJournalCapability);
      expect(r.line!.data['cap'], 2);
    });

    test('heartbeat_service.dart 源码里没有手写的 cap:', () {
      final src =
          File('lib/services/heartbeat_service.dart').readAsStringSync();
      expect(
        RegExp(r"""['"]cap['"]\s*:""").hasMatch(src),
        isFalse,
        reason: 'cap 只许由 injectCapIfNeeded 注入；业务侧写死等于把协议版本号抄进业务代码',
      );
    });
  });

  // ————————————————————————————————————————————————————————————
  group('4. 零网络 + 零后台常驻', () {
    test('心跳服务不碰任何网络栈（源码级）', () {
      final src =
          File('lib/services/heartbeat_service.dart').readAsStringSync();
      for (final needle in <String>[
        'HttpClient',
        'package:http',
        'dio',
        'cloudbase',
        'CloudBase',
      ]) {
        expect(src.contains(needle), isFalse,
            reason: '心跳/状态必须纯本机，出现 $needle 就是"高频轮询云端"的开端');
      }
    });

    test('600 次 tick（500ms 窗口内）只落 1 行，之后不再写', () async {
      HeartbeatService.beginSyncSession();
      var wrote = 0;
      for (var i = 0; i < 600; i++) {
        final r =
            await HeartbeatService.instance.drainToJournal(nowMs: _now + i);
        if (r.wrote) wrote += 1;
      }
      expect(wrote, 1, reason: '600 次 tick 里只该有 1 次真的写（5 分钟去抖）');
      expect(await Prefs.stateDayCount(), 1);
    });
  });

  // ————————————————————————————————————————————————————————————
  group('5. 时序：链外写入不落云', () {
    test('不在同步会话内 → not_in_sync_session，且什么都不写', () async {
      HeartbeatService.endSyncSession();

      final r = await HeartbeatService.instance.writeState(nowMs: _now);

      expect(r.wrote, isFalse);
      expect(r.reason, HeartbeatService.reasonNotInSyncSession);
      expect(await Prefs.stateData(), isEmpty,
          reason: '链外写入连本机载荷都不许写：否则就是"本机一行、云上永远没有"');
      expect(await Prefs.heartbeatLastTickAt(), 0);
      expect(await Prefs.stateDayCount(), 0);
    });

    test('同一时刻，会话内写就能过（证明门禁是"会话"而不是"永远不给写"）', () async {
      HeartbeatService.beginSyncSession();
      final r = await HeartbeatService.instance.drainToJournal(nowMs: _now);
      expect(r.wrote, isTrue);
      expect(r.reason, HeartbeatService.reasonOk);
    });
  });

  // ————————————————————————————————————————————————————————————
  group('6. 去抖 + 有界重试（`_runLockedOnce` 会被调两次）', () {
    test('同一 5 分钟窗口第二次 tick → debounce，日计数仍为 1', () async {
      HeartbeatService.beginSyncSession();
      final first =
          await HeartbeatService.instance.drainToJournal(nowMs: _now);
      final second = await HeartbeatService.instance
          .drainToJournal(nowMs: _now + 1000);

      expect(first.wrote, isTrue);
      expect(second.wrote, isFalse);
      expect(second.reason, HeartbeatService.reasonDebounce);
      expect(await Prefs.stateDayCount(), 1, reason: '去抖不许把限额计数也吃掉');
    });

    test('重试场景（token 过期后 `_runLockedOnce` 再跑一次）：最终只有 1 行 state',
        () async {
      // 真实重试路径：`_runLocked` 见 token 过期 → 换新会话 → **再调一次**
      // `_runLockedOnce` → 里面的 drainToJournal 会第二次执行。这里按同一条
      // 时间线复现：第一次写成功，第二次（毫秒级之后）必须被挡住。
      HeartbeatService.beginSyncSession();
      final attempt1 =
          await HeartbeatService.instance.drainToJournal(nowMs: _now);
      final attempt2 = await HeartbeatService.instance
          .drainToJournal(nowMs: _now + 200); // 重试紧跟其后

      expect(attempt1.wrote, isTrue);
      expect(attempt2.reason, HeartbeatService.reasonDebounce);

      // 上行侧也只有一行：拿真实载荷过一遍真实的"组装追加行"函数
      final payload = await CloudSync.readStatePayload();
      expect(payload, isNotEmpty);
      final appended = CloudSync.buildAppendedLines(
        local: _localWithState(payload),
        cloudKeys: const <String>{},
        cloudLatest: const <String, JournalLine>{},
        deletedHashes: const <String>{},
        nowMs: _now + 200,
      );
      final stateRows =
          appended.where((l) => l.type == JournalLine.typeState).toList();
      expect(stateRows.length, 1, reason: '重试不许产生第二行 state');
      expect(await Prefs.stateDayCount(), 1, reason: '限额计数只许加一次');
    });
  });

  // ————————————————————————————————————————————————————————————
  group('7. 端到端：上行请求体里真的有那一行（不是只测"本机多一行"）', () {
    test('bucket.upload 的字节里确实有一条 type=state / key=state:v1 / cap=2 的行',
        () async {
      HeartbeatService.beginSyncSession();
      final r = await HeartbeatService.instance.drainToJournal(nowMs: _now);
      expect(r.wrote, isTrue);

      // 生产路径：prefs 载荷 → LocalExport.state → 追加行 → 上传正文
      final payload = await CloudSync.readStatePayload();
      expect(payload, isNotEmpty);
      final appended = CloudSync.buildAppendedLines(
        local: _localWithState(payload),
        cloudKeys: const <String>{},
        cloudLatest: const <String, JournalLine>{},
        deletedHashes: const <String>{},
        nowMs: _now,
      );
      // `_runLockedOnce` 上传的就是这串字节：mergeJournal(raw, appended) 的 utf8
      final body = mergeJournal('', appended);
      final rows = parseJournalLines(body);

      final states = rows.where((row) => row.type == JournalLine.typeState);
      expect(states.length, 1, reason: '请求体里必须有一条 state 行');
      final state = states.first;
      expect(state.key, journalKeyState);
      expect(state.data['cap'], 2);
      expect(state.data['lastPulseAt'], _now);
      expect(
        body.contains('"type":"state"'),
        isTrue,
        reason: '断"正文里真有这行"，不是断一个内存对象',
      );
    });

    test('反例：state 为空时，请求体里没有 state 行，而且不抛', () async {
      final appended = CloudSync.buildAppendedLines(
        local: _localWithState(const <String, dynamic>{}),
        cloudKeys: const <String>{},
        cloudLatest: const <String, JournalLine>{},
        deletedHashes: const <String>{},
        nowMs: _now,
      );
      expect(appended.any((l) => l.type == JournalLine.typeState), isFalse,
          reason: '空 state 不许每轮都推一条空行');
      final body = mergeJournal('', appended);
      expect(body.contains('"type":"state"'), isFalse);
      expect(body, isEmpty, reason: '全空导出 → 空正文，绝不拼出坏行');
    });

    test('反例：云端已有同一份 state → 不重复追加（单赢家内容比较）', () async {
      HeartbeatService.beginSyncSession();
      await HeartbeatService.instance.drainToJournal(nowMs: _now);
      final payload = await CloudSync.readStatePayload();

      final cloudLatest = <String, JournalLine>{
        journalKeyState: JournalLine(
          type: JournalLine.typeState,
          key: journalKeyState,
          ts: _now - 1000,
          data: payload,
        ),
      };
      final appended = CloudSync.buildAppendedLines(
        local: _localWithState(payload),
        cloudKeys: <String>{journalKeyState},
        cloudLatest: cloudLatest,
        deletedHashes: const <String>{},
        nowMs: _now,
      );
      expect(appended.any((l) => l.type == JournalLine.typeState), isFalse);
    });
  });

  // ————————————————————————————————————————————————————————————
  group('8. reducer 纯函数（同输入同输出，字段集合封闭）', () {
    LifeState lifeAt(int hour) => ClockService.describe(
          now: DateTime(2026, 11, 25, hour, 0),
          identity: '在广州做设计',
          habits: '朝九晚六',
        );

    test('data 字段集合封闭：多一个字段都不许（防垃圾桶化）', () {
      final keys = const HeartbeatState().toData().keys.toSet();
      expect(keys, <String>{
        'activity',
        'energy',
        'moodLeft',
        'wantTalk',
        'lastPulseAt',
        'event',
      });
      // cap 是协议层注入的，不属于状态本身
      expect(keys.contains('cap'), isFalse);
    });

    test('同一组输入算两次结果完全相同（没有 now()/随机）', () {
      final a = HeartbeatReducer.next(
        prev: null,
        life: lifeAt(14),
        mood: const MoodState(anger: 30),
        lastMsgAt: _now - 1000,
        nowMs: _now,
      );
      final b = HeartbeatReducer.next(
        prev: null,
        life: lifeAt(14),
        mood: const MoodState(anger: 30),
        lastMsgAt: _now - 1000,
        nowMs: _now,
      );
      expect(a.state.toData(), b.state.toData());
      expect(a.reason, b.reason);
    });

    test('energy：深夜 20 档 / 上班 45 档，且夹在 0~100', () {
      expect(
        HeartbeatReducer.energyFor(hour: 2, activity: '睡觉', event: ''),
        lessThanOrEqualTo(20),
      );
      expect(HeartbeatReducer.energyFor(hour: 14, activity: '上班', event: ''),
          45);
      expect(HeartbeatReducer.energyFor(hour: 19, activity: '下班路上', event: ''),
          55);
      // 生病 -20 也不会掉到负数
      expect(
        HeartbeatReducer.energyFor(hour: 2, activity: '睡觉', event: 'sick'),
        greaterThanOrEqualTo(0),
      );
    });

    test('moodLeft = 100 - anger（只读 MoodState，不改它）', () {
      final mood = const MoodState(anger: 60);
      final d = HeartbeatReducer.next(
        prev: null,
        life: lifeAt(14),
        mood: mood,
        lastMsgAt: _now,
        nowMs: _now,
      );
      expect(d.state.moodLeft, 40);
      expect(mood.anger, 60, reason: 'reducer 不许改入参');
    });

    test('wantTalk：隔 >3h 或 有未消费 intent', () {
      final fresh = HeartbeatReducer.next(
        prev: null,
        life: lifeAt(14),
        mood: const MoodState(),
        lastMsgAt: _now - const Duration(minutes: 30).inMilliseconds,
        nowMs: _now,
      );
      expect(fresh.state.wantTalk, isFalse);

      final longGap = HeartbeatReducer.next(
        prev: null,
        life: lifeAt(14),
        mood: const MoodState(),
        lastMsgAt: _now - const Duration(hours: 4).inMilliseconds,
        nowMs: _now,
      );
      expect(longGap.state.wantTalk, isTrue);

      final intent = HeartbeatReducer.next(
        prev: null,
        life: lifeAt(14),
        mood: const MoodState(),
        lastMsgAt: _now,
        unconsumedIntents: 1,
        nowMs: _now,
      );
      expect(intent.state.wantTalk, isTrue);
    });

    test('reason 判定顺序：首次 → event → 情绪档 → 长间隔 → 时段 → none', () {
      final first = HeartbeatReducer.next(
        prev: null,
        life: lifeAt(14),
        mood: const MoodState(),
        lastMsgAt: _now,
        nowMs: _now,
      );
      expect(first.reason, HeartbeatReasons.period);

      final prev = first.state;
      final noChange = HeartbeatReducer.next(
        prev: prev,
        life: lifeAt(14),
        mood: const MoodState(),
        lastMsgAt: _now,
        nowMs: _now,
      );
      expect(noChange.reason, HeartbeatReasons.none);
      expect(noChange.shouldAppend, isFalse);

      final moodJump = HeartbeatReducer.next(
        prev: prev,
        life: lifeAt(14),
        mood: const MoodState(anger: 60),
        lastMsgAt: _now,
        nowMs: _now,
      );
      expect(moodJump.reason, HeartbeatReasons.moodLevel);
    });

    test('long_gap 只记"跨过 3h 的那一刻"，不是"一直处于长间隔"', () {
      // 上一份状态是"不想说话"
      const prev = HeartbeatState(
        activity: '在公司',
        energy: 45,
        moodLeft: 100,
        wantTalk: false,
        lastPulseAt: 0,
        event: '',
      );
      final crossed = HeartbeatReducer.next(
        prev: prev,
        life: lifeAt(14),
        mood: const MoodState(),
        lastMsgAt: _now - const Duration(hours: 4).inMilliseconds,
        nowMs: _now,
      );
      expect(crossed.reason, HeartbeatReasons.longGap);
      expect(crossed.state.wantTalk, isTrue);

      // 5 分钟后再算一次：仍然"隔了很久"，但已经记过了 → none
      final again = HeartbeatReducer.next(
        prev: crossed.state,
        life: lifeAt(14),
        mood: const MoodState(),
        lastMsgAt: _now - const Duration(hours: 4).inMilliseconds,
        nowMs: _now + const Duration(minutes: 5).inMilliseconds,
      );
      expect(again.reason, HeartbeatReasons.none,
          reason: '否则只要她半天不说话，每 5 分钟 tick 都记一行，4 行额度上午就见底');
    });

    test('reason == none 时不追加行（只更新本机缓存）', () async {
      HeartbeatService.beginSyncSession();
      final first =
          await HeartbeatService.instance.drainToJournal(nowMs: _now);
      expect(first.wrote, isTrue);

      // 5 分钟窗口过了，但状态没变 → unchanged，不写第二行
      final later = _now + const Duration(minutes: 6).inMilliseconds;
      final second =
          await HeartbeatService.instance.drainToJournal(nowMs: later);
      expect(second.wrote, isFalse);
      expect(second.reason, HeartbeatService.reasonUnchanged);
      expect(await Prefs.stateDayCount(), 1);
    });
  });

  // ————————————————————————————————————————————————————————————
  group('9. markEvent：只留 API，取值封闭', () {
    test('链外标记 → not_in_sync_session', () async {
      final r = await HeartbeatService.instance.markEvent('travel', nowMs: _now);
      expect(r.reason, HeartbeatService.reasonNotInSyncSession);
      expect(await Prefs.stateData(), isEmpty);
    });

    test('非法取值 → invalid_event（不许自由文本）', () async {
      HeartbeatService.beginSyncSession();
      final r =
          await HeartbeatService.instance.markEvent('在巴黎', nowMs: _now);
      expect(r.reason, HeartbeatService.reasonInvalidEvent);
      expect(await Prefs.stateData(), isEmpty);
    });

    test('链内标记 travel → 写成功且 event 落进载荷', () async {
      HeartbeatService.beginSyncSession();
      final r = await HeartbeatService.instance.markEvent('travel', nowMs: _now);
      expect(r.wrote, isTrue, reason: '显式标记可以越过 5 分钟去抖');
      expect(r.state!.event, 'travel');
      final payload = await CloudSync.readStatePayload();
      expect(payload['event'], 'travel');
    });
  });

  // ————————————————————————————————————————————————————————————
  group('10. 兼容：坏缓存不会把同步带崩', () {
    test('state_data 是坏 JSON → readStatePayload 返回空 map（不抛）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'state_data': '{not json',
      });
      expect(await CloudSync.readStatePayload(), isEmpty);
    });

    test('state_data 是 JSON 数组（不是对象）→ 也按空处理', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'state_data': jsonEncode(<int>[1, 2, 3]),
      });
      expect(await CloudSync.readStatePayload(), isEmpty);
    });
  });
}
