import 'package:flutter/cupertino.dart';

import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 模考页（FE-01 阶段只做空状态）
///
/// 后端 BE-05 已提供组卷 / 提交 / 报告三组端点，
/// 后续 FE 里程碑接上后这里是「选科目 → 限时作答 → 交卷出报告」。
class MockPage extends StatelessWidget {
  const MockPage({super.key});

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
            largeTitle: Text('模考'),
            border: Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: CupertinoIcons.timer,
              title: '还没有模考记录',
              message: '暂无数据，从一次模考或错题开始',
            ),
          ),
        ],
      ),
    );
  }
}
