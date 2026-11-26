// 考试配置专用 API 层（A1 任务新增）。
//
// ── 为什么单独建文件，而不是往 `defect_api.dart` 里塞 ──────────────────────
// `defect_api.dart` 的职责是「缺陷单」。考试目标只是它**顺带**提供的两个读取
// 方法（建单页要选 `exam_profile_id`）。现在考试配置要做删除 / 进度 / 自定义
// 类型这些写操作，塞进去会让两个不相干的领域混在一个类里，改动还会波及缺陷单
// 页面的回归面。故独立成 `ExamApi`。
//
// ── 顺带收敛两处重复定义 ──────────────────────────────────────────────────
// 「考试类型中文表」此前在 `exam_config_page.dart` 与
// `exam_profile_create_page.dart` 各写了一份（`Map` 一份、`List` 一份）。
// 两份表迟早漂移（比如加 'custom' 时只改一处），故在这里只留**一份真源**：
// `kExamTypeLabels`（值 → 标签）与 `kExamTypeOptions`（选项列表）。
//
// ── 后端契约（A1，后端由另一位同事实现）─────────────────────────────────
// * `DELETE /exam-profiles/{id}`，body `{ "version": <当前 version> }`（乐观锁必填）。
//   → 200 `{...archived, cascaded:{subjects,knowledge_nodes}}`
//   → 若该目标被未删除的 defect_tickets / mock_exams 引用 → 409
//     `{ "error": "exam_profile_in_use", "message": "该配置正在使用中，无法删除" }`
// * `GET /exam-profiles/{id}/progress` →
//   `{exam_profile_id, daily_minutes, minutes_used, minutes_progress,
//     questions_done, correct, total_answered, accuracy}`
//   （`minutes_progress` / `accuracy` 可能为 null）。
// * `exam_type` 新增 'custom'（迁移 0006），另加可空列 `exam_type_custom`
//   （自定义名称文本，≤20 字）。
// * 跨用户一律 404（不是 403）。

import 'api_client.dart';

/// `exam_type` 枚举 → 中文标签。
///
/// 含 `'custom'`（自定义）。只用于展示兜底，不做输入校验 ——
/// 枚举合法性由后端 `core/validators.mjs` 的 `validateExamType` 判定。
const Map<String, String> kExamTypeLabels = <String, String>{
  'civil_service': '公务员',
  'postgrad': '考研',
  'final_exam': '期末',
  'vocational': '职业资格',
  'adult_self_study': '成人自考',
  'custom': '自定义',
};

/// 新建页的「考试类型」选项（顺序即 UI 顺序）。
///
/// 与 [kExamTypeLabels] 严格一致：同一份枚举既做展示兜底又做选项列表，
/// 多一份定义就会漂移。
const List<({String value, String label})> kExamTypeOptions =
    <({String value, String label})>[
      (value: 'civil_service', label: '公务员'),
      (value: 'postgrad', label: '考研'),
      (value: 'final_exam', label: '期末'),
      (value: 'vocational', label: '职业资格'),
      (value: 'adult_self_study', label: '成人自考'),
      (value: 'custom', label: '自定义'),
    ];

/// 「每日可用分钟」的说明文案。抽成常量，避免散落在 UI 代码里。
const String kDailyMinutesHelp =
    '每日可用分钟：指每天可用于该考试学习的最大时长，达到上限后当日不再计入学习进度。';

/// 自定义考试类型名称的最大字数（后端 `exam_type_custom` 列约束 ≤20 字）。
const int kExamTypeCustomMaxLength = 20;

/// 考试配置相关的 API 客户端。
class ExamApi {
  ExamApi({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  /// 当前用户的考试目标列表：`GET /users/:userId/exam-profiles`。
  ///
  /// 返回 `List<Map>`（不是强类型模型）——字段按 map key 取，且值可能为 null。
  Future<List<Map<String, Object?>>> fetchExamProfiles(String userId) async {
    final Object? raw = await _client.get(
      '/users/${Uri.encodeComponent(userId)}/exam-profiles',
    );
    return _extractItems(raw);
  }

  /// 某目标下的科目列表：`GET /exam-profiles/:id/subjects`。
  Future<List<Map<String, Object?>>> fetchSubjects(String examProfileId) async {
    final Object? raw = await _client.get(
      '/exam-profiles/${Uri.encodeComponent(examProfileId)}/subjects',
    );
    return _extractItems(raw);
  }

  /// 新建考试目标：`POST /exam-profiles`。
  ///
  /// [examType] 为 `'custom'` 时必须给 [examTypeCustom]（自定义名称）。
  /// [targetScore] / [dailyMinutes] 为 null 时**不传该键**（空串会被后端
  /// 以 INVALID_* 拒掉）。[sourceScope] 是 jsonb 列，必须包成 `{'raw': ...}`。
  ///
  /// 返回后端响应体（通常是 `{profile, subjects}`，也可能是裸 profile）。
  Future<Map<String, Object?>> createExamProfile({
    required String userId,
    required String examType,
    required String targetLabel,
    required String examDate,
    double? targetScore,
    int? dailyMinutes,
    String? sourceScope,
    String? examTypeCustom,
  }) async {
    final String scope = sourceScope?.trim() ?? '';
    final String custom = examTypeCustom?.trim() ?? '';
    final Map<String, Object?> body = <String, Object?>{
      'user_id': userId,
      'exam_type': examType,
      'target_label': targetLabel,
      'exam_date': examDate,
      if (targetScore != null) 'target_score': targetScore,
      if (dailyMinutes != null) 'daily_minutes': dailyMinutes,
      if (custom.isNotEmpty) 'exam_type_custom': custom,
      // jsonb 列：必须给合法 JSON 文本，{'raw': ...} 由 toJsonbParam 序列化。
      if (scope.isNotEmpty) 'source_scope': <String, Object?>{'raw': scope},
    };
    final Object? raw = await _client.post('/exam-profiles', body: body);
    if (raw is! Map) throw ApiException('创建响应不是 JSON 对象', body: raw);
    return raw.cast<String, Object?>();
  }

  /// 删除考试目标：`DELETE /exam-profiles/:id`，body 带 `version`（乐观锁）。
  ///
  /// 调用方必须先从列表项里拿到该目标的 `version`，取不到就不要调
  /// （见 `exam_config_page.dart` 的删除流程）。
  ///
  /// 失败时抛 [ApiException]：
  /// * 409 → `body.error == 'exam_profile_in_use'`（该目标正被缺陷单/模考引用）；
  /// * 404 → 目标不存在或不属于当前用户（跨用户一律 404，不返回 403）。
  Future<Map<String, Object?>> deleteExamProfile(
    String id, {
    required int version,
  }) async {
    final Object? raw = await _client.delete(
      '/exam-profiles/${Uri.encodeComponent(id)}',
      body: <String, Object?>{'version': version},
    );
    if (raw is Map) return raw.cast<String, Object?>();
    return <String, Object?>{};
  }

  // 注：学习进度（GET /exam-profiles/:id/progress）**不在本文件**。
  // 它由 `exam_progress_api.dart` 的 ExamProgressApi 负责（带强类型 ExamProgress），
  // 首页翻转卡片 `widgets/exam_flip_card.dart` 用的是那一个。
  // 刻意不保留第二份 Map 版实现：两份 progress API 迟早漂移。

  /// 后端有时返回 `{items:[...]}`，有时返回裸数组 —— 两种都容错。
  List<Map<String, Object?>> _extractItems(Object? raw) {
    if (raw is Map) {
      final Object? items = raw['items'];
      if (items is List) {
        return items
            .whereType<Map>()
            .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
            .toList(growable: false);
      }
      return const <Map<String, Object?>>[];
    }
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
          .toList(growable: false);
    }
    throw ApiException('列表响应格式不符合预期', body: raw);
  }

  void close() => _client.close();
}
