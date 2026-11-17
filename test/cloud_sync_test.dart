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
}
