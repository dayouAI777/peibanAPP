import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/companion.dart';
import '../models/message.dart';
import '../services/chat_images.dart';
import '../state/app_state.dart';
import '../widgets/chat_background_view.dart';
import '../widgets/correct_reply_dialog.dart';
import '../widgets/emoji_picker.dart';

/// 聊天页。输入框旁有表情面板，点一下插入到光标处；
/// AI 回复里的表情由 system prompt 里的表情规则控制。
///
/// 长按她的消息 →「改她这句怎么说」：用户写一遍对的，存进她的说话风格。
///
/// 页面里有个每 20 秒走一次的钟：标题下面那行会跟着变成她现在的生活状态
/// （在上班 / 刚下班 / 在吃饭 / 生气中），消息之间也会插时间分隔，
/// 这样每次打开都像「正在发生」，而不是接着上次的聊天记录。
///
/// 键盘弹出时 viewInsets 变化会让列表可视高度缩水，
/// 这里用 WidgetsBindingObserver 监听尺寸变化，始终把列表贴回底部。
class ChatPage extends StatefulWidget {
  final bool autoProactive;

  const ChatPage({super.key, this.autoProactive = false});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  bool _proactiveDone = false;
  bool _showEmoji = false;
  String? _pickedImage; // 待发送的图片（已拷进沙盒）

  /// 页面自己的“现在”。20 秒跳一次，足够让状态和时间跟上现实。
  DateTime _now = DateTime.now();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
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
    _ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 键盘弹起 / 收起、表情面板展开都会触发尺寸变化。
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _keepAtBottom();
  }

  /// 立刻贴底 + 键盘动画结束后补一次，防止动画途中被挤回去。
  void _keepAtBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToEnd(instant: true);
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _scrollToEnd(instant: true);
    });
  }

  void _scrollToEnd({bool instant = false}) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (instant) {
      pos.jumpTo(pos.maxScrollExtent);
    } else {
      pos.animateTo(
        pos.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _dayLabel(DateTime t) {
    final today = DateTime(_now.year, _now.month, _now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (t.year == _now.year) return '${t.month}月${t.day}日';
    return '${t.year}年${t.month}月${t.day}日';
  }

  /// 两条消息中间要不要插时间条。规则跟微信一样：超过 5 分钟就标一次。
  /// 这是让人一眼看出「隔了多久」的最直接办法。
  String? _dividerText(ChatMessage m, ChatMessage? prev) {
    final t = DateTime.fromMillisecondsSinceEpoch(m.createdAt);
    if (prev == null) return '${_dayLabel(t)} ${_hhmm(t)}';
    if (m.createdAt - prev.createdAt <
        const Duration(minutes: 5).inMilliseconds) {
      return null;
    }
    final p = DateTime.fromMillisecondsSinceEpoch(prev.createdAt);
    final sameDay = p.year == t.year && p.month == t.month && p.day == t.day;
    return sameDay ? _hhmm(t) : '${_dayLabel(t)} ${_hhmm(t)}';
  }

  Widget _timeDivider(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              text,
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
          ),
        ),
      );

  void _insertEmoji(String emoji) {
    final text = _input.text;
    final sel = _input.selection;
    final pos = (sel.isValid && sel.baseOffset >= 0 && sel.baseOffset <= text.length)
        ? sel.baseOffset
        : text.length;
    _input.text = text.substring(0, pos) + emoji + text.substring(pos);
    _input.selection = TextSelection.collapsed(offset: pos + emoji.length);
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final x = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1280,
        imageQuality: 72,
      );
      if (x == null) return;
      final path = await ChatImages.instance.persist(x.path);
      setState(() {
        _pickedImage = path;
        _showEmoji = false;
      });
      _keepAtBottom();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('图片拿不到，再试一次')),
        );
      }
    }
  }

  Future<void> _send(AppState s) async {
    final text = _input.text;
    final img = _pickedImage;
    if ((text.trim().isEmpty && (img == null || img.isEmpty)) || s.busy) return;
    _input.clear();
    setState(() => _pickedImage = null);
    await s.send(text, imagePath: img);
    _keepAtBottom();
  }

  /// 长按气泡：她的消息能改说法，谁的都能复制。
  Future<void> _longPress(ChatMessage m) async {
    final app = context.read<AppState>();
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!m.fromUser)
              ListTile(
                leading: const Icon(Icons.edit_note_rounded),
                title: const Text('改她这句怎么说'),
                subtitle: const Text('你写一遍对的，她以后照着说'),
                onTap: () => Navigator.pop(sheetCtx, 'fix'),
              ),
            if (m.content.trim().isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制'),
                onTap: () => Navigator.pop(sheetCtx, 'copy'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || kind == null) return;

    if (kind == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.content));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('复制好了'),
        duration: Duration(seconds: 1),
      ));
      return;
    }

    final r = await showCorrectReplyDialog(context, original: m.content);
    if (r == null || !mounted) return;
    final out = await app.correctReply(
      msg: m,
      preferred: r.text,
      replaceMessage: r.replace,
    );
    if (!mounted) return;
    // 提示必须说实话：以前不管存没存进去都弹「改好了」
    final msg = switch (out.result) {
      CorrectResult.unchanged => '跟原文一样，没有记下来',
      CorrectResult.failed => '没记下来，再试一次',
      CorrectResult.duplicate => '这条之前就记过了，没重复记',
      CorrectResult.saved => out.total > 0
          ? '记住了（第 ${out.total} 条），她以后遇到同类场合照这个说'
          : '记住了，她以后照这个说',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 2),
    ));
  }

  /// 点气泡里的图，全屏放大看。
  void _viewImage(BuildContext context, String path) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                maxScale: 4,
                child: Image.file(File(path), fit: BoxFit.contain),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(ChatMessage m, Companion c, ThemeData theme) {
    final mine = m.fromUser;
    final hasAvatar =
        c.avatarPath.isNotEmpty && File(c.avatarPath).existsSync();

    final avatar = CircleAvatar(
      radius: 16,
      backgroundColor: theme.colorScheme.primaryContainer,
      backgroundImage: hasAvatar ? FileImage(File(c.avatarPath)) : null,
      child: hasAvatar
          ? null
          : Text(c.name.isEmpty ? 'TA' : c.name.substring(0, 1),
              style: const TextStyle(fontSize: 12)),
    );

    final imageWidget = m.hasImage && File(m.imagePath).existsSync()
        ? Padding(
            padding: EdgeInsets.only(
                bottom: m.content.trim().isEmpty ? 0 : 8),
            child: GestureDetector(
              onTap: () => _viewImage(context, m.imagePath),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220, maxHeight: 260),
                  child: Image.file(File(m.imagePath), fit: BoxFit.cover),
                ),
              ),
            ),
          )
        : null;

    Widget contentWidget;
    if (m.isSticker && imageWidget == null) {
      // 只有表情：不放气泡里，直接放大了甩出来（生气时她就这样）
      contentWidget = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          m.content.trim(),
          style: const TextStyle(fontSize: 44, height: 1.15),
        ),
      );
    } else if (imageWidget != null && m.content.trim().isEmpty) {
      // 纯图片：不要文字气泡底色，直接给图
      contentWidget = Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: imageWidget,
      );
    } else {
      contentWidget = Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: mine ? theme.colorScheme.primary : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
          border: mine ? null : Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (imageWidget != null) imageWidget,
            if (m.content.trim().isNotEmpty)
              Text(
                m.content,
                style: TextStyle(
                  color: mine ? Colors.white : Colors.black87,
                  height: 1.6,
                  fontSize: 15,
                ),
              ),
          ],
        ),
      );
    }

    final bubble = Flexible(
      child: GestureDetector(
        onLongPress: () => _longPress(m),
        child: contentWidget,
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
                .pushNamedAndRemoveUntil('/home', (route) => false),
            child: const Text('还没有 TA，回去定一个'),
          ),
        ),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());

    return Scaffold(
      resizeToAvoidBottomInset: true,
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
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    // 「刚下班，在路上 · 20:47」/「生气中，不想说话 · 20:47」
                    '${s.statusLabel(_now)} · ${_hhmm(_now)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: s.moodEnabled && s.mood.faceLabel.isNotEmpty
                          ? theme.colorScheme.error
                          : Colors.grey.shade600,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
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
      body: Stack(
        children: [
          Positioned.fill(child: ChatBackgroundView(bg: s.chatBg)),
          SafeArea(
            child: Column(
              children: [
                if (s.error != null)
                  Material(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
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
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 11),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.78),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text('说点什么吧，或者只是打个招呼',
                                style: TextStyle(color: Colors.grey.shade700)),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          itemCount: s.messages.length,
                          itemBuilder: (_, i) {
                            final m = s.messages[i];
                            final prev = i > 0 ? s.messages[i - 1] : null;
                            final divider = _dividerText(m, prev);
                            final bubble = _bubble(m, c, theme);
                            if (divider == null) return bubble;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [_timeDivider(divider), bubble],
                            );
                          },
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
                if (_pickedImage != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(_pickedImage!),
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('图片已就绪，加点字或直接发送',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade600)),
                        ),
                        IconButton(
                          tooltip: '移除图片',
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () => setState(() => _pickedImage = null),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '表情',
                        icon: Icon(_showEmoji
                            ? Icons.keyboard_outlined
                            : Icons.sentiment_satisfied_alt_outlined),
                        onPressed: () {
                          FocusScope.of(context).unfocus();
                          setState(() => _showEmoji = !_showEmoji);
                          _keepAtBottom();
                        },
                      ),
                      IconButton(
                        tooltip: '发图片',
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        onPressed: s.busy
                            ? null
                            : () {
                                showModalBottomSheet(
                                  context: context,
                                  builder: (_) => SafeArea(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ListTile(
                                          leading:
                                              const Icon(Icons.photo_outlined),
                                          title: const Text('从相册选'),
                                          onTap: () {
                                            Navigator.pop(context);
                                            _pickImage(ImageSource.gallery);
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(
                                              Icons.photo_camera_outlined),
                                          title: const Text('拍一张'),
                                          onTap: () {
                                            Navigator.pop(context);
                                            _pickImage(ImageSource.camera);
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                      ),
                      Expanded(
                        child: TextField(
                          controller: _input,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onTap: () {
                            if (_showEmoji) setState(() => _showEmoji = false);
                            _keepAtBottom();
                          },
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
                if (_showEmoji) EmojiPicker(onTap: _insertEmoji),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
