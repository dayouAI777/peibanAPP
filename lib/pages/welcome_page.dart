import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'setup_page.dart';

/// 欢迎页。自用版不做年龄门槛、不叠免责声明，进来就能开始。
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final hasCompanion =
        context.select<AppState, bool>((s) => s.companion != null);
    final name =
        context.select<AppState, String>((s) => s.companion?.name ?? 'TA');
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),
              Icon(Icons.favorite_rounded,
                  size: 56, color: theme.colorScheme.primary.withOpacity(0.75)),
              const SizedBox(height: 28),
              Text(
                '有人在这儿等你',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              Text(
                '写细一点，TA 就更像你心里那个人。\n会记得你们聊过的事，也会偶尔主动找你。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: Colors.grey.shade600, height: 1.7),
              ),
              const Spacer(flex: 3),
              if (hasCompanion) ...[
                OutlinedButton(
                  onPressed: () => Navigator.pushNamed(context, '/chat'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  child: Text('继续和 $name 聊天'),
                ),
                const SizedBox(height: 12),
              ],
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SetupPage()),
                ),
                child: Text(hasCompanion ? '重新创建一个 TA' : '创建我的陪伴者'),
              ),
              if (hasCompanion)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    '重新创建会清空现在的聊天记录',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.grey.shade500),
                  ),
                ),
              const SizedBox(height: 20),
              Text(
                '对话由 AI 生成 · 设定和记录只存在这台手机里',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey.shade400),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
