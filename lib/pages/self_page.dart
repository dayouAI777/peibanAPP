import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/self_models.dart';
import '../services/self_prompt.dart';
import '../state/app_state.dart';

/// 「她的自我」——R2 自我认知的界面载体（设计 T04 / PRD B6–B10）。
///
/// 完整可独立运行的页面（入口由设置页统一加，见交付报告）：
/// - 顶部「自我摘要」= 当前 self 段（≤360 字）；
/// - 自生长事实列表：每条显示内容 + 生成时间 + 可点开的来源对话 +
///   「涉及你的现实生活」标记（**恒开、不可关**）；
/// - 筛选开关：只看涉及现实生活的；
/// - 单条删除：点了立即消失（本机清单删除，不碰 journal）。
///
/// 已知限制（B10，界面必须如实说）：删除只在本机生效，换机 / 清数据后
/// 删过的事实可能重新长出来；被删条目的明文不进导出、不在此界面展示。
class SelfPage extends StatefulWidget {
  const SelfPage({super.key});

  @override
  State<SelfPage> createState() => _SelfPageState();
}

class _SelfPageState extends State<SelfPage> {
  /// 只看涉及现实生活（筛选开关；与 hardFactGuardEnabled 完全无关）。
  bool _onlyRealLife = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final all = app.selfFacts;
    final shown = _onlyRealLife
        ? all.where((f) => SelfGuard.isRealLifeFact(f.text)).toList()
        : all;
    final realCount = all.where((f) => SelfGuard.isRealLifeFact(f.text)).length;

    return Scaffold(
      appBar: AppBar(title: const Text('她的自我')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          _SummaryCard(text: app.selfBlock),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '她自己长出来的想法 · ${all.length} 条',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              FilterChip(
                label: Text('只看现实生活 ($realCount)'),
                selected: _onlyRealLife,
                onSelected: (v) => setState(() => _onlyRealLife = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '每条都标了来源，点开能看当时那几句。'
            '涉及现实生活的条目恒带标记、可单独删除，删了立刻就不在这一页、也不再进对话。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  _onlyRealLife
                      ? '没有被标记的条目。'
                      : '还没有。她重蒸自我时才会长出新的想法（每 7 天一次，每周最多 3 条）。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, height: 1.7),
                ),
              ),
            )
          else
            ...shown.map(
              (f) => _FactCard(
                fact: f,
                realLife: SelfGuard.isRealLifeFact(f.text),
                onDelete: () => _confirmDelete(context, app, f),
              ),
            ),
          const SizedBox(height: 20),
          Card(
            elevation: 0,
            color: Colors.grey.shade100,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                '关于删除：删掉的条目只记在本机（只有一串编号和时间，没有原文），'
                '不会写进云端、也不会进导出文件。'
                '同一台设备上删了就不再出现；但换手机或清掉 App 数据后，'
                '这份本机记录会丢，删过的想法可能重新长出来——这是已知限制。',
                style: TextStyle(fontSize: 12, color: Colors.black54, height: 1.7),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, AppState app, SelfFact fact) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删掉这一条？'),
        content: Text('「${fact.text}」\n\n删了它立刻不再出现，也不再进对话。'
            '本机生效，换机后可能复现。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await app.deleteSelfFact(fact);
    }
  }
}

class _SummaryCard extends StatelessWidget {
  final String text;
  const _SummaryCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.self_improvement,
                    size: 18, color: Colors.teal.shade600),
                const SizedBox(width: 8),
                const Text('自我摘要',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              text.trim().isEmpty ? '还没有自我描述，等下一次重蒸。' : text,
              style: const TextStyle(height: 1.7, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _FactCard extends StatelessWidget {
  final SelfFact fact;
  final bool realLife;
  final VoidCallback onDelete;

  const _FactCard({
    required this.fact,
    required this.realLife,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final when = fact.createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(fact.createdAt)
        : null;
    final timeText = when == null
        ? ''
        : '${when.year}-${when.month.toString().padLeft(2, '0')}-'
            '${when.day.toString().padLeft(2, '0')} '
            '${when.hour.toString().padLeft(2, '0')}:'
            '${when.minute.toString().padLeft(2, '0')}';
    final src = fact.source;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(fact.text,
                      style: const TextStyle(fontSize: 14, height: 1.5)),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: Colors.grey.shade600,
                  tooltip: '删除这一条',
                  onPressed: onDelete,
                ),
              ],
            ),
            if (realLife)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber.shade300),
                  ),
                  child: Text('涉及你的现实生活',
                      style: TextStyle(
                          fontSize: 11, color: Colors.amber.shade800)),
                ),
              ),
            const SizedBox(height: 4),
            Text(timeText.isEmpty ? '来源时间未知' : '长出来于 $timeText',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey.shade600)),
            const SizedBox(height: 4),
            _SourceLine(source: src),
          ],
        ),
      ),
    );
  }
}

/// 可点开的来源对话：列出 messageKeys 与摘要 key，展开显示当时的原话。
class _SourceLine extends StatelessWidget {
  final SelfSource source;
  const _SourceLine({required this.source});

  @override
  Widget build(BuildContext context) {
    final keys = <String>[...source.messageKeys];
    if (source.chunkKey.trim().isNotEmpty) keys.add(source.chunkKey);
    if (keys.isEmpty && source.quote.trim().isEmpty) {
      return Text('来源：无（这条不会被写进云端）',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade500));
    }
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 8, bottom: 6),
      title: Text('来源对话（${keys.length} 条）',
          style: TextStyle(fontSize: 12, color: Colors.teal.shade700)),
      children: <Widget>[
        if (source.quote.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('当时那句：「${source.quote}」',
                style: const TextStyle(fontSize: 12, height: 1.6)),
          ),
        for (final k in keys)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text('· $k',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ),
      ],
    );
  }
}
