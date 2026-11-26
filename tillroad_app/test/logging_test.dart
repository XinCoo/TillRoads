// 日志核心的单元测试（任务 A/C 的硬性约束必须可验证）。
//
// 这些断言刻意只覆盖「脱敏 + 环形缓冲 + 文件滚动」三件最容易回归的事：
//   - 脱敏漏一处就等于把 token 发给第三方，必须被测试钉住；
//   - 环形缓冲上限 500 是内存安全边界；
//   - 保留 3 天 / 5MB 是磁盘安全边界。
//
// 不测 UI（导出入口靠真机验证），因为 UI 的失败模式是本机可肉眼确认的，
// 而这三类失败模式都是「静默的」。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tillroad_app/logging/app_logger.dart';
import 'package:tillroad_app/logging/log_file_writer.dart';

void main() {
  group('脱敏（任务 C）', () {
    test('Bearer token 被替换，原值不残留', () {
      const String raw =
          'Authorization: Bearer tk_test_001abcDEF_-123 请求 /health';
      final String out = sanitizeLogText(raw);
      expect(out, isNot(contains('tk_test_001abcDEF_-123')));
      expect(out.toLowerCase(), contains('bearer ***'));
    });

    test('裸 tk_ token 被替换', () {
      expect(sanitizeLogText('token=tk_abcdef123 开始'), isNot(contains('tk_abcdef123')));
    });

    test('分发用的 tltest token 也被替换（新旧两种格式）', () {
      // 裸 tltest 前缀
      final String bare = sanitizeLogText('token=tltest001 开始练习');
      expect(bare, isNot(contains('tltest001')));
      expect(bare, contains('token=***'));

      // Bearer tltest 前缀
      final String bearer = sanitizeLogText('Authorization: Bearer tltest002 请求 /users');
      expect(bearer, isNot(contains('tltest002')));
      expect(bearer.toLowerCase(), contains('bearer ***'));

      // 旧格式 tk_ 仍然有效（历史日志不能因为改了正则就漏出去）
      expect(sanitizeLogText('tltest003 tk_test_004'), isNot(contains('tltest003')));
      expect(sanitizeLogText('tltest003 tk_test_004'), isNot(contains('tk_test_004')));
    });

    test('正常单词不被误伤（task_x / risk_abc）', () {
      expect(sanitizeLogText('task_x risk_abc'), 'task_x risk_abc');
    });

    test('UUID 只保留前 4 位', () {
      const String uuid = '11111111-1111-4111-8111-111111111111';
      final String out = sanitizeLogText('GET /users/$uuid/defect-tickets');
      expect(out, contains('1111****'));
      expect(out, isNot(contains(uuid)));
      expect(out, contains('/users/1111****/defect-tickets'));
    });

    test('maskUuid 处理短串与非 UUID 文本', () {
      // 短于 4 位没有可保留的信息，全部打成 ****。
      expect(maskUuid('abc'), '****');
      // 非 UUID 文本不会被 `_uuidRe` 命中，`sanitizeLogText` 应原样保留 ——
      // 这条断言防止有人把正则写成「任何带连字符的串」。
      expect(sanitizeLogText('not-a-uuid'), 'not-a-uuid');
    });

    test('查询串里的敏感键被替换', () {
      final String out = sanitizeLogText('/x?token=abc123&a=1');
      expect(out, isNot(contains('abc123')));
      expect(out, contains('token=***'));
    });
  });

  group('环形缓冲', () {
    test('超过 500 条丢最旧的', () {
      final AppLogger logger = AppLogger.instance..resetForTest();
      for (int i = 0; i < 520; i++) {
        logger.info('T', '第 $i 条');
      }
      expect(logger.entryCount, AppLogger.maxEntries);
      // 最旧的 20 条应已被丢弃，缓冲区首条是「第 20 条」。
      expect(logger.entries.first.message, contains('第 20 条'));
      expect(logger.entries.last.message, contains('第 519 条'));
    });

    test('写入缓冲区前已脱敏（内存不留原文）', () {
      final AppLogger logger = AppLogger.instance..resetForTest();
      const String uuid = 'cbd8eb64-73d9-44c3-9898-aa2e701e8d84';
      logger.info('API', 'GET /users/$uuid/mock-exams token=tk_secret_9');
      final String joined =
          logger.entries.map((LogEntry e) => e.toLine()).join('\n');
      expect(joined, isNot(contains(uuid)));
      expect(joined, isNot(contains('tk_secret_9')));
      expect(joined, contains('cbd8****'));
    });
  });

  group('文件滚动 / 保留策略（任务 A2）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tillroad_log_test_');
    });

    tearDown(() async {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });

    test('按天命名 app-YYYY-MM-DD.log 并写入换行', () async {
      final LogFileWriter writer = await LogFileWriter.forDirectory(dir);
      await writer.append('第一行');
      await writer.append('第二行');
      await writer.flush();

      final File today = writer.todayFile;
      expect(today.existsSync(), isTrue);
      expect(today.uri.pathSegments.last, matches(r'^app-\d{4}-\d{2}-\d{2}\.log$'));
      final String content = await today.readAsString();
      expect(content, contains('第一行'));
      expect(content, contains('第二行'));
      // 两条日志必须是两行，不能粘连。
      expect(content.trimRight().split('\n').length, 2);
      await writer.deleteAll();
    });

    test('只保留最近 3 个日期的文件', () async {
      // 先造 5 个历史文件（命名规则与 writer 一致）。
      final List<String> days = <String>[
        '2020-01-01',
        '2020-01-02',
        '2020-01-03',
        '2020-01-04',
        '2020-01-05',
      ];
      for (final String d in days) {
        await File('${dir.path}${Platform.pathSeparator}app-$d.log')
            .writeAsString('old');
      }
      final LogFileWriter writer = await LogFileWriter.forDirectory(dir);
      await writer.append('当前一行');
      await writer.flush();

      final List<File> remaining = await writer.recentFiles();
      // 已 prune 到 3 天，因此最多 3 个。
      expect(remaining.length, lessThanOrEqualTo(kLogRetentionDays));
      await writer.deleteAll();
    });

    test('deleteAll 清空所有日志文件', () async {
      final LogFileWriter writer = await LogFileWriter.forDirectory(dir);
      await writer.append('x');
      await writer.flush();
      final int removed = await writer.deleteAll();
      expect(removed, greaterThanOrEqualTo(1));
      expect(writer.todayFile.existsSync(), isFalse);
    });
  });
}
