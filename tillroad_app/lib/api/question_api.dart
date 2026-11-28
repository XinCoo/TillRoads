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

/// 题型 → 中文标签的**唯一**映射表。
///
/// 题库列表、题型统计（`GET /question-types`）都要用同一套口径，
/// 免得同一个题型在两个页面上显示成两个名字。
const Map<String, String> kQuestionTypeLabels = <String, String>{
  'choice': '选择题',
  'multi': '多选题',
  'judge': '判断题',
  'fill': '填空题',
  'calculation': '计算题',
  'short_answer': '简答题',
  'subjective': '主观题',
  'essay': '论述题',
  'material': '材料题',
};

/// 题型的中文标签。未知题型回退成原值（后端以后加新类型也不至于显示成空白）。
String questionTypeLabel(String type) {
  final String t = type.trim();
  if (t.isEmpty) return '未分类';
  return kQuestionTypeLabels[t] ?? t;
}

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
    this.tags = const <String>[],
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

  /// 考点标签（后端 tags jsonb 数组）。列表口径也带上，管理页要显示/编辑它。
  final List<String> tags;

  /// 题型展示名。
  String get typeLabel => questionTypeLabel(type);

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
      tags: _tagList(json['tags']),
    );
  }
}

/// 导入结果。
class ImportResult {
  const ImportResult({
    this.importedNew = 0,
    this.importedOverwritten = 0,
    this.duplicatesSkipped = 0,
    this.duplicatesOverwritten = 0,
    this.duplicates = const <ImportDuplicate>[],
    this.errors = const <String>[],
    this.stats = const <String, Object?>{},
    this.subjectMatched = const ImportSubjectMatch(),
    this.nodeCreated = const ImportNodeCreated(),
    this.remapResult = const ImportRemapResult(),
  });

  /// 真正**新入库**的题数（`imported.new`）。
  final int importedNew;

  /// 覆盖写入的题数（`imported.overwritten`，即选了 `overwrite` 后
  /// 用文件内容更新了库里同题的条数）。
  final int importedOverwritten;

  /// 判重跳过的题数（`duplicates.skipped`，即因为库里已有而没入库的条数）。
  final int duplicatesSkipped;

  /// 判重项里被覆盖的题数（`duplicates.overwritten`）。
  ///
  /// 与 [importedOverwritten] 口径不同：前者是「重复题里被覆盖了多少」，
  /// 后者是「入库动作里有多少是覆盖」，正常一次导入两者应当相等，
  /// 分开保留是为了后端拆分统计口径时前端不必改签名。
  final int duplicatesOverwritten;

  /// 重复题的明细（新结构在 `duplicate_details`）。
  ///
  /// 每条带原题干（`stem`）与库里的 id（`existing_id`）供用户核对；
  /// 旧后端这个列表明细在 `duplicates` 数组里，[fromJson] 已做兼容。
  final List<ImportDuplicate> duplicates;

  /// 出错的题（单题级错误）。
  final List<String> errors;

  /// 后端统计（kind/mime/pages/total/bytes…）。
  final Map<String, Object?> stats;

  /// 按科目匹配结果（`subject_matched`）。
  ///
  /// 旧后端没有这个字段 —— [ImportSubjectMatch.fromJson] 容错成全 0，
  /// 界面据此整块不显示（不能拿 0 冒充「一道都没匹配上」）。
  final ImportSubjectMatch subjectMatched;

  /// 导入过程中自动创建的考点（`node_created`），同样是旧后端可缺失的字段。
  final ImportNodeCreated nodeCreated;

  /// 跨设备恢复结果（`remap_result`，m34301）。
  ///
  /// 只有带 subjects / knowledge_nodes 的 `.tillroad` 导出文件才会填这个字段；
  /// 普通 AI JSON / 文本导入时后端给全 0 —— 界面靠 [ImportRemapResult.isEmpty]
  /// 判断整块不渲染，避免在每次普通导入后都显示一行「恢复了 0 个科目」。
  final ImportRemapResult remapResult;
  /// 是否有题真正动过库。
  ///
  /// 注意语义变了：**「全部被跳过」不算成功**（`importedNew` 与
  /// `importedOverwritten` 都是 0），但也不能算失败 ——
  /// 调用方要结合 [duplicatesSkipped] 判断，别把「全已存在」显示成红的。
  bool get isSuccess => importedNew > 0 || importedOverwritten > 0;

  factory ImportResult.fromJson(Map<String, Object?> json) {
    // ── 旧响应结构兼容（护栏）──────────────────────────────────────────
    // 旧后端：`imported` 是**数字**（新入库题数）、`duplicates` 是**数组**
    //（判重明细）。新后端：`imported` 是 `{new, overwritten}`、
    // `duplicates` 是 `{skipped, overwritten}`，明细搬到了 `duplicate_details`。
    // 这里按「先看类型再取值」解析，两种形状都能读 —— 是为了让前端先上线、
    // 后端灰度或回滚时页面不会因为一次 `is int` 判断写反就整页报错。
    final Object? rawImported = json['imported'];
    final int importedNew = rawImported is int
        ? rawImported
        : _int(_asMap(rawImported)['new'], 0);
    final int importedOverwritten =
        rawImported is int ? 0 : _int(_asMap(rawImported)['overwritten'], 0);

    final Object? rawDuplicates = json['duplicates'];
    final int duplicatesSkipped = rawDuplicates is List
        ? rawDuplicates.length
        : _int(_asMap(rawDuplicates)['skipped'], 0);
    final int duplicatesOverwritten =
        rawDuplicates is List ? 0 : _int(_asMap(rawDuplicates)['overwritten'], 0);

    // 明细优先读 `duplicate_details`；旧结构就直接用 `duplicates` 数组本身。
    final List<Object?> rawDups = json['duplicate_details'] is List
        ? json['duplicate_details']! as List<Object?>
        : (rawDuplicates is List ? rawDuplicates : const <Object?>[]);
    final List<Object?> rawErrors = json['errors'] is List ? json['errors']! as List<Object?> : const <Object?>[];
    return ImportResult(
      importedNew: importedNew,
      importedOverwritten: importedOverwritten,
      duplicatesSkipped: duplicatesSkipped,
      duplicatesOverwritten: duplicatesOverwritten,
      duplicates: rawDups
          .whereType<Map>()
          .map((Map m) => ImportDuplicate.fromJson(m.cast<String, Object?>()))
          .toList(growable: false),
      errors: rawErrors.map((Object? e) => e is Map ? _str(e['message']) : '$e').toList(growable: false),
      stats: _asMap(json['stats']),
      subjectMatched: ImportSubjectMatch.fromJson(_asMap(json['subject_matched'])),
      nodeCreated: ImportNodeCreated.fromJson(_asMap(json['node_created'])),
      remapResult: ImportRemapResult.fromJson(_asMap(json['remap_result'])),
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

/// 导入预检结果（`POST /questions/import/preview`，不写库）。
///
/// 预检只回答三件事：会新进多少道、会撞上多少道重复、哪些条目根本解析不出来。
/// 真正的导入仍走 [QuestionApi.importQuestions]，决策（跳过 / 覆盖）由用户在预检页选。
class ImportPreviewResult {
  const ImportPreviewResult({
    this.newCount = 0,
    this.duplicateCount = 0,
    this.duplicates = const <ImportPreviewDuplicate>[],
    this.parseErrors = const <String>[],
  });

  /// 会新入库的题数（`new_count`）。
  final int newCount;

  /// 与库里已有题重复的条数（`duplicate_count`，含「同一文件内互相重复」）。
  final int duplicateCount;

  /// 重复题明细（`duplicates`），供用户逐条核对题干与差异。
  final List<ImportPreviewDuplicate> duplicates;

  /// 解析失败的条目说明（`parse_errors[].message`）。
  ///
  /// 这些条目**不会被导入**，所以要逐条告诉用户是哪一条、为什么。
  final List<String> parseErrors;

  bool get hasDuplicates => duplicateCount > 0;

  /// 文件里一道可用的题都没有（既没有新题、也没有重复题）。
  bool get isEmptyFile => newCount == 0 && duplicateCount == 0;

  factory ImportPreviewResult.fromJson(Map<String, Object?> json) {
    final List<Object?> rawDuplicates =
        json['duplicates'] is List ? json['duplicates']! as List<Object?> : const <Object?>[];
    final List<Object?> rawErrors =
        json['parse_errors'] is List ? json['parse_errors']! as List<Object?> : const <Object?>[];
    return ImportPreviewResult(
      newCount: _int(json['new_count'], 0),
      duplicateCount: _int(json['duplicate_count'], 0),
      duplicates: rawDuplicates
          .whereType<Map>()
          .map((Map m) => ImportPreviewDuplicate.fromJson(m.cast<String, Object?>()))
          .toList(growable: false),
      // `parse_errors` 是 `[{message}]`，只取 message（可能为空白，过滤掉）。
      parseErrors: rawErrors
          .map((Object? e) => e is Map ? _str(e['message']).trim() : '$e'.trim())
          .where((String e) => e.isNotEmpty)
          .toList(growable: false),
    );
  }
}

/// 预检里的一条重复题。
///
/// 注意 [existingId] 可能为 null：同一份文件内部前后重复、而库里还没有这道题时，
/// 后端给不出「已存在的那道题」，界面上要按「文件内重复」呈现。
class ImportPreviewDuplicate {
  const ImportPreviewDuplicate({
    this.incomingStem = '',
    this.incomingType = '',
    this.contentHash = '',
    this.existingId,
    this.existingStem,
    this.existingCreatedAt,
    this.diff = const <String>[],
  });

  /// 文件里那道题的题干（后端可能已截断）。
  final String incomingStem;

  /// 文件里那道题的题型（原始值，如 `choice`）。
  final String incomingType;

  /// 判重用的内容指纹。
  final String contentHash;

  /// 库里已存在的那道题的 id（文件内重复且库里没有时为 null）。
  final String? existingId;

  /// 库里已存在的那道题的题干。
  final String? existingStem;

  /// 库里那道题的入库时间。
  final DateTime? existingCreatedAt;

  /// 差异说明（中文短语，如 `answer 不同`）；空数组 = 内容一致。
  final List<String> diff;

  /// 库里是否真的有这道题（false = 只跟文件里的另一道重复）。
  bool get hasExisting {
    final String? id = existingId;
    return id != null && id.trim().isNotEmpty;
  }

  /// 列表里显示的题干（前 30 个字符，超出加省略号）。
  String get shortIncomingStem {
    final String stem = incomingStem.trim();
    if (stem.length <= 30) return stem;
    return '${stem.substring(0, 30)}…';
  }

  /// 差异摘要（空数组时回「内容相同」）。
  String get diffLabel => diff.isEmpty ? '内容相同' : diff.join('、');

  /// 题型展示名（复用全局口径）。
  String get incomingTypeLabel => questionTypeLabel(incomingType);

  factory ImportPreviewDuplicate.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> incoming = _asMap(json['incoming']);
    // `existing` 可能显式为 null —— 这时整段按「库里没有」处理。
    final Map<String, Object?> existing = _asMap(json['existing']);
    return ImportPreviewDuplicate(
      incomingStem: _str(incoming['stem']),
      incomingType: _str(incoming['type']),
      contentHash: _str(incoming['content_hash']),
      existingId: _strOrNull(existing['id']),
      existingStem: _strOrNull(existing['stem']),
      existingCreatedAt: _dateOrNull(existing['created_at']),
      diff: json['diff'] is List
          ? (json['diff']! as List<Object?>)
              .map((Object? e) => _str(e).trim())
              .where((String e) => e.isNotEmpty)
              .toList(growable: false)
          : const <String>[],
    );
  }
}

/// 一个科目的匹配计数（`subject_matched.matched_subjects[i]`）。
class ImportSubjectCount {
  const ImportSubjectCount({
    this.subjectId = '',
    this.name = '',
    this.count = 0,
  });

  final String subjectId;
  final String name;
  final int count;

  factory ImportSubjectCount.fromJson(Map<String, Object?> json) {
    return ImportSubjectCount(
      subjectId: _str(json['subject_id']),
      name: _str(json['name']),
      count: _int(json['count'], 0),
    );
  }
}

/// 导入时的按科目匹配结果（`subject_matched`）。
///
/// 旧后端（以及只传了 subject_id 的 uniform 导入）可能整段缺失，
/// 此时 fromJson 全部归零 —— 界面用 [isEmpty] 判断要不要显示这个区块。
class ImportSubjectMatch {
  const ImportSubjectMatch({
    this.matchedCount = 0,
    this.unmatchedCount = 0,
    this.unmatchedSubjects = const <String>[],
    this.matchedSubjects = const <ImportSubjectCount>[],
  });

  /// 按文件里的 `subject` 文本匹配上的题数。
  final int matchedCount;

  /// 没匹配上、落进兜底科目的题数。
  final int unmatchedCount;

  /// 没匹配上的科目名（文件里写的原始文本）。
  final List<String> unmatchedSubjects;

  /// 匹配上的科目及各自题数。
  final List<ImportSubjectCount> matchedSubjects;

  /// 完全没有匹配信息（旧后端）。
  bool get isEmpty =>
      matchedCount == 0 &&
      unmatchedCount == 0 &&
      unmatchedSubjects.isEmpty &&
      matchedSubjects.isEmpty;

  factory ImportSubjectMatch.fromJson(Map<String, Object?> json) {
    if (json.isEmpty) return const ImportSubjectMatch();
    final List<Object?> rawMatched =
        json['matched_subjects'] is List ? json['matched_subjects']! as List<Object?> : const <Object?>[];
    return ImportSubjectMatch(
      matchedCount: _int(json['matched_count'], 0),
      unmatchedCount: _int(json['unmatched_count'], 0),
      unmatchedSubjects: json['unmatched_subjects'] is List
          ? (json['unmatched_subjects']! as List<Object?>)
              .map((Object? e) => _str(e).trim())
              .where((String e) => e.isNotEmpty)
              .toList(growable: false)
          : const <String>[],
      matchedSubjects: rawMatched
          .whereType<Map>()
          .map((Map m) => ImportSubjectCount.fromJson(m.cast<String, Object?>()))
          .toList(growable: false),
    );
  }
}

/// 导入时自动创建的考点（`node_created`）。旧后端同样可能缺失。
class ImportNodeCreated {
  const ImportNodeCreated({
    this.createdCount = 0,
    this.createdPaths = const <String>[],
  });

  final int createdCount;

  /// 新建考点的路径，形如 `资料分析/增长率`。
  final List<String> createdPaths;

  bool get isEmpty => createdCount == 0 && createdPaths.isEmpty;

  factory ImportNodeCreated.fromJson(Map<String, Object?> json) {
    if (json.isEmpty) return const ImportNodeCreated();
    return ImportNodeCreated(
      createdCount: _int(json['created_count'], 0),
      createdPaths: json['created_paths'] is List
          ? (json['created_paths']! as List<Object?>)
              .map((Object? e) => _str(e).trim())
              .where((String e) => e.isNotEmpty)
              .toList(growable: false)
          : const <String>[],
    );
  }
}

/// 跨设备恢复结果（`remap_result`，m34301）。
///
/// 语义分两对：
/// - `subjects_mapped` / `nodes_mapped`：目标库里已有同名科目 / 同路径考点，**复用**了；
/// - `subjects_created` / `nodes_created`：目标库里没有，本次**新建**了。
/// 两者相加就是「文件里一共有多少科目 / 考点被处理」。
///
/// `questions_without_subject` 是映射失败的题数（文件里的 subject_id 在目标库找不到，
/// 且文件自己的 subjects 数组里也没声明）——这些题仍会入库，只是没有科目。
class ImportRemapResult {
  const ImportRemapResult({
    this.subjectsMapped = 0,
    this.subjectsCreated = 0,
    this.nodesMapped = 0,
    this.nodesCreated = 0,
    this.questionsWithoutSubject = 0,
    this.createdSubjectNames = const <String>[],
    this.createdNodePaths = const <String>[],
  });

  final int subjectsMapped;
  final int subjectsCreated;
  final int nodesMapped;
  final int nodesCreated;
  final int questionsWithoutSubject;

  /// 新建的科目名（供用户确认是否要保留）。
  final List<String> createdSubjectNames;

  /// 新建的考点路径，形如 `资料分析/增长率`。
  final List<String> createdNodePaths;

  /// 无事可报：普通 AI JSON / 文本导入，或文件里根本没有分类树。
  /// 界面据此整块不渲染。
  bool get isEmpty =>
      subjectsMapped == 0 &&
      subjectsCreated == 0 &&
      nodesMapped == 0 &&
      nodesCreated == 0 &&
      questionsWithoutSubject == 0;

  /// 是否发生了「新建」（用于把提示语从「已恢复」改成「已恢复 + 新建了…」）。
  bool get hasCreated => subjectsCreated > 0 || nodesCreated > 0;

  factory ImportRemapResult.fromJson(Map<String, Object?> json) {
    if (json.isEmpty) return const ImportRemapResult();
    List<String> readList(Object? raw) => raw is List
        ? raw
            .map((Object? e) => _str(e).trim())
            .where((String e) => e.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    return ImportRemapResult(
      subjectsMapped: _int(json['subjects_mapped'], 0),
      subjectsCreated: _int(json['subjects_created'], 0),
      nodesMapped: _int(json['nodes_mapped'], 0),
      nodesCreated: _int(json['nodes_created'], 0),
      questionsWithoutSubject: _int(json['questions_without_subject'], 0),
      createdSubjectNames: readList(json['created_subject_names']),
      createdNodePaths: readList(json['created_node_paths']),
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
    final int deleted = _int(json['deleted'], _int(json['restored'], _int(json['updated'], 0)));
    return BatchResult(
      requested: requested,
      deleted: deleted,
      skipped: _int(json['skipped'], requested - deleted),
    );
  }

  final int requested;
  final int deleted;
  final int skipped;

  /// 批量改标签时后端回的是 `updated`；[BatchResult.fromJson] 已把它读进
  /// [deleted]，这里再给一个语义明确的名字。
  int get updated => deleted;

  @override
  String toString() => 'requested=$requested deleted=$deleted skipped=$skipped';
}
/// ★ m31124：一次导入的批次档案（`GET /import-batches` 的一项）。
///
/// 后端实际返回 4 列白名单：`id` / `filename` / `question_count` / `created_at`。
/// [questionCount] 是「那次导入真正入库的题数」—— 不是当前还剩多少道，
/// 所以即使整批被删掉，它仍然显示当初导入的数量（账本语义）。
class ImportBatch {
  const ImportBatch({
    required this.id,
    required this.filename,
    this.questionCount = 0,
    this.createdAt,
  });

  final String id;
  final String filename;
  final int questionCount;
  final DateTime? createdAt;

  /// 下拉里显示的文案：`文件名（N 题）· 3 分钟前`。
  ///
  /// 文件名可能很长（用户传的原始文件名），截断到 24 个字符并保留扩展名，
  /// 免得下拉被一个超长文件名挤成两三行。
  String get label {
    final String name = filename.trim().isEmpty ? '未命名文件' : filename.trim();
    return '${_shortenFileName(name)}（$questionCount 题）· ${relativeTimeLabel(createdAt)}';
  }

  factory ImportBatch.fromJson(Map<String, Object?> json) {
    return ImportBatch(
      id: _str(json['id']),
      filename: _str(json['filename']),
      questionCount: _int(json['question_count'], 0),
      createdAt: _dateOrNull(json['created_at']),
    );
  }

  @override
  String toString() => 'ImportBatch($id, $filename, $questionCount)';
}

/// 文件名截断：保留扩展名，主体截到 18 个字符。
String _shortenFileName(String name) {
  if (name.length <= 24) return name;
  final int dot = name.lastIndexOf('.');
  final String ext = dot > 0 && name.length - dot <= 6 ? name.substring(dot) : '';
  final String body = ext.isEmpty ? name : name.substring(0, dot);
  final String head = body.length <= 18 ? body : '${body.substring(0, 18)}…';
  return '$head$ext';
}

/// 相对时间：下拉里不需要精确到秒，只要「刚才 / N 分钟前 / N 小时前 / N 天前」。
///
/// [when] 为 null（后端没给或解析失败）时回「刚刚」，不用「未知时间」这种噪音文案。
String relativeTimeLabel(DateTime? when) {
  if (when == null) return '刚刚';
  final Duration diff = DateTime.now().difference(when);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  final DateTime local = when.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}

/// 一种题型的统计（`GET /question-types` 的一项）。
class QuestionTypeCount {
  const QuestionTypeCount({required this.type, required this.count});

  /// 后端的题型原始值（如 `choice`）。
  final String type;

  /// 这种题型有多少道题。
  final int count;

  /// 中文标签（复用 [questionTypeLabel] 的统一口径，未知类型回退成原值）。
  String get label => questionTypeLabel(type);

  factory QuestionTypeCount.fromJson(Map<String, Object?> json) {
    return QuestionTypeCount(
      type: _str(json['type']),
      count: _int(json['count'], 0),
    );
  }

  @override
  String toString() => '$type=$count';
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
    /// ★ m31124：按导入批次筛选（`GET /questions?batch_id=...`）。
    ///
    /// null / 空串 = 全部批次。手动建的题 `batch_id` 是 NULL，
    /// 所以选具体批次时它们不会出现在列表里（需求 C3）。
    String? batchId,
    /// ★ m31635：题型过滤（`GET /questions?type=choice,multi`）。
    ///
    /// 后端接受逗号分隔的多值；这里保持 string，便于后续做多选
    /// 而不用改调用方签名。null / 空串 = 不按题型过滤。
    String? type,
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
        // m31124：批次筛选。空串不传，免得后端把 `batch_id=` 当成有效值（它会 trim 后判空，
        // 但请求里多一个空参数没有意义，日志里也不好读）。
        if (batchId != null && batchId.trim().isNotEmpty) 'batch_id': batchId.trim(),
        // ★ m31635：题型过滤。多值由调用方用逗号拼好（后端按数组比较）。
        if (type != null && type.trim().isNotEmpty) 'type': type.trim(),
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
  /// 新契约响应：`{imported:{new,overwritten}, duplicates:{skipped,overwritten},
  /// duplicate_details, errors, stats, ...}` —— 旧形状由 [ImportResult.fromJson] 兼容。
  Future<ImportResult> importQuestions({
    required String filename,
    required String contentBase64,
    String? mime,
    String? subjectId,
    String? knowledgeNodeId,
    /// 科目归属模式：`from_file`（按每题自带的 subject 文本匹配，
    /// subject_id 降级为匹配失败时的兜底科目）或 `uniform`
    /// （现有行为：全部题进 subject_id，缺省）。
    String subjectMode = 'uniform',
    /// 判重决策：`skip`（缺省，跳过重复题，与旧行为一致）
    /// 或 `overwrite`（用文件里的内容覆盖库里同题）。
    String duplicateAction = 'skip',
  }) async {
    final Map<String, Object?> body = _importBody(
      filename: filename,
      contentBase64: contentBase64,
      mime: mime,
      subjectId: subjectId,
      knowledgeNodeId: knowledgeNodeId,
      subjectMode: subjectMode,
    );
    // 判重决策**无条件**带上：缺省 `skip` 与旧行为完全一致；
    // 后端按 `decisions.duplicate_action` 分流（字段缺失也当 skip）。
    body['decisions'] = <String, Object?>{'duplicate_action': duplicateAction};
    final Object? raw = await _client.post('/questions/import', body: body);
    if (raw is! Map) throw ApiException('导入响应不是 JSON 对象', body: raw);
    return ImportResult.fromJson(raw.cast<String, Object?>());
  }
  /// 导入预检：`POST /questions/import/preview`（不写库）。
  ///
  /// 请求体与 [importQuestions] **完全相同** —— 两者共用 [_importBody] 构造，
  /// 避免以后补字段时只改了一边、预检与真正导入的口径悄悄漂移。
  Future<ImportPreviewResult> previewImport({
    required String filename,
    required String contentBase64,
    String? mime,
    String? subjectId,
    String? knowledgeNodeId,
    String subjectMode = 'uniform',
  }) async {
    final Map<String, Object?> body = _importBody(
      filename: filename,
      contentBase64: contentBase64,
      mime: mime,
      subjectId: subjectId,
      knowledgeNodeId: knowledgeNodeId,
      subjectMode: subjectMode,
    );
    final Object? raw = await _client.post('/questions/import/preview', body: body);
    if (raw is! Map) throw ApiException('预检响应不是 JSON 对象', body: raw);
    return ImportPreviewResult.fromJson(raw.cast<String, Object?>());
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

  /// ★ m31124：整批删除：`DELETE /questions/batch` body `{batch_id}`。
  ///
  /// 与 [deleteQuestionsBatch]（按 id 数组）走同一个端点，后端按 body 里有没有
  /// `batch_id` 分流。返回的 `requested` 是「删除前该批还剩多少道」——
  /// 确认弹窗里的 N 就用这个值（不要用 [ImportBatch.questionCount]，那是导入时的历史数量）。
  Future<BatchResult> deleteQuestionsByBatch(String batchId) async {
    final String id = batchId.trim();
    if (id.isEmpty) throw ApiException('batch_id 不能为空');
    final Object? raw = await _client.delete(
      '/questions/batch',
      body: <String, Object?>{'batch_id': id},
    );
    if (raw is! Map) throw ApiException('整批删除响应不是 JSON 对象', body: raw);
    return BatchResult.fromJson(raw.cast<String, Object?>());
  }

  /// ★ m31124：导入批次列表：`GET /import-batches`。
  ///
  /// user_id 由后端从 token 取（不传参，也不该传）。按 created_at DESC，最近的在前。
  Future<List<ImportBatch>> fetchImportBatches({int limit = 50}) async {
    final Object? raw = await _client.get(
      '/import-batches',
      query: <String, String>{'limit': '$limit'},
    );
    if (raw is! Map) throw ApiException('批次列表响应不是 JSON 对象', body: raw);
    final Object? items = raw.cast<String, Object?>()['items'];
    if (items is! List) return const <ImportBatch>[];
    return items
        .whereType<Map>()
        .map((Map m) => ImportBatch.fromJson(m.cast<String, Object?>()))
        .toList(growable: false);
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

  /// ★ A2③：批量改考点标签：`PATCH /questions/batch/tags`。
  ///
  /// body `{ids, tags, mode}`；[mode] 为 `replace`（整组覆盖）或 `add`（追加）。
  /// 后端只改自己的题 —— 公共题 / 别人的题静默跳过，计入 [BatchResult.skipped]。
  Future<BatchResult> updateQuestionTags(
    List<String> ids,
    List<String> tags, {
    String mode = 'replace',
  }) async {
    final Object? raw = await _client.patch(
      '/questions/batch/tags',
      body: <String, Object?>{
        'ids': ids,
        'tags': tags,
        'mode': mode,
      },
    );
    if (raw is! Map) throw ApiException('批量标签响应不是 JSON 对象', body: raw);
    return BatchResult.fromJson(raw.cast<String, Object?>());
  }

  /// 批量改归属：`PATCH /questions/batch`（m26090 批量重新分配）。
  ///
  /// [subjectId] 把选中的题移到目标科目；[knowledgeNodeId] 改考点；
  /// [clearKnowledgeNode] 为 true 时传 `knowledge_node_id: null` 清空考点
  /// （后端要求 subject_id / knowledge_node_id 至少给一个，否则 400 EMPTY_PATCH）。
  /// 只能改自己的题，公共题 / 别人的题静默跳过，计入 [BatchResult.skipped]。
  Future<BatchResult> updateQuestionsBatch(
    List<String> ids, {
    String? subjectId,
    String? knowledgeNodeId,
    bool clearKnowledgeNode = false,
  }) async {
    final Map<String, Object?> body = <String, Object?>{
      'ids': ids,
      if (subjectId != null && subjectId.isNotEmpty) 'subject_id': subjectId,
      if (clearKnowledgeNode)
        'knowledge_node_id': null
      else if (knowledgeNodeId != null && knowledgeNodeId.isNotEmpty)
        'knowledge_node_id': knowledgeNodeId,
    };
    final Object? raw = await _client.patch('/questions/batch', body: body);
    if (raw is! Map) throw ApiException('批量移动响应不是 JSON 对象', body: raw);
    return BatchResult.fromJson(raw.cast<String, Object?>());
  }

  /// ★ A2③：题型统计：`GET /question-types?scope=&q=`。
  ///
  /// [scope] 为 `imported`（只统计 source='import' 的题）或 `all`；
  /// [q] 是可选的题干关键词。后端按 count 倒序返回。
  Future<List<QuestionTypeCount>> fetchQuestionTypes({
    String scope = 'imported',
    String? q,
  }) async {
    final Object? raw = await _client.get(
      '/question-types',
      query: <String, String>{
        'scope': scope,
        if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
      },
    );
    if (raw is! Map) throw ApiException('题型统计响应不是 JSON 对象', body: raw);
    final Object? items = raw.cast<String, Object?>()['items'];
    if (items is! List) return const <QuestionTypeCount>[];
    return items
        .whereType<Map>()
        .map((Map m) => QuestionTypeCount.fromJson(m.cast<String, Object?>()))
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

/// 导入类端点（`/questions/import` 与 `/questions/import/preview`）的公共请求体。
///
/// 两个端点收的字段**完全一致**，抽成一处是为了防止两处漂移：
/// 以后新增字段（比如新的 `subject_mode` 取值）只改这里，两条路径同时生效。
Map<String, Object?> _importBody({
  required String filename,
  required String contentBase64,
  String? mime,
  String? subjectId,
  String? knowledgeNodeId,
  String subjectMode = 'uniform',
}) {
  return <String, Object?>{
    'filename': filename,
    'content_base64': contentBase64,
    if (mime != null && mime.isNotEmpty) 'mime': mime,
    if (subjectId != null && subjectId.isNotEmpty) 'subject_id': subjectId,
    if (knowledgeNodeId != null && knowledgeNodeId.isNotEmpty)
      'knowledge_node_id': knowledgeNodeId,
    if (subjectMode.isNotEmpty) 'subject_mode': subjectMode,
  };
}

/// base64 编码（导入端点只走 JSON + base64，不走 multipart）。
String encodeBase64(List<int> bytes) => base64Encode(bytes);
