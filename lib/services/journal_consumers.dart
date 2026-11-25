import '../models/journal.dart';
import '../models/memory_chunk.dart';
import '../models/self_models.dart';
import '../models/speech_profile.dart';
import '../models/style_example.dart';
import '../models/style_profile.dart';
import '../models/user_note.dart';
import 'cloud_reader.dart';
import 'context_builder.dart';
import 'journal_snapshot.dart';
import 'proactive_pool_store.dart';
import 'self_prompt.dart';

/// 消费方 id（与设计 §3.1「type × 消费方矩阵」的**列**一一对应，一字不差）。
///
/// 为什么要单独列常量：矩阵是文档里的表，代码里必须有一个能被测试读到的镜像，
/// 否则"新 type 没表态"只能靠人眼看表——而人眼看表这件事，我们已经错过一次
/// （v1.3.7 是拿产品经理的纪律回审自己才发现的）。
class Consumers {
  /// 导出全量（含聊天原文）。
  static const String exportFull = 'exportFull';

  /// 导出仅记忆（0 条 message）。
  static const String exportMemoryOnly = 'exportMemoryOnly';

  /// prompt 三层视图（最终送给模型的 system 字符串）。
  static const String prompt = 'prompt';

  /// 云端候选句读取（独立 COS 对象，**不是** journal）。
  static const String cloudRead = 'cloudRead';

  /// 只数不读：进入 `full` 的行的 type 分布。
  static const String byTypeCount = 'byTypeCount';

  const Consumers._();
}

/// 全部消费方（顺序 = 矩阵列顺序）。少写一个 ⇒ 矩阵里多出一列，断言②红。
// ignore: constant_identifier_names — 名字是设计 §3.1 / v1.4.1 裁决给定的，测试按这个名字读
const List<String> CONSUMERS = <String>[
  Consumers.exportFull,
  Consumers.exportMemoryOnly,
  Consumers.prompt,
  Consumers.cloudRead,
  Consumers.byTypeCount,
];

/// 每个记忆类 type 那一行（四列进、`cloudRead` 一列不进）。
const Map<String, bool> _memoryRow = <String, bool>{
  Consumers.exportFull: true,
  Consumers.exportMemoryOnly: true,
  Consumers.prompt: true,
  Consumers.cloudRead: false,
  Consumers.byTypeCount: true,
};

/// `message` 那一行：**不进 memory_only**（C6）。
const Map<String, bool> _messageRow = <String, bool>{
  Consumers.exportFull: true,
  Consumers.exportMemoryOnly: false,
  Consumers.prompt: true,
  Consumers.cloudRead: false,
  Consumers.byTypeCount: true,
};

/// 设计 §3.1 矩阵的代码镜像：**type → {消费方: 进/不进}**，每一行都必须把
/// **全部五列**写全（✅ 和 ❌ 都写），这是铁律 17 的落地形状。
///
/// 为什么把 ❌ 也写出来：只记 ✅ 的话，一个**全列都 ❌** 的消费方（`cloudRead` 正是）
/// 在数据里根本不存在，"矩阵列 == CONSUMERS" 就永远成立——那正是这一列当初被漏掉的原因。
const Map<String, Map<String, bool>> kTypeConsumerMatrix =
    <String, Map<String, bool>>{
  JournalLine.typeMessage: _messageRow,
  JournalLine.typePersona: _memoryRow,
  JournalLine.typeNote: _memoryRow,
  JournalLine.typeMemoryChunk: _memoryRow,
  JournalLine.typeSelf: _memoryRow,
  JournalLine.typeSelfFact: _memoryRow,
  JournalLine.typeSelfNote: _memoryRow,
  JournalLine.typeStyleProfile: _memoryRow,
  JournalLine.typeStyleExample: _memoryRow,
  JournalLine.typeSpeechProfile: _memoryRow,
  JournalLine.typeState: _memoryRow,
};

/// 矩阵某**列**的允许 type 集合（该列写 ✅ 的那些）。测试拿它和登记表的手写名单对拍。
Set<String> matrixColumn(String consumerId) {
  final out = <String>{};
  for (final e in kTypeConsumerMatrix.entries) {
    if (e.value[consumerId] == true) out.add(e.key);
  }
  return out;
}

/// 一次消费的输入：全类型 fixture + 原始文本 + 候选句载体。
class ConsumerInput {
  /// 全类型 journal 行（含一个虚构 type，用来验证"没登记的不许进来"）。
  final List<JournalLine> lines;

  /// 原始 JSONL 文本（`cloudRead` 会把它当"错误的载体"喂进去，验证返回空池）。
  final String journalRaw;

  /// 候选句池的载体（默认实现是 COS 对象；测试注入假实现）。
  final ProactivePoolStore poolStore;

  /// 候选句池属于哪一天（yyyyMMdd）。
  final String dayKey;

  const ConsumerInput({
    required this.lines,
    required this.journalRaw,
    required this.poolStore,
    required this.dayKey,
  });
}

/// 一次消费的产出。**"没产出"和"没照做"是两件事**：候选项为空时没产出是正确行为，
/// 所以 [produced] 单独记，由 [ConsumerEntry.mustProduce] 决定它该不该有产出。
class ConsumerRun {
  /// 这次真消费到的 type（消费方自己报告）。
  final Set<String> types;

  /// 最终文本（prompt 消费方给的是**最终 system 字符串本身**）。
  final String text;

  /// 计数结果（`byTypeCount` 消费方用）。
  final Map<String, int> counts;

  /// 是否真的产出了东西（非空跑）。
  final bool produced;

  const ConsumerRun({
    required this.types,
    this.text = '',
    this.counts = const <String, int>{},
    required this.produced,
  });
}

typedef ConsumerRunner = Future<ConsumerRun> Function(ConsumerInput input);

/// 一个消费方的登记项。
class ConsumerEntry {
  /// 消费方 id（必须在 [CONSUMERS] 里）。
  final String id;

  /// 一句话说明它消费什么、边界在哪（给后来人看的，不参与断言）。
  final String description;

  /// 该消费方**允许拿到**的 type（**手写**，测试与 [matrixColumn] 逐项比对）。
  ///
  /// 刻意不在这里从矩阵自动派生：派生出来的名单永远不会和矩阵不一致，
  /// 那断言②就成了永真断言。两处独立写、测试对拍，才拦得住"矩阵改了登记没改"。
  final Set<String> allowedTypes;

  /// 喂全类型 fixture 时**是否必须**产出一份非空结果。
  /// `cloudRead` 是 false：候选句不在 journal 里，读 journal 返回空池才是对的。
  final bool mustProduce;

  /// 真调一次。
  final ConsumerRunner run;

  const ConsumerEntry({
    required this.id,
    required this.description,
    required this.allowedTypes,
    required this.mustProduce,
    required this.run,
  });
}

/// 消费方登记表。**`CONSUMER_ENTRIES.keys` 必须 == `CONSUMERS`**（断言②）。
// ignore: constant_identifier_names — 同上，名字由设计给定
const Map<String, ConsumerEntry> CONSUMER_ENTRIES = <String, ConsumerEntry>{
  Consumers.exportFull: ConsumerEntry(
    id: Consumers.exportFull,
    description: '导出全量：W_FULL 筛一次后逐行原样写出（含 message）。',
    allowedTypes: <String>{
      JournalLine.typeMessage,
      JournalLine.typePersona,
      JournalLine.typeNote,
      JournalLine.typeMemoryChunk,
      JournalLine.typeSelf,
      JournalLine.typeSelfFact,
      JournalLine.typeSelfNote,
      JournalLine.typeStyleProfile,
      JournalLine.typeStyleExample,
      JournalLine.typeSpeechProfile,
      JournalLine.typeState,
    },
    mustProduce: true,
    run: _runExportFull,
  ),
  Consumers.exportMemoryOnly: ConsumerEntry(
    id: Consumers.exportMemoryOnly,
    description: '导出仅记忆：W_MEMORY 筛一次，0 条 message。',
    allowedTypes: <String>{
      JournalLine.typePersona,
      JournalLine.typeNote,
      JournalLine.typeMemoryChunk,
      JournalLine.typeSelf,
      JournalLine.typeSelfFact,
      JournalLine.typeSelfNote,
      JournalLine.typeStyleProfile,
      JournalLine.typeStyleExample,
      JournalLine.typeSpeechProfile,
      JournalLine.typeState,
    },
    mustProduce: true,
    run: _runExportMemoryOnly,
  ),
  Consumers.prompt: ConsumerEntry(
    id: Consumers.prompt,
    description: 'prompt 三层视图：最终送给模型的 system 字符串（不含候选句）。',
    allowedTypes: <String>{
      JournalLine.typeMessage,
      JournalLine.typePersona,
      JournalLine.typeNote,
      JournalLine.typeMemoryChunk,
      JournalLine.typeSelf,
      JournalLine.typeSelfFact,
      JournalLine.typeSelfNote,
      JournalLine.typeStyleProfile,
      JournalLine.typeStyleExample,
      JournalLine.typeSpeechProfile,
      JournalLine.typeState,
    },
    mustProduce: true,
    run: _runPrompt,
  ),
  Consumers.cloudRead: ConsumerEntry(
    id: Consumers.cloudRead,
    description: '云端候选句读取：只读独立 COS 对象；喂 journal 返回空池是正确行为。',
    // 矩阵里这一列全 ❌：候选句不在 journal 里，任何 memory type 都不该被它读到。
    allowedTypes: <String>{},
    mustProduce: false,
    run: _runCloudRead,
  ),
  Consumers.byTypeCount: ConsumerEntry(
    id: Consumers.byTypeCount,
    description: '只数不读：进入 full 的行的 type 分布（含 message、不含候选句）。',
    allowedTypes: <String>{
      JournalLine.typeMessage,
      JournalLine.typePersona,
      JournalLine.typeNote,
      JournalLine.typeMemoryChunk,
      JournalLine.typeSelf,
      JournalLine.typeSelfFact,
      JournalLine.typeSelfNote,
      JournalLine.typeStyleProfile,
      JournalLine.typeStyleExample,
      JournalLine.typeSpeechProfile,
      JournalLine.typeState,
    },
    mustProduce: true,
    run: _runByTypeCount,
  ),
};

// ——— 各消费方的真实实现（都是生产路径，不是为测试另写一套）———

Future<ConsumerRun> _runExportFull(ConsumerInput input) async {
  final snap = JournalSnapshot.full(input.lines,
      cloudSync: 'on', isComplete: true);
  final counts = snap.byType();
  return ConsumerRun(
    types: counts.keys.toSet(),
    text: snap.toJsonl(),
    counts: counts,
    produced: snap.lineCount > 0,
  );
}

Future<ConsumerRun> _runExportMemoryOnly(ConsumerInput input) async {
  final snap = JournalSnapshot.memoryOnly(input.lines,
      cloudSync: 'on', isComplete: true);
  final counts = snap.byType();
  return ConsumerRun(
    types: counts.keys.toSet(),
    text: snap.toJsonl(),
    counts: counts,
    produced: snap.lineCount > 0,
  );
}

Future<ConsumerRun> _runByTypeCount(ConsumerInput input) async {
  // 计数口径（§3.1）：数**进入 full 的行**，含 message、不含候选句。
  final counts = JournalSnapshot.full(input.lines,
          cloudSync: 'on', isComplete: true)
      .byType();
  return ConsumerRun(
    types: counts.keys.toSet(),
    counts: counts,
    produced: counts.values.fold<int>(0, (a, b) => a + b) > 0,
  );
}

Future<ConsumerRun> _runCloudRead(ConsumerInput input) async {
  // 真调 CloudReader（生产入口）。喂 journal 原文时它必须返回空池——
  // 候选句不在云母库里，读到东西才是 bug。
  final reader = CloudReader(store: input.poolStore);
  final pool = await reader.loadPool(input.dayKey);
  return ConsumerRun(
    types: const <String>{},
    text: <String>[for (final it in pool.items) it.text].join('\n'),
    produced: pool.items.isNotEmpty,
  );
}

/// prompt 消费方：把全类型行按**真实注入位置**拼成最终 system 字符串。
///
/// 刻意走 [ContextBuilder.buildSystem] 而不是自己拼字符串——断言的对象必须是
/// 真正送给模型的那一份，中间段的拼接不算数。
Future<ConsumerRun> _runPrompt(ConsumerInput input) async {
  final effective = resolveEffectiveLines(input.lines);
  final used = <String>{};

  JournalLine? pick(String type) {
    for (final l in effective) {
      if (l.type == type) return l;
    }
    return null;
  }

  final personaLine = pick(JournalLine.typePersona);
  final persona = personaLine?.data['persona'] is String
      ? personaLine!.data['persona'] as String
      : '';

  final notes = <UserNote>[];
  for (final l in effective) {
    if (l.type != JournalLine.typeNote) continue;
    notes.add(UserNote.fromMap(l.data));
  }

  final chunks = <MemoryChunk>[];
  for (final l in effective) {
    if (l.type != JournalLine.typeMemoryChunk) continue;
    chunks.add(MemoryChunk.fromMap(l.data));
  }

  final examples = <StyleExample>[];
  for (final l in effective) {
    if (l.type != JournalLine.typeStyleExample) continue;
    examples.add(StyleExample.fromMap(l.data));
  }

  final speechLine = pick(JournalLine.typeSpeechProfile);
  final speech = speechLine == null
      ? null
      : SpeechProfile.fromMap(speechLine.data);

  final styleLine = pick(JournalLine.typeStyleProfile);
  final styleProfile =
      styleLine == null ? null : StyleProfile.fromMap(styleLine.data);

  // self 三件聚合成一段（≤360 字），与 App 里 SelfService 的注入同口径。
  final derived = <String>[];
  final facts = <SelfFact>[];
  for (final l in effective) {
    if (l.type == JournalLine.typeSelf) {
      final t = l.data['text'];
      if (t is String && t.trim().isNotEmpty) derived.add(t);
    } else if (l.type == JournalLine.typeSelfNote) {
      final t = l.data['text'];
      if (t is String && t.trim().isNotEmpty) derived.add(t);
    } else if (l.type == JournalLine.typeSelfFact) {
      final t = l.data['text'];
      if (t is String && t.trim().isNotEmpty) {
        facts.add(SelfFact(
          hash: l.data['hash'] is String ? l.data['hash'] as String : '',
          text: t,
          source: SelfSource.fromMap(l.data['source']),
          createdAt: l.data['createdAt'] is int ? l.data['createdAt'] as int : 0,
          weekKey: l.data['weekKey'] is String ? l.data['weekKey'] as String : '',
        ));
      }
    }
  }
  final selfBlock = SelfComposer.compose(derived, facts);

  if (persona.trim().isNotEmpty) used.add(JournalLine.typePersona);
  if (notes.isNotEmpty) used.add(JournalLine.typeNote);
  if (chunks.isNotEmpty) used.add(JournalLine.typeMemoryChunk);
  if (examples.isNotEmpty) used.add(JournalLine.typeStyleExample);
  if (speech != null) used.add(JournalLine.typeSpeechProfile);
  if (styleProfile != null) used.add(JournalLine.typeStyleProfile);
  if (derived.isNotEmpty) used.add(JournalLine.typeSelf);
  if (facts.isNotEmpty) used.add(JournalLine.typeSelfFact);
  for (final l in effective) {
    if (l.type == JournalLine.typeSelfNote) {
      used.add(JournalLine.typeSelfNote);
    }
  }
  // message 走 messages 数组（ContextBuilder.buildTurns），不进 system 字符串。
  for (final l in effective) {
    if (l.type == JournalLine.typeMessage) {
      used.add(JournalLine.typeMessage);
    }
  }
  // `state` 上线后应进【现在】那一段；本阶段 ContextBuilder 没有 state 入参，
  // 所以这里不注入（矩阵的"✅"表示"该进"，不是"已经写了"，子集断言允许缺席）。

  final text = ContextBuilder.buildSystem(
    persona: persona,
    notes: notes,
    chunks: chunks,
    window: ContextBuilder.defaultWindow,
    styleExamples: examples,
    styleProfile: styleProfile,
    speech: speech,
    selfBlock: selfBlock,
  );

  return ConsumerRun(types: used, text: text, produced: text.trim().isNotEmpty);
}
