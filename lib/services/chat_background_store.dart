import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 聊天背景图存在 App 沙盒里（相册的临时文件随时会被系统清掉）。
/// 每次换图都写新文件名并清掉旧的，既避免堆积，也避开 Flutter 的图片缓存。
class ChatBackgroundStore {
  ChatBackgroundStore._();
  static final ChatBackgroundStore instance = ChatBackgroundStore._();

  Future<Directory> _dir() async {
    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(doc.path, 'chat_bg'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 把选中的图拷进沙盒，返回新路径。
  Future<String> persist(String tempPath) async {
    final dir = await _dir();
    for (final e in dir.listSync()) {
      if (e is File) {
        try {
          e.deleteSync();
        } catch (_) {
          // 删不掉就算了，不影响本次换图
        }
      }
    }
    final dest = p.join(
        dir.path, 'bg_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await File(tempPath).copy(dest);
    return dest;
  }

  /// 用户点「恢复默认」时顺手清掉占地方的旧图。
  Future<void> clear() async {
    try {
      final dir = await _dir();
      for (final e in dir.listSync()) {
        if (e is File) e.deleteSync();
      }
    } catch (_) {
      // 静默：清不掉也不影响使用
    }
  }
}
