import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/prefs.dart';
import '../models/persona_space.dart';
import '../services/update_service.dart';
import '../state/app_state.dart';
import '../widgets/update_helper.dart';

/// 启动落地页：人设卡（只读）。强调「这个人已经定了」。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  UpdateCheckResult? _update;

  @override
  void initState() {
    super.initState();
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    if (!await Prefs.autoUpdateCheck()) return;
    final r = await UpdateService().check();
    if (!mounted) return;
    setState(() => _update = r);
  }

  Future<void> _confirmRebuild() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除这个人，重新定？'),
        content: const Text(
          '人设定稿后不能改，删除是唯一重来的办法。\n\n'
          '角色、全部聊天记录、压缩记忆、行为手册会一起清空，无法恢复。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('再想想')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除重建')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().deleteCompanion();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/persona', (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final c = s.companion;
    final theme = Theme.of(context);

    if (c == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context)
              .pushNamedAndRemoveUntil('/persona', (r) => false);
        }
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    PersonaSpace? space;
    if (c.hasPersonaSpace) {
      try {
        space = PersonaSpace.decode(c.personaSpace);
      } catch (_) {
        space = null;
      }
    }

    final hasAvatar =
        c.avatarPath.isNotEmpty && File(c.avatarPath).existsSync();

    return Scaffold(
      appBar: AppBar(
        title: const Text('这个人'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_update?.hasUpdate == true) ...[
                Card(
                  color: theme.colorScheme.secondaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.system_update_alt_rounded),
                    title: Text('有新版本 ${_update!.info!.version}'),
                    subtitle: const Text('去设置里查看更新内容并升级'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pushNamed(context, '/settings'),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (s.needsRebuild) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Text(
                    '这是旧版本建的人设，没有完整的人设空间。按现在的规则，'
                    '需要删除重建一次，聊天记录会一并清空。',
                    style: TextStyle(height: 1.6),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: hasAvatar
                      ? Image.file(
                          File(c.avatarPath),
                          width: 128,
                          height: 128,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _placeholder(theme),
                        )
                      : _placeholder(theme),
                ),
              ),
              const SizedBox(height: 20),
              Center(
                child: Text(
                  c.name,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  '性格已定 · 不会更改',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.grey.shade600),
                ),
              ),
              const SizedBox(height: 22),
              if (space != null)
                Card(
                  child: ExpansionTile(
                    title: const Text('人设档案（只读）'),
                    subtitle: Text(
                        '${space.filledCount} 个维度 · 定稿于 ${_date(space.finalizedAt)}'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Text(space.renderReadonly(),
                            style: const TextStyle(height: 1.8)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 26),
              FilledButton.icon(
                onPressed: () => Navigator.pushNamed(context, '/chat'),
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                label: Text('继续和 ${c.name} 聊天'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.pushNamed(context, '/appearance'),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('修改头像与昵称'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _confirmRebuild,
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('删除重建'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () async {
                  final r = await UpdateHelper.checkAndShow(context);
                  if (!mounted) return;
                  setState(() => _update = r);
                },
                icon: const Icon(Icons.system_update_alt_rounded, size: 18),
                label: const Text('检查更新'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(ThemeData theme) => Container(
        width: 128,
        height: 128,
        color: Colors.grey.shade200,
        child:
            Icon(Icons.person_outline, size: 48, color: Colors.grey.shade500),
      );

  String _date(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}
