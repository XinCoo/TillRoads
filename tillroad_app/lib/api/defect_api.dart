// 缺陷单 API（FE-03 联调）。
//
// 职责：把后端 JSON 映射成界面已在用的 `DefectTicket`。
// 手写映射而不是 json_serializable —— 任务书明确不引序列化库，
// 而且这里要处理三处**后端与界面模型的真实差异**（见下方注释），
// 代码生成器反而会把差异藏起来。
//
// ── 与后端契约的三处差异（已用 curl 实测确认，不是猜测）────────────────────
//
// 1) 后端返回 `status`，界面模型叫 `stage` 语义（V1/V2/V3 是"阶段"）。
//    这里读 `status`，映射到 DefectStatus。
//
// 2) 后端 `GET /users/:id/defect-tickets` 与 `GET /defect-tickets/:id` 都用
//    `SELECT *`，**不 JOIN** knowledge_nodes / subjects，响应里既没有
//    `knowledge_node_title` 也没有 `subject_name`（只有 id）。
//    → 考点名退化为「考点 {id 前 8 位}」，科目名留空字符串。
//    这是后端待补的 JOIN，已记入遗留项；前端不伪造中文名。
//
// 3) 后端 `defect_tickets.verification_state` 这个 jsonb 列恒为默认值
//    `{"v1":"pending","v2":"pending","v3":"pending"}` —— 它由写路径维护，
//    而 seed / 当前写接口并未同步它。真正可信的验证结果是
//    `verifications` 数组（每条有 stage/round/result）。
//    → 详情页从 `verifications` 推导 v1/v2/v3；列表页不需要该字段。
//
// 另外：后端没有 `defect_events` 表，所以 `statusHistory` 无法造假历史，
// 只按「创建時間 + 当前状态」构造两个节点（任务书 C3 已明确此取舍）。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../mock/defects_mock.dart';
import 'api_client.dart';
// 题型中文标签复用题库层的唯一口径（kQuestionTypeLabels），避免同一个题型
// 在题库页和缺陷单里显示成两个名字。
import 'question_api.dart';
class DefectApi {
  DefectApi({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  /// 排序端点用的是 `PUT`，而 `ApiClient` 只封装了 get/post/patch/delete，
  /// 且 `api_client.dart` 不在本轮可改文件范围内 → 这里自建一条最小 PUT 通道
  /// （独立 http client，基址与 Authorization 头沿用全局配置）。
  final http.Client _putClient = http.Client();

  /// 列表：`GET /users/:userId/defect-tickets?status=...`
  ///
  /// [status] 支持**逗号分隔多值**（如 `'V1,V2,V3'`）—— 后端 `listByUser`
  /// 自 FE-03 写操作联调起用 `status::text = ANY($n::text[])` 匹配，
  /// 因此「待验证」分组可以直接交给服务端过滤，不必拉全量。
  /// 仍保留本地兜底（见 defects_page 的 `_visible`），两边语义一致。
  Future<List<DefectTicket>> fetchDefectTickets(
    String userId, {
    String? status,
    int? limit,
  }) async {
    final query = <String, String>{};
    if (status != null && status.isNotEmpty) query['status'] = status;
    if (limit != null) query['limit'] = '$limit';

    final raw = await _client.get(
      '/users/${Uri.encodeComponent(userId)}/defect-tickets',
      query: query.isEmpty ? null : query,
    );

    final items = _extractItems(raw);
    return items.map(_ticketFromJson).toList(growable: false);
  }

  /// 详情：`GET /defect-tickets/:id`，响应比列表多 `verifications` 与 `actions`。
  Future<DefectTicket> fetchDefectDetail(String id) async {
    final raw = await _client.get('/defect-tickets/${Uri.encodeComponent(id)}');
    if (raw is! Map) {
      throw ApiException('详情响应不是 JSON 对象', body: raw);
    }
    final map = raw.cast<String, Object?>();
    final verifications = map['verifications'];
    return _ticketFromJson(
      map,
      verifications: verifications is List ? verifications : const <Object?>[],
    );
  }

  /// 后端返回 `{ items: [...], limit, offset }`；容错单个对象 / 裸数组。
  List<Map<String, Object?>> _extractItems(Object? raw) {
    if (raw is Map) {
      final items = raw['items'];
      if (items is List) {
        return items
            .whereType<Map>()
            .map((m) => m.cast<String, Object?>())
            .toList(growable: false);
      }
      return const [];
    }
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((m) => m.cast<String, Object?>())
          .toList(growable: false);
    }
    throw ApiException('列表响应格式不符合预期', body: raw);
  }

  DefectTicket _ticketFromJson(
    Map<String, Object?> json, {
    List<Object?> verifications = const <Object?>[],
  }) {
    final status = DefectStatus.fromWire(_str(json['status']));
    final nodeId = _str(json['knowledge_node_id']);

    // 差异 (2)：后端不 JOIN，拿不到考点中文名 —— 用 id 短码占位，不伪造。
    final nodeTitle = _str(json['knowledge_node_title']);
    final fallbackTitle =
        nodeId.isEmpty ? '未关联考点' : '考点 ${nodeId.substring(0, 8)}';

    final actions = _actionsFromJson(json['actions']);
    // round 用后端派生列（DB 触发器在 REOPENED→ANALYZED 时 +1）
    final round = _int(json['verification_round'], 1);
    final results = _verifyResults(status, verifications, currentRound: round);
    return DefectTicket(
      id: _str(json['id']),
      qType: _nullableText(json['q_type'], fallback: '未分类题型'),
      // 差异 (1)：DRAFT 单没有归因（P0-3 允许 null），界面模型要求非空字符串
      errorLayer: _nullableText(json['error_layer'], fallback: '未归因'),
      errorCause: _nullableText(json['error_cause'], fallback: '尚未填写归因说明'),
      // C3：自定义错因（云端 custom_reason），没有就空串。
      customReason: _str(json['custom_reason']),
      // 后端可能没有 priority 列值（可空）
      priority: DefectPriority.fromWire(_str(json['priority'])),
      status: status,
      verificationRound: _int(json['verification_round'], 1),
      reopenCount: _int(json['reopen_count'], 0),
      createdAt: _date(json['created_at']),
      knowledgeNodeId: nodeId,
      knowledgeNodeTitle: nodeTitle.isEmpty ? fallbackTitle : nodeTitle,
      subjectName: _str(json['subject_name']),
      actions: actions,
      v1: results[VerifyStage.v1] ?? VerifyResult.pending,
      v2: results[VerifyStage.v2] ?? VerifyResult.pending,
      v3: results[VerifyStage.v3] ?? VerifyResult.pending,
      // 无 defect_events 表：只构造「创建 → 当前状态」两个节点（任务书 C3）
      statusHistory: _minimalHistory(status, _date(json['created_at'])),
      // 乐观锁版本号：写请求必须带，后端 +1 后返回新行
      version: _int(json['version'], 1),
    );
  }

  /// 差异 (3)：从 `verifications` 数组推导 v1/v2/v3，而非读恒为 pending 的
  /// `verification_state` jsonb。
  ///
  /// 取法：只看**当前 round** 的记录（重开后旧 round 的历史不应覆盖新进度），
  /// 同一 stage 若有多条（理论上唯一索引防住了），取最后一条。
  Map<VerifyStage, VerifyResult> _verifyResults(
    DefectStatus status,
    List<Object?> verifications, {
    required int currentRound,
  }) {
    final out = <VerifyStage, VerifyResult>{};
    for (final v in verifications) {
      if (v is! Map) continue;
      // 只看当前 round：重开后旧 round 的 pass 不应把新 round 误显示为已通过。
      // （v2/v3 的 pass 会推进状态，但 round 1 的历史记录仍在库里）
      final round = _int(v['round'], 1);
      if (round != currentRound) continue;
      final stage = _str(v['stage']).toUpperCase();
      final parsed = switch (stage) {
        'V1' => VerifyStage.v1,
        'V2' => VerifyStage.v2,
        'V3' => VerifyStage.v3,
        _ => null,
      };
      if (parsed == null) continue;
      // 失败记录优先保留：同一 stage 在 DB 有唯一约束，但 round 维度下
      // 可能出现「先 fail 后 pass」的历史，取最后一条更贴近当前状态。
      out[parsed] = VerifyResult.fromWire(_str(v['result']));
    }
    return out;
  }

  static List<DefectAction> _actionsFromJson(Object? raw) {
    if (raw is! List) return const <DefectAction>[];
    return raw.whereType<Map>().map((m) {
      final map = m.cast<String, Object?>();
      return DefectAction(
        id: _str(map['id']),
        content: _str(map['content']),
        done: map['done'] == true,
        // R4a：actions 行的乐观锁版本号，和缺陷单的 version 是两套。
        version: _int(map['version'], 1),
      );
    }).toList(growable: false);
  }

  static List<StatusEvent> _minimalHistory(DefectStatus status, DateTime created) {
    final events = <StatusEvent>[StatusEvent(status: DefectStatus.draft, at: created)];
    if (status != DefectStatus.draft) {
      events.add(StatusEvent(status: status, at: DateTime.now()));
    }
    return events;
  }

  static String _str(Object? v) => v == null ? '' : '$v';

  static String _nullableText(Object? v, {required String fallback}) {
    final s = _str(v).trim();
    return s.isEmpty ? fallback : s;
  }

  static int _int(Object? v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static DateTime _date(Object? v) {
    if (v is String && v.isNotEmpty) {
      // 后端 timestamptz 由 pool.mjs 的 parser 转成 ISO 8601 UTC 字符串
      return DateTime.tryParse(v)?.toLocal() ?? DateTime.now();
    }
    return DateTime.now();
  }

  // ── 写操作（FE-03 写操作联调）──────────────────────────────────────────
  //
  // 统一约定：
  //   * 所有写请求都带 `version`（乐观锁）。后端 0 行命中 → 409 + 当前行，
  //     页面必须提示用户刷新，不能静默失败。
  //   * 后端写方法走 `updateWithVersion(... RETURNING *)`，返回的是**裸行**
  //     （不带 LEFT JOIN 的 knowledge_node_title / subject_name）。
  //     因此写方法一律返回 `void`，调用方写完重新 `fetchDefectDetail`，
  //     避免把占位考点名写回界面造成信息丢失。

  /// 建单：`POST /defect-tickets`。
  ///
  /// [draft] 为 true 时后端建 DRAFT（允许无归因）；否则 ANALYZED（必须带归因）。
  /// 返回后端建好的裸行（含 id 与初始 version）。
  ///
  /// 已知的**后端契约缺口**（本轮不改后端写方法）：`POST /defect-tickets` 只
  /// 把 [actions] 写进 `defect_tickets.actions` 这个 jsonb 列，**不会**在
  /// `actions` 表里生成行；而 `PATCH /:id/begin-verification` 的门禁
  /// `actions.assertAllDone()` 读的是 `actions` 表（0 行 → `NO_ACTIONS`）。
  /// → 所以拿回 201 后，在此逐条 `POST /:id/actions` 把它们落成真实行。
  Future<Map<String, Object?>> createDefectTicket({
    required String userId,
    required String examProfileId,
    required String qType,
    required String errorCause,
    String? errorLayer,
    String? knowledgeNodeId,
    String? priority,
    String? questionId,
    /// 自定义错因文本（≤30 字）；为空则不提交该字段。
    String? customReason,
    List<String> actions = const <String>[],
    bool draft = false,
  }) async {
    final payload = <String, Object?>{
      'user_id': userId,
      'exam_profile_id': examProfileId,
      'q_type': qType,
      'error_cause': errorCause,
      if (customReason != null && customReason.trim().isNotEmpty)
        'custom_reason': customReason.trim(),
      if (errorLayer != null && errorLayer.isNotEmpty) 'error_layer': errorLayer,
      if (knowledgeNodeId != null && knowledgeNodeId.isNotEmpty)
        'knowledge_node_id': knowledgeNodeId,
      if (priority != null && priority.isNotEmpty) 'priority': priority,
      if (questionId != null && questionId.isNotEmpty)
        'question_id': questionId,
      if (actions.isNotEmpty) 'actions': actions,
      if (draft) 'status': 'DRAFT',
    };
    final raw = await _client.post('/defect-tickets', body: payload);
    if (raw is! Map) throw ApiException('建单响应不是 JSON 对象', body: raw);
    final Map<String, Object?> ticket = raw.cast<String, Object?>();

    // 把动作落成 actions 表的真实行，否则永远进不了验证（NO_ACTIONS）。
    final Object? id = ticket['id'];
    if (actions.isNotEmpty && id != null) {
      final String encoded = Uri.encodeComponent('$id');
      for (final String content in actions) {
        final String trimmed = content.trim();
        if (trimmed.isEmpty) continue;
        await _client.post(
          '/defect-tickets/$encoded/actions',
          body: <String, Object?>{'action': trimmed},
        );
      }
    }
    return ticket;
  }

  /// 归因：`PATCH /defect-tickets/:id/analyze`（DRAFT 或 REOPENED 补齐归因）。
  ///
  /// 带 `status: 'REOPENED'` 时后端走 `reanalyze`（校验必须是 REOPENED，
  /// 并由 DB 触发器把 verification_round +1）。
  Future<void> analyzeDefectTicket(
    String id, {
    required String errorLayer,
    required String errorCause,
    required int version,
    /// 自定义错因文本（≤30 字）；为空则不提交该字段。
    String? customReason,
    bool reopened = false,
  }) async {
    await _client.patch(
      '/defect-tickets/${Uri.encodeComponent(id)}/analyze',
      body: <String, Object?>{
        'error_layer': errorLayer,
        'error_cause': errorCause,
        if (customReason != null && customReason.trim().isNotEmpty)
          'custom_reason': customReason.trim(),
        'version': version,
        if (reopened) 'status': 'REOPENED',
      },
    );
  }

  /// 标记动作完成/取消：`PATCH /defect-tickets/:ticketId/actions/:actionId`。
  Future<void> markActionDone(
    String ticketId,
    String actionId, {
    required bool done,
    required int version,
  }) async {
    await _client.patch(
      '/defect-tickets/${Uri.encodeComponent(ticketId)}'
      '/actions/${Uri.encodeComponent(actionId)}',
      body: <String, Object?>{'done': done, 'version': version},
    );
  }

  /// 进入验证：`PATCH /defect-tickets/:id/begin-verification`。
  ///
  /// 后端会先校验「至少一条动作且全部完成」，再把 ANALYZED → ACTION_DONE → V1
  /// 两步写在同一个事务里（DB 触发器只接受逐步跳）。
  Future<void> beginVerification(String id, {required int version}) async {
    await _client.patch(
      '/defect-tickets/${Uri.encodeComponent(id)}/begin-verification',
      body: <String, Object?>{'version': version},
    );
  }

  /// 提交验证：`POST /defect-tickets/:id/verifications`。
  ///
  /// [stage] 必须在当前阶段（V1/V2/V3），否则后端 400 INVALID_VERIFICATION_STAGE。
  /// [verifyType] 受阶段白名单约束（见 `verifyTypesForStage`）。
  Future<void> submitVerification(
    String id, {
    required String stage,
    required String result,
    required String verifyType,
    required int version,
    String? questionId,
    String? evidence,
  }) async {
    await _client.post(
      '/defect-tickets/${Uri.encodeComponent(id)}/verifications',
      body: <String, Object?>{
        'stage': stage,
        'result': result,
        'verify_type': verifyType,
        'version': version,
        if (questionId != null && questionId.trim().isNotEmpty)
          'question_id': questionId.trim(),
        if (evidence != null && evidence.trim().isNotEmpty)
          'evidence': evidence.trim(),
      },
    );
  }

  /// 拉考点树：`GET /subjects/:id/knowledge-nodes`，供建单表单选择考点。
  /// 返回 `[{id, title, freq_tag, parent_id}]`。
  Future<List<Map<String, Object?>>> fetchKnowledgeNodes(String subjectId) async {
    final raw = await _client.get(
      '/subjects/${Uri.encodeComponent(subjectId)}/knowledge-nodes',
      query: const <String, String>{'limit': '200'},
    );
    return _extractItems(raw);
  }

  /// 取当前用户的考试目标（建单需要 `exam_profile_id`）。
  Future<List<Map<String, Object?>>> fetchExamProfiles(
    String userId, {
    Duration? timeout,
  }) async {
    final raw = await _client.get(
      '/users/${Uri.encodeComponent(userId)}/exam-profiles',
      timeout: timeout,
    );
    return _extractItems(raw);
  }

  /// 列主题列表：`GET /exam-profiles/:id/subjects`（建单页先选科目再选考点）。
  Future<List<Map<String, Object?>>> fetchSubjects(
    String examProfileId, {
    Duration? timeout,
  }) async {
    final raw = await _client.get(
      '/exam-profiles/${Uri.encodeComponent(examProfileId)}/subjects',
      timeout: timeout,
    );
    return _extractItems(raw);
  }

  /// 缺陷聚合统计：`GET /users/:id/defect-stats`（FE-07 首页缺陷分布用）。
  ///
  /// 返回 `{by_layer:[{error_layer,count}], by_status:{八态}, open_total, closed_total, total}`。
  /// `by_layer` 只统计未关闭的单（后端口径），`unclassified` 是 `error_layer` 为空的归处。
  ///
  /// 为什么不在前端 `GROUP BY`：①列表页已经拉过全量，首页再拉一次就是两次全量；
  /// ②「未关闭」的业务定义只应有一处（`status != 'CLOSED'`），两边各写一遍必然漂移；
  /// ③八态计数一次 `GROUP BY` 算完，不会漏键。
  Future<Map<String, Object?>> fetchDefectStats(String userId) async {
    final raw = await _client.get(
      '/users/${Uri.encodeComponent(userId)}/defect-stats',
    );
    if (raw is Map<String, Object?>) return raw;
    if (raw is Map) return raw.cast<String, Object?>();
    throw ApiException('缺陷统计响应形状异常：${raw.runtimeType}');
  }

  /// 题型下拉的选项来源：`GET /question-types?scope=imported&q=<关键词>`。
  ///
  /// 后端返回 `{items:[{type,count}], total, scope}`，按 count DESC。
  /// [scope] 可选：
  ///   - `imported`（默认）：只统计 `source='import'` 的题 —— 也就是用户**自己导入**的题，
  ///     这才是「这个用户真正会做的题型」；
  ///   - `all`：统计全部题（含公共题/示例题）。
  ///
  /// 这里返回**去重后**的列表（同名 type 只保留一条），顺序沿用后端的 count DESC。
  Future<List<QuestionTypeCount>> fetchQuestionTypes({
    String scope = 'imported',
    String? q,
  }) async {
    final Map<String, String> query = <String, String>{'scope': scope};
    if (q != null && q.trim().isNotEmpty) query['q'] = q.trim();
    final Object? raw = await _client.get('/question-types', query: query);
    final List<Map<String, Object?>> items = _extractItems(raw);
    final List<QuestionTypeCount> result = <QuestionTypeCount>[];
    final Set<String> seen = <String>{};
    for (final Map<String, Object?> item in items) {
      final QuestionTypeCount count = QuestionTypeCount.fromJson(item);
      if (count.type.isEmpty || !seen.add(count.type)) continue;
      result.add(count);
    }
    return result;
  }

  /// 历史自定义错因（可复用）：`GET /defect-tickets/custom-reasons?exam_profile_id=<uuid>`。
  ///
  /// 返回 `{items:[{custom_reason,count}]}`，只含**当前用户自己**用过的自定义错因。
  /// [examProfileId] 可选，传了就按考试目标过滤。
  Future<List<String>> fetchCustomReasons({String? examProfileId}) async {
    final Map<String, String> query = <String, String>{};
    if (examProfileId != null && examProfileId.trim().isNotEmpty) {
      query['exam_profile_id'] = examProfileId.trim();
    }
    final Object? raw = await _client.get(
      '/defect-tickets/custom-reasons',
      query: query,
    );
    final List<Map<String, Object?>> items = _extractItems(raw);
    final List<String> reasons = <String>[];
    final Set<String> seen = <String>{};
    for (final Map<String, Object?> item in items) {
      final String reason = (item['custom_reason'] ?? '').toString().trim();
      if (reason.isEmpty || !seen.add(reason)) continue;
      reasons.add(reason);
    }
    return reasons;
  }

  /// 单个缺陷单的 `custom_reason`：`GET /defect-tickets/:id`。
  ///
  /// `DefectTicket`（`defects_mock.dart`，不可改）里没有这个字段，归因页要回填
  /// 「自定义错因」只能从详情响应里单独取。取不到返回 null。
  Future<String?> fetchTicketCustomReason(String ticketId) async {
    final Object? raw = await _client.get(
      '/defect-tickets/${Uri.encodeComponent(ticketId)}',
    );
    if (raw is! Map) return null;
    final Object? value = raw.cast<String, Object?>()['custom_reason'];
    final String text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }

  /// 详情接口里顺带返回的 `questions` 数组：`GET /defect-tickets/:id`。
  ///
  /// 为什么单独开一个方法：`DefectTicket`（`defects_mock.dart`，不可改）里没有
  /// 题目字段，而任务书要求详情页刷新时能顺带把关联题目带回来 —— 这里只取
  /// `questions` 数组，解析成 [DefectLinkedQuestion]。
  Future<List<DefectLinkedQuestion>> fetchDetailQuestions(String ticketId) async {
    final Object? raw = await _client.get(
      '/defect-tickets/${Uri.encodeComponent(ticketId)}',
    );
    if (raw is! Map) return const <DefectLinkedQuestion>[];
    final Object? list = raw.cast<String, Object?>()['questions'];
    if (list is! List) return const <DefectLinkedQuestion>[];
    return list
        .whereType<Map>()
        .map((Map m) => DefectLinkedQuestion.fromJson(m.cast<String, Object?>()))
        .toList(growable: false);
  }

  /// 关联题目列表：`GET /defect-tickets/:id/questions`（按 sort ASC）。
  Future<List<DefectLinkedQuestion>> fetchLinkedQuestions(String ticketId) async {
    final Object? raw = await _client.get(
      '/defect-tickets/${Uri.encodeComponent(ticketId)}/questions',
    );
    final List<Map<String, Object?>> items = _extractItems(raw);
    return items
        .map(DefectLinkedQuestion.fromJson)
        .toList(growable: false);
  }

  /// 关联一道题：`POST /defect-tickets/:id/questions`，body `{question_id}`。
  ///
  /// 后端对重复关联返回 409 `duplicate_defect_question` —— 这里把 [ApiException]
  /// 原样抛出（`body` 里带 `error` 字段），由页层转成「该题目已关联此缺陷单」。
  Future<void> linkQuestion(String ticketId, String questionId) async {
    await _client.post(
      '/defect-tickets/${Uri.encodeComponent(ticketId)}/questions',
      body: <String, Object?>{'question_id': questionId},
    );
  }

  /// 取消关联：`DELETE /defect-tickets/:id/questions/:questionId`。
  Future<void> unlinkQuestion(String ticketId, String questionId) async {
    await _client.delete(
      '/defect-tickets/${Uri.encodeComponent(ticketId)}'
      '/questions/${Uri.encodeComponent(questionId)}',
    );
  }

  /// 重排关联题目：`PUT /defect-tickets/:id/questions/sort`，body `{ids:[...]}`。
  ///
  /// [questionIds] 必须是**目标顺序**的 question_id 列表；列表里混入不属于该单的
  /// id 时后端返回 400 `INVALID_SORT_LIST`（同样以 [ApiException] 抛出）。
  Future<void> reorderLinkedQuestions(
    String ticketId,
    List<String> questionIds,
  ) async {
    await _putJson(
      '/defect-tickets/${Uri.encodeComponent(ticketId)}/questions/sort',
      body: <String, Object?>{
        'ids': questionIds.map((String id) => id).toList(growable: false),
      },
    );
  }

  /// 可供关联的题目候选：`GET /questions?limit=<limit>`。
  ///
  /// 为什么自己实现而不复用 `QuestionApi.fetchQuestions`：`question_api.dart`
  /// 不在本轮可改文件范围内，而且建单/详情页只需要 id / stem / type 这三个
  /// 最小字段，没必要把整套题库模型拉进来。
  Future<List<SelectableQuestion>> fetchSelectableQuestions({
    int limit = 50,
    int offset = 0,
  }) async {
    final Object? raw = await _client.get(
      '/questions',
      query: <String, String>{
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    final List<Map<String, Object?>> items = _extractItems(raw);
    return items
        .map(SelectableQuestion.fromJson)
        .where((SelectableQuestion q) => q.id.isNotEmpty)
        .toList(growable: false);
  }

  void close() {
    _client.close();
    _putClient.close();
  }

  /// 发一个 PUT 请求（目前只有「关联题目排序」用）。
  ///
  /// 语义与 `ApiClient` 保持一致：2xx 返回响应体；非 2xx 抛 [ApiException]，
  /// 且 `body` 里保留后端业务码（如 `INVALID_SORT_LIST`），这样上层可以
  /// 像处理其它接口那样按业务码给用户不同的提示。
  Future<Object?> _putJson(
    String path, {
    required Map<String, Object?> body,
  }) async {
    final Uri uri = buildApiUri(kApiBaseUrl, path);
    final http.Request request = http.Request('PUT', uri)
      ..headers['Accept'] = 'application/json'
      ..headers['Content-Type'] = 'application/json; charset=utf-8';
    final String? token = kApiToken;
    if (token != null && token.trim().isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${token.trim()}';
    }
    request.body = jsonEncode(body);

    final http.StreamedResponse streamed = await _putClient
        .send(request)
        .timeout(kApiTimeout);
    final String raw = await streamed.stream.bytesToString();
    Object? decoded;
    if (raw.isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        decoded = raw;
      }
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final Object? hint =
          decoded is Map && decoded['error'] != null ? decoded['error'] : null;
      throw ApiException(
        hint == null
            ? '后端返回 ${streamed.statusCode}'
            : '后端返回 ${streamed.statusCode}（$hint）',
        statusCode: streamed.statusCode,
        body: decoded,
        uri: uri,
      );
    }
    return decoded;
  }
}

/// 内部用：三个验证阶段的稳定键，避免用字符串做 map key。
enum VerifyStage { v1, v2, v3 }

/// 验证类型的中文标签与**阶段白名单**（与 `core/index.mjs` 的 `STAGE_WINDOWS` 一致）。
///
/// 注意：任务书里写「V3 只能选限时模考/讲题」，但后端 `core/index.mjs:40-44`
/// 的 `STAGE_WINDOWS.V3.types` 只有 `['timed_mock']`，`teach_back` 属于 V1。
/// 前端按 core 常量走（否则 V3 选讲题会被后端 400 拒），不一致已记入答复。
const Map<String, String> kVerifyTypeLabels = <String, String>{
  'redo_hidden': '无答案重做',
  'similar_variant': '同类变式',
  'new_question': '新题识别',
  'timed_mock': '限时模考',
  'teach_back': '讲题',
  'peer_check': '同伴抽验',
};

/// 某阶段允许的验证类型（顺序与 core 白名单一致，便于界面稳定排序）。
List<String> verifyTypesForStage(String stage) => switch (stage.toUpperCase()) {
      'V1' => const <String>['redo_hidden', 'similar_variant', 'teach_back'],
      'V2' => const <String>['new_question'],
      'V3' => const <String>['timed_mock'],
      _ => const <String>[],
    };

/// 错因层级候选。
///
/// 后端 `defect_tickets.error_layer` 是 **text 自由文本**（`schema.sql:299`），
/// 不是枚举，所以这里只管界面选项；用户仍可能从其他端写入自定义层级，
/// 前端展示时应以接口返回值为准（不在这里做白名单校验）。
/// 取值来自开发文档 `题路TillRoad-开发文档初稿.md:499`「行测六层」。
const List<String> kErrorLayerOptions = <String>[
  '知道',
  '识别',
  '执行',
  '抗压',
  '策略取舍',
  '稳定迁移',
  kCustomErrorLayerValue,
];

/// 「自定义」哨兵值 —— **只是 UI 层的第 7 个选项**，不是后端 `error_layer` 的取值。
///
/// 后端 `defect_tickets.error_layer` 是自由文本，但工程内其它地方（统计、筛选、
/// 练习模式默认值）都按「行测六层」枚举使用它。若把「自定义」两个字直接当作
/// `error_layer` 传上去，这些按枚举口径统计的地方就会多出一个层级。
/// → 约定：选「自定义」时，`error_layer` 仍传六层枚举里的一个值（缺省
/// [kPracticeDefaultErrorLayer]），用户填的文本走新字段 `custom_reason`。
const String kCustomErrorLayerValue = '自定义';
/// 练习模式 R2：自动建缺陷单时用的默认错因层级。
///
/// 从「行测六层」里挑最接近「练习中没掌握」的一层 —— 其实是**识别**层：
/// 练习没做对，多半是「当时就没想起来/没认出来」，而不是执行算错了。
/// 后端 `error_layer` 是自由文本，这里只是给个合理默认值。
const String kPracticeDefaultErrorLayer = '识别';

/// 禁用语（与 `core/index.mjs:29-31` 的 `FORBIDDEN_PHRASES` 逐字一致）。
/// 前端做**内联预校验**，减少一次往返；后端仍是最终权威。
const List<String> kForbiddenPhrases = <String>[
  '粗心',
  '马虎',
  '没掌握',
  '我懂了',
  '大意',
  '差不多',
  '忘了',
];

/// 返回文本中命中的禁用语（空列表表示通过）。
List<String> findForbiddenPhrases(String text) =>
    kForbiddenPhrases.where(text.contains).toList(growable: false);

/// 缺陷单关联的一道题（`GET /defect-tickets/:id/questions` 的一项）。
///
/// 后端字段：`id`(关联记录 id) / `question_id` / `sort` / `stem` / `type` /
/// `source` / `difficulty` / `created_at`。
class DefectLinkedQuestion {
  const DefectLinkedQuestion({
    required this.id,
    required this.questionId,
    required this.sort,
    required this.stem,
    required this.type,
    required this.source,
    required this.difficulty,
    required this.createdAt,
  });

  /// 关联记录自身的 id（不是题目 id）。
  final String id;

  /// 题目 id（关联/移除/排序都用它）。
  final String questionId;

  /// 排序序号（小的在前）。
  final int sort;

  /// 题干（可能很长，列表里截断显示）。
  final String stem;

  /// 题型原始值（如 `choice`）。
  final String type;

  /// 题目来源（如 `import`）。
  final String source;

  /// 难度（后端可能是数字或字符串，统一成字符串）。
  final String difficulty;

  /// 关联时间。
  final DateTime? createdAt;

  /// 题型中文标签（复用题库层口径）。
  String get typeLabel => questionTypeLabel(type);

  factory DefectLinkedQuestion.fromJson(Map<String, Object?> json) {
    return DefectLinkedQuestion(
      id: _linkedStr(json['id']),
      questionId: _linkedStr(json['question_id']),
      sort: _linkedInt(json['sort']),
      stem: _linkedStr(json['stem']),
      type: _linkedStr(json['type']),
      source: _linkedStr(json['source']),
      difficulty: _linkedStr(json['difficulty']),
      createdAt: _linkedDate(json['created_at']),
    );
  }

  @override
  String toString() => 'DefectLinkedQuestion($questionId, sort=$sort)';
}

/// 关联题目弹层里的候选项（`GET /questions` 的最小解析）。
class SelectableQuestion {
  const SelectableQuestion({
    required this.id,
    required this.stem,
    required this.type,
  });

  final String id;
  final String stem;
  final String type;

  /// 题型中文标签（复用题库层口径）。
  String get typeLabel => questionTypeLabel(type);

  factory SelectableQuestion.fromJson(Map<String, Object?> json) {
    return SelectableQuestion(
      id: _linkedStr(json['id']),
      stem: _linkedStr(json['stem']),
      type: _linkedStr(json['type']),
    );
  }

  @override
  String toString() => 'SelectableQuestion($id)';
}

String _linkedStr(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  return '$value';
}

int _linkedInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

DateTime? _linkedDate(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return DateTime.tryParse(value.trim());
}
