import 'dart:async';
import 'dart:convert';

import 'package:cloudbase_flutter/cloudbase_flutter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db_helper.dart';
import '../data/prefs.dart';
import '../models/journal.dart';

// R10 共用口径：与 peiban-core/src/r10.mjs 逐字一致。
// 改动任何一个函数都要同步改 Node 端并跑对拍测试，否则手机和电脑
// 会派生出两个身份、读到两本不同的库。

/// 云同步状态。
///
/// - off：开关没开（用户自己关的，不算故障）
/// - noPassphrase：开了但还没设置同步口令（或还没完成过一次同步）
/// - syncing：一次对齐/推送/拉取正在进行
/// - synced：最近一次对齐/推送/拉取成功
/// - dirMismatch：云端没读到数据、但本机有可重建历史（口令可能不对 / 版本过旧）
/// - error：最近一次失败，[CloudSync.lastError] 有中文文案
enum SyncStatus { off, noPassphrase, syncing, synced, dirMismatch, error }

/// 一次读取的三态。
///
/// 服务端实测：「对象真不存在」与「被 RLS 拒绝」返回逐字节同形的 404
/// （118 bytes / STORAGE_OBJECT_NOT_FOUND）——它故意如此，否则平台自己
/// 就是存在性 oracle。所以这里绝不叫 notFound / notExists / denied，
/// 只叫 missing：**服务端说没拿到，分不清是真没有还是没权限**。
enum CloudReadState { ok, missing, error }

/// 三态叠加「本机可重建历史」后的动作。
enum CloudOutcome {
  /// 读到了，正常继续
  ready,
  /// missing + 本机有历史：不初始化、不写回、不把本机数据当待上传
  blocked,
  /// missing + 本机无历史：可以建新库
  newLibrary,
  /// 网络 / 鉴权 / 其它异常
  error,
}

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
/// 追加日志：`memories/<匿名身份 sub>/journal.jsonl`，
/// 协议见 [JournalLine]（lib/models/journal.dart，三方共用）。
///
/// **R10（方案 A：身份即目录）**：桶权限在 PG RLS，一条过宽的
/// `memories_bucket_all` 曾把匿名身份对整桶敞开。修法是服务端只放行
/// `foldername(name)[1] = auth.uid()` 的目录，客户端把身份本身变成口令的
/// 确定性函数（`deviceId = sha256('peiban-dev-v1:'+口令)[:32]`），
/// 于是「口令 → deviceId → sub → 目录前缀」，门槛由服务端执行。
/// **目录只是路径，不是权限**；不许把这套写法解释成"路径随机所以安全"。
///
/// 只读只写 `<sub>` 前缀，**没有旧前缀回退**：收紧策略后旧前缀不在任何
/// uid 名下，回退是死代码；放行旧前缀等于洞没关。旧数据由迁移脚本
/// `peiban-core/tool/migrate-r10.mjs` 在关洞前 copy 到 `<sub>`。
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

  /// 旧口径的口令哈希盐（**只供迁移脚本 / 历史对照**，客户端不再用它寻址）。
  static const String _passphraseSalt = 'peiban-sync-v1:';

  /// R10 设备指纹派生盐。与 Node 端 `src/r10.mjs` 的 DEVICE_SALT 逐字一致。
  static const String _deviceSalt = 'peiban-dev-v1:';

  /// deviceId 取 sha256 hex 前 32 位（128 bit），与 SDK 的 uuid-v4 去横线同形。
  static const int deviceIdHexLength = 32;

  /// cloudbase_flutter 1.3.0 内部 x-device-id 的 prefs 键（cloudbase.dart:28）。
  /// SDK 没开放注入口，只能在 init 之前先写这个键。升级 SDK 必须回来核对。
  static const String _sdkDeviceIdKey = 'device_id';

  /// SDK 会话的 prefs 键：'credentials_$env'（cloudbase.dart:103）。
  /// 换身份时必须清掉，否则 getSession 会把旧 sub 的会话当有效会话复用。
  static String get _sdkSessionKey => 'credentials_$envId';

  /// 云母库文件名。
  static const String journalFileName = 'journal.jsonl';

  /// 本次发布的最小支持版本（按构建号数值比较，不比较版本名字符串）。
  static const String minSupportedVersion = '1.7.4';
  static const int minSupportedVersionCode = 20;

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

  /// 最近一次读的三态与动作判定（测试可直接断言，不许只塞进日志）。
  CloudReadState? _readState;
  CloudOutcome? _outcome;
  CloudReadState? get readState => _readState;
  CloudOutcome? get outcome => _outcome;
  bool get dirMismatch => _outcome == CloudOutcome.blocked;

  String get uid => _uid;
  int get lastSyncAt => _lastSyncAt;
  bool get enabled => _enabled;
  bool get hasPassphrase => _passphrase.isNotEmpty;
  bool get signedIn => _uid.isNotEmpty;
  bool get isBusy => _busy;

  /// 最近一次失败的中文文案（给设置页直接显示）。
  String? lastError;

  int _localBuildNumber = 0;

  /// 口令 → deviceId：sha256('peiban-dev-v1:' + 口令) 的前 32 位小写十六进制。
  ///
  /// **纯函数、现算、不落盘、无兜底**：同一口令在任意机器 / 任意时间 /
  /// 任意安装目录都得到同一个身份。口令为空返回空串，调用方必须走
  /// 「未启用云同步」分支，绝不能用盐本身算出一个合法身份。
  static String deviceIdFor(String passphrase) {
    if (passphrase.trim().isEmpty) return '';
    final hex = sha256.convert(utf8.encode('$_deviceSalt$passphrase')).toString();
    return hex.substring(0, deviceIdHexLength);
  }

  /// 旧口径目录名：sha256('peiban-sync-v1:' + 口令) 的 64 位小写十六进制。
  /// **仅供迁移脚本与历史对照**，客户端寻址绝不再用它。
  static String snapshotDirFor(String passphrase) =>
      sha256.convert(utf8.encode('$_passphraseSalt$passphrase')).toString();

  /// 新前缀 = 匿名登录返回的 sub。客户端只读只写这一层。
  static String dirFor(String sub) => sub.trim();

  /// 云母库完整路径：`<sub>/journal.jsonl`。未登录时返回空串。
  String get journalPath =>
      _uid.isEmpty ? '' : '${dirFor(_uid)}/$journalFileName';

  /// 三态 + 本机可重建历史 → 动作（纯函数，与 Node classifyRead 一致）。
  ///
  /// [hasLocalHistory] 必须是可重建证据（本地 journal 行数>0 或 lastSyncAt>0），
  /// 不许用一次性布尔标记。判定绝不向服务端查询"目录是否存在"。
  static CloudOutcome classifyRead({
    required CloudReadState state,
    required bool hasLocalHistory,
  }) {
    if (state == CloudReadState.error) return CloudOutcome.error;
    if (state == CloudReadState.ok) return CloudOutcome.ready;
    return hasLocalHistory ? CloudOutcome.blocked : CloudOutcome.newLibrary;
  }

  /// MISSING 时对用户说的话。两个分支允许同一句，差别在动作：
  /// blocked 不建库、不写回；newLibrary 才建库。最后半句必须在。
  static String cloudEmptyMessage() =>
      '云端的记忆目录变了。可能是 App 版本过旧，也可能是口令不同。'
      '本机记忆完好，没有被改动。';

  /// 老版本专用：明确升级，且不走新库初始化。
  static String upgradeRequiredMessage() =>
      '云端的记忆库已升级到新的存储规则，当前 App 版本过旧，请升级到 '
      '$minSupportedVersion 或更高版本。本机记忆完好，没有被改动。';

  /// 版本名按数值逐段比较，绝不用字符串直接比（1.7.10 会被排到 1.7.9 前面）。
  static List<int> versionParts(String versionName) {
    final m = RegExp(r'^(\d+(?:\.\d+){0,3})').firstMatch(versionName.trim());
    if (m == null) return const <int>[0];
    return m.group(1)!.split('.').map((s) => int.parse(s)).toList();
  }

  static int compareVersionName(String a, String b) {
    final x = versionParts(a);
    final y = versionParts(b);
    final n = x.length > y.length ? x.length : y.length;
    for (var i = 0; i < n; i++) {
      final xi = i < x.length ? x[i] : 0;
      final yi = i < y.length ? y[i] : 0;
      if (xi != yi) return xi < yi ? -1 : 1;
    }
    return 0;
  }

  /// '1.7.3' → true，'1.7.4' / '1.7.10' → false。
  static bool isOldVersionName(String versionName) =>
      compareVersionName(versionName, minSupportedVersion) < 0;

  /// 构建号比较：19 → true，20 → false。
  static bool isOldBuildNumber(int buildNumber) =>
      buildNumber < minSupportedVersionCode;

  /// 是否老客户端。优先用版本名，缺失时用构建号。
  static bool isOldClient({String versionName = '', int buildNumber = 0}) =>
      versionName.trim().isNotEmpty
          ? isOldVersionName(versionName)
          : isOldBuildNumber(buildNumber);

  // ——— 初始化 ———

  /// 把「口令派生的 deviceId」写进 SDK 的 prefs 再 init。
  ///
  /// cloudbase_flutter 1.3.0 的 `CloudBase.init()` 会读 prefs 的 `device_id`，
  /// 没有就随机生成一个 UUID 并持久化——那正是 S6 禁止的"一次读取失败 =
  /// 永久新身份"。所以必须在 init 之前把现算的身份写进去。
  ///
  /// 返回 false 表示不该进云路径（口令为空），调用方一律静默返回，
  /// 不生成任何随机身份、不落盘。
  Future<bool> _prepareIdentity() async {
    if (_passphrase.isEmpty) return false;
    final want = deviceIdFor(_passphrase);
    if (want.isEmpty) return false;
    try {
      final sp = await SharedPreferences.getInstance();
      final current = sp.getString(_sdkDeviceIdKey) ?? '';
      if (current != want) {
        // 身份变了（首次升级到 R10，或用户改了口令）：
        // 旧会话属于旧 sub，必须清掉，否则 getSession 会把旧 sub 一路复用。
        await sp.remove(_sdkSessionKey);
        await sp.setString(_sdkDeviceIdKey, want);
        _app = null;
        _uid = '';
        _readState = null;
        _outcome = null;
        assert(() {
          debugPrint('[cloud_sync] identity switched: dev=${want.substring(0, 8)}…');
          return true;
        }());
      }
      return true;
    } catch (e) {
      assert(() {
        debugPrint('[cloud_sync] identity prepare failed: ${e.runtimeType}');
        return true;
      }());
      return false;
    }
  }

  /// 懒初始化 CloudBase。失败只记录，绝不抛——同步是锦上添花，不能崩主流程。
  Future<CloudBase?> _ensureApp() async {
    if (!await _prepareIdentity()) return null;
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
        debugPrint('[cloud_sync] init failed: ${e.runtimeType}');
        return true;
      }());
      return null;
    }
  }

  /// 读取本机 App 构建号（数值）。失败返回 0，由版本名兜底。
  Future<int> _localBuildNumberOrZero() async {
    if (_localBuildNumber > 0) return _localBuildNumber;
    try {
      final info = await PackageInfo.fromPlatform();
      _localBuildNumber = int.tryParse(info.buildNumber.trim()) ?? 0;
    } catch (_) {
      _localBuildNumber = 0;
    }
    return _localBuildNumber;
  }

  /// 本机是否有可重建历史（PRD S5④）：本地 journal 行数 > 0 或 lastSyncAt>0。
  /// 不用一次性布尔标记——标记会丢、会和真实数据不一致，数据本身不会。
  Future<bool> hasLocalHistory() async {
    if (_lastSyncAt > 0) return true;
    try {
      final c = await DbHelper.instance.firstCompanion();
      if (c?.id == null) return false;
      final int id = c!.id!;
      if (await DbHelper.instance.messageCount(id) > 0) return true;
      if ((await DbHelper.instance.userNotes()).isNotEmpty) return true;
      if ((await DbHelper.instance.memoryChunks(id)).isNotEmpty) return true;
      if ((await DbHelper.instance.exportAllStyleExamples(id)).isNotEmpty) {
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 换机出口：用户明确说「我在旧手机上有记录」时调用。
  /// 只在本机记一个"这次允许按新库初始化"的确认（用派生的 deviceId 做标记，
  /// 不写口令明文），**不向服务端查询任何目录是否存在**。
  Future<void> acknowledgeNewLibrary() async {
    final key = deviceIdFor(_passphrase);
    if (key.isEmpty) return;
    await Prefs.setCloudLibraryAck(key);
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

    // 改口令 = 换身份 = 新目录，是用户在这里显式选择的，等价于一次
    // 「允许按新库初始化」确认；否则会被 MISSING + 本机历史的门禁挡住。
    if (changed) await acknowledgeNewLibrary();

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

  /// 判断一段错误文本是否为「登录态过期」类错误（token 过期需换新会话重试）。
  ///
  /// 纯静态、可测。匹配 cloudbase 网关的几类口径：
  /// - 错误码 `ACCESS_TOKEN_EXPIRED`（`access_token_expired`）；
  /// - SDK 原文「access token has expired. for more information, ...」；
  /// - 「token expired」（网关换措辞时的兜底口径）。
  /// 一律小写化后 contains 匹配，调用方传进来的文案无论什么大小写、
  /// 带不带中文前缀（如「对齐失败：...」）都能命中。
  static bool isTokenExpiredText(String raw) {
    final s = raw.toLowerCase();
    return s.contains('access_token_expired') ||
        s.contains('token has expired') ||
        s.contains('token expired');
  }

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
      // 覆盖上传空 journal（全协议唯一的整文件覆盖点）。PG 存储路径没有 SDK
      // 的 token 刷新重试拦截，撞上过期 token 时换新会话重试一次（与
      // _runLocked 的自愈同一套口径）
      var emptyErr = await _uploadEmptyJournal(app);
      if (emptyErr != null &&
          isTokenExpiredText(emptyErr) &&
          await _recoverSession(app)) {
        emptyErr = await _uploadEmptyJournal(app);
      }
      if (emptyErr != null) {
        // 上传失败：云端保持原样，一个字节都没动
        _setStatus(SyncStatus.error, emptyErr);
        return AlignResult(ok: false, message: '$emptyErr（云端保持原样）');
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

  /// 覆盖上传空 journal（销毁的覆盖点）。成功返回 null；失败返回中文错误
  /// 文案（[CloudSync.isTokenExpiredText] 可对其判别是否登录态过期）。
  /// 抽成独立方法：token 过期自愈要「失败 → 换会话 → 原样再传一次」，
  /// 不抽的话重试逻辑得把 StorageError / 异常两条失败路径各抄一遍。
  Future<String?> _uploadEmptyJournal(CloudBase app) async {
    try {
      final bucket = app.storage.fromBucket(bucketId);
      // 空覆盖是全协议唯一允许整份覆盖的地方，但也绝不能在
      // 「MISSING + 本机有历史」时执行——那正是"空库 → 覆盖"的毁数据路径。
      final pre = await bucket.download(journalPath);
      if (pre.error != null) {
        final code = (pre.error!.code ?? '').toUpperCase();
        final status = pre.error!.status ?? 0;
        final missing = code.contains('NOT_FOUND') ||
            status == 404 ||
            code.contains('NO_SUCH');
        if (!missing) return _storageMessage(pre.error!, '销毁失败');
        _readState = CloudReadState.missing;
        final preOutcome = classifyRead(
          state: CloudReadState.missing,
          hasLocalHistory: await hasLocalHistory(),
        );
        _outcome = preOutcome;
        if (preOutcome == CloudOutcome.blocked) return cloudEmptyMessage();
      } else {
        _readState = CloudReadState.ok;
        _outcome = CloudOutcome.ready;
      }
      final up = await bucket.upload(
        journalPath,
        utf8.encode(''),
        options: PgStorageUploadOptions(
          contentType: 'application/jsonl',
          upsert: true,
        ),
      );
      if (up.error != null) return _storageMessage(up.error!, '销毁失败');
      return null;
    } catch (e) {
      return _anyMessage(e, '销毁失败');
    }
  }

  /// 对齐算法的公共实现（App 端 align()；Agent 端未来同款）：
  ///
  /// 1. 下载 `<sub>/journal.jsonl` → 解析有效行 + key 集合（坏行跳过）；
  ///    404 = MISSING（分不清真没有还是没权限），有本机历史就 BLOCKED 停下
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

  /// 对齐/拉取入口（薄壳）：先跑一次 [_runLockedOnce]；失败文案命中
  /// [isTokenExpiredText] 时，换新会话后**重试一次**，返回第二次结果。
  ///
  /// 为什么在这里修：cloudbase_flutter 的「token 过期 → 刷新 → 重试」拦截
  /// 只挂在 auth/callFunction 路径，PG 云存储走裸 HTTP 直连，过期后
  /// StorageError 原样冒出（用户看到的就是「对齐失败：access token has
  /// expired」）。ensureSignedIn 只看 SDK 有没有持久化会话、不校验 token
  /// 有效性，所以过期会话会被一路复用。修法是在 App 层识别过期文案，
  /// signOut 清掉持久化会话后重新匿名登录——新会话即可用（journal 目录
  /// 按口令哈希寻址，与 uid 无关）。
  ///
  /// 只重试一次：避免网络抖动 + 会话异常组合成无限循环。
  Future<AlignResult> _runLocked(
    CloudBase app, {
    required bool doPush,
    required bool doPull,
    required String verb,
  }) async {
    final first = await _runLockedOnce(
      app,
      doPush: doPush,
      doPull: doPull,
      verb: verb,
    );
    if (first.ok || !isTokenExpiredText(first.message)) return first;
    // token 过期：换新会话。恢复失败（网络等）就不重试了，如实返回第一次结果
    if (!await _recoverSession(app)) return first;
    return _runLockedOnce(
      app,
      doPush: doPush,
      doPull: doPull,
      verb: verb,
    );
  }

  /// 登录态过期后的会话恢复：signOut 清掉 SDK 持久化的旧会话（token 已过期，
  /// 留着只会被 ensureSignedIn 复用），再匿名登录拿一个新会话。
  ///
  /// signOut 的任何异常都忽略——目标只是「清空本地会话」，网络失败也要继续
  /// 尝试重新登录。
  Future<bool> _recoverSession(CloudBase app) async {
    // 不要拿 uid 判断「是否真的换了新会话」：CloudBase 匿名登录按 x-device-id
    // 去重（device_id 持久化在 SDK prefs，signOut 只清 currentSession 不清它），
    // 重新匿名登录拿到的是新 access_token + 同一个 uid。uid 比对会恒为 false，
    // 把自愈整个关死（这段代码曾经就这么死过一次，测试还是全绿的）。
    // 这里只信 signOut 的契约：auth.dart 的 signOut 无条件把 currentSession
    // 置 null（revoke 失败也置），所以紧接着的 ensureSignedIn 必然走新登录。
    // 重试严格有界（一次），最坏情况只是白发一次请求。
    try {
      await app.auth.signOut();
    } catch (_) {
      // 清会话失败也继续：下一步 ensureSignedIn 会给出最终结论
    }
    _uid = '';
    return await ensureSignedIn();
  }

  /// 对齐/拉取核心（调用方必须已持 `_busy` 锁；本方法不管锁、不管门禁）。
  ///
  /// destroyCloud 的「空覆盖 → 重推」全程共用同一把锁，中间防抖 pushOnly
  /// 插不进来——不会出现「销毁刚完成、旧数据被并发写回复活」的竞态。
  ///
  /// token 过期自愈在 [_runLocked] 薄壳里做（换新会话重试一次），本方法
  /// 内部逻辑一行不动。
  ///
  /// 1. 下载 `<sub>/journal.jsonl` → 解析有效行 + key 集合（坏行跳过）；
  ///    404 = MISSING（分不清真没有还是没权限），有本机历史就 BLOCKED 停下
  /// 2. 推送：导出本地全部记录，逐条算 key；key 不在云端 key 集合的 → 生成追加行
  /// 3. 写回：「下载的原文 + 追加行」按原行顺序合并（追加行在后面）重新上传。
  ///    云端已有的行原样保留，一行不删不改。3 和 4 之间若上传失败，下次对齐
  ///    仍会因 key 缺失自动重推（幂等、自愈）
  /// 4. 拉取：云端记录走 restoreCloudData 式补缺（内容级去重、坏行净化、
  ///    本地为主；人设本地有则忽略；speechProfile / styleProfile 本地有才不采用）
  /// 5. 更新 lastSyncAt，返回对齐结果（推送 N 条 / 拉取 M 条）
  Future<AlignResult> _runLockedOnce(
    CloudBase app, {
    required bool doPush,
    required bool doPull,
    required String verb,
  }) async {
    _setStatus(SyncStatus.syncing, null);
    try {
      final bucket = app.storage.fromBucket(bucketId);

      // ——— 1. 下载云母库 ———
      // 只读 `<sub>` 前缀：没有旧前缀回退（收紧策略后旧前缀不在任何 uid 名下）。
      // 404 是 MISSING（服务端说没拿到，分不清真没有还是没权限），
      // **不是空库**：有本机历史就必须停下来，不许写回、不许初始化。
      var raw = '';
      var cloudMissing = false;
      final down = await bucket.download(journalPath);
      final CloudReadState readState;
      if (down.error != null) {
        final code = (down.error!.code ?? '').toUpperCase();
        final status = down.error!.status ?? 0;
        final missing = code.contains('NOT_FOUND') ||
            status == 404 ||
            code.contains('NO_SUCH');
        if (!missing) {
          readState = CloudReadState.error;
          _readState = readState;
          _outcome = CloudOutcome.error;
          final msg = _storageMessage(down.error!, '$verb失败');
          _setStatus(SyncStatus.error, msg);
          return AlignResult(ok: false, message: msg);
        }
        readState = CloudReadState.missing;
      } else {
        readState = CloudReadState.ok;
        raw = utf8.decode(down.data ?? <int>[]);
      }
      _readState = readState;

      var outcome = classifyRead(
        state: readState,
        hasLocalHistory: readState == CloudReadState.missing
            ? await hasLocalHistory()
            : false,
      );
      if (readState == CloudReadState.missing) {
        // 换机出口：只在用户明确点过「我在旧手机上有记录」时放行一次。
        // 不查服务端、不猜目录、不写口令明文。
        final ack = await Prefs.cloudLibraryAck();
        if (outcome == CloudOutcome.blocked &&
            ack.isNotEmpty &&
            ack == deviceIdFor(_passphrase)) {
          await Prefs.clearCloudLibraryAck();
          outcome = CloudOutcome.newLibrary;
        }
        // 版本门禁：构建号小于最小支持版本时一律请升级，绝不走新库初始化。
        final build = await _localBuildNumberOrZero();
        if (build > 0 &&
            isOldBuildNumber(build) &&
            outcome == CloudOutcome.newLibrary) {
          final msg = upgradeRequiredMessage();
          _outcome = CloudOutcome.blocked;
          _setStatus(SyncStatus.dirMismatch, msg);
          return AlignResult(ok: false, message: msg);
        }
        if (outcome == CloudOutcome.blocked) {
          final msg = cloudEmptyMessage();
          _outcome = CloudOutcome.blocked;
          _setStatus(SyncStatus.dirMismatch, msg);
          return AlignResult(ok: false, message: msg);
        }
        cloudMissing = true;
      }
      _outcome = outcome;
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
    // MISSING + 无本机历史才可能走到这里（有历史已经在读取段 BLOCKED 返回）。
    // 文案两种分支允许相同，差别在"有没有发出建库请求"这个动作。
    final note = cloudMissing
        ? '${cloudEmptyMessage()}（本次按新库处理；如不是你要的库请核对口令。）'
        : '';
    if (verb == '对齐') {
      if (pushed == 0 && pulled == 0) return '$note对齐完成：云端和本地已经一致';
      return '$note对齐完成：上传 $pushed 条，拉取 $pulled 条';
    }
    if (verb == '上传') {
      if (pushed == 0) return '$note云端记忆已是最新';
      return '$note已推送 $pushed 条到云端';
    }
    // 恢复
    if (cloudMissing && pulled == 0) {
      return '$note这次没有从云端读到记忆，本机记录未被改动。';
    }
    if (pulled == 0) return '云端没有这台设备缺的记录，本地已经是全的';
    return '$note已从云端补齐 $pulled 条';
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
    // 401 必须放在所有分支之前：网关有时用 401 + 空 body 回过期，body 没有
    // message 时 dio 兜底文案是「Http status error [401]」，里面没有 token
    // 字面量，不在这里翻成可判别口径的话自愈会静默失效。也不许落进 403 的
    // 「权限问题」（网关偶尔用 403 表过期同样会被挡）。文案不写「正在自动
    // 重试」：自动重试成功时用户根本看不到这条，只有重试也失败才显示，
    // 中性措辞两种情形都成立（本项目规矩：文案必须如实，不许自作多情）。
    if (e.status == 401) {
      return '$prefix：登录态已过期（access_token_expired），请再点一次对齐';
    }
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
    // token 过期原文必须原样保留（'$prefix：$raw' 口径）：_runLocked 靠
    // result.message 里的这段文本来判断「要不要换会话重试」，包成
    // 「请稍后重试」会让自愈永远触发不了。恢复失败（重试也不成）时用户
    // 会看到这条，所以先给人话、异常英文原文放括号里兜底。
    if (isTokenExpiredText(raw)) {
      return '$prefix：登录态已过期，请再点一次对齐（${e.toString()}）';
    }
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
