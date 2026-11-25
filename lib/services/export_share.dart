import 'dart:io';

// XFile 由 share_plus 转出，不额外依赖 cross_file。
import 'package:share_plus/share_plus.dart';

import '../models/journal.dart';
import 'export_service.dart';

/// 分享动作的注入缝：**只接收一个文件路径**，返回时不做任何判断。
///
/// 抽成函数类型是为了让"导出成功必须把文件递到用户手里"这条能被单测——
/// 系统分享面板本身没法在单测里跑，但"有没有调、调了几次、传的是不是那个
/// filePath"全都能断。
typedef ShareOneFile = Future<void> Function(String path);

/// 「导出并把它交到用户手里」。
///
/// 为什么需要这一层：`ExportService.export()` 写的是
/// `getApplicationDocumentsDirectory()`，在 Android 上是
/// `/data/user/0/<包名>/app_flutter/...` —— **App 私有目录，任何文件管理器都
/// 看不到**。也就是说文件确实生成了、sha256 也确实算了，但用户拿不出来，
/// 那个导出等于没做。
///
/// 分层刻意这样切：
/// - `ExportService`：**只写文件**，不 import 任何 UI / 分享库（它的失败语义
///   是"读写异常"，不该被"用户取消了分享"污染）；
/// - 本类：文件写成功之后再"递出去"，**分享失败绝不影响导出结果**——文件已经
///   在磁盘上了，分享只是拿走它的动作。用户取消 / 没有可用应用都不是"导出失败"。
class ExportShare {
  ExportShare._();

  /// 分享面板里带哪些文件。
  ///
  /// **只带 `.jsonl` 一个**：manifest 是给机器看的（字段 / 计数 / sha256），
  /// 一起发出去只会让用户困惑"这两个哪个是我的记忆"，而且它没有独立价值——
  /// 真要校验，jsonl 本身就在，sha256 也写在文件旁边（同目录）。
  static List<String> filesFor(String jsonlPath) {
    final p = jsonlPath.trim();
    return p.isEmpty ? const <String>[] : <String>[p];
  }

  /// 默认分享实现：调系统分享面板。
  ///
  /// 用户在面板里可以「保存到文件」「发给微信」「存到网盘」——这才是真的把记忆
  /// 拿到手。**任何异常都吞掉**：这一层的失败不是导出失败。
  static Future<void> share(String jsonlPath) async {
    final files = filesFor(jsonlPath);
    if (files.isEmpty) return;
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[for (final f in files) XFile(f)],
          subject: '姜禾的记忆备份',
        ),
      );
    } catch (_) {
      // 用户取消 / 无可用应用 / 平台通道异常：文件已经写好了，静默即可。
      // 这里绝不能往上报"导出失败"，否则用户会以为文件没了。
    }
  }

  /// 导出 → 成功则分享。
  ///
  /// [share] 仅供测试替换（默认走系统面板）。**只在导出成功且拿到路径时调用**：
  /// 失败路径（`isFailure` / `filePath == null`）一次都不许弹面板——那时磁盘上
  /// 什么都没有，弹出来只会让用户以为导出成功了。
  static Future<ExportResult> exportAndShare({
    required List<JournalLine> lines,
    required ExportMode mode,
    required String cloudSync,
    required bool isComplete,
    ShareOneFile? share,
    // 以下两个只给测试用（与 ExportService.export 同口径透传）。
    Directory? outDir,
    String? baseName,
  }) async {
    final r = await ExportService.export(
      lines: lines,
      mode: mode,
      cloudSync: cloudSync,
      isComplete: isComplete,
      outDir: outDir,
      baseName: baseName,
    );
    final path = r.filePath;
    if (r.isFailure || path == null || path.trim().isEmpty) return r;
    try {
      await (share ?? ExportShare.share)(path);
    } catch (_) {
      // 分享失败只影响"拿走"，不影响"导出成功"。
    }
    return r;
  }
}
