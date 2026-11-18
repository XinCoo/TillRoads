import 'package:flutter/cupertino.dart';

import '../mock/defects_mock.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/defect_badges.dart';
import '../widgets/verification_progress.dart';

/// 缺陷单详情页（FE-03B）。
///
/// 结构：大标题导航栏（q_type）+ 六栏基本信息 + 处理动作 + 三次验证进度 +
/// 状态时间线 + 底部固定操作区。数据全部来自 mock，不连后端。
///
/// 注意：这里用 `CupertinoSliverNavigationBar` 而不是
/// `CupertinoPageScaffold(navigationBar:)`——后者不会给 child 预留导航栏高度，
/// 滚动内容会钻到导航栏下面（实测截图里归因首行被挡住）。
class DefectDetailPage extends StatelessWidget {
  const DefectDetailPage({super.key, required this.ticket});

  final DefectTicket ticket;

  /// 底部主按钮文案；`null` 表示不给主按钮（已关闭）。
  String? get _primaryActionLabel => switch (ticket.status) {
    DefectStatus.draft => '去归因',
    DefectStatus.analyzed => '暂无操作',
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
                                        onTap: () => _toast(
                                          context,
                                          '标记完成功能后续实现。',
                                        ),
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
            onPressed: () => _toast(
              context,
              '该操作需要连接后端 API，将在 FE-04 / BE-03 接口接入后实现。',
            ),
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
