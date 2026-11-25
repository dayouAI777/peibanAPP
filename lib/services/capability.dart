import 'dart:convert';

import '../models/journal.dart';

/// 版本 / 能力协商门禁（设计 §7.2）。**纯函数，零 IO、零副作用。**
///
/// 为什么单独一个文件：探针要能"看见"未知 type，而 [parseJournalLines]
/// 按协议把未知 type 跳过了。旧端看不见新 type 就会拿旧规则重蒸一条
/// `self:v1`，单赢家语义让它的新 ts 赢掉新版的行 ⇒ 已删事实复活。
/// 所以探测必须只读 `type` 字段、不看 knownTypes、坏行跳过。
///
/// 与 `peiban-core/src/capability.mjs` 逐条对应，同一份 fixture 必须同结果。

/// 本端能力号。手机端与 Node 本体在同一个版本里一起升。
const int kPhoneCapability = kJournalCapability;

/// 敏感 type：云端只要出现其中任意一个，就说明被更高版本写过。
/// 本端不认识它们也照样能探测到（probe 不查 knownTypes）。
const Set<String> kSensitiveTypes = <String>{
  JournalLine.typeSelf,
  JournalLine.typeSelfFact,
  JournalLine.typeSelfNote,
  JournalLine.typeState,
};

/// 扫描 journal 原文里出现过的**所有** type（含未知 type）。
///
/// - 只读每行的 `type` 字段，不解析成 JournalLine、不看 knownTypes；
/// - 坏行 / 非对象 / type 不是 String / 空串 → 跳过；
/// - 结果排序，保证两端对拍稳定。
Set<String> probeJournalTypes(String raw) {
  final out = <String>{};
  if (raw.isEmpty) return out;
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(t);
    } catch (_) {
      continue;
    }
    if (decoded is! Map) continue;
    final type = decoded['type'];
    if (type is! String || type.isEmpty) continue;
    out.add(type);
  }
  return out;
}

/// 从 `self` / `state` 行的 data 里取能力号。**没有 cap 字段的老行视为 1。**
int selfCapOf(Map<String, dynamic>? data) {
  final v = data?['cap'];
  if (v is int) return v;
  return 1;
}

/// 能不能写 self（设计 §7.2 三条规则，顺序不许换）。
///
/// 1. 本端能力 < 2 → false；
/// 2. 云端出现任一敏感 type → false（已被更高版本写过）；
/// 3. 现有 self 行的 cap 高于本端 → false；
/// 否则 true。
bool canWriteSelf({
  required Set<String> cloudTypes,
  required int cloudSelfCap,
  required int localCap,
}) {
  if (localCap < 2) return false;
  if (cloudTypes.any(kSensitiveTypes.contains)) return false;
  if (cloudSelfCap > localCap) return false;
  return true;
}

/// 旧端看到 self 行 ⇒ 只读模式：直接注入 `self.text`，不重蒸、不追加。
bool isSelfReadOnlyMode({
  required Set<String> cloudTypes,
  required int localCap,
}) =>
    localCap < 2 && cloudTypes.contains(JournalLine.typeSelf);

/// 一次协商的完整结果（给调用方一个入口，别各自组合三条规则）。
CapabilityDecision decideCapability({
  required Set<String> cloudTypes,
  required int cloudSelfCap,
  int localCap = kPhoneCapability,
}) =>
    CapabilityDecision(
      canWriteSelf: canWriteSelf(
        cloudTypes: cloudTypes,
        cloudSelfCap: cloudSelfCap,
        localCap: localCap,
      ),
      readOnlySelf: isSelfReadOnlyMode(
        cloudTypes: cloudTypes,
        localCap: localCap,
      ),
    );

/// 协商结论（不可变，字段直接可断言）。
class CapabilityDecision {
  final bool canWriteSelf;
  final bool readOnlySelf;

  const CapabilityDecision({
    required this.canWriteSelf,
    required this.readOnlySelf,
  });

  @override
  bool operator ==(Object other) =>
      other is CapabilityDecision &&
      other.canWriteSelf == canWriteSelf &&
      other.readOnlySelf == readOnlySelf;

  @override
  int get hashCode => Object.hash(canWriteSelf, readOnlySelf);

  @override
  String toString() =>
      'CapabilityDecision(canWriteSelf: $canWriteSelf, readOnlySelf: $readOnlySelf)';
}
