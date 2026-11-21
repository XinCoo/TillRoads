// DAO 层共用的常量与工具（本地优先架构 R1）。
//
// DAO 的职责边界（任务书 C4）：**只做 CRUD**。
//   · 不做版本校验（乐观锁的比较在服务端与 R4 的 pusher 里）；
//   · 不做冲突检测（R4）；
//   · 不做派生计算（urgency、统计在 R2 的 derived 层）；
//   · 不做同步（R3）。
//
// 所有 DAO 方法都接收 `DatabaseExecutor`（`Database` 与 `Transaction` 的共同父类型），
// 这样同一个 DAO 既能被页面直接调用，也能被包进 `db.transaction(...)` 复用。

/// `sync_state` 的取值（设计 §2.1）。
///
/// 命名与设计文档逐字一致，R3/R4 会直接比较这些整数。
abstract final class SyncState {
  /// 与云端一致，无待推送修改。
  static const int synced = 0;

  /// 本地新建，尚未推送（server_id 为 NULL）。
  static const int pendingCreate = 1;

  /// 本地改过，待推送。
  static const int dirty = 2;

  /// 本地删除，待推送（R1 不产生，R4 使用）。
  static const int pendingDelete = 3;

  /// 与服务端冲突，等待用户选择（R4 使用）。
  static const int conflict = 4;
}

/// `pending_operations.status` 的取值（设计 §2.3 T10）。
abstract final class PendingStatus {
  static const int pending = 0;
  static const int inflight = 1;
  static const int failedRetryable = 2;
  static const int conflict = 3;
  static const int dead = 4;

  /// 已出队的行在 R1 里**直接物理删除**（`markDone`）。
  ///
  /// 为什么不留 `done` 状态：队列的唯一用途是「还没推送成功的操作」，
  /// 留历史会让 `listPending()` 每次都要过滤，且表会无界增长。
  /// 需要审计时看 `AppLogger` 的日志。
}

/// 数据库列名常量（避免手写字符串拼错）。
///
/// 只列三张核心表与队列表里最常被引用的列；其余列在 DAO 内直接写字符串，
/// 因为它们在单个方法里只出现一两次，抽常量反而增加阅读跳转。
abstract final class Col {
  static const String localId = 'local_id';
  static const String serverId = 'server_id';
  static const String syncState = 'sync_state';
  static const String createdAt = 'created_at';
  static const String updatedAt = 'updated_at';
  static const String version = 'version';

  // defect_tickets
  static const String userId = 'user_id';
  static const String status = 'status';
  static const String verificationRound = 'verification_round';

  // actions / verifications
  static const String defectTicketLocalId = 'defect_ticket_local_id';
  static const String stage = 'stage';
  static const String round = 'round';

  // pending_operations
  static const String opId = 'op_id';
  static const String entityType = 'entity_type';
  static const String entityLocalId = 'entity_local_id';
}

/// 当前时刻的 ISO 8601 UTC 字符串（本地所有时间列的统一格式，设计 §2.1）。
String nowIso() => DateTime.now().toUtc().toIso8601String();

/// 把任意时间/Dart 值转成本地库可存的形态。
///
/// 只处理三种：`DateTime` → ISO 8601 UTC 字符串、`bool` → 0/1、`Enum` → 名称。
/// 其余原样返回（TEXT/INTEGER/REAL/NULL 由 sqflite 自己映射）。
Object? toLocalValue(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is bool) return value ? 1 : 0;
  if (value is Enum) return value.name;
  return value;
}

/// 对一整行做 [toLocalValue] 归一化（insert/update 前调用）。
Map<String, Object?> normalizeRow(Map<String, Object?> row) {
  final Map<String, Object?> out = <String, Object?>{};
  row.forEach((String key, Object? value) {
    out[key] = toLocalValue(value);
  });
  return out;
}

/// `list()` 方法的通用参数：等值过滤 + 排序 + 分页。
///
/// 刻意只支持等值过滤（任务书 C1 的「带简单过滤」）：复杂查询（JOIN、GROUP BY）
/// 在 R2 接页面时按实际需要再写，避免现在猜错索引。
class LocalQuery {
  const LocalQuery({
    this.where = const <String, Object?>{},
    this.orderBy,
    this.limit,
    this.offset,
  });

  /// 列名 → 值。值为 null 时不参与过滤（SQL 里 `IS NULL` 需要显式写）。
  final Map<String, Object?> where;
  final String? orderBy;
  final int? limit;
  final int? offset;

  /// 拼 `WHERE` 子句与参数。空过滤返回 (null, [])。
  (String?, List<Object?>) buildWhere() {
    if (where.isEmpty) return (null, const <Object?>[]);
    final List<String> clauses = <String>[];
    final List<Object?> args = <Object?>[];
    where.forEach((String column, Object? value) {
      clauses.add('$column = ?');
      args.add(toLocalValue(value));
    });
    return (clauses.join(' AND '), args);
  }
}
