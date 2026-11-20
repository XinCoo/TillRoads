// 复盘详情页（FE-06 任务 D）。
//
// 六块 metrics 卡片 + 底部固定操作区。数据来自列表页传入的 `ReviewCycle`
// 快照；这一页**不重新计算任何指标**，只负责把后端给的 JSON 画出来
// （口径细节见 review_api.dart 里 ReviewMetrics 各字段的注释）。
//
// ── 三个刻意的展示决策 ────────────────────────────────────────────────
// 1) 「未关闭缺陷」是**时点量**、「错因层级分布」是**周期内增量**，两者合计
//    不相等是正常的。所以两块卡的副标题里各写了一句口径，避免用户把
//    「8 条未关闭」与「3 条层级分布」当成同一件事的对不上账。
// 2) 验证通过率 `total == 0` 时显示「本周期没有提交验证」而不是「0%」——
//    「没做验证」和「验证全错」在复盘里是完全相反的行动指引。
// 3) 稳定性 null → 「本周期无模考」。不填 0，也不隐藏整张卡：卡片消失会让
//    用户以为页面缺了一块。
//
// ── 底部操作区 ────────────────────────────────────────────────────────
// 未读 → 「标记已读」（PATCH completed=true，必经乐观锁 version）
// 已读 → 绿色「已完成」+ 次要按钮「删除复盘」（DELETE 带 version，弹确认）
// 删完 pop 回列表，由列表静默刷新（因此这里不做本地列表维护）。
import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/review_api.dart';
import '../mock/defects_mock.dart';
import '../theme/app_theme.dart';
import '../widgets/defect_badges.dart';

class ReviewDetailPage extends StatefulWidget {
  const ReviewDetailPage({super.key, required this.cycle});

  final ReviewCycle cycle;

  @override
  State<ReviewDetailPage> createState() => _ReviewDetailPageState();
}

class _ReviewDetailPageState extends State<ReviewDetailPage> {
  final ReviewApi _api = ReviewApi();

  late ReviewCycle _cycle = widget.cycle;

  /// 任一操作（标记已读 / 删除）在飞时锁住底部按钮，避免重复提交。
  bool _busy = false;

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<void> _markCompleted() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ReviewCycle updated = await _api.markCompleted(
        _cycle.id,
        version: _cycle.version,
      );
      if (!mounted) return;
      setState(() {
        _cycle = updated;
        _busy = false;
      });
      _toast('已标记为完成');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (e.statusCode == 409) {
        // 乐观锁冲突：本地 version 过期，正确的下一步是回列表重新拉。
        _toast('这条复盘已在别处被修改，请返回列表刷新后再操作。');
      } else if (e.isNetworkError) {
        _toast('无法连接后端，请确认服务已启动。');
      } else {
        _toast('标记失败（HTTP ${e.statusCode}）：${e.message}');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('标记时出现未知错误。');
    }
  }

  Future<void> _confirmDelete() async {
    if (_busy) return;

    final bool? ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '删除复盘',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '删除后需重新生成，确定？\n'
            '（快照内容不可恢复；同周期重新生成会按那时的数据重算。）',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              '取消',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                color: AppColors.accent,
              ),
            ),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              '删除',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.overdue,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await _api.deleteReviewCycle(_cycle.id, version: _cycle.version);
      if (!mounted) return;
      // 回列表并告知列表这次需要刷新
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (e.statusCode == 409) {
        _toast('这条复盘已在别处被修改，请返回列表刷新后再删除。');
      } else if (e.isNetworkError) {
        _toast('无法连接后端，请确认服务已启动。');
      } else {
        _toast('删除失败（HTTP ${e.statusCode}）：${e.message}');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('删除时出现未知错误。');
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
    final ReviewMetrics m = _cycle.metrics;

    // 注意：导航栏必须给**不透明**背景色。`CupertinoPageScaffold` 只在
    // `shouldFullyObstruct`（backgroundColor.alpha == 0xFF）为真时才给 child
    // 补顶部内边距；半透明时会改用 MediaQuery.padding.top，若页面又写了
    // SafeArea(top: false) 就会顶到状态栏下面被盖住（FE-05 踩过两次）。
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.groupedBackground,
        middle: Text(
          _cycle.period,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
            letterSpacing: -0.4,
          ),
        ),
        trailing: _CompletedPill(completed: _cycle.completed),
        border: const Border(
          bottom: BorderSide(color: AppColors.separator, width: 0.5),
        ),
      ),
      child: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                12,
                AppSpacing.page,
                20,
              ),
              children: <Widget>[
                _HeaderBlock(cycle: _cycle),

                _StaggeredFadeIn(
                  index: 0,
                  child: _OpenDefectsCard(data: m.openDefects),
                ),
                const SizedBox(height: AppSpacing.cardGap),
                _StaggeredFadeIn(
                  index: 1,
                  child: _LayerDistCard(entries: m.sortedLayerDist),
                ),
                const SizedBox(height: AppSpacing.cardGap),
                _StaggeredFadeIn(
                  index: 2,
                  child: _VerifyPassCard(data: m.verifyPassRate),
                ),
                const SizedBox(height: AppSpacing.cardGap),
                _StaggeredFadeIn(
                  index: 3,
                  child: _StabilityCard(value: m.mockStability),
                ),
                const SizedBox(height: AppSpacing.cardGap),
                _StaggeredFadeIn(
                  index: 4,
                  child: _TargetCard(data: m.targetProgress),
                ),
                const SizedBox(height: AppSpacing.cardGap),
                _StaggeredFadeIn(
                  index: 5,
                  child: _ReopenCard(spots: m.reopenHotspots),
                ),
                const SizedBox(height: 8),
                const _FooterNote(),
              ],
            ),
          ),
          _BottomBar(
            completed: _cycle.completed,
            busy: _busy,
            onMarkCompleted: _markCompleted,
            onDelete: _confirmDelete,
          ),
        ],
      ),
    );
  }
}

/// 顶部摘要：周期类型 + 生成时间 + 时区口径。
class _HeaderBlock extends StatelessWidget {
  const _HeaderBlock({required this.cycle});

  final ReviewCycle cycle;

  @override
  Widget build(BuildContext context) {
    final String tz = cycle.timeZone ?? 'Asia/Shanghai';
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                cycle.cycleType.label,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: AppColors.label,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(width: 8),
              _SoftTag(text: cycle.period),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '生成于 ${_formatDateTime(cycle.createdAt)} · 按 $tz 切日界',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              height: 1.4,
              color: AppColors.secondaryLabel,
            ),
          ),
        ],
      ),
    );
  }
}

class _SoftTag extends StatelessWidget {
  const _SoftTag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.accent,
          height: 1.3,
        ),
      ),
    );
  }
}

class _CompletedPill extends StatelessWidget {
  const _CompletedPill({required this.completed});

  final bool completed;

  @override
  Widget build(BuildContext context) {
    final Color color = completed ? AppColors.normal : AppColors.secondaryLabel;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        completed ? '已完成' : '未读',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
          height: 1.25,
        ),
      ),
    );
  }
}

// ─────────── 卡片 1：未关闭缺陷 ───────────

class _OpenDefectsCard extends StatelessWidget {
  const _OpenDefectsCard({required this.data});

  final OpenDefects data;

  @override
  Widget build(BuildContext context) {
    final List<MapEntry<String, int>> rows = data.nonZeroStatuses;
    final int sum = rows.fold<int>(
      0,
      (int acc, MapEntry<String, int> e) => acc + e.value,
    );

    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _SectionLabel(text: '未关闭缺陷'),
          const SizedBox(height: 2),
          const _Hint(text: '周期末仍未关闭的单（时点量，不是周期内新增）'),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                '${data.total}',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                  color: AppColors.label,
                  height: 1.1,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                '条',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 14,
                  color: AppColors.secondaryLabel,
                ),
              ),
            ],
          ),
          if (rows.isEmpty)
            const _EmptyLine(text: '本周期末没有未关闭的缺陷单')
          else ...<Widget>[
            const SizedBox(height: 12),
            // 堆叠条：一条宽度按各态占比切分，比七个独立条形更省空间，
            // 也更直观地表达「总数 = 各态之和」。
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 10,
                child: Row(
                  children: <Widget>[
                    for (final MapEntry<String, int> e in rows)
                      Expanded(
                        flex: e.value,
                        child: Container(
                          color: statusColor(DefectStatus.fromWire(e.key)),
                          margin: const EdgeInsets.only(right: 1),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 8,
              children: <Widget>[
                for (final MapEntry<String, int> e in rows)
                  _LegendDot(
                    color: statusColor(DefectStatus.fromWire(e.key)),
                    label: '${DefectStatus.fromWire(e.key).label} ${e.value}',
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '合计 $sum 条按状态拆分',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                color: AppColors.tertiaryLabel,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────── 卡片 2：错因层级分布 ───────────

class _LayerDistCard extends StatelessWidget {
  const _LayerDistCard({required this.entries});

  final List<MapEntry<String, int>> entries;

  @override
  Widget build(BuildContext context) {
    final int maxCount = entries.isEmpty
        ? 1
        : entries
            .map((MapEntry<String, int> e) => e.value)
            .reduce((int a, int b) => a > b ? a : b);

    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _SectionLabel(text: '错因层级分布'),
          const SizedBox(height: 2),
          const _Hint(text: '周期内新建的单按归因层级分组（增量，含已关闭）'),
          const SizedBox(height: 12),
          if (entries.isEmpty)
            const _EmptyLine(text: '本周期没有新建缺陷单')
          else
            for (int i = 0; i < entries.length; i++)
              _BarRow(
                label: _layerLabel(entries[i].key),
                value: entries[i].value,
                maxValue: maxCount,
                color: i == 0 ? AppColors.accent : AppColors.accent.withValues(alpha: 0.35),
              ),
        ],
      ),
    );
  }
}

/// 层级键是后端自由文本（`error_layer`）。
/// 空串与 `unclassified` 都表示「没填/填了空白」，统一显示成「未分类」。
String _layerLabel(String key) {
  final String k = key.trim();
  if (k.isEmpty || k == 'unclassified') return '未分类';
  return k;
}

// ─────────── 卡片 3：验证通过率 ───────────

class _VerifyPassCard extends StatelessWidget {
  const _VerifyPassCard({required this.data});

  final VerifyPassRate data;

  @override
  Widget build(BuildContext context) {
    final bool empty = data.total == 0;
    final double rate = data.rate ?? 0;
    final Color color = empty
        ? AppColors.tertiaryLabel
        : (rate < 0.6
            ? AppColors.overdue
            : (rate < 0.85 ? AppColors.dueSoon : AppColors.normal));

    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _SectionLabel(text: '验证通过率'),
          const SizedBox(height: 2),
          const _Hint(text: '周期内提交的三次验证结果'),
          const SizedBox(height: 14),
          if (empty)
            const _EmptyLine(text: '本周期没有提交验证')
          else ...<Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Text(
                  data.ratePercent,
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                    color: color,
                    height: 1.1,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '通过 ${data.pass} / 共 ${data.total}',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    color: AppColors.secondaryLabel,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // pass / fail 两根柱并排比较：比单根进度条更能看出「失败也很多」
            Row(
              children: <Widget>[
                Expanded(
                  child: _ColumnBar(
                    label: '通过',
                    value: data.pass,
                    total: data.total,
                    color: AppColors.normal,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ColumnBar(
                    label: '未通过',
                    value: data.fail,
                    total: data.total,
                    color: AppColors.overdue,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ColumnBar extends StatelessWidget {
  const _ColumnBar({
    required this.label,
    required this.value,
    required this.total,
    required this.color,
  });

  final String label;
  final int value;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final double ratio = total <= 0 ? 0 : (value / total).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  color: AppColors.secondaryLabel,
                ),
              ),
            ),
            Text(
              '$value',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: color,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 6,
            child: Stack(
              children: <Widget>[
                Container(color: AppColors.groupedBackground),
                FractionallySizedBox(
                  widthFactor: ratio == 0 ? 0.02 : ratio,
                  child: Container(color: color),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────── 卡片 4：模考稳定性 ───────────

class _StabilityCard extends StatelessWidget {
  const _StabilityCard({required this.value});

  /// 变异系数（标准差 / 均值），越小越稳。本周期无模考时为 null。
  final double? value;

  @override
  Widget build(BuildContext context) {
    final double? v = value;
    // 阈值与模考报告页保持一致（0.15 / 0.30），避免同一指标两套解读。
    final String verdict = v == null
        ? ''
        : (v < 0.15
            ? '波动很小，接近稳定'
            : (v < 0.30 ? '有小幅波动' : '波动偏大（变异系数）'));
    final Color color = v == null
        ? AppColors.secondaryLabel
        : (v < 0.15
            ? AppColors.normal
            : (v < 0.30 ? AppColors.dueSoon : AppColors.overdue));

    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _SectionLabel(text: '模考稳定性'),
          const SizedBox(height: 2),
          const _Hint(text: '近 3 次模考正确率的变异系数，越小越稳'),
          const SizedBox(height: 14),
          if (v == null)
            const _EmptyLine(text: '本周期无模考')
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Text(
                  v.toStringAsFixed(2),
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    color: color,
                    height: 1.1,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    verdict,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 13,
                      height: 1.35,
                      color: AppColors.secondaryLabel,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ─────────── 卡片 5：目标进度 ───────────

class _TargetCard extends StatelessWidget {
  const _TargetCard({required this.data});

  final TargetProgress data;

  @override
  Widget build(BuildContext context) {
    final double? fraction = data.barFraction;
    final String rateText = data.rate == null
        ? '—'
        : '${(data.rate! * 100).round()}%';

    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _SectionLabel(text: '目标进度'),
          const SizedBox(height: 2),
          const _Hint(text: '周期内最近一次模考折算分 / 目标分'),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: _ScoreCell(
                  label: '当前',
                  value: data.latestMockScore,
                  suffix: '分',
                ),
              ),
              Expanded(
                child: _ScoreCell(
                  label: '目标',
                  value: data.targetScore,
                  suffix: '分',
                ),
              ),
              Expanded(
                child: _ScoreCell(
                  label: '达成',
                  valueText: rateText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: Stack(
                children: <Widget>[
                  Container(color: AppColors.groupedBackground),
                  if (fraction != null)
                    FractionallySizedBox(
                      // 0 也要留 2% 宽度，否则「达成了 0%」与「没有进度条」看不出区别
                      widthFactor: fraction == 0 ? 0.02 : fraction,
                      child: Container(
                        color: fraction >= 1
                            ? AppColors.normal
                            : AppColors.accent,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            data.targetScore == null
                ? '考试目标还没设置目标分，无法算达成率'
                : (data.latestMockScore == null
                    ? '本周期没有已交卷的模考'
                    : (fraction != null && fraction >= 1
                        ? '已达到目标分'
                        : '距离目标还差 ${(data.targetScore! - data.latestMockScore!).toStringAsFixed(1)} 分')),
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11,
              height: 1.35,
              color: AppColors.tertiaryLabel,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoreCell extends StatelessWidget {
  const _ScoreCell({
    required this.label,
    this.value,
    this.valueText,
    this.suffix,
  });

  final String label;
  final double? value;
  final String? valueText;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final String text = valueText ??
        (value == null ? '—' : value!.toStringAsFixed(1).replaceAll('.0', ''));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11,
            color: AppColors.secondaryLabel,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.label,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (suffix != null && value != null)
              Text(
                suffix!,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 11,
                  color: AppColors.secondaryLabel,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ─────────── 卡片 6：重开热点 ───────────

class _ReopenCard extends StatelessWidget {
  const _ReopenCard({required this.spots});

  final List<ReopenHotspot> spots;

  @override
  Widget build(BuildContext context) {
    final int sum = spots.fold<int>(
      0,
      (int acc, ReopenHotspot s) => acc + s.reopenCountSum,
    );
    final int maxCount = spots.isEmpty
        ? 1
        : spots
            .map((ReopenHotspot s) => s.reopenCountSum)
            .reduce((int a, int b) => a > b ? a : b);

    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _SectionLabel(text: '重开热点'),
          const SizedBox(height: 2),
          _Hint(
            text: sum == 0
                ? '周期内没有发生过重开'
                : '周期内重开次数累计最多的考点（前 5 名，合计 $sum 次）',
          ),
          const SizedBox(height: 12),
          if (spots.isEmpty)
            const _EmptyLine(text: '本周期没有重开记录')
          else
            for (final ReopenHotspot s in spots)
              _BarRow(
                label: s.displayTitle,
                value: s.reopenCountSum,
                maxValue: maxCount,
                color: AppColors.overdue.withValues(alpha: 0.85),
              ),
        ],
      ),
    );
  }
}

// ─────────── 共用小件 ───────────

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
        letterSpacing: -0.2,
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: kFontFamily,
        fontSize: 11,
        height: 1.35,
        color: AppColors.tertiaryLabel,
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
      padding: const EdgeInsets.symmetric(vertical: 6),
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

/// 一行「标签 + 条 + 数值」，用于层级分布与重开热点。
class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.value,
    required this.maxValue,
    required this.color,
  });

  final String label;
  final int value;
  final int maxValue;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final double ratio = maxValue <= 0 ? 0 : (value / maxValue).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    color: AppColors.label,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$value',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.label,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Stack(
                children: <Widget>[
                  Container(color: AppColors.groupedBackground),
                  FractionallySizedBox(
                    widthFactor: ratio == 0 ? 0.02 : ratio,
                    child: Container(color: color),
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

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 12,
            color: AppColors.secondaryLabel,
          ),
        ),
      ],
    );
  }
}

class _FooterNote extends StatelessWidget {
  const _FooterNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Text(
        '复盘是生成那一刻的快照：之后的缺陷单、验证、模考都不会改动这份数据。'
        '需要最新数字请重新生成（同周期需先删除旧快照）。',
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          height: 1.45,
          color: AppColors.tertiaryLabel,
        ),
      ),
    );
  }
}

/// 底部固定操作区。
///
/// 用 `SafeArea(top: false)` 保证在 iPhone 上不被 home indicator 压住；
/// 顶部 0.5px 分割线与页面其它分隔保持一致。
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.completed,
    required this.busy,
    required this.onMarkCompleted,
    required this.onDelete,
  });

  final bool completed;
  final bool busy;
  final VoidCallback onMarkCompleted;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(
          top: BorderSide(color: AppColors.separator, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: completed
              ? Row(
                  children: <Widget>[
                    const Icon(
                      CupertinoIcons.check_mark_circled_solid,
                      size: 18,
                      color: AppColors.normal,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      '已完成',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.normal,
                      ),
                    ),
                    const Spacer(),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      color: AppColors.overdue.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(AppRadii.chip),
                      onPressed: busy ? null : onDelete,
                      child: const Text(
                        '删除复盘',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.overdue,
                        ),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: <Widget>[
                    Expanded(
                      child: CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(AppRadii.chip),
                        onPressed: busy ? null : onMarkCompleted,
                        child: Text(
                          busy ? '处理中…' : '标记已读',
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// 六块卡片依次淡入（任务要求「简单 fadeIn，无第三方动画库」）。
///
/// 用 stateful + 一次性 AnimationController 而不是隐式动画：
/// 隐式动画只能表达「值变了」，无法表达「延迟 60ms×index 后自己开始」。
class _StaggeredFadeIn extends StatefulWidget {
  const _StaggeredFadeIn({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_StaggeredFadeIn> createState() => _StaggeredFadeInState();
}

class _StaggeredFadeInState extends State<_StaggeredFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  // 刻意声明成 CurvedAnimation 而不是 Animation<double>：
  // `Animation` 接口没有 dispose，只有 CurvedAnimation 有（它要给父动画
  // 摘监听），dispose 里必须能调到，否则会泄漏一个 listener。
  late final CurvedAnimation _fade = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOut,
  );

  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    // Reduce Motion 下直接显示终态，不做错峰淡入
    final bool reduce =
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
            .disableAnimations;
    if (reduce) {
      _c.value = 1;
      return;
    }
    _scheduled = true;
    // 用 post-frame 回调而不是 initState 里 Future.delayed，
    // 这样首帧已经在位（opacity 0），不会出现「先闪一下再淡入」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Future<void>.delayed(Duration(milliseconds: 45 * widget.index), () {
        if (!mounted) return;
        _c.forward();
      });
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_scheduled) return widget.child;
    return FadeTransition(opacity: _fade, child: widget.child);
  }
}

String _formatDateTime(DateTime t) {
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
