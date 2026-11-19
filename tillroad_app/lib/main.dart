import 'dart:async';

import 'package:flutter/cupertino.dart';

import 'api/api_client.dart' show ApiClient;
import 'config/api_config.dart';
import 'pages/defects_page.dart';
import 'pages/home_page.dart';
import 'pages/mock_page.dart';
import 'pages/review_page.dart';
import 'pages/verify_page.dart';
import 'theme/app_theme.dart';

void main() {
  // FE-07 E4：应用启动时顺带打一次 `GET /health` 预热 Neon。
  //
  // 为什么有用：Neon 免费版实例空闲会挂起（suspend），第一个请求要等它被唤醒，
  // 冷启动 20–40s。而这个唤醒是「一次性的」——只要有一个请求把它叫醒，后续就快了。
  //
  // 为什么**不阻塞** UI：`unawaited(...)` 把它甩到后台，首屏立刻渲染骨架屏。
  // 首页的三个数据请求会与这个预热请求并发；如果预热先到，它们就直接命中热连接；
  // 如果没先到也无所谓，反正三个请求各自有 15s 超时 + 逐卡片降级。
  //
  // 为什么不在 widget 里做：`main()` 比任何 widget 都早，能最大化预热收益；
  // 且失败时不该影响 UI（这里显式吞掉所有异常）。
  if (!kUseMock) {
    unawaited(_prewarm());
  }
  runApp(const TillRoadApp());
}

/// 预热后端连接：只发一次轻量请求，结果完全忽略。
///
/// 单独建一个 `ApiClient` 并在用完后立刻 `close()`，
/// 避免这个一次性请求占着页面（如首页）持有的连接池。
Future<void> _prewarm() async {
  final ApiClient client = ApiClient();
  final Stopwatch watch = Stopwatch()..start();
  try {
    await client.get('/health');
    watch.stop();
    debugPrint('[prewarm] GET /health 成功，耗时 ${watch.elapsedMilliseconds}ms');
  } catch (e) {
    watch.stop();
    // 预热失败是正常情况（后端没起 / 离线演示），不打扰用户
    debugPrint('[prewarm] GET /health 失败（${watch.elapsedMilliseconds}ms）：$e');
  } finally {
    client.close();
  }
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
///
/// FE-07 改为 `StatefulWidget` + `CupertinoTabController`：
/// 首页的「转缺陷单」快捷入口需要以代码切 Tab，而 `CupertinoTabScaffold`
/// 只有拿到 controller 才能被外部改选中项。
class RootTabs extends StatefulWidget {
  const RootTabs({super.key});

  @override
  State<RootTabs> createState() => _RootTabsState();
}

class _RootTabsState extends State<RootTabs> {
  final CupertinoTabController _controller = CupertinoTabController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 供首页快捷入口调用。用 `animateTo` 而不是直接改 `index`，
  /// 这样标签栏的高亮有个短过渡，与 iOS 行为一致。
  void _switchTab(int index) {
    if (index < 0 || index > 4) return;
    _controller.index = index;
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoTabScaffold(
      controller: _controller,
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
                return HomePage(onSwitchTab: _switchTab);
              case 1:
                return const DefectsPage();
              case 2:
                return const VerifyPage();
              case 3:
                return const MockPage();
              case 4:
                return const ReviewPage();
              default:
                return HomePage(onSwitchTab: _switchTab);
            }
          },
        );
      },
    );
  }
}
