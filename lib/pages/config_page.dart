import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// 配置门禁：先填 Key，再真测一次链接，通了才准进人设。
class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key});

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  final _key = TextEditingController();
  bool _obscure = true;
  bool _testing = false;
  bool _ok = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 设置页改过 Key 的话，回到这里要重新测
    _key.text = '';
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final key = _key.text.trim();
    if (key.isEmpty) {
      setState(() {
        _ok = false;
        _message = '先把 API Key 填进去';
      });
      return;
    }
    setState(() {
      _testing = true;
      _message = null;
      _ok = false;
    });
    try {
      await context.read<AppState>().testConnection(key);
      if (!mounted) return;
      setState(() {
        _testing = false;
        _ok = true;
        _message = '连上了，DeepSeek 有回应。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _ok = false;
        _message = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  Future<void> _next() async {
    if (!_ok) return;
    await context.read<AppState>().markConfigured(_key.text.trim());
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/persona', (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('第一步 · 先连上')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Icon(Icons.link_rounded,
                  size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 20),
              Text(
                '先把话路接通',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                '这个 App 不会替你存任何账号。\n填一个你自己的 DeepSeek API Key，测一下能不能通，然后我们再去定人。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: Colors.grey.shade600, height: 1.7),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: _key,
                obscureText: _obscure,
                onChanged: (_) {
                  if (_ok || _message != null) {
                    setState(() {
                      _ok = false;
                      _message = null;
                    });
                  }
                },
                decoration: InputDecoration(
                  labelText: 'DeepSeek API Key',
                  hintText: 'sk-...',
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '去 platform.deepseek.com 申请。Key 只存在这台手机，不进 APK、不上传。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey.shade500, height: 1.6),
              ),
              const SizedBox(height: 22),
              OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_check_rounded),
                label: Text(_testing ? '正在测…' : '测试链接'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(50)),
              ),
              if (_message != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _ok
                        ? Colors.green.shade50
                        : theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _ok ? Icons.check_circle_outline : Icons.error_outline,
                        size: 18,
                        color: _ok
                            ? Colors.green.shade700
                            : theme.colorScheme.error,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _message!,
                          style: TextStyle(
                            fontSize: 13,
                            color: _ok
                                ? Colors.green.shade800
                                : theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 26),
              FilledButton(
                onPressed: _ok ? _next : null,
                child: const Text('下一步 · 定人设'),
              ),
              if (!_ok)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    '测试通过后才放行——免得定好人设才发现聊不了。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.grey.shade500),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
