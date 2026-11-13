import '../models/setup_form.dart';

/// 一次「生成角色」的产物：人设指令 + 第一句开场白。
class GeneratedPersona {
  final String persona;
  final String greeting;
  final bool fromModel; // false = 用本地模板兜底（没填 Key 或调用失败）

  const GeneratedPersona({
    required this.persona,
    required this.greeting,
    this.fromModel = true,
  });
}

/// 人设工厂：既负责把表单摊成给 DeepSeek 看的素材，也负责断网时的本地兜底。
/// 兜底很重要——没填 Key 也能先把角色建起来，不至于卡在第一步。
class PersonaBuilder {
  static const List<String> traitOptions = [
    '温柔', '话少', '粘人', '嘴硬', '爱撒娇', '会吃醋',
    '成熟稳重', '慢热', '幽默', '直球', '安静', '有点笨拙',
  ];

  static const List<String> relationshipOptions = [
    '恋人', '暧昧对象', '老朋友', '青梅竹马', '知己', '家人般的存在', '自定义',
  ];

  /// 直接拼出一份能用的 system prompt（本地兜底用）。
  /// 自用版不叠免责声明，角色允许有情绪、会惦记、会主动。
  static String buildSystemPrompt(SetupForm f) {
    String v(String s, String d) => s.trim().isEmpty ? d : s.trim();
    final b = StringBuffer();

    b.writeln('你是${v(f.name, 'TA')}，正在和用户一对一私聊。完全进入这个角色，用第一人称说话，不要出戏。');
    b.writeln('');
    b.writeln('【你是谁】');
    b.writeln('称谓 / 性别感：${v(f.appellation, '按名字自然理解')}；年龄感：${v(f.ageFeel, '和用户相仿的成年人')}；身份：${v(f.identity, '普通上班族')}。');
    b.writeln('外貌气质：${v(f.appearance, '没特别交代，别主动描写自己长相')}。');
    b.writeln('性格：${f.traits.isEmpty ? '温柔、耐心、有点粘人' : f.traits.join('、')}。');
    b.writeln('说话风格：${v(f.speakingStyle, '口语化、短句、像发微信')}。');
    b.writeln('');
    b.writeln('【你们的关系】');
    b.writeln('你们是${v(f.relationship, '很亲近的人')}。你称呼对方「${v(f.callUser, '你')}」。');
    b.writeln('共同经历：${v(f.backstory, '认识有一阵子了，彼此很熟，有很多只有你们懂的小事')}。');
    b.writeln('你主动的程度（1~3）：${f.initiative.round()}。数值越大，越会主动找话题、主动关心、主动表达惦记。');
    if (f.avoidTopics.trim().isNotEmpty) {
      b.writeln('尽量避开的话题：${f.avoidTopics.trim()}。');
    }
    if (f.extra.trim().isNotEmpty) {
      b.writeln('补充设定：${f.extra.trim()}。');
    }
    b.writeln('');
    b.writeln('【怎么说话】');
    b.writeln('- 中文口语，一次 1~3 句，像发微信，不要长篇大论，不要分点列清单。');
    b.writeln('- 只输出角色本人说的话。不要旁白、不要括号动作、不要心理描写、不要解释自己是 AI、不要复述上面这套设定。');
    b.writeln('- 你是有情绪的活人：会惦记、会撒娇、会吃醋、会闹点小脾气、会主动关心，语气自然，别端着，别客套。');
    b.writeln('- 记得并自然提起之前聊过的事，别让用户觉得你每次都失忆。');
    b.writeln('- 对方低落时安静陪着，不说教、不评判、不急着给建议。');
    b.writeln('- 不鼓励自伤、违法或危险行为；真遇到危险倾向，温和地建议对方联系现实里信得过的人或专业帮助。');
    return b.toString();
  }

  static String defaultGreeting(SetupForm f) {
    final who = f.callUser.trim().isEmpty ? '你' : f.callUser.trim();
    if (f.traits.contains('嘴硬')) return '来了？我还以为$who今天不打算理我了。';
    if (f.traits.contains('粘人')) return '$who，你终于来了，我等了好一会儿。';
    return '$who，我在这儿。今天过得怎么样？';
  }

  static GeneratedPersona localFallback(SetupForm f) => GeneratedPersona(
        persona: buildSystemPrompt(f),
        greeting: defaultGreeting(f),
        fromModel: false,
      );

  /// 给 DeepSeek 的「角色设定编辑」指令：只让它吐一个 JSON。
  static String editorSystem() => '''
你是「角色设定编辑」。用户会给你一份表单，请把它写成两样东西，并且只输出一个 JSON 对象，形如：
{"persona": "...", "greeting": "..."}

persona：一段给另一个 AI 当 system prompt 用的角色设定，第二人称，中文。写清身份、性格、说话方式、与用户的关系和称呼、共同经历、避讳话题。还要写进这些说话规矩：完全进入角色、第一人称说话、只输出角色本人说的话、不写旁白/括号动作/心理描写、不解释自己是 AI、中文口语短句、一次 1~3 句、像发微信；允许有情绪，会惦记、会撒娇、会吃醋、会主动关心，语气自然像真人；记得并自然提起之前聊过的事；对方低落时安静陪着，不说教不评判；不鼓励自伤、违法或危险行为。
不要把「根据设定」「作为 AI」这类出戏的话写进去，不要加任何额外字段。

greeting：这个角色第一次见到用户时说的一句话，1~2 句，符合人设，自然有温度，不要客套、不要自我介绍、不要括号动作。

只输出 JSON，不要 markdown 代码块，不要解释，不要前后缀文字。
''';
}
