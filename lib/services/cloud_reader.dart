import 'proactive_pool_store.dart';

/// 云端候选句读取入口（T06 · v1.4.1 补）。
///
/// 供 T05 的 `CONSUMER_ENTRIES['cloudRead']` 登记与 B11 断言③使用。
/// **只读独立 COS 对象（候选句池），绝不读 journal**——喂 journal fixture 时
/// 返回空池是正确行为，不是 bug：候选句根本不在云母库里（v1.4.0 / O11 已结案）。
class CloudReader {
  final ProactivePoolStore store;

  const CloudReader({required this.store});

  /// 读某一天的候选句池。
  ///
  /// - 对象存在 → 解析出 `ProactivePool`（schema 不认识 → 空池）；
  /// - 对象不存在 / 读失败 → 空池（调用方据此走"断食降级"分支）；
  /// - 载体里混进 journal 内容（JSONL）→ 解析失败 → 空池（候选句不读记忆层）。
  Future<ProactivePool> loadPool(String dayKey) => store.read(dayKey);
}
