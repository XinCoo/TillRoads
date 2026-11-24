// 考试配置 · 目标列表页。
//
// ── 这一页解决什么问题 ──────────────────────────────────────────────────
// 「考试配置」是整条备考链路的根：目标（exam_profiles）→ 科目（subjects）
// → 考点树（knowledge_nodes）。后端 BE-01 的四张表和端点早就有了，
// 但前端一直没有入口，用户建不了目标也就没法建科目/考点。
// 本页是这条链路的第一个落地点：列出「我建过的考试目标」，
// 右上角「新建」跳到创建页，点某一行进科目管理。
//
// ── 为什么倒计时要在前端算 ──────────────────────────────────────────────
// 后端只存 `exam_date`（date 列，JSON 里是 'YYYY-MM-DD' 字符串），
// 不存「还剩几天」——那是随当天变化的派生值，存下来必然过期。
// 这里两边都归零到当天 00:00 再相减，避免「今晚 23:00 与明早 01:00
// 只差 2 小时却跨了一天」这类按时间戳直接相减的错。
// 归零用 UTC 日历日（DateTime.utc(y, m, d)）：夏令时切换当天本地日长
// 不是 24 小时，用本地时间相减会出现 23/25 小时 -> inDays 截断成 0 天。
//
// ── 数据来源 ────────────────────────────────────────────────────────────
// `GET /users/{userId}/exam-profiles`，复用 `DefectApi.fetchExamProfiles`
// （内部已做 Map{items:[]} / 裸 List 的容错）。返回的是 `List<Map>`，
// 不是强类型模型 —— 字段按 map key 取，且每个值都可能是 null。

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
import '../api/defect_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart' show EmptyState, PressableCard;
import 'exam_profile_create_page.dart';
import 'subject_config_page.dart';

/// `schema.sql:46-48` 的 exam_type 枚举 → 中文标签。
///
/// 只用于「没有 target_label 时给个能读的兜底标题」，不做输入校验
/// （枚举合法性由后端 core/validators.mjs 的 validateExamType 判定）。
const Map<String, String> _kExamTypeLabels = <String, String>{
  'civil_service': '公务员',
  'postgrad': '考研',
  'final_exam': '期末',
  'vocational': '职业资格',
  'adult_self_study': '成人自考',
};

class ExamConfigPage extends StatefulWidget {
  const ExamConfigPage({super.key});

  @override
  State<ExamConfigPage> createState() => _ExamConfigPageState();
}

class _ExamConfigPageState extends State<ExamConfigPage> {
  final DefectApi _api = DefectApi();

  List<Map<String, Object?>> _profiles = const <Map<String, Object?>>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // DefectApi 内部持有一个 http.Client；不关会泄漏连接池。
    _api.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<Map<String, Object?>> list = await _api.fetchExamProfiles(
        kDemoUserId,
      );
      if (!mounted) return;
      setState(() {
        _profiles = list;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '考试目标加载失败：$e';
        _loading = false;
      });
    }
  }

  /// 新建页用 `push<bool>`：创建成功时它会 `pop(true)`，据此决定是否刷新。
  Future<void> _openCreate() async {
    final bool? changed = await Navigator.of(context).push<bool>(
      appRoute<bool>(context, const ExamProfileCreatePage()),
    );
    if (!mounted) return;
    if (changed == true) await _load();
  }

  Future<void> _openSubjects(String profileId, String label) async {
    await Navigator.of(context).push<void>(
      appRoute<void>(
        context,
        SubjectConfigPage(profileId: profileId, targetLabel: label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: const Text(
              '考试配置',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                color: AppColors.label,
              ),
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(36, 36),
              onPressed: _openCreate,
              child: const Text(
                '新建',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
          ),
          ..._buildBody(),
        ],
      ),
    );
  }

  List<Widget> _buildBody() {
    if (_loading) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CupertinoActivityIndicator(radius: 12)),
        ),
      ];
    }

    if (_error != null) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _ErrorView(message: _error!, onRetry: _load),
        ),
      ];
    }

    if (_profiles.isEmpty) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            title: '还没有考试目标',
            message: '点右上角「新建」创建第一个考试目标。',
            icon: CupertinoIcons.flag,
          ),
        ),
      ];
    }

    return <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        sliver: SliverList.separated(
          itemCount: _profiles.length,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 8),
          itemBuilder: (BuildContext context, int index) =>
              _buildRow(_profiles[index]),
        ),
      ),
    ];
  }

  Widget _buildRow(Map<String, Object?> profile) {
    final String id = '${profile['id'] ?? ''}'.trim();
    final String label = _labelOf(profile);
    final String? dateText = _dateText(profile['exam_date']);
    final ({String text, Color color})? countdown = _countdown(profile['exam_date']);

    return PressableCard(
      onTap: id.isEmpty ? null : () => _openSubjects(id, label),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: <Widget>[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: const Color(0x14007AFF),
                borderRadius: BorderRadius.circular(AppRadii.chip),
              ),
              child: const Icon(
                CupertinoIcons.flag,
                size: 18,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.label,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Text(
                        dateText ?? '未设置考试日期',
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 13,
                          color: AppColors.secondaryLabel,
                        ),
                      ),
                      if (countdown != null) ...<Widget>[
                        const SizedBox(width: 8),
                        Text(
                          '·',
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 13,
                            color: AppColors.tertiaryLabel,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          countdown.text,
                          style: TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: countdown.color,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const Icon(
              CupertinoIcons.chevron_forward,
              size: 16,
              color: AppColors.tertiaryLabel,
            ),
          ],
        ),
      ),
    );
  }

  /// 主标题：优先 `target_label`，没有就用考试类型的中文名兜底。
  String _labelOf(Map<String, Object?> profile) {
    final String label = '${profile['target_label'] ?? ''}'.trim();
    if (label.isNotEmpty) return label;
    final String type = '${profile['exam_type'] ?? ''}'.trim();
    return _kExamTypeLabels[type] ?? '未命名考试目标';
  }

  /// `exam_date` 后端是 date 列 → JSON 里固定是 'YYYY-MM-DD'（`server/db/pool.mjs`
  /// 对 date(1082) 原样返回字符串）。这里只做展示，不再二次格式化。
  String? _dateText(Object? raw) {
    final DateTime? date = _parseDate(raw);
    if (date == null) return null;
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  DateTime? _parseDate(Object? raw) {
    if (raw is DateTime) return raw;
    if (raw is! String) return null;
    final String s = raw.trim();
    if (s.length < 10) return null;
    final int? year = int.tryParse(s.substring(0, 4));
    final int? month = int.tryParse(s.substring(5, 7));
    final int? day = int.tryParse(s.substring(8, 10));
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }

  /// 倒计时：两边归零到当天 00:00 再相减（UTC 日历日，规避夏令时）。
  ({String text, Color color})? _countdown(Object? raw) {
    final DateTime? date = _parseDate(raw);
    if (date == null) return null;
    final DateTime now = DateTime.now();
    final DateTime today = DateTime.utc(now.year, now.month, now.day);
    final DateTime target = DateTime.utc(date.year, date.month, date.day);
    final int days = target.difference(today).inDays;
    if (days > 0) {
      return (
        text: '还剩 $days 天',
        color: days <= 7 ? AppColors.dueSoon : AppColors.normal,
      );
    }
    if (days == 0) {
      return (text: '就是今天', color: AppColors.dueSoon);
    }
    return (text: '已过 ${-days} 天', color: AppColors.overdue);
  }
}

/// 错误态：可重试。
///
/// `question_bank_page.dart` / `mock_page.dart` 里各有一份同名私有实现；
/// 私有类不能跨文件复用，而硬约束不允许新建共享 widget 文件，故此处再复制一份。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              CupertinoIcons.exclamationmark_triangle,
              size: 40,
              color: AppColors.dueSoon,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                color: AppColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton(
              onPressed: () {
                onRetry();
              },
              child: const Text(
                '重试',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
