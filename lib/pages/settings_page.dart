import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/emoji_kit.dart';
import '../data/prefs.dart';
import '../models/update_info.dart';
import '../services/update_service.dart';
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
  bool _testing = false;
  bool _checking = false;

  late ProactiveSettings _s;
  double _temperature = 1.25;
  int _emojiLevel = 1;
  int _contextWindow = 1000;
  bool _manualEnabled = true;
  bool _autoUpdate = true;
  String _versionText = '—';
  String? _testMessage;
  bool _testOk = false;

  final _updateService = UpdateService();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _key.text = await Prefs.apiKey();
    _s = await Prefs.proactiveSettings();
    _temperature = await Prefs.temperature();
    _emojiLevel = await Prefs.emojiLevel();
    _contextWindow = await Prefs.contextLimit();
    _manualEnabled = await Prefs.manualEnabled();
    _autoUpdate = await Prefs.autoUpdateCheck();
    final v = await _updateService.localVersion();
    if (!mounted) return;
    setState(() {
      _versionText = '${v.version}+${v.build}';
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    try {
      await context.read<AppState>().testConnection(_key.text.trim());
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = true;
        _testMessage = '连上了';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testMessage = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await Prefs.setApiKey(_key.text);
    await Prefs.saveProactiveSettings(_s);
    await Prefs.setTemperature(_temperature);
    await Prefs.setEmojiLevel(_emojiLevel);
    await Prefs.setContextLimit(_contextWindow);
    await Prefs.setManualEnabled(_manualEnabled);
    await Prefs.setAutoUpdateCheck(_autoUpdate);
    await context.read<AppState>().applySettings();
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('存好了，通知时间也重新排过了')));
  }

  Future<void> _checkUpdate({bool manual = false}) async {
    setState(() => _checking = true);
    final r = await _updateService.check();
    if (!mounted) return;
    setState(() => _checking = false);
    if (r.hasUpdate && r.info != null) {
      _showUpdate(r.info!);
    } else if (manual) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r.error != null
            ? '检查失败：${r.error}'
            : '已是最新版 ${r.local.version}+${r.local.build}'),
      ));
    }
  }

  void _showUpdate(UpdateInfo info) {
    var downloading = false;
    var received = 0;
    var total = 0;
    String? err;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('新版 ${info.version}',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text('发布于 ${info.publishedAt} · 当前 $_versionText',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 16),
                for (final line in info.changelog)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('·  '),
                        Expanded(child: Text(line)),
                      ],
                    ),
                  ),
                if (downloading) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: total > 0 ? received / total : null,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    total > 0
                        ? '${(received / 1024 / 1024).toStringAsFixed(1)} / ${(total / 1024 / 1024).toStringAsFixed(1)} MB'
                        : '正在连接…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (err != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(err!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 13)),
                  ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: downloading
                      ? null
                      : () async {
                          setSheet(() {
                            downloading = true;
                            err = null;
                          });
                          try {
                            final path = await _updateService.download(
                              info.apkUrl,
                              (r, t) => setSheet(() {
                                received = r;
                                total = t;
                              }),
                            );
                            await _updateService.install(path);
                          } catch (e) {
                            setSheet(() {
                              downloading = false;
                              err = e.toString().replaceAll('Exception: ', '');
                            });
                          }
                        },
                  child: Text(downloading ? '下载中…' : '下载并安装'),
                ),
                TextButton(
                  onPressed: () async {
                    await Prefs.setIgnoredBuild(info.build);
                    if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                  },
                  child: const Text('忽略这个版本'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirm(
      String title, String body, Future<void> Function() run) async {
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
          DropdownMenuItem(
              value: h,
              child: Text('${h.toString().padLeft(2, '0')}:00')),
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
          // ——— 在线升级 ———
          Text('版本与升级', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.system_update_alt_rounded),
            title: Text('当前版本 $_versionText'),
            subtitle: const Text('版本清单托管在 GitHub 仓库的 version.json'),
            trailing: _checking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right),
            onTap: _checking ? null : () => _checkUpdate(manual: true),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _autoUpdate,
            title: const Text('启动时自动检查更新'),
            onChanged: (v) => setState(() => _autoUpdate = v),
          ),
          const Divider(height: 28),

          // ——— 连接 ———
          Text('DeepSeek API Key', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _key,
            obscureText: _obscure,
            onChanged: (_) => setState(() {
              _testOk = false;
              _testMessage = null;
            }),
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
          OutlinedButton.icon(
            onPressed: _testing ? null : _test,
            icon: const Icon(Icons.network_check_rounded, size: 18),
            label: Text(_testing ? '测试中…' : '测试链接'),
          ),
          if (_testMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _testMessage!,
                style: TextStyle(
                    fontSize: 13,
                    color: _testOk
                        ? Colors.green.shade700
                        : theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'Key 只存在这台手机上。把 APK 发给朋友时，对方填自己的 Key。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.grey.shade600, height: 1.6),
          ),
          const Divider(height: 28),

          // ——— 聊天与记忆 ———
          Text('聊天与记忆', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('TA 用表情：${EmojiKit.labelOf(_emojiLevel)}'),
          DropdownButton<int>(
            value: _emojiLevel,
            isExpanded: true,
            items: const [
              DropdownMenuItem(value: 0, child: Text('不用表情')),
              DropdownMenuItem(value: 1, child: Text('偶尔用（默认）')),
              DropdownMenuItem(value: 2, child: Text('常用')),
            ],
            onChanged: (v) => setState(() => _emojiLevel = v ?? 1),
          ),
          const SizedBox(height: 12),
          Text('记忆窗口：最近 $_contextWindow 句'),
          Slider(
            value: _contextWindow.toDouble(),
            min: 200,
            max: 5000,
            divisions: 24,
            label: '$_contextWindow 句',
            onChanged: (v) =>
                setState(() => _contextWindow = v.round()),
          ),
          Text(
            '窗口内的对话都记得住；更早的会由 AI 压成摘要长期带着，不会丢，也不会每次把上千句原文全发出去。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.grey.shade600, height: 1.6),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _manualEnabled,
            title: const Text('记录我的行为习惯'),
            subtitle: const Text('AI 判断 + 内置规则，只记稳定的习惯'),
            onChanged: (v) => setState(() => _manualEnabled = v),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('查看行为记录手册'),
            subtitle: const Text('能看到记了什么，也能逐条删'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/manual'),
          ),
          const Divider(height: 28),

          // ——— 主动消息 ———
          Text('主动消息', style: theme.textTheme.titleMedium),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _s.enabled,
            title: const Text('偶尔让 TA 主动找我'),
            subtitle: const Text('预约本地通知，点开后现场生成一句话'),
            onChanged: (v) => setState(() => _s = ProactiveSettings(
                  enabled: v,
                  perDay: _s.perDay,
                  startHour: _s.startHour,
                  endHour: _s.endHour,
                )),
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
                  onChanged: (v) => setState(() => _s = ProactiveSettings(
                        enabled: true,
                        perDay: v ?? 1,
                        startHour: _s.startHour,
                        endHour: _s.endHour,
                      )),
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
                  onChanged: (v) => setState(() => _s = ProactiveSettings(
                        enabled: true,
                        perDay: _s.perDay,
                        startHour: v ?? 9,
                        endHour: _s.endHour > (v ?? 9) ? _s.endHour : (v ?? 9) + 1,
                      )),
                ),
                const Text(' — '),
                DropdownButton<int>(
                  value: _s.endHour > 24 ? 24 : _s.endHour,
                  items: _hours(1, 24),
                  onChanged: (v) => setState(() => _s = ProactiveSettings(
                        enabled: true,
                        perDay: _s.perDay,
                        startHour: _s.startHour,
                        endHour: (v ?? 23) > _s.startHour
                            ? (v ?? 23)
                            : _s.startHour + 1,
                      )),
                ),
              ],
            ),
          ],
          const Divider(height: 28),

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
          const SizedBox(height: 20),
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
            leading: const Icon(Icons.article_outlined),
            title: const Text('查看人设档案（只读）'),
            subtitle: const Text('定稿后不能改'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/home'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('清空聊天记录'),
            subtitle: const Text('人设、行为手册保留，压缩摘要会一起清掉'),
            onTap: () => _confirm('清空聊天记录？', '之前的对话会全部删掉，不能恢复。',
                () => context.read<AppState>().clearMessages()),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.person_remove_outlined,
                color: theme.colorScheme.error),
            title: Text('删除重建',
                style: TextStyle(color: theme.colorScheme.error)),
            subtitle: const Text('人设、聊天、摘要、行为手册一起清空，配置保留'),
            onTap: () => _confirm(
              '删除这个人，重新定？',
              '人设定稿后不能改，删除是唯一重来的办法。所有记录会清空，无法恢复。',
              () async {
                await context.read<AppState>().deleteCompanion();
                if (!mounted) return;
                Navigator.of(context)
                    .pushNamedAndRemoveUntil('/persona', (route) => false);
              },
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
