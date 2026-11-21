// verify_window.dart 的单元测试（本地优先架构 R2 · 任务 A2）。
//
// 断言里的数字全部来自后端 `server/verify_window.mjs`：窗口 7/14/21、临期阈值 3 天、
// 一天 86400000 毫秒、`daysLeft <= 0` 判逾期、`elapsedDays` 向下取整。
// 这些断言的作用是「钉住副本」——若有人改了本地常量却忘了同步后端（或反过来），
// 这一组会失败。

import 'package:flutter_test/flutter_test.dart';
import 'package:tillroad_app/local/verify_window.dart';

void main() {
  // 固定参照时刻，避免测试依赖「现在几点」。
  // 2026-11-22T12:00:00Z 是本轮开发期间的某个时刻，仅作锚点。
  final DateTime now = DateTime.utc(2026, 11, 22, 12, 0, 0);

  /// 造一个「距今 [days] 天零 [hours] 小时」的进入时刻。
  String enteredDaysAgo(int days, {int hours = 0}) =>
      now.subtract(Duration(days: days, hours: hours)).toIso8601String();

  group('常量与后端一致', () {
    test('窗口天数 V1=7 / V2=14 / V3=21', () {
      expect(kVerifyWindows['V1'], 7);
      expect(kVerifyWindows['V2'], 14);
      expect(kVerifyWindows['V3'], 21);
      expect(kVerifyWindows.length, 3);
    });

    test('临期阈值 3 天、一天 86400000 毫秒', () {
      expect(kDueSoonDays, 3);
      expect(kDayMs, 86400000);
    });

    test('阶段顺序与 urgency 取值集合', () {
      expect(kVerifyStages, <String>['V1', 'V2', 'V3']);
      expect(Urgency.values, <String>['overdue', 'due_soon', 'normal']);
    });

    test('windowDaysFor 命中与未知阶段', () {
      expect(windowDaysFor('V1'), 7);
      expect(windowDaysFor('V2'), 14);
      expect(windowDaysFor('V3'), 21);
      // 未知阶段必须抛错，不能静默当成 0 天窗口（否则会被判成「已逾期」）。
      expect(() => windowDaysFor('V4'), throwsArgumentError);
      expect(() => windowDaysFor(''), throwsArgumentError);
    });

    test('isVerifyStage / isUrgency 白名单', () {
      expect(isVerifyStage('V1'), isTrue);
      expect(isVerifyStage('v1'), isFalse);
      expect(isVerifyStage('V4'), isFalse);
      expect(isUrgency('overdue'), isTrue);
      expect(isUrgency('due_soon'), isTrue);
      expect(isUrgency('normal'), isTrue);
      expect(isUrgency('dueSoon'), isFalse);
    });
  });

  group('daysLeft 边界：0 / 3 / 4（判定的分界点）', () {
    test('daysLeft = 0 → overdue（今天到期即算逾期），overdueDays = 0', () {
      final UrgencyResult r = computeUrgency(enteredDaysAgo(7), 7, now: now);
      expect(r.daysLeft, 0);
      expect(r.elapsedDays, 7);
      expect(r.urgency, Urgency.overdue);
      expect(r.overdueDays, 0);
      expect(r.isOverdue, isTrue);
    });

    test('daysLeft = 1 → due_soon', () {
      final UrgencyResult r = computeUrgency(enteredDaysAgo(6), 7, now: now);
      expect(r.daysLeft, 1);
      expect(r.urgency, Urgency.dueSoon);
      expect(r.overdueDays, 0);
    });

    test('daysLeft = 3（临期阈值上界）→ due_soon', () {
      final UrgencyResult r = computeUrgency(enteredDaysAgo(4), 7, now: now);
      expect(r.daysLeft, 3);
      expect(r.urgency, Urgency.dueSoon);
    });

    test('daysLeft = 4（阈值 + 1）→ normal', () {
      final UrgencyResult r = computeUrgency(enteredDaysAgo(3), 7, now: now);
      expect(r.daysLeft, 4);
      expect(r.urgency, Urgency.normal);
      expect(r.isOverdue, isFalse);
    });

    test('刚进入（elapsed = 0）→ 剩满窗天数且为 normal', () {
      final UrgencyResult r = computeUrgency(now.toIso8601String(), 21, now: now);
      expect(r.elapsedDays, 0);
      expect(r.daysLeft, 21);
      expect(r.urgency, Urgency.normal);
    });
  });

  group('负数取正：逾期天数', () {
    test('逾期 1 天 → daysLeft = -1，overdueDays = 1', () {
      final UrgencyResult r = computeUrgency(enteredDaysAgo(8), 7, now: now);
      expect(r.daysLeft, -1);
      expect(r.overdueDays, 1);
      expect(r.urgency, Urgency.overdue);
    });

    test('逾期 30 天 → daysLeft = -30，overdueDays = 30（取绝对值）', () {
      final UrgencyResult r = computeUrgency(enteredDaysAgo(37), 7, now: now);
      expect(r.daysLeft, -30);
      expect(r.overdueDays, 30);
      expect(r.urgency, Urgency.overdue);
    });

    test('enteredAt 在未来 → daysLeft 超过窗口，overdueDays 保持 0', () {
      // 时钟漂移或服务端时区偏差时可能出现的异常输入：不能算成逾期。
      final UrgencyResult r =
          computeUrgency(now.add(const Duration(days: 2)).toIso8601String(), 7, now: now);
      expect(r.elapsedDays, -2);
      expect(r.daysLeft, 9);
      expect(r.overdueDays, 0);
      expect(r.urgency, Urgency.normal);
    });
  });

  group('23 小时向下取整为 0 天', () {
    test('elapsed 23h → elapsedDays = 0，仍剩满窗', () {
      final UrgencyResult r =
          computeUrgency(enteredDaysAgo(0, hours: 23), 7, now: now);
      expect(r.elapsedDays, 0);
      expect(r.daysLeft, 7);
      expect(r.urgency, Urgency.normal);
    });

    test('elapsed 47h（1 天 23 小时）→ elapsedDays = 1', () {
      final UrgencyResult r =
          computeUrgency(enteredDaysAgo(1, hours: 23), 7, now: now);
      expect(r.elapsedDays, 1);
      expect(r.daysLeft, 6);
    });

    test('23 小时的取整不会让逾期提前一天：距到期 23h → 仍 normal', () {
      // 进入 3 天 23 小时前，窗口 7 天：真实剩余 3.04 天，向下取整后 daysLeft = 4。
      final UrgencyResult r =
          computeUrgency(enteredDaysAgo(3, hours: 23), 7, now: now);
      expect(r.elapsedDays, 3);
      expect(r.daysLeft, 4);
      expect(r.urgency, Urgency.normal);
    });
  });

  group('入参校验：非法输入必须抛错而不是静默降级', () {
    test('enteredAt 无法解析 → ArgumentError', () {
      expect(() => computeUrgency('not-a-time', 7), throwsArgumentError);
      expect(() => computeUrgency('', 7), throwsArgumentError);
      expect(() => computeUrgency(123.45, 7), throwsArgumentError);
    });

    test('windowDays 为负 → ArgumentError', () {
      expect(() => computeUrgency(enteredDaysAgo(1), -1), throwsArgumentError);
    });

    test('windowDays = 0 合法（立即到期）', () {
      final UrgencyResult r = computeUrgency(enteredDaysAgo(0), 0, now: now);
      expect(r.daysLeft, 0);
      expect(r.urgency, Urgency.overdue);
    });
  });

  group('enteredAt 接受三种形态', () {
    test('DateTime / ISO 字符串 / 毫秒整数 结果一致', () {
      final DateTime start = now.subtract(const Duration(days: 2));
      final UrgencyResult a = computeUrgency(start, 7, now: now);
      final UrgencyResult b = computeUrgency(start.toIso8601String(), 7, now: now);
      final UrgencyResult c =
          computeUrgency(start.millisecondsSinceEpoch, 7, now: now);
      expect(a.daysLeft, 5);
      expect(b.daysLeft, 5);
      expect(c.daysLeft, 5);
      expect(b.enteredAt, a.enteredAt);
      expect(c.enteredAt, a.enteredAt);
    });
  });

  group('输出格式：wire 与后端 snake_case 同形', () {
    test('wire 的七个键与后端响应字段名一致', () {
      final UrgencyResult r = computeUrgency(enteredDaysAgo(8), 7, now: now);
      final Map<String, Object?> wire = r.wire;
      expect(wire.keys.toSet(), <String>{
        'urgency',
        'days_left',
        'overdue_days',
        'elapsed_days',
        'window_days',
        'entered_at',
        'due_at',
      });
      expect(wire['urgency'], 'overdue');
      expect(wire['days_left'], -1);
      expect(wire['overdue_days'], 1);
      expect(wire['elapsed_days'], 8);
      expect(wire['window_days'], 7);
    });

    test('enteredAt / dueAt 是 UTC ISO 8601（与后端 toISOString 同格式）', () {
      final UrgencyResult r = computeUrgency(enteredDaysAgo(1), 7, now: now);
      expect(r.enteredAt.endsWith('Z'), isTrue);
      expect(r.dueAt.endsWith('Z'), isTrue);
      final DateTime due = DateTime.parse(r.dueAt);
      final DateTime start = DateTime.parse(r.enteredAt);
      expect(due.difference(start), const Duration(days: 7));
    });

    test('带时区偏移的输入会被统一成 UTC', () {
      // 东八区 2026-11-20 20:00 == UTC 2026-11-20 12:00
      final UrgencyResult r = computeUrgency('2026-11-20T20:00:00+08:00', 7, now: now);
      expect(r.enteredAt, '2026-11-20T12:00:00.000Z');
      expect(r.elapsedDays, 2);
      expect(r.daysLeft, 5);
    });
  });

  group('stage 便捷版', () {
    test('computeUrgencyForStage 自动取窗口（V1/V2/V3）', () {
      expect(computeUrgencyForStage('V1', enteredDaysAgo(7), now: now).urgency,
          Urgency.overdue);
      expect(computeUrgencyForStage('V2', enteredDaysAgo(13), now: now).daysLeft, 1);
      expect(computeUrgencyForStage('V2', enteredDaysAgo(13), now: now).urgency,
          Urgency.dueSoon);
      expect(computeUrgencyForStage('V3', enteredDaysAgo(12), now: now).daysLeft, 9);
      expect(computeUrgencyForStage('V3', enteredDaysAgo(12), now: now).urgency,
          Urgency.normal);
    });

    test('computeUrgencyForStage 未知阶段抛错', () {
      expect(() => computeUrgencyForStage('V9', enteredDaysAgo(1), now: now),
          throwsArgumentError);
    });
  });

  group('parseLocalTime', () {
    test('null / 空串 → null', () {
      expect(parseLocalTime(null), isNull);
      expect(parseLocalTime(''), isNull);
      expect(parseLocalTime('   '), isNull);
    });

    test('DateTime 原样返回，ISO 字符串可解析，乱码 → null', () {
      final DateTime t = DateTime.utc(2026, 11, 22, 12);
      expect(parseLocalTime(t), t);
      expect(parseLocalTime('2026-11-22T12:00:00.000Z'), t);
      expect(parseLocalTime('not-a-time'), isNull);
      expect(parseLocalTime(3.14), isNull);
    });

    test('毫秒整数按 UTC 解析', () {
      final int ms = DateTime.utc(2026, 11, 22, 12).millisecondsSinceEpoch;
      expect(parseLocalTime(ms), DateTime.utc(2026, 11, 22, 12));
    });
  });

  group('describeVerifyWindows', () {
    test('序列化成一行 JSON，便于写进启动日志', () {
      final String s = describeVerifyWindows();
      expect(s.contains('"V1":7'), isTrue);
      expect(s.contains('"V2":14'), isTrue);
      expect(s.contains('"V3":21'), isTrue);
    });
  });
}
