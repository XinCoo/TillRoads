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

import 'dart:async' show unawaited;
import 'dart:io' show Directory;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart' show ApiClient, ApiException;
import '../config/api_config.dart';
import '../config/app_info.dart';
import '../logging/app_logger.dart';
import '../logging/log_export.dart';
import '../storage/app_dirs.dart';
import '../theme/app_theme.dart';
import '../services/export_location.dart'
    show ExportLocation, ExportPickResult;
import '../services/export_service.dart'
    show
        ExportException,
        ExportFailureKind,
        ExportResult,
        ExportService;
import '../utils/session.dart'
    show SwitchTokenResult, purgeCacheDirectories, switchApiToken;
import '../widgets/diagnose_dialog.dart';
import '../widgets/log_export_sheet.dart' show kLogExportIcon, kLogExportLabel;
import '../widgets/toast_overlay.dart';
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

  /// 云端删除进行中 —— 避免重复点、也让列表项可以置灰。
  bool _deleting = false;

  /// 通知权限状态。`null` = 还没读出来（首帧显示「检查中…」）。
  ///
  /// 用 `PermissionStatus` 而不是自定义枚举：`permission_handler` 的枚举已经
  /// 区分了 granted / denied / permanentlyDenied / restricted / limited，
  /// 自己再包一层只会把信息丢掉。
  PermissionStatus? _notifStatus;

  /// 日志目录路径（不在 build 里重复调 `AppDirs.logs()`，进页面读一次）。
  String _logDirLabel = '（尚未就绪）';

  /// ★ m32406：导出位置的展示名（未选时为「未设置，导出时选择」）。
  ///
  /// 存展示串而不是 token：设置页只负责「显示 + 更换」，token 的持久化读写
  /// 全在 `ExportLocation` 里，这里不该持有凭证类数据。
  String _exportDirLabel = '未设置，导出时选择';

  /// ★ m32406：导出进行中（防止连点重复弹 SAF 选择器 / 重复请求）。
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    // m32036：权限状态每次进页面重读 —— 用户可能刚从系统设置里改完再回来。
    unawaited(_loadPermissionState());
    unawaited(_loadLogDir());
    unawaited(_loadExportDir());
  }

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
                  // ★ m32406：数据管理（导出题库 + 导出位置）放在危险操作之前 ——
                  // 「导出」是保管手段，「删除」才是风险项，两者相邻但轻重不同。
                  _buildDataSection(),
                  _buildDangerSection(),
                  _buildPermissionSection(),
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
            '删除我的所有数据',
            style: TextStyle(fontFamily: kFontFamily, color: AppColors.overdue),
          ),
          subtitle: const Text(
            '云端与本机全部删除，不可恢复',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
          // 删除进行中时置灰，避免重复提交（云端要跑 9 条 UPDATE）。
          onTap: _deleting ? null : _deleteAllData,
        ),
      ],
    );
  }

  /// 「权限」分区（m32036 任务 E）。
  ///
  /// 两条设计取舍：
  ///   ① **不在这里 request()**：任务书 E2 明确「不重复申请」。Android 上反复
  ///      request 会被系统永久拒绝（permanentlyDenied），以后连对话框都不弹，
  ///      反而把用户彻底锁在无权限状态。所以这里只展示状态 + 跳系统设置。
  ///   ② **日志位置不给「打开目录」只给「复制路径」**：直接打开文件管理器
  ///      需要 `open_filex` 之类的额外依赖（本轮禁止），而且 Android 10+ 对
  ///      路径的访问限制很多；复制路径后用户可自己粘到文件管理器/发给客服。
  Widget _buildPermissionSection() {
    final PermissionStatus? status = _notifStatus;
    final String statusLabel = switch (status) {
      null => '检查中…',
      PermissionStatus.granted ||
      PermissionStatus.limited ||
      PermissionStatus.provisional =>
        '已开启',
      PermissionStatus.permanentlyDenied => '已拒绝（需去系统设置）',
      PermissionStatus.restricted => '受系统限制',
      _ => '已拒绝',
    };
    final bool granted = status == PermissionStatus.granted ||
        status == PermissionStatus.limited ||
        status == PermissionStatus.provisional;
    return CupertinoListSection.insetGrouped(
      header: _sectionHeader('权限'),
      backgroundColor: AppColors.groupedBackground,
      separatorColor: AppColors.separator,
      children: <Widget>[
        CupertinoListTile(
          leading: Icon(
            granted
                ? CupertinoIcons.bell_fill
                : CupertinoIcons.bell_slash,
            color: granted ? AppColors.normal : AppColors.secondaryLabel,
          ),
          title: const Text('通知权限'),
          subtitle: Text(
            statusLabel,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: granted ? AppColors.normal : AppColors.secondaryLabel,
            ),
          ),
          trailing: const CupertinoListTileChevron(),
          // 不 request，只跳系统设置 —— 系统设置里用户可以自己改，
          // 改完回到本页时 initState 已经读过一次，但用户往往只 pop 回来，
          // 所以这里用 `_openSystemSettings` 里带一次重读。
          onTap: _openSystemSettings,
        ),
        CupertinoListTile(
          leading: const Icon(
            CupertinoIcons.folder,
            color: AppColors.accent,
          ),
          title: const Text('日志位置'),
          subtitle: Text(
            _logDirLabel,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
          trailing: const CupertinoListTileChevron(),
          onTap: _copyLogDir,
        ),
      ],
    );
  }
  /// 「数据管理」分区（m32406 任务 D3）。
  ///
  /// 两条：①「导出题库」快捷入口（与题库管理页右上角「⋯ → 导出题库」同一条链路）；
  /// ②「导出位置」显示当前目录友好名 + 「更换」按钮（调 pickAndSaveDirectory）。
  ///
  /// 没选过目录时 subtitle 显示「未设置，导出时选择」而不是空白 —— 空白会让用户
  /// 以为功能坏了，而不是「还没选」。
  Widget _buildDataSection() {
    final bool hasDir = _exportDirLabel != '未设置，导出时选择';
    return CupertinoListSection.insetGrouped(
      header: _sectionHeader('数据管理'),
      backgroundColor: AppColors.groupedBackground,
      separatorColor: AppColors.separator,
      children: <Widget>[
        CupertinoListTile(
          leading: const Icon(
            CupertinoIcons.arrow_up_doc,
            color: AppColors.accent,
          ),
          title: const Text('导出题库'),
          subtitle: const Text(
            '存成 .tillroad 压缩文件（不包含练习记录与缺陷单）',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
          // 导出中置灰，同时把 subtitle 换成进度文案式的提示（不改变布局高度）。
          trailing: _exporting
              ? const CupertinoActivityIndicator(radius: 7)
              : const CupertinoListTileChevron(),
          onTap: _exporting ? null : _exportQuestions,
        ),
        CupertinoListTile(
          leading: const Icon(
            CupertinoIcons.folder_badge_plus,
            color: AppColors.accent,
          ),
          title: const Text('导出位置'),
          subtitle: Text(
            _exportDirLabel,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
          // 只给「更换」不给「清除」：Android 上遗留一个未使用的持久化 URI
          // 会占 128 个名额中的一个，而「更换」内部已经 release 旧 token 了。
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(36, 36),
            onPressed: _exporting ? null : _changeExportDir,
            child: Text(
              hasDir ? '更换' : '选择',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 15,
                color: AppColors.accent,
              ),
            ),
          ),
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

  /// 删除我的所有数据（m18680 B1）：云端软删 + 本机全清，然后退回 Token 页。
  ///
  /// 为什么要输入「确认删除」而不是普通二次确认：
  ///   它同时清云端（缺陷单 / 模考 / 复盘 / 自己导入的题），不可撤销，
  ///   代价远高于「清除本地缓存」；一次误触就要重录几十张缺陷单。
  ///   要求手打四个字能拦住绝大多数误触，且不需要用户理解技术细节。
  ///
  /// 为什么要先调云端再清本地：
  ///   云端请求需要 Token；先把本地 Token 清掉就删不了云端了。
  ///   云端失败时**不清本地**并如实报错 —— 不让用户以为删干净了（这正是本轮要修的旧问题）。
  Future<void> _deleteAllData() async {
    final bool? ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => const _DeleteAllDialog(),
    );
    if (ok != true || !mounted) return;

    setState(() => _deleting = true);
    int total = 0;
    Map<String, Object?>? deleted;
    try {
      final Object? raw = await ApiClient().delete('/users/$kDemoUserId/data');
      final Map<String, Object?> body =
          raw is Map<String, Object?> ? raw : const <String, Object?>{};
      total = (body['total'] as num?)?.toInt() ?? 0;
      final Object? d = body['deleted'];
      deleted = d is Map<String, Object?> ? d : null;
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      AppLogger.instance.error('CLEAR', '删除云端数据失败：${e.message}（status=${e.statusCode}）');
      await _info(
        title: '云端删除失败',
        message: e.isNetworkError
            ? '无法连接后端，云端数据未删除，本机数据也没有清。请联网后重试。'
            : '服务端返回 ${e.statusCode}：${e.message}\n\n云端数据未删除，本机数据也没有清。',
      );
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      await _info(title: '云端删除失败', message: '删除过程出错：$e\n\n本机数据未清。');
      return;
    }

    // 云端已删 -> 再清本机（顺序不能反，见上面的注释）。
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    try {
      await AppLogger.instance.clearAll();
    } catch (e) {
      AppLogger.instance.warn('CLEAR', '清空日志失败：$e');
    }
    await _purgeCacheDirectories();
    await saveApiToken('');
    if (!mounted) return;
    setState(() {
      _token = null;
      _deleting = false;
    });

    final String detail = deleted == null
        ? '共删除 $total 行云端数据。'
        : '线索 ${deleted['defect_tickets'] ?? 0} 张 / 动作 ${deleted['actions'] ?? 0} 条 / '
            '验证 ${deleted['verifications'] ?? 0} 条 / 自导入题 ${deleted['questions'] ?? 0} 道 / '
            '模考 ${deleted['mock_exams'] ?? 0} 次 / 复盘 ${deleted['review_cycles'] ?? 0} 份。';
    await _info(
      title: '已删除',
      message: '云端与本地数据已删除，共 $total 行。\n$detail\n\n公共题库不受影响，已退出登录。',
    );
    if (!mounted) return;

    if (widget.onSessionCleared != null) {
      widget.onSessionCleared!();
      return;
    }

    final NavigatorState rootNav = Navigator.of(context, rootNavigator: true);
    await rootNav.pushAndRemoveUntil<void>(
      appRoute<void>(
        context,
        ApiTokenPage(onSaved: () => rootNav.maybePop()),
      ),
      (Route<dynamic> route) => false,
    );
  }

  /// 切换 Token：弹窗输入 → 校验新 token → 落盘 → 清旧账号残留 → 刷新本页展示。
  ///
  /// 与「我的」页共用 [switchApiToken]（lib/utils/session.dart），两边行为与文案一致：
  ///   · 新 token 无效 → 抛错，弹窗明确报错，旧 token 继续有效；
  ///   · 新 token 有效 → 已切换至 {displayName}。
  Future<void> _changeToken() async {
    final String? token = await showCupertinoDialog<String>(
      context: context,
      builder: (BuildContext ctx) => const _TokenDialog(),
    );
    if (token == null || token.isEmpty || !mounted) return;

    try {
      final SwitchTokenResult result = await switchApiToken(token);
      if (!mounted) return;
      setState(() => _token = kApiToken);
      showAppToast(context, '已切换至 ${result.displayName}');
    } on ApiException catch (e) {
      if (!mounted) return;
      AppLogger.instance.error('TOKEN', '切换 Token 失败：${e.message}（status=${e.statusCode}）');
      await _info(
        title: '切换失败',
        message: '${e.message}\n\n原 Token 仍然有效，本机数据未做任何更改。',
      );
    } catch (e) {
      if (!mounted) return;
      AppLogger.instance.error('TOKEN', '切换 Token 出错：$e');
      await _info(
        title: '切换失败',
        message: '切换过程出错：$e\n\n原 Token 仍然有效，本机数据未做任何更改。',
      );
    }
  }

  // ------------------------------------------------------------ 清理实现细节

  /// 清掉缓存目录（导出临时文件 + 日志/数据目录）。
  ///
  /// m32036 起这里**不再自己拼路径**，而是委托给 `utils/session.dart` 的
  /// `purgeCacheDirectories()`：那个函数同时覆盖旧 `systemTemp/tillroad`
  /// （升级前残留导出文件）与新 `AppDirs` 根目录（m32036 起的日志/数据）。
  /// 两边维护两份路径拼接的话，迟早会出现「点清缓存但新目录没清」——
  /// 这个 bug 在 m32036 就真的发生过一次（当时只改了日志写入器）。
  Future<int> _purgeCacheDirectories() => purgeCacheDirectories();

  // ------------------------------------------------------------ 权限与目录

  /// 读一次通知权限状态（m32036 任务 E）。
  ///
  /// 失败不报错：权限只是说明信息，读不到就停在「检查中…」，
  /// 不应该让整个设置页变成错误页。
  Future<void> _loadPermissionState() async {
    try {
      final PermissionStatus status = await Permission.notification.status;
      if (!mounted) return;
      setState(() => _notifStatus = status);
    } catch (e) {
      AppLogger.instance.warn('PERM', '读取通知权限状态失败：$e');
    }
  }

  /// 取一次日志目录路径（不在 build 里调，避免每次重建都碰一次磁盘）。
  Future<void> _loadLogDir() async {
    try {
      final Directory? dir = await AppDirs.logs();
      if (!mounted) return;
      setState(() => _logDirLabel = AppDirs.describe(dir));
    } catch (e) {
      AppLogger.instance.warn('PERM', '读取日志目录失败：$e');
    }
  }

  /// 跳系统设置（任务书 E2：不重复 request，只引导）。
  ///
  /// 从系统设置返回后重读一次状态：`openAppSettings` 只是把 App 挂到系统页面，
  /// 用户改完权限回来时本页不会重建（settings 页在整个导航栈里一直活到 pop），
  /// 所以必须在这里留一个「回来后刷新」的入口。
  Future<void> _openSystemSettings() async {
    try {
      await openAppSettings();
    } catch (e) {
      AppLogger.instance.warn('PERM', '打开系统设置失败：$e');
      if (mounted) {
        _info(title: '无法打开系统设置', message: '请手动进入系统设置 → 应用 → 题路 → 通知 中开启。');
      }
      return;
    }
    if (!mounted) return;
    await _loadPermissionState();
  }

  /// 复制日志目录路径到剪贴板。
  Future<void> _copyLogDir() async {
    final String path = _logDirLabel;
    if (path == '（尚未就绪）') {
      _info(title: '日志目录不可用', message: '还没有找到可写的日志目录，可能存储空间不足。');
      return;
    }
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    showAppToast(context, '路径已复制');
  }

  /// 读一次导出位置（m32406 任务 D3）。
  ///
  /// 只读展示串，不碰 token 本身：token 的持久化读写全在 `ExportLocation` 里。
  Future<void> _loadExportDir() async {
    try {
      final String? token = await ExportLocation.getSavedToken();
      if (!mounted) return;
      setState(() => _exportDirLabel = ExportLocation.describeToken(token));
    } catch (e) {
      AppLogger.instance.warn('EXPORT', '读取导出位置失败：$e');
    }
  }

  /// 导出题库（m32406 任务 D3）。
  ///
  /// 与题库管理页右上角「⋯ → 导出题库」共用 `ExportService`，两条入口行为一致。
  /// 失败分档报文案：网络异常 / 其他失败（目录不可写、压缩出错都已在
  /// `ExportException.message` 里写清楚了，这里不再二次分类）。
  Future<void> _exportQuestions() async {
    if (_exporting) return;
    setState(() => _exporting = true);

    final ExportService service = ExportService();
    try {
      final ExportResult result = await service.exportQuestions(kDemoUserId);
      if (!mounted) return;
      await _info(
        title: '导出完成',
        message: '已导出 ${result.questionCount} 道题到 ${result.path}\n'
            '文件大小 ${result.sizeLabel}。',
      );
    } on ExportException catch (e) {
      if (!mounted) return;
      // 用户在 SAF 选择器里按了取消 —— 不是错误，不弹窗。
      if (e.kind == ExportFailureKind.location && e.message.contains('已取消')) {
        return;
      }
      AppLogger.instance.warn('EXPORT', '导出失败（${e.kind.name}）：${e.message}');
      await _info(
        title: e.kind == ExportFailureKind.network ? '网络异常' : '导出失败',
        message: e.message,
      );
    } catch (e) {
      if (!mounted) return;
      AppLogger.instance.error('EXPORT', '导出出错：$e');
      await _info(title: '导出失败', message: '导出过程出错：$e');
    } finally {
      service.close();
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 更换导出位置（m32406 任务 D3）。
  ///
  /// 先置 `_exporting`：换目录本身也会弹系统选择器，与导出共用一个「忙」态，
  /// 避免用户在导出进行中又把目录换掉（换掉后本次导出会写到旧目录）。
  Future<void> _changeExportDir() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final ExportPickResult picked = await ExportLocation.pickAndSaveDirectory();
      if (!mounted) return;
      if (picked.isFailed) {
        await _info(title: '无法更换导出位置', message: picked.error ?? '未知错误');
        return;
      }
      if (!picked.isPicked) return; // 用户取消，静默
      setState(() => _exportDirLabel = ExportLocation.describeToken(picked.token));
      await _info(title: '已更换导出位置', message: _exportDirLabel);
    } catch (e) {
      if (!mounted) return;
      AppLogger.instance.error('EXPORT', '更换导出位置出错：$e');
      await _info(title: '无法更换导出位置', message: '更换过程出错：$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
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

/// 「删除我的所有数据」确认弹窗（m18680 B1）。
///
/// 与 `_TokenDialog` 一样单独做成 StatefulWidget：`TextEditingController`
/// 必须有人 dispose，放在 `_SettingsPageState` 里会因弹窗反复开关而泄漏。
///
/// 为什么不用 `_confirm`：它只支持一行 message，而这里需要「输入四个字
/// 才能启用按钮」，必须自己控制 [CupertinoDialogAction.onPressed] 的可空。
class _DeleteAllDialog extends StatefulWidget {
  const _DeleteAllDialog();

  @override
  State<_DeleteAllDialog> createState() => _DeleteAllDialogState();
}

class _DeleteAllDialogState extends State<_DeleteAllDialog> {
  final TextEditingController _controller = TextEditingController();

  /// 只有逐字打出这四个字才能点「删除」。
  static const String _keyword = '确认删除';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  bool get _confirmed => _controller.text.trim() == _keyword;

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text(
        '删除我的所有数据',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: AppColors.overdue,
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              '将永久删除云端与本机的全部数据：缺陷单、验证记录、处理动作、模考、'
              '复盘，以及你自己导入的题目。公共题库与其他用户的数据不受影响。'
              '此操作不可撤销。',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '请输入「确认删除」四个字以继续：',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                height: 1.4,
                color: AppColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 8),
            CupertinoTextField(
              controller: _controller,
              autofocus: true,
              placeholder: _keyword,
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
              onSubmitted: (_) {
                if (_confirmed) Navigator.of(context).pop(true);
              },
            ),
          ],
        ),
      ),
      actions: <Widget>[
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消', style: TextStyle(fontFamily: kFontFamily)),
        ),
        CupertinoDialogAction(
          isDestructiveAction: true,
          // 未打出四个字时禁用：`onPressed: null` 会让按钮变灰且不可点。
          onPressed: _confirmed ? () => Navigator.of(context).pop(true) : null,
          child: const Text(
            '删除',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
