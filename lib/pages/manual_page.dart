import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db_helper.dart';
import '../data/prefs.dart';
import '../state/app_state.dart';

/// 用户行为记录手册：透明可查、可逐条删。
/// 这里能看到 AI 到底记了什么，记错了就删掉。
class ManualPage extends StatefulWidget {
  const ManualPage({super.key});

  @override
  State<ManualPage> createState() => _ManualPageState();
}

class _ManualPageState extends State<ManualPage> {
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await Prefs.manualEnabled();
    if (!mounted) return;
    setState(() => _enabled = v);
    await context.read<AppState>().refreshNotes();
  }

  Future<void> _toggle(bool v) async {
    await Prefs.setManualEnabled(v);
    if (!mounted) return;
    setState(() => _enabled = v);
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空行为手册？'),
        content: const Text('所有已记录的习惯会删掉，之后重新慢慢记。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await DbHelper.instance.clearNotes();
    await context.read<AppState>().refreshNotes();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final list = s.notes;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('行为记录手册'),
        actions: [
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: list.isEmpty ? null : _clearAll,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withOpacity(0.4),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text(
                '只记「稳定的、值得长期记住的」行为习惯：反复出现的模式、明确说出口的好恶、'
                '身份事实、重要关系和日期。\n\n'
                '临时情绪、一次性闲聊、随口一提、玩笑、证件号银行卡手机号住址这类隐私，'
                '一律不记。AI 先判断，本地还有一票否决的硬规则。\n\n'
                '记错了就在这里删掉。',
                style: TextStyle(height: 1.7, fontSize: 13),
              ),
            ),
          ),
          SwitchListTile(
            value: _enabled,
            title: const Text('继续记录'),
            subtitle: const Text('关掉后 AI 不再往手册里加新条目'),
            onChanged: _toggle,
          ),
          const Divider(height: 1),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text('还没有记到什么\n聊一阵子再看',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.grey.shade500, height: 1.8)),
                  )
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final n = list[i];
                      return ListTile(
                        title: Text(n.content),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '${n.category} · 依据：${n.evidence}\n置信度 ${n.confidence.toStringAsFixed(2)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.grey.shade600, height: 1.5),
                          ),
                        ),
                        isThreeLine: true,
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () async {
                            if (n.id == null) return;
                            await DbHelper.instance.deleteNote(n.id!);
                            if (!mounted) return;
                            await context.read<AppState>().refreshNotes();
                          },
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('当前 ${list.length} 条 · 上限 60 条',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey.shade500)),
          ),
        ],
      ),
    );
  }
}
