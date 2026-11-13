import 'dart:convert';

/// 一个陪伴角色。全局唯一，定稿后不可修改，只能删除重建。
class Companion {
  final int? id;
  final String name;
  final String persona; // 给大模型看的 system prompt（角色的「灵魂」）
  final String greeting; // 角色第一次开口说的话
  final String avatarPath; // 用户上传的参考图，已复制进 App 私有目录
  final String personaSpace; // 定稿的人设空间 JSON，只读留档
  final int createdAt;

  const Companion({
    this.id,
    required this.name,
    required this.persona,
    required this.greeting,
    required this.avatarPath,
    required this.createdAt,
    this.personaSpace = '',
  });

  bool get hasPersonaSpace => personaSpace.trim().isNotEmpty;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'persona': persona,
        'greeting': greeting,
        'avatar_path': avatarPath,
        'created_at': createdAt,
        'persona_space': personaSpace,
      };

  factory Companion.fromMap(Map<String, dynamic> m) => Companion(
        id: m['id'] as int?,
        name: (m['name'] as String?) ?? 'TA',
        persona: (m['persona'] as String?) ?? '',
        greeting: (m['greeting'] as String?) ?? '',
        avatarPath: (m['avatar_path'] as String?) ?? '',
        createdAt: (m['created_at'] as int?) ?? 0,
        personaSpace: (m['persona_space'] as String?) ?? '',
      );

  /// 只用于写入 id，绝不用于改人设字段。
  Companion withId(int newId) => Companion(
        id: newId,
        name: name,
        persona: persona,
        greeting: greeting,
        avatarPath: avatarPath,
        createdAt: createdAt,
        personaSpace: personaSpace,
      );

  String encode() => jsonEncode(toMap());

  static Companion decode(String raw) =>
      Companion.fromMap(jsonDecode(raw) as Map<String, dynamic>);
}
