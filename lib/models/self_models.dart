import '../models/journal.dart';

/// R2 自我认知的数据模型（设计 §3.1 / T04）。
///
/// 四件事分开装：
/// - [SelfProfile]：`self:v1` 聚合视图（单赢家）。
/// - [SelfFact]：`self_fact` 一条一行、可单删；**data 里绝不写 isReal/hardFact**，
///   标记一律展示期现算（PRD B9 硬约束：写进云端等于把判定冻死、改不回来）。
/// - [SelfNote]：`self_note` 每日自述。
/// - [DeletedFactList]：本机 `deleted_self_facts.json`，**只有 sha16 + ts**，
///   不进云、不进导出、界面不展示（PRD D6 / B10）。

/// 一条自生长事实的来源。至少 1 个 message key 或 chunk key 才算可追溯。
class SelfSource {
  final List<String> messageKeys;
  final String chunkKey;
  final String quote;

  const SelfSource({
    this.messageKeys = const <String>[],
    this.chunkKey = '',
    this.quote = '',
  });

  bool get isTraceable =>
      messageKeys.isNotEmpty || chunkKey.trim().isNotEmpty;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'messageKeys': List<String>.from(messageKeys),
        'chunkKey': chunkKey,
        'quote': quote,
      };

  static SelfSource fromMap(Object? raw) {
    if (raw is! Map) return const SelfSource();
    final ms = raw['messageKeys'];
    final keys = <String>[];
    if (ms is List) {
      for (final k in ms) {
        if (k is String && k.trim().isNotEmpty) keys.add(k);
      }
    }
    return SelfSource(
      messageKeys: keys,
      chunkKey: raw['chunkKey'] is String ? raw['chunkKey'] as String : '',
      quote: raw['quote'] is String ? raw['quote'] as String : '',
    );
  }
}

/// 一条自生长事实。`hash = sha16(text.trim())` 同时是 journal key 的后半段。
class SelfFact {
  final String hash;
  final String text;
  final SelfSource source;
  final int createdAt;
  final String weekKey;

  const SelfFact({
    required this.hash,
    required this.text,
    required this.source,
    required this.createdAt,
    this.weekKey = '',
  });

  /// 云母库里的 key，与 Node `keyForSelfFact` 同一个算法。
  String get key => journalKeyForSelfFact(text);

  bool get isTraceable => source.isTraceable;

  /// 落 journal 的 data。**不含 cap**（由 buildJournalLine 自动注入）、
  /// 不含 isReal/hardFact 标记（展示期现算）。
  Map<String, dynamic> toData() => <String, dynamic>{
        'text': text,
        'hash': hash,
        'source': source.toMap(),
        'createdAt': createdAt,
        'weekKey': weekKey,
      };

  static SelfFact fromData(Map<String, dynamic> d) {
    final text = d['text'] is String ? d['text'] as String : '';
    return SelfFact(
      hash: d['hash'] is String && (d['hash'] as String).isNotEmpty
          ? d['hash'] as String
          : journalKeyForSelfFact(text).split(':').last,
      text: text,
      source: SelfSource.fromMap(d['source']),
      createdAt: d['createdAt'] is int ? d['createdAt'] as int : 0,
      weekKey: d['weekKey'] is String ? d['weekKey'] as String : '',
    );
  }
}

/// `self:v1` 的聚合视图。单赢家，读者取 ts 最大那行。
class SelfProfile {
  final String text;
  final List<String> facts;
  final int derivedAt;
  final String reason;

  const SelfProfile({
    this.text = '',
    this.facts = const <String>[],
    this.derivedAt = 0,
    this.reason = '',
  });

  Map<String, dynamic> toData() => <String, dynamic>{
        'text': text,
        'facts': List<String>.from(facts),
        'derivedAt': derivedAt,
        'reason': reason,
      };

  static SelfProfile fromData(Map<String, dynamic> d) {
    final facts = <String>[];
    if (d['facts'] is List) {
      for (final f in (d['facts'] as List)) {
        if (f is String) facts.add(f);
      }
    }
    return SelfProfile(
      text: d['text'] is String ? d['text'] as String : '',
      facts: facts,
      derivedAt: d['derivedAt'] is int ? d['derivedAt'] as int : 0,
      reason: d['reason'] is String ? d['reason'] as String : '',
    );
  }
}

/// 每日自述 `self_note`：≤60 字第一人称。
class SelfNote {
  final String dayKey;
  final String text;
  final int createdAt;

  const SelfNote({
    required this.dayKey,
    required this.text,
    required this.createdAt,
  });

  String get key => journalKeyForSelfNote(dayKey, text);

  Map<String, dynamic> toData() => <String, dynamic>{
        'text': text,
        'dayKey': dayKey,
        'createdAt': createdAt,
      };

  static SelfNote fromData(Map<String, dynamic> d) => SelfNote(
        dayKey: d['dayKey'] is String ? d['dayKey'] as String : '',
        text: d['text'] is String ? d['text'] as String : '',
        createdAt: d['createdAt'] is int ? d['createdAt'] as int : 0,
      );
}

/// 一条本机删除记录。**只有 sha16 + ts**（几十字节，PRD D6 / B8）。
class DeletionEntry {
  final String sha16;
  final int ts;

  const DeletionEntry({required this.sha16, required this.ts});

  Map<String, dynamic> toMap() => <String, dynamic>{'sha16': sha16, 'ts': ts};

  static DeletionEntry fromMap(Object? raw) {
    if (raw is! Map) return const DeletionEntry(sha16: '', ts: 0);
    return DeletionEntry(
      sha16: raw['sha16'] is String ? raw['sha16'] as String : '',
      ts: raw['ts'] is int ? raw['ts'] as int : 0,
    );
  }
}

/// 本机删除清单。持久化的 items 只有 sha16 + ts；
/// 关键词只存在于内存（删除当时由原文现算），**不落盘**——
/// PRD 已知缺口一：只有哈希、没有关键词 ⇒ 跨进程近似措辞拦不住（不算缺陷）。
class DeletedFactList {
  final List<DeletionEntry> items;

  /// 内存关键词索引：从被删事实原文抽出，重启后为空（与已知缺口一致）。
  final Set<String> keywords;

  const DeletedFactList({
    this.items = const <DeletionEntry>[],
    this.keywords = const <String>{},
  });

  bool containsHash(String hash) =>
      items.any((e) => e.sha16.isNotEmpty && e.sha16 == hash);

  /// 关键词 contains 命中：候选关键词与任一被删关键词互相包含。
  String? keywordHit(Iterable<String> candidateKeywords) {
    for (final k in candidateKeywords) {
      if (k.isEmpty) continue;
      for (final dk in keywords) {
        if (dk.isNotEmpty && (dk.contains(k) || k.contains(dk))) return dk;
      }
    }
    return null;
  }

  /// 追加一条删除（sha16 + ts）。[keywords] 是当时从原文现算的，仅进内存。
  DeletedFactList add(SelfFact fact, Iterable<String> keywords, int ts) {
    final next = <DeletionEntry>[...items, DeletionEntry(sha16: fact.hash, ts: ts)];
    final kw = <String>{...this.keywords, ...keywords};
    return DeletedFactList(items: next, keywords: kw);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': 1,
        'items': items.map((e) => e.toMap()).toList(),
      };

  static DeletedFactList fromJson(Object? raw) {
    if (raw is! Map) return const DeletedFactList();
    final list = raw['items'];
    final items = <DeletionEntry>[];
    if (list is List) {
      for (final e in list) {
        final entry = DeletionEntry.fromMap(e);
        if (entry.sha16.isNotEmpty) items.add(entry);
      }
    }
    return DeletedFactList(items: items);
  }
}
