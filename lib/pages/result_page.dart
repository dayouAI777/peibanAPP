import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/setup_form.dart';
import '../services/persona_builder.dart';
import '../state/app_state.dart';

/// 生成结果页：先看一眼 TA 长什么样、第一句说什么，满意了再落库。
class ResultPage extends StatefulWidget {
  final SetupForm form;
  final GeneratedPersona draft;

  const ResultPage({super.key, required this.form, required this.draft});

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  late GeneratedPersona _draft;
  bool _busy = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _draft = widget.draft;
  }

  Future<void> _regenerate() async {
    setState(() => _busy = true);
    final next = await context.read<AppState>().generateDraft(widget.form);
    if (!mounted) return;
    setState(() {
      _draft = next;
      _busy = false;
    });
  }

  Future<void> _start() async {
    setState(() => _saving = true);
    await context.read<AppState>().saveCompanion(widget.form, _draft);
    if (!mounted) return;
    Navigator.of(context)
        .pushNamedAndRemoveUntil('/chat', (route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasAvatar = widget.form.avatarPath.isNotEmpty &&
        File(widget.form.avatarPath).existsSync();
    final name = widget.form.name.trim().isEmpty
        ? 'TA'
        : widget.form.name.trim();

    return Scaffold(
      appBar: AppBar(title: const Text('TA 来了')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: hasAvatar
                            ? Image.file(
                                File(widget.form.avatarPath),
                                width: double.infinity,
                                height: 300,
                                fit: BoxFit.cover,
                              )
                            : Container(
                                width: double.infinity,
                                height: 220,
                                color: Colors.grey.shade200,
                                child: Icon(Icons.person_outline,
                                    size: 64, color: Colors.grey.shade500),
                              ),
                      ),
                      const SizedBox(height: 22),
                      Text(name,
                          style: theme.textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: _busy
                            ? const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(12),
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            : Text(_draft.greeting,
                                style: theme.textTheme.bodyLarge
                                    ?.copyWith(height: 1.7)),
                      ),
                      if (!_draft.fromModel) ...[
                        const SizedBox(height: 12),
                        Text(
                          '这次用的是本地模板（可能没填 API Key，或没连上）。\n'
                          '去「设置」填上 Key，回来点「换一句」就能让 DeepSeek 重新写。',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: Colors.grey.shade600, height: 1.6),
                        ),
                      ],
                      const SizedBox(height: 18),
                      ExpansionTile(
                        title: const Text('看看人设是怎么写的'),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(14),
                            child: Text(_draft.persona,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(height: 1.6)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _regenerate,
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                      child: const Text('换一句'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                      child: const Text('改设定'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: (_busy || _saving) ? null : _start,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('就开始聊天吧'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
