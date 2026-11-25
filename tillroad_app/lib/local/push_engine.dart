// 推送引擎（R4a 任务 C）：把 `pending_operations` 里的队列行按序发给云端。
//
// 与 write_queue.dart 的分工：那边只负责「本地立即生效 + 记一条待推送」，这边负责
// 「联网后把队列清空并把云端返回的真实 id / version 回填到本地」。
//
// 五条关键规则（每一条都对应一个真实会踩的坑，改之前先读完）：
//   1. **按 op_id 升序全局串行**。同一条单上的操作有先后依赖（建单 → 归因 → 标记动作
//      → 进入验证 → 提交验证），后端每一步都会 `version + 1`，乱序发必然 409。
//      设计文档 §3.2 给的结论：MVP 直接全局串行，简单且量小。
//   2. **base_version 级联**。队列行里存的 `base_version` 是「入队那一刻本地知道的
//      version」，只在离线期间有效。一旦前一条推送成功、云端返回了新 version，
//      后面所有同实体的操作都必须改用新 version —— 用 `_latestVersion` 记录。
//   3. **占位符必须解析成 server_id**。离线新建的单在入队时还没有 server_id，所以
//      path_template 写成 `/defect-tickets/{server_id}/...`，这里推送前替换。
//   4. **begin-verification 必须先 GET 最新版本**。后端这一步是「两跳同事务」
//      （ACTION_DONE → V1，version +2），本地无法预测，用旧 version 发过去 100% 409。
//      队列行里的 `__requires_online_refresh` 就是干这个的。
//   5. **失败要分类，不能一律当网络错误重试**：
//        · 409 → 冲突，标记 conflict 并**暂停该实体后续操作**（用户需手动刷新）；
//        · 401 → token 失效，停止整轮推送（继续发只会刷 401）；
//        · 400 业务校验 → dead，重试一万次也不会成功（本地校验漏了才会到这里）；
//        · 网络错误 / 5xx → 指数退避重试，超过 5 次转 dead。
//
// 幂等性提示：`POST /defect-tickets` 不幂等。如果在「已发出、还没收到响应」时进程被
// 杀，重启后会重发，可能在云端留下重复单。设计文档 §3.2 认为 MVP 可接受（极少数
// 情况需手动删）。R4b 会加对账探测。

import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../api/api_client.dart';
import '../config/api_config.dart';
import '../config/local_config.dart';
import '../logging/app_logger.dart';
import 'dao/dao_base.dart';
import 'dao/pending_operations_dao.dart';
import 'dao/table_daos.dart';
import 'first_fill.dart' show kLocalDataRevision;
import 'local_db.dart';

/// 重试次数上限；达到后转 dead，不再自动推送。
const int kPushMaxRetry = 5;

/// 指数退避的基数与上限：`min(2^retry * 2s, 5min)`。
const int kPushBackoffBaseSeconds = 2;
const int kPushBackoffCapSeconds = 300;

/// 单条队列行的推送结果，供日志与测试断言用。
enum PushOutcome {
  /// 成功，队列行已删除。
  success,

  /// 冲突（409），队列行标记 conflict。
  conflict,

  /// 业务校验失败（400）或重试超限，队列行标记 dead。
  dead,

  /// 可重试失败（网络 / 5xx / 超时），已排下次重试。
  retryable,

  /// token 失效（401），整轮停止。
  unauthorized,
}

/// 一次推送的汇总。
class PushReport {
  PushReport({
    this.succeeded = 0,
    this.conflicts = 0,
    this.dead = 0,
    this.retryable = 0,
    this.remaining = 0,
    this.unauthorized = false,
    this.stoppedByEntity = 0,
  });

  int succeeded;
  int conflicts;
  int dead;
  int retryable;

  /// 本轮结束后仍留在队列里的行数（含冲突 / dead / 待重试）。
  int remaining;

  /// 是否因 401 提前中止。
  bool unauthorized;

  /// 因冲突或 dead 而暂停的实体数（这些实体后面的操作本轮没发）。
  int stoppedByEntity;

  bool get isClean =>
      conflicts == 0 && dead == 0 && retryable == 0 && remaining == 0;

  @override
  String toString() =>
      'PushReport(ok=$succeeded, conflict=$conflicts, dead=$dead, '
      'retryable=$retryable, remaining=$remaining, '
      'stopped=$stoppedByEntity, unauthorized=$unauthorized)';
}

/// 推送引擎。全部静态方法，内部用 `_inFlight` 做并发保护。
abstract final class PushEngine {
  PushEngine._();

  static Future<PushReport>? _inFlight;

  /// 是否有推送正在进行（页面可据此显示「同步中」）。
  static bool get isPushing => _inFlight != null;

  /// 推送队列。并发调用共享同一个 Future —— 避免页面 initState、写操作后、
  /// 下拉刷新三处同时触发，把同一条队列行发两遍（`POST` 不幂等，会造重复单）。
  static Future<PushReport> pushPending() {
    final Future<PushReport>? running = _inFlight;
    if (running != null) return running;
    final Future<PushReport> task = _push().whenComplete(() => _inFlight = null);
    _inFlight = task;
    return task;
  }

  static Future<PushReport> _push() async {
    final PushReport report = PushReport();
    // R4b：推送引擎的判据也改成「本地库能不能用」。
    // 原来用 `kLocalFirstEnabled`，一旦本地库初始化失败（被置 false），
    // 队列就永远不会被推送——离线写的东西会静默卡在本地。
    if (!kLocalDbReady) return report;
    if ((kApiToken ?? '').trim().isEmpty) return report;

    final Database db = await LocalDb.instance.database;
    final List<PendingOperation> pending = await LocalDaos.pending.listPending(
      db,
      includeRetryable: true,
    );
    if (pending.isEmpty) return report;

    final ApiClient client = ApiClient();
    // 同实体上一条成功后云端返回的新 version，用于级联覆盖后续操作的 base_version。
    final Map<String, int> latestVersion = <String, int>{};
    // 本轮被暂停的实体（冲突 / dead 之后，该实体剩下的操作不再发）。
    final Set<String> paused = <String>{};

    try {
      for (final PendingOperation op in pending) {
        if (op.status == PendingStatus.conflict ||
            op.status == PendingStatus.dead) {
          continue;
        }
        if (paused.contains(op.entityLocalId)) {
          report.stoppedByEntity++;
          continue;
        }
        // 没到重试时间的行先跳过（本轮不发，但也不删）。
        if (_notYetDue(op)) continue;

        final PushOutcome outcome =
            await _pushOne(client, db, op, latestVersion);
        switch (outcome) {
          case PushOutcome.success:
            report.succeeded++;
          case PushOutcome.conflict:
            report.conflicts++;
            paused.add(op.entityLocalId);
          case PushOutcome.dead:
            report.dead++;
            paused.add(op.entityLocalId);
          case PushOutcome.retryable:
            report.retryable++;
            // 网络断了，后面的行也一定失败，直接结束本轮，避免无谓的等待。
            report.remaining = await LocalDaos.pending.count(db);
            return report;
          case PushOutcome.unauthorized:
            report.unauthorized = true;
            report.remaining = await LocalDaos.pending.count(db);
            return report;
        }
      }
    } finally {
      client.close();
    }

    report.remaining = await LocalDaos.pending.count(db);
    if (report.succeeded > 0) {
      kLocalDataRevision.value++;
      AppLogger.instance.info(
        'SYNC',
        '推送完成：成功 ${report.succeeded} 条'
        '${report.conflicts > 0 ? '，冲突 ${report.conflicts} 条' : ''}'
        '${report.dead > 0 ? '，失败 ${report.dead} 条' : ''}'
        '${report.retryable > 0 ? '，待重试 ${report.retryable} 条' : ''}，'
        '剩余 ${report.remaining} 条',
      );
    }
    return report;
  }

  // ───────────────────────── 单条推送 ─────────────────────────

  static Future<PushOutcome> _pushOne(
    ApiClient client,
    Database db,
    PendingOperation op,
    Map<String, int> latestVersion,
  ) async {
    final Map<String, Object?> payload = _decodePayload(op.payload);

    // 1) 定位云端 id。离线新建的单此时还没有 server_id —— 那是「这条建单操作自己」
    //    要拿到的结果，所以建单操作不需要 server_id，其余操作必须有。
    final Map<String, Object?>? ticket =
        await LocalDaos.defectTickets.getByLocalId(db, op.entityLocalId);
    final String? ticketServerId = ticket?[Col.serverId] as String?;

    if (op.operation != 'POST' || op.pathTemplate != '/defect-tickets') {
      if (ticketServerId == null || ticketServerId.isEmpty) {
        // 前置的建单操作还没成功，这条只能等下一轮。
        await _markRetryable(db, op, '前置建单尚未同步（server_id 为空）');
        return PushOutcome.retryable;
      }
    }

    // 2) 解析路径占位符。
    String path = op.pathTemplate;
    if (path.contains('{server_id}')) {
      if (ticketServerId == null || ticketServerId.isEmpty) {
        await _markRetryable(db, op, '缺少 server_id');
        return PushOutcome.retryable;
      }
      path = path.replaceAll('{server_id}', ticketServerId);
    }
    if (path.contains('{action_server_id}')) {
      final String? actionLocalId = payload['__action_local_id'] as String?;
      final Map<String, Object?>? action = actionLocalId == null
          ? null
          : await LocalDaos.actions.getByLocalId(db, actionLocalId);
      final String? actionServerId = action?[Col.serverId] as String?;
      if (actionServerId == null || actionServerId.isEmpty) {
        await _markRetryable(db, op, '动作缺少 server_id');
        return PushOutcome.retryable;
      }
      path = path.replaceAll('{action_server_id}', actionServerId);
      // R4a：base_version 取动作行**当前**的 version（入队时写的那个可能已被
      // 上一条成功推送更新过）。动作的乐观锁与缺陷单是两套，不能级联。
      final int? localActionVersion = _intOf(action?[Col.version]);
      if (localActionVersion != null) {
        payload['version'] = localActionVersion;
      }
    }

    // 3) base_version 级联：同实体已有成功记录时，用最新 version 覆盖。
    //
    // R4a 修正：**标记动作**走的是 actions 表自己的乐观锁，不能用缺陷单的
    // version 级联覆盖，否则一张单有两条动作、只标记其中一条时就会错位。
    // 动作的 base_version 一律以本地 action 行为准（入队时写入 payload）。
    final bool isActionOp = op.pathTemplate.contains('/actions/');
    if (!isActionOp && latestVersion.containsKey(op.entityLocalId)) {
      payload['version'] = latestVersion[op.entityLocalId];
    }

    // 4) begin-verification 的两跳保护：先拉最新 version。
    if (payload['__requires_online_refresh'] == true) {
      try {
        final Object? fresh = await client.get('/defect-tickets/$ticketServerId');
        final int? serverVersion = _versionOf(fresh);
        if (serverVersion != null) {
          payload['version'] = serverVersion;
          latestVersion[op.entityLocalId] = serverVersion;
        }
      } on ApiException catch (e) {
        if (e.statusCode == 401) return PushOutcome.unauthorized;
        await _markRetryable(db, op, '拉取最新版本失败：${e.message}');
        return PushOutcome.retryable;
      }
    }

    final Map<String, Object?> body = stripInternalKeys(payload);
    await LocalDaos.pending.markInflight(db, op.opId);

    try {
      final Object? response = await _send(client, op.operation, path, body);
      await _applySuccess(db, op, response, latestVersion);
      await LocalDaos.pending.markDone(db, op.opId);
      return PushOutcome.success;
    } on ApiException catch (e) {
      return _applyFailure(db, op, e);
    } catch (e) {
      // 非 ApiException（解析异常等）也按可重试处理，不要卡住队列。
      await _markRetryable(db, op, '$e');
      return PushOutcome.retryable;
    }
  }

  static Future<Object?> _send(
    ApiClient client,
    String operation,
    String path,
    Map<String, Object?> body,
  ) {
    switch (operation) {
      case 'POST':
        return client.post(path, body: body);
      case 'PATCH':
        return client.patch(path, body: body);
      case 'DELETE':
        return client.delete(path, body: body);
      default:
        throw StateError('未知操作类型：$operation');
    }
  }

  // ───────────────────────── 成功后回填 ─────────────────────────

  static Future<void> _applySuccess(
    Database db,
    PendingOperation op,
    Object? response,
    Map<String, int> latestVersion,
  ) async {
    final Map<String, Object?>? row =
        response is Map ? response.cast<String, Object?>() : null;
    if (row == null) return;

    final String localId = op.entityLocalId;

    // 建单：云端分配了 id / version，还要把 actions 的 server_id 按顺序回填。
    if (op.pathTemplate == '/defect-tickets') {
      final String? serverId = row['id'] as String?;
      final int version = _intOf(row['version']) ?? 1;
      final String? status = row['status'] as String?;
      if (serverId != null) {
        await LocalDaos.defectTickets.update(db, localId, <String, Object?>{
          Col.serverId: serverId,
          Col.syncState: SyncState.synced,
          Col.version: version,
          if (status != null) 'status': status,
        });
        latestVersion[localId] = version;
        await _backfillActions(db, localId, row['actions'], version);
        AppLogger.instance.info(
          'PUSH',
          '建单成功，本地 server_id=$serverId status=${status ?? '-'} version=$version',
        );
      }
      return;
    }

    // 提交验证：响应是 { ticket, verification }。
    if (op.pathTemplate.endsWith('/verifications')) {
      final Object? ticketRaw = row['ticket'];
      final Map<String, Object?>? ticketRow = ticketRaw is Map
          ? ticketRaw.cast<String, Object?>()
          : null;
      if (ticketRow != null) {
        await _applyTicketRow(db, localId, ticketRow, latestVersion);
      }
      final Object? verificationRaw = row['verification'];
      final Map<String, Object?>? verificationRow = verificationRaw is Map
          ? verificationRaw.cast<String, Object?>()
          : null;
      if (verificationRow != null) {
        await _applyVerificationRow(db, localId, verificationRow);
        // R4b：把「推送后本地状态是什么」明确记下来，方便核对列表与详情是否一致。
        final Map<String, Object?>? appliedTicket =
            await LocalDaos.defectTickets.getByLocalId(db, localId);
        AppLogger.instance.info(
          'PUSH',
          '提交验证成功，本地 status=${appliedTicket?['status']}'
          ' version=${appliedTicket?[Col.version]}',
        );
      }
      return;
    }

    // 标记动作：响应是单个 action 行，缺陷单 version 不变。
    if (op.pathTemplate.contains('/actions/')) {
      final String? serverId = row['id'] as String?;
      final int actionVersion = _intOf(row['version']) ?? 1;
      final String? actionLocalId = _decodePayload(op.payload)['__action_local_id']
          as String?;
      if (actionLocalId != null) {
        await LocalDaos.actions.update(db, actionLocalId, <String, Object?>{
          if (serverId != null) Col.serverId: serverId,
          Col.syncState: SyncState.synced,
          Col.version: actionVersion,
          if (row['done'] is bool) 'done': (row['done']! as bool) ? 1 : 0,
        });
        AppLogger.instance.info(
          'PUSH',
          '标记动作成功，本地 action=$actionLocalId done=${row['done']}'
          ' version=$actionVersion',
        );
      }
      return;
    }

    // 归因 / 进入验证：响应都是缺陷单裸行。
    await _applyTicketRow(db, localId, row, latestVersion);
    AppLogger.instance.info(
      'PUSH',
      '${op.operation} ${op.pathTemplate} 成功，'
      '本地 status=${row['status']} version=${_intOf(row['version']) ?? 1}',
    );
  }

  static Future<void> _applyTicketRow(
    Database db,
    String localId,
    Map<String, Object?> row,
    Map<String, int> latestVersion,
  ) async {
    final int version = _intOf(row['version']) ?? 1;
    final String? status = row['status'] as String?;
    await LocalDaos.defectTickets.update(db, localId, <String, Object?>{
      Col.syncState: SyncState.synced,
      Col.version: version,
      if (status != null) 'status': status,
      if (row['verification_round'] != null)
        Col.verificationRound: _intOf(row['verification_round']),
      if (row['reopen_count'] != null)
        'reopen_count': _intOf(row['reopen_count']),
      if (row['closed_at'] is String) 'closed_at': row['closed_at'],
    });
    latestVersion[localId] = version;
  }

  static Future<void> _applyVerificationRow(
    Database db,
    String localId,
    Map<String, Object?> row,
  ) async {
    final String? serverId = row['id'] as String?;
    if (serverId == null) return;
    // 本地这条验证记录的 server_id 是空的，用 (stage, round) 定位。
    final String? stage = row['stage'] as String?;
    final int round = _intOf(row['round']) ?? 1;
    if (stage == null) return;
    final Map<String, Object?>? local = await LocalDaos.verifications
        .findByStageRound(db, localId, stage, round);
    if (local == null) return;
    await LocalDaos.verifications.update(
      db,
      local[Col.localId]! as String,
      <String, Object?>{
        Col.serverId: serverId,
        Col.syncState: SyncState.synced,
        Col.version: _intOf(row['version']) ?? 1,
      },
    );
  }

  /// 建单成功后把响应里的 actions 按顺序回填 server_id。
  ///
  /// 为什么按顺序而不是按 content 匹配：同一条单可能写两条文案完全一样的动作，
  /// 按内容匹配会把它们弄混。服务端 `insertActionsForTicket` 是**按数组顺序**
  /// 逐条 INSERT 的，所以第 i 条响应就对应本地第 i 条（本地也是按顺序 insertAll）。
  /// 条数不同（云端过滤了空白文案）时以响应为准，多出来的本地行保持 pending。
  static Future<void> _backfillActions(
    Database db,
    String ticketLocalId,
    Object? actionsRaw,
    int ticketVersion,
  ) async {
    if (actionsRaw is! List || actionsRaw.isEmpty) return;
    final List<Map<String, Object?>> localActions =
        await LocalDaos.actions.listByTicket(db, ticketLocalId);
    final int count =
        actionsRaw.length < localActions.length ? actionsRaw.length : localActions.length;
    for (int i = 0; i < count; i++) {
      final Object? raw = actionsRaw[i];
      if (raw is! Map) continue;
      final Map<String, Object?> remote = raw.cast<String, Object?>();
      final String? serverId = remote['id'] as String?;
      if (serverId == null) continue;
      await LocalDaos.actions.update(
        db,
        localActions[i][Col.localId]! as String,
        <String, Object?>{
          Col.serverId: serverId,
          Col.syncState: SyncState.synced,
          Col.version: _intOf(remote['version']) ?? 1,
        },
      );
    }
    // 缺陷单本身的 version 已在调用方写过；这里只是让读回来的动作行与单一致。
    assert(ticketVersion >= 1);
  }

  // ───────────────────────── 失败分类 ─────────────────────────

  static Future<PushOutcome> _applyFailure(
    Database db,
    PendingOperation op,
    ApiException e,
  ) async {
    final int? status = e.statusCode;

    if (status == 401) {
      return PushOutcome.unauthorized;
    }

    // 409：乐观锁冲突或重复提交。把服务端返回的 current 存进 last_error，
    // 详情页的橙色 banner 会把这段文本展示给用户。
    if (status == 409) {
      await LocalDaos.pending.markConflict(db, op.opId, error: _conflictText(e));
      await LocalDaos.defectTickets.update(db, op.entityLocalId, <String, Object?>{
        Col.syncState: SyncState.conflict,
      });
      return PushOutcome.conflict;
    }

    // 400：业务校验失败。本地状态机已经拦过一次，走到这里说明两侧规则漂了 ——
    // 重试没有意义，标 dead 并在日志里留下原因。
    if (status == 400) {
      await LocalDaos.pending.markDead(db, op.opId, error: '${e.message}｜${_bodyText(e)}');
      AppLogger.instance.warn('SYNC', '队列行 #${op.opId} 被服务端拒绝（400），已转 dead');
      return PushOutcome.dead;
    }

    // 404：目标实体在云端没了（被别的端删了），同样不该重试。
    if (status == 404) {
      await LocalDaos.pending.markDead(db, op.opId, error: '服务端找不到该资源（404）');
      return PushOutcome.dead;
    }

    // 其余（网络 / 超时 / 5xx）：可重试。
    await _markRetryable(db, op, '${e.message}｜${_bodyText(e)}');
    return PushOutcome.retryable;
  }

  static Future<void> _markRetryable(
    Database db,
    PendingOperation op,
    String error,
  ) async {
    final int nextRetry = op.retryCount + 1;
    if (nextRetry > kPushMaxRetry) {
      await LocalDaos.pending.markDead(db, op.opId, error: '重试 $kPushMaxRetry 次仍失败：$error');
      AppLogger.instance.warn('SYNC', '队列行 #${op.opId} 重试超限，已转 dead');
      return;
    }
    final int seconds = _backoffSeconds(nextRetry);
    final String nextAt = DateTime.now()
        .toUtc()
        .add(Duration(seconds: seconds))
        .toIso8601String();
    await LocalDaos.pending.markFailed(
      db,
      op.opId,
      error: error,
      retryCount: nextRetry,
      nextRetryAt: nextAt,
    );
  }

  /// `min(2^retry * 2s, 300s)`：2s / 4s / 8s / 16s / 32s …
  static int _backoffSeconds(int retry) {
    final int raw = kPushBackoffBaseSeconds * (1 << (retry - 1).clamp(0, 16));
    return raw > kPushBackoffCapSeconds ? kPushBackoffCapSeconds : raw;
  }

  static bool _notYetDue(PendingOperation op) {
    final String? at = op.nextRetryAt;
    if (at == null || at.isEmpty) return false;
    final DateTime? due = DateTime.tryParse(at);
    if (due == null) return false;
    return due.toUtc().isAfter(DateTime.now().toUtc());
  }

  // ───────────────────────── 小工具 ─────────────────────────

  static Map<String, Object?> _decodePayload(String raw) {
    if (raw.trim().isEmpty) return <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } catch (_) {
      // 坏 payload 当空对象处理，后面的推送会拿到 400 并转 dead。
    }
    return <String, Object?>{};
  }

  /// 剥掉以 `__` 开头的内部键（服务端不认识它们）。
  static Map<String, Object?> stripInternalKeys(Map<String, Object?> payload) {
    final Map<String, Object?> out = <String, Object?>{};
    payload.forEach((String key, Object? value) {
      if (!key.startsWith('__')) out[key] = value;
    });
    return out;
  }

  static String _conflictText(ApiException e) {
    final Object? body = e.body;
    if (body is Map) {
      final Object? current = body['current'];
      final Object? field = body['field'];
      final String detail = current == null
          ? ''
          : '（服务端当前值：${current is Map ? jsonEncode(current) : current}）';
      return '该单已被修改${field is String ? '，字段 $field' : ''}$detail';
    }
    return e.message;
  }

  static String _bodyText(ApiException e) {
    final Object? body = e.body;
    if (body == null) return '';
    final String text = body is String ? body : jsonEncode(body);
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  static int? _versionOf(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> map = raw.cast<String, Object?>();
    final Object? inner = map['ticket'];
    if (inner is Map) return _intOf(inner['version']);
    return _intOf(map['version']);
  }

  static int? _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// 触发时机（任务 C2）：启动后、回前台时、写操作后、下拉刷新时。
///
/// 刻意**不引** `connectivity_plus`：R4a 硬约束禁止新依赖，而「写操作后 + 回前台 +
/// 下拉刷新」三个事件已经覆盖了绝大多数「用户发现离线然后联网」的场景。真正断网
/// 期间的失败会按指数退避排队，用户下次进入 App 时自动重试。
///
/// 这里的节流是为了避免「连续点三个动作」时触发三次推送（每次都从队头重扫）。
abstract final class PushScheduler {
  PushScheduler._();

  static DateTime? _lastPushAt;

  /// 最小触发间隔。
  static const Duration minInterval = Duration(seconds: 5);

  /// 尽力而为地触发一次推送：失败只记日志，绝不影响调用方（页面写操作后的调用处
  /// 不该因为推送失败而回滚 UI）。
  static void schedule({bool force = false}) {
    // R4b：改用 `kLocalDbReady`（本地库能不能用）。
    if (!kLocalDbReady) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastPushAt;
    if (!force && last != null && now.difference(last) < minInterval) return;
    _lastPushAt = now;
    unawaited(
      PushEngine.pushPending().catchError((Object e) {
        AppLogger.instance.warn('SYNC', '推送调度失败：$e');
        return PushReport();
      }),
    );
  }

  /// 启动时补推（R4a）：上次断网 / 进程被杀留下的队列。
  /// 与 [schedule] 的区别：不受 5 秒节流限制（启动时本来就没有上一次）。
  ///
  /// **调用方要保证已在首次填充之后**（见 `main()`）：否则 `POST /defect-tickets`
  /// 成功回写的 `server_id` 可能被随后全量覆写的父表 deleteSynced 抹掉。
  static void pushOnStartup() {
    // R4b：同上。
    if (!kLocalDbReady) return;
    _lastPushAt = DateTime.now();
    unawaited(
      PushEngine.pushPending().catchError((Object e) {
        AppLogger.instance.warn('SYNC', '启动补推失败：$e');
        return PushReport();
      }),
    );
  }

  /// 供测试重置节流状态。
  static void resetThrottleForTest() => _lastPushAt = null;
}
