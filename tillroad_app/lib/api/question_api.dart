// 题库 API（m17431）。
//
// 职责：把后端两个端点映射成界面模型 ——
//   · GET  /questions?subject_id=&limit=&offset=      题库列表（可见 = 公共题 + 自己的题）
//   · POST /questions/import                          导入（body: {filename, mime, content_base64, subject_id, knowledge_node_id}）
//
// 与后端契约的两点差异（已按 server/routes/questions.mjs 与 questions_import.mjs 实现对齐）：
//
// 1) **列表不含 answer / analysis**：题库页只是「看看有哪些题」，
//    答案与解析在真正做这题时才需要，避免在列表页泄露答案。
//
// 2) **归属由后端按 token 决定**：请求体里没有 user_id 字段，
//    前端也不该传 —— 传了也会被 server/index.mjs 改写成 token 用户。
//    `owner_user_id` 只在响应里回读（null = 公共题），用来给「我导入的题」加标记。
//
// 手写 snake_case → camelCase，不引 json_serializable（工程既有取向）。

import 'dart:convert';

import 'api_client.dart';

/// 题库里的一道题（列表口径，不含答案）。
class BankQuestion {
  const BankQuestion({
    required this.id,
    required this.stem,
    required this.type,
    required this.source,
    this.subjectId = '',
    this.knowledgeNodeId = '',
    this.difficulty,
    this.isSubjective = false,
    this.isMine = false,
    this.mastered,
    this.createdAt,
    this.options = const <String>[],
  });

  final String id;
  final String stem;
  final String type;
  final String source;
  final String subjectId;
  final String knowledgeNodeId;
  final String? difficulty;
  final bool isSubjective;

  /// true = 这是「我」导入的题（owner_user_id == 当前用户）；false = 公共题。
  final bool isMine;

  /// 掌握度三态（练习 R2）：
  ///   * `true`  = 已掌握（用户标记过）
  ///   * `false` = 未掌握（用户标记过）
  ///   * `null`  = 未标记（从来没有标记过）
  ///
  /// 后端在列表里逐项回 `mastered`；「没有这一行」与「标记为 false」
  /// 是两回事，所以这里必须是可空布尔而不是普通 bool。
  final bool? mastered;

  /// 入题时间（列表按它倒序）。题库页的「最近 7 天 / 30 天」筛选要用，
  /// 后端 `created_at` 缺失或不可解析时为 null（筛选时按「不在时间窗内」处理）。
  final DateTime? createdAt;

  final List<String> options;

  /// 题型展示名。
  String get typeLabel {
    switch (type) {
      case 'choice':
        return '选择题';
      case 'multi':
        return '多选题';
      case 'judge':
        return '判断题';
      case 'subjective':
        return '主观题';
      case 'fill':
        return '填空题';
      case 'calculation':
        return '计算题';
      default:
        return type.isEmpty ? '未分类' : type;
    }
  }

  /// 来源展示名。
  String get sourceLabel {
    switch (source) {
      case 'manual':
        return '手动';
      case 'photo':
        return '拍照';
      case 'import':
        return '导入';
      case 'mock':
        return '模考';
      case 'ai_generated':
        return 'AI 生成';
      default:
        return source.isEmpty ? '未知' : source;
    }
  }

  /// 题干前两行（列表里只展示前两行，长题干要截断）。
  String get preview {
    final List<String> lines = stem
        .split('\n')
        .map((String l) => l.trim())
        .where((String l) => l.isNotEmpty)
        .toList();
    final String head = lines.take(2).join('\n');
    if (head.length <= 120) return head;
    return '${head.substring(0, 120)}…';
  }

  factory BankQuestion.fromJson(Map<String, Object?> json, {String? currentUserId}) {
    final String owner = _str(json['owner_user_id']);
    return BankQuestion(
      id: _str(json['id']),
      stem: _str(json['stem']),
      type: _str(json['type']),
      source: _str(json['source']),
      subjectId: _str(json['subject_id']),
      knowledgeNodeId: _str(json['knowledge_node_id']),
      difficulty: _strOrNull(json['difficulty']),
      isSubjective: json['is_subjective'] == true,
      isMine: owner.isNotEmpty && owner == currentUserId,
      mastered: json['mastered'] == null
          ? null
          : (json['mastered'] == true),
      createdAt: _dateOrNull(json['created_at']),
      options: _stringList(json['options']),
    );
  }
}

/// 导入结果。
class ImportResult {
  const ImportResult({
    required this.imported,
    required this.duplicates,
    required this.errors,
    this.stats = const <String, Object?>{},
  });

  /// 成功入库的题数。
  final int imported;

  /// 判重的题（已存在，没重复入库）。每条带原题干供用户核对。
  final List<ImportDuplicate> duplicates;

  /// 出错的题（单题级错误）。
  final List<String> errors;

  /// 后端统计（kind/mime/pages/total/bytes…）。
  final Map<String, Object?> stats;

  bool get isSuccess => imported > 0;

  factory ImportResult.fromJson(Map<String, Object?> json) {
    final List<Object?> rawDups = json['duplicates'] is List ? json['duplicates']! as List<Object?> : const <Object?>[];
    final List<Object?> rawErrors = json['errors'] is List ? json['errors']! as List<Object?> : const <Object?>[];
    return ImportResult(
      imported: _int(json['imported'], 0),
      duplicates: rawDups
          .whereType<Map>()
          .map((Map m) => ImportDuplicate.fromJson(m.cast<String, Object?>()))
          .toList(growable: false),
      errors: rawErrors.map((Object? e) => e is Map ? _str(e['message']) : '$e').toList(growable: false),
      stats: _asMap(json['stats']),
    );
  }
}

/// 一条判重记录。
class ImportDuplicate {
  const ImportDuplicate({required this.stem, this.existingId = ''});

  /// 已存在的那道题的题干。
  final String stem;

  /// 已存在的那道题在库里的 id（批内重复时为空）。
  final String existingId;

  factory ImportDuplicate.fromJson(Map<String, Object?> json) {
    return ImportDuplicate(
      stem: _str(json['stem']),
      existingId: _str(json['existing_id']),
    );
  }
}

/// 一道题的完整详情（m23700 FE-02）。
///
/// 与 [BankQuestion]（列表口径）的区别：**带 answer / analysis**。
/// 列表页不给答案是有意的（避免在浏览题库时剧透），
/// 但出题人自己在建题/编辑页必须看到答案与解析。
class QuestionDetail {
  const QuestionDetail({
    required this.id,
    required this.stem,
    required this.type,
    this.source = 'manual',
    this.subjectId = '',
    this.knowledgeNodeId = '',
    this.options = const <QuestionOption>[],
    this.answer = '',
    this.analysis = '',
    this.formulaText = '',
    this.difficulty = '',
    this.tags = const <String>[],
    this.isSubjective = false,
    this.version = 1,
  });

  final String id;
  final String stem;
  final String type;
  final String source;
  final String subjectId;
  final String knowledgeNodeId;

  /// 选项（后端归一成 `{key, text}`）。
  final List<QuestionOption> options;
  final String answer;
  final String analysis;
  final String formulaText;
  final String difficulty;
  final List<String> tags;
  final bool isSubjective;

  /// 乐观锁版本号（编辑与删除都要带上）。
  final int version;

  /// 是否主观题（用于「是/否」开关的初值）。
  ///
  /// 后端另有 [type] 可表达同一件事（short_answer/subjective/essay/material），
  /// 但老数据 is_subjective 可能为 false 而 type 确实是主观题 ——
  /// 所以这里取「或」而不是只看一个字段。
  bool get looksSubjective =>
      isSubjective ||
      type == 'short_answer' ||
      type == 'subjective' ||
      type == 'essay' ||
      type == 'material';

  factory QuestionDetail.fromJson(Map<String, Object?> json) {
    return QuestionDetail(
      id: _str(json['id']),
      stem: _str(json['stem']),
      type: _str(json['type']),
      source: _str(json['source']),
      subjectId: _str(json['subject_id']),
      knowledgeNodeId: _str(json['knowledge_node_id']),
      options: _optionList(json['options']),
      answer: _str(json['answer']),
      analysis: _str(json['analysis']),
      formulaText: _str(json['formula_text']),
      difficulty: _str(json['difficulty']),
      tags: _tagList(json['tags']),
      isSubjective: json['is_subjective'] == true,
      version: _int(json['version'], 1),
    );
  }
}

/// 一个选项（后端统一形状 `{key, text}`）。
class QuestionOption {
  const QuestionOption({required this.key, required this.text});

  final String key;
  final String text;

  /// 发给后端的形状。
  Map<String, String> toJson() => <String, String>{'key': key, 'text': text};

  @override
  String toString() => '$key. $text';
}
/// ★ m26090（R3）：批量操作的结果。
///
/// skipped > 0 说明有一部分题没动（公共题 / 别人的题不属于当前 token 用户），
/// 前端要如实告诉用户「其中 N 道没删掉」，不能当成全成功。
class BatchResult {
  const BatchResult({required this.requested, required this.deleted, required this.skipped});

  factory BatchResult.fromJson(Map<String, Object?> json) {
    final int requested = _int(json['requested'], 0);
    final int deleted = _int(json['deleted'], _int(json['restored'], 0));
    return BatchResult(
      requested: requested,
      deleted: deleted,
      skipped: _int(json['skipped'], requested - deleted),
    );
  }

  final int requested;
  final int deleted;
  final int skipped;

  @override
  String toString() => 'requested=$requested deleted=$deleted skipped=$skipped';
}

class QuestionApi {
  QuestionApi({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  /// 释放底层 HTTP client（页面 dispose 时调）。
  void close() => _client.close();

  /// 题库列表：`GET /questions?subject_id=&limit=&offset=`。
  ///
  /// 后端只返回「公共题 + 当前 token 用户自己的题」，别人的私有题不可见。
  Future<List<BankQuestion>> fetchQuestions({
    String? subjectId,
    String? knowledgeNodeId,
    String? q,
    int limit = 50,
    int offset = 0,
    bool? mastered,
    String? currentUserId,
  }) async {
    final Object? raw = await _client.get(
      '/questions',
      query: <String, String>{
        if (subjectId != null && subjectId.isNotEmpty) 'subject_id': subjectId,
        if (knowledgeNodeId != null && knowledgeNodeId.isNotEmpty)
          'knowledge_node_id': knowledgeNodeId,
        // m21780：题干关键字由后端 ILIKE 过滤（已做 LIKE 元字符转义），
        // 空白串不当参数传，免得白白走一次 `ILIKE '%%'`。
        if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
        // 练习 R2：掌握度过滤。后端只认字符串 'true'/'false'，
        // 所以这里传字符串而不是 bool（null = 不筛选）。
        if (mastered != null) 'mastered': mastered ? 'true' : 'false',
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    if (raw is! Map) throw ApiException('题库响应不是 JSON 对象', body: raw);
    final Map<String, Object?> map = raw.cast<String, Object?>();
    final Object? items = map['items'];
    if (items is! List) return const <BankQuestion>[];
    return items
        .whereType<Map>()
        .map((Map m) => BankQuestion.fromJson(m.cast<String, Object?>(), currentUserId: currentUserId))
        .toList(growable: false);
  }

  /// 导入：`POST /questions/import`。
  ///
  /// [contentBase64] 是文件内容的 base64（JSON 传输，不走 multipart）。
  /// 后端返回 `{imported, duplicates, errors, stats}`。
  Future<ImportResult> importQuestions({
    required String filename,
    required String contentBase64,
    String? mime,
    String? subjectId,
    String? knowledgeNodeId,
  }) async {
    final Map<String, Object?> body = <String, Object?>{
      'filename': filename,
      'content_base64': contentBase64,
      if (mime != null && mime.isNotEmpty) 'mime': mime,
      if (subjectId != null && subjectId.isNotEmpty) 'subject_id': subjectId,
      if (knowledgeNodeId != null && knowledgeNodeId.isNotEmpty) 'knowledge_node_id': knowledgeNodeId,
    };
    final Object? raw = await _client.post('/questions/import', body: body);
    if (raw is! Map) throw ApiException('导入响应不是 JSON 对象', body: raw);
    return ImportResult.fromJson(raw.cast<String, Object?>());
  }
  /// 单题详情（m23700 FE-02）。
  ///
  /// 列表口径（[fetchQuestions]）刻意不含 answer/analysis；但出题人自己在
  /// 编辑页要看到答案与解析，所以单题详情端点会返回它们。
  Future<QuestionDetail> fetchQuestion(String id) async {
    final Object? raw = await _client.get('/questions/$id');
    if (raw is! Map) throw ApiException('题目详情不是 JSON 对象', body: raw);
    return QuestionDetail.fromJson(raw.cast<String, Object?>());
  }

  /// 手动建题：`POST /questions`。
  ///
  /// 后端强制 `source='manual'`、`owner_user_id` 取 token，
  /// 所以这里不用（也不该）传这两个字段。
  Future<QuestionDetail> createQuestion({
    required String type,
    required String stem,
    String? subjectId,
    String? knowledgeNodeId,
    List<Map<String, String>>? options,
    String? answer,
    String? analysis,
    String? formulaText,
    String? difficulty,
    List<String>? tags,
    bool isSubjective = false,
  }) async {
    final Map<String, Object?> body = <String, Object?>{
      'type': type,
      'stem': stem,
      if (subjectId != null && subjectId.isNotEmpty) 'subject_id': subjectId,
      if (knowledgeNodeId != null && knowledgeNodeId.isNotEmpty)
        'knowledge_node_id': knowledgeNodeId,
      if (options != null) 'options': options,
      if (answer != null) 'answer': answer,
      if (analysis != null) 'analysis': analysis,
      if (formulaText != null) 'formula_text': formulaText,
      if (difficulty != null) 'difficulty': difficulty,
      if (tags != null) 'tags': tags,
      'is_subjective': isSubjective,
    };
    final Object? raw = await _client.post('/questions', body: body);
    if (raw is! Map) throw ApiException('建题响应不是 JSON 对象', body: raw);
    return QuestionDetail.fromJson(raw.cast<String, Object?>());
  }

  /// 编辑题目：`PATCH /questions/:id`。
  ///
  /// [version] 是乐观锁基准 —— 拿的是打开编辑页时读到的版本；
  /// 别人改过这题就会 409 conflict，前端要提示「已被修改」而不是静默覆盖。
  Future<QuestionDetail> updateQuestion({
    required String id,
    required int version,
    String? type,
    String? stem,
    String? subjectId,
    String? knowledgeNodeId,
    List<Map<String, String>>? options,
    String? answer,
    String? analysis,
    String? formulaText,
    String? difficulty,
    List<String>? tags,
    bool? isSubjective,
  }) async {
    final Map<String, Object?> body = <String, Object?>{
      'version': version,
      if (type != null) 'type': type,
      if (stem != null) 'stem': stem,
      if (subjectId != null) 'subject_id': subjectId,
      if (knowledgeNodeId != null) 'knowledge_node_id': knowledgeNodeId,
      if (options != null) 'options': options,
      if (answer != null) 'answer': answer,
      if (analysis != null) 'analysis': analysis,
      if (formulaText != null) 'formula_text': formulaText,
      if (difficulty != null) 'difficulty': difficulty,
      if (tags != null) 'tags': tags,
      if (isSubjective != null) 'is_subjective': isSubjective,
    };
    final Object? raw = await _client.patch('/questions/$id', body: body);
    if (raw is! Map) throw ApiException('改题响应不是 JSON 对象', body: raw);
    return QuestionDetail.fromJson(raw.cast<String, Object?>());
  }

  /// 删除题目：`DELETE /questions/:id`（软删，version 必填）。
  /// 标记题目掌握度：`PATCH /questions/:id/mastery`。
  ///
  /// 后端按 token 决定归属，**只能标记自己的题**：
  /// 公共题或别人的私有题一律 403 `FORBIDDEN_MASTERY`。
  ///
  /// 语义：`mastered=true` 记「已掌握」；`false` 记「未掌握」；
  /// 从没标记过的题在列表里是第三态（null），所以「未掌握」和「未标记」不同。
  Future<void> setMastery({required String id, required bool mastered}) async {
    await _client.patch(
      '/questions/$id/mastery',
      body: <String, Object?>{'mastered': mastered},
    );
  }

  /// 删除题目：`DELETE /questions/:id`（软删，version 必填）。
  Future<void> deleteQuestion({required String id, required int version}) async {
    await _client.delete('/questions/$id', body: <String, Object?>{'version': version});
  }

  /// ★ m26090（R3）：恢复软删的题：`PATCH /questions/:id/restore`。
  ///
  /// 后端刻意不要求 base_version —— 恢复不是「基于某个版本改内容」，
  /// 只是把墓碑搬回来。
  Future<void> restoreQuestion({required String id}) async {
    await _client.patch('/questions/$id/restore', body: <String, Object?>{});
  }

  /// ★ m26090（R3）：隐藏 / 取消隐藏题目：`PATCH /questions/:id/hide`。
  ///
  /// 公共题不能软删（不属于任何用户），只能「只对我隐藏」。
  Future<void> setHidden({required String id, required bool hidden}) async {
    await _client.patch(
      '/questions/$id/hide',
      body: <String, Object?>{'hidden': hidden},
    );
  }

  /// ★ m26090（R3）：批量软删：`DELETE /questions/batch`。
  ///
  /// 返回 `BatchResult{requested, deleted, skipped}` ——
  /// skipped 是被跳过的数量（公共题 / 别人的题不属于你，删不掉）。
  Future<BatchResult> deleteQuestionsBatch(List<String> ids) async {
    final Object? raw = await _client.delete(
      '/questions/batch',
      body: <String, Object?>{'ids': ids},
    );
    if (raw is! Map) throw ApiException('批量删除响应不是 JSON 对象', body: raw);
    return BatchResult.fromJson(raw.cast<String, Object?>());
  }

  /// ★ m26090（R3）：批量恢复：`PATCH /questions/batch/restore`。
  Future<BatchResult> restoreQuestionsBatch(List<String> ids) async {
    final Object? raw = await _client.patch(
      '/questions/batch/restore',
      body: <String, Object?>{'ids': ids},
    );
    if (raw is! Map) throw ApiException('批量恢复响应不是 JSON 对象', body: raw);
    return BatchResult.fromJson(raw.cast<String, Object?>());
  }

  /// ★ m26090（R3）：列已软删的题：`GET /questions/deleted`。
  Future<List<BankQuestion>> fetchDeletedQuestions({
    int limit = 50,
    int offset = 0,
    String? currentUserId,
  }) async {
    final Object? raw = await _client.get(
      '/questions/deleted',
      query: <String, String>{'limit': '$limit', 'offset': '$offset'},
    );
    if (raw is! Map) throw ApiException('已删除题目响应不是 JSON 对象', body: raw);
    final Object? items = raw.cast<String, Object?>()['items'];
    if (items is! List) return const <BankQuestion>[];
    return items
        .whereType<Map>()
        .map((Map m) => BankQuestion.fromJson(m.cast<String, Object?>(), currentUserId: currentUserId))
        .toList(growable: false);
  }
}

// ── 映射辅助（与 review_api.dart / defect_api.dart 同风格）───────────────────

String _str(Object? v) => v == null ? '' : '$v';

String? _strOrNull(Object? v) {
  final String s = _str(v).trim();
  return s.isEmpty ? null : s;
}

/// 时间解析：后端给的是 ISO 8601 字符串，解析失败返回 null（不抛，不让一条烂数据拖死整页）。
DateTime? _dateOrNull(Object? v) {
  final String s = _str(v).trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s)?.toLocal();
}

int _int(Object? v, int fallback) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

Map<String, Object?> _asMap(Object? v) {
  if (v is Map) return v.cast<String, Object?>();
  return const <String, Object?>{};
}
/// tags 是 jsonb 数组，只取字符串元素。
List<String> _tagList(Object? v) {
  if (v is! List) return const <String>[];
  return v
      .whereType<String>()
      .map((String t) => t.trim())
      .where((String t) => t.isNotEmpty)
      .toList(growable: false);
}

/// options 是 jsonb 数组。后端建题/改题统一成 `{key, text}`，
/// 但老数据（导入的题）可能是纯字符串或 `{key, value}` —— 三种都要能读。
List<QuestionOption> _optionList(Object? v) {
  if (v is! List) return const <QuestionOption>[];
  final List<QuestionOption> out = <QuestionOption>[];
  int index = 0;
  for (final Object? item in v) {
    final String fallbackKey = String.fromCharCode(65 + index);
    index++;
    if (item is String) {
      final String text = item.trim();
      if (text.isEmpty) continue;
      // 'A. 选项文本' / 'A、选项文本' —— 取首字母当 key（与后端 normalizeOptions 同口径）
      final RegExpMatch? m = RegExp(r'^([A-Za-z])\s*[.、．:：)]?\s*(.*)$').firstMatch(text);
      out.add(
        QuestionOption(
          key: m == null ? fallbackKey : m.group(1)!.toUpperCase(),
          text: m == null ? text : m.group(2)!,
        ),
      );
    } else if (item is Map) {
      final Map<String, Object?> m = item.cast<String, Object?>();
      final String key = _str(m['key']).trim();
      final String text = _str(m['text']).trim().isNotEmpty
          ? _str(m['text']).trim()
          : _str(m['value']).trim();
      if (text.isEmpty) continue;
      out.add(QuestionOption(key: key.isEmpty ? fallbackKey : key.toUpperCase(), text: text));
    }
  }
  return out;
}

/// options 是 jsonb 数组，元素可能是字符串，也可能是 `{key, value}` 形状。
List<String> _stringList(Object? v) {
  if (v is! List) return const <String>[];
  final List<String> out = <String>[];
  for (final Object? item in v) {
    if (item is String) {
      out.add(item);
    } else if (item is Map) {
      final Map<String, Object?> m = item.cast<String, Object?>();
      final String key = _str(m['key']);
      final String value = _str(m['value']);
      out.add(key.isEmpty ? value : '$key. $value');
    }
  }
  return out;
}

/// base64 编码（导入端点只走 JSON + base64，不走 multipart）。
String encodeBase64(List<int> bytes) => base64Encode(bytes);
