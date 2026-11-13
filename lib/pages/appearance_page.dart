import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// 只改外观：头像 + 昵称。
/// 性格、说话方式、共同经历等人设内容定稿后不可改，这个页面碰都不碰它们。
class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key});

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  final _name = TextEditingController();
  String _avatarPath = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final c = context.read<AppState>().companion;
    _name.text = c?.name ?? '';
    _avatarPath = c?.avatarPath ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _hasAvatar =>
      _avatarPath.isNotEmpty && File(_avatarPath).existsSync();

  Future<void> _pickAvatar() async {
    try {
      final x = await ImagePicker()
          .pickImage(source: ImageSource.gallery, maxWidth: 1200, imageQuality: 88);
      if (x == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory(p.join(dir.path, 'avatars'));
      if (!await folder.exists()) await folder.create(recursive: true);
      final target = p.join(
          folder.path, 'companion_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(x.path).copy(target);
      if (!mounted) return;
      setState(() => _avatarPath = target);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('选图失败：$e')));
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('昵称不能空着')));
      return;
    }
    setState(() => _saving = true);
    await context.read<AppState>().updateAppearance(
          name: name,
          avatarPath: _avatarPath,
        );
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('头像与昵称')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text(
                  '这里只能改头像和昵称。\n'
                  '性格、说话方式、共同经历、雷区这些人设内容定稿后不会变，也不在这里改。',
                  style: TextStyle(height: 1.7),
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: _hasAvatar
                      ? Image.file(File(_avatarPath),
                          width: 128,
                          height: 128,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _placeholder())
                      : _placeholder(),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _pickAvatar,
                icon: const Icon(Icons.image_outlined),
                label: Text(_hasAvatar ? '换一张头像' : '选一张头像'),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '昵称',
                  hintText: 'TA 叫什么',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '改完昵称，主动消息通知的标题也会跟着变。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey.shade600),
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder() => Container(
        width: 128,
        height: 128,
        color: Colors.grey.shade200,
        child: Icon(Icons.person_outline,
            size: 48, color: Colors.grey.shade500),
      );
}
