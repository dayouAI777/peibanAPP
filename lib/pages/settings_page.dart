import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/emoji_kit.dart';
import '../data/prefs.dart';
import '../models/style_profile.dart';
import '../services/cloud_sync.dart';
import '../services/update_service.dart';
import '../state/app_state.dart';
import '../widgets/silent_update_banner.dart';
import '../widgets/update_helper.dart';

/// 设置页。API Key 只写进本机，不进仓库、不进 APK、不上传。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _key = TextEditingController();
  final _passphraseCtl = TextEditingController();
  bool _obscure = true;
  bool _loaded = false;
  bool _saving = false;
  bool _testing = false;
  bool _checking = false;
  bool _cloudBusy = false;
  bool _cloudSyncOn = false;
  bool _passphraseVisible = false;
  bool _hasAuthCode = false;

  late ProactiveSettings _s;
  double _temperature = 0.8;
  int _emojiLevel = 2;
  int _contextWindow = 1000;
  bool _manualEnabled = true;
  bool _autoUpdate = true;
  bool _silentUpdate = true;
  bool _moodEnabled = true;
  String _versionText = '—';
  String? _testMessage;
  String? _updateStatus;
  bool _testOk = false;

  final _updateService = UpdateService();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _key.text = await Prefs.apiKey();
    _s = await Prefs.proactiveSettings();
    _temperature = await Prefs.temperature();
    _emojiLevel = await Prefs.emojiLevel();
    _contextWindow = await Prefs.contextLimit();
    _manualEnabled = await Prefs.manualEnabled();
    _autoUpdate = await Prefs.autoUpdateCheck();
    _silentUpdate = await Prefs.silentUpdateEnabled();
    _moodEnabled = await Prefs.moodEnabled();
    _cloudSyncOn = await Prefs.cloudSync();
    _hasAuthCode = (await Prefs.cloudAuthCode()).isNotEmpty;
    final v = await _updateService.localVersion();
    if (!mounted) return;
    setState(() {
      _versionText = '${v.version}+${v.build}';
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _key.dispose();
    _passphraseCtl.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    try {
      await context.read<AppState>().testConnection(_key.text.trim());
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = true;
        _testMessage = '连上了';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testMessage = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    // 先拿到引用，避免跨异步等待后再碰 context
    final app = context.read<AppState>();
    await Prefs.setApiKey(_key.text);
    await Prefs.saveProactiveSettings(_s);
    await Prefs.setTemperature(_temperature);
    await Prefs.setEmojiLevel(_emojiLevel);
    await Prefs.setContextLimit(_contextWindow);
    await Prefs.setManualEnabled(_manualEnabled);
    await Prefs.setAutoUpdateCheck(_autoUpdate);
    await Prefs.setSilentUpdateEnabled(_silentUpdate);
    await Prefs.setMoodEnabled(_moodEnabled);
    await app.applySettings();
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('存好了，通知时间也重新排过了')));
  }

  /// 「检查更新」按钮：有新版弹升级面板，没有也弹明确结果，并把结果常驻显示。
  Future<void> _checkUpdate() async {
    setState(() => _checking = true);
    final r = await UpdateHelper.checkAndShow(context);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _updateStatus = r.error != null
          ? '上次检查失败：${r.error}'
          : (r.hasUpdate
              ? '上次检查：发现新版 ${r.info!.version}'
              : '上次检查：已是最新版 ${r.local.version}+${r.local.build}');
    });
  }

  // ——— 云同步 ———

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 开启同步：拿输入框里的口令调 setPassphrase（内含 ≥8 位校验 + 立即上传）。
  Future<void> _cloudEnable() async {
    setState(() => _cloudBusy = true);
    final outcome = await CloudSync.instance.setPassphrase(_passphraseCtl.text);
    if (!mounted) return;
    setState(() => _cloudBusy = false);
    // 弹窗/提示只说真实结果：ok 才清输入框、刷开关，失败原样保留让用户改
    _snack(outcome.message);
    if (outcome.ok) {
      setState(() => _cloudSyncOn = CloudSync.instance.enabled);
      _passphraseCtl.clear();
    }
  }

  /// 修改口令 = 换云端目录。旧口令的备份留在云端，不删。
  Future<void> _cloudChangePassphrase() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('修改同步口令'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctl,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: '新口令（至少 8 位）',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '改口令后，新口令的目录是空的，会立刻把本地记忆传一份过去；'
              '旧口令的备份还在云端。请像记密码一样记住新口令。',
              style: TextStyle(fontSize: 13, height: 1.6),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('再想想')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定修改')),
        ],
      ),
    );
    if (ok != true) {
      ctl.dispose();
      return;
    }
    setState(() => _cloudBusy = true);
    final outcome = await CloudSync.instance.setPassphrase(ctl.text);
    ctl.dispose();
    if (!mounted) return;
    setState(() => _cloudBusy = false);
    // 提示文案来自 setPassphrase 的真实结果（没变/已更新/失败原因），不硬编码
    _snack(outcome.message);
  }

  /// 关闭同步：云端不再变动，口令保留（重新打开不用重输），本机数据不受影响。
  Future<void> _cloudDisable() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('关闭云同步？'),
        content: const Text(
            '云端备份保留不动，本机数据也不受影响，只是不再自动备份。'
            '口令会记住，重新打开同步不用重输。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('再想想')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('关闭')),
        ],
      ),
    );
    if (ok != true) return;
    await CloudSync.instance.setEnabled(false);
    if (!mounted) return;
    setState(() => _cloudSyncOn = CloudSync.instance.enabled);
    _snack('云同步已关闭');
  }

  /// 「对齐云端」：先推送（本地有、云端没有的追加到云端），再拉取（云端有、
  /// 本地没有的补进本地）。完成后 snack 显示真实结果（真实条数或真实失败原因）。
  Future<void> _cloudAlign() async {
    setState(() => _cloudBusy = true);
    final app = context.read<AppState>();
    final r = await CloudSync.instance.align();
    if (r.ok) {
      await app.reloadFromDb();
    }
    if (!mounted) return;
    setState(() => _cloudBusy = false);
    _snack(r.message);
  }

  /// 从云端恢复：必须二次确认。合并规则是「只补缺」，本机数据一条不删。
  Future<void> _cloudRestore() async {
    final app = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('从云端恢复？'),
        content: const Text(
            '会用云端备份把这台设备没有的资料补全到本机：聊天记录、行为手册、'
            '说话范例、记忆摘要都会按「已有的不动、缺的才补」合并。\n\n'
            '不会删除本地任何聊天记录，人设定稿也不会被覆盖。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('再想想')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开始恢复')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _cloudBusy = true);
    final r = await CloudSync.instance.pullOnly();
    if (r.ok) {
      await app.reloadFromDb();
    }
    if (!mounted) return;
    setState(() => _cloudBusy = false);
    _snack(r.message);
  }

  /// 授权码设置入口：未设置时可设置（输入两次确认），已设置可修改（先输旧码）。
  Future<void> _cloudAuthCode() async {
    final hasOld = _hasAuthCode;
    final oldCtl = TextEditingController();
    final newCtl = TextEditingController();
    final confirmCtl = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          title: Text(hasOld ? '修改授权码' : '设置授权码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasOld) ...[
                TextField(
                  controller: oldCtl,
                  obscureText: true,
                  decoration: const InputDecoration(hintText: '旧授权码'),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: newCtl,
                obscureText: true,
                decoration:
                    const InputDecoration(hintText: '新授权码（至少 8 位）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmCtl,
                obscureText: true,
                decoration: const InputDecoration(hintText: '再输一遍新授权码'),
              ),
              const SizedBox(height: 12),
              const Text(
                '授权码用于销毁云母库等高危操作，与同步口令相互独立，'
                '只在 App 本机保存，不上云、不进任何备份文件。',
                style: TextStyle(fontSize: 13, height: 1.6),
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(err!,
                      style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(dialogCtx).colorScheme.error)),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: const Text('再想想')),
            FilledButton(
              onPressed: () {
                final v = newCtl.text.trim();
                if (v != confirmCtl.text.trim()) {
                  setDialogState(() => err = '两次输入的新授权码不一致');
                  return;
                }
                Navigator.pop(dialogCtx, true);
              },
              child: Text(hasOld ? '确定修改' : '确定设置'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) {
      oldCtl.dispose();
      newCtl.dispose();
      confirmCtl.dispose();
      return;
    }
    setState(() => _cloudBusy = true);
    final outcome = hasOld
        ? await CloudSync.instance.changeAuthCode(oldCtl.text, newCtl.text)
        : await CloudSync.instance.setAuthCode(newCtl.text);
    oldCtl.dispose();
    newCtl.dispose();
    confirmCtl.dispose();
    if (!mounted) return;
    setState(() {
      _cloudBusy = false;
      if (outcome.ok) _hasAuthCode = true;
    });
    _snack(outcome.message);
  }

  /// 「销毁云母库」：输入授权码 → 危险确认弹窗 → 本地验证授权码 →
  /// 空 journal 覆盖上传 → 自动把本地当前记忆重新对齐上传。
  Future<void> _cloudDestroy() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('销毁云母库'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '这是高危操作：云端记忆将全部清除且不可找回。'
              '继续前请输入授权码确认身份。',
              style: TextStyle(fontSize: 13, height: 1.6),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              obscureText: true,
              decoration: const InputDecoration(hintText: '授权码'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('再想想')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续')),
        ],
      ),
    );
    if (ok != true) {
      ctl.dispose();
      return;
    }
    if (!mounted) {
      ctl.dispose();
      return;
    }
    final ok2 = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认销毁云母库？'),
        content: const Text(
            '云端记忆将全部清除，且不可找回。\n\n'
            '本地数据不受影响；销毁完成后会自动把本地当前记忆重新对齐上传。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('再想想')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('彻底销毁'),
          ),
        ],
      ),
    );
    if (ok2 != true) {
      ctl.dispose();
      return;
    }
    setState(() => _cloudBusy = true);
    final r = await CloudSync.instance.destroyCloud(ctl.text);
    ctl.dispose();
    if (!mounted) return;
    setState(() => _cloudBusy = false);
    _snack(r.message);
  }

  /// 删除重建：本地必删；可选同时销毁云端记忆（需授权码，本地删除成功后才执行）。
  Future<void> _deleteCompanion() async {
    bool destroy = false;
    final authCtl = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          title: const Text('删除这个人，重新定？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  '人设定稿后不能改，删除是唯一重来的办法。所有本地记录会清空，无法恢复。'),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: destroy,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('同时销毁云端记忆（需输入授权码）'),
                subtitle: const Text('不勾选则云端仍保留旧记忆'),
                onChanged: (v) => setDialogState(() => destroy = v ?? false),
              ),
              if (destroy) ...[
                TextField(
                  controller: authCtl,
                  obscureText: true,
                  decoration: const InputDecoration(hintText: '授权码'),
                ),
                const SizedBox(height: 8),
              ],
              if (err != null)
                Text(err!,
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(dialogCtx).colorScheme.error)),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: const Text('再想想')),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogCtx).colorScheme.error),
              onPressed: () {
                if (destroy && authCtl.text.trim().isEmpty) {
                  setDialogState(() => err = '勾选了销毁云端，请输入授权码');
                  return;
                }
                Navigator.pop(dialogCtx, true);
              },
              child: const Text('确定删除'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) {
      authCtl.dispose();
      return;
    }
    if (!mounted) {
      authCtl.dispose();
      return;
    }
    // 先拿引用：删除后会导航走，本页 context 会失效
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _cloudBusy = true);
    // 本地先删；本地失败不碰云端
    var localDeleted = false;
    try {
      await app.deleteCompanion();
      localDeleted = true;
    } catch (_) {
      localDeleted = false;
    }
    if (!localDeleted) {
      authCtl.dispose();
      if (!mounted) return;
      setState(() => _cloudBusy = false);
      _snack('本地删除失败，云端未做任何改动');
      return;
    }
    String msg;
    if (destroy) {
      final r = await CloudSync.instance.destroyCloud(authCtl.text);
      msg = r.ok
          ? '本地已删除，云端记忆已销毁'
          : '本地已删除，但云端销毁失败：${r.message}（云端仍保留旧记忆，'
              '可在云同步中授权销毁）';
    } else {
      msg = '本地已删除。云端仍保留旧记忆，可在云同步中授权销毁';
    }
    authCtl.dispose();
    if (!mounted) return;
    setState(() => _cloudBusy = false);
    messenger.showSnackBar(SnackBar(content: Text(msg)));
    nav.pushNamedAndRemoveUntil('/persona', (route) => false);
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '还没同步过';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    final hh = t.hour.toString().padLeft(2, '0');
    final mi = t.minute.toString().padLeft(2, '0');
    return '${t.year}-$mm-$dd $hh:$mi';
  }

  /// 她的说话方式档案的状态行文案（只读展示，不做编辑入口）。
  String _styleProfileStatus(StyleProfile p) {
    if (p.isEmpty) return '还没有档案；攒够几条修改后会自动蒸馏一份，不用管它';
    final t = DateTime.fromMillisecondsSinceEpoch(p.updatedAt);
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    final hh = t.hour.toString().padLeft(2, '0');
    final mi = t.minute.toString().padLeft(2, '0');
    return '已消化 ${p.digested} 条范例 · ${t.year}-$mm-$dd $hh:$mi 更新';
  }

  Future<void> _confirm(
      String title, String body, Future<void> Function() run) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('再想想')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok == true) await run();
  }

  List<DropdownMenuItem<int>> _hours(int from, int to) => [
        for (int h = from; h <= to; h++)
          DropdownMenuItem(
              value: h,
              child: Text('${h.toString().padLeft(2, '0')}:00')),
      ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          // ——— 在线升级 ———
          Text('版本与升级', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.system_update_alt_rounded),
            title: Text('当前版本 $_versionText'),
            subtitle: const Text('Git 仓库 version.json 作后台；App 主动查，不是推送'),
          ),
          OutlinedButton.icon(
            onPressed: _checking ? null : _checkUpdate,
            icon: _checking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, size: 18),
            label: Text(_checking ? '正在检查…' : '检查更新'),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48)),
          ),
          if (_updateStatus != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_updateStatus!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.grey.shade700)),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _autoUpdate,
            title: const Text('启动时自动检查更新'),
            subtitle: const Text('只检查、不自动下载；发现新版会在首页显示提示'),
            onChanged: (v) => setState(() => _autoUpdate = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _silentUpdate,
            title: const Text('后台静默升级'),
            subtitle: const Text(
                '启动后在后台查版本、下安装包，不挡聊天也不弹窗；下好才提示一下，装不装你说了算'),
            onChanged: (v) => setState(() => _silentUpdate = v),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4, bottom: 6),
            child: SilentUpdateBanner(showProgress: true),
          ),
          const Divider(height: 28),

          // ——— 连接 ———
          Text('DeepSeek API Key', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _key,
            obscureText: _obscure,
            onChanged: (_) => setState(() {
              _testOk = false;
              _testMessage = null;
            }),
            decoration: InputDecoration(
              hintText: 'sk-...',
              suffixIcon: IconButton(
                icon: Icon(_obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _testing ? null : _test,
            icon: const Icon(Icons.network_check_rounded, size: 18),
            label: Text(_testing ? '测试中…' : '测试链接'),
          ),
          if (_testMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _testMessage!,
                style: TextStyle(
                    fontSize: 13,
                    color: _testOk
                        ? Colors.green.shade700
                        : theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'Key 只存在这台手机上。把 APK 发给朋友时，对方填自己的 Key。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.grey.shade600, height: 1.6),
          ),
          const Divider(height: 28),

          // ——— 云同步 ———
          Text('云同步', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: CloudSync.instance,
            builder: (context, _) {
              final cloud = CloudSync.instance;
              final active = _cloudSyncOn && cloud.hasPassphrase;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _cloudSyncOn,
                    title: const Text('开启云同步'),
                    subtitle: const Text(
                        '聊天记忆备份到云端你自己的口令目录下；关掉后云端不再变动，本机数据不受影响'),
                    onChanged: (v) async {
                      await cloud.setEnabled(v);
                      if (!mounted) return;
                      setState(() => _cloudSyncOn = v);
                    },
                  ),
                  if (active) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.cloud_done_outlined),
                      title: const Text('已开启同步'),
                      subtitle:
                          Text('最后同步：${_fmtTime(cloud.lastSyncAt)}'),
                    ),
                    // R10：云端没读到数据但本机有历史时，必须给出可判别状态，
                    // 不许显示成空库，也不许静默继续。两个可能原因一起说，
                    // 并明确告诉用户"本机记忆完好、没有被改动"。
                    if (cloud.dirMismatch)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                cloud.lastError ?? CloudSync.cloudEmptyMessage(),
                                style: TextStyle(
                                    color: theme.colorScheme.onErrorContainer),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: _cloudChangePassphrase,
                                    child: const Text('核对口令（一字不差）'),
                                  ),
                                  TextButton(
                                    onPressed: () async {
                                      // S5⑤ 换机出口：只有用户明确走这条才允许按新库处理。
                                      // 先强提示核对口令并让用户重新输入，全程不查服务端。
                                      final confirmed =
                                          await showDialog<bool>(
                                        context: context,
                                        builder: (_) => AlertDialog(
                                          title: const Text('我在旧手机上有记录'),
                                          content: const Text(
                                            '请确认旧手机上的同步口令一字不差（含大小写、空格）。'
                                            '下一步会让你重新输入口令，并按新库处理本机记忆。'
                                            '本机记忆完好，不会被删除。',
                                          ),
                                          actions: [
                                            TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(context, false),
                                                child: const Text('取消')),
                                            FilledButton(
                                                onPressed: () =>
                                                    Navigator.pop(context, true),
                                                child: const Text('已核对，继续')),
                                          ],
                                        ),
                                      );
                                      if (confirmed != true || !mounted) return;
                                      await CloudSync.instance
                                          .acknowledgeNewLibrary();
                                      if (!mounted) return;
                                      await _cloudChangePassphrase();
                                      if (!mounted) return;
                                      await _cloudAlign();
                                    },
                                    child: const Text('我在旧手机上有记录'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (cloud.status == SyncStatus.syncing)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                            SizedBox(width: 10),
                            Text('正在同步…'),
                          ],
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _cloudBusy ? null : _cloudAlign,
                            icon: const Icon(Icons.sync_outlined, size: 18),
                            label: const Text('对齐云端'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _cloudBusy ? null : _cloudRestore,
                            icon: const Icon(Icons.restore_outlined, size: 18),
                            label: const Text('从云端恢复'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _cloudBusy ? null : _cloudChangePassphrase,
                            icon: const Icon(Icons.key_outlined, size: 18),
                            label: const Text('修改口令'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _cloudBusy ? null : _cloudDisable,
                            icon: const Icon(Icons.cloud_off_outlined, size: 18),
                            label: const Text('关闭同步'),
                          ),
                        ),
                      ],
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.verified_user_outlined),
                      title: Text('授权码（${_hasAuthCode ? '已设置' : '未设置'}）'),
                      subtitle: const Text(
                          '授权码用于销毁云母库等高危操作，只在 App 本机保存'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _cloudBusy ? null : _cloudAuthCode,
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                          side: BorderSide(color: theme.colorScheme.error),
                          minimumSize: const Size.fromHeight(44),
                        ),
                        onPressed: _cloudBusy ? null : _cloudDestroy,
                        icon: const Icon(Icons.local_fire_department_outlined,
                            size: 18),
                        label: const Text('销毁云母库'),
                      ),
                    ),
                    Text(
                      '云端记忆库只增不删：本地删除不影响云端历史；'
                      '「对齐云端」会先把本地缺的补上去、再把云端缺的补回来，'
                      '两边对齐后一致。发消息成功后 5 分钟也会自动推送一次，'
                      'App 退到后台时同样补推。恢复只补缺、不删除本机任何记录。'
                      '销毁云母库是唯一清空云端的入口，需要授权码确认。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.grey.shade600, height: 1.6),
                    ),
                  ] else ...[
                    TextField(
                      controller: _passphraseCtl,
                      enabled: !_cloudBusy,
                      obscureText: !_passphraseVisible,
                      decoration: InputDecoration(
                        hintText: '设置同步口令（至少 8 位）',
                        prefixIcon: const Icon(Icons.key, size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(_passphraseVisible
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () => setState(
                              () => _passphraseVisible = !_passphraseVisible),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _cloudBusy ? null : _cloudEnable,
                      icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                      label: Text(_cloudBusy ? '正在开启…' : '开启同步'),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                    ),
                    if (cloud.lastError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          cloud.lastError!,
                          style: TextStyle(
                              fontSize: 13, color: theme.colorScheme.error),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      '口令是你云端记忆的唯一凭证。换手机或重装 App 后，输入同一个口令'
                      '再点「对齐云端」就能找回云端记忆。云端记忆库只增不删，'
                      '本地删除不影响云端历史。口令忘了云端就找不回'
                      '（手机本地记录不受影响），请像记密码一样记住它。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.grey.shade600, height: 1.6),
                    ),
                  ],
                ],
              );
            },
          ),
          const Divider(height: 28),

          // ——— 聊天与记忆 ———
          Text('聊天与记忆', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.wallpaper_rounded),
            title: const Text('聊天背景'),
            subtitle: const Text('预设渐变，或用自己相册里的图'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/background'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.edit_note_rounded),
            title: const Text('她学到的说法'),
            subtitle: Text(
              context.watch<AppState>().styleExamples.isEmpty
                  ? '长按她说的话，写一遍她该怎么说'
                  : '${context.watch<AppState>().styleExamples.length} 条，长按消息可随时加',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/style-examples'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.record_voice_over_rounded),
            title: const Text('她的说话方式档案'),
            subtitle: Text(_styleProfileStatus(
                context.watch<AppState>().styleProfile)),
            // 只读状态行：档案是机器蒸馏产物，不做编辑入口
            // （与「人设定稿不改」同一精神），攒够修改自动更新。
          ),
          const Divider(height: 24),
          Text('TA 用表情：${EmojiKit.labelOf(_emojiLevel)}'),
          DropdownButton<int>(
            value: _emojiLevel,
            isExpanded: true,
            items: const [
              DropdownMenuItem(value: 0, child: Text('不用表情')),
              DropdownMenuItem(value: 1, child: Text('偶尔用')),
              DropdownMenuItem(value: 2, child: Text('常用（默认，回复生动）')),
            ],
            onChanged: (v) => setState(() => _emojiLevel = v ?? 1),
          ),
          const SizedBox(height: 12),
          Text('记忆窗口：最近 $_contextWindow 句'),
          Slider(
            value: _contextWindow.toDouble(),
            min: 200,
            max: 5000,
            divisions: 24,
            label: '$_contextWindow 句',
            onChanged: (v) => setState(() => _contextWindow = v.round()),
          ),
          Text(
            '窗口内的对话都记得住；更早的会由 AI 压成摘要长期带着，不会丢，也不会每次把上千句原文全发出去。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.grey.shade600, height: 1.6),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _manualEnabled,
            title: const Text('记录我的行为习惯'),
            subtitle: const Text('AI 判断 + 内置规则，只记稳定的习惯'),
            onChanged: (v) => setState(() => _manualEnabled = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _moodEnabled,
            title: const Text('她会有情绪'),
            subtitle: const Text(
                '一直不理她会生气、会甩个表情不说话，得哄；哄好了会自己下台阶。关掉就永远好脾气'),
            onChanged: (v) => setState(() => _moodEnabled = v),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('查看行为记录手册'),
            subtitle: const Text('能看到记了什么，也能逐条删'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/manual'),
          ),
          const Divider(height: 28),

          // ——— 主动消息 ———
          Text('主动消息', style: theme.textTheme.titleMedium),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _s.enabled,
            title: const Text('偶尔让 TA 主动找我'),
            subtitle: const Text('预约本地通知，点开后现场生成一句话'),
            onChanged: (v) => setState(() => _s = ProactiveSettings(
                  enabled: v,
                  perDay: _s.perDay,
                  startHour: _s.startHour,
                  endHour: _s.endHour,
                )),
          ),
          if (_s.enabled) ...[
            Row(
              children: [
                const Text('每天'),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: _s.perDay,
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1 条')),
                    DropdownMenuItem(value: 2, child: Text('2 条')),
                    DropdownMenuItem(value: 3, child: Text('3 条')),
                  ],
                  onChanged: (v) => setState(() => _s = ProactiveSettings(
                        enabled: true,
                        perDay: v ?? 1,
                        startHour: _s.startHour,
                        endHour: _s.endHour,
                      )),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('时段'),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: _s.startHour,
                  items: _hours(0, 22),
                  onChanged: (v) => setState(() => _s = ProactiveSettings(
                        enabled: true,
                        perDay: _s.perDay,
                        startHour: v ?? 9,
                        endHour:
                            _s.endHour > (v ?? 9) ? _s.endHour : (v ?? 9) + 1,
                      )),
                ),
                const Text(' — '),
                DropdownButton<int>(
                  value: _s.endHour > 24 ? 24 : _s.endHour,
                  items: _hours(1, 24),
                  onChanged: (v) => setState(() => _s = ProactiveSettings(
                        enabled: true,
                        perDay: _s.perDay,
                        startHour: _s.startHour,
                        endHour: (v ?? 23) > _s.startHour
                            ? (v ?? 23)
                            : _s.startHour + 1,
                      )),
                ),
              ],
            ),
          ],
          const Divider(height: 28),

          Text('说话的随机度：${_temperature.toStringAsFixed(2)}',
              style: theme.textTheme.titleMedium),
          Slider(
            value: _temperature.clamp(0.4, 1.0),
            min: 0.4,
            max: 1.0,
            divisions: 6,
            label: _temperature.toStringAsFixed(2),
            onChanged: (v) => setState(() => _temperature = v),
          ),
          Text(
            '默认 0.8，上限锁在 1.0——再高模型容易输出前言不搭后语的大段胡话。'
            '旧版存过的高数值会自动降下来。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.grey.shade600, height: 1.6),
          ),
          const SizedBox(height: 10),
          Text(
            '对话风格会在后台自动学习（只学说话方式，不记聊天内容），只存本机，不用管它。'
            '想直接纠正她，就在聊天里长按她说的话。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.grey.shade600, height: 1.6),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存设置'),
          ),
          const Divider(height: 36),

          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.edit_outlined),
            title: const Text('修改头像与昵称'),
            subtitle: const Text('只改外观；性格定稿后不可改'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/appearance'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.article_outlined),
            title: const Text('查看人设档案（只读）'),
            subtitle: const Text('定稿后不能改'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/home'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('清空聊天记录'),
            subtitle: const Text('人设、行为手册保留，压缩摘要会一起清掉'),
            onTap: () => _confirm('清空聊天记录？', '之前的对话会全部删掉，不能恢复。',
                () => context.read<AppState>().clearMessages()),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.person_remove_outlined,
                color: theme.colorScheme.error),
            title:
                Text('删除重建', style: TextStyle(color: theme.colorScheme.error)),
            subtitle: const Text('人设、聊天、摘要、行为手册一起清空，配置保留；可选同时销毁云端记忆'),
            onTap: _deleteCompanion,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
