import '../models/journal.dart';
import '../models/user_note.dart';

/// Prompt 预算纯函数（设计 §6.1 / §6.2，PRD B3 / D3 / L3）。
///
/// 只做"选哪些行、够不够预算"的判定，**不拼 prompt、不改人设、不读云端**。
/// T04（三层视图）与 T05（导出/诊断）按这里的契约接，别各自写裁剪。
///
/// 硬口径（不许自行放宽）：
/// - `maxSelfChars = 360` **含标题行**，是 PRD 定稿值（400 会破 D3 的 110%）；
/// - notes 总数 20，**近况优先占位但不能把总数撑成 25**；
/// - 摘要 3000 字、原文 60 条 / 12000 字不变；
/// - D3 的 110% 不放宽，超线优先砍 chunks，绝不砍 persona / self。
class PromptBudget {
  const PromptBudget._();

  /// 【我知道我是谁】段硬上限，含标题行（PRD B3）。
  static const int maxSelfChars = 360;

  /// notes 注入上限（不变）。
  static const int maxNotes = 20;

  /// 近况 note 在 20 条里的优先占位上限（不新增预算）。
  static const int maxNearTermNotes = 5;

  /// 每条 note 的 content 截断长度（设计 §6.2 的零信息损失压缩）。
  static const int maxNoteContentChars = 60;

  /// 摘要层 / 原文层预算（不变）。
  static const int maxChunkChars = 3000;
  static const int maxTurns = 60;
  static const int maxTurnChars = 12000;

  /// D3：组装后 system prompt 不超过改动前的 110%。
  static const double maxPromptRatio = 1.10;

  /// 近况 category 的约定值（与 R4 中期层一致）。
  static const String nearTermCategory = '近况';

  /// 选 notes：**排序责任在本函数内部**（设计 §6.1，v1.4.1 裁决）。
  ///
  /// 规则固定（调用方不许预排序、不许依赖传入顺序——乱序是合法输入）：
  /// ① 全量按 `createdAt` **降序**稳定排序，`createdAt` 相同按 note 的 journal key
  ///    字典序**升序**兜底（保证两端 / 多调用方逐字一致）；
  /// ② 从排好序的列表里取 `category=近况` 的前 ≤[nearTermMax] 条占位；
  /// ③ 其它 category 按**同一降序**补足到 [max]（默认 20）；
  /// ③' 只有其它 category 不够补满时才让多出来的近况回填（极端兜底）；
  /// ④ 返回总数 **≤max**。
  ///
  /// 为什么排序必须收进函数内部：三个调用方各传一种序 ⇒ 同一份 journal 生成三种
  /// prompt，D3/B3 的 golden 断言失去可比性；更隐蔽的是近况段可能被普通 note 挤出
  /// 20 条预算，「近况优先」变成看调用心情。
  static List<UserNote> pickNotes(
    List<UserNote> notes, {
    int max = maxNotes,
    int nearTermMax = maxNearTermNotes,
  }) {
    if (max <= 0) return const <UserNote>[];
    final limitNear = nearTermMax < 0 ? 0 : nearTermMax;

    // ① 全量稳定排序：createdAt 降序；同 ts 按 journal key 字典序升序兜底。
    final sorted = <UserNote>[...notes];
    sorted.sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt); // 降序
      if (byTime != 0) return byTime;
      final ka = journalKeyForNote(a.category, a.content);
      final kb = journalKeyForNote(b.category, b.content);
      return ka.compareTo(kb); // 升序兜底
    });

    // ② 近况前 ≤limitNear 条进「占位名单」；其它类目进补位池；超出占位的近况
    //    单独放一边——它们**不许直接挤占**剩下的槽位（那是给长期事实的）。
    final near = <UserNote>[];
    final others = <UserNote>[];
    final overflowNear = <UserNote>[];
    for (final n in sorted) {
      if (n.category != nearTermCategory) {
        others.add(n);
      } else if (near.length < limitNear) {
        near.add(n);
      } else {
        overflowNear.add(n);
      }
    }

    // ③ 近况先占位，其它类目按同一降序补足到 max。
    final out = <UserNote>[...near];
    for (final n in others) {
      if (out.length >= max) break;
      out.add(n);
    }

    // ③' 兜底：其它类目不够补满（极端情况：手上的 note 全是近况）才让多出来的
    //     近况回填，绝不把 20 条预算空着不用。正常情况走不到这里。
    for (final n in overflowNear) {
      if (out.length >= max) break;
      out.add(n);
    }

    // ④ 总数 ≤max。
    if (out.length > max) return out.sublist(0, max);
    return List<UserNote>.unmodifiable(out);
  }

  /// D3 判定：[prompt] 的 UTF-16 长度是否 ≤ [baseline] * [ratio]。
  ///
  /// 用 `.length` 与 PRD 的 golden 文本口径一致（Dart / JS 都按 UTF-16 计）。
  /// 非法 baseline（<=0）或 ratio（<=0）一律 false，不许静默当成通过。
  static bool withinBaseline(
    String prompt,
    int baseline, {
    double ratio = maxPromptRatio,
  }) {
    if (baseline <= 0 || ratio <= 0) return false;
    return prompt.length <= baseline * ratio;
  }

  /// self 段是否超 B3 硬上限（含标题行）。空串合法。
  static bool selfWithinBudget(String section) =>
      section.length <= maxSelfChars;
}
