// 会话（Token）切换与「换账号后清本机残留」的共享实现（A3③）。
//
// ── 为什么放在 utils 而不是 ui 层 ─────────────────────────────────────────
// 「我的」页（profile_page.dart）与「设置」页（settings_page.dart）各有一个
// 「切换 Token」入口。两边必须**行为完全一致**：同样的校验、同样的清理、
// 同样的报错文案。把核心逻辑抽到这里，两个页面只负责「弹输入框」与
// 「把结果渲染成提示」。
//
// ── 切换顺序（关键：先验证，后写盘）────────────────────────────────────
//  1. 用**新 token** 直连 `GET /me` 校验它是否真的可用；
//     · 失败 → 直接抛错，**一个字节都没写盘**，旧 token 继续有效；
//  2. 校验通过 → 才 `saveApiToken(token)` 落盘；
//  3. 再把上一个用户的本机残留（SQLite / 日志 / 导出文件 / 其它 prefs 键）
//     清干净，避免「新 token + 旧账号数据」串号；
//  4. 最后把新用户的 id 记到 `current_user_id`，供「我的」页展示真实 id。
//
// 为什么必须先验证：`ApiClient` 的 Authorization 头取自全局 `kApiToken`，
// 没有单请求级 token 覆盖能力（api_client.dart 不在本次改动范围内）。
// 若先写盘再校验，一旦新 token 无效，旧 token 已经被覆盖掉了 ——
// 用户会直接掉线。所以这里用 `UserApi.fetchMeWithToken`（内部直接用
// `package:http` 带 `Authorization: Bearer <新 token>`）做预检，
// **失败不需要回滚**：因为压根没写过盘。

import 'dart:io' show Directory, FileSystemEntity, Platform;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show DatabaseExecutor;

import '../api/api_client.dart' show ApiException;
import '../api/user_api.dart';
import '../config/api_config.dart';
import '../local/local.dart';
import '../logging/app_logger.dart';
/// Token 在 shared_preferences 里的键名（与 api_config.dart 一致）。
const String kApiTokenPrefsKey = 'api_token';

/// 切换 Token 的结果。
class SwitchTokenResult {
  const SwitchTokenResult({
    required this.profile,
    required this.removedFiles,
    required this.removedPrefs,
  });

  /// 新 token 对应的用户资料（来自 `GET /me`）。
  final UserProfile profile;

  /// 清理掉的本机缓存文件数。
  final int removedFiles;

  /// 清理掉的 shared_preferences 键数（不含 api_token / current_user_id）。
  final int removedPrefs;

  /// 展示用名字（后端 display_name）。
  String get displayName => profile.displayName;
}

/// 切换到新 token：校验 → 落盘 → 清旧账号残留 → 记新用户 id。
///
/// 失败时抛异常（通常是 [ApiException]）且**不写盘**，旧 token 保持有效。
Future<SwitchTokenResult> switchApiToken(String token) async {
  final String normalized = token.trim();
  if (normalized.isEmpty) {
    throw ApiException('Token 不能为空');
  }

  // ① 先校验：新 token 必须真的能取到用户，否则一切都不动。
  final UserProfile profile = await UserApi.fetchMeWithToken(normalized);

  // ② 校验通过才写盘。
  await saveApiToken(normalized);

  // ③ 清上一个账号的本机残留（串号防护）。
  final int removedFiles = await clearSessionLocalState();
  final int removedPrefs = await _removeOtherPreferences();

  // ④ 记下新用户 id：「我的」页要显示真实 id（而不是硬编码的演示 id）。
  await persistCurrentUserId(profile.id);
  return SwitchTokenResult(
    profile: profile,
    removedFiles: removedFiles,
    removedPrefs: removedPrefs,
  );
}

/// 清掉「属于上一个账号」的本机数据。
///
/// 具体动作：
///   · SQLite：清空 8 张同步表的全部行 + `pending_operations`（待推送队列）
///     + `local_meta`（其中 `token_fingerprint` 是按 token 算的，换账号必须
///     一起清掉，否则 `first_fill` 会误判「本地已就绪」而跳过重新填充）；
///   · 落盘日志：`AppLogger.instance.clearAll()`；
///   · 导出文件：删掉 `systemTemp/tillroad/` 下的文件（设置页的
///     「清除本地缓存」原本只清 `tillroad/export`，这里把整个 `tillroad/`
///     目录都收一遍，顺带覆盖将来新增的子目录）。
///
/// 返回删除的文件数。
Future<int> clearSessionLocalState() async {
  int removedFiles = 0;
  try {
    final DatabaseExecutor db = await LocalDb.instance.database;
    for (final SyncTableDao dao in LocalDaos.all) {
      await dao.deleteAll(db);
    }
    await LocalDaos.pending.deleteAll(db);
    await LocalDaos.meta.deleteAll(db);
    kLocalDataRevision.value++;
  } catch (e) {
    AppLogger.instance.warn('SESSION', '清空本地库失败：$e');
  }

  try {
    await AppLogger.instance.clearAll();
  } catch (e) {
    AppLogger.instance.warn('SESSION', '清空日志失败：$e');
  }

  removedFiles += await purgeCacheDirectories();
  return removedFiles;
}

/// 删掉 `systemTemp/tillroad/` 下的文件（导出目录等）。
///
/// 与设置页原本的 `_purgeCacheDirectories()` 同源，抽到这里给两边共用。
/// 返回删除的文件数；单个文件删除失败只记日志，不中断整体清理。
Future<int> purgeCacheDirectories() async {
  final String sep = Platform.pathSeparator;
  final Directory root = Directory(
    '${Directory.systemTemp.path}${sep}tillroad',
  );
  if (!root.existsSync()) return 0;
  int removed = 0;
  try {
    await for (final FileSystemEntity entity in root.list(recursive: true)) {
      try {
        await entity.delete(recursive: true);
        removed++;
      } catch (e) {
        AppLogger.instance.warn(
          'SESSION',
          '缓存文件删除失败：${entity.path} · $e',
        );
      }
    }
  } catch (e) {
    AppLogger.instance.warn('SESSION', '缓存目录遍历失败：$e');
  }
  return removed;
}

/// 清掉 shared_preferences 里除 Token 之外的键。
///
/// 保留：`api_token`（当前凭证）、`current_user_id`（当前用户 id，
/// 由 `setCurrentUserId` 随后重写）。返回删除的键数。
Future<int> _removeOtherPreferences() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final List<String> keys = prefs
      .getKeys()
      .where(
        (String key) =>
            key != kApiTokenPrefsKey && key != kCurrentUserIdPrefsKey,
      )
      .toList();
  for (final String key in keys) {
    await prefs.remove(key);
  }
  return keys.length;
}
