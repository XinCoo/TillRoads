// T10 `pending_operations` 的 DAO（本地优先架构 R1）。
//
// **R1 只做队列的存取，不做推送**（任务书硬约束：不实现写队列的推送，那是 R4）。
// 所以这里没有「发送」方法，只有入队/取队/标记结果——推送逻辑在 R4 的 pusher 里。
//
// 队列语义（设计 §3.2 / §3.6）：
//   · `op_id` 单调递增 = 全局发送顺序，同一实体的操作天然按入队顺序出队；
//   · `path_template` 存占位符（`/defect-tickets/{server_id}/analyze`），
//     因为入队时 server_id 可能还不存在（离线建单），推送时才替换；
//   · 失败保留在队里（`markFailed` 只改状态与重试时间，不删行）；
//   · 成功后**物理删除**（见 dao_base.dart 的 PendingStatus 注释）。

import 'package:sqflite/sqflite.dart';

import 'dao_base.dart';

/// 队列里一条待推送操作的不可变视图（R4 的 pusher 会用到）。
class PendingOperation {
  const PendingOperation({
    required this.opId,
    required this.entityType,
    required this.entityLocalId,
    required this.operation,
    required this.pathTemplate,
    required this.payload,
    this.baseVersion,
    this.status = PendingStatus.pending,
    this.retryCount = 0,
    this.nextRetryAt,
    this.lastError,
    required this.createdAt,
  });

  final int opId;
  final String entityType;
  final String entityLocalId;

  /// `POST` / `PATCH` / `DELETE`（对应云端 HTTP 方法）。
  final String operation;

  /// 带 `{server_id}` 等占位符的路径模板。
  final String pathTemplate;

  /// JSON 字符串；`{}` 表示无 body。
  final String payload;

  /// 乐观锁基准；null 表示服务端当时也不需要（如 POST 建单）。
  final int? baseVersion;

  final int status;
  final int retryCount;
  final String? nextRetryAt;
  final String? lastError;
  final String createdAt;

  /// 转成可直接 insert 的行。
  Map<String, Object?> toRow() => <String, Object?>{
        Col.entityType: entityType,
        Col.entityLocalId: entityLocalId,
        'operation': operation,
        'path_template': pathTemplate,
        'payload': payload,
        'base_version': baseVersion,
        'status': status,
        'retry_count': retryCount,
        'next_retry_at': nextRetryAt,
        'last_error': lastError,
        Col.createdAt: createdAt,
      };

  /// 从查询结果还原。
  factory PendingOperation.fromRow(Map<String, Object?> row) => PendingOperation(
        opId: row[Col.opId]! as int,
        entityType: row[Col.entityType]! as String,
        entityLocalId: row[Col.entityLocalId]! as String,
        operation: row['operation']! as String,
        pathTemplate: row['path_template']! as String,
        payload: (row['payload'] as String?) ?? '{}',
        baseVersion: row['base_version'] as int?,
        status: (row['status'] as int?) ?? PendingStatus.pending,
        retryCount: (row['retry_count'] as int?) ?? 0,
        nextRetryAt: row['next_retry_at'] as String?,
        lastError: row['last_error'] as String?,
        createdAt: (row[Col.createdAt] as String?) ?? '',
      );
}

/// `pending_operations` 表 DAO。
class PendingOperationsDao {
  const PendingOperationsDao();

  static const String table = 'pending_operations';

  /// 入队一条操作，返回自增的 `op_id`。
  Future<int> enqueue(DatabaseExecutor db, PendingOperation op) {
    return db.insert(
      table,
      <String, Object?>{
        ...op.toRow(),
        Col.createdAt: op.createdAt.isEmpty ? nowIso() : op.createdAt,
      },
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  /// 取待发送队列（按 `op_id` 升序 = 全局发送顺序）。
  ///
  /// [includeRetryable] 为 false 时只取 `status = 0` 的（首次尝试）；
  /// 为 true 时把 `failed_retryable` 也带上，由调用方再按 [PendingOperation.nextRetryAt]
  /// 过滤——把时间判断留在调用方，DAO 不注入 `DateTime.now()` 才可测。
  Future<List<PendingOperation>> listPending(
    DatabaseExecutor db, {
    bool includeRetryable = false,
    int? limit,
  }) async {
    final String statusClause = includeRetryable
        ? 'status IN (?, ?)'
        : 'status = ?';
    final List<Object?> args = includeRetryable
        ? <Object?>[PendingStatus.pending, PendingStatus.failedRetryable]
        : <Object?>[PendingStatus.pending];
    final List<Map<String, Object?>> rows = await db.query(
      table,
      where: statusClause,
      whereArgs: args,
      orderBy: '${Col.opId} ASC',
      limit: limit,
    );
    return rows.map(PendingOperation.fromRow).toList(growable: false);
  }

  /// 取某个实体的全部排队操作（R4 的「同实体队头阻塞」判断用）。
  Future<List<PendingOperation>> listByEntity(
    DatabaseExecutor db,
    String entityType,
    String entityLocalId,
  ) async {
    final List<Map<String, Object?>> rows = await db.query(
      table,
      where: '${Col.entityType} = ? AND ${Col.entityLocalId} = ?',
      whereArgs: <Object?>[entityType, entityLocalId],
      orderBy: '${Col.opId} ASC',
    );
    return rows.map(PendingOperation.fromRow).toList(growable: false);
  }

  /// 标记为发送中（防止并发 pusher 重复取同一条）。
  Future<int> markInflight(DatabaseExecutor db, int opId) {
    return db.update(
      table,
      <String, Object?>{'status': PendingStatus.inflight},
      where: '${Col.opId} = ?',
      whereArgs: <Object?>[opId],
    );
  }

  /// 成功出队：**物理删除**该行。
  Future<int> markDone(DatabaseExecutor db, int opId) {
    return db.delete(table, where: '${Col.opId} = ?', whereArgs: <Object?>[opId]);
  }

  /// 失败但可重试：记录错误 + 下一次重试时间，行保留在队列里。
  ///
  /// [retryCount] 由调用方传入新值（DAO 不读旧值再 +1，避免并发下丢更新）。
  Future<int> markFailed(
    DatabaseExecutor db,
    int opId, {
    required String error,
    int? retryCount,
    String? nextRetryAt,
  }) {
    return db.update(
      table,
      <String, Object?>{
        'status': PendingStatus.failedRetryable,
        'last_error': error,
        // Dart 3.8+ 的 null-aware 元素：值为 null 时整条键值对不写入，
        // 等价于旧写法 `if (x != null) 'k': x`，但更短且不会被 lint 提示。
        'retry_count': ?retryCount,
        'next_retry_at': ?nextRetryAt,
      },
      where: '${Col.opId} = ?',
      whereArgs: <Object?>[opId],
    );
  }

  /// 重试计数 +1（保留原状态以外的字段不动）。
  ///
  /// 与 [markFailed] 分开的原因：R4 需要「只加计数、不改状态」的中间态
  /// （例如网络抖动后立刻重试，不该把行标成 failed）。
  Future<int> incrementRetry(DatabaseExecutor db, int opId) {
    return db.rawUpdate(
      'UPDATE $table SET retry_count = retry_count + 1 WHERE ${Col.opId} = ?',
      <Object?>[opId],
    );
  }

  /// 标记为冲突（等用户在详情页/设置页裁决，R4）。
  Future<int> markConflict(DatabaseExecutor db, int opId, {required String error}) {
    return db.update(
      table,
      <String, Object?>{
        'status': PendingStatus.conflict,
        'last_error': error,
      },
      where: '${Col.opId} = ?',
      whereArgs: <Object?>[opId],
    );
  }

  /// 标记为死信（重试次数耗尽或不可恢复错误）。
  Future<int> markDead(DatabaseExecutor db, int opId, {required String error}) {
    return db.update(
      table,
      <String, Object?>{
        'status': PendingStatus.dead,
        'last_error': error,
      },
      where: '${Col.opId} = ?',
      whereArgs: <Object?>[opId],
    );
  }

  /// 队列长度（设置页「待同步 N 条」）。
  Future<int> count(DatabaseExecutor db) async {
    final List<Map<String, Object?>> rows =
        await db.rawQuery('SELECT COUNT(*) AS n FROM $table');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// 清空队列（「清除所有数据」用）。
  Future<int> deleteAll(DatabaseExecutor db) => db.delete(table);
}
