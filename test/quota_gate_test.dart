// QuotaGate 限额闸门（设计 §8.1 / v1.4.1）——Dart 半边对拍 + 单测。
// Node 半边在 peiban-core/test/quota_gate.test.mjs，读同一份 quota-v1.json。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/services/quota_gate.dart';

List<Map<String, dynamic>> _loadCases() {
  final root = Platform.environment['PEIBAN_CORE_DIR'] ?? 'D:/peiban-core';
  final f = File('$root/test/fixtures/quota-v1.json');
  if (!f.existsSync()) {
    throw StateError('找不到跨端唯一 fixture：${f.path}（可设 PEIBAN_CORE_DIR 指向 peiban-core 仓库）');
  }
  final decoded = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  return (decoded['cases'] as List<dynamic>)
      .map((e) => (e as Map<String, dynamic>))
      .toList();
}

void main() {
  test('T01 计数键名常量与限额表（写入方不许另写字符串）', () {
    expect(QuotaKeys.selfLastDistillAt, 'self_last_distill_at');
    expect(QuotaKeys.selfFactWeek, 'self_fact_week');
    expect(QuotaKeys.stateDay, 'state_day');
    expect(QuotaKeys.stateDayCount, 'state_day_count');
    expect(QuotaKeys.noteNeartermDay, 'note_nearterm_day');
    expect(kQuotaLimits['self']!.limit, 1);
    expect(kQuotaLimits['state']!.limit, 4);
    expect(kQuotaLimits['self_fact']!.limit, 3);
    expect(kQuotaLimits['self_note']!.limit, 1);
    expect(kQuotaLimits['note_nearterm']!.limit, 1);
    expect(kQuotaLimits['self_fact']!.period, 'week');
  });

  test('未登记 type 不设限、放行、计数透传', () {
    final r = QuotaGate.allow('message', 7, 9);
    expect(r.allowed, isTrue);
    expect(r.limit, 0);
    expect(r.period, 'none');
    expect(r.nextTodayCount, 7);
    expect(r.nextWeekCount, 9);
    expect(QuotaGate.limitFor('never_seen').limit, 0);
  });

  test('跨端 fixture 对拍：同一输入两端判定逐字段一致（含跨天/跨周边界）', () {
    for (final c in _loadCases()) {
      final got = QuotaGate.allow(
        c['type'] as String,
        c['todayCount'] as int,
        c['weekCount'] as int,
      );
      expect(got.allowed, c['allowed'],
          reason: 'allowed 不一致: ${c['type']}/${c['todayCount']}/${c['weekCount']}');
      expect(got.nextTodayCount, c['nextTodayCount'],
          reason: 'nextTodayCount 不一致: ${c['type']}');
      expect(got.nextWeekCount, c['nextWeekCount'],
          reason: 'nextWeekCount 不一致: ${c['type']}');
      expect(got.limit, c['limit'], reason: 'limit 不一致: ${c['type']}');
      expect(got.period, c['period'], reason: 'period 不一致: ${c['type']}');
    }
  });

  test('超限直接丢弃不排队：计数不自增，跨天/跨周重置后可再写', () {
    final denied = QuotaGate.allow('self', 1, 0);
    expect(denied.allowed, isFalse);
    expect(denied.nextTodayCount, 1); // 不是 2
    expect(QuotaGate.allow('self_fact', 0, 3).allowed, isFalse);
    expect(QuotaGate.allow('self_fact', 0, 0).allowed, isTrue);
    expect(QuotaGate.allow('state', 4, 0).allowed, isFalse);
    expect(QuotaGate.allow('state', 0, 0).allowed, isTrue);
  });

  test('脏输入兜底：负数按 0 处理，不抛异常', () {
    final r = QuotaGate.allow('state', -1, 0);
    expect(r.nextTodayCount, 1);
    expect(r.nextWeekCount, 0);
  });
}
