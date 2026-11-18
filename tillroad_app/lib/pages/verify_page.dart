import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/defect_api.dart';
import '../api/verification_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/defect_badges.dart';
import 'defect_detail_page.dart';

/// 验证任务页（FE-04）。
///
/// 数据源：`GET /users/:userId/verification-tasks` 与
/// `GET /users/:userId/verification-summary`（BE-04 已实现，本轮只接不建）。
///
/// 设计要点：
///   · **后端算 urgency，前端只展示**。窗口天数是后端常量（V1=7/V2=14/V3=21），
///     前端再算一遍就会出现「服务端说逾期、客户端说还剩 1 天」的双口径。
///   · **筛选走后端**。BE-04 的 `status`（stage 多值）与 `urgency`（多值）都支持
///     逗号分隔，所以切换筛选等于重新请求，而不是在内存里过滤。这与 FE-03 缺陷单
///     列表（当时后端只支持单值，所以本地算）不同，别再照搬。
///   · **摘要卡片点击即筛选**，减少一次「先看数字再点筛选条」的往返。
class VerifyPage extends StatefulWidget {
  const VerifyPage({super.key});

  @override
  State<VerifyPage> createState() => _VerifyPageState();
}

/// 紧急度筛选（与后端 `urgency` 参数一一对应）。
enum _UrgencyFilter {
  all('全部', null),
  overdue('逾期', 'overdue'),
  dueSoon('临期', 'due_soon'),
  normal('正常', 'normal');

  const _UrgencyFilter(this.label, this.wire);

  final String label;

  /// 传给后端的 `urgency` 值；`all` 不带该参数。
  final String? wire;
}

/// stage 筛选。
enum _StageFilter {
  all('全部', null),
  v1('V1', 'V1'),
  v2('V2', 'V2'),
  v3('V3', 'V3');

  const _StageFilter(this.label, this.wire);

  final String label;
  final String? wire;
}

class _VerifyPageState extends State<VerifyPage> {
  final VerificationApi _api = VerificationApi();
  final DefectApi _defectApi = DefectApi();

  /// 正在拉取详情的任务 id（只用于给该卡片显示局部 loading）。
  String? _openingId;

  List<VerificationTask>? _items; // null = 加载中
  VerificationSummary _summary = VerificationSummary.empty;
  ApiException? _error;
  _UrgencyFilter _urgency = _UrgencyFilter.all;
  _StageFilter _stage = _StageFilter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _api.close();
    _defectApi.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _items = null;
      _error = null;
    });
    if (kUseMock) {
      // 离线演示：延迟一点点让加载态可见（与 FE-03 列表页一致）。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      setState(() {
        _items = _mockTasks;
        _summary = _mockSummary;
      });
      return;
    }
    try {
      final results = await Future.wait(<Future<Object>>[
        _api.fetchVerificationTasks(
          kDemoUserId,
          status: _stage.wire,
          urgency: _urgency.wire,
          limit: 100,
        ),
        // 摘要始终拉全量，不随筛选变（否则「逾期 3」会在筛选到 V1 时变成「逾期 1」，
        // 用户会以为数据丢了）。
        _api.fetchVerificationSummary(kDemoUserId),
      ]);
      if (!mounted) return;
      setState(() {
        _items = results[0] as List<VerificationTask>;
        _summary = results[1] as VerificationSummary;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  Future<void> _applyUrgency(_UrgencyFilter f) async {
    if (_urgency == f) return;
    setState(() => _urgency = f);
    await _load();
  }

  Future<void> _applyStage(_StageFilter f) async {
    if (_stage == f) return;
    setState(() => _stage = f);
    await _load();
  }

  Future<void> _openDetail(VerificationTask task) async {
    // 验证任务就是「正处于 V1/V2/V3 的缺陷单」，详情页按缺陷单 id 拉取。
    //
    // DefectDetailPage 的构造要求一个完整 DefectTicket（它先用传入数据首屏渲染，
    // 再 initState 补拉 verifications/actions），所以这里必须先拿到详情。
    // 为避免「白屏 + 全屏转圈」的二次跳转，点击后只给该卡片局部 loading，
    // 拿到后一次性 push。
    if (kUseMock) {
      _toast('离线演示模式（kUseMock=true）下不跳转详情。');
      return;
    }
    setState(() => _openingId = task.id);
    try {
      final ticket = await _defectApi.fetchDefectDetail(task.id);
      if (!mounted) return;
      setState(() => _openingId = null);
      final changed = await Navigator.of(context).push<bool>(
        appRoute<bool>(context, DefectDetailPage(ticket: ticket)),
      );
      // 从详情页提交了验证 / 改了状态，回来必须重新拉：筛选结果会变。
      if (changed == true) await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _openingId = null);
      _toast(
        e.isNetworkError
            ? '无法连接后端，请确认服务已启动。'
            : '打开详情失败（HTTP ${e.statusCode}）',
      );
    }
  }

  /// 轻提示。
  ///
  /// `CupertinoAlertDialog` 内部硬编码 `fontFamily: 'CupertinoSystemText'` 且没有
  /// 暴露 textStyle 参数，所以每个 Text 都要显式写 style（见 README §5.5）。
  void _toast(String message) {
    showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        content: Text(
          message,
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            height: 1.35,
            color: AppColors.label,
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              '好',
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
    final items = _items;
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: const Text('验证任务'),
            middle: const Text('验证任务'),
            alwaysShowMiddle: false,
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: _load,
              child: const Icon(CupertinoIcons.arrow_clockwise, size: 22),
            ),
            border: const Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          // 摘要卡片（逾期 / 临期 / 正常 三色计数，点击即筛选）
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                12,
                AppSpacing.page,
                0,
              ),
              child: _SummaryCard(
                summary: _summary,
                selected: _urgency,
                onSelect: _applyUrgency,
              ),
            ),
          ),
          // stage 筛选条
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                12,
                AppSpacing.page,
                12,
              ),
              child: _StageChipRow(selected: _stage, onChanged: _applyStage),
            ),
          ),
          if (items == null && _error == null)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CupertinoActivityIndicator(radius: 14)),
            )
          else if (_error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _LoadErrorView(error: _error!, onRetry: _load),
            )
          else if (items!.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: CupertinoIcons.check_mark_circled,
                title: _isEmptyByFilter ? '当前筛选下没有任务' : '还没有待验证任务',
                message: _isEmptyByFilter
                    ? '换一个紧急度或阶段筛选看看'
                    : '暂无数据，从一次模考或错题开始',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                0,
                AppSpacing.page,
                24,
              ),
              sliver: SliverList.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppSpacing.cardGap),
                itemBuilder: (context, i) => _VerificationTaskCard(
                  task: items[i],
                  opening: _openingId == items[i].id,
                  onTap: () => _openDetail(items[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 「筛选后无结果」与「压根没有任务」要分开说话，否则用户不知道是数据没了还是筛错了。
  bool get _isEmptyByFilter =>
      _urgency != _UrgencyFilter.all || _stage != _StageFilter.all;
}

/// 摘要卡片：三色计数 + 点击筛选。
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.summary,
    required this.selected,
    required this.onSelect,
  });

  final VerificationSummary summary;
  final _UrgencyFilter selected;
  final ValueChanged<_UrgencyFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    return CardShell(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      child: Row(
        children: <Widget>[
          _SummaryCell(
            filter: _UrgencyFilter.overdue,
            count: summary.overdue,
            color: AppColors.overdue,
            selected: selected == _UrgencyFilter.overdue,
            onTap: onSelect,
          ),
          _divider(),
          _SummaryCell(
            filter: _UrgencyFilter.dueSoon,
            count: summary.dueSoon,
            color: AppColors.dueSoon,
            selected: selected == _UrgencyFilter.dueSoon,
            onTap: onSelect,
          ),
          _divider(),
          _SummaryCell(
            filter: _UrgencyFilter.normal,
            count: summary.normal,
            color: AppColors.normal,
            selected: selected == _UrgencyFilter.normal,
            onTap: onSelect,
          ),
        ],
      ),
    );
  }

  /// 竖向分隔线：纯 Cupertino 工程没有 Material 的 `VerticalDivider`，
  /// 直接手画 0.5px（与卡片横向分隔线同一做法）。
  Widget _divider() => const SizedBox(
        height: 32,
        width: 0.5,
        child: ColoredBox(color: AppColors.separator),
      );
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({
    required this.filter,
    required this.count,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final _UrgencyFilter filter;
  final int count;
  final Color color;
  final bool selected;
  final ValueChanged<_UrgencyFilter> onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(filter),
        child: AnimatedContainer(
          duration: AppDurations.countdown,
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.10)
                : CupertinoColors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.chip),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '$count',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: count > 0 ? color : AppColors.tertiaryLabel,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              // 颜色 + 文字双编码（色盲友好）
              Text(
                filter.label,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  color: AppColors.secondaryLabel,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// stage 筛选条（横向滚动，与 FE-03 缺陷单筛选条同形）。
class _StageChipRow extends StatelessWidget {
  const _StageChipRow({required this.selected, required this.onChanged});

  final _StageFilter selected;
  final ValueChanged<_StageFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _StageFilter.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final f = _StageFilter.values[i];
          final active = f == selected;
          return GestureDetector(
            onTap: () => onChanged(f),
            child: AnimatedContainer(
              duration: AppDurations.countdown,
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: active ? AppColors.accent : AppColors.card,
                borderRadius: BorderRadius.circular(17),
                boxShadow: active
                    ? null
                    : const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x0A000000),
                          blurRadius: 6,
                          offset: Offset(0, 1),
                        ),
                      ],
              ),
              child: Center(
                child: Text(
                  f.label,
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 14,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active ? CupertinoColors.white : AppColors.label,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 单条验证任务卡片。
class _VerificationTaskCard extends StatelessWidget {
  const _VerificationTaskCard({
    required this.task,
    required this.onTap,
    this.opening = false,
  });

  final VerificationTask task;
  final VoidCallback onTap;

  /// 该卡片正在拉取详情（点击后到 push 之间的过渡态）。
  final bool opening;

  Color get _urgencyColor => switch (task.urgency) {
        'overdue' => AppColors.overdue,
        'due_soon' => AppColors.dueSoon,
        _ => AppColors.normal,
      };

  String get _urgencyLabel => switch (task.urgency) {
        'overdue' => '已逾期',
        'due_soon' => '临期',
        _ => '正常',
      };

  @override
  Widget build(BuildContext context) {
    final freq = task.freqLabel;
    return PressableCard(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 左侧紧急度色条（与 FE-01 任务卡同规格，配色 + 文字双编码）
            Container(
              width: 3,
              height: 40,
              margin: const EdgeInsets.only(right: 10, top: 2),
              decoration: BoxDecoration(
                color: _urgencyColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 第一行：考点名 + urgency 徽标
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          task.nodeTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.label,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (opening)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: CupertinoActivityIndicator(radius: 8),
                        )
                      else
                        _UrgencyBadge(
                          color: _urgencyColor,
                          label: _urgencyLabel,
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 第二行：stage 徽标 + 第 N 轮 + 重开 M 次 + 频次
                  Row(
                    children: <Widget>[
                      _StageBadge(stage: task.stage),
                      if (task.verificationRound > 1) ...<Widget>[
                        const SizedBox(width: 6),
                        RoundChip(round: task.verificationRound),
                      ],
                      if (task.reopenCount > 0) ...<Widget>[
                        const SizedBox(width: 6),
                        ReopenChip(count: task.reopenCount),
                      ],
                      if (freq != null) ...<Widget>[
                        const SizedBox(width: 6),
                        Text(
                          freq,
                          style: TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 12,
                            color: AppColors.tertiaryLabel,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 第三行：剩余天数 + 窗口值
                  Row(
                    children: <Widget>[
                      Text(
                        task.daysLabel,
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _urgencyColor,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        task.windowLabel,
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 12,
                          color: AppColors.tertiaryLabel,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 紧急度徽标：淡底 + 实色字（与 FE-03 的 StatusBadge 同工艺）。
class _UrgencyBadge extends StatelessWidget {
  const _UrgencyBadge({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// stage 徽标：V1/V2/V3 统一灰底（不按阶段染不同色，避免暗示 V3 更重要）。
class _StageBadge extends StatelessWidget {
  const _StageBadge({required this.stage});

  final String stage;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.secondaryLabel.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        stage,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.secondaryLabel,
        ),
      ),
    );
  }
}

/// 加载失败（与缺陷单列表页同形，文案按网络 / HTTP 分流）。
class _LoadErrorView extends StatelessWidget {
  const _LoadErrorView({required this.error, required this.onRetry});

  final ApiException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error.isNetworkError
        ? '后端似乎没有运行。\n启动方式：node scripts/dev-start.mjs'
        : '${error.message}\n（HTTP ${error.statusCode}）';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              CupertinoIcons.exclamationmark_triangle,
              size: 40,
              color: AppColors.dueSoon,
            ),
            const SizedBox(height: 12),
            Text(
              '加载失败',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.label,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                height: 1.35,
                color: AppColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              onPressed: onRetry,
              child: Text(
                '重试',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 离线演示数据（kUseMock = true）
// ---------------------------------------------------------------------------

/// 三条覆盖 urgency 三态的假任务，用于 widget test 与无后端演示。
final List<VerificationTask> _mockTasks = <VerificationTask>[
  const VerificationTask(
    id: 'mock-overdue',
    stage: 'V1',
    urgency: 'overdue',
    windowDays: 7,
    daysLeft: -2,
    overdueDays: 2,
    elapsedDays: 9,
    verificationRound: 1,
    reopenCount: 0,
    knowledgeNodeTitle: '充分必要条件',
    knowledgeNodeFreqTag: 'high',
    subjectName: '行测 · 判断推理与言语',
    qType: '判断推理 · 充分必要条件',
  ),
  const VerificationTask(
    id: 'mock-due-soon',
    stage: 'V2',
    urgency: 'due_soon',
    windowDays: 14,
    daysLeft: 2,
    overdueDays: 0,
    elapsedDays: 12,
    verificationRound: 1,
    reopenCount: 0,
    knowledgeNodeTitle: '增长率比较',
    knowledgeNodeFreqTag: 'high',
    subjectName: '行测 · 数量与资料',
    qType: '资料分析 · 增长率比较',
  ),
  const VerificationTask(
    id: 'mock-normal',
    stage: 'V3',
    urgency: 'normal',
    windowDays: 21,
    daysLeft: 9,
    overdueDays: 0,
    elapsedDays: 12,
    verificationRound: 2,
    reopenCount: 1,
    knowledgeNodeTitle: '法律常识',
    knowledgeNodeFreqTag: 'low',
    subjectName: '行测 · 判断推理与言语',
    qType: '常识判断 · 法律常识',
  ),
];

const VerificationSummary _mockSummary = VerificationSummary(
  total: 3,
  overdue: 1,
  dueSoon: 1,
  normal: 1,
  byStage: <String, int>{'V1': 1, 'V2': 1, 'V3': 1},
);
