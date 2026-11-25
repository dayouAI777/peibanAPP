import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/proactive_diag.dart';
import '../services/proactive_service.dart';
import '../state/app_state.dart';

/// 主动消息诊断页（T02 · R1 第一步）。
///
/// 只显示 `proactive_debug` 里采到的原始证据；这里不修调度、不申请权限，
/// 唯一会「做事」的按钮是「测试一条（3 分钟后）」，用于验证通知通道是否通。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  ProactiveDiagSnapshot? _snap;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final snap = await ProactiveDiag.load();
    if (!mounted) return;
    setState(() {
      _snap = snap;
      _loading = false;
    });
  }

  /// 只重读系统状态，不申请权限、不动排程。
  Future<void> _refreshEnvironment() async {
    try {
      await ProactiveService.init();
      await ProactiveDiag.collectEnvironment(plugin: ProactiveService.plugin);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读取系统状态失败：$e')),
      );
    }
    await _load();
  }

  /// A2：真的排一条 3 分钟后的通知，用同一通道、同一时段文案池。
  Future<void> _sendTest() async {
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final name = context.read<AppState>().companion?.name ?? 'TA';
      await ProactiveService.testIn3Minutes(name: name);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        content: Text('已排一条 3 分钟后的通知；权限未开时系统不会显示，请看上方状态'),
      ));
      await _load();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('测试排程失败：$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _snap;

    return Scaffold(
      appBar: AppBar(
        title: const Text('主动消息诊断'),
        actions: [
          IconButton(
            tooltip: '重读权限与通道状态',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refreshEnvironment,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '本页只读本机 proactive_debug 的观测记录，不改调度。'
              '先在这里看真实证据，3~7 天后再决定怎么修。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.grey.shade600, height: 1.6),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (s == null)
              _Notice(
                text: '尚无观测记录',
                detail: '打开 App 让主动消息重排一次，再点右上角刷新。',
                color: Colors.orange.shade700,
              )
            else ...[
              if (s.scheduled == 0)
                _Notice(
                  text: ProactiveDiag.scheduledLabel(s.scheduled),
                  detail: '计划 ${s.planned} 条，但插件一条都没排成功。'
                      '先看下面「最近错误」和「通知权限」。',
                  color: theme.colorScheme.error,
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('调度证据（原样显示，不美化）',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      _DiagRow('通知权限 permissionState',
                          ProactiveDiag.display(s.permissionState)),
                      _DiagRow('精确闹钟权限 exactAlarm',
                          ProactiveDiag.display(s.exactAlarm)),
                      _DiagRow('通知通道重要性 channelImportance',
                          ProactiveDiag.display(s.channelImportance)),
                      _DiagRow('计划了几条 planned', '${s.planned} 条'),
                      _DiagRow(
                        '排程成功几条 scheduled',
                        ProactiveDiag.scheduledLabel(s.scheduled),
                        emphasize: s.scheduled == 0,
                      ),
                      _DiagRow('计划时刻 plannedTimes',
                          ProactiveDiag.displayTimes(s.plannedTimes)),
                      _DiagRow('下次触发 nextFireAt',
                          ProactiveDiag.display(s.nextFireAt)),
                      _DiagRow('上次触发 lastFiredAt',
                          ProactiveDiag.display(s.lastFiredAt)),
                      _DiagRow('最近错误 lastError',
                          ProactiveDiag.display(s.lastError)),
                      const Divider(height: 20),
                      Text('旁证（PRD L4）', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 6),
                      _DiagRow('上次开始重排 lastScheduleAt',
                          ProactiveDiag.display(s.lastScheduleAt)),
                      _DiagRow('本轮目标条数 targetCount', '${s.targetCount} 条'),
                      _DiagRow('排成功的时刻 scheduledTimes',
                          ProactiveDiag.displayTimes(s.scheduledTimes)),
                      _DiagRow('pushplus 状态（token 已脱敏）',
                          ProactiveDiag.display(s.pushplusState)),
                      _DiagRow('测试条排程时刻',
                          ProactiveDiag.display(s.testScheduledAt)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _sending ? null : _sendTest,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.notifications_active_outlined),
                label: const Text('测试一条（3 分钟后）'),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              '口径说明：「上次触发」记的是用户点了通知（前台点按 / 冷启动点开）的时刻，'
              '本轮没有原生回执，不能当成系统实际投递时刻。'
              '「精确闹钟权限」原生读取尚未接入（设计留到 T03），因此显示未接入，不猜。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.grey.shade600, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasize;

  const _DiagRow(this.label, this.value, {this.emphasize = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: Colors.grey.shade700)),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: emphasize ? theme.colorScheme.error : null,
              fontWeight: emphasize ? FontWeight.bold : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final String text;
  final String detail;
  final Color color;

  const _Notice({
    required this.text,
    required this.detail,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text,
              style: TextStyle(
                  color: color, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(detail, style: TextStyle(color: color, height: 1.5)),
        ],
      ),
    );
  }
}
