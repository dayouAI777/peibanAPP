import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/data/emoji_kit.dart';
import 'package:peiban_app/models/persona_space.dart';
import 'package:peiban_app/models/user_note.dart';
import 'package:peiban_app/services/context_builder.dart';
import 'package:peiban_app/services/persona_analyst.dart';
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
    expect(system.contains('偶尔用表情'), isTrue);
  });

  test('表情库分类齐全且无重复', () {
    expect(EmojiKit.groups.length, 8);
    expect(EmojiKit.all.toSet().length, EmojiKit.all.length);
    expect(EmojiKit.aiRules(0).contains('不要用任何表情'), isTrue);
  });
}
