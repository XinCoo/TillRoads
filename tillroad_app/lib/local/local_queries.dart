// 本地读查询：把本地表行拼成页面直接能用的模型（本地优先架构 R2）。
//
// 为什么单独一个文件、而不把这些 JOIN 塞进 DAO：
//   DAO 层是「一张表 → 行」的机械 CRUD（R1 的约定，会被 R3 对账复用）；
//   这里是「多表拼装 + 派生计算」，属于页面视图层的一部分。分开后
//   R3 想改同步逻辑时不会误伤页面模型，页面改展示时也不会动到 DAO。
//
// 三条铁律（与 docs/local-first-design.md §2.4 一致）：
//   1. 派生数据（urgency / 摘要 / 分布）**全部本地复算**，不再请求云端。
//      urgency 必须用 [computeUrgency]，与 `server/verify_window.mjs` 同一套公式。
//   2. 展示字段（考点名 / 科目名）用 LEFT JOIN 本地目录表得到；
//      考点尚未同步时回落成「考点 <id 前 8 位>」，与 `_ticketFromJson` 的兜底一致。
//   3. 返回 null 表示「本地还没有任何数据」，与「确实查不到」区分开——
//      页面据此决定显示加载态（首次填充未完成）还是空状态（任务书 C5）。

import 'package:sqflite/sqflite.dart';

import '../api/verification_api.dart';
import '../mock/defects_mock.dart';
import 'dao/dao_base.dart';
import 'dao/sync_table_dao.dart';
import 'dao/table_daos.dart';
import 'first_fill.dart';
import 'local_db.dart';
import 'verify_window.dart';

/// 本地是否已经有可展示的数据（任一业务表非空）。
///
/// 页面在「false 且首次填充未完成」时显示加载态，而不是「暂无缺陷单」——
/// 那是把「还没同步下来」误报成「你确实没有数据」。
Future<bool> localHasAnyData() async {
  final Database db = await LocalDb.instance.database;
  for (final SyncTableDao dao in LocalDaos.all) {
    if (await dao.count(db) > 0) return true;
  }
  return false;
}

/// T1：取当前生效的考试目标（服务端 `status = 'active'` 优先，否则取第一条）。
Future<Map<String, Object?>?> loadActiveExamProfile(String userId) async {
  final Database db = await LocalDb.instance.database;
  final List<Map<String, Object?>> rows = await db.query(
    'exam_profiles',
    where: '${Col.userId} = ?',
    whereArgs: <Object?>[userId],
    orderBy: 'created_at ASC, local_id ASC',
  );
  if (rows.isEmpty) return null;
  for (final Map<String, Object?> row in rows) {
    if (text(row['status']) == 'active') return _profileToWire(row);
  }
  return _profileToWire(rows.first);
}

/// 把本地行翻成页面期望的 JSON 形状（`target_label` / `exam_date`），
/// 这样 `home_page` 不必区分「数据来自本地」还是「来自云端」。
Map<String, Object?> _profileToWire(Map<String, Object?> row) => <String, Object?>{
      'id': row['server_id'] ?? row['local_id'],
      'target_label': row['target_label'],
      'exam_date': row['exam_date'],
      'target_score': row['target_score'],
      'status': row['status'],
    };

/// T2：取某个考试目标下的第一个科目（建单页需要）。
///
/// 建单只需要「哪个科目」，列表页目前也只支持选第一个科目，所以不再提供
/// `loadSubjects` 全量接口 —— 等真的要做科目选择器时再加。
Future<Map<String, Object?>?> loadFirstSubject(String examProfileId) async {
  final Database db = await LocalDb.instance.database;
  final List<Map<String, Object?>> rows = await db.query(
    'subjects',
    where: 'exam_profile_id = ?',
    whereArgs: <Object?>[examProfileId],
    orderBy: 'created_at ASC, local_id ASC',
    limit: 1,
  );
  if (rows.isEmpty) return null;
  final Map<String, Object?> row = rows.first;
  return <String, Object?>{
    'id': row['server_id'] ?? row['local_id'],
    'name': row['name'],
    'kind': row['kind'],
  };
}
/// T3：某科目下的考点（建单页的下拉选项）。
///
/// 返回形状对齐云端 `GET /subjects/:id/knowledge-nodes` 的 items：
/// `{id, title, freq_tag, parent_id}`，这样页面不必区分来源。
Future<List<Map<String, Object?>>> loadKnowledgeNodes(String subjectId) async {
  final Database db = await LocalDb.instance.database;
  final List<Map<String, Object?>> rows = await db.query(
    'knowledge_nodes',
    where: 'subject_id = ?',
    whereArgs: <Object?>[subjectId],
    orderBy: 'created_at ASC, local_id ASC',
  );
  return rows
      .map((Map<String, Object?> row) => <String, Object?>{
            'id': row['server_id'] ?? row['local_id'],
            'title': row['title'],
            'freq_tag': row['freq_tag'],
            'parent_id': row['parent_id'],
          })
      .toList();
}

/// T4：缺陷单列表（带考点/科目名、动作、当前 round 的验证结果）。
///
/// [statuses] 为空表示全部；排序与云端一致（`created_at ASC, local_id ASC`）。
Future<List<DefectTicket>> loadDefectTickets(
  String userId, {
  List<String>? statuses,
}) async {
  final Database db = await LocalDb.instance.database;
  final List<String>? statusList = statuses;

  final String where = statusList != null && statusList.isNotEmpty
      ? 'dt.${Col.userId} = ? AND dt.${Col.status} IN (${List<String>.filled(statusList.length, '?').join(', ')})'
      : 'dt.${Col.userId} = ?';
  final List<Object?> args = <Object?>[userId, if (statusList != null) ...statusList];

  final List<Map<String, Object?>> rows = await db.rawQuery(
    '''SELECT dt.*,
              kn.title   AS knowledge_node_title,
              kn.freq_tag AS knowledge_node_freq_tag,
              sub.name   AS subject_name
         FROM defect_tickets dt
         LEFT JOIN knowledge_nodes kn ON kn.local_id = dt.knowledge_node_id
         LEFT JOIN subjects sub       ON sub.local_id = kn.subject_id
        WHERE $where
        ORDER BY dt.created_at ASC, dt.local_id ASC''',
    args,
  );
  if (rows.isEmpty) return const <DefectTicket>[];

  final List<String> ticketIds =
      rows.map((Map<String, Object?> r) => r['local_id']! as String).toList(growable: false);

  // 一次取回所有子行再在内存分组：N+1 查询在 100 单 × 3 子表上就是 300 次往返。
  final Map<String, List<Map<String, Object?>>> verifications =
      await _groupBy(db, 'verifications', ticketIds);
  final Map<String, List<Map<String, Object?>>> actions = await _groupBy(db, 'actions', ticketIds);

  return rows
      .map((Map<String, Object?> r) => _ticketFromRow(
            r,
            verifications[r['local_id']] ?? const <Map<String, Object?>>[],
            actions[r['local_id']] ?? const <Map<String, Object?>>[],
          ))
      .toList(growable: false);
}

Future<Map<String, List<Map<String, Object?>>>> _groupBy(
  Database db,
  String table,
  List<String> ticketIds,
) async {
  final String placeholders = List<String>.filled(ticketIds.length, '?').join(', ');
  final List<Map<String, Object?>> rows = await db.query(
    table,
    where: '${Col.defectTicketLocalId} IN ($placeholders)',
    whereArgs: ticketIds.cast<Object?>(),
    orderBy: 'created_at ASC, local_id ASC',
  );
  final Map<String, List<Map<String, Object?>>> out = <String, List<Map<String, Object?>>>{};
  for (final Map<String, Object?> row in rows) {
    final String key = row[Col.defectTicketLocalId]! as String;
    (out[key] ??= <Map<String, Object?>>[]).add(row);
  }
  return out;
}

/// 本地行 → 页面模型。字段口径与 `defect_api.dart:95 _ticketFromJson` 保持一致
/// （同样的兜底文案、同样只取当前 round 的验证结果），否则同一张单在
/// 「本地渲染」与「刷新后渲染」之间会跳变。
DefectTicket _ticketFromRow(
  Map<String, Object?> row,
  List<Map<String, Object?>> verifications,
  List<Map<String, Object?>> actions,
) {
  final String? nodeId = text(row['knowledge_node_id']);
  final String title = text(row['knowledge_node_title']) ??
      (nodeId == null ? '未关联考点' : '考点 ${nodeId.substring(0, 8)}');
  final int round = asInt(row['verification_round'], 1) ?? 1;

  final Map<String, VerifyResult> results = <String, VerifyResult>{};
  for (final Map<String, Object?> v in verifications) {
    if ((asInt(v['round'], 1) ?? 1) != round) continue;
    final String? stage = text(v['stage'])?.toUpperCase();
    if (stage == null) continue;
    results[stage] = VerifyResult.fromWire(text(v['result']) ?? 'pending');
  }

  final DateTime created = parseLocalTime(row['created_at'])?.toLocal() ?? DateTime.now();

  return DefectTicket(
    id: (row['server_id'] ?? row['local_id'])! as String,
    qType: text(row['q_type']) ?? '未分类题型',
    errorLayer: text(row['error_layer']) ?? '未归因',
    errorCause: text(row['error_cause']) ?? '尚未填写归因说明',
    priority: DefectPriority.fromWire(text(row['priority'])),
    status: DefectStatus.fromWire(text(row['status']) ?? 'DRAFT'),
    verificationRound: round,
    reopenCount: asInt(row['reopen_count'], 0) ?? 0,
    createdAt: created,
    knowledgeNodeId: nodeId ?? '',
    knowledgeNodeTitle: title,
    subjectName: text(row['subject_name']) ?? '',
    actions: actions
        .map((Map<String, Object?> a) => DefectAction(
              id: (a['server_id'] ?? a['local_id'])! as String,
              content: text(a['content']) ?? '',
              done: (asInt(a['done'], 0) ?? 0) != 0,
              // R4a：动作行的乐观锁版本号是独立的一套，不能用缺陷单的 version。
              version: asInt(a['version'], 1) ?? 1,
            ))
        .toList(growable: false),
    v1: results['V1'] ?? VerifyResult.pending,
    v2: results['V2'] ?? VerifyResult.pending,
    v3: results['V3'] ?? VerifyResult.pending,
    statusHistory: <StatusEvent>[
      StatusEvent(status: DefectStatus.draft, at: created),
      StatusEvent(
        status: DefectStatus.fromWire(text(row['status']) ?? 'DRAFT'),
        at: parseLocalTime(row['updated_at'])?.toLocal() ?? created,
      ),
    ],
    version: asInt(row['version'], 1) ?? 1,
  );
}

/// T4 + T6：待验证任务（V1/V2/V3），urgency 本地复算。
///
/// 进入时间由 `listVerifiableWithEnteredAt` 的 SQL 复现后端 `ENTERED_AT_SQL`：
/// V2/V3 取「上一阶段 pass 的 created_at」，V1 退化用 `updated_at`。
Future<List<VerificationTask>> loadVerificationTasks(
  String userId, {
  String? stage,
  String? urgency,
}) async {
  final Database db = await LocalDb.instance.database;
  final List<Map<String, Object?>> rows =
      await LocalDaos.defectTickets.listVerifiableWithEnteredAt(db, userId);

  final Map<String, String> nodeTitles = await _nodeTitleMap(db);
  final DateTime now = DateTime.now();

  final List<VerificationTask> out = <VerificationTask>[];
  for (final Map<String, Object?> row in rows) {
    final String status = text(row['status']) ?? 'V1';
    if (stage != null && stage.isNotEmpty && stage.toUpperCase() != status) continue;

    final int window = windowDaysFor(status);
    // entered_at 由 SQL 的 COALESCE(上一阶段 pass, updated_at) 保证非空；
    // updated_at 在本地是 NOT NULL，所以这里 `!` 是安全的。
    final UrgencyResult computed =
        computeUrgency(row['entered_at']!, window, now: now);
    if (urgency != null && urgency.isNotEmpty && urgency != computed.urgency) continue;

    final String? nodeId = text(row['knowledge_node_id']);
    final String title = text(row['knowledge_node_title']) ??
        nodeTitles[nodeId] ??
        (nodeId == null ? '未关联考点' : '考点 ${nodeId.substring(0, 8)}');

    out.add(
      VerificationTask.fromJson(<String, Object?>{
        'id': (row['server_id'] ?? row['local_id'])! as String,
        'stage': status,
        'verification_round': row['verification_round'],
        'reopen_count': row['reopen_count'],
        'knowledge_node_title': title,
        'knowledge_node_freq_tag': row['knowledge_node_freq_tag'],
        'subject_name': row['subject_name'],
        'q_type': row['q_type'],
        ...computed.wire, // urgency / days_left / overdue_days / elapsed_days / window_days / entered_at / due_at
      }),
    );
  }
  return out;
}

/// 考点 id → 标题（列表 SQL 已 JOIN，这里只在个别查询缺列时兜底）。
Future<Map<String, String>> _nodeTitleMap(Database db) async {
  final List<Map<String, Object?>> rows = await db.query('knowledge_nodes', columns: <String>['local_id', 'title']);
  final Map<String, String> out = <String, String>{};
  for (final Map<String, Object?> row in rows) {
    final String? id = text(row['local_id']);
    final String? title = text(row['title']);
    if (id != null && title != null) out[id] = title;
  }
  return out;
}

/// 验证看板摘要：**与列表同一份数据源**，避免「列表 3 条、摘要说 4 条」。
///
/// 后端 `verificationSummary` 也是复用 `listVerificationTasks` 再聚合
/// （`server/repositories/defect_tickets.mjs:455`），这里保持同构。
Future<VerificationSummary> loadVerificationSummary(String userId) async {
  final List<VerificationTask> tasks = await loadVerificationTasks(userId);
  int overdue = 0;
  int dueSoon = 0;
  int normal = 0;
  final Map<String, int> byStage = <String, int>{'V1': 0, 'V2': 0, 'V3': 0};
  for (final VerificationTask t in tasks) {
    switch (t.urgency) {
      case Urgency.overdue:
        overdue++;
      case Urgency.dueSoon:
        dueSoon++;
      default:
        normal++;
    }
    byStage[t.stage] = (byStage[t.stage] ?? 0) + 1;
  }
  return VerificationSummary(
    total: tasks.length,
    overdue: overdue,
    dueSoon: dueSoon,
    normal: normal,
    byStage: byStage,
  );
}

/// 缺陷聚合统计：形状与 `GET /users/:id/defect-stats` 完全一致。
///
/// 为什么要照抄云端形状而不是让页面直接用 Map：`home_page` 的
/// `_distributionsFrom` / `_openCount` 已经在读这套键，本地换形状就要改两处
/// 渲染逻辑，还得保证两条路径渲染结果一致（设计 §6.4 R-7 的同类风险）。
Future<Map<String, Object?>> loadDefectStats(String userId) async {
  final Database db = await LocalDb.instance.database;

  final Map<String, int> byLayer = await LocalDaos.defectTickets.countOpenByLayer(db, userId);

  final List<Map<String, Object?>> statusRows = await db.rawQuery(
    'SELECT ${Col.status} AS s, COUNT(*) AS n FROM defect_tickets '
    'WHERE ${Col.userId} = ? GROUP BY 1',
    <Object?>[userId],
  );

  // 八态白名单预填 0：与 `server/repositories/defect_tickets.mjs:250` 的
  // `ALL_STATUSES` 一致，缺键会让前端读到 null 而不是 0。
  final Map<String, int> byStatus = <String, int>{
    'DRAFT': 0,
    'ANALYZED': 0,
    'ACTION_DONE': 0,
    'V1': 0,
    'V2': 0,
    'V3': 0,
    'REOPENED': 0,
    'CLOSED': 0,
  };
  for (final Map<String, Object?> row in statusRows) {
    final String? key = text(row['s']);
    final int? n = asInt(row['n'], 0);
    if (key != null && byStatus.containsKey(key) && n != null) byStatus[key] = n;
  }

  final int total = byStatus.values.fold<int>(0, (int a, int b) => a + b);
  final int closed = byStatus['CLOSED'] ?? 0;

  return <String, Object?>{
    'by_layer': byLayer.entries
        .map((MapEntry<String, int> e) => <String, Object?>{
              'error_layer': e.key,
              'count': e.value,
            })
        .toList(growable: false),
    'by_status': byStatus,
    'open_total': total - closed,
    'closed_total': closed,
    'total': total,
  };
}
