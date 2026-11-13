import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/appearance_page.dart';
import 'pages/background_page.dart';
import 'pages/chat_page.dart';
import 'pages/config_page.dart';
import 'pages/home_page.dart';
import 'pages/manual_page.dart';
import 'pages/persona_page.dart';
import 'pages/settings_page.dart';
import 'pages/style_examples_page.dart';
import 'services/proactive_service.dart';
import 'services/silent_updater.dart';
import 'state/app_state.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 通知插件要先初始化，冷启动才能读到「是不是被通知点开的」
  await ProactiveService.init();

  final state = AppState();
  await state.load();

  final payload = await ProactiveService.launchPayload();
  final fromNotification = payload == ProactiveService.payload;

  // 每次冷启动顺手重排未来 7 天的通知
  if (state.companion != null && !fromNotification) {
    await ProactiveService.reschedule(name: state.companion!.name);
  }

  runApp(PeiBanApp(
    state: state,
    launchedFromNotification: fromNotification && state.companion != null,
  ));

  // 界面先出来，升级的事在后台慢慢做：查版本 → 下安装包 → 等用户点安装。
  // 不 await，不挡首帧，失败完全静默。
  SilentUpdater.instance.autoStart();
}

class PeiBanApp extends StatelessWidget {
  final AppState state;
  final bool launchedFromNotification;

  const PeiBanApp({
    super.key,
    required this.state,
    required this.launchedFromNotification,
  });

  /// 顺序就是这个 App 的规矩：先配置 → 测链接 → 定人设 → 才进聊天。
  Widget _initialPage() {
    if (!state.configured) return const ConfigPage();
    if (state.companion == null) return const PersonaPage();
    if (launchedFromNotification) return const ChatPage(autoProactive: true);
    return const HomePage();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        title: '陪伴',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: _initialPage(),
        routes: {
          '/config': (_) => const ConfigPage(),
          '/persona': (_) => const PersonaPage(),
          '/home': (_) => const HomePage(),
          '/chat': (_) => const ChatPage(autoProactive: false),
          '/settings': (_) => const SettingsPage(),
          '/manual': (_) => const ManualPage(),
          '/appearance': (_) => const AppearancePage(),
          '/background': (_) => const BackgroundPage(),
          '/style-examples': (_) => const StyleExamplesPage(),
        },
      ),
    );
  }
}
