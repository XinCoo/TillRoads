// 「我的模考」列表页（FE-05 任务 B 的第二半：把 FE-01 的空状态换成真实列表）。
//
// ── 为什么列表要按 exam_profile 拉，而不是按 user ─────────────────────────
// 后端只有 `GET /exam-profiles/:id/mock-exams`。用户可能有多个考试目标
// （省考 / 国考），而模考天然属于「某次备考」。因此先拉 profiles，
// 用第一个 active 的 profile 作为当前目标 —— 与首页倒计时用的是同一个目标，
// 避免「首页显示省考 46 天、模考列表却在看国考」这种前后不一致。
//
// ── 已交卷 / 未交卷为什么分开显示 ─────────────────────────────────────────
// `submitted=true` 才返回已交卷的。未交卷的卷子是「开了没交」的残留，
// 混在历史列表里会让「平均正确率」这类直觉判断失真，所以两张表分开：
// 顶部「进行中」放未交卷（可点击继续去报告页/交卷），下面才是历史。
//
// 注意：MVP 没有中断恢复（任务书硬约束），未交卷的卷子点进去只能提示
// 「该卷未交卷，请在设备上重新组卷」——因为作答只存在内存里，进程退出即丢。
import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/defect_api.dart';
import '../api/mock_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/defect_badges.dart';
import 'mock_create_page.dart';
import 'mock_report_page.dart';

class MockPage extends StatefulWidget {
  const MockPage({super.key});

  @override
  State<MockPage> createState() => _MockPageState();
}

class _MockPageState extends State<MockPage> {
  final DefectApi _defectApi = DefectApi();
  final MockExamApi _mockApi = MockExamApi();

  List<MockExam>? _submitted;
  String _profileLabel = '';
  List<MockExam> _pending = const <MockExam>[];
  ApiException? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _defectApi.close();
    _mockApi.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 1) 先确定当前考试目标（与首页一致的「第一个 active profile」）
      final List<Map<String, Object?>> profiles =
          await _defectApi.fetchExamProfiles(kDemoUserId);
      if (!mounted) return;
      if (profiles.isEmpty) {
        setState(() {
          _loading = false;
          _submitted = const <MockExam>[];
          _pending = const <MockExam>[];
        });
        return;
      }
      final Map<String, Object?> profile = profiles.first;
      final String profileId = '${profile['id']}';
      final String label = '${profile['target_label'] ?? '考试目标'}';

      // 2) 两路并发：已交卷（历史）与全部（用来挑未交卷的）
      final List<MockExamListPage> pages =
          await Future.wait(<Future<MockExamListPage>>[
        _mockApi.fetchMockExamsByProfile(profileId, submitted: true, limit: 20),
        _mockApi.fetchMockExamsByProfile(profileId, limit: 20),
      ]);
      if (!mounted) return;
      final List<MockExam> all = pages[1].items;
      setState(() {
        _profileLabel = label;
        _submitted = pages[0].items;
        _pending = all
            .where((MockExam e) => !e.isSubmitted)
            .toList(growable: false);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ApiException('加载模考记录时出现未知错误');
      });
    }
  }

  Future<void> _openCreate() async {
    final bool? created =
        await Navigator.of(context).push<bool>(appRoute<bool>(context, const MockCreatePage()));
    // 组卷成功后配置页用 replace 进答题页，答题页再 replace 进报告页，
    // 所以这里只在「用户从配置页直接返回」时收到 null；无论如何都刷新一次。
    if (!mounted) return;
    if (created == true || created == null) await _load();
  }

  Future<void> _openReport(MockExam exam) async {
    if (!exam.isSubmitted) {
      _toast('该卷还没有交卷。MVP 不做中断恢复，答题过程只存在上一次的设备内存里，'
          '请重新组卷作答。');
      return;
    }
    try {
      final MockReport report = await _mockApi.fetchMockExamReport(exam.id);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        appRoute<void>(
          context,
          MockReportPage(
            examId: exam.id,
            report: report,
            questions: const <MockQuestion>[],
            timedOut: false,
            elapsedMs: 0,
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(e.isNetworkError
          ? '无法连接后端，请确认服务已启动。'
          : '读取报告失败（HTTP ${e.statusCode}）');
    }
  }

  void _toast(String message) {
    showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            message,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 14,
              height: 1.45,
            ),
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '好',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
          ),
        ],
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
            largeTitle: const Text('模考'),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: _loading ? null : _openCreate,
              child: const Text(
                '开始模考',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                ),
              ),
            ),
            border: const Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          // 下拉刷新：_load 会重置 _loading，滚动区保持在原位
          CupertinoSliverRefreshControl(onRefresh: _load),
          ..._buildSlivers(),
        ],
      ),
    );
  }

  List<Widget> _buildSlivers() {
    if (_loading) {
      return const <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CupertinoActivityIndicator(radius: 12),
          ),
        ),
      ];
    }
    if (_error != null) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _ErrorView(error: _error!, onRetry: _load),
        ),
      ];
    }
    final List<MockExam> submitted = _submitted ?? const <MockExam>[];
    if (submitted.isEmpty && _pending.isEmpty) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: CupertinoIcons.timer,
            title: '还没有模考记录',
            message: '点右上角「开始模考」，选好范围与限时就能开一卷',
            actionLabel: '开始模考',
            onAction: _openCreate,
          ),
        ),
      ];
    }
    return <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            8,
            AppSpacing.page,
            0,
          ),
          child: SectionHeader(
            text: _profileLabel.isEmpty ? '模考记录' : _profileLabel,
            trailing: Text(
              '共 ${submitted.length} 次已交卷',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                color: AppColors.secondaryLabel,
              ),
            ),
          ),
        ),
      ),
      if (_pending.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              0,
              AppSpacing.page,
              AppSpacing.cardGap,
            ),
            child: CardShell(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '进行中',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.label,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '这些卷子开了但没交卷。MVP 不做中断恢复，作答只存在组卷时的设备内存里。',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11,
                      height: 1.45,
                      color: AppColors.secondaryLabel,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._pending.map((MockExam e) => Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _openReport(e),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  '${e.modeLabel} · ${e.plannedCount} 题 · '
                                  '${_formatDate(e.createdAt)}',
                                  style: const TextStyle(
                                    fontFamily: kFontFamily,
                                    fontSize: 13,
                                    color: AppColors.label,
                                  ),
                                ),
                              ),
                              const Text(
                                '未交卷',
                                style: TextStyle(
                                  fontFamily: kFontFamily,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.dueSoon,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )),
                ],
              ),
            ),
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          0,
          AppSpacing.page,
          24,
        ),
        sliver: SliverList.separated(
          itemCount: submitted.length,
          separatorBuilder: (BuildContext _, int _) =>
              const SizedBox(height: AppSpacing.cardGap),
          itemBuilder: (BuildContext context, int i) => _ExamCard(
            exam: submitted[i],
            onTap: () => _openReport(submitted[i]),
          ),
        ),
      ),
    ];
  }

  static String _formatDate(DateTime dt) {
    final String m = dt.month.toString().padLeft(2, '0');
    final String d = dt.day.toString().padLeft(2, '0');
    final String hh = dt.hour.toString().padLeft(2, '0');
    final String mm = dt.minute.toString().padLeft(2, '0');
    return '$m-$d $hh:$mm';
  }
}

/// 一条历史模考记录。
class _ExamCard extends StatelessWidget {
  const _ExamCard({required this.exam, required this.onTap});

  final MockExam exam;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 列表里 `report` 是完整的 report jsonb，所以能直接读出正确率，
    // 不需要再为每张卡单独请求 /report（那会变成 N+1 次往返）。
    final Map<String, Object?>? report = exam.report;
    final Map<String, Object?> overall = report?['overall'] is Map
        ? (report!['overall']! as Map).cast<String, Object?>()
        : const <String, Object?>{};
    final Object? accRaw = overall['accuracy'];
    final double? acc = accRaw is num ? accRaw.toDouble() : null;
    final int total = overall['total'] is num ? (overall['total']! as num).toInt() : 0;
    final int correct =
        overall['correct'] is num ? (overall['correct']! as num).toInt() : 0;
    final Color accColor = acc == null
        ? AppColors.tertiaryLabel
        : (acc < 0.5
            ? AppColors.overdue
            : (acc < 0.8 ? AppColors.dueSoon : AppColors.normal));

    return PressableCard(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        exam.modeLabel,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.label,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${exam.plannedCount} 题',
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 12,
                          color: AppColors.secondaryLabel,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_MockPageState._formatDate(exam.createdAt)}'
                    '${exam.durationLimitMs == null ? '' : ' · 限时 ${(exam.durationLimitMs! / 60000).round()} 分钟'}',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11,
                      color: AppColors.tertiaryLabel,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  acc == null ? '—' : '${(acc * 100).round()}%',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: accColor,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '答对 $correct/$total',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 11,
                    color: AppColors.secondaryLabel,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(width: 4),
            const Icon(
              CupertinoIcons.chevron_right,
              size: 16,
              color: AppColors.tertiaryLabel,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final ApiException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 36,
              color: AppColors.secondaryLabel,
            ),
            const SizedBox(height: 12),
            Text(
              error.isNetworkError
                  ? '无法连接后端\n请确认服务已启动后重试'
                  : '加载失败：${error.message}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                height: 1.5,
                color: AppColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              color: AppColors.card,
              borderRadius: BorderRadius.circular(AppRadii.chip + 4),
              onPressed: onRetry,
              child: const Text(
                '重试',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
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
