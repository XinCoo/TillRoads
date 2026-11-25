// 练习模式 API（练习 R1）。
//
// 职责：把后端四个练习端点映射成界面模型 ——
//   · GET  /questions/practice?subject_id=&knowledge_node_id=&count=&source=  抽题
//   · POST /practice-sessions                                            提交一次练习
//   · GET  /practice-sessions?limit=&offset=                              练习历史
//   · GET  /practice-sessions/:id                                        单次详情
//
// ── 三条与后端契约对齐的要点 ───────────────────────────────────────────────
// 1) **归属只认 token**：请求体里没有 user_id，前端也不该传（传了也会被
//    server/index.mjs 改写成 token 用户）。归属隔离在服务端做。
// 2) **公共题没有答案**：后端在仓储层就把公共题（owner_user_id IS NULL）的
//    answer 置 null，所以前端拿到的 `answer == null` 时必须显示「请自评」，
//    不能当成「这题没答案」。
// 3) **统计口径在服务端**：correct/wrong/accuracy 由服务端按作答明细算，
//    客户端传什么都改不了。前端本地判分只用于「让用户立刻看到结果」。
import 'api_client.dart';

/// 抽题来源。
enum PracticeSource {
  /// 只抽自己的题（有标准答案，可自动判分）。
  mine('mine', '我导入的'),

  /// 只抽公共题（没有标准答案，要自评）。
  public('public', '公共题'),

  /// 公共题 + 自己的题。
  all('all', '全部');

  const PracticeSource(this.wire, this.label);

  final String wire;
  final String label;

  static PracticeSource fromWire(String? value) {
    for (final PracticeSource s in PracticeSource.values) {
      if (s.wire == value) return s;
    }
    return PracticeSource.all;
  }
}

/// 练习里的一道题。
///
/// 与 `BankQuestion` 的区别：**带 answer**（自己的题才有），
/// 并且多一个 `hasAnswer` 告诉前端「能不能自动判分」。
class PracticeQuestion {
  const PracticeQuestion({
    required this.id,
    required this.stem,
    required this.type,
    this.subjectId,
    this.knowledgeNodeId,
    this.options = const <PracticeOption>[],
    this.answer,
    this.analysis,
    this.difficulty,
    this.isSubjective = false,
    this.isMine = false,
    this.hasAnswer = false,
  });

  final String id;
  final String stem;
  final String type;
  final String? subjectId;
  final String? knowledgeNodeId;
  final List<PracticeOption> options;

  /// 标准答案（自己的题才有；公共题恒为 null）。
  final String? answer;
  final String? analysis;
  final String? difficulty;
  final bool isSubjective;

  /// 是否是自己的题。
  final bool isMine;

  /// 是否有标准答案 → false 时前端要「请自评」。
  final bool hasAnswer;

  /// 题型标签（跟题库页保持同一套说法）。
  String get typeLabel {
    switch (type) {
      case 'choice':
        return '选择题';
      case 'multi':
        return '多选题';
      case 'judge':
        return '判断题';
      case 'fill':
        return '填空题';
      case 'calculation':
        return '计算题';
      case 'short_answer':
        return '简答题';
      case 'subjective':
        return '主观题';
      case 'essay':
        return '论述题';
      case 'material':
        return '材料题';
      default:
        return type;
    }
  }

  /// 是不是多选（多选判分要按集合比，不能按字符串比）。
  bool get isMulti => type == 'multi';

  /// 主观题没有选项，只能自评。
  bool get isObjective =>
      !isSubjective &&
      type != 'short_answer' &&
      type != 'subjective' &&
      type != 'essay' &&
      type != 'material';

  static PracticeQuestion fromJson(Map<String, Object?> json) {
    final Object? rawOptions = json['options'];
    final List<PracticeOption> options = <PracticeOption>[];
    if (rawOptions is List) {
      int index = 0;
      for (final Object? item in rawOptions) {
        final String fallbackKey = String.fromCharCode(65 + index);
        index++;
        if (item is String) {
          final String text = item.trim();
          if (text.isEmpty) continue;
          final RegExpMatch? m = RegExp(
            r'^([A-Za-z])\s*[.、．:：)]?\s*(.*)$',
          ).firstMatch(text);
          options.add(
            PracticeOption(
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
          options.add(
            PracticeOption(
              key: key.isEmpty ? fallbackKey : key.toUpperCase(),
              text: text,
            ),
          );
        }
      }
    }
    return PracticeQuestion(
      id: _str(json['id']),
      stem: _str(json['stem']),
      type: _str(json['type']),
      subjectId: _strOrNull(json['subject_id']),
      knowledgeNodeId: _strOrNull(json['knowledge_node_id']),
      options: options,
      answer: _strOrNull(json['answer']),
      analysis: _strOrNull(json['analysis']),
      difficulty: _strOrNull(json['difficulty']),
      isSubjective: json['is_subjective'] == true,
      isMine: json['is_mine'] == true,
      hasAnswer: json['has_answer'] == true,
    );
  }
}

/// 选项。
class PracticeOption {
  const PracticeOption({required this.key, required this.text});

  final String key;
  final String text;
}

/// 一次抽题的结果。
class PracticePick {
  const PracticePick({
    required this.items,
    required this.requested,
    required this.available,
    required this.source,
  });

  final List<PracticeQuestion> items;

  /// 用户要的题量。
  final int requested;

  /// 该范围实际有多少题（题量不足时 < requested）。
  final int available;
  final PracticeSource source;

  /// 题量不够（要的比有的多）。
  bool get insufficient => items.length < requested;
}

/// 提交一次练习后的服务端统计。
class PracticeSubmitResult {
  const PracticeSubmitResult({
    required this.sessionId,
    required this.total,
    required this.correct,
    required this.wrong,
    required this.unjudged,
    required this.accuracy,
    this.createdAt,
  });

  final String sessionId;
  final int total;
  final int correct;
  final int wrong;

  /// 没有标准答案、用户还没自评的题数。
  final int unjudged;

  /// 正确率（百分比，一位小数）。
  final double accuracy;
  final DateTime? createdAt;
}

/// 练习历史里的一条。
class PracticeSessionSummary {
  const PracticeSessionSummary({
    required this.id,
    required this.total,
    required this.correct,
    required this.wrong,
    required this.accuracy,
    this.subjectId,
    this.knowledgeNodeId,
    this.source,
    this.createdAt,
  });

  final String id;
  final String? subjectId;
  final String? knowledgeNodeId;
  final String? source;
  final int total;
  final int correct;
  final int wrong;
  final double accuracy;
  final DateTime? createdAt;
}

/// 一次练习里的单题作答（详情口径）。
class PracticeAnswerRecord {
  const PracticeAnswerRecord({
    required this.questionId,
    required this.stem,
    required this.type,
    this.userAnswer,
    this.correctAnswer,
    this.analysis,
    this.isCorrect,
    this.durationMs,
    this.options = const <PracticeOption>[],
    this.isMine = false,
  });

  final String questionId;
  final String stem;
  final String type;

  /// 用户选了什么（没作答时为 null）。
  final String? userAnswer;

  /// 标准答案（公共题为 null）。
  final String? correctAnswer;
  final String? analysis;

  /// 对错；null = 没判定（公共题未自评）。
  final bool? isCorrect;
  final int? durationMs;
  final List<PracticeOption> options;

  /// 是否是自己的题。
  final bool isMine;

  bool get isWrong => isCorrect == false;
}

/// 一次练习的详情。
class PracticeSessionDetail {
  const PracticeSessionDetail({
    required this.session,
    required this.answers,
  });

  final PracticeSessionSummary session;
  final List<PracticeAnswerRecord> answers;

  List<PracticeAnswerRecord> get wrongAnswers => answers
      .where((PracticeAnswerRecord a) => a.isCorrect == false)
      .toList(growable: false);

  List<PracticeAnswerRecord> get rightAnswers => answers
      .where((PracticeAnswerRecord a) => a.isCorrect == true)
      .toList(growable: false);

  List<PracticeAnswerRecord> get unjudgedAnswers => answers
      .where((PracticeAnswerRecord a) => a.isCorrect == null)
      .toList(growable: false);
}

/// 一次练习里的单题作答（客户端本地口径）。
///
/// 与服务端返回的 `PracticeAnswerRecord` 结构对齐，但字段更少 ——
/// 提交后立刻就能显示结果，不必再等一次网络往返。
class PracticeLocalAnswer {
  const PracticeLocalAnswer({
    required this.questionId,
    this.userAnswer,
    this.correctAnswer,
    this.isCorrect,
    this.hasAnswer = false,
  });

  final String questionId;

  /// 用户选了什么（没作答为 null）。
  final String? userAnswer;

  /// 标准答案（公共题为 null）。
  final String? correctAnswer;

  /// 对错；null = 未判定。
  final bool? isCorrect;

  /// 是否有标准答案（false = 公共题，只能自评）。
  final bool hasAnswer;

  bool get isWrong => isCorrect == false;
}

/// 提交一次练习时的单题作答。
class PracticeAnswerInput {
  const PracticeAnswerInput({
    required this.questionId,
    this.userAnswer,
    this.isCorrect,
    this.durationMs,
  });

  final String questionId;
  final String? userAnswer;

  /// null = 没判定（跳过 / 公共题没自评）。
  final bool? isCorrect;
  final int? durationMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'question_id': questionId,
    'user_answer': userAnswer,
    'is_correct': isCorrect,
    'duration_ms': durationMs,
  };
}

class PracticeApi {
  PracticeApi({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  void close() => _client.close();

  /// 抽题。题量不足时**不报错**，返回的 `items` 会短于 `requested`，
  /// 同时 `available` 告诉前端实际有多少 —— 前端据此问用户「按 N 道开始？」。
  Future<PracticePick> pickQuestions({
    String? subjectId,
    String? knowledgeNodeId,
    PracticeSource source = PracticeSource.all,
    int count = 10,
  }) async {
    final Map<String, String> query = <String, String>{
      'source': source.wire,
      'count': '$count',
      if (subjectId != null && subjectId.isNotEmpty) 'subject_id': subjectId,
      if (knowledgeNodeId != null && knowledgeNodeId.isNotEmpty)
        'knowledge_node_id': knowledgeNodeId,
    };
    final Object? raw = await _client.get('/questions/practice', query: query);
    final Map<String, Object?> map = _asMap(raw);
    final List<Object?> rawItems =
        map['items'] is List ? map['items']! as List<Object?> : const <Object?>[];
    return PracticePick(
      items: rawItems
          .whereType<Map>()
          .map((Map<Object?, Object?> m) => PracticeQuestion.fromJson(m.cast<String, Object?>()))
          .toList(growable: false),
      requested: _int(map['requested'], count),
      available: _int(map['available'], rawItems.length),
      source: PracticeSource.fromWire(_strOrNull(map['source'])),
    );
  }

  /// 提交一次练习。
  Future<PracticeSubmitResult> submitSession({
    required List<PracticeAnswerInput> answers,
    String? subjectId,
    String? knowledgeNodeId,
    PracticeSource source = PracticeSource.all,
  }) async {
    final Map<String, Object?> body = <String, Object?>{
      'source': source.wire,
      'answers': answers.map((PracticeAnswerInput a) => a.toJson()).toList(),
      if (subjectId != null && subjectId.isNotEmpty) 'subject_id': subjectId,
      if (knowledgeNodeId != null && knowledgeNodeId.isNotEmpty)
        'knowledge_node_id': knowledgeNodeId,
    };
    final Object? raw = await _client.post('/practice-sessions', body: body);
    final Map<String, Object?> map = _asMap(raw);
    return PracticeSubmitResult(
      sessionId: _str(map['session_id']),
      total: _int(map['total'], answers.length),
      correct: _int(map['correct'], 0),
      wrong: _int(map['wrong'], 0),
      unjudged: _int(map['unjudged'], 0),
      accuracy: _double(map['accuracy'], 0),
      createdAt: _dateOrNull(map['created_at']),
    );
  }

  /// 练习历史（只返回自己的会话）。
  Future<List<PracticeSessionSummary>> listSessions({int limit = 20, int offset = 0}) async {
    final Object? raw = await _client.get(
      '/practice-sessions',
      query: <String, String>{'limit': '$limit', 'offset': '$offset'},
    );
    final Map<String, Object?> map = _asMap(raw);
    final List<Object?> items =
        map['items'] is List ? map['items']! as List<Object?> : const <Object?>[];
    return items
        .whereType<Map>()
        .map((Map<Object?, Object?> m) => _summaryFromJson(m.cast<String, Object?>()))
        .toList(growable: false);
  }

  /// 单次详情（含每题题干与对错）。别人的会话 → 404。
  Future<PracticeSessionDetail> fetchSession(String id) async {
    final Object? raw = await _client.get('/practice-sessions/$id');
    final Map<String, Object?> map = _asMap(raw);
    final Map<String, Object?> session = _asMap(map['session']);
    final List<Object?> rawAnswers =
        map['answers'] is List ? map['answers']! as List<Object?> : const <Object?>[];
    return PracticeSessionDetail(
      session: _summaryFromJson(session),
      answers: rawAnswers
          .whereType<Map>()
          .map((Map<Object?, Object?> m) => _answerFromJson(m.cast<String, Object?>()))
          .toList(growable: false),
    );
  }

  PracticeSessionSummary _summaryFromJson(Map<String, Object?> json) {
    final int total = _int(json['total'], 0);
    final int correct = _int(json['correct'], 0);
    return PracticeSessionSummary(
      id: _str(json['id']),
      subjectId: _strOrNull(json['subject_id']),
      knowledgeNodeId: _strOrNull(json['knowledge_node_id']),
      source: _strOrNull(json['source']),
      total: total,
      correct: correct,
      wrong: _int(json['wrong'], 0),
      accuracy: _double(
        json['accuracy'],
        total > 0 ? correct / total * 100 : 0,
      ),
      createdAt: _dateOrNull(json['created_at']),
    );
  }

  PracticeAnswerRecord _answerFromJson(Map<String, Object?> json) {
    final Object? rawOptions = json['options'];
    final List<PracticeOption> options = <PracticeOption>[];
    if (rawOptions is List) {
      int index = 0;
      for (final Object? item in rawOptions) {
        final String fallbackKey = String.fromCharCode(65 + index);
        index++;
        if (item is String) {
          final String text = item.trim();
          if (text.isEmpty) continue;
          final RegExpMatch? m = RegExp(
            r'^([A-Za-z])\s*[.、．:：)]?\s*(.*)$',
          ).firstMatch(text);
          options.add(
            PracticeOption(
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
          options.add(
            PracticeOption(
              key: key.isEmpty ? fallbackKey : key.toUpperCase(),
              text: text,
            ),
          );
        }
      }
    }
    return PracticeAnswerRecord(
      questionId: _str(json['question_id']),
      stem: _str(json['stem']),
      type: _str(json['type']),
      userAnswer: _strOrNull(json['user_answer']),
      correctAnswer: _strOrNull(json['correct_answer']),
      analysis: _strOrNull(json['analysis']),
      isCorrect: json['is_correct'] == true
          ? true
          : json['is_correct'] == false
          ? false
          : null,
      durationMs: json['duration_ms'] is num
          ? (json['duration_ms']! as num).toInt()
          : null,
      options: options,
      isMine: json['is_mine'] == true,
    );
  }
}

// ── 映射辅助 ────────────────────────────────────────────────────────────────

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

double _double(Object? v, double fallback) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

DateTime? _dateOrNull(Object? v) {
  final String s = _str(v).trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s)?.toLocal();
}

Map<String, Object?> _asMap(Object? v) {
  if (v is Map) return v.cast<String, Object?>();
  return const <String, Object?>{};
}
