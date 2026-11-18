import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/services/apk_downloader.dart';

/// 针对 [ApkDownloader.rangeActuallySupported]（Range 行为验证纯函数）的
/// 单元测试。
///
/// 背景：线上 CDN（tcloudbaseapp.com）会在响应头谎报 `accept-ranges: bytes`，
/// 实际对 `Range: bytes=0-1023` 回 HTTP 200 + 全量 20903436 字节。
/// 判定函数必须只认实打实的证据（206 + Content-Range + 实收不超请求），
/// 否则分段下载会白拉几百 MB 流量。
void main() {
  group('ApkDownloader.rangeActuallySupported（Range 行为验证纯函数）', () {
    test('206 + Content-Range + 实收恰好等于请求 → 支持', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 206,
          hasContentRange: true,
          receivedBytes: 1024,
          requestedBytes: 1024,
        ),
        isTrue,
      );
    });

    test('206 + Content-Range + 实收少于请求 → 支持', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 206,
          hasContentRange: true,
          receivedBytes: 512,
          requestedBytes: 1024,
        ),
        isTrue,
      );
    });

    test('200 + 全量 20903436 字节（线上事故场景：CDN 谎报 accept-ranges）→ 不支持', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 200,
          hasContentRange: false,
          receivedBytes: 20903436,
          requestedBytes: 1024,
        ),
        isFalse,
      );
    });

    test('200 + 实收恰好 1024（部分谎报）→ 不支持', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 200,
          hasContentRange: false,
          receivedBytes: 1024,
          requestedBytes: 1024,
        ),
        isFalse,
      );
    });

    test('200 但带 Content-Range 且实收不超 → 仍不支持（非 206 不算数）', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 200,
          hasContentRange: true,
          receivedBytes: 1024,
          requestedBytes: 1024,
        ),
        isFalse,
      );
    });

    test('206 但没有 Content-Range 头 → 不支持', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 206,
          hasContentRange: false,
          receivedBytes: 1024,
          requestedBytes: 1024,
        ),
        isFalse,
      );
    });

    test('状态码未知（null）→ 不支持', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: null,
          hasContentRange: true,
          receivedBytes: 1024,
          requestedBytes: 1024,
        ),
        isFalse,
      );
    });

    test('5xx 服务器错误 → 不支持', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 502,
          hasContentRange: true,
          receivedBytes: 1024,
          requestedBytes: 1024,
        ),
        isFalse,
      );
    });

    test('实收字节数为负（异常输入）→ 不支持', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 206,
          hasContentRange: true,
          receivedBytes: -1,
          requestedBytes: 1024,
        ),
        isFalse,
      );
    });

    test('请求字节数为 0（异常输入）→ 不支持', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 206,
          hasContentRange: true,
          receivedBytes: 0,
          requestedBytes: 0,
        ),
        isFalse,
      );
    });

    // ——— 补充边界（QA 独立回归追加，覆盖谎报源的典型变形） ———

    test('206 + Content-Range 但实收超出请求 1 字节 → 不支持（超量边界）', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 206,
          hasContentRange: true,
          receivedBytes: 1025,
          requestedBytes: 1024,
        ),
        isFalse,
      );
    });

    test('206 + Content-Range 但实收大幅超出（谎报源整包塞过来）→ 不支持', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 206,
          hasContentRange: true,
          receivedBytes: 20903436,
          requestedBytes: 1024,
        ),
        isFalse,
      );
    });

    test('301 重定向状态码 → 不支持（只有 206 算数）', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 301,
          hasContentRange: true,
          receivedBytes: 1024,
          requestedBytes: 1024,
        ),
        isFalse,
      );
    });

    test('416 Range Not Satisfiable → 不支持', () {
      expect(
        ApkDownloader.rangeActuallySupported(
          statusCode: 416,
          hasContentRange: true,
          receivedBytes: 0,
          requestedBytes: 1024,
        ),
        isFalse,
      );
    });
  });
}
