import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/models/journal.dart';
import 'package:peiban_app/services/export_service.dart';
import 'package:peiban_app/services/export_share.dart';

/// 「导出 + 把文件递到用户手里」的可执行覆盖。
///
/// 背景：`ExportService.export()` 写的是 `getApplicationDocumentsDirectory()`，
/// 在 Android 上是 `/data/user/0/<包名>/app_flutter/...` —— **App 私有目录，
/// 任何文件管理器都看不到**。文件生成了、sha256 也算了，但用户拿不出来，
/// 这个功能就等于没做。所以"导出成功后必须把文件递进系统分享面板"是**功能
/// 的一部分**，不是锦上添花。
///
/// 系统面板本身没法在单测里跑，但"有没有调、调了几次、传的是不是那个 filePath、
/// 带的是不是只有一个文件"全都能断——用注入的 [ShareOneFile] 记录器。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  const String base = 'peiban-full-share-case';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('peiban-export-share-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  List<JournalLine> sampleLines() => <JournalLine>[
        JournalLine(
          type: JournalLine.typeNote,
          key: 'n:a',
          ts: 1,
          data: const <String, dynamic>{'category': '稳定偏好', 'content': '喜欢猫'},
        ),
        JournalLine(
          type: JournalLine.typeMessage,
          key: 'm:user:2',
          ts: 2,
          data: const <String, dynamic>{'role': 'user', 'content': '你好'},
        ),
      ];

  test('导出成功 → 分享恰好调 1 次，传的就是 filePath', () async {
    final shared = <String>[];
    final r = await ExportShare.exportAndShare(
      lines: sampleLines(),
      mode: ExportMode.full,
      cloudSync: 'on',
      isComplete: true,
      outDir: tmp,
      baseName: base,
      share: (path) async => shared.add(path),
    );

    expect(r.isFailure, isFalse);
    expect(r.filePath, isNotNull);
    expect(shared.length, 1, reason: '导出成功必须把文件递出去，且只递一次');
    expect(shared.single, r.filePath, reason: '递出去的必须是那个文件本身');
    expect(await File(shared.single).exists(), isTrue);
  });

  test('只带 1 个文件，且不是 manifest（manifest 是给机器看的）', () async {
    final shared = <String>[];
    final r = await ExportShare.exportAndShare(
      lines: sampleLines(),
      mode: ExportMode.memoryOnly,
      cloudSync: 'off',
      isComplete: false,
      outDir: tmp,
      baseName: base,
      share: (path) async => shared.add(path),
    );

    final files = ExportShare.filesFor(shared.single);
    expect(files.length, 1, reason: '分享面板里只该有 1 个文件');
    expect(files.single, r.filePath);
    expect(files.single.endsWith('.jsonl'), isTrue);
    expect(files.any((f) => f.contains('manifest')), isFalse,
        reason: 'manifest 一起发出去只会让用户困惑"哪个才是我的记忆"');
  });

  test('「只导出记忆」与「导出全部」两条路径都走分享', () async {
    for (final mode in <ExportMode>[ExportMode.full, ExportMode.memoryOnly]) {
      final shared = <String>[];
      await ExportShare.exportAndShare(
        lines: sampleLines(),
        mode: mode,
        cloudSync: 'off',
        isComplete: false,
        outDir: tmp,
        baseName: '$base-${mode == ExportMode.full ? 'full' : 'memory'}',
        share: (path) async => shared.add(path),
      );
      expect(shared.length, 1, reason: '$mode 这条路径也必须分享');
    }
  });

  test('导出失败（manifest 落点被同名目录占住）→ 一次分享都不弹', () async {
    // 用真实文件系统造"jsonl 已落盘、manifest 写失败"的中间态。
    await Directory('${tmp.path}${Platform.pathSeparator}$base.manifest.json')
        .create();
    var shares = 0;
    final r = await ExportShare.exportAndShare(
      lines: sampleLines(),
      mode: ExportMode.full,
      cloudSync: 'on',
      isComplete: true,
      outDir: tmp,
      baseName: base,
      share: (path) async => shares++,
    );

    expect(r.isFailure, isTrue);
    expect(r.filePath, isNull);
    expect(shares, 0, reason: '磁盘上什么都没有的时候弹分享面板，等于告诉用户"导出成功了"');
  });

  test('分享抛异常 → 导出结果一个字都不变（文件已经写好了）', () async {
    final r = await ExportShare.exportAndShare(
      lines: sampleLines(),
      mode: ExportMode.full,
      cloudSync: 'on',
      isComplete: true,
      outDir: tmp,
      baseName: base,
      share: (path) async => throw StateError('用户取消了分享'),
    );

    expect(r.isFailure, isFalse, reason: '用户取消分享不是导出失败');
    expect(r.filePath, isNotNull);
    expect(await File(r.filePath!).exists(), isTrue);
    expect(r.message.contains('导出失败'), isFalse);
  });

  test('导出产物本身没被改动：文件在盘上、manifest 的 sha256 与正文实算相等', () async {
    final r = await ExportShare.exportAndShare(
      lines: sampleLines(),
      mode: ExportMode.full,
      cloudSync: 'on',
      isComplete: true,
      outDir: tmp,
      baseName: base,
      share: (path) async {},
    );

    final body = await File(r.filePath!).readAsString();
    final expected = sha256.convert(utf8.encode(body)).toString();
    expect(r.manifest!['sha256'], expected,
        reason: '分享这一步不许碰导出内容，指纹必须仍然对得上');
    expect(r.manifest!['lines'], 2);
    // 正文是逐行 JSON，没有被重排/裁剪
    final rows = body
        .trim()
        .split('\n')
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
    expect(rows.length, 2);
    expect(rows.first['type'], JournalLine.typeNote);
    expect(rows.last['type'], JournalLine.typeMessage);
  });
}
