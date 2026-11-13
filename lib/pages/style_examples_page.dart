import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// 用户长按消息亲手改过的说法，都在这里。
/// 能看见、能删——改坏了或者不想让她学了，随时撤。
class StyleExamplesPage extends StatelessWidget {
  const StyleExamplesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final list = app.styleExamples;

    return Scaffold(
      appBar: AppBar(title: const Text('她学到的说法')),
      body: list.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.edit_note_rounded,
                        size: 42, color: Colors.grey.shade400),
                    const SizedBox(height: 12),
                    Text(
                      '还没有。\n在聊天里长按她说的话，选「改她这句怎么说」，\n写一遍你希望她说出来的样子。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          height: 1.8, color: Colors.grey.shade600, fontSize: 13),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: list.length + 1,
              itemBuilder: (_, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '这些是你亲手改的，每次对话都会带上：她遇到同类场合，'
                      '会照「应该说」那栏的语气和长度来。共 ${list.length} 条。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.grey.shade600, height: 1.6),
                    ),
                  );
                }
                final e = list[i - 1];
                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 10),
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: Colors.grey.shade200),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (e.trigger.trim().isNotEmpty) ...[
                                Text(
                                  '当时你说：${e.trigger.trim()}',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600,
                                      height: 1.5),
                                ),
                                const SizedBox(height: 6),
                              ],
                              Text(
                                '她原来：${e.original}',
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.5,
                                  color: Colors.grey.shade500,
                                  decoration: TextDecoration.lineThrough,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '应该说：${e.preferred}',
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '删掉这条',
                          icon: Icon(Icons.close,
                              size: 18, color: Colors.grey.shade400),
                          onPressed: e.id == null
                              ? null
                              : () => app.deleteStyleExample(e.id!),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
