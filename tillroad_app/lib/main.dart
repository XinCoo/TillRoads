import 'package:flutter/cupertino.dart';

import 'pages/defects_page.dart';
import 'pages/home_page.dart';
import 'pages/mock_page.dart';
import 'pages/review_page.dart';
import 'pages/verify_page.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const TillRoadApp());
}

/// 应用根组件
///
/// 刻意不使用 `MaterialApp`：
/// - 产品目标是 iOS 原生手感，Material 的 ripple / shared axis 转场
///   在动效规范（fe-11-audit-motion-spec.md）里明确禁止；
/// - 少一层 Material 依赖，`pubspec` 只留 `cupertino_icons`。
class TillRoadApp extends StatelessWidget {
  const TillRoadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      title: '题路',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const RootTabs(),
    );
  }
}

/// 底部五个 Tab 的容器
///
/// 用 `CupertinoTabScaffold` + `CupertinoTabBar`，
/// 而不是 Material 的 `BottomNavigationBar`：前者是 iOS 原生的
/// 标签栏行为（无 ripple、图标与文字垂直居中、选中态用主色而非高亮块）。
class RootTabs extends StatelessWidget {
  const RootTabs({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoTabScaffold(
      tabBar: CupertinoTabBar(
        backgroundColor: AppColors.card,
        activeColor: AppColors.accent,
        inactiveColor: AppColors.secondaryLabel,
        // iOS 标签栏顶部分割线，0.5px 物理像素
        border: const Border(
          top: BorderSide(color: AppColors.separator, width: 0.5),
        ),
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.home),
            label: '首页',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.doc_text),
            label: '缺陷单',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.check_mark_circled),
            label: '验证',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.timer),
            label: '模考',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.chart_bar),
            label: '复盘',
          ),
        ],
      ),
      tabBuilder: (BuildContext context, int index) {
        // 每个 Tab 一个独立的 CupertinoTabView（各自持有 Navigator），
        // 这样切换 Tab 不会丢失各页的滚动位置与导航栈。
        return CupertinoTabView(
          builder: (BuildContext context) {
            switch (index) {
              case 0:
                return const HomePage();
              case 1:
                return const DefectsPage();
              case 2:
                return const VerifyPage();
              case 3:
                return const MockPage();
              case 4:
                return const ReviewPage();
              default:
                return const HomePage();
            }
          },
        );
      },
    );
  }
}
