// 写队列（R4a 任务 B）的单元测试。
//
// 为什么要用 FFI：`sqflite` 在 `flutter test` 的宿主环境（Windows）没有平台实现，
// 直接调用会抛 `MissingPluginException`。`sqflite_common_ffi` 把同一套 Dart API
// 桥接到宿主原生的 sqlite3，行为与移动端一致。
//
// 每个用例一个独立临时库文件；用例之间重置 [LocalDb] 单例（全局状态）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tillroad_app/local/local.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    LocalDb.debugFactoryOverride = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tillroad_wq_test_');
    dbPath = p.join(tempDir.path, 'wq.db');
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

  /// 建一张已归因（ANALYZED）的单，返回 local id。
  Future<String> seedAnalyzedTicket({
    required String localId,
    int version = 1,
  }) async {
    final Database db = await LocalDb.instance.database;
    await LocalDaos.defectTickets.insert(db, <String, Object?>{
      'local_id': localId,
      'server_id': '$localId-srv',
      'sync_state': SyncState.synced,
      'user_id': 'u-1',
      'exam_profile_id': 'p-1',
      'q_type': '判断推理',
      'error_layer': '方法不会',
      'error_cause': '没有先画图再列方程',
      'priority': 'P1',
      'status': 'ANALYZED',
      'verification_round': 1,
      'reopen_count': 0,
      'created_at': '2026-11-22T00:00:00.000Z',
      'updated_at': '2026-11-22T00:00:00.000Z',
      'version': version,
    });
    return localId;
  }

  Future<void> seedAction(
    String ticketLocalId, {
    required String actionId,
    int version = 1,
    bool done = false,
  }) async {
    final Database db = await LocalDb.instance.database;
    await LocalDaos.actions.insert(db, <String, Object?>{
      'local_id': actionId,
      'server_id': '$actionId-srv',
      'sync_state': SyncState.synced,
      'defect_ticket_local_id': ticketLocalId,
      'content': '整理解题步骤卡片',
      'done': done ? 1 : 0,
      'due': null,
      'created_at': '2026-11-22T00:00:00.000Z',
      'updated_at': '2026-11-22T00:00:00.000Z',
      'version': version,
    });
  }

  /// 读队列里最后一条（action 操作）的 payload。
  Future<Map<String, Object?>> lastActionPayload() async {
    final Database db = await LocalDb.instance.database;
    final List<PendingOperation> ops = await LocalDaos.pending.listPending(
      db,
      includeRetryable: true,
    );
    expect(ops, isNotEmpty, reason: '队列里应该有一条待推送的操作');
    final PendingOperation op = ops.last;
    return jsonDecode(op.payload) as Map<String, Object?>;
  }

  group('enqueueMarkAction：base_version 必须来自动作行自己', () {
    test('入队时 payload.version = action.version，而不是 ticket.version', () async {
      await seedAnalyzedTicket(localId: 'dt-1', version: 7);
      await seedAction('dt-1', actionId: 'ac-1', version: 3);

      await WriteQueue.enqueueMarkAction(
        ticketId: 'dt-1',
        actionId: 'ac-1',
        done: true,
      );

      final Map<String, Object?> payload = await lastActionPayload();
      expect(
        payload['version'],
        3,
        reason: 'R4a 修正：后端 actions 表自己的 version 才是乐观锁基准，'
            '不能用缺陷单的 version（这里是 7）。',
      );
    });

    test('缺陷单 version 与动作 version 不同时不会串用', () async {
      // 一张单两条动作，只标记第二条：第一条被标记过 → 动作 version 已 +1，
      // 此时 ticket.version 仍是 1（云端 actions.markDone 不动缺陷单 version）。
      await seedAnalyzedTicket(localId: 'dt-2', version: 1);
      await seedAction('dt-2', actionId: 'ac-a', version: 2, done: true);
      await seedAction('dt-2', actionId: 'ac-b', version: 1);

      await WriteQueue.enqueueMarkAction(
        ticketId: 'dt-2',
        actionId: 'ac-b',
        done: true,
      );

      final Map<String, Object?> payload = await lastActionPayload();
      expect(payload['version'], 1, reason: '用的是第二条动作自己的 version=1');
      expect(payload['done'], isTrue);
      expect(payload['__action_local_id'], 'ac-b');
    });

    test('动作行 version 缺失时回落到 1 而不是用 ticket 的 version', () async {
      final Database db = await LocalDb.instance.database;
      await seedAnalyzedTicket(localId: 'dt-3', version: 9);
      await LocalDaos.actions.insert(db, <String, Object?>{
        'local_id': 'ac-x',
        'server_id': 'ac-x-srv',
        'sync_state': SyncState.synced,
        'defect_ticket_local_id': 'dt-3',
        'content': '重做同类题 5 道',
        'done': 0,
        'due': null,
        'created_at': '2026-11-22T00:00:00.000Z',
        'updated_at': '2026-11-22T00:00:00.000Z',
        // 故意不写 version，触发列默认值 1
      });

      await WriteQueue.enqueueMarkAction(
        ticketId: 'dt-3',
        actionId: 'ac-x',
        done: true,
      );

      final Map<String, Object?> payload = await lastActionPayload();
      expect(payload['version'], 1);
    });

    test('动作行被本地标记为 done 且 sync_state 变为 dirty', () async {
      await seedAnalyzedTicket(localId: 'dt-4');
      await seedAction('dt-4', actionId: 'ac-2');

      await WriteQueue.enqueueMarkAction(
        ticketId: 'dt-4',
        actionId: 'ac-2',
        done: true,
      );

      final Database db = await LocalDb.instance.database;
      final Map<String, Object?>? row =
          await LocalDaos.actions.getByPk(db, 'ac-2');
      expect(row, isNotNull);
      expect(row!['done'], 1);
      expect(row[Col.syncState], SyncState.dirty);
    });

    test('找不到动作时抛 LocalValidationException（ACTION_NOT_FOUND）', () async {
      await seedAnalyzedTicket(localId: 'dt-5');
      expect(
        () => WriteQueue.enqueueMarkAction(
          ticketId: 'dt-5',
          actionId: 'ac-missing',
          done: true,
        ),
        throwsA(
          isA<LocalValidationException>().having(
            (LocalValidationException e) => e.code,
            'code',
            'ACTION_NOT_FOUND',
          ),
        ),
      );
    });
    test('pendingOpCount 按 server_id 也能查到（回归：SQL 插值曾漏花括号）', () async {
      await seedAnalyzedTicket(localId: 'dt-9', version: 1);
      await seedAction('dt-9', actionId: 'ac-5');
      await WriteQueue.enqueueMarkAction(
        ticketId: 'dt-9',
        actionId: 'ac-5',
        done: true,
      );
      expect(await WriteQueueStatus.pendingOpCount('dt-9'), 1);
      expect(
        await WriteQueueStatus.pendingOpCount('dt-9-srv'),
        1,
        reason: '页面拿到的是 server_id，DAO 也必须认。',
      );
    });
  });

  group('enqueueBeginVerification：门禁与 base_version', () {
    test('没有动作时抛 NO_ACTIONS', () async {
      await seedAnalyzedTicket(localId: 'dt-6');
      expect(
        () => WriteQueue.enqueueBeginVerification(
          ticketId: 'dt-6',
          baseVersion: 1,
        ),
        throwsA(
          isA<LocalValidationException>().having(
            (LocalValidationException e) => e.code,
            'code',
            'NO_ACTIONS',
          ),
        ),
      );
    });

    test('动作未全部完成时抛 ACTIONS_NOT_DONE', () async {
      await seedAnalyzedTicket(localId: 'dt-7');
      await seedAction('dt-7', actionId: 'ac-3');
      expect(
        () => WriteQueue.enqueueBeginVerification(
          ticketId: 'dt-7',
          baseVersion: 1,
        ),
        throwsA(
          isA<LocalValidationException>().having(
            (LocalValidationException e) => e.code,
            'code',
            'ACTIONS_NOT_DONE',
          ),
        ),
      );
    });

    test('全部动作完成时入队且带 __requires_online_refresh 标记', () async {
      await seedAnalyzedTicket(localId: 'dt-8', version: 4);
      await seedAction('dt-8', actionId: 'ac-4', done: true);

      await WriteQueue.enqueueBeginVerification(
        ticketId: 'dt-8',
        baseVersion: 4,
      );

      final Map<String, Object?> payload = await lastActionPayload();
      expect(payload['__requires_online_refresh'], isTrue);
      expect(payload['version'], 4);
    });
  });

  group('冲突消解：clearConflicts', () {
    test('清掉 conflict 行并把 sync_state 回落为 synced', () async {
      await seedAnalyzedTicket(localId: 'dt-10');
      await seedAction('dt-10', actionId: 'ac-6');
      final Database db = await LocalDb.instance.database;
      // 造一条 conflict 队列行。
      await LocalDaos.pending.enqueue(
        db,
        PendingOperation(
          opId: 0,
          entityType: 'defect_ticket',
          entityLocalId: 'dt-10',
          operation: 'PATCH',
          pathTemplate: '/defect-tickets/{server_id}/actions/{action_server_id}',
          payload: '{}',
          baseVersion: 1,
          status: PendingStatus.conflict,
          retryCount: 0,
          nextRetryAt: null,
          lastError: '该单已被修改',
          createdAt: '2026-11-22T00:00:00.000Z',
        ),
      );
      await LocalDaos.defectTickets.update(db, 'dt-10', <String, Object?>{
        Col.syncState: SyncState.conflict,
      });

      expect(await WriteQueueStatus.ticketIdsInConflict(), contains('dt-10-srv'));

      final int cleared = await WriteQueueStatus.clearConflicts('dt-10');
      expect(cleared, 1);
      expect(await WriteQueueStatus.ticketIdsInConflict(), isEmpty);

      final Map<String, Object?>? row =
          await LocalDaos.defectTickets.getByPk(db, 'dt-10');
      expect(row![Col.syncState], SyncState.synced);
    });

    test('clearConflicts 只删 conflict 行，保留待推送的正常操作', () async {
      await seedAnalyzedTicket(localId: 'dt-11');
      final Database db = await LocalDb.instance.database;
      for (final int status in <int>[PendingStatus.conflict, PendingStatus.pending]) {
        await LocalDaos.pending.enqueue(
          db,
          PendingOperation(
            opId: 0,
            entityType: 'defect_ticket',
            entityLocalId: 'dt-11',
            operation: 'PATCH',
            pathTemplate: '/defect-tickets/{server_id}/analyze',
            payload: '{}',
            baseVersion: 1,
            status: status,
            retryCount: 0,
            nextRetryAt: null,
            lastError: null,
            createdAt: '2026-11-22T00:00:00.000Z',
          ),
        );
      }
      expect(await WriteQueueStatus.clearConflicts('dt-11'), 1);
      final int remaining = await LocalDaos.pending.count(db);
      expect(remaining, 1, reason: '待推送的正常操作不能被一次冲突一起丢掉');
    });
  });

}
