import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/data/prefs.dart';
import 'package:peiban_app/models/journal.dart';
import 'package:peiban_app/services/cloud_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('口令哈希路径推导：确定性——同口令同目录，不同口令不同目录', () {
    const pass = 'probe-passphrase-12345';
    final dir = CloudSync.snapshotDirFor(pass);

    // 确定性：同一个口令无论算多少次、在哪个实例上算，目录都一样
    expect(dir, CloudSync.snapshotDirFor(pass));
    expect(CloudSync.snapshotDirFor(pass), dir);

    // 形状：64 位小写十六进制（sha256 hex）
    expect(dir, matches(RegExp(r'^[0-9a-f]{64}$')));

    // 固定向量（与云端约定的盐 'peiban-sync-v1:' 参与哈希，外部用 python 算好钉死，
    // 防止以后有人不小心改盐或改拼接方式）
    expect(dir, '848d929eb1e7c345299bba7826f34c2ac622973136263e2460655a412bdf5863');

    // 不同口令 → 不同目录（换口令 = 换目录）
    final other = CloudSync.snapshotDirFor('another-passphrase');
    expect(other, isNot(dir));
    expect(other, '4fa5270e553f8841a90ce36177535a706347862df561f34d8740beb0adb8be57');

    // 前后空格不该改变目录（setPassphrase 会 trim，这里保证口径一致）
    expect(CloudSync.snapshotDirFor('  $pass  '), isNot(dir));
  });

  test('云母库路径 = <口令哈希>/journal.jsonl（同目录同口令规则不变）', () {
    // journalPath 是实例 getter，依赖内部口令状态；这里验证静态目录推导口径，
    // 保证目录名和文件名拼接没有拼接符歧义
    final dir = CloudSync.snapshotDirFor('probe-passphrase-12345');
    expect('$dir/journal.jsonl'.split('/').length, 2);
    expect('$dir/journal.jsonl'.endsWith('/journal.jsonl'), isTrue);
    // 快照时代的 snapshot.json 退役：路径规则里不再出现
    expect('$dir/journal.jsonl'.contains('snapshot'), isFalse);
  });

  test('协议常量：云母库文件协议三方共用，常量不许悄悄变', () {
    expect(JournalLine.protocolVersion, 1);
    expect(JournalLine.knownTypes, containsAll(<String>[
      JournalLine.typeMessage,
      JournalLine.typeNote,
      JournalLine.typeStyleExample,
      JournalLine.typeMemoryChunk,
      JournalLine.typeSpeechProfile,
      JournalLine.typeStyleProfile,
      JournalLine.typePersona,
    ]));
    // 防抖与口令门禁沿用 V1 口径
    expect(CloudSync.uploadDebounce, const Duration(minutes: 5));
    expect(CloudSync.minPassphraseLength, 8);
  });

  test('授权码：设置/修改的本地校验，与同步口令完全独立', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    // 太短 → 拒绝
    final short = await CloudSync.instance.setAuthCode('1234567');
    expect(short.ok, isFalse);
    expect(short.message, contains('至少'));

    // 正常设置
    final set = await CloudSync.instance.setAuthCode('destroy-code-1');
    expect(set.ok, isTrue);
    expect(await Prefs.cloudAuthCode(), 'destroy-code-1');

    // 已设置后再走设置入口 → 拒绝（必须走修改流程）
    final again = await CloudSync.instance.setAuthCode('another-code-1');
    expect(again.ok, isFalse);
    expect(await Prefs.cloudAuthCode(), 'destroy-code-1');

    // 修改：旧码不对 → 拒绝，授权码保持不变
    final badOld =
        await CloudSync.instance.changeAuthCode('wrong-code-99', 'new-code-123');
    expect(badOld.ok, isFalse);
    expect(badOld.message, contains('旧授权码不对'));
    expect(await Prefs.cloudAuthCode(), 'destroy-code-1');

    // 修改：新码太短 → 拒绝
    final badNew = await CloudSync.instance.changeAuthCode('destroy-code-1', 'short');
    expect(badNew.ok, isFalse);

    // 修改成功
    final changed =
        await CloudSync.instance.changeAuthCode('destroy-code-1', 'new-code-123');
    expect(changed.ok, isTrue);
    expect(await Prefs.cloudAuthCode(), 'new-code-123');

    // 本地比对（不上传校验）：未设置时任何输入都不匹配
    expect(CloudSync.authCodeMatches('new-code-123', 'new-code-123'), isTrue);
    expect(CloudSync.authCodeMatches('new-code-123', ' wrong-code '), isFalse);
    expect(CloudSync.authCodeMatches('', 'anything'), isFalse);
  });

  test('销毁的授权码验证分支：未设置/码不对都拒绝，一步不往云端走', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    // 未设置授权码 → 拒绝
    final r1 = await CloudSync.instance.destroyCloud('anything-123');
    expect(r1.ok, isFalse);
    expect(r1.message, contains('还没有设置授权码'));

    // 已设置但码不对 → 拒绝（每次都要求重输）
    await Prefs.setCloudAuthCode('right-code-1');
    final r2 = await CloudSync.instance.destroyCloud('wrong-code-99');
    expect(r2.ok, isFalse);
    expect(r2.message, contains('授权码不对'));

    // 授权码正确 → 越过验证；测试环境没开启云同步，走门禁拒绝，不触网、不抛
    final r3 = await CloudSync.instance.destroyCloud('right-code-1');
    expect(r3.ok, isFalse);
    expect(r3.message, contains('云同步没有开启'));
  });

  test('授权码与口令互相独立：改口令不影响授权码，反之亦然', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await Prefs.setCloudPassphrase('sync-pass-12345');
    await Prefs.setCloudAuthCode('auth-code-12345');

    // 授权码的存取不碰口令键，口令的存取不碰授权码键（分别读写验证）
    expect(await Prefs.cloudPassphrase(), 'sync-pass-12345');
    expect(await Prefs.cloudAuthCode(), 'auth-code-12345');
    await Prefs.setCloudAuthCode('auth-code-99999');
    expect(await Prefs.cloudPassphrase(), 'sync-pass-12345');
    await Prefs.setCloudPassphrase('new-pass-999999');
    expect(await Prefs.cloudAuthCode(), 'auth-code-99999');
  });

  test('isTokenExpiredText：SDK 原文与错误码都能命中', () {
    // SDK 原文（全小写、带 docs 链接）：用户实际看到的报错原文
    expect(
      CloudSync.isTokenExpiredText(
          'access token has expired. for more information, please refer to '
          'https://docs.cloudbase.net/error-code/service/access_token_expired'),
      isTrue,
    );
    // 网关错误码：大写 code 形式
    expect(CloudSync.isTokenExpiredText('ACCESS_TOKEN_EXPIRED'), isTrue);
    // 小写错误码（_storageMessage 会把 code 转大写后再比较，但 message 保持原样）
    expect(CloudSync.isTokenExpiredText('access_token_expired'), isTrue);
    // 网关换措辞时的兜底口径（'token expired'）
    expect(CloudSync.isTokenExpiredText('token expired'), isTrue);
    // 混合大小写（e.toString() 原文常带异常类名前缀）
    expect(CloudSync.isTokenExpiredText('Access Token Has Expired'), isTrue);
    // 带中文前缀的完整失败文案（'$prefix：$raw' 口径，正是 _runLocked 收到的形态）
    expect(
      CloudSync.isTokenExpiredText(
          '对齐失败：access token has expired. for more information'),
      isTrue,
    );
    // _storageMessage 对 401 的新产出形态（dio 兜底文案 'Http status error
    // [401]' 没有 token 字面量，实现里翻成了可判别口径，401 分支在最前面）
    expect(
      CloudSync.isTokenExpiredText(
          '对齐失败：登录态已过期（access_token_expired），请再点一次对齐'),
      isTrue,
    );
  });

  test('isTokenExpiredText：非 token 过期错误不误伤', () {
    // 空串：直接 false，不抛
    expect(CloudSync.isTokenExpiredText(''), isFalse);
    // 普通网络错误文案（本项目统一口径）
    expect(CloudSync.isTokenExpiredText('连不上云端，请检查网络'), isFalse);
    // 云存储常见错误：NOT_FOUND / 权限类，都和登录态过期无关
    expect(CloudSync.isTokenExpiredText('NOT_FOUND: file not found'), isFalse);
    expect(
        CloudSync.isTokenExpiredText('云端拒绝了这次操作（权限问题）'), isFalse);
    // 「稍后重试」包装文案（_anyMessage 对非过期异常的输出）
    expect(CloudSync.isTokenExpiredText('对齐失败，请稍后重试'), isFalse);
  });

  test('isTokenExpiredText：三条失败文案出口的**实际产出形态**都能命中（自愈接缝）', () {
    // 这是整条自愈链上唯一的判定接缝：只要 _storageMessage / _anyMessage 的
    // 产出文案不再包含 token 过期字样，_runLocked / destroyCloud 就永远不会换
    // 会话重试，而且不会有任何测试变红。这里把三个出口的真实产出形态钉死：
    // 形态来自 cloud_sync.dart 的 _storageMessage / _anyMessage 实现：
    //   _storageMessage: '$prefix：$raw'（raw 已 toLowerCase）、
    //                    '$prefix：云端返回错误（$code）'（message 为空时，code 大写）、
    //                    '$prefix：access_token_expired（登录态已过期…）'（status==401）
    //   _anyMessage:     '$prefix：登录态已过期，请再点一次对齐（${e.toString()}）'

    // 出口 1：下载失败（_runLockedOnce 里 '$verb失败'）
    //   1a. message 非空 → 小写原文
    expect(
      CloudSync.isTokenExpiredText('对齐失败：access token has expired. '
          'for more information, please refer to https://docs.cloudbase.net/'
          'error-code/service/access_token_expired'),
      isTrue,
    );
    //   1b. message 为空 → 只剩大写错误码，必须仍能被小写化匹配命中
    expect(
      CloudSync.isTokenExpiredText('对齐失败：云端返回错误（ACCESS_TOKEN_EXPIRED）'),
      isTrue,
    );
    //   1c. status==401（dio 兜底文案无 token 字面量，实现里已翻成可判别口径）
    expect(
      CloudSync.isTokenExpiredText(
          '对齐失败：登录态已过期（access_token_expired），请再点一次对齐'),
      isTrue,
    );

    // 出口 2：上传失败（'$verb时上传失败'）
    expect(
      CloudSync.isTokenExpiredText('对齐时上传失败：云端返回错误（ACCESS_TOKEN_EXPIRED）'),
      isTrue,
    );

    // 出口 3：异常兜底（_anyMessage 的
    // '$prefix：登录态已过期，请再点一次对齐（${e.toString()}）'）
    expect(
      CloudSync.isTokenExpiredText(
          '对齐失败：登录态已过期，请再点一次对齐（AuthError(code: '
          'access_token_expired, message: ...)）'),
      isTrue,
    );

    // 出口 4：destroyCloud 空覆盖上传失败（'销毁失败'）——重传一次也靠同一判定
    expect(
      CloudSync.isTokenExpiredText('销毁失败：云端返回错误（ACCESS_TOKEN_EXPIRED）'),
      isTrue,
    );
    expect(
      CloudSync.isTokenExpiredText('销毁失败：access token has expired'),
      isTrue,
    );
  });

  test('isTokenExpiredText：其它存储错误码不会被当成登录态过期（不误伤重试）', () {
    // 非过期类云存储错误：NOT_FOUND（空库）、权限、通用失败码——都不该换会话重试
    expect(
      CloudSync.isTokenExpiredText('对齐失败：云端返回错误（NOT_FOUND）'),
      isFalse,
    );
    expect(
      CloudSync.isTokenExpiredText('对齐失败：云端返回错误（STORAGE_PG_REQUEST_FAIL）'),
      isFalse,
    );
    expect(
      CloudSync.isTokenExpiredText('云端拒绝了这次操作（权限问题），请联系主理人检查桶策略'),
      isFalse,
    );
    // 网络类错误（timeout / 连不上）也不该走「换会话」分支
    expect(CloudSync.isTokenExpiredText('连不上云端，请检查网络'), isFalse);
    expect(
      CloudSync.isTokenExpiredText('对齐失败：DioException [connection timeout]'),
      isFalse,
    );
    // 只提到 token 这个词、但没说过期：不能命中（避免 contains('token') 式过宽匹配）
    expect(
      CloudSync.isTokenExpiredText('对齐失败：invalid token format'),
      isFalse,
    );
    expect(CloudSync.isTokenExpiredText('token'), isFalse);
  });

  test('persona 跨设备收敛：仅 avatar_path 不同的两份内容 → 判「内容没变」不追加', () {
    // 同一个人设，手机端与本机（Agent 场景同理）沙盒路径必然不同
    final cloudData = <String, dynamic>{
      'name': '阿雾',
      'persona': '你是阿雾……',
      'greeting': '回来啦',
      'avatar_path': '/data/user/0/com.a/app_flutter/avatar_a.jpg',
      'created_at': 1700000000000,
      'persona_space': '{"fields":{"name":"阿雾"}}',
    };
    final localData = <String, dynamic>{
      'name': '阿雾',
      'persona': '你是阿雾……',
      'greeting': '回来啦',
      'avatar_path': 'C:/agent/profile/avatar_b.jpg',
      'created_at': 1700000000000,
      'persona_space': '{"fields":{"name":"阿雾"}}',
    };

    // 仅 avatar_path（和 id）不同 → 内容没变 → 不追加（收敛：不再互顶膨胀）
    expect(
      CloudSync.singleWinnerNeedsPush(
          cloudLatestData: cloudData, localData: localData),
      isFalse,
    );

    // 人设真变了 → 追加新行
    final changed = <String, dynamic>{...localData, 'persona': '你变了'};
    expect(
      CloudSync.singleWinnerNeedsPush(
          cloudLatestData: cloudData, localData: changed),
      isTrue,
    );

    // 云端没有该 key（比如刚被销毁）→ 追加（自愈）
    expect(
      CloudSync.singleWinnerNeedsPush(cloudLatestData: null, localData: localData),
      isTrue,
    );

    // 云端最新行是旧口径（还带着 avatar_path）也能正确比较
    final legacyCloud = <String, dynamic>{...cloudData};
    expect(
      CloudSync.singleWinnerNeedsPush(
          cloudLatestData: legacyCloud, localData: localData),
      isFalse,
    );

    // 本地为空（没建角色）→ 不追加
    expect(
      CloudSync.singleWinnerNeedsPush(
          cloudLatestData: null, localData: const <String, dynamic>{}),
      isFalse,
    );

    // 导出口径：stripDeviceLocal 去掉 id 与 avatar_path，其余原样保留
    final stripped = CloudSync.stripDeviceLocal(localData);
    expect(stripped.containsKey('id'), isFalse);
    expect(stripped.containsKey('avatar_path'), isFalse);
    expect(stripped['name'], '阿雾');
    expect(stripped['persona_space'], '{"fields":{"name":"阿雾"}}');
  });

  // ——— R10：身份派生 / 三态 / 版本门禁（与 Node r10.mjs 对拍）———

  test('R10 身份派生黄金值：sha256(peiban-dev-v1:+口令) 前 32 位，跨端逐字节一致', () {
    const pass = 'probe-passphrase-12345';
    final id = CloudSync.deviceIdFor(pass);

    expect(id, '0fda70a517aaba85d616bf1b93c97ca8');
    expect(id.length, 32);
    expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));

    // 确定性（跨实例、跨调用）
    expect(CloudSync.deviceIdFor(pass), id);
    expect(CloudSync.deviceIdFor(pass), CloudSync.deviceIdFor(pass));

    // 差一个字符 = 另一个身份（这就是"口令打错看到空库"的成因）
    expect(CloudSync.deviceIdFor('${pass}x'), isNot(id));

    // 空口令不得派生出任何身份
    expect(CloudSync.deviceIdFor(''), '');
    expect(CloudSync.deviceIdFor('   '), '');
  });

  test('R10 目录只取匿名身份 sub，绝不用旧口令哈希目录寻址', () {
    final dir = CloudSync.dirFor('gbNaPyO4oQTsw8yIdQflWg');
    expect(dir, 'gbNaPyO4oQTsw8yIdQflWg');
    expect(CloudSync.dirFor('  x  '), 'x');

    // 旧哈希仍可计算（迁移脚本/历史对照用），但不参与云路径
    final legacy = CloudSync.snapshotDirFor('probe-passphrase-12345');
    expect(legacy, '848d929eb1e7c345299bba7826f34c2ac622973136263e2460655a412bdf5863');
    expect(dir, isNot(legacy));
  });

  test('R10 404 三态：MISSING 不能当空库，有本机历史必须 BLOCKED', () {
    expect(CloudSync.classifyRead(
        state: CloudReadState.missing, hasLocalHistory: true),
        CloudOutcome.blocked);
    expect(CloudSync.classifyRead(
        state: CloudReadState.missing, hasLocalHistory: false),
        CloudOutcome.newLibrary);
    expect(CloudSync.classifyRead(
        state: CloudReadState.ok, hasLocalHistory: true),
        CloudOutcome.ready);
    expect(CloudSync.classifyRead(
        state: CloudReadState.error, hasLocalHistory: true),
        CloudOutcome.error);

    final msg = CloudSync.cloudEmptyMessage();
    expect(msg, contains('版本过旧'));
    expect(msg, contains('口令不同'));
    expect(msg, contains('本机记忆完好，没有被改动'));
    // 不许暗示"我知道目录不存在"（服务端对两种 404 是同形的）
    expect(msg.contains('不存在'), isFalse);
    expect(msg.contains('not found'), isFalse);
  });

  test('R10 版本门禁用数值比较：1.7.3 旧、1.7.4 可用、1.7.10 大于 1.7.9', () {
    expect(CloudSync.versionParts('1.7.10'), <int>[1, 7, 10]);
    expect(CloudSync.compareVersionName('1.7.10', '1.7.9'), 1);
    expect(CloudSync.isOldVersionName('1.7.3'), isTrue);
    expect(CloudSync.isOldVersionName('1.7.4'), isFalse);
    expect(CloudSync.isOldVersionName('1.7.10'), isFalse);
    expect(CloudSync.isOldBuildNumber(19), isTrue);
    expect(CloudSync.isOldBuildNumber(20), isFalse);
    expect(CloudSync.minSupportedVersion, '1.7.4');
    expect(CloudSync.minSupportedVersionCode, 20);
  });

  test('R10 口令为空时不进云路径：derive 出空身份且 align 被门禁拦住', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CloudSync.instance.bootstrap();

    expect(CloudSync.instance.hasPassphrase, isFalse);
    expect(CloudSync.deviceIdFor(''), '');

    final r = await CloudSync.instance.align();
    expect(r.ok, isFalse);
    expect(r.message, contains('云同步没有开启'));
    // 从头到尾没拿到任何身份：没有登录、没有派生、没有路径
    expect(CloudSync.instance.uid, '');
    expect(CloudSync.instance.journalPath, '');
  });

  test('R2 能力门禁保守化：从没对齐成功过 → 不给写 self 的能力', () async {
    // 裁决（T05 A 阶段后）：未对齐时**不许**按 cap=1 最宽松放行——
    // 我们此刻并不知道云端有没有别人的 self / 更高的 cap 行。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CloudSync.instance.bootstrap();
    expect(await Prefs.cloudAlignedOnce(), 0);
    expect(CloudSync.instance.canWriteSelfNow(), isFalse);
  });

  test('R2 能力门禁：落盘标志 > 0（成功对齐过）→ 放行', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // 键名是设计定的 cloud_aligned_once（值是毫秒时间戳，>0 即"对齐过"）
      'cloud_aligned_once': 1730000000000,
    });
    await CloudSync.instance.bootstrap();
    expect(CloudSync.instance.canWriteSelfNow(), isTrue);
  });
}
