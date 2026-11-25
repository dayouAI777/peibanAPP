import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/data/prefs.dart';
import 'package:peiban_app/models/journal.dart';
import 'package:peiban_app/models/user_note.dart';
import 'package:peiban_app/services/capability.dart';
import 'package:peiban_app/services/prompt_budget.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// T01 跨端 fixture 物理唯一源：与 Node 的 test/fixtures/journal-v2.jsonl 同一份字节。
/// 两个仓库目录不同，Node 侧用相对路径，Dart 侧用环境变量 PEIBAN_CORE_DIR
/// （缺省 D:/peiban-core）拼出绝对路径。任一侧改动文件，两端测试同时变——不再内嵌拷贝。
String _coreFixture(String name) {
  final root = Platform.environment['PEIBAN_CORE_DIR'] ?? 'D:/peiban-core';
  final f = File('$root/test/fixtures/$name');
  if (!f.existsSync()) {
    throw StateError('找不到跨端唯一 fixture：${f.path}（可设 PEIBAN_CORE_DIR 指向 peiban-core 仓库）');
  }
  return f.readAsStringSync();
}

const List<String> _effectiveKeys = <String>[
  'm:user:1000',
  'n:aaa',
  'sf:fact1',
  'sf:fact2',
  'sn:20261113:note1',
  'self:v1',
  'state:v1',
  'persona:v1',
];

const List<String> _sortedTypes = <String>[
  '__future_type__',
  'message',
  'note',
  'persona',
  'self',
  'self_fact',
  'self_note',
  'state',
];

void main() {
  late final String fixture;

  setUpAll(() {
    fixture = _coreFixture('journal-v2.jsonl');
  });

  test('T01 能力号与敏感 type：与 Node 同版本同步', () {
    expect(kJournalCapability, 2);
    expect(kPhoneCapability, 2);
    expect(kSensitiveTypes.toList()..sort(), <String>[
      'self', 'self_fact', 'self_note', 'state',
    ].toList()..sort());
    expect(JournalLine.knownTypes.contains('pending'), isFalse);
    expect(JournalLine.knownTypes.contains('self_fact_del'), isFalse);
  });

  test('T01 新 key 黄金值（Node 侧同一条断言）', () {
    expect(journalKeySelf, 'self:v1');
    expect(journalKeyState, 'state:v1');
    expect(journalKeyForSelfFact('我在广州工作'), 'sf:0e6b349ef4572019');
    expect(journalKeyForSelfNote('20261113', '今天有点累'),
        'sn:20261113:49baf06a9b62633c');
  });

  test('probeJournalTypes：看见未知 type、跳过坏行、不查 knownTypes（唯一 fixture）', () {
    final got = probeJournalTypes(fixture).toList()..sort();
    expect(got, _sortedTypes);
    expect(probeJournalTypes('{bad\n{"type":123}\n{"type":""}'), isEmpty);
    expect(probeJournalTypes('{"type":"never_seen_before"}\nnot json'),
        <String>{'never_seen_before'});
  });

  test('selfCapOf：没有 cap 字段的老行视为 1', () {
    expect(selfCapOf(const <String, dynamic>{}), 1);
    expect(selfCapOf(const <String, dynamic>{'cap': 2}), 2);
    expect(selfCapOf(const <String, dynamic>{'cap': '2'}), 1);
  });

  test('canWriteSelf 三条规则 + 正常放行', () {
    expect(decideCapability(
      cloudTypes: const <String>{}, cloudSelfCap: 1, localCap: 1).canWriteSelf,
        isFalse);
    expect(decideCapability(
      cloudTypes: const <String>{'self_fact'}, cloudSelfCap: 1, localCap: 2)
        .canWriteSelf, isFalse);
    expect(decideCapability(
      cloudTypes: const <String>{}, cloudSelfCap: 3, localCap: 2).canWriteSelf,
        isFalse);
    expect(decideCapability(
      cloudTypes: const <String>{}, cloudSelfCap: 1, localCap: 2).canWriteSelf,
        isTrue);
    expect(decideCapability(
      cloudTypes: const <String>{'note'}, cloudSelfCap: 2, localCap: 2)
        .canWriteSelf, isTrue);
  });

  test('旧端探测到 self → 只读模式（不重蒸、不追加）', () {
    final r = decideCapability(
        cloudTypes: const <String>{'self'}, cloudSelfCap: 1, localCap: 1);
    expect(r.readOnlySelf, isTrue);
    expect(r.canWriteSelf, isFalse);
    expect(decideCapability(cloudTypes: const <String>{'self'},
        cloudSelfCap: 1, localCap: 2).readOnlySelf, isFalse);
  });

  test('跨端 fixture 对拍：生效行 / 单赢家 / 未知 type 跳过（唯一源）', () {
    final lines = parseJournalLines(fixture);
    expect(lines.length, 10);
    final effective = resolveEffectiveLines(lines);
    expect(effective.map((l) => l.key).toList(), _effectiveKeys);
    final self = effective.firstWhere((l) => l.key == 'self:v1');
    final state = effective.firstWhere((l) => l.key == 'state:v1');
    expect(self.data['text'], '新版自我');
    expect(self.ts, 1600);
    expect(state.data['activity'], '工作');
    expect(state.ts, 1800);
    expect(effective.where((l) => l.type == 'self_fact').length, 2);
    expect(effective.any((l) => l.type == '__future_type__'), isFalse);
  });

  test('PromptBudget：近况优先占位但总数不超 20，D3 用数值比较', () {
    final notes = <UserNote>[
      for (var i = 0; i < 7; i++)
        UserNote(
            category: '近况',
            content: '近$i',
            confidence: 1,
            evidence: '',
            createdAt: i),
      for (var i = 0; i < 20; i++)
        UserNote(
            category: '稳定偏好',
            content: '常$i',
            confidence: 1,
            evidence: '',
            createdAt: 100 + i),
    ];
    final picked = PromptBudget.pickNotes(notes);
    expect(picked.length, 20);
    expect(picked.where((n) => n.category == '近况').length, 5);
    // T05 §6.1 起排序责任收进 pickNotes 内部：近况按 createdAt **降序**占前 5 个
    // 槽位，所以排在最前的是最新的那条近况（近6），不是输入顺序里的第一条。
    expect(picked.first.content, '近6');

    expect(PromptBudget.maxSelfChars, 360);
    expect(PromptBudget.withinBaseline('x' * 100, 100), isTrue);
    expect(PromptBudget.withinBaseline('x' * 110, 100), isTrue);
    expect(PromptBudget.withinBaseline('x' * 111, 100), isFalse);
    expect(PromptBudget.withinBaseline('x', 0), isFalse);
    expect(PromptBudget.selfWithinBudget('x' * 360), isTrue);
    expect(PromptBudget.selfWithinBudget('x' * 361), isFalse);
  });

  test('prefs §3.3 新键可读写，R10 换机出口键仍在', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await Prefs.pushplusEnabled(), isFalse);
    await Prefs.setPushplusToken('pus-secret-1234');
    expect(Prefs.maskPushplusToken(await Prefs.pushplusToken()), 'pus***1234');
    await Prefs.setPushplusDayCount(3);
    expect(await Prefs.pushplusDayCount(), 3);
    await Prefs.setSelfFactWeek('2026W47:2');
    expect(await Prefs.selfFactWeek(), '2026W47:2');
    await Prefs.setNoteNeartermDay('20261125');
    expect(await Prefs.noteNeartermDay(), '20261125');
    await Prefs.setCloudLibraryAck('abcdef0123456789');
    expect(await Prefs.cloudLibraryAck(), 'abcdef0123456789');
    // `cloud_aligned_once`：默认 0（= 从没对齐过，导出必须报"可能不完整"），
    // 写进去要能原样读回来。这条防的是"键名写错 → 永远读到 0 → 导出永远说不完整"
    // 这种一声不响的错（`_kCloudAlignedOnce` 的字符串是私有常量，只有往返能验）。
    expect(await Prefs.cloudAlignedOnce(), 0);
    await Prefs.setCloudAlignedOnce(1730000000000);
    expect(await Prefs.cloudAlignedOnce(), 1730000000000);
  });
}
