import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/services/cloud_reader.dart';
import 'package:peiban_app/services/proactive_pool_store.dart';

/// 记忆型假对象通道：路径 → 正文。写失败可用 [failOnWrite] 打开。
class FakeObjectClient implements ProactiveObjectClient {
  final Map<String, String> objects = <String, String>{};
  final bool failOnWrite;
  final bool throwOnWrite;

  FakeObjectClient({this.failOnWrite = false, this.throwOnWrite = false});

  @override
  Future<String?> readObject(String path) async => objects[path];

  @override
  Future<PoolWriteResult> writeObject(String path, String body) async {
    if (throwOnWrite) throw StateError('通道炸了');
    if (failOnWrite) return PoolWriteResult.failed('模拟写失败');
    objects[path] = body;
    return const PoolWriteResult.success();
  }
}

class _ExplodeOnRead implements ProactiveObjectClient {
  @override
  Future<String?> readObject(String path) async => throw StateError('读炸了');

  @override
  Future<PoolWriteResult> writeObject(String path, String body) async =>
      PoolWriteResult.failed('读侧不写');
}

void main() {
  group('T06 候选句池（ProactivePoolStore）', () {
    test('key = sha16(text.trim())，内容即身份；同文同 key，差一字符不同 key', () {
      final a = PoolItem.fromText('今天有点想你');
      final b = PoolItem.fromText('  今天有点想你  ');
      final c = PoolItem.fromText('今天有点想你！');
      expect(a.key, b.key); // trim 后同一句
      expect(a.key.length, 16);
      expect(a.key, isNot(c.key));
      // 黄金值钉死拼法：sha256(utf8('今天有点想你')) 前 16 位
      expect(
        poolSha16('今天有点想你'),
        sha256.convert(utf8.encode('今天有点想你')).toString().substring(0, 16),
      );
    });

    test('对象往返：encode → decode 原样回来，schema 写进载体', () {
      const pool = ProactivePool(
        dayKey: '20261201',
        items: [
          PoolItem(key: 'k1', text: '在忙吗', createdAt: 100),
          PoolItem(key: 'k2', text: '下班了吗', createdAt: 200),
        ],
      );
      final round = ProactivePool.decode(pool.encode());
      expect(round.dayKey, '20261201');
      expect(round.items.length, 2);
      expect(round.items[0].text, '在忙吗');
      expect(round.items[1].createdAt, 200);
      expect(pool.encode().contains('"schema":1'), isTrue);
    });

    test('坏数据不抛：空串 / 坏 JSON / 未知 schema / journal JSONL → 空池', () {
      const journalLine =
          '{"v":1,"type":"message","key":"m:x","ts":1,"dev":"app","data":{}}\n'
          '{"v":1,"type":"note","key":"n:y","ts":2,"dev":"app","data":{}}\n';
      for (final raw in <String>['', '   ', '不是json', '[]', journalLine]) {
        expect(ProactivePool.decode(raw).items, isEmpty, reason: '输入：$raw');
      }
      final unknownSchema =
          ProactivePool.decode('{"schema":99,"dayKey":"20261201","items":[]}');
      expect(unknownSchema.items, isEmpty);
    });

    test('read：对象不存在 / 通道抛异常 / sub 为空 → 一律空池，不抛', () async {
      final missing =
          CosObjectPoolStore(client: FakeObjectClient(), sub: 'sub-a');
      expect((await missing.read('20261201')).items, isEmpty);

      final bomb = CosObjectPoolStore(client: _ExplodeOnRead(), sub: 'sub-a');
      expect((await bomb.read('20261201')).items, isEmpty);

      final noSub = CosObjectPoolStore(client: FakeObjectClient(), sub: '');
      expect((await noSub.read('20261201')).items, isEmpty);
    });

    test('write 永不抛：通道失败 / 通道抛异常 / 超 8KB → 都返回 failed，不留半截', () async {
      final fail = CosObjectPoolStore(
        client: FakeObjectClient(failOnWrite: true),
        sub: 'sub-a',
      );
      final r1 = await fail.write(
          '20261201', const ProactivePool(dayKey: '20261201', items: []));
      expect(r1.ok, isFalse);
      expect(r1.reason, contains('模拟写失败'));

      final bomb = CosObjectPoolStore(
        client: FakeObjectClient(throwOnWrite: true),
        sub: 'sub-a',
      );
      final r2 = await bomb.write(
          '20261201', const ProactivePool(dayKey: '20261201', items: []));
      expect(r2.ok, isFalse);
      expect(r2.reason, contains('写候选句池失败'));

      // 8KB 上限：塞 400 条长句必然超限，且超限时不调用通道
      final client = FakeObjectClient();
      final big = CosObjectPoolStore(client: client, sub: 'sub-a');
      final huge = ProactivePool(
        dayKey: '20261201',
        items: [
          for (int i = 0; i < 400; i++)
            PoolItem(key: 'k$i', text: '这是一条用来撑爆体积的候选句' * 20),
        ],
      );
      expect(huge.encodedBytes(), greaterThan(kPoolMaxBytes));
      final r3 = await big.write('20261201', huge);
      expect(r3.ok, isFalse);
      expect(r3.reason, contains('8KB'));
      expect(client.objects, isEmpty); // 通道根本没被碰
    });

    test('write 成功落在 memories/<sub>/proactive-<dayKey>.json 路径上', () async {
      final client = FakeObjectClient();
      final store = CosObjectPoolStore(client: client, sub: 'sub-a');
      final r = await store.write(
        '20261201',
        const ProactivePool(dayKey: '20261201', items: []),
      );
      expect(r.ok, isTrue);
      expect(
          client.objects.containsKey('sub-a/proactive-20261201.json'), isTrue);
      expect(poolObjectPathFor('sub-a', '20261201'),
          'sub-a/proactive-20261201.json');
      expect(poolObjectPathFor('', '20261201'), '');
    });

    test('CloudReader.loadPool：读独立对象；喂 journal 内容返回空池（正确行为）', () async {
      final client = FakeObjectClient();
      // ① 同一天写进两个"载体"：候选句池对象 + journal 文本（历史载体）
      client.objects['sub-a/proactive-20261201.json'] = ProactivePool(
        dayKey: '20261201',
        items: [PoolItem.fromText('中午吃什么呀', createdAt: 1)],
      ).encode();
      client.objects['sub-a/journal.jsonl'] =
          '{"v":1,"type":"message","key":"m:x","ts":1,"dev":"app","data":{}}\n';

      final store = CosObjectPoolStore(client: client, sub: 'sub-a');
      final reader = CloudReader(store: store);

      final pool = await reader.loadPool('20261201');
      expect(pool.items.length, 1);
      expect(pool.items.first.text, '中午吃什么呀');

      // ② CloudReader 只走候选句池路径：journal 路径不被读、journal 内容喂进
      //    池解析口径就是空池。
      expect(client.objects.containsKey('sub-a/journal.jsonl'), isTrue);
      expect(
          ProactivePool.decode(client.objects['sub-a/journal.jsonl']!).items,
          isEmpty);
    });
  });
}
