import 'api_client.dart';

/// 验证任务（FE-04）。
///
/// 字段与后端 `GET /users/:userId/verification-tasks` 的 items 逐字对齐
/// （`server/repositories/defect_tickets.mjs` 的 `listVerificationTasks`）：
///
/// | 后端列 | 说明 |
/// |---|---|
/// | `id` | 缺陷单 id（不是独立的验证任务表主键，验证任务就是「正处于 V1/V2/V3 的缺陷单」） |
/// | `stage` | `V1` / `V2` / `V3`（后端由 `dt.status::text` 投影出来，注意字段名是 `stage` 不是 `status`） |
/// | `entered_at` | 进入当前 stage 的时间（V2/V3 取上一阶段 pass 的记录时间，V1 退化用 updated_at） |
/// | `window_days` | 该阶段的窗口天数（V1=7 / V2=14 / V3=21，来自 core 的 VERIFY_WINDOWS） |
/// | `days_left` | 剩余天数，负数表示已逾期 |
/// | `overdue_days` | 逾期天数（未逾期为 0） |
/// | `elapsed_days` | 已进入该阶段的天数 |
/// | `due_at` | 到期时刻（ISO 8601 UTC 字符串） |
/// | `urgency` | `overdue` / `due_soon` / `normal`（后端算好，前端不做二次判定） |
/// | `verification_round` | 第几轮（重开一次 +1） |
/// | `reopen_count` | 重开次数 |
/// | `knowledge_node_title` / `knowledge_node_freq_tag` / `subject_name` | 展示用，LEFT JOIN 而来，可能为 null |
///
/// 刻意不把 `due_at` 解析成 DateTime 再用：后端已经是唯一口径（按 Asia/Shanghai
/// 切日界算出来的），前端再算一次会有时区偏差风险，所以保留原始字符串只用于展示。
class VerificationTask {
  const VerificationTask({
    required this.id,
    required this.stage,
    required this.urgency,
    required this.windowDays,
    required this.daysLeft,
    required this.overdueDays,
    required this.elapsedDays,
    required this.verificationRound,
    required this.reopenCount,
    this.knowledgeNodeTitle,
    this.knowledgeNodeFreqTag,
    this.subjectName,
    this.qType,
    this.enteredAt,
    this.dueAt,
  });

  final String id;

  /// `V1` / `V2` / `V3`
  final String stage;

  /// `overdue` / `due_soon` / `normal`
  final String urgency;

  final int windowDays;
  final int daysLeft;
  final int overdueDays;
  final int elapsedDays;
  final int verificationRound;
  final int reopenCount;

  final String? knowledgeNodeTitle;
  final String? knowledgeNodeFreqTag;
  final String? subjectName;
  final String? qType;
  final String? enteredAt;
  final String? dueAt;

  /// 是否处于某种紧急态（供列表做左侧色条与徽标）。
  bool get isOverdue => urgency == 'overdue';

  /// 剩余天数的中文文案。逾期时为「已逾期 N 天」，当天为「今天到期」。
  String get daysLabel {
    if (daysLeft < 0) return '已逾期 $overdueDays 天';
    if (daysLeft == 0) return '今天到期';
    return '还剩 $daysLeft 天';
  }

  /// 窗口说明，如「V1 窗口 7 天」。
  String get windowLabel => '$stage 窗口 $windowDays 天';

  /// 考点标题兜底：后端 LEFT JOIN 可能拿不到（knowledge_node_id 为空），
  /// 这时用 id 短码占位而不是伪造中文名（与 FE-03 的取舍一致）。
  String get nodeTitle {
    final t = (knowledgeNodeTitle ?? '').trim();
    if (t.isNotEmpty) return t;
    return '未关联考点';
  }

  /// 频次标签的中文（high/mid/low）。
  String? get freqLabel => switch ((knowledgeNodeFreqTag ?? '').trim()) {
        'high' => '高频',
        'mid' => '中频',
        'low' => '低频',
        _ => null,
      };

  static VerificationTask fromJson(Map<String, Object?> json) {
    return VerificationTask(
      id: _str(json['id']),
      stage: _upper(_str(json['stage'])),
      urgency: _urgency(_str(json['urgency'])),
      windowDays: _int(json['window_days'], 0),
      daysLeft: _int(json['days_left'], 0),
      overdueDays: _int(json['overdue_days'], 0),
      elapsedDays: _int(json['elapsed_days'], 0),
      verificationRound: _int(json['verification_round'], 1),
      reopenCount: _int(json['reopen_count'], 0),
      knowledgeNodeTitle: _nullableText(json['knowledge_node_title']),
      knowledgeNodeFreqTag: _nullableText(json['knowledge_node_freq_tag']),
      subjectName: _nullableText(json['subject_name']),
      qType: _nullableText(json['q_type']),
      enteredAt: _nullableText(json['entered_at']),
      dueAt: _nullableText(json['due_at']),
    );
  }

  static String _str(Object? v) => v == null ? '' : '$v';

  static String _upper(String v) => v.toUpperCase();

  /// 未知 urgency 一律回落 normal（不让脏值把卡片染成红色）。
  static String _urgency(String v) {
    final u = v.trim().toLowerCase();
    if (u == 'overdue' || u == 'due_soon' || u == 'normal') return u;
    return 'normal';
  }

  static int _int(Object? v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v.trim()) ?? fallback;
    return fallback;
  }

  static String? _nullableText(Object? v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }
}

/// 验证看板摘要（`GET /users/:userId/verification-summary`）。
///
/// 后端形状：`{ total, by_stage:{V1,V2,V3}, by_urgency:{overdue,due_soon,normal},
/// overdue, due_soon, normal }`。三个扁平字段是 `by_urgency` 的副本，
/// 这里两者都读，优先扁平字段（后端注释说明它是给前端直接用的）。
class VerificationSummary {
  const VerificationSummary({
    required this.total,
    required this.overdue,
    required this.dueSoon,
    required this.normal,
    required this.byStage,
  });

  final int total;
  final int overdue;
  final int dueSoon;
  final int normal;

  /// `{'V1': 2, 'V2': 1, 'V3': 0}`（缺键按 0 处理）
  final Map<String, int> byStage;

  static const VerificationSummary empty = VerificationSummary(
    total: 0,
    overdue: 0,
    dueSoon: 0,
    normal: 0,
    byStage: <String, int>{'V1': 0, 'V2': 0, 'V3': 0},
  );

  int stageCount(String stage) => byStage[stage] ?? 0;

  static VerificationSummary fromJson(Map<String, Object?> json) {
    final byUrgency = json['by_urgency'];
    final Map<String, Object?> urgencyMap =
        byUrgency is Map ? byUrgency.cast<String, Object?>() : const <String, Object?>{};

    final byStageRaw = json['by_stage'];
    final Map<String, int> stages = <String, int>{'V1': 0, 'V2': 0, 'V3': 0};
    if (byStageRaw is Map) {
      byStageRaw.forEach((k, v) {
        stages['$k'] = VerificationTask._int(v, 0);
      });
    }

    int pick(String flatKey, String nestedKey) {
      final flat = json[flatKey];
      if (flat != null) return VerificationTask._int(flat, 0);
      return VerificationTask._int(urgencyMap[nestedKey], 0);
    }

    return VerificationSummary(
      total: VerificationTask._int(json['total'], 0),
      overdue: pick('overdue', 'overdue'),
      dueSoon: pick('due_soon', 'due_soon'),
      normal: pick('normal', 'normal'),
      byStage: stages,
    );
  }
}

/// 验证任务的读接口（FE-04）。
///
/// 与 `DefectApi` 分开的理由：这两个端点在 BE-04 归属「验证任务」域，
/// 后续如果加「标记提醒已读」之类不会污染缺陷单 API 的职责。
class VerificationApi {
  VerificationApi({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  /// `GET /users/:userId/verification-tasks`
  ///
  /// [status] 传逗号分隔的 stage（`'V1,V2'`），后端参数名沿用 BE-03 列表端点的
  /// `status` 但语义是「当前验证 stage」。
  /// [urgency] 传逗号分隔的 `overdue,due_soon`。
  Future<List<VerificationTask>> fetchVerificationTasks(
    String userId, {
    String? status,
    String? urgency,
    int? limit,
    int? offset,
  }) async {
    final query = <String, String>{};
    if (status != null && status.isNotEmpty) query['status'] = status;
    if (urgency != null && urgency.isNotEmpty) query['urgency'] = urgency;
    if (limit != null) query['limit'] = '$limit';
    if (offset != null) query['offset'] = '$offset';

    final raw = await _client.get(
      '/users/${Uri.encodeComponent(userId)}/verification-tasks',
      query: query.isEmpty ? null : query,
    );
    final items = _extractItems(raw);
    return items.map(VerificationTask.fromJson).toList(growable: false);
  }

  /// `GET /users/:userId/verification-summary`
  Future<VerificationSummary> fetchVerificationSummary(String userId) async {
    final raw = await _client.get(
      '/users/${Uri.encodeComponent(userId)}/verification-summary',
    );
    if (raw is! Map) {
      throw ApiException('验证摘要响应不是 JSON 对象', body: raw);
    }
    return VerificationSummary.fromJson(raw.cast<String, Object?>());
  }

  /// 后端返回 `{ items: [...], total, limit, offset }`；仍容错裸数组。
  List<Map<String, Object?>> _extractItems(Object? raw) {
    Object? listLike = raw;
    if (raw is Map) {
      final items = raw['items'];
      if (items == null) return const <Map<String, Object?>>[];
      listLike = items;
    }
    if (listLike is! List) return const <Map<String, Object?>>[];
    return listLike
        .whereType<Map>()
        .map((m) => m.cast<String, Object?>())
        .toList(growable: false);
  }

  void close() => _client.close();
}
