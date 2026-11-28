// lib/services/export_location.dart
// 题路 TillRoad · m32406：导出位置（SAF 目录选择 + 持久化 URI）
//
// 为什么选方案 A（dir_picker + saf_stream）而不是方案 B（docman）：
//   1. **职责单一**：dir_picker 只做「选目录 + 要持久化权限」，saf_stream 只做
//      「往 content:// 写字节」。导出这条链路的两个失败点（选目录失败 / 写入失败）
//      天然分开，错误文案也能分开讲（见 export_service 的分档）。
//   2. **docman 把两件事封在一起**，它自己的 pickDirectory 语义与本轮需求的
//      「先选、再持久化、失效时重弹」不完全对齐，遇到 SecurityException 时只能在
//      docman 的错误类型上做字符串判断，比直接用 dir_picker 的 `restore() == null`
//      脆弱。
//   3. 体积/依赖面：两者底层都带 jni，但 dir_picker 的持久化语义是显式的
//      `persist()`/`restore()`/`release()` 三件套，正好对应任务书 B2/B4。
//
// 关键 API 事实（dir_picker 0.8.1 实测，与任务书写法不同）：
//   * 没有 `pickDirectory()`；入口是 `DirPicker.pick()` → `PickedLocation?`。
//   * `PickOptions.android(shouldPersist: true)` **已废弃**，现写法是先 pick 再
//     `DirPicker.persist(location)` 拿 token（Android 上 token 就是 content:// URI）。
//   * `DirPicker.restore(token)` 在权限被撤/目录被删时返回 null —— 这就是「URI 失效」
//     的判定方式，不需要捕 SecurityException 才能发现。
//   * Android 每个 App 最多保留 128 个（Android 11+ 512）持久化 URI，超了系统丢最旧的，
//     所以换目录时必须 `DirPicker.release(oldToken)`，否则反复换目录会把早期权限挤掉。
//
// 存的是什么：**persist() 返回的 token**，不是 `PickedLocation.uri.toString()`。
//   Android 上两者恰好都是 content:// URI，但 iOS/macOS 上 token 是 bookmark base64，
//   存 uri 字符串会在下次启动直接失效。统一存 token 才能跨平台一致。
//
// 显示名怎么来：content:// URI 对人毫无意义（`content://com.android.externalstorage.documents/
// tree/primary%3ADownload%2FTillRoad`）。这里把 URI 解开成人能读的「主存储/Download/TillRoad」，
// 解不出来就退回原始 URI（宁可难看也不能显示空白）。

import 'dart:io' show Platform;

import 'package:dir_picker/dir_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// shared_preferences 里保存导出目录 token 的键。
const String kExportDirKey = 'export_dir_uri';

/// 导出位置的选择 / 持久化 / 失效处理。
class ExportLocation {
  ExportLocation._();

  /// 读已保存的目录 token。null = 从未选过（或已被清掉）。
  ///
  /// 这里**只读不校验**：校验要 `restore()`（会走平台通道），放在真正写入前做，
  /// 避免每次进设置页都触发一次平台调用。
  static Future<String?> getSavedToken() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString(kExportDirKey);
    if (token == null || token.trim().isEmpty) return null;
    return token.trim();
  }

  /// 兼容任务书的命名（任务书叫 getSavedDirectory）。
  static Future<Uri?> getSavedDirectory() async {
    final String? token = await getSavedToken();
    if (token == null) return null;
    final Uri? uri = Uri.tryParse(token);
    // file:// / content:// 才算 URI；iOS 的 bookmark base64 解析不出 scheme，
    // 这种情况返回 null 而不是一个假 URI（调用方只用它判断「有没有选过」）。
    return uri != null && uri.hasScheme ? uri : null;
  }

  /// 弹 SAF 选择器，拿到持久化权限，保存 token 并返回。
  ///
  /// 返回 null 有两种含义，调用方都要按「没选成」处理：
  ///   * 用户取消（`pick()` 返回 null）；
  ///   * `persist()` 抛错（平台拒绝授权，例如 Android 上目录已不可访问）。
  ///
  /// 换目录时会把旧 token `release()` 掉，避免 Android 的 128 个持久化 URI 名额被占满。
  static Future<ExportPickResult> pickAndSaveDirectory() async {
    PickedLocation? location;
    try {
      location = await DirPicker.pick();
    } on DirPickerException catch (e) {
      return ExportPickResult.failed('无法打开目录选择器：${e.message}');
    } catch (e) {
      return ExportPickResult.failed('无法打开目录选择器：$e');
    }
    if (location == null) return ExportPickResult.cancelled();

    String token;
    try {
      token = await DirPicker.persist(location);
    } catch (e) {
      return ExportPickResult.failed('无法获得该目录的长期写入权限：$e');
    }
    if (token.isEmpty) {
      return ExportPickResult.failed('无法获得该目录的长期写入权限');
    }

    final String? previous = await getSavedToken();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(kExportDirKey, token);

    // 换目录：把旧权限还回去。失败不影响本次保存（只是少腾一个名额）。
    if (previous != null && previous != token) {
      try {
        await DirPicker.release(previous);
      } catch (_) {
        // 忽略：名额是稀缺资源但不影响正确性。
      }
    }

    return ExportPickResult.picked(token);
  }

  /// 清除已保存的目录（设置页「换成新目录」或用户在 iOS 上想重选时调用）。
  ///
  /// 同时 `release()` 掉权限：否则 Android 上这个名额会一直占着，
  /// 用户换几次目录后就再也弹不出选择器了（系统丢最旧的，可能丢掉当前在用的）。
  static Future<void> clearSavedDirectory() async {
    final String? token = await getSavedToken();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(kExportDirKey);
    if (token == null) return;
    try {
      await DirPicker.release(token);
    } catch (_) {
      // 忽略：release 失败只影响名额回收，不影响「已清除」的语义。
    }
  }

  /// 校验一个 token 现在还能不能用。返回 null 表示失效（目录被删 / 权限被撤）。
  ///
  /// 这是任务书 B4 的落点：失效时**不要**在这里自动弹选择器（设置页只展示状态），
  /// 由调用方决定是「重新弹」还是「提示用户去换」——导出流程里会自动重弹。
  static Future<bool> isUsable(String token) async {
    try {
      final PickedLocation? location = await DirPicker.restore(token);
      return location != null;
    } catch (_) {
      return false;
    }
  }

  /// 把 token 解释成人类可读的目录名，给设置页 / 导出成功提示用。
  ///
  /// 例：`content://com.android.externalstorage.documents/tree/primary%3ADownload%2FTillRoad`
  ///   → `主存储/Download/TillRoad`
  /// Windows/Linux 的 `file:///C:/Users/me/Desktop` → `C:/Users/me/Desktop`
  /// iOS 的 bookmark base64 → 认不出来，返回「已选择的文件夹」。
  static String describeToken(String? token) {
    if (token == null || token.trim().isEmpty) return '未设置，导出时选择';
    final String raw = token.trim();

    final Uri? uri = Uri.tryParse(raw);
    if (uri != null && uri.scheme == 'file') {
      try {
        return uri.toFilePath();
      } catch (_) {
        return uri.path.isEmpty ? raw : uri.path;
      }
    }

    if (uri != null && uri.scheme == 'content') {
      // SAF 树 URI 的最后一段形如 `tree/primary:Download/TillRoad`（编码后是
      // `tree%2Fprimary%3ADownload%2FTillRoad`）。这里直接对整串做一次解码，
      // 再取 `tree/` 之后的部分，避免依赖具体的 pathSegments 结构
      // （不同 provider 的段数不一样）。
      try {
        String decoded = Uri.decodeFull(raw);
        final int treeAt = decoded.indexOf('/tree/');
        if (treeAt >= 0) {
          decoded = decoded.substring(treeAt + '/tree/'.length);
        }
        final int endAt = decoded.indexOf('#');
        if (endAt >= 0) decoded = decoded.substring(0, endAt);
        decoded = decoded.trim();
        // `primary:Download/TillRoad` → `主存储/Download/TillRoad`
        if (decoded.startsWith('primary:')) {
          decoded = '主存储/${decoded.substring('primary:'.length)}';
        } else if (decoded.startsWith('home:')) {
          decoded = '文档/${decoded.substring('home:'.length)}';
        }
        return decoded.isEmpty ? raw : decoded;
      } catch (_) {
        return raw;
      }
    }

    // iOS/macOS 的 bookmark base64 之类：认不出来就明说，别显示一坨 base64。
    if (Platform.isIOS || Platform.isMacOS) return '已选择的文件夹';
    return raw;
  }
}

/// `pickAndSaveDirectory()` 的结果。
///
/// 三态（picked / cancelled / failed）用独立类型而不是 `Uri?`，因为调用方对
/// 「用户取消」和「选失败了」要给不同文案 —— 用 null 两者混在一起会说错话。
class ExportPickResult {
  const ExportPickResult._(this.token, this.cancelled, this.error);

  factory ExportPickResult.picked(String token) =>
      ExportPickResult._(token, false, null);
  factory ExportPickResult.cancelled() =>
      const ExportPickResult._(null, true, null);
  factory ExportPickResult.failed(String error) =>
      ExportPickResult._(null, false, error);

  /// 成功时的持久化 token。
  final String? token;

  /// 用户主动取消（不算错误，不弹错误提示）。
  final bool cancelled;

  /// 失败原因（中文短句）。
  final String? error;

  bool get isPicked => token != null;
  bool get isFailed => error != null;
}
