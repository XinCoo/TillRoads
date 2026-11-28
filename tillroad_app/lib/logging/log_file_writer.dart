// 日志文件写入器：按天滚动 + 保留 3 天 + 总量 ≤5MB。
//
// 为什么用 `dart:io` 手写而不引包：
//   ① 硬约束：不引 logger/ansicolor/logging 一类的第三方日志库；
//   ② 需求只有「追加一行 + 定期清理」两件事，`RandomAccessFile` 足够。
// 目录选择（m32036 起）：由 `lib/storage/app_dirs.dart` 统一决策 ——
//   1. `getExternalStorageDirectory()/TillRoad/logs`（应用专属外部目录，无需权限）
//   2. `getApplicationDocumentsDirectory()/TillRoad/logs`（回落）
//   3. `<当前工作目录>/logs`（仅桌面调试的兑底，手机上走不到）
// 历史包袱：旧版本用的是 `Directory.systemTemp/tillroad/logs`（Android 上就是
// `/data/user/0/<包名>/cache/tillroad/logs`）。那个目录会被系统在存储吃紧时整个清掉，
// 所以搬出来了；老的 `.log` 由 `lib/storage/log_migration.dart` 一次性迁过来。
//
// 落盘策略：**串行队列**。每次 append 只是把 Future 串到队尾，调用方永不等待磁盘。
// 这样既保证同一文件的写入顺序，也保证并发记日志不会把两行写串。

import 'dart:io';

import '../storage/app_dirs.dart';

/// 日志保留天数（含当天）。
const int kLogRetentionDays = 3;

/// 日志目录总量上限（字节）。超出后从最旧的文件开始删。
const int kLogMaxTotalBytes = 5 * 1024 * 1024;

/// 文件名前缀与后缀，`.tmp` 前缀的文件不会被本类误删（保留可预测的清理边界）。
const String _kFilePrefix = 'app-';
const String _kFileSuffix = '.log';

/// 按天滚动的日志文件写入器。
///
/// 一个实例对应一个目录；同目录下 `app-YYYY-MM-DD.log` 每天一个文件。
class LogFileWriter {
  LogFileWriter._(this.directory);

  /// 日志目录。
  final Directory directory;

  /// 已打开的当天文件句柄（跨天时会重建）。
  RandomAccessFile? _sink;

  /// `_sink` 对应的日期（本地时间，只有年月日有效）。
  DateTime? _sinkDay;

  /// 串行队列的队尾。所有 IO 都挂在这条链上。
  Future<void> _tail = Future<void>.value();


  /// 打开（或创建）日志目录。
  ///
  /// m32036 起目录由 [AppDirs.logs] 决定（外部私有目录 → 文档目录），
  /// 本方法只负责「拿目录 + 建 writer + 首轮清理」。
  ///
  /// 兑底：手机上两个 path_provider 候选都不可用时（极少），
  /// 再试一次 `<当前工作目录>/logs`（桌面调试友好）；全部失败则抛异常，
  /// 由 `AppLogger.init` 捕获并降级为纯内存日志。
  static Future<LogFileWriter> open() async {
    final Directory? appDir = await AppDirs.logs();
    final List<Directory> candidates = <Directory>[
      if (appDir != null) appDir,
      Directory('${Directory.current.path}${Platform.pathSeparator}logs'),
    ];

    Object? lastError;
    for (final Directory dir in candidates) {
      try {
        if (!dir.existsSync()) {
          await dir.create(recursive: true);
        }
        // 真写一次探针：某些目录能创建但不可写（只读挂载 / 被清理工具锁住），必须实测。
        final File probe = File(
          '${dir.path}${Platform.pathSeparator}.write-probe',
        );
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        final LogFileWriter writer = LogFileWriter._(dir);
        await writer._prune();
        return writer;
      } catch (e) {
        lastError = e;
      }
    }
    throw FileSystemException('没有可写的日志目录：$lastError');
  }

  /// 仅供测试：直接绑定到给定目录（不探测、不清理旧文件）。
  static Future<LogFileWriter> forDirectory(Directory dir) async {
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return LogFileWriter._(dir);
  }

  /// 当天的日志文件路径（导出时给用户看）。
  File get todayFile => File(_pathFor(DateTime.now()));

  String _pathFor(DateTime day) {
    final String y = day.year.toString().padLeft(4, '0');
    final String m = day.month.toString().padLeft(2, '0');
    final String d = day.day.toString().padLeft(2, '0');
    return '${directory.path}${Platform.pathSeparator}$_kFilePrefix$y-$m-$d'
        '$_kFileSuffix';
  }

  /// 追加一行（可含换行）。**不等待磁盘**，返回的 Future 仅在出错时完成。
  ///
  /// 出错被吞掉并打到控制台：写日志失败绝不能反过来影响业务。
  Future<void> append(String line) {
    final Future<void> task = _tail.then((_) async {
      try {
        await _appendNow(line);
      } catch (e) {
        // 写日志失败绝不能反过来影响业务，只能尽力打到控制台。
        // ignore: avoid_print
        print('[logger] 写日志失败：$e');
      }
    });
    _tail = task;
    return task;
  }

  Future<void> _appendNow(String line) async {
    final DateTime now = DateTime.now();
    final DateTime day = DateTime(now.year, now.month, now.day);
    if (_sink == null || _sinkDay != day) {
      await _sink?.close();
      final String path = _pathFor(now);
      final File file = File(path);
      if (!file.existsSync()) {
        await file.create(recursive: true);
      }
      // 跨天时顺便清理过期文件，避免只在启动时清理（App 常驻几天的情况）。
      _sink = await file.open(mode: FileMode.append);
      _sinkDay = day;
      await _prune();
    }
    // 末尾必须自带换行，否则多条日志会粘连成一行。
    await _sink!.writeString('$line\n');
  }

  /// 等待队列写完并落盘。导出前必须调用。
  Future<void> flush() async {
    await _tail;
    await _sink?.flush();
  }

  /// 读取最近 [kLogRetentionDays] 天内的所有日志文件内容（按日期升序）。
  ///
  /// 直接读文件而不是读内存缓冲：文件才是「用户上次启动时的现场」，
  /// 而内存缓冲只覆盖本次会话。
  Future<List<File>> recentFiles() async {
    final List<File> files = await _logFiles();
    final List<File> keep = <File>[];
    final DateTime cutoff = DateTime.now().subtract(
      Duration(days: kLogRetentionDays - 1),
    );
    final DateTime cutoffDay = DateTime(
      cutoff.year,
      cutoff.month,
      cutoff.day,
    );
    for (final File file in files) {
      final DateTime? day = _dayOf(file);
      if (day == null) continue;
      if (day.isBefore(cutoffDay)) continue;
      keep.add(file);
    }
    // 文件名里的日期是 YYYY-MM-DD，字典序 = 时间序。
    keep.sort((File a, File b) => a.path.compareTo(b.path));
    return keep;
  }

  /// 删除所有日志文件并重置句柄，返回删除数量。
  Future<int> deleteAll() async {
    await _sink?.close();
    _sink = null;
    _sinkDay = null;
    int removed = 0;
    for (final File file in await _logFiles()) {
      try {
        await file.delete();
        removed++;
      } catch (_) {
        // 单个文件删不掉不影响其余；静默跳过。
      }
    }
    _tail = Future<void>.value();
    return removed;
  }

  /// 清理：先按天数删，再按总量删最旧的。
  Future<void> _prune() async {
    final List<File> files = await _logFiles();
    if (files.isEmpty) return;
    files.sort((File a, File b) => a.path.compareTo(b.path));

    // ① 天数：只保留最近 kLogRetentionDays 个「日期」的文件。
    //    用文件名解析日期而不是 mtime —— mtime 会被备份/解压等操作篡改。
    final Map<String, File> byDay = <String, File>{};
    for (final File f in files) {
      final DateTime? day = _dayOf(f);
      if (day == null) continue;
      byDay[_dayKey(day)] = f;
    }
    final List<String> days = byDay.keys.toList()..sort();
    while (days.length > kLogRetentionDays) {
      final String oldest = days.removeAt(0);
      await _tryDelete(byDay[oldest]!);
    }

    // ② 总量：仍超出 5MB 就继续删最旧的，直到达标（至少留 1 个文件）。
    final List<File> remain = await _logFiles();
    remain.sort((File a, File b) => a.path.compareTo(b.path));
    final String today = todayFile.path;
    int total = 0;
    for (final File f in remain) {
      total += await f.length();
    }
    for (final File f in remain) {
      if (total <= kLogMaxTotalBytes || remain.length <= 1) break;
      // 当天文件永远不删：用户的现场就在里面。
      if (f.path == today) continue;
      final int size = await f.length();
      if (await _tryDelete(f)) total -= size;
    }
  }

  Future<bool> _tryDelete(File file) async {
    try {
      if (file.existsSync()) {
        await file.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 目录下符合命名规则的文件（`app-YYYY-MM-DD.log`）。
  Future<List<File>> _logFiles() async {
    if (!directory.existsSync()) return <File>[];
    final List<File> out = <File>[];
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File) continue;
      final String name = entity.uri.pathSegments.last;
      if (!name.startsWith(_kFilePrefix) || !name.endsWith(_kFileSuffix)) {
        continue;
      }
      out.add(entity);
    }
    return out;
  }

  DateTime? _dayOf(File file) {
    final String name = file.uri.pathSegments.last;
    if (!name.startsWith(_kFilePrefix) || !name.endsWith(_kFileSuffix)) {
      return null;
    }
    final String body = name.substring(
      _kFilePrefix.length,
      name.length - _kFileSuffix.length,
    );
    return DateTime.tryParse(body);
  }

  String _dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}
