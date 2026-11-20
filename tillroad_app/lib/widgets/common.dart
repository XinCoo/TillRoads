import 'package:flutter/cupertino.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// 可按下卡片：iOS 弹簧回弹 + 触感反馈
///
/// 动效依据 fe-11-audit-motion-spec.md：
/// - 按下时 `HapticFeedback.lightImpact()` 与视觉变化同帧触发
/// - 缩放走 `SpringDescription.withDampingRatio(ratio: 0.85, stiffness: 220)`
///   （见 [kPressSpring]），**不使用** `Curves.elasticOut` 冒充弹簧
/// - Reduce Motion 开启时完全关闭缩放，只保留触感反馈
///
/// 为什么手写而不是用 `AnimatedScale`：`AnimatedScale` 只接受 `Curve`，
/// 无法表达 SpringDescription；而 iOS 的按压手感本质是弹簧，不是缓动曲线。
class PressableCard extends StatefulWidget {
  const PressableCard({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.97,
    this.borderRadius = AppRadii.card,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// 按下时缩到的比例。0.97 是 iOS 卡片常见的「几乎看不出但能感觉到」的量
  final double pressedScale;
  final double borderRadius;

  @override
  State<PressableCard> createState() => _PressableCardState();
}

class _PressableCardState extends State<PressableCard>
    with SingleTickerProviderStateMixin {
  /// `unbounded` 因为弹簧会过冲超过 [Container] 的 0..1 区间，
  /// 用普通 AnimationController 会被 clamp 掉回弹过程。
  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _reduceMotion {
    final MediaQueryData? data = MediaQuery.maybeOf(context);
    return data?.disableAnimations ?? false;
  }

  void _pressIn() {
    // 触感与视觉同帧：先触发触感，再启动动画（两者在同一帧回调内）
    HapticFeedback.lightImpact();
    if (_reduceMotion) return;
    _controller.animateWith(
      SpringSimulation(kPressSpring, _controller.value, widget.pressedScale, 0),
    );
  }

  void _pressOut() {
    if (_reduceMotion) {
      _controller.value = 1;
      return;
    }
    _controller.animateWith(
      SpringSimulation(kPressSpring, _controller.value, 1, 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget card = DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 12,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: widget.child,
    );

    final Widget animated = widget.onTap == null
        ? card
        : ScaleTransition(scale: _controller, child: card);

    if (widget.onTap == null) return animated;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _pressIn(),
      onTapUp: (_) => _pressOut(),
      onTapCancel: _pressOut,
      onTap: widget.onTap,
      child: animated,
    );
  }
}

/// 分组标题（iOS 分组列表里那种小号灰字大写标题）
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.text, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.secondaryLabel,
                letterSpacing: -0.08,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 空状态占位（底部四个 Tab 用）
///
/// 文案按 FE-01 任务书固定为「暂无数据，从一次模考或错题开始」。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 56, color: AppColors.tertiaryLabel),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppColors.label,
                letterSpacing: -0.45,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                height: 1.4,
                color: AppColors.secondaryLabel,
              ),
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: 20),
              CupertinoButton(
                color: AppColors.accent,
                // 必须显式给前景色：`CupertinoButton` 的 plain 样式在传了
                // `color` 之后，文字默认仍取主题 `primaryColor`（等于 accent），
                // 于是出现「蓝底蓝字」——按钮看起来是个空蓝块。
                foregroundColor: CupertinoColors.white,
                borderRadius: BorderRadius.circular(AppRadii.chip),
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
