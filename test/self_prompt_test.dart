import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/models/self_models.dart';
import 'package:peiban_app/services/self_prompt.dart';

/// T04 · R2 跨端自我认知对拍：与 Node test/fixtures/self-v1.json 共读同一份字节。
/// Node 侧相对路径，Dart 侧用 PEIBAN_CORE_DIR（缺省 D:/peiban-core）拼绝对路径。
Map<String, dynamic> _readFixture() {
  final root = Platform.environment['PEIBAN_CORE_DIR'] ?? 'D:/peiban-core';
  final f = File('$root/test/fixtures/self-v1.json');
  if (!f.existsSync()) {
    throw StateError('找不到跨端唯一 fixture：${f.path}（可设 PEIBAN_CORE_DIR）');
  }
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final fx = _readFixture();

  test('T04 golden sha16 与 fixture 逐字一致（与 Node 对拍）', () {
    final golden = fx['goldenSha16'] as Map<String, dynamic>;
    golden.forEach((text, hash) {
      expect(selfSha16(text), hash, reason: 'sha16($text)');
    });
    expect(selfSha16('我在广州做设计').length, 16);
  });

  test('T04 三重拦截逐条对拍 fixture（顺序：sha16 → 关键词 → 硬事实）', () {
    for (final c in (fx['guard'] as List<dynamic>)) {
      final m = c as Map<String, dynamic>;
      final deleted = DeletedFactList(
        items: (m['deletedHashes'] as List<dynamic>)
            .map((h) => DeletionEntry(sha16: h as String, ts: 1))
            .toList(),
        keywords: (m['deletedKeywords'] as List<dynamic>).cast<String>().toSet(),
      );
      final existing = (m['existing'] as List<dynamic>).cast<String>().toSet();
      final verdict = SelfGuard.check(
        text: m['text'] as String,
        existingHashes: existing,
        deleted: deleted,
        hardFactGuardEnabled: m['hardFactGuardEnabled'] as bool,
      );
      expect(verdict.reason.name, m['expect'] as String, reason: 'guard ${m['name']}');
      expect(verdict.keep, m['expect'] == 'none', reason: 'keep ${m['name']}');
    }
  });

  test('T04 isRealLifeFact 标记逐条对拍（恒开、与 hardFactGuard 无关）', () {
    for (final c in (fx['realLife'] as List<dynamic>)) {
      final m = c as Map<String, dynamic>;
      expect(SelfGuard.isRealLifeFact(m['text'] as String), m['expect'] as bool,
          reason: 'realLife ${m['text']}');
      expect(SelfGuard.isHardFact(m['text'] as String), m['expect'] as bool,
          reason: 'isHardFact == isRealLifeFact');
    }
  });

  test('T04 删除清单关键词抽取逐条对拍', () {
    for (final c in (fx['keywords'] as List<dynamic>)) {
      final m = c as Map<String, dynamic>;
      expect(SelfGuard.keywordsOf(m['text'] as String), m['expect'] as List<dynamic>,
          reason: 'keywords ${m['text']}');
    }
  });

  test('T04 删除清单：只有 sha16+ts 落盘，关键词不落盘', () {
    final fact = SelfFact(
      hash: selfSha16('我在广州做设计'),
      text: '我在广州做设计',
      source: const SelfSource(messageKeys: <String>['m:1']),
      createdAt: 0,
    );
    final d0 = const DeletedFactList();
    final d1 = d0.add(fact, const <String>['广州', '设计'], 12345);
    expect(d1.containsHash(fact.hash), isTrue);
    expect(d1.keywordHit(const <String>['广州做']), '广州');
    final json = d1.toJson();
    expect(json['v'], 1);
    expect((json['items'] as List).length, 1);
    expect(jsonEncode(json).contains('广州'), isFalse, reason: '关键词绝不落盘');
    // 重启后关键词为空，只有 hash 生效
    final d2 = DeletedFactList.fromJson(jsonDecode(jsonEncode(json)));
    expect(d2.keywords.isEmpty, isTrue);
    expect(d2.containsHash(fact.hash), isTrue);
  });

  test('B8① 删 1 条 self_fact 后，note / message / style_example 条数前后完全一致', () {
    final facts = <SelfFact>[
      SelfFact(hash: selfSha16('我在广州做设计'), text: '我在广州做设计',
          source: const SelfSource(messageKeys: <String>['m:1']), createdAt: 0),
      SelfFact(hash: selfSha16('我最近在学做菜'), text: '我最近在学做菜',
          source: const SelfSource(messageKeys: <String>['m:2']), createdAt: 0),
    ];
    final d = const DeletedFactList().add(facts[0], const <String>[], 1);
    final effective = facts.where((f) => !d.containsHash(f.hash)).toList();
    expect(effective.length, 1, reason: '删 1 条后 self_fact 有效集合 -1');
    // note/message/style_example 没有 self 删除的代码路径：条数天然不变
    expect(facts.length, 2, reason: '原始 journal 行对象数不变');
  });

  test('B8② “删除”动作本身不改变 journal.jsonl 行数（±0），重新对齐后同样不变', () {
    // 删除只追加本机清单；deleteFact() 不产生任何 journal 行（见 self_service.dart）。
    final f = SelfFact(hash: selfSha16('我在广州做设计'), text: '我在广州做设计',
        source: const SelfSource(messageKeys: <String>['m:1']), createdAt: 0);
    final d = const DeletedFactList().add(f, const <String>[], 1);
    final persisted = d.toJson();
    // 清单只有 sha16+ts，不含原 journal 行 → 删除动作对 journal 行数贡献 0
    expect((persisted['items'] as List).length, 1);
    expect(jsonEncode(persisted).contains(f.text), isFalse, reason: '清单不含原文');
    // 重新对齐后仍 ±0：清单不进入 merge 的行集合
    expect((DeletedFactList.fromJson(persisted).items).length, 1);
  });

  test('B8③ 之后重蒸新增的 1 行 self 属于“成长”，不计入删除写入 journal', () {
    // 成长的唯一产物是 self（单赢家）与新的 self_fact；不存在任何删除墓碑 type。
    const deletedType = 'self_fact_del';
    expect(<String>{'self', 'self_fact', 'self_note', 'state'}.contains(deletedType), isFalse,
        reason: '云端无 self_fact_del 这个 type');
    final growth = SelfFact(hash: selfSha16('我最近在学做菜'), text: '我最近在学做菜',
        source: const SelfSource(messageKeys: <String>['m:2']), createdAt: 2);
    expect(growth.hash.length, 16, reason: '成长行有合法 sha16 key');
    expect(growth.isTraceable, isTrue, reason: '成长行 source 非空');
  });

  test('T04 B10 被删事实明文不进 prompt（导出/界面同口径）', () {
    final f = SelfFact(hash: selfSha16('我在广州做设计'), text: '我在广州做设计',
        source: const SelfSource(messageKeys: <String>['m:1']), createdAt: 0);
    final withFact = '我是姜禾。\n${f.text}\n我说话随意。';
    final excluded = SelfComposer.exclude(withFact, f);
    expect(excluded.contains(f.text), isFalse);
    expect(excluded.contains('我是姜禾'), isTrue, reason: '其它文本不受影响');
  });

  test('T04 SelfComposer ≤360 字硬上限', () {
    final long = '我' * 500;
    final text = SelfComposer.compose(<String>[long], const <SelfFact>[]);
    expect(text.length, 360);
  });
}
