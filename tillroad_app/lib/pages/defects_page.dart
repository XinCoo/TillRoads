import 'package:flutter/cupertino.dart';

import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 缺陷单页（FE-01 阶段只做空状态）
///
/// 后续 FE 里程碑会把这里换成按状态分组的列表
/// （DRAFT / ANALYZED / ACTION_DONE / V1 / V2 / V3 / REOPENED / CLOSED），
/// 且「ACTION_DONE 不等于 CLOSED」要在 UI 上明显区分。
class DefectsPage extends StatelessWidget {
  const DefectsPage({super.key});

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
            largeTitle: Text('缺陷单'),
            border: Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: CupertinoIcons.doc_text,
              title: '还没有缺陷单',
              message: '暂无数据，从一次模考或错题开始',
            ),
          ),
        ],
      ),
    );
  }
}
