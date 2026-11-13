import 'dart:io';

import 'package:flutter/material.dart';

import '../models/chat_background.dart';

/// 聊天页背景。图片模式会把图铺满，再叠一层可调厚度的白纱（veil），
/// 这样再花的图也不会把白气泡和黑字吃掉。
class ChatBackgroundView extends StatelessWidget {
  final ChatBackground bg;

  const ChatBackgroundView({super.key, required this.bg});

  @override
  Widget build(BuildContext context) {
    if (bg.isImage && File(bg.imagePath).existsSync()) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(bg.imagePath),
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
          ColoredBox(color: Colors.white.withValues(alpha: bg.veil)),
        ],
      );
    }

    final preset = bg.preset;
    if (preset != null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: preset.colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );
    }

    return const ColoredBox(color: Color(0xFFFBF7FA));
  }
}
