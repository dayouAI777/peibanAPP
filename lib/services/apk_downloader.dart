import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

/// 安装包下载器。
///
/// 为什么不能用一句 `dio.download` 了事：
/// APK 放在 GitHub Releases 上时，国内直连 `objects.githubusercontent.com`
/// 基本不通，只能走镜像；而单个镜像的单连接实测只有 250~570 KB/s，
/// 50 多 MB 要下两分钟以上。
///
/// 这里做了三件事：
///   1. **挑最快的源**：GitHub 链接（含 raw/release 的
///      githubusercontent.com 直链）同时探测「直连 / ghfast / ghproxy」，
///      各拉 256KB 测速，谁快用谁；**非 GitHub 链接（如自家 CDN
///      tcloudbaseapp.com）跳过挑源直连**——镜像前缀拼上去就是垃圾地址；
///   2. **分段并发**：先做一次 1KB Range **行为验证**，确认源真的只回
///      小段才拆成最多 8 段同时下，实测吞吐能到 1 MB/s 上下。不能只信
///      `accept-ranges: bytes` 响应头——部分静态托管 CDN（实测
///      tcloudbaseapp.com）头里写着 accept-ranges: bytes，实际对 Range
///      请求回 200 + 全量内容，信了它进度条就会「拉满又重来」，
///      白拉几百 MB 流量后才退回单连接；
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

  /// Range 行为验证探针请求的字节数（1KB）。
  static const int rangeProbeBytes = 1024;

  static const Duration _connectTimeout = Duration(seconds: 8);

  static Dio _client() => Dio(BaseOptions(
        connectTimeout: _connectTimeout,
        receiveTimeout: const Duration(minutes: 3),
        followRedirects: true,
        maxRedirects: 5,
        validateStatus: (s) => s != null && s < 400,
      ));

  /// 判定一次 Range 响应是否「真的支持分段」（纯函数，可单测）。
  ///
  /// 只认实打实的证据，三条必须同时满足：
  ///   - 状态码是 206 Partial Content；
  ///   - 响应带 Content-Range 头（没有头的 206 同样不可信）；
  ///   - 实收字节数不超过请求字节数——超了说明服务端无视 Range 把整包
  ///     （或超量内容）塞了过来。
  ///
  /// 为什么不能信 `accept-ranges: bytes` 响应头：线上实测
  /// tcloudbaseapp.com 静态托管 CDN 对 `Range: bytes=0-1023` 回
  /// HTTP 200 + 全量 20903436 字节，响应头却带 accept-ranges: bytes，
  /// 纯靠头判断会白拉几百 MB 流量。
  static bool rangeActuallySupported({
    required int? statusCode,
    required bool hasContentRange,
    required int receivedBytes,
    required int requestedBytes,
  }) {
    if (statusCode == null || statusCode != 206) return false;
    if (!hasContentRange) return false;
    if (requestedBytes <= 0) return false;
    if (receivedBytes < 0) return false;
    return receivedBytes <= requestedBytes;
  }

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

    // 只有 GitHub 链接才需要挑镜像：镜像前缀拼到非 GitHub 地址前面
    // （如自家 CDN tcloudbaseapp.com）就是垃圾地址，三个源全废。
    // githubusercontent.com 是 GitHub raw / release 资产的真实跳转目标，
    // 直链同样被墙，必须和 github.com 一样参与镜像竞速。
    // 非GitHub 源若真支持 Range，后面的分段并发照样生效（有行为验证兜底）。
    final onGithub =
        url.contains('github.com') || url.contains('githubusercontent.com');
    final pick = onGithub
        ? await _pickMirror(url, onStatus: onStatus)
        : const _Pick('', 0, 0);
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

  /// 发一次 1KB 的 Range 探针 GET，收集判定所需的所有证据。
  ///
  /// 读到能下结论的字节数就 break（await-for 退出时会自动 cancel 订阅、
  /// 释放连接），不会为了验证把整包拉下来。任何网络异常返回 null。
  static Future<_RangeProbe?> _rangeProbe(String url) async {
    final dio = _client();
    try {
      final r = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-${rangeProbeBytes - 1}'},
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      final cr = r.headers.value('content-range');
      var received = 0;
      await for (final chunk in r.data!.stream) {
        received += chunk.length;
        // 超过请求字节数 = 服务端无视 Range，足够下结论，立即断开
        if (received > rangeProbeBytes) break;
      }
      int? total;
      if (cr != null && cr.contains('/')) {
        total = int.tryParse(cr.split('/').last.trim());
      }
      return _RangeProbe(
        statusCode: r.statusCode,
        hasContentRange: (cr ?? '').isNotEmpty,
        totalFromContentRange: total,
        receivedBytes: received,
      );
    } catch (_) {
      return null;
    }
  }

  /// 问一下文件多大。读不到大小、或源只是「嘴上说支持 Range」就返回
  /// null（退回单连接）。
  ///
  /// 流程：
  ///   1. 先试 HEAD 拿整包 Content-Length——但这只是服务器「自报」，
  ///      **不能**单独作为走分段的依据（CDN 会谎报 accept-ranges，
  ///      见 [rangeActuallySupported] 的注释）；
  ///   2. 无论 HEAD 成败，都再发一次 1KB Range GET 做**行为验证**：
  ///      206 + Content-Range + 实收不超过请求字节数，才允许走分段；
  ///   3. HEAD 拿不到长度时，从 Content-Range 里读总长——这条兜底路径
  ///      同样要先通过行为验证，不留后门。
  /// 注意不能用 `bytes=0-0`：实测 ghfast 对单字节请求只回 Content-Length: 1，
  /// 不带 Content-Range，会误判成「读不到大小」。
  static Future<int?> _probeSize(String url) async {
    final dio = _client();

    var headLen = 0;
    try {
      final r = await dio.head<void>(
        url,
        options: Options(headers: {'Accept-Ranges': 'bytes'}),
      );
      headLen = int.tryParse(r.headers.value('content-length') ?? '') ?? 0;
    } catch (_) {
      // 有些镜像禁 HEAD，往下走
    }

    final probe = await _rangeProbe(url);
    if (probe == null || !probe.supported) return null;

    if (headLen > rangeProbeBytes) return headLen;
    final crTotal = probe.totalFromContentRange;
    if (crTotal != null && crTotal > rangeProbeBytes) return crTotal;
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
    final tokens = List<CancelToken>.generate(n, (_) => CancelToken());

    var failed = false;
    // 有段收到「长度对不上」这种实锤 = 源根本不认 Range。此时必须让其余
    // 段**立即停手**，而不是各段独自重试 3 次把全量白拉好几遍
    // （线上事故就是这里漏掉的 ~300MB 流量）。
    var rangeBroken = false;

    void abortAll({required bool rangeNotHonored}) {
      failed = true;
      if (rangeNotHonored) rangeBroken = true;
      for (final t in tokens) {
        if (!t.isCancelled) t.cancel('分段下载中止');
      }
    }

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
        // 兄弟段已实锤源不认 Range（或本段已被取消）→ 立即停手，别再白拉
        if (failed || tokens[i].isCancelled) return;
        try {
          await dio.download(
            fullUrl,
            part.path,
            options: Options(
              headers: {'Range': 'bytes=$start-$end'},
              receiveTimeout: const Duration(minutes: 3),
            ),
            deleteOnError: true,
            cancelToken: tokens[i],
            onReceiveProgress: (r, _) {
              progress[i] = r;
              report();
            },
          );
          // 服务端不认 Range 会把整包塞进这一片，长度对不上就是实锤：
          // 立即取消其余所有在途段（fail-fast），把最坏浪费压到一波
          // 在途请求以内，然后整体退回单连接。
          if (await part.length() != wantLen) {
            if (await part.exists()) await part.delete();
            abortAll(rangeNotHonored: true);
            return;
          }
          return;
        } catch (_) {
          progress[i] = 0;
          report();
          // 被 fail-fast 取消 / 已经判死：不重试，直接退出
          if (failed || tokens[i].isCancelled) return;
          if (attempt == 3) {
            failed = true;
            return;
          }
          onStatus?.call('第 $attempt 次没成，正在补第 ${i + 1} 段…');
          await Future<void>.delayed(Duration(seconds: attempt));
        }
      }
    }));

    if (failed) {
      if (rangeBroken) {
        // 源不认 Range 的分片毫无复用价值，清掉省得占着几十 MB 磁盘
        await _cleanParts(destPath, n);
        if (await meta.exists()) await meta.delete();
      }
      return false;
    }

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

/// 1KB Range 探针请求收集到的证据。
class _RangeProbe {
  final int? statusCode;
  final bool hasContentRange;
  final int? totalFromContentRange;
  final int receivedBytes;

  const _RangeProbe({
    required this.statusCode,
    required this.hasContentRange,
    required this.totalFromContentRange,
    required this.receivedBytes,
  });

  /// 是否通过 Range 行为验证（判据见 [ApkDownloader.rangeActuallySupported]）。
  bool get supported => ApkDownloader.rangeActuallySupported(
        statusCode: statusCode,
        hasContentRange: hasContentRange,
        receivedBytes: receivedBytes,
        requestedBytes: ApkDownloader.rangeProbeBytes,
      );
}

class _Pick {
  final String prefix;
  final int bytes;
  final double speed;

  const _Pick(this.prefix, this.bytes, this.speed);
}
