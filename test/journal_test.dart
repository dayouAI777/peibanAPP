import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/models/journal.dart';

void main() {
  group('journal 行构建与解析往返', () {
    test('一行 encode → parse 往返字段一致（含中文、emoji、嵌套 data）', () {
      final line = JournalLine(
        type: JournalLine.typeMessage,
        key: journalKeyForMessage('user', 1700000001000),
        ts: 1700000001000,
        dev: 'phone',
        data: const {
          'role': 'user',
          'content': '在干嘛😤 最近还好吗',
          'created_at': 1700000001000,
          'is_proactive': 0,
        },
      );

      final back = parseJournalLines('${line.encode()}\n');
      expect(back.length, 1);
      expect(back.first.type, JournalLine.typeMessage);
      expect(back.first.key, journalKeyForMessage('user', 1700000001000));
      expect(back.first.ts, 1700000001000);
      expect(back.first.dev, 'phone');
      expect(back.first.data['role'], 'user');
      expect(back.first.data['content'], '在干嘛😤 最近还好吗');
      expect(back.first.data['created_at'], 1700000001000);
    });

    test('buildJournalLine 构建的行内容与 JournalLine.encode 等价', () {
      final s = buildJournalLine(
        type: JournalLine.typeNote,
        key: journalKeyForNote('身份事实', '在广州工作'),
        ts: 123,
        data: const {'category': '身份事实', 'content': '在广州工作'},
      );
      final back = parseJournalLines(s);
      expect(back.length, 1);
      expect(back.first.type, JournalLine.typeNote);
      expect(back.first.key, 'n:4171b31ab4ce8acd');
      expect(back.first.data['content'], '在广州工作');
    });

    test('data 里带换行的字符串不会把 JSONL 撑裂（jsonEncode 转义）', () {
      final line = JournalLine(
        type: JournalLine.typeNote,
        key: journalKeyForNote('生活习惯', '第一行\n第二行'),
        ts: 1,
        data: const {'category': '生活习惯', 'content': '第一行\n第二行'},
      );
      final file = mergeJournal('', [line]);
      // 文件就是一行 + 结尾换行
      final physicalLines =
          file.split('\n').where((l) => l.trim().isNotEmpty).length;
      expect(physicalLines, 1);
      final back = parseJournalLines(file);
      expect(back.length, 1);
      expect(back.first.data['content'], '第一行\n第二行');
    });

    test('空文本解析为空列表（空库不是错误）', () {
      expect(parseJournalLines(''), isEmpty);
      expect(parseJournalLines('\n\n  \n'), isEmpty);
    });
  });

  group('journal 坏行净化', () {
    test('空行 / 坏 JSON / 非对象 / 未知 v / 未知 type / 空 key / data 非 map：逐个跳过，好行保留', () {
      final good = JournalLine(
        type: JournalLine.typeNote,
        key: journalKeyForNote('身份事实', '在广州工作'),
        ts: 7,
        data: const {'category': '身份事实', 'content': '在广州工作'},
      );
      final raw = [
        '', // 空行
        '{bad json', // 坏 JSON
        '123', // 合法 JSON 但不是对象
        '"字符串"', // 不是对象
        '[1,2,3]', // 不是对象
        '{"v":2,"type":"note","key":"n:abc","ts":1,"data":{}}', // 未来版本 → 跳过
        '{"v":1,"type":"todo","key":"t:1","ts":1,"data":{}}', // 未知 type → 跳过
        '{"v":1,"type":"note","key":"","ts":1,"data":{}}', // 空 key → 跳过
        '{"v":1,"type":"note","key":"n:abc","ts":1,"data":"不是对象"}', // data 非 map → 跳过
        '{"v":1,"type":"note","key":"n:abc","ts":1}', // 缺 data → 跳过
        good.encode(), // 好行
        '完全乱写的 行', // 坏行夹在好行后面
      ].join('\n');

      final back = parseJournalLines(raw);
      expect(back.length, 1, reason: '只有好行被保留');
      expect(back.first.key, good.key);
      expect(back.first.data['content'], '在广州工作');
    });

    test('缺 ts / ts 类型不对的行兜成 ts=0，不跳过、不崩', () {
      final raw =
          '{"v":1,"type":"note","key":"n:abc123","data":{"content":"x"}}';
      final back = parseJournalLines(raw);
      expect(back.length, 1);
      expect(back.first.ts, 0);
    });
  });

  group('journal 确定性指纹 key', () {
    test('message：同输入同 key，不同输入不同 key', () {
      expect(journalKeyForMessage('user', 1700000001000),
          journalKeyForMessage('user', 1700000001000));
      expect(journalKeyForMessage('user', 1700000001000),
          isNot(journalKeyForMessage('assistant', 1700000001000)));
      expect(journalKeyForMessage('user', 1700000001000),
          isNot(journalKeyForMessage('user', 1700000002000)));
      // 固定格式
      expect(journalKeyForMessage('user', 1700000001000),
          'm:user:1700000001000');
    });

    test('note：sha256(category+|+content) 前 16 位 hex，固定向量钉死', () {
      final k = journalKeyForNote('生活习惯', '周末睡到中午');
      expect(k, 'n:d5a7938613879e3d'); // 外部 python 算好钉死，防改盐/改拼接
      expect(journalKeyForNote('生活习惯', '周末睡到中午'), k); // 确定性
      expect(journalKeyForNote('生活习惯', '周末睡到中午'),
          isNot(journalKeyForNote('生活习惯', '周末早起'))); // 内容变 → key 变
      expect(journalKeyForNote('生活习惯', '周末睡到中午'),
          isNot(journalKeyForNote('身份事实', '周末睡到中午'))); // 类别变 → key 变
      // hex 形状
      expect(k.startsWith('n:'), isTrue);
      expect(k.substring(2), matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('style_example 与 memory_chunk：确定性 + 不同输入不同 key', () {
      final s = journalKeyForStyleExample('在忙哦，有什么事吗？', '刚画完画，你呢');
      expect(s, 's:f14889704c1a35e9');
      expect(journalKeyForStyleExample('在忙哦，有什么事吗？', '刚画完画，你呢'), s);
      expect(s, isNot(journalKeyForStyleExample('在忙哦', '刚画完画')));

      final c = journalKeyForMemoryChunk(1, 50, '聊了搬家的事');
      expect(c, 'c:ebadbe3ac219a1c1');
      expect(journalKeyForMemoryChunk(1, 50, '聊了搬家的事'), c);
      expect(c, isNot(journalKeyForMemoryChunk(2, 60, '聊了搬家')));
    });

    test('speech_profile / persona / style_profile 是固定 key（整对象一条）', () {
      expect(journalKeySpeechProfile, 'sp:v1');
      expect(journalKeyPersona, 'persona:v1');
      expect(journalKeyStyleProfile, 'stp:v1');
    });
  });

  group('journal 生效规则与追加合并', () {
    test('speech / persona：同 key 多行取 ts 最大的一行（平局取后出现的）', () {
      final old = JournalLine(
          type: JournalLine.typeSpeechProfile,
          key: journalKeySpeechProfile,
          ts: 100,
          data: const {'samples': 1});
      final mid = JournalLine(
          type: JournalLine.typeSpeechProfile,
          key: journalKeySpeechProfile,
          ts: 300,
          data: const {'samples': 3});
      final newest = JournalLine(
          type: JournalLine.typeSpeechProfile,
          key: journalKeySpeechProfile,
          ts: 200,
          data: const {'samples': 2});
      final eff = resolveEffectiveLines([old, mid, newest]);
      expect(eff.length, 1);
      expect(eff.first.ts, 300, reason: '取 ts 最大的那行');
      expect(eff.first.data['samples'], 3);

      // 平局：ts 相同取后出现的
      final a = JournalLine(
          type: JournalLine.typePersona,
          key: journalKeyPersona,
          ts: 100,
          data: const {'name': '旧'});
      final b = JournalLine(
          type: JournalLine.typePersona,
          key: journalKeyPersona,
          ts: 100,
          data: const {'name': '新'});
      final eff2 = resolveEffectiveLines([a, b]);
      expect(eff2.length, 1);
      expect(eff2.first.data['name'], '新');
    });

    test('普通类型全部保留（不去重，去重由调用方按 key 做）', () {
      final m1 = JournalLine(
          type: JournalLine.typeMessage,
          key: journalKeyForMessage('user', 1),
          ts: 1,
          data: const {'role': 'user'});
      final m2 = JournalLine(
          type: JournalLine.typeMessage,
          key: journalKeyForMessage('user', 2),
          ts: 2,
          data: const {'role': 'user'});
      final eff = resolveEffectiveLines([m1, m2]);
      expect(eff.length, 2);
    });

    test('mergeJournal：原文一行不动（含坏行原样保留），追加行排在后面', () {
      final good = JournalLine(
          type: JournalLine.typeNote,
          key: 'n:aaaa',
          ts: 1,
          data: const {'content': 'a'});
      final appended = JournalLine(
          type: JournalLine.typeNote,
          key: 'n:bbbb',
          ts: 2,
          data: const {'content': 'b'});
      final raw = '${good.encode()}\n这是一行坏数据\n';

      final merged = mergeJournal(raw, [appended]);
      final physical =
          merged.split('\n').where((l) => l.trim().isNotEmpty).toList();
      expect(physical.length, 3);
      expect(physical[0], good.encode(), reason: '原文第一行逐字节保留');
      expect(physical[1], '这是一行坏数据', reason: '原文坏行也原样保留（一行不删不改）');
      expect(physical[2], appended.encode(), reason: '追加行排在后面');
      expect(merged.endsWith('\n'), isTrue);
    });

    test('mergeJournal：空原文 + 空追加 = 空文件（不是错误）', () {
      expect(mergeJournal('', const []), '');
    });

    test('追加合并的幂等性：同 key 不重复追加（调用方按 key 过滤后 merge 不变）', () {
      final l1 = JournalLine(
          type: JournalLine.typeStyleExample,
          key: 's:aaaa',
          ts: 1,
          data: const {'original': 'a', 'preferred': 'b'});
      final first = mergeJournal('', [l1]);

      // 第二轮：从 first 里解析出 key 集合，同样的追加行应被整体过滤掉
      final keys = parseJournalLines(first).map((l) => l.key).toSet();
      final fresh = [l1].where((l) => !keys.contains(l.key)).toList();
      final second = mergeJournal(first, fresh);
      expect(second, first, reason: '相同 key 重复追加合并，文件应逐字节不变');
    });
  });

  group('journal style_profile 类型（她的说话方式档案）', () {
    JournalLine profileLine(int ts, int digested) => JournalLine(
          type: JournalLine.typeStyleProfile,
          key: journalKeyStyleProfile,
          ts: ts,
          data: {
            'digested': digested,
            'updated_at': ts,
            'tone': '随性偏糙',
            'catchphrases': <String>['哈？'],
            'taboos': '不连发长段',
          },
        );

    test('类型注册：knownTypes 认识 style_profile，isSingleWinner 成立', () {
      expect(JournalLine.knownTypes, contains(JournalLine.typeStyleProfile));
      final l = profileLine(1, 5);
      expect(l.isSingleWinner, isTrue);
    });

    test('encode → parse 往返：档案整对象字段原样回来', () {
      final back = parseJournalLines('${profileLine(1700000009000, 29).encode()}\n');
      expect(back.length, 1);
      expect(back.first.type, JournalLine.typeStyleProfile);
      expect(back.first.key, 'stp:v1');
      expect(back.first.data['digested'], 29);
      expect(back.first.data['tone'], '随性偏糙');
      expect(back.first.data['catchphrases'], <String>['哈？']);
      expect(back.first.data['taboos'], '不连发长段');
    });

    test('同 key 多行取 ts 最大的一行（档案更新后旧行不再生效）', () {
      final eff = resolveEffectiveLines(
          [profileLine(100, 10), profileLine(300, 29), profileLine(200, 20)]);
      expect(eff.length, 1);
      expect(eff.first.ts, 300);
      expect(eff.first.data['digested'], 29);
    });

    test('坏行净化对 style_profile 同样生效：data 非对象 / 空 key 跳过，好行保留', () {
      final raw = [
        '{"v":1,"type":"style_profile","key":"","ts":1,"data":{}}', // 空 key
        '{"v":1,"type":"style_profile","key":"stp:v1","ts":1,"data":"不是对象"}',
        profileLine(9, 29).encode(), // 好行
      ].join('\n');
      final back = parseJournalLines(raw);
      expect(back.length, 1);
      expect(back.first.data['digested'], 29);
    });
  });

  test('T01 四新 type：key 黄金值 / 单赢家集合 / 能力号（与 Node 逐字一致）', () {
    expect(journalKeySelf, 'self:v1');
    expect(journalKeyState, 'state:v1');
    expect(journalKeyForSelfFact('我在广州工作'), 'sf:0e6b349ef4572019');
    expect(journalKeyForSelfNote('20261113', '今天有点累'),
        'sn:20261113:49baf06a9b62633c');
    expect(kJournalCapability, 2);

    for (final t in <String>[
      JournalLine.typeSelf,
      JournalLine.typeSelfFact,
      JournalLine.typeSelfNote,
      JournalLine.typeState,
    ]) {
      expect(JournalLine.knownTypes.contains(t), isTrue, reason: '缺少 $t');
    }
    expect(JournalLine.knownTypes.contains('pending'), isFalse);
    expect(JournalLine.knownTypes.contains('self_fact_del'), isFalse);

    expect(JournalLine(type: 'self', key: 'self:v1', ts: 1, data: const {})
        .isSingleWinner, isTrue);
    expect(JournalLine(type: 'state', key: 'state:v1', ts: 1, data: const {})
        .isSingleWinner, isTrue);
    expect(JournalLine(type: 'self_fact', key: 'sf:x', ts: 1, data: const {})
        .isSingleWinner, isFalse);
    expect(JournalLine(type: 'self_note', key: 'sn:x', ts: 1, data: const {})
        .isSingleWinner, isFalse);
    expect(JournalLine(type: 'pending', key: 'p:x', ts: 1, data: const {})
        .isSingleWinner, isFalse);
  });

  test('v1.4.1：buildJournalLine 给四个新 type 自动注入 data.cap=2', () {
    final cases = <List<String>>[
      <String>[JournalLine.typeSelf, journalKeySelf],
      <String>[JournalLine.typeSelfFact, 'sf:x'],
      <String>[JournalLine.typeSelfNote, 'sn:20261125:x'],
      <String>[JournalLine.typeState, journalKeyState],
    ];
    for (final c in cases) {
      final line = parseJournalLines(buildJournalLine(
        type: c[0], key: c[1], ts: 10, data: const <String, dynamic>{'text': 'hi'},
      )).single;
      expect(line.data['cap'], 2, reason: '${c[0]} 必须自动注入 cap=2');
      expect(line.data['text'], 'hi');
    }
    // 显式 cap 不被覆盖
    final explicit = parseJournalLines(buildJournalLine(
      type: JournalLine.typeSelf,
      key: journalKeySelf,
      ts: 1,
      data: const <String, dynamic>{'cap': 9},
    )).single;
    expect(explicit.data['cap'], 9);
  });

  test('v1.4.1：buildJournalLine 对四个老 type 逐字节不变（回归防误伤老行格式）', () {
    final golden = <Map<String, String>>[
      <String, String>{
        'got': buildJournalLine(
            type: JournalLine.typePersona,
            key: 'persona:v1',
            ts: 3,
            data: const <String, dynamic>{'name': '阿雾'}),
        'want': '{"v":1,"type":"persona","key":"persona:v1","ts":3,"dev":"phone","data":{"name":"阿雾"}}',
      },
      <String, String>{
        'got': buildJournalLine(
            type: JournalLine.typeNote,
            key: 'n:a',
            ts: 4,
            data: const <String, dynamic>{'content': 'x'}),
        'want': '{"v":1,"type":"note","key":"n:a","ts":4,"dev":"phone","data":{"content":"x"}}',
      },
      <String, String>{
        'got': buildJournalLine(
            type: JournalLine.typeMessage,
            key: 'm:user:1',
            ts: 5,
            data: const <String, dynamic>{'role': 'user'}),
        'want': '{"v":1,"type":"message","key":"m:user:1","ts":5,"dev":"phone","data":{"role":"user"}}',
      },
      <String, String>{
        'got': buildJournalLine(
            type: JournalLine.typeMemoryChunk,
            key: 'c:a',
            ts: 6,
            data: const <String, dynamic>{'summary': 's'}),
        'want': '{"v":1,"type":"memory_chunk","key":"c:a","ts":6,"dev":"phone","data":{"summary":"s"}}',
      },
    ];
    for (final g in golden) {
      expect(g['got'], g['want']);
      expect(parseJournalLines(g['got']!).single.data.containsKey('cap'), isFalse);
    }
  });
}
