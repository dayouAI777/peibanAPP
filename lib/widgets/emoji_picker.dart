import 'package:flutter/material.dart';

import '../data/emoji_kit.dart';

/// 表情面板：按情绪分组，点一下插入到输入框光标处。
class EmojiPicker extends StatelessWidget {
  final void Function(String emoji) onTap;

  const EmojiPicker({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: EmojiKit.groups.length,
      child: SafeArea(
        top: false,
        child: Container(
          height: 250,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(top: BorderSide(color: Colors.grey.shade300)),
          ),
          child: Column(
            children: [
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: theme.colorScheme.primary,
                unselectedLabelColor: Colors.grey.shade600,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: [
                  for (final g in EmojiKit.groups)
                    Tab(text: g.label),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    for (final g in EmojiKit.groups)
                      GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 8,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                        ),
                        itemCount: g.emojis.length,
                        itemBuilder: (_, i) => InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => onTap(g.emojis[i]),
                          child: Center(
                            child: Text(
                              g.emojis[i],
                              style: const TextStyle(fontSize: 26),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
