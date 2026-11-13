import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/data/emoji_kit.dart';
import 'package:peiban_app/models/chat_background.dart';
import 'package:peiban_app/models/life_state.dart';
import 'package:peiban_app/models/message.dart';
import 'package:peiban_app/models/persona_space.dart';
import 'package:peiban_app/models/style_example.dart';
import 'package:peiban_app/models/user_note.dart';
import 'package:peiban_app/services/clock_service.dart';
import 'package:peiban_app/services/context_builder.dart';
import 'package:peiban_app/services/mood_service.dart';
import 'package:peiban_app/services/persona_analyst.dart';
import 'package:peiban_app/services/update_service.dart';
import 'package:peiban_app/services/user_manual.dart';

void main() {
  test('人设必填维度由本地判定，不能靠模型自己报完成度', () {
    final empty = PersonaSpace.empty();
    expect(empty.isComplete, isFalse);
    expect(empty.missingRequired().length, PersonaSpace.requiredKeys.length);

    final full = PersonaSpace(fields: {
      for (final k in PersonaSpace.requiredKeys) k: '这是一段足够长的内容',
    });
    expect(full.isComplete, isTrue);
  });

  test('断网兜底也能拼出可用的人设指令', () {
    final space = PersonaSpace(fields: {
      'name': '阿雾',
      'callUser': '阿澈',
      'personality': '话不多但记得住事',
    });
    final prompt = PersonaAnalyst.localSystemPrompt(space);
    expect(prompt.contains('阿雾'), isTrue);
    expect(prompt.contains('话不多但记得住事'), isTrue);
    expect(prompt.contains('不要旁白'), isTrue);
  });

  test('行为手册硬规则挡掉隐私、临时闲聊和低置信度', () {
    final service = UserManualService();
    final candidates = [
      const ManualCandidate(
          category: '生活习惯',
          content: '习惯每天睡前看半小时书',
          confidence: 0.9,
          evidence: '我习惯睡前看书'),
      const ManualCandidate(
          category: '身份事实',
          content: '我的手机号是13800138000',
          confidence: 0.99,
          evidence: '手机号 13800138000'),
      const ManualCandidate(
          category: '稳定偏好',
          content: '今天有点累想早点睡',
          confidence: 0.95,
          evidence: '今天有点累'),
      const ManualCandidate(
          category: '稳定偏好',
          content: '好像也许可能喜欢喝茶',
          confidence: 0.4,
          evidence: '随便说说'),
      const ManualCandidate(
          category: '不存在的类别',
          content: '这是一条类别不合法的内容',
          confidence: 0.9,
          evidence: '有依据'),
    ];
    final accepted = service.applyRules(candidates, <UserNote>[]);
    expect(accepted.length, 1);
    expect(accepted.first.content, '习惯每天睡前看半小时书');
  });

  test('上下文 system 会带上行为手册、摘要和表情规则', () {
    final system = ContextBuilder.buildSystem(
      persona: '你是阿雾',
      notes: const [
        UserNote(
            category: '生活习惯',
            content: '习惯睡前看书',
            confidence: 0.9,
            evidence: '我习惯睡前看书',
            createdAt: 0),
      ],
      chunks: const [],
      window: 1000,
      emojiLevel: 1,
    );
    expect(system.contains('你是阿雾'), isTrue);
    expect(system.contains('习惯睡前看书'), isTrue);
    expect(system.contains('1000 句'), isTrue);
    expect(system.contains('小表情'), isTrue);
  });

  test('表情库分类齐全且无重复', () {
    expect(EmojiKit.groups.length, 8);
    expect(EmojiKit.all.toSet().length, EmojiKit.all.length);
    expect(EmojiKit.aiRules(0).contains('不要用任何表情'), isTrue);
  });

  test('用户亲手改的说法会进 system，只带最新 12 条', () {
    final examples = [
      for (int i = 0; i < 20; i++)
        StyleExample(
          companionId: 1,
          trigger: '触发$i',
          original: '错$i',
          preferred: '对$i',
          createdAt: i,
        ),
    ];
    final system = ContextBuilder.buildSystem(
      persona: '你是阿雾',
      notes: const [],
      chunks: const [],
      window: 1000,
      styleExamples: examples,
    );
    expect(system.contains('改后'), isTrue);
    expect(system.contains('对19'), isTrue); // 最新的在
    expect(system.contains('对8'), isTrue); // 刚好第 12 条
    expect(system.contains('对7'), isFalse); // 再早的砍掉，别稀释人设
  });

  test('聊天背景读坏了退回默认，图片丢了也不白屏', () {
    expect(ChatBackground.decode('').type, 'none');
    expect(ChatBackground.decode('这不是 json').type, 'none');
    expect(ChatBackground.decode('{"type":"image","image_path":""}').type,
        'none');
    expect(ChatBackground.decode('{"type":"preset","preset_id":"不存在"}').type,
        'none');

    final p = ChatBackground.decode(
        '{"type":"preset","preset_id":"peach","veil":0.4}');
    expect(p.isPreset, isTrue);
    expect(p.veil, 0.4);
    expect(ChatPresets.all.length, greaterThanOrEqualTo(4));
  });

  // ——— 时间感 ———

  test('晚上八点她绝不可能还在上班', () {
    // 2026-11-13 是星期五，20:30
    final now = DateTime(2026, 11, 13, 20, 30);
    final life = ClockService.describe(now: now);
    expect(life.workday, isTrue);
    expect(life.activity.contains('在上班'), isFalse);
    expect(life.activity.contains('加班'), isFalse);
    expect(life.rules.any((r) => r.contains('早就下班')), isTrue);
  });

  test('加班安排生效时才允许晚上待在公司', () {
    final now = DateTime(2026, 11, 13, 20, 30);
    final overtime = LifeEvent(
      kind: 'overtime',
      title: '今晚要加班',
      detail: '临时来了活',
      startMs: DateTime(2026, 11, 13, 18, 30).millisecondsSinceEpoch,
      endMs: DateTime(2026, 11, 13, 22, 30).millisecondsSinceEpoch,
    );
    final life = ClockService.describe(now: now, event: overtime);
    expect(life.activity.contains('加班'), isTrue);
    expect(life.rules.any((r) => r.contains('早就下班')), isFalse);
  });

  test('周末不会说自己在开会通勤，深夜会困', () {
    final sat = ClockService.describe(now: DateTime(2026, 11, 14, 14, 0));
    expect(sat.workday, isFalse);
    expect(sat.rules.any((r) => r.contains('今天是周末')), isTrue);

    final night = ClockService.describe(now: DateTime(2026, 11, 14, 3, 0));
    expect(night.period, '凌晨');
    expect(night.rules.any((r) => r.contains('深夜')), isTrue);
  });

  test('明天的旅行今天不该生效', () {
    final travel = LifeEvent(
      kind: 'travel',
      title: '在大理玩',
      detail: '请了两天假',
      startMs: DateTime(2026, 11, 16, 8).millisecondsSinceEpoch,
      endMs: DateTime(2026, 11, 18, 8).millisecondsSinceEpoch,
    );
    final today = ClockService.describe(now: DateTime(2026, 11, 13, 20), event: travel);
    expect(today.event, isNull);

    final during = ClockService.describe(now: DateTime(2026, 11, 17, 15), event: travel);
    expect(during.event, isNotNull);
    expect(during.rules.any((r) => r.contains('不在家')), isTrue);
  });

  test('隔了好几天不会假装一直在聊', () {
    final almostADay = ClockService.gapRule(
      d: const Duration(hours: 27),
      overnight: false,
      sheSpokeLast: true,
    );
    expect(almostADay.contains('不要假装'), isTrue);

    final long = ClockService.gapRule(
      d: const Duration(days: 9),
      overnight: false,
      sheSpokeLast: false,
    );
    expect(long.contains('9 天'), isTrue);
  });

  test('隔夜不算被冷落，白天隔半天才算', () {
    final last = DateTime(2026, 11, 12, 23, 0);
    final morning = DateTime(2026, 11, 13, 9, 0);
    expect(ClockService.looksLikeOvernight(last, morning), isTrue);

    final afternoon = DateTime(2026, 11, 13, 16, 0);
    expect(ClockService.looksLikeOvernight(last, afternoon), isFalse);
  });

  test('作息类型认得出学生和自由职业', () {
    expect(ClockService.rhythmOf('大四学生', ''), Rhythm.student);
    expect(ClockService.rhythmOf('自由撰稿人', ''), Rhythm.freelance);
    expect(ClockService.rhythmOf('程序员', ''), Rhythm.office);
    expect(ClockService.rhythmOf('护士', '上夜班'), Rhythm.shift);
  });

  // ——— 情绪 ———

  test('被晾十几个小时会生气，隔夜不算', () {
    final afterOvernight = MoodService.syncWithGap(
      const MoodState(),
      gap: const Duration(hours: 9),
      sheSpokeLast: true,
      overnight: true,
    );
    expect(afterOvernight.anger, 0);

    final ignored = MoodService.syncWithGap(
      const MoodState(),
      gap: const Duration(hours: 13),
      sheSpokeLast: true,
      overnight: false,
    );
    expect(ignored.anger, greaterThanOrEqualTo(MoodState.annoyedAt));
    expect(ignored.reason.contains('没回'), isTrue);
  });

  test('syncWithGap 幂等：反复调用不会越骂越气', () {
    var m = const MoodState();
    for (var i = 0; i < 5; i++) {
      m = MoodService.syncWithGap(
        m,
        gap: const Duration(hours: 13),
        sheSpokeLast: true,
        overnight: false,
      );
    }
    expect(m.anger, lessThan(MoodState.coldAt));
  });

  test('骂一句会生气，再补一句就冷战；哄两次才回得来', () {
    var r = MoodService.afterUserMessage(
      const MoodState(),
      text: '滚，别烦我',
      recentUserTexts: const [],
    );
    expect(r.mood.isAngry, isTrue);

    // 再顶一句 → 冷战
    r = MoodService.afterUserMessage(r.mood,
        text: '随便你，懒得跟你说', recentUserTexts: const []);
    expect(r.mood.isCold, isTrue);

    // 第一句哄：离开冷战，还在生气
    r = MoodService.afterUserMessage(r.mood, text: '对不起，我不该那样说',
        recentUserTexts: const []);
    expect(r.coaxed, isTrue);
    expect(r.mood.isCold, isFalse);
    expect(r.mood.isAngry, isTrue);

    // 继续哄：两轮之内必须见好，不然就是耍人
    r = MoodService.afterUserMessage(r.mood, text: '别生气了好不好，我错了',
        recentUserTexts: const []);
    expect(r.mood.anger, lessThan(MoodState.annoyedAt));
    expect(r.justRecovered, isTrue);
  });

  test('连着敷衍会加气，认真解释会消气', () {
    final base = const MoodState(anger: 40);
    final slacked = MoodService.afterUserMessage(base,
        text: '哦', recentUserTexts: const ['嗯', '哦', '行']);
    expect(slacked.mood.anger, greaterThan(40));

    final explained = MoodService.afterUserMessage(base,
        text: '刚在开会手机放桌上了，没看到你消息，别多想啊',
        recentUserTexts: const []);
    expect(explained.mood.anger, lessThan(40));
  });

  test('冷战先甩一个生气表情，再晾着', () {
    expect(MoodService.coldSticker(coldTurns: 1, coaxed: false), '😤');
    expect(MoodService.coldSticker(coldTurns: 2, coaxed: false), isNull);
    expect(MoodService.coldSticker(coldTurns: 1, coaxed: true), '🥺');
  });

  test('生气时 prompt 会带情绪段，平静时不带', () {
    expect(MoodService.promptBlock(const MoodState()), '');
    final block = MoodService.promptBlock(
        const MoodState(anger: 60, reason: '你半天没回我'));
    expect(block.contains('你半天没回我'), isTrue);
    expect(block.contains('不主动关心他'), isTrue);
    expect(block.contains('不许骂人'), isTrue);
  });

  test('只有表情的消息会被当成表情包', () {
    const sticker = ChatMessage(
        companionId: 1, role: 'assistant', content: '😤', createdAt: 0);
    expect(sticker.isSticker, isTrue);

    const text = ChatMessage(
        companionId: 1, role: 'assistant', content: '算了', createdAt: 0);
    expect(text.isSticker, isFalse);
  });

  test('时间块和断层块会进 system', () {
    final system = ContextBuilder.buildSystem(
      persona: '你是阿雾',
      notes: const [],
      chunks: const [],
      window: 1000,
      nowBlock: '【现在】现在是 11月13日 星期五 20:30',
      gapBlock: '上一次说话是 2 天前',
      moodBlock: '【你此刻的情绪】你在生气',
    );
    expect(system.contains('11月13日'), isTrue);
    expect(system.contains('2 天前'), isTrue);
    expect(system.contains('你在生气'), isTrue);
    // 顺序：人设 → 现在 → 情绪，情绪要压在靠后的位置
    expect(system.indexOf('你是阿雾') < system.indexOf('11月13日'), isTrue);
  });

  test('清单竞速挑 build 最大的那份，不听谁的网快', () {
    const stale = '{"version":"1.6.0","build":12}';
    const fresh = '{"version":"1.6.1","build":13}';
    // CDN 先答（旧）也不能用
    expect(UpdateService.newestManifest([stale, fresh]), fresh);
    expect(UpdateService.newestManifest([fresh, stale]), fresh);
    // 只有一份就照用
    expect(UpdateService.newestManifest([stale]), stale);
  });

  test('坏清单不会盖掉好清单', () {
    const good = '{"version":"1.6.1","build":13}';
    expect(UpdateService.buildOf('<html>404</html>'), 0);
    expect(UpdateService.buildOf('{}'), 0);
    expect(UpdateService.newestManifest(['<html>404</html>', good]), good);
  });
}
