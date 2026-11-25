import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/journal.dart';
import 'journal_snapshot.dart';
import 'update_service.dart';

/// 导出模式：`full` 含聊天原文，`memory_only` 只含记忆（0 条 message）。
enum ExportMode { full, memoryOnly }

/// 导出结果。文案与"是否失败/是否成功"是**三件分开的事**（C5 要求，别合并）：
/// - [isFailure]：真异常（读写失败）。只有它为 true 时界面才说"导出失败"。
/// - [generated]：文件是否已生成（可与 isFailure 无关：C5② 里文件已生成但不显示"导出成功"）。
/// - [message]：给用户看的文案。
/// - [manifest]：导出清单。C5③ 失败时为 null（**不生成 manifest**）。
class ExportResult {
  final bool isFailure;
  final bool generated;
  final String message;
  final String? filePath;
  final Map<String, dynamic>? manifest;

  const ExportResult({
    required this.isFailure,
    required this.generated,
    required this.message,
    this.filePath,
    this.manifest,
  });
}

/// R3 导出服务：把本机 journal 行导成文件 + 清单。
///
/// 关键约束（PRD C5 / C6 / C7 / C9）：
/// - **白名单只在 [JournalSnapshot.build] 里筛一次**，本服务不再按 type 裁剪；
/// - `full` / `memoryOnly` 共用同一份原始行，只是 allow 集不同；
/// - C5 四条文案分支严格按 `cloudSync` 先于 `isComplete` 的顺序判（不许 `if (a && b)`）。
class ExportService {
  const ExportService._();

  /// 导出。失败安全：任何读写异常返回 [ExportResult.isFailure]=true 且**不带 manifest**。
  ///
  /// [outDir] / [baseName] **只用于测试**，生产调用方一个字不用改（都默认 null）：
  /// - [outDir] 为 null 时走 `getApplicationDocumentsDirectory()`（生产路径）。
  /// - [baseName] 为 null 时按 `peiban-<full|memory>-<时间戳>` 现算。
  ///
  /// 为什么需要 [baseName]：失败清理那条测试要**提前**在 manifest 的落点上造一个
  /// 同名目录（写到目录上必然抛），而现算的文件名里带微秒时间戳，外部**猜不到**。
  /// 所以把「这一次的文件名」做成可传入 —— 不是给生产开的口子，是让"半份文件
  /// 必须清掉"这条路径**能被真的执行到**（否则那两行 `_deleteQuietly` 零覆盖）。
  static Future<ExportResult> export({
    required List<JournalLine> lines,
    required ExportMode mode,
    required String cloudSync, // 'off' | 'on'
    required bool isComplete,
    Directory? outDir,
    String? baseName,
  }) async {
    // 本方法写出的文件（失败时只清这一个，不做通配删除）。
    File? jsonlFile;
    File? manifestFile;
    try {
      final snapshot = JournalSnapshot.build(
        lines,
        memoryOnly: mode == ExportMode.memoryOnly,
        cloudSync: cloudSync,
        isComplete: isComplete,
        appVersion: await _appVersion(),
      );

      final dir = outDir ?? await getApplicationDocumentsDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      final base = baseName ??
          'peiban-${mode == ExportMode.full ? 'full' : 'memory'}-$stamp';
      jsonlFile = File('${dir.path}${Platform.pathSeparator}$base.jsonl');
      // 只拼一次正文：**写进文件的那串字符串，就是算 sha256 的那串**（同一个变量）。
      final body = snapshot.toJsonl();
      await jsonlFile.writeAsString(body, flush: true);

      final manifest = snapshot.manifest(jsonlBody: body);
      manifestFile =
          File('${dir.path}${Platform.pathSeparator}$base.manifest.json');
      await manifestFile.writeAsString(jsonEncode(manifest), flush: true);

      final msg = _message(cloudSync: cloudSync, isComplete: isComplete);
      return ExportResult(
        isFailure: false,
        generated: true,
        message: msg,
        filePath: jsonlFile.path,
        manifest: manifest,
      );
    } catch (_) {
      // C5③：真异常才失败，且**不生成 manifest**。
      //
      // 失败要失败得干净：jsonl 是先落的盘，manifest 后写——manifest 写失败时
      // jsonl 已经躺在磁盘上了，而返回的 filePath 是 null，用户既拿不到路径也
      // 看不见它。留着就是一坨"看起来像备份、其实是半份"的文件。
      // 只清**本次这两个**路径，绝不做通配删除（那会误删用户以前导出的备份）。
      await _deleteQuietly(jsonlFile);
      await _deleteQuietly(manifestFile);
      return const ExportResult(
        isFailure: true,
        generated: false,
        message: '导出失败：读写出现异常，请稍后重试（记忆仍在，未受影响）',
        filePath: null,
        manifest: null,
      );
    }
  }

  /// 删一个文件，删不掉也不抛（失败路径上再抛异常会把真正的原因盖掉）。
  static Future<void> _deleteQuietly(File? f) async {
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删不掉就算了：重要的是别让它冒充"导出成功"。
    }
  }

  /// 当前 App 版本，形如 `1.7.4+20`（清单里的 `appVersion`，§3.4 要求非空）。
  /// 取不到（无插件环境 / 读失败）时给 `'unknown'`——**宁可说"不知道哪个版本"，
  /// 也不许把这个字段留空**：它是三个月后唯一能回溯"哪个版本导的"的线索。
  static Future<String> _appVersion() async {
    try {
      final v = await UpdateService().localVersion();
      final name = v.version.trim();
      if (name.isEmpty) return 'unknown';
      return '$name+${v.build}';
    } catch (_) {
      return 'unknown';
    }
  }

  /// C5 文案判定（纯函数，可单测）。**两个判断不许合成 `if (a && b)`**：
  /// `cloudSync` 必须先判——`off` 时不许落到 ② 分支。
  ///
  /// - ① `cloudSync=off`：正常，本机全部记忆，不算失败。
  /// - ② `cloudSync=on` 且 `isComplete=false`：不显示"导出成功"，但文件已生成。
  /// - ③ `on` 且完整：正常导出成功文案。
  static String _message({
    required String cloudSync,
    required bool isComplete,
  }) {
    // 铁律 1：`cloudSync` **只有 off / on 两值**。以前只是"文档上这么写"，
    // 实现里其余一切值（'OFF' / 'off ' / '' / 'unknown'）都会静默落到 ②③，
    // 最坏情况给用户看"导出成功"——这跟"把失败折叠成正常值"是同一族病：
    // 不该容忍的地方容忍了，错误就变成了正常路径。所以把它变成 debug 期会红的检查。
    assert(
      cloudSync == 'on' || cloudSync == 'off',
      'cloudSync 只有 off / on 两值（§3.4 铁律 1），收到：$cloudSync',
    );
    // ① 云同步未开启优先——必须先判，off 时不许落 ②。
    if (cloudSync == 'off') {
      return '云同步未开启，导出的是本机全部记忆';
    }
    // ② 云端已开但本机可能缺云端记录：不显示"导出成功"，但文件已生成可分享。
    if (!isComplete) {
      return '本机可能缺云端记录，建议先「对齐云端」再导一次';
    }
    // ③ on 且完整。
    return '导出成功，文件已生成';
  }

  /// 仅供测试：暴露文案判定（保持纯函数边界，不碰 IO）。
  static String messageFor({
    required String cloudSync,
    required bool isComplete,
  }) =>
      _message(cloudSync: cloudSync, isComplete: isComplete);
}
