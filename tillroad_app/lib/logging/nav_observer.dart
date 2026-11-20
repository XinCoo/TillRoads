// 页面跳转日志（任务 B4）。
//
// 为什么用 `NavigatorObserver` 而不是在每个 `Navigator.push` 处手写日志：
//   全项目有 15 处 push/pushReplacement，逐处埋点既啰嗦又容易漏；
//   `NavigatorObserver` 挂在 `CupertinoTabView` 上一处搞定，且天然覆盖
//   ActionSheet / 全屏弹层这些非 push 场景之外的路径。
//
// 记录粒度刻意收窄：
//   - 只记**路由名或类型名**，不记参数对象 —— 路由参数里可能带题干文本（用户输入）；
//   - 详情类页面会在 `routeName` 里带上业务 ID，ID 会被 `sanitizeLogText` 脱敏成 `1111****`。

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

import 'app_logger.dart';

/// 把 Navigator 事件写成 `[NAV]` 日志。
class LoggingNavigatorObserver extends NavigatorObserver {
  LoggingNavigatorObserver();

  String _describe(Route<dynamic>? route) {
    if (route == null) return 'unknown';
    // `settings.name` 优先：显式命名的路由最能说明「跳到了哪」。
    final String? name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    // 否则退化为类型名。`MaterialPageRoute` 之类的框架类名对排查没意义，
    // 但本项目全部用 `appRoute`（CupertinoPageRoute / PageRouteBuilder），
    // 真正的页面类型在泛型参数里拿不到，只能靠 build 时的 widget 名补位，
    // 所以这里再用 `route.settings.arguments` 里约定的字符串（若页面传了）。
    final Object? args = route.settings.arguments;
    if (args is String && args.isNotEmpty) return '${route.runtimeType}($args)';
    return '${route.runtimeType}';
  }

  void _log(String action, Route<dynamic>? route, Route<dynamic>? previous) {
    // release 也记：用户报障时「点进哪个页面」是最基础的上下文。
    // 但只在 debug 构建保留类型名的完整形式，release 只留动作本身（减少噪音）。
    final String target = _describe(route);
    final String from = previous == null ? '-' : _describe(previous);
    AppLogger.instance.info(
      'NAV',
      kDebugMode ? '$action $target ← $from' : '$action $target',
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _log('push', route, previousRoute);
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _log('pop', route, previousRoute);
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _log('replace', newRoute, oldRoute);
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}
