// 通用 DAO 基类：所有「带 local_id / server_id 双键」或「server_id 单键」的表共用。
//
// 设计取舍（任务书 C1「每张表一个 DAO 文件（或合并为少量文件，你判断）」）：
//   6 张表（exam_profiles / subjects / knowledge_nodes / defect_tickets /
//   actions / verifications）的 CRUD 语义完全一致，只是表名与主键列不同。
//   为它们各写一份 120 行的 CRUD 只会产生 6 份需要同步修改的副本，
//   所以用「一个基类 + 6 个 4 行的子类」代替。真正有额外方法的表
//   （local_meta / pending_operations）单独写。
//
// 所有方法都接收 `DatabaseExecutor`，因此既可以直接传 `Database`，
// 也可以在 `db.transaction((txn) async { dao.insert(txn, row); })` 里传 `Transaction`。

import 'package:sqflite/sqflite.dart';

import 'dao_base.dart';

/// 只读列投影：指定要取的列（null = 全部）。
typedef Columns = List<String>?;

/// 带「同步元数据」的表的通用 CRUD。
///
/// 子类只需给出 [table] 与 [primaryKey]：
///   · 主键是 `local_id` 的表（可能离线创建）；
///   · 主键是 `server_id` 的表（纯云端生成）。
abstract class SyncTableDao {
  const SyncTableDao({required this.table, required this.primaryKey});

  /// 表名。
  final String table;

  /// 主键列名（`local_id` 或 `server_id`）。
  final String primaryKey;

  /// 插入一行（`ConflictAlgorithm.replace`）。
  ///
  /// 为什么用 replace：R3 的同步是「按 server_id upsert」，同一个 server_id
  /// 再来一次必须覆盖而不是报 UNIQUE 冲突。离线创建的行（server_id 为 NULL）
  /// 不受影响，因为唯一索引带 `WHERE server_id IS NOT NULL`。
  ///
  /// 返回受影响行数（sqflite 的 insert 返回 rowid，这里统一转成行数语义：
  /// 成功即 1）。
  Future<int> insert(DatabaseExecutor db, Map<String, Object?> row) async {
    await db.insert(
      table,
      normalizeRow(row),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return 1;
  }

  /// 批量插入（单事务 Batch，比循环 insert 快一个数量级）。
  Future<int> insertAll(DatabaseExecutor db, List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return 0;
    final Batch batch = db.batch();
    for (final Map<String, Object?> row in rows) {
      batch.insert(
        table,
        normalizeRow(row),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    final List<Object?> results = await batch.commit();
    return results.length;
  }

  /// 按主键查一行（未找到返回 null）。
  Future<Map<String, Object?>?> getByPk(DatabaseExecutor db, String pk) async {
    final List<Map<String, Object?>> rows = await db.query(
      table,
      where: '$primaryKey = ?',
      whereArgs: <Object?>[pk],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 按 `local_id` 查一行。
  ///
  /// 主键是 `server_id` 的表（mock_exams / review_cycles）调用它会拿
  /// `server_id = <值>` 的结果。刻意不抛错：R4 回填 server_id 时需要在两张键
  /// 之间自由切换，硬拦反而碍事。
  Future<Map<String, Object?>?> getByLocalId(DatabaseExecutor db, String localId) =>
      getByPk(db, localId);
  /// 按 `server_id` 查一行。
  ///
  /// 对主键就是 server_id 的表，等价于 [getByPk]。
  Future<Map<String, Object?>?> getByServerId(DatabaseExecutor db, String serverId) async {
    final List<Map<String, Object?>> rows = await db.query(
      table,
      where: '${Col.serverId} = ?',
      whereArgs: <Object?>[serverId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 条件列表查询（等值过滤 + 排序 + 分页）。
  Future<List<Map<String, Object?>>> list(
    DatabaseExecutor db, {
    Columns columns,
    LocalQuery query = const LocalQuery(orderBy: 'created_at ASC'),
  }) async {
    final (String?, List<Object?>) built = query.buildWhere();
    return db.query(
      table,
      columns: columns,
      where: built.$1,
      whereArgs: built.$2.isEmpty ? null : built.$2,
      orderBy: query.orderBy,
      limit: query.limit,
      offset: query.offset,
    );
  }

  /// 按主键更新（返回受影响行数；0 表示行不存在）。
  ///
  /// **不自动 +version**：本地 `version` 只在两种情况下变——服务端响应、
  /// 拉取结果（设计 §3.6 不变量 6）。DAO 若自作聪明递增，R4 的乐观锁基准就废了。
  Future<int> update(DatabaseExecutor db, String pk, Map<String, Object?> values) {
    return db.update(
      table,
      normalizeRow(values),
      where: '$primaryKey = ?',
      whereArgs: <Object?>[pk],
    );
  }

  /// 按主键删除（返回受影响行数）。
  Future<int> delete(DatabaseExecutor db, String pk) {
    return db.delete(
      table,
      where: '$primaryKey = ?',
      whereArgs: <Object?>[pk],
    );
  }

  /// 清空整表（R3 的对账与「清空本地库」用）。
  Future<int> deleteAll(DatabaseExecutor db) => db.delete(table);

  /// 只删「与云端一致」的行（保留待推送 / 冲突行）。
  ///
  /// R2 的回写用它而不是 [deleteAll]：整表清空会把 R4 之后离线新建、
  /// 还没拿到 server_id 的行一起删掉（那批行 sync_state = 1/2/4）。
  /// R2 阶段本地其实没有这类行，但先把语义定死，R4 接队列时不用回头改页面。
  Future<int> deleteSynced(DatabaseExecutor db) =>
      db.delete(table, where: '${Col.syncState} = 0');

  /// 只删「某个父实体下、且与云端一致」的子行。
  ///
  /// 子表（actions / verifications）回写必须用这个而不是 [deleteSynced]：
  /// 某张缺陷单没有动作时，若调整表 [deleteSynced] 会把**别的单**刚写进去的
  /// 动作一并抹掉（R2 首次填充实测：9 张单里 6 张无动作，于是 6 条真实动作
  /// 全被后处理的空列表删光，本地 actions 变成 0 行）。
  Future<int> deleteSyncedWhere(
    DatabaseExecutor db,
    String where,
    List<Object?> args,
  ) =>
      db.delete(
        table,
        where: '${Col.syncState} = 0 AND ($where)',
        whereArgs: args,
      );

  /// 总行数（设置页「本地行数」展示用）。
  Future<int> count(DatabaseExecutor db) async {
    final List<Map<String, Object?>> rows =
        await db.rawQuery('SELECT COUNT(*) AS n FROM $table');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// `sync_state <> 0` 的行数（R4 的「待推送 N」展示用）。
  Future<int> countUnsynced(DatabaseExecutor db) async {
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM $table WHERE ${Col.syncState} <> 0',
    );
    return (rows.first['n'] as int?) ?? 0;
  }
}
