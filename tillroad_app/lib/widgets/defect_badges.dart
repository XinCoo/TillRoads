import 'package:flutter/cupertino.dart';

import '../mock/defects_mock.dart';
import '../theme/app_theme.dart';

/// 状态 → 徽标颜色
///
/// 严格按任务书约定：
/// - `DRAFT` / `ANALYZED` 灰
/// - `ACTION_DONE` 蓝
/// - `V1` / `V2` / `V3` 橙
/// - `REOPENED` 红
/// - `CLOSED` 绿
Color statusColor(DefectStatus status) => switch (status) {
  DefectStatus.draft => AppColors.secondaryLabel,
  DefectStatus.analyzed => AppColors.secondaryLabel,
  DefectStatus.actionDone => AppColors.accent,
  DefectStatus.v1 => AppColors.dueSoon,
  DefectStatus.v2 => AppColors.dueSoon,
  DefectStatus.v3 => AppColors.dueSoon,
  DefectStatus.reopened => AppColors.overdue,
  DefectStatus.closed => AppColors.normal,
};

/// 优先级 → 徽标颜色：P0 红 / P1 橙 / P2 灰
Color priorityColor(DefectPriority priority) => switch (priority) {
  DefectPriority.p0 => AppColors.overdue,
  DefectPriority.p1 => AppColors.dueSoon,
  DefectPriority.p2 => AppColors.secondaryLabel,
};

/// 状态徽标
///
/// 用 `AnimatedContainer` 做 250ms ease-in-out 的颜色过渡：
/// 当状态因筛选或数据刷新而变化时，底色与文字色会平滑插值，不硬切。
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status, this.dense = false});

  final DefectStatus status;

  /// 列表里用小号，详情页用常规号
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final bool reduce =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final Color color = statusColor(status);

    return AnimatedContainer(
      // Reduce Motion 时不做颜色渐变，直接切（≤200ms 也允许，但直接切更彻底）
      duration: reduce ? Duration.zero : AppDurations.countdown,
      curve: Curves.easeInOut,
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(dense ? 5 : 6),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: dense ? 11 : 12,
          fontWeight: FontWeight.w600,
          color: color,
          height: 1.25,
        ),
      ),
    );
  }
}

/// 优先级徽标（P0/P1/P2）
class PriorityBadge extends StatelessWidget {
  const PriorityBadge({super.key, required this.priority});

  final DefectPriority priority;

  @override
  Widget build(BuildContext context) {
    final Color color = priorityColor(priority);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        priority.wire,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
          height: 1.25,
        ),
      ),
    );
  }
}

/// 「第 N 轮」小标签（verification_round > 1 时才显示）
class RoundChip extends StatelessWidget {
  const RoundChip({super.key, required this.round});

  final int round;

  @override
  Widget build(BuildContext context) {
    return Text(
      '第 $round 轮',
      style: const TextStyle(
        fontFamily: kFontFamily,
        fontSize: 11,
        color: AppColors.secondaryLabel,
        height: 1.3,
      ),
    );
  }
}

/// 「重开 N 次」红色角标（reopen_count > 0 时才显示）
class ReopenChip extends StatelessWidget {
  const ReopenChip({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.overdue.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '重开 $count 次',
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.overdue,
          height: 1.3,
        ),
      ),
    );
  }
}

/// 同步状态小角标（R4a）：本地已改、还没推到云端，或推送撞上了 409。
///
/// 刻意做得轻：灰字 + 小圆点，不抢状态的视觉优先级 —— 用户关心的是这张单
/// 「验证到第几次了」，而不是「有没有同步」。冲突用橙色，因为那时需要他动手。
class SyncBadge extends StatelessWidget {
  const SyncBadge({super.key, this.hasConflict = false});

  final bool hasConflict;

  @override
  Widget build(BuildContext context) {
    final Color color =
        hasConflict ? AppColors.dueSoon : AppColors.secondaryLabel;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          hasConflict ? '待同步 · 有冲突' : '待同步',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: color,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}

/// 白色圆角卡片外壳（与 FE-01 首页 `_CardShell` 同一视觉规格）
class CardShell extends StatelessWidget {
  const CardShell({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 12,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 一行「标签 — 值」的只读信息行（详情页六栏用）
class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value});

  final String label;

  /// 允许多个 widget 横排（如徽标 + 文字）
  final Widget value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                color: AppColors.secondaryLabel,
                height: 1.4,
              ),
            ),
          ),
          Expanded(child: value),
        ],
      ),
    );
  }
}

/// 详情页那种「一行文字值」的便捷构造
class InfoText extends StatelessWidget {
  const InfoText(
    this.text, {
    super.key,
    this.size = 14,
    this.weight = FontWeight.w400,
    this.color = AppColors.label,
    this.height = 1.4,
  });

  final String text;
  final double size;
  final FontWeight weight;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: kFontFamily,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
      ),
    );
  }
}
