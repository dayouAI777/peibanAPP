import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/data/prefs.dart';
import 'package:peiban_app/models/journal.dart';
import 'package:peiban_app/services/cloud_plan.dart';
import 'package:peiban_app/services/cloud_proactive_service.dart';
import 'package:peiban_app/services/proactive_pool_store.dart';
import 'package:peiban_app/services/proactive_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假对象通道：记录读写次数与内容，永不抛（与生产实现同口径）。
class _FakeObjectClient implements ProactiveObjectClient {
  final Map<String, String> objects = <String, String>{};
  int reads = 0;
  int writes = 0;
  String? failWriteWith;

  @override
  Future<String?> readObject(String path) async {
    reads++;
    return objects[path];
  }

  @override
  Future<PoolWriteResult> writeObject(String path, String body) async {
    writes++;
    if (failWriteWith != null) {
      return PoolWriteResult.failed(failWriteWith!);
    }
    objects[path] = body;
    return const PoolWriteResult.success();
  }
}

/// 假本机投递日志（只记 `c:` 那类条目）。
class _FakeLog implements CloudDeliveryLog {
  final List<CloudDeliveryEntry> entries = <CloudDeliveryEntry>[];

  @override
  Future<List<CloudDeliveryEntry>> read() async => entries;

  @override
  Future<void> append(CloudDeliveryEntry entry) async => entries.add(entry);
}

/// 固定"现在"：2026-11-25 15:00（+08:00）。
/// 25 号窗口表是 [562,667,928,1168,1283] 分钟 ⇒ 此刻已过 0、1 两个窗口。
int _nowAt(int minutesOfDay) =>
    CloudPlan.chinaDayStartMs('20261125') +
    minutesOfDay * CloudPlan.msPerMin;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ————————————————————————————————————————————————————————————
  group('1. 排期纯函数：与 Node 端 plan.js 逐字一致（固定向量）', () {
    // 向量由 `node -e "require('./lib/plan.js')…"` 在 peiban-core 实测产出，
    // 两端任一侧改算法，这里就红。
    const vectors = <String, List<int>>{
      '20261125': <int>[562, 667, 928, 1168, 1283],
      '20261126': <int>[665, 923, 1043, 1153],
      '20260101': <int>[569, 797, 920],
      '20261231': <int>[556, 928, 1036, 1159, 1266],
    };

    test('slots 与 Node 逐字相等（4 个固定 dayKey）', () {
      vectors.forEach((dayKey, expected) {
        expect(CloudPlan.slots(dayKey), expected, reason: 'dayKey=$dayKey');
        expect(CloudPlan.dayCount(dayKey), expected.length,
            reason: 'dayCount 必须等于 slots 长度（dayKey=$dayKey）');
      });
    });

    test('sendAt[0] 与 Node 逐字相等（25 号 = 1795569720000）', () {
      expect(CloudPlan.sendAt('20261125', 0), 1795569720000);
      expect(CloudPlan.sendAt('20260101', 0), 1767230940000);
      // 越界返回 null（Node 那边是 NaN）
      expect(CloudPlan.sendAt('20261125', 99), isNull);
    });

    test('dayKey 按 +08:00 折算；零点毫秒与 Node 一致', () {
      expect(CloudPlan.chinaDayStartMs('20261125'), 1795536000000);
      // 2025-11-24T16:00:00Z = +08:00 的 25 日零点
      expect(CloudPlan.dayKeyOf(1764000000000), '20251125');
    });

    test('逐日条数恒在 [3,5]，且相邻两条间隔 ≥90 分钟', () {
      for (var d = 1; d <= 28; d++) {
        final dayKey = '202611${d.toString().padLeft(2, '0')}';
        final s = CloudPlan.slots(dayKey);
        expect(s.length, inInclusiveRange(3, 5));
        for (var i = 1; i < s.length; i++) {
          expect(s[i] - s[i - 1], greaterThanOrEqualTo(90),
              reason: '$dayKey 的第 $i 条间隔太近');
        }
        // 末条绝不越 23:00
        expect(s.last, lessThan(23 * 60));
      }
    });
  });

  // ————————————————————————————————————————————————————————————
  group('2. 对账四种情形（纯决策，零 IO）', () {
    test('① 有记录命中：云端发过的窗口本机也都确认了 → 不补标、不落 L3', () {
      final o = CloudProactiveService.planReconcile(
        dayKey: '20261125',
        passedWindows: <int>[0, 1],
        confirmedWindows: <int>{0, 1},
        cloudSentWindows: <int>{0, 1},
      );
      expect(o.expected, 2);
      expect(o.confirmed, 2);
      expect(o.markedWindows, isEmpty);
      expect(o.degradeToL3, isFalse);
      expect(o.cloudHasTrace, isTrue);
    });

    test('② 有记录未命中：云端说发了、本机没记 → 补标那个窗口', () {
      final o = CloudProactiveService.planReconcile(
        dayKey: '20261125',
        passedWindows: <int>[0, 1],
        confirmedWindows: <int>{0},
        cloudSentWindows: <int>{0, 1},
      );
      expect(o.missing, 1);
      expect(o.markedWindows, <int>[1]);
      expect(o.degradeToL3, isFalse);
    });

    test('③ 无记录（接口不可用）→ 按窗口数推算，补最早的几条', () {
      final o = CloudProactiveService.planReconcile(
        dayKey: '20261125',
        passedWindows: <int>[0, 1, 2],
        confirmedWindows: <int>{0},
        cloudSentWindows: null,
      );
      expect(o.expected, 3);
      expect(o.confirmed, 1);
      expect(o.markedWindows, <int>[1, 2], reason: '按窗口先后补，不随机挑');
      expect(o.degradeToL3, isFalse, reason: '云端没痕迹但本机有确认，不算整日无痕迹');
    });

    test('④ 云端整日无痕迹 → 落 L3 补 1 条', () {
      final o = CloudProactiveService.planReconcile(
        dayKey: '20261125',
        passedWindows: <int>[0, 1],
        confirmedWindows: const <int>{},
        cloudSentWindows: null,
      );
      expect(o.cloudHasTrace, isFalse);
      expect(o.degradeToL3, isTrue,
          reason: '云端今天没跑（cron 挂了/没配），不能让她整天不出现');
      expect(o.markedWindows, <int>[0, 1]);
    });

    test('一个窗口都没过的时候不落 L3（早上八点不该触发兜底）', () {
      final o = CloudProactiveService.planReconcile(
        dayKey: '20261125',
        passedWindows: const <int>[],
        confirmedWindows: const <int>{},
        cloudSentWindows: null,
      );
      expect(o.expected, 0);
      expect(o.degradeToL3, isFalse);
    });
  });

  // ————————————————————————————————————————————————————————————
  group('3. reconcile 的 IO 版：只写本机 delivery_log（c: 前缀）', () {
    test('云端正午前发过一条、本机没记 → 补一条 c: 记录，且不碰云端', () async {
      final log = _FakeLog();
      final o = await CloudProactiveService.instance.reconcile(
        log: log,
        nowMs: _nowAt(15 * 60), // 15:00，已过 0/1 两个窗口
        cloudSentWindows: <int>{0},
      );
      expect(o.expected, 2);
      // 云端说 0 号窗口发过了，本机没记 → 补标的正是 0 号
      expect(o.markedWindows, <int>[0]);
      expect(log.entries.length, 1);
      expect(log.entries.first.dayKey, '20261125');
      expect(log.entries.first.dedup, 'c:20261125#0');
      expect(log.entries.first.channel, 'cloud');
    });

    test('本机已有 c: 记录 → 不重复补标（幂等）', () async {
      final log = _FakeLog()
        ..entries.add(const CloudDeliveryEntry(
          dayKey: '20261125',
          windowIndex: 0,
          channel: 'cloud',
          result: 'ok',
          at: 1,
        ));
      final o = await CloudProactiveService.instance.reconcile(
        log: log,
        nowMs: _nowAt(15 * 60),
        cloudSentWindows: <int>{0, 1},
      );
      expect(o.confirmed, 1);
      expect(o.markedWindows, <int>[1], reason: '0 号已确认过，只补 1 号');
      expect(log.entries.length, 2);
    });
  });

  // ————————————————————————————————————————————————————————————
  group('4. 通道分级：cloudProactive=on 时本地一条都不排', () {
    test('on → notify/pushplus 全关、unread 保留', () {
      final plan = ProactiveService.channelPlanFor(Prefs.cloudProactiveOn);
      expect(plan.notify, isFalse, reason: 'L1 必须停用，否则一天响两次');
      expect(plan.pushplus, isFalse, reason: 'L2 与云端同一条 pushplus，会双发');
      expect(plan.unread, isTrue, reason: 'L3 永远保留：它是唯一的兜底痕迹');
    });

    test('off / 脏值 / 空 → 本地照旧（"不知道"不许当成 on）', () {
      for (final v in <String>['off', 'ON', '', 'unknown', 'true']) {
        final plan = ProactiveService.channelPlanFor(v);
        expect(plan.notify, isTrue, reason: '取值「$v」必须按 off 处理');
        expect(plan.pushplus, isTrue);
        expect(plan.unread, isTrue);
      }
    });

    test('on 时 reschedule() 返回 0 条（且不抛异常）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cloud_proactive': Prefs.cloudProactiveOn,
      });
      final n = await ProactiveService.reschedule(name: '姜禾');
      expect(n, 0, reason: '云端接管时本地排程必须是 0 条');
    });

    test('Prefs：只有 off/on 两值，默认 off，写入脏值被归一成 off', () async {
      expect(await Prefs.cloudProactive(), Prefs.cloudProactiveOff);
      expect(await Prefs.cloudProactiveEnabled(), isFalse);
      await Prefs.setCloudProactive('ON');
      expect(await Prefs.cloudProactive(), Prefs.cloudProactiveOff);
      await Prefs.setCloudProactive(Prefs.cloudProactiveOn);
      expect(await Prefs.cloudProactiveEnabled(), isTrue);
    });
  });

  // ————————————————————————————————————————————————————————————
  group('5. 补货 syncPool：不足 3 条才生成，写完即结束', () {
    test('开关 off → 一条都不生成、一个对象都不写', () async {
      final client = _FakeObjectClient();
      var generated = 0;
      final o = await CloudProactiveService.instance.syncPool(
        client: client,
        sub: 'sub-1',
        nowMs: _nowAt(15 * 60),
        generate: ({required int count}) async {
          generated++;
          return <String>['在忙吗'];
        },
      );
      expect(o.reason, CloudProactiveService.reasonOff);
      expect(o.wrote, isFalse);
      expect(generated, 0);
      expect(client.writes, 0);
    });

    test('已有 3 条以上 → 不生成、不写（enough）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cloud_proactive': Prefs.cloudProactiveOn,
      });
      final client = _FakeObjectClient();
      final dayKey = CloudPlan.dayKeyOf(_nowAt(15 * 60));
      client.objects['sub-1/proactive-$dayKey.json'] =
          const ProactivePool(dayKey: '', items: <PoolItem>[
        PoolItem(key: 'a', text: '一', createdAt: 1),
        PoolItem(key: 'b', text: '二', createdAt: 2),
        PoolItem(key: 'c', text: '三', createdAt: 3),
      ]).encode();
      var generated = 0;
      final o = await CloudProactiveService.instance.syncPool(
        client: client,
        sub: 'sub-1',
        nowMs: _nowAt(15 * 60),
        generate: ({required int count}) async {
          generated++;
          return <String>['新的'];
        },
      );
      expect(o.reason, CloudProactiveService.reasonEnough);
      expect(o.size, 3);
      expect(generated, 0);
      expect(client.writes, 0);
    });

    test('空池 → 生成 3~5 条、立刻写对象，正文可被解析回来', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cloud_proactive': Prefs.cloudProactiveOn,
      });
      final client = _FakeObjectClient();
      final o = await CloudProactiveService.instance.syncPool(
        client: client,
        sub: 'sub-1',
        nowMs: _nowAt(15 * 60),
        generate: ({required int count}) async {
          expect(count, 5, reason: '空池时一次补到上限 5 条');
          return <String>['在忙吗', '刚想到你', '吃了吗', '今天好累', '早点睡'];
        },
      );
      expect(o.reason, CloudProactiveService.reasonGenerated);
      expect(o.wrote, isTrue);
      expect(o.size, 5);
      expect(client.writes, 1);

      final dayKey = CloudPlan.dayKeyOf(_nowAt(15 * 60));
      final back = ProactivePool.decode(
          client.objects['sub-1/proactive-$dayKey.json']!);
      expect(back.items.length, 5);
      expect(back.items.first.text, '在忙吗');
      expect(back.dayKey, dayKey);
    });

    test('生成重复/空串 → 去重 + 丢空，不会写进池', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cloud_proactive': Prefs.cloudProactiveOn,
      });
      final client = _FakeObjectClient();
      final o = await CloudProactiveService.instance.syncPool(
        client: client,
        sub: 'sub-1',
        nowMs: _nowAt(15 * 60),
        generate: ({required int count}) async =>
            <String>['在忙吗', '在忙吗', '  ', '在忙吗'],
      );
      expect(o.wrote, isTrue);
      expect(o.size, 1, reason: '三条一样 + 一条空白 → 池里只有 1 条');
    });

    test('生成不出东西 → generate_failed，不写空对象、不重试', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cloud_proactive': Prefs.cloudProactiveOn,
      });
      final client = _FakeObjectClient();
      final o = await CloudProactiveService.instance.syncPool(
        client: client,
        sub: 'sub-1',
        nowMs: _nowAt(15 * 60),
        generate: ({required int count}) async => const <String>[],
      );
      expect(o.reason, CloudProactiveService.reasonGenerateFailed);
      expect(o.wrote, isFalse);
      expect(client.writes, 0);
      expect(client.reads, 1, reason: '只读一次，失败不许重试');
    });

    test('同一天只尝试一次生成：失败后第二次调用不再触发生成（防账单放大）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cloud_proactive': Prefs.cloudProactiveOn,
      });
      final client = _FakeObjectClient();
      var attempts = 0;
      Future<List<String>> fail({required int count}) async {
        attempts++;
        return const <String>[]; // 生成失败
      }

      final first = await CloudProactiveService.instance.syncPool(
        client: client,
        sub: 'sub-1',
        nowMs: _nowAt(15 * 60),
        generate: fail,
      );
      expect(first.reason, CloudProactiveService.reasonGenerateFailed);
      expect(attempts, 1);

      // 5 分钟后同一轮同步会话再来一次：**必须直接跳过，不许再调模型**
      final second = await CloudProactiveService.instance.syncPool(
        client: client,
        sub: 'sub-1',
        nowMs: _nowAt(15 * 60 + 5),
        generate: fail,
      );
      expect(second.reason, CloudProactiveService.reasonAlreadyTried,
          reason: '同一天第二次必须被每日尝试守卫挡住');
      expect(second.wrote, isFalse);
      expect(attempts, 1, reason: '一天只许调一次模型：失败即今天没有，不是"失败就再试"');
      expect(client.writes, 0);
    });

    test('跨天后守卫放开：第二天会重新尝试一次', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cloud_proactive': Prefs.cloudProactiveOn,
      });
      final client = _FakeObjectClient();
      var attempts = 0;
      Future<List<String>> gen({required int count}) async {
        attempts++;
        return <String>['在忙吗'];
      }

      await CloudProactiveService.instance.syncPool(
        client: client,
        sub: 'sub-1',
        nowMs: _nowAt(15 * 60),
        generate: gen,
      );
      expect(attempts, 1);

      // 第二天（+1 天）同一个时刻：dayKey 变了，守卫必须放开
      await CloudProactiveService.instance.syncPool(
        client: client,
        sub: 'sub-1',
        nowMs: _nowAt(15 * 60) + CloudPlan.msPerDay,
        generate: gen,
      );
      expect(attempts, 2, reason: '每日守卫只挡"同一天"，跨天必须重置');
    });

    test('写对象失败 → write_failed，且不抛异常', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cloud_proactive': Prefs.cloudProactiveOn,
      });
      final client = _FakeObjectClient()..failWriteWith = '网络断了';
      final o = await CloudProactiveService.instance.syncPool(
        client: client,
        sub: 'sub-1',
        nowMs: _nowAt(15 * 60),
        generate: ({required int count}) async => <String>['在忙吗'],
      );
      expect(o.reason, CloudProactiveService.reasonWriteFailed);
      expect(o.wrote, isFalse);
      expect(client.writes, 1, reason: '写一次就结束，不许重试');
    });

    test('sub 为空 → no_sub（不猜路径、不写）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cloud_proactive': Prefs.cloudProactiveOn,
      });
      final client = _FakeObjectClient();
      final o = await CloudProactiveService.instance.syncPool(
        client: client,
        sub: '  ',
        nowMs: _nowAt(15 * 60),
      );
      expect(o.reason, CloudProactiveService.reasonNoSub);
      expect(client.writes, 0);
    });
  });

  // ————————————————————————————————————————————————————————————
  group('6. 本机投递日志（文件实现）：容错、只认 c: 行', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('peiban-delivery-');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('追加 + 读回：坏行跳过，不因一行坏数据丢整份日志', () async {
      final log = FileCloudDeliveryLog(dir: tmp);
      await log.append(const CloudDeliveryEntry(
        dayKey: '20261125',
        windowIndex: 0,
        channel: 'cloud',
        result: 'ok',
        at: 1,
      ));
      await log.append(const CloudDeliveryEntry(
        dayKey: '20261125',
        windowIndex: 1,
        channel: 'cloud',
        result: 'ok',
        at: 2,
      ));
      // 混进三种坏行：坏 JSON / 空行 / 不是 c: 前缀（本地通道的 d: 行）
      final f = File('${tmp.path}${Platform.pathSeparator}'
          '${FileCloudDeliveryLog.fileName}');
      await f.writeAsString(
        'not json\n\n'
        '${jsonEncode(<String, dynamic>{'dedup': 'd:123', 'result': 'ok'})}\n',
        mode: FileMode.append,
        flush: true,
      );

      final back = await log.read();
      expect(back.length, 2);
      expect(back.map((e) => e.windowIndex), <int>[0, 1]);
    });

    test('文件不存在 → 空列表（不是错误）', () async {
      expect(await FileCloudDeliveryLog(dir: tmp).read(), isEmpty);
    });
  });

  // ————————————————————————————————————————————————————————————
  group('7. 硬约束：候选句不进 prompt/导出/journal，生产代码不出现禁令词', () {
    test('候选句池不是一个 journal type（knownTypes 里没有它）', () {
      expect(JournalLine.knownTypes.contains('proactive'), isFalse);
      expect(JournalLine.knownTypes.contains('pool'), isFalse);
      expect(JournalLine.knownTypes.contains('pending'), isFalse);
    });

    test('生产代码里不出现禁令词（候选句的新名字是"候选句 / 候选句池"）', () {
      for (final f in <String>[
        'lib/services/proactive_pool_store.dart',
        'lib/services/cloud_proactive_service.dart',
        'lib/services/cloud_plan.dart',
        'lib/services/cloud_reader.dart',
      ]) {
        final src = File(f).readAsStringSync();
        expect(RegExp(r'\bpending\b', caseSensitive: false).hasMatch(src), isFalse,
            reason: '$f 里出现了 pending 这个词（O11 已撤销该命名）');
      }
    });

    test('候选句池对象路径与云母库同级但不同文件（不写进 journal.jsonl）', () {
      final p = poolObjectPathFor('sub-1', '20261125');
      expect(p, 'sub-1/proactive-20261125.json');
      expect(p.endsWith('journal.jsonl'), isFalse);
    });
  });
}
