import 'dart:convert';

/// 仓库里 version.json 的内容，作为在线升级的唯一依据。
class UpdateInfo {
  final String version;
  final int build;
  final String apkUrl;
  final List<String> changelog;
  final String publishedAt;
  final bool force;

  const UpdateInfo({
    required this.version,
    required this.build,
    required this.apkUrl,
    required this.changelog,
    required this.publishedAt,
    this.force = false,
  });

  factory UpdateInfo.fromJson(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return UpdateInfo(
      version: (m['version'] as String?) ?? '0.0.0',
      build: (m['build'] as num?)?.toInt() ?? 0,
      apkUrl: (m['apk_url'] as String?) ?? '',
      changelog: (m['changelog'] as List?) == null
          ? <String>[]
          : List<String>.from(m['changelog'] as List),
      publishedAt: (m['published_at'] as String?) ?? '',
      force: (m['force'] as bool?) ?? false,
    );
  }
}
