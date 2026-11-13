/// 「角色设定页」三步表单里填的全部内容。
/// 纯数据，不依赖 Flutter，方便单独改。
class SetupForm {
  // 第一步：TA 是谁
  String name = '';
  String appellation = ''; // 称谓 / 性别感
  String ageFeel = '';
  String identity = '';
  String appearance = ''; // 只写进人设文字，不再拿去生图
  List<String> traits = [];
  String speakingStyle = '';
  String avatarPath = ''; // 用户自己上传的参考图

  // 第二步：你们的关系
  String callUser = ''; // TA 怎么称呼你
  String relationship = '';
  String backstory = '';
  double initiative = 1; // 希望 TA 多主动，1~3

  // 第三步：边界
  String avoidTopics = '';
  String extra = '';

  /// 把表单摊成一段纯文字，交给 DeepSeek 润色成人设。
  String toPlainText() {
    final b = StringBuffer();
    void put(String label, String value, [String fallback = '未填，你按常识补一个合适的']) {
      b.writeln('$label：${value.trim().isEmpty ? fallback : value.trim()}');
    }

    put('名字', name, '你起一个贴合设定的名字');
    put('称谓 / 性别感', appellation);
    put('年龄感', ageFeel);
    put('身份 / 职业', identity);
    put('外貌气质', appearance);
    b.writeln('性格标签：${traits.isEmpty ? '温柔、耐心、有点粘人' : traits.join('、')}');
    put('说话风格', speakingStyle, '口语化、短句、像发微信');
    b.writeln('---');
    put('TA 怎么称呼用户', callUser, '你');
    put('两人的关系', relationship, '很亲近的人');
    put('初见场景 / 共同经历', backstory, '认识有一阵子了，彼此很熟');
    b.writeln('主动程度（1~3，越大越主动）：${initiative.round()}');
    b.writeln('---');
    put('不希望聊的话题', avoidTopics, '没有特别避讳的');
    put('其他补充', extra, '无');
    return b.toString();
  }
}
