import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/setup_form.dart';
import 'persona_builder.dart';

/// 调用出错时抛这个，界面直接把 message 显示给用户，不堆术语。
class DeepSeekException implements Exception {
  final String message;
  DeepSeekException(this.message);

  @override
  String toString() => message;
}

/// DeepSeek 网络层。只做三件事：润色人设、普通聊天、生成主动消息。
/// 用的是 OpenAI 兼容格式，以后想换别家模型，改 endpoint / model 两行即可。
class DeepSeekService {
  static const String endpoint = 'https://api.deepseek.com/chat/completions';
  static const String model = 'deepseek-chat';

  Future<String> _complete({
    required String apiKey,
    required String system,
    required List<Map<String, String>> messages,
    double temperature = 1.25,
    int maxTokens = 400,
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw DeepSeekException('还没填 API Key，去「设置」里填一个就能聊了');
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
          .timeout(const Duration(seconds: 40));
    } catch (e) {
      throw DeepSeekException('连不上 DeepSeek，先看看网络：$e');
    }

    // 用 bodyBytes 手动按 UTF-8 解，避免中文变乱码
    final raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode != 200) {
      throw DeepSeekException('DeepSeek 返回 ${resp.statusCode}：${_short(raw)}');
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final choices = decoded['choices'] as List<dynamic>;
      final content = choices.first['message']['content'] as String;
      return content.trim();
    } catch (e) {
      throw DeepSeekException('返回内容读不懂：${_short(raw)}');
    }
  }

  String _short(String s) => s.length > 160 ? '${s.substring(0, 160)}…' : s;

  /// 生成角色。没填 Key / 断网 / 返回格式不对 → 一律退回本地模板，
  /// 这样「创建角色」这一步永远不会被卡住。
  Future<GeneratedPersona> buildPersona({
    required String apiKey,
    required SetupForm form,
  }) async {
    if (apiKey.trim().isEmpty) return PersonaBuilder.localFallback(form);
    try {
      final raw = await _complete(
        apiKey: apiKey,
        system: PersonaBuilder.editorSystem(),
        messages: [
          {'role': 'user', 'content': form.toPlainText()},
        ],
        temperature: 1.1,
        maxTokens: 900,
      );
      final cleaned = _stripFence(raw);
      final m = jsonDecode(cleaned) as Map<String, dynamic>;
      final persona = (m['persona'] as String?)?.trim() ?? '';
      final greeting = (m['greeting'] as String?)?.trim() ?? '';
      if (persona.length < 40 || greeting.isEmpty) {
        return PersonaBuilder.localFallback(form);
      }
      return GeneratedPersona(persona: persona, greeting: greeting);
    } catch (_) {
      return PersonaBuilder.localFallback(form);
    }
  }

  String _stripFence(String s) {
    var t = s.trim();
    if (t.startsWith('```')) {
      final nl = t.indexOf('\n');
      if (nl != -1) t = t.substring(nl + 1);
      t = t.replaceAll(RegExp(r'```\s*$'), '').trim();
    }
    return t;
  }

  /// 普通聊天。history 是最近若干条，按顺序 [{role, content}, ...]。
  Future<String> reply({
    required String apiKey,
    required String persona,
    required List<Map<String, String>> history,
    required double temperature,
  }) async {
    return _complete(
      apiKey: apiKey,
      system: persona,
      messages: history,
      temperature: temperature,
      maxTokens: 400,
    );
  }

  /// 角色主动开口。不是等用户说完再回，所以额外加一段「此刻要求」。
  Future<String> proactiveLine({
    required String apiKey,
    required String persona,
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
      system: '$persona\n\n$extra',
      messages: turns,
      temperature: 1.35,
      maxTokens: 180,
    );
  }
}
