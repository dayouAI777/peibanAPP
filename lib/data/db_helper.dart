import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/companion.dart';
import '../models/memory_chunk.dart';
import '../models/message.dart';
import '../models/style_example.dart';
import '../models/user_note.dart';

/// 本地数据库。所有数据都在这台手机的 App 沙盒里，不上传任何服务器。
/// v2：新增人设空间、用户行为手册、旧对话压缩摘要三张/列。
/// v3：messages 加 image_path 列（用户发图片，模型看图）。
/// v4：新增 style_examples 表（用户长按消息、亲手改的「她该这么说」范例）。
class DbHelper {
  DbHelper._();
  static final DbHelper instance = DbHelper._();

  static Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'peiban.db'),
      version: 4,
      onCreate: (d, _) async => _createAll(d),
      onUpgrade: (d, oldV, _) async {
        if (oldV < 2) {
          // 旧版角色保留聊天记录，但人设空间为空 → App 会提示需要重建
          await d.execute(
              "ALTER TABLE companions ADD COLUMN persona_space TEXT NOT NULL DEFAULT ''");
          await _createNotes(d);
          await _createChunks(d);
        }
        if (oldV < 3) {
          await d.execute(
              "ALTER TABLE messages ADD COLUMN image_path TEXT NOT NULL DEFAULT ''");
        }
        if (oldV < 4) {
          await _createStyleExamples(d);
        }
      },
    );
    return _db!;
  }

  Future<void> _createAll(Database d) async {
    await d.execute('''
      CREATE TABLE companions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        persona TEXT NOT NULL,
        greeting TEXT NOT NULL,
        avatar_path TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        persona_space TEXT NOT NULL DEFAULT ''
      )
    ''');
    await d.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        companion_id INTEGER NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        is_proactive INTEGER NOT NULL DEFAULT 0,
        image_path TEXT NOT NULL DEFAULT ''
      )
    ''');
    await d.execute(
        'CREATE INDEX idx_messages_companion ON messages(companion_id, id)');
    await _createNotes(d);
    await _createChunks(d);
    await _createStyleExamples(d);
  }

  Future<void> _createNotes(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS user_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category TEXT NOT NULL,
        content TEXT NOT NULL,
        confidence REAL NOT NULL,
        evidence TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _createChunks(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS memory_chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        companion_id INTEGER NOT NULL,
        from_id INTEGER NOT NULL,
        to_id INTEGER NOT NULL,
        summary TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_chunks ON memory_chunks(companion_id, from_id)');
  }

  /// 用户亲手改过的「她该这么说」范例。属于角色，删角色时一起清掉。
  Future<void> _createStyleExamples(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS style_examples (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        companion_id INTEGER NOT NULL,
        trigger_text TEXT NOT NULL DEFAULT '',
        original TEXT NOT NULL,
        preferred TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_style ON style_examples(companion_id, id)');
  }

  // ——— 角色：唯一、定稿后不可改（所以这里故意没有 update 方法）———
  Future<Companion?> firstCompanion() async {
    final rows =
        await (await db).query('companions', orderBy: 'id ASC', limit: 1);
    if (rows.isEmpty) return null;
    return Companion.fromMap(rows.first);
  }

  Future<int> insertCompanion(Companion c) async {
    final m = c.toMap()..remove('id');
    return (await db).insert('companions', m);
  }

  /// 只允许改外观：头像 + 昵称。
  /// 性格（persona）、人设空间（persona_space）、开场白一律不在这个方法里，
  /// 数据库层就不给改性格的口子。
  Future<void> updateAppearance({
    required int id,
    required String name,
    required String avatarPath,
  }) async {
    await (await db).update(
      'companions',
      {'name': name, 'avatar_path': avatarPath},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ——— 聊天记录 ———
  Future<List<ChatMessage>> messages(int companionId,
      {int limit = 1000}) async {
    final rows = await (await db).query(
      'messages',
      where: 'companion_id = ?',
      whereArgs: [companionId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(ChatMessage.fromMap).toList().reversed.toList();
  }

  Future<int> messageCount(int companionId) async {
    final r = await (await db).rawQuery(
        'SELECT COUNT(*) AS c FROM messages WHERE companion_id = ?',
        [companionId]);
    return (r.first['c'] as int?) ?? 0;
  }

  /// 按消息 id 区间取，用于把一段旧对话压成摘要。
  Future<List<ChatMessage>> messagesInRange(
      int companionId, int fromId, int toId) async {
    final rows = await (await db).query(
      'messages',
      where: 'companion_id = ? AND id >= ? AND id <= ?',
      whereArgs: [companionId, fromId, toId],
      orderBy: 'id ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<int> insertMessage(ChatMessage m) async {
    return (await db).insert('messages', m.toMap()..remove('id'));
  }

  /// 只改内容，不动时间、不动角色归属——用于「长按改她这句话」。
  Future<void> updateMessageContent(int id, String content) async {
    await (await db).update(
      'messages',
      {'content': content},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 清空聊天记录。
  /// 注意：style_examples 是用户亲手写的调教成果，不算「聊天记录」，这里保留；
  /// 只有删角色（deleteEverything）才会一起清掉。
  Future<void> clearMessages(int companionId) async {
    final d = await db;
    await d.delete('messages',
        where: 'companion_id = ?', whereArgs: [companionId]);
    await d.delete('memory_chunks',
        where: 'companion_id = ?', whereArgs: [companionId]);
  }

  // ——— 用户亲手改的说法 ———
  /// 取最新的若干条（id 倒序后再翻正，交给 prompt 按时间顺序排）。
  Future<List<StyleExample>> styleExamples(int companionId,
      {int limit = 40}) async {
    final rows = await (await db).query(
      'style_examples',
      where: 'companion_id = ?',
      whereArgs: [companionId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(StyleExample.fromMap).toList().reversed.toList();
  }

  Future<int> insertStyleExample(StyleExample e) async {
    return (await db).insert('style_examples', e.toMap()..remove('id'));
  }

  Future<void> deleteStyleExample(int id) async {
    await (await db)
        .delete('style_examples', where: 'id = ?', whereArgs: [id]);
  }

  // ——— 用户行为记录手册 ———
  Future<List<UserNote>> userNotes() async {
    final rows =
        await (await db).query('user_notes', orderBy: 'created_at DESC');
    return rows.map(UserNote.fromMap).toList();
  }

  Future<int> insertNote(UserNote n) async {
    return (await db).insert('user_notes', n.toMap()..remove('id'));
  }

  Future<void> deleteNote(int id) async {
    await (await db).delete('user_notes', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearNotes() async => (await db).delete('user_notes');

  // ——— 压缩记忆 ———
  Future<List<MemoryChunk>> memoryChunks(int companionId) async {
    final rows = await (await db).query(
      'memory_chunks',
      where: 'companion_id = ?',
      whereArgs: [companionId],
      orderBy: 'from_id ASC',
    );
    return rows.map(MemoryChunk.fromMap).toList();
  }

  Future<int> insertChunk(MemoryChunk c) async {
    return (await db).insert('memory_chunks', c.toMap()..remove('id'));
  }

  // ——— 云母库导出（只读，不破坏任何现有查询签名） ———

  /// 全量聊天记录导出（云母库推送用）。messages() 平时按上下文窗口截取，
  /// 上云必须全量——对话一条都不能少。
  Future<List<ChatMessage>> exportAllMessages(int companionId) async {
    final rows = await (await db).query(
      'messages',
      where: 'companion_id = ?',
      whereArgs: [companionId],
      orderBy: 'id ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  /// 全量「她该这么说」范例导出。styleExamples() 平时只取最新 40 条，
  /// 上云必须全量——用户亲手写的调教成果一条都不能丢。
  Future<List<StyleExample>> exportAllStyleExamples(int companionId) async {
    final rows = await (await db).query(
      'style_examples',
      where: 'companion_id = ?',
      whereArgs: [companionId],
      orderBy: 'id ASC',
    );
    return rows.map(StyleExample.fromMap).toList();
  }

  // ——— 记忆上云：从云端补缺 ———

  /// 把云端云母库记录合并进本地库。铁律：**只补缺，不覆盖、不删除本地任何一条**。
  ///
  /// 合并规则（V1 定死，别自创）：
  /// - 以角色为锚：本地已有角色 → 云端的角色/人设字段一律忽略（人设定稿不可改）；
  ///   本地没有角色 → 才用云端那份建一个（persona / personaSpace / greeting / name 原样入）。
  /// - notes：按 (category, content) 去重补缺（全局表，不挂角色）。
  /// - styleExamples：按 (original, preferred) 去重补缺。
  /// - memoryChunks：按 (from_id, to_id, summary) 去重补缺。
  /// - messages：按 (role, created_at) 去重补缺（content 不进键：本地改写过的
  ///   消息以本地为准，防止云端旧原文复活成重复条目）；image_path 是另一台设备的
  ///   沙盒路径，到这边一定是死链，一律置空。
  ///
  /// 每一行插入前都做类型/空值校验：云端坏行直接跳过并继续，
  /// 不让单行毒死整个事务（否则 NOT NULL 约束会把整个恢复无声归零）。
  ///
  /// 整个过程在一个事务里：任何一步失败整体回滚，不会留下半份恢复数据。
  /// 返回各类实际新增的条数，给用户一个「补了多少」的交代。
  Future<Map<String, int>> restoreCloudData({
    Map<String, dynamic>? companion,
    List<Map<String, dynamic>> notes = const [],
    List<Map<String, dynamic>> styleExamples = const [],
    List<Map<String, dynamic>> memoryChunks = const [],
    List<Map<String, dynamic>> messages = const [],
  }) async {
    final d = await db;
    return d.transaction((txn) async {
      var addedCompanion = 0;
      var addedNotes = 0;
      var addedExamples = 0;
      var addedChunks = 0;
      var addedMessages = 0;

      // 1. 角色：本地没有才建。字段类型不对的兜成默认值，保证 NOT NULL 不炸。
      final local = await txn.query('companions', orderBy: 'id ASC', limit: 1);
      int? cid = local.isEmpty ? null : (local.first['id'] as int?);
      if (cid == null && companion != null) {
        final persona = companion['persona'];
        if (persona is String && persona.trim().isNotEmpty) {
          final m = Map<String, dynamic>.from(companion)..remove('id');
          // 头像文件在原来那台手机的沙盒里，这里恢复不了，置空让用户重选
          m['avatar_path'] = '';
          if (m['name'] is! String || (m['name'] as String).isEmpty) {
            m['name'] = 'TA';
          }
          if (m['greeting'] is! String) m['greeting'] = '';
          if (m['created_at'] is! int) {
            m['created_at'] = DateTime.now().millisecondsSinceEpoch;
          }
          if (m['persona_space'] is! String) m['persona_space'] = '';
          cid = await txn.insert('companions', m);
          addedCompanion = 1;
        }
      }
      if (cid == null) {
        return <String, int>{
          'companion': 0,
          'notes': 0,
          'styleExamples': 0,
          'memoryChunks': 0,
          'messages': 0,
        };
      }

      // 2. 用户行为手册（全局表）。缺列兜默认值，坏行跳过，不让 NOT NULL 毒死事务。
      if (notes.isNotEmpty) {
        final have = <String>{};
        for (final r in await txn.query('user_notes',
            columns: ['category', 'content'])) {
          have.add('${r['category']}\u241F${r['content']}');
        }
        for (final n in notes) {
          if (n['created_at'] is! int) continue;
          final content = n['content'];
          if (content is! String || content.trim().isEmpty) continue;
          final category = n['category'] is String && (n['category'] as String).isNotEmpty
              ? n['category'] as String
              : '稳定偏好';
          final m = <String, dynamic>{
            'category': category,
            'content': content,
            'confidence': n['confidence'] is num ? n['confidence'] : 0,
            'evidence': n['evidence'] is String ? n['evidence'] : '',
            'created_at': n['created_at'],
          };
          final key = '$category\u241F$content';
          if (have.contains(key)) continue;
          await txn.insert('user_notes', m);
          have.add(key);
          addedNotes++;
        }
      }

      // 3. 说话范例：同 original+preferred 不重复（与 correctReply 的去重口径一致）。
      if (styleExamples.isNotEmpty) {
        final have = <String>{};
        for (final r in await txn.query('style_examples',
            where: 'companion_id = ?',
            whereArgs: [cid],
            columns: ['original', 'preferred'])) {
          have.add('${r['original']}\u241F${r['preferred']}');
        }
        for (final e in styleExamples) {
          if (e['created_at'] is! int) continue;
          final original = e['original'];
          final preferred = e['preferred'];
          if (original is! String || preferred is! String) continue;
          if (preferred.trim().isEmpty) continue;
          final m = <String, dynamic>{
            'companion_id': cid,
            'trigger_text': e['trigger_text'] is String ? e['trigger_text'] : '',
            'original': original,
            'preferred': preferred,
            'created_at': e['created_at'],
          };
          final key = '$original\u241F$preferred';
          if (have.contains(key)) continue;
          await txn.insert('style_examples', m);
          have.add(key);
          addedExamples++;
        }
      }

      // 4. 压缩记忆摘要。
      if (memoryChunks.isNotEmpty) {
        final have = <String>{};
        for (final r in await txn.query('memory_chunks',
            where: 'companion_id = ?',
            whereArgs: [cid],
            columns: ['from_id', 'to_id', 'summary'])) {
          have.add('${r['from_id']}\u241F${r['to_id']}\u241F${r['summary']}');
        }
        for (final c in memoryChunks) {
          if (c['created_at'] is! int) continue;
          final summary = c['summary'];
          if (summary is! String || summary.trim().isEmpty) continue;
          final fromId = c['from_id'] is int ? c['from_id'] : 0;
          final toId = c['to_id'] is int ? c['to_id'] : 0;
          final m = <String, dynamic>{
            'companion_id': cid,
            'from_id': fromId,
            'to_id': toId,
            'summary': summary,
            'created_at': c['created_at'],
          };
          final key = '$fromId\u241F$toId\u241F$summary';
          if (have.contains(key)) continue;
          await txn.insert('memory_chunks', m);
          have.add(key);
          addedChunks++;
        }
      }

      // 5. 聊天记录：按 (role, created_at) 去重补缺，一条不删。
      //    不把 content 放进键：本地可能已经「长按改她的话」改写过内容，
      //    云端快照里是改前原文——同键一律跳过（本地为主），否则原文会复活成重复消息。
      if (messages.isNotEmpty) {
        final have = <String>{};
        for (final r in await txn.query('messages',
            where: 'companion_id = ?',
            whereArgs: [cid],
            columns: ['role', 'created_at'])) {
          have.add('${r['role']}\u241F${r['created_at']}');
        }
        for (final msg in messages) {
          final m = Map<String, dynamic>.from(msg)
            ..remove('id')
            ..['companion_id'] = cid
            // 图片文件存在发图那台手机的沙盒里，这里恢复不了，直接置空
            ..['image_path'] = '';
          final key = '${m['role']}\u241F${m['created_at']}';
          if (have.contains(key)) continue;
          if (m['role'] is! String) continue;
          if ((m['content'] as String?)?.trim().isEmpty ?? true) continue;
          if (m['created_at'] is! int) continue;
          await txn.insert('messages', m);
          have.add(key);
          addedMessages++;
        }
      }

      return <String, int>{
        'companion': addedCompanion,
        'notes': addedNotes,
        'styleExamples': addedExamples,
        'memoryChunks': addedChunks,
        'messages': addedMessages,
      };
    });
  }

  Future<void> deleteEverything() async {
    final d = await db;
    await d.delete('messages');
    await d.delete('memory_chunks');
    await d.delete('user_notes');
    await d.delete('style_examples');
    await d.delete('companions');
  }
}
