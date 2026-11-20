// 模考 API（FE-05）。
//
// 职责：把 BE-05 的五个端点映射成界面可用的模型。
// 手写 snake_case → camelCase，不引 json_serializable（任务书硬约束）。
//
// ── 与后端契约的差异（curl 实测确认，非猜测）──────────────────────────────
//
// 1) `POST /mock-exams` 返回 `{mock_exam, questions, question_count}`：
//    `mock_exam.questions` 是 schema 里的 jsonb 索引行
//    `[{question_id, attempt_id, is_correct, duration_ms}]`，**不含题干与选项**；
//    真正能渲染的题目在顶层 `questions` 数组里。
//    → 所以 createMockExam 返回 `MockExamCreated`（exam + questions），
//      而不是任务书写的「返回 MockExam 对象」。答题页没有题干就无法工作。
//
// 2) `mock_exams` 表**没有 submitted_at 列**（schema 只有 created_at / updated_at）。
//    → `submittedAt` 在已提交时取 `updated_at`（提交是本表最后一次写），
//      未提交时为 null。这是本文件里唯一「推导」而非「直读」的字段。
//
// 3) 报告里的 `module_accuracy[*].title` 与 `avg_duration_ms.by_knowledge_node[*].title`
//    当前恒为 null —— 后端组卷时把考点名放在 `title` 键，而报告生成器读
//    `q.knowledge_node_title`（见 server/repositories/mock_exams.mjs 的 submit
//    与 server/mock_report.mjs 的 reportGenerator），两处键名不一致。
//    硬约束不允许改后端，前端一律用 `knowledge_node_id` 前 8 位兜底显示，
//    不伪造中文名；该缺陷已记入答复的遗留项。
//
// 4) `difficulty` 是 PG 枚举 `easy|medium|hard`，可能是 null（sql 允空）。
//    → 保持 `String?`，不做本地映射成数字。
//
// 5) `strategy_execution` 恒为 null（后端刻意不实现，见 mock_report.mjs 文件头）。
//    → 保留 `Object?` 原值，界面只在非 null 时渲染该卡片。
//
// 6) 提交成功后 `report` 里**没有标准答案**（HIDDEN_FIELDS 剔除 answer/analysis），
//    → 报告页只能展示对错与统计，不能做「题目解析」。任务书 D4 的「查看详情」
//      在 MVP 阶段只能提示，已在答复里说明。

import 'api_client.dart';

/// 单选题的一个选项（`questions.options` jsonb 的元素：`{key, text}`）。
class MockOption {
  const MockOption({required this.key, required this.text});

  final String key;
  final String text;

  static MockOption fromJson(Map<String, Object?> json) => MockOption(
        key: _str(json['key']),
        text: _str(json['text']),
      );
}

/// 开考时可渲染的题目（来自组卷响应的顶层 `questions`）。
class MockQuestion {
  const MockQuestion({
    required this.questionId,
    required this.subjectId,
    required this.knowledgeNodeId,
    required this.type,
    required this.stem,
    required this.options,
    required this.difficulty,
    required this.isSubjective,
  });

  final String questionId;
  final String subjectId;
  final String knowledgeNodeId;

  /// `choice` / `fill` / `short_answer` / `essay` / `material`
  final String type;
  final String stem;
  final List<MockOption> options;

  /// 枚举 `easy|medium|hard`，可能为 null。
  final String? difficulty;
  final bool isSubjective;

  /// 是否用多行输入框作答（主观题或非选择题）。
  bool get wantsFreeText => isSubjective || type != 'choice';

  factory MockQuestion.fromJson(Map<String, Object?> json) {
    final Object? rawOptions = json['options'];
    final List<MockOption> options = rawOptions is List
        ? rawOptions
            .whereType<Map>()
            .map((Map m) => MockOption.fromJson(m.cast<String, Object?>()))
            .toList(growable: false)
        : const <MockOption>[];
    return MockQuestion(
      questionId: _str(json['id']),
      subjectId: _str(json['subject_id']),
      knowledgeNodeId: _str(json['knowledge_node_id']),
      type: _str(json['type']),
      stem: _str(json['stem']),
      options: options,
      difficulty: _strOrNull(json['difficulty']),
      isSubjective: json['is_subjective'] == true,
    );
  }
}

/// `mock_exams.questions` jsonb 的一行（**不含题干**，只有索引与判分结果）。
class MockExamEntry {
  const MockExamEntry({
    required this.questionId,
    required this.attemptId,
    required this.isCorrect,
    required this.durationMs,
  });

  final String questionId;
  final String? attemptId;

  /// `null` = 未判分（主观题/无标准答案）；false = 错。
  final bool? isCorrect;
  final int? durationMs;

  factory MockExamEntry.fromJson(Map<String, Object?> json) => MockExamEntry(
        questionId: _str(json['question_id']),
        attemptId: _strOrNull(json['attempt_id']),
        isCorrect: json['is_correct'] is bool ? json['is_correct']! as bool : null,
        durationMs: _intOrNull(json['duration_ms']),
      );
}

/// 一张模考卷（`mock_exams` 行）。
class MockExam {
  const MockExam({
    required this.id,
    required this.examProfileId,
    required this.mode,
    required this.durationLimitMs,
    required this.entries,
    required this.report,
    required this.createdAt,
    required this.submittedAt,
    required this.version,
  });

  final String id;
  final String examProfileId;

  /// `module`（模块模考）/ `full`（整套限时）。
  final String mode;
  final int? durationLimitMs;
  final List<MockExamEntry> entries;

  /// 原始报告 JSON；`null` 表示未提交。
  final Map<String, Object?>? report;
  final DateTime createdAt;

  /// 差异 (2)：表里没有 submitted_at，已提交时取 `updated_at`。
  final DateTime? submittedAt;
  final int version;

  bool get isSubmitted => report != null;

  String get modeLabel => mode == 'full' ? '整套限时' : '模块模考';

  factory MockExam.fromJson(Map<String, Object?> json) {
    final Object? rawEntries = json['questions'];
    final List<MockExamEntry> entries = rawEntries is List
        ? rawEntries
            .whereType<Map>()
            .map((Map m) => MockExamEntry.fromJson(m.cast<String, Object?>()))
            .toList(growable: false)
        : const <MockExamEntry>[];
    final Object? rawReport = json['report'];
    final Map<String, Object?>? report =
        rawReport is Map ? rawReport.cast<String, Object?>() : null;
    return MockExam(
      id: _str(json['id']),
      examProfileId: _str(json['exam_profile_id']),
      mode: _str(json['mode']),
      durationLimitMs: _intOrNull(json['duration_limit_ms']),
      entries: entries,
      report: report,
      createdAt: _date(json['created_at']),
      submittedAt: report == null ? null : _dateOrNull(json['updated_at']),
      version: _int(json['version'], 1),
    );
  }

  /// 计划的题量（jsonb 行数），用于「已答 X / 共 Y」。
  int get plannedCount => entries.length;
}

/// 组卷结果：卷子元数据 + 可渲染的题目。
class MockExamCreated {
  const MockExamCreated({required this.exam, required this.questions});

  final MockExam exam;
  final List<MockQuestion> questions;

  int get questionCount => questions.length;
}

/// 每题的正确率分组（`module_accuracy` 的一项）。
class MockModuleAccuracy {
  const MockModuleAccuracy({
    required this.key,
    required this.title,
    required this.correct,
    required this.total,
    required this.accuracy,
    required this.ungraded,
  });

  /// knowledge_node_id，或后端兜底键 `__ungrouped__`。
  final String key;
  final String? title;
  final int correct;
  final int total;
  final double? accuracy;
  final int ungraded;

  /// 差异 (3)：后端 title 恒 null，用 id 短码兜底，不伪造中文名。
  String get displayTitle {
    if (title != null && title!.isNotEmpty) return title!;
    if (key == '__ungrouped__' || key.isEmpty) return '未归属考点';
    return '考点 ${key.length >= 8 ? key.substring(0, 8) : key}';
  }
}

/// 某考点的平均用时（`avg_duration_ms.by_knowledge_node` 的一项）。
class MockDurationNode {
  const MockDurationNode({
    required this.key,
    required this.title,
    required this.count,
    required this.avgDurationMs,
  });

  final String key;
  final String? title;
  final int count;
  final int? avgDurationMs;

  String get displayTitle {
    if (title != null && title!.isNotEmpty) return title!;
    if (key == '__ungrouped__' || key.isEmpty) return '未归属考点';
    return '考点 ${key.length >= 8 ? key.substring(0, 8) : key}';
  }
}

/// 缺陷重复率（`defect_repeat_rate`）。
class MockDefectRepeatRate {
  const MockDefectRepeatRate({
    required this.repeatCount,
    required this.totalWrong,
    required this.rate,
  });

  final int repeatCount;
  final int totalWrong;
  final double rate;
}

/// 总分（`overall`）。
class MockOverall {
  const MockOverall({
    required this.correct,
    required this.total,
    required this.accuracy,
    required this.ungraded,
  });

  final int correct;

  /// 分母只计**已判分**的题（主观题不计入），与后端口径一致。
  final int total;
  final double? accuracy;
  final int ungraded;

  String get accuracyPercent =>
      accuracy == null ? '—' : '${(accuracy! * 100).round()}%';
}

/// V3 候选（本次错题命中「已处于 V3 的缺陷单」的考点）。
class V3Candidate {
  const V3Candidate({
    required this.defectTicketId,
    required this.questionId,
    required this.knowledgeNodeId,
  });

  final String defectTicketId;
  final String questionId;
  final String knowledgeNodeId;

  factory V3Candidate.fromJson(Map<String, Object?> json) => V3Candidate(
        defectTicketId: _str(json['defect_ticket_id']),
        questionId: _str(json['question_id']),
        knowledgeNodeId: _str(json['knowledge_node_id']),
      );

  /// 考点短码（后端未 JOIN 时界面用它，不伪造中文名）。
  String get knowledgeNodeShort =>
      knowledgeNodeId.length >= 8 ? knowledgeNodeId.substring(0, 8) : knowledgeNodeId;

  String get questionShort =>
      questionId.length >= 8 ? questionId.substring(0, 8) : questionId;
}

/// 模考报告（`report` jsonb 的结构化视图）。
class MockReport {
  const MockReport({
    required this.moduleAccuracy,
    required this.overallDurationMs,
    required this.durationByNode,
    required this.stability,
    required this.defectRepeatRate,
    required this.v3Candidates,
    required this.overall,
    required this.ungradedCount,
    required this.strategyExecution,
  });

  final List<MockModuleAccuracy> moduleAccuracy;
  final int? overallDurationMs;
  final List<MockDurationNode> durationByNode;

  /// 近 3 次同模式模考正确率的变异系数；样本 <2 时为 null（首次模考）。
  final double? stability;
  final MockDefectRepeatRate defectRepeatRate;
  final List<V3Candidate> v3Candidates;
  final MockOverall overall;
  final int ungradedCount;

  /// 差异 (5)：后端恒 null，界面据此不渲染该卡片。
  final Object? strategyExecution;

  factory MockReport.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> moduleAccRaw = _asMap(json['module_accuracy']);
    final List<MockModuleAccuracy> modules = moduleAccRaw.entries.map((e) {
      final Map<String, Object?> v = _asMap(e.value);
      return MockModuleAccuracy(
        key: e.key,
        title: _strOrNull(v['title']),
        correct: _int(v['correct'], 0),
        total: _int(v['total'], 0),
        accuracy: _doubleOrNull(v['accuracy']),
        ungraded: _int(v['ungraded'], 0),
      );
    }).toList(growable: false);

    final Map<String, Object?> avgRaw = _asMap(json['avg_duration_ms']);
    final Map<String, Object?> byNodeRaw = _asMap(avgRaw['by_knowledge_node']);
    final List<MockDurationNode> byNode = byNodeRaw.entries.map((e) {
      final Map<String, Object?> v = _asMap(e.value);
      return MockDurationNode(
        key: e.key,
        title: _strOrNull(v['title']),
        count: _int(v['count'], 0),
        avgDurationMs: _intOrNull(v['avg_duration_ms']),
      );
    }).toList(growable: false);

    final Map<String, Object?> repeatRaw = _asMap(json['defect_repeat_rate']);
    final List<V3Candidate> v3 = (json['v3_candidates'] is List)
        ? (json['v3_candidates']! as List)
            .whereType<Map>()
            .map((Map m) => V3Candidate.fromJson(m.cast<String, Object?>()))
            .toList(growable: false)
        : const <V3Candidate>[];

    final Map<String, Object?> overallRaw = _asMap(json['overall']);
    return MockReport(
      moduleAccuracy: modules,
      overallDurationMs: _intOrNull(avgRaw['overall']),
      durationByNode: byNode,
      stability: _doubleOrNull(json['stability']),
      defectRepeatRate: MockDefectRepeatRate(
        repeatCount: _int(repeatRaw['repeat_count'], 0),
        totalWrong: _int(repeatRaw['total_wrong'], 0),
        rate: _doubleOrNull(repeatRaw['rate']) ?? 0,
      ),
      v3Candidates: v3,
      overall: MockOverall(
        correct: _int(overallRaw['correct'], 0),
        total: _int(overallRaw['total'], 0),
        accuracy: _doubleOrNull(overallRaw['accuracy']),
        ungraded: _int(overallRaw['ungraded'], 0),
      ),
      ungradedCount: _int(json['ungraded_count'], 0),
      strategyExecution: json['strategy_execution'],
    );
  }
}

/// 交卷结果（`POST /mock-exams/:id/submit` 的响应）。
class MockSubmitResult {
  const MockSubmitResult({
    required this.exam,
    required this.report,
    required this.timedOut,
    required this.elapsedMs,
  });

  final MockExam exam;
  final MockReport report;
  final bool timedOut;
  final int elapsedMs;
}

/// 一页模考记录（`GET /exam-profiles/:id/mock-exams` 的响应）。
///
/// 注意命名：这里叫 `MockExamListPage` 而不是 `MockExamPage`，因为
/// `lib/pages/mock_exam_page.dart` 里的答题页 Widget 已经叫 `MockExamPage`，
/// 两个同名类在同一文件里导入会触发 `ambiguous_import`。分页对象用
/// `ListPage` 后缀也更能说明它是「一页数据」而不是「一个页面」。
class MockExamListPage {
  const MockExamListPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<MockExam> items;
  final int total;
  final int limit;
  final int offset;
}

/// 提交时的一题作答（`answers` 数组的元素）。
class MockAnswer {
  const MockAnswer({
    required this.questionId,
    required this.answerText,
    required this.durationMs,
  });

  final String questionId;
  final String answerText;
  final int durationMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'question_id': questionId,
        'answer_text': answerText,
        'duration_ms': durationMs,
      };
}

class MockExamApi {
  MockExamApi({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  /// 组卷：`POST /mock-exams`。
  ///
  /// [mode] 为 `module` 时必须给 [knowledgeNodeId]，为 `full` 时必须给 [subjectId]
  /// （后端分别返回 MISSING_KNOWLEDGE_NODE_ID / MISSING_SUBJECT_ID）。
  ///
  /// 题库不足 400 `INSUFFICIENT_QUESTIONS`，body 带 `{available, requested}`，
  /// 由调用方渲染成内联提示。
  Future<MockExamCreated> createMockExam({
    required String examProfileId,
    required String mode,
    String? subjectId,
    String? knowledgeNodeId,
    required int questionCount,
    int? durationLimitMs,
  }) async {
    // 用「先建表再按需追加」而不是 if-null 元素：
    // `if (x != null)` 会被 lint 建议改成 null-aware 元素 `?x`（Dart 3.8 语法），
    // 而 subjectId / knowledgeNodeId 的空串判断本来就不能用 `?`，混写反而更难读。
    final Map<String, Object?> payload = <String, Object?>{
      'exam_profile_id': examProfileId,
      'mode': mode,
      'question_count': questionCount,
    };
    if (durationLimitMs != null) payload['duration_limit_ms'] = durationLimitMs;
    if (subjectId != null && subjectId.isNotEmpty) payload['subject_id'] = subjectId;
    if (knowledgeNodeId != null && knowledgeNodeId.isNotEmpty) {
      payload['knowledge_node_id'] = knowledgeNodeId;
    }

    final Object? raw = await _client.post('/mock-exams', body: payload);
    if (raw is! Map) throw ApiException('组卷响应不是 JSON 对象', body: raw);
    final Map<String, Object?> map = raw.cast<String, Object?>();

    final Object? examRaw = map['mock_exam'];
    if (examRaw is! Map) throw ApiException('组卷响应缺少 mock_exam', body: raw);

    final Object? questionsRaw = map['questions'];
    final List<MockQuestion> questions = questionsRaw is List
        ? questionsRaw
            .whereType<Map>()
            .map((Map m) => MockQuestion.fromJson(m.cast<String, Object?>()))
            .toList(growable: false)
        : const <MockQuestion>[];

    return MockExamCreated(
      exam: MockExam.fromJson(examRaw.cast<String, Object?>()),
      questions: questions,
    );
  }

  /// 读卷：`GET /mock-exams/:id`（未提交的卷子也能读，用于超时后确认）。
  Future<MockExam> fetchMockExam(String id) async {
    final Object? raw = await _client.get('/mock-exams/${Uri.encodeComponent(id)}');
    if (raw is! Map) throw ApiException('模考响应不是 JSON 对象', body: raw);
    final Object? examRaw = raw.cast<String, Object?>()['mock_exam'];
    if (examRaw is! Map) throw ApiException('模考响应缺少 mock_exam', body: raw);
    return MockExam.fromJson(examRaw.cast<String, Object?>());
  }

  /// 交卷：`POST /mock-exams/:id/submit`。
  ///
  /// [version] 必填（乐观锁）；重复提交 → 409 `already_submitted`。
  /// [answers] 可为空数组（超时自动交卷时可能一题未答）。
  Future<MockSubmitResult> submitMockExam(
    String id, {
    required int version,
    required List<MockAnswer> answers,
    DateTime? submittedAt,
  }) async {
    final Map<String, Object?> payload = <String, Object?>{
      'version': version,
      'answers': answers.map((MockAnswer a) => a.toJson()).toList(growable: false),
      if (submittedAt != null) 'submitted_at': submittedAt.toUtc().toIso8601String(),
    };

    final Object? raw = await _client.post(
      '/mock-exams/${Uri.encodeComponent(id)}/submit',
      body: payload,
    );
    if (raw is! Map) throw ApiException('交卷响应不是 JSON 对象', body: raw);
    final Map<String, Object?> map = raw.cast<String, Object?>();

    final Object? examRaw = map['mock_exam'];
    final Object? reportRaw = map['report'];
    if (reportRaw is! Map) throw ApiException('交卷响应缺少 report', body: raw);

    return MockSubmitResult(
      exam: examRaw is Map
          ? MockExam.fromJson(examRaw.cast<String, Object?>())
          : MockExam.fromJson(const <String, Object?>{}),
      report: MockReport.fromJson(reportRaw.cast<String, Object?>()),
      timedOut: map['timed_out'] == true,
      elapsedMs: _int(map['elapsed_ms'], 0),
    );
  }

  /// 读报告：`GET /mock-exams/:id/report`（未提交 → 404 `not_submitted`）。
  Future<MockReport> fetchMockExamReport(String id) async {
    final Object? raw =
        await _client.get('/mock-exams/${Uri.encodeComponent(id)}/report');
    if (raw is! Map) throw ApiException('报告响应不是 JSON 对象', body: raw);
    final Object? reportRaw = raw.cast<String, Object?>()['report'];
    if (reportRaw is! Map) throw ApiException('报告响应缺少 report', body: raw);
    return MockReport.fromJson(reportRaw.cast<String, Object?>());
  }

  /// 历史列表：`GET /exam-profiles/:id/mock-exams`。
  ///
  /// 后端按 `created_at DESC` 返回；`submitted=true` 时只返回已交卷的。
  Future<MockExamListPage> fetchMockExamsByProfile(
    String profileId, {
    String? mode,
    bool? submitted,
    int? limit,
    int? offset,
  }) async {
    final Map<String, String> query = <String, String>{
      if (mode != null && mode.isNotEmpty) 'mode': mode,
      if (submitted == true) 'submitted': 'true',
      if (limit != null) 'limit': '$limit',
      if (offset != null && offset > 0) 'offset': '$offset',
    };

    final Object? raw = await _client.get(
      '/exam-profiles/${Uri.encodeComponent(profileId)}/mock-exams',
      query: query.isEmpty ? null : query,
    );
    if (raw is! Map) throw ApiException('模考列表响应不是 JSON 对象', body: raw);
    final Map<String, Object?> map = raw.cast<String, Object?>();
    final Object? itemsRaw = map['items'];
    final List<MockExam> items = itemsRaw is List
        ? itemsRaw
            .whereType<Map>()
            .map((Map m) => MockExam.fromJson(m.cast<String, Object?>()))
            .toList(growable: false)
        : const <MockExam>[];

    return MockExamListPage(
      items: items,
      total: _int(map['total'], items.length),
      limit: _int(map['limit'], 20),
      offset: _int(map['offset'], 0),
    );
  }

  void close() => _client.close();
}

// ── 映射辅助（与 defect_api.dart 同风格）──────────────────────────────────

String _str(Object? v) => v == null ? '' : '$v';

String? _strOrNull(Object? v) {
  final String s = _str(v).trim();
  return s.isEmpty ? null : s;
}

int _int(Object? v, int fallback) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

int? _intOrNull(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double? _doubleOrNull(Object? v) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

Map<String, Object?> _asMap(Object? v) {
  if (v is Map) return v.cast<String, Object?>();
  return const <String, Object?>{};
}

DateTime _date(Object? v) => _dateOrNull(v) ?? DateTime.now();

DateTime? _dateOrNull(Object? v) {
  if (v is String && v.isNotEmpty) {
    return DateTime.tryParse(v)?.toLocal();
  }
  return null;
}
