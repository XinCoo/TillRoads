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
