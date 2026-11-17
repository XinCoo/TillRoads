import 'package:flutter/cupertino.dart';

import '../theme/app_theme.dart';
import 'common.dart';

/// 快捷入口数据
@immutable
class QuickAction {
  const QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// 快捷入口网格：2×2 四个图标按钮
///
/// 时序：建题 → 转缺陷单 → 开始模考 → 复盘，
/// 与产品主闭环（录入 → 归因 → 限时验证 → 周期复盘）同序，
/// 用户从左到右、从上到下扫视即是一条完整流程。
///
/// 每个格子都用 [PressableCard]（弹簧 + 触感），
/// 而不是 `CupertinoButton`——后者在网格里会带明显的按下遮罩，
/// 与「卡片」视觉语言不一致。
class QuickActionGrid extends StatelessWidget {
  const QuickActionGrid({super.key, required this.actions});

  final List<QuickAction> actions;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 两列，中间 12 间距。用 LayoutBuilder 而不是 GridView，
        // 因为这里只需要固定 2×2，GridView 会引入滚动与 viewport 的开销。
        final double cellWidth = (constraints.maxWidth - 12) / 2;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            for (final QuickAction action in actions)
              SizedBox(
                width: cellWidth,
                child: PressableCard(
                  onTap: action.onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 16,
                    ),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppColors.accent.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            action.icon,
                            size: 19,
                            color: AppColors.accent,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            action.label,
                            maxLines: 2,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.25,
                              color: AppColors.label,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
