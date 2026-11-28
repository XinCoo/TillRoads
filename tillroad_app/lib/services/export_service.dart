// lib/services/export_service.dart
// 题路 TillRoad · m32406：题库导出（拉取 → GZip → 写入 SAF 目录）
//
// 链路：GET /export/questions（后端只读快照）→ jsonEncode → GZip → 写入用户选的目录。
//
// 为什么先 jsonEncode 再压缩，而不是让后端直接回 gzip：
//   1. 后端走的是统一的 `json()` 响应封装（Content-Type + JSON.parse 契约），往回塞
//      二进制会破坏那份契约，也让 curl 调试变难；
//   2. 50 题的导出体积只有百来 KB，压缩在客户端做代价可以忽略；
//   3. 客户端压缩能让「压缩失败」成为可单独报错的一档（任务书 C3 要求分档）。
//
// 为什么用 `ApiClient.get` 拿解析后的对象再 `jsonEncode`，而不是拿原始字节：
//   ApiClient 只暴露「解析后的 JSON」，没有 raw-text 出口。对导出而言重新序列化完全
//   等价（JSON 是自描述格式，没有依赖字段顺序的语义），且顺带把后端多打的空行/缩进
//   去掉，压得更小。代价是数字/日期的字符串形式必须保持后端给的原样 —— 所以这里
//   **不做**任何类型规整，原样 `jsonEncode`。
//
// 写入分两条路（这是本轮最容易踩的坑）：
//   * Android：token 是 `content://` 树 URI，必须走 `saf_stream` 的 `writeFileBytes`。
//   * Windows / Linux：dir_picker 的 token 是 `file://` URI（桌面无沙箱），`saf_stream`
//     在这些平台上没有实现，直接写本地文件系统即可。
//   两条路都实现，才能让 `flutter run -d windows` 的调试路径真的能导出。

import 'dart:convert';
import 'dart:io' show File, Platform, gzip;
import 'dart:typed_data';

import 'package:saf_stream/saf_stream.dart';

import '../api/api_client.dart';
import '../logging/app_logger.dart';
import 'export_location.dart';

/// 导出文件的 MIME。`.tillroad` 没有注册类型，用通用二进制。
const String kExportMimeType = 'application/octet-stream';

/// 导出文件后缀。
const String kExportFileSuffix = '.tillroad';

/// 失败分档（任务书 C3）。
///
/// 为什么不用 `ApiException` 直接往外抛：调用方要给四种不同的用户文案
/// （网络 / 目录不可写 / 压缩 / 其他），而 ApiException 只覆盖第一种。
enum ExportFailureKind {
  /// 网络层或后端 5xx/4xx（`ApiException`）。
  network,

  /// 目录不可用：没选目录、权限失效、写入被拒。
  location,

  /// `jsonEncode` / `gzip` 抛错（理论上不该发生，兜底用）。
  compress,

  /// 其他未归类的异常。
  other,
}

/// 导出失败。`message` 直接可以给用户看。
class ExportException implements Exception {
  ExportException(this.kind, this.message, {this.cause});

  final ExportFailureKind kind;
  final String message;
  final Object? cause;

  @override
  String toString() => 'ExportException(${kind.name}): $message';
}

/// 导出成功的结果。
class ExportResult {
  const ExportResult({
    required this.path,
    required this.size,
    required this.questionCount,
    required this.fileName,
  });

  /// 用户可见的目录描述 + 文件名（例：`主存储/Download/TillRoad/tillroad-export-11111111-20261128-121530.tillroad`）。
  final String path;

  /// 写入字节数（压缩后的真实大小）。
  final int size;

  /// 导出题目数。
  final int questionCount;

  /// SAF 实际落盘的文件名（可能与请求的不同：同名已存在时 SAF 会自动加后缀）。
  final String fileName;

  /// 人类可读的大小（`96.4 KB`）。
  String get sizeLabel {
    if (size < 1024) return '$size B';
    final double kb = size / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(2)} MB';
  }
}

/// 题库导出服务。
class ExportService {
  ExportService({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  /// 导出当前用户的题库到已选定的 SAF 目录。
  ///
  /// 流程（任务书 B3 + C1）：
  ///   1. 读已保存的 token。没有 → 弹选择器；用户取消 → 抛 [ExportFailureKind.location]。
  ///   2. token 失效（目录被删 / 权限被撤）→ 清掉并重弹一次。**只重弹一次**：
  ///      用户若再次选了一个同样不可用的目录，报错比无限弹窗好。
  ///   3. 拉 `GET /export/questions`。
  ///   4. `jsonEncode` → `gzip` → 写入。
  ///
  /// 返回的 [ExportResult.path] 是「目录描述/文件名」拼好的展示串。
  Future<ExportResult> exportQuestions(String userId) async {
    final String token = await _resolveToken();

    // ---- 1. 拉数据 ----------------------------------------------------------
    Object? payload;
    try {
      payload = await _client.get('/export/questions');
    } on ApiException catch (e) {
      throw ExportException(
        ExportFailureKind.network,
        e.isNetworkError ? '网络连接失败：${e.message}' : '导出失败：${e.message}',
        cause: e,
      );
    } catch (e) {
      throw ExportException(
        ExportFailureKind.network,
        '导出失败：$e',
        cause: e,
      );
    }

    if (payload is! Map) {
      throw ExportException(
        ExportFailureKind.network,
        '导出失败：服务端返回格式不符合预期',
      );
    }

    final List<Object?> questions =
        (payload['questions'] as List<Object?>?) ?? const <Object?>[];
    final int questionCount = questions.length;

    // ---- 2. 压缩 ------------------------------------------------------------
    Uint8List compressed;
    try {
      final String jsonString = jsonEncode(payload);
      compressed = Uint8List.fromList(
        gzip.encode(utf8.encode(jsonString)),
      );
    } catch (e) {
      throw ExportException(
        ExportFailureKind.compress,
        '导出失败：压缩题库数据出错（$e）',
        cause: e,
      );
    }

    // ---- 3. 写入 ------------------------------------------------------------
    final String fileName = buildFileName(userId);
    final String actualName = await _write(token, fileName, compressed);

    AppLogger.instance.info(
      'EXPORT',
      '题库导出完成：$actualName · $questionCount 题 · ${compressed.length} 字节',
    );

    return ExportResult(
      path: '${ExportLocation.describeToken(token)}/$actualName',
      size: compressed.length,
      questionCount: questionCount,
      fileName: actualName,
    );
  }

  /// 拿到一个可用的目录 token；没有或失效时弹选择器。
  Future<String> _resolveToken() async {
    String? token = await ExportLocation.getSavedToken();

    if (token != null && !await ExportLocation.isUsable(token)) {
      // 失效：目录被删 / 权限被撤。清掉再重选（任务书 B4）。
      AppLogger.instance.warn('EXPORT', '保存的导出目录已失效，重新选择');
      await ExportLocation.clearSavedDirectory();
      token = null;
    }

    if (token == null) {
      final ExportPickResult picked =
          await ExportLocation.pickAndSaveDirectory();
      if (picked.isFailed) {
        throw ExportException(
          ExportFailureKind.location,
          picked.error ?? '无法选择导出目录',
        );
      }
      if (!picked.isPicked) {
        // 用户取消：不是错误，但仍然要中断导出。
        throw ExportException(
          ExportFailureKind.location,
          '已取消选择导出位置，题库没有导出。',
        );
      }
      token = picked.token!;
    }

    return token;
  }

  /// 按平台选择写入方式，返回 SAF 实际使用的文件名。
  Future<String> _write(String token, String fileName, Uint8List bytes) async {
    final Uri? uri = Uri.tryParse(token);

    // 桌面：dir_picker 给的是 file:// 目录，直接落盘（saf_stream 只有 Android 实现）。
    final bool isFileUri = uri != null && uri.scheme == 'file';
    if (isFileUri && !Platform.isAndroid) {
      try {
        String dirPath;
        try {
          dirPath = uri.toFilePath();
        } on UnsupportedError {
          throw ExportException(
            ExportFailureKind.location,
            '导出失败：无法解析导出目录路径（$token）',
          );
        }
        final File target = File(
          dirPath.endsWith(Platform.pathSeparator)
              ? '$dirPath$fileName'
              : '$dirPath${Platform.pathSeparator}$fileName',
        );
        await target.writeAsBytes(bytes, flush: true);
        return target.uri.pathSegments.isEmpty
            ? fileName
            : target.uri.pathSegments.last;
      } on ExportException {
        rethrow;
      } catch (e) {
        throw ExportException(
          ExportFailureKind.location,
          '导出失败：无法写入导出目录（$e）',
          cause: e,
        );
      }
    }

    // Android（以及将来 iOS 若接 SAF 实现）：走 saf_stream。
    try {
      // 返回值类型 `SafNewFile` 定义在 saf_stream 的 platform_interface 里，
      // 主入口库没有 re-export 它；这里靠类型推断拿字段，避免多引一个内部路径。
      final written = await SafStream().writeFileBytes(
        token,
        fileName,
        kExportMimeType,
        bytes,
      );
      // SAF 在同名文件已存在且未要求 overwrite 时会自动改名（加 ` (1)`），
      // 所以以返回的 fileName 为准，不要假设就是传入的名字。
      return written.fileName ?? fileName;
    } catch (e) {
      throw ExportException(
        ExportFailureKind.location,
        '导出失败：目录不可写（$e）',
        cause: e,
      );
    }
  }

  /// 文件名：`tillroad-export-{userId前8位}-{YYYYMMDD-HHmmss}.tillroad`
  ///
  /// userId 截 8 位是因为完整 uuid 会让文件名过长（部分 SAF provider 有长度限制），
  /// 而 8 位足够在「同一目录里区分不同账号」这个场景里唯一。
  static String buildFileName(String userId, {DateTime? now}) {
    final String shortId = userId.length <= 8 ? userId : userId.substring(0, 8);
    final DateTime t = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final String stamp =
        '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
    return 'tillroad-export-$shortId-$stamp$kExportFileSuffix';
  }

  void close() => _client.close();
}
