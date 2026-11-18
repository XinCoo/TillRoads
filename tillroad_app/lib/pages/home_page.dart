import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
// 只拿 summary 相关的两个类型：`VerificationTask` 在 home_mock.dart 里已有一个
// 首页专用版本（展示字段不同），两个都导入会 ambiguous_import。
import '../api/verification_api.dart'
    show VerificationApi, VerificationSummary;
import '../config/api_config.dart';
import '../mock/home_mock.dart';
import '../theme/app_theme.dart';
import '../widgets/countdown_card.dart';
import '../widgets/defect_summary_card.dart';
import '../widgets/common.dart';
import '../widgets/quick_action_grid.dart';
import '../widgets/task_card.dart';

/// 首页看板（FE-01 的核心页面）
///
/// 布局：`CustomScrollView` + `CupertinoSliverNavigationBar(largeTitle: ...)`，
/// 这是 iOS 大标题折叠的标准实现——滚动时 Flutter 内部按滚动偏移
/// **连续插值**大标题（34pt）与导航栏标题（17pt）的位置与不透明度，
/// 不存在「突然变小」的跳变，因此不需要自己写折叠动画。
///
/// 内容顺序按用户当日决策优先级排：
/// 考试倒计时（目标锚点）→ 今日待验证（最该做的事）→ 缺陷分布（现状）→ 快捷入口（行动）。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// FE-01 用静态 mock；接后端时改成从 repository 拉取并 setState。
  final HomeSnapshot _snapshot = kHomeSnapshot;

  /// 「今日待验证」的**真实计数**（FE-04 C2）。
  ///
  /// 本轮只把这一处接上 `GET /users/:id/verification-summary`，首页其余 mock
  /// （倒计时、缺陷分布、快捷入口、任务列表本身）都留到 FE-07 完整联调。
  /// 失败时保持 null，标题右侧回落到 mock 条数——首页不该因为一个计数请求
  /// 就整屏报错。
  final VerificationApi _verifyApi = VerificationApi();
  VerificationSummary? _summary;
  ApiException? _summaryError;

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  @override
  void dispose() {
    _verifyApi.close();
    super.dispose();
  }

  Future<void> _loadSummary() async {
    if (kUseMock) return;
    try {
      final summary = await _verifyApi.fetchVerificationSummary(kDemoUserId);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _summaryError = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _summaryError = e);
    }
  }

  void _showComingSoon(String feature) {
    showCupertinoDialog<void>(
      context: context,
      // CupertinoAlertDialog 在 cupertino/dialog.dart 里把 title/content/action
      // 三处文字硬编码成 `fontFamily: 'CupertinoSystemText'`
      // （_kCupertinoDialogTitleStyle / _kCupertinoDialogContentStyle /
      // _kCupertinoDialogActionStyle），而且对外只暴露 title/content/actions
      // 三个 Widget，没有 titleTextStyle / messageTextStyle 参数可覆盖。
      // 所以这里只能给每个 Text 显式写 style —— TextStyle.merge 时显式指定的
      // fontFamily 胜出，组件内部的 DefaultTextStyle 只负责填充剩余属性。
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: Text(
          feature,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        content: const Text(
          'FE-01 只做看板展示，该功能在后续前端里程碑实现。',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            color: AppColors.label,
            height: 1.35,
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '知道了',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w400,
                color: AppColors.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onTapTask(VerificationTask task) {
    _showComingSoon('验证 · ${task.knowledgeNodeTitle}');
  }

  /// 标题右侧：优先真实计数，拿不到就用 mock 条数（带小标记提示降级）。
  Widget _summaryTrailing() {
    final summary = _summary;
    final fallback = '${_snapshot.tasks.length} 项';
    if (summary == null) {
      return Text(
        _summaryError == null ? fallback : '$fallback（离线）',
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 13,
          color: AppColors.secondaryLabel,
        ),
      );
    }
    // 三色计数：逾期红 / 临期橙 / 正常绿，颜色 + 数字双编码
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (summary.overdue > 0) ...<Widget>[
          _CountDot(color: AppColors.overdue, count: summary.overdue),
          const SizedBox(width: 8),
        ],
        if (summary.dueSoon > 0) ...<Widget>[
          _CountDot(color: AppColors.dueSoon, count: summary.dueSoon),
          const SizedBox(width: 8),
        ],
        _CountDot(color: AppColors.normal, count: summary.normal),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: CustomScrollView(
        // iOS 手感：滚动到边界有回弹
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: <Widget>[
          const CupertinoSliverNavigationBar(
            largeTitle: Text(
              '题路',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.37,
              ),
            ),
            // alwaysShowMiddle 默认为 true，会导致大标题未折叠时
            // 中间标题与 largeTitle 同时出现（截图里看到「题路」重复两次）。
            // 置 false 让中间标题只在大标题折起后才淡入，符合 iOS 行为。
            alwaysShowMiddle: false,
            middle: Text('题路'),
            border: Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          SliverSafeArea(
            top: false,
            sliver: SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                8,
                AppSpacing.page,
                24,
              ),
              sliver: SliverList.list(
                children: <Widget>[
                  CountdownCard(
                    examLabel: _snapshot.examLabel,
                    daysToExam: _snapshot.daysToExam,
                  ),
                  const SizedBox(height: 20),

                  SectionHeader(
                    text: '今日待验证',
                    trailing: _summaryTrailing(),
                  ),
                  _CardShell(
                    child: TaskListCard(
                      tasks: _snapshot.tasks,
                      onTapTask: _onTapTask,
                    ),
                  ),
                  const SizedBox(height: 20),

                  SectionHeader(
                    text: '缺陷分布',
                    trailing: Text(
                      '共 ${_snapshot.totalDefects} 条',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.secondaryLabel,
                      ),
                    ),
                  ),
                  _CardShell(
                    child: DefectSummaryCard(
                      distributions: _snapshot.distributions,
                      totalDefects: _snapshot.totalDefects,
                    ),
                  ),
                  const SizedBox(height: 20),

                  const SectionHeader(text: '快捷入口'),
                  QuickActionGrid(
                    actions: <QuickAction>[
                      QuickAction(
                        icon: CupertinoIcons.add,
                        label: '建题',
                        onTap: () => _showComingSoon('建题 / 导入'),
                      ),
                      QuickAction(
                        icon: CupertinoIcons.doc_text,
                        label: '转缺陷单',
                        onTap: () => _showComingSoon('转缺陷单'),
                      ),
                      QuickAction(
                        icon: CupertinoIcons.timer,
                        label: '开始模考',
                        onTap: () => _showComingSoon('限时模考'),
                      ),
                      QuickAction(
                        icon: CupertinoIcons.chart_bar,
                        label: '复盘',
                        onTap: () => _showComingSoon('周期复盘'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片外壳：白底 + 圆角 16 + 轻阴影，把内容包成 iOS 分组卡片
class _CardShell extends StatelessWidget {
  const _CardShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 12,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 首页「今日待验证」右侧的小计数：彩色圆点 + 数字（颜色 + 数字双编码，色盲友好）。
class _CountDot extends StatelessWidget {
  const _CountDot({required this.color, required this.count});

  final Color color;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          '$count',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
