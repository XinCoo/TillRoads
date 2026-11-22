// 写队列生产（R4a 任务 B）：把五个写操作变成「本地立即生效 + 入队待推送」。
//
// 为什么需要这一层：R2 之后读操作已经秒出，但只要断网就没法建单 / 归因 / 标记动作 /
// 进入验证 / 提交验证 —— 而这五个动作恰好是用户在地铁、电梯里最想做的事。
// R4a 把它们改成：先把结果写进本地 SQLite（用户立刻看到变化），再把「要发给云端
// 的那一条请求」记进 `pending_operations`，联网后由 `push_engine.dart` 按序推送。
//
// 三条硬性设计约束（都来自设计文档 §3.2，实现时不要绕开）：
//   1. **本地主键与云端主键分离**。离线新建的单在云端还没有 id，所以本地生成
//      `local_id`；推送成功后才回填 `server_id`。**本地主键永不删除**，否则
//      actions / verifications 的 `defect_ticket_local_id`、队列 payload、页面里
//      持有的对象引用会同时失效。
//   2. **入队前先在本地跑状态机校验**（任务 A）。非法操作（DRAFT 直接提交 V1、
//      归因写「粗心」）在这里就抛 `LocalValidationException`，根本不落库 ——
//      否则本地写脏了还要等联网被后端 400 拒绝后再回滚。
//   3. **两条特殊标记用 payload 里的 `__` 前缀承载**，推送前剥掉：
//        · `__requires_online_refresh`：begin-verification 必须先 GET 最新 version
//          （后端两跳让 version +2，本地无法预测，否则必然 409）；
//        · `__action_local_id`：标记动作的路径里需要 actions 表的 server_id，
//          而离线新建的动作还没有它，只能先记本地 id，推送时再解析。
//      `__` 前缀是内部约定：`push_engine.dart` 的 `stripInternalKeys()` 负责剔除，
//      服务端永远不会看到这些键。

import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import 'dao/dao_base.dart';
import 'dao/pending_operations_dao.dart';
import 'dao/sync_table_dao.dart';
import 'dao/table_daos.dart';
import 'local_db.dart';
import 'local_queries.dart';
import 'local_state_machine.dart';

/// 生成一个 v4 UUID（本地主键用）。
///
/// 为什么不引 `uuid` 包：R4a 硬约束「不引新依赖」，而这里只需要一个不会碰撞的
/// 随机串 —— 用 `Random.secure()` 取 16 字节，按 RFC 4122 打上版本位即可。
/// 注意：它**不是**密码学用途，也刻意不用 `dart:math` 的伪随机（那样同一毫秒
/// 创建的两条会在不同进程里撞车）。
String newLocalId() {
  final Random rng = Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((int b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// 入队结果。
class WriteQueueResult {
  const WriteQueueResult({
    required this.ticketLocalId,
    required this.opId,
    required this.status,
  });

  /// 缺陷单的本地主键（页面后续操作都用它定位，不再依赖 server_id）。
  final String ticketLocalId;

  /// 队列行自增 id（调试与日志用）。
  final int opId;

  /// 乐观更新后的单状态（`DRAFT`/`ANALYZED`/`V1`/`V2`/`V3`/`REOPENED`/`CLOSED`）。
  final String status;

  @override
  String toString() => 'WriteQueueResult($ticketLocalId, op#$opId, $status)';
}

/// 五个写操作的入队入口。
///
/// 每个方法都是「一个事务内完成：校验 → 写本地实体 → 写队列」，任一步失败整体回滚，
/// 不会出现「本地改了但队列没记」的半成品状态。
abstract final class WriteQueue {
  WriteQueue._();

  /// 建单（任务 B2 的第一条路径）。
  ///
  /// 校验策略（与后端 `create` 一致）：
  ///   · 带了 `errorLayer` → 视为「建单即归因」，走完整 `assertAnalyzable`；
  ///   · 没带 → 建 DRAFT 存草稿，只挡禁用语（否则后续 analyze 一定失败）。
  static Future<WriteQueueResult> enqueueCreateDefect({
    required String userId,
    required String examProfileId,
    required String qType,
    required String errorCause,
    String? errorLayer,
    String? knowledgeNodeId,
    String? priority,
    List<String> actions = const <String>[],
  }) async {
    final String? layer = errorLayer?.trim();
    final String cause = errorCause.trim();
    final bool analyzable = layer != null && layer.isNotEmpty;
    if (analyzable) {
      assertAnalyzable(status: 'DRAFT', errorLayer: layer, errorCause: cause);
    } else if (cause.isNotEmpty) {
      assertNoForbiddenPhrase(cause);
    }

    final List<String> cleanedActions = actions
        .map((String a) => a.trim())
        .where((String a) => a.isNotEmpty)
        .toList(growable: false);

    final Database db = await LocalDb.instance.database;
    final String ticketLocalId = newLocalId();
    final String now = nowIso();
    final String status = analyzable ? 'ANALYZED' : 'DRAFT';

    return db.transaction<WriteQueueResult>((Transaction txn) async {
      await _ticketDao.insert(txn, <String, Object?>{
        Col.localId: ticketLocalId,
        Col.serverId: null,
        Col.syncState: SyncState.pendingCreate,
        Col.userId: userId,
        'exam_profile_id': examProfileId,
        'knowledge_node_id': (knowledgeNodeId?.trim().isEmpty ?? true)
            ? null
            : knowledgeNodeId!.trim(),
        'question_id': null,
        'q_type': qType,
        'error_layer': analyzable ? layer : null,
        'error_cause': cause.isEmpty ? null : cause,
        'priority': (priority?.trim().isEmpty ?? true) ? null : priority,
        'status': status,
        Col.verificationRound: 1,
        'reopen_count': 0,
        'reopen_reason': null,
        'closed_at': null,
        Col.createdAt: now,
        Col.updatedAt: now,
        Col.version: 1,
      });

      final List<Map<String, Object?>> actionRows = <Map<String, Object?>>[];
      for (final String content in cleanedActions) {
        actionRows.add(<String, Object?>{
          Col.localId: newLocalId(),
          Col.serverId: null,
          Col.syncState: SyncState.pendingCreate,
          Col.defectTicketLocalId: ticketLocalId,
          'content': content,
          'done': 0,
          'due': null,
          Col.createdAt: now,
          Col.updatedAt: now,
          Col.version: 1,
        });
      }
      if (actionRows.isNotEmpty) {
        await _actionDao.insertAll(txn, actionRows);
      }

      final int opId = await _enqueue(
        txn,
        entityLocalId: ticketLocalId,
        operation: 'POST',
        pathTemplate: '/defect-tickets',
        payload: <String, Object?>{
          'user_id': userId,
          'exam_profile_id': examProfileId,
          'q_type': qType,
          'error_cause': cause,
          if (analyzable) 'error_layer': layer,
          if (knowledgeNodeId != null && knowledgeNodeId.trim().isNotEmpty)
            'knowledge_node_id': knowledgeNodeId.trim(),
          if (priority != null && priority.trim().isNotEmpty)
            'priority': priority.trim(),
          if (cleanedActions.isNotEmpty) 'actions': cleanedActions,
          // 显式声明建出来的状态，避免服务端按「有没有 error_layer」二次猜测。
          'status': status,
        },
        baseVersion: null,
      );

      return WriteQueueResult(
        ticketLocalId: ticketLocalId,
        opId: opId,
        status: status,
      );
    });
  }

  /// 归因（DRAFT 补齐 → ANALYZED；REOPENED 重新归因 → ANALYZED 且 round+1）。
  static Future<WriteQueueResult> enqueueAnalyze({
    required String ticketId,
    required String errorLayer,
    required String errorCause,
    required int baseVersion,
  }) async {
    final Database db = await LocalDb.instance.database;

    return db.transaction<WriteQueueResult>((Transaction txn) async {
      final Map<String, Object?> row = await _requireTicket(txn, ticketId);
      final String localId = row[Col.localId]! as String;
      final String status = row['status']! as String;
      final int round = _intOf(row['verification_round']) ?? 1;

      // 状态机先行：DRAFT→ANALYZED 合法，REOPENED→ANALYZED 合法，其余（CLOSED 等）拒绝。
      assertAnalyzable(status: status, errorLayer: errorLayer, errorCause: errorCause);

      final bool reopened = status == 'REOPENED';
      final Map<String, Object?> patch = <String, Object?>{
        'error_layer': errorLayer,
        'error_cause': errorCause,
        'status': 'ANALYZED',
        Col.syncState: SyncState.dirty,
        Col.updatedAt: nowIso(),
        if (reopened) Col.verificationRound: round + 1,
      };
      await _ticketDao.update(txn, localId, patch);

      final int opId = await _enqueue(
        txn,
        entityLocalId: localId,
        operation: 'PATCH',
        pathTemplate: '/defect-tickets/{server_id}/analyze',
        payload: <String, Object?>{
          'error_layer': errorLayer,
          'error_cause': errorCause,
          'version': baseVersion,
          // 后端据此走 reanalyze（并要求当前确实是 REOPENED）。
          if (reopened) 'status': 'REOPENED',
        },
        baseVersion: baseVersion,
      );

      return WriteQueueResult(ticketLocalId: localId, opId: opId, status: 'ANALYZED');
    });
  }

  /// 标记动作完成（actionId 可以是本地 id，也可以是云端 id —— 内部会解析）。
  ///
  /// R4a 重要修正：这里**不再接收 ticket 的 baseVersion**。
  /// 后端 `PATCH /defect-tickets/:id/actions/:actionId` 的乐观锁作用在
  /// **actions 行自己的 version** 上（`server/repositories/actions.mjs`
  /// 的 `markDone` → `updateWithVersion({table:'actions', ...})`），
  /// 跟缺陷单的 version 是两套。之前客户端传 ticket.version，
  /// 只是因为两者碰巧相等才没炸；一张单两条动作、只标记其中一条时就会错位。
  /// 所以 base_version 一律从本地 action 行读，不再由调用方传。
  static Future<WriteQueueResult> enqueueMarkAction({
    required String ticketId,
    required String actionId,
    required bool done,
  }) async {
    final Database db = await LocalDb.instance.database;

    return db.transaction<WriteQueueResult>((Transaction txn) async {
      final Map<String, Object?> row = await _requireTicket(txn, ticketId);
      final String localId = row[Col.localId]! as String;

      final Map<String, Object?>? action =
          await _resolveAction(txn, localId, actionId);
      if (action == null) {
        throw LocalValidationException(
          'ACTION_NOT_FOUND',
          '找不到这条处理动作，请刷新后重试。',
          details: <String, Object?>{'actionId': actionId},
        );
      }
      final String actionLocalId = action[Col.localId]! as String;
      // 动作行自己的乐观锁版本号（R4a：不能用 ticket.version）。
      final int actionVersion = _intOf(action[Col.version]) ?? 1;

      await _actionDao.update(txn, actionLocalId, <String, Object?>{
        'done': done ? 1 : 0,
        Col.syncState: SyncState.dirty,
        Col.updatedAt: nowIso(),
      });
      // 单本身的 updated_at 变了（详情页据此判断「刚操作过」），但版本不变：
      // 云端 `actions.markDone` 只写 actions 表，缺陷单 version 不动。
      await _ticketDao.update(txn, localId, <String, Object?>{
        Col.updatedAt: nowIso(),
      });

      final int opId = await _enqueue(
        txn,
        entityLocalId: localId,
        operation: 'PATCH',
        pathTemplate: '/defect-tickets/{server_id}/actions/{action_server_id}',
        payload: <String, Object?>{
          'done': done,
          'version': actionVersion,
          // 推送前解析成 server_id，然后被 stripInternalKeys 剔除。
          '__action_local_id': actionLocalId,
        },
        baseVersion: actionVersion,
      );

      return WriteQueueResult(
        ticketLocalId: localId,
        opId: opId,
        status: row['status']! as String,
      );
    });
  }

  /// 进入验证（ACTION_DONE → V1，云端一步两跳，本地只乐观前进到 V1）。
  static Future<WriteQueueResult> enqueueBeginVerification({
    required String ticketId,
    required int baseVersion,
  }) async {
    final Database db = await LocalDb.instance.database;

    return db.transaction<WriteQueueResult>((Transaction txn) async {
      final Map<String, Object?> row = await _requireTicket(txn, ticketId);
      final String localId = row[Col.localId]! as String;
      final String status = row['status']! as String;

      // 门禁：至少一条动作且全部完成（与后端 actions.assertAllDone 同口径）。
      final List<Map<String, Object?>> actionRows =
          await _actionDao.listByTicket(txn, localId);
      assertCanBeginVerification(
        actionRows
            .map((Map<String, Object?> a) => LocalActionState(
                  content: (a['content'] as String?) ?? '',
                  done: (a['done'] as int?) == 1,
                ))
            .toList(growable: false),
      );
      assertBeginVerification(status);

      await _ticketDao.update(txn, localId, <String, Object?>{
        'status': 'V1',
        Col.syncState: SyncState.dirty,
        Col.updatedAt: nowIso(),
      });

      final int opId = await _enqueue(
        txn,
        entityLocalId: localId,
        operation: 'PATCH',
        pathTemplate: '/defect-tickets/{server_id}/begin-verification',
        payload: <String, Object?>{
          'version': baseVersion,
          // 两跳 → 云端 version +2；本地不能预测，推送前必须先 GET 最新版本。
          '__requires_online_refresh': true,
        },
        baseVersion: baseVersion,
      );

      return WriteQueueResult(ticketLocalId: localId, opId: opId, status: 'V1');
    });
  }

  /// 提交验证（pass → 下一阶段 / V3 pass → CLOSED；fail → REOPENED 且 reopen_count+1）。
  static Future<WriteQueueResult> enqueueSubmitVerification({
    required String ticketId,
    required String stage,
    required String verifyType,
    required String result,
    required int baseVersion,
    String? questionId,
    String? evidence,
  }) async {
    final Database db = await LocalDb.instance.database;

    return db.transaction<WriteQueueResult>((Transaction txn) async {
      final Map<String, Object?> row = await _requireTicket(txn, ticketId);
      final String localId = row[Col.localId]! as String;
      final String status = row['status']! as String;
      final int round = _intOf(row[Col.verificationRound]) ?? 1;
      final int reopenCount = _intOf(row['reopen_count']) ?? 0;

      validateVerifyType(stage: stage, verifyType: verifyType);
      final VerificationDecision decision = applyVerification(
        LocalTicketState(
          status: status,
          reopenCount: reopenCount,
          verificationRound: round,
        ),
        stage,
        result,
      );

      // 同单同阶段同轮次只能有一条（本地唯一索引会拦，先给出可读错误）。
      final Map<String, Object?>? dup =
          await _verificationDao.findByStageRound(txn, localId, stage, round);
      if (dup != null) {
        throw LocalValidationException(
          'DUPLICATE_VERIFICATION',
          '第 $round 轮的 $stage 验证已提交过，不能重复提交。',
          details: <String, Object?>{'stage': stage, 'round': round},
        );
      }

      final String now = nowIso();
      await _ticketDao.update(txn, localId, <String, Object?>{
        'status': decision.status,
        'reopen_count': decision.reopenCount,
        Col.syncState: SyncState.dirty,
        Col.updatedAt: now,
        if (decision.status == 'CLOSED') 'closed_at': now,
      });

      await _verificationDao.insert(txn, <String, Object?>{
        Col.localId: newLocalId(),
        Col.serverId: null,
        Col.syncState: SyncState.pendingCreate,
        Col.defectTicketLocalId: localId,
        Col.stage: stage,
        Col.round: round,
        'verify_type': verifyType,
        'question_id': (questionId?.trim().isEmpty ?? true)
            ? null
            : questionId!.trim(),
        'result': result,
        'evidence': (evidence?.trim().isEmpty ?? true) ? null : evidence!.trim(),
        'verified_at': now,
        Col.createdAt: now,
        Col.version: 1,
      });

      final int opId = await _enqueue(
        txn,
        entityLocalId: localId,
        operation: 'POST',
        pathTemplate: '/defect-tickets/{server_id}/verifications',
        payload: <String, Object?>{
          'stage': stage,
          'result': result,
          'verify_type': verifyType,
          'version': baseVersion,
          if (questionId != null && questionId.trim().isNotEmpty)
            'question_id': questionId.trim(),
          if (evidence != null && evidence.trim().isNotEmpty)
            'evidence': evidence.trim(),
        },
        baseVersion: baseVersion,
      );

      return WriteQueueResult(
        ticketLocalId: localId,
        opId: opId,
        status: decision.status,
      );
    });
  }

  // ─────────────────────────── 内部工具 ───────────────────────────

  static const DefectTicketsDao _ticketDao = LocalDaos.defectTickets;
  static const ActionsDao _actionDao = LocalDaos.actions;
  static const VerificationsDao _verificationDao = LocalDaos.verifications;

  /// 页面传进来的 id 可能是 `server_id`（已同步的单）或 `local_id`（离线新建的单）。
  static Future<Map<String, Object?>> _requireTicket(
    DatabaseExecutor db,
    String ticketId,
  ) async {
    final Map<String, Object?>? byLocal = await _ticketDao.getByLocalId(db, ticketId);
    if (byLocal != null) return byLocal;
    final Map<String, Object?>? byServer = await _ticketDao.getByServerId(db, ticketId);
    if (byServer != null) return byServer;
    throw LocalValidationException(
      'TICKET_NOT_FOUND',
      '本地找不到这张缺陷单，请下拉刷新后重试。',
      details: <String, Object?>{'ticketId': ticketId},
    );
  }

  static Future<Map<String, Object?>?> _resolveAction(
    DatabaseExecutor db,
    String ticketLocalId,
    String actionId,
  ) async {
    final List<Map<String, Object?>> actions =
        await _actionDao.listByTicket(db, ticketLocalId);
    for (final Map<String, Object?> a in actions) {
      if (a[Col.localId] == actionId || a[Col.serverId] == actionId) return a;
    }
    return null;
  }

  static Future<int> _enqueue(
    DatabaseExecutor db, {
    required String entityLocalId,
    required String operation,
    required String pathTemplate,
    required Map<String, Object?> payload,
    required int? baseVersion,
  }) {
    return LocalDaos.pending.enqueue(
      db,
      PendingOperation(
        opId: 0, // AUTOINCREMENT 会覆盖
        entityType: 'defect_ticket',
        entityLocalId: entityLocalId,
        operation: operation,
        pathTemplate: pathTemplate,
        payload: jsonEncode(payload),
        baseVersion: baseVersion,
        createdAt: nowIso(),
      ),
    );
  }

  static int? _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// 页面用的辅助查询：某个单当前是否有待推送 / 冲突。
///
/// 放在这个文件而不是 `local_queries.dart`，是因为它只服务写路径的 UI 反馈：
/// 列表页的「待同步」角标、详情页的冲突 banner 都从这里取。
abstract final class WriteQueueStatus {
  WriteQueueStatus._();

  /// 单 id（页面视角：`server_id ?? local_id`）→ `sync_state`。
  static Future<Map<String, int>> ticketSyncStates() async {
    final Database db = await LocalDb.instance.database;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT COALESCE(server_id, local_id) AS page_id, sync_state '
      'FROM defect_tickets WHERE sync_state <> 0',
    );
    final Map<String, int> out = <String, int>{};
    for (final Map<String, Object?> row in rows) {
      final Object? id = row['page_id'];
      final Object? state = row['sync_state'];
      if (id is String && state is int) out[id] = state;
    }
    return out;
  }

  /// 有 conflict 待裁决的单 id 集合（详情页橙色 banner 用）。
  static Future<Set<String>> ticketIdsInConflict() async {
    final Database db = await LocalDb.instance.database;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT DISTINCT COALESCE(dt.server_id, dt.local_id) AS page_id '
      'FROM pending_operations p '
      'JOIN defect_tickets dt ON dt.local_id = p.entity_local_id '
      'WHERE p.status = ?',
      <Object?>[PendingStatus.conflict],
    );
    final Set<String> out = <String>{};
    for (final Map<String, Object?> row in rows) {
      final Object? id = row['page_id'];
      if (id is String) out.add(id);
    }
    return out;
  }

  /// 该单是否有未完成操作（详情页「待同步 N 条」）。
  static Future<int> pendingOpCount(String ticketId) async {
    final Database db = await LocalDb.instance.database;
    final List<Map<String, Object?>> ticket = await db.query(
      'defect_tickets',
      columns: <String>[Col.localId],
      where: '${Col.localId} = ? OR ${Col.serverId} = ?',
      whereArgs: <Object?>[ticketId, ticketId],
      limit: 1,
    );
    if (ticket.isEmpty) return 0;
    final String localId = ticket.first[Col.localId]! as String;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM pending_operations '
      'WHERE entity_type = ? AND entity_local_id = ?',
      <Object?>['defect_ticket', localId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// 清掉某单的 conflict 操作（详情页点「刷新」后调用）。
  ///
  /// 只删**冲突**行：待推送的正常操作不能因为一次冲突被一起丢掉，用户刷新后
  /// 它们仍应继续推送（R4b 会做真正的字段级仲裁，这里只处理「用户选择了云端版本」）。
  static Future<int> clearConflicts(String ticketId) async {
    final Database db = await LocalDb.instance.database;
    final List<Map<String, Object?>> ticket = await db.query(
      'defect_tickets',
      columns: <String>[Col.localId],
      where: '${Col.localId} = ? OR ${Col.serverId} = ?',
      whereArgs: <Object?>[ticketId, ticketId],
      limit: 1,
    );
    if (ticket.isEmpty) return 0;
    final String localId = ticket.first[Col.localId]! as String;
    final int cleared = await db.delete(
      'pending_operations',
      where: 'entity_type = ? AND entity_local_id = ? AND status = ?',
      whereArgs: <Object?>['defect_ticket', localId, PendingStatus.conflict],
    );
    // 该单本地若还标着 conflict，回落成 synced，让角标消失。
    await db.update(
      'defect_tickets',
      <String, Object?>{Col.syncState: SyncState.synced},
      where: '${Col.localId} = ? AND ${Col.syncState} = ?',
      whereArgs: <Object?>[localId, SyncState.conflict],
    );
    return cleared;
  }
}
