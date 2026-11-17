import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 云母库（journal.jsonl）协议：手机端、电脑 Agent 端三方共用的追加日志。
///
/// 铁律（用户拍板的架构口径，不许自创方案）：
/// - **云端是唯一权威，只增、不删、不覆盖**。任何写入方都只「往里追加」，
///   重新上传时云端已有的行必须原样保留，一行不删不改。
/// - 每条记录有**确定性指纹 key**（由内容算出），各方各自判断「云端有没有这条」
///   再决定加不加；即使并发写互相覆盖了对方的追加行，下一次对齐会因 key 仍缺失
///   而自动补回——自我修复。
/// - 文件是 UTF-8 JSONL：每行一个 JSON 对象。任何一行解析失败 → 跳过该行继续，
///   绝不因坏行崩掉整个文件（本地为主、坏行净化的老规矩平移到这里）。
/// - 文件不存在（NOT_FOUND）视为空库，不是错误。
///
/// 行格式：
/// ```json
/// {"v":1,"type":"message","key":"m:user:1700000001000","ts":1700000001000,"dev":"phone","data":{...}}
/// ```
///
/// key 规则（双方各自推导结果必须相同）：
/// - message：`m:<role>:<createdAt>`
/// - note：`n:` + sha256(category+'|'+content) 前 16 位 hex
/// - style_example：`s:` + sha256(original+'|'+preferred) 前 16 位 hex
/// - memory_chunk：`c:` + sha256(fromId+'|'+toId+'|'+summary) 前 16 位 hex
/// - speech_profile：固定 `sp:v1`（整对象一条，读者取该 type 的最新 ts 那行）
/// - style_profile：固定 `stp:v1`（同上；「她的说话方式档案」，手机是唯一
///   蒸馏写入方，电脑 Agent 端只读）
/// - persona：固定 `persona:v1`（同上）
class JournalLine {
  /// 协议版本。读取方只认自己支持的版本，未来版本留给未来的读者。
  static const int protocolVersion = 1;

  // ——— 记录类型 ———
  static const String typeMessage = 'message';
  static const String typeNote = 'note';
  static const String typeStyleExample = 'style_example';
  static const String typeMemoryChunk = 'memory_chunk';
  static const String typeSpeechProfile = 'speech_profile';
  static const String typeStyleProfile = 'style_profile';
  static const String typePersona = 'persona';

  /// 本协议认识的全部类型。类型不认识（未来版本写入的）→ 解析时跳过该行。
  static const Set<String> knownTypes = <String>{
    typeMessage,
    typeNote,
    typeStyleExample,
    typeMemoryChunk,
    typeSpeechProfile,
    typeStyleProfile,
    typePersona,
  };

  /// speech_profile / style_profile / persona 是「整对象一条」：key 固定，
  /// 读者取同 key 中 ts 最大的一行生效。
  bool get isSingleWinner =>
      type == typeSpeechProfile ||
      type == typeStyleProfile ||
      type == typePersona;

  final String type;
  final String key;

  /// 该记录产生/导出时间（毫秒）。同一 key 多行时，时间新的生效。
  final int ts;

  /// 写入方标识：`phone` / `agent`。本版手机端写死 phone。
  final String dev;

  /// 该类型对应的本地模型 toJson()（沿用现有模型字段）。
  final Map<String, dynamic> data;

  const JournalLine({
    required this.type,
    required this.key,
    required this.ts,
    this.dev = 'phone',
    required this.data,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': protocolVersion,
        'type': type,
        'key': key,
        'ts': ts,
        'dev': dev,
        'data': data,
      };

  /// 一行 JSONL 文本。jsonEncode 会把 data 里的换行转义成 \n，
  /// 所以一行永远是一条记录，不会把文件撑裂。
  String encode() => jsonEncode(toJson());

  /// 安全解析一行 JSON 对象（解析已由 [parseJournalLines] 完成 try/catch）。
  /// 字段类型不对的按默认值兜底，绝不抛。
  factory JournalLine.fromMap(Map<dynamic, dynamic> m) => JournalLine(
        type: m['type'] is String ? m['type'] as String : '',
        key: m['key'] is String ? m['key'] as String : '',
        ts: m['ts'] is int ? m['ts'] as int : 0,
        dev: m['dev'] is String ? m['dev'] as String : '',
        data: copyStringMap(m['data']),
      );
}

/// 把任意来源的 Map 浅拷贝成 `Map<String, dynamic>`：
/// 非 String 键的条目丢弃，其余原样保留（int / list / 嵌套 map 都不动）。
Map<String, dynamic> copyStringMap(Object? raw) {
  if (raw is! Map) return const <String, dynamic>{};
  final out = <String, dynamic>{};
  raw.forEach((k, v) {
    if (k is String) out[k] = v;
  });
  return out;
}

// ——— 确定性指纹 key ———

String _hex16(String input) =>
    sha256.convert(utf8.encode(input)).toString().substring(0, 16);

/// message 的 key：role + createdAt 就够唯一（恢复侧去重口径也是这对）。
String journalKeyForMessage(String role, int createdAt) => 'm:$role:$createdAt';

String journalKeyForNote(String category, String content) =>
    'n:${_hex16('$category|$content')}';

String journalKeyForStyleExample(String original, String preferred) =>
    's:${_hex16('$original|$preferred')}';

String journalKeyForMemoryChunk(int fromId, int toId, String summary) =>
    'c:${_hex16('$fromId|$toId|$summary')}';

/// speech_profile 的固定 key（整对象一条）。
const String journalKeySpeechProfile = 'sp:v1';

/// style_profile（她的说话方式档案）的固定 key（整对象一条）。
const String journalKeyStyleProfile = 'stp:v1';

/// persona 的固定 key（整对象一条）。
const String journalKeyPersona = 'persona:v1';

// ——— 构建与解析 ———

/// 构建一行 JSONL 文本。纯函数，可单测；Agent 端未来照抄同一份规则。
String buildJournalLine({
  required String type,
  required String key,
  required int ts,
  String dev = 'phone',
  required Map<String, dynamic> data,
}) =>
    jsonEncode(<String, dynamic>{
      'v': JournalLine.protocolVersion,
      'type': type,
      'key': key,
      'ts': ts,
      'dev': dev,
      'data': data,
    });

/// 解析整份 journal.jsonl 文本 → 全部有效行。
///
/// 铁律：任何一行解析失败 → 跳过该行继续，绝不抛异常、绝不因坏行丢掉好行。
/// 跳过规则：空行 / 坏 JSON / 不是对象 / v 不是本协议版本 / type 不认识 /
/// key 为空或类型不对 / data 不是对象。
List<JournalLine> parseJournalLines(String raw) {
  final out = <JournalLine>[];
  if (raw.isEmpty) return out;
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(t);
    } catch (_) {
      continue; // 坏 JSON：跳过这行，继续读后面的
    }
    if (decoded is! Map) continue;
    if (decoded['v'] != JournalLine.protocolVersion) continue;
    final type = decoded['type'];
    final key = decoded['key'];
    final data = decoded['data'];
    if (type is! String || !JournalLine.knownTypes.contains(type)) continue;
    if (key is! String || key.isEmpty) continue;
    if (data is! Map) continue;
    out.add(JournalLine.fromMap(decoded));
  }
  return out;
}

/// 从全部有效行里挑出「应生效」的行：
/// - 普通类型（message/note/style_example/memory_chunk）：全部保留，
///   调用方自己按 key 去重；
/// - speech_profile / persona：同 key 取 ts 最大的一行（平局取后出现的）。
List<JournalLine> resolveEffectiveLines(List<JournalLine> lines) {
  final out = <JournalLine>[];
  final singleIdx = <String, int>{}; // key -> 在 out 中的下标
  for (final l in lines) {
    if (!l.isSingleWinner) {
      out.add(l);
      continue;
    }
    final idx = singleIdx[l.key];
    if (idx == null) {
      out.add(l);
      singleIdx[l.key] = out.length - 1;
    } else if (l.ts >= out[idx].ts) {
      out[idx] = l;
    }
  }
  return out;
}

/// 云端原文 + 新追加行 → 合并后的整份 journal 文本。
///
/// 追加合并，不是快照覆盖：**原文一行不动**（包括坏行也原样保留），
/// 追加行按顺序排在后面。返回文本以换行结尾（空文件返回空串）。
/// 纯函数，可单测；Agent 端未来照抄同一份规则。
String mergeJournal(String rawCloudText, List<JournalLine> appended) {
  final lines = <String>[];
  if (rawCloudText.trim().isNotEmpty) {
    for (final l in rawCloudText.split('\n')) {
      if (l.trim().isEmpty) continue;
      lines.add(l);
    }
  }
  for (final l in appended) {
    lines.add(l.encode());
  }
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}
