import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
import '../api/defect_api.dart';
// 只拿 summary 相关的两个类型：`VerificationTask` 在 home_mock.dart 里已有一个
// 首页专用版本（展示字段不同），两个都导入会 ambiguous_import。
import '../api/verification_api.dart'
    show VerificationApi, VerificationSummary;
import '../config/api_config.dart';
import '../mock/home_mock.dart';
import '../pages/defect_create_page.dart';
import '../theme/app_theme.dart';
import '../widgets/countdown_card.dart';
import '../widgets/defect_summary_card.dart';
import '../widgets/common.dart';
import '../widgets/quick_action_grid.dart';
import '../widgets/task_card.dart';

/// 首页看板（FE-01 的核心页面，FE-07 完成数据联调）
///
/// 布局：`CustomScrollView` + `CupertinoSliverNavigationBar(largeTitle: ...)`，
/// 这是 iOS 大标题折叠的标准实现——滚动时 Flutter 内部按滚动偏移
/// **连续插值**大标题（34pt）与导航栏标题（17pt）的位置与不透明度，
/// 不存在「突然变小」的跳变，因此不需要自己写折叠动画。
///
/// 内容顺序按用户当日决策优先级排：
/// 考试倒计时（目标锚点）→ 今日待验证（最该做的事）→ 缺陷分布（现状）→ 快捷入口（行动）。
///
/// ## 数据源（FE-07）
///
/// 四块数据三路并发拉取（`Future.wait`），**每路各自 try/catch**：
///   · 倒计时   ← `GET /users/:id/exam-profiles`（取第一个 active 的）
///   · 待验证   ← `GET /users/:id/verification-summary`
///   · 缺陷分布 ← `GET /users/:id/defect-stats`
///   · 任务列表 仍用 mock（完整列表在「验证」Tab，首页只做一个摘要位）
///
/// 为什么逐卡片降级而不是整屏失败：Neon 免费版空闲会挂起，唤醒要 20–40s。
/// 若一个请求超时就把整屏变错误页，用户会看到一个「什么都干不了」的首页；
/// 而实际上下面的缺陷分布可能早就拿到了。所以每块各自回落 mock + 「离线数据」标记。
///
/// 首屏不显示 0 也不显示 mock 数字：数据没到就显示灰色骨架块，
/// 到位后 `AnimatedSwitcher` 淡入——避免用户看到「0 条缺陷」再突然变「23 条」。
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.onSwitchTab});

  /// 切到指定 Tab（快捷入口「转缺陷单」用）。
  /// 由 `RootTabs` 注入，首页自己不知道 Tab 结构。
  final ValueChanged<int>? onSwitchTab;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 任务列表仍用 mock：完整列表在「验证」Tab（FE-04 已接真实 API），
  /// 首页这块是「今日待验证」的摘要位，样式沿用 FE-01。
  final HomeSnapshot _snapshot = kHomeSnapshot;

  final VerificationApi _verifyApi = VerificationApi();
  final DefectApi _defectApi = DefectApi();

  /// —— 倒计时 ——
  Map<String, Object?>? _profile;
  ApiException? _profileError;
  bool _profileLoaded = false;
  /// —— 今日待验证 ——
  VerificationSummary? _summary;
  ApiException? _summaryError;

  /// —— 缺陷分布 ——
  Map<String, Object?>? _stats;
  ApiException? _statsError;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _verifyApi.close();
    _defectApi.close();
    super.dispose();
  }

  /// 三路并发。每路自己吞掉异常并记在各自的 error 字段上，
  /// 所以 `Future.wait` 不会因一路失败而整体抛出（也就不会让另两路白拉）。
  Future<void> _loadAll() async {
    if (kUseMock) return;
    await Future.wait<void>(<Future<void>>[
      _loadProfile(),
      _loadSummary(),
      _loadStats(),
    ]);
  }

  Future<void> _loadProfile() async {
    try {
      final profiles = await _defectApi.fetchExamProfiles(kDemoUserId);
      if (!mounted) return;
      setState(() {
        // Prefer the active profile; otherwise fall back to the first archived profile.
        _profile = profiles.cast<Map<String, Object?>?>().firstWhere(
          (Map<String, Object?>? p) => p?['status'] == 'active',
          orElse: () => profiles.isEmpty ? null : profiles.first,
        );
        _profileError = null;
        _profileLoaded = true;
      });
    } on ApiException catch (e) {
      debugPrint('[home] 考试目标加载失败：${e.message}（uri=${e.uri}, status=${e.statusCode}）');
      if (!mounted) return;
      setState(() {
        _profileError = e;
        _profileLoaded = true;
      });
    } catch (e) {
      debugPrint('[home] 考试目标解析异常：$e');
      if (!mounted) return;
      setState(() {
        _profileError = ApiException('考试目标解析失败：$e');
        _profileLoaded = true;
      });
    }
  }

  Future<void> _loadSummary() async {
    try {
      final summary = await _verifyApi.fetchVerificationSummary(kDemoUserId);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _summaryError = null;
      });
    } on ApiException catch (e) {
      debugPrint('[home] 验证摘要加载失败：${e.message}（uri=${e.uri}, status=${e.statusCode}）');
      if (!mounted) return;
      setState(() => _summaryError = e);
    } catch (e) {
      debugPrint('[home] 验证摘要解析异常：$e');
      if (!mounted) return;
      setState(() => _summaryError = ApiException('验证摘要解析失败：$e'));
    }
  }

  Future<void> _loadStats() async {
    try {
      final stats = await _defectApi.fetchDefectStats(kDemoUserId);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _statsError = null;
      });
    } on ApiException catch (e) {
      debugPrint('[home] 缺陷统计加载失败：${e.message}（uri=${e.uri}, status=${e.statusCode}）');
      if (!mounted) return;
      setState(() => _statsError = e);
    } catch (e) {
      debugPrint('[home] 缺陷统计解析异常：$e');
      if (!mounted) return;
      setState(() => _statsError = ApiException('缺陷统计解析失败：$e'));
    }
  }

  /// 下拉刷新：三路一起重拉。
  Future<void> _refreshAll() async {
    if (kUseMock) {
      // 离线演示时给一点延迟，让刷新动画有反馈
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return;
    }
    setState(() {
      _profileError = null;
      _summaryError = null;
      _statsError = null;
      _profileLoaded = false;
    });
    await _loadAll();
  }

  void _toast(String title, String message) {
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
          title,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        content: Text(
          message,
          style: const TextStyle(
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
    // 首页任务列表是摘要位，点进去切到「验证」Tab 看完整列表
    if (widget.onSwitchTab != null) {
      widget.onSwitchTab!(2);
    } else {
      _toast('验证 · ${task.knowledgeNodeTitle}', '完整验证任务列表在「验证」标签页。');
    }
  }

  // ─────────────────────────── 倒计时 ───────────────────────────

  /// 剩余天数按**本地时区**算（后端只给 `YYYY-MM-DD` 日期）。
  ///
  /// 关键：把两边都归零到当天 00:00 再相减。直接用 `examDate.difference(now)`
  /// 会因为「现在几点」而差一天——晚上看是 46 天、早上看是 47 天，用户会觉得数字在乱跳。
  static int _daysUntil(Object? examDate) {
    if (examDate is! String) return 0;
    final DateTime? target = DateTime.tryParse(examDate);
    if (target == null) return 0;
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime examDay = DateTime(target.year, target.month, target.day);
    return examDay.difference(today).inDays;
  }

  Widget _buildCountdown() {
    final Map<String, Object?>? profile = _profile;

    // kUseMock（离线演示 / widget test）：直接回落 mock，不显示骨架也不显示空状态。
    // 骨架只在「真实模式下、数据还在路上」时出现；mock 模式下数据天然立刻可得。
    if (kUseMock) {
      return CountdownCard(
        examLabel: _snapshot.examLabel,
        daysToExam: _snapshot.daysToExam,
      );
    }

    // 数据没到且没失败 → 骨架
    if (!_profileLoaded && profile == null && _profileError == null) {
      return const _SkeletonBlock(height: 108);
    }


    // 失败或没有考试目标 → 空状态卡片（不显示 0 天）
    if (profile == null) {
      return _GoalEmptyCard(
        offline: _profileError != null,
        onRetry: _profileError != null ? _refreshAll : null,
        onSetup: () => _toast('设置考试目标', '目标配置页将在后续里程碑实现。'),
      );
    }

    final Object? label = profile['target_label'];
    final String examLabel =
        (label is String && label.trim().isNotEmpty) ? label.trim() : '我的考试';
    return CountdownCard(
      examLabel: examLabel,
      daysToExam: _daysUntil(profile['exam_date']),
    );
  }

  // ───────────────────────── 今日待验证 ─────────────────────────

  /// 标题右侧：优先真实计数，拿不到就用 mock 条数（带小标记提示降级）。
  /// 标题右侧：优先真实计数，拿不到就用 mock 条数（带小标记提示降级）。
  ///
  /// 骨架阶段（真实模式、数据未到、也没失败）返回 `null`：不显示计数。
  /// 否则会先看到 mock 的「3 项」再突变成真实的「1 2」，违反 FE-07「首屏不显示 mock 数字」的要求。
  Widget? _summaryTrailing() {
    final VerificationSummary? summary = _summary;
    if (summary == null && _summaryError == null && !kUseMock) {
      return null;
    }
    final String fallback = '${_snapshot.tasks.length} 项';
    if (summary == null) {
      return Text(
        kUseMock ? fallback : '$fallback（离线）',
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

  // ───────────────────────── 缺陷分布 ─────────────────────────

  /// 后端的 `error_layer` 是自由文本（schema 未做枚举），已知的六层有中文名；
  /// 后端聚合会把空值归到 `unclassified`。这里做一次键→中文的映射，
  /// 未知值原样显示（比硬编码成「其他」更诚实：至少能看出数据里有什么）。
  static String _layerLabel(String layer) {
    switch (layer) {
      case 'unclassified':
        return '未分类';
      case 'concept':
        return '概念不清';
      case 'method':
        return '方法不会';
      case 'calculation':
        return '计算失误';
      case 'reading':
        return '审题偏差';
      default:
        return layer;
    }
  }

  /// 把后端 `{by_layer:[{error_layer,count}]}` 转成卡片要的 `LayerDistribution`，
  /// 取前 4 条（卡片高度有限，5 条以上会挤），其余合并成「其他」。
  static List<LayerDistribution> _distributionsFrom(Map<String, Object?>? stats) {
    final Object? raw = stats?['by_layer'];
    if (raw is! List) return const <LayerDistribution>[];
    final List<MapEntry<String, int>> items = <MapEntry<String, int>>[];
    for (final Object? row in raw) {
      if (row is! Map) continue;
      final Object? layer = row['error_layer'];
      final Object? count = row['count'];
      if (layer is! String || count is! int || count <= 0) continue;
      items.add(MapEntry<String, int>(layer, count));
    }
    if (items.isEmpty) return const <LayerDistribution>[];

    const int kMaxRows = 4;
    final List<LayerDistribution> out = <LayerDistribution>[];
    if (items.length <= kMaxRows) {
      for (final MapEntry<String, int> e in items) {
        out.add(LayerDistribution(
          layer: e.key,
          label: _layerLabel(e.key),
          count: e.value,
        ));
      }
      return out;
    }
    int rest = 0;
    for (int i = 0; i < items.length; i++) {
      if (i < kMaxRows - 1) {
        out.add(LayerDistribution(
          layer: items[i].key,
          label: _layerLabel(items[i].key),
          count: items[i].value,
        ));
      } else {
        rest += items[i].value;
      }
    }
    out.add(LayerDistribution(layer: 'other', label: '其他', count: rest));
    return out;
  }

  /// 未关闭总数：后端 `open_total`。
  ///
  /// 骨架阶段（真实模式、数据未到、也没失败）返回 `null`，让 trailing 整块不渲染——
  /// 否则会先看到 mock 的「共 23 条」再突变成真实数字，违反「首屏不显示 0/mock」。
  int? get _openCount {
    final Object? v = _stats?['open_total'];
    if (v is int) return v;
    if (_stats == null && _statsError == null && !kUseMock) return null;
    return _snapshot.totalDefects;
  }

  Widget _buildDistribution() {
    final Map<String, Object?>? stats = _stats;

    if (stats == null && _statsError == null && !kUseMock) {
      return const _SkeletonBlock(height: 132);
    }

    final bool offline = _statsError != null || stats == null;
    final List<LayerDistribution> distributions =
        offline ? _snapshot.distributions : _distributionsFrom(stats);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        DefectSummaryCard(
          distributions: distributions,
          // 此处已过骨架分支（stats 非空或已降级），_openCount 不会为 null，
          // 但类型上是 int?，用 ?? 只是为了保持非空类型，实际不会走到右值。
          totalDefects: _openCount ?? _snapshot.totalDefects,
        ),
        if (offline)
          // 左右各留 16 与卡片内其他内容对齐；底部留 14 否则文字贴到卡片圆角边缘显得被裁。
          const Padding(
            padding: EdgeInsets.only(top: 10, left: 16, right: 16, bottom: 14),
            child: Text(
              '离线数据',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                color: AppColors.tertiaryLabel,
              ),
            ),
          ),
      ],
    );
  }

  // ───────────────────────── 快捷入口 ─────────────────────────

  /// 「建题」：建单页需要 `examProfileId` + `subjectId`，与缺陷单页的
  /// `_openCreate()` 同一套取数逻辑（那边不能改，所以这里独立实现一份）。
  Future<void> _openCreate() async {
    if (kUseMock) {
      _toast('建题', '离线演示模式（kUseMock=true）下无法建单。');
      return;
    }
    try {
      final profiles = await _defectApi.fetchExamProfiles(kDemoUserId);
      if (!mounted) return;
      if (profiles.isEmpty) {
        _toast('还没有考试目标', '请先创建考试目标，再建缺陷单。');
        return;
      }
      final Map<String, Object?> first = profiles.first;
      final String profileId = '${first['id']}';
      final subjects = await _defectApi.fetchSubjects(profileId);
      if (!mounted) return;
      if (subjects.isEmpty) {
        _toast('还没有科目', '该考试目标下没有科目，无法建单。');
        return;
      }
      final Map<String, Object?> subject = subjects.first;
      final String subjectId = '${subject['id']}';
      final Object? subjectName = subject['name'];
      final bool? changed = await Navigator.of(context).push<bool>(
        appRoute<bool>(
          context,
          DefectCreatePage(
            examProfileId: profileId,
            subjectId: subjectId,
            subjectName: subjectName is String ? subjectName : '科目',
          ),
        ),
      );
      if (changed == true && mounted) {
        setState(() {
          _stats = null;
          _summary = null;
        });
        await _loadAll();
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast('无法建题', e.message);
    }
  }

  void _openDefects() {
    final ValueChanged<int>? switchTab = widget.onSwitchTab;
    if (switchTab != null) {
      switchTab(1);
    } else {
      _toast('缺陷单', '请在底部标签栏切到「缺陷单」。');
    }
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
                  // 数据到达淡入（250ms），避免骨架块「啪」一下变成内容
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    switchInCurve: Curves.easeInOut,
                    switchOutCurve: Curves.easeInOut,
                    child: KeyedSubtree(
                      key: ValueKey<String>(
                        'countdown-${_profile == null}-${_profileError == null}',
                      ),
                      child: _buildCountdown(),
                    ),
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
                    trailing: switch (_openCount) {
                      final int n => Text(
                        '共 $n 条',
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 13,
                          color: AppColors.secondaryLabel,
                        ),
                      ),
                      // 骨架阶段不显示 mock 计数。
                      null => const SizedBox.shrink(),
                    },
                  ),
                  _CardShell(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      switchInCurve: Curves.easeInOut,
                      switchOutCurve: Curves.easeInOut,
                      child: KeyedSubtree(
                        key: ValueKey<String>(
                          'dist-${_stats == null}-${_statsError == null}',
                        ),
                        child: _buildDistribution(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  const SectionHeader(text: '快捷入口'),
                  QuickActionGrid(
                    actions: <QuickAction>[
                      QuickAction(
                        icon: CupertinoIcons.add,
                        label: '建题',
                        onTap: _openCreate,
                      ),
                      QuickAction(
                        icon: CupertinoIcons.doc_text,
                        label: '转缺陷单',
                        onTap: _openDefects,
                      ),
                      QuickAction(
                        icon: CupertinoIcons.timer,
                        label: '开始模考',
                        onTap: () => _toast('限时模考', '模考页将在后续里程碑实现。'),
                      ),
                      QuickAction(
                        icon: CupertinoIcons.chart_bar,
                        label: '复盘',
                        onTap: () => _toast('周期复盘', '复盘页将在后续里程碑实现。'),
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

/// 骨架块：数据未到时占位，避免显示 0 或 mock 数字。
///
/// 用浅灰圆角矩形而不是转圈：转圈只传达「在等」，灰块还能传达「这里将出现什么形状」，
/// 数据到了就地替换，视觉上不会跳变。
class _SkeletonBlock extends StatelessWidget {
  /// 期望高度（仅作参考，不参与布局）：内容高度优先，避免 bone 总高超过它时溢出。
  const _SkeletonBlock({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    // DisableAnimations 时不做闪烁，避免无障碍用户受干扰
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // 高度不写死：padding(32) + 三条 bone + 两条间距 = 32+13+14+32+10+13 = 114，
    // 写死 108 会溢出 6px（真机截图里出现黄黑警告条）。让内容自己撑开高度。
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x0F000000), blurRadius: 12, offset: Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      // 用 minHeight 而不是 height：允许内容比预期高时自然擑开，避免 RenderFlex 溢出。
      constraints: BoxConstraints(minHeight: height),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Bone(width: 120, height: 13, reduceMotion: reduceMotion),
          const SizedBox(height: 14),
          _Bone(width: double.infinity, height: 32, reduceMotion: reduceMotion),
          const SizedBox(height: 10),
          _Bone(width: 180, height: 13, reduceMotion: reduceMotion),
        ],
      ),
    );
  }
}

class _Bone extends StatelessWidget {
  const _Bone({
    required this.width,
    required this.height,
    required this.reduceMotion,
  });

  final double width;
  final double height;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final Widget bone = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.groupedBackground,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    if (reduceMotion) return bone;
    // 轻微呼吸：0.55 ↔ 1.0 不透明度，1.2s 一轮
    return _Pulse(child: bone);
  }
}

/// 骨架的呼吸动画（自带 controller，避免上层 State 管一堆动画）。
class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.55, end: 1.0).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: widget.child,
    );
  }
}

/// 没有考试目标时的倒计时卡（FE-07 任务 B3）。
///
/// 不用 `CountdownCard` 是因为它的语义是「距离考试 N 天」，
/// 没有目标时那个大数字没有任何意义——显示 0 天更像 bug 而不是空状态。
class _GoalEmptyCard extends StatelessWidget {
  const _GoalEmptyCard({
    required this.offline,
    required this.onSetup,
    this.onRetry,
  });

  final bool offline;
  final VoidCallback onSetup;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x0F000000), blurRadius: 12, offset: Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                CupertinoIcons.calendar,
                size: 18,
                color: AppColors.secondaryLabel,
              ),
              const SizedBox(width: 8),
              Text(
                offline ? '考试目标加载失败' : '还没有设置考试目标',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.label,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            offline
                ? '无法连接后端，倒计时暂时显示不出来。'
                : '设置考试日期后，这里会显示距离考试还剩多少天。',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.secondaryLabel,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                onPressed: offline ? onRetry : onSetup,
                child: Text(
                  offline ? '重试' : '去设置',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ],
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
