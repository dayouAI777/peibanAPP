import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/models/journal.dart';
import 'package:peiban_app/services/export_service.dart';

/// 「manifest 写失败必须清掉已落盘的 jsonl」这条路径的**可执行覆盖**。
///
/// 之前这条逻辑是零覆盖的：代码在那儿，但没有任何东西能让它失败或成功。
/// 而它保护的恰恰是最难受的失败——用户看到「导出失败」、返回的 `filePath`
/// 是 null，磁盘上却留了一份来路不明的 jsonl（用户拿不到路径、也看不见它，
/// 只有某天清理文件时才发现）。
///
/// 本文件用**真实文件系统**造那个中间态，不注入 fake、不 mock IO：
/// 1. 在 manifest 的**目标路径上先建一个同名目录** —— `writeAsString` 写到
///    目录上必然抛（EISDIR），而 jsonl 那一步已经成功落盘；
/// 2. 断言三件事：`isFailure == true`、`filePath == null`、**jsonl 真的不在盘上了**。
///
/// 注意「同名目录」不是笔误：就是靠"该是文件的位置上有个目录"来让写盘失败，
/// 这样失败点落在"jsonl 已写好之后"，正好命中要测的那段清理。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('peiban-export-cleanup-');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  /// 本次导出的固定文件名（不传 baseName 时 base 里带微秒时间戳，外部猜不到，
  /// 也就没法提前在那个位置上建目录）。
  const String base = 'peiban-full-cleanup-case';

  File jsonlIn(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}$base.jsonl');

  File manifestIn(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}$base.manifest.json');

  test('manifest 写失败 → 已落盘的 jsonl 必须被清掉，且不返回 filePath', () async {
    // ① 先占位：在 manifest 的目标路径上建一个**目录**。
    final squatter = Directory(manifestIn(tmp).path);
    await squatter.create();
    expect(await squatter.exists(), isTrue);

    // ② 真跑导出（不是手搓 ExportResult）。
    final r = await ExportService.export(
      lines: <JournalLine>[
        JournalLine(
          type: JournalLine.typeNote,
          key: 'n:a',
          ts: 1,
          data: const <String, dynamic>{'content': '喜欢猫'},
        ),
      ],
      mode: ExportMode.full,
      cloudSync: 'on',
      isComplete: true,
      outDir: tmp,
      baseName: base,
    );

    // ③ 三件分开断：失败 / 不给路径 / 半份文件不留在磁盘上。
    expect(r.isFailure, isTrue, reason: 'manifest 写不进去必须如实报失败');
    expect(r.generated, isFalse);
    expect(r.manifest, isNull, reason: 'C5③ 失败不生成 manifest');
    expect(r.filePath, isNull, reason: '失败时不给路径，否则用户会去点一个不存在的文件');
    expect(r.message.contains('导出失败'), isTrue);
    expect(r.message.contains('导出成功'), isFalse);

    expect(
      await jsonlIn(tmp).exists(),
      isFalse,
      reason: 'jsonl 是先落盘的，manifest 失败后必须把它清掉——'
          '否则磁盘上留一份用户看不见、也拿不到路径的半份备份',
    );
    // 占位的目录还在（清理只针对本次写出的两个文件，不做通配删除）。
    expect(await squatter.exists(), isTrue,
        reason: '清理只许删本次写出的文件，不许误删别的路径');
  });

  test('正常路径：同一套参数在没有占位目录时能成功，jsonl 与 manifest 都在', () async {
    // 对照组：证明上一条的红不是"这套参数怎么写都失败"。
    final r = await ExportService.export(
      lines: <JournalLine>[
        JournalLine(
          type: JournalLine.typeNote,
          key: 'n:a',
          ts: 1,
          data: const <String, dynamic>{'content': '喜欢猫'},
        ),
      ],
      mode: ExportMode.full,
      cloudSync: 'on',
      isComplete: true,
      outDir: tmp,
      baseName: base,
    );

    expect(r.isFailure, isFalse);
    expect(r.generated, isTrue);
    expect(await jsonlIn(tmp).exists(), isTrue);
    expect(await manifestIn(tmp).exists(), isTrue);
    expect(r.filePath, jsonlIn(tmp).path);
  });
}
