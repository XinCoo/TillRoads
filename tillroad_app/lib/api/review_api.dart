// 复盘 API（FE-06）。
//
// 职责：把 BE-06 的五个端点映射成界面模型。手写 snake_case → camelCase，
// 不引 json_serializable（任务硬约束）。
//
// ── 与后端契约的四处差异（已用 curl 实测确认，不是猜测）────────────────────
//
// 1) **只有 POST 返回周期的起止时刻**。`GET /review-cycles` 与
//    `GET /review-cycles/:id` 都是直接 `SELECT *` 返回行，而
//    `period_start_at` / `period_end_at` / `time_zone` 这三项**不在表里**——
//    它们是 POST 时由 `review_period.resolvePeriod()` 算出、只挂在响应体上。
//    → 本模型三个字段都是可空的；列表页与详情页都用 `period` 字符串本身
//      做展示（`2026-W47` 已足够），不依赖起止时刻。
//
// 2) **同周期重复生成是 409 ALREADY_EXISTS**，body 带 `existing_id` 与
//    `resolution: 'delete_then_recreate'`。这与其它模块的 409（乐观锁
//    `conflict` / 重名 `DUPLICATE_*`）语义不同，所以 `_statusCode`/`existingId`
//    单独暴露，让列表页能「提示 + 直接跳到已有那条」。
//
// 3) **PATCH 只接受 `completed`**。metrics / period / cycle_type 是快照身份，
//    传了会 400 `IMMUTABLE_FIELD`。所以 `markCompleted` 只发 version + completed。
//
// 4) **DELETE 也要带 version**（乐观锁），成功返回软删后的行（`deleted_at` 非空）。
//
// metrics 六项的结构见 `ReviewMetrics`，全部按 BE-06 的真实 JSON 手写：
//   open_defects     {total, by_status:{七态: int}}   ← 时点量（周期末仍未关闭）
//   layer_dist       {层级: int}                      ← 周期内新增
//   verify_pass_rate {pass, fail, total, rate|null}   ← total=0 时 rate 为 null
//   mock_stability   number|null                      ← 本周期无模考时为 null
//   target_progress  {target_score, latest_mock_score, rate}
//   reopen_hotspots  [{knowledge_node_id, title, reopen_count_sum}]

import 'api_client.dart';

class ReviewApi {
  ReviewApi({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  /// 生成一份复盘快照：`POST /review-cycles`。
  ///
  /// [period] 省略时由后端按当前时间算当前周期（daily→`YYYY-MM-DD`、
  /// weekly→`YYYY-Www`、monthly→`YYYY-MM`）。周期格式错了后端返回
  /// 400 `INVALID_PERIOD`，不会静默取当前周期。
  Future<ReviewCycle> createReviewCycle({
    required String userId,
    required String cycleType,
    String? period,
  }) async {
    final Map<String, Object?> body = <String, Object?>{
      'user_id': userId,
      'cycle_type': cycleType,
      if (period != null && period.isNotEmpty) 'period': period,
    };

    final Object? raw = await _client.post('/review-cycles', body: body);
    if (raw is! Map) throw ApiException('生成复盘响应不是 JSON 对象', body: raw);
    return ReviewCycle.fromJson(raw.cast<String, Object?>());
  }

  /// 列表：`GET /review-cycles?user_id=&cycle_type=&period=&completed=`。
  ///
  /// 后端按 `period DESC, created_at DESC` 排序（周期是零填充字符串，
  /// 字典序即时间序），所以「最近的周期在最前」由服务端保证。
  Future<ReviewCyclePage> fetchReviewCycles(
    String userId, {
    String? cycleType,
    String? period,
    bool? completed,
    int? limit,
    int? offset,
  }) async {
    final Map<String, String> query = <String, String>{
      'user_id': userId,
      if (cycleType != null && cycleType.isNotEmpty) 'cycle_type': cycleType,
      if (period != null && period.isNotEmpty) 'period': period,
      if (completed != null) 'completed': completed ? 'true' : 'false',
      if (limit != null) 'limit': '$limit',
      if (offset != null && offset > 0) 'offset': '$offset',
    };

    final Object? raw = await _client.get('/review-cycles', query: query);
    if (raw is! Map) throw ApiException('复盘列表响应不是 JSON 对象', body: raw);
    final Map<String, Object?> map = raw.cast<String, Object?>();
    final Object? itemsRaw = map['items'];
    final List<ReviewCycle> items = itemsRaw is List
        ? itemsRaw
            .whereType<Map>()
            .map((Map m) => ReviewCycle.fromJson(m.cast<String, Object?>()))
            .toList(growable: false)
        : const <ReviewCycle>[];

    return ReviewCyclePage(
      items: items,
      total: _int(map['total'], items.length),
      limit: _int(map['limit'], 50),
      offset: _int(map['offset'], 0),
    );
  }

  /// 单条：`GET /review-cycles/:id`（软删即 404）。
  Future<ReviewCycle> fetchReviewCycle(String id) async {
    final Object? raw = await _client.get('/review-cycles/${Uri.encodeComponent(id)}');
    if (raw is! Map) throw ApiException('复盘详情响应不是 JSON 对象', body: raw);
    return ReviewCycle.fromJson(raw.cast<String, Object?>());
  }

  /// 标记已读：`PATCH /review-cycles/:id`，body 必须只有 version + completed。
  ///
  /// 为什么必须带 version：后端 `updateWithVersion` 用
  /// `WHERE id=$1 AND version=$2 AND deleted_at IS NULL`，
  /// 0 行即判定并发冲突 → 409 `conflict`（resolution: client_merge）。
  Future<ReviewCycle> markCompleted(String id, {required int version}) async {
    final Object? raw = await _client.patch(
      '/review-cycles/${Uri.encodeComponent(id)}',
      body: <String, Object?>{'version': version, 'completed': true},
    );
    if (raw is! Map) throw ApiException('标记已读响应不是 JSON 对象', body: raw);
    return ReviewCycle.fromJson(raw.cast<String, Object?>());
  }

  /// 软删：`DELETE /review-cycles/:id`。同样要带 version（乐观锁）。
  ///
  /// 删除后同周期可以重新生成——这正是 409 里
  /// `resolution: 'delete_then_recreate'` 的含义。
  Future<void> deleteReviewCycle(String id, {required int version}) async {
    await _client.delete(
      '/review-cycles/${Uri.encodeComponent(id)}',
      body: <String, Object?>{'version': version},
    );
  }

  void close() => _client.close();
}

/// 复盘周期类型。与 `server/review_period.mjs` 的 `CYCLE_TYPES` 对齐。
enum ReviewCycleType {
  daily('daily', '日复盘'),
  weekly('weekly', '周复盘'),
  monthly('monthly', '月复盘');

  const ReviewCycleType(this.wire, this.label);

  /// 后端枚举值（小写单词）。
  final String wire;

  /// 界面标签。
  final String label;

  /// 未知值回落 daily 而不是抛错——历史数据若出现新类型，界面仍能显示。
  static ReviewCycleType fromWire(String? value) {
    final String v = (value ?? '').trim().toLowerCase();
    for (final ReviewCycleType t in ReviewCycleType.values) {
      if (t.wire == v) return t;
    }
    return ReviewCycleType.daily;
  }
}

/// 一条复盘快照。
///
/// 注意这是**快照**不是实时视图：`metrics` 是生成那一刻算出来的数字，
/// 之后业务数据再怎么变，这条记录都不动（BE-06 拍板项 2）。
class ReviewCycle {
  const ReviewCycle({
    required this.id,
    required this.userId,
    required this.cycleType,
    required this.period,
    required this.metrics,
    required this.completed,
    required this.version,
    required this.createdAt,
    this.periodStartAt,
    this.periodEndAt,
    this.timeZone,
  });

  factory ReviewCycle.fromJson(Map<String, Object?> json) {
    return ReviewCycle(
      id: _str(json['id']),
      userId: _str(json['user_id']),
      cycleType: ReviewCycleType.fromWire(_str(json['cycle_type'])),
      period: _str(json['period']),
      metrics: ReviewMetrics.fromJson(json['metrics']),
      completed: json['completed'] == true,
      version: _int(json['version'], 1),
      createdAt: _date(json['created_at']),
      // 差异 (1)：这三项只在 POST 响应里有，GET 返回的裸行没有
      periodStartAt: _dateOrNull(json['period_start_at']),
      periodEndAt: _dateOrNull(json['period_end_at']),
      timeZone: _strOrNull(json['time_zone']),
    );
  }

  final String id;
  final String userId;
  final ReviewCycleType cycleType;

  /// 周期字符串：daily `2026-11-17` / weekly `2026-W47` / monthly `2026-11`。
  final String period;

  final ReviewMetrics metrics;
  final bool completed;

  /// 乐观锁版本号，PATCH / DELETE 必须带。
  final int version;

  final DateTime createdAt;

  /// 仅 POST 响应提供（表里没有这三列），列表/详情读到的会是 null。
  final DateTime? periodStartAt;
  final DateTime? periodEndAt;
  final String? timeZone;

  /// 周期 + 类型，如「周复盘 · 2026-W47」。
  String get title => '${cycleType.label} · $period';
}

class ReviewCyclePage {
  const ReviewCyclePage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<ReviewCycle> items;
  final int total;
  final int limit;
  final int offset;
}

/// 复盘六项指标（结构按 `server/review_stats.mjs:computeMetrics` 的真实 JSON）。
class ReviewMetrics {
  const ReviewMetrics({
    required this.openDefects,
    required this.layerDist,
    required this.verifyPassRate,
    required this.mockStability,
    required this.targetProgress,
    required this.reopenHotspots,
  });

  factory ReviewMetrics.fromJson(Object? raw) {
    final Map<String, Object?> map = _asMap(raw);
    return ReviewMetrics(
      openDefects: OpenDefects.fromJson(map['open_defects']),
      layerDist: _intMap(map['layer_dist']),
      verifyPassRate: VerifyPassRate.fromJson(map['verify_pass_rate']),
      mockStability: _doubleOrNull(map['mock_stability']),
      targetProgress: TargetProgress.fromJson(map['target_progress']),
      reopenHotspots: _listOfMap(map['reopen_hotspots'])
          .map(ReopenHotspot.fromJson)
          .toList(growable: false),
    );
  }

  final OpenDefects openDefects;

  /// 错因层级 → 条数（周期内**新增**的单）。键可能是任意自由文本或
  /// `unclassified`（后端把 NULL/空白归到这里）。
  final Map<String, int> layerDist;

  final VerifyPassRate verifyPassRate;

  /// 近 3 次模考正确率的变异系数；本周期无模考时为 null。
  final double? mockStability;

  final TargetProgress targetProgress;
  final List<ReopenHotspot> reopenHotspots;

  /// 层级分布按条数降序（同数按名称升序，保证顺序稳定）。
  List<MapEntry<String, int>> get sortedLayerDist {
    final List<MapEntry<String, int>> entries = layerDist.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
        final int byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return entries;
  }
}

/// 未关闭缺陷：`total` + 七态分布。
///
/// 口径是**时点量**（周期末仍未关闭），不是周期内新增 —— 所以
/// `total` 与 `layer_dist` 的合计不一定相等，界面上要标清楚。
class OpenDefects {
  const OpenDefects({required this.total, required this.byStatus});

  factory OpenDefects.fromJson(Object? raw) {
    final Map<String, Object?> map = _asMap(raw);
    return OpenDefects(
      total: _int(map['total'], 0),
      byStatus: _intMap(map['by_status']),
    );
  }

  final int total;

  /// 七态 → 条数。后端用白名单预填 0，所以七个键一定都在。
  final Map<String, int> byStatus;

  /// 按条数降序的七态（只保留 > 0 的，界面上零值不占位置）。
  List<MapEntry<String, int>> get nonZeroStatuses {
    final List<MapEntry<String, int>> entries =
        byStatus.entries.where((MapEntry<String, int> e) => e.value > 0).toList()
          ..sort((MapEntry<String, int> a, MapEntry<String, int> b) =>
              b.value.compareTo(a.value));
    return entries;
  }
}

/// 验证通过率。`total == 0` 时 `rate` 为 null（「没做验证」≠「验证全错」）。
class VerifyPassRate {
  const VerifyPassRate({
    required this.pass,
    required this.fail,
    required this.total,
    required this.rate,
  });

  factory VerifyPassRate.fromJson(Object? raw) {
    final Map<String, Object?> map = _asMap(raw);
    return VerifyPassRate(
      pass: _int(map['pass'], 0),
      fail: _int(map['fail'], 0),
      total: _int(map['total'], 0),
      rate: _doubleOrNull(map['rate']),
    );
  }

  final int pass;
  final int fail;
  final int total;

  /// 0–1 小数；total=0 时为 null。
  final double? rate;

  /// 百分比文本；rate 为 null 时给 `—`。
  String get ratePercent => rate == null ? '—' : '${(rate! * 100).round()}%';
}

/// 目标进度：目标分 vs 周期内最近一次模考折算分。
class TargetProgress {
  const TargetProgress({
    required this.targetScore,
    required this.latestMockScore,
    required this.rate,
  });

  factory TargetProgress.fromJson(Object? raw) {
    final Map<String, Object?> map = _asMap(raw);
    return TargetProgress(
      targetScore: _doubleOrNull(map['target_score']),
      latestMockScore: _doubleOrNull(map['latest_mock_score']),
      rate: _doubleOrNull(map['rate']),
    );
  }

  /// `exam_profiles.target_score`（百制分），未设置时为 null。
  final double? targetScore;

  /// 周期内最近一次已提交模考的准确率 × 100；无模考时为 null。
  final double? latestMockScore;

  /// `latest_mock_score / target_score`；缺任一项或目标分为 0 时为 null。
  final double? rate;

  /// 进度条填充比例（0–1，超 1 截断）；rate 为 null 时返回 null。
  double? get barFraction {
    if (rate == null) return null;
    return rate!.clamp(0.0, 1.0).toDouble();
  }
}

/// 重开热点：周期内重开次数累加最多的考点（后端已取 top 5）。
class ReopenHotspot {
  const ReopenHotspot({
    required this.knowledgeNodeId,
    required this.title,
    required this.reopenCountSum,
  });

  factory ReopenHotspot.fromJson(Map<String, Object?> json) {
    return ReopenHotspot(
      knowledgeNodeId: _str(json['knowledge_node_id']),
      title: _strOrNull(json['title']),
      reopenCountSum: _int(json['reopen_count_sum'], 0),
    );
  }

  final String knowledgeNodeId;

  /// 后端 `LEFT JOIN knowledge_nodes`；节点已软删时可能为 null。
  final String? title;

  final int reopenCountSum;

  /// 展示名：有中文名用中文名，否则退化成 id 短码（不伪造）。
  String get displayTitle {
    final String? t = title;
    if (t != null && t.isNotEmpty) return t;
    if (knowledgeNodeId.isEmpty) return '未关联考点';
    final String id = knowledgeNodeId;
    return '考点 ${id.length > 8 ? id.substring(0, 8) : id}';
  }
}

// ── 映射辅助（与 defect_api.dart / mock_api.dart 同风格）───────────────────

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

/// jsonb 里「字符串 → 数字」的字典（layer_dist / by_status）。
/// 值可能是 int 也可能是 string（pg 的 jsonb 数字解析有时走 numeric），都要收。
Map<String, int> _intMap(Object? v) {
  final Map<String, Object?> raw = _asMap(v);
  final Map<String, int> out = <String, int>{};
  raw.forEach((String k, Object? val) {
    final int? n = _intOrNull(val);
    if (n != null) out[k] = n;
  });
  return out;
}

List<Map<String, Object?>> _listOfMap(Object? v) {
  if (v is List) {
    return v
        .whereType<Map>()
        .map((Map m) => m.cast<String, Object?>())
        .toList(growable: false);
  }
  return const <Map<String, Object?>>[];
}

DateTime? _dateOrNull(Object? v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  final String s = '$v'.trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s)?.toLocal();
}

DateTime _date(Object? v) => _dateOrNull(v) ?? DateTime.fromMillisecondsSinceEpoch(0);
