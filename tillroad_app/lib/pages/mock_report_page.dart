// 模考报告页（FE-05 任务 D）。
//
// 职责：把 `POST /mock-exams/:id/submit` 返回的 `report` 渲染成四块卡
// （总分 / 模块正确率 / 用时 / 稳定性与重复率）+ V3 候选引导。
//
// ── 为什么这些数字不能「美化」────────────────────────────────────────────
// 本页是这套 App 的信任基石：用户要靠它判断自己到底哪块不行。
// 所以三条底线：
//   1) `overall.total` 只计**已判分**的题（主观题不进分母），界面上另起一行
//      显示 `未判分 N 题`，绝不把主观题算成错题；
//   2) 后端 `stability` 为 null 时显示「首次模考，暂无稳定性数据」，
//      不显示 0（0 会被读成「极其稳定」，与事实相反）；
//   3) `module_accuracy[*].title` 当前恒为 null（后端键名 bug，见 mock_api.dart
//      文件头差异 3），此时显示 `考点 xxxxxxxx` 短码，**不伪造中文考点名**。
//
// ── 不渲染的部分 ──────────────────────────────────────────────────────────
// `strategy_execution` 后端恒为 null（MVP 没有跳题记录，硬算就是伪指标），
// 本页据此完全不出现该卡片 —— 而不是画一个空框说「暂无数据」。
//
// ── V3 候选引导 ───────────────────────────────────────────────────────────
// `v3_candidates` 是「本次错题命中了处于 V3 的缺陷单」。点击去提交验证时，
// 必须先 `fetchDefectDetail(defect_ticket_id)` 拿到完整 DefectTicket，
// 因为 `DefectVerifyPage` 的构造要求真实工单（要读 version 与当前 status）。
// V3 阶段的白名单只有 `timed_mock` 一种验证方式（core/index.mjs 的
// STAGE_WINDOWS.V3.types），所以这里不做选择，直接进 V3 表单。
import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/defect_api.dart';
import '../api/mock_api.dart';
import '../theme/app_theme.dart';
import '../widgets/defect_badges.dart';
import '../mock/defects_mock.dart';
import 'defect_verify_page.dart';

/// 卡片内的小标题。
///
/// 刻意不用 `SectionHeader`：那是分组列表外的标题（带 4px 外缩进
/// 与 13pt 灰字），而这里是卡片**内部**的一级标签，需要 15pt 主色，
/// 两者视觉层级不同，混用会让报告页的四个卡片看起来像四个分组。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: kFontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppColors.label,
      ),
    );
  }
}

class MockReportPage extends StatefulWidget {
  const MockReportPage({
    super.key,
    required this.examId,
    required this.report,
    required this.questions,
    required this.timedOut,
    required this.elapsedMs,
  });

  final String examId;
  final MockReport report;

  /// 本次卷子的题目（用来把 V3 候选的 question_id 映射成可读短码）。
  final List<MockQuestion> questions;

  /// 是否超时交卷（后端 `timed_out` 或本地自动交卷）。
  final bool timedOut;

  /// 后端换算的作答耗时（毫秒）；本地自动交卷路径可能为 0。
  final int elapsedMs;

  @override
  State<MockReportPage> createState() => _MockReportPageState();
}

class _MockReportPageState extends State<MockReportPage> {
  final DefectApi _defectApi = DefectApi();
  String? _openingId;

  @override
  void dispose() {
    _defectApi.close();
    super.dispose();
  }

  MockReport get _report => widget.report;

  /// 把 `question_id` 短码换成本卷第几题，用户才认得出是哪道题。
  String _questionLabel(String questionId) {
    final int i = widget.questions
        .indexWhere((MockQuestion q) => q.questionId == questionId);
    if (i >= 0) return '第 ${i + 1} 题';
    return '题目 ${questionId.length >= 8 ? questionId.substring(0, 8) : questionId}';
  }

  Future<void> _openV3(V3Candidate candidate) async {
    if (_openingId != null) return;
    setState(() => _openingId = candidate.defectTicketId);
    try {
      final DefectTicket ticket =
          await _defectApi.fetchDefectDetail(candidate.defectTicketId);
      if (!mounted) return;
      setState(() => _openingId = null);
      // DefectVerifyPage 提交成功后 pop(true)；本页只是引导，不需要刷新报告。
      await Navigator.of(context).push<bool>(
        appRoute<bool>(context, DefectVerifyPage(ticket: ticket)),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _openingId = null);
      _toast(e.isNetworkError
          ? '无法连接后端，请确认服务已启动。'
          : '打开验证页失败（HTTP ${e.statusCode}）');
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
              height: 1.4,
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
      navigationBar: CupertinoNavigationBar(
        middle: const Text(
          '模考报告',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        // 刻意用**不透明**背景（不加 alpha）：CupertinoPageScaffold 只有在
        // navigationBar.shouldFullyObstruct == true（即 alpha == 0xFF）时才会替
        // child 预留导航栏高度；半透明时它只改 MediaQuery.padding.top 而不再内边距，
        // 若 child 又写了 SafeArea(top: false)，首屏内容就会被导航栏盖住（实测过）。
        backgroundColor: AppColors.groupedBackground,
        border: const Border(
          bottom: BorderSide(color: AppColors.separator, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            12,
            AppSpacing.page,
            32,
          ),
          children: <Widget>[
            _ScoreCard(
              report: _report,
              timedOut: widget.timedOut,
              elapsedMs: widget.elapsedMs,
            ),
            const SizedBox(height: AppSpacing.cardGap),
            _ModuleAccuracyCard(modules: _report.moduleAccuracy),
            const SizedBox(height: AppSpacing.cardGap),
            _DurationCard(report: _report),
            const SizedBox(height: AppSpacing.cardGap),
            _StabilityCard(report: _report),
            if (_report.v3Candidates.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.cardGap),
              _V3Card(
                candidates: _report.v3Candidates,
                questionLabel: _questionLabel,
                openingId: _openingId,
                onTap: _openV3,
              ),
            ],
            const SizedBox(height: AppSpacing.cardGap),
            _FooterNote(unanswered: _report.overall.ungraded),
            const SizedBox(height: 8),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 12),
              color: AppColors.card,
              borderRadius: BorderRadius.circular(AppRadii.chip + 4),
              onPressed: () =>
                  Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst),
              child: const Text(
                '返回首页',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 16,
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

/// D1：总分卡（正确率 + 对/错 + 超时标记 + 用时）。
class _ScoreCard extends StatelessWidget {
  const _ScoreCard({
    required this.report,
    required this.timedOut,
    required this.elapsedMs,
  });

  final MockReport report;
  final bool timedOut;
  final int elapsedMs;

  @override
  Widget build(BuildContext context) {
    final MockOverall o = report.overall;
    final int usedMs = elapsedMs > 0 ? elapsedMs : (report.overallDurationMs ?? 0);
    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text(
                '本次正确率',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 14,
                  color: AppColors.secondaryLabel,
                ),
              ),
              const Spacer(),
              if (timedOut) const _SoftBadge(text: '超时交卷', color: AppColors.dueSoon),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                o.accuracyPercent,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 42,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  color: AppColors.label,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '答对 ${o.correct} / ${o.total}',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 14,
                  color: AppColors.secondaryLabel,
                ),
              ),
            ],
          ),
          if (o.ungraded > 0) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '另有 ${o.ungraded} 题未判分（主观题不进正确率分母）',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                height: 1.4,
                color: AppColors.secondaryLabel,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              _MiniStat(
                label: '用时',
                value: _formatDuration(usedMs),
              ),
              const SizedBox(width: 20),
              _MiniStat(
                label: '未判分',
                value: '${report.ungradedCount} 题',
              ),
              const SizedBox(width: 20),
              _MiniStat(
                label: '错题数',
                value: '${report.defectRepeatRate.totalWrong} 题',
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatDuration(int ms) {
    if (ms <= 0) return '—';
    final int totalSeconds = (ms / 1000).round();
    final int m = totalSeconds ~/ 60;
    final int s = totalSeconds % 60;
    if (m == 0) return '$s 秒';
    return s == 0 ? '$m 分钟' : '$m 分 $s 秒';
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11,
            color: AppColors.tertiaryLabel,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
            fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// D2-a：模块正确率（横条图，纯 Widget 手绘，不引图表库）。
class _ModuleAccuracyCard extends StatelessWidget {
  const _ModuleAccuracyCard({required this.modules});

  final List<MockModuleAccuracy> modules;

  @override
  Widget build(BuildContext context) {
    // 按题量降序：题多的考点更值得看，也比按 id 排更稳定（id 是 uuid）。
    final List<MockModuleAccuracy> sorted = List<MockModuleAccuracy>.of(modules)
      ..sort((MockModuleAccuracy a, MockModuleAccuracy b) =>
          b.total.compareTo(a.total));
    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _SectionLabel(text: '模块正确率'),
          const SizedBox(height: 4),
          if (sorted.isEmpty)
            const _EmptyLine(text: '本卷没有可归组的题目')
          else
            ...sorted.map((MockModuleAccuracy m) => _AccuracyRow(module: m)),
        ],
      ),
    );
  }
}

class _AccuracyRow extends StatelessWidget {
  const _AccuracyRow({required this.module});

  final MockModuleAccuracy module;

  @override
  Widget build(BuildContext context) {
    final double? acc = module.accuracy;
    final double ratio = (acc ?? 0).clamp(0.0, 1.0);
    final String pct = acc == null ? '未判分' : '${(acc * 100).round()}%';
    // 三档配色：低于 50% 红、50–80% 橙、80% 以上绿。阈值刻意与
    // 后端「错题转缺陷单」的习惯口径一致，避免同一条数据两种解读。
    final Color barColor = acc == null
        ? AppColors.tertiaryLabel
        : (acc < 0.5
            ? AppColors.overdue
            : (acc < 0.8 ? AppColors.dueSoon : AppColors.normal));
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  module.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 15,
                    color: AppColors.label,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${module.correct}/${module.total}',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  color: AppColors.secondaryLabel,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 42,
                child: Text(
                  pct,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: barColor,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Stack(
                children: <Widget>[
                  Container(color: AppColors.groupedBackground),
                  FractionallySizedBox(
                    widthFactor: ratio == 0 ? 0.02 : ratio,
                    child: Container(color: barColor),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// D2-b：平均用时（整体 + 分考点）。
class _DurationCard extends StatelessWidget {
  const _DurationCard({required this.report});

  final MockReport report;

  @override
  Widget build(BuildContext context) {
    final int? overall = report.overallDurationMs;
    final List<MockDurationNode> nodes = List<MockDurationNode>.of(
      report.durationByNode,
    )..sort((MockDurationNode a, MockDurationNode b) =>
        (b.avgDurationMs ?? 0).compareTo(a.avgDurationMs ?? 0));
    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _SectionLabel(text: '平均用时'),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Text(
                overall == null ? '—' : _formatSeconds(overall),
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: AppColors.label,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '整卷平均每题',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  color: AppColors.secondaryLabel,
                ),
              ),
            ],
          ),
          if (nodes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            // 0.5px 分割线用 Container 画：纯 Cupertino 工程没有 Material 的 Divider
            Container(height: 0.5, color: AppColors.separator),
            ...nodes.take(6).map((MockDurationNode n) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          n.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 14,
                            color: AppColors.label,
                          ),
                        ),
                      ),
                      Text(
                        '${n.count} 题',
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 11,
                          color: AppColors.tertiaryLabel,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        n.avgDurationMs == null
                            ? '—'
                            : _formatSeconds(n.avgDurationMs!),
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.label,
                          fontFeatures: <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ],
      ),
    );
  }

  static String _formatSeconds(int ms) {
    final int totalSeconds = (ms / 1000).round();
    if (totalSeconds < 60) return '$totalSeconds 秒';
    final int m = totalSeconds ~/ 60;
    final int s = totalSeconds % 60;
    return s == 0 ? '$m 分' : '$m 分 $s 秒';
  }
}

/// D2-c：稳定性 + 缺陷重复率（两张小卡并排）。
class _StabilityCard extends StatelessWidget {
  const _StabilityCard({required this.report});

  final MockReport report;

  @override
  Widget build(BuildContext context) {
    final double? stability = report.stability;
    final MockDefectRepeatRate rep = report.defectRepeatRate;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: CardShell(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const _SectionLabel(text: '稳定性'),
                const SizedBox(height: 8),
                if (stability == null)
                  const Text(
                    '首次模考，暂无稳定性数据',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 13,
                      height: 1.45,
                      color: AppColors.secondaryLabel,
                    ),
                  )
                else ...<Widget>[
                  Text(
                    stability.toStringAsFixed(2),
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: AppColors.label,
                      fontFeatures: <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 变异系数越小越稳；0.15 与 0.30 是本项目沿用的经验阈值
                  Text(
                    stability <= 0.15
                        ? '波动很小（变异系数）'
                        : (stability <= 0.30 ? '波动正常（变异系数）' : '波动偏大（变异系数）'),
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11,
                      height: 1.4,
                      color: AppColors.secondaryLabel,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.cardGap),
        Expanded(
          child: CardShell(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const _SectionLabel(text: '缺陷重复率'),
                const SizedBox(height: 8),
                Text(
                  '${(rep.rate * 100).round()}%',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: AppColors.label,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${rep.repeatCount} / ${rep.totalWrong} 道错题命中未闭环缺陷',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 11,
                    height: 1.4,
                    color: AppColors.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// D3：V3 候选（本次错题命中处于 V3 的缺陷单）。
class _V3Card extends StatelessWidget {
  const _V3Card({
    required this.candidates,
    required this.questionLabel,
    required this.openingId,
    required this.onTap,
  });

  final List<V3Candidate> candidates;
  final String Function(String) questionLabel;
  final String? openingId;
  final ValueChanged<V3Candidate> onTap;

  @override
  Widget build(BuildContext context) {
    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const _SectionLabel(text: 'V3 验证建议'),
              const Spacer(),
              _SoftBadge(
                text: '${candidates.length} 条',
                color: AppColors.accent,
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '这些错题对应的缺陷单已在 V3 阶段，建议用一次限时模考做最终验证。',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              height: 1.45,
              color: AppColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 10),
          ...candidates.take(5).map((V3Candidate c) {
            final bool busy = openingId == c.defectTicketId;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: busy ? null : () => onTap(c),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(AppRadii.chip + 4),
                    border: Border.all(
                      color: AppColors.accent.withValues(alpha: 0.25),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              questionLabel(c.questionId),
                              style: const TextStyle(
                                fontFamily: kFontFamily,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.label,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '考点 ${c.knowledgeNodeShort}',
                              style: const TextStyle(
                                fontFamily: kFontFamily,
                                fontSize: 11,
                                color: AppColors.secondaryLabel,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (busy)
                        const CupertinoActivityIndicator(radius: 8)
                      else
                        const Row(
                          children: <Widget>[
                            Text(
                              '去提交 V3 验证',
                              style: TextStyle(
                                fontFamily: kFontFamily,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.accent,
                              ),
                            ),
                            SizedBox(width: 2),
                            Icon(
                              CupertinoIcons.chevron_right,
                              size: 14,
                              color: AppColors.accent,
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
          if (candidates.length > 5)
            Text(
              '另有 ${candidates.length - 5} 条同类候选，未在此列出。',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                color: AppColors.tertiaryLabel,
              ),
            ),
        ],
      ),
    );
  }
}

/// D4：底部说明（为什么不能看解析）。
class _FooterNote extends StatelessWidget {
  const _FooterNote({required this.unanswered});

  final int unanswered;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        unanswered > 0
            ? '未作答的题按答错计；报告不含标准答案与解析，'
                '错题请到缺陷单页建单归因再进入验证。'
            : '报告不含标准答案与解析，错题请到缺陷单页建单归因再进入验证。',
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          height: 1.5,
          color: AppColors.tertiaryLabel,
        ),
      ),
    );
  }
}

class _SoftBadge extends StatelessWidget {
  const _SoftBadge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.chip),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
          height: 1.3,
        ),
      ),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 13,
          color: AppColors.secondaryLabel,
        ),
      ),
    );
  }
}
