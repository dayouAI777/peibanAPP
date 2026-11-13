import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/setup_form.dart';
import '../services/persona_builder.dart';
import '../state/app_state.dart';
import 'result_page.dart';

/// 角色设定页：三步表单。写得越细，人设越准。
/// 参考图是用户自己从相册选的，选完会复制进 App 私有目录（相册临时路径会失效）。
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  int _step = 0;
  bool _generating = false;
  String _avatarPath = '';
  List<String> _traits = [];
  String _relationship = '恋人';
  double _initiative = 1;

  final _name = TextEditingController();
  final _appellation = TextEditingController();
  final _ageFeel = TextEditingController();
  final _identity = TextEditingController();
  final _appearance = TextEditingController();
  final _speakingStyle = TextEditingController();
  final _callUser = TextEditingController();
  final _backstory = TextEditingController();
  final _avoidTopics = TextEditingController();
  final _extra = TextEditingController();

  @override
  void dispose() {
    for (final c in [
      _name, _appellation, _ageFeel, _identity, _appearance,
      _speakingStyle, _callUser, _backstory, _avoidTopics, _extra,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(TextEditingController c, String label, String hint,
      {int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          alignLabelWithHint: maxLines > 1,
        ),
      ),
    );
  }

  Future<void> _pickAvatar() async {
    try {
      final x = await ImagePicker()
          .pickImage(source: ImageSource.gallery, maxWidth: 1200, imageQuality: 88);
      if (x == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory(p.join(dir.path, 'avatars'));
      if (!await folder.exists()) await folder.create(recursive: true);
      final target = p.join(
          folder.path, 'companion_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(x.path).copy(target);
      if (!mounted) return;
      setState(() => _avatarPath = target);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('选图失败：$e')));
    }
  }

  SetupForm _collect() => SetupForm()
    ..name = _name.text
    ..appellation = _appellation.text
    ..ageFeel = _ageFeel.text
    ..identity = _identity.text
    ..appearance = _appearance.text
    ..traits = List<String>.from(_traits)
    ..speakingStyle = _speakingStyle.text
    ..avatarPath = _avatarPath
    ..callUser = _callUser.text
    ..relationship = _relationship
    ..backstory = _backstory.text
    ..initiative = _initiative
    ..avoidTopics = _avoidTopics.text
    ..extra = _extra.text;

  void _next() {
    if (_step == 0 && _name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('至少给 TA 起个名字吧')));
      return;
    }
    setState(() => _step += 1);
  }

  Future<void> _generate() async {
    final form = _collect();
    setState(() => _generating = true);
    final draft = await context.read<AppState>().generateDraft(form);
    if (!mounted) return;
    setState(() => _generating = false);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ResultPage(form: form, draft: draft)),
    );
  }

  Widget _stepBody() {
    if (_step == 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field(_name, '名字 *', '比如：阿雾'),
          _field(_appellation, '称谓 / 性别感', '比如：她 / 姐姐 / 少年感'),
          _field(_ageFeel, '年龄感', '比如：二十出头、比我还小一点'),
          _field(_identity, '身份 / 职业', '比如：书店店员、自由插画师'),
          _field(_appearance, '外貌气质', '比如：短发、常穿宽松毛衣、笑起来眼睛弯'),
          Text('性格标签', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: PersonaBuilder.traitOptions.map((t) {
              final on = _traits.contains(t);
              return FilterChip(
                label: Text(t),
                selected: on,
                onSelected: (v) => setState(() {
                  if (v) {
                    _traits.add(t);
                  } else {
                    _traits.remove(t);
                  }
                }),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          _field(_speakingStyle, '说话风格', '比如：话不多但很直、爱用语气词、偶尔嘴硬'),
          Text('人物参考图', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _avatarPath.isNotEmpty && File(_avatarPath).existsSync()
                    ? Image.file(File(_avatarPath),
                        width: 72, height: 72, fit: BoxFit.cover)
                    : Container(
                        width: 72,
                        height: 72,
                        color: Colors.grey.shade200,
                        child: Icon(Icons.person_outline,
                            color: Colors.grey.shade500),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickAvatar,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(_avatarPath.isEmpty ? '从相册选一张' : '换一张'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('不接生图服务，图只存在这台手机上。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey.shade500)),
        ],
      );
    }

    if (_step == 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field(_callUser, 'TA 怎么称呼你', '比如：阿澈 / 小孩 / 你的小名'),
          Text('你们的关系', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: PersonaBuilder.relationshipOptions.map((r) {
              return ChoiceChip(
                label: Text(r),
                selected: _relationship == r,
                onSelected: (_) => setState(() => _relationship = r),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          _field(_backstory, '初见场景 / 共同经历',
              '比如：去年雨天在便利店躲雨认识的，后来常一起走那段路',
              maxLines: 4),
          const SizedBox(height: 4),
          Text('希望 TA 多主动',
              style: Theme.of(context).textTheme.titleSmall),
          Slider(
            value: _initiative,
            min: 1,
            max: 3,
            divisions: 2,
            label: ['偶尔', '挺主动', '很粘人'][_initiative.round() - 1],
            onChanged: (v) => setState(() => _initiative = v),
          ),
          Text(
            '这一项写进人设，决定 TA 说话时有多主动；通知频率在「设置」里单独调。',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey.shade500),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(_avoidTopics, '不希望聊的话题', '比如：工作、前任、某个人的名字', maxLines: 2),
        _field(_extra, '其他补充', '任何你希望 TA 记住的小事、口头禅、只有你们懂的梗',
            maxLines: 6),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.4),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Text(
            '点「生成 TA」时，会把这些设定交给 DeepSeek 整理成一份人设和第一句开场白。\n'
            '没填 API Key 也能先建好角色（用本地模板），之后在设置里补上 Key 就行。',
            style: TextStyle(height: 1.6),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final titles = ['说说 TA 是谁', '说说你们俩', '最后一点边界'];
    return Scaffold(
      appBar: AppBar(title: Text('${_step + 1} / 3 · ${titles[_step]}')),
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(value: (_step + 1) / 3),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: _stepBody(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Row(
                children: [
                  if (_step > 0)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => setState(() => _step -= 1),
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(52)),
                        child: const Text('上一步'),
                      ),
                    ),
                  if (_step > 0) const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _generating
                          ? null
                          : (_step < 2 ? _next : _generate),
                      child: _generating
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_step < 2 ? '下一步' : '生成 TA'),
                    ),
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
