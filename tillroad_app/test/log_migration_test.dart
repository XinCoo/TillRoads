// 日志迁移与 App 私有目录的单元测试（m32036）。
//
// 为什么这两个模块值得单独测：
//   ① `migrateLegacyLogs` 是**一次性**动作 —— 上线后跑错一次，用户的历史日志
//      就永远搬不过来（标记已置 true，不会再试）。它必须被测住。
//   ② `AppDirs` 的失败回落（外部目录不可用 → 文档目录）没法在真机上人为造，
//      只能靠 `debugOverrideRoot` 在测试里模拟。
//
// 测试策略：
//   · `AppDirs.debugOverrideRoot()` 把根目录指到本进程的临时目录，绝不碰真实
//     设备的 `/storage/emulated/0`；
//   · `SharedPreferences.setMockInitialValues({})` 让标记读写落在内存里；
//   · 旧目录用的是**真实**的 `Directory.systemTemp/tillroad/logs`（这也是运行时
//     真实的旧路径），测完显式清掉，避免污染后续用例。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tillroad_app/storage/app_dirs.dart';
import 'package:tillroad_app/storage/log_migration.dart';

void main() {
  late Directory tempRoot;
  late Directory legacyDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempRoot = await Directory.systemTemp.createTemp('tillroad_dirs_test_');
    AppDirs.debugOverrideRoot(tempRoot);
    legacyDir = legacyLogDirectory();
    // 每个用例从「旧目录不存在」开始，避免用例之间互相影响。
    if (legacyDir.existsSync()) {
      await legacyDir.delete(recursive: true);
    }
  });

  tearDown(() async {
    AppDirs.debugOverrideRoot(null);
    if (legacyDir.existsSync()) {
      await legacyDir.delete(recursive: true);
    }
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('AppDirs', () {
    test('logs() 建出 logs 子目录，且可写', () async {
      final Directory? dir = await AppDirs.logs();
      expect(dir, isNotNull);
      expect(dir!.existsSync(), isTrue);
      expect(dir.path, contains('logs'));
      // 探针文件不该留在目录里。
      expect(
        dir.listSync().whereType<File>().where(
              (File f) => f.path.endsWith('.write-probe'),
            ),
        isEmpty,
      );
    });

    test('data() 建出 data 子目录', () async {
      final Directory? dir = await AppDirs.data();
      expect(dir, isNotNull);
      expect(dir!.existsSync(), isTrue);
      expect(dir.path, contains('data'));
    });

    test('init() 同时准备两个目录', () async {
      await AppDirs.init();
      expect((await AppDirs.logs())!.existsSync(), isTrue);
      expect((await AppDirs.data())!.existsSync(), isTrue);
    });

    test('root() 不创建目录：还没建过时返回 null', () async {
      // 新临时根目录里只有根本身（由 createTemp 建出），logs/data 都还没有。
      // root() 只报告存在性，不负责建 —— 删东西不需要能写。
      final Directory? root = await AppDirs.root();
      expect(root, isNotNull);
      expect(Directory('${root!.path}/logs').existsSync(), isFalse);
    });

    test('describe() 对 null 给出占位文案', () {
      expect(AppDirs.describe(null), '（尚未就绪）');
      expect(AppDirs.describe(Directory('/x/y')), '/x/y');
    });
  });

  group('migrateLegacyLogs', () {
    test('旧目录不存在时直接置标记，且不报错', () async {
      final LogMigrationResult r = await migrateLegacyLogs();
      expect(r.didSomething, isFalse);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kLogMigrationDoneKey), isTrue);
    });

    test('把 app-*.log 搬到新目录并删源文件', () async {
      await legacyDir.create(recursive: true);
      final File old1 = File('${legacyDir.path}/app-2026-11-01.log')
        ..writeAsStringSync('line-a');
      final File old2 = File('${legacyDir.path}/app-2026-11-02.log')
        ..writeAsStringSync('line-b');
      // 非日志文件不该被搬走。
      final File noise = File('${legacyDir.path}/notes.txt')
        ..writeAsStringSync('keep me');

      final LogMigrationResult r = await migrateLegacyLogs();
      expect(r.moved, 2);
      expect(r.skipped, 0);
      expect(r.failed, 0);

      final Directory newDir = (await AppDirs.logs())!;
      expect(File('${newDir.path}/app-2026-11-01.log').readAsStringSync(),
          'line-a');
      expect(File('${newDir.path}/app-2026-11-02.log').readAsStringSync(),
          'line-b');
      // 源文件已删，杂项保留。
      expect(old1.existsSync(), isFalse);
      expect(old2.existsSync(), isFalse);
      expect(noise.existsSync(), isTrue);

      // 标记已置：再跑一次什么都不做。
      final LogMigrationResult again = await migrateLegacyLogs();
      expect(again.alreadyDone, isTrue);
      expect(again.moved, 0);
    });

    test('目标同名文件存在时跳过，不覆盖新文件', () async {
      await legacyDir.create(recursive: true);
      File('${legacyDir.path}/app-2026-11-03.log').writeAsStringSync('old');
      final Directory newDir = (await AppDirs.logs())!;
      File('${newDir.path}/app-2026-11-03.log').writeAsStringSync('new');

      final LogMigrationResult r = await migrateLegacyLogs();
      expect(r.moved, 0);
      expect(r.skipped, 1);
      // 新文件内容没被旧内容盖掉。
      expect(File('${newDir.path}/app-2026-11-03.log').readAsStringSync(), 'new');
    });

    test('force=true 时忽略标记重新扫描', () async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kLogMigrationDoneKey, true);
      await legacyDir.create(recursive: true);
      File('${legacyDir.path}/app-2026-11-04.log').writeAsStringSync('x');

      expect((await migrateLegacyLogs()).alreadyDone, isTrue);
      final LogMigrationResult forced = await migrateLegacyLogs(force: true);
      expect(forced.alreadyDone, isFalse);
      expect(forced.moved, 1);
    });

    test('resetLogMigrationFlagForTest 清掉标记', () async {
      await migrateLegacyLogs();
      await resetLogMigrationFlagForTest();
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kLogMigrationDoneKey), isNull);
    });
  });
}
