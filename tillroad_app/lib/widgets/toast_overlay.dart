// 轻量顶部浮层提示（toast）。
//
// ── 为什么需要自己实现 ───────────────────────────────────────────────────
// 本工程刻意不依赖 Material 组件（`SnackBar` / `ScaffoldMessenger` 都在
// material.dart 里），而且全前端没有任何现成的 toast 组件。需求是
// 「顶部 toast 持续 3s」，所以这里用最轻的做法：
// `Overlay.of(context).insert(OverlayEntry(...))` 插一条顶部对齐的半透明圆角条，
// 定时器到点后 `entry.remove()`。
//
// ── 关键约束 ─────────────────────────────────────────────────────────────
//  ① 重复调用时必须先移除旧的 entry（否则两条会叠在一起，且旧的那条永远
//     不会被移除）。用一个 static OverlayEntry? 保存当前 entry。
//  ② 移除只能走 `entry.remove()`：`markNeedsBuild()` 不会把 entry 从
//     Overlay 里摘掉，只是重画 —— 那条提示会永远留在屏幕上。
//  ③ Timer 到点时页面可能已经 dispose：此时 `context` 已失效，直接
//     `entry.remove()`（OverlayEntry.remove 内部会校验 mounted），不要
//     再触碰 context。

import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../theme/app_theme.dart';

/// 当前正在显示的 toast entry（全局只允许一条）。
///
/// 用 static 而不是按 context 保存：toast 是「一次性提示」，同一次切换
/// 可能连续触发两个页面的提示（设置页切换 → 回到我的页再提示），
/// 静态字段天然保证「后来的顶掉先前的」。
OverlayEntry? _activeToastEntry;

/// 定时器：负责在 duration 之后移除当前 entry。
Timer? _activeToastTimer;

/// 在顶部显示一条轻提示（默认 3s 后自动消失）。
///
/// [message] 是要显示的短句；[duration] 控制停留时长。
/// 重复调用会替换掉正在显示的那条（不会叠加）。
///
/// 返回值是为了让调用方能主动 dismiss（例如页面即将 pop 时），
/// 一般不需要用。
void showAppToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 3),
}) {
  // 先撤掉旧的，避免叠加。
  _dismissToast();

  final OverlayState? overlay = Overlay.maybeOf(context);
  if (overlay == null) {
    // 没有 Overlay（例如页面已销毁）时静默忽略：toast 是锦上添花，
    // 不该因为它抛异常把切换流程打断。
    return;
  }

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (BuildContext ctx) => _ToastLayer(message: message),
  );
  _activeToastEntry = entry;
  overlay.insert(entry);

  _activeToastTimer = Timer(duration, () {
    // 到点：只移除 entry 本身，不依赖调用方的 context。
    _dismissToast();
  });
}

/// 立刻移除当前 toast（若没有则什么都不做）。
void dismissAppToast() => _dismissToast();

void _dismissToast() {
  _activeToastTimer?.cancel();
  _activeToastTimer = null;
  final OverlayEntry? entry = _activeToastEntry;
  _activeToastEntry = null;
  if (entry == null) return;
  // `remove()` 才是「从 Overlay 里摘掉」；markNeedsBuild 只会重画。
  entry.remove();
}

/// 顶部提示条本体。
///
/// 深色底 + 白字（`AppColors.label` 是深色文字，所以这里反过来用
/// 接近黑的底 + 近乎白的字），圆角 12，水平方向留出页边距。
class _ToastLayer extends StatelessWidget {
  const _ToastLayer({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      // 顶部安全区之下一点，避免压住状态栏/刘海。
      top: MediaQuery.of(context).padding.top + 12,
      left: 24,
      right: 24,
      child: IgnorePointer(
        child: Opacity(
          opacity: 0.85,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              // 黑色 0.85 透明感：深色底白字，不依赖 AppColors（那是浅色底）。
              color: const Color(0xD9000000),
              borderRadius: BorderRadius.circular(AppRadii.chip),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x1F000000),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                height: 1.35,
                color: Color(0xFFFFFFFF),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
