import 'dart:convert';

import 'package:http/http.dart' as http;

/// 调用出错时抛这个，界面直接把 message 显示给用户，不堆术语。
class DeepSeekException implements Exception {
  final String message;
  DeepSeekException(this.message);

  @override
  String toString() => message;
}

/// DeepSeek 网络层（OpenAI 兼容格式）。换模型只改 endpoint / model 两行。
class DeepSeekService {
  static const String endpoint = 'https://api.deepseek.com/chat/completions';
  static const String model = 'deepseek-chat';

  Future<String> _complete({
    required String apiKey,
    required String system,
    required List<Map<String, String>> messages,
    double temperature = 1.25,
    int maxTokens = 500,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw DeepSeekException('还没填 API Key，先去配置页填一个');
    }

    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': system},
        ...messages,
      ],
      'temperature': temperature,
      'max_tokens': maxTokens,
      'stream': false,
    };

    late http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } catch (e) {
      throw DeepSeekException('连不上 DeepSeek，检查网络或 Key：$e');
    }

    // 用 bodyBytes 手动按 UTF-8 解，避免中文变乱码
    final raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode != 200) {
      throw DeepSeekException('DeepSeek 返回 ${resp.statusCode}：${_short(raw)}');
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final choices = decoded['choices'] as List<dynamic>;
      return (choices.first['message']['content'] as String).trim();
    } catch (e) {
      throw DeepSeekException('返回内容读不懂：${_short(raw)}');
    }
  }

  String _short(String s) => s.length > 180 ? '${s.substring(0, 180)}…' : s;

  String _stripFence(String s) {
    var t = s.trim();
    if (t.startsWith('```')) {
      final nl = t.indexOf('\n');
      if (nl != -1) t = t.substring(nl + 1);
      t = t.replaceAll(RegExp(r'```\s*$'), '').trim();
    }
    return t;
  }

  /// 配置页「测试链接」：真发一次最小请求，确认 Key 和链路都通。
  Future<bool> testConnection(String apiKey) async {
    await _complete(
      apiKey: apiKey,
      system: '你是连通性测试助手，无论用户说什么，只回复 ok，不要输出别的字。',
      messages: [
        {'role': 'user', 'content': 'ping'},
      ],
      temperature: 0,
      maxTokens: 8,
      timeout: const Duration(seconds: 20),
    );
    return true;
  }

  /// 让模型吐一个 JSON 对象（人设分析、行为抽取、摘要都走这里）。
  Future<Map<String, dynamic>> completeJson({
    required String apiKey,
    required String system,
    required String user,
    int maxTokens = 1400,
    double temperature = 0.5,
  }) async {
    final raw = await _complete(
      apiKey: apiKey,
      system: system,
      messages: [
        {'role': 'user', 'content': user},
      ],
      temperature: temperature,
      maxTokens: maxTokens,
    );
    return jsonDecode(_stripFence(raw)) as Map<String, dynamic>;
  }

  /// 普通聊天。system 是拼好的完整指令（人设 + 行为手册 + 旧事摘要）。
  Future<String> reply({
    required String apiKey,
    required String system,
    required List<Map<String, String>> history,
    required double temperature,
  }) async {
    return _complete(
      apiKey: apiKey,
      system: system,
      messages: history,
      temperature: temperature,
      maxTokens: 500,
    );
  }

  /// 角色主动开口。
  Future<String> proactiveLine({
    required String apiKey,
    required String system,
    required List<Map<String, String>> history,
  }) async {
    const extra = '''
【此刻的特殊要求】
现在是你主动找对方说话，不是回复。不要说「嗯」「我在」这种等着接话的短语，也不要问「有什么可以帮你的」。
像忽然想起一件小事那样自然开口：可以惦记一下对方、提起上次聊过的事、说一点你这边的小动静、或者只是轻轻问一句在干嘛。
1~2 句，短，有温度，别客套，别解释自己为什么突然发消息，不要括号动作。
''';
    final turns = <Map<String, String>>[
      ...history,
      {
        'role': 'user',
        'content': '（系统提示，不要照抄也不要提及：轮到你主动开口了）',
      },
    ];
    return _complete(
      apiKey: apiKey,
      system: '$system\n\n$extra',
      messages: turns,
      temperature: 1.35,
      maxTokens: 180,
    );
  }

  /// 把一段旧对话压成摘要。
  Future<String> summarize({
    required String apiKey,
    required String transcript,
  }) async {
    return _complete(
      apiKey: apiKey,
      system: '''
你是「长期记忆整理员」。把下面这段旧对话压缩成一段客观记忆，供另一个 AI 以后回忆用。
要求：
- 只写真实发生过的事实：谁说了什么、提到的人名地名、约定、反复出现的习惯、明确的喜好与情绪走向。
- 保留具体细节和原话关键词，不要笼统概括成「聊了一些日常」。
- 不编造、不评价、不写建议、不写「本次对话」这类元信息。
- 150 字以内，一段话，中文。
''',
      messages: [
        {'role': 'user', 'content': transcript},
      ],
      temperature: 0.2,
      maxTokens: 320,
    );
  }
}
