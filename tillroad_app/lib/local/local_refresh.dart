// 后台刷新：把云端最新数据拉回本地（本地优先架构 R2 的「第二段」）。
//
// 与 `first_fill.dart` 的分工：
//   · first_fill 是「本地空 → 从零灌满」，只在首次（或换 token）跑，跑完打勾；
//   · 本文件是「本地已有 → 增量对账的全量拉取」，每次页面打开都可能触发。
// 两者共用同一套行映射（`LocalCache`），所以不会出现字段名漂移。
//
// 三条设计约束（对应 docs/local-first-design.md §3.3 / 拍板第 1 条）：
//   1. **只做全量分页对账**：后端没有 `updated_since` / ETag，无法真增量
//      （本轮不改后端）。所以每次都是「按 created_at 分页拉全量 → 覆盖本地」。
//   2. **不阻塞 UI**：调用方一律 `unawaited`，失败只记 warn，本地数据保持可用。
//   3. **并发去重**：四个页面在启动/切换时可能同时触发，`_inFlight` 让它们
//      共享同一次网络往返——否则冷启动会并发打 4 倍请求，把 Neon 打醒得更慢。

import 'package:sqflite/sqflite.dart' show Database, DatabaseExecutor;

import '../api/api_client.dart';
import '../config/api_config.dart';
import '../config/local_config.dart';
import '../logging/app_logger.dart';
import 'dao/dao_base.dart';
import 'dao/local_meta_dao.dart';
import 'dao/sync_table_dao.dart';
import 'dao/table_daos.dart';
import 'first_fill.dart';
import 'local_db.dart';

/// 单页条数。**必须与后端 `pageParams` 的上限 200 一致**——
/// 传 200 服务端原样接受；传更大服务端会夹回 200，客户端却按「不足一页」
/// 判断结束，就会提前停拉（first_fill 里同一条约束）。
const int kRefreshPageSize = 200;

/// 单资源最多翻多少页（200×20 = 4000 行，防服务端异常时死循环）。
const int kRefreshMaxPages = 20;

/// 只为这些状态补拉子行：V2/V3 的 urgency 依赖「上一阶段 pass 的 created_at」，
/// 没有 verifications 就复算不出正确的进入时间。V1 用 updated_at，不需要。
const List<String> kChildRefreshStatuses = <String>['V2', 'V3'];

/// 一次刷新最多补拉多少张单的详情（每个 = 1 次请求）。
const int kMaxChildRefresh = 40;

Future<int>? _inFlight;

/// 是否正在刷新（设置页可用来显示「同步中」）。
bool get isRefreshingFromCloud => _inFlight != null;

/// 后台刷新本地缓存；返回写入行数（0 表示跳过或失败）。
///
/// 并发调用共享同一个 Future：页面各自 `unawaited(refreshLocalFromCloud())`
/// 不会造成重复请求。
Future<int> refreshLocalFromCloud() {
  if (!kLocalFirstEnabled) return Future<int>.value(0);
  final Future<int>? running = _inFlight;
  if (running != null) return running;
  final Future<int> future = _refresh().whenComplete(() => _inFlight = null);
  _inFlight = future;
  return future;
}

Future<int> _refresh() async {
  // 没有 token 就不该发起任何请求：`kApiToken` 是空值（未初始化 / 已退出）时
  // 请求会带 `Authorization: Bearer ` 并拿到 401，白白唤醒一次 Neon。
  if ((kApiToken ?? '').trim().isEmpty) return 0;

  final ApiClient client = ApiClient();
  final Stopwatch watch = Stopwatch()..start();
  int written = 0;
  try {
    // ① 档案 → ② 科目 → ③ 考点：与 first_fill 同样的父→子顺序，
    //    这样「考点标题」不会在写入脏单时还缺失。
    final List<Map<String, Object?>> profiles =
        await _pullAll(client, '/users/$kDemoUserId/exam-profiles');
    written += await LocalCache.writeExamProfiles(profiles);

    final List<String> profileIds =
        profiles.map((Map<String, Object?> p) => text(p['id'])).whereType<String>().toList(growable: false);

    final List<Map<String, Object?>> subjects = <Map<String, Object?>>[];
    for (final String profileId in profileIds) {
      subjects.addAll(await _pullAll(client, '/exam-profiles/$profileId/subjects'));
    }
    written += await LocalCache.writeSubjects(subjects);

    final List<String> subjectIds =
        subjects.map((Map<String, Object?> s) => text(s['id'])).whereType<String>().toList(growable: false);

    final List<Map<String, Object?>> nodes = <Map<String, Object?>>[];
    for (final String subjectId in subjectIds) {
      nodes.addAll(await _pullAll(client, '/subjects/$subjectId/knowledge-nodes'));
    }
    written += await LocalCache.writeKnowledgeNodes(nodes);

    // ④ 缺陷单主表
    final List<Map<String, Object?>> tickets =
        await _pullAll(client, '/users/$kDemoUserId/defect-tickets');
    written += await LocalCache.writeDefectTickets(tickets);

    // ⑤ 只补 V2/V3 的子行（见 kChildRefreshStatuses 的注释）
    written += await _refreshChildren(client);

    // ⑥ 模考（列表页用得上；报告数据在 mock_exams.report 里）
    final List<Map<String, Object?>> mocks = <Map<String, Object?>>[];
    for (final String profileId in profileIds) {
      mocks.addAll(await _pullAll(client, '/exam-profiles/$profileId/mock-exams'));
    }
    written += await LocalCache.writeMockExams(mocks);

    // ⑦ 复盘（必须带 user_id query，否则后端 400 missing_user_id）
    final List<Map<String, Object?>> cycles = await _pullAll(
      client,
      '/review-cycles',
      baseQuery: <String, String>{'user_id': kDemoUserId},
    );
    written += await LocalCache.writeReviewCycles(cycles);

    final Database db = await LocalDb.instance.database;
    await LocalDaos.meta.setAll(db, <String, String>{
      MetaKey.lastSyncAt: nowIso(),
      MetaKey.sync('defect_tickets', 'row_count'): '${tickets.length}',
      MetaKey.sync('exam_profiles', 'row_count'): '${profiles.length}',
      MetaKey.sync('review_cycles', 'row_count'): '${cycles.length}',
    });

    // 通知所有在听的页面「本地数据变了，重读一次」。
    kLocalDataRevision.value++;
    AppLogger.instance.info(
      'SYNC',
      '后台刷新完成：写入 $written 行（档案 ${profiles.length} / 科目 ${subjects.length} / '
          '考点 ${nodes.length} / 缺陷单 ${tickets.length} / 模考 ${mocks.length} / 复盘 ${cycles.length}），'
          '耗时 ${watch.elapsedMilliseconds}ms',
    );
    return written;
  } catch (e, stack) {
    // 失败不抛：页面已经渲染了本地数据，刷新失败只影响「新鲜度」。
    AppLogger.instance.warn('SYNC', '后台刷新失败（保留本地数据）：$e', stackTrace: stack.toString());
    return 0;
  } finally {
    client.close();
  }
}

/// 为 V2/V3 的缺陷单补拉 `actions` / `verifications`。
///
/// 为什么不顺带补 V1：V1 的进入时间用 `updated_at`（主表已有），不依赖子表；
/// 每多补一张就是一次往返，冷启动时这 40 次请求代价太高。
Future<int> _refreshChildren(ApiClient client) async {
  final Database db = await LocalDb.instance.database;
  final String placeholders = List<String>.filled(kChildRefreshStatuses.length, '?').join(', ');
  final List<Map<String, Object?>> rows = await db.rawQuery(
    'SELECT ${Col.localId} AS local_id, ${Col.serverId} AS server_id '
    'FROM defect_tickets WHERE ${Col.status} IN ($placeholders) '
    'ORDER BY ${Col.updatedAt} DESC LIMIT $kMaxChildRefresh',
    kChildRefreshStatuses,
  );

  int written = 0;
  for (final Map<String, Object?> row in rows) {
    final String? serverId = text(row['server_id']);
    final String? localId = text(row['local_id']);
    if (serverId == null || localId == null) continue;
    try {
      final Object? raw = await client.get('/defect-tickets/$serverId');
      if (raw is! Map) continue;
      final Object? actions = raw['actions'];
      final Object? verifications = raw['verifications'];
      if (actions is List) written += await LocalCache.writeActions(localId, actions);
      if (verifications is List) written += await LocalCache.writeVerifications(localId, verifications);
    } catch (e) {
      // 单张失败不影响其它单：下次刷新会再试。
      AppLogger.instance.warn('SYNC', '补拉缺陷单 $serverId 详情失败：$e');
    }
  }
  return written;
}

/// 分页拉全量。终止条件**只能是** `items.length < limit`
/// （`defect-tickets` 响应没有 total；`review-cycles`/`mock-exams` 的 total
/// 是 `items.length` 假 total，用它会永远停在第一页）。
Future<List<Map<String, Object?>>> _pullAll(
  ApiClient client,
  String path, {
  Map<String, String>? baseQuery,
}) async {
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  int offset = 0;
  for (int page = 0; page < kRefreshMaxPages; page++) {
    final Map<String, String> query = <String, String>{
      ...?baseQuery,
      'limit': '$kRefreshPageSize',
      'offset': '$offset',
    };
    final Object? raw = await client.get(path, query: query);
    final List<Map<String, Object?>> items = extractItems(raw);
    out.addAll(items);
    if (items.length < kRefreshPageSize) return out;
    offset += items.length;
  }
  AppLogger.instance.warn('SYNC', '$path 超过 $kRefreshMaxPages 页，本次截断');
  return out;
}

/// 清空所有「与云端一致」的行（换 token / 退出登录时用）。
///
/// 与 `first_fill._wipeAllSynced` 同语义，但放在这里是给设置页调的公开入口
/// （不清 `local_meta`，因为 token_fingerprint 由调用方决定何时重写）。
Future<void> clearLocalCache({bool keepMeta = true}) async {
  final DatabaseExecutor db = await LocalDb.instance.database;
  for (final SyncTableDao dao in LocalDaos.all) {
    await dao.deleteSynced(db);
  }
  if (!keepMeta) await LocalDaos.meta.deleteAll(db);
  kLocalDataRevision.value++;
}
