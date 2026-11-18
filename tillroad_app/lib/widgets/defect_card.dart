import 'package:flutter/cupertino.dart';

import '../mock/defects_mock.dart';
import '../theme/app_theme.dart';
import 'common.dart';
import 'defect_badges.dart';

/// 缺陷单列表卡片
///
/// 三行布局（严格按任务书）：
/// 1. `q_type` + 右侧 priority 徽标
/// 2. `error_cause` 单行截断
/// 3. status 徽标 + 第 N 轮 + 重开 N 次 + 相对时间
class DefectCard extends StatelessWidget {
  const DefectCard({super.key, required this.ticket, this.onTap});

  final DefectTicket ticket;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return PressableCard(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // ── 第一行：题型考点 + 优先级 ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(
                    ticket.qType,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.label,
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PriorityBadge(priority: ticket.priority),
              ],
            ),
            const SizedBox(height: 6),

            // ── 第二行：归因说明，单行截断 ──
            Text(
              ticket.errorCause,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                color: AppColors.secondaryLabel,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),

            // ── 第三行：状态徽标 + 轮次 + 重开 + 时间 ──
            Row(
              children: <Widget>[
                StatusBadge(status: ticket.status, dense: true),
                if (ticket.verificationRound > 1) ...<Widget>[
                  const SizedBox(width: 6),
                  RoundChip(round: ticket.verificationRound),
                ],
                if (ticket.reopenCount > 0) ...<Widget>[
                  const SizedBox(width: 6),
                  ReopenChip(count: ticket.reopenCount),
                ],
                const Spacer(),
                Text(
                  relativeTime(ticket.createdAt),
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    color: AppColors.tertiaryLabel,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 横向滚动的筛选 chip 行
///
/// 为什么不用 `CupertinoSegmentedControl`：它在 5 个中文标签下会挤压到
/// 文字换行，且选中机会被系统色带覆盖，无法保留我们统一的主色与圆角。
/// 自定义 chip 行更可控，也没有引入任何 Material 组件（不会有 ripple）。
class FilterChipRow extends StatelessWidget {
  const FilterChipRow({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.counts,
  });

  final DefectFilter selected;
  final ValueChanged<DefectFilter> onChanged;

  /// 每个分组下的条数，用于 chip 右侧的小数字
  final Map<DefectFilter, int> counts;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
        itemCount: DefectFilter.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final DefectFilter filter = DefectFilter.values[index];
          final bool active = filter == selected;
          final int count = counts[filter] ?? 0;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(filter),
            child: AnimatedContainer(
              duration: AppDurations.countdown,
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? AppColors.accent : AppColors.card,
                borderRadius: BorderRadius.circular(17),
                boxShadow: active
                    ? null
                    : const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x0A000000),
                          blurRadius: 6,
                          offset: Offset(0, 1),
                        ),
                      ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    filter.label,
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 14,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active ? CupertinoColors.white : AppColors.label,
                      height: 1.3,
                    ),
                  ),
                  if (count > 0) ...<Widget>[
                    const SizedBox(width: 5),
                    Text(
                      '$count',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: active
                            ? CupertinoColors.white.withValues(alpha: 0.75)
                            : AppColors.tertiaryLabel,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
