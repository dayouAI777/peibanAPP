import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

/// 安装包下载器。
///
/// 为什么不能用一句 `dio.download` 了事：
/// APK 放在 GitHub Releases 上，国内直连 `objects.githubusercontent.com` 基本不通，
/// 只能走镜像；而单个镜像的单连接实测只有 250~570 KB/s，50 多 MB 要下两分钟以上。
///
/// 这里做了三件事：
///   1. **挑最快的源**：同时探测「直连 / ghfast / ghproxy」，各拉 256KB 测速，谁快用谁；
///   2. **分段并发**：支持 Range 的源拆成最多 8 段同时下，实测吞吐能到 1 MB/s 上下；
///   3. **断点续传**：每段落到独立分片文件，断了重下只补缺的那段，不从头再来。
class ApkDownloader {
  /// 镜像前缀。空串 = GitHub 直连（人在墙外时它最快，所以也参与竞速）。
  /// 这些是公共加速服务，可用性会变；探测失败会自动跳过，不会卡住下载。
  /// 实测（2026-11-13）：直连不通、ghfast 250~570KB/s、ghproxy.net 时通时断。
  static const List<String> mirrors = <String>[
    'https://ghfast.top/',
    'https://ghproxy.net/',
    '',
  ];

  /// 最多几路并发。再多容易被镜像限速，收益反而下降。
  static const int maxConnections = 8;

  /// 小于这个体积就不分段了，多线程的开销不值。
  static const int chunkThreshold = 6 * 1024 * 1024;

  /// 测速时每个源拉多少字节。
  static const int probeBytes = 256 * 1024;

  static const Duration _connectTimeout = Duration(seconds: 8);

  static Dio _client() => Dio(BaseOptions(
        connectTimeout: _connectTimeout,
        receiveTimeout: const Duration(minutes: 3),
        followRedirects: true,
        maxRedirects: 5,
        validateStatus: (s) => s != null && s < 400,
      ));

  /// 下载到 [destPath]，返回该路径。
  ///
  /// [onProgress] 是**总进度**（分段下载时已聚合）；
  /// [onStatus] 用来告诉界面上正在干什么（挑源 / 第几段重试）。
  static Future<String> download({
    required String url,
    required String destPath,
    void Function(int received, int total)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    final dest = File(destPath);
    if (await dest.exists()) await dest.delete();

    final pick = await _pickMirror(url, onStatus: onStatus);
    final fullUrl = '${pick.prefix}$url';
    onStatus?.call(pick.prefix.isEmpty ? '直连下载中…' : '走加速通道下载中…');

    final size = await _probeSize(fullUrl);
    if (size != null && size > chunkThreshold) {
      final ok = await _downloadChunked(
        fullUrl: fullUrl,
        destPath: destPath,
        total: size,
        onProgress: onProgress,
        onStatus: onStatus,
      );
      if (ok) return destPath;
      // 分段失败就退回单连接，别让用户白等
      onStatus?.call('分段下载没成，换单线程重试…');
    }

    await _downloadSingle(
      fullUrl: fullUrl,
      destPath: destPath,
      onProgress: onProgress,
      onStatus: onStatus,
    );
    return destPath;
  }

  // ——— 挑源 ———

  static Future<_Pick> _pickMirror(
    String url, {
    void Function(String status)? onStatus,
  }) async {
    onStatus?.call('正在挑最快的下载源…');

    // 国内到 GitHub 及其镜像的 TLS 握手经常被中途掐断（实测三个源会同时失败），
    // 所以这一层必须重试，不能让一次网络抖动把整个下载判死。
    for (var round = 1; round <= 3; round++) {
      final results = await Future.wait(
        mirrors.map((m) => _probe('$m$url', m)),
      );
      final usable = results.where((r) => r.bytes > 0).toList()
        ..sort((a, b) => b.speed.compareTo(a.speed));
      if (usable.isNotEmpty) return usable.first;
      if (round < 3) {
        onStatus?.call('网络抖了一下，重新挑源（$round/3）…');
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    throw Exception('所有下载源都连不上');
  }

  static Future<_Pick> _probe(String url, String prefix) async {
    final sw = Stopwatch()..start();
    try {
      final dio = _client();
      final resp = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-${probeBytes - 1}'},
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      var got = 0;
      // 只读一小段就断开，不为了测速把整个包拉下来
      await for (final chunk in resp.data!.stream) {
        got += chunk.length;
        if (got >= probeBytes) break;
      }
      sw.stop();
      if (got == 0) return _Pick(prefix, 0, 0);
      return _Pick(prefix, got, got / max(1, sw.elapsedMilliseconds));
    } catch (_) {
      return _Pick(prefix, 0, 0);
    }
  }

  /// 问一下文件多大。读不到就返回 null（退回单连接）。
  ///
  /// 先试 HEAD：多数镜像会老实给整包的 Content-Length。
  /// 拿不到再发 1KB 的 Range 读 Content-Range——
  /// 注意不能用 `bytes=0-0`：实测 ghfast 对单字节请求只回 Content-Length: 1，
  /// 不带 Content-Range，会误判成「读不到大小」。
  static Future<int?> _probeSize(String url) async {
    final dio = _client();

    try {
      final r = await dio.head<void>(
        url,
        options: Options(headers: {'Accept-Ranges': 'bytes'}),
      );
      final len = int.tryParse(r.headers.value('content-length') ?? '');
      if (len != null && len > 1024) return len;
    } catch (_) {
      // 有些镜像禁 HEAD，往下走
    }

    try {
      final r = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-1023'},
        ),
      );
      final cr = r.headers.value('content-range');
      await r.data?.stream.listen((_) {}).cancel();
      if (cr != null && cr.contains('/')) {
        final total = int.tryParse(cr.split('/').last.trim());
        if (total != null && total > 1024) return total;
      }
    } catch (_) {
      // 读不到就退回单连接，至少还能下
    }
    return null;
  }

  // ——— 分段并发 ———

  static Future<bool> _downloadChunked({
    required String fullUrl,
    required String destPath,
    required int total,
    void Function(int received, int total)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    final n = min(maxConnections, max(2, (total / (4 * 1024 * 1024)).ceil()));
    final chunkSize = (total / n).ceil();
    final meta = File('$destPath.meta');

    // 换了版本 / 上次下的不是同一个包 → 旧分片作废
    final want = '$total';
    if (await meta.exists()) {
      final old = (await meta.readAsString()).trim();
      if (old != want) await _cleanParts(destPath, n);
    }
    await meta.writeAsString(want);

    final progress = List<int>.filled(n, 0);
    void report() {
      var sum = 0;
      for (final v in progress) {
        sum += v;
      }
      onProgress?.call(min(sum, total), total);
    }

    onStatus?.call('分 $n 路同时下载…');
    final dio = _client();

    var failed = false;
    await Future.wait(List.generate(n, (i) async {
      final start = i * chunkSize;
      final end = min(total - 1, start + chunkSize - 1);
      if (start > end) return;
      final wantLen = end - start + 1;
      final part = File('$destPath.part$i');

      // 上次下完的分片直接复用
      if (await part.exists() && await part.length() == wantLen) {
        progress[i] = wantLen;
        report();
        return;
      }
      if (await part.exists()) await part.delete();

      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          await dio.download(
            fullUrl,
            part.path,
            options: Options(
              headers: {'Range': 'bytes=$start-$end'},
              receiveTimeout: const Duration(minutes: 3),
            ),
            deleteOnError: true,
            onReceiveProgress: (r, _) {
              progress[i] = r;
              report();
            },
          );
          // 服务端不认 Range 会把整包塞进这一片，长度对不上就当作失败
          if (await part.length() != wantLen) {
            throw Exception('分片长度不对');
          }
          return;
        } catch (_) {
          progress[i] = 0;
          report();
          if (attempt == 3) {
            failed = true;
            return;
          }
          onStatus?.call('第 $attempt 次没成，正在补第 ${i + 1} 段…');
          await Future<void>.delayed(Duration(seconds: attempt));
        }
      }
    }));

    if (failed) return false;

    // 合并
    onStatus?.call('正在合并…');
    final sink = File(destPath).openWrite();
    try {
      for (var i = 0; i < n; i++) {
        final part = File('$destPath.part$i');
        if (!await part.exists()) continue;
        await sink.addStream(part.openRead());
      }
    } finally {
      await sink.close();
    }

    final out = File(destPath);
    if (!await out.exists() || await out.length() != total) {
      if (await out.exists()) await out.delete();
      return false;
    }

    await _cleanParts(destPath, n);
    if (await meta.exists()) await meta.delete();
    onProgress?.call(total, total);
    return true;
  }

  static Future<void> _cleanParts(String destPath, int n) async {
    for (var i = 0; i < max(n, maxConnections); i++) {
      final f = File('$destPath.part$i');
      if (await f.exists()) await f.delete();
    }
  }

  // ——— 单连接兜底 ———

  static Future<void> _downloadSingle({
    required String fullUrl,
    required String destPath,
    void Function(int received, int total)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    final dio = _client();
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        onStatus?.call(attempt == 1 ? '正在连接…' : '第 $attempt 次尝试…');
        await dio.download(
          fullUrl,
          destPath,
          deleteOnError: true,
          onReceiveProgress: onProgress,
          options: Options(receiveTimeout: const Duration(minutes: 5)),
        );
        return;
      } catch (e) {
        if (attempt == 3) rethrow;
        onStatus?.call('没连上，正在重试（${attempt + 1}/3）…');
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
  }
}

class _Pick {
  final String prefix;
  final int bytes;
  final double speed;

  const _Pick(this.prefix, this.bytes, this.speed);
}
