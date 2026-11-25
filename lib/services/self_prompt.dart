import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/self_models.dart';

/// R2 自我认知的**纯函数层**（全文件零 IO、零副作用）：拼 prompt / 解析 /
/// 三重拦截 / 删除清单关键词抽取 / 现实生活标记。与有副作用的 [SelfService] 分开，
/// B6/B7/B9 才可自动化测。与 Node `src/state_view.mjs` 逐条对应。

/// sha16(x) = sha256(utf8(x)) 前 16 位小写 hex。与 journal.dart 的 _hex16 同一实现。
String selfSha16(String input) =>
    sha256.convert(utf8.encode(input)).toString().substring(0, 16);

/// 一层拦截的判定原因（供测试逐条断言三层顺序，别混成布尔）。
enum RejectReason {
  /// 通过三层，可写
  none,

  /// ① 精确 sha16 命中删除清单 / 已有事实
  exactHash,

  /// ② 关键词 contains 命中删除清单
  keyword,

  /// ③ 硬事实候选（仅 hardFactGuardEnabled=true 时丢弃；标记与此无关）
  hardFact,
}

/// 一条候选事实过三重拦截的结论。
class GuardVerdict {
  final RejectReason reason;
  bool get keep => reason == RejectReason.none;

  const GuardVerdict(this.reason);

  @override
  bool operator ==(Object other) =>
      other is GuardVerdict && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'GuardVerdict(${reason.name})';
}

/// 拦截与标记的纯函数集合。
class SelfGuard {
  const SelfGuard._();

  /// 删除清单关键词抽取：去停用词后取 ≤3 个 2~3 字片段，不过模型（PRD O7）。
  /// 规则固定、两端一致：只取中文连续 2/3 字，过滤常见虚词，最多 3 个。
  static const Set<String> _stopWords = <String>{
    '今天', '现在', '这个', '那个', '什么', '怎么', '就是', '不是', '可以',
    '我们', '你们', '他们', '一个', '自己', '觉得', '好像', '有点', '真的',
    '已经', '还是', '但是', '因为', '所以', '然后', '一下', '这些', '那些',
  };

  static List<String> keywordsOf(String text) {
    final out = <String>[];
    final plain = text.replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]'), ' ');
    for (final seg in plain.split(RegExp(r'\s+'))) {
      if (seg.isEmpty) continue;
      // 取 3 字优先、其次 2 字，滑动窗口
      for (final n in <int>[3, 2]) {
        if (seg.length < n) continue;
        for (var i = 0; i + n <= seg.length; i++) {
          final piece = seg.substring(i, i + n);
          if (_stopWords.contains(piece) || out.contains(piece)) continue;
          out.add(piece);
          if (out.length >= 3) return out;
        }
      }
    }
    return out;
  }

  /// 「涉及你的现实生活」标记：职业 / 年龄 / 家人 / 城市 / 学历 / 身体。
  /// **恒开，不可关闭**——与 hardFactGuardEnabled 完全无关（B9 硬约束）。
  static bool isRealLifeFact(String text) {
    const markers = <String>[
      // 职业
      '工作', '上班', '公司', '职业', '老板', '同事', '加班', '客户', '通勤', '设计', '程序员',
      // 年龄
      '岁', '年纪', '年龄', '出生', '生日', '本命年',
      // 家人
      '妈', '爸', '妈妈', '爸爸', '家人', '母亲', '父亲', '姐', '弟', '妹', '哥', '孩子', '儿子', '女儿', '外婆', '奶奶', '爷爷',
      // 城市 / 住址
      '广州', '北京', '上海', '深圳', '杭州', '成都', '城市', '住在', '搬家', '租房', '老家',
      // 学历
      '大学', '毕业', '学历', '读研', '考研', '高中', '专业', '学校', '同学',
      // 身体
      '身体', '生病', '住院', '体检', '手术', '怀孕', '失眠', '胃', '头疼', '感冒',
    ];
    for (final m in markers) {
      if (text.contains(m)) return true;
    }
    return false;
  }

  /// 可选留档项（不进 P0 门禁）：硬事实判定与 isRealLifeFact 同一口径。
  static bool isHardFact(String text) => isRealLifeFact(text);

  /// 三层顺序固定：① 精确 sha16 → ② 关键词 contains → ③ 硬事实（条件层）。
  ///
  /// - [existingHashes]：当前已生效事实的 hash，防止逐字重复生长。
  /// - [deleted]：本机删除清单（含内存关键词）。
  /// - [hardFactGuardEnabled]：只影响第 ③ 层；**不影响 isRealLifeFact 标记**。
  static GuardVerdict check({
    required String text,
    required Set<String> existingHashes,
    required DeletedFactList deleted,
    required bool hardFactGuardEnabled,
  }) {
    final hash = selfSha16(text.trim());
    // ① 精确 sha16 命中（删除清单或已生效事实）
    if (deleted.containsHash(hash) || existingHashes.contains(hash)) {
      return const GuardVerdict(RejectReason.exactHash);
    }
    // ② 关键词 contains 命中删除清单
    final kws = keywordsOf(text);
    if (deleted.keywordHit(kws) != null) {
      return const GuardVerdict(RejectReason.keyword);
    }
    // ③ 硬事实候选（开关默认 false：这一层放行，只标记不丢弃）
    if (hardFactGuardEnabled && isHardFact(text)) {
      return const GuardVerdict(RejectReason.hardFact);
    }
    return const GuardVerdict(RejectReason.none);
  }

  /// 兼容旧签名：只判"是否重复"（①②两层）。
  static bool isRepeat(SelfFact f, DeletedFactList deleted) =>
      deleted.containsHash(f.hash);
}

/// 生成 prompt 的拼装与解析。
class SelfPrompt {
  const SelfPrompt._();

  /// system 段固定硬约束：不得出现 AI/助手/模型/程序。
  static const String systemPrompt = '''
你在回顾「自己是谁」。只输出 JSON：{"self_text":"...","facts":[{"text":"...","source":{"messageKeys":["m:..."],"chunkKey":"","quote":"..."}}]}
要求：
- self_text 是 300-360 字第一人称自我描述，只允许增补细化，不许推翻已有结论。
- facts 最多 3 条，每条都是你自己新长出来的、第一人称的一句话事实（≤60字）。
- 每条 facts 必须带 source：至少给 1 个 message key，或 1 个 chunkKey；quote 填当时那句原话。没有来源的丢弃。
- 不得出现"AI/助手/模型/程序"字样，不得和人设的年龄/职业矛盾。
- 只输出 JSON，不要解释。''';

  /// 把来源材料拼成 user 输入（删除清单关键词 ≤50 字作为"别再说这些"的提示）。
  static String buildUserInput({
    required String personaProjection,
    required List<String> recentLines,
    required List<String> nearNotes,
    DeletedFactList deleted = const DeletedFactList(),
  }) {
    final b = StringBuffer();
    b.writeln('【我的人设投影（不可推翻）】');
    b.writeln(personaProjection.trim().isEmpty ? '（无）' : personaProjection.trim());
    b.writeln('\n【最近对话（可能有新事实，附 message key）】');
    if (recentLines.isEmpty) {
      b.writeln('（无）');
    } else {
      for (final l in recentLines) {
        b.writeln(l);
      }
    }
    b.writeln('\n【最近在聊什么】');
    if (nearNotes.isEmpty) {
      b.writeln('（无）');
    } else {
      for (final n in nearNotes) {
        b.writeln('- $n');
      }
    }
    final kws = <String>[];
    for (final k in deleted.keywords) {
      if (!kws.contains(k)) kws.add(k);
    }
    if (kws.isNotEmpty) {
      final joined = kws.take(12).join('、');
      final cut = joined.length > 50 ? joined.substring(0, 50) : joined;
      b.writeln('\n【这些是我已经删掉的意思，不许再长出来】');
      b.writeln(cut);
    }
    return b.toString();
  }

  /// 解析模型 JSON 文本 → 事实列表。
  static List<SelfFact> parseFacts(String json) {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return const <SelfFact>[];
    }
    return factsFromMap(decoded);
  }

  /// 解析模型 JSON Map → 事实列表。**source 为空（无可追溯 key）直接丢弃**。
  static List<SelfFact> factsFromMap(Object? decoded) {
    final out = <SelfFact>[];
    if (decoded is! Map) return out;
    final facts = decoded['facts'];
    if (facts is! List) return out;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final raw in facts) {
      if (raw is! Map) continue;
      final text = raw['text'] is String ? (raw['text'] as String).trim() : '';
      if (text.isEmpty) continue;
      final source = SelfSource.fromMap(raw['source']);
      if (!source.isTraceable) continue; // 无来源不许写（溯源锁）
      out.add(SelfFact(
        hash: selfSha16(text),
        text: text,
        source: source,
        createdAt: now,
      ));
    }
    return out;
  }
}

/// 聚合 self 文本。≤360 字硬上限（B3，不让位给 D3 的 110% 预算）。
class SelfComposer {
  const SelfComposer._();

  static const int maxChars = 360;

  /// 派生事实 + 自生长事实 → 第一人称 self 文本（≤360 字）。
  static String compose(List<String> derived, List<SelfFact> facts) {
    final b = StringBuffer();
    for (final d in derived) {
      final t = d.trim();
      if (t.isNotEmpty) b.writeln(t);
    }
    for (final f in facts) {
      final t = f.text.trim();
      if (t.isNotEmpty) b.writeln(t);
    }
    var text = b.toString().trim();
    if (text.length > maxChars) text = text.substring(0, maxChars);
    return text;
  }

  /// 展示期剔除一条已删事实的明文（导出/界面不出现，本机清单本就没有原文）。
  static String exclude(String text, SelfFact fact) {
    final t = fact.text.trim();
    if (t.isEmpty) return text;
    return text.replaceAll(t, '');
  }
}
