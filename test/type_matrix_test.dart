import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/models/journal.dart';
import 'package:peiban_app/services/cloud_reader.dart';
import 'package:peiban_app/services/journal_consumers.dart';
import 'package:peiban_app/services/proactive_pool_store.dart';

/// B11「type × 消费方矩阵」四条断言（**必须同文件**：它们是同一个病的四个位置）。
///
/// 那个病叫「同一个允许集只做了一个消费方」。v1.3.7 之前设计只给导出做了允许集，
/// prompt 和云端读取两列完全空白——而漏 prompt 那列比漏导出严重得多：
/// 候选句一旦进 prompt，她就会开始念还没发出去的话。
///
/// ① 漏 type：矩阵行集合 == `knownTypes`（新 type 没表态即红）
/// ② 漏消费方：矩阵列集合 == `CONSUMERS`，且登记表 keys == `CONSUMERS`，
///    且每项的 `allowedTypes` == 矩阵那一列（两处独立写，互相对拍）
/// ③ 登记了没照做：遍历登记表逐个**真调**，验它只出本列、且真的产出了
/// ④ 验错对象：抓**最终送给模型的完整 system 字符串本身**，两份 fixture 各跑一遍

// ——— 全类型 fixture（每个 type 一个独一无二的标记，用来判断"这段话进没进"）———

String _fmt(String type, String key, int ts, Map<String, dynamic> data) =>
    JournalLine(type: type, key: key, ts: ts, data: data).encode();

/// 每个 type 的正文里都埋一个 `MK_xxx` 标记；断言靠标记**内容**，不靠 type 名。
final Map<String, String> _typeMarker = <String, String>{
  JournalLine.typePersona: 'MK_persona',
  JournalLine.typeNote: 'MK_note',
  JournalLine.typeMemoryChunk: 'MK_chunk',
  JournalLine.typeSelf: 'MK_self',
  JournalLine.typeSelfFact: 'MK_fact',
  JournalLine.typeSelfNote: 'MK_selfnote',
  JournalLine.typeStyleProfile: 'MK_styleprofile',
  JournalLine.typeStyleExample: 'MK_example',
  JournalLine.typeSpeechProfile: 'MK_speech',
  JournalLine.typeState: 'MK_state',
  JournalLine.typeMessage: 'MK_message',
};

List<JournalLine> _allTypeLines() => <JournalLine>[
      JournalLine(
        type: JournalLine.typePersona,
        key: 'persona:v1',
        ts: 1,
        data: {'name': '林小满', 'persona': '你叫林小满，26 岁。标记 ${_typeMarker['persona']}'},
      ),
      JournalLine(
        type: JournalLine.typeNote,
        key: 'n:a',
        ts: 2,
        data: {
          'category': '稳定偏好',
          'content': '喜欢猫 ${_typeMarker['note']}',
          'created_at': 2,
        },
      ),
      JournalLine(
        type: JournalLine.typeMemoryChunk,
        key: 'c:a',
        ts: 3,
        data: {
          'from_id': 1,
          'to_id': 2,
          'summary': '十一月刚认识 ${_typeMarker['chunk']}',
          'created_at': 3,
        },
      ),
      JournalLine(
        type: JournalLine.typeSelf,
        key: 'self:v1',
        ts: 4,
        data: {
          'cap': 2,
          'text': '我是姜禾 ${_typeMarker['self']}',
          'facts': <String>[],
          'derivedAt': 4,
          'reason': 'distill',
        },
      ),
      JournalLine(
        type: JournalLine.typeSelfFact,
        key: 'sf:a',
        ts: 5,
        data: {
          'text': '我在广州做设计 ${_typeMarker['fact']}',
          'hash': 'aaaaaaaaaaaaaaaa',
          'source': {
            'messageKeys': <String>['m:user:1'],
            'chunkKey': '',
            'quote': 'q',
          },
          'createdAt': 5,
          'weekKey': '2026W47',
        },
      ),
      JournalLine(
        type: JournalLine.typeSelfNote,
        key: 'sn:20260101:a',
        ts: 6,
        data: {
          'text': '今天很累 ${_typeMarker['selfnote']}',
          'dayKey': '20260101',
          'createdAt': 6,
        },
      ),
      JournalLine(
        type: JournalLine.typeStyleProfile,
        key: 'style_profile:v1',
        ts: 7,
        data: {
          'digested': 3,
          'tone': '直接 ${_typeMarker['styleprofile']}',
          'updated_at': 7,
        },
      ),
      JournalLine(
        type: JournalLine.typeStyleExample,
        key: 's:a',
        ts: 8,
        data: {
          'trigger_text': '今天好累',
          'original': '我理解你的感受',
          'preferred': '累成狗了吧 ${_typeMarker['example']}',
          'created_at': 8,
        },
      ),
      JournalLine(
        type: JournalLine.typeSpeechProfile,
        key: 'speech_profile:v1',
        ts: 9,
        data: {
          'samples': 10,
          'sentence_length': '偏短',
          'tone': '随意 ${_typeMarker['speech']}',
          'catchphrases': <String>['哦'],
        },
      ),
      JournalLine(
        type: JournalLine.typeState,
        key: 'state:v1',
        ts: 10,
        data: {'cap': 2, 'activity': '工作 ${_typeMarker['state']}', 'energy': 60},
      ),
      JournalLine(
        type: JournalLine.typeMessage,
        key: 'm:user:1',
        ts: 11,
        data: {'role': 'user', 'content': '今天上班好累 ${_typeMarker['message']}', 'created_at': 11},
      ),
      // 虚构 type：没登记的必须两处都进不来（与 C9② 同一手法，永远能失败）。
      JournalLine(
        type: '__unknown__',
        key: 'u:1',
        ts: 12,
        data: {'text': 'MK_unknown 机制类不许出现'},
      ),
    ];

String _rawOf(List<JournalLine> lines) =>
    lines.map((l) => l.encode()).join('\n');

/// 空载体：读什么都返回空池（`cloudRead` 断言里的"对"就是空）。
class _EmptyPoolStore implements ProactivePoolStore {
  @override
  Future<ProactivePool> read(String dayKey) async =>
      const ProactivePool.empty();

  @override
  Future<PoolWriteResult> write(String dayKey, ProactivePool pool) async =>
      const PoolWriteResult.success();
}

/// 固定返回一份原始文本的载体（用来模拟"对象里确实存着候选句"）。
class _FixedPoolStore implements ProactivePoolStore {
  _FixedPoolStore(this.raw);

  final String raw;

  @override
  Future<ProactivePool> read(String dayKey) async => ProactivePool.decode(raw);

  @override
  Future<PoolWriteResult> write(String dayKey, ProactivePool pool) async =>
      const PoolWriteResult.success();
}

/// 断言一段文本里**没有**任何"不该进"的 type 的标记。
void _expectNoDisallowedMarker(String text, Set<String> allowed) {
  _typeMarker.forEach((type, marker) {
    if (allowed.contains(type)) return;
    expect(text.contains(marker), isFalse,
        reason: 'type=$type 的正文不该出现（标记 $marker）');
  });
  expect(text.contains('MK_unknown'), isFalse, reason: '未登记的 type 不许出现');
}

void main() {
  group('① 漏 type：矩阵行集合 == knownTypes', () {
    test('knownTypes 里每个 type 都在矩阵里有表态，且矩阵没有多余行', () {
      expect(kTypeConsumerMatrix.keys.toSet(), JournalLine.knownTypes,
          reason: '新 type 没在 §3.1 矩阵表态（每一列都要写进/不进）');
      expect(kTypeConsumerMatrix.length, JournalLine.knownTypes.length);
    });

    test('撤销的 pending 不在矩阵里（绑名字的条文会跟着名字一起死）', () {
      expect(kTypeConsumerMatrix.containsKey('pending'), isFalse);
      expect(JournalLine.knownTypes.contains('pending'), isFalse);
    });
  });

  group('② 漏消费方：矩阵列 / CONSUMERS / 登记表三者对齐', () {
    test('矩阵每一行都把全部五列写全（❌ 也要写，否则全 ❌ 的列会被漏掉）', () {
      for (final row in kTypeConsumerMatrix.entries) {
        expect(row.value.keys.toSet(), CONSUMERS.toSet(),
            reason: 'type=${row.key} 这一行没有把全部消费方表态');
        expect(row.value.length, CONSUMERS.length);
      }
    });

    test('矩阵出现过的消费方集合 == CONSUMERS', () {
      final columns = <String>{};
      for (final row in kTypeConsumerMatrix.values) {
        columns.addAll(row.keys);
      }
      expect(columns, CONSUMERS.toSet(),
          reason: '矩阵多一列 / 少一列，都必须同步 CONSUMERS');
    });

    test('CONSUMER_ENTRIES.keys == CONSUMERS（新消费方没登记即红）', () {
      expect(CONSUMER_ENTRIES.keys.toSet(), CONSUMERS.toSet());
      expect(CONSUMER_ENTRIES.length, CONSUMERS.length);
    });

    test('每一项手写的 allowedTypes == 矩阵那一列（两处独立写，互相对拍）', () {
      for (final entry in CONSUMER_ENTRIES.values) {
        expect(entry.allowedTypes, matrixColumn(entry.id),
            reason: '${entry.id} 的允许集与 §3.1 矩阵不一致');
      }
    });
  });

  group('③ 登记了没照做：遍历登记表逐个真调', () {
    final input = ConsumerInput(
      lines: _allTypeLines(),
      journalRaw: _rawOf(_allTypeLines()),
      poolStore: _EmptyPoolStore(),
      dayKey: '20260101',
    );

    test('每个消费方：只出本列、且产出与否符合登记（cloudRead 空池才对）', () async {
      for (final id in CONSUMERS) {
        final entry = CONSUMER_ENTRIES[id]!;
        final run = await entry.run(input);

        // 只出本列：消费方报告的 type 必须是本列的子集。
        expect(entry.allowedTypes.containsAll(run.types), isTrue,
            reason: '$id 报了列外的 type：${run.types.difference(entry.allowedTypes)}');
        // 真的产出了没有：cloudRead 必须"没产出"（候选句不在 journal 里），其余必须有。
        expect(run.produced, entry.mustProduce,
            reason: '$id 的产出与登记不符（produced=${run.produced}）');
        // 文本层面再验一次：不许出现本列之外的正文标记。
        _expectNoDisallowedMarker(run.text, entry.allowedTypes);
      }
    });

    test('byTypeCount 与 exportFull 同源：计数逐项相等（只数不读的语义）', () async {
      final full = await CONSUMER_ENTRIES[Consumers.exportFull]!.run(input);
      final counted = await CONSUMER_ENTRIES[Consumers.byTypeCount]!.run(input);
      expect(counted.counts, full.counts);
      expect(counted.counts[JournalLine.typeMessage], 1);
      expect(counted.counts.containsKey('__unknown__'), isFalse);
    });

    test('cloudRead 喂 journal 原文 → 空池（这是对的，不是失败）', () async {
      final run = await CONSUMER_ENTRIES[Consumers.cloudRead]!.run(input);
      expect(run.produced, isFalse);
      expect(run.text, isEmpty);
      expect(run.types, isEmpty);
    });

    test('exportMemoryOnly 与 exportFull 的差值就是 message 行数', () async {
      final full = await CONSUMER_ENTRIES[Consumers.exportFull]!.run(input);
      final mem = await CONSUMER_ENTRIES[Consumers.exportMemoryOnly]!.run(input);
      final fullLines = full.text.isEmpty ? 0 : full.text.split('\n').length;
      final memLines = mem.text.isEmpty ? 0 : mem.text.split('\n').length;
      expect(fullLines - memLines, 1, reason: 'fixture 里只有 1 条 message');
      expect(mem.types.contains(JournalLine.typeMessage), isFalse);
    });
  });

  group('④ 验错对象：抓最终 system 字符串，两份 fixture 各跑一遍', () {
    // 候选句正文：绝不许可出现在 prompt 里（进了就等于让她念还没发出去的话）。
    const candidateA = '今晚要不要一起去吃那家新开的店';
    const candidateB = '你上次说的那个项目后来怎么样了';

    test('fixture A（历史 journal 行，含撤销的 pending 载体）：候选句正文不出现', () async {
      // 历史载体：`pending` 是候选句在 v1.4.0 之前的 journal type，已撤销。
      final raw = <String>[
        _fmt(JournalLine.typePersona, 'persona:v1', 1,
            {'persona': '你叫林小满。标记 MK_persona'}),
        _fmt(JournalLine.typeNote, 'n:a', 2,
            {'category': '稳定偏好', 'content': '喜欢猫 MK_note', 'created_at': 2}),
        // ↓ 这一行是"有人把候选句写进了记忆层"的历史形态
        _fmt('pending', 'p:candidateA', 3, {'text': candidateA}),
      ].join('\n');

      final prompt = await _promptFinal(raw);
      // 先证明我们抓的是"最终 system 字符串本身"，不是空串/中间段。
      expect(prompt.contains('MK_persona'), isTrue,
          reason: '抓到的必须是完整 system 字符串（含人设）');
      expect(prompt.contains(candidateA), isFalse,
          reason: '候选句正文不许进 prompt');
      // 那一行确实没被解析成生效记忆（撤销的 type 在协议层就被跳过）。
      final parsed = parseJournalLines(raw);
      expect(parsed.any((l) => l.type == 'pending'), isFalse);
      expect(parsed.any((l) => l.data['text'] == candidateA), isFalse);
      // `p:` 前缀这类子断言不得单独作通过依据（永真），所以这里断言的是**正文**。
      expect(prompt.contains('p:candidateA'), isFalse);
    });

    test('fixture B（当前默认 COS 对象）：候选句正文不出现', () async {
      // 当前载体：独立 COS 小对象（不是 journal）。先证明它里面**真的**有候选句，
      // 再证明**把这个对象一起喂进 prompt 链路**，正文也进不了 system 字符串。
      //
      // 这份 fixture 之所以能失败：poolStore 里装的是真内容，只要有人给 prompt
      // 加一条"让它提前看到候选句"的注入，这条断言立刻红。用空池就永远测不出来。
      final pool = ProactivePool(dayKey: '20260101', items: <PoolItem>[
        PoolItem.fromText(candidateB),
      ]);
      final objectRaw = pool.encode();

      final reader = CloudReader(store: _FixedPoolStore(objectRaw));
      final loaded = await reader.loadPool('20260101');
      expect(loaded.items.length, 1, reason: '对象里确实存着候选句');
      expect(loaded.items.first.text, candidateB);

      // 模拟"把 COS 对象原文当 journal 内容喂进 prompt 链路"这个错法。
      final prompt = await _promptFinal(objectRaw,
          poolStore: _FixedPoolStore(objectRaw));
      expect(prompt.contains(candidateB), isFalse,
          reason: '候选句正文不许进 prompt（哪怕对象被当记忆层/池子一起喂进来）');
      // 这一份原始文本里没有正经人设，prompt 仍必须是非空串——证明抓的还是最终对象。
      expect(prompt, isNotEmpty);
      expect(prompt.contains('MK_message'), isFalse);
    });
  });
}

/// 把"原始 journal 文本"跑完整条 prompt 链路，返回**最终 system 字符串**。
///
/// [poolStore] 默认空池；传非空池是给断言④用的——只有池子里真装着候选句，
/// "正文没进 prompt"这条断言才有失败的可能。
Future<String> _promptFinal(
  String journalRaw, {
  ProactivePoolStore? poolStore,
}) async {
  final entry = CONSUMER_ENTRIES[Consumers.prompt]!;
  final run = await entry.run(ConsumerInput(
    lines: parseJournalLines(journalRaw),
    journalRaw: journalRaw,
    poolStore: poolStore ?? _EmptyPoolStore(),
    dayKey: '20260101',
  ));
  return run.text;
}
