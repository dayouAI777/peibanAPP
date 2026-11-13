import 'dart:io';

import 'package:peiban_app/services/apk_downloader.dart';

/// 手动验证下载器（不打包进 App）：
///   `dart run tool/test_download.dart <url> <本地保存路径>`
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/test_download.dart <url> <dest>');
    exit(2);
  }
  final sw = Stopwatch()..start();
  final path = await ApkDownloader.download(
    url: args[0],
    destPath: args[1],
    onStatus: (s) => stdout.writeln('[status] $s'),
    onProgress: (r, t) {
      final mb = t > 0 ? '${(r / 1024 / 1024).toStringAsFixed(1)}/'
          '${(t / 1024 / 1024).toStringAsFixed(1)} MB' : '$r B';
      stdout.write('\r[progress] $mb      ');
    },
  );
  sw.stop();
  final f = File(path);
  stdout.writeln('\n[done] ${f.lengthSync()} 字节，用时 '
      '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s，'
      '平均 ${(f.lengthSync() / 1024 / (sw.elapsedMilliseconds / 1000)).toStringAsFixed(0)} KB/s');
}
