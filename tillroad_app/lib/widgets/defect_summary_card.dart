import 'package:flutter/cupertino.dart';

import '../mock/home_mock.dart';
import '../theme/app_theme.dart';

/// 缺陷分布概况卡片：按 error_layer 的横向条形图
///
/// 硬约束要求「纯 Widget 画，不引图表库」——这里用 `LayoutBuilder` 拿到可用宽度，
/// 再对每一行用 `Align + FractionallySizedBox` 控制条形宽度比例，
/// 既不需要任何依赖，也不会像 `Stack + Positioned` 那样在窄屏溢出。
class DefectSummaryCard extends StatelessWidget {
  const DefectSummaryCard({
    super.key,
    required this.distributions,
    required this.totalDefects,
  });

  final List<LayerDistribution> distributions;
  final int totalDefects;

  int get _max {
    int max = 0;
    for (final LayerDistribution item in distributions) {
      if (item.count > max) max = item.count;
    }
    return max == 0 ? 1 : max;
  }

  @override
  Widget build(BuildContext context) {
    if (distributions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.cardPadding),
        child: Text(
          '还没有归因数据',
          style: TextStyle(fontSize: 14, color: AppColors.secondaryLabel),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.cardPadding,
        14,
        AppSpacing.cardPadding,
        16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int i = 0; i < distributions.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 12),
            _DistributionBar(
              item: distributions[i],
              ratio: distributions[i].count / _max,
              // 只有第一档用主色强调，其余用同一色系的递减透明度，
              // 避免四根不同颜色的条形变成「彩虹图」反而难读
              emphasis: i == 0,
            ),
          ],
        ],
      ),
    );
  }
}

class _DistributionBar extends StatelessWidget {
  const _DistributionBar({
    required this.item,
    required this.ratio,
    required this.emphasis,
  });

  final LayerDistribution item;

  /// 0..1，相对最大值
  final double ratio;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final Color barColor = emphasis
        ? AppColors.accent
        : AppColors.accent.withValues(alpha: 0.35);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                item.label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.label,
                ),
              ),
            ),
            Text(
              '${item.count}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: emphasis ? AppColors.accent : AppColors.secondaryLabel,
                fontFeatures: const <FontFeature>[
                  FontFeature.tabularFigures(),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Container(
            height: 6,
            color: AppColors.groupedBackground,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                // 最小 3% 保证「1 条」也能看见一条细线，不会完全消失
                widthFactor: ratio.clamp(0.03, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: barColor,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
