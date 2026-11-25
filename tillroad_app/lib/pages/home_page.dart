import 'dart:async' show unawaited;

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
import '../api/defect_api.dart';
// 只拿 summary 相关的两个类型：`VerificationTask` 在 home_mock.dart 里已有一个
// 首页专用版本（展示字段不同），两个都导入会 ambiguous_import。
// 用前缀别名导入：`VerificationTask` 在 home_mock.dart 里已有一个首页专用版本
// （展示字段不同），两个都直接导入会 ambiguous_import；而 `show` 后面不能带
// 逐项 `as` 前缀，所以这里整个模块用别名。
import '../api/verification_api.dart' as vapi;
import '../config/api_config.dart';
import '../config/local_config.dart';
import '../local/local.dart';
import '../logging/app_logger.dart';
import '../mock/home_mock.dart';
import '../mock/defects_mock.dart' show DefectTicket;
import '../pages/defect_create_page.dart';
import '../pages/defect_detail_page.dart';
import '../pages/exam_config_page.dart';
import '../pages/mock_create_page.dart';
import '../pages/practice_config_page.dart';
import '../pages/review_page.dart';
import '../pages/settings_page.dart';
import '../pages/verify_page.dart';
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

  final vapi.VerificationApi _verifyApi = vapi.VerificationApi();
  final DefectApi _defectApi = DefectApi();

  /// —— 倒计时 ——
  Map<String, Object?>? _profile;
  ApiException? _profileError;
  bool _profileLoaded = false;
  /// —— 今日待验证 ——
  vapi.VerificationSummary? _summary;
  ApiException? _summaryError;

  /// 「今日待验证」的真实任务列表（R4b）。
  ///
  /// R4a 之前这里渲染的是 mock 常量 `_snapshot.tasks`——断网时点开卡片拿不到
  /// 任何真实数据，而且摘要数字是真实的、列表是假的，两者对不上。
  /// 现在本地优先模式下从本地表算出来；空列表时才回落到 mock（离线演示）。
  List<VerificationTask> _tasks = const <VerificationTask>[];

  // ── 缺陷分布 ──
  Map<String, Object?>? _stats;
  ApiException? _statsError;

  /// 首次填充还没跑完（本地空 + `sync.first_fill.completed != '1'`）。
  /// 此时倒计时/分布都显示骨架，并给一行「正在连接服务器」的提示，
  /// 而不是先报「还没有设置考试目标」再把用户吓一跳（任务书 C5 / E4）。
  bool _syncPending = false;

  @override
  void initState() {
    super.initState();
    if (kLocalFirstEnabled) kLocalDataRevision.addListener(_onLocalDataChanged);
    _loadAll();
  }

  /// 首次填充 / 后台刷新写完了本地表，重读一次（无需用户下拉）。
  void _onLocalDataChanged() {
    if (!mounted) return;
    unawaited(_loadFromLocal());
  }

  @override
  void dispose() {
    if (kLocalFirstEnabled) kLocalDataRevision.removeListener(_onLocalDataChanged);
    _verifyApi.close();
    _defectApi.close();
    super.dispose();
  }

  /// 三段式加载（本地优先 R2）：
  ///   ① 读本地 → 有数据立刻渲染（不等网络，冷启动不再卡 Neon 10–30s）；
  ///   ② 后台打云端刷新（不显示全屏 loading）；
  ///   ③ 刷新写回本地后由 `kLocalDataRevision` 触发重读。
  ///
  /// `kLocalFirstEnabled = false` 时走旧路径（三路并发直连），完全不变。
  Future<void> _loadAll() async {
    if (kUseMock) return;
    if (!kLocalFirstEnabled) {
      await _loadFromCloud();
      return;
    }
    await _loadFromLocal();
    unawaited(_refreshFromCloud());
  }

  /// 旧路径：三路并发。每路自己吞掉异常并记在各自的 error 字段上，
  /// 所以 `Future.wait` 不会因一路失败而整体抛出（也就不会让另两路白拉）。
  Future<void> _loadFromCloud() async {
    await Future.wait<void>(<Future<void>>[
      _loadProfile(),
      _loadSummary(),
      _loadStats(),
    ]);
  }

  /// 本地读取：一次 `Future.wait` 读三块，全部同步完成后再 `setState`，
  /// 避免「倒计时到了、分布还在跳」的中间态。
  Future<void> _loadFromLocal() async {
    try {
      final bool hasData = await localHasAnyData();
      // 首次填充是否已跑完：未跑完时「本地为空」只意味着「还没拉下来」，
      // 不能当成「确定没有数据」——两者的 UI 语义完全不同（任务书 C5）。
      final bool fillDone = hasData || await isFirstFillComplete();
      if (!fillDone) {
        if (!mounted) return;
        setState(() {
          _profile = null;
          _summary = null;
          _stats = null;
          _profileError = null;
          _summaryError = null;
          _statsError = null;
          // 关键：保持 false，让倒计时继续显示骨架而不是「还没有设置考试目标」。
          _profileLoaded = false;
          _syncPending = true;
        });
        return;
      }
      final Map<String, Object?>? profile = await loadActiveExamProfile(kDemoUserId);
      final vapi.VerificationSummary summary = await loadVerificationSummary(kDemoUserId);
      final Map<String, Object?> stats = await loadDefectStats(kDemoUserId);
      // R4b：今日待验证也从本地算，不再渲染 mock。
      final List<vapi.VerificationTask> rawTasks = await loadVerificationTasks(kDemoUserId);
      AppLogger.instance.info('LOCAL', '读取验证任务 ${rawTasks.length} 条');
      final List<VerificationTask> tasks = rawTasks.map(_toHomeTask).toList();
      if (!mounted) return;
      setState(() {
        // 三块已是「本地真实值」，不再标降级：离线也能读到的数据不该带「离线数据」标记。
        _profile = profile;
        _summary = summary;
        _tasks = tasks;
        _stats = stats;
        _profileError = null;
        _summaryError = null;
        _statsError = null;
        _profileLoaded = true;
        _syncPending = false;
      });
    } catch (e) {
      // 本地库异常（极少见：磁盘满、文件损坏）→ 记日志并保持骨架，
      // 不要在这里把页面变成错误页：后台刷新若成功仍可救回来。
      debugPrint('[home] 本地读取失败：$e');
    }
  }

  /// 后台刷新：失败只在日志里 warn，本地数据继续可用。
  Future<void> _refreshFromCloud() async {
    try {
      await refreshLocalFromCloud();
    } catch (e) {
      debugPrint('[home] 后台刷新异常：$e');
    }
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

  /// 下拉刷新。
  ///
  /// 本地优先模式下：**先读本地（立即出结果）→ 再等一次云端刷新完成**，
  /// 这样下拉手势会真的转圈到网络回来，用户能看到「刷新了」的反馈，
  /// 而中途本地数据一直在（不会白屏）。
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
    if (kLocalFirstEnabled) {
      await _loadFromLocal();
      await refreshLocalFromCloud();
      await _loadFromLocal();
      return;
    }
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

  /// 「今日待验证」摘要位点击 → push 验证任务页。
  ///
  /// Tab 从 5 个瘦成 3 个后，验证不再是 Tab 之一（旧代码里固定切索引 2，
  /// 而现在索引 2 是「我的」）——继续用切 Tab 会把用户送到错误页面，
  /// 所以一律改 push，导航意图不再依赖数字索引。
  void _openVerify() {
    Navigator.of(context).push<void>(appRoute<void>(context, const VerifyPage()));
  }

  /// 考试配置（m18680 D1）：从「我的」也可以进，但首页空目标卡片直接跳更顺手。
  void _openExamConfig() {
    Navigator.of(context)
        .push<void>(appRoute<void>(context, const ExamConfigPage()));
  }

  /// 缺陷单 id 必须是 UUID（v4 或服务端 `gen_random_uuid()`）。
  ///
  /// m18680 B2：历史上「今日待验证」在本地为空时会回落 mock 三张卡，
  /// 那些卡的 id 是 `dt-v1-001` 这类硬编码串。点开就会把非 UUID 发给后端，
  /// PG 报 22P02，被 `httpError` 吞成 500 —— 用户看到「服务器错误」。
  /// 现在列表不再回落 mock，但旧本地缓存 / 旧深链里仍可能有脏 id，
  /// 所以在发请求前统一拦一道。
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  bool _isUuid(String value) => _uuidPattern.hasMatch(value.trim());

  void _onTapTask(VerificationTask task) {
    // 非法 id：不发请求，直接提示刷新（硬约束「非法 id 防御必须做」）。
    if (!_isUuid(task.id)) {
      _toast('数据异常', '这条待验证记录缺少有效的缺陷单编号，请下拉刷新后重试。');
      return;
    }
    // R4b：本地优先时直接进缺陷单详情（详情页自己会从本地表读完整数据），
    // 断网也能看到归因、动作与验证进度；读不到才回落到验证任务页。
    if (kLocalFirstEnabled && !kUseMock) {
      unawaited(_openTaskDetail(task.id));
      return;
    }
    _openVerify();
  }

  /// 打开某张缺陷单的详情页：先从本地表取完整单（离线可用），
  /// 取不到再回落云端。
  Future<void> _openTaskDetail(String ticketId) async {
    try {
      DefectTicket? ticket = await loadDefectTicketById(kDemoUserId, ticketId);
      if (ticket == null) {
        ticket = await _defectApi.fetchDefectDetail(ticketId);
      }
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        appRoute<void>(context, DefectDetailPage(ticket: ticket)),
      );
      if (mounted) await _loadFromLocal();
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(
        '打开详情',
        e.isNetworkError
            ? '无法连接后端，且本地没有这条缺陷单。'
            : '打开详情失败（HTTP ${e.statusCode}）',
      );
    }
  }

  /// 把 API 层的验证任务转成首页卡片用的模型（字段名不同，见 home_mock）。
  VerificationTask _toHomeTask(vapi.VerificationTask t) {
    return VerificationTask(
      id: t.id,
      knowledgeNodeTitle: (t.knowledgeNodeTitle ?? '').trim().isEmpty
          ? '未关联考点'
          : t.knowledgeNodeTitle!,
      subjectName: (t.subjectName ?? '').trim().isEmpty ? '未分类科目' : t.subjectName!,
      stage: t.stage,
      daysLeft: t.daysLeft,
      urgency: TaskUrgency.fromWire(t.urgency),
    );
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
        onSetup: _openExamConfig,
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
    final vapi.VerificationSummary? summary = _summary;
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

  /// 今日待验证的列表体。
  ///
  /// m18680 B2：以前 `_tasks.isEmpty ? _snapshot.tasks : _tasks` —— 本地为空时
  /// 回落到 mock 三张卡，而摘要数字是真实值，两者对不上；点卡片还会把
  /// `dt-v1-001` 这类非 UUID 发给后端（500）。现在三种状态分开：
  ///   · 首次同步中（`_syncPending`）→ 轻量占位，不冒充真实任务；
  ///   · 已同步完、确实没有待验证 → 空状态文案；
  ///   · 有数据 → 真实列表。
  /// `kUseMock`（离线演示 / widget test）仍直接用 mock，保持旧行为。
  Widget _buildTaskList() {
    if (kUseMock) {
      return TaskListCard(tasks: _snapshot.tasks, onTapTask: _onTapTask);
    }
    if (_tasks.isNotEmpty) {
      return TaskListCard(tasks: _tasks, onTapTask: _onTapTask);
    }
    if (_syncPending) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.cardPadding,
          vertical: 20,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const <Widget>[
            CupertinoActivityIndicator(radius: 6),
            SizedBox(width: 8),
            Text(
              '正在同步验证任务…',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: AppColors.secondaryLabel,
              ),
            ),
          ],
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: <Widget>[
          Icon(
            CupertinoIcons.check_mark_circled,
            size: 28,
            color: AppColors.normal,
          ),
          SizedBox(height: 8),
          Text(
            '今天没有待验证的题',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              color: AppColors.label,
            ),
          ),
          SizedBox(height: 4),
          Text(
            '进入验证阶段后会出现在这里。',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.secondaryLabel,
            ),
          ),
        ],
      ),
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

  /// 「复盘」：push 复盘页。
  ///
  /// 以前是切到第 5 个 Tab。Tab 瘦成 3 个后复盘不再是分区之一，
  /// 切 Tab 已不可能，改 push（复盘页内部自带列表→详情的二级栈，
  /// 返回手势会逐层退，不会把用户直接弹回首页）。
  void _openReview() {
    Navigator.of(context).push<void>(appRoute<void>(context, const ReviewPage()));
  }

  /// 「设置」：push 设置页（原来在 trailing 里的诊断/日志入口已收进此页）。
  void _openSettings() {
    Navigator.of(context).push<void>(appRoute<void>(context, const SettingsPage()));
  }

  /// 「开始模考」：直接进组卷配置页（考试目标 / 模式 / 范围 / 题量 / 限时）。
  ///
  /// 不在这里预取 profile：配置页自己会拉考试目标并展示成 chips，
  /// 用户可能想为「另一个考试目标」组卷——首页只负责导航。
  Future<void> _openMockCreate() async {
    if (kUseMock) {
      _toast('限时模考', '离线演示模式（kUseMock=true）下无法组卷。');
      return;
    }
    await Navigator.of(context).push<bool>(
      appRoute<bool>(context, const MockCreatePage()),
    );
  }
  /// 「开始练习」：push 练习配置页（练习模式 R1）。
  ///
  /// 与「开始模考」并列但语义不同：模考限时、生成报告、走 mock_exams；
  /// 练习不限时、客户端判分、走 practice_sessions。
  Future<void> _openPracticeConfig() async {
    if (kUseMock) {
      _toast('开始练习', '离线演示模式（kUseMock=true）下无法抽题。');
      return;
    }
    await Navigator.of(context).push<void>(
      appRoute<void>(context, const PracticeConfigPage()),
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
          CupertinoSliverNavigationBar(
            largeTitle: const Text(
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
            middle: const Text('题路'),
            border: const Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
            // 右上角只留一个齿轮：连接诊断 / 导出日志 两个调试入口已迁到设置页。
            // 首页是每天看数据的地方，不该摆排障工具；设置页里它们还能跟
            // 「切换 Token」「清除缓存」放在一起，排查时不用来回跳。
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: _openSettings,
              child: const Icon(
                CupertinoIcons.gear,
                size: 22,
                color: AppColors.accent,
              ),
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
                  // 首次填充进行中：明说一句「正在连接服务器」，
                  // 避免用户把骨架当成卡死（任务书 E4）。
                  if (_syncPending) ...<Widget>[
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        const CupertinoActivityIndicator(radius: 6),
                        const SizedBox(width: 8),
                        Text(
                          '正在连接服务器，首次同步中…',
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 13,
                            color: AppColors.secondaryLabel,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  SectionHeader(
                    text: '今日待验证',
                    trailing: _summaryTrailing(),
                  ),
                  _CardShell(
                    child: _buildTaskList(),
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
                        onTap: _openMockCreate,
                      ),
                      QuickAction(
                        icon: CupertinoIcons.chart_bar,
                        label: '复盘',
                        onTap: _openReview,
                      ),
                      QuickAction(
                        icon: CupertinoIcons.pencil_outline,
                        label: '开始练习',
                        onTap: _openPracticeConfig,
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

