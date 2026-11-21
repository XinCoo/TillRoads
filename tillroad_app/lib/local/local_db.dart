// 本地 SQLite 数据库的打开/关闭/单例（本地优先架构 R1）。
//
// 职责边界（刻意保持很薄）：
//   · 选数据库文件位置、打开连接、跑建表脚本、暴露 `database` 给 DAO；
//   · **不做**任何业务逻辑、不做同步、不判断平台（平台策略在调用方，见 R2）。
//
// 为什么单例：sqflite 的 `openDatabase` 本身会复用同一个文件句柄，但我们要保证
//   · `main()` 里 await 过一次之后，页面与 DAO 拿到的都是同一个 `Database`；
//   · 测试里能通过 [close] 彻底断开，再验证「重开后数据还在」。
//   用一个显式的单例比依赖 sqflite 的内部缓存更可控。

import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../config/local_config.dart';
import 'local_schema.dart';

/// 本地库门面。
///
/// 用法：
/// ```dart
/// final Database db = await LocalDb.instance.database;
/// await db.query('defect_tickets');
/// ```
class LocalDb {
  LocalDb._();

  /// 全局唯一实例。
  static final LocalDb instance = LocalDb._();

  Database? _db;

  /// 正在打开中的 Future：并发调用 [database] 只真正 open 一次。
  Future<Database>? _opening;

  /// 最近一次初始化失败的原因（供设置页/日志展示；成功时为 null）。
  String? lastError;

  /// 测试专用：覆盖 sqflite 的工厂与数据库路径。
  ///
  /// 生产代码绝不调用它。测试里用 `sqflite_common_ffi` 提供的
  /// `databaseFactoryFfi` + 内存/临时目录路径。
  static DatabaseFactory? debugFactoryOverride;
  static String? debugPathOverride;

  /// 拿到数据库连接（首次调用时打开并建表）。
  ///
  /// 失败时抛出原始异常——**降级由调用方决定**（`main()` 里 catch 后把
  /// `kLocalFirstEnabled` 置 false，见任务书 D2）。这里不吞异常，否则测试
  /// 无法区分「建表 SQL 写错」与「平台不支持」。
  Future<Database> get database {
    final Database? existing = _db;
    if (existing != null && existing.isOpen) return Future<Database>.value(existing);
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<Database> _open() async {
    final DatabaseFactory factory = debugFactoryOverride ?? databaseFactory;
    final String dir = await factory.getDatabasesPath();
    final String path = debugPathOverride ?? p.join(dir, kLocalDbFileName);

    final Database db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: kLocalSchemaVersion,
        onConfigure: (Database db) async {
          // 显式打开外键——即使我们**没有**声明任何 FOREIGN KEY（见 local_schema.dart
          // 的说明），保留这一行是为了：将来若要加约束，不必再改这里；
          // 且 sqflite 的默认值在各平台不一致，显式声明行为更可预期。
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (Database db, int version) async {
          final Batch batch = db.batch();
          for (final String statement in kLocalSchemaStatements) {
            batch.execute(statement);
          }
          await batch.commit(noResult: true);
        },
        onUpgrade: (Database db, int from, int to) async {
          // R1 只有 version 1，不存在升级路径。
          // 将来加迁移时：按 from→to 逐版本执行，**不要**写 `DROP TABLE` 重建
          // （本地库里有尚未推送的写操作，重建会丢队列）。
          assert(from < to, 'onUpgrade 只在版本上升时触发');
        },
      ),
    );

    _db = db;
    lastError = null;
    return db;
  }

  /// 关闭连接（测试与「重建本地库」用）。
  ///
  /// 生产路径里不需要主动调用：进程结束时 sqflite 会自动落盘。
  Future<void> close() async {
    final Database? db = _db;
    _db = null;
    _opening = null;
    if (db != null && db.isOpen) await db.close();
  }

  /// 当前是否已打开（不触发打开）。
  bool get isOpen => _db?.isOpen ?? false;

  /// 自检：返回实际存在的表名与索引名。
  ///
  /// 供单元测试与设置页的「数据同步」分区使用（R2 起会显示在诊断里）。
  Future<LocalDbInventory> inspect() async {
    final Database db = await database;
    final List<Map<String, Object?>> tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    final List<Map<String, Object?>> indexes = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    return LocalDbInventory(
      tables: tables.map((Map<String, Object?> r) => r['name']! as String).toList(growable: false),
      indexes: indexes.map((Map<String, Object?> r) => r['name']! as String).toList(growable: false),
    );
  }
}

/// [LocalDb.inspect] 的返回值。
class LocalDbInventory {
  const LocalDbInventory({required this.tables, required this.indexes});

  final List<String> tables;
  final List<String> indexes;

  /// 缺失的表（期望 [kLocalTableNames] 全覆盖）。
  List<String> get missingTables =>
      kLocalTableNames.where((String t) => !tables.contains(t)).toList(growable: false);

  /// 缺失的索引（期望 [kLocalIndexNames] 全覆盖）。
  List<String> get missingIndexes =>
      kLocalIndexNames.where((String i) => !indexes.contains(i)).toList(growable: false);

  @override
  String toString() =>
      'LocalDbInventory(tables=${tables.length}, indexes=${indexes.length}, '
      'missingTables=$missingTables, missingIndexes=$missingIndexes)';
}
