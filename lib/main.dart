import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/chat_page.dart';
import 'pages/settings_page.dart';
import 'pages/welcome_page.dart';
import 'services/proactive_service.dart';
import 'state/app_state.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 通知插件要先初始化，才能在冷启动时读到「是不是被通知点开的」
  await ProactiveService.init();

  final state = AppState();
  await state.load();
  final payload = await ProactiveService.launchPayload();
  final fromNotification = payload == ProactiveService.payload;

  // 每次冷启动顺手把未来 7 天的通知重排一遍，防止系统清掉后再不响
  if (state.companion != null && !fromNotification) {
    await ProactiveService.reschedule(name: state.companion!.name);
  }

  runApp(PeiBanApp(
    state: state,
    launchedFromNotification: fromNotification && state.companion != null,
  ));
}

class PeiBanApp extends StatelessWidget {
  final AppState state;
  final bool launchedFromNotification;

  const PeiBanApp({
    super.key,
    required this.state,
    required this.launchedFromNotification,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        title: '陪伴',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: launchedFromNotification
            ? const ChatPage(autoProactive: true)
            : const WelcomePage(),
        routes: {
          '/': (_) => const WelcomePage(),
          '/chat': (_) => const ChatPage(autoProactive: false),
          '/settings': (_) => const SettingsPage(),
        },
      ),
    );
  }
}
