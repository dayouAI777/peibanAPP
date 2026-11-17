import 'dart:async';
import 'dart:convert';

import 'package:cloudbase_flutter/cloudbase_flutter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';

import '../data/db_helper.dart';
import '../data/prefs.dart';
import '../models/journal.dart';

/// 云同步状态。
///
/// - off：开关没开（用户自己关的，不算故障）
/// - noPassphrase：开了但还没设置同步口令（或还没完成过一次同步）
/// - syncing：一次对齐/推送/拉取正在进行
/// - synced：最近一次对齐/推送/拉取成功
/// - error：最近一次失败，[CloudSync.lastError] 有中文文案
enum SyncStatus { off, noPassphrase, syncing, synced, error }

/// 一次对齐 / 推送 / 拉取的结果。message 给界面直接显示（中文）。
class AlignResult {
  final bool ok;
  final String message;

  /// 本次真正追加到云端的记录条数。
  final int pushed;

  /// 本次真正补进本地的记录条数。
  final int pulled;

  const AlignResult({
    required this.ok,
    required this.message,
    this.pushed = 0,
    this.pulled = 0,
  });
}

/// 设置/修改口令的结果。
///
/// ok = 口令流程真实走完（新设成功、或口令没变且云端确为最新）；
/// message 是真实结果文案——界面照着显示，**不许自己编「成功」**
/// （弹窗成功 ≠ 逻辑成功，本项目血泪教训）。
class PassphraseOutcome {
  final bool ok;
  final String message;

  const PassphraseOutcome(this.ok, this.message);
}

/// 记忆上云 V2：云母库日志追加制。
///
/// **云端是唯一权威（「云母库」），只增、不删、不覆盖。** 手机端和电脑 Agent 端
/// 都只往里添加，任何一方都不能改写或删除云端历史。云端文件是一条 UTF-8 JSONL
/// 追加日志：`memories/<sha256('peiban-sync-v1:' + 口令)>/journal.jsonl`，
/// 协议见 [JournalLine]（lib/models/journal.dart，三方共用）。
///
/// 对齐（align）= 先推送（本地有、云端没有的按确定性 key 追加到云端），
/// 再拉取（云端有、本地没有的补进本地）。key 由内容算出，即使两个写入方并发
/// 互相覆盖了对方的追加行，下一次对齐会因 key 仍缺失而自动补回——自我修复。
/// 本地删除只在本地生效，云端永远保留。
///
/// **协议全文（三方共用，不许各自解释）：**
/// 1. 默认只增追加：手机端与电脑 Agent 端同权，都只能往 journal.jsonl 里追加
///    新行（key 不在就加），重新上传时云端已有的行原样保留，一行不删不改。
/// 2. 唯一覆盖例外 = 授权销毁（destroyCloud）：用空 journal 整文件重置云端。
///    只允许在 App 内、验证授权码（cloud_auth_code，仅存本机、与同步口令完全
///    独立）后执行；**电脑 Agent 端永不实现销毁/改写**。销毁后 App 会立即把
///    本地当前记忆重新对齐上传。
/// 3. journal 行里 `dev` 字段区分写入方（phone / agent），各方身份只做标注，
///    不带来任何额外权限。
///
/// 登录用云端的匿名会话（SDK 自动持久化），用户完全不感知账号；数据只走 PG
/// 云存储。口令明文存本机 prefs（它只是同步凭证，泄露最多丢云端备份）。
/// 全部异常吞掉转成中文状态——**同步失败永远不许阻塞聊天**。
class CloudSync extends ChangeNotifier {
  CloudSync._();
  static final CloudSync instance = CloudSync._();

  /// 云开发环境参数（Publishable Key 设计上就是要嵌客户端的，非机密）。
  static const String envId = 'naughty-beaver-d7gdchzub18ffae94';
  static const String region = 'ap-shanghai';
  static const String _accessKey =
      'eyJhbGciOiJSUzI1NiIsImtpZCI6IjVkNDQ5ZDUzLTAzODMtNDg4My05MzQ4LWRjNDM0YmZjMDcwYyJ9.eyJpc3MiOiJodHRwczovL25hdWdodHktYmVhdmVyLWQ3Z2RjaHp1YjE4ZmZhZTk0LmFwLXNoYW5naGFpLnRjYi1hcGkudGVuY2VudGNsb3VkYXBpLmNvbSIsInN1YiI6ImFub24iLCJhdWQiOiJuYXVnaHR5LWJlYXZlci1kN2dkY2h6dWIxOGZmYWU5NCIsImV4cCI6NDA5ODU3NzE3MSwiaWF0IjoxNzk0ODkzOTcxLCJub25jZSI6ImdRSVp4emFyVDM2djV0alRoYjZsSmciLCJhdF9oYXNoIjoiZ1FJWnh6YXJUMzZ2NXRqVGhiNmxKZyIsIm5hbWUiOiJBbm9ueW1vdXMiLCJzY29wZSI6ImFub255bW91cyIsInByb2plY3RfaWQiOiJuYXVnaHR5LWJlYXZlci1kN2dkY2h6dWIxOGZmYWU5NCIsIm1ldGEiOnsicGxhdGZvcm0iOiJQdWJsaXNoYWJsZUtleSJ9LCJyb2xlIjoiYW5vbiIsImlzX2Fub255bW91cyI6dHJ1ZSwiYXBwX21ldGFkYXRhIjp7InByb3ZpZGVyIjoiYW5vbnltb3VzIiwicHJvdmlkZXJzIjpbImFub255bW91cyJdfSwidXNlcl9tZXRhZGF0YSI6eyJuYW1lIjoiQW5vbnltb3VzIn0sInVzZXJfdHlwZSI6IiIsImNsaWVudF90eXBlIjoiY2xpZW50X3VzZXIiLCJpc19zeXN0ZW1fYWRtaW4iOmZhbHNlfQ.FgEUYKyhguzB56FbC0ok3IsQBYTG3zHEX6gcNoxyT6kkkVIgMYRNVI6Nv3uYMiAa_ebuosEXFMMbxvibFRQDux-wfyI0f_TG94QeJMvQHhlr396BjmV9juT5YRBnHTcOSiXSMIR-tGOWR82tniPvlG39xvDfDMlFnNLawOZo52t3a0tEPp6DSAhg434fbUxBjlONg70A-qkgqem5H4loOK33fqXJJMuIc630n0kGfLQ2-7LfZZfJe7SOknqjAjgNkuN2jOnVa3VDmkBL6UQX9U0uy8wIzHl3UOnP5ZAiWvfSq_IMV_CyzIm1d__mKVhy25yaS6f0VlL-AsfyoTpmw';

  /// PG（Neo）云存储的桶。PG 环境禁用老式 COS 存储（SDK_UPGRADE_REQUIRED），
  /// 必须走 fromBucket。桶由主理人在管理端建好，客户端不建桶。
  static const String bucketId = 'memories';

  /// 口令哈希的盐前缀：参与哈希，避免纯口令直接出现在目录名的彩虹表里。
  static const String _passphraseSalt = 'peiban-sync-v1:';

  /// 口令最小长度（客户端强校验）。
  static const int minPassphraseLength = 8;

  /// 发完消息后延迟多久才推送（防抖：连续聊天只推最后一次）。
  static const Duration uploadDebounce = Duration(minutes: 5);

  CloudBase? _app;
  Timer? _debounce;
  bool _busy = false;

  SyncStatus _status = SyncStatus.off;
  SyncStatus get status => _status;

  String _uid = '';
  String _passphrase = '';
  int _lastSyncAt = 0;
  bool _enabled = false;

  String get uid => _uid;
  int get lastSyncAt => _lastSyncAt;
  bool get enabled => _enabled;
  bool get hasPassphrase => _passphrase.isNotEmpty;
  bool get signedIn => _uid.isNotEmpty;
  bool get isBusy => _busy;

  /// 最近一次失败的中文文案（给设置页直接显示）。
  String? lastError;

  /// 口令 → 云端目录名：sha256('peiban-sync-v1:' + 口令) 的 64 位小写十六进制。
  /// 同口令永远同目录，不同口令不同目录（改动即换目录，旧目录留在云端）。
  static String snapshotDirFor(String passphrase) =>
      sha256.convert(utf8.encode('$_passphraseSalt$passphrase')).toString();

  /// 云母库在 memories 桶内的完整路径。<哈希>/journal.jsonl。
  String get journalPath => '${snapshotDirFor(_passphrase)}/journal.jsonl';

  // ——— 初始化 ———

  /// 懒初始化 CloudBase。失败只记录，绝不抛——同步是锦上添花，不能崩主流程。
  Future<CloudBase?> _ensureApp() async {
    if (_app != null) return _app;
    try {
      _app = await CloudBase.init(
        env: envId,
        region: region,
        accessKey: _accessKey,
      );
      return _app;
    } catch (e) {
      lastError = '连不上云端，请检查网络';
      assert(() {
        debugPrint('[cloud_sync] init failed: $e');
        return true;
      }());
      return null;
    }
  }

  /// 启动时调一次：读开关和口令，恢复状态。只查询、不登录不上传下载。
  /// **没有静默自动拉取**——手动「对齐云端」是唯一拉取入口。
  Future<void> bootstrap() async {
    _passphrase = await Prefs.cloudPassphrase();
    _lastSyncAt = await Prefs.cloudLastSyncAt();
    _enabled = await Prefs.cloudSync();
    if (!_enabled) {
      _status = SyncStatus.off;
    } else if (_passphrase.isEmpty) {
      _status = SyncStatus.noPassphrase;
    } else {
      // 有口令：匿名会话由 SDK 自己从本地恢复，等第一次同步时 ensureSignedIn。
      // 这里只按「有没有成功同步过」给个初始状态。
      _status = _lastSyncAt > 0 ? SyncStatus.synced : SyncStatus.noPassphrase;
    }
    notifyListeners();
  }

  // ——— 匿名登录（幂等） ———

  /// 确保有一个可用的云端会话：先试 SDK 存着的旧会话，没有才匿名登录。
  /// 成功返回 true；失败把 lastError 设为中文文案（网络类错误统一口径）。
  Future<bool> ensureSignedIn() async {
    if (_uid.isNotEmpty) return true;
    final app = await _ensureApp();
    if (app == null) return false;
    // 1) SDK 持久化的旧会话（含匿名），能用就不重复登录
    try {
      final res = await app.auth.getSession();
      final id = res.data?.user?.id;
      if (res.error == null && id != null && id.isNotEmpty) {
        _uid = id;
        return true;
      }
    } catch (_) {
      // 查会话失败（多半是离线），继续试匿名登录——也会失败，统一走下面的文案
    }
    // 2) 匿名登录
    try {
      final anon = await app.auth.signInAnonymously();
      if (anon.error != null) {
        lastError = '连不上云端，请检查网络';
        assert(() {
          debugPrint('[cloud_sync] anonymous sign-in failed: ${anon.error}');
          return true;
        }());
        return false;
      }
      final id = anon.data?.user?.id ?? '';
      if (id.isEmpty) {
        lastError = '连不上云端，请检查网络';
        return false;
      }
      _uid = id;
      return true;
    } catch (e) {
      lastError = '连不上云端，请检查网络';
      assert(() {
        debugPrint('[cloud_sync] anonymous sign-in error: $e');
        return true;
      }());
      return false;
    }
  }

  /// 云同步开关。关掉时取消排队的防抖推送；口令保留（重新打开不用重输）。
  Future<void> setEnabled(bool v) async {
    _enabled = v;
    await Prefs.setCloudSync(v);
    if (!v) {
      _debounce?.cancel();
      _debounce = null;
      _status = SyncStatus.off;
    } else {
      _status = hasPassphrase
          ? (_lastSyncAt > 0 ? SyncStatus.synced : SyncStatus.noPassphrase)
          : SyncStatus.noPassphrase;
    }
    notifyListeners();
  }

  /// 设置 / 修改同步口令。
  ///
  /// 校验长度 → 存 prefs → 视情况触发推送（新口令=新目录，立刻把本地记忆追加
  /// 过去；旧口令的备份留在云端不删）。返回 [PassphraseOutcome]：ok 与 message
  /// 都是真实结果，界面照实显示，不硬编码「成功」。
  Future<PassphraseOutcome> setPassphrase(String passphrase) async {
    final v = passphrase.trim();
    if (v.length < minPassphraseLength) {
      return PassphraseOutcome(
          false, '口令至少 $minPassphraseLength 位，再想一个长一点的');
    }
    final changed = v != _passphrase;
    _passphrase = v;
    await Prefs.setCloudPassphrase(v);
    if (!_enabled) {
      // 设口令即视为开启同步
      _enabled = true;
      await Prefs.setCloudSync(true);
    }
    notifyListeners();

    // 口令没变且云端已经是最新：什么都不做，如实告诉用户，不假装上传了
    if (!changed && _lastSyncAt > 0) {
      return const PassphraseOutcome(true, '口令没有变化，云端备份还是最新的');
    }

    // 第一次设口令，或换了口令（换了目录）：推送一份过去（只推送，安全）
    final r = await pushOnly();
    if (!r.ok) {
      return PassphraseOutcome(false, r.message);
    }
    return changed
        ? const PassphraseOutcome(true, '口令已更新，本地记忆已传到新目录')
        : const PassphraseOutcome(true, '口令没有变化，本地记忆已传到云端');
  }

  // ——— 授权码（销毁等高危操作的本地凭证，与同步口令完全独立）———

  /// 授权码本地比对（不上传校验）。未设置时任何输入都算不匹配。
  static bool authCodeMatches(String stored, String input) =>
      stored.isNotEmpty && input.trim() == stored;

  /// 首次设置授权码。已设置过则拒绝（走 [changeAuthCode] 修改流程）。
  Future<PassphraseOutcome> setAuthCode(String code) async {
    final v = code.trim();
    if (v.length < minPassphraseLength) {
      return PassphraseOutcome(
          false, '授权码至少 $minPassphraseLength 位，再想一个长一点的');
    }
    if ((await Prefs.cloudAuthCode()).isNotEmpty) {
      return const PassphraseOutcome(false, '授权码已经设置过了，请走修改流程');
    }
    await Prefs.setCloudAuthCode(v);
    return const PassphraseOutcome(true, '授权码已设置（只保存在本机）');
  }

  /// 修改授权码：先本地比对旧授权码，通过且新码合规才落盘。
  Future<PassphraseOutcome> changeAuthCode(String oldCode, String newCode) async {
    final stored = await Prefs.cloudAuthCode();
    if (stored.isEmpty) {
      return const PassphraseOutcome(false, '授权码还没设置过，直接设置即可');
    }
    if (!authCodeMatches(stored, oldCode)) {
      return const PassphraseOutcome(false, '旧授权码不对，没有修改');
    }
    final v = newCode.trim();
    if (v.length < minPassphraseLength) {
      return PassphraseOutcome(
          false, '新授权码至少 $minPassphraseLength 位，再想一个长一点的');
    }
    await Prefs.setCloudAuthCode(v);
    return const PassphraseOutcome(true, '授权码已修改（只保存在本机）');
  }

  // ——— 对齐 / 推送 / 拉取 ———

  /// 手动「对齐云端」：一次点击完成双向补齐。
  ///
  /// 先推送（本地有、云端没有的记忆追加到云端），再拉取（云端有、本地没有的
  /// 补进本地）。对齐后两边一致。返回结果（含真实条数）；失败不抛异常。
  Future<AlignResult> align() => _run(doPush: true, doPull: true, verb: '对齐');

  /// 只推送（append-only，安全）：防抖上传与退后台补推走这里。
  /// 不往本地写任何东西，所以即使并发乱序也只会「下次对齐自动补回」。
  Future<AlignResult> pushOnly() =>
      _run(doPush: true, doPull: false, verb: '上传');

  /// 只拉取：「从云端恢复」按钮走这里（全量拉云母库，按「只补缺」合并进本地）。
  Future<AlignResult> pullOnly() =>
      _run(doPush: false, doPull: true, verb: '恢复');

  /// 「销毁云母库」：全协议唯一允许的覆盖点——用空 journal 整文件重置云端。
  ///
  /// 仅限 App 内、验证授权码后执行（授权码校验只在本地比对，不上传）；
  /// 电脑 Agent 端永不实现。销毁失败（网络等）时云端保持原样、本地不受影响。
  /// 销毁成功后自动执行一次完整对齐，把本地当前记忆重新推上去
  /// （align 内部会更新 lastSyncAt）。
  Future<AlignResult> destroyCloud(String authCode) async {
    // 授权码校验放最前：码不对/没设置时，一步都不往云端走
    final stored = await Prefs.cloudAuthCode();
    if (stored.isEmpty) {
      return const AlignResult(ok: false, message: '还没有设置授权码，销毁需要授权');
    }
    if (!authCodeMatches(stored, authCode)) {
      return const AlignResult(ok: false, message: '授权码不对，销毁没有执行');
    }
    if (_busy) return const AlignResult(ok: false, message: '上一次同步还没结束');
    if (!_enabled) {
      return const AlignResult(ok: false, message: '云同步没有开启');
    }
    if (_passphrase.isEmpty) {
      return const AlignResult(ok: false, message: '还没有设置同步口令');
    }
    final app = await _ensureApp();
    if (app == null) {
      _setStatus(SyncStatus.error, lastError);
      return AlignResult(
          ok: false, message: lastError ?? '连不上云端，请检查网络');
    }
    if (!await ensureSignedIn()) {
      _setStatus(SyncStatus.error, lastError);
      return AlignResult(
          ok: false, message: lastError ?? '连不上云端，请检查网络');
    }
    // 全程持有同一把忙锁：从空覆盖到重推之间，防抖 pushOnly / 退后台补推
    // 都插不进来——不会出现「销毁刚完成、旧数据被并发写回复活且销毁还报成功」
    _busy = true;
    try {
      _setStatus(SyncStatus.syncing, null);
      try {
        final bucket = app.storage.fromBucket(bucketId);
        // 覆盖上传空 journal（全协议唯一的整文件覆盖点）
        final up = await bucket.upload(
          journalPath,
          utf8.encode(''),
          options: PgStorageUploadOptions(
            contentType: 'application/jsonl',
            upsert: true,
          ),
        );
        if (up.error != null) {
          // 上传失败：云端保持原样，一个字节都没动
          final msg = _storageMessage(up.error!, '销毁失败');
          _setStatus(SyncStatus.error, msg);
          return AlignResult(ok: false, message: '$msg（云端保持原样）');
        }
      } catch (e) {
        final msg = _anyMessage(e, '销毁失败');
        _setStatus(SyncStatus.error, msg);
        return AlignResult(ok: false, message: '$msg（云端保持原样）');
      }
      // 销毁成功：同一把锁内立即把本地当前记忆重新对齐上传
      final r = await _runLocked(app, doPush: true, doPull: true, verb: '对齐');
      if (!r.ok) {
        _setStatus(SyncStatus.error, r.message);
        return AlignResult(
          ok: false,
          message: '云端已清空，但重新上传本地记忆失败：${r.message}'
              '（下次对齐会自动补回）',
        );
      }
      return AlignResult(
        ok: true,
        message: '云母库已销毁，本地当前记忆已重新上传（推送 ${r.pushed} 条）',
        pushed: r.pushed,
      );
    } finally {
      _busy = false;
    }
  }

  /// 对齐算法的公共实现（App 端 align()；Agent 端未来同款）：
  ///
  /// 1. 下载 journal.jsonl → 解析全部有效行 + key 集合（坏行跳过；NOT_FOUND = 空库）
  /// 2. 推送：导出本地全部记录，逐条算 key；key 不在云端 key 集合的 → 生成追加行
  /// 3. 写回：「下载的原文 + 追加行」按原行顺序合并（追加行在后面）重新上传。
  ///    云端已有的行原样保留，一行不删不改。3 和 4 之间若上传失败，下次对齐
  ///    仍会因 key 缺失自动重推（幂等、自愈）
  /// 4. 拉取：云端记录走 restoreCloudData 式补缺（内容级去重、坏行净化、
  ///    本地为主；人设本地有则忽略；speechProfile / styleProfile 本地有才不采用）
  /// 5. 更新 lastSyncAt，返回对齐结果（推送 N 条 / 拉取 M 条）
  Future<AlignResult> _run({
    required bool doPush,
    required bool doPull,
    required String verb,
  }) async {
    if (_busy) return const AlignResult(ok: false, message: '上一次同步还没结束');
    if (!_enabled) {
      return const AlignResult(ok: false, message: '云同步没有开启');
    }
    if (_passphrase.isEmpty) {
      return const AlignResult(ok: false, message: '还没有设置同步口令');
    }
    final app = await _ensureApp();
    if (app == null) {
      _setStatus(SyncStatus.error, lastError);
      return AlignResult(
          ok: false, message: lastError ?? '连不上云端，请检查网络');
    }
    if (!await ensureSignedIn()) {
      _setStatus(SyncStatus.error, lastError);
      return AlignResult(
          ok: false, message: lastError ?? '连不上云端，请检查网络');
    }
    _busy = true;
    try {
      return await _runLocked(app, doPush: doPush, doPull: doPull, verb: verb);
    } finally {
      _busy = false;
    }
  }

  /// 对齐/拉取核心（调用方必须已持 `_busy` 锁；本方法不管锁、不管门禁）。
  ///
  /// destroyCloud 的「空覆盖 → 重推」全程共用同一把锁，中间防抖 pushOnly
  /// 插不进来——不会出现「销毁刚完成、旧数据被并发写回复活」的竞态。
  ///
  /// 1. 下载 journal.jsonl → 解析全部有效行 + key 集合（坏行跳过；NOT_FOUND = 空库）
  /// 2. 推送：导出本地全部记录，逐条算 key；key 不在云端 key 集合的 → 生成追加行
  /// 3. 写回：「下载的原文 + 追加行」按原行顺序合并（追加行在后面）重新上传。
  ///    云端已有的行原样保留，一行不删不改。3 和 4 之间若上传失败，下次对齐
  ///    仍会因 key 缺失自动重推（幂等、自愈）
  /// 4. 拉取：云端记录走 restoreCloudData 式补缺（内容级去重、坏行净化、
  ///    本地为主；人设本地有则忽略；speechProfile / styleProfile 本地有才不采用）
  /// 5. 更新 lastSyncAt，返回对齐结果（推送 N 条 / 拉取 M 条）
  Future<AlignResult> _runLocked(
    CloudBase app, {
    required bool doPush,
    required bool doPull,
    required String verb,
  }) async {
    _setStatus(SyncStatus.syncing, null);
    try {
      final bucket = app.storage.fromBucket(bucketId);

      // ——— 1. 下载云母库（不存在 = 空库，不是错误）———
      var raw = '';
      var cloudMissing = false;
      final down = await bucket.download(journalPath);
      if (down.error != null) {
        final code = (down.error!.code ?? '').toUpperCase();
        final status = down.error!.status ?? 0;
        final missing = code.contains('NOT_FOUND') ||
            status == 404 ||
            code.contains('NO_SUCH');
        if (!missing) {
          final msg = _storageMessage(down.error!, '$verb失败');
          _setStatus(SyncStatus.error, msg);
          return AlignResult(ok: false, message: msg);
        }
        cloudMissing = true;
      } else {
        raw = utf8.decode(down.data ?? <int>[]);
      }
      final cloudLines = parseJournalLines(raw);
      final cloudKeys = cloudLines.map((l) => l.key).toSet();
      // 同 key 取 ts 最大的一行：给 speech/persona 的「内容变了才追加」比较用
      final cloudLatest = <String, JournalLine>{};
      for (final l in cloudLines) {
        final cur = cloudLatest[l.key];
        if (cur == null || l.ts >= cur.ts) cloudLatest[l.key] = l;
      }

      // ——— 2 & 3. 推送段：本地有、云端没有的 → 追加合并写回 ———
      var pushed = 0;
      if (doPush) {
        final local = await _exportLocal();
        final appended = <JournalLine>[];

        void addUnique(
            String key, String type, int ts, Map<String, dynamic> data) {
          if (cloudKeys.contains(key)) return;
          appended.add(JournalLine(type: type, key: key, ts: ts, data: data));
        }

        for (final m in local.messages) {
          final role = m['role'];
          final at = m['created_at'];
          if (role is String && at is int) {
            addUnique(journalKeyForMessage(role, at), JournalLine.typeMessage,
                at, m);
          }
        }
        for (final n in local.notes) {
          final content = n['content'];
          if (content is! String || content.trim().isEmpty) continue;
          final cat = n['category'] is String ? n['category'] as String : '';
          final at = n['created_at'] is int ? n['created_at'] as int : 0;
          addUnique(journalKeyForNote(cat, content), JournalLine.typeNote, at,
              n);
        }
        for (final e in local.styleExamples) {
          final original = e['original'];
          final preferred = e['preferred'];
          if (original is! String || preferred is! String) continue;
          if (preferred.trim().isEmpty) continue;
          final at = e['created_at'] is int ? e['created_at'] as int : 0;
          addUnique(journalKeyForStyleExample(original, preferred),
              JournalLine.typeStyleExample, at, e);
        }
        for (final c in local.memoryChunks) {
          final summary = c['summary'];
          if (summary is! String || summary.trim().isEmpty) continue;
          final fromId = c['from_id'] is int ? c['from_id'] as int : 0;
          final toId = c['to_id'] is int ? c['to_id'] as int : 0;
          final at = c['created_at'] is int ? c['created_at'] as int : 0;
          addUnique(
              journalKeyForMemoryChunk(fromId, toId, summary),
              JournalLine.typeMemoryChunk,
              at,
              c);
        }
        // speech / style_profile / persona：固定 key 的整对象记录。内容变了
        // 就追加新行（读者取最新 ts 那行）；内容没变不追加，免得日志无限膨胀。
        _pushSingleWinner(appended, cloudLatest, JournalLine.typeSpeechProfile,
            journalKeySpeechProfile, local.speechProfile);
        _pushSingleWinner(appended, cloudLatest, JournalLine.typeStyleProfile,
            journalKeyStyleProfile, local.styleProfile);
        _pushSingleWinner(appended, cloudLatest, JournalLine.typePersona,
            journalKeyPersona, local.companion);

        if (appended.isNotEmpty) {
          final merged = mergeJournal(raw, appended);
          final up = await bucket.upload(
            journalPath,
            utf8.encode(merged),
            options: PgStorageUploadOptions(
              contentType: 'application/jsonl',
              upsert: true,
            ),
          );
          if (up.error != null) {
            // 上传失败不致命：key 仍缺失，下次对齐会自动重推（幂等、自愈）
            final msg = _storageMessage(up.error!, '$verb时上传失败');
            _setStatus(SyncStatus.error, msg);
            return AlignResult(ok: false, message: msg);
          }
          pushed = appended.length;
        }
      }

      // ——— 4. 拉取段：云端记录补缺进本地（沿用 restoreCloudData 的
      //         内容级去重、坏行净化、本地为主逻辑）———
      var pulled = 0;
      if (doPull && cloudLines.isNotEmpty) {
        final effective = resolveEffectiveLines(cloudLines);
        final notes = <Map<String, dynamic>>[];
        final examples = <Map<String, dynamic>>[];
        final chunks = <Map<String, dynamic>>[];
        final messages = <Map<String, dynamic>>[];
        Map<String, dynamic>? personaData;
        JournalLine? speechLine;
        JournalLine? styleProfileLine;
        for (final l in effective) {
          switch (l.type) {
            case JournalLine.typeMessage:
              messages.add(l.data);
              break;
            case JournalLine.typeNote:
              notes.add(l.data);
              break;
            case JournalLine.typeStyleExample:
              examples.add(l.data);
              break;
            case JournalLine.typeMemoryChunk:
              chunks.add(l.data);
              break;
            case JournalLine.typeSpeechProfile:
              speechLine = l;
              break;
            case JournalLine.typeStyleProfile:
              styleProfileLine = l;
              break;
            case JournalLine.typePersona:
              personaData = l.data;
              break;
          }
        }
        final counts = await DbHelper.instance.restoreCloudData(
          companion: personaData,
          notes: notes,
          styleExamples: examples,
          memoryChunks: chunks,
          messages: messages,
        );
        pulled = counts.values.fold(0, (a, b) => a + b);

        // 说话方式画像：本地有就不动（那是本机静默学习的成果），
        // 本地没有才采用云端的。
        if (speechLine != null && speechLine.data.isNotEmpty) {
          final localSpeech = await Prefs.speechProfile();
          if (localSpeech.trim().isEmpty) {
            await Prefs.setSpeechProfile(jsonEncode(speechLine.data));
          }
        }

        // 她的说话方式档案：手机是唯一蒸馏写入方，本地为主；
        // 本地还没有档案（空）才采用云端的。
        if (styleProfileLine != null && styleProfileLine.data.isNotEmpty) {
          final localStyle = await Prefs.styleProfile();
          if (localStyle.trim().isEmpty) {
            await Prefs.setStyleProfile(jsonEncode(styleProfileLine.data));
          }
        }
      }

      // ——— 5. 收尾 ———
      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      await Prefs.setCloudLastSyncAt(_lastSyncAt);
      _setStatus(SyncStatus.synced, null);
      return AlignResult(
        ok: true,
        message: _resultMessage(verb, pushed: pushed, pulled: pulled,
            cloudMissing: cloudMissing),
        pushed: pushed,
        pulled: pulled,
      );
    } catch (e) {
      final msg = _anyMessage(e, '$verb失败');
      _setStatus(SyncStatus.error, msg);
      return AlignResult(ok: false, message: msg);
    }
  }

  /// speech / persona 这类「整对象一条」记录的推送判断，判定逻辑在
  /// [singleWinnerNeedsPush]（纯静态、可测）。
  void _pushSingleWinner(
    List<JournalLine> appended,
    Map<String, JournalLine> cloudLatest,
    String type,
    String key,
    Map<String, dynamic> data,
  ) {
    if (!singleWinnerNeedsPush(
      cloudLatestData: cloudLatest[key]?.data,
      localData: data,
    )) {
      return;
    }
    appended.add(JournalLine(
      type: type,
      key: key,
      ts: DateTime.now().millisecondsSinceEpoch,
      data: data,
    ));
  }

  /// 导出 / 比较口径：去掉设备本地字段（id、avatar_path）。
  ///
  /// id 是本地自增主键，别的设备没有意义；avatar_path 是本机沙盒路径，
  /// 跨设备必然不同。persona 行的 data 与整 map 比较都用这个口径，
  /// 否则「内容没变不追加」在跨设备场景永不收敛。纯静态、可测。
  static Map<String, dynamic> stripDeviceLocal(Map<String, dynamic>? m) =>
      m == null
          ? <String, dynamic>{}
          : (Map<String, dynamic>.from(m)
            ..remove('id')
            ..remove('avatar_path'));

  /// 整对象记录（speech_profile / persona）的推送判定（纯静态、可测）：
  /// - 本地为空 → 不追加；
  /// - 云端没有该 key → 追加；
  /// - 云端最新行与本地（双方都按 [stripDeviceLocal] 口径去设备本地字段后）
  ///   内容一致 → 不追加；
  /// - 否则 → 追加新行（读者取最新 ts 那行生效）。
  static bool singleWinnerNeedsPush({
    required Map<String, dynamic>? cloudLatestData,
    required Map<String, dynamic> localData,
  }) {
    if (localData.isEmpty) return false;
    final local = stripDeviceLocal(localData);
    if (local.isEmpty) return false;
    if (cloudLatestData == null || cloudLatestData.isEmpty) return true;
    final cloud = stripDeviceLocal(cloudLatestData);
    return !_sameJson(cloud, local);
  }

  /// 内容级比较（key 顺序无关紧要，jsonDecode 保持文档序足够稳定）。
  static bool _sameJson(Map<String, dynamic> a, Map<String, dynamic> b) {
    try {
      return jsonEncode(a) == jsonEncode(b);
    } catch (_) {
      return false;
    }
  }

  String _resultMessage(
    String verb, {
    required int pushed,
    required int pulled,
    required bool cloudMissing,
  }) {
    if (verb == '对齐') {
      if (pushed == 0 && pulled == 0) return '对齐完成：云端和本地已经一致';
      return '对齐完成：上传 $pushed 条，拉取 $pulled 条';
    }
    if (verb == '上传') {
      if (pushed == 0) return '云端记忆已是最新';
      return '已推送 $pushed 条到云端';
    }
    // 恢复
    if (cloudMissing && pulled == 0) {
      return '这个口令下云端还没有记忆库（先在另一台设备上「对齐云端」一次，'
          '或确认口令和之前设的一样）';
    }
    if (pulled == 0) return '云端没有这台设备缺的记录，本地已经是全的';
    return '已从云端补齐 $pulled 条';
  }

  // ——— 本地导出 ———

  /// 从本地库 + 偏好导出待推送的全部记录。全部失败安全：
  /// 任何一块读不出来就置空，不抛。
  Future<_LocalExport> _exportLocal() async {
    final c = await DbHelper.instance.firstCompanion();

    Map<String, dynamic> companion = const <String, dynamic>{};
    if (c != null) {
      // 去设备本地字段（见 [stripDeviceLocal]）：avatar_path 不去掉的话，
      // persona 整 map 比较在跨设备场景永远判「内容变了」，
      // 双方每次对齐互顶追加，日志无限膨胀（恢复端本来就强制 avatar_path=''，
      // 零数据损失）。
      companion = stripDeviceLocal(c.toMap());
    }

    Map<String, dynamic> speech = const <String, dynamic>{};
    try {
      speech = _safeJsonMap(await Prefs.speechProfile());
    } catch (_) {}

    Map<String, dynamic> styleProfile = const <String, dynamic>{};
    try {
      styleProfile = _safeJsonMap(await Prefs.styleProfile());
    } catch (_) {}

    final notes = <Map<String, dynamic>>[];
    try {
      notes.addAll(
          (await DbHelper.instance.userNotes()).map((n) => _strip(n.toMap())));
    } catch (_) {}

    final examples = <Map<String, dynamic>>[];
    final chunks = <Map<String, dynamic>>[];
    final messages = <Map<String, dynamic>>[];
    if (c?.id != null) {
      try {
        // 上云必须全量：范例是用户亲手写的调教成果，一条都不能丢
        examples.addAll((await DbHelper.instance.exportAllStyleExamples(c!.id!))
            .map((e) => _strip(e.toMap()))
            .toList());
      } catch (_) {}
      try {
        chunks.addAll((await DbHelper.instance.memoryChunks(c!.id!))
            .map((e) => _strip(e.toMap()))
            .toList());
      } catch (_) {}
      try {
        // 上云必须全量：不分页、不限上下文窗口。image_path 是本机沙盒路径，
        // 到别的设备一定是死链，companion_id 是本地自增，都不上云。
        messages.addAll((await DbHelper.instance.exportAllMessages(c!.id!))
            .map((m) {
              final m2 = _strip(m.toMap())
                ..remove('companion_id')
                ..remove('image_path');
              return m2;
            })
            .toList());
      } catch (_) {}
    }

    return _LocalExport(
      companion: companion,
      speechProfile: speech,
      styleProfile: styleProfile,
      notes: notes,
      styleExamples: examples,
      memoryChunks: chunks,
      messages: messages,
    );
  }

  /// 掉 id：本地自增主键在别的设备上没有意义。
  Map<String, dynamic> _strip(Map<String, dynamic>? m) =>
      m == null ? <String, dynamic>{} : (Map<String, dynamic>.from(m)..remove('id'));

  Map<String, dynamic> _safeJsonMap(String raw) {
    if (raw.trim().isEmpty) return const <String, dynamic>{};
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return v.cast<String, dynamic>();
    } catch (_) {}
    return const <String, dynamic>{};
  }

  // ——— 防抖与补推 ———

  /// 发完消息后的防抖推送：取消上一个 timer 再排新的。
  /// 语义是「只推送（append-only 安全）」，不拉取。开关没开、没设口令时空操作。
  void scheduleUpload() {
    if (!_enabled || _passphrase.isEmpty) return;
    _debounce?.cancel();
    _debounce = Timer(uploadDebounce, () {
      _debounce = null;
      // 失败只改状态文案，绝不打扰聊天
      pushOnly();
    });
  }

  /// 立即补推一次（App 退到后台时调）。条件不满足就静默跳过。
  void pushNowIfEnabled() {
    if (!_enabled || _passphrase.isEmpty || _busy) return;
    _debounce?.cancel();
    _debounce = null;
    pushOnly();
  }

  // ——— 状态与文案 ———

  void _setStatus(SyncStatus s, String? error) {
    _status = s;
    lastError = error;
    notifyListeners();
  }

  /// 把存储层的 StorageError 翻成人话。网络类错误统一口径。
  String _storageMessage(StorageError e, String prefix) {
    final code = (e.code ?? '').toUpperCase();
    final raw = (e.message ?? '').trim().toLowerCase();
    if (code.contains('TIMEOUT') ||
        code.contains('UNREACHABLE') ||
        raw.contains('timeout')) {
      return '连不上云端，请检查网络';
    }
    if (code.contains('FORBIDDEN') ||
        code.contains('PERMISSION') ||
        e.status == 403) {
      return '云端拒绝了这次操作（权限问题），请联系主理人检查桶策略';
    }
    if (raw.isEmpty) return '$prefix：云端返回错误（$code）';
    return '$prefix：$raw';
  }

  String _anyMessage(Object e, String prefix) {
    final raw = e.toString().toLowerCase();
    if (raw.contains('timeout') ||
        raw.contains('socket') ||
        raw.contains('connection') ||
        raw.contains('网络')) {
      return '连不上云端，请检查网络';
    }
    return '$prefix，请稍后重试';
  }
}

/// 本地待推送记录的一次性导出结果。
class _LocalExport {
  final Map<String, dynamic> companion;
  final Map<String, dynamic> speechProfile;

  /// 她的说话方式档案（整对象一条，key 固定 stp:v1）。
  final Map<String, dynamic> styleProfile;
  final List<Map<String, dynamic>> notes;
  final List<Map<String, dynamic>> styleExamples;
  final List<Map<String, dynamic>> memoryChunks;
  final List<Map<String, dynamic>> messages;

  const _LocalExport({
    required this.companion,
    required this.speechProfile,
    required this.styleProfile,
    required this.notes,
    required this.styleExamples,
    required this.memoryChunks,
    required this.messages,
  });
}

/// App 生命周期观察者：退到后台立刻补推一次云备份（只推送，append-only 安全）。
///
/// 单独放在这里而不是让 AppState 实现 WidgetsBindingObserver——
/// AppState 是 ChangeNotifier，不该变成 Widget 层的东西。
/// 在 main() 里 `WidgetsBinding.instance.addObserver(CloudSyncLifecycleObserver())`。
class CloudSyncLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      CloudSync.instance.pushNowIfEnabled();
    }
  }
}
