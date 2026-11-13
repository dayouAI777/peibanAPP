import 'dart:convert';

import 'package:flutter/material.dart';

/// 一个预设背景（柔和渐变，跟 App 的紫粉底子协调）。
class ChatPreset {
  final String id;
  final String label;
  final List<Color> colors;
  final Color sample; // 选择器上的小圆点代表色

  const ChatPreset(this.id, this.label, this.colors, this.sample);
}

/// 聊天背景设置。
///
/// 三种状态：
/// - `none`   跟随主题默认（浅紫白）；
/// - `preset` 用内置渐变；
/// - `image`  用户从相册挑的图，叠一层可调厚度的白纱，保证白气泡和文字永远看得清。
class ChatBackground {
  final String type;
  final String presetId;
  final String imagePath;

  /// 白纱厚度 0~0.85：图片越花就调越厚，文字越清楚，图片就越淡。
  final double veil;

  const ChatBackground({
    this.type = 'none',
    this.presetId = '',
    this.imagePath = '',
    this.veil = 0.55,
  });

  static const ChatBackground initial = ChatBackground();

  bool get isImage => type == 'image' && imagePath.isNotEmpty;
  bool get isPreset => type == 'preset';

  ChatPreset? get preset => ChatPresets.byId(presetId);

  ChatBackground copyWith({
    String? type,
    String? presetId,
    String? imagePath,
    double? veil,
  }) =>
      ChatBackground(
        type: type ?? this.type,
        presetId: presetId ?? this.presetId,
        imagePath: imagePath ?? this.imagePath,
        veil: veil ?? this.veil,
      );

  /// 图片丢了（被系统清理/换机）就当没设过，绝不白屏。
  ChatBackground sanitized() {
    if (type == 'image' && imagePath.isEmpty) return initial;
    if (type == 'preset' && preset == null) return initial;
    return this;
  }

  Map<String, dynamic> toMap() => {
        'type': type,
        'preset_id': presetId,
        'image_path': imagePath,
        'veil': veil,
      };

  factory ChatBackground.fromMap(Map<String, dynamic> m) => ChatBackground(
        type: (m['type'] as String?) ?? 'none',
        presetId: (m['preset_id'] as String?) ?? '',
        imagePath: (m['image_path'] as String?) ?? '',
        veil: ((m['veil'] as num?)?.toDouble() ?? 0.55).clamp(0.0, 0.85),
      );

  String encode() => jsonEncode(toMap());

  static ChatBackground decode(String raw) {
    if (raw.trim().isEmpty) return initial;
    try {
      return ChatBackground.fromMap(jsonDecode(raw) as Map<String, dynamic>)
          .sanitized();
    } catch (_) {
      return initial;
    }
  }
}

class ChatPresets {
  static const List<ChatPreset> all = [
    ChatPreset('peach', '蜜桃', [Color(0xFFFFF4EE), Color(0xFFFFE6EF)],
        Color(0xFFFFD9E6)),
    ChatPreset('dusk', '暮紫', [Color(0xFFEDE9F7), Color(0xFFDCD5EE)],
        Color(0xFFCFC5E6)),
    ChatPreset('mint', '薄荷', [Color(0xFFEBF7F2), Color(0xFFDDEFE9)],
        Color(0xFFCBE7DD)),
    ChatPreset('sand', '米沙', [Color(0xFFFCF5E9), Color(0xFFF4E7D3)],
        Color(0xFFEBD9BC)),
    ChatPreset('salt', '海盐', [Color(0xFFEDF4FB), Color(0xFFDCE9F7)],
        Color(0xFFC8DCF2)),
    ChatPreset('night', '夜色', [Color(0xFF322C3C), Color(0xFF1B1722)],
        Color(0xFF322C3C)),
  ];

  static ChatPreset? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}
