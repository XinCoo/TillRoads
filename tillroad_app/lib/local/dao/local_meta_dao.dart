// T11 替代表 `local_meta` 的 DAO（本地优先架构 R1）。
//
// 与 [SyncTableDao] 的区别：这张表是通用 key/value，没有 local_id/server_id/version，
// 所以不继承那个基类，方法名也按任务书 C2 的要求用 getMeta/setMeta/deleteMeta。

import 'package:sqflite/sqflite.dart';

import 'dao_base.dart';

/// `local_meta` 的键名常量。
///
/// 前缀约定（见 local_schema.dart 文件头）：
///   · `token_fingerprint` / `schema_version` / `last_sync_at` 是单值键；
///   · `sync.<resource>.<field>` 是每个资源的同步水位（替代设计文档的 T11 表）。
abstract final class MetaKey {
  /// 当前 token 的指纹（sha256 前 16 位）。换账号必须清库，否则数据串号（设计 §5）。
  static const String tokenFingerprint = 'token_fingerprint';

  /// 本地 schema 版本（与 `kLocalSchemaVersion` 冗余存一份，便于排查设备上的旧库）。
  static const String schemaVersion = 'schema_version';

  /// 最近一次同步成功时间（ISO 8601 UTC）。
  static const String lastSyncAt = 'last_sync_at';

  /// 拼 `sync.<resource>.<field>` 形式的键。
  static String sync(String resource, String field) => 'sync.$resource.$field';
}

/// `local_meta` 表 DAO。
class LocalMetaDao {
  const LocalMetaDao();

  static const String table = 'local_meta';

  /// 读一个键（不存在返回 null）。
  Future<String?> getMeta(DatabaseExecutor db, String key) async {
    final List<Map<String, Object?>> rows = await db.query(
      table,
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// 写一个键（存在即覆盖）。
  Future<void> setMeta(DatabaseExecutor db, String key, String? value) async {
    await db.insert(
      table,
      <String, Object?>{
        'key': key,
        'value': value,
        'updated_at': nowIso(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 批量写（一次同步结束时把多个水位一起落盘，走单事务）。
  Future<void> setAll(DatabaseExecutor db, Map<String, String?> values) async {
    if (values.isEmpty) return;
    final Batch batch = db.batch();
    final String ts = nowIso();
    values.forEach((String key, String? value) {
      batch.insert(
        table,
        <String, Object?>{'key': key, 'value': value, 'updated_at': ts},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    await batch.commit(noResult: true);
  }

  /// 删一个键（返回受影响行数）。
  Future<int> deleteMeta(DatabaseExecutor db, String key) {
    return db.delete(table, where: 'key = ?', whereArgs: <Object?>[key]);
  }

  /// 列出所有键（设置页的「同步诊断」会展示）。
  Future<List<Map<String, Object?>>> listAll(DatabaseExecutor db) {
    return db.query(table, orderBy: 'key ASC');
  }

  /// 列出某个前缀下的键（R3 用它一次取某资源的全部水位）。
  ///
  /// 用 `LIKE 'prefix%'` 而不是 `GLOB`：SQLite 的 LIKE 默认对 ASCII 不区分大小写，
  /// 我们的键全是小写 ASCII，行为确定。
  Future<Map<String, String?>> listByPrefix(DatabaseExecutor db, String prefix) async {
    final List<Map<String, Object?>> rows = await db.query(
      table,
      where: 'key LIKE ?',
      whereArgs: <Object?>['$prefix%'],
      orderBy: 'key ASC',
    );
    return <String, String?>{
      for (final Map<String, Object?> row in rows)
        row['key']! as String: row['value'] as String?,
    };
  }

  /// 清空（「清除所有数据」用）。
  Future<int> deleteAll(DatabaseExecutor db) => db.delete(table);
}
