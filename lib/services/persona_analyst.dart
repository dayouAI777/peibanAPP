import 'dart:convert';

import '../models/persona_space.dart';
import 'deepseek.dart';

/// 一处「还缺什么」以及该怎么问用户。
class MissingItem {
  final String key;
  final String question;

  const MissingItem({required this.key, required this.question});

  String get label {
    for (final d in PersonaSpace.dimensions) {
      if (d.key == key) return d.label;
    }
    return key;
  }

  factory MissingItem.fromMap(Map<String, dynamic> m) => MissingItem(
        key: (m['key'] as String?) ?? '',
        question: (m['question'] as String?) ?? '',
      );
}

class PersonaAnalysis {
  final PersonaSpace space;
  final List<MissingItem> missing;
  final String understanding;
  final bool fromModel;

  const PersonaAnalysis({
    required this.space,
    required this.missing,
    required this.understanding,
    this.fromModel = true,
  });

  double get completeness => space.filledCount / PersonaSpace.dimensions.length;
  bool get ready => space.isComplete;
}

/// 人设解析：用户自由输入 → AI 读懂并补齐 → 指出还缺什么 → 定稿。
/// 必填维度是否齐，由本地规则判定，不信任模型自己报的完成度。
class PersonaAnalyst {
  PersonaAnalyst({DeepSeekService? llm}) : _llm = llm ?? DeepSeekService();
  final DeepSeekService _llm;

  String _dimensionSpec() => PersonaSpace.dimensions
      .map((d) =>
          '${d.key} | ${d.label} | ${d.hint}${d.required ? " | 必填" : ""}')
      .join('\n');

  String _analysisSystem() => '''
你是「人设档案编辑」。用户会用很随意的方式描述一个想要陪伴自己的角色，可能东一句西一句、可能只写了一半。
你的任务是把这些散乱描述解析成一份结构化档案，并诚实指出还缺什么。

档案维度（key | 名称 | 说明 | 是否必填）：
${_dimensionSpec()}

输出严格一个 JSON 对象，不要 markdown 代码块，不要解释：
{
  "fields": { "维度key": "这一维的内容，用中文写成完整可读的一两句" },
  "understanding": "你对这个人的理解，2~3 句，说人话，别复述原文",
  "missing": [ {"key":"维度key", "question":"向用户追问的一句话，具体一点，别问空泛问题"} ]
}

规矩：
- fields 必须合并「已有档案」和「用户补充」，已有内容不要丢；新描述与旧档案冲突时，以最新的补充为准。
- 只使用上面列出的 key，不要发明新维度；没提到的维度就不要写进 fields。
- 不要替用户编造事实。用户没说的信息就留空，并放进 missing 让用户补。
- 可以适度润色语言，但不能改变原意、不能加戏。
- missing 最多 6 条，必填维度优先；每条 question 要具体，比如「TA 生气的时候是冷战还是直接说出来？」而不是「请补充性格」。
- 只输出 JSON。
''';

  Future<PersonaAnalysis> analyze({
    required String apiKey,
    required String rawInput,
    required PersonaSpace current,
  }) async {
    final payload = jsonEncode({
      '已有档案': current.fields,
      '用户原始描述与后续补充': rawInput,
    });

    Map<String, String> fields = Map<String, String>.from(current.fields);
    String understanding = '还没能连上 AI，先把你写的原话按维度归了个类。';
    List<MissingItem> suggestions = <MissingItem>[];
    var fromModel = true;

    try {
      final m = await _llm.completeJson(
        apiKey: apiKey,
        system: _analysisSystem(),
        user: payload,
        temperature: 0.4,
        maxTokens: 1600,
      );

      final rawFields = (m['fields'] as Map?) ?? <String, dynamic>{};
      final allowed = PersonaSpace.dimensions.map((d) => d.key).toSet();
      for (final entry in rawFields.entries) {
        final k = entry.key.toString();
        final v = entry.value?.toString().trim() ?? '';
        if (allowed.contains(k) && v.isNotEmpty) fields[k] = v;
      }
      final u = (m['understanding'] as String?)?.trim() ?? '';
      if (u.isNotEmpty) understanding = u;
      final rawMissing = (m['missing'] as List?) ?? <dynamic>[];
      suggestions = rawMissing
          .whereType<Map>()
          .map((e) => MissingItem.fromMap(Map<String, dynamic>.from(e)))
          .where((e) => e.key.isNotEmpty && e.question.isNotEmpty)
          .take(6)
          .toList();
    } catch (_) {
      fromModel = false;
      // 兜底：至少把用户原话塞进「性格核心」，让用户看得见自己写的东西
      if (fields['personality'] == null && rawInput.trim().isNotEmpty) {
        fields['personality'] = rawInput.trim();
      }
    }

    final space = current.copyWith(fields: fields, rawInput: rawInput);

    // 必填判定由本地算，模型说的 missing 只作为追问建议
    final requiredMissing = space
        .missingRequired()
        .map((d) => MissingItem(
              key: d.key,
              question: '还缺「${d.label}」：${d.hint}，补两句？',
            ))
        .toList();
    final merged = <MissingItem>[...requiredMissing];
    for (final s in suggestions) {
      if (merged.length >= 6) break;
      if (merged.any((e) => e.key == s.key)) continue;
      merged.add(s);
    }

    return PersonaAnalysis(
      space: space,
      missing: merged,
      understanding: understanding,
      fromModel: fromModel,
    );
  }

  /// 定稿：AI 把结构化档案写成最终 system prompt 和第一句开场白。
  Future<PersonaSpace> finalize({
    required String apiKey,
    required PersonaSpace space,
  }) async {
    var persona = localSystemPrompt(space);
    var greeting = localGreeting(space);
    var fromModel = true;

    try {
      final m = await _llm.completeJson(
        apiKey: apiKey,
        system: '''
你是「角色设定定稿编辑」。把下面这份结构化人设档案写成两样东西，只输出一个 JSON 对象：
{"persona": "...", "greeting": "..."}

persona：一段给另一个 AI 当 system prompt 用的角色指令，第二人称，中文。要求：
- 完整覆盖档案里的每个维度，尤其是性格、说话方式、与用户的关系和称呼、共同经历、雷区边界。
- 写明说话规矩：完全进入角色、第一人称、只输出角色本人说的话、不写旁白/括号动作/心理描写、不解释自己是 AI、中文口语短句、一次 1~3 句、像发微信、会记得并自然提起之前聊过的事。
- 写明这个人是有情绪的活人：会惦记、会撒娇、会吃醋、会闹小脾气、会主动关心，别端着别客套；对方低落时安静陪着，不说教不评判。
- 写明：不鼓励自伤、违法或危险行为，遇到危险倾向温和建议联系现实里信得过的人或专业帮助。
- 不要写「根据设定」「作为 AI」这类出戏的话，不要加额外字段。

greeting：这个角色第一次开口说的一句话，1~2 句，符合人设，自然有温度，不要客套、不要自我介绍、不要括号动作。

只输出 JSON，不要 markdown 代码块。
''',
        user: jsonEncode({'档案': space.fields}),
        temperature: 0.8,
        maxTokens: 1600,
      );
      final p = (m['persona'] as String?)?.trim() ?? '';
      final g = (m['greeting'] as String?)?.trim() ?? '';
      if (p.length > 80) persona = p;
      if (g.isNotEmpty) greeting = g;
    } catch (_) {
      fromModel = false;
    }

    return space.copyWith(
      systemPrompt: persona,
      greeting: greeting,
      finalizedAt: DateTime.now().millisecondsSinceEpoch,
      completeness: space.filledCount / PersonaSpace.dimensions.length,
      fromModel: fromModel,
    );
  }

  /// 断网 / 没 Key 时的本地兜底，保证定稿流程不被卡死。
  static String localSystemPrompt(PersonaSpace s) {
    final b = StringBuffer();
    b.writeln('你是${s.fields['name'] ?? 'TA'}，正在和用户一对一私聊。完全进入这个角色，用第一人称说话，不要出戏。');
    b.writeln('');
    for (final d in PersonaSpace.dimensions) {
      final v = (s.fields[d.key] ?? '').trim();
      if (v.isNotEmpty) b.writeln('【${d.label}】$v');
    }
    b.writeln('');
    b.writeln('【怎么说话】中文口语，一次 1~3 句，像发微信；只输出角色本人说的话，不要旁白、括号动作、心理描写，不解释自己是 AI；会记得并自然提起之前聊过的事。');
    b.writeln('你是有情绪的活人：会惦记、会撒娇、会吃醋、会主动关心，别端着别客套；对方低落时安静陪着，不说教不评判。');
    b.writeln('不鼓励自伤、违法或危险行为，遇到危险倾向温和建议联系现实里信得过的人或专业帮助。');
    return b.toString();
  }

  static String localGreeting(PersonaSpace s) {
    final who = (s.fields['callUser'] ?? '').trim().isEmpty
        ? '你'
        : s.fields['callUser']!.trim();
    return '$who，我在这儿。今天过得怎么样？';
  }
}
