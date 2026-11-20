// 运行日志核心（单例 + 内存环形缓冲 + 写入前脱敏）。
//
// 为什么手写而不引 `logger` / `logging` / `ansicolor`：
//   ① 本项目对新增依赖有硬约束，本轮只允许 share_plus；
//   ② 需求很小（四个级别 + 环形缓冲 + 落文件），第三方包的额外能力（彩色终端输出、
//      多层输出器、Zone 集成）在这里全是负担；
//   ③ **脱敏必须在写入前执行**，这一点必须由我们自己完全掌控 ——
//      交给第三方库做后置过滤，一旦某条路径绕过过滤器，token 就留在磁盘上了。
//
// 脱敏的强制执行点：`_write()` 是唯一入口，任何级别、任何 tag 的日志都要经过
// `sanitizeLogText()` 才会进入缓冲区和文件。也就是说「内存里也不留原文」是结构性保证，
// 而不是靠调用方自觉。

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugPrint, immutable, kDebugMode, visibleForTesting;

import 'log_file_writer.dart';

/// 日志级别。`label` 用于落盘时的定宽前缀（方便 grep / 肉眼扫）。
enum LogLevel {
  debug('DEBUG'),
  info('INFO'),
  warn('WARN'),
  error('ERROR');

  const LogLevel(this.label);

  final String label;
}

/// 一条结构化日志。字段一旦构造就不再变化。
@immutable
class LogEntry {
  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.stackTrace,
  });

  final DateTime timestamp;
  final LogLevel level;

  /// 来源标签，约定用大写短词：`APP` / `API` / `NAV` / `DIAG` / `FLUTTER` / `ASYNC`。
  final String tag;
  final String message;
  final String? stackTrace;

  /// 单行格式：`2026-11-20 18:42:23.123 [INFO ] [API] GET /users/1111****/defect-tickets`
  ///
  /// 时间戳用本地时间、毫秒精度：排查时「两条日志的先后顺序」比绝对时间更重要，
  /// 而毫秒足够区分同一秒内的请求与响应。
  String toLine() {
    final String ts =
        '${timestamp.year.toString().padLeft(4, '0')}-'
        '${timestamp.month.toString().padLeft(2, '0')}-'
        '${timestamp.day.toString().padLeft(2, '0')} '
        '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}.'
        '${timestamp.millisecond.toString().padLeft(3, '0')}';
    // 注意变量名不能叫 `level`：会遮蔽外层同名成员，Dart 判定为「使用前声明」。
    final String levelText = level.label.padRight(5, ' ');
    final StringBuffer sb = StringBuffer('$ts [$levelText] [$tag] $message');
    final String? trace = stackTrace;
    if (trace != null && trace.trim().isNotEmpty) {
      // 栈只取前 12 行：完整栈动辄上百行，导出文件里没人看，还会挤掉别的日志。
      final List<String> lines = trace.trim().split('\n');
      final int take = lines.length > 12 ? 12 : lines.length;
      for (int i = 0; i < take; i++) {
        sb.write('\n    ${lines[i].trimRight()}');
      }
      if (lines.length > take) {
        sb.write('\n    …（栈已截断，共 ${lines.length} 行）');
      }
    }
    return sb.toString();
  }
}

// ---------------------------------------------------------------------------
// 脱敏（任务 C）
// ---------------------------------------------------------------------------

/// `Bearer xxx` → `Bearer ***`。
///
/// 同时覆盖 `Bearer  xxx`（多个空格）与大小写变体，避免因为格式差异漏网。
final RegExp _bearerRe = RegExp(
  r'Bearer\s+[A-Za-z0-9_\-.=+/]+',
  caseSensitive: false,
);

/// `tk_test_001` 一类的固定 token → `***`。
///
/// 前置 `\b`：避免把 `task_x`、`risk_abc` 这类正常单词误伤成 `***`。
final RegExp _tkTokenRe = RegExp(r'\btk_[A-Za-z0-9_]+');

/// UUID（用户 ID、缺陷单 ID、复盘 ID 都是这个格式）。
final RegExp _uuidRe = RegExp(
  r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
);

/// query 里的 `token=...` / `access_token=...` / `api_key=...`。
///
/// 任务书没点名这一条，但请求 URL 是要落盘的，而 URL 拼接出错的场景恰恰
/// 最容易把 token 带进 query —— 顺手堵上，成本一个正则。
final RegExp _querySecretRe = RegExp(
  r'\b(token|access_token|api_key|apikey|password|pwd)=[^&\s]+',
  caseSensitive: false,
);

/// UUID 只保留前 4 位：`11111111-1111-4111-8111-111111111111` → `1111****`。
///
/// 为什么保留前 4 位而不是全删：同一个用户的日志条目要能看出「是不是同一个 ID」，
/// 全删就丢了这个信息；而 4 位十六进制只有 65536 种可能，单独无法定位到人。
String maskUuid(String uuid) {
  final String compact = uuid.replaceAll('-', '');
  if (compact.length < 4) return '****';
  return '${compact.substring(0, 4)}****';
}

/// 对任意日志文本执行脱敏。**在进入缓冲区之前调用**（见 `AppLogger._write`）。
///
/// 顺序有讲究：先替 UUID 再替 query secret，最后替 Bearer / tk_ token。
/// 实际上三种规则互不重叠（UUID 是十六进制带连字符、tk_ 有前缀、Bearer 有前缀），
/// 顺序不影响结果，这里按「最长匹配优先」的习惯排列。
String sanitizeLogText(String text) {
  String s = text;
  s = s.replaceAllMapped(_uuidRe, (Match m) => maskUuid(m.group(0)!));
  s = s.replaceAllMapped(
    _querySecretRe,
    (Match m) => '${m.group(1)}=***',
  );
  s = s.replaceAllMapped(_bearerRe, (Match m) => 'Bearer ***');
  s = s.replaceAllMapped(_tkTokenRe, (Match m) => '***');
  return s;
}

// ---------------------------------------------------------------------------
// 单例
// ---------------------------------------------------------------------------

/// 全局日志入口。
///
/// 使用方式：
/// ```dart
/// AppLogger.instance.info('APP', '启动 v$kAppVersion');
/// AppLogger.instance.error('API', '请求失败', stackTrace: e.toString());
/// ```
///
/// 所有方法都是**同步非阻塞**的：写文件通过内部队列异步落盘，
/// 调用方不需要 `await`（也不会因为磁盘慢而卡住 UI）。
class AppLogger {
  AppLogger._();

  /// 全局唯一实例。
  static final AppLogger instance = AppLogger._();

  /// 内存环形缓冲上限。超过后丢最旧的 —— 用户报障时最近 500 条足够复原现场。
  static const int maxEntries = 500;

  /// 定长队列，`removeFirst()` 是 O(1)；用 `List` 做 `removeAt(0)` 是 O(n)。
  final ListQueue<LogEntry> _buffer = ListQueue<LogEntry>(maxEntries);

  LogFileWriter? _writer;
  bool _initialized = false;

  /// 是否同时把日志打到控制台（debug 构建才开）。
  bool mirrorToConsole = kDebugMode;

  /// 当前落盘目录；未初始化或降级为纯内存时为 `null`。
  String? get logDirectory => _writer?.directory.path;

  /// 是否已接上文件落盘（false 表示只保留内存日志）。
  bool get isPersisting => _writer != null;

  /// 内存中的日志条数（≤ [maxEntries]）。
  int get entryCount => _buffer.length;

  /// 内存中的日志快照（旧 → 新），供导出使用。
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_buffer);

  /// 当前的文件写入器（未落盘时为 `null`）。导出时用它读历史文件。
  LogFileWriter? get fileWriter => _writer;
  /// 初始化文件落盘。**可重复调用**（第二次只是换 writer）。
  ///
  /// 失败不抛异常：日志系统本身不能成为崩溃源。落盘不可用时退化为「只有内存日志」，
  /// 导出时仍能拿到本次会话的缓冲区内容。
  Future<void> init({LogFileWriter? writer}) async {
    if (_initialized && writer == null) return;
    _initialized = true;
    try {
      _writer = writer ?? await LogFileWriter.open();
    } catch (e) {
      _writer = null;
      // 这里只能 debugPrint：日志系统还没就绪，不能自己记自己。
      debugPrint('[logger] 文件落盘初始化失败，降级为纯内存：$e');
    }
  }

  void debug(String tag, String message) =>
      _write(LogLevel.debug, tag, message);

  void info(String tag, String message) => _write(LogLevel.info, tag, message);

  void warn(String tag, String message, {String? stackTrace}) =>
      _write(LogLevel.warn, tag, message, stackTrace: stackTrace);

  void error(String tag, String message, {String? stackTrace}) =>
      _write(LogLevel.error, tag, message, stackTrace: stackTrace);

  /// 唯一写入入口 —— 脱敏在这里强制发生（任务 C4）。
  void _write(LogLevel level, String tag, String message, {String? stackTrace}) {
    // 先脱敏，再构造 LogEntry：内存缓冲区里从头到尾没有原文。
    final LogEntry entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: sanitizeLogText(tag),
      message: sanitizeLogText(message),
      stackTrace: stackTrace == null ? null : sanitizeLogText(stackTrace),
    );

    if (_buffer.length >= maxEntries) {
      _buffer.removeFirst();
    }
    _buffer.add(entry);

    final String line = entry.toLine();
    // 落盘也走脱敏后的 entry.toLine()，不会二次引入原文。
    unawaited(_writer?.append(line) ?? Future<void>.value());

    if (mirrorToConsole) {
      debugPrint(line);
    }
  }

  /// 等待所有挂起的落盘写完。导出前必须调用，否则可能少最后几条。
  Future<void> flush() async {
    await _writer?.flush();
  }

  /// 清空内存缓冲（**不动文件**）。任务 D4 的「清空日志」会连带删文件。
  void clearMemory() {
    _buffer.clear();
  }

  /// 删除所有日志文件并清空内存缓冲。返回删除的文件数。
  Future<int> clearAll() async {
    clearMemory();
    final LogFileWriter? writer = _writer;
    if (writer == null) return 0;
    return writer.deleteAll();
  }

  /// 仅测试用：把单例恢复到未初始化状态。
  @visibleForTesting
  void resetForTest() {
    _buffer.clear();
    _writer = null;
    _initialized = false;
  }
}

/// 从 `dart:io` 取设备与系统信息，供导出文件头使用。
///
/// 刻意不引 `device_info_plus`：只为了多拿一个「设备型号」而引入一个原生插件，
/// 在对外分发前的稳定性预算里不划算。`Platform.operatingSystemVersion` 在
/// Android 上已经带版本号（形如 `"Android 17 (API 37)"`），足够判断 ROM 与 API 级别。
class DeviceInfo {
  const DeviceInfo({
    required this.operatingSystem,
    required this.operatingSystemVersion,
    required this.hostName,
    required this.numberOfProcessors,
  });

  factory DeviceInfo.current() => DeviceInfo(
    operatingSystem: Platform.operatingSystem,
    operatingSystemVersion: Platform.operatingSystemVersion,
    hostName: Platform.localHostname,
    numberOfProcessors: Platform.numberOfProcessors,
  );

  final String operatingSystem;
  final String operatingSystemVersion;
  final String hostName;
  final int numberOfProcessors;

  String get summary => '$operatingSystem · $operatingSystemVersion';
}
