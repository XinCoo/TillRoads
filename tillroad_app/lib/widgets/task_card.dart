import 'package:flutter/cupertino.dart';

import '../mock/home_mock.dart';
import '../theme/app_theme.dart';

/// 单条待验证任务
///
/// 布局取舍：考点名（可能很长，如「判断推理 · 充分必要条件」）必须优先拿到
/// 水平空间，所以右侧只放一个紧凑的天数徽标，urgency 的中文标签移到左侧
/// 第二行跟 stage 徽标并排。若把「剩余天数」和「urgency 文案」叠在右侧两行，
/// 右列会吃掉约 80px，考点名在 400px 宽的手机上会被截成「充分必要…」。
class TaskCard extends StatelessWidget {
  const TaskCard({super.key, required this.task});

  final VerificationTask task;

  @override
  Widget build(BuildContext context) {
    final Color urgencyColor = AppColors.forUrgency(task.urgency);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          // 左侧 urgency 色竖条：三态在这里最直观，比只靠徽标颜色更醒目
          Container(
            width: 3,
            height: 40,
            decoration: BoxDecoration(
              color: urgencyColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  task.knowledgeNodeTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.label,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: <Widget>[
                    _StageBadge(stage: task.stage),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        task.subjectName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.secondaryLabel,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      AppColors.labelForUrgency(task.urgency),
                      style: TextStyle(fontSize: 12, color: urgencyColor),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // 天数徽标：12% 透明底 + 实色字，是 iOS 徽标的标准做法
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: urgencyColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              task.daysLeftLabel,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: urgencyColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// V1 / V2 / V3 阶段徽标
///
/// 刻意三态同色（中性灰）：阶段是流程位置，不是优先级，
/// 用不同颜色会让人误以为 V3 比 V1 更重要。
class _StageBadge extends StatelessWidget {
  const _StageBadge({required this.stage});

  final String stage;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.separator,
        borderRadius: BorderRadius.circular(AppRadii.chip - 2),
      ),
      child: Text(
        stage,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.secondaryLabel,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// 任务列表卡片内容（外壳由外部提供）
class TaskListCard extends StatelessWidget {
  const TaskListCard({super.key, required this.tasks, this.onTapTask});

  final List<VerificationTask> tasks;
  final ValueChanged<VerificationTask>? onTapTask;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.cardPadding,
        vertical: 6,
      ),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < tasks.length; i++) ...<Widget>[
            if (i > 0)
              // 0.5px 分割线用 Container 画，避免引 Material 的 Divider
              const SizedBox(
                height: 0.5,
                child: ColoredBox(color: AppColors.separator),
              ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTapTask == null ? null : () => onTapTask!(tasks[i]),
              child: TaskCard(task: tasks[i]),
            ),
          ],
        ],
      ),
    );
  }
}
