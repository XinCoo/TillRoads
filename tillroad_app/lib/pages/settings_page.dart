// 设置页（任务 D）。
//
// 为什么是独立页面而不是首页右上角两个图标：
//   诊断与日志都属于「出问题时才用」的低频入口，直接摊在首页 trailing 上，
//   常态使用时会一直占着导航栏空间，也让首页的动作区语义变模糊。
//   收进设置页后，首页只留一个齿轮，两个功能也终于有了说明文字的位置
//   （原来只有图标 + 无障碍标签，新用户看不出「文档图标」是导出日志）。
//
// 为什么只有 push 入口、不占底部 Tab：
//   设置是低频页面，占 Tab 会挤掉高频入口；它又必须能从「我的」和首页齿轮
//   两处进入，push 才能保证两个入口看到的是同一份代码。
//
// 清空类操作的口径（与 `lib/widgets/log_export_sheet.dart` 保持一致）：
//   · 「清空日志」= `AppLogger.instance.clearAll()`，即删落盘日志 + 清内存缓冲；
//   · 「清除本地缓存」= 日志 + 导出文件 + shared_preferences 里除 Token 外的键，
//     登录态保留；
//   · 「清除所有数据」= shared_preferences 全清（含 Token）+ 上面全部缓存，
//     然后把 Token 输入页推到根导航栈顶。

import 'dart:io' show Directory, FileSystemEntity, Platform;

import 'package:flutter/cupertino.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../config/app_info.dart';
import '../logging/app_logger.dart';
import '../logging/log_export.dart';
import '../theme/app_theme.dart';
import '../widgets/diagnose_dialog.dart';
import '../widgets/log_export_sheet.dart' show kLogExportIcon, kLogExportLabel;
import 'api_token_page.dart';

/// Token 在 shared_preferences 里的键名。
///
/// `lib/config/api_config.dart` 只暴露了读写函数、没有导出键名，而本页需要
/// 「枚举除 Token 外的所有键」来清缓存，只能在这里镜像一份。
/// 若将来 api_config 改了键名，这里的常量要同步（已写入遗留项）。
const String _kTokenPrefsKey = 'api_token';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.onSessionCleared});

  /// 「清除所有数据」成功后的回调，供 App 根部接管「重登」流程。
  ///
  /// 不传时的兜底是：把 [ApiTokenPage] 推到**根**导航栈顶并清空其余路由。
  /// 为什么不能只靠 `ApiTokenGate` 自己 rebuild：`--dart-define=API_TOKEN`
  /// 会让 `hasApiToken` 在编译期恒为 true，清掉本地 token 后它依然是 true，
  /// 门卫不会退回登录页。详见完成回报里的「需 main.dart 配合点」。
  final VoidCallback? onSessionCleared;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 账户分区展示用的当前 Token（脱敏后仅显示前 4 位）。
  String? _token = kApiToken;

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: <Widget>[
          // 本页由其他页面 push 进入，返回箭头由 `automaticallyImplyLeading`
          // 自动生成（`route.canPop` 为真时出现），不需要手写 leading。
          const CupertinoSliverNavigationBar(
            largeTitle: Text('设置'),
            border: Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          SliverToBoxAdapter(
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 24),
              child: Column(
                children: <Widget>[
                  _buildConnectionSection(),
                  _buildLogSection(),
                  _buildAccountSection(),
                  _buildDangerSection(),
                  _buildAboutSection(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 分区构建

  Widget _buildConnectionSection() {
    return CupertinoListSection.insetGrouped(
      header: _sectionHeader('连接与诊断'),
      backgroundColor: AppColors.groupedBackground,
      separatorColor: AppColors.separator,
      children: <Widget>[
        CupertinoListTile(
          leading: const Icon(kDiagnoseIcon, color: AppColors.accent),
          title: const Text(kDiagnoseLabel),
          subtitle: const Text(
            '后端连通性、延迟与 Token 校验',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
          trailing: const CupertinoListTileChevron(),
          onTap: () => showDiagnoseDialog(context),
        ),
        CupertinoListTile(
          leading: const Icon(CupertinoIcons.link, color: AppColors.accent),
          title: const Text('API 地址'),
          subtitle: Text(
            kApiBaseUrl,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
          // 只读：点开看完整地址（长 URL 在列表里会被截断），不提供编辑。
          onTap: () => _info(title: 'API 地址', message: kApiBaseUrl),
        ),
      ],
    );
  }

  Widget _buildLogSection() {
    final int entries = AppLogger.instance.entryCount;
    return CupertinoListSection.insetGrouped(
      header: _sectionHeader('日志'),
      backgroundColor: AppColors.groupedBackground,
      separatorColor: AppColors.separator,
      children: <Widget>[
        CupertinoListTile(
          leading: const Icon(kLogExportIcon, color: AppColors.accent),
          title: const Text('导出运行日志'),
          subtitle: Text(
            '$kLogExportLabel · 内存 $entries 条 · 已自动脱敏',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
          trailing: const CupertinoListTileChevron(),
          onTap: _exportLogs,
        ),
        CupertinoListTile(
          leading: const Icon(CupertinoIcons.trash, color: AppColors.accent),
          title: const Text('清空日志'),
          subtitle: const Text(
            '删除落盘日志并清空内存缓冲',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
          onTap: _clearLogs,
        ),
      ],
    );
  }

  Widget _buildAccountSection() {
    return CupertinoListSection.insetGrouped(
      header: _sectionHeader('账户'),
      backgroundColor: AppColors.groupedBackground,
      separatorColor: AppColors.separator,
      children: <Widget>[
        CupertinoListTile(
          leading: const Icon(CupertinoIcons.person, color: AppColors.accent),
          title: const Text('当前 Token'),
          additionalInfo: Text(
            _maskToken(_token),
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              color: AppColors.secondaryLabel,
            ),
          ),
        ),
        CupertinoListTile(
          leading: const Icon(
            CupertinoIcons.arrow_2_circlepath,
            color: AppColors.accent,
          ),
          title: const Text('切换 Token'),
          subtitle: const Text(
            '只保存在本机，不上传服务器',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
          trailing: const CupertinoListTileChevron(),
          onTap: _changeToken,
        ),
      ],
    );
  }

  Widget _buildDangerSection() {
    return CupertinoListSection.insetGrouped(
      header: _sectionHeader('危险操作'),
      backgroundColor: AppColors.groupedBackground,
      separatorColor: AppColors.separator,
      children: <Widget>[
        CupertinoListTile(
          leading: const Icon(
            CupertinoIcons.delete_left,
            color: AppColors.overdue,
          ),
          title: const Text(
            '清除本地缓存',
            style: TextStyle(fontFamily: kFontFamily, color: AppColors.overdue),
          ),
          subtitle: const Text(
            '题目与日志的本地副本，保留登录态',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
          onTap: _clearLocalCache,
        ),
        CupertinoListTile(
          leading: const Icon(
            CupertinoIcons.exclamationmark_triangle,
            color: AppColors.overdue,
          ),
          title: const Text(
            '清除所有数据',
            style: TextStyle(fontFamily: kFontFamily, color: AppColors.overdue),
          ),
          subtitle: const Text(
            '本地数据全清并退出登录',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
          onTap: _wipeAll,
        ),
      ],
    );
  }

  Widget _buildAboutSection() {
    return CupertinoListSection.insetGrouped(
      header: _sectionHeader('关于'),
      backgroundColor: AppColors.groupedBackground,
      separatorColor: AppColors.separator,
      footer: Text(
        '$kAppName · 本地日志不包含 Token 与完整用户 ID',
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 12,
          color: AppColors.secondaryLabel,
        ),
      ),
      children: <Widget>[
        CupertinoListTile(
          leading: const Icon(
            CupertinoIcons.info_circle,
            color: AppColors.accent,
          ),
          title: const Text('版本'),
          additionalInfo: Text(
            kAppVersion,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              color: AppColors.secondaryLabel,
            ),
          ),
        ),
        CupertinoListTile(
          leading: const Icon(
            CupertinoIcons.doc_plaintext,
            color: AppColors.accent,
          ),
          title: const Text('开源协议'),
          trailing: const CupertinoListTileChevron(),
          onTap: () => _info(title: '开源协议', message: '后续补充'),
        ),
        CupertinoListTile(
          leading: const Icon(
            CupertinoIcons.lock_shield,
            color: AppColors.accent,
          ),
          title: const Text('隐私政策'),
          trailing: const CupertinoListTileChevron(),
          onTap: () => _info(title: '隐私政策', message: '后续补充'),
        ),
      ],
    );
  }

  Widget _sectionHeader(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: kFontFamily,
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: AppColors.secondaryLabel,
      ),
    );
  }

  // ------------------------------------------------------------ 具体功能实现

  /// 导出运行日志。
  ///
  /// 确认文案、脱敏说明、分享参数刻意与 `showLogActionsSheet` 里的
  /// `_runExport` 完全一致 —— 那个函数是私有的，本页没法复用，
  /// 只能镜像；两边若改动需同步（已写入遗留项）。
  Future<void> _exportLogs() async {
    final bool ok = await _confirm(
      title: '导出运行日志',
      message: '日志已脱敏，不含 token 和完整用户 ID，可放心发送。\n'
          '文件还可能包含：应用版本、系统版本、设备主机名、API 地址、'
          '最近 3 天的请求记录与异常信息。',
      confirmText: '继续导出',
    );
    if (!ok || !mounted) return;

    try {
      final LogExportResult result = await exportLogs();
      if (!mounted) return;
      // Android 上 share_plus 会把文件复制进自己的 cache 再经 FileProvider
      // 授权给目标 App，因此这里传原始路径即可。
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(result.file.path)],
          subject: '题路运行日志',
          text: '题路运行日志（${result.sizeLabel}，已脱敏）',
        ),
      );
      if (!mounted) return;
      await _info(
        title: '日志已生成',
        message: '${result.lineCount} 行 · ${result.sizeLabel}\n${result.file.path}',
      );
    } catch (e) {
      if (!mounted) return;
      AppLogger.instance.error('EXPORT', '导出失败：$e');
      await _info(
        title: '导出失败',
        message: '$e\n\n可先「清空日志」再重试；若仍失败，请把这条提示反馈给开发者。',
      );
    }
  }

  /// 清空日志：落盘文件 + 内存缓冲。
  Future<void> _clearLogs() async {
    final bool ok = await _confirm(
      title: '清空日志',
      message: '将删除所有已落盘的日志文件并清空内存缓冲。此操作不可撤销。',
      confirmText: '清空',
      destructive: true,
    );
    if (!ok || !mounted) return;

    final int removed = await AppLogger.instance.clearAll();
    if (!mounted) return;
    await _info(title: '已清空', message: '删除了 $removed 个日志文件。');
  }

  /// 清除本地缓存：日志 + 导出文件 + 非 Token 的本地配置。
  ///
  /// 「题目缓存」本轮仓库里还没有实体目录（全仓库只有日志目录），
  /// 因此实际能清的是日志与导出文件；将来加题库缓存时把目录补进
  /// `_purgeCacheDirectories` 即可。
  Future<void> _clearLocalCache() async {
    final bool ok = await _confirm(
      title: '清除本地缓存',
      message: '将清除本地缓存的题目和日志，不影响云端数据',
      confirmText: '清除',
      destructive: true,
    );
    if (!ok || !mounted) return;

    int removedFiles = 0;
    try {
      removedFiles += await AppLogger.instance.clearAll();
    } catch (e) {
      AppLogger.instance.warn('CLEAR', '清空日志失败：$e');
    }
    removedFiles += await _purgeCacheDirectories();
    final int removedKeys = await _removeCachePreferences();
    if (!mounted) return;
    await _info(
      title: '缓存已清除',
      message: '删除 $removedFiles 个缓存文件'
          '${removedKeys > 0 ? '、$removedKeys 项本地配置' : ''}；'
          '登录状态与 Token 已保留。',
    );
  }

  /// 清除所有数据：shared_preferences 全清（含 Token）+ 全部本地缓存，
  /// 然后把 Token 输入页推到根导航栈顶。
  Future<void> _wipeAll() async {
    final bool ok = await _confirm(
      title: '清除所有数据',
      message: '将清除本地所有数据并退出登录，云端数据不受影响。此操作不可撤销',
      confirmText: '全部清除',
      destructive: true,
    );
    if (!ok || !mounted) return;

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    try {
      await AppLogger.instance.clearAll();
    } catch (e) {
      AppLogger.instance.warn('CLEAR', '清空日志失败：$e');
    }
    await _purgeCacheDirectories();
    // prefs 已经清过键，这里再走一次公开 API 是为了把 api_config 里的
    // 内存副本 `_apiToken` 也置空（否则本进程内还会带着旧 token 发请求）。
    await saveApiToken('');
    if (!mounted) return;
    setState(() => _token = null);

    if (widget.onSessionCleared != null) {
      widget.onSessionCleared!();
      return;
    }

    // 兜底：整棵根导航栈换成 Token 输入页。必须用 rootNavigator —— 设置页
    // 本身在 Tab 的嵌套 Navigator 里，只在 Tab 栈内 push 会被底部 TabBar 挡住。
    final NavigatorState rootNav = Navigator.of(context, rootNavigator: true);
    await rootNav.pushAndRemoveUntil<void>(
      appRoute<void>(
        context,
        // 保存成功后没有可回退的页面，`maybePop` 是安全空操作；
        // 真正的「回到主界面」由 main.dart 的 ApiTokenGate 重建接管。
        ApiTokenPage(onSaved: () => rootNav.maybePop()),
      ),
      (Route<dynamic> route) => false,
    );
  }

  /// 切换 Token：弹窗输入 → `saveApiToken` → 刷新本页展示。
  Future<void> _changeToken() async {
    final String? token = await showCupertinoDialog<String>(
      context: context,
      builder: (BuildContext ctx) => const _TokenDialog(),
    );
    if (token == null || token.isEmpty || !mounted) return;

    await saveApiToken(token);
    if (!mounted) return;
    setState(() => _token = kApiToken);
    await _info(title: 'Token 已更新', message: '后续请求将使用新的 Token。');
  }

  // ------------------------------------------------------------ 清理实现细节

  /// 删掉 `tillroad/export`（日志导出的落盘目录）下的文件。
  ///
  /// `AppLogger.instance.clearAll()` 只清 `tillroad/logs`，导出目录不归它管，
  /// 所以缓存清理要单独收一遍，否则「清缓存」之后导出文件还在。
  Future<int> _purgeCacheDirectories() async {
    final String sep = Platform.pathSeparator;
    final Directory exportDir = Directory(
      '${Directory.systemTemp.path}${sep}tillroad${sep}export',
    );
    int removed = 0;
    if (!exportDir.existsSync()) return removed;
    try {
      await for (final FileSystemEntity entity in exportDir.list()) {
        try {
          await entity.delete(recursive: true);
          removed++;
        } catch (e) {
          AppLogger.instance.warn('CLEAR', '缓存文件删除失败：${entity.path} · $e');
        }
      }
    } catch (e) {
      AppLogger.instance.warn('CLEAR', '缓存目录遍历失败：$e');
    }
    return removed;
  }

  /// 删除 shared_preferences 里除 Token 之外的键（当前仓库只有 api_token，
  /// 这里按「枚举全部键再排除」实现，将来加了别的缓存键也不用改代码）。
  Future<int> _removeCachePreferences() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> keys = prefs
        .getKeys()
        .where((String key) => key != _kTokenPrefsKey)
        .toList();
    for (final String key in keys) {
      await prefs.remove(key);
    }
    return keys.length;
  }

  // -------------------------------------------------------------- 弹窗与工具

  /// 二次确认弹窗。`CupertinoAlertDialog` 内部把字体硬编码成
  /// `CupertinoSystemText` 且没有 textStyle 参数，所以每个 Text 都要显式带
  /// `fontFamily: kFontFamily`。
  Future<bool> _confirm({
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

  /// 结果提示弹窗（单按钮）。
  Future<void> _info({required String title, required String message}) async {
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

  /// Token 脱敏：只露前 4 位。
  String _maskToken(String? token) {
    final String value = (token ?? '').trim();
    if (value.isEmpty) return '未设置';
    if (value.length <= 4) return '****';
    return '${value.substring(0, 4)}****';
  }
}

/// 「切换 Token」弹窗。
///
/// 单独做成 StatefulWidget 只为一件事：`TextEditingController` 必须有人
/// dispose。放在 `_SettingsPageState` 里会因为弹窗反复开关而泄漏。
class _TokenDialog extends StatefulWidget {
  const _TokenDialog();

  @override
  State<_TokenDialog> createState() => _TokenDialogState();
}

class _TokenDialogState extends State<_TokenDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text(
        '切换 Token',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Token 只保存在本机，不会上传到任何服务器。',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            CupertinoTextField(
              controller: _controller,
              autofocus: true,
              obscureText: true,
              placeholder: '贴入新的 API Token',
              placeholderStyle: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                color: AppColors.tertiaryLabel,
              ),
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                color: AppColors.label,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.groupedBackground,
                borderRadius: BorderRadius.circular(AppRadii.chip),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(fontFamily: kFontFamily)),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: _submit,
          child: const Text('保存', style: TextStyle(fontFamily: kFontFamily)),
        ),
      ],
    );
  }
}
