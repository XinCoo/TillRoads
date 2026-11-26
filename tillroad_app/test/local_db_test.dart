// 本地 SQLite 库地基的单元测试（本地优先架构 R1，任务书 E1–E5）。
//
// 为什么要 FFI：`sqflite` 在 `flutter test` 的宿主环境（Windows）没有平台实现，
// 直接调用会抛 `MissingPluginException`。`sqflite_common_ffi` 把同一套 Dart API
// 桥接到宿主原生的 sqlite3，行为与移动端一致（同样的 SQL、同样的 UNIQUE 语义）。
// 它只出现在 dev_dependencies 里，不进产物。
//
// 每个 test 之间必须重置 [LocalDb] 单例：它是全局状态，上一个用例留下的连接
// 会让下一个用例读到脏数据（且 sqlite 的临时文件句柄会锁住重开）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tillroad_app/local/local.dart';

void main() {
  // FFI 初始化只需一次，放在 setUpAll。
  setUpAll(() {
    sqfliteFfiInit();
    LocalDb.debugFactoryOverride = databaseFactoryFfi;
  });

  /// 每个用例一个独立的临时库文件（不用 inMemory：E5 要验证「关掉再打开数据还在」，
  /// 内存库一关就没了，测不出持久化）。
  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tillroad_local_test_');
    dbPath = p.join(tempDir.path, 'test.db');
    LocalDb.debugPathOverride = dbPath;
    await LocalDb.instance.close();
  });

  tearDown(() async {
    await LocalDb.instance.close();
    LocalDb.debugPathOverride = null;
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // ── E1 建表 ─────────────────────────────────────────────────────────────
  group('E1 建表', () {
    test('10 张表全部存在', () async {
      final LocalDbInventory inv = await LocalDb.instance.inspect();
      expect(inv.missingTables, isEmpty, reason: '缺少表：${inv.missingTables}');
      expect(inv.tables.length, kLocalTableNames.length);
      for (final String table in kLocalTableNames) {
        expect(inv.tables, contains(table));
      }
    });

    test('22 个索引全部存在', () async {
      final LocalDbInventory inv = await LocalDb.instance.inspect();
      expect(inv.missingIndexes, isEmpty, reason: '缺少索引：${inv.missingIndexes}');
      expect(inv.indexes.length, kLocalIndexNames.length);
    });

    test('用户表不含 sqlite_ 前缀的系统表', () async {
      final LocalDbInventory inv = await LocalDb.instance.inspect();
      expect(
        inv.tables.where((String t) => t.startsWith('sqlite_')),
        isEmpty,
      );
    });

    test('defect_tickets 不含 actions / verification_state / deleted_at 列', () async {
      final Database db = await LocalDb.instance.database;
      final List<Map<String, Object?>> cols =
          await db.rawQuery('PRAGMA table_info(defect_tickets)');
      final Set<String> names =
          cols.map((Map<String, Object?> c) => c['name']! as String).toSet();
      // 这 4 类列被设计文档明确要求「不落本地」（§2.3 T4）。
      expect(names, isNot(contains('actions')));
      expect(names, isNot(contains('verification_state')));
      expect(names, isNot(contains('deleted_at')));
      expect(names, isNot(contains('knowledge_node_title')));
      // 核心列必须在。
      expect(names, containsAll(<String>[
        'local_id',
        'server_id',
        'sync_state',
        'status',
        'verification_round',
        'version',
      ]));
    });
  });

  // ── E2 DAO 基础 CRUD ────────────────────────────────────────────────────
  //
  // 8 张同步表共用 [SyncTableDao] 的实现，所以这里用同一套 4 步
  // （insert → getByLocalId → update → delete）参数化跑一遍：
  // 任何一张表的表名/主键列写错都会在这里暴露。
  group('E2 DAO 基础 CRUD', () {
    /// 每张表的「最小可插入行」：只填 NOT NULL 列 + 主键。
    final Map<SyncTableDao, Map<String, Object?>> seed = <SyncTableDao, Map<String, Object?>>{
      LocalDaos.examProfiles: <String, Object?>{
        'local_id': 'ep-1',
        'server_id': 'ep-srv-1',
        'user_id': 'u-1',
        'target_label': '省考 · 行测',
        'version': 3,
      },
      LocalDaos.subjects: <String, Object?>{
        'local_id': 'sub-1',
        'server_id': 'sub-srv-1',
        'exam_profile_id': 'ep-srv-1',
        'name': '判断推理',
        'version': 1,
      },
      LocalDaos.knowledgeNodes: <String, Object?>{
        'local_id': 'kn-1',
        'server_id': 'kn-srv-1',
        'subject_id': 'sub-srv-1',
        'title': '充分必要条件',
        'version': 1,
      },
      LocalDaos.defectTickets: <String, Object?>{
        'local_id': 'dt-1',
        'server_id': 'dt-srv-1',
        'user_id': 'u-1',
        'status': 'ANALYZED',
        'error_layer': '概念不清',
        'version': 2,
      },
      LocalDaos.actions: <String, Object?>{
        'local_id': 'act-1',
        'server_id': 'act-srv-1',
        'defect_ticket_local_id': 'dt-1',
        'content': '重做 10 题',
        'done': false,
        'version': 1,
      },
      LocalDaos.verifications: <String, Object?>{
        'local_id': 'ver-1',
        'server_id': 'ver-srv-1',
        'defect_ticket_local_id': 'dt-1',
        'stage': 'V1',
        'round': 1,
        'result': 'pass',
        'version': 1,
      },
      // 主键是 server_id 的两张表：map 的 key 用 server_id 的值当「主键」。
      LocalDaos.mockExams: <String, Object?>{
        'server_id': 'me-srv-1',
        'exam_profile_id': 'ep-srv-1',
        'mode': 'module',
        'questions': '[]',
        'version': 1,
      },
      LocalDaos.reviewCycles: <String, Object?>{
        'server_id': 'rc-srv-1',
        'user_id': 'u-1',
        'cycle_type': 'weekly',
        'period': '2026-W47',
        'completed': false,
        'version': 1,
      },
    };

    /// 取该行的主键值（local_id 优先，否则 server_id）。
    String pkOf(SyncTableDao dao, Map<String, Object?> row) {
      final Object? pk = row[dao.primaryKey];
      expect(pk, isNotNull, reason: '${dao.table} 的种子缺少主键列 ${dao.primaryKey}');
      return pk! as String;
    }

    test('8 张表都能 insert → get → update → delete', () async {
      final Database db = await LocalDb.instance.database;

      for (final MapEntry<SyncTableDao, Map<String, Object?>> entry in seed.entries) {
        final SyncTableDao dao = entry.key;
        final Map<String, Object?> row = entry.value;
        final String pk = pkOf(dao, row);

        // insert
        expect(await dao.insert(db, row), 1, reason: '${dao.table} insert');

        // get（读到同一行，且 bool 已转成 0/1）
        final Map<String, Object?>? loaded = await dao.getByPk(db, pk);
        expect(loaded, isNotNull, reason: '${dao.table} getByPk');
        expect(loaded![dao.primaryKey], pk);

        // update：只改 version，验证按主键命中
        expect(
          await dao.update(db, pk, <String, Object?>{'version': 99}),
          1,
          reason: '${dao.table} update',
        );
        final Map<String, Object?>? updated = await dao.getByPk(db, pk);
        expect(updated!['version'], 99, reason: '${dao.table} version 未更新');

        // delete
        expect(await dao.delete(db, pk), 1, reason: '${dao.table} delete');
        expect(await dao.getByPk(db, pk), isNull, reason: '${dao.table} 删除后仍能读到');
      }
    });

    test('insertAll 批量插入并计数', () async {
      final Database db = await LocalDb.instance.database;
      final int n = await LocalDaos.defectTickets.insertAll(db, <Map<String, Object?>>[
        for (int i = 0; i < 5; i++)
          <String, Object?>{
            'local_id': 'dt-bulk-$i',
            'server_id': 'dt-bulk-srv-$i',
            'user_id': 'u-1',
            'status': 'ANALYZED',
            'version': 1,
          },
      ]);
      expect(n, 5);
      expect(await LocalDaos.defectTickets.count(db), 5);
    });

    test('bool 字段落库为 0/1', () async {
      final Database db = await LocalDb.instance.database;
      await LocalDaos.actions.insert(db, <String, Object?>{
        'local_id': 'act-b',
        'server_id': 'act-b-srv',
        'defect_ticket_local_id': 'dt-1',
        'content': '待办',
        'done': true,
      });
      final Map<String, Object?>? row =
          await LocalDaos.actions.getByPk(db, 'act-b');
      expect(row!['done'], 1, reason: 'bool true 必须存成整数 1');
    });

    test('DateTime 字段落库为 ISO 8601 UTC', () async {
      final Database db = await LocalDb.instance.database;
      final DateTime t = DateTime.utc(2026, 11, 21, 12, 30);
      await LocalDaos.defectTickets.insert(db, <String, Object?>{
        'local_id': 'dt-t',
        'server_id': 'dt-t-srv',
        'user_id': 'u-1',
        'status': 'DRAFT',
        'created_at': t,
      });
      final Map<String, Object?>? row =
          await LocalDaos.defectTickets.getByPk(db, 'dt-t');
      expect(row!['created_at'], '2026-11-21T12:30:00.000Z');
    });

    test('server_id 唯一索引拦截重复（NULL 不受限）', () async {
      final Database db = await LocalDb.instance.database;
      await LocalDaos.defectTickets.insert(db, <String, Object?>{
        'local_id': 'dt-u1',
        'server_id': 'dup-srv',
        'user_id': 'u-1',
        'status': 'DRAFT',
      });
      // 同一个 server_id 用 insert（replace）会覆盖，不会抛——这是 R3 upsert 需要的语义。
      await LocalDaos.defectTickets.insert(db, <String, Object?>{
        'local_id': 'dt-u2',
        'server_id': 'dup-srv',
        'user_id': 'u-1',
        'status': 'CLOSED',
      });
      final List<Map<String, Object?>> rows = await db.query(
        'defect_tickets',
        where: 'server_id = ?',
        whereArgs: <Object?>['dup-srv'],
      );
      expect(rows.length, 1, reason: 'server_id 唯一索引应让第二行覆盖第一行');

      // 两个 server_id 都为 NULL 的行必须共存（离线建单场景）。
      await LocalDaos.defectTickets.insert(db, <String, Object?>{
        'local_id': 'dt-null-1',
        'user_id': 'u-1',
        'status': 'DRAFT',
      });
      await LocalDaos.defectTickets.insert(db, <String, Object?>{
        'local_id': 'dt-null-2',
        'user_id': 'u-1',
        'status': 'DRAFT',
      });
      final List<Map<String, Object?>> nulls = await db.query(
        'defect_tickets',
        where: 'server_id IS NULL',
      );
      expect(nulls.length, 2, reason: '唯一索引带 WHERE server_id IS NOT NULL，NULL 应可重复');
    });
  });

  // ── 表特有的查询方法 ────────────────────────────────────────────────────
  group('DAO 专有查询', () {
    test('listByUser 按 user + 状态集合过滤，排序为 created_at ASC', () async {
      final Database db = await LocalDb.instance.database;
      await LocalDaos.defectTickets.insertAll(db, <Map<String, Object?>>[
        for (int i = 0; i < 3; i++)
          <String, Object?>{
            'local_id': 'dt-o-$i',
            'server_id': 'dt-o-srv-$i',
            'user_id': 'u-1',
            'status': i == 0 ? 'DRAFT' : 'ANALYZED',
            'created_at': '2026-11-2${i}T00:00:00.000Z',
          },
      ]);
      await LocalDaos.defectTickets.insert(db, <String, Object?>{
        'local_id': 'dt-other',
        'server_id': 'dt-other-srv',
        'user_id': 'u-2',
        'status': 'ANALYZED',
        'created_at': '2026-11-20T00:00:00.000Z',
      });

      final List<Map<String, Object?>> all =
          await LocalDaos.defectTickets.listByUser(db, 'u-1');
      expect(all.length, 3);
      expect(
        all.map((Map<String, Object?> r) => r['local_id']).toList(),
        <String>['dt-o-0', 'dt-o-1', 'dt-o-2'],
        reason: '必须按 created_at 升序（对齐服务端 ORDER BY created_at ASC）',
      );

      final List<Map<String, Object?>> analyzed = await LocalDaos.defectTickets
          .listByUser(db, 'u-1', statuses: <String>['ANALYZED']);
      expect(analyzed.length, 2);
      expect(analyzed.every((Map<String, Object?> r) => r['status'] == 'ANALYZED'),
          isTrue);
    });

    test('listVerifiable 只返回 V1/V2/V3', () async {
      final Database db = await LocalDb.instance.database;
      const List<String> statuses = <String>[
        'DRAFT',
        'ANALYZED',
        'ACTION_DONE',
        'V1',
        'V2',
        'V3',
        'CLOSED',
        'REOPENED',
      ];
      await LocalDaos.defectTickets.insertAll(db, <Map<String, Object?>>[
        for (final String s in statuses)
          <String, Object?>{
            'local_id': 'dt-s-$s',
            'server_id': 'dt-s-srv-$s',
            'user_id': 'u-1',
            'status': s,
          },
      ]);
      final List<Map<String, Object?>> out =
          await LocalDaos.defectTickets.listVerifiable(db, 'u-1');
      expect(
        out.map((Map<String, Object?> r) => r['status']).toSet(),
        <String>{'V1', 'V2', 'V3'},
      );
    });

    test('findByStageRound 按 (单, stage, round) 唯一命中', () async {
      final Database db = await LocalDb.instance.database;
      await LocalDaos.verifications.insertAll(db, <Map<String, Object?>>[
        <String, Object?>{
          'local_id': 'v-1-1',
          'defect_ticket_local_id': 'dt-x',
          'stage': 'V1',
          'round': 1,
          'result': 'pass',
        },
        <String, Object?>{
          'local_id': 'v-1-2',
          'defect_ticket_local_id': 'dt-x',
          'stage': 'V2',
          'round': 1,
          'result': 'pending',
        },
        <String, Object?>{
          'local_id': 'v-2-1',
          'defect_ticket_local_id': 'dt-x',
          'stage': 'V1',
          'round': 2,
          'result': 'pass',
        },
      ]);

      final Map<String, Object?>? hit = await LocalDaos.verifications
          .findByStageRound(db, 'dt-x', 'V1', 2);
      expect(hit, isNotNull);
      expect(hit!['local_id'], 'v-2-1');

      expect(
        await LocalDaos.verifications.findByStageRound(db, 'dt-x', 'V3', 1),
        isNull,
      );
    });

    test('同一 (单, stage, round) 二次插入被唯一索引拒绝', () async {
      final Database db = await LocalDb.instance.database;
      final Map<String, Object?> row = <String, Object?>{
        'local_id': 'v-dup-1',
        'defect_ticket_local_id': 'dt-y',
        'stage': 'V1',
        'round': 1,
        'result': 'pass',
      };
      await LocalDaos.verifications.insert(db, row);
      // 换 local_id 但同 (单, stage, round)：replace 语义会按唯一索引覆盖，
      // 因此这里要断言「最终只有一行」，而不是「抛异常」。
      await LocalDaos.verifications.insert(db, <String, Object?>{
        ...row,
        'local_id': 'v-dup-2',
      });
      final List<Map<String, Object?>> rows = await db.query(
        'verifications',
        where: 'defect_ticket_local_id = ? AND stage = ? AND round = ?',
        whereArgs: <Object?>['dt-y', 'V1', 1],
      );
      expect(rows.length, 1, reason: '云端 idx_ver_dt_stage 同构的唯一索引必须生效');
    });

    test('listByTicket 按父键取子行', () async {
      final Database db = await LocalDb.instance.database;
      await LocalDaos.actions.insertAll(db, <Map<String, Object?>>[
        <String, Object?>{
          'local_id': 'a-1',
          'defect_ticket_local_id': 'dt-p',
          'content': '动作一',
        },
        <String, Object?>{
          'local_id': 'a-2',
          'defect_ticket_local_id': 'dt-p',
          'content': '动作二',
        },
        <String, Object?>{
          'local_id': 'a-3',
          'defect_ticket_local_id': 'dt-q',
          'content': '别的单',
        },
      ]);
      final List<Map<String, Object?>> out =
          await LocalDaos.actions.listByTicket(db, 'dt-p');
      expect(out.length, 2);
      expect(
        out.map((Map<String, Object?> r) => r['local_id']).toSet(),
        <String>{'a-1', 'a-2'},
      );
    });

    test('listByProfile / listBySubject 按外键过滤', () async {
      final Database db = await LocalDb.instance.database;
      await LocalDaos.subjects.insertAll(db, <Map<String, Object?>>[
        <String, Object?>{'local_id': 's-1', 'exam_profile_id': 'ep-a', 'name': '判断推理'},
        <String, Object?>{'local_id': 's-2', 'exam_profile_id': 'ep-a', 'name': '资料分析'},
        <String, Object?>{'local_id': 's-3', 'exam_profile_id': 'ep-b', 'name': '言语理解'},
      ]);
      expect((await LocalDaos.subjects.listByProfile(db, 'ep-a')).length, 2);

      await LocalDaos.knowledgeNodes.insertAll(db, <Map<String, Object?>>[
        <String, Object?>{'local_id': 'k-1', 'subject_id': 's-1', 'title': '充分必要条件'},
        <String, Object?>{'local_id': 'k-2', 'subject_id': 's-2', 'title': '增长率'},
      ]);
      expect((await LocalDaos.knowledgeNodes.listBySubject(db, 's-1')).length, 1);
    });

    test('count / countUnsynced 统计正确', () async {
      final Database db = await LocalDb.instance.database;
      await LocalDaos.defectTickets.insertAll(db, <Map<String, Object?>>[
        <String, Object?>{'local_id': 'c-1', 'user_id': 'u', 'status': 'DRAFT', 'sync_state': 0},
        <String, Object?>{'local_id': 'c-2', 'user_id': 'u', 'status': 'DRAFT', 'sync_state': 1},
        <String, Object?>{'local_id': 'c-3', 'user_id': 'u', 'status': 'DRAFT', 'sync_state': 2},
      ]);
      expect(await LocalDaos.defectTickets.count(db), 3);
      expect(await LocalDaos.defectTickets.countUnsynced(db), 2);
      expect(await LocalDaos.defectTickets.deleteAll(db), 3);
      expect(await LocalDaos.defectTickets.count(db), 0);
    });
  });

  // ── E3 pending_operations ───────────────────────────────────────────────
  group('E3 pending_operations', () {
    PendingOperation op({
      String entity = 'defect_ticket',
      String localId = 'dt-1',
      String operation = 'PATCH',
      String path = '/defect-tickets/{server_id}/analyze',
      int? baseVersion = 3,
    }) {
      return PendingOperation(
        opId: 0,
        entityType: entity,
        entityLocalId: localId,
        operation: operation,
        pathTemplate: path,
        payload: '{"status":"ANALYZED"}',
        baseVersion: baseVersion,
        createdAt: '',
      );
    }

    test('enqueue → listPending → markDone 完整流程', () async {
      final Database db = await LocalDb.instance.database;
      final int id1 = await LocalDaos.pending.enqueue(db, op());
      final int id2 = await LocalDaos.pending.enqueue(
        db,
        op(localId: 'dt-2', operation: 'POST', baseVersion: null),
      );
      expect(id2, greaterThan(id1), reason: 'op_id 必须单调递增 = 全局发送顺序');

      final List<PendingOperation> pending = await LocalDaos.pending.listPending(db);
      expect(pending.length, 2);
      expect(pending.first.opId, id1, reason: '出队按 op_id 升序');
      expect(pending.first.baseVersion, 3);
      expect(pending.last.baseVersion, isNull);

      expect(await LocalDaos.pending.markDone(db, id1), 1);
      final List<PendingOperation> after = await LocalDaos.pending.listPending(db);
      expect(after.length, 1);
      expect(after.single.opId, id2);
    });

    test('markFailed 保留在队列并记录错误与重试时间', () async {
      final Database db = await LocalDb.instance.database;
      final int id = await LocalDaos.pending.enqueue(db, op());
      await LocalDaos.pending.markFailed(
        db,
        id,
        error: 'ApiException 500',
        retryCount: 2,
        nextRetryAt: '2026-11-21T23:00:00.000Z',
      );

      expect(await LocalDaos.pending.listPending(db), isEmpty,
          reason: '默认只取 status=0');
      final List<PendingOperation> retryable =
          await LocalDaos.pending.listPending(db, includeRetryable: true);
      expect(retryable.length, 1);
      expect(retryable.single.status, PendingStatus.failedRetryable);
      expect(retryable.single.retryCount, 2);
      expect(retryable.single.lastError, 'ApiException 500');
      expect(retryable.single.nextRetryAt, '2026-11-21T23:00:00.000Z');
    });

    test('incrementRetry 只加计数不改状态', () async {
      final Database db = await LocalDb.instance.database;
      final int id = await LocalDaos.pending.enqueue(db, op());
      await LocalDaos.pending.incrementRetry(db, id);
      await LocalDaos.pending.incrementRetry(db, id);
      final PendingOperation row =
          (await LocalDaos.pending.listPending(db)).single;
      expect(row.retryCount, 2);
      expect(row.status, PendingStatus.pending);
    });

    test('listByEntity 返回同实体的全部操作且按入队顺序', () async {
      final Database db = await LocalDb.instance.database;
      await LocalDaos.pending.enqueue(db, op(operation: 'PATCH', path: '/a'));
      await LocalDaos.pending.enqueue(db, op(operation: 'PATCH', path: '/b'));
      await LocalDaos.pending.enqueue(db, op(localId: 'other', path: '/c'));

      final List<PendingOperation> mine =
          await LocalDaos.pending.listByEntity(db, 'defect_ticket', 'dt-1');
      expect(mine.length, 2);
      expect(
        mine.map((PendingOperation o) => o.pathTemplate).toList(),
        <String>['/a', '/b'],
      );
    });

    test('markConflict / markDead 改状态', () async {
      final Database db = await LocalDb.instance.database;
      final int a = await LocalDaos.pending.enqueue(db, op());
      final int b = await LocalDaos.pending.enqueue(db, op(localId: 'dt-2'));
      await LocalDaos.pending.markConflict(db, a, error: '409');
      await LocalDaos.pending.markDead(db, b, error: 'too many retries');

      final List<PendingOperation> all =
          await LocalDaos.pending.listPending(db, includeRetryable: true);
      expect(all, isEmpty, reason: 'conflict/dead 不在 pending 与 retryable 里');
      expect(await LocalDaos.pending.count(db), 2, reason: '行数不变，只是状态变了');
    });
  });

  // ── E4 local_meta ───────────────────────────────────────────────────────
  group('E4 local_meta', () {
    test('setMeta / getMeta / deleteMeta 读写', () async {
      final Database db = await LocalDb.instance.database;

      expect(await LocalDaos.meta.getMeta(db, MetaKey.tokenFingerprint), isNull);

      await LocalDaos.meta.setMeta(db, MetaKey.tokenFingerprint, 'a1b2c3d4');
      expect(await LocalDaos.meta.getMeta(db, MetaKey.tokenFingerprint), 'a1b2c3d4');

      // 覆盖写
      await LocalDaos.meta.setMeta(db, MetaKey.tokenFingerprint, 'ffff0000');
      expect(await LocalDaos.meta.getMeta(db, MetaKey.tokenFingerprint), 'ffff0000');

      expect(await LocalDaos.meta.deleteMeta(db, MetaKey.tokenFingerprint), 1);
      expect(await LocalDaos.meta.getMeta(db, MetaKey.tokenFingerprint), isNull);
    });

    test('setAll 批量写 + listByPrefix 按前缀取', () async {
      final Database db = await LocalDb.instance.database;
      await LocalDaos.meta.setAll(db, <String, String?>{
        MetaKey.sync('defect_tickets', 'last_full_pull_at'): '2026-11-21T00:00:00.000Z',
        MetaKey.sync('defect_tickets', 'row_count'): '9',
        MetaKey.sync('mock_exams', 'row_count'): '3',
        MetaKey.lastSyncAt: '2026-11-21T00:00:00.000Z',
      });
      final Map<String, String?> dt =
          await LocalDaos.meta.listByPrefix(db, 'sync.defect_tickets.');
      expect(dt.length, 2);
      expect(dt['sync.defect_tickets.row_count'], '9');
      expect(await LocalDaos.meta.listAll(db), hasLength(4));
    });

    test('MetaKey.sync 拼键格式固定', () {
      expect(MetaKey.sync('a', 'b'), 'sync.a.b');
    });
  });

  // ── E5 关闭后重开 ───────────────────────────────────────────────────────
  group('E5 持久化', () {
    test('close() 后重新初始化，数据仍在', () async {
      final Database db1 = await LocalDb.instance.database;
      await LocalDaos.defectTickets.insert(db1, <String, Object?>{
        'local_id': 'dt-persist',
        'server_id': 'dt-persist-srv',
        'user_id': 'u-1',
        'status': 'ANALYZED',
        'error_layer': '方法不会',
      });
      await LocalDaos.meta.setMeta(db1, MetaKey.lastSyncAt, '2026-11-21T01:02:03.000Z');

      await LocalDb.instance.close();
      expect(LocalDb.instance.isOpen, isFalse);

      // 重新打开：不应重复建表（version 已是 1，onCreate 不会再跑）
      final Database db2 = await LocalDb.instance.database;
      expect(LocalDb.instance.isOpen, isTrue);
      final Map<String, Object?>? row =
          await LocalDaos.defectTickets.getByPk(db2, 'dt-persist');
      expect(row, isNotNull, reason: '重开后数据必须还在');
      expect(row!['error_layer'], '方法不会');
      expect(await LocalDaos.meta.getMeta(db2, MetaKey.lastSyncAt),
          '2026-11-21T01:02:03.000Z');
    });

    test('并发调用 database 只打开一次', () async {
      final List<Database> dbs = await Future.wait(<Future<Database>>[
        LocalDb.instance.database,
        LocalDb.instance.database,
        LocalDb.instance.database,
      ]);
      expect(dbs[0], same(dbs[1]), reason: '并发打开必须返回同一句柄');
      expect(dbs[1], same(dbs[2]));
    });
  });

  // ── 开关 ────────────────────────────────────────────────────────────────
  group('kLocalFirstEnabled 开关', () {
    test('R2 起默认启用本地优先', () {
      // R1 时这里是 false（只建库不接页面）；R2 把开关翻成 true 并接上四个页面。
      // 这条断言存在的意义：开关被误改回 false 时，本地优先会静默失效——
      // 四个页面仍工作（走旧直连路径），没有别的测试会失败。
      expect(kLocalFirstEnabled, isTrue);
    });
  });
}
