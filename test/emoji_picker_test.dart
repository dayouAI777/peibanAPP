import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/data/emoji_kit.dart';
import 'package:peiban_app/data/prefs.dart';
import 'package:peiban_app/models/companion.dart';
import 'package:peiban_app/pages/chat_page.dart';
import 'package:peiban_app/state/app_state.dart';
import 'package:peiban_app/theme.dart';
import 'package:peiban_app/widgets/emoji_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('常用按频次排，同频按最近选择排，忽略无效历史', () {
    expect(
      EmojiKit.frequent(['🤣', '👌', '😄', '😄', 'obsolete']),
      ['😄', '🤣', '👌'],
    );
    expect(EmojiKit.all.length, greaterThanOrEqualTo(400));
    expect(EmojiKit.all.toSet(), hasLength(EmojiKit.all.length));
  });

  testWidgets('聊天表情可筛选，替换选区后常用跨重开保留', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState()
          ..companion = const Companion(
            name: '禾禾',
            persona: '',
            greeting: '',
            avatarPath: '',
            createdAt: 0,
          ),
        child: MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.3),
            ),
            child: child!,
          ),
          home: const ChatPage(),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '甲xy乙');
    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!;
    controller.selection = const TextSelection(baseOffset: 3, extentOffset: 1);

    Future<void> tap(Finder target) async {
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    await tap(find.byTooltip('表情'));
    expect(find.text('常用'), findsOneWidget);
    expect(find.text('总览'), findsOneWidget);
    expect(find.text('笑脸与情绪'), findsOneWidget);
    await tap(find.text('常用'));
    expect(find.text('去总览选表情'), findsOneWidget);
    await tap(find.text('去总览选表情'));

    await tap(find.byTooltip('选择表情分类'));
    expect(find.text('全部分类'), findsOneWidget);
    await tap(find.text('美食与饮品'));
    expect(find.text('🍎'), findsOneWidget);
    await tap(find.text('🍎'));
    expect(controller.text, '甲🍎乙');
    expect(controller.selection.baseOffset, '甲🍎'.length);
    await tap(find.text('🍎'));
    expect(controller.text, '甲🍎🍎乙');
    expect(await Prefs.emojiHistory(), ['🍎', '🍎']);

    await tap(find.byTooltip('收起表情'));
    expect(find.byType(EmojiPicker), findsNothing);
    await tap(find.byTooltip('表情'));
    expect(find.text('🍎'), findsOneWidget);
    expect(find.text('笑脸与情绪'), findsNothing);
    await tap(find.text('总览'));
    expect(find.text('笑脸与情绪'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 350));
  });
}
