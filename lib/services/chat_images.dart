import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 用户随消息发的图片：先拷进 App 沙盒（相册临时文件随时可能被系统清掉），
/// 发请求时再转成 base64 data url 给模型看。
class ChatImages {
  ChatImages._();
  static final ChatImages instance = ChatImages._();

  /// 把 picker 返回的临时图拷进 documents/chat_images/，返回长期可用的路径。
  Future<String> persist(String tempPath) async {
    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(doc.path, 'chat_images'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final name =
        'img_${DateTime.now().millisecondsSinceEpoch}${p.extension(tempPath)}';
    final dest = p.join(dir.path, name);
    await File(tempPath).copy(dest);
    return dest;
  }

  /// 读图并转成 data:image/jpeg;base64,... 形式，文件没了就返回 null。
  Future<String?> dataUrl(String path) async {
    final f = File(path);
    if (!f.existsSync()) return null;
    final bytes = await f.readAsBytes();
    return 'data:image/jpeg;base64,${base64Encode(bytes)}';
  }
}
