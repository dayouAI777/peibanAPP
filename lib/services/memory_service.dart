import '../data/db_helper.dart';
import '../models/memory_chunk.dart';
import 'deepseek.dart';

/// 旧对话压缩：把超出直发范围的历史按批交给 AI 压成摘要，缓存进本地库。
/// 每条只压一次，之后永久带着，不会重复花钱。
class MemoryService {
  MemoryService({DeepSeekService? llm}) : _llm = llm ?? DeepSeekService();
  final DeepSeekService _llm;

  /// 每批多少条消息压成一段摘要。
  static const int chunkSize = 50;

  /// 最近多少条保留为「原文直发区」，不参与压缩。
  static const int keepRaw = 60;

  /// 单批送进模型的最大字符数，防止极端长消息撑爆请求。
  static const int maxTranscriptChars = 9000;

  bool _running = false;

  Future<void> compressIfNeeded({
    required String apiKey,
    required int companionId,
  }) async {
    if (_running || apiKey.trim().isEmpty) return;
    _running = true;
    try {
      final all =
          await DbHelper.instance.messages(companionId, limit: 100000);
      if (all.length <= keepRaw) return;

      final existing = await DbHelper.instance.memoryChunks(companionId);
      final covered = <String>{
        for (final c in existing) '${c.fromMessageId}-${c.toMessageId}'
      };

      final compressEnd = all.length - keepRaw;
      for (int start = 0; start < compressEnd; start += chunkSize) {
        final end = start + chunkSize < compressEnd
            ? start + chunkSize
            : compressEnd;
        final batch = all.sublist(start, end);
        if (batch.isEmpty || batch.first.id == null || batch.last.id == null) {
          continue;
        }
        final key = '${batch.first.id}-${batch.last.id}';
        if (covered.contains(key)) continue;

        var transcript = batch
            .map((m) => '${m.fromUser ? '用户' : 'TA'}：${m.content}')
            .join('\n');
        if (transcript.length > maxTranscriptChars) {
          transcript = transcript.substring(0, maxTranscriptChars);
        }

        final summary = await _llm.summarize(
          apiKey: apiKey,
          transcript: transcript,
        );
        if (summary.trim().isEmpty) continue;

        await DbHelper.instance.insertChunk(MemoryChunk(
          companionId: companionId,
          fromMessageId: batch.first.id!,
          toMessageId: batch.last.id!,
          summary: summary.trim(),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    } catch (_) {
      // 压缩失败绝不影响聊天，下次会重试
    } finally {
      _running = false;
    }
  }
}
