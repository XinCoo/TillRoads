// 验证窗口与临期判定（本地优先架构 R2 · 任务 A）。
//
// ★ 这是 `server/verify_window.mjs` 的**逐行移植**，不是「重新实现」。
//   后端那一份的注释写得很清楚：窗口天数与 urgency 判定是业务规则，必须只有
//   一份定义。R2 之前「只有一份」是靠整个项目只有一个 Node 文件；R2 之后客户端
//   必须能离线算 urgency，于是有了第二份副本 —— 它的正确性完全依赖「与后端
//   逐字一致」，因此这里刻意保留同名常量、同名函数、同顺序的判定分支，
//   连「向下取整」和「<=0 判逾期」的写法都照抄，方便以后 diff。
//
// ★ 漂移风险（设计文档 §2.4 已标注）：若后端改了 `VERIFY_WINDOWS`，这份副本会
//   漂移，表现为「服务端说逾期、客户端说还剩 1 天」。缓解手段：
//     · 常量集中在本文件，改一处即可；
//     · `test/verify_window_test.dart` 用后端常量值做断言（7/14/21、临期阈值 3）；
//     · R3 的同步引擎拉到云端数据后，`urgency` 一律以**服务端返回的字段优先**
//       （列表/摘要接口都带 urgency），本地复算只用于「云端还没拉过」的投影数据。
//
// ★ 为什么不引入 intl/dayjs 之类的日期库：与后端同理，Date 的毫秒差足够，
//   而 R2 任务书硬约束「不引新依赖」。

import 'dart:convert';

/// 验证窗口（天）。值必须与 `server/verify_window.mjs` 的 `VERIFY_WINDOWS` 一致。
///
/// 取文档区间的**上限**作为宽松期限：V1「3–7 天」→ 7；V2「1–2 周」→ 14；
/// V3 模考文档未定时长 → 21（避免误判逾期）。
const Map<String, int> kVerifyWindows = <String, int>{
  'V1': 7,
  'V2': 14,
  'V3': 21,
};

/// 合法的验证阶段（顺序即状态机推进顺序）。
const List<String> kVerifyStages = <String>['V1', 'V2', 'V3'];

/// urgency 三态。与后端 `URGENCY` 同名同值。
abstract final class Urgency {
  static const String overdue = 'overdue';
  static const String dueSoon = 'due_soon';
  static const String normal = 'normal';

  /// 合法值集合（供筛选参数校验）。
  static const List<String> values = <String>[overdue, dueSoon, normal];
}

/// 剩余天数 ≤ 该值即为「临期」。与后端 `DUE_SOON_DAYS` 一致。
const int kDueSoonDays = 3;

/// 一天的毫秒数。
const int kDayMs = 24 * 60 * 60 * 1000;

/// 一次 urgency 计算的全部结果（对应后端 `computeUrgency` 的返回对象）。
///
/// 字段名与后端返回的 snake_case 一一对应（[wire] 可直接写进
/// `Map<String, Object?>` 充当本地投影的 `VerificationTask` 数据源）。
class UrgencyResult {
  const UrgencyResult({
    required this.urgency,
    required this.daysLeft,
    required this.overdueDays,
    required this.elapsedDays,
    required this.windowDays,
    required this.enteredAt,
    required this.dueAt,
  });

  /// `overdue` / `due_soon` / `normal`
  final String urgency;

  /// 剩余天数 = 窗口 − 已过天数；≤0 表示已逾期（0 = 今天到期）。
  final int daysLeft;

  /// 已逾期天数（未逾期为 0）。
  final int overdueDays;

  /// 已过天数（向下取整）。
  final int elapsedDays;

  /// 该 stage 的窗口天数。
  final int windowDays;

  /// 进入当前验证态的时刻（UTC ISO 8601），与后端 `enteredAt` 同格式。
  final String enteredAt;

  /// 到期时刻（`enteredAt + windowDays`），UTC ISO 8601。
  final String dueAt;

  bool get isOverdue => urgency == Urgency.overdue;

  /// 拼成后端响应同形的 map，方便本地投影直接喂给 `VerificationTask.fromJson`。
  Map<String, Object?> get wire => <String, Object?>{
    'urgency': urgency,
    'days_left': daysLeft,
    'overdue_days': overdueDays,
    'elapsed_days': elapsedDays,
    'window_days': windowDays,
    'entered_at': enteredAt,
    'due_at': dueAt,
  };

  @override
  String toString() =>
      'UrgencyResult($urgency, daysLeft=$daysLeft, elapsed=$elapsedDays, '
      'window=$windowDays)';
}

/// 取某 stage 的窗口天数。
///
/// 用 [`Map.containsKey`] 而不是直接索引：'constructor' / '__proto__' 之类的
/// 字符串在 JS 会命中原型链（后端注释记录过这个坑）；Dart 没有原型链问题，但
/// 「未知 stage 必须抛错」这条契约要保留，避免脏值被静默当成 0 天窗口。
int windowDaysFor(String stage) {
  final int? days = kVerifyWindows[stage];
  if (days == null) {
    throw ArgumentError.value(stage, 'stage', '未知验证阶段（只接受 V1/V2/V3）');
  }
  return days;
}

/// 校验一个 stage 是否是 V1/V2/V3（供筛选与解析用）。
bool isVerifyStage(String stage) => kVerifyWindows.containsKey(stage);

/// 校验一个 urgency 值是否合法。
bool isUrgency(String value) => Urgency.values.contains(value);

/// 计算某验证任务的紧迫度。
///
/// [enteredAt] 进入当前验证状态的时间，接受 `DateTime` 或 ISO 8601 字符串。
/// [windowDays] 该 stage 的窗口天数（由 [windowDaysFor] 给出）。
/// [now] 参照时间，默认当前时刻（测试可注入）。
///
/// 与后端一致的三条规则：
///   1. `elapsedDays = floor((now - enteredAt) / 一天)` —— 不足一天算 0 天，
///      避免「刚进入 V1 就剩 6.99 天」的浮点抖动；
///   2. `daysLeft = windowDays - elapsedDays`；
///   3. `daysLeft <= 0` → overdue；否则 `daysLeft <= 3` → due_soon；否则 normal。
UrgencyResult computeUrgency(
  Object enteredAt,
  int windowDays, {
  DateTime? now,
}) {
  final DateTime start = _parseTime(enteredAt, 'enteredAt');
  if (windowDays < 0) {
    throw ArgumentError.value(windowDays, 'windowDays', '必须是非负整数');
  }
  final DateTime reference = now ?? DateTime.now();

  // 两个时刻都可能带不同时区；统一用毫秒差，与后端 `Date.getTime()` 同语义。
  final int elapsedDays = (reference.millisecondsSinceEpoch - start.millisecondsSinceEpoch) ~/ kDayMs;
  final int daysLeft = windowDays - elapsedDays;

  final String urgency;
  if (daysLeft <= 0) {
    urgency = Urgency.overdue;
  } else if (daysLeft <= kDueSoonDays) {
    urgency = Urgency.dueSoon;
  } else {
    urgency = Urgency.normal;
  }

  final int overdueDays = daysLeft < 0 ? -daysLeft : 0;
  final DateTime dueAt = start.add(Duration(milliseconds: windowDays * kDayMs));

  return UrgencyResult(
    urgency: urgency,
    daysLeft: daysLeft,
    overdueDays: overdueDays,
    elapsedDays: elapsedDays,
    windowDays: windowDays,
    enteredAt: start.toUtc().toIso8601String(),
    dueAt: dueAt.toUtc().toIso8601String(),
  );
}

/// `computeUrgency` 的 stage 便捷版：窗口天数按 stage 自动取。
UrgencyResult computeUrgencyForStage(
  String stage,
  Object enteredAt, {
  DateTime? now,
}) {
  return computeUrgency(enteredAt, windowDaysFor(stage), now: now);
}

/// 把 `DateTime` / ISO 字符串 / 毫秒数归一成 `DateTime`；无法解析抛 [ArgumentError]。
DateTime _parseTime(Object value, String argumentName) {
  if (value is DateTime) return value;
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  if (value is String) {
    final String text = value.trim();
    if (text.isNotEmpty) {
      final DateTime? parsed = DateTime.tryParse(text);
      if (parsed != null) return parsed;
    }
  }
  throw ArgumentError.value(value, argumentName, '无法解析为时间');
}

/// 本地时间列的读写约定（设计 §2.1：本地一律存 UTC ISO 8601 字符串）。
///
/// DAO 层写入时由 `toLocalValue` 完成转换；这里额外提供「解析本地列」的入口，
/// 供派生层（entered_at / urgency）读取字符串列时不必各处 tryParse。
DateTime? parseLocalTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  if (value is String) {
    final String text = value.trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text);
  }
  return null;
}

/// 调试用：把窗口常量序列化成一行字符串，便于写进启动日志核对客户端副本。
String describeVerifyWindows() => jsonEncode(kVerifyWindows);
