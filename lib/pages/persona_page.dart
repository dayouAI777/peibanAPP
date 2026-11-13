import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/persona_space.dart';
import '../services/persona_analyst.dart';
import '../state/app_state.dart';

/// 人设页：自由输入 → AI 解析、查缺补漏 → 补到齐 → 定稿。
/// 定稿后这份性格不会再变，只能删除重建。
class PersonaPage extends StatefulWidget {
  const PersonaPage({super.key});

  @override
  State<PersonaPage> createState() => _PersonaPageState();
}

class _PersonaPageState extends State<PersonaPage> {
  final _input = TextEditingController();
  String _rawInput = '';
  PersonaSpace _space = PersonaSpace.empty();
  PersonaAnalysis? _analysis;
  String _avatarPath = '';
  bool _busy = false;
  bool _finalizing = false;
  int _rounds = 0;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

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

  Future<void> _analyze() async {
    final extra = _input.text.trim();
    if (_rawInput.isEmpty && extra.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('先随便写点什么，想到哪写到哪就行')));
      return;
    }
    if (extra.isNotEmpty) {
      _rawInput = _rawInput.isEmpty
          ? extra
          : '$_rawInput\n\n【补充】$extra';
      _input.clear();
    }
    setState(() => _busy = true);
    final a = await context.read<AppState>().analyzePersona(_rawInput, _space);
    if (!mounted) return;
    setState(() {
      _analysis = a;
      _space = a.space;
      _busy = false;
      _rounds++;
    });
  }

  Future<void> _finalize() async {
    if (_analysis?.ready != true) return;
    setState(() => _finalizing = true);
    try {
      await context.read<AppState>().finalizePersona(_space, _avatarPath);
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (r) => false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _finalizing = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('定稿失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = _analysis;
    final ready = a?.ready ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('第二步 · 定一个人')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 严肃声明
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text(
                  '人设只有一份，定稿之后性格不会改变。\n'
                  '不满意只能删除重建，不能事后修改——一个人的性格本来就不会轻易变。',
                  style: TextStyle(height: 1.7, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(height: 18),

              // 参考图
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _avatarPath.isNotEmpty &&
                            File(_avatarPath).existsSync()
                        ? Image.file(File(_avatarPath),
                            width: 68, height: 68, fit: BoxFit.cover)
                        : Container(
                            width: 68,
                            height: 68,
                            color: Colors.grey.shade200,
                            child: Icon(Icons.person_outline,
                                color: Colors.grey.shade500),
                          ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickAvatar,
                      icon: const Icon(Icons.image_outlined),
                      label: Text(_avatarPath.isEmpty ? '选一张参考图' : '换一张'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              Text('说说 TA 是个什么样的人',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                '不用填表，想到什么写什么：长相、脾气、说话方式、你们怎么认识的、'
                'TA 会为什么事生气、有什么小习惯……写多写少都行，AI 会读，然后告诉你还缺什么。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey.shade600, height: 1.6),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _input,
                maxLines: 6,
                minLines: 4,
                enabled: !_busy,
                decoration: const InputDecoration(
                  hintText: '比如：她话不多，但记得我说过的每一件小事……',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _analyze,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome_outlined),
                label: Text(_busy
                    ? 'AI 正在读…'
                    : (_rounds == 0 ? '让 AI 读一遍' : '补充后重新分析')),
              ),

              if (a != null) ...[
                const SizedBox(height: 24),
                if (!a.fromModel)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '这次没连上 AI，先按本地规则归了类；检查 Key 和链接后再点一次。',
                      style: TextStyle(
                          color: theme.colorScheme.error, fontSize: 13),
                    ),
                  ),

                // 理解摘要
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('AI 读懂了', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Text(a.understanding,
                          style: const TextStyle(height: 1.7)),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 完整度
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: a.completeness.clamp(0.0, 1.0),
                        minHeight: 8,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text('${a.space.filledCount} / ${PersonaSpace.dimensions.length} 维'),
                  ],
                ),
                const SizedBox(height: 8),
                ExpansionTile(
                  title: const Text('看看已经解析出来的档案'),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    for (final d in PersonaSpace.dimensions)
                      if ((a.space.fields[d.key] ?? '').trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(d.label,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                      color: theme.colorScheme.primary)),
                              const SizedBox(height: 2),
                              Text(a.space.fields[d.key]!,
                                  style: const TextStyle(height: 1.5)),
                            ],
                          ),
                        ),
                  ],
                ),

                // 查缺补漏
                if (a.missing.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('还缺这些，补一补',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  for (final m in a.missing)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('· '),
                          Expanded(
                            child: Text(m.question,
                                style: const TextStyle(height: 1.5)),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    '在上面的框里接着写，再点「补充后重新分析」。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.grey.shade600),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Text('维度已经齐了，可以定稿。',
                      style: TextStyle(color: Colors.green.shade700)),
                ],
              ],

              const SizedBox(height: 26),
              FilledButton(
                onPressed: (ready && !_finalizing) ? _finalize : null,
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                ),
                child: _finalizing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('定稿 · 就是这个人了'),
              ),
              if (!ready)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    a == null
                        ? '先让 AI 读一遍你的描述'
                        : '补齐上面标出的必填维度后才能定稿',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.grey.shade500),
                  ),
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
