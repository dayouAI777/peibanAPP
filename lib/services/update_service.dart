import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/prefs.dart';
import '../models/update_info.dart';
import 'apk_downloader.dart';

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

  /// 结果来自本机缓存（网络没通），用来在界面上说清「这是上次的清单」。
  final bool fromCache;

  const UpdateCheckResult({
    required this.hasUpdate,
    required this.local,
    this.info,
    this.error,
    this.fromCache = false,
  });
}

/// 在线升级：Git 仓库里的 version.json 就是「升级后台」，不需要服务器。
///
/// 国内访问 GitHub 的三个域名时通时断，旧写法是「raw 超时 12 秒 → 再试 API 15 秒」，
/// 慢的时候启动要空等近半分钟。这里改成：
///   1) 三个源并发竞速（raw / jsDelivr CDN / GitHub API），第一个回来后再等 1.2 秒，
///      收齐了就挑 build 最大的——谁先答不重要，谁新才重要（CDN 有缓存会吐旧清单）；
///   2) 成功一次就把清单缓存到本机，下次先拿缓存判断，再后台刷新；
///   3) 全部失败且缓存未过期时，用缓存结果照常提示升级，不因为网络抽风就「检查失败」。
class UpdateService {
  static const String rawUrl =
      'https://raw.githubusercontent.com/dayouAI777/peibanAPP/main/version.json';

  /// jsDelivr 的 GitHub 镜像：国内通常比 raw 通得快，且本身就是 CDN。
  static const String cdnUrl =
      'https://cdn.jsdelivr.net/gh/dayouAI777/peibanAPP@main/version.json';

  static const String apiUrl =
      'https://api.github.com/repos/dayouAI777/peibanAPP/contents/version.json';

  /// 三源竞速的总时限。超过就认输，用缓存兜底。
  static const Duration raceTimeout = Duration(seconds: 10);

  /// 第一个源回来后再等这么久，收其它源的答案。只加 1.2 秒，换来不认错版本。
  static const Duration graceWindow = Duration(milliseconds: 1200);

  /// 缓存多久算新鲜：超过这个时间，网络又读不到，就不再拿旧清单说「有新版本」。
  static const Duration cacheTtl = Duration(days: 7);

  Future<LocalVersion> localVersion() async {
    final i = await PackageInfo.fromPlatform();
    return LocalVersion(
      version: i.version,
      build: int.tryParse(i.buildNumber) ?? 0,
    );
  }

  // ——— 拉清单：三源并发，谁先成功算谁 ———

  Future<String> _tryRaw() async {
    final r = await http
        .get(Uri.parse(rawUrl))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) throw Exception('raw ${r.statusCode}');
    return utf8.decode(r.bodyBytes, allowMalformed: true);
  }

  Future<String> _tryCdn() async {
    final r = await http.get(
      Uri.parse(cdnUrl),
      headers: {'User-Agent': 'peiban-app'},
    ).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) throw Exception('cdn ${r.statusCode}');
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    // CDN 偶尔会把 404 页面 200 返回，这里用 JSON 解析做一次校验
    jsonDecode(text);
    return text;
  }

  Future<String> _tryApi() async {
    final r = await http.get(
      Uri.parse(apiUrl),
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'peiban-app',
      },
    ).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) throw Exception('api ${r.statusCode}');
    final m = jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true))
        as Map<String, dynamic>;
    final content = (m['content'] as String?)?.replaceAll('\n', '') ?? '';
    return utf8.decode(base64Decode(content), allowMalformed: true);
  }

  Future<String> _fetchVersionJson() {
    final completer = Completer<String>();
    final sources = <Future<String>>[_tryRaw(), _tryCdn(), _tryApi()];
    final answers = <String>[];
    var failed = 0;
    Timer? grace;

    void done() {
      if (completer.isCompleted || answers.isEmpty) return;
      completer.complete(newestManifest(answers));
    }

    for (final f in sources) {
      f.then(
        (v) {
          if (completer.isCompleted) return;
          answers.add(v);
          if (answers.length == sources.length) {
            grace?.cancel();
            done();
            return;
          }
          // 第一个回来的先别急着用：CDN 可能还吐着上一版的清单，等一小会儿
          grace ??= Timer(graceWindow, done);
        },
        onError: (Object _, StackTrace __) {
          failed++;
          if (failed == sources.length &&
              answers.isEmpty &&
              !completer.isCompleted) {
            completer.completeError(Exception('三个源都没连上'));
          }
        },
      );
    }

    return completer.future.timeout(raceTimeout);
  }

  /// 从多份清单里挑 build 最大的那份。解析不了的一律当 0 分。
  @visibleForTesting
  static String newestManifest(List<String> answers) {
    var best = answers.first;
    var bestBuild = buildOf(best);
    for (final a in answers.skip(1)) {
      final b = buildOf(a);
      if (b > bestBuild) {
        best = a;
        bestBuild = b;
      }
    }
    return best;
  }

  /// 取一份清单里的 build 号，坏数据返回 0。
  @visibleForTesting
  static int buildOf(String manifest) {
    try {
      final m = jsonDecode(manifest);
      if (m is Map && m['build'] is num) return (m['build'] as num).toInt();
    } catch (_) {
      // 不是 JSON 就当没版本，排在最后
    }
    return 0;
  }

  /// 读清单：网络优先；[preferCache] 为真时只要缓存还新鲜就立刻返回（毫秒级）。
  ///
  /// 无论哪种方式，成功了都会刷新缓存，下次启动更快。
  Future<String> _readManifest({
    bool preferCache = false,
    bool refreshInBackground = true,
  }) async {
    final cached = await Prefs.cachedVersionJson();
    final cachedAt = await Prefs.cachedVersionAt();
    final fresh = cached.trim().isNotEmpty &&
        DateTime.now().millisecondsSinceEpoch - cachedAt <
            cacheTtl.inMilliseconds;

    if (preferCache && fresh) {
      // 先用旧的顶上，同时后台悄悄刷新，不占用启动时间
      if (refreshInBackground) {
        unawaited(_fetchVersionJson().then((v) {
          Prefs.cacheVersionJson(v);
        }).catchError((_) {}));
      }
      return cached;
    }

    try {
      final v = await _fetchVersionJson();
      await Prefs.cacheVersionJson(v);
      return v;
    } catch (e) {
      if (fresh) return cached;
      rethrow;
    }
  }

  /// 检查更新。
  ///
  /// [preferCache] 给「启动时静默检查」用：有缓存就秒回，网络在后台补。
  /// 失败时若有可用缓存，会带 [UpdateCheckResult.fromCache] 返回，不当作错误。
  Future<UpdateCheckResult> check({bool preferCache = false}) async {
    final local = await localVersion();
    final hadCache = (await Prefs.cachedVersionJson()).trim().isNotEmpty;
    try {
      final info = UpdateInfo.fromJson(
        await _readManifest(preferCache: preferCache),
      );
      await Prefs.setLastUpdateCheck(DateTime.now().millisecondsSinceEpoch);
      final ignored = await Prefs.ignoredBuild();
      final has = info.build > local.build &&
          info.build != ignored &&
          info.apkUrl.trim().isNotEmpty;
      return UpdateCheckResult(hasUpdate: has, info: info, local: local);
    } catch (e) {
      // 网络彻底不通：只要能读到一份还没过期的缓存，就照常判断版本
      final cached = await Prefs.cachedVersionJson();
      final cachedAt = await Prefs.cachedVersionAt();
      final fresh = cached.trim().isNotEmpty &&
          DateTime.now().millisecondsSinceEpoch - cachedAt <
              cacheTtl.inMilliseconds;
      if (hadCache && fresh) {
        try {
          final info = UpdateInfo.fromJson(cached);
          final ignored = await Prefs.ignoredBuild();
          final has = info.build > local.build &&
              info.build != ignored &&
              info.apkUrl.trim().isNotEmpty;
          return UpdateCheckResult(
            hasUpdate: has,
            info: info,
            local: local,
            fromCache: true,
          );
        } catch (_) {
          // 缓存也坏了，走下面的报错
        }
      }
      return UpdateCheckResult(
        hasUpdate: false,
        local: local,
        error: e.toString().replaceAll('Exception: ', ''),
      );
    }
  }

  /// 下载新版 APK。
  ///
  /// 真实链路是：先挑最快的镜像 → 支持 Range 就 8 路分段并发 → 失败退回单连接。
  /// 具体在 [ApkDownloader] 里，这里只负责落盘位置和把错误翻译成人话。
  Future<String> download(
    String url,
    void Function(int received, int total) onProgress, {
    void Function(String status)? onStatus,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'peiban-update.apk');
    final f = File(path);
    if (await f.exists()) await f.delete();

    try {
      return await ApkDownloader.download(
        url: url,
        destPath: path,
        onProgress: onProgress,
        onStatus: onStatus,
      );
    } catch (e) {
      if (await f.exists()) await f.delete();
      throw Exception(_friendlyError(e));
    }
  }

  /// 后台静默下载：没有进度回调给界面，失败直接抛给调用方（调用方自己静默处理）。
  Future<String> downloadSilently(String url) => download(url, (_, __) {});

  String _friendlyError(Object? e) {
    final s = e.toString();
    if (s.contains('connectionTimeout') ||
        s.contains('connection timeout') ||
        s.contains('SocketConnection timed out') ||
        s.contains('errno = 110')) {
      return '连不上 GitHub 的下载服务器，自动重试 3 轮还是没通。'
          '切换一下网络（Wi-Fi ↔ 流量）再点一次通常就好了，版本不会丢。';
    }
    if (s.contains('所有下载源')) {
      return '三个下载源都试过了，一个都没连上。过几分钟再点一次，或者换个网络。';
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
