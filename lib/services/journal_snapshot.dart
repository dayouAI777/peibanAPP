import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/journal.dart';

/// 导出白名单（PRD v1.5.3 的 C9，v1.3.5 起从黑名单改为白名单）。
///
/// **三个名单必须分开，绝不合成一个**：
/// - [memory]：`memory_only` 的允许集（记忆类，不含聊天原文）。
/// - [full]：`full` 的允许集 = 记忆类 + `message`（全量含原文）。
/// - [excluded]：存在的、**永不导出**的机制类。v1.4.0 起为**空集**，但必须是
///   代码里的**显式常量**（C9 要求，不许省略），否则 C9③ 无从对齐。
///
/// 为什么用白名单而不是黑名单：黑名单绑在可能不存在的 type 名字上（比如已撤销的
/// `pending`），条文会变永真断言，而且未来新增任何 type 都会默认进导出（泄露面）。
/// 白名单默认拒绝，两件事一起解决。
///
/// ⚠️ `state` 归位说明：`state` 是 P1 的「心跳/状态快照」，**T01 已把它登记进
/// [JournalLine.knownTypes]**。C9③ 要求 `knownTypes == W_FULL ∪ E_EXCLUDED`，
/// 而 [excluded] 必须是空集，所以 `state` 只能归到记忆侧（[memory]）。它上线前不会
/// 有任何 state 行，导出结果不受影响；上线后自动作为第 10 项进入 memory_only。
class SnapshotWhitelist {
  const SnapshotWhitelist._();

  /// 记忆类：`memory_only` 的允许集。**不写死长度**——新增记忆 type 同时改这里
  /// 与 [JournalLine.knownTypes] 即可，C9③ 的一致性检查会强制核对。
  static const Set<String> memory = <String>{
    JournalLine.typePersona,
    JournalLine.typeNote,
    JournalLine.typeMemoryChunk,
    JournalLine.typeSpeechProfile,
    JournalLine.typeStyleProfile,
    JournalLine.typeStyleExample,
    JournalLine.typeSelf,
    JournalLine.typeSelfFact,
    JournalLine.typeSelfNote,
    JournalLine.typeState, // P1：已登记 knownTypes；上线前无行，结果不变
  };

  /// 全量允许集 = 记忆类 + 聊天原文。用 spread 派生，保证 [memory] 增项时自动跟进。
  ///
  /// ⚠️ **这里必须是 `static final` 而不是 `const`**：Dart **不支持 const 集合里做
  /// spread**（`const {...memory, ...}` 直接编译不过）。`memory` / `excluded` 保持
  /// `const`，只有这一个因为上面那条理由必须是 `final`——**别"统一"掉它**，
  /// 统一的结果是编译失败，或者更糟：有人为了让它 const 而把 10 项手抄一遍，
  /// 于是"派生"没了，将来加 type 时两处不同步。
  static final Set<String> full = <String>{
    ...memory,
    JournalLine.typeMessage,
  };

  /// 机制类：永不导出的 type。v1.4.0 起为空集（O11 结案、候选句不进 journal、
  /// `pending` 已撤销）。**空集也必须显式声明**（C9 硬要求）。
  static const Set<String> excluded = <String>{};

  /// C9③ 常量一致性检查：`knownTypes == full ∪ excluded`。
  ///
  /// 为什么做成「常量一致性」而不是「扫 journal」：扫 journal 是**数据依赖**的
  /// （新装机器某些 type 从没出现过 ⇒ 假通过）；而 `knownTypes` 是**确定性**的
  /// ——新增 type 必须同时改常量与一个名单，否则这里直接抛错。这拦住的是
  /// 「记忆被静默吃掉」：白名单忘了更新 ⇒ 新增的记忆 type 被挡在导出外，
  /// 用户以为都带走了，其实少一块，而且导出成功、文件正常、没人会发现。
  static void assertKnownTypesClassified() {
    final union = <String>{...full, ...excluded};
    final known = JournalLine.knownTypes;
    final missing = known.difference(union); // knownTypes 有、名单没归类
    final extra = union.difference(known); // 名单有、knownTypes 没有（拼错/遗留）
    if (missing.isNotEmpty || extra.isNotEmpty) {
      throw StateError(
        '导出白名单与 knownTypes 不一致。请归类：它是记忆（进 W_MEMORY）'
        '还是机制（进 E_EXCLUDED）。未归类=$missing；名单多余=$extra',
      );
    }
  }
}

/// 一次导出快照。**白名单只在这里 where 一次**（铁律 14：一个地方筛干净），
/// [byType] / [manifest] / [toJsonl] 都不许再过滤。
///
/// 设计关系（C6 / C7 / C9）：
/// - `full` 快照 = 白名单 [SnapshotWhitelist.full] 筛过；
/// - `memoryOnly` 快照 = 白名单 [SnapshotWhitelist.memory] 筛过；
/// - 两者由**同一个** [build] 走不同 allow 集产出，筛选点唯一。
class JournalSnapshot {
  /// 已按白名单筛过的行（原始顺序，未重排、未裁剪）。
  final List<JournalLine> lines;

  /// 云同步状态：只有 `off` / `on` 两值（C5④）。
  final String cloudSync;

  /// 本机是否是云端的**超集/相等**（true=可能完整，false=本机可能缺云端记录）。
  final bool isComplete;

  /// 导出种类：`full` / `memory_only`（清单里要能认得出这份含不含聊天原文）。
  final String kind;

  /// 导出时刻（毫秒）。出问题时是"什么时候导的"这条线索。
  final int exportAt;

  /// 导出时的 App 版本（`1.7.3+19` 这种）。进清单，不进 journal。
  final String appVersion;

  bool get isMemoryOnly => kind == 'memory_only';

  const JournalSnapshot._(
    this.lines,
    this.cloudSync,
    this.isComplete,
    this.kind,
    this.exportAt,
    this.appVersion,
  );

  /// 唯一筛点：按 allow 集 `where` 一次，产出快照。`memoryOnly` / `manifest`
  /// 都基于 [lines]，**不再过滤**。
  ///
  /// [exportAt] 传 0 表示"就是现在"（测试可传定值钉死）；[appVersion] 由调用方
  /// （`ExportService`）从系统取，取不到时传 `'unknown'`——**清单里这个字段不许空着**。
  factory JournalSnapshot.build(
    List<JournalLine> raw, {
    required bool memoryOnly,
    required String cloudSync,
    required bool isComplete,
    int exportAt = 0,
    String appVersion = 'unknown',
  }) {
    final allow =
        memoryOnly ? SnapshotWhitelist.memory : SnapshotWhitelist.full;
    final kept = <JournalLine>[];
    for (final l in raw) {
      if (allow.contains(l.type)) kept.add(l);
    }
    return JournalSnapshot._(
      List<JournalLine>.unmodifiable(kept),
      cloudSync,
      isComplete,
      memoryOnly ? 'memory_only' : 'full',
      exportAt == 0 ? DateTime.now().millisecondsSinceEpoch : exportAt,
      appVersion,
    );
  }

  /// 全量导出快照（含 message）。
  factory JournalSnapshot.full(
    List<JournalLine> raw, {
    required String cloudSync,
    required bool isComplete,
    int exportAt = 0,
    String appVersion = 'unknown',
  }) =>
      JournalSnapshot.build(raw,
          memoryOnly: false,
          cloudSync: cloudSync,
          isComplete: isComplete,
          exportAt: exportAt,
          appVersion: appVersion);

  /// 仅记忆导出快照（0 条 message）。
  factory JournalSnapshot.memoryOnly(
    List<JournalLine> raw, {
    required String cloudSync,
    required bool isComplete,
    int exportAt = 0,
    String appVersion = 'unknown',
  }) =>
      JournalSnapshot.build(raw,
          memoryOnly: true,
          cloudSync: cloudSync,
          isComplete: isComplete,
          exportAt: exportAt,
          appVersion: appVersion);

  int get lineCount => lines.length;

  /// 各类型行数。基于已过滤的 [lines]，**不再过滤**。
  Map<String, int> byType() {
    final m = <String, int>{};
    for (final l in lines) {
      m[l.type] = (m[l.type] ?? 0) + 1;
    }
    return m;
  }

  /// 导出清单（设计 §3.4，**落点只有这一处**，不在导出服务里补字段）。
  ///
  /// 八个字段一个都不许少：
  /// - `kind` / `exportAt` / `appVersion`：这份是哪种导出、什么时候、哪个版本导的
  ///   ——三个月后"导出好像少了东西"时，这是唯一能回溯的线索；
  /// - `sha256`：**导出正文（不含 manifest 自身）的指纹**。缺了它，用户和我们
  ///   都没法判断文件有没有被截断或改过，而"导出"的全部价值就是"它是完整的"；
  /// - `lines` / `byType`：数出来的东西，`byType` 必须按实际出现过的 type 动态生成；
  /// - `isComplete` / `cloudSync`：C5 判文案用的两个概念（互不替代）。
  ///
  /// [jsonlBody] **必须传"真正写进文件的那串正文"**（由 [ExportService] 写完再传进来），
  /// **不许在这里自己再拼一遍**：两处一旦不同步（比如将来 `toJsonl` 改了写法而这里
  /// 还在用旧的），指纹就和文件对不上了——而指纹唯一的作用就是"证明这串字节没被动过"。
  /// 所以这里**不做重算兜底**，参数是 required 的，谁也别想走另一条路。
  ///
  /// `isComplete` 在 `cloudSync=off` 时**恒 false**（§3.4）：老板自己关了云同步，
  /// 我们确实无法判断本机是不是云端子集——但 C5① 认定这是正常状态，不是失败。
  /// C5③ 要求失败时**不生成 manifest**——由 [ExportService] 保证失败分支返回 null。
  Map<String, dynamic> manifest({required String jsonlBody}) => <String, dynamic>{
        'kind': kind,
        'exportAt': exportAt,
        'appVersion': appVersion,
        'lines': lineCount,
        'byType': byType(),
        'sha256': sha256HexOf(jsonlBody),
        'isComplete': cloudSync == 'off' ? false : isComplete,
        'cloudSync': cloudSync,
      };

  /// 导出正文的 sha256（十六进制小写）。抽成静态纯函数，测试可以拿同一份字符串
  /// 独立实算对拍——清单里的 `sha256` 必须**逐字等于**导出文件正文的指纹。
  static String sha256HexOf(String text) =>
      sha256.convert(utf8.encode(text)).toString();

  /// R3 主格式：**逐行原样**（按 [lines] 原始顺序），不重排、不格式化、不裁剪。
  /// 白名单决定「哪些行进入快照」，不是「对行做裁剪」——这两件事别混。
  String toJsonl() {
    final b = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) b.writeln();
      b.write(lines[i].encode());
    }
    return b.toString();
  }
}
