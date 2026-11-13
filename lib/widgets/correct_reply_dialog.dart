import 'package:flutter/material.dart';

/// 用户在「改她这句怎么说」里做的选择。
class CorrectReplyResult {
  /// 她本来应该怎么说。
  final String text;

  /// 是否把这条历史消息也替换掉。
  final bool replace;

  const CorrectReplyResult({required this.text, required this.replace});
}

/// 弹出「她该怎么说」编辑窗。取消返回 null。
Future<CorrectReplyResult?> showCorrectReplyDialog(
  BuildContext context, {
  required String original,
}) {
  return showDialog<CorrectReplyResult>(
    context: context,
    builder: (_) => _CorrectReplyDialog(original: original),
  );
}

class _CorrectReplyDialog extends StatefulWidget {
  final String original;

  const _CorrectReplyDialog({required this.original});

  @override
  State<_CorrectReplyDialog> createState() => _CorrectReplyDialogState();
}

class _CorrectReplyDialogState extends State<_CorrectReplyDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.original);
  bool _replace = true;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    Navigator.pop(context, CorrectReplyResult(text: t, replace: _replace));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('她该怎么说？'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                widget.original,
                style: TextStyle(
                    fontSize: 13, height: 1.5, color: Colors.grey.shade700),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: '写成你希望她说出来的样子',
                helperText: '照她的人设写，短句、口语，别写成客服话',
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _replace,
              onChanged: (v) => setState(() => _replace = v ?? false),
              title: const Text('把这条消息也换成我写的',
                  style: TextStyle(fontSize: 13)),
              subtitle: const Text('不勾就只记下说法，历史消息保持原样',
                  style: TextStyle(fontSize: 11)),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            Text(
              '存下来她会一直记着：以后遇到同类场合，按你写的语气和长度来说。',
              style: TextStyle(
                  fontSize: 11, height: 1.5, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('存下来')),
      ],
    );
  }
}
