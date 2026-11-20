// 日志导出：把最近 3 天日志 + 设备信息头打包成一个 .txt，供用户分享给开发者。
//
// 设计要点：
//   ① 导出文件是**纯文本**，不是 zip —— 用户要在微信/邮件里直接预览，
//      压缩包在手机端反而需要额外解压步骤；
//   ② 文件头信息（版本/OS/API 地址/导出时间）必须足够定位「哪个包、哪台机器、连的哪个后端」。
//      token 与完整 userId 已在写入日志时脱敏，文件头只放 base URL（不含 token）；
//   ③ 落盘到 `Directory.systemTemp` 下的独立子目录：share_plus 会把文件复制到自己的
//      cache 目录再分享，放 temp 里能保证源文件可读且不占用户可见存储。

import 'dart:io';

import '../config/api_config.dart';
import '../config/app_info.dart';
import 'app_logger.dart';
import 'log_file_writer.dart';

/// 一次导出的结果。
class LogExportResult {
  const LogExportResult({
    required this.file,
    required this.bytes,
    required this.lineCount,
    required this.includedFiles,
    required this.generatedAt,
  });

  /// 生成的文件（已落盘）。
  final File file;

  /// 文件字节数。
  final int bytes;

  /// 明细行数（不含文件头）。
  final int lineCount;

  /// 被合并进这份导出的日志文件名（按日期升序）。
  final List<String> includedFiles;

  final DateTime generatedAt;

  /// 人类可读大小，如 `12.4 KB`。
  String get sizeLabel {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

/// 导出最近 3 天日志。
///
/// 合并顺序：**先写入本次会话的内存缓冲（时间较早的在文件里）→ 再追加历史文件**。
/// 为什么这样排：用户报障时最关心「刚才发生了什么」，而刚发生的事可能还没落盘完成；
/// 把它放在最前面，打开文件第一屏就是现场。
///
/// 返回的文件路径可直接交给 `SharePlus.instance.share(ShareParams(files: [...]))`。
Future<LogExportResult> exportLogs({AppLogger? logger}) async {
  final AppLogger log = logger ?? AppLogger.instance;
  // 先把挂起的写刷完，否则内存缓冲里最新的几条会与文件里的旧内容重复/错序。
  await log.flush();

  final DateTime now = DateTime.now();
  final List<String> body = <String>[];

  // ① 内存缓冲（本次会话，可能包含尚未出现在文件里的最新几条）。
  final List<LogEntry> memory = log.entries;
  for (final LogEntry entry in memory) {
    body.add(entry.toLine());
  }
  final int memoryCount = body.length;

  // ② 历史文件（跳过与内存重叠的部分：内存已覆盖过的行不再重复）。
  //    做法是把文件内容整体当作「更早的上下文」追加在后面，并加分隔标记，
  //    而不是逐行去重 —— 去重成本高且容易误删合法的重复行（如两次相同请求）。
  final List<String> included = <String>[];
  final LogFileWriter? writer = log.fileWriter;
  if (writer != null) {
    final List<File> files = await writer.recentFiles();
    for (final File file in files) {
      included.add(file.uri.pathSegments.last);
      final String content = await _readSafely(file);
      if (content.trim().isEmpty) continue;
      body.add('');
      body.add('----- ${file.uri.pathSegments.last} -----');
      // 文件内容同样过一遍脱敏：即使某天有旧版本 App 写出过未脱敏内容，
      // 导出前也要再兜一次底（防御历史遗留，不是重复劳动）。
      body.add(sanitizeLogText(content.trimRight()));
    }
  }

  final String header = _buildHeader(
    now: now,
    lineCount: body.length,
    memoryCount: memoryCount,
    included: included,
  );

  final String text = '$header\n${body.join('\n')}\n';

  final Directory outDir = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}tillroad'
    '${Platform.pathSeparator}export',
  );
  if (!outDir.existsSync()) {
    await outDir.create(recursive: true);
  }

  // 文件名带秒级时间戳：连续导出两次不会互相覆盖，也方便用户区分。
  final String stamp =
      '${now.year.toString().padLeft(4, '0')}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}-'
      '${now.hour.toString().padLeft(2, '0')}'
      '${now.minute.toString().padLeft(2, '0')}'
      '${now.second.toString().padLeft(2, '0')}';
  final File out = File(
    '${outDir.path}${Platform.pathSeparator}tillroad-log-$stamp.txt',
  );
  await out.writeAsString(text, flush: true);

  // 只保留最近 5 个导出文件，避免用户反复点导出把缓存撑大。
  await _pruneExports(outDir, keep: 5);

  log.info(
    'EXPORT',
    '导出日志 ${out.uri.pathSegments.last}（${body.length} 行，'
    '${included.length} 个历史文件）',
  );

  return LogExportResult(
    file: out,
    bytes: await out.length(),
    lineCount: body.length,
    includedFiles: included,
    generatedAt: now,
  );
}

String _buildHeader({
  required DateTime now,
  required int lineCount,
  required int memoryCount,
  required List<String> included,
}) {
  final DeviceInfo device = DeviceInfo.current();
  // 注意：这里只放 base URL。token 是**独立**的 kApiToken，绝不出现在文件头。
  final String baseUrl = kApiBaseUrl;
  final String deviceLine = device.summary;
  final StringBuffer sb = StringBuffer()
    ..writeln('==========================================================')
    ..writeln(' 题路 TillRoad · 运行日志')
    ..writeln('==========================================================')
    ..writeln('应用版本 : $kAppVersion')
    ..writeln('应用名称 : $kAppName')
    ..writeln('系统     : $deviceLine')
    ..writeln('设备标识 : ${device.hostName}（本机主机名，非用户身份）')
    ..writeln('CPU 核数 : ${device.numberOfProcessors}')
    ..writeln('API 地址 : $baseUrl')
    ..writeln('导出时间 : ${_fmt(now)}')
    ..writeln('日志行数 : $lineCount（本次会话 $memoryCount 行）')
    ..writeln(
      '历史文件 : ${included.isEmpty ? '无' : included.join(', ')}',
    )
    ..writeln()
    ..writeln('脱敏说明：token 已替换为 ***，用户 ID 只保留前 4 位（如 1111****）。')
    ..writeln('          本文件不含题干、答案等用户输入内容。')
    ..writeln('==========================================================');
  return sb.toString();
}

String _fmt(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')} '
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';

Future<String> _readSafely(File file) async {
  try {
    return await file.readAsString();
  } catch (_) {
    // 读到一半被系统清缓存的情况：返回占位而不是让整个导出失败。
    return '<该文件读取失败，可能已被系统清理>';
  }
}

Future<void> _pruneExports(Directory dir, {required int keep}) async {
  try {
    final List<File> files = <File>[];
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.txt')) {
        files.add(entity);
      }
    }
    if (files.length <= keep) return;
    files.sort((File a, File b) => a.path.compareTo(b.path));
    for (final File f in files.take(files.length - keep)) {
      try {
        await f.delete();
      } catch (_) {
        // 忽略：清理失败不影响本次导出。
      }
    }
  } catch (_) {
    // 目录不可读时静默跳过。
  }
}
