import 'dart:async';

import 'package:flutter/material.dart';

import '../data/emoji_kit.dart';
import '../data/prefs.dart';

class EmojiPicker extends StatefulWidget {
  const EmojiPicker({super.key, required this.onTap});

  final ValueChanged<String> onTap;

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();
}

enum _EmojiView { frequent, overview }

class _EmojiPickerState extends State<EmojiPicker> {
  List<String>? _history;
  List<String> _frequent = [];
  _EmojiView _view = _EmojiView.overview;
  int _category = -1;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHistory());
  }

  Future<void> _loadHistory() async {
    var history = <String>[];
    try {
      history = await Prefs.emojiHistory();
    } catch (_) {
      debugPrint('Could not load emoji history');
    }
    if (!mounted) return;
    setState(() {
      _history = history;
      _frequent = EmojiKit.frequent(history);
      if (_frequent.isNotEmpty) _view = _EmojiView.frequent;
    });
  }

  void _switchTo(_EmojiView view) {
    setState(() {
      _view = view;
      // Keep the grid stable while the user is inserting several emojis.
      if (view == _EmojiView.frequent) {
        _frequent = EmojiKit.frequent(_history ?? const []);
      }
    });
  }

  void _select(String emoji) {
    widget.onTap(emoji);
    _history = [emoji, ..._history!.take(Prefs.emojiHistoryLimit - 1)];
    unawaited(_recordUse(emoji));
  }

  Future<void> _recordUse(String emoji) async {
    try {
      await Prefs.recordEmojiUse(emoji);
    } catch (_) {
      debugPrint('Could not save emoji history');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final groups =
        _category < 0 ? EmojiKit.groups : [EmojiKit.groups[_category]];

    return SizedBox(
      height: (MediaQuery.sizeOf(context).height * .4).clamp(100.0, 280.0),
      width: double.infinity,
      child: Material(
        color: colors.surface,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: SegmentedButton<_EmojiView>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: _EmojiView.frequent,
                          label: Text('常用'),
                        ),
                        ButtonSegment(
                          value: _EmojiView.overview,
                          label: Text('总览'),
                        ),
                      ],
                      selected: {_view},
                      onSelectionChanged: _history == null
                          ? null
                          : (view) => _switchTo(view.single),
                    ),
                  ),
                  const SizedBox(width: 6),
                  PopupMenuButton<int>(
                    tooltip: '选择表情分类',
                    icon: const Icon(Icons.grid_view_outlined),
                    enabled: _history != null,
                    initialValue: _category,
                    onSelected: (category) => setState(() {
                      _category = category;
                      _view = _EmojiView.overview;
                    }),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: -1, child: Text('全部分类')),
                      for (final (index, group) in EmojiKit.groups.indexed)
                        PopupMenuItem(value: index, child: Text(group.label)),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: _history == null
                  ? const Center(child: CircularProgressIndicator())
                  : _view == _EmojiView.frequent && _frequent.isEmpty
                      ? Center(
                          child: TextButton(
                            onPressed: () => _switchTo(_EmojiView.overview),
                            child: const Text('去总览选表情'),
                          ),
                        )
                      : CustomScrollView(
                          key: ValueKey((_view, _category)),
                          primary: false,
                          slivers: _view == _EmojiView.frequent
                              ? [_grid(_frequent)]
                              : [
                                  for (final group in groups) ...[
                                    SliverToBoxAdapter(
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                            14, 8, 14, 2),
                                        child: Text(
                                          group.label,
                                          style: theme.textTheme.labelLarge
                                              ?.copyWith(
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ),
                                    _grid(group.emojis),
                                  ],
                                ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(List<String> emojis) => SliverPadding(
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 52,
            mainAxisExtent: 44,
          ),
          itemCount: emojis.length,
          itemBuilder: (context, index) {
            final emoji = emojis[index];
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _select(emoji),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(emoji, style: const TextStyle(fontSize: 26)),
                  ),
                ),
              ),
            );
          },
        ),
      );
}
