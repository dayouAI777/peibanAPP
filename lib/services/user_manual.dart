import 'dart:convert';

import '../data/db_helper.dart';
import '../models/message.dart';
import '../models/user_note.dart';
import 'deepseek.dart';

class ManualCandidate {
  final String category;
  final String content;
  final double confidence;
  final String evidence;

  const ManualCandidate({
    required this.category,
    required this.content,
    required this.confidence,
    required this.evidence,
  });

  factory ManualCandidate.fromMap(Map<String, dynamic> m) => ManualCandidate(
        category: (m['category'] as String?) ?? '',
        content: (m['content'] as String?) ?? '',
        confidence: (m['confidence'] as num?)?.toDouble() ?? 0,
        evidence: (m['evidence'] as String?) ?? '',
      );
}

/// 用户行为记录手册。
/// 原则：宁可不记，也不乱记。AI 负责判断「值不值得记」，
/// 本地这层硬规则负责一票否决——模型再怎么说好，踩了规则也不入库。
class UserManualService {
  UserManualService({DeepSeekService? llm}) : _llm = llm ?? DeepSeekService();
  final DeepSeekService _llm;

  /// 每积累多少条用户消息评一次。
  static const int reviewEvery = 6;

  static const double minConfidence = 0.75;
  static const int maxNotes = 60;
  static const int minLength = 6;
  static const int maxLength = 120;

  /// 隐私类信息一律不记，无论模型多确定。
  static final List<RegExp> privacyPatterns = [
    RegExp(r'身份证|银行卡|信用卡|密码|验证码|手机号|电话号码|住址|门牌|账号|卡号|工号'),
    RegExp(r'\d{11,}'),
  ];

  /// 临时性措辞：出现这些词，又没有稳定标记，就当一次性闲聊丢掉。
  static const List<String> transientMarkers = [
    '今天', '刚才', '刚刚', '这次', '等下', '一会儿', '待会', '这会儿', '马上', '现在'
  ];

  /// 稳定标记：反复出现或明确声明的习惯才留。
  static const List<String> stableMarkers = [
    '每次', '总是', '一直', '从来', '向来', '习惯', '一般', '平时',
    '最喜欢', '最讨厌', '不喜欢', '都会', '每年', '生日', '纪念日'
  ];

  String _system() => '''
你是「用户行为记录员」。下面只给你【用户自己说的话】和【已经记过的条目】。
判断其中有没有值得长期记住的、稳定的用户行为习惯或事实，谨慎地挑出来。

只记这几类（category 必须原样使用）：${UserNote.categories.join(' / ')}

必须记的：
- 反复出现的行为模式、明确说出口的好恶、稳定的生活习惯、身份事实、重要关系、重要日期。
- 用户明确声明的偏好，例如「我不吃香菜」「我习惯晚睡」「我每次出差都…」。

一定不要记：
- 一次性闲聊、临时情绪（今天累了、刚才有点烦）、随口一提、寒暄、玩笑、反问。
- 某一次的具体安排（等下吃饭、这会儿在忙）。
- 用户转述的别人的事、猜测、假设、AI 说的话。
- 证件号、银行卡、密码、验证码、手机号、详细住址等隐私信息。
- 已经记录过的内容，换个说法也别重复记。

每条必须给出 evidence：用户原话里支持这条判断的依据（摘一小段原话）。没有依据就不要记。
confidence 只给 0.75 以上；低于 0.75 的直接不输出。

输出严格一个 JSON 对象，不要 markdown 代码块，不要解释：
{"items":[{"category":"生活习惯","content":"一句话写清这条习惯","confidence":0.9,"evidence":"用户原话片段"}]}
没有值得记的就输出 {"items":[]}。
''';

  /// 评一次最近对话，返回实际新增的条数。失败静默，绝不打扰聊天。
  Future<int> review({
    required String apiKey,
    required List<ChatMessage> recent,
  }) async {
    if (apiKey.trim().isEmpty) return 0;
    final userLines = recent
        .where((m) => m.fromUser)
        .map((m) => m.content.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (userLines.length < 2) return 0;

    final existing = await DbHelper.instance.userNotes();
    if (existing.length >= maxNotes) return 0;

    List<ManualCandidate> candidates;
    try {
      final m = await _llm.completeJson(
        apiKey: apiKey,
        system: _system(),
        user: jsonEncode({
          '用户最近说的话': userLines,
          '已经记录过的条目': existing.map((e) => e.content).toList(),
        }),
        temperature: 0.2,
        maxTokens: 900,
      );
      final items = (m['items'] as List?) ?? <dynamic>[];
      candidates = items
          .whereType<Map>()
          .map((e) => ManualCandidate.fromMap(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return 0;
    }

    final accepted = applyRules(candidates, existing);
    for (final c in accepted) {
      await DbHelper.instance.insertNote(UserNote(
        category: c.category,
        content: c.content.trim(),
        confidence: c.confidence,
        evidence: c.evidence.trim(),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    return accepted.length;
  }

  /// 本地硬规则，公开出来方便单独测试。
  List<ManualCandidate> applyRules(
      List<ManualCandidate> candidates, List<UserNote> existing) {
    final accepted = <ManualCandidate>[];
    final seen = <String>[for (final e in existing) e.content];

    for (final c in candidates) {
      if (existing.length + accepted.length >= maxNotes) break;
      if (!UserNote.categories.contains(c.category)) continue;
      if (c.confidence < minConfidence) continue;

      final t = c.content.trim();
      if (t.length < minLength || t.length > maxLength) continue;
      if (c.evidence.trim().isEmpty) continue;
      if (privacyPatterns.any((r) => r.hasMatch(t) || r.hasMatch(c.evidence))) {
        continue;
      }

      final transient = transientMarkers.any((w) => t.contains(w));
      final stable =
          stableMarkers.any((w) => t.contains(w) || c.evidence.contains(w));
      if (transient && !stable) continue;

      if (_duplicate(t, seen)) continue;
      seen.add(t);
      accepted.add(c);
    }
    return accepted;
  }

  bool _duplicate(String text, List<String> seen) {
    final a = text.replaceAll(RegExp(r'\s+'), '');
    for (final s in seen) {
      final b = s.replaceAll(RegExp(r'\s+'), '');
      if (a == b || a.contains(b) || b.contains(a)) return true;
      final setA = a.split('').toSet();
      final setB = b.split('').toSet();
      final union = setA.union(setB).length;
      if (union > 0 && setA.intersection(setB).length / union > 0.8) {
        return true;
      }
    }
    return false;
  }
}
