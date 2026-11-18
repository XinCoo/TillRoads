import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/defect_api.dart';
import '../config/api_config.dart';
import '../mock/defects_mock.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/defect_badges.dart';
import '../widgets/verification_progress.dart';
import 'defect_analyze_page.dart';
import 'defect_verify_page.dart';
/// 缺陷单详情页（FE-03B）。
///
/// 结构：大标题导航栏（q_type）+ 六栏基本信息 + 处理动作 + 三次验证进度 +
/// 状态时间线 + 底部固定操作区。
///
/// 数据来源（FE-03 联调）：
///   · 先用列表页传来的 [ticket] **立即渲染**（避免白屏）
///   · 若 `kUseMock == false`，initState 再用 id 拉一次详情拿
///     `verifications` / `actions`（列表端点在 `listRows` 的 SELECT * 下
///     不带这两个关联集合），拿到后刷新界面
///   · 拉取失败**不阻断浏览**：只在顶部加一条轻量提示，用户仍能看到列表那份
///     数据；这与列表页的错误态区别对待（详情页有面包屑可退回，不必强阻断）
/// 注意：这里用 `CupertinoSliverNavigationBar` 而不是
/// `CupertinoPageScaffold(navigationBar:)`——后者不会给 child 预留导航栏高度，
/// 滚动内容会钻到导航栏下面（实测截图里归因首行被挡住）。
class DefectDetailPage extends StatefulWidget {
  const DefectDetailPage({super.key, required this.ticket});

  final DefectTicket ticket;

  @override
  State<DefectDetailPage> createState() => _DefectDetailPageState();
}

class _DefectDetailPageState extends State<DefectDetailPage> {
  late DefectTicket ticket = widget.ticket;

  final DefectApi _api = DefectApi();
  ApiException? _refreshError;

  @override
  void initState() {
    super.initState();
    _refreshDetail();
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  /// 拉详情（含 verifications / actions）。失败只记提示，不回退整页错误态。
  Future<void> _refreshDetail() async {
    if (kUseMock) return;
    try {
      final detail = await _api.fetchDefectDetail(widget.ticket.id);
      if (!mounted) return;
      setState(() {
        ticket = detail;
        _refreshError = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _refreshError = e);
    }
  }
  // ─────────── 写操作（FE-03 写操作联调）───────────

  bool _busy = false;

  /// 统一报错：后端的业务错误用 ApiException.body['error'] 判别。
  void _handleWriteError(Object e) {
    if (e is! ApiException) {
      setState(() => _busy = false);
      _toast(context, '操作失败：$e');
      return;
    }
    final Object? body = e.body;
    final String code =
        body is Map && body['error'] != null ? '${body['error']}' : '';

    setState(() => _busy = false);

    if (code == 'conflict' || e.statusCode == 409) {
      // 乐观锁失效：别人改过这条单。刷新拿到最新 version 再重试。
      _toast(context, '该单已被修改，正在刷新到最新状态。');
      _refreshDetail();
      return;
    }
    if (code == 'ai_cannot_close') {
      _toast(context, 'AI 不能替用户关单：验证通过必须由你本人标记。');
      return;
    }
    if (code == 'NO_ACTIONS') {
      _toast(context, '先添加至少一条处理动作，再进入验证。');
      return;
    }
    if (code == 'ACTIONS_NOT_DONE') {
      _toast(context, '还有处理动作未完成，全部勾选后才能进入验证。');
      return;
    }
    if (code == 'INVALID_BASE_VERSION') {
      _toast(context, '缺少版本号（乐观锁）。请刷新页面后重试。');
      return;
    }
    if (code == 'ILLEGAL_DEFECT_TRANSITION' ||
        code == 'INVALID_VERIFICATION_STAGE') {
      _toast(context, '当前状态不支持这个操作，正在刷新到最新状态。');
      _refreshDetail();
      return;
    }
    _toast(
      context,
      e.isNetworkError ? '${e.message}\n请确认后端在运行。' : e.message,
    );
  }

  /// D：点未完成的动作 → 标记 done=true（完成态不可点，避免误取消）。
  Future<void> _toggleAction(DefectAction action) async {
    if (_busy || kUseMock) {
      if (kUseMock) _toast(context, '当前是离线演示模式（kUseMock=true），不会真的改数据。');
      return;
    }
    if (action.done) {
      _toast(context, '已完成的动作不能取消，如需调整请删除后重新添加。');
      return;
    }
    setState(() => _busy = true);
    try {
      await _api.markActionDone(
        ticket.id,
        action.id,
        done: true,
        version: ticket.version,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await _refreshDetail();
    } catch (e) {
      if (!mounted) return;
      _handleWriteError(e);
    }
  }

  /// E1：ACTION_DONE → V1（后端同事务两跳：先写 ACTION_DONE 再写 V1）。
  Future<void> _enterVerification() async {
    if (_busy || kUseMock) {
      if (kUseMock) _toast(context, '当前是离线演示模式（kUseMock=true），不会真的改数据。');
      return;
    }
    setState(() => _busy = true);
    try {
      await _api.beginVerification(ticket.id, version: ticket.version);
      if (!mounted) return;
      setState(() => _busy = false);
      await _refreshDetail();
      if (!mounted) return;
      _toast(context, '已进入第 1 次验证（V1）。');
    } catch (e) {
      if (!mounted) return;
      _handleWriteError(e);
    }
  }

  /// C：DRAFT → 补充归因；REOPENED → 重新归因。
  Future<void> _openAnalyze() async {
    if (kUseMock) {
      _toast(context, '当前是离线演示模式（kUseMock=true），不会真的改数据。');
      return;
    }
    final bool? changed = await Navigator.of(context).push<bool>(
      appRoute<bool>(context, DefectAnalyzePage(ticket: ticket)),
    );
    if (!mounted) return;
    if (changed == true) {
      await _refreshDetail();
      if (!mounted) return;
      _toast(context, '归因已提交，状态推进到「已归因」。');
    }
  }

  /// E2：V1/V2/V3 → 提交验证表单。
  Future<void> _openVerify() async {
    if (kUseMock) {
      _toast(context, '当前是离线演示模式（kUseMock=true），不会真的改数据。');
      return;
    }
    final bool? submitted = await Navigator.of(context).push<bool>(
      appRoute<bool>(context, DefectVerifyPage(ticket: ticket)),
    );
    if (!mounted) return;
    if (submitted == true) {
      await _refreshDetail();
      if (!mounted) return;
      final bool closed = ticket.status == DefectStatus.closed;
      _toast(context, closed ? '三次验证全部通过，缺陷单已关闭。' : '验证已提交，状态已推进。');
    }
  }

  /// 底部主按钮分发。
  Future<void> _onPrimaryAction() async {
    switch (ticket.status) {
      case DefectStatus.draft:
      case DefectStatus.reopened:
        await _openAnalyze();
      case DefectStatus.analyzed:
        // ANALYZED 不是死路：先加动作并全部勾选，再由后端同事务两跳
        // ANALYZED → ACTION_DONE → V1。若还没满足前置，后端会返回
        // NO_ACTIONS / ACTIONS_NOT_DONE，_handleWriteError 会给出可操作提示。
        await _enterVerification();
      case DefectStatus.actionDone:
        await _enterVerification();
      case DefectStatus.v1:
      case DefectStatus.v2:
      case DefectStatus.v3:
        await _openVerify();
      case DefectStatus.closed:
        break;
    }
  }

  /// 底部主按钮文案；`null` 表示不给主按钮（已关闭）。
  String? get _primaryActionLabel => switch (ticket.status) {
    DefectStatus.draft => '去归因',
    DefectStatus.analyzed => '进入验证',
    DefectStatus.actionDone => '进入验证',
    DefectStatus.v1 || DefectStatus.v2 || DefectStatus.v3 => '提交验证',
    DefectStatus.reopened => '重新归因',
    DefectStatus.closed => null,
  };

  /// 统一的轻提示。
  ///
  /// `CupertinoAlertDialog` 内部把标题/正文/按钮样式硬编码成
  /// `fontFamily: 'CupertinoSystemText'`，构造函数也没暴露 textStyle 参数，
  /// 所以只能给每个 Text 显式写 style 才能用上霞鹜新致宋。
  void _toast(BuildContext context, String message) {
    showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '提示',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            message,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '知道了',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                color: AppColors.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: Column(
        children: <Widget>[
          Expanded(
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: <Widget>[
                CupertinoSliverNavigationBar(
                  // 大标题用 q_type；个别考点名较长，降到 28pt 并允许两行
                  largeTitle: Text(
                    ticket.qType,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                      color: AppColors.label,
                    ),
                  ),
                  middle: Text(
                    ticket.qType,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: AppColors.label,
                      letterSpacing: -0.4,
                    ),
                  ),
                  alwaysShowMiddle: false,
                  trailing: CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () =>
                        _toast(context, '编辑功能将在后续前端里程碑实现。'),
                    child: const Text(
                      '编辑',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 17,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                  border: const Border(
                    bottom: BorderSide(
                      color: AppColors.separator,
                      width: 0.5,
                    ),
                  ),
                ),
                SliverSafeArea(
                  top: false,
                  bottom: false,
                  sliver: SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.page,
                      16,
                      AppSpacing.page,
                      24,
                    ),
                    sliver: SliverList.list(
                      children: <Widget>[
                        // 详情刷新失败时不阻断浏览（已先用列表数据渲染），
                        // 只给一条可感知的提示，并允许点重试。
                        if (_refreshError != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _RefreshFailedBanner(
                              error: _refreshError!,
                              onRetry: () {
                                setState(() => _refreshError = null);
                                _refreshDetail();
                              },
                            ),
                          ),
                        // ─────────── 六栏基本信息 ───────────
                        const SectionHeader(text: '基本信息'),
                        CardShell(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              // 1. 归因（error_cause 完整展示，不截断）
                              InfoRow(
                                label: '归因',
                                value: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: <Widget>[
                                    InfoText(
                                      ticket.errorLayer,
                                      size: 15,
                                      weight: FontWeight.w600,
                                    ),
                                    const SizedBox(height: 4),
                                    InfoText(
                                      ticket.errorCause,
                                      color: AppColors.secondaryLabel,
                                    ),
                                  ],
                                ),
                              ),
                              // 2. 状态
                              InfoRow(
                                label: '状态',
                                value: Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  crossAxisAlignment:
                                      WrapCrossAlignment.center,
                                  children: <Widget>[
                                    StatusBadge(status: ticket.status),
                                    if (ticket.verificationRound > 1)
                                      RoundChip(
                                        round: ticket.verificationRound,
                                      ),
                                    if (ticket.reopenCount > 0)
                                      ReopenChip(count: ticket.reopenCount),
                                  ],
                                ),
                              ),
                              // 3. 优先级
                              InfoRow(
                                label: '优先级',
                                value: Row(
                                  children: <Widget>[
                                    PriorityBadge(priority: ticket.priority),
                                    const SizedBox(width: 8),
                                    InfoText(
                                      ticket.priority.hint,
                                      color: AppColors.secondaryLabel,
                                    ),
                                  ],
                                ),
                              ),
                              // 4. 考点
                              InfoRow(
                                label: '考点',
                                value: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: <Widget>[
                                    InfoText(
                                      ticket.knowledgeNodeTitle,
                                      size: 15,
                                    ),
                                    const SizedBox(height: 2),
                                    InfoText(
                                      ticket.subjectName,
                                      color: AppColors.secondaryLabel,
                                    ),
                                  ],
                                ),
                              ),
                              // 5. 创建时间
                              InfoRow(
                                label: '创建时间',
                                value: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: <Widget>[
                                    InfoText(
                                      relativeTime(ticket.createdAt),
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        absoluteTime(ticket.createdAt),
                                        style: const TextStyle(
                                          fontFamily: kFontFamily,
                                          fontSize: 12,
                                          color: AppColors.tertiaryLabel,
                                          height: 1.4,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // 6. 动作数（最后一行不留底部间距）
                              Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: <Widget>[
                                  const SizedBox(
                                    width: 76,
                                    child: Text(
                                      '动作数',
                                      style: TextStyle(
                                        fontFamily: kFontFamily,
                                        fontSize: 14,
                                        color: AppColors.secondaryLabel,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: InfoText(
                                      '${ticket.actions.length} 条'
                                      '（已完成 ${ticket.doneActionCount}）',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        // ─────────── 处理动作 ───────────
                        const SizedBox(height: 20),
                        SectionHeader(
                          text: '处理动作',
                          trailing: Text(
                            '${ticket.doneActionCount}/'
                            '${ticket.actions.length}',
                            style: const TextStyle(
                              fontFamily: kFontFamily,
                              fontSize: 13,
                              color: AppColors.tertiaryLabel,
                              height: 1.4,
                            ),
                          ),
                        ),
                        CardShell(
                          child: ticket.actions.isEmpty
                              ? const InfoText(
                                  '还没有添加处理动作',
                                  color: AppColors.secondaryLabel,
                                )
                              : Column(
                                  children: <Widget>[
                                    for (
                                      int i = 0;
                                      i < ticket.actions.length;
                                      i++
                                    )
                                      _ActionRow(
                                        action: ticket.actions[i],
                                        isLast:
                                            i == ticket.actions.length - 1,
                                        onTap: () =>
                                            _toggleAction(ticket.actions[i]),
                                      ),
                                  ],
                                ),
                        ),

                        // ─────────── 三次验证进度 ───────────
                        const SizedBox(height: 20),
                        const SectionHeader(text: '三次验证'),
                        CardShell(
                          child: VerificationProgress(ticket: ticket),
                        ),

                        // ─────────── 状态时间线 ───────────
                        const SizedBox(height: 20),
                        const SectionHeader(text: '状态时间线'),
                        CardShell(
                          child: StatusTimeline(
                            events: ticket.statusHistory,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ─────────── 底部固定操作区 ───────────
          _BottomActionBar(
            status: ticket.status,
            label: _primaryActionLabel,
            onPressed: _busy ? () {} : _onPrimaryAction,
          ),
        ],
      ),
    );
  }
}

/// 单条处理动作：完成态用绿色实心勾 + 删除线，未完成用空心圆。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.action,
    required this.isLast,
    required this.onTap,
  });

  final DefectAction action;
  final bool isLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color iconColor = action.done
        ? AppColors.normal
        : AppColors.tertiaryLabel;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    action.done
                        ? CupertinoIcons.check_mark_circled_solid
                        : CupertinoIcons.circle,
                    size: 20,
                    color: iconColor,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    action.content,
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 15,
                      height: 1.4,
                      color: action.done
                          ? AppColors.secondaryLabel
                          : AppColors.label,
                      decoration: action.done
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                      decorationColor: AppColors.tertiaryLabel,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!isLast)
            const SizedBox(
              height: 0.5,
              child: ColoredBox(color: AppColors.separator),
            ),
        ],
      ),
    );
  }
}

/// 底部固定操作区：白底 + 顶部细分割线；已关闭时不给按钮，只显示绿色「已关闭」。
class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar({
    required this.status,
    required this.label,
    required this.onPressed,
  });

  final DefectStatus status;
  final String? label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final bool closed = status == DefectStatus.closed;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(
          top: BorderSide(color: AppColors.separator, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            10,
            AppSpacing.page,
            10,
          ),
          child: closed
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const <Widget>[
                    Icon(
                      CupertinoIcons.check_mark_circled_solid,
                      size: 20,
                      color: AppColors.normal,
                    ),
                    SizedBox(width: 8),
                    Text(
                      '已关闭',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.normal,
                      ),
                    ),
                  ],
                )
              : SizedBox(
                  width: double.infinity,
                  child: CupertinoButton.filled(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    borderRadius: BorderRadius.circular(AppRadii.chip),
                    onPressed: onPressed,
                    child: Text(
                      label ?? '暂无操作',
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.white,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// 详情刷新失败时的轻量提示条。
///
/// 为什么不用整页错误态：详情页进来时已有列表传过来的基础数据，
/// 用户能看到归因/状态/优先级等大部分信息；只是缺 `verifications` /
/// `actions` 两个关联集合（等于说验证进度会显示为未验证）。
/// 把整页换成错误屏会丢掉已经能看的内容，得不偿失。
class _RefreshFailedBanner extends StatelessWidget {
  const _RefreshFailedBanner({required this.error, required this.onRetry});

  final ApiException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final String reason = error.isNetworkError ? '无法连接后端' : 'HTTP ${error.statusCode}';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.dueSoon.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.chip),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            CupertinoIcons.exclamationmark_circle,
            size: 18,
            color: AppColors.dueSoon,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '验证进度刷新失败（$reason），下面展示的是列表数据',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                height: 1.35,
                color: AppColors.label,
              ),
            ),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: Size.zero,
            onPressed: onRetry,
            child: const Text(
              '重试',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
