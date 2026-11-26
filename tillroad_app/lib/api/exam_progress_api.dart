import 'api_client.dart';

/// 某个考试目标下的学习进度（首页卡片背面用）。
///
/// 口径由后端 `GET /exam-profiles/:id/progress` 定义，这里只做形状映射：
///   · minutes_used    —— 今天已学分钟数（模考用时 + 练习用时）
///   · minutes_progress —— 分钟数 / daily_minutes，落在 [0,1]；daily_minutes 为空时为 null
///   · questions_done  —— 今天完成的题数
///   · accuracy        —— 正确率 [0,1]；没有判分记录时为 null
class ExamProgress {
  const ExamProgress({
    required this.examProfileId,
    required this.minutesUsed,
    required this.questionsDone,
    required this.correct,
    required this.totalAnswered,
    this.dailyMinutes,
    this.minutesProgress,
    this.accuracy,
  });

  final String examProfileId;
  final int minutesUsed;
  final int questionsDone;
  final int correct;
  final int totalAnswered;
  final int? dailyMinutes;
  final double? minutesProgress;
  final double? accuracy;

  factory ExamProgress.fromJson(Map<String, Object?> json) {
    return ExamProgress(
      examProfileId: '${json['exam_profile_id'] ?? ''}',
      minutesUsed: _intOf(json['minutes_used']),
      questionsDone: _intOf(json['questions_done']),
      correct: _intOf(json['correct']),
      totalAnswered: _intOf(json['total_answered']),
      dailyMinutes: json['daily_minutes'] == null
          ? null
          : _intOf(json['daily_minutes']),
      minutesProgress: _doubleOf(json['minutes_progress']),
      accuracy: _doubleOf(json['accuracy']),
    );
  }
}

int _intOf(Object? value) {
  if (value is int) return value;
  if (value is double) return value.round();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

double? _doubleOf(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

/// 拉取考试进度的小 API 层。
class ExamProgressApi {
  ExamProgressApi({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  Future<ExamProgress> fetchProgress(String examProfileId) async {
    final Object? raw = await _client.get(
      '/exam-profiles/${Uri.encodeComponent(examProfileId)}/progress',
    );
    // 声明成 Map<String, dynamic>（而不是 Object?）：这样 cast 才存在，
    // 且 downcast 到 Map<String, Object?> 时运行期才可能失败（json 里 key 都是 string）。
    final Map<String, dynamic>? map = raw is Map<String, dynamic> ? raw : null;
    if (map == null) {
      throw ApiException('进度响应格式异常');
    }
    return ExamProgress.fromJson(map.cast<String, Object?>());
  }

  void close() => _client.close();
}
