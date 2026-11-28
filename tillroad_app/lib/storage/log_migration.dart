// 旧日志目录一次性迁移（m32036 任务 C）。
//
// 背景：m32036 之前日志落在 `Directory.systemTemp/tillroad/logs`。
// 在 Android 上 `systemTemp` 是「应用私有**缓存**目录」（`/data/user/0/<包名>/cache`），
// 系统在存储吃紧时会**整个清掉**——用户报障时常常发现「日志目录是空的」。
// 现在改到 `getExternalStorageDirectory()/TillRoad/logs`（应用专属外部目录，
// 用户可见、系统不会随意清），所以旧目录里的历史日志要搬过来。
//
// 三条设计取舍：
//   ① **只搬一次**，用 `shared_preferences` 的 `log_migration_done` 标记。
//      没有这个标记的话，用户后来手动在旧目录里放了文件会被莫名搬走；
//      反过来每次启动都扫一遍旧目录也是无谓的 IO。
//   ② **失败不阻塞启动**：迁移只是「提升历史日志存活率」的锦上添花，
//      任何一步失败都记 `AppLogger.warn`（不是 error —— 它不影响功能），
//      并且**不置标记**，下次启动会再试一次。
//   ③ **同名文件不覆盖**：旧目录与新目录都可能有 `app-2026-11-20.log`
//      （升级当天两个版本都写过日志）。策略是「新目录已存在就跳过这个文件」，
//      而不是覆盖或追加 —— 两边格式相同，追加会把同一天的行拆到两个文件，
//      排序乱掉；跳过虽丢旧目录那一半，但至少不会污染新文件。
//      代价写进 REVIEW-NOTES 遗留项。
//
// 为什么不 rename 而是 copy + delete：
//   `systemTemp` 与「应用专属外部目录」在 Android 上属于**不同挂载点**
//   （`/data/user/0` vs `/storage/emulated/0`），跨挂载点的 rename 会抛
//   `EXDEV: Cross-device link`。必须 copy 后删源。

import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';
import 'app_dirs.dart';

/// `shared_preferences` 里的迁移标记键。
const String kLogMigrationDoneKey = 'log_migration_done';

/// 迁移结果，供日志记录与测试断言。
class LogMigrationResult {
  const LogMigrationResult({
    required this.moved,
    required this.skipped,
    required this.failed,
    required this.alreadyDone,
  });

  /// 成功搬过来的文件数。
  final int moved;

  /// 因为目标已存在而跳过的文件数。
  final int skipped;

  /// 搬运过程中抛错的文件数。
  final int failed;

  /// 标记已存在，本次什么都没做。
  final bool alreadyDone;

  bool get didSomething => moved > 0 || skipped > 0 || failed > 0;

  @override
  String toString() =>
      '已迁移 $moved · 跳过 $skipped · 失败 $failed · 已完成过=$alreadyDone';
}

/// 旧日志目录（m32036 之前 `LogFileWriter.open()` 的第一候选）。
///
/// 原样保留这段路径拼接，不改用 `AppDirs` —— 迁移的对象就是**旧**路径，
/// 将来 `AppDirs` 再变也不会影响这里。
Directory legacyLogDirectory() => Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}tillroad'
      '${Platform.pathSeparator}logs',
    );

/// 执行一次（幂等的）日志迁移。
///
/// `force: true` 时忽略标记强行迁移 —— **仅测试用**。
Future<LogMigrationResult> migrateLegacyLogs({bool force = false}) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  if (!force && (prefs.getBool(kLogMigrationDoneKey) ?? false)) {
    return const LogMigrationResult(
      moved: 0,
      skipped: 0,
      failed: 0,
      alreadyDone: true,
    );
  }

  final Directory oldDir = legacyLogDirectory();
  if (!oldDir.existsSync()) {
    // 全新安装：本来就没有旧目录，直接置标记，避免以后每次启动都 stat 一次。
    await prefs.setBool(kLogMigrationDoneKey, true);
    return const LogMigrationResult(
      moved: 0,
      skipped: 0,
      failed: 0,
      alreadyDone: false,
    );
  }

  final Directory? newDir = await AppDirs.logs();
  if (newDir == null) {
    // 新目录建不出来 —— 不置标记，下次启动再试。
    AppLogger.instance.warn('LOG', '日志迁移跳过：新日志目录不可用');
    return const LogMigrationResult(
      moved: 0,
      skipped: 0,
      failed: 0,
      alreadyDone: false,
    );
  }

  int moved = 0;
  int skipped = 0;
  int failed = 0;

  try {
    await for (final FileSystemEntity entity in oldDir.list()) {
      if (entity is! File) continue;
      final String name = entity.uri.pathSegments.last;
      // 只搬自己命名规则内的日志文件；`.write-probe` 之类的杂项不碰。
      if (!name.startsWith('app-') || !name.endsWith('.log')) continue;

      final File target = File(
        '${newDir.path}${Platform.pathSeparator}$name',
      );
      if (target.existsSync()) {
        skipped++;
        continue;
      }
      try {
        await entity.copy(target.path);
        await entity.delete();
        moved++;
      } catch (e) {
        failed++;
        // 单个文件失败不中断整批：其余文件继续搬，最后按 failed 记账。
        AppLogger.instance.warn('LOG', '日志迁移失败：$name · $e');
      }
    }
  } catch (e) {
    // `oldDir.list()` 本身失败（目录被删/权限变化），不置标记。
    AppLogger.instance.warn('LOG', '日志迁移扫描旧目录失败：$e');
    return LogMigrationResult(
      moved: moved,
      skipped: skipped,
      failed: failed,
      alreadyDone: false,
    );
  }

  // 只有「没有失败」才置标记：有失败说明还有文件没搬完，
  // 下次启动再试一次更划算（失败通常是暂时性的，如磁盘满）。
  if (failed == 0) {
    await prefs.setBool(kLogMigrationDoneKey, true);
  }

  if (moved > 0 || skipped > 0 || failed > 0) {
    AppLogger.instance.info(
      'LOG',
      '旧日志迁移：搬入 $moved 个 · 目标已存在跳过 $skipped 个 · 失败 $failed 个'
      '（旧目录 ${oldDir.path}）',
    );
  }
  return LogMigrationResult(
    moved: moved,
    skipped: skipped,
    failed: failed,
    alreadyDone: false,
  );
}

/// 仅供测试：清掉迁移标记，让下一次 [migrateLegacyLogs] 重新执行。
Future<void> resetLogMigrationFlagForTest() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.remove(kLogMigrationDoneKey);
}
