import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/emoji_kit.dart';
import '../data/prefs.dart';
import '../models/style_profile.dart';
import '../services/cloud_sync.dart';
import '../services/export_service.dart';
import '../services/export_share.dart';
import '../services/proactive_diag.dart';
import '../services/proactive_service.dart';
import '../services/update_service.dart';
import '../state/app_state.dart';
import 'self_page.dart';
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
  bool _cloudProactiveOn = false;
  bool _passphraseVisible = false;
  bool _hasAuthCode = false;
  bool _exporting = false;
  String? _exportStatus;

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
  ProactiveDiagSnapshot? _diag;

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
    _cloudProactiveOn = await Prefs.cloudProactiveEnabled();
    _hasAuthCode = (await Prefs.cloudAuthCode()).isNotEmpty;
    _diag = await ProactiveDiag.load();
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

  // ——— 导出（R3）———

  /// 两个导出按钮共用这一条路径，只有 [ExportMode] 不同。
  ///
  /// 文案不由本页拼：C5 的四个分支（off / on+不完整 / on+完整 / 异常）全在
  /// [ExportService] 里判，本页只负责把**真实状态**传进去，再把真实文案显示出来。
  /// 本页绝不出现「导出成功」这种硬编码——云同步开着但本机可能缺记录时，
  /// 文件确实生成了，但不许说成功。
  Future<void> _export(ExportMode mode) async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _exportStatus = null;
    });
    final cloud = CloudSync.instance;
    // C5④：cloudSync 只有 off / on 两个值。开了开关但没设口令 = 实际没同步 ⇒ off。
    final cloudSync = (_cloudSyncOn && cloud.hasPassphrase) ? 'on' : 'off';
    // isComplete = 我们**知道**本机是不是云端的全量。三个条件缺一不可：
    //   ① signedIn   —— 有身份，才有可能读到云端的行
    //   ② !dirMismatch —— R10 三态里没有"云端读不到"这一种
    //   ③ 落盘的对齐成功时间 > 0 —— 至少成功读过一次云端（键 `cloud_aligned_once`）
    // 为什么要有 ③：首帧 / 从未对齐过时，我们**根本不知道**云端有没有本机缺的行。
    // 这时说"导出成功"等于替她保证了一件我们并不知道的事，而失败模式是
    // "她以为记忆都带走了，其实少了一块，且永远不会发现"——这就是静默数据丢失。
    // 代价只是一行提示文案。代价不对称到这个程度，就选诚实那边。
    final alignedOnce = await Prefs.cloudAlignedOnce() > 0;
    final isComplete = cloud.signedIn && !cloud.dirMismatch && alignedOnce;
    String message;
    try {
      final lines = await cloud.buildLocalJournalLines();
      // 走 exportAndShare：文件写到 App 私有目录，**用户拿不到**，所以导出
      // 成功后必须把文件递进系统分享面板（保存到文件 / 发给自己 / 存网盘）。
      // 分享失败不改变导出结果——文件已经在磁盘上了。
      final r = await ExportShare.exportAndShare(
        lines: lines,
        mode: mode,
        cloudSync: cloudSync,
        isComplete: isComplete,
      );
      message = r.message;
    } catch (_) {
      // 兜底：导出服务内部已 try/catch，这里只防「取本机行」这一步自己抛。
      // C5③ 失败口径一致：说失败，不给成功暗示。
      message = '导出失败：读写出现异常，请稍后重试（记忆仍在，未受影响）';
    }
    if (!mounted) return;
    setState(() {
      _exporting = false;
      _exportStatus = message;
    });
    _snack(message);
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

  /// 「云端按时送达」开关（T06）。
  ///
  /// 开之前必须二次确认：这个功能的代价是"内容过第三方 + 只在最近开过 App 时带记忆"，
  /// 不写清楚就等于用一句"已开启"把边界藏起来。关掉时立刻恢复 L1/L2，
  /// **不许留"云端关了本地也没了"的空窗**（§5A.9）。
  Future<void> _cloudProactiveToggle(bool v) async {
    final app = context.read<AppState>();
    final name = app.companion?.name ?? '';
    if (!v) {
      await Prefs.setCloudProactive(Prefs.cloudProactiveOff);
      if (!mounted) return;
      setState(() => _cloudProactiveOn = false);
      // 立刻恢复本地排程（applySettings 也会走到这里，但用户刚点完就要有反馈）
      try {
        await ProactiveService.reschedule(name: name);
      } catch (_) {
        // 恢复失败只影响本地通知，不能因此把开关状态回滚成"还开着"。
      }
      _snack('已关闭云端送达，本地提醒恢复');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('开启云端按时送达？'),
        content: const Text(
            '开启后，消息由云端服务器按时推送到微信，内容会经过第三方服务器'
            '（pushplus）与云开发环境；App 里不会再重复提醒。\n\n'
            '同时：本机的定时提醒会停用（否则一天会响两次），只保留兜底记录。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('再想想')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开启')),
        ],
      ),
    );
    if (ok != true) return;

    await Prefs.setCloudProactive(Prefs.cloudProactiveOn);
    if (!mounted) return;
    setState(() => _cloudProactiveOn = true);
    // 停用 L1/L2、只留 L3：这条路必须真的走到 reschedule，否则旧排程还会响。
    try {
      await ProactiveService.reschedule(name: name);
    } catch (_) {}
    _snack('已开启云端送达');
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

  Future<void> _openProactiveDiagnostics() async {
    await Navigator.pushNamed(context, '/diagnostics');
    if (!mounted) return;
    final diag = await ProactiveDiag.load();
    if (mounted) setState(() => _diag = diag);
  }

  List<Widget> _appearanceSettings(BuildContext context) {
    return [
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
        leading: const Icon(Icons.wallpaper_rounded),
        title: const Text('聊天背景'),
        subtitle: const Text('预设渐变，或用自己相册里的图'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.pushNamed(context, '/background'),
      ),
    ];
  }

  List<Widget> _chatSettings(BuildContext context) {
    final theme = Theme.of(context);
    return [
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.psychology_outlined),
        title: const Text('她的自我'),
        subtitle: const Text('她长出来的想法 · 可查看来源、可删'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SelfPage()),
        ),
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
        subtitle:
            Text(_styleProfileStatus(context.watch<AppState>().styleProfile)),
        // 只读状态行：档案是机器蒸馏产物，不做编辑入口
        // （与「人设定稿不改」同一精神），攒够修改自动更新。
      ),
      Padding(
        padding: const EdgeInsets.only(left: 56, bottom: 4),
        child: Text(
          '节奏适配：档案只用来对齐句长和节奏，不模仿对方的用词、情绪和态度——'
          '她和 TA 是两个人；和「她的自我」冲突时，以她自己的说法为准。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: Colors.grey.shade600, height: 1.6),
        ),
      ),
      const Divider(height: 24),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _moodEnabled,
        title: const Text('她会有情绪'),
        subtitle: const Text('一直不理她会生气、会甩个表情不说话，得哄；哄好了会自己下台阶。关掉就永远好脾气'),
        onChanged: (v) => setState(() => _moodEnabled = v),
      ),
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
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.menu_book_outlined),
        title: const Text('查看行为记录手册'),
        subtitle: const Text('能看到记了什么，也能逐条删'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.pushNamed(context, '/manual'),
      ),
    ];
  }

  List<Widget> _proactiveSettings(BuildContext context) {
    return [
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
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            const Text('每天'),
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
        const Text('提醒时段'),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            DropdownButton<int>(
              value: _s.startHour,
              items: _hours(0, 22),
              onChanged: (v) => setState(() => _s = ProactiveSettings(
                    enabled: true,
                    perDay: _s.perDay,
                    startHour: v ?? 9,
                    endHour: _s.endHour > (v ?? 9) ? _s.endHour : (v ?? 9) + 1,
                  )),
            ),
            const Text('至'),
            DropdownButton<int>(
              value: _s.endHour > 24 ? 24 : _s.endHour,
              items: _hours(1, 24),
              onChanged: (v) => setState(() => _s = ProactiveSettings(
                    enabled: true,
                    perDay: _s.perDay,
                    startHour: _s.startHour,
                    endHour:
                        (v ?? 23) > _s.startHour ? (v ?? 23) : _s.startHour + 1,
                  )),
            ),
          ],
        ),
      ],
      const Divider(height: 28),
      ListenableBuilder(
        listenable: CloudSync.instance,
        builder: (context, _) {
          final available = _cloudSyncOn && CloudSync.instance.hasPassphrase;
          return SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: available && _cloudProactiveOn,
            title: const Text('云端按时送达'),
            subtitle: Text(available
                ? '云端靠 App 预先生成的话，最近 48 小时内打开过 App 才带记忆'
                : '请先在「同步与导出」中开启云同步并设置口令'),
            onChanged: available && !_cloudBusy ? _cloudProactiveToggle : null,
          );
        },
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.monitor_heart_outlined),
        title: const Text('主动消息诊断'),
        subtitle: Text(ProactiveDiag.summary(_diag)),
        trailing: const Icon(Icons.chevron_right),
        onTap: _openProactiveDiagnostics,
      ),
    ];
  }

  List<Widget> _dataSettings(BuildContext context) {
    final theme = Theme.of(context);
    return [
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
                subtitle: const Text('聊天记忆备份到云端你自己的口令目录下；关掉后云端不再变动，本机数据不受影响'),
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
                  subtitle: Text('最后同步：${_fmtTime(cloud.lastSyncAt)}'),
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
                                  final confirmed = await showDialog<bool>(
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
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 10),
                        Text('正在同步…'),
                      ],
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _cloudBusy ? null : _cloudAlign,
                      icon: const Icon(Icons.sync_outlined, size: 18),
                      label: const Text('对齐云端'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _cloudBusy ? null : _cloudRestore,
                      icon: const Icon(Icons.restore_outlined, size: 18),
                      label: const Text('从云端恢复'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _cloudBusy ? null : _cloudChangePassphrase,
                      icon: const Icon(Icons.key_outlined, size: 18),
                      label: const Text('修改口令'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _cloudBusy ? null : _cloudDisable,
                      icon: const Icon(Icons.cloud_off_outlined, size: 18),
                      label: const Text('关闭同步'),
                    ),
                  ],
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.verified_user_outlined),
                  title: Text('授权码（${_hasAuthCode ? '已设置' : '未设置'}）'),
                  subtitle: const Text('授权码用于销毁云母库等高危操作，只在 App 本机保存'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _cloudBusy ? null : _cloudAuthCode,
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
      Text('导出本机数据', style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
        '导出后可通过系统分享保存文件。「只导出记忆」不含聊天原文。',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: Colors.grey.shade600, height: 1.6),
      ),
      const SizedBox(height: 10),
      // 两个按钮并列：同一份本机数据，两套白名单（C6/C7 说的就是这两份的差值）。
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          OutlinedButton.icon(
            onPressed: _exporting ? null : () => _export(ExportMode.full),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('导出全部'),
          ),
          OutlinedButton.icon(
            onPressed: _exporting ? null : () => _export(ExportMode.memoryOnly),
            icon: const Icon(Icons.psychology_outlined, size: 18),
            label: const Text('只导出记忆'),
          ),
        ],
      ),
      if (_exporting)
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Row(
            children: [
              SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10),
              Text('正在导出…'),
            ],
          ),
        ),
      // C5 的真实文案（三种正常分支 + 失败分支）常驻显示，不靠一闪而过的提示。
      if (_exportStatus != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            _exportStatus!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.grey.shade700, height: 1.6),
          ),
        ),
      const Divider(height: 28),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        leading:
            Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
        title: const Text('清理与重置'),
        children: [
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
          ListenableBuilder(
            listenable: CloudSync.instance,
            builder: (context, _) {
              if (!_cloudSyncOn || !CloudSync.instance.hasPassphrase) {
                return const SizedBox.shrink();
              }
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.local_fire_department_outlined,
                    color: theme.colorScheme.error),
                title: Text('销毁云母库',
                    style: TextStyle(color: theme.colorScheme.error)),
                subtitle: const Text('清空云端记忆，需要授权码确认'),
                onTap: _cloudBusy ? null : _cloudDestroy,
              );
            },
          ),
        ],
      ),
    ];
  }

  List<Widget> _connectionSettings(BuildContext context) {
    final theme = Theme.of(context);
    return [
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
        label: Text(_testing ? '测试中…' : '测试连接'),
      ),
      if (_testMessage != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _testMessage!,
            style: TextStyle(
                fontSize: 13,
                color:
                    _testOk ? Colors.green.shade700 : theme.colorScheme.error),
          ),
        ),
      const SizedBox(height: 8),
      Text(
        'Key 只存在这台手机上。把 APK 发给朋友时，对方填自己的 Key。',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: Colors.grey.shade600, height: 1.6),
      ),
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
    ];
  }

  List<Widget> _updateSettings(BuildContext context) {
    final theme = Theme.of(context);
    return [
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.system_update_alt_rounded),
        title: Text('当前版本 $_versionText'),
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
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
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
        subtitle: const Text('启动后在后台查版本、下安装包，不挡聊天也不弹窗；下好才提示一下，装不装你说了算'),
        onChanged: (v) => setState(() => _silentUpdate = v),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 4, bottom: 6),
        child: SilentUpdateBanner(showProgress: true),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingsSection(
              icon: Icons.palette_outlined,
              title: '外观与人设',
              description: '头像、昵称、聊天背景、人设档案',
              children: _appearanceSettings(context),
            ),
            _SettingsSection(
              icon: Icons.forum_outlined,
              title: '聊天与记忆',
              description: '她的自我、说话方式、情绪、记忆窗口',
              children: _chatSettings(context),
            ),
            _SettingsSection(
              icon: Icons.notifications_outlined,
              title: '主动消息',
              description: '本地提醒、云端送达、通知诊断',
              children: _proactiveSettings(context),
            ),
            _SettingsSection(
              icon: Icons.cloud_outlined,
              title: '同步与导出',
              description: '云端备份、换机恢复、导出与清理',
              children: _dataSettings(context),
            ),
            _SettingsSection(
              icon: Icons.tune_rounded,
              title: '连接与模型',
              description: 'DeepSeek API Key、回复随机度',
              children: _connectionSettings(context),
            ),
            _SettingsSection(
              icon: Icons.system_update_alt_rounded,
              title: '版本与更新',
              description: '检查更新、后台下载',
              children: _updateSettings(context),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Material(
          color: colors.surface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存设置'),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.description,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(16)),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: shape,
        collapsedShape: shape,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        leading: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.secondaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Icon(icon, size: 21, color: colors.onSecondaryContainer),
          ),
        ),
        title: Text(title, style: theme.textTheme.titleMedium),
        subtitle: Text(description,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant)),
        children: children,
      ),
    );
  }
}
