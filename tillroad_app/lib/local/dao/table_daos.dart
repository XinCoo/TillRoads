// 8 张「同步表」的 DAO（本地优先架构 R1）。
//
// 为什么合并在一个文件里（任务书 C1 允许「合并为少量文件」）：
//   这 8 个类的公共 CRUD 全部继承自 [SyncTableDao]，子类只声明表名与主键列，
//   没有独立的业务逻辑。分成 8 个文件会产生 8 个各 15 行、看一眼就懂、但要在
//   目录树里翻 8 次的文件；合并后能一屏看清「本地到底有哪些表、主键是什么」。
//
// 额外方法只加**设计文档里明确要用的**（不多写猜的查询）：
//   · DefectTicketsDao.listByUser —— 设计 §4 列表页要按 user + 状态过滤
//   · DefectTicketsDao.listVerifiable —— 设计 §2.4 验证任务页的候选集
//   · VerificationsDao.findByStageRound —— 设计 §2.3 T6 的重复提交预检
//   · ActionsDao.listByTicket —— 设计 §2.3 T5 详情页读子表

import 'package:sqflite/sqflite.dart';

import 'dao_base.dart';
import 'local_meta_dao.dart';
import 'pending_operations_dao.dart';
import 'sync_table_dao.dart';

/// T1 `exam_profiles`。
class ExamProfilesDao extends SyncTableDao {
  const ExamProfilesDao() : super(table: 'exam_profiles', primaryKey: Col.localId);
}

/// T2 `subjects`。
class SubjectsDao extends SyncTableDao {
  const SubjectsDao() : super(table: 'subjects', primaryKey: Col.localId);

  /// 按考点档案列科目（设计 §2.3 T2 的 idx_sub_ep）。
  Future<List<Map<String, Object?>>> listByProfile(DatabaseExecutor db, String examProfileId) {
    return list(
      db,
      query: LocalQuery(
        where: <String, Object?>{'exam_profile_id': examProfileId},
        orderBy: 'created_at ASC, local_id ASC',
      ),
    );
  }
}

/// T3 `knowledge_nodes`。
class KnowledgeNodesDao extends SyncTableDao {
  const KnowledgeNodesDao() : super(table: 'knowledge_nodes', primaryKey: Col.localId);

  /// 按科目列考点（设计 §2.3 T3 的 idx_kn_subject）。
  Future<List<Map<String, Object?>>> listBySubject(DatabaseExecutor db, String subjectId) {
    return list(
      db,
      query: LocalQuery(
        where: <String, Object?>{'subject_id': subjectId},
        orderBy: 'created_at ASC, local_id ASC',
      ),
    );
  }
}

/// T4 `defect_tickets`（核心表）。
class DefectTicketsDao extends SyncTableDao {
  const DefectTicketsDao()
      : super(table: 'defect_tickets', primaryKey: Col.localId);

  /// 按用户 + 可选状态集合列出缺陷单。
  ///
  /// 排序**必须**是 `created_at ASC, local_id ASC`：服务端 `listByUser` 就是
  /// `ORDER BY dt.created_at ASC, dt.id ASC`（`server/repositories/defect_tickets.mjs:222`），
  /// 本地换顺序会导致「刚同步完列表跳一下」（设计 §2.3 T4 的说明）。
  Future<List<Map<String, Object?>>> listByUser(
    DatabaseExecutor db,
    String userId, {
    List<String>? statuses,
    int? limit,
    int? offset,
  }) async {
    // 局部变量承接非空集合：`statuses!` 在闭包/三元里会被提升失效，
    // 先解包成局部 final 后 where 与 args 都能直接用，不必到处加 `!`。
    final List<String>? statusList = statuses;
    final bool hasStatuses = statusList != null && statusList.isNotEmpty;
    final String where = hasStatuses
        ? '${Col.userId} = ? AND ${Col.status} IN (${List<String>.filled(statusList.length, '?').join(', ')})'
        : '${Col.userId} = ?';
    final List<Object?> args = <Object?>[
      userId,
      if (statusList != null) ...statusList,
    ];
    return db.query(
      table,
      where: where,
      whereArgs: args,
      orderBy: 'created_at ASC, local_id ASC',
      limit: limit,
      offset: offset,
    );
  }

  /// 验证任务页的候选集：状态属于 V1/V2/V3（设计 §2.4 的「进行中」定义）。
  ///
  /// 只做**状态筛选**，不在这里算 urgency——窗口天数与当前时间有关，
  /// 属于派生层（R2 的 `verification_window.dart`）。
  Future<List<Map<String, Object?>>> listVerifiable(DatabaseExecutor db, String userId) {
    return listByUser(
      db,
      userId,
      statuses: const <String>['V1', 'V2', 'V3'],
    );
  }

  /// 未关闭单的归因分布：`{error_layer: count}`（R2 首页「缺陷分布」用）。
  ///
  /// 口径**逐字对齐**后端 `defectStats`（`server/repositories/defect_tickets.mjs:250`）：
  ///   · 只计未关闭（`status <> 'CLOSED'`）；
  ///   · 空串/纯空白归到 `unclassified`（服务端的 `UNCLASSIFIED_LAYER`）；
  ///   · `count DESC, layer ASC` —— 第二键是必需的，否则同数的行顺序不定，
  ///     首页那四行每刷一次就会换位置。
  Future<Map<String, int>> countOpenByLayer(DatabaseExecutor db, String userId) async {
    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''SELECT COALESCE(NULLIF(TRIM(error_layer), ''), 'unclassified') AS layer,
              COUNT(*) AS n
         FROM $table
        WHERE ${Col.userId} = ? AND ${Col.status} <> 'CLOSED'
        GROUP BY 1
        ORDER BY n DESC, 1 ASC''',
      <Object?>[userId],
    );
    final Map<String, int> out = <String, int>{};
    for (final Map<String, Object?> row in rows) {
      final Object? layer = row['layer'];
      final Object? n = row['n'];
      if (layer is String && n is int) out[layer] = n;
    }
    return out;
  }

  /// 待验证单 + 本地算出的「进入当前验证阶段时间」。
  ///
  /// 为什么需要它：urgency 的起点不是 `updated_at`，而是「上一次通过验证的时间」。
  /// 后端用 `ENTERED_AT_SQL`（`server/repositories/defect_tickets.mjs:352`）做这件事，
  /// 本地必须同口径复现，否则「云端说还剩 1 天、本地说已逾期」——
  /// 这是设计 §6.4 R-7 明确列出的风险。
  ///
  /// 取法（与后端一致）：
  ///   · V2 → 本 round 的 V1 `pass` 记录 `created_at`；
  ///   · V3 → 本 round 的 V2 `pass` 记录 `created_at`；
  ///   · V1（或上一阶段还没记录）→ 退化用 `updated_at`。
  /// 退化的偏差方向是「晚报而不误报逾期」：刚进 V1 时 updated_at 最接近真实时点。
  ///
  /// 返回的每行额外带 `entered_at`（ISO 8601 UTC 字符串，永不为 null）。
  Future<List<Map<String, Object?>>> listVerifiableWithEnteredAt(
    DatabaseExecutor db,
    String userId,
  ) async {
    return db.rawQuery(
      '''SELECT dt.*,
               COALESCE(
                 (SELECT v.created_at
                    FROM verifications v
                   WHERE v.defect_ticket_local_id = dt.local_id
                     AND v.round = dt.verification_round
                     AND v.result = 'pass'
                     AND v.stage = CASE dt.status
                                     WHEN 'V2' THEN 'V1'
                                     WHEN 'V3' THEN 'V2'
                                   END
                   ORDER BY v.created_at DESC, v.local_id DESC
                   LIMIT 1),
                 dt.updated_at
               ) AS entered_at
          FROM $table dt
         WHERE dt.${Col.userId} = ?
           AND dt.${Col.status} IN ('V1', 'V2', 'V3')
         ORDER BY dt.created_at ASC, dt.local_id ASC''',
      <Object?>[userId],
    );
  }
}

/// T5 `actions`。
class ActionsDao extends SyncTableDao {
  const ActionsDao() : super(table: 'actions', primaryKey: Col.localId);

  /// 按缺陷单列动作（设计 §2.3 T5 的 idx_act_ticket）。
  ///
  /// 父键是 `defect_ticket_local_id`（不是 server_id），这样离线建单时
  /// 子行无需等云端回填 server_id 就能落库。
  Future<List<Map<String, Object?>>> listByTicket(
    DatabaseExecutor db,
    String defectTicketLocalId,
  ) {
    return list(
      db,
      query: LocalQuery(
        where: <String, Object?>{Col.defectTicketLocalId: defectTicketLocalId},
        orderBy: 'created_at ASC, local_id ASC',
      ),
    );
  }
}

/// T6 `verifications`。
class VerificationsDao extends SyncTableDao {
  const VerificationsDao() : super(table: 'verifications', primaryKey: Col.localId);

  /// 按缺陷单列验证记录（同一 round 内的多 stage 会一起返回）。
  Future<List<Map<String, Object?>>> listByTicket(
    DatabaseExecutor db,
    String defectTicketLocalId,
  ) {
    return list(
      db,
      query: LocalQuery(
        where: <String, Object?>{Col.defectTicketLocalId: defectTicketLocalId},
        orderBy: 'round ASC, stage ASC, created_at ASC',
      ),
    );
  }

  /// 查「同单 + 同 stage + 同 round」的唯一一条。
  ///
  /// 云端 `idx_ver_dt_stage` 是唯一索引，重复提交返回 409（`submitVerification`
  /// 在 `server/repositories/defect_tickets.mjs:603`）。本地提前查一次，
  /// 让 R2 的提交表单能在发请求前就拦下重复（设计 §2.3 T6 的说明）。
  Future<Map<String, Object?>?> findByStageRound(
    DatabaseExecutor db,
    String defectTicketLocalId,
    String stage,
    int round,
  ) async {
    final List<Map<String, Object?>> rows = await db.query(
      table,
      where:
          '${Col.defectTicketLocalId} = ? AND ${Col.stage} = ? AND ${Col.round} = ?',
      whereArgs: <Object?>[defectTicketLocalId, stage, round],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }
}

/// T8 `mock_exams`（主键是 `server_id`：卷子永远在云端创建）。
class MockExamsDao extends SyncTableDao {
  const MockExamsDao() : super(table: 'mock_exams', primaryKey: Col.serverId);

  /// 按考点档案列卷子，新的在前（对齐服务端 `ORDER BY created_at DESC, id DESC`）。
  Future<List<Map<String, Object?>>> listByProfile(
    DatabaseExecutor db,
    String examProfileId, {
    int? limit,
    int? offset,
  }) {
    return list(
      db,
      query: LocalQuery(
        where: <String, Object?>{'exam_profile_id': examProfileId},
        orderBy: 'created_at DESC, server_id DESC',
        limit: limit,
        offset: offset,
      ),
    );
  }
}

/// T9 `review_cycles`（主键是 `server_id`：复盘在云端生成）。
class ReviewCyclesDao extends SyncTableDao {
  const ReviewCyclesDao() : super(table: 'review_cycles', primaryKey: Col.serverId);

  /// 按用户列复盘周期，新的在前（对齐服务端 `ORDER BY period DESC, created_at DESC`）。
  Future<List<Map<String, Object?>>> listByUser(
    DatabaseExecutor db,
    String userId, {
    int? limit,
    int? offset,
  }) {
    return list(
      db,
      query: LocalQuery(
        where: <String, Object?>{Col.userId: userId},
        orderBy: 'period DESC, created_at DESC, server_id DESC',
        limit: limit,
        offset: offset,
      ),
    );
  }
}

/// 全部同步表 DAO 的聚合入口。
///
/// 用途：R3 的对账要遍历所有表（`for (final dao in LocalDaos.all)`），
/// 测试也要一次拿到全部 DAO 做 CRUD 覆盖。单例化避免每次 new。
class LocalDaos {
  LocalDaos._();

  static const ExamProfilesDao examProfiles = ExamProfilesDao();
  static const SubjectsDao subjects = SubjectsDao();
  static const KnowledgeNodesDao knowledgeNodes = KnowledgeNodesDao();
  static const DefectTicketsDao defectTickets = DefectTicketsDao();
  static const ActionsDao actions = ActionsDao();
  static const VerificationsDao verifications = VerificationsDao();
  static const MockExamsDao mockExams = MockExamsDao();
  static const ReviewCyclesDao reviewCycles = ReviewCyclesDao();

  /// 全部 8 张同步表的 DAO（不含 local_meta 与 pending_operations，
  /// 它们不是「云端表的投影」，方法签名也不同）。
  static const List<SyncTableDao> all = <SyncTableDao>[
    examProfiles,
    subjects,
    knowledgeNodes,
    defectTickets,
    actions,
    verifications,
    mockExams,
    reviewCycles,
  ];

  /// T10 写队列（不实现推送，推送在 R4）。
  static const PendingOperationsDao pending = PendingOperationsDao();

  /// T11 替代品 local_meta（key/value 水位）。
  static const LocalMetaDao meta = LocalMetaDao();
}
