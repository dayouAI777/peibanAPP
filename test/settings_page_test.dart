import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:peiban_app/pages/settings_page.dart';
import 'package:peiban_app/state/app_state.dart';
import 'package:peiban_app/theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> openSettings(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: '陪伴',
      packageName: 'com.dayouai.peiban.peiban_app',
      version: '1.8.1',
      buildNumber: '2022',
      buildSignature: '',
    );
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.3),
            ),
            child: child!,
          ),
          home: const SettingsPage(),
          routes: {
            '/diagnostics': (_) => const Scaffold(body: Text('诊断测试页')),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapLabel(WidgetTester tester, String label) async {
    final target = find.text(label);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('诊断返回后保留其他分类里还没保存的设置', (tester) async {
    await openSettings(tester);

    expect(find.text('DeepSeek API Key'), findsNothing);
    expect(find.text('主动消息诊断'), findsNothing);
    await tapLabel(tester, '连接与模型');
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'draft-key');
    await tapLabel(tester, '连接与模型');
    await tapLabel(tester, '主动消息');
    await tapLabel(tester, '主动消息诊断');
    expect(find.text('诊断测试页'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    await tapLabel(tester, '主动消息');
    await tapLabel(tester, '连接与模型');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'draft-key');
    expect(find.text('保存设置').hitTestable(), findsOneWidget);
  });

  testWidgets('同步导出保留两个入口，清理操作需要再展开一层', (tester) async {
    await openSettings(tester);

    await tapLabel(tester, '同步与导出');
    expect(find.text('导出全部'), findsOneWidget);
    expect(find.text('只导出记忆'), findsOneWidget);
    expect(find.text('清空聊天记录'), findsNothing);
    await tapLabel(tester, '清理与重置');
    expect(find.text('清空聊天记录'), findsOneWidget);
    expect(find.text('删除重建'), findsOneWidget);
  });
}
