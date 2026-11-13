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

  static const int _maxAttempts = 3;
  static const Duration _connectTimeout = Duration(seconds: 15);

  /// 下载新版 APK。国内连 GitHub 下载域名偶发 TCP 超时，
  /// 这里做「明确超时 + 自动重试 + 说人话的报错」，不用用户手动点第二次。
  Future<String> download(
    String url,
    void Function(int received, int total) onProgress, {
    void Function(String status)? onStatus,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'peiban-update.apk');
    final f = File(path);
    if (await f.exists()) await f.delete();

    Object? lastError;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        onProgress(0, 0);
        onStatus?.call(attempt == 1
            ? '正在连接…'
            : '第 $attempt 次尝试（共 $_maxAttempts 次）…');
        await Dio().download(
          url,
          path,
          onReceiveProgress: onProgress,
          options: Options(
            connectTimeout: _connectTimeout,
            sendTimeout: _connectTimeout,
            receiveTimeout: const Duration(minutes: 5),
            followRedirects: true,
          ),
        );
        return path;
      } catch (e) {
        lastError = e;
        // 删掉半成品，避免下次把半个 APK 当完整包
        if (await f.exists()) await f.delete();
        if (attempt < _maxAttempts) {
          onStatus?.call('没连上，正在重试（${attempt + 1}/$_maxAttempts）…');
          await Future.delayed(Duration(seconds: attempt));
        }
      }
    }
    throw Exception(_friendlyError(lastError));
  }

  String _friendlyError(Object? e) {
    final s = e.toString();
    if (s.contains('connectionTimeout') ||
        s.contains('connection timeout') ||
        s.contains('SocketConnection timed out') ||
        s.contains('errno = 110')) {
      return '连不上 GitHub 的下载服务器，自动重试 $_maxAttempts 次还是没通。'
          '切换一下网络（Wi-Fi ↔ 流量）再点一次通常就好了，版本不会丢。';
    }
    if (s.contains('receiveTimeout')) {
      return '下载中途断了（网速太慢）。换个网络再点一次，会重新下载。';
    }
    if (s.contains('404')) {
      return '安装包地址失效了，检查一下 version.json 里的 apk_url。';
    }
    return '下载没成功，稍后再点一次。原始信息：'
        '${s.length > 120 ? '${s.substring(0, 120)}…' : s}';
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
