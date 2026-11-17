import 'package:flutter/cupertino.dart';

import '../mock/home_mock.dart';

/// 设计令牌（Design Tokens）
///
/// 全部取自 iOS 系统色，避免自造色板与系统控件打架：
/// - `groupedBackground` = iOS 分组列表背景（systemGroupedBackground 浅色版）
/// - `card` = iOS 卡片背景
/// - `secondaryLabel` = iOS 次要文字（systemGray）
/// - 三态色严格按 fe-11-audit-motion-spec.md 与 FE-01 任务书的约定值
class AppColors {
  const AppColors._();

  static const Color groupedBackground = Color(0xFFF2F2F7);
  static const Color card = Color(0xFFFFFFFF);
  static const Color label = Color(0xFF1C1C1E);
  static const Color secondaryLabel = Color(0xFF8E8E93);
  static const Color tertiaryLabel = Color(0xFFC7C7CC);
  static const Color separator = Color(0xFFE5E5EA);
  static const Color accent = Color(0xFF007AFF);

  /// overdue `#FF3B30` / due_soon `#FF9500` / normal `#34C759`
  static const Color overdue = Color(0xFFFF3B30);
  static const Color dueSoon = Color(0xFFFF9500);
  static const Color normal = Color(0xFF34C759);

  /// 三态 → 颜色。用 switch 表达式穷举，新增枚举值时会编译报错，
  /// 避免像 `ConcurrenceMap[key]` 那样静默返回 null。
  static Color forUrgency(TaskUrgency urgency) => switch (urgency) {
    TaskUrgency.overdue => overdue,
    TaskUrgency.dueSoon => dueSoon,
    TaskUrgency.normal => normal,
  };

  /// 三态 → 中文短标签（用于任务卡右侧徽标）
  static String labelForUrgency(TaskUrgency urgency) => switch (urgency) {
    TaskUrgency.overdue => '已逾期',
    TaskUrgency.dueSoon => '临期',
    TaskUrgency.normal => '正常',
  };
}

/// 圆角与间距：卡片统一 16，页面左右留白 16
class AppRadii {
  const AppRadii._();

  static const double card = 16;
  static const double chip = 8;
}

class AppSpacing {
  const AppSpacing._();

  static const double page = 16;
  static const double cardGap = 12;
  static const double cardPadding = 16;
}

/// 动效时长
///
/// - `countdown`：倒计时数字变化，ease-in-out 250ms（任务书硬要求）
/// - `reduceMotion`：Reduce Motion 开启后所有动效统一 ≤200ms 淡入淡出
class AppDurations {
  const AppDurations._();

  static const Duration countdown = Duration(milliseconds: 250);
  static const Duration reduceMotion = Duration(milliseconds: 200);
}

/// iOS 弹簧：`SpringDescription.withDampingRatio(ratio: 0.85, stiffness: 220)`
///
/// 注意：`withDampingRatio` 的 `mass` 与 `stiffness` 都是 **required**，
/// 任务书只写了 stiffness 220，这里补 `mass: 1`（质量的单位基准，1 是标准值）。
/// 该构造函数内部要算 `sqrt(mass * stiffness)`，不是一个 const 表达式，
/// 所以只能声明为 `final` 而不能是 `const`。
final SpringDescription kPressSpring = SpringDescription.withDampingRatio(
  mass: 1,
  stiffness: 220,
  ratio: 0.85,
);

/// Cupertino 主题
///
/// 只覆盖会真正用到的几项：主色、分组背景、导航栏背景、
/// 以及大标题/导航标题字号（iOS 大标题 34pt bold，与系统一致）。
class AppTheme {
  const AppTheme._();

  static CupertinoThemeData light() {
    return const CupertinoThemeData(
      brightness: Brightness.light,
      primaryColor: AppColors.accent,
      scaffoldBackgroundColor: AppColors.groupedBackground,
      barBackgroundColor: Color(0xF2F7F7FA),
      textTheme: CupertinoTextThemeData(
        textStyle: TextStyle(
          fontSize: 17,
          color: AppColors.label,
          decoration: TextDecoration.none,
        ),
        navTitleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: AppColors.label,
          letterSpacing: -0.4,
          decoration: TextDecoration.none,
        ),
        navLargeTitleTextStyle: TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w700,
          color: AppColors.label,
          letterSpacing: 0.37,
          decoration: TextDecoration.none,
        ),
        tabLabelTextStyle: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}

/// 页面转场统一入口
///
/// 动效依据 fe-11-audit-motion-spec.md：
/// - 正常：`CupertinoPageRoute` —— 新页右滑入，旧页向左视差（iOS 原生约 30% 宽度），
///   不使用 Material 的共享轴（shared axis）转场，也不产生 ripple。
/// - Reduce Motion（`MediaQueryData.disableAnimations == true`）：
///   关闭视差与滑动，统一 200ms 淡入淡出（≤200ms 是硬上限）。
///
/// 需要 `context` 是因为 Reduce Motion 必须在构建路由时读取，
/// 而 `Navigator.push` 处一定能拿到 context。
Route<T> appRoute<T>(BuildContext context, Widget page) {
  final bool reduceMotion =
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  if (reduceMotion) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, _, _) => page,
      transitionDuration: AppDurations.reduceMotion,
      reverseTransitionDuration: AppDurations.reduceMotion,
      transitionsBuilder: (_, Animation<double> animation, _, Widget child) {
        // 纯透明度变化，不做位移/缩放，避免前庭不适
        return FadeTransition(opacity: animation, child: child);
      },
    );
  }

  return CupertinoPageRoute<T>(builder: (_) => page);
}
