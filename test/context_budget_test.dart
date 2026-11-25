import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/models/journal.dart';
import 'package:peiban_app/models/memory_chunk.dart';
import 'package:peiban_app/models/speech_profile.dart';
import 'package:peiban_app/models/user_note.dart';
import 'package:peiban_app/services/context_builder.dart';
import 'package:peiban_app/services/near_term_note_service.dart';
import 'package:peiban_app/services/prompt_budget.dart';
import 'package:peiban_app/services/quota_gate.dart';
import 'package:peiban_app/services/speech_profile_service.dart';

UserNote _note(String category, String content, int createdAt) => UserNote(
      category: category,
      content: content,
      confidence: 0.8,
      evidence: 'e',
      createdAt: createdAt,
    );

/// 造一个固定的乱序输入（保证 createdAt 有重复、有近况、有普通）。
List<UserNote> _shuffledNotes() => <UserNote>[
      _note('稳定偏好', '普通C', 300),
      _note('近况', '近况A', 500),
      _note('生活习惯', '普通A', 100),
      _note('近况', '近况B', 500), // 与近况A 同 ts，靠 key 升序兜底
      _note('身份事实', '普通B', 400),
      _note('近况', '近况C', 200),
      _note('明确好恶', '普通D', 300), // 与普通C 同 ts
    ];

/// 把乱序输入按契约"排好序时应得的结果"独立算一遍（不看实现，按 §6.1 手写）。
List<String> _expectedOrder(List<UserNote> notes,
    {int max = 20, int nearTermMax = 5}) {
  final sorted = [...notes];
  sorted.sort((a, b) {
    final byTime = b.createdAt.compareTo(a.createdAt);
    if (byTime != 0) return byTime;
    final ka = journalKeyForNote(a.category, a.content);
    final kb = journalKeyForNote(b.category, b.content);
    return ka.compareTo(kb);
  });
  final near = <UserNote>[];
  final rest = <UserNote>[];
  final overflowNear = <UserNote>[];
  for (final n in sorted) {
    if (n.category != '近况') {
      rest.add(n);
    } else if (near.length < nearTermMax) {
      near.add(n);
    } else {
      overflowNear.add(n);
    }
  }
  final out = <UserNote>[...near];
  for (final n in rest) {
    if (out.length >= max) break;
    out.add(n);
  }
  for (final n in overflowNear) {
    if (out.length >= max) break;
    out.add(n);
  }
  return out.take(max).map((n) => n.content).toList();
}

/// 造一段旧事摘要（D3 的 baseline 需要「有东西可砍」才谈得上收口）。
MemoryChunk _chunk(String summary, int createdAt) => MemoryChunk(
      companionId: 1,
      fromMessageId: createdAt,
      toMessageId: createdAt + 1,
      summary: summary,
      createdAt: createdAt,
    );

void main() {
  group('§6.1 pickNotes 排序契约（内部排序，乱序输入必须给确定结果）', () {
    test('喂乱序输入 → 输出与"已排好序输入"的结果逐字相同', () {
      final shuffled = _shuffledNotes();
      final preSorted = [...shuffled]
        ..sort((a, b) {
          final byTime = b.createdAt.compareTo(a.createdAt);
          if (byTime != 0) return byTime;
          return journalKeyForNote(a.category, a.content)
              .compareTo(journalKeyForNote(b.category, b.content));
        });

      final outFromShuffled =
          PromptBudget.pickNotes(shuffled).map((n) => n.content).toList();
      final outFromSorted =
          PromptBudget.pickNotes(preSorted).map((n) => n.content).toList();

      expect(outFromShuffled, outFromSorted, reason: '乱序与已排序结果必须一致');
      expect(outFromShuffled, _expectedOrder(shuffled), reason: '与手算契约一致');
    });

    test('排序：createdAt 降序；同 ts 按 note journal key 字典序升序兜底', () {
      final notes = <UserNote>[
        _note('稳定偏好', '同日C', 300),
        _note('稳定偏好', '同日A', 300),
        _note('稳定偏好', '同日B', 300),
        _note('稳定偏好', '较新', 500),
        _note('稳定偏好', '较旧', 100),
      ];
      final out = PromptBudget.pickNotes(notes);
      // 500 最前，100 最后；300 三条按 key 升序
      expect(out.first.content, '较新');
      expect(out.last.content, '较旧');
      final sameDay = out
          .where((n) => n.createdAt == 300)
          .map((n) => n.content)
          .toList();
      final expectedSameDay = ['同日A', '同日B', '同日C']
        ..sort((a, b) => journalKeyForNote('稳定偏好', a)
            .compareTo(journalKeyForNote('稳定偏好', b)));
      expect(sameDay, expectedSameDay);
    });

    test('近况前 ≤5 条优先占位，且不把总数撑超 max', () {
      final notes = <UserNote>[
        for (var i = 0; i < 10; i++) _note('近况', '近况$i', 1000 + i),
        for (var i = 0; i < 20; i++) _note('稳定偏好', '普通$i', i),
      ];
      final out = PromptBudget.pickNotes(notes);
      expect(out.length, PromptBudget.maxNotes, reason: '总数永 ≤20，不是 25');
      final nearCount = out.where((n) => n.category == '近况').length;
      expect(nearCount, PromptBudget.maxNearTermNotes, reason: '近况占位 ≤5');
      // 近况排在前 5（按 createdAt 降序：1009..1005）
      expect(out.take(5).every((n) => n.category == '近况'), isTrue);
    });

    test('近况不足时其它类目补满 20', () {
      final notes = <UserNote>[
        _note('近况', '唯一近况', 9999),
        for (var i = 0; i < 30; i++) _note('稳定偏好', '普通$i', i),
      ];
      final out = PromptBudget.pickNotes(notes);
      expect(out.length, PromptBudget.maxNotes);
      expect(out.first.content, '唯一近况');
    });
  });

  group('B3 self 段 ≤360 字', () {
    test('SelfComposer 之外的拼接也守住 360', () {
      expect(PromptBudget.maxSelfChars, 360);
      expect(PromptBudget.selfWithinBudget('我' * 360), isTrue);
      expect(PromptBudget.selfWithinBudget('我' * 361), isFalse);
    });
  });

  group('D3 prompt 总字数 ≤ baseline × 1.10（不放宽）', () {
    test('withinBaseline 边界：110% 内通过，超出失败', () {
      const baseline = 4000;
      expect(PromptBudget.withinBaseline('a' * 4400, baseline), isTrue); // 恰好 110%
      expect(PromptBudget.withinBaseline('a' * 4401, baseline), isFalse);
      expect(PromptBudget.withinBaseline('a' * 100, 0), isFalse, reason: '非法 baseline 不放行');
    });

    test('砍到线内为止：必须砍掉 ≥2 段才达标时，不能停在"砍光仍超线"', () {
      // 这个场景专门暴露一种错法：**每砍一次就把 cap 用新的（更短的）baseline 重算**。
      // 那样越砍 baseline 越小、cap 越小，砍一条省下的字还不够 cap 缩掉的，数学上
      // 会卡在"砍光了还超线"。正确形状是 cap 在**砍之前**算一次、之后不再变。
      //
      // 构造：摘要小（100 字）× 12 段 ⇒ 单砍 1 段不足以消化超线量（≈240→需 ≥3 段）。
      final notes = <UserNote>[
        for (var i = 0; i < 20; i++) _note('稳定偏好', '笔记内容$i', i),
      ];
      final chunks = <MemoryChunk>[
        for (var i = 0; i < 12; i++) _chunk('第$i段旧事：${'一起聊过的事情' * 11}', i),
      ];
      const speech = SpeechProfile(
        samples: 10,
        sentenceLength: '偏短',
        tone: '随意',
        rhythm: '快',
      );
      final selfText = '我是姜禾，' * 70; // 350 字

      final baseline = ContextBuilder.buildSystem(
        persona: '林小满，一个普通的女孩，' * 30,
        notes: notes,
        chunks: chunks,
        window: 1000,
        speech: speech,
        withNewBlocks: false,
      );
      final withSelf = ContextBuilder.buildSystem(
        persona: '林小满，一个普通的女孩，' * 30,
        notes: notes,
        chunks: chunks,
        window: 1000,
        speech: speech,
        selfBlock: selfText,
      );

      int chunkLines(String s) =>
          RegExp(r'^- 第\d+段旧事', multiLine: true).allMatches(s).length;
      final dropped = chunkLines(baseline) - chunkLines(withSelf);
      expect(dropped >= 2, isTrue, reason: '本例必须砍 ≥2 段（实测砍了 $dropped 段）');
      // ⚠️ 上界断言：这条才是真正抓"每次重算 cap"的东西。
      // 重算版会**越砍越难达标**，一路砍到 12 段全光；而砍光之后的终值必然小于
      // 原始 cap ⇒ 只写 `withinBaseline` 的断言对错版照样全绿（砍得太多也是"达标"）。
      // 所以必须把"砍多少"也钉住：12 段里只需砍 2~4 段。
      expect(dropped, lessThanOrEqualTo(4),
          reason: '重算 cap 会砍光 12 段；cap 砍前只算一次的话只砍 2~4 段（实测 $dropped）');
      expect(chunkLines(withSelf) >= 8, isTrue, reason: '必须还剩 ≥8 段摘要');
      expect(PromptBudget.withinBaseline(withSelf, baseline.length), isTrue,
          reason: '砍完必须真的到线内：${withSelf.length} vs ${baseline.length}');
      // 被砍的是**最旧**的：留下的都是靠后的段落（i 大的）。
      expect(withSelf.contains('第0段旧事'), isFalse, reason: '最旧的先砍');
      expect(withSelf.contains('第11段旧事'), isTrue, reason: '最新的留下');
    });

    test('实拼 prompt：加 self + speech 硬约束后仍 ≤ baseline×1.10（只砍 chunks）', () {
      final notes = <UserNote>[
        for (var i = 0; i < 20; i++) _note('稳定偏好', '笔记内容$i', i),
      ];
      // 有摘要可砍，才谈得上「超线优先砍 chunks」。6 段 × 约 370 字。
      final chunks = <MemoryChunk>[
        for (var i = 0; i < 6; i++)
          _chunk('第$i段旧事：${'我们一起聊过的事情' * 40}', i),
      ];
      const persona = '林小满，一个普通的女孩，';
      final selfText = '我是姜禾，' * 70; // 350 字，未超 360
      const speech = SpeechProfile(
        samples: 10,
        sentenceLength: '偏短',
        tone: '随意',
        catchphrases: <String>['哈哈'],
        rhythm: '快',
      );

      // baseline = 改动前口径（不带 self 段、不带 R5 三行），与实现的收口口径同一个函数。
      final baseline = ContextBuilder.buildSystem(
        persona: persona * 30,
        notes: notes,
        chunks: chunks,
        window: 1000,
        emojiLevel: 2,
        speech: speech,
        withNewBlocks: false,
      );
      final withSelf = ContextBuilder.buildSystem(
        persona: persona * 30,
        notes: notes,
        chunks: chunks,
        window: 1000,
        emojiLevel: 2,
        speech: speech,
        selfBlock: selfText,
      );

      expect(PromptBudget.withinBaseline(withSelf, baseline.length), isTrue,
          reason: 'D3 不放宽：${withSelf.length} vs ${baseline.length}');

      // 允许变少的只有旧事摘要；persona / self / notes 一个字都不许少。
      int chunkLines(String s) =>
          RegExp(r'^- 第\d+段旧事', multiLine: true).allMatches(s).length;
      int noteLines(String s) =>
          RegExp(r'^- \[稳定偏好\]', multiLine: true).allMatches(s).length;
      expect(withSelf.substring(0, 200), baseline.substring(0, 200),
          reason: 'B3：注入前后 prompt 首 200 字必须一致（persona 不动）');
      // ⚠️ 上面这条断言成立的前提：**persona 至少 200 字**（本例 persona 是 390 字）。
      // 谁把 persona 改短，`substring(0, 200)` 会先抛 RangeError——那不是"B3 失败"，
      // 是 fixture 不满足前提。别把它当假警报删掉，改 persona 长度时一起看这里。
      expect(withSelf.contains(selfText), isTrue, reason: 'self 段必须完整，不许为了省字砍它');
      expect(noteLines(withSelf), noteLines(baseline), reason: 'notes 条数不变');
      expect(chunkLines(withSelf) <= chunkLines(baseline), isTrue,
          reason: '只允许砍 chunks');
      expect(chunkLines(withSelf) < chunkLines(baseline), isTrue,
          reason: '本例确实超线，必须真的砍掉最旧的摘要（机制生效）');
    });
  });

  group('E2 prompt 快照含「只对齐节奏」「你和 TA 是两个人」', () {
    test('speech 硬约束注入 prompt 快照', () {
      final prompt = ContextBuilder.buildSystem(
        persona: '林小满',
        notes: const [],
        chunks: const [],
        window: 1000,
        speech: const SpeechProfile(
          samples: 5,
          sentenceLength: '偏短',
          tone: '随意',
          rhythm: '快',
        ),
      );
      expect(prompt.contains('只对齐节奏'), isTrue);
      // 断言跟着句子走：句子里写的是「你和 TA 是两个人」，就断言这一句。
      expect(prompt.contains('你和 TA 是两个人'), isTrue);
      expect(prompt.contains('和上面的自我描述冲突时，以你自己的描述为准。'), isTrue);
    });

    test('R5 裁决顺序写进 prompt', () {
      final prompt = ContextBuilder.buildSystem(
        persona: '林小满',
        notes: const [],
        chunks: const [],
        window: 1000,
      );
      expect(prompt.contains('style_example > self > style_profile > speech_profile'),
          isTrue);
    });
  });

  group('R4 近况 note：时间窗 + 当天只试一次 + QuotaGate（note_nearterm ≤1/天）', () {
    test('shouldAttempt：20 点前不生成，20 点后才生成', () {
      final sameDay = DateTime(2026, 11, 13, 20, 5);
      final before20 = DateTime(2026, 11, 13, 19, 59);
      expect(NearTermNoteService.shouldAttempt(now: before20, lastDayKey: ''),
          isFalse);
      expect(
          NearTermNoteService.shouldAttempt(now: sameDay, lastDayKey: ''), isTrue);
      expect(NearTermNoteService.kNearTermHour, 20);
    });

    test('shouldAttempt：同一天只尝试一次（哪怕模型失败也不反复重试）', () {
      final t = DateTime(2026, 11, 13, 21, 0);
      expect(NearTermNoteService.shouldAttempt(now: t, lastDayKey: '20261113'),
          isFalse);
      // 隔天又能试
      expect(NearTermNoteService.shouldAttempt(now: t, lastDayKey: '20261112'),
          isTrue);
    });

    test('写前必须过闸：note_nearterm 一天只放行一次，超限直接丢弃不自增', () {
      expect(QuotaGate.limitFor('note_nearterm'), const QuotaRule(1, 'day'));
      final first = QuotaGate.allow('note_nearterm', 0, 0);
      expect(first.allowed, isTrue);
      expect(first.nextTodayCount, 1);
      final second = QuotaGate.allow('note_nearterm', 1, 0);
      expect(second.allowed, isFalse, reason: '超限不许放行（云母库只增不删）');
      expect(second.nextTodayCount, 1, reason: '超限不自增、不排队');
    });
  });

  group('E4 filterCatchphrases 纯函数', () {
    test('冷感人设丢弃撒娇叠词', () {
      final kept = SpeechProfileService.filterCatchphrases(
          const ['宝宝', '哈哈', '亲亲', '真的吗'], '她话少，脾气冷淡');
      expect(kept, <String>['哈哈', '真的吗']);
    });

    test('非冷感人设原样返回', () {
      final kept = SpeechProfileService.filterCatchphrases(
          const ['宝宝', '哈哈'], '她温柔爱撒娇');
      expect(kept, <String>['宝宝', '哈哈']);
    });
  });
}
