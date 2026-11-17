// 探针：验证云母库（journal.jsonl）追加日志协议在真实云端的全链路。
// ignore_for_file: invalid_use_of_visible_for_testing_member
//
// 注意：不能用 `dart run` 跑这个文件——cloudbase_flutter 依赖 Flutter 插件
//（package:flutter + shared_preferences），纯 Dart VM 加载不了。
// 运行方式（与项目其他测试一致，先 unset 代理）：
//   flutter test tool/test_cloudbase.dart
//
// 云端已配好：anonymous=true，memories 桶 RLS 对 authenticated/anon 全量读写
// ——路径本身即凭证。目录名 = sha256('peiban-sync-v1:' + 口令) 的 64 位小写 hex。
// 对象路径 = <目录>/journal.jsonl（UTF-8 JSONL，每行一个 JSON 对象）。
//
// 六步（全部实跑真实云端）：
//   1. init → 匿名登录
//   2. 首次上传 journal：3 行不同 type/key 的行
//   3. 下载比对：行数一致、内容一致
//   4. 追加写：下载原文件 → 追加 2 行新 key → 上传 → 再下载验证
//      5 行全在、原有 3 行未被改动（追加不覆盖语义）
//   5. 幂等验证：用相同 key 再走一遍追加合并 → 下载验证仍 5 行、无重复 key
//   6. 每步打印真实结果
import 'dart:convert';

import 'package:cloudbase_flutter/cloudbase_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/models/journal.dart';
import 'package:peiban_app/services/cloud_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kEnvId = 'naughty-beaver-d7gdchzub18ffae94';
const String kRegion = 'ap-shanghai';
const String kAccessKey =
    'eyJhbGciOiJSUzI1NiIsImtpZCI6IjVkNDQ5ZDUzLTAzODMtNDg4My05MzQ4LWRjNDM0YmZjMDcwYyJ9.eyJpc3MiOiJodHRwczovL25hdWdodHktYmVhdmVyLWQ3Z2RjaHp1YjE4ZmZhZTk0LmFwLXNoYW5naGFpLnRjYi1hcGkudGVuY2VudGNsb3VkYXBpLmNvbSIsInN1YiI6ImFub24iLCJhdWQiOiJuYXVnaHR5LWJlYXZlci1kN2dkY2h6dWIxOGZmYWU5NCIsImV4cCI6NDA5ODU3NzE3MSwiaWF0IjoxNzk0ODkzOTcxLCJub25jZSI6ImdRSVp4emFyVDM2djV0alRoYjZsSmciLCJhdF9oYXNoIjoiZ1FJWnh6YXJUMzZ2NXRqVGhiNmxKZyIsIm5hbWUiOiJBbm9ueW1vdXMiLCJzY29wZSI6ImFub255bW91cyIsInByb2plY3RfaWQiOiJuYXVnaHR5LWJlYXZlci1kN2dkY2h6dWIxOGZmYWU5NCIsIm1ldGEiOnsicGxhdGZvcm0iOiJQdWJsaXNoYWJsZUtleSJ9LCJyb2xlIjoiYW5vbiIsImlzX2Fub255bW91cyI6dHJ1ZSwiYXBwX21ldGFkYXRhIjp7InByb3ZpZGVyIjoiYW5vbnltb3VzIiwicHJvdmlkZXJzIjpbImFub255bW91cyJdfSwidXNlcl9tZXRhZGF0YSI6eyJuYW1lIjoiQW5vbnltb3VzIn0sInVzZXJfdHlwZSI6IiIsImNsaWVudF90eXBlIjoiY2xpZW50X3VzZXIiLCJpc19zeXN0ZW1fYWRtaW4iOmZhbHNlfQ.FgEUYKyhguzB56FbC0ok3IsQBYTG3zHEX6gcNoxyT6kkkVIgMYRNVI6Nv3uYMiAa_ebuosEXFMMbxvibFRQDux-wfyI0f_TG94QeJMvQHhlr396BjmV9juT5YRBnHTcOSiXSMIR-tGOWR82tniPvlG39xvDfDMlFnNLawOZo52t3a0tEPp6DSAhg434fbUxBjlONg70A-qkgqem5H4loOK33fqXJJMuIc630n0kGfLQ2-7LfZZfJe7SOknqjAjgNkuN2jOnVa3VDmkBL6UQX9U0uy8wIzHl3UOnP5ZAiWvfSq_IMV_CyzIm1d__mKVhy25yaS6f0VlL-AsfyoTpmw';
// 探针专用口令（与 App 代码里同一套哈希推导，验证的就是真实路径）
const String kProbePassphrase = 'probe-passphrase-12345';
const String kBucket = 'memories';

void log(Object? msg) => print('[probe] $msg');

/// 构造探针用的初始 3 行（不同 type/key）。
List<String> seedLines() => [
      buildJournalLine(
        type: JournalLine.typeMessage,
        key: journalKeyForMessage('user', 1700000001000),
        ts: 1700000001000,
        data: const {'role': 'user', 'content': '在干嘛', 'created_at': 1700000001000},
      ),
      buildJournalLine(
        type: JournalLine.typeNote,
        key: journalKeyForNote('生活习惯', '周末睡到中午'),
        ts: 1700000002000,
        data: const {
          'category': '生活习惯',
          'content': '周末睡到中午',
          'confidence': 0.8,
          'evidence': '说过两次',
          'created_at': 1700000002000,
        },
      ),
      buildJournalLine(
        type: JournalLine.typePersona,
        key: journalKeyPersona,
        ts: 1700000003000,
        data: const {'name': '阿雾', 'persona': '你是阿雾……', 'created_at': 1700000003000},
      ),
    ];

/// 追加用的 3 行（新 key / 新类型，与初始 3 行不重）。
List<JournalLine> appendLines() => [
      JournalLine(
        type: JournalLine.typeStyleExample,
        key: journalKeyForStyleExample('在忙哦，有什么事吗？', '刚画完画，你呢'),
        ts: 1700000004000,
        data: const {
          'trigger_text': '在干嘛',
          'original': '在忙哦，有什么事吗？',
          'preferred': '刚画完画，你呢',
          'created_at': 1700000004000,
        },
      ),
      JournalLine(
        type: JournalLine.typeMemoryChunk,
        key: journalKeyForMemoryChunk(1, 50, '聊了搬家的事'),
        ts: 1700000005000,
        data: const {
          'from_id': 1,
          'to_id': 50,
          'summary': '聊了搬家的事',
          'created_at': 1700000005000,
        },
      ),
      // 她的说话方式档案：整对象一条（key 固定 stp:v1），验证新类型真实云端往返
      JournalLine(
        type: JournalLine.typeStyleProfile,
        key: journalKeyStyleProfile,
        ts: 1700000006000,
        data: const {
          'digested': 12,
          'updated_at': 1700000006000,
          'tone': '随性偏糙，像熟人',
          'catchphrases': <String>['哈？'],
          'taboos': '不连发长段',
        },
      ),
    ];

Future<String> downloadJournal(CloudBase app, String path) async {
  final down = await app.storage.fromBucket(kBucket).download(path);
  if (down.error != null) {
    final code = (down.error!.code ?? '').toUpperCase();
    final status = down.error!.status ?? 0;
    final missing =
        code.contains('NOT_FOUND') || status == 404 || code.contains('NO_SUCH');
    if (missing) return '';
    fail('下载失败: code=${down.error!.code} status=$status '
        'msg=${down.error!.message}');
  }
  return utf8.decode(down.data ?? <int>[]);
}

Future<void> uploadJournal(CloudBase app, String path, String text) async {
  final up = await app.storage.fromBucket(kBucket).upload(
        path,
        utf8.encode(text),
        options: PgStorageUploadOptions(
          contentType: 'application/jsonl',
          upsert: true,
        ),
      );
  if (up.error != null) {
    fail('上传失败: code=${up.error!.code} status=${up.error!.status} '
        'msg=${up.error!.message}');
  }
}

/// 探针版的「追加合并」：和 App 端 align() 的推送段同一套规则——
/// 云端已有的 key 一律跳过，新 key 才追加；原文一行不动。
String appendMerge(String rawCloudText, List<JournalLine> appended) {
  final existingKeys =
      parseJournalLines(rawCloudText).map((l) => l.key).toSet();
  final fresh =
      appended.where((l) => !existingKeys.contains(l.key)).toList();
  return mergeJournal(rawCloudText, fresh);
}

void main() {
  setUpAll(() {
    // CloudBase.init 内部用 SharedPreferences 持久化会话，测试环境给个内存实现
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('云母库 journal.jsonl 六步探针（真实云端）', () async {
    log('— 1. init + 匿名登录 —');
    final app = await CloudBase.init(
      env: kEnvId,
      region: kRegion,
      accessKey: kAccessKey,
    );
    log('init 完成，baseUrl=${app.config.baseUrl}');
    final anon = await app.auth.signInAnonymously();
    if (anon.error != null) {
      fail('匿名登录失败: code=${anon.error!.code} status=${anon.error!.status} '
          'msg=${anon.error!.message}');
    }
    final uid = anon.data?.user?.id ?? '';
    log('匿名登录成功: uid=$uid');

    final dir = CloudSync.snapshotDirFor(kProbePassphrase);
    final path = '$dir/journal.jsonl';
    log('口令目录: $dir');
    log('对象路径: $path');

    final seeds = seedLines();

    // ——— 2. 首次上传 journal：3 行不同 type/key ———
    log('— 2. 首次上传 journal（3 行：message / note / persona）—');
    // 种子就是完整行文本，直接拼成 journal 文件
    final firstFile = '${seeds.join('\n')}\n';
    await uploadJournal(app, path, firstFile);
    log('首次上传成功：${seeds.length} 行');

    // ——— 3. 下载比对：行数一致、内容一致 ———
    log('— 3. 下载比对 —');
    final back3 = await downloadJournal(app, path);
    final lines3 = parseJournalLines(back3);
    log('下载回来 ${lines3.length} 行有效记录');
    expect(lines3.length, 3, reason: '首次上传后应有 3 行有效记录');
    for (var i = 0; i < seeds.length; i++) {
      final want = seeds[i];
      final got = lines3[i].encode();
      expect(got, want, reason: '第 ${i + 1} 行往返后应与原文一致');
    }
    log('行数与逐行内容比对一致 ✅');

    // ——— 4. 追加写：下载 → 追加 3 行新 key → 上传 → 再下载 ———
    log('— 4. 追加写（3 行新 key，含 style_profile 新类型）—');
    final rawBefore = back3;
    final appended = appendLines();
    final merged = appendMerge(rawBefore, appended);
    expect(merged.split('\n').where((l) => l.trim().isNotEmpty).length, 6,
        reason: '合并后应是 6 行');
    await uploadJournal(app, path, merged);
    final back5 = await downloadJournal(app, path);
    final lines5 = parseJournalLines(back5);
    log('追加后下载 ${lines5.length} 行');
    expect(lines5.length, 6, reason: '追加后应有 6 行全在');
    // 原有 3 行未被改动：追加后文件的前 3 行必须与追加前完全一致（字节级）
    final back5Lines =
        back5.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final rawBeforeLines =
        rawBefore.split('\n').where((l) => l.trim().isNotEmpty).toList();
    for (var i = 0; i < rawBeforeLines.length; i++) {
      expect(back5Lines[i], rawBeforeLines[i],
          reason: '原有第 ${i + 1} 行必须原样保留（追加不覆盖）');
    }
    // 追加的 2 行新 key 都在
    final keys5 = lines5.map((l) => l.key).toSet();
    expect(keys5.containsAll(appended.map((a) => a.key)), isTrue,
        reason: '追加的 2 行新 key 必须都在云端');
    log('6 行全在，原有 3 行逐字节未被改动 ✅（追加不覆盖语义成立）');

    // ——— 5. 幂等验证：相同 key 再走一遍追加合并 ———
    log('— 5. 幂等验证（相同 key 重复追加）—');
    final merged2 = appendMerge(back5, appended);
    expect(merged2, back5, reason: '相同 key 再追加合并，结果应与原文完全一致');
    await uploadJournal(app, path, merged2);
    final backFinal = await downloadJournal(app, path);
    final linesFinal = parseJournalLines(backFinal);
    final uniqueKeys = linesFinal.map((l) => l.key).toSet();
    log('重复追加后下载 ${linesFinal.length} 行，去重 key 数 ${uniqueKeys.length}');
    expect(linesFinal.length, 6, reason: '重复追加后仍应只有 6 行');
    expect(uniqueKeys.length, linesFinal.length, reason: '不应出现重复 key');
    // style_profile 整对象行的内容往返校验
    final stp = linesFinal
        .firstWhere((l) => l.type == JournalLine.typeStyleProfile);
    expect(stp.key, journalKeyStyleProfile);
    expect(stp.data['digested'], 12);
    expect(stp.data['taboos'], '不连发长段');
    log('仍 6 行、无重复 key、style_profile 往返一致 ✅（幂等 + 自愈基础成立）');

    // ——— 6. 销毁语义：空 journal 覆盖上传 → 下载验证为空（全协议唯一覆盖点）———
    log('— 6. 销毁语义（空 journal 整文件覆盖）—');
    await uploadJournal(app, path, '');
    final backEmpty = await downloadJournal(app, path);
    final linesEmpty = parseJournalLines(backEmpty);
    log('覆盖上传空文件后下载：原始字节 ${backEmpty.length}，有效记录 ${linesEmpty.length} 行');
    expect(backEmpty.trim(), isEmpty, reason: '销毁 = 空 journal 覆盖，下载应为空文本');
    expect(linesEmpty, isEmpty, reason: '销毁后云母库应为空库');
    log('云端已为空 ✅（销毁覆盖语义成立；下次对齐会按 key 缺失重新追加本地记忆）');

    log('— 探针全部通过 —');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
