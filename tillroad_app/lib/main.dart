import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show FlutterError, FlutterErrorDetails, FlutterExceptionHandler;

import 'api/api_client.dart' show ApiClient;
import 'config/api_config.dart';
import 'config/app_info.dart';
import 'logging/app_logger.dart';
import 'logging/nav_observer.dart';
import 'pages/defects_page.dart';
import 'pages/home_page.dart';
import 'pages/mock_page.dart';
import 'pages/review_page.dart';
import 'pages/verify_page.dart';
import 'pages/api_token_page.dart';
import 'theme/app_theme.dart';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeApiToken();
  // 日志初始化要尽可能早：越早接上，越不容易丢掉启动阶段的异常。
  await AppLogger.instance.init();
  _installErrorHandlers();
  if (!kUseMock) {
    unawaited(_prewarm());
  }
  runApp(const TillRoadApp());
  AppLogger.instance.info(
    'APP',
    '启动 $kAppName v$kAppVersion（API=$kApiBaseUrl，mock=$kUseMock）',
  );
}

/// 全局异常捕获（任务 B1）。
///
/// 两条链路必须都接：
///   - `FlutterError.onError`：框架内部的构建/布局/绘制异常（脏 ``Widget``、越界等）；
///   - `PlatformDispatcher.instance.onError`：**异步未捕获异常**（Future 里 `throw` 而
///     没人 `catch`），这类异常不会进入 `FlutterError`，release 包里表现就是「点了没反应」。
///
/// 「保留默认行为」的具体含义：
///   - debug：仍然 `FlutterError.presentError` 打红字，否则开发期看不到；
///   - release：**不**调 presentError（它只写控制台），也绝不弹框——我们的日志已经落盘，
///     用户可一键导出，比红屏有用得多。
void _installErrorHandlers() {
  final FlutterExceptionHandler? original = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    AppLogger.instance.error(
      'FLUTTER',
      details.exceptionAsString(),
      stackTrace: details.stack?.toString() ??
          details.context?.toString(),
    );
    // debug 下继续走框架默认输出（红屏/控制台），release 下安静记日志。
    original?.call(details);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    AppLogger.instance.error(
      'ASYNC',
      error.toString(),
      stackTrace: stack.toString(),
    );
    // 返回 true 表示「已处理」：不会再被引擎当成未捕获异常上抛（release 下会静默）。
    return true;
  };
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
      home: const ApiTokenGate(),
    );
  }
}

class ApiTokenGate extends StatefulWidget {
  const ApiTokenGate({super.key});

  @override
  State<ApiTokenGate> createState() => _ApiTokenGateState();
}

class _ApiTokenGateState extends State<ApiTokenGate> {
  @override
  Widget build(BuildContext context) {
    if (kUseMock || hasApiToken) return const RootTabs();
    return ApiTokenPage(onSaved: () => setState(() {}));
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
          BottomNavigationBarItem(icon: Icon(CupertinoIcons.home), label: '首页'),
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
          // 每个 Tab 的 Navigator 都挂一个观察者：底部切 Tab 不会重建 Navigator，
          // 但 push 详情页大多发生在单个 Tab 栈内，挂在这里就能覆盖。
          navigatorObservers: <NavigatorObserver>[
            LoggingNavigatorObserver(),
          ],
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
