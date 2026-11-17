import 'package:flutter/cupertino.dart';

import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 验证页（FE-01 阶段只做空状态）
///
/// 后端 BE-04 已提供 `GET /users/:userId/verification-tasks`，
/// 后续 FE 里程碑接上后这里会按 urgency 三态（overdue / due_soon / normal）
/// 分组展示，与首页「今日待验证」卡片同源。
class VerifyPage extends StatelessWidget {
  const VerifyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: const <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: Text('验证'),
            border: Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: CupertinoIcons.check_mark_circled,
              title: '还没有待验证任务',
              message: '暂无数据，从一次模考或错题开始',
            ),
          ),
        ],
      ),
    );
  }
}
