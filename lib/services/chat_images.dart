import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
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

  /// 角色的「定妆照」：把头像压成 512px 小图，作为她认识自己长相的参考。
  /// 缓存在 chat_images/selfie_cache.jpg，头像没换过就直接复用缓存。
  /// 压不了或头像不存在返回 null，上层降级成纯文字描述。
  Future<String?> selfieDataUrl(String avatarPath) async {
    try {
      final f = File(avatarPath);
      if (!f.existsSync()) return null;
      final doc = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(doc.path, 'chat_images'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final cache = File(p.join(dir.path, 'selfie_cache.jpg'));

      if (cache.existsSync() &&
          cache.lastModifiedSync().isAfter(f.lastModifiedSync())) {
        return 'data:image/jpeg;base64,${base64Encode(await cache.readAsBytes())}';
      }

      final decoded = img.decodeImage(await f.readAsBytes());
      if (decoded == null) return null;
      final resized = decoded.width > 512
          ? img.copyResize(decoded, width: 512)
          : decoded;
      final bytes = img.encodeJpg(resized, quality: 72);
      await cache.writeAsBytes(bytes);
      return 'data:image/jpeg;base64,${base64Encode(bytes)}';
    } catch (_) {
      return null;
    }
  }
}
