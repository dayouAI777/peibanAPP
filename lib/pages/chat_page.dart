import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/companion.dart';
import '../models/message.dart';
import '../state/app_state.dart';

/// 聊天页（主页面）。从通知点进来时会先自动生成一条「TA 主动找你」的消息。
class ChatPage extends StatefulWidget {
  final bool autoProactive;

  const ChatPage({super.key, this.autoProactive = false});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _proactiveDone = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoProactive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_proactiveDone && mounted) {
          _proactiveDone = true;
          context.read<AppState>().generateProactiveMessage();
        }
      });
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _send(AppState s) {
    final text = _input.text;
    if (text.trim().isEmpty || s.busy) return;
    _input.clear();
    s.send(text);
  }

  Widget _bubble(ChatMessage m, Companion c, ThemeData theme) {
    final mine = m.fromUser;
    final hasAvatar =
        c.avatarPath.isNotEmpty && File(c.avatarPath).existsSync();

    final avatar = CircleAvatar(
      radius: 16,
      backgroundColor: theme.colorScheme.primaryContainer,
      backgroundImage:
          hasAvatar ? FileImage(File(c.avatarPath)) : null,
      child: hasAvatar
          ? null
          : Text(c.name.isEmpty ? 'TA' : c.name.substring(0, 1),
              style: const TextStyle(fontSize: 12)),
    );

    final bubble = Flexible(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: mine
              ? theme.colorScheme.primary
              : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
          border: mine ? null : Border.all(color: Colors.grey.shade200),
        ),
        child: Text(
          m.content,
          style: TextStyle(
            color: mine ? Colors.white : Colors.black87,
            height: 1.6,
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (m.isProactiveMessage)
            Padding(
              padding: const EdgeInsets.only(left: 40, bottom: 4),
              child: Text('主动找你',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.primary)),
            ),
          Row(
            mainAxisAlignment:
                mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: mine
                ? [bubble]
                : [avatar, const SizedBox(width: 8), bubble],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final c = s.companion;
    final theme = Theme.of(context);

    if (c == null) {
      return Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => Navigator.of(context)
                .pushNamedAndRemoveUntil('/', (route) => false),
            child: const Text('还没有 TA，回去创建一个'),
          ),
        ),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primaryContainer,
              backgroundImage: c.avatarPath.isNotEmpty &&
                      File(c.avatarPath).existsSync()
                  ? FileImage(File(c.avatarPath))
                  : null,
              child: c.avatarPath.isNotEmpty &&
                      File(c.avatarPath).existsSync()
                  ? null
                  : const Icon(Icons.person, size: 18),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.name, style: theme.textTheme.titleMedium),
                Text(
                  s.busy ? '正在输入…' : '在这儿',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.grey.shade500, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (s.error != null)
              Material(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(s.error!,
                            style: TextStyle(
                                color: theme.colorScheme.onErrorContainer,
                                fontSize: 13)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: s.dismissError,
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: s.messages.isEmpty
                  ? Center(
                      child: Text('说点什么吧，或者只是打个招呼',
                          style: TextStyle(color: Colors.grey.shade500)),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      itemCount: s.messages.length,
                      itemBuilder: (_, i) =>
                          _bubble(s.messages[i], c, theme),
                    ),
            ),
            if (s.busy)
              const Padding(
                padding: EdgeInsets.only(left: 18, bottom: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(s),
                      decoration: const InputDecoration(
                        hintText: '说点什么，或者只是打个招呼',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: s.busy ? null : () => _send(s),
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
