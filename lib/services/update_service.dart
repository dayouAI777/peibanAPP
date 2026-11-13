import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/prefs.dart';
import '../models/update_info.dart';
import 'dart:io';

class LocalVersion {
  final String version;
  final int build;

  const LocalVersion({required this.version, required this.build});
}

class UpdateCheckResult {
  final bool hasUpdate;
  final UpdateInfo? info;
  final LocalVersion local;
  final String? error;

  const UpdateCheckResult({
    required this.hasUpdate,
    required this.local,
    this.info,
    this.error,
  });
}

/// 在线升级：Git 仓库里的 version.json 就是「升级后台」，不需要服务器。
/// 版本清单优先走 raw，失败退到 GitHub contents 接口（国内网络更稳）。
class UpdateService {
  static const String rawUrl =
      'https://raw.githubusercontent.com/dayouAI777/peibanAPP/main/version.json';
  static const String apiUrl =
      'https://api.github.com/repos/dayouAI777/peibanAPP/contents/version.json';

  Future<LocalVersion> localVersion() async {
    final i = await PackageInfo.fromPlatform();
    return LocalVersion(
      version: i.version,
      build: int.tryParse(i.buildNumber) ?? 0,
    );
  }

  Future<String> _fetchVersionJson() async {
    try {
      final r = await http
          .get(Uri.parse(rawUrl))
          .timeout(const Duration(seconds: 12));
      if (r.statusCode == 200) {
        return utf8.decode(r.bodyBytes, allowMalformed: true);
      }
    } catch (_) {
      // 换备用源
    }

    final r = await http.get(
      Uri.parse(apiUrl),
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'peiban-app',
      },
    ).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('读不到版本清单（HTTP ${r.statusCode}）');
    }
    final m = jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true))
        as Map<String, dynamic>;
    final content = (m['content'] as String?)?.replaceAll('\n', '') ?? '';
    return utf8.decode(base64Decode(content), allowMalformed: true);
  }

  Future<UpdateCheckResult> check() async {
    final local = await localVersion();
    try {
      final info = UpdateInfo.fromJson(await _fetchVersionJson());
      await Prefs.setLastUpdateCheck(DateTime.now().millisecondsSinceEpoch);
      final ignored = await Prefs.ignoredBuild();
      final has = info.build > local.build &&
          info.build != ignored &&
          info.apkUrl.trim().isNotEmpty;
      return UpdateCheckResult(hasUpdate: has, info: info, local: local);
    } catch (e) {
      return UpdateCheckResult(
        hasUpdate: false,
        local: local,
        error: e.toString().replaceAll('Exception: ', ''),
      );
    }
  }

  /// 下载新版 APK 到 App 私有目录，返回本地路径。
  Future<String> download(
      String url, void Function(int received, int total) onProgress) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'peiban-update.apk');
    final f = File(path);
    if (await f.exists()) await f.delete();

    await Dio().download(
      url,
      path,
      onReceiveProgress: onProgress,
      options: Options(
        receiveTimeout: const Duration(minutes: 10),
        followRedirects: true,
      ),
    );
    return path;
  }

  /// 调起系统安装界面（需要 REQUEST_INSTALL_PACKAGES 权限）。
  Future<void> install(String path) async {
    final result = await OpenFilex.open(
      path,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type != ResultType.done) {
      throw Exception('没能调起安装界面：${result.message}');
    }
  }
}
