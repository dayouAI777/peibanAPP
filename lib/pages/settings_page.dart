import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/prefs.dart';
import '../state/app_state.dart';

/// 设置页。API Key 只写进本机，不进仓库、不进 APK、不上传。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _key = TextEditingController();
  bool _obscure = true;
  bool _loaded = false;
  bool _saving = false;

  late ProactiveSettings _s;
  double _temperature = 1.25;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _key.text = await Prefs.apiKey();
    _s = await Prefs.proactiveSettings();
    _temperature = await Prefs.temperature();
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await Prefs.setApiKey(_key.text);
    await Prefs.saveProactiveSettings(_s);
    await Prefs.setTemperature(_temperature);
    await context.read<AppState>().applySettings();
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('存好了，通知时间也重新排过了')));
  }

  Future<void> _confirm(String title, String body, Future<void> Function() run) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('再想想')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok == true) await run();
  }

  List<DropdownMenuItem<int>> _hours(int from, int to) => [
        for (int h = from; h <= to; h++)
          DropdownMenuItem(value: h, child: Text('${h.toString().padLeft(2, '0')}:00')),
      ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text('DeepSeek API Key', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _key,
            obscureText: _obscure,
            decoration: InputDecoration(
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
            'Key 只存在这台手机上，不会上传到任何地方。\n'
            '把 APK 发给朋友时，对方填自己的 Key 就行。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.grey.shade600, height: 1.6),
          ),
          const Divider(height: 32),

          Text('主动消息', style: theme.textTheme.titleMedium),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _s.enabled,
            title: const Text('偶尔让 TA 主动找我'),
            subtitle: const Text('预约本地通知，点开后现场生成一句话'),
            onChanged: (v) => setState(
              () => _s = ProactiveSettings(
                enabled: v,
                perDay: _s.perDay,
                startHour: _s.startHour,
                endHour: _s.endHour,
              ),
            ),
          ),
          if (_s.enabled) ...[
            Row(
              children: [
                const Text('每天'),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: _s.perDay,
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1 条')),
                    DropdownMenuItem(value: 2, child: Text('2 条')),
                    DropdownMenuItem(value: 3, child: Text('3 条')),
                  ],
                  onChanged: (v) => setState(
                    () => _s = ProactiveSettings(
                      enabled: true,
                      perDay: v ?? 1,
                      startHour: _s.startHour,
                      endHour: _s.endHour,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('时段'),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: _s.startHour,
                  items: _hours(0, 22),
                  onChanged: (v) => setState(
                    () => _s = ProactiveSettings(
                      enabled: true,
                      perDay: _s.perDay,
                      startHour: v ?? 9,
                      endHour: _s.endHour > (v ?? 9)
                          ? _s.endHour
                          : (v ?? 9) + 1,
                    ),
                  ),
                ),
                const Text(' — '),
                DropdownButton<int>(
                  value: _s.endHour > 24 ? 24 : _s.endHour,
                  items: _hours(1, 24),
                  onChanged: (v) => setState(
                    () => _s = ProactiveSettings(
                      enabled: true,
                      perDay: _s.perDay,
                      startHour: _s.startHour,
                      endHour: (v ?? 23) > _s.startHour
                          ? (v ?? 23)
                          : _s.startHour + 1,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('时间点每天随机，不是准点闹钟。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey.shade500)),
          ],
          const Divider(height: 32),

          Text('说话的随机度：${_temperature.toStringAsFixed(2)}',
              style: theme.textTheme.titleMedium),
          Slider(
            value: _temperature,
            min: 0.7,
            max: 1.5,
            divisions: 8,
            label: _temperature.toStringAsFixed(2),
            onChanged: (v) => setState(() => _temperature = v),
          ),
          Text('越大越跳脱、越有人味；太小会变得公事公办。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.grey.shade500)),
          const SizedBox(height: 24),

          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存设置'),
          ),
          const Divider(height: 36),

          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('清空聊天记录'),
            subtitle: const Text('角色和设定保留'),
            onTap: () => _confirm('清空聊天记录？', '之前的对话会全部删掉，不能恢复。',
                () => context.read<AppState>().clearMessages()),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.person_remove_outlined,
                color: theme.colorScheme.error),
            title: Text('删除这个 TA',
                style: TextStyle(color: theme.colorScheme.error)),
            subtitle: const Text('角色、设定、聊天记录、排好的通知一起清掉'),
            onTap: () => _confirm('删除这个 TA？', '所有聊天记录和设定都会消失，不能恢复。',
                () async {
              await context.read<AppState>().deleteCompanion();
              if (!mounted) return;
              Navigator.of(context)
                  .pushNamedAndRemoveUntil('/', (route) => false);
            }),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
