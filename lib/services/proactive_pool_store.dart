/// 5. 接口不知道"什么时候写"，只管"写什么、写成什么样"。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 候选句池（T06 · R1-Cloud · §5A.12）。
///
/// 它是「还没说出口的话」，不是记忆：不进 prompt、不进导出、不占 journal type。
/// 载体默认是独立 COS 小对象 `memories/<sub>/proactive-<dayKey>.json`（≤8KB），
/// **只由 App 写，云端只读**；投递状态不写回（记在本机 `delivery_log` 的 `c:` 前缀里）。
///
/// 接口五条纪律（§5A.12，每条防一个具体的坑）：
/// 1. `write` 永不抛异常，失败返回 `PoolWriteResult.failed(reason)`。
/// 2. 接口**不提供**重试 / 定时 / 后台能力——"同步和上传在同一次呼吸里"靠接口没有
///    这个能力才拦得住；调用时机由同步会话保证（cloud_proactive_service，后续任务）。
/// 3. `key = sha16(text)`（= sha256(utf8(text.trim())) 前 16 位小写 hex），两端共用同一拼法。
/// 4. `schema` 版本号写进载体内部，换实现时旧数据仍可解读。
/// 5. 接口不知道"什么时候写"，只管"写什么、写成什么样"。

/// 候选句池载体内部的 schema 版本。
const int kPoolSchema = 1;

/// 候选句池对象的体积上限（PRD O11 / §5A.12）。
const int kPoolMaxBytes = 8 * 1024;

/// `sha16(x)`：sha256(utf8(x)) 前 16 位小写 hex。
/// 输入拼法两端一致（`text.trim()`），同一条候选句在任何一端算出同一个 key。
String poolSha16(String text) =>
    sha256.convert(utf8.encode(text.trim())).toString().substring(0, 16);

/// 候选句池对象路径（bucket 固定为 `memories`，路径不含 bucket 名）。
/// `sub` = 匿名登录返回的 uid；口令派生只发生在登录侧，这里不重复算。
String poolObjectPathFor(String sub, String dayKey) {
  final s = sub.trim();
  final d = dayKey.trim();
  if (s.isEmpty || d.isEmpty) return '';
  return '$s/proactive-$d.json';
}

/// 一条候选句。
class PoolItem {
  /// `sha16(text)`，内容即身份：同一句话不会在同一天被发两次。
  final String key;

  /// 候选句正文（她可能主动说的话）。
  final String text;

  /// 生成时刻（毫秒 int，与 journal 的 `ts` 同单位）。
  final int createdAt;

  const PoolItem({
    required this.key,
    required this.text,
    this.createdAt = 0,
  });

  /// 由正文构造，key 现算，不许外部塞 key（纪律 3）。
  factory PoolItem.fromText(String text, {int createdAt = 0}) => PoolItem(
        key: poolSha16(text),
        text: text,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'text': text,
        'createdAt': createdAt,
      };

  /// 容错解析：字段缺失 / 类型不对 → 退默认值，坏条目交由调用方按 key 去重。
  factory PoolItem.fromJson(Map<String, dynamic> json) {
    final text = json['text'] is String ? json['text'] as String : '';
    return PoolItem(
      key: json['key'] is String && (json['key'] as String).isNotEmpty
          ? json['key'] as String
          : poolSha16(text),
      text: text,
      createdAt: json['createdAt'] is int ? json['createdAt'] as int : 0,
    );
  }
}

/// 一天的候选句池。
class ProactivePool {
  /// 池属于哪一天（yyyyMMdd）。
  final String dayKey;

  /// 候选句列表（3~5 条为预期值，但解析不强校验，坏行跳过）。
  final List<PoolItem> items;

  const ProactivePool({required this.dayKey, this.items = const <PoolItem>[]});

  /// 空池：云端读不到 / App 还没补货时的正确状态，不是错误。
  const ProactivePool.empty() : dayKey = '', items = const <PoolItem>[];

  /// 序列化成对象正文（schema 写进载体内部，纪律 4）。
  String encode() => jsonEncode(<String, dynamic>{
        'schema': kPoolSchema,
        'dayKey': dayKey,
        'items': [for (final it in items) it.toJson()],
      });

  /// UTF-8 字节数（≤8KB 硬约束用它判）。
  int encodedBytes() => utf8.encode(encode()).length;

  /// 容错解析：空串 / 坏 JSON / schema 不认识 → 空池，绝不抛。
  /// **它只认候选句池对象格式**；喂进 journal.jsonl（JSONL，不是单个 JSON 对象）
  /// 会解析失败返回空池——这正是 `CloudReader.loadPool`「喂 journal 返回空」的依据。
  factory ProactivePool.decode(String raw) {
    final r = raw.trim();
    if (r.isEmpty) return const ProactivePool.empty();
    try {
      final decoded = jsonDecode(r);
      if (decoded is! Map<String, dynamic>) return const ProactivePool.empty();
      if (decoded['schema'] != kPoolSchema) return const ProactivePool.empty();
      final day = decoded['dayKey'] is String ? decoded['dayKey'] as String : '';
      final rawItems = decoded['items'];
      final items = <PoolItem>[];
      if (rawItems is List) {
        for (final it in rawItems) {
          if (it is Map<String, dynamic>) {
            final item = PoolItem.fromJson(it);
            // 正文为空的条目没有意义，直接跳过，不让空文本混进投递。
            if (item.text.trim().isNotEmpty) items.add(item);
          }
        }
      }
      return ProactivePool(dayKey: day, items: items);
    } catch (_) {
      return const ProactivePool.empty();
    }
  }
}

/// 写结果。**"不完整" ≠ "失败"**：对象已存在、已过期等都算正常路径，不算失败。
class PoolWriteResult {
  final bool ok;
  final String reason;

  const PoolWriteResult._(this.ok, this.reason);

  const PoolWriteResult.success() : ok = true, reason = '';

  const PoolWriteResult.failed(this.reason) : ok = false;
}

/// 对象读写通道抽象。**由云同步侧实现**（CloudSync 已有带 token 的 REST 网关），
/// 本文件不 import cloud_sync.dart，避免和其他并行任务的改动互相绊住。
/// 通道只有"读写一个对象"两个动作，没有重试、没有定时——纪律 2 落在接口形状上。
abstract class ProactiveObjectClient {
  /// 读一个对象；返回 null 表示对象不存在（MISSING，分不清真没有还是没权限，
  /// 与 r10.mjs 的 READ_STATE.MISSING 同口径）。
  Future<String?> readObject(String path);

  /// 写一个对象。实现内部可以失败，但**不许抛**——上层统一拿 PoolWriteResult。
  Future<PoolWriteResult> writeObject(String path, String body);
}

/// 候选句池存储接口（载体无关）。默认实现是 [CosObjectPoolStore]。
abstract class ProactivePoolStore {
  /// 读某一天的候选句池；读不到返回空池（不是错误）。
  Future<ProactivePool> read(String dayKey);

  /// 写某一天的候选句池；**永不抛异常**（纪律 1）。
  Future<PoolWriteResult> write(String dayKey, ProactivePool pool);
}

/// 默认实现：写独立 COS 小对象 `memories/<sub>/proactive-<dayKey>.json`（≤8KB）。
class CosObjectPoolStore implements ProactivePoolStore {
  final ProactiveObjectClient client;

  /// 匿名登录返回的 uid（对象前缀）。空串时读写都返回失败/空池，不猜路径。
  final String sub;

  const CosObjectPoolStore({required this.client, required this.sub});

  @override
  Future<ProactivePool> read(String dayKey) async {
    final path = poolObjectPathFor(sub, dayKey);
    if (path.isEmpty) return const ProactivePool.empty();
    try {
      final raw = await client.readObject(path);
      if (raw == null) return const ProactivePool.empty();
      return ProactivePool.decode(raw);
    } catch (_) {
      // 读失败也返回空池：补货逻辑会把它当"没有货"重生成，不会崩溃。
      return const ProactivePool.empty();
    }
  }

  @override
  Future<PoolWriteResult> write(String dayKey, ProactivePool pool) async {
    final path = poolObjectPathFor(sub, dayKey);
    if (path.isEmpty) {
      return const PoolWriteResult.failed('sub 或 dayKey 为空，不写候选句池');
    }
    try {
      final body = pool.encode();
      final bytes = utf8.encode(body);
      if (bytes.length > kPoolMaxBytes) {
        return PoolWriteResult.failed(
            '候选句池超出 8KB 上限（${bytes.length} 字节），不写');
      }
      return await client.writeObject(path, body);
    } catch (e) {
      // 纪律 1：write 永不抛。失败即今天没有，不许在这里顺手重试。
      return PoolWriteResult.failed('写候选句池失败：${e.toString()}');
    }
  }
}
