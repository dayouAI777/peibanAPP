import 'package:flutter/material.dart';

import '../data/prefs.dart';
import '../models/update_info.dart';
import '../services/update_service.dart';

/// 升级入口的共用逻辑：设置页和首页都调这里。
/// 注意：Git 仓库不会「推送」升级，是 App 自己来查 version.json（pull）。
class UpdateHelper {
  static final UpdateService _service = UpdateService();

  static Future<UpdateCheckResult> checkOnly() => _service.check();

  /// 手动检查：有新版弹升级面板，没有也给明确反馈（不用一闪而过的 SnackBar）。
  static Future<UpdateCheckResult> checkAndShow(BuildContext context) async {
    final r = await _service.check();
    if (!context.mounted) return r;
    if (r.hasUpdate && r.info != null) {
      await showUpdateSheet(context, r.info!);
    } else {
      await showResult(context, r);
    }
    return r;
  }

  static Future<void> showResult(
      BuildContext context, UpdateCheckResult r) async {
    final msg = r.error != null
        ? '检查失败：${r.error}\n\n检查一下手机网络，或稍后再试。'
        : '已是最新版 ${r.local.version}+${r.local.build}\n\n'
            '版本清单来自 Git 仓库的 version.json：只有仓库里的 build 号比本机大，'
            '才会提示升级。启动时的自动检查也走同一条链路。';
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('检查更新'),
        content: Text(msg),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 发现新版时的面板：更新内容 / 下载进度 / 重试状态 / 安装 / 忽略。
  static Future<void> showUpdateSheet(
      BuildContext context, UpdateInfo info) async {
    final local = await _service.localVersion();
    if (!context.mounted) return;

    var downloading = false;
    var received = 0;
    var total = 0;
    String? err;
    String? status;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('新版 ${info.version}',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text('发布于 ${info.publishedAt} · 当前 ${local.version}+${local.build}',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 16),
                  for (final line in info.changelog)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('·  '),
                          Expanded(child: Text(line)),
                        ],
                      ),
                    ),
                  if (downloading) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                        value: total > 0 ? received / total : null),
                    const SizedBox(height: 8),
                    Text(
                      status ?? '正在下载…',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary),
                    ),
                    if (total > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${(received / 1024 / 1024).toStringAsFixed(1)} / ${(total / 1024 / 1024).toStringAsFixed(1)} MB',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                  if (err != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(err!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 13,
                              height: 1.6)),
                    ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: downloading
                        ? null
                        : () async {
                            setSheet(() {
                              downloading = true;
                              err = null;
                              status = '正在连接…';
                              received = 0;
                              total = 0;
                            });
                            try {
                              final path = await _service.download(
                                info.apkUrl,
                                (r, t) => setSheet(() {
                                  received = r;
                                  total = t;
                                  if (t > 0) status = null; // 开始传数据后显示字节数
                                }),
                                onStatus: (s) => setSheet(() => status = s),
                              );
                              await _service.install(path);
                            } catch (e) {
                              setSheet(() {
                                downloading = false;
                                status = null;
                                err =
                                    e.toString().replaceAll('Exception: ', '');
                              });
                            }
                          },
                    child: Text(downloading ? '下载中…' : '下载并安装'),
                  ),
                  TextButton(
                    onPressed: () async {
                      await Prefs.setIgnoredBuild(info.build);
                      if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                    },
                    child: const Text('忽略这个版本'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
