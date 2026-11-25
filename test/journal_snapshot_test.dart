import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/models/journal.dart';
import 'package:peiban_app/services/export_service.dart';
import 'package:peiban_app/services/journal_snapshot.dart';

/// 造一条 journal 行（data 随便，只关心 type/key）。
JournalLine _line(String type, String key, int ts,
        [Map<String, dynamic> data = const <String, dynamic>{}]) =>
    JournalLine(type: type, key: key, ts: ts, data: data);

/// 一条"什么都有"的样本库：覆盖全部 10 个记忆 type + message + 一个虚构 type。
List<JournalLine> _sampleWithJunk() => <JournalLine>[
      _line(JournalLine.typePersona, 'persona:v1', 1, {'name': '林小满'}),
      _line(JournalLine.typeNote, 'n:a', 2, {'category': '稳定偏好', 'content': '喜欢猫'}),
      _line(JournalLine.typeMemoryChunk, 'c:a', 3, {'summary': '一段摘要'}),
      _line(JournalLine.typeSpeechProfile, 'sp:v1', 4, {'tone': '随意'}),
      _line(JournalLine.typeStyleProfile, 'stp:v1', 5, {'tone': '直接'}),
      _line(JournalLine.typeStyleExample, 's:a', 6, {'preferred': '嗯呢'}),
      _line(JournalLine.typeSelf, 'self:v1', 7, {'text': '我是姜禾'}),
      _line(JournalLine.typeSelfFact, 'sf:a', 8, {'text': '我在广州做设计'}),
      _line(JournalLine.typeSelfNote, 'sn:20260101:a', 9, {'text': '今天很累'}),
      _line(JournalLine.typeMessage, 'm:user:1', 10, {'content': '你好'}),
      _line(JournalLine.typeMessage, 'm:agent:2', 11, {'content': '嗨'}),
      _line('__unknown__', 'u:1', 12, {'x': 1}), // C9② 虚构 type，必须被白名单挡掉
    ];

void main() {
  group('C9③ 白名单与 knownTypes 常量一致性', () {
    test('knownTypes == W_FULL ∪ E_EXCLUDED（常量一致性，不扫 journal）', () {
      // 不抛错即通过；新增 type 忘了归类这里会红。
      expect(SnapshotWhitelist.assertKnownTypesClassified, returnsNormally);
    });

    test('当前 11 个 knownTypes 全部被归入 memory/full，excluded 为空集', () {
      expect(SnapshotWhitelist.excluded, isEmpty);
      expect(JournalLine.knownTypes.length, SnapshotWhitelist.full.length);
      expect(JournalLine.knownTypes.difference(SnapshotWhitelist.full), isEmpty);
    });
  });

  group('C9① 该挡的挡住了：type 集合 ⊆ 各自允许集', () {
    test('full 的 type 集合 ⊂ W_FULL', () {
      final snap = JournalSnapshot.full(_sampleWithJunk(),
          cloudSync: 'on', isComplete: true);
      final types = snap.lines.map((l) => l.type).toSet();
      expect(SnapshotWhitelist.full.containsAll(types), isTrue);
    });

    test('memory_only 的 type 集合 ⊂ W_MEMORY', () {
      final snap = JournalSnapshot.memoryOnly(_sampleWithJunk(),
          cloudSync: 'on', isComplete: true);
      final types = snap.lines.map((l) => l.type).toSet();
      expect(SnapshotWhitelist.memory.containsAll(types), isTrue);
    });

    test('manifest.byType 的 key 集合 ⊆ 各自允许集', () {
      final full = JournalSnapshot.full(_sampleWithJunk(),
          cloudSync: 'on', isComplete: true);
      final mem = JournalSnapshot.memoryOnly(_sampleWithJunk(),
          cloudSync: 'on', isComplete: true);
      expect(
          SnapshotWhitelist.full.containsAll(full.byType().keys), isTrue);
      expect(
          SnapshotWhitelist.memory.containsAll(mem.byType().keys), isTrue);
    });
  });

  group('C9② 防机制类混进来：虚构 type __unknown__ 两个导出都不出现', () {
    test('__unknown__ 不在 full', () {
      final snap = JournalSnapshot.full(_sampleWithJunk(),
          cloudSync: 'on', isComplete: true);
      expect(snap.lines.any((l) => l.type == '__unknown__'), isFalse);
      expect(snap.byType().containsKey('__unknown__'), isFalse);
    });

    test('__unknown__ 不在 memory_only', () {
      final snap = JournalSnapshot.memoryOnly(_sampleWithJunk(),
          cloudSync: 'on', isComplete: true);
      expect(snap.lines.any((l) => l.type == '__unknown__'), isFalse);
      expect(snap.byType().containsKey('__unknown__'), isFalse);
    });
  });

  group('C6 memory_only 里 0 条 message；9(10) 个记忆 type 计数与 full 逐项相等', () {
    test('memory_only 0 条 message', () {
      final mem = JournalSnapshot.memoryOnly(_sampleWithJunk(),
          cloudSync: 'on', isComplete: true);
      expect(mem.byType()[JournalLine.typeMessage] ?? 0, 0);
      expect(mem.lines.any((l) => l.type == JournalLine.typeMessage), isFalse);
    });

    test('九个记忆 type 计数逐项相等（state 缺失也容忍，不写死 9 项长度）', () {
      final full = JournalSnapshot.full(_sampleWithJunk(),
          cloudSync: 'on', isComplete: true);
      final mem = JournalSnapshot.memoryOnly(_sampleWithJunk(),
          cloudSync: 'on', isComplete: true);
      // 逐项遍历 W_MEMORY，不写死"9 项"——state 上线即第 10 项自动纳入。
      for (final type in SnapshotWhitelist.memory) {
        expect(mem.byType()[type] ?? 0, full.byType()[type] ?? 0,
            reason: 'type=$type 计数必须一致');
      }
      // 显式点名 PRD 的 9 项（防止 W_MEMORY 被误删成员）。
      for (final type in <String>[
        JournalLine.typePersona,
        JournalLine.typeNote,
        JournalLine.typeMemoryChunk,
        JournalLine.typeSpeechProfile,
        JournalLine.typeStyleProfile,
        JournalLine.typeStyleExample,
        JournalLine.typeSelf,
        JournalLine.typeSelfFact,
        JournalLine.typeSelfNote,
      ]) {
        expect(mem.byType()[type] ?? 0, full.byType()[type] ?? 0,
            reason: 'PRD 9 项之一：$type');
      }
    });
  });

  group('C7 full.lines - memory_only.lines == full 里 message 行数（±0）', () {
    test('差值恰为 message 行数', () {
      final raw = _sampleWithJunk();
      final full =
          JournalSnapshot.full(raw, cloudSync: 'on', isComplete: true);
      final mem =
          JournalSnapshot.memoryOnly(raw, cloudSync: 'on', isComplete: true);
      final messageCount = full.byType()[JournalLine.typeMessage] ?? 0;
      expect(full.lineCount - mem.lineCount, messageCount);
      expect(messageCount, 2);
    });
  });

  group(' R3 主格式：逐行原样，不重排不裁剪', () {
    test('full 的行顺序与原始一致（白名单只决定"进不进"，不重排）', () {
      final raw = _sampleWithJunk();
      final snap = JournalSnapshot.full(raw, cloudSync: 'on', isComplete: true);
      // 期望顺序 = 原顺序里剔除 __unknown__
      final expectedKeys = raw
          .where((l) => SnapshotWhitelist.full.contains(l.type))
          .map((l) => l.key)
          .toList();
      expect(snap.lines.map((l) => l.key).toList(), expectedKeys);
    });

    test('toJsonl 每行是原样 encode，不裁剪', () {
      final raw = _sampleWithJunk();
      final snap =
          JournalSnapshot.memoryOnly(raw, cloudSync: 'on', isComplete: true);
      final lines = snap.toJsonl().split('\n');
      expect(lines.length, snap.lineCount);
      for (var i = 0; i < snap.lineCount; i++) {
        expect(lines[i], snap.lines[i].encode());
      }
    });
  });

  group('C4 空库导出 0 行 + manifest(lines=0) 不报错', () {
    test('空 raw → 0 行，manifest.lines=0', () {
      final snap =
          JournalSnapshot.full(const [], cloudSync: 'on', isComplete: true);
      expect(snap.lineCount, 0);
      expect(snap.manifest(jsonlBody: snap.toJsonl())['lines'], 0);
      expect(snap.toJsonl(), '');
    });
  });

  group('C3/C8 安全：无密钥/口令明文', () {
    test('导出文本不含 API Key / 口令 / pushplus token 形态', () {
      final raw = <JournalLine>[
        _line(JournalLine.typePersona, 'persona:v1', 1, {'name': '林小满'}),
        _line(JournalLine.typeNote, 'n:a', 2, {'content': '喜欢猫'}),
      ];
      final text =
          JournalSnapshot.full(raw, cloudSync: 'on', isComplete: true).toJsonl();
      for (final secret in <String>['sk-', 'api_key', 'passphrase', 'pushplus']) {
        expect(text.contains(secret), isFalse, reason: '不应含 $secret');
      }
    });
  });

  group('§3.4 manifest 八字段（v1.4.5 验收项：四字段必须都在且非空）', () {
    test('kind / exportAt / appVersion / sha256 都在且非空', () {
      final snap = JournalSnapshot.full(
        _sampleWithJunk(),
        cloudSync: 'on',
        isComplete: true,
        exportAt: 1763000000000,
        appVersion: '1.7.4+20',
      );
      final m = snap.manifest(jsonlBody: snap.toJsonl());
      expect(m['kind'], 'full');
      expect(m['exportAt'], 1763000000000);
      expect(m['appVersion'], '1.7.4+20');
      expect(m['sha256'], isNotNull);
      expect((m['sha256'] as String).isNotEmpty, isTrue);
      expect(m['lines'], snap.lineCount);
      expect(m['cloudSync'], 'on');
      expect(m['isComplete'], isTrue);
    });

    test('memory_only 的 kind 是 memory_only（两种导出落到同目录时要认得出）', () {
      final snap = JournalSnapshot.memoryOnly(_sampleWithJunk(),
          cloudSync: 'on', isComplete: true);
      final m = snap.manifest(jsonlBody: snap.toJsonl());
      expect(m['kind'], 'memory_only');
    });

    test('sha256 与导出正文（不含 manifest 自身）实算值逐字相等', () {
      final snap = JournalSnapshot.full(_sampleWithJunk(),
          cloudSync: 'on', isComplete: true, appVersion: '1.7.4+20');
      final body = snap.toJsonl();
      // 用 crypto 独立算一遍，不信实现里那一份
      final expected = sha256.convert(utf8.encode(body)).toString();
      expect(snap.manifest(jsonlBody: body)['sha256'], expected);
      // 反向：改一个字符，指纹必须变（否则"指纹"是常量，等于没指纹）
      final tampered = '$body ';
      expect(sha256.convert(utf8.encode(tampered)).toString(), isNot(expected));
    });

    test('cloudSync=off 时 isComplete 恒 false（§3.4：关了同步就无法判断是否子集）', () {
      final snap = JournalSnapshot.full(_sampleWithJunk(),
          cloudSync: 'off', isComplete: true);
      final m = snap.manifest(jsonlBody: snap.toJsonl());
      expect(m['isComplete'], isFalse);
      expect(m['cloudSync'], 'off');
    });

    test('exportAt 缺省 = now（不倒填 0，否则清单里时间是假值）', () {
      final before = DateTime.now().millisecondsSinceEpoch;
      final snap =
          JournalSnapshot.full(const [], cloudSync: 'on', isComplete: true);
      final after = DateTime.now().millisecondsSinceEpoch;
      expect(snap.exportAt >= before, isTrue);
      expect(snap.exportAt <= after, isTrue);
    });
  });

  group('C5 四条文案分支（分开写，不许合并）', () {
    test('C5① cloudSync=off → 「云同步未开启」文案，正常不算失败', () {
      final msg = ExportService.messageFor(cloudSync: 'off', isComplete: false);
      expect(msg.contains('云同步未开启'), isTrue);
      expect(msg.contains('导出失败'), isFalse);
      expect(msg.contains('导出成功'), isFalse);
    });

    test('C5② cloudSync=on 且 isComplete=false → 缺云端记录的提示，不显示"导出成功"', () {
      final msg = ExportService.messageFor(cloudSync: 'on', isComplete: false);
      expect(msg.contains('本机可能缺云端记录'), isTrue);
      expect(msg.contains('导出成功'), isFalse);
      expect(msg.contains('导出失败'), isFalse);
    });

    test('C5④ off + isComplete=false 时文案必须是 ①（cloudSync 优先于 isComplete）', () {
      final off = ExportService.messageFor(cloudSync: 'off', isComplete: false);
      final on = ExportService.messageFor(cloudSync: 'on', isComplete: false);
      expect(off.contains('云同步未开启'), isTrue);
      expect(off, isNot(on), reason: 'off 不许落 ② 分支');
    });

    test('cloudSync 只有 off/on 两值；on+完整 → 导出成功', () {
      expect(ExportService.messageFor(cloudSync: 'on', isComplete: true),
          contains('导出成功'));
    });
  });

  group('C5③ 真异常才失败且不生成 manifest（ExportService 失败分支）', () {
    test('失败路径实跑：取不到文档目录 → isFailure=true 且 manifest=null', () async {
      // 单测环境没有 path_provider 原生实现 ⇒ 取文档目录必抛 ⇒ 走 C5③ 失败分支。
      // 断言的是**真实调用**的结果，不是手搓一个 ExportResult 来自证。
      final r = await ExportService.export(
        lines: <JournalLine>[
          _line(JournalLine.typeNote, 'n:a', 1, {'content': '喜欢猫'}),
        ],
        mode: ExportMode.full,
        cloudSync: 'on',
        isComplete: true,
      );
      expect(r.isFailure, isTrue, reason: '取不到目录必须如实报失败，不许假装成功');
      expect(r.generated, isFalse);
      expect(r.manifest, isNull, reason: 'C5③ 失败不生成 manifest');
      expect(r.filePath, isNull);
      expect(r.message.contains('导出失败'), isTrue);
      expect(r.message.contains('导出成功'), isFalse);
    });
  });
}
