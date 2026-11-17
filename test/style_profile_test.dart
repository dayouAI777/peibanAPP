import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/models/style_example.dart';
import 'package:peiban_app/models/style_profile.dart';
import 'package:peiban_app/services/context_builder.dart';
import 'package:peiban_app/services/deepseek.dart';
import 'package:peiban_app/services/style_profile_service.dart';

/// 假的 DeepSeek 服务：不触网，直接吐预设的 JSON 或抛异常。
class _FakeLlm extends DeepSeekService {
  _FakeLlm(this._reply, {this.throwError = false});
  final Map<String, dynamic> _reply;
  final bool throwError;

  @override
  Future<Map<String, dynamic>> completeJson({
    required String apiKey,
    required String system,
    required String user,
    int maxTokens = 1400,
    double temperature = 0.5,
  }) async {
    if (throwError) throw const FormatException('bad json');
    return _reply;
  }
}

StyleExample _ex({
  String trigger = '在干嘛',
  String original = '在忙哦，有什么事吗？',
  String preferred = '刚画完画 你呢',
  int createdAt = 1,
}) =>
    StyleExample(
      companionId: 1,
      trigger: trigger,
      original: original,
      preferred: preferred,
      createdAt: createdAt,
    );

void main() {
  group('StyleProfile 模型：encode / decode / 降级', () {
    test('encode → decode 往返字段一致（含中文与口头禅列表）', () {
      final p = const StyleProfile(
        digested: 29,
        updatedAt: 1700000000000,
        tone: '随性偏糙，像熟人',
        sentenceLength: '多为 3~8 字短句',
        catchphrases: ['哈？', '就离谱', '行吧'],
        punctuation: '基本不加标点，偶尔 emoji',
        rhythm: '先结论后补刀',
        taboos: '不连发长段；不自称我厸厸；不说客服金句',
        notes: '无聊的话题就一个字接',
      );
      final back = StyleProfile.decode(p.encode());
      expect(back.digested, 29);
      expect(back.updatedAt, 1700000000000);
      expect(back.tone, '随性偏糙，像熟人');
      expect(back.sentenceLength, '多为 3~8 字短句');
      expect(back.catchphrases, ['哈？', '就离谱', '行吧']);
      expect(back.punctuation, '基本不加标点，偶尔 emoji');
      expect(back.rhythm, '先结论后补刀');
      expect(back.taboos, contains('不自称我厸厸'));
      expect(back.notes, '无聊的话题就一个字接');
      expect(back.isEmpty, isFalse);
    });

    test('坏 JSON / 非对象 JSON / 空串 → 降级成空档案，绝不抛', () {
      expect(StyleProfile.decode('这不是 json').isEmpty, isTrue);
      expect(StyleProfile.decode('[1,2,3]').isEmpty, isTrue);
      expect(StyleProfile.decode('null').isEmpty, isTrue);
      expect(StyleProfile.decode('').isEmpty, isTrue);
      expect(StyleProfile.decode('   ').isEmpty, isTrue);
    });

    test('字段缺失 / 类型不对 → 兜默认值，不抛、不崩', () {
      final p = StyleProfile.decode('{"digested":"abc","catchphrases":[1,"行吧",2,"行吧"],"tone":42}');
      expect(p.digested, 0);
      expect(p.tone, '');
      // 非字符串元素转字符串、重复的去掉
      expect(p.catchphrases, ['1', '行吧', '2']);
    });

    test('超长口头禅截断，防模型违约束把整段话塞进列表', () {
      final p = StyleProfile.decode(
          '{"catchphrases":["${'啊' * 30}","正常"]}');
      expect(p.catchphrases.first.length, 16);
      expect(p.catchphrases.last, '正常');
    });

    test('isEmpty 口径：digested==0 且全字段空才算空；有内容但 digested=0 不算空', () {
      expect(StyleProfile.empty().isEmpty, isTrue);
      expect(const StyleProfile(digested: 0).isEmpty, isTrue);
      // 只蒸了字段还没记 digested（理论边界）→ 有内容就不算空
      expect(const StyleProfile(digested: 0, tone: '随性').isEmpty, isFalse);
      expect(const StyleProfile(digested: 5).isEmpty, isFalse);
    });

    test('renderForPrompt：有值的才输出，全空返回空串', () {
      expect(StyleProfile.empty().renderForPrompt(), '');
      final p = const StyleProfile(
        digested: 1,
        tone: '随性偏糙',
        catchphrases: ['哈？', '就离谱'],
        taboos: '不连发长段',
      );
      final r = p.renderForPrompt();
      expect(r, contains('语气与态度：随性偏糙'));
      expect(r, contains('口头禅与用词：哈？、就离谱'));
      expect(r, contains('底线雷区（这些绝不能说）：不连发长段'));
      expect(r.contains('句子长短'), isFalse); // 没值的字段不出
    });
  });

  group('蒸馏触发阈值（纯函数）', () {
    test('digested 落后 ≥ 3 条触发，落后 2 条不触发', () {
      expect(StyleProfileService.shouldDistill(digested: 0, total: 3), isTrue);
      expect(StyleProfileService.shouldDistill(digested: 0, total: 29), isTrue);
      expect(StyleProfileService.shouldDistill(digested: 26, total: 29), isTrue);
      expect(StyleProfileService.shouldDistill(digested: 27, total: 29),
          isFalse);
      expect(StyleProfileService.shouldDistill(digested: 29, total: 29),
          isFalse);
    });

    test('范例被删导致 digested 超前 → 差值为负，不触发', () {
      expect(StyleProfileService.shouldDistill(digested: 35, total: 30),
          isFalse);
    });

    test('自定义阈值生效', () {
      expect(
        StyleProfileService.shouldDistill(
            digested: 0, total: 2, threshold: 2),
        isTrue,
      );
      expect(
        StyleProfileService.shouldDistill(
            digested: 0, total: 1, threshold: 2),
        isFalse,
      );
    });
  });

  group('蒸馏 prompt 拼接（供审查）', () {
    test('system prompt 写明：preferred 优先、original 只进底线雷区、只输出 JSON', () {
      final s = StyleProfileService.distillSystemPrompt;
      expect(s, contains('preferred（改后句）永远优先于 original（改前句）'));
      expect(s, contains('提炼进 taboos'));
      expect(s, contains('绝不把错句原样照抄进任何其他字段'));
      expect(s, contains('增量合并，不是重写'));
      expect(s, contains('不超过 40 字'));
      expect(s, contains('只输出 JSON'));
      expect(s, contains('"taboos"'));
    });

    test('user 输入：现有档案 JSON + 新增范例（trigger/original/preferred）+ 旧抽样', () {
      final current = const StyleProfile(
        digested: 23,
        tone: '随性偏糙',
        catchphrases: ['哈？'],
      );
      final user = StyleProfileService.buildDistillUserInput(
        current: current,
        newExamples: [_ex(), _ex(preferred: '你先忙你的')],
        sampleOld: [_ex(trigger: '吃了吗', preferred: '还没 叫外卖呢')],
      );
      expect(user, contains('"preferred":"刚画完画 你呢"'));
      expect(user, contains('"original":"在忙哦，有什么事吗？"'));
      expect(user, contains('"trigger":"吃了吗"'));
      expect(user, contains('"tone":"随性偏糙"'));
      expect(user, contains('"digested":23'));
      expect(user, contains('"old_sample"'));
    });

    test('第一次蒸馏：current 为空时明确告诉模型', () {
      final user = StyleProfileService.buildDistillUserInput(
        current: StyleProfile.empty(),
        newExamples: [_ex()],
        sampleOld: const [],
      );
      expect(user, contains('还没有档案，这是第一次蒸馏'));
    });
  });

  group('distill 蒸馏（mock 注入，不触网）', () {
    test('成功：合并模型字段 + 保留旧口头禅 + digested 前进到范例总数', () async {
      final service = StyleProfileService(
        llm: _FakeLlm(const {
          'tone': '随性偏糙，懒得解释',
          'catchphrases': ['哈？', '就离谱'],
          'taboos': '不连发长段；不自称我厸厸',
        }),
      );
      final current = const StyleProfile(
        digested: 10,
        tone: '还行',
        catchphrases: ['哈？', '行吧'],
        rhythm: '短句',
      );
      final out = await service.distill(
        apiKey: 'sk-test',
        current: current,
        newExamples: [_ex(), _ex(), _ex(preferred: '你先忙你的')],
        sampleOld: [_ex(trigger: '吃了吗')],
        totalExamples: 13,
      );
      expect(out.digested, 13, reason: 'digested = 当前范例总数');
      expect(out.updatedAt, greaterThan(0));
      expect(out.tone, '随性偏糙，懒得解释');
      expect(out.taboos, contains('不自称我厸厸'));
      // 模型没给的字段保留 current 原值（增量合并兜底）
      expect(out.rhythm, '短句');
      expect(out.sentenceLength, '');
      // 旧口头禅保底保留
      expect(out.catchphrases, containsAll(['就离谱', '行吧']));
    });

    test('一轮被上限截断时 digested 只前进实际消化数，不虚报', () async {
      final service = StyleProfileService(llm: _FakeLlm(const {
        'tone': '随性',
      }));
      final out = await service.distill(
        apiKey: 'sk-test',
        current: const StyleProfile(digested: 0),
        newExamples: [for (int i = 0; i < 10; i++) _ex(createdAt: i)],
        sampleOld: const [],
        totalExamples: 8,
      );
      expect(out.digested, 8, reason: 'min(total, digested + new.length)');
    });

    test('网络/解析失败 → 返回 current 原样，状态不变，不抛', () async {
      final service = StyleProfileService(
        llm: _FakeLlm(const {}, throwError: true),
      );
      final current = const StyleProfile(digested: 5, tone: '随性偏糙');
      final out = await service.distill(
        apiKey: 'sk-test',
        current: current,
        newExamples: [_ex()],
        sampleOld: const [],
        totalExamples: 6,
      );
      expect(out.digested, 5);
      expect(out.tone, '随性偏糙');
      expect(out.updatedAt, current.updatedAt);
    });

    test('没 Key / 新范例为空 → 直接原样返回，连 API 都不调', () async {
      final service = StyleProfileService(llm: _FakeLlm(const {}));
      final current = const StyleProfile(digested: 5, tone: '随性');
      expect(
        (await service.distill(
          apiKey: '  ',
          current: current,
          newExamples: [_ex()],
          sampleOld: const [],
          totalExamples: 6,
        )).digested,
        5,
      );
      expect(
        (await service.distill(
          apiKey: 'sk-test',
          current: current,
          newExamples: const [],
          sampleOld: const [],
          totalExamples: 6,
        )).digested,
        5,
      );
    });
  });

  group('prompt 注入（档案在前、范例在后）', () {
    test('非空档案：注入长期习惯块，位置在范例块之前', () {
      final profile = const StyleProfile(
        digested: 29,
        updatedAt: 1,
        tone: '随性偏糙，像熟人',
        taboos: '不连发长段',
        catchphrases: ['哈？'],
      );
      final system = ContextBuilder.buildSystem(
        persona: '你是阿雾',
        notes: const [],
        chunks: const [],
        window: 1000,
        styleProfile: profile,
        styleExamples: [_ex()],
      );
      expect(system, contains('长期形成的习惯'));
      expect(system, contains('随性偏糙，像熟人'));
      expect(system, contains('不连发长段'));
      expect(system, contains('以范例为准'));
      // 档案是长期规律，范例是最新鲜标杆：档案在前
      final archiveIdx = system.indexOf('长期形成的习惯');
      final exampleIdx = system.indexOf('她这个人的说话方式');
      expect(archiveIdx, greaterThanOrEqualTo(0));
      expect(exampleIdx, greaterThan(archiveIdx));
    });

    test('空档案 / 不传档案：不输出该块', () {
      final withEmpty = ContextBuilder.buildSystem(
        persona: '你是阿雾',
        notes: const [],
        chunks: const [],
        window: 1000,
        styleProfile: StyleProfile.empty(),
        styleExamples: [_ex()],
      );
      expect(withEmpty.contains('长期形成的习惯'), isFalse);

      final without = ContextBuilder.buildSystem(
        persona: '你是阿雾',
        notes: const [],
        chunks: const [],
        window: 1000,
        styleExamples: [_ex()],
      );
      expect(without.contains('长期形成的习惯'), isFalse);
    });

    test('maxStyleExamples = 12 的窗口逻辑原样不动', () {
      final examples = [
        for (int i = 0; i < 20; i++)
          _ex(trigger: '触发$i', original: '错$i', preferred: '对$i', createdAt: i),
      ];
      final system = ContextBuilder.buildSystem(
        persona: '你是阿雾',
        notes: const [],
        chunks: const [],
        window: 1000,
        styleProfile: const StyleProfile(digested: 20, tone: '随性'),
        styleExamples: examples,
      );
      expect(system.contains('对19'), isTrue);
      expect(system.contains('对8'), isTrue);
      expect(system.contains('对7'), isFalse);
    });
  });
}
