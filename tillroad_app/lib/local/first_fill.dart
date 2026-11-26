// 最小首次填充 + 云端行 → 本地行的投影（本地优先架构 R2）。
//
// 两个职责为什么放在一个文件：
//   ① [ensureInitialData] 首次填充时拉的每一批行都要写本地；
//   ② 四个页面的「后台刷新成功后回写本地」写的是同一批表、同一套映射。
//   把映射函数集中在这里，页面只调 `LocalCache.writeXxx(rows)`，
//   不会出现「首次填充与页面回写对同一张表用了两套字段名」这种漂移。
//
// 关键设计（与 docs/local-first-design.md §3.1 一致）：
//   · **父→子**顺序拉取：exam_profiles → subjects → knowledge_nodes →
//     defect_tickets → actions → verifications → mock_exams → review_cycles。
//     先父后子是为了让「考点标题」在写入脏单时已经就位（否则前端会先显示
//     「考点 <uuid8>」占位再跳变）。
//   · 分页终止**只能**靠 `items.length < limit`：`defect-tickets` 响应没有
//     total 字段，`review-cycles` / `mock-exams` 的 total 是 `items.length`
//     （假 total）。用 total 判断会永远拿不到第二页或提前停。
//   · 失败不阻塞启动：记 `AppLogger.error` + 标记 `sync.first_fill.completed=0`，
//     下次启动重试。页面在「未完成」时显示加载态而不是空状态（任务书 C5）。
//   · **本地主键取云端 id**：`local_id = server_id`。这不是偷懒——
//     `actions` / `verifications` 的 `defect_ticket_local_id` 指向
//     `defect_tickets.local_id`，若每次填充重新生成 UUID，子表的引用会全部
//     失效；让云端行的 local_id 恒等于 server_id 后，重复同步是幂等的。
//     离线新建的行（R4）仍用随机 UUID，两者互不冲突。

import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:sqflite/sqflite.dart' show DatabaseExecutor, Database, Transaction;

import '../api/api_client.dart';
import '../config/api_config.dart';
import '../logging/app_logger.dart';
import 'dao/dao_base.dart';
import 'dao/local_meta_dao.dart';
import 'dao/sync_table_dao.dart';
import 'dao/table_daos.dart';
import 'local_db.dart';
import 'local_schema.dart';
import 'sha256.dart';
import '../mock/defects_mock.dart' show DefectTicket, DefectAction, VerifyResult;

/// 单页条数。**必须**与服务端 `pageParams` 的上限 200 一致，
/// 否则服务端会把 limit 夹回 50，而客户端用 200 判断「还有下一页」→ 死循环。
const int kFillPageSize = 200;

/// 单个资源最多翻多少页（防服务端异常时无限翻页）。200×50 = 1 万行。
const int kFillMaxPages = 50;

/// 一张单最多补拉多少次详情（详情才能拿到 actions / verifications）。
/// 单个请求约 100ms，120 条约 3–12s；超出的只写主表并在日志里明说，
/// 不静默截断（R3 的正式同步会把这些补齐）。
const int kFillMaxDetailTickets = 120;

/// 本地数据版本号：首次填充完成 / 页面回写成功后 +1。
///
/// 页面 `initState` 里 `addListener` 一次，收到通知就重读本地表——
/// 这样「打开 App → 后台填充完成 → 首页自动出现数据」不需要下拉刷新（任务书 C5）。
final ValueNotifier<int> kLocalDataRevision = ValueNotifier<int>(0);

/// 本地缓存写入器：把云端行**投影**成本地表行并落库。
///
/// 所有 `writeX` 都是「删掉与云端一致的行 → 批量插入新行」，
/// 用 [SyncTableDao.deleteSynced] 而不是 `deleteAll`：
/// R4 上线后本地会有待推送行（sync_state = 1/2/4），整表清空会把它们一起抹掉。
abstract final class LocalCache {
  /// T1 `exam_profiles`。
  static Future<int> writeExamProfiles(List<Map<String, Object?>> rows) =>
      _rewrite(LocalDaos.examProfiles, rows.map(examProfileRow).toList());

  /// T2 `subjects`。
  static Future<int> writeSubjects(List<Map<String, Object?>> rows) =>
      _rewrite(LocalDaos.subjects, rows.map(subjectRow).toList());

  /// T3 `knowledge_nodes`。
  static Future<int> writeKnowledgeNodes(List<Map<String, Object?>> rows) =>
      _rewrite(LocalDaos.knowledgeNodes, rows.map(knowledgeNodeRow).toList());

  /// T4 `defect_tickets`。
  static Future<int> writeDefectTickets(List<Map<String, Object?>> rows) =>
      _rewrite(LocalDaos.defectTickets, rows.map(defectTicketRow).toList());

  /// T5 `actions`。父键用 `defect_ticket_local_id`（= 缺陷单 server_id）。
  ///
  /// 注意：子表只能按父键范围重写（见 [_rewriteChildren]），不能整表清空。
  static Future<int> writeActions(String ticketLocalId, List<Object?> actions) =>
      _rewriteChildren(
        LocalDaos.actions,
        ticketLocalId,
        actions
            .whereType<Map>()
            .map((Map m) => actionRow(m.cast<String, Object?>(), ticketLocalId))
            .toList(),
      );

  /// T6 `verifications`。
  static Future<int> writeVerifications(String ticketLocalId, List<Object?> verifications) =>
      _rewriteChildren(
        LocalDaos.verifications,
        ticketLocalId,
        verifications
            .whereType<Map>()
            .map((Map m) => verificationRow(m.cast<String, Object?>(), ticketLocalId))
            .toList(),
      );

  /// 子表单事务「按父键删旧行 + 批量插入」。
  ///
  /// 为什么不能沿用 [_rewrite]：那个按**整表** `deleteSynced`，而子表是一张单一条
  /// 循环写入的。云端的 9 张缺陷单里 6 张没有动作，后处理到「空列表」时会执行
  /// 整表清空，把前面写好的 6 条真实动作全删了——首次填充实测本地 actions=0 行。
  static Future<int> _rewriteChildren(
    SyncTableDao dao,
    String ticketLocalId,
    List<Map<String, Object?>> rows,
  ) async {
    final db = await LocalDb.instance.database;
    return db.transaction<int>(
      (Transaction txn) => _rewriteChildrenIn(txn, dao, ticketLocalId, rows),
    );
  }

  /// [_rewriteChildren] 的事务内版本，供已经开了事务的调用方（详情缓存）复用。
  static Future<int> _rewriteChildrenIn(
    Transaction txn,
    SyncTableDao dao,
    String ticketLocalId,
    List<Map<String, Object?>> rows,
  ) async {
    await dao.deleteSyncedWhere(
      txn,
      '${Col.defectTicketLocalId} = ?',
      <Object?>[ticketLocalId],
    );
    if (rows.isNotEmpty) {
      await dao.insertAll(txn, rows);
    }
    return rows.length;
  }
  /// 缓存**单张**缺陷单的详情（含 actions / verifications）。
  ///
  /// 由详情页在云端刷新成功后调用。为什么需要它：子表刷新只覆盖
  /// `kChildRefreshStatuses` 那几种状态，而 ANALYZED / ACTION_DONE 的单在离线时
  /// 同样要能勾选动作、进入验证——用户刚看过详情页就是最好的缓存时机，
  /// 过期数据由后续刷新覆盖。
  ///
  /// 与 [writeDefectTickets] 的区别：那是整表重写（列表页/首次填充用），
  /// 这里只 upsert 一行，不会把列表刚拉回来的其它单删掉。
  static Future<void> cacheTicketDetail(DefectTicket detail) async {
    final Map<String, Object?> row = <String, Object?>{
      'local_id': detail.id,
      'server_id': detail.id,
      'sync_state': SyncState.synced,
      'user_id': kDemoUserId,
      'q_type': detail.qType,
      'error_layer': detail.errorLayer,
      'error_cause': detail.errorCause,
      'priority': detail.priority.wire,
      'status': detail.status.wire,
      'verification_round': detail.verificationRound,
      'reopen_count': detail.reopenCount,
      'created_at': detail.createdAt.toUtc().toIso8601String(),
      'updated_at': nowIso(),
      'version': detail.version,
    };
    final Database db = await LocalDb.instance.database;
    await db.transaction<void>((Transaction txn) async {
      await LocalDaos.defectTickets.insert(txn, row);
      await _rewriteChildrenIn(
        txn,
        LocalDaos.actions,
        detail.id,
        detail.actions
            .map((DefectAction a) => <String, Object?>{
                  'local_id': a.id,
                  'server_id': a.id,
                  'sync_state': SyncState.synced,
                  'defect_ticket_local_id': detail.id,
                  'content': a.content,
                  'done': a.done ? 1 : 0,
                  'created_at': detail.createdAt.toUtc().toIso8601String(),
                  'updated_at': nowIso(),
                  // R4a：动作行的乐观锁版本号独立于缺陷单，必须原样落库。
                  'version': a.version,
                })
            .toList(),
      );
      final List<Map<String, Object?>> verifications = <Map<String, Object?>>[];
      for (final String stage in const <String>['V1', 'V2', 'V3']) {
        final VerifyResult r = stage == 'V1'
            ? detail.v1
            : stage == 'V2'
                ? detail.v2
                : detail.v3;
        if (r == VerifyResult.pending) continue;
        verifications.add(<String, Object?>{
          'local_id': '${detail.id}:$stage:${detail.verificationRound}',
          'server_id': null,
          'sync_state': SyncState.synced,
          'defect_ticket_local_id': detail.id,
          'stage': stage,
          'round': detail.verificationRound,
          'result': r.wire,
          'created_at': detail.createdAt.toUtc().toIso8601String(),
          'version': 1,
        });
      }
      await _rewriteChildrenIn(
        txn,
        LocalDaos.verifications,
        detail.id,
        verifications,
      );
    });
  }

  /// T8 `mock_exams`（主键 server_id）。
  static Future<int> writeMockExams(List<Map<String, Object?>> rows) =>
      _rewrite(LocalDaos.mockExams, rows.map(mockExamRow).toList());

  /// T9 `review_cycles`（主键 server_id）。
  static Future<int> writeReviewCycles(List<Map<String, Object?>> rows) =>
      _rewrite(LocalDaos.reviewCycles, rows.map(reviewCycleRow).toList());

  /// 单表单事务「删一致行 + 批量插入」。
  static Future<int> _rewrite(SyncTableDao dao, List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) {
      // 空结果也要清掉旧行：服务端删了数据，本地不能继续显示。
      final db = await LocalDb.instance.database;
      return dao.deleteSynced(db);
    }
    final db = await LocalDb.instance.database;
    return db.transaction<int>((txn) async {
      await dao.deleteSynced(txn);
      await dao.insertAll(txn, rows);
      return rows.length;
    });
  }

  // ───────────── 行映射（云端 JSON → 本地表行）─────────────

  static Map<String, Object?> examProfileRow(Map<String, Object?> json) {
    final String? id = text(json['id']);
    return <String, Object?>{
      'local_id': id,
      'server_id': id,
      'sync_state': SyncState.synced,
      'user_id': text(json['user_id']),
      'exam_type': text(json['exam_type']),
      'target_label': text(json['target_label']),
      'target_score': real(json['target_score']),
      'subject_target': jsonText(json['subject_target']),
      'exam_date': text(json['exam_date']),
      'daily_minutes': asInt(json['daily_minutes'], null),
      'source_scope': jsonText(json['source_scope']),
      'baseline': jsonText(json['baseline']),
      'status': text(json['status']),
      'created_at': utcIso(json['created_at']),
      'updated_at': utcIso(json['updated_at']),
      'version': asInt(json['version'], 1),
    };
  }

  static Map<String, Object?> subjectRow(Map<String, Object?> json) {
    final String? id = text(json['id']);
    return <String, Object?>{
      'local_id': id,
      'server_id': id,
      'sync_state': SyncState.synced,
      'exam_profile_id': text(json['exam_profile_id']),
      'name': text(json['name']),
      'kind': text(json['kind']),
      'layer_template_id': text(json['layer_template_id']),
      'created_at': utcIso(json['created_at']),
      'updated_at': utcIso(json['updated_at']),
      'version': asInt(json['version'], 1),
    };
  }

  static Map<String, Object?> knowledgeNodeRow(Map<String, Object?> json) {
    final String? id = text(json['id']);
    return <String, Object?>{
      'local_id': id,
      'server_id': id,
      'sync_state': SyncState.synced,
      'subject_id': text(json['subject_id']),
      'title': text(json['title']),
      'parent_id': text(json['parent_id']),
      'freq_tag': text(json['freq_tag']),
      'weight_to_target': real(json['weight_to_target']) ?? 0,
      'created_at': utcIso(json['created_at']),
      'updated_at': utcIso(json['updated_at']),
      'version': asInt(json['version'], 1),
    };
  }

  /// T4：**刻意丢掉** 4 类列（见 local_schema.dart 的文件头说明）。
  static Map<String, Object?> defectTicketRow(Map<String, Object?> json) {
    final String? id = text(json['id']);
    return <String, Object?>{
      'local_id': id,
      'server_id': id,
      'sync_state': SyncState.synced,
      'user_id': text(json['user_id']),
      'exam_profile_id': text(json['exam_profile_id']),
      'knowledge_node_id': text(json['knowledge_node_id']),
      'question_id': text(json['question_id']),
      'q_type': text(json['q_type']),
      'error_layer': text(json['error_layer']),
      'error_cause': text(json['error_cause']),
      // C3：自定义错因（云端 custom_reason）。
      'custom_reason': text(json['custom_reason']),
      'priority': text(json['priority']),
      'status': text(json['status']) ?? 'DRAFT',
      'verification_round': asInt(json['verification_round'], 1),
      'reopen_count': asInt(json['reopen_count'], 0),
      'reopen_reason': text(json['reopen_reason']),
      'closed_at': utcIso(json['closed_at']),
      'created_at': utcIso(json['created_at']),
      'updated_at': utcIso(json['updated_at']),
      'version': asInt(json['version'], 1),
    };
  }

  static Map<String, Object?> actionRow(Map<String, Object?> json, String ticketLocalId) {
    final String? id = text(json['id']);
    return <String, Object?>{
      'local_id': id,
      'server_id': id,
      'sync_state': SyncState.synced,
      'defect_ticket_local_id': ticketLocalId,
      'content': text(json['content']) ?? '',
      'done': (json['done'] == true) ? 1 : 0,
      'due': utcIso(json['due']),
      'created_at': utcIso(json['created_at']),
      'updated_at': utcIso(json['updated_at']),
      'version': asInt(json['version'], 1),
    };
  }

  static Map<String, Object?> verificationRow(
    Map<String, Object?> json,
    String ticketLocalId,
  ) {
    final String? id = text(json['id']);
    return <String, Object?>{
      'local_id': id,
      'server_id': id,
      'sync_state': SyncState.synced,
      'defect_ticket_local_id': ticketLocalId,
      'stage': text(json['stage']),
      'round': asInt(json['round'], 1),
      'verify_type': text(json['verify_type']),
      'question_id': text(json['question_id']),
      'result': text(json['result']) ?? 'pending',
      'evidence': text(json['evidence']),
      'verified_at': utcIso(json['verified_at']),
      'created_at': utcIso(json['created_at']),
      'version': asInt(json['version'], 1),
    };
  }

  static Map<String, Object?> mockExamRow(Map<String, Object?> json) {
    final String? id = text(json['id']);
    final Object? report = json['report'];
    return <String, Object?>{
      'server_id': id,
      'sync_state': SyncState.synced,
      'exam_profile_id': text(json['exam_profile_id']),
      'mode': text(json['mode']),
      'duration_limit_ms': asInt(json['duration_limit_ms'], null),
      'questions': jsonText(json['questions']),
      'report': jsonText(report),
      // 后端没有 submitted_at 列：有 report 即视为已交卷，用 updated_at 近似。
      'submitted_at': report == null ? null : utcIso(json['updated_at']),
      'created_at': utcIso(json['created_at']),
      'updated_at': utcIso(json['updated_at']),
      'version': asInt(json['version'], 1),
    };
  }

  static Map<String, Object?> reviewCycleRow(Map<String, Object?> json) {
    final String? id = text(json['id']);
    return <String, Object?>{
      'server_id': id,
      'sync_state': SyncState.synced,
      'user_id': text(json['user_id']),
      'cycle_type': text(json['cycle_type']),
      'period': text(json['period']),
      'metrics': jsonText(json['metrics']),
      'completed': (json['completed'] == true) ? 1 : 0,
      'created_at': utcIso(json['created_at']),
      'updated_at': utcIso(json['updated_at']),
      'version': asInt(json['version'], 1),
    };
  }
}

/// 最小首次填充（任务书 B）。
///
/// 返回 true = 本次真的拉取并写入了数据；false = 跳过（已在填充中 / 无 token /
/// 指纹一致无需填充）或失败（见日志与 `local_meta.sync.first_fill.*`）。
Future<bool> ensureInitialData() async {
  final String token = (kApiToken ?? '').trim();
  if (token.isEmpty) {
    AppLogger.instance.warn('FILL', '没有 token，跳过首次填充');
    return false;
  }

  final String fingerprint = Sha256.hex(token).substring(0, 16);
  final db = await LocalDb.instance.database;

  final String? stored = await LocalDaos.meta.getMeta(db, MetaKey.tokenFingerprint);
  final String? completed = await LocalDaos.meta.getMeta(db, _kCompletedKey);

  if (stored == fingerprint && completed == '1') {
    AppLogger.instance.info('FILL', '本地数据已就绪（指纹 $fingerprint），跳过首次填充');
    return false;
  }
  if (stored != null && stored != fingerprint) {
    // 换账号：旧账号的行必须清掉，否则两个账号的数据会混在一张表里（设计 §5 的风险 5）。
    AppLogger.instance.warn('FILL', 'token 指纹变化（$stored → $fingerprint），清空本地缓存后重新填充');
    await _wipeAllSynced(db);
  }

  if (_running) {
    AppLogger.instance.info('FILL', '首次填充已在进行中，跳过重复触发');
    return false;
  }
  _running = true;

  final ApiClient client = ApiClient();
  final Stopwatch watch = Stopwatch()..start();
  try {
    AppLogger.instance.info('FILL', '首次填充开始（指纹 $fingerprint）');

    // ① 考试目标（父）
    final List<Map<String, Object?>> profiles =
        await _pullAll(client, '/users/${_enc(kDemoUserId)}/exam-profiles');
    final int nProfiles = await LocalCache.writeExamProfiles(profiles);

    // ② 科目（子）—— 逐个 profile
    final List<Map<String, Object?>> subjects = <Map<String, Object?>>[];
    for (final Map<String, Object?> p in profiles) {
      final String? pid = text(p['id']);
      if (pid == null) continue;
      subjects.addAll(await _pullAll(client, '/exam-profiles/${_enc(pid)}/subjects'));
    }
    final int nSubjects = await LocalCache.writeSubjects(subjects);

    // ③ 考点（子）—— 逐个 subject
    final List<Map<String, Object?>> nodes = <Map<String, Object?>>[];
    for (final Map<String, Object?> s in subjects) {
      final String? sid = text(s['id']);
      if (sid == null) continue;
      nodes.addAll(await _pullAll(client, '/subjects/${_enc(sid)}/knowledge-nodes'));
    }
    final int nNodes = await LocalCache.writeKnowledgeNodes(nodes);

    // ④ 缺陷单（核心）
    final List<Map<String, Object?>> tickets =
        await _pullAll(client, '/users/${_enc(kDemoUserId)}/defect-tickets');
    final int nTickets = await LocalCache.writeDefectTickets(tickets);

    // ⑤⑥ 动作与验证：只有「详情」端点会返回，逐单补拉。
    final ({int actions, int verifications}) children =
        await _fillTicketChildren(client, tickets);
    final int nActions = children.actions;
    final int nVerifications = children.verifications;

    // ⑦ 模考（按 profile）
    final List<Map<String, Object?>> mocks = <Map<String, Object?>>[];
    for (final Map<String, Object?> p in profiles) {
      final String? pid = text(p['id']);
      if (pid == null) continue;
      mocks.addAll(await _pullAll(client, '/exam-profiles/${_enc(pid)}/mock-exams'));
    }
    final int nMocks = await LocalCache.writeMockExams(mocks);

    // ⑧ 复盘周期
    final List<Map<String, Object?>> cycles =
        await _pullAll(client, '/review-cycles', baseQuery: <String, String>{'user_id': kDemoUserId});
    final int nCycles = await LocalCache.writeReviewCycles(cycles);

    // 水位与指纹
    await LocalDaos.meta.setAll(db, <String, String>{
      MetaKey.tokenFingerprint: fingerprint,
      MetaKey.lastSyncAt: nowIso(),
      MetaKey.schemaVersion: '$kLocalSchemaVersion',
      _kCompletedKey: '1',
      _kErrorKey: '',
      _countKey('exam_profiles'): '$nProfiles',
      _countKey('subjects'): '$nSubjects',
      _countKey('knowledge_nodes'): '$nNodes',
      _countKey('defect_tickets'): '$nTickets',
      _countKey('actions'): '$nActions',
      _countKey('verifications'): '$nVerifications',
      _countKey('mock_exams'): '$nMocks',
      _countKey('review_cycles'): '$nCycles',
    });

    kLocalDataRevision.value++;
    AppLogger.instance.info(
      'FILL',
      '首次填充完成：档案 $nProfiles / 科目 $nSubjects / 考点 $nNodes / 缺陷单 $nTickets / '
          '动作 $nActions / 验证 $nVerifications / 模考 $nMocks / 复盘 $nCycles，'
          '耗时 ${watch.elapsedMilliseconds}ms',
    );
    return true;
  } catch (e, stack) {
    await LocalDaos.meta.setAll(db, <String, String>{
      _kCompletedKey: '0',
      _kErrorKey: '$e',
    });
    AppLogger.instance.error(
      'FILL',
      '首次填充失败（页面会用本地已有数据或显示加载态），下次启动重试：$e',
      stackTrace: stack.toString(),
    );
    return false;
  } finally {
    client.close();
    _running = false;
  }
}

/// 首次填充是否已经成功完成过（任务书 C5：未完成时页面显示加载态而非空状态）。
Future<bool> isFirstFillComplete() async {
  final db = await LocalDb.instance.database;
  final String? completed = await LocalDaos.meta.getMeta(db, _kCompletedKey);
  return completed == '1';
}

/// 本地库是否一条业务数据都没有（设置页「数据同步」展示用）。
Future<int> localDefectCount() async {
  final db = await LocalDb.instance.database;
  return LocalDaos.defectTickets.count(db);
}

bool _running = false;

const String _kCompletedKey = 'sync.first_fill.completed';
const String _kErrorKey = 'sync.first_fill.error';

String _countKey(String resource) => MetaKey.sync(resource, 'row_count');

/// 逐单补拉详情，把 actions / verifications 落本地。
///
/// 为什么必须补：列表端点**不返回**这两个数组（`server/routes/defect_tickets.mjs`
/// 只有详情分支带 `verifications` + `actions`），而本地算 urgency 要
/// `verifications` 里「上一阶段 pass 的 created_at」，详情页要 `actions`。
///
/// 返回 `(actions, verifications)` 两类的**实际写入行数**（不是单数），便于日志
/// 与 `sync.actions.row_count` 对账。注意：一张单没有动作时也会把该单名下旧行
/// 删干净（[LocalCache.writeActions] 按父键范围重写），所以「没有」与「还没拉」
/// 在本地是能区分开的两件事。
Future<({int actions, int verifications})> _fillTicketChildren(
  ApiClient client,
  List<Map<String, Object?>> tickets,
) async {
  int nActions = 0;
  int nVerifications = 0;
  int fetched = 0;
  int skipped = 0;

  for (final Map<String, Object?> json in tickets) {
    final String? id = text(json['id']);
    if (id == null) continue;
    // 上限按「已补拉的张数」算，不能按写入行数算：没有动作的单永远不增长。
    if (fetched >= kFillMaxDetailTickets) {
      skipped++;
      continue;
    }
    try {
      final Object? raw = await client.get('/defect-tickets/${_enc(id)}');
      if (raw is! Map) continue;
      final Map<String, Object?> detail = raw.cast<String, Object?>();
      final Object? actions = detail['actions'];
      final Object? verifications = detail['verifications'];
      if (actions is List) {
        nActions += await LocalCache.writeActions(id, actions);
      }
      if (verifications is List) {
        nVerifications += await LocalCache.writeVerifications(id, verifications);
      }
      fetched++;
    } catch (e) {
      // 单条详情失败不影响整体：列表数据已在，R3 的对账会补齐。
      AppLogger.instance.warn('FILL', '缺陷单 $id 详情拉取失败（跳过）：$e');
    }
  }

  if (skipped > 0) {
    AppLogger.instance.warn(
      'FILL',
      '缺陷单共 ${tickets.length} 张，补拉详情上限 $kFillMaxDetailTickets，'
          '跳过 $skipped 张（其动作/验证在本地暂缺，R3 同步会补齐）',
    );
  }
  return (actions: nActions, verifications: nVerifications);
}

/// 换账号：清掉所有「与云端一致」的本地行与水位（保留待推送队列，虽然 R2 还没有）。
Future<void> _wipeAllSynced(DatabaseExecutor db) async {
  for (final SyncTableDao dao in LocalDaos.all) {
    await dao.deleteSynced(db);
  }
  await LocalDaos.meta.deleteAll(db);
}

/// 通用分页拉取：`limit/offset` + 「`items.length < limit` 即最后一页」。
Future<List<Map<String, Object?>>> _pullAll(
  ApiClient client,
  String path, {
  Map<String, String>? baseQuery,
}) async {
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  int offset = 0;
  for (int page = 0; page < kFillMaxPages; page++) {
    final Map<String, String> query = <String, String>{
      ...?baseQuery,
      'limit': '$kFillPageSize',
      'offset': '$offset',
    };
    final Object? raw = await client.get(path, query: query);
    final List<Map<String, Object?>> items = extractItems(raw);
    out.addAll(items);
    if (items.length < kFillPageSize) return out;
    offset += items.length;
  }
  AppLogger.instance.warn('FILL', '$path 拉到 $kFillMaxPages 页仍未结束，已截断（共 ${out.length} 行）');
  return out;
}

/// 列表响应 → 行数组；容错裸数组与 `{items: [...]}`。
List<Map<String, Object?>> extractItems(Object? raw) {
  Object? listLike = raw;
  if (raw is Map) {
    final Object? items = raw['items'];
    if (items == null) return const <Map<String, Object?>>[];
    listLike = items;
  }
  if (listLike is! List) return const <Map<String, Object?>>[];
  return listLike
      .whereType<Map>()
      .map((Map m) => m.cast<String, Object?>())
      .toList(growable: false);
}

String _enc(String value) => Uri.encodeComponent(value);

// ───────────── 值转换（与 dao_base.toLocalValue 的约定保持一致）─────────────

/// 文本：trim 后空串归一成 null（本地表用 NULL 表示「没有」，不用 ''）。
String? text(Object? value) {
  if (value == null) return null;
  final String s = '$value'.trim();
  return s.isEmpty ? null : s;
}

int? asInt(Object? value, int? fallback) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

double? real(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

/// JSON 列：字符串原样存，Map/List 序列化，null 保持 null。
String? jsonText(Object? value) {
  if (value == null) return null;
  if (value is String) return value.isEmpty ? null : value;
  return jsonEncode(value);
}

/// 时间列：统一 ISO 8601 **UTC** 字符串（与 `Col.createdAt` 的消费方式一致）。
String? utcIso(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc().toIso8601String();
  final DateTime? parsed = DateTime.tryParse('$value');
  return parsed?.toUtc().toIso8601String();
}
