import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/data/prefs.dart';
import 'package:peiban_app/services/proactive_diag.dart';

void main() {
  group('T02 主动消息纯观测', () {
    test('九个诊断字段原样落盘、原样读回', () {
      const original = ProactiveDiagSnapshot(
        permissionState: '未开启',
        exactAlarm: '未接入',
        channelImportance: 'none（值 0）',
        planned: 7,
        scheduled: 0,
        plannedTimes: ['2026-11-17 09:12:00'],
        nextFireAt: '无（没有排程成功或已全部过期）',
        lastFiredAt: '尚无记录',
        lastError: '排程失败：MissingPluginException',
      );
      final decoded = ProactiveDiagSnapshot.fromJson(original.toJson());
      expect(decoded.permissionState, '未开启');
      expect(decoded.exactAlarm, '未接入');
      expect(decoded.channelImportance, 'none（值 0）');
      expect(decoded.planned, 7);
      expect(decoded.scheduled, 0);
      expect(decoded.plannedTimes, ['2026-11-17 09:12:00']);
      expect(decoded.nextFireAt, '无（没有排程成功或已全部过期）');
      expect(decoded.lastFiredAt, '尚无记录');
      expect(decoded.lastError, '排程失败：MissingPluginException');
    });

    test('坏数据不会伪造出「正常」，只会退回空值', () {
      final bad = ProactiveDiagSnapshot.fromJson(<String, dynamic>{
        'planned': '七条',
        'scheduled': null,
        'plannedTimes': '不是列表',
        'permissionState': 42,
      });
      expect(bad.planned, 0);
      expect(bad.scheduled, 0);
      expect(bad.plannedTimes, isEmpty);
      expect(bad.permissionState, '');
    });

    test('scheduled==0 必须说「0 条：排程没成功」', () {
      expect(ProactiveDiag.scheduledLabel(0), '0 条：排程没成功');
      expect(ProactiveDiag.scheduledLabel(3), '3 条：排程已成功');
      expect(ProactiveDiag.scheduledLabel(0).contains('正常'), isFalse);
    });

    test('没有观测记录时状态行如实说没有', () {
      expect(ProactiveDiag.summary(null), contains('尚无观测记录'));
      final zero = ProactiveDiagSnapshot(planned: 7, scheduled: 0);
      expect(ProactiveDiag.summary(zero), contains('计划 7 条'));
      expect(ProactiveDiag.summary(zero), contains('0 条：排程没成功'));
    });

    test('下次触发只认未来的、已排成功的时刻', () {
      final now = DateTime.now();
      final past = ProactiveDiag.formatTime(now.subtract(const Duration(days: 1)));
      final soon = ProactiveDiag.formatTime(now.add(const Duration(hours: 2)));
      final later = ProactiveDiag.formatTime(now.add(const Duration(hours: 5)));
      expect(ProactiveDiag.nextFireFrom(<String>[past, later, soon]), soon);
      expect(ProactiveDiag.nextFireFrom(<String>[past]),
          '无（没有排程成功或已全部过期）');
      expect(ProactiveDiag.nextFireFrom(const <String>[]),
          '无（没有排程成功或已全部过期）');
    });

    test('空字段显示「尚无记录」，空列表显示「无」，不留白', () {
      expect(ProactiveDiag.display(''), '尚无记录');
      expect(ProactiveDiag.display('   '), '尚无记录');
      expect(ProactiveDiag.display('未开启'), '未开启');
      expect(ProactiveDiag.displayTimes(const <String>[]), '无');
      expect(ProactiveDiag.displayTimes(['09:00', '15:00']), '09:00\n15:00');
    });

    test('观测时间戳格式固定，不依赖 intl', () {
      expect(ProactiveDiag.formatTime(DateTime(2026, 1, 2, 3, 4, 5)),
          '2026-01-02 03:04:05');
    });

    test('诊断里的 pushplus token 一律脱敏', () {
      expect(Prefs.maskPushplusToken('pushplus_abcdefgh'), 'pus***efgh');
      expect(Prefs.maskPushplusToken('1234'), 'pus***');
    });
  });
}
