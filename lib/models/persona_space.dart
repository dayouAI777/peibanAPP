import 'dart:convert';

/// 人设空间的一个维度。定稿后整份空间只读，不再允许修改。
class PersonaDimension {
  final String key;
  final String label;
  final String hint;
  final bool required;

  const PersonaDimension({
    required this.key,
    required this.label,
    required this.hint,
    this.required = false,
  });
}

/// 「人设空间」：把用户自由输入的内容，经 AI 解析、查缺补漏后形成的结构化档案。
/// 严肃设定：一旦定稿（写入 Companion.personaSpace），性格就不会再变；
/// 想换人只有一个办法——删除重建。
class PersonaSpace {
  static const List<PersonaDimension> dimensions = [
    PersonaDimension(key: 'name', label: '名字 / 称呼', hint: '叫什么，你希望被怎么称呼', required: true),
    PersonaDimension(key: 'identity', label: '身份与年龄感', hint: '做什么的、大概多大、什么处境', required: true),
    PersonaDimension(key: 'appearance', label: '外貌气质', hint: '长相、穿着、给人的第一印象'),
    PersonaDimension(key: 'personality', label: '性格核心', hint: '底色、遇事的反应、矛盾之处', required: true),
    PersonaDimension(key: 'speaking', label: '说话方式', hint: '语气、句长、口头禅、会不会嘴硬', required: true),
    PersonaDimension(key: 'relationship', label: '你们的关系', hint: '恋人 / 老友 / 别的什么', required: true),
    PersonaDimension(key: 'callUser', label: '怎么称呼你', hint: 'TA 叫你什么', required: true),
    PersonaDimension(key: 'backstory', label: '初见与共同经历', hint: '怎么认识的、有哪些只有你们懂的事', required: true),
    PersonaDimension(key: 'habits', label: '生活习惯', hint: '作息、常做的事、常待的地方'),
    PersonaDimension(key: 'values', label: '在意的点', hint: '看重什么、喜欢什么、什么会让 TA 高兴'),
    PersonaDimension(key: 'boundaries', label: '雷区与边界', hint: '不喜欢什么、不愿聊什么、底线在哪'),
    PersonaDimension(key: 'quirks', label: '小动作与小习惯', hint: '口头禅、下意识动作、你们之间的梗'),
  ];

  static const List<String> requiredKeys = [
    'name', 'identity', 'personality', 'speaking',
    'relationship', 'callUser', 'backstory',
  ];

  final Map<String, String> fields;
  final String rawInput;
  final String systemPrompt;
  final String greeting;
  final int finalizedAt;
  final double completeness;
  final bool fromModel;

  const PersonaSpace({
    required this.fields,
    this.rawInput = '',
    this.systemPrompt = '',
    this.greeting = '',
    this.finalizedAt = 0,
    this.completeness = 0,
    this.fromModel = true,
  });

  List<PersonaDimension> missingRequired() => dimensions
      .where((d) => d.required && (fields[d.key] ?? '').trim().length < 4)
      .toList();

  bool get isComplete => missingRequired().isEmpty;

  int get filledCount =>
      dimensions.where((d) => (fields[d.key] ?? '').trim().isNotEmpty).length;

  PersonaSpace copyWith({
    Map<String, String>? fields,
    String? rawInput,
    String? systemPrompt,
    String? greeting,
    int? finalizedAt,
    double? completeness,
    bool? fromModel,
  }) =>
      PersonaSpace(
        fields: fields ?? this.fields,
        rawInput: rawInput ?? this.rawInput,
        systemPrompt: systemPrompt ?? this.systemPrompt,
        greeting: greeting ?? this.greeting,
        finalizedAt: finalizedAt ?? this.finalizedAt,
        completeness: completeness ?? this.completeness,
        fromModel: fromModel ?? this.fromModel,
      );

  /// 只读展示用：把空间摊成一段人看得懂的文字。
  String renderReadonly() {
    final b = StringBuffer();
    for (final d in dimensions) {
      final v = (fields[d.key] ?? '').trim();
      if (v.isNotEmpty) b.writeln('【${d.label}】$v');
    }
    return b.toString();
  }

  Map<String, dynamic> toMap() => {
        'fields': fields,
        'raw_input': rawInput,
        'system_prompt': systemPrompt,
        'greeting': greeting,
        'finalized_at': finalizedAt,
        'completeness': completeness,
        'from_model': fromModel,
      };

  factory PersonaSpace.fromMap(Map<String, dynamic> m) => PersonaSpace(
        fields: (m['fields'] as Map?) == null
            ? <String, String>{}
            : Map<String, String>.from(m['fields'] as Map),
        rawInput: (m['raw_input'] as String?) ?? '',
        systemPrompt: (m['system_prompt'] as String?) ?? '',
        greeting: (m['greeting'] as String?) ?? '',
        finalizedAt: (m['finalized_at'] as int?) ?? 0,
        completeness: (m['completeness'] as num?)?.toDouble() ?? 0,
        fromModel: (m['from_model'] as bool?) ?? true,
      );

  String encode() => jsonEncode(toMap());

  static PersonaSpace decode(String raw) =>
      PersonaSpace.fromMap(jsonDecode(raw) as Map<String, dynamic>);

  static PersonaSpace empty() => const PersonaSpace(fields: <String, String>{});
}
