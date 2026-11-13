import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/companion.dart';
import '../models/message.dart';

/// 本地数据库。所有数据都在这台手机的 App 沙盒里，不上传任何服务器。
class DbHelper {
  DbHelper._();
  static final DbHelper instance = DbHelper._();

  static Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'peiban.db'),
      version: 1,
      onCreate: (d, _) async {
        await d.execute('''
          CREATE TABLE companions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            persona TEXT NOT NULL,
            greeting TEXT NOT NULL,
            avatar_path TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await d.execute('''
          CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            companion_id INTEGER NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            is_proactive INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await d.execute(
            'CREATE INDEX idx_messages_companion ON messages(companion_id, id)');
      },
    );
    return _db!;
  }

  Future<Companion?> firstCompanion() async {
    final rows = await (await db).query('companions', orderBy: 'id ASC', limit: 1);
    if (rows.isEmpty) return null;
    return Companion.fromMap(rows.first);
  }

  Future<int> insertCompanion(Companion c) async {
    final m = c.toMap()..remove('id');
    return (await db).insert('companions', m);
  }

  Future<void> updateCompanion(Companion c) async {
    await (await db).update('companions', c.toMap()..remove('id'),
        where: 'id = ?', whereArgs: [c.id]);
  }

  /// 取某个角色的最近 n 条消息，按时间正序返回（方便直接喂给聊天界面）。
  Future<List<ChatMessage>> messages(int companionId, {int limit = 200}) async {
    final rows = await (await db).query(
      'messages',
      where: 'companion_id = ?',
      whereArgs: [companionId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(ChatMessage.fromMap).toList().reversed.toList();
  }

  Future<int> insertMessage(ChatMessage m) async {
    return (await db).insert('messages', m.toMap()..remove('id'));
  }

  Future<void> clearMessages(int companionId) async {
    await (await db)
        .delete('messages', where: 'companion_id = ?', whereArgs: [companionId]);
  }

  Future<void> deleteEverything() async {
    final d = await db;
    await d.delete('messages');
    await d.delete('companions');
  }
}
