import 'package:flutter_test/flutter_test.dart';
import 'package:peiban_app/models/setup_form.dart';
import 'package:peiban_app/services/persona_builder.dart';

void main() {
  test('没填 API Key 时，本地模板也能拼出可用的人设和开场白', () {
    final form = SetupForm()
      ..name = '阿雾'
      ..callUser = '阿澈'
      ..relationship = '恋人'
      ..traits = ['温柔', '粘人'];

    final draft = PersonaBuilder.localFallback(form);

    expect(draft.fromModel, isFalse);
    expect(draft.persona.contains('阿雾'), isTrue);
    expect(draft.persona.contains('阿澈'), isTrue);
    expect(draft.greeting.isNotEmpty, isTrue);
  });

  test('表单摊成纯文字时，空字段有兜底文案', () {
    final plain = SetupForm().toPlainText();
    expect(plain.contains('名字：'), isTrue);
    expect(plain.contains('未填，你按常识补一个合适的'), isTrue);
  });
}
