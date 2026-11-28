// App 私有目录（m32036 任务 B）。
//
// 只定义两个目录，**刻意不定义导出目录**：导出位置将来由 SAF（Storage Access
// Framework）让用户自己选，那是一条与「App 自己的数据放哪」完全不同的决策链，
// 提前写死一个 export 目录只会在接 SAF 时变成要清理的历史包袱。
//
// 为什么是 getExternalStorageDirectory() 而不是 getApplicationDocumentsDirectory()：
//   · 前者在 Android 上是 `/storage/emulated/0/Android/data/<包名>/files`，
//     属于 scoped storage 里的「应用专属外部目录」——**不需要任何存储权限**就能读写，
//     而且它在「设置 → 应用 → 存储」里是用户可见、可清理的；
//   · 后者在 Android 上是 `/data/user/0/<包名>/app_flutter`，属内部存储，
//     用户完全看不到、也清理不掉。日志与临时导入文件放在这里，出问题时
//     用户连「日志大概在哪」都说不清，所以只作为**回落**候选。
//   · 两者都会随卸载被系统删除（外部目录的 flutter 子目录在部分 ROM 上会残留，
//     所以下面统一放到 `TillRoad/` 这个自有前缀下，便于「清除缓存」整体删除）。
//
// 为什么目录要显式 create(recursive: true) 而不是依赖写入时自动建：
//   `Directory.list()` / `File.exists()` 在父目录不存在时不会报错，只会返回空，
//   于是一个「目录没建出来」的 bug 会伪装成「今天没有日志」。统一在这里建，
//   让失败点在 init 阶段暴露一次，而不是散落到各处。
//
// 失败策略：**任何一步失败都不抛异常**，只是返回 null / 回落候选。
//   启动流程（main）不能被一个目录问题阻塞；调用方拿到 null 时按各自语义降级
//   （日志 → 纯内存；导入临时文件 → 报错让用户重试）。

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

/// App 私有目录的统一入口。
///
/// 使用方式：
/// ```dart
/// await AppDirs.init();                 // main() 里启动一次
/// final Directory? logs = await AppDirs.logs();
/// final Directory? data = await AppDirs.data();
/// ```
///
/// 所有 getter 都是**异步且幂等**的：重复调用返回同一个 [Directory]（路径相同），
/// 磁盘上的 mkdir 也只会真正发生一次。这样页面层可以直接 await，不需要自己缓存。
class AppDirs {
  AppDirs._();

  /// 自有前缀。放在应用专属外部目录下的 `TillRoad/` 里，
  /// 便于「清除本地缓存」整体删除、也便于用户自己找。
  static const String kRootName = 'TillRoad';

  /// 日志子目录名。
  static const String kLogsName = 'logs';

  /// 数据子目录名（导入临时文件、题库缓存等）。
  static const String kDataName = 'data';

  /// 启动时创建一次。**不阻塞启动**：失败只打日志，后续调用会各自重试。
  static Future<void> init() async {
    await logs();
    await data();
  }

  /// 日志目录。优先应用专属外部目录，失败回落应用文档目录。
  ///
  /// 两个候选都失败时返回 null（调用方降级为纯内存日志）。
  static Future<Directory?> logs() => _resolve(kLogsName);

  /// 数据目录（导入临时文件、题库缓存）。回落顺序同 [logs]。
  static Future<Directory?> data() => _resolve(kDataName);

  /// 根目录（`.../TillRoad`）。仅供「清除本地缓存」整体删除用。
  ///
  /// 与 [logs] / [data] 不同，这里**不**建目录也不写探针 ——
  /// 删的时候不需要能写，返回 null 就表示「没东西可删」。
  static Future<Directory?> root() async {
    if (_rootOverride != null) {
      return _rootOverride!.existsSync() ? _rootOverride : null;
    }
    try {
      final Directory? base = await _externalBase();
      if (base != null && base.existsSync()) return base;
    } catch (_) {
      // 外部目录不可用，继续回落。
    }
    try {
      final Directory? base = await _documentsBase();
      if (base != null && base.existsSync()) return base;
    } catch (_) {
      // 两个都不在，返回 null。
    }
    return null;
  }

  /// 仅供测试：把根目录钉死到临时目录，避免测试去碰真实设备目录。
  static void debugOverrideRoot(Directory? dir) {
    _rootOverride = dir;
  }

  static Directory? _rootOverride;

  /// 按「外部 → 文档」顺序回落，返回第一个能建出来的子目录。
  ///
  /// 两个候选都失败时返回 null（调用方各自降级），并 debugPrint 出两个原因。
  static Future<Directory?> _resolve(String child) async {
    if (_rootOverride != null) return _ensure(_rootOverride!, child);

    Object? firstError;
    try {
      final Directory? base = await _externalBase();
      if (base == null) {
        firstError = 'getExternalStorageDirectory() 返回 null';
      } else {
        final Directory? dir = await _ensure(base, child);
        if (dir != null) return dir;
        firstError = '创建 $child 子目录失败';
      }
    } catch (e) {
      firstError = e;
    }
    debugPrint('[dirs] 应用专属外部目录不可用（$firstError），回落到文档目录');

    Object? secondError;
    try {
      final Directory? base = await _documentsBase();
      if (base == null) {
        secondError = 'getApplicationDocumentsDirectory() 不可用';
      } else {
        final Directory? dir = await _ensure(base, child);
        if (dir != null) return dir;
        secondError = '创建 $child 子目录失败';
      }
    } catch (e) {
      secondError = e;
    }
    debugPrint('[dirs] 文档目录也不可用（$secondError），$child 目录不可用');
    return null;
  }

  /// 基础目录：应用专属外部目录（Android 无需权限）。
  static Future<Directory?> _externalBase() async {
    final Directory? dir = await getExternalStorageDirectory();
    if (dir == null) return null;
    return Directory('${dir.path}${Platform.pathSeparator}$kRootName');
  }

  /// 回落基础目录：应用文档目录。
  static Future<Directory?> _documentsBase() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    return Directory('${dir.path}${Platform.pathSeparator}$kRootName');
  }

  /// 建出 `base/child`（`child` 为空时就是 base 本身），返回可用目录。
  ///
  /// 只 create 不够：某些 ROM 上目录能创建但不可写（只读挂载 / 被清理工具锁住），
  /// 这里真写一次探针再删，确保「返回非 null 就一定可写」。
  static Future<Directory?> _ensure(Directory base, String child) async {
    final Directory dir = child.isEmpty
        ? base
        : Directory('${base.path}${Platform.pathSeparator}$child');
    try {
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      final File probe = File(
        '${dir.path}${Platform.pathSeparator}.write-probe',
      );
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return dir;
    } catch (e) {
      debugPrint('[dirs] 创建/校验目录失败 ${dir.path}：$e');
      return null;
    }
  }

  /// 目录的展示路径（给设置页用）。未就绪时返回占位文案而不是抛异常。
  static String describe(Directory? dir) => dir?.path ?? '（尚未就绪）';
}
