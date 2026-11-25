import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../data/db_helper.dart';
import '../data/prefs.dart';
import '../models/persona_space.dart';
import 'cloud_plan.dart';
import 'deepseek.dart';
import 'proactive_pool_store.dart';

/// 云端主动消息的 App 侧接线（T06）。
///
/// ## 挂接点：`CloudSync._runLockedOnce()` 的 `if (doPush) {` 块内
///
/// 设计文档 T06 节写的是「必须与 `CloudSync.align()` 在同一 async 调用链内」——
/// **那是错的**（架构师待改）：只有用户手动点「对齐云端」才走 `align()`，而防抖
/// 5 分钟（`scheduleUpload` → `pushOnly`）、退后台（`pushNowIfEnabled` → `pushOnly`）、
/// 重蒸后（`scheduleUpload` → `pushOnly`）**都不走 align**，它们占一天里的绝大多数。
/// 只挂 `align()` 的表现是"功能看起来接上了，但只有手动点对齐才补货"。
///
/// 所以补货挂在 `_runLockedOnce()` 的 push 段开头（与 T07 的 `state` drain 同一次
/// 呼吸、同一个会话、同样的成本口径）：那次会话本来就要上传一次，补货的写对象
/// 只是**多一个对象写**，不新开会话 ⇒ 边际桶数 ≈ 0。
///
/// ## 五条纪律（§5A.12，每条堵一个具体的坑）
/// 1. 候选句**永不进 prompt、不进导出、不占 journal type**：它只活在独立 COS 对象
///    `memories/<sub>/proactive-<dayKey>.json` 里。
/// 2. `write` 永不抛；失败即"今天没有"，**不许重试、不许定时补传、不许丢进后台任务**。
/// 3. 池 ≤ 8KB（`CosObjectPoolStore` 已拦），超出直接拒绝写。
/// 4. 旧的那套命名（O11 撤销的候选句前缀）不进生产代码：统一叫"候选句 / 候选句池"。
/// 5. 云端零 PG 查询：所有对象读写走 COS 路径（`CloudSync` 的 gateway），不碰
///    `storages/object`。
class CloudProactiveService {
  CloudProactiveService._();

  static final CloudProactiveService instance = CloudProactiveService._();

  /// 池子低于这个数才补货（3~5 条是预期值）。
  static const int minPoolSize = 3;

  /// 每次补货最多生成几条。
  static const int maxPoolSize = 5;

  // ——— 补货结果原因（测试按字面量断言，别改字眼） ———
  static const String reasonOff = 'off';
  static const String reasonEnough = 'enough';

  /// 今天已经尝试生成过一次（成功或失败都算）——**不再试第二次**。
  static const String reasonAlreadyTried = 'already_tried';
  static const String reasonNoKey = 'no_api_key';
  static const String reasonNoSub = 'no_sub';
  static const String reasonGenerated = 'generated';
  static const String reasonGenerateFailed = 'generate_failed';
  static const String reasonWriteFailed = 'write_failed';

  /// 补货：读今天的池，**不足 3 条才生成**；生成完立刻 `write`，写完即结束。
  ///
  /// [client] / [sub] 由 `CloudSync` 在同步会话里传进来（不在这里 new 一个通道，
  /// 也不读 `_uid`——服务不该知道"登录"这回事）。
  /// [generate] 可注入：默认走真实模型，测试里换成固定产出。
  Future<PoolSyncOutcome> syncPool({
    required ProactiveObjectClient client,
    required String sub,
    int? nowMs,
    PoolLineGenerator? generate,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;

    // 开关是 `'off' | 'on'` 的字符串（不是 bool）：脏数据一律按 off，
    // "不知道"绝不等于 on。判在这一层，调用方（cloud_sync）就没有漏判的机会。
    if (!await Prefs.cloudProactiveEnabled()) {
      return const PoolSyncOutcome(wrote: false, size: 0, reason: reasonOff);
    }
    if (sub.trim().isEmpty) {
      return const PoolSyncOutcome(wrote: false, size: 0, reason: reasonNoSub);
    }
    final dayKey = CloudPlan.dayKeyOf(now);
    final store = CosObjectPoolStore(client: client, sub: sub);

    try {
      final existing = await store.read(dayKey);
      if (existing.items.length >= minPoolSize) {
        return PoolSyncOutcome(
          wrote: false,
          size: existing.items.length,
          reason: reasonEnough,
        );
      }

      // 每日尝试守卫：**成功失败都算"试过"**。
      //
      // 没有这一条时的放大路径：池子读不到 → read 返回空池（分不清"空"和"读失败"）
      // → 又生成 → 又调一次模型（5~15s）→ 写失败 → 5 分钟后下一轮同步再来一遍。
      // 一天活跃 12 小时就是上百次模型调用，而且每次都把同步会话拖十几秒。
      // 一次故障自己放大成账单，比"今天没有候选句"严重得多。
      final attemptDay = await Prefs.proactivePoolAttemptDay();
      if (attemptDay == dayKey) {
        return PoolSyncOutcome(
          wrote: false,
          size: existing.items.length,
          reason: reasonAlreadyTried,
        );
      }
      // 先落标记再生成：进程中途被杀也算"试过"（失败即今天没有，不补传）。
      await Prefs.setProactivePoolAttemptDay(dayKey);

      final gen = generate ?? _defaultGenerate;
      final want = maxPoolSize - existing.items.length;
      final lines = await gen(count: want);
      final merged = _mergeUnique(existing.items, lines, now);
      if (merged.length <= existing.items.length) {
        // 一条新的都没生成出来（模型空转 / 全重复）：当作"今天没有"，
        // 不写空对象、不重试。
        return PoolSyncOutcome(
          wrote: false,
          size: existing.items.length,
          reason: reasonGenerateFailed,
        );
      }

      final pool = ProactivePool(dayKey: dayKey, items: merged);
      final w = await store.write(dayKey, pool);
      if (!w.ok) {
        return PoolSyncOutcome(
          wrote: false,
          size: existing.items.length,
          reason: reasonWriteFailed,
          detail: w.reason,
        );
      }
      return PoolSyncOutcome(
        wrote: true,
        size: merged.length,
        reason: reasonGenerated,
      );
    } catch (e) {
      // 纪律 2：这里永不抛。失败即今天没有。
      return PoolSyncOutcome(
        wrote: false,
        size: 0,
        reason: reasonGenerateFailed,
        detail: e.toString(),
      );
    }
  }

  /// 把新生成的句子并进已有池：去空、去重（按 `sha16(text)`）、上限 [maxPoolSize]。
  static List<PoolItem> _mergeUnique(
    List<PoolItem> existing,
    List<String> fresh,
    int nowMs,
  ) {
    final seen = <String>{for (final it in existing) it.key};
    final out = <PoolItem>[...existing];
    for (final raw in fresh) {
      if (out.length >= maxPoolSize) break;
      final text = raw.trim();
      if (text.isEmpty) continue;
      final item = PoolItem.fromText(text, createdAt: nowMs);
      if (seen.contains(item.key)) continue;
      seen.add(item.key);
      out.add(item);
    }
    return out;
  }

  /// 默认生成器：一次模型调用吐 3~5 条短句（不是每条一次调用——会话预算有限）。
  static Future<List<String>> _defaultGenerate({required int count}) async {
    final key = await Prefs.apiKey();
    if (key.trim().isEmpty) return const <String>[];
    final c = await DbHelper.instance.firstCompanion();
    if (c == null) return const <String>[];
    final fields = PersonaSpace.decode(c.personaSpace).fields;
    final identity = fields['identity'] ?? c.persona;
    final personality = fields['personality'] ?? '';

    final json = await DeepSeekService().completeJson(
      apiKey: key,
      system: '你是「${c.name}」，一个真实的人。现在为你准备今天可能主动说出口的几句话。'
          '你的身份：$identity\n你的性格：$personality\n'
          '要求：只输出 JSON 对象 {"lines": ["…", …]}；'
          '每条 1~2 句、≤20 字、口语、有温度；不要客套、不要解释、不要括号动作；'
          '不要提"系统""记忆""AI"这类词；不要在句子里写日期或时刻。',
      user: '给我 $count 条今天可能主动说的话（互不重复，语气自然）。',
      maxTokens: 500,
      temperature: 0.9,
    );
    final raw = json['lines'];
    if (raw is! List) return const <String>[];
    return <String>[
      for (final v in raw)
        if (v is String && v.trim().isNotEmpty) v.trim(),
    ];
  }

  // ——————————————————————————————————————————————————————————
  // 对账（reconcile）
  // ——————————————————————————————————————————————————————————

  /// 对账：算出"云端今天应该发了几条 / 本机确认了几条 / 差几条"，差的按窗口
  /// **从早到晚**补标成本机 `delivery_log` 的 `c:<windowKey>` 记录，并给出是否
  /// 需要落 L3 兜底。
  ///
  /// [cloudSentWindows] 是"云端声称已发的窗口序号"（来自 pushplus 记录或游标；
  /// 接口不可用时传 null，走"按窗口数推算"的兜底路径）。
  ///
  /// 只写本机，**绝不回写云端**（投递状态不属于"她的记忆"）。
  Future<ReconcileOutcome> reconcile({
    CloudDeliveryLog? log,
    int? nowMs,
    Set<int>? cloudSentWindows,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final dayKey = CloudPlan.dayKeyOf(now);
    final passed = CloudPlan.passedWindowIndexes(dayKey, now);

    var confirmed = <int>{};
    try {
      final entries = await (log ?? FileCloudDeliveryLog()).read();
      confirmed = <int>{
        for (final e in entries)
          if (e.dayKey == dayKey && e.windowIndex != null) e.windowIndex!,
      };
    } catch (_) {
      // 读日志失败按"没确认过"处理：宁可多标一条，也不让对账整段失效。
    }

    final outcome = planReconcile(
      dayKey: dayKey,
      passedWindows: passed,
      confirmedWindows: confirmed,
      cloudSentWindows: cloudSentWindows,
    );

    if (outcome.markedWindows.isNotEmpty) {
      await markCloudDelivered(
        dayKey: dayKey,
        windows: outcome.markedWindows,
        log: log,
        nowMs: now,
      );
    }
    return outcome;
  }

  /// 对账的**纯决策**部分（零 IO、可单测）。四种情形都在这里分叉：
  /// 1. 有记录命中 → 已确认，不补标；
  /// 2. 有记录未命中 → 该窗口云端确实发过，补标；
  /// 3. 无记录（接口不可用）→ 按"已过窗口数 − 已确认数"推算，补标最早的几条；
  /// 4. 云端整日无痕迹 → [ReconcileOutcome.degradeToL3] = true（落 L3 补 1 条）。
  static ReconcileOutcome planReconcile({
    required String dayKey,
    required List<int> passedWindows,
    required Set<int> confirmedWindows,
    required Set<int>? cloudSentWindows,
  }) {
    final confirmed = confirmedWindows.where(passedWindows.contains).toSet();
    final expected = passedWindows.length;
    final cloudHasTrace = cloudSentWindows != null && cloudSentWindows.isNotEmpty;

    final marked = <int>{};
    if (cloudHasTrace) {
      // 情形 ①②：云端有记录 → 记录里有、本机没有的窗口补标。
      for (final idx in cloudSentWindows) {
        if (passedWindows.contains(idx) && !confirmed.contains(idx)) {
          marked.add(idx);
        }
      }
    } else {
      // 情形 ③：没有记录 → 按窗口数推算缺几条，补最早的几条（云端按窗口顺序发）。
      final missing = expected - confirmed.length;
      if (missing > 0) {
        final candidates = passedWindows.where((i) => !confirmed.contains(i));
        marked.addAll(candidates.take(missing));
      }
    }

    // 情形 ④：今天已经过了至少一个窗口，但云端一条痕迹都没有、本机也一条没确认
    // → 云端今天没跑（cron 挂了 / 没配 / 被停），落 L3 补 1 条，别让她整天不出现。
    final degradeToL3 =
        !cloudHasTrace && expected >= 1 && confirmed.isEmpty;

    return ReconcileOutcome(
      dayKey: dayKey,
      expected: expected,
      confirmed: confirmed.length,
      markedWindows: (marked.toList()..sort()),
      degradeToL3: degradeToL3,
      cloudHasTrace: cloudHasTrace,
    );
  }

  /// 把若干窗口标成"云端已发"，**只写本机** `delivery_log`（`c:` 前缀）。
  ///
  /// `d:` 前缀属于本地通道（T03 的 `ChannelRouter`），`c:` 属于云端通道，
  /// 两者并列不冲突（§5.5 / §5A.7）。
  Future<void> markCloudDelivered({
    required String dayKey,
    required List<int> windows,
    CloudDeliveryLog? log,
    int? nowMs,
  }) async {
    if (windows.isEmpty) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final target = log ?? FileCloudDeliveryLog();
    for (final i in windows) {
      try {
        await target.append(CloudDeliveryEntry(
          dayKey: dayKey,
          windowIndex: i,
          channel: 'cloud',
          result: 'ok',
          at: now,
        ));
      } catch (_) {
        // 纪律 2 的同一口径：记不下就算了，绝不抛、绝不重试。
      }
    }
  }
}

/// 生成器：`count` 条候选句正文。可注入（测试用固定产出，不打模型）。
typedef PoolLineGenerator = Future<List<String>> Function({required int count});

/// 一次补货的结果。
class PoolSyncOutcome {
  /// 是否真的写了对象。
  final bool wrote;

  /// 写完（或跳过后）池里有几条。
  final int size;

  /// 见 `CloudProactiveService.reasonXxx`。
  final String reason;

  /// 失败详情（只进诊断，不给用户看）。
  final String detail;

  const PoolSyncOutcome({
    required this.wrote,
    required this.size,
    required this.reason,
    this.detail = '',
  });

  @override
  String toString() =>
      'PoolSyncOutcome(wrote: $wrote, size: $size, reason: $reason)';
}

/// 一次对账的结果。
class ReconcileOutcome {
  final String dayKey;

  /// 到此刻为止"云端应该已经发了几条"（= 已过窗口数）。
  final int expected;

  /// 本机 `delivery_log` 里确认过几条。
  final int confirmed;

  /// 这次补标的窗口序号（升序）。
  final List<int> markedWindows;

  /// 云端整日无痕迹 → 需要落 L3 补 1 条。
  ///
  /// ⚠️ 本字段只判「**该补一条**」，实际派发在 **T03 的 `ChannelRouter`**，
  /// 未实现前这条只到**判据级**：置 `true` 不等于用户已经收到任何东西。
  /// 谁要是拿它当"已经补了"，就会出现"看起来做了、用户什么都没收到"。
  final bool degradeToL3;

  /// 云端今天有没有留下任何痕迹（pushplus 记录 / 游标）。
  final bool cloudHasTrace;

  const ReconcileOutcome({
    required this.dayKey,
    required this.expected,
    required this.confirmed,
    required this.markedWindows,
    required this.degradeToL3,
    required this.cloudHasTrace,
  });

  int get missing => expected - confirmed;

  @override
  String toString() => 'ReconcileOutcome(day: $dayKey, expected: $expected, '
      'confirmed: $confirmed, marked: $markedWindows, l3: $degradeToL3)';
}

/// 一条"云端已发"的本机记录。
///
/// 行格式与 `delivery_log.jsonl` 对齐（§3.2 ③），只是 `channel` 多了 `cloud`
/// 这个取值、`dedup` 用 `c:` 前缀：
/// `{"v":1,"slotMs":…,"channel":"cloud","result":"ok","dedup":"c:20261125#2","at":…}`
class CloudDeliveryEntry {
  final String dayKey;

  /// 窗口序号；解析失败为 null（坏行跳过）。
  final int? windowIndex;

  final String channel;
  final String result;
  final int at;

  const CloudDeliveryEntry({
    required this.dayKey,
    required this.windowIndex,
    required this.channel,
    required this.result,
    required this.at,
  });

  /// 去重键：`c:<dayKey>#<windowIndex>`——同一窗口只允许一条 `result=ok`。
  String get dedup =>
      windowIndex == null ? '' : 'c:$dayKey#$windowIndex';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': 1,
        'channel': channel,
        'result': result,
        'dedup': dedup,
        'at': at,
      };

  /// 容错解析：坏行一律 null（调用方跳过）。
  static CloudDeliveryEntry? fromJson(Map<String, dynamic> m) {
    final dedup = m['dedup'] is String ? m['dedup'] as String : '';
    if (!dedup.startsWith('c:')) return null;
    final body = dedup.substring(2);
    final hash = body.indexOf('#');
    if (hash <= 0) return null;
    final dayKey = body.substring(0, hash);
    final idx = int.tryParse(body.substring(hash + 1));
    if (idx == null || dayKey.isEmpty) return null;
    return CloudDeliveryEntry(
      dayKey: dayKey,
      windowIndex: idx,
      channel: m['channel'] is String ? m['channel'] as String : 'cloud',
      result: m['result'] is String ? m['result'] as String : 'ok',
      at: m['at'] is int ? m['at'] as int : 0,
    );
  }
}

/// 本机投递日志的读写口子（只认 `c:` 那些行）。
///
/// T03 会实现 `lib/data/local_files.dart`（`delivery_log.jsonl` 的正式读写层、
/// 含 14 天裁剪）。到时把这个接口的实现换过去即可，**本文件只保留调用**。
/// 现在先给一个最小文件实现：追加 + 容错读，失败一律吞掉（后台行为静默）。
abstract class CloudDeliveryLog {
  Future<List<CloudDeliveryEntry>> read();

  Future<void> append(CloudDeliveryEntry entry);
}

/// 最小文件实现：`<documents>/delivery_log.jsonl`，只追加。
///
/// ⚠️ **这是临时实现，不是最终实现**：T03 的 `lib/data/local_files.dart` 落地后
/// **必须替换本实现**（本文件只保留调用）。替换时保持：
/// - 行格式与设计 §3.2 ③ 一致；
/// - `channel` 增加 `cloud` 取值；
/// - `dedup` 用 `c:` 前缀（与本地通道的 `d:` 并列，不冲突）。
/// 临时实现不可怕，可怕的是它悄悄变成永久实现——"两个写者各写一套行格式"是
/// 最难查的一类 bug（两边都"能跑"，只是互相看不见对方写的行）。
class FileCloudDeliveryLog implements CloudDeliveryLog {
  /// 只用于测试（默认走 `getApplicationDocumentsDirectory()`）。
  final Directory? dir;

  const FileCloudDeliveryLog({this.dir});

  static const String fileName = 'delivery_log.jsonl';

  /// 只保留最近这么多天（防无限膨胀；正式裁剪归 T03）。
  static const int keepDays = 14;

  Future<File> _file() async {
    final d = dir ?? await getApplicationDocumentsDirectory();
    return File('${d.path}${Platform.pathSeparator}$fileName');
  }

  @override
  Future<List<CloudDeliveryEntry>> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const <CloudDeliveryEntry>[];
      final raw = await f.readAsString();
      final out = <CloudDeliveryEntry>[];
      for (final line in raw.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        try {
          final decoded = jsonDecode(t);
          if (decoded is Map<String, dynamic>) {
            final e = CloudDeliveryEntry.fromJson(decoded);
            if (e != null) out.add(e);
          }
        } catch (_) {
          // 坏行跳过，绝不因一行坏数据丢掉整份日志。
        }
      }
      return out;
    } catch (_) {
      return const <CloudDeliveryEntry>[];
    }
  }

  @override
  Future<void> append(CloudDeliveryEntry entry) async {
    try {
      final f = await _file();
      await f.writeAsString('${jsonEncode(entry.toJson())}\n',
          mode: FileMode.append, flush: true);
    } catch (_) {
      // 写不进去就算了：对账是尽力而为，不能因为它把同步主路径带崩。
    }
  }
}

/// 供 `CloudSync` 之外的地方判断"今天要不要落 L3"的最小入口（诊断页可读）。
///
/// 注意：本函数只判「该补一条」，**不派发任何通知**；实际派发在 T03 的
/// `ChannelRouter`，未实现前这条只到**判据级**（返回 true ≠ 用户收到）。
/// 真正落 L3 是 T03 的通道分级负责的事。
Future<bool> shouldDegradeToLocalFallback({int? nowMs}) async {
  final o = await CloudProactiveService.instance.reconcile(nowMs: nowMs);
  return o.degradeToL3;
}
