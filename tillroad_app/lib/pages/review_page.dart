import 'package:flutter/cupertino.dart';

import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 复盘页（FE-01 阶段只做空状态）
///
/// 后端 BE-06 已提供日 / 周 / 月复盘快照（metrics 六项），
/// 后续 FE 里程碑接上后这里展示周期选择器 + 指标卡片。
class ReviewPage extends StatelessWidget {
  const ReviewPage({super.key});

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
            largeTitle: Text('复盘'),
            border: Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: CupertinoIcons.chart_bar,
              title: '还没有复盘记录',
              message: '暂无数据，从一次模考或错题开始',
            ),
          ),
        ],
      ),
    );
  }
}
