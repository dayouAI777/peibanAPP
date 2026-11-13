import 'package:flutter/material.dart';

import '../services/silent_updater.dart';

/// 后台静默升级的状态条。
///
/// 设计原则：**只有「已经下好可以装」才主动出现在首页**；
/// 检查中、下载中一律不打扰（设置页里才显示，方便排查）。
class SilentUpdateBanner extends StatelessWidget {
  /// 是否显示「检查中 / 下载中」这类过程状态。首页给 false，设置页给 true。
  final bool showProgress;

  const SilentUpdateBanner({super.key, this.showProgress = false});

  Future<void> _install(BuildContext context, SilentUpdateState st) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('装新版 ${st.info?.version ?? ''}？'),
        content: const Text(
          '安装包已经在后台下好了，点「安装」会弹出系统的安装界面。\n\n'
          '聊天记录、人设、行为手册都存在本机，升级不会丢。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final path = st.path;
    if (path == null || path.isEmpty) return;
    try {
      await SilentUpdater.instance.install(path);
      // 系统安装界面已经拉起，这个包不再提示
      await SilentUpdater.instance.consume();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<SilentUpdateState>(
      valueListenable: SilentUpdater.instance.state,
      builder: (context, st, _) {
        final ready = st.hasReady;
        final working = st.phase == SilentPhase.checking ||
            st.phase == SilentPhase.downloading;

        if (ready) {
          return Card(
            margin: EdgeInsets.zero,
            color: theme.colorScheme.secondaryContainer,
            child: ListTile(
              leading: const Icon(Icons.download_done_rounded),
              title: Text('新版 ${st.info?.version ?? ''} 已经下好了'),
              subtitle: const Text('后台下完的，点一下就能装'),
              trailing: FilledButton(
                onPressed: () => _install(context, st),
                child: const Text('安装'),
              ),
            ),
          );
        }

        if (showProgress && working) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    st.phase == SilentPhase.checking
                        ? '后台正在查新版本…'
                        : '后台正在下安装包，不用管它',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.grey.shade600),
                  ),
                ),
              ],
            ),
          );
        }

        if (showProgress && st.phase == SilentPhase.failed) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '后台升级这次没成：${st.error ?? '网络问题'}（6 小时后再试）',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.grey.shade600),
            ),
          );
        }

        return const SizedBox.shrink();
      },
    );
  }
}
