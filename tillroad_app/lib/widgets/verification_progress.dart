import 'package:flutter/cupertino.dart';

import '../mock/defects_mock.dart';
import '../theme/app_theme.dart';
import 'defect_badges.dart';

/// 三次验证进度（V1 / V2 / V3 三行）
///
/// - 结果图标：`pending` 灰空心圆 / `pass` 绿实心勾 / `fail` 红实心叉
/// - **当前 stage 高亮**：如 `status == V2` 时 V2 这行带橙色左边框
/// - 图标切换用 `AnimatedSwitcher` 200ms（Reduce Motion 时直接切）
///
/// 之所以把三个 stage 一次性都展示（而不是只显示当前那条），是因为
/// 产品核心是「三次验证才能关闭」——用户需要一眼看到还差几步。
class VerificationProgress extends StatelessWidget {
  const VerificationProgress({super.key, required this.ticket});

  final DefectTicket ticket;

  @override
  Widget build(BuildContext context) {
    final bool reduce =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final DefectStatus? active = ticket.currentStage;

    return Column(
      children: <Widget>[
        for (final (String stage, VerifyResult result) in ticket.verifyTrack)
          _StageRow(
            stage: stage,
            result: result,
            isActive: active != null && active.wire == stage,
            reduceMotion: reduce,
          ),
      ],
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({
    required this.stage,
    required this.result,
    required this.isActive,
    required this.reduceMotion,
  });

  final String stage;
  final VerifyResult result;

  /// 是否是「当前正在进行的这一阶段」
  final bool isActive;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final Color accent =
        isActive ? AppColors.dueSoon : CupertinoColors.transparent;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: isActive
            ? AppColors.dueSoon.withValues(alpha: 0.06)
            : CupertinoColors.transparent,
        borderRadius: BorderRadius.circular(8),
        // 当前阶段：橙色左边框（3px）——比整块高亮更克制
        border: Border(
          left: BorderSide(width: 3, color: accent),
        ),
      ),
      child: Row(
        children: <Widget>[
          AnimatedSwitcher(
            duration: reduceMotion ? Duration.zero : AppDurations.reduceMotion,
            switchInCurve: Curves.easeInOut,
            switchOutCurve: Curves.easeInOut,
            child: _ResultIcon(
              key: ValueKey<VerifyResult>(result),
              result: result,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            stage,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              color: AppColors.label,
              height: 1.3,
            ),
          ),
          const SizedBox(width: 8),
          if (isActive)
            Text(
              '进行中',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.dueSoon,
                height: 1.3,
              ),
            ),
          const Spacer(),
          Text(
            result.label,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: _resultColor(result),
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

Color _resultColor(VerifyResult result) => switch (result) {
  VerifyResult.pending => AppColors.tertiaryLabel,
  VerifyResult.pass => AppColors.normal,
  VerifyResult.fail => AppColors.overdue,
};

IconData _resultIcon(VerifyResult result) => switch (result) {
  VerifyResult.pending => CupertinoIcons.circle,
  VerifyResult.pass => CupertinoIcons.check_mark_circled_solid,
  VerifyResult.fail => CupertinoIcons.xmark_circle_fill,
};

class _ResultIcon extends StatelessWidget {
  const _ResultIcon({super.key, required this.result});

  final VerifyResult result;

  @override
  Widget build(BuildContext context) {
    return Icon(_resultIcon(result), size: 20, color: _resultColor(result));
  }
}

/// 垂直状态流转时间线
///
/// 纯 `Container` + 圆点 + 竖线手画，不引任何第三方时间线库。
/// 最后一个节点下方不画竖线（否则会悬空一截）。
class StatusTimeline extends StatelessWidget {
  const StatusTimeline({super.key, required this.events});

  /// 按时间正序传入（最早在前）
  final List<StatusEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Text(
        '暂无状态记录',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 14,
          color: AppColors.secondaryLabel,
        ),
      );
    }

    return Column(
      children: <Widget>[
        for (int i = 0; i < events.length; i++)
          _TimelineNode(
            event: events[i],
            isLast: i == events.length - 1,
            isCurrent: i == events.length - 1,
          ),
      ],
    );
  }
}

class _TimelineNode extends StatelessWidget {
  const _TimelineNode({
    required this.event,
    required this.isLast,
    required this.isCurrent,
  });

  final StatusEvent event;
  final bool isLast;

  /// 最后一个节点是「当前状态」，用实心大圆点强调
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final Color dotColor =
        isCurrent ? statusColor(event.status) : AppColors.tertiaryLabel;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // ── 左侧：圆点 + 竖线 ──
          SizedBox(
            width: 20,
            child: Column(
              children: <Widget>[
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  width: isCurrent ? 12 : 9,
                  height: isCurrent ? 12 : 9,
                  decoration: BoxDecoration(
                    color: isCurrent ? dotColor : AppColors.card,
                    shape: BoxShape.circle,
                    border: Border.all(color: dotColor, width: 2),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      color: AppColors.separator,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // ── 右侧：状态徽标 + 时间 ──
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: Row(
                children: <Widget>[
                  StatusBadge(status: event.status, dense: true),
                  const SizedBox(width: 8),
                  Text(
                    relativeTime(event.at),
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12,
                      color: AppColors.secondaryLabel,
                      height: 1.4,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    absoluteTime(event.at),
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11,
                      color: AppColors.tertiaryLabel,
                      height: 1.4,
                    ),
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
