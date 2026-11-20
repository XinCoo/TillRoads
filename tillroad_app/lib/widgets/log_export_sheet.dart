// 日志入口 UI（任务 D）。
//
// 为什么是「一个图标 + ActionSheet」而不是独立设置页：
//   本项目没有设置页（`lib/pages/` 下没有 settings），而为了一个导出功能新造
//   一个设置页会引入导航层级和空页面——对「用户遇到问题时才用」的工具属性来说，
//   藏两层反而是缺陷。放在首页大标题右侧，出问题的人一眼能找到。
//
// 交互顺序刻意是「先说明再导出」：
//   日志里虽然已脱敏，但用户有权在发送前知道「文件里有什么、没有什么」。
//   确认弹窗放在分享**之前**，点了「继续」才生成文件 —— 否则用户点一下取消就白写一个文件。

import 'package:flutter/cupertino.dart';
import 'package:share_plus/share_plus.dart';

import '../logging/app_logger.dart';
import '../logging/log_export.dart';
import '../theme/app_theme.dart';

/// 首页右上角「运行日志」按钮的图标。
const IconData kLogExportIcon = CupertinoIcons.doc_text;

/// 首页右上角按钮的无障碍标签。
const String kLogExportLabel = '运行日志';

/// 弹出「导出日志 / 清空日志 / 取消」菜单。
Future<void> showLogActionsSheet(BuildContext context) async {
  final _LogAction? action = await showCupertinoModalPopup<_LogAction>(
    context: context,
    builder: (BuildContext ctx) => CupertinoActionSheet(
      title: const Text(
        '运行日志',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      message: const Text(
        '用于把真机上的问题反馈给开发者。\n'
        '已自动脱敏：不含 token、不含完整用户 ID、不含题干与答案。',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 13,
          color: AppColors.secondaryLabel,
        ),
        textAlign: TextAlign.center,
      ),
      actions: <Widget>[
        CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(_LogAction.export),
          child: const Text(
            '导出日志',
            style: TextStyle(fontFamily: kFontFamily),
          ),
        ),
        CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.of(ctx).pop(_LogAction.clear),
          child: const Text(
            '清空日志',
            style: TextStyle(fontFamily: kFontFamily),
          ),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(ctx).pop(),
        child: const Text(
          '取消',
          style: TextStyle(fontFamily: kFontFamily, fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );

  if (!context.mounted || action == null) return;
  switch (action) {
    case _LogAction.export:
      await _runExport(context);
    case _LogAction.clear:
      await _runClear(context);
  }
}

enum _LogAction { export, clear }

Future<void> _runExport(BuildContext context) async {
  // ① 先讲清楚文件里有什么，用户确认后才真的生成。
  final bool ok = await _confirm(
    context,
    title: '导出运行日志',
    message: '日志已脱敏，不含 token 和完整用户 ID，可放心发送。\n'
        '文件还可能包含：应用版本、系统版本、设备主机名、API 地址、'
        '最近 3 天的请求记录与异常信息。',
    confirmText: '继续导出',
  );
  if (!ok || !context.mounted) return;

  try {
    final LogExportResult result = await exportLogs();
    if (!context.mounted) return;

    // ② 系统分享面板。Android 上 share_plus 会把文件复制到自己的 cache 目录，
    //    由 FileProvider 授权给目标 App，因此这里传原路径即可。
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(result.file.path)],
        subject: '题路运行日志',
        text: '题路运行日志（${result.sizeLabel}，已脱敏）',
      ),
    );
    if (!context.mounted) return;

    // ③ 分享面板关闭后给一个可复制的落盘位置：某些 ROM 的分享目标会失败，
    //    用户仍能凭路径自行取文件。
    await _info(
      context,
      title: '日志已生成',
      message: '${result.lineCount} 行 · ${result.sizeLabel}\n'
          '${result.file.path}',
    );
  } catch (e) {
    if (!context.mounted) return;
    AppLogger.instance.error('EXPORT', '导出失败：$e');
    await _info(
      context,
      title: '导出失败',
      message: '$e\n\n可先「清空日志」再重试；若仍失败，请把这条提示反馈给开发者。',
    );
  }
}

Future<void> _runClear(BuildContext context) async {
  final bool ok = await _confirm(
    context,
    title: '清空日志',
    message: '将删除所有已落盘的日志文件并清空内存缓冲。此操作不可撤销。',
    confirmText: '清空',
    destructive: true,
  );
  if (!ok || !context.mounted) return;

  final int removed = await AppLogger.instance.clearAll();
  if (!context.mounted) return;
  await _info(context, title: '已清空', message: '删除了 $removed 个日志文件。');
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmText,
  bool destructive = false,
}) async {
  final bool? ok = await showCupertinoDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => CupertinoAlertDialog(
      title: Text(
        title,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          message,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ),
      actions: <Widget>[
        CupertinoDialogAction(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消', style: TextStyle(fontFamily: kFontFamily)),
        ),
        CupertinoDialogAction(
          isDestructiveAction: destructive,
          isDefaultAction: !destructive,
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            confirmText,
            style: const TextStyle(fontFamily: kFontFamily),
          ),
        ),
      ],
    ),
  );
  return ok ?? false;
}

Future<void> _info(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  await showCupertinoDialog<void>(
    context: context,
    builder: (BuildContext ctx) => CupertinoAlertDialog(
      title: Text(
        title,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          message,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 12,
            height: 1.4,
          ),
        ),
      ),
      actions: <Widget>[
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('好', style: TextStyle(fontFamily: kFontFamily)),
        ),
      ],
    ),
  );
}

/// 首页导航栏用的按钮（与 `_DiagnoseButton` 同样只用图标，省 trailing 空间）。
class LogExportButton extends StatelessWidget {
  const LogExportButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: kLogExportLabel,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        onPressed: onPressed,
        child: const Icon(
          kLogExportIcon,
          size: 22,
          color: AppColors.accent,
        ),
      ),
    );
  }
}

