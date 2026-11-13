import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/chat_background.dart';
import '../services/chat_background_store.dart';
import '../state/app_state.dart';
import '../widgets/chat_background_view.dart';

/// 聊天背景。改完立刻生效、立刻落盘，没有「保存」按钮——
/// 背景这种事，看到什么就是什么最省心。
class BackgroundPage extends StatefulWidget {
  const BackgroundPage({super.key});

  @override
  State<BackgroundPage> createState() => _BackgroundPageState();
}

class _BackgroundPageState extends State<BackgroundPage> {
  bool _busy = false;

  Future<void> _apply(ChatBackground bg) async {
    final app = context.read<AppState>();
    await app.setChatBackground(bg);
  }

  Future<void> _pickImage() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1440,
        imageQuality: 82,
      );
      if (x == null) return;
      setState(() => _busy = true);
      final path = await ChatBackgroundStore.instance.persist(x.path);
      await _apply(app.chatBg.copyWith(type: 'image', imagePath: path));
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(const SnackBar(content: Text('这张图读不出来，换一张试试')));
    }
  }

  Future<void> _removeImage() async {
    await ChatBackgroundStore.instance.clear();
    await _apply(ChatBackground.initial);
  }

  Widget _bubble(String text, bool mine, ThemeData theme) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: mine ? theme.colorScheme.primary : Colors.white.withValues(alpha: 0.94),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(mine ? 12 : 3),
            bottomRight: Radius.circular(mine ? 3 : 12),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: mine ? Colors.white : Colors.black87,
          ),
        ),
      );

  Widget _preview(ChatBackground bg, ThemeData theme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 152,
        child: Stack(
          children: [
            Positioned.fill(child: ChatBackgroundView(bg: bg)),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bubble('今天怎么这么安静', false, theme),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _bubble('刚到家 累', true, theme),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _bubble('吃饭了没啊', false, theme),
                  ),
                  const Spacer(),
                  Text(
                    '预览',
                    style: TextStyle(
                      fontSize: 10,
                      color: bg.isPreset && bg.presetId == 'night'
                          ? Colors.white54
                          : Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile({
    required String id,
    required String label,
    required List<Color> colors,
    required bool selected,
    required VoidCallback onTap,
    bool plain = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: plain ? const Color(0xFFFBF7FA) : null,
                gradient: plain
                    ? null
                    : LinearGradient(
                        colors: colors,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.shade300,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: selected
                  ? Icon(Icons.check_circle_rounded,
                      size: 20, color: Theme.of(context).colorScheme.primary)
                  : null,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade700,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = context.watch<AppState>().chatBg;

    return Scaffold(
      appBar: AppBar(title: const Text('聊天背景')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          _preview(bg, theme),
          const SizedBox(height: 20),
          Text('预设', style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          SizedBox(
            height: 190,
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.92,
              children: [
                _tile(
                  id: 'none',
                  label: '默认',
                  colors: const [],
                  plain: true,
                  selected: bg.type == 'none',
                  onTap: () => _apply(ChatBackground.initial),
                ),
                for (final p in ChatPresets.all)
                  _tile(
                    id: p.id,
                    label: p.label,
                    colors: p.colors,
                    selected: bg.isPreset && bg.presetId == p.id,
                    onTap: () => _apply(ChatBackground(
                      type: 'preset',
                      presetId: p.id,
                    )),
                  ),
              ],
            ),
          ),
          const Divider(height: 32),
          Text('用自己的图', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '从相册挑一张，会铺满整个聊天背景。图越花，把下面的「雾面」调厚一点，字就越清楚。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.grey.shade600, height: 1.6),
          ),
          const SizedBox(height: 12),
          if (bg.isImage) ...[
            Text('雾面厚度：${(bg.veil * 100).round()}%'),
            Slider(
              value: bg.veil.clamp(0.0, 0.85),
              min: 0,
              max: 0.85,
              divisions: 17,
              label: '${(bg.veil * 100).round()}%',
              onChanged: (v) => _apply(bg.copyWith(veil: v)),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _pickImage,
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('换一张'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _removeImage,
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: const Text('恢复默认'),
                  ),
                ),
              ],
            ),
          ] else
            FilledButton.icon(
              onPressed: _busy ? null : _pickImage,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.photo_library_outlined, size: 18),
              label: Text(_busy ? '正在处理…' : '从相册选一张'),
            ),
          const SizedBox(height: 24),
          Text(
            '背景只影响你自己的观感，不会发给模型，也不会影响她说什么。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.grey.shade600, height: 1.6),
          ),
        ],
      ),
    );
  }
}
