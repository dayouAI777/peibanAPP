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

  Future<void> deleteEverything() async {
    final d = await db;
    await d.delete('messages');
    await d.delete('memory_chunks');
    await d.delete('user_notes');
    await d.delete('style_examples');
    await d.delete('companions');
  }
}
