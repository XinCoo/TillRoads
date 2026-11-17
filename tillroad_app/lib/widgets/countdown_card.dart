import 'package:flutter/cupertino.dart';

import '../theme/app_theme.dart';

/// 考试目标 + 倒计时卡片
///
/// 大标题折叠动效由外层 `CupertinoSliverNavigationBar(largeTitle: ...)` 提供
/// （滚动时 34pt 大标题连续插值收缩为 17pt 导航标题，中间不跳变），
/// 本卡片负责的是标题下方的倒计时数字本身。
///
/// 数字变化动效：`ease-in-out 250ms`（[AppDurations.countdown]），
/// 用 `AnimatedSwitcher` + `FadeTransition`/`ScaleTransition` 实现，
/// 因为「天数」是离散整数，直接数字滚动会像计数器，
/// iOS 风格是「旧数字淡出、新数字从 0.9 淡入」。
class CountdownCard extends StatelessWidget {
  const CountdownCard({
    super.key,
    required this.examLabel,
    required this.daysToExam,
  });

  final String examLabel;
  final int daysToExam;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final Duration duration = reduceMotion
        ? AppDurations.reduceMotion
        : AppDurations.countdown;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.cardPadding,
        vertical: 18,
      ),
      decoration: BoxDecoration(
        // 用 iOS 主色的极浅渐变增加层次，避免纯白卡片与背景对比不足
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFFEAF2FF), Color(0xFFFFFFFF)],
        ),
        borderRadius: BorderRadius.circular(AppRadii.card),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 12,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  examLabel,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '距离考试',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              AnimatedSwitcher(
                duration: duration,
                switchInCurve: Curves.easeInOut,
                switchOutCurve: Curves.easeInOut,
                // 默认的 layoutBuilder 会把新旧子节点叠在一起，
                // 这里保持默认叠放即可；关键是 key 必须绑定数值，
                // 否则相同 widget 类型不会触发切换动画。
                transitionBuilder: (Widget child, Animation<double> animation) {
                  if (reduceMotion) {
                    return FadeTransition(opacity: animation, child: child);
                  }
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      // 0.9 → 1.0 的轻微放大，避免数字「凭空出现」
                      scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: Text(
                  '$daysToExam',
                  key: ValueKey<int>(daysToExam),
                  style: const TextStyle(
                    fontSize: 44,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: AppColors.label,
                    letterSpacing: -1,
                    fontFeatures: <FontFeature>[
                      // 等宽数字：数字变化时宽度不抖
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  '天',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
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
