// 首启动引导页（m32036 任务 D：通知权限）。
//
// 为什么要在**第一次**启动时挡住用户要通知权限：
//   产品里唯一的「主动提醒」是验证窗口临期（V1 7 天 / V2 14 天 / V3 21 天）。
//   这类提醒如果没权限就完全静默，用户会觉得「这功能坏了」而不是「我没授权」。
//   而 Android 13+ 的 `POST_NOTIFICATIONS` 是运行时权限，只能在有上下文的时刻
//   弹系统框；第一次打开的引导页正是唯一合理的时机。
//
// 三条设计取舍：
//   ① **只出现一次**：`onboarding_done` 一置 true 就再也不出现，包括用户拒绝的情况。
//      任务书 D3 明确「拒绝后不重复弹窗」——反复弹是 Android 上最招人烦的反模式，
//      系统在用户拒绝两次后甚至不会再显示对话框。
//   ② **不做成多页**：一屏讲完。多页引导要有真实的教学内容才值得，而这里
//      只有一件事要说（允许通知），翻页只会稀释它。
//   ③ **「暂不开启」与「允许」视觉权重不同但不诱导**：主按钮是「允许」（实心），
//      次按钮是「暂不开启」（文字按钮），但不加「以后再说也没关系」之类的话术。
//
// 与 `settings_page.dart` 的分工：
//   本页只负责「首次引导 + 请求一次」；之后用户想开启只能去设置页的「权限」分区，
//   那里只展示状态 + `openAppSettings()`（系统设置），**不重复 request()**。

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// `shared_preferences` 里的「引导已完成」标记键。
///
/// 与 `lib/storage/log_migration.dart` 的 `log_migration_done` 同一套路：
/// 都是「只做一次的启动期动作」，用布尔标记而不是版本号 —— 这些动作
/// 一旦完成就永久完成，不需要随着版本重新执行。
const String kOnboardingDoneKey = 'onboarding_done';

/// 首启动引导是否已经完成。
Future<bool> isOnboardingDone() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kOnboardingDoneKey) ?? false;
}

/// 标记引导已完成（允许与暂不开启都要调）。
Future<void> markOnboardingDone() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kOnboardingDoneKey, true);
}

/// 仅供测试：清掉引导标记，让下一次启动重新走引导页。
Future<void> resetOnboardingForTest() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.remove(kOnboardingDoneKey);
}

/// 单屏引导页。
///
/// `onDone` 在用户做出选择后调用（无论允许还是拒绝），由调用方（`ApiTokenGate`）
/// 切到下一页。本页**不自己 push** —— 引导页隶属于根部切换而不是导航栈里的
/// 一个路由，否则用户返回手势会退回到引导页，形成死循环。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({required this.onDone, super.key});

  final VoidCallback onDone;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  /// 正在请求系统权限 —— 期间两个按钮都置灰，避免连点弹两次。
  bool _requesting = false;

  Future<void> _allowNotifications() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      // 结果不影响后续流程：允许就正常推送，拒绝就静默降级。
      // 这里**故意**不根据结果分支 —— 任务书 D2 要求「无论结果都置
      // onboarding_done=true 并进入 token 页」。
      await Permission.notification.request();
    } catch (_) {
      // 某些定制 ROM 上 request() 会抛平台异常。用户看到引导页就说明他已经
      // 做了选择，此时卡在引导页才是最差的结果，因此吞掉异常继续。
    }
    await _finish();
  }

  Future<void> _skip() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    await _finish();
  }

  Future<void> _finish() async {
    await markOnboardingDone();
    if (!mounted) return;
    // 轻触觉反馈：这一步是「一次性动作」，给一个确认感（与全局 PressableCard
    // 的 lightImpact 口径一致）。
    HapticFeedback.lightImpact();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 图标：直接用 App 自己的 1024 图标（白底无 alpha），
              // 外面套一层圆角卡片，避免与分组背景糊在一起。
              Center(
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x14000000),
                        blurRadius: 16,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/icons/app_icon.png',
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                '题路 TillRoad',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: AppColors.label,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '为了让验证窗口临期提醒正常工作，请允许通知权限。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 15,
                  height: 1.45,
                  color: AppColors.secondaryLabel,
                ),
              ),
              const SizedBox(height: 36),
              // 主按钮：允许通知（实心蓝）。
              CupertinoButton.filled(
                padding: const EdgeInsets.symmetric(vertical: 15),
                borderRadius: BorderRadius.circular(AppRadii.card),
                onPressed: _requesting ? null : _allowNotifications,
                child: _requesting
                    ? const CupertinoActivityIndicator(
                        radius: 9,
                        color: CupertinoColors.white,
                      )
                    : const Text(
                        '允许通知',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
              const SizedBox(height: 6),
              // 次按钮：暂不开启（纯文字，视觉权重明显低一档，但不做灰色死链）。
              CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 12),
                onPressed: _requesting ? null : _skip,
                child: Text(
                  '暂不开启',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 15,
                    color: AppColors.accent.withValues(
                      alpha: _requesting ? 0.4 : 1.0,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 说明「以后还能开」—— 这句话很重要：用户拒绝时最大的心理负担是
              // 「我是不是把这个功能永久废了」。给出路径就不会有这种顾虑。
              Text(
                '以后可以在「我的 → 设置 → 权限」里重新开启。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  height: 1.4,
                  color: AppColors.tertiaryLabel.withValues(
                    alpha: reduceMotion ? 1.0 : 0.9,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
