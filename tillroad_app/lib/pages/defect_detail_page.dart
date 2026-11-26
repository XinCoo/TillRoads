import 'dart:async' show unawaited;

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/defect_api.dart';
import '../config/api_config.dart';
import '../logging/app_logger.dart';
// 只取写队列相关符号：`local.dart` 与 defect_api 都有 forbidden 相关同名函数。
import '../local/local.dart'
    show
        LocalCache,
        LocalValidationException,
        PushScheduler,
        WriteQueue,
        WriteQueueResult,
        WriteQueueStatus,
        kLocalDataRevision,
        kLocalDbReady,
        kLocalFirstEnabled,
        loadDefectTicketById;
import '../mock/defects_mock.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/defect_badges.dart';
import '../widgets/defect_question_list.dart';
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

  /// 关联题目（任务 C4）。后端在详情返回体里带 `questions`，
  /// 也提供 `GET /defect-tickets/:id/questions` 单独拉。
  List<DefectLinkedQuestion> _questions = const <DefectLinkedQuestion>[];
  bool _loadingQuestions = false;
  String? _questionsError;

  /// R4a：这张单的写队列里有 409 冲突（推送被服务端版本号挡下）。
  bool _hasConflict = false;
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
  ///
  /// R4a：本地优先时先读本地库（写操作后能立刻看到乐观结果），再在后台拉云端。
  Future<void> _refreshDetail() async {
    if (kUseMock) return;
    if (kLocalFirstEnabled) {
      await _readLocalDetail();
      unawaited(_refreshConflictFlag());
      unawaited(_refreshFromCloud());
      return;
    }
    await _refreshFromCloud();
  }

  /// R4a：冲突标记不在单行上（它属于队列），要单独查一次。
  Future<void> _refreshConflictFlag() async {
    if (!kLocalFirstEnabled) return;
    try {
      final Set<String> conflicts = await WriteQueueStatus.ticketIdsInConflict();
      if (!mounted) return;
      setState(() => _hasConflict = conflicts.contains(ticket.id));
    } catch (e) {
      debugPrint('[detail] 冲突状态读取失败：$e');
    }
  }

  /// R4a：冲突后用户点「刷新」——先清掉本地冲突操作，再以云端为准重拉。
  Future<void> _resolveConflict() async {
    try {
      await WriteQueueStatus.clearConflicts(ticket.id);
    } catch (e) {
      debugPrint('[detail] 清除冲突失败：$e');
    }
    if (!mounted) return;
    setState(() => _hasConflict = false);
    await _refreshDetail();
    if (!mounted) return;
    _toast(context, '已丢弃本地冲突的修改，并以云端数据为准。');
  }

  Future<void> _readLocalDetail() async {
    try {
      // R4b：改成按 id 直接查单张（`local_id` 或 `server_id` 都认）。
      // 原来拿全量再按 `t.id == id` 在内存里找，而 `t.id` 是 `server_id ?? local_id`，
      // 离线新建 / 推送成功回填 / 页面拿着旧快照这三种情况下都对不上，
      // 表现就是「列表显示 V2、详情还是 V1」。
      final DefectTicket? found =
          await loadDefectTicketById(kDemoUserId, ticket.id);
      if (!mounted || found == null) {
        AppLogger.instance.warn(
          'LOCAL',
          '本地读取缺陷单失败：未找到 id=${ticket.id}',
        );
        return;
      }
      AppLogger.instance.info(
        'LOCAL',
        '读取缺陷单 1 条（status=${found.status.wire}）',
      );
      setState(() {
        ticket = found;
        _refreshError = null;
      });
    } catch (e) {
      AppLogger.instance.warn('LOCAL', '本地读取缺陷单失败：$e');
      debugPrint('[detail] 本地读取失败：$e');
    }
  }


  Future<void> _refreshFromCloud() async {
    if (kUseMock) return;
    try {
      final detail = await _api.fetchDefectDetail(widget.ticket.id);
      // R4a：把详情（含 actions / verifications）落到本地。
      //
      // 没有这一步，ANALYZED / ACTION_DONE 的单在离线时就找不到处理动作：
      // 后台刷新只补 kChildRefreshStatuses（V2/V3）的子行，其余状态永远没缓存。
      // 写入失败不影响 UI（页面已经从云端拿到数据了）。
      if (kLocalFirstEnabled) {
        try {
          await LocalCache.cacheTicketDetail(detail);
        } catch (e) {
          debugPrint('[detail] 详情缓存写入失败：$e');
        }
      }
      if (!mounted) return;
      setState(() {
        ticket = detail;
        _refreshError = null;
      });
      // 详情返回体里新增了 `questions` 字段，但为了兼容后端旧版本，
      // 这里单独再拉一次关联题目列表（接口更轻，失败不影响详情）。
      unawaited(_syncQuestionsFromDetail());
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _refreshError = e);
    }
  }

  // ─────────── 关联题目（任务 C4）───────────

  /// 拉取这张单关联的题目（按 sort ASC）。
  /// 详情返回体里的 `questions` 数组（任务 C4）。
  ///
  /// 后端给 `GET /defect-tickets/:id` 加了 `questions` 字段，优先用它；
  /// 若返回里没有（后端版本较旧），再退回单独的关联题目接口。
  Future<void> _syncQuestionsFromDetail() async {
    try {
      final List<DefectLinkedQuestion> fromDetail =
          await _api.fetchDetailQuestions(widget.ticket.id);
      if (!mounted) return;
      if (fromDetail.isEmpty) {
        await _refreshQuestions();
        return;
      }
      setState(() {
        _questions = fromDetail;
        _loadingQuestions = false;
        _questionsError = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      debugPrint('[detail] 详情里的关联题目读取失败：${e.message}');
      await _refreshQuestions();
    }
  }

  /// 拉取这张单关联的题目（按 sort ASC）。
  Future<void> _refreshQuestions() async {
    if (kUseMock) return;
    if (!mounted) return;
    setState(() => _loadingQuestions = true);
    try {
      final List<DefectLinkedQuestion> list =
          await _api.fetchLinkedQuestions(widget.ticket.id);
      if (!mounted) return;
      setState(() {
        _questions = list;
        _loadingQuestions = false;
        _questionsError = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingQuestions = false;
        _questionsError = e.message;
      });
    }
  }

  /// 批量关联题目。后端对重复关联返回 409 `duplicate_defect_question`，
  /// 这里逐个提交并如实统计「已在列表中」的数量。
  Future<void> _linkQuestions(List<String> questionIds) async {
    if (questionIds.isEmpty) return;
    int added = 0;
    int skipped = 0;
    String? failure;
    for (final String id in questionIds) {
      try {
        await _api.linkQuestion(widget.ticket.id, id);
        added++;
      } on ApiException catch (e) {
        final Object? body = e.body;
        final String code =
            body is Map && body['error'] != null ? '${body['error']}' : '';
        if (code == 'duplicate_defect_question') {
          skipped++;
          continue;
        }
        failure = e.message;
        break;
      }
    }
    await _refreshQuestions();
    if (!mounted) return;
    final List<String> parts = <String>[];
    if (added > 0) parts.add('已关联 $added 道题');
    if (skipped > 0) parts.add('$skipped 道已在列表中');
    if (failure != null) parts.add(failure);
    _toast(context, parts.isEmpty ? '没有新增关联' : parts.join('，'));
  }

  /// 移除一道关联题目。
  Future<void> _unlinkQuestion(String questionId) async {
    try {
      await _api.unlinkQuestion(widget.ticket.id, questionId);
      await _refreshQuestions();
      if (!mounted) return;
      _toast(context, '已移除该题关联。');
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(context, '移除失败：${e.message}');
    }
  }

  /// 拖拽排序后提交新顺序（PUT /defect-tickets/:id/questions/sort）。
  Future<void> _reorderQuestions(List<String> orderedQuestionIds) async {
    final List<String> previous =
        _questions.map((DefectLinkedQuestion q) => q.questionId).toList();
    // 先本地更新，避免等网络返回时列表“弹回去”。
    setState(() {
      final Map<String, DefectLinkedQuestion> byId = <String, DefectLinkedQuestion>{
        for (final DefectLinkedQuestion q in _questions) q.questionId: q,
      };
      _questions = orderedQuestionIds
          .map((String id) => byId[id])
          .whereType<DefectLinkedQuestion>()
          .toList(growable: false);
    });
    try {
      await _api.reorderLinkedQuestions(widget.ticket.id, orderedQuestionIds);
      if (!mounted) return;
      _toast(context, '顺序已保存。');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        final Map<String, DefectLinkedQuestion> byId =
            <String, DefectLinkedQuestion>{
          for (final DefectLinkedQuestion q in _questions) q.questionId: q,
        };
        _questions = previous
            .map((String id) => byId[id])
            .whereType<DefectLinkedQuestion>()
            .toList(growable: false);
      });
      _toast(context, '排序保存失败：${e.message}');
    }
  }

  // ─────────── 写操作（FE-03 写操作联调）───────────

  bool _busy = false;

  /// 统一报错：后端的业务错误用 ApiException.body['error'] 判别。
  void _handleWriteError(Object e) {
    if (e is LocalValidationException) {
      // 本地状态机拦截（R4a）：没落库，也没发网络。把业务码翻成用户能懂的一句话。
      setState(() => _busy = false);
      switch (e.code) {
        case 'NO_ACTIONS':
          _toast(context, '先添加至少一条处理动作，再进入验证。');
        case 'ACTIONS_NOT_DONE':
          _toast(context, '还有处理动作未完成，全部勾选后才能进入验证。');
        case 'ILLEGAL_DEFECT_TRANSITION':
          _toast(context, '当前状态不支持这个操作，请返回列表刷新后重试。');
        case 'DUPLICATE_VERIFICATION':
          _toast(context, '本轮验证已提交过，不能重复提交。');
        case 'TICKET_NOT_FOUND':
          _toast(context, '本地找不到这张单，请下拉刷新后重试。');
        default:
          _toast(context, e.message);
      }
      return;
    }
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
      // R4b：写路径判据改为 `kLocalDbReady`（本地库能不能用），
      // 不再用 `kLocalFirstEnabled`——后者失败时会连写操作一起关掉。
      if (kLocalDbReady) {
        final WriteQueueResult queued = await WriteQueue.enqueueMarkAction(
          ticketId: ticket.id,
          actionId: action.id,
          done: true,
        );
        AppLogger.instance.info(
          'QUEUE',
          '入队 markAction op_id=${queued.opId}'
          '（action=${action.id} done=true）',
        );
        if (!mounted) return;
        setState(() => _busy = false);
        kLocalDataRevision.value++;
        PushScheduler.schedule();
        await _refreshDetail();
        return;
      }
      await _api.markActionDone(
        ticket.id,
        action.id,
        done: true,
        // R4a：后端这条端点的乐观锁作用在 **action 行自己** 的 version 上，
        // 不是缺陷单的 version。用 action.version。
        version: action.version,
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
      // R4b：同上，写路径只看本地库是否可用。
      if (kLocalDbReady) {
        // 本地只乐观前进到 V1；云端那一步是两跳（version +2），推送前会先拉最新版本。
        final WriteQueueResult queued = await WriteQueue.enqueueBeginVerification(
          ticketId: ticket.id,
          baseVersion: ticket.version,
        );
        AppLogger.instance.info(
          'QUEUE',
          '入队 beginVerification op_id=${queued.opId}'
          '（本地 status=${queued.status}）',
        );
        if (!mounted) return;
        setState(() => _busy = false);
        kLocalDataRevision.value++;
        PushScheduler.schedule();
        await _refreshDetail();
        if (!mounted) return;
        _toast(context, '已进入第 1 次验证（V1），联网后会自动同步。');
        return;
      }
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
      // R4b：本地优先时不能说「已提交」——那会让人以为云端已经收到。
      // 实际是「已保存到本地，联网后自动同步」。
      _toast(
        context,
        kLocalDbReady
            ? '归因已保存，联网后会自动同步。'
            : '归因已提交，状态推进到「已归因」。',
      );
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
      // R4b：同上，写入本地 ≠ 云端已收到。措辞要区分「已保存」与「已提交」。
      final String message = kLocalDbReady
          ? (closed
              ? '验证已保存，联网后会自动同步（通过后缺陷单将关闭）。'
              : '已提交，联网后自动同步。')
          : (closed ? '三次验证全部通过，缺陷单已关闭。' : '验证已提交，状态已推进。');
      _toast(context, message);
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
                        // R4a：这张单的离线修改被服务端版本号挡下了。
                        // 只给一条橙色提示 + 「刷新」，字段级仲裁留给 R4b。
                        if (_hasConflict)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _ConflictBanner(onRefresh: _resolveConflict),
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
                              // 6. 关联题目数量（任务 C4）
                              InfoRow(
                                label: '关联题目',
                                value: InfoText('${_questions.length} 道'),
                              ),
                              // 7. 动作数（最后一行不留底部间距）
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
                        // ─────────── 关联题目（任务 C4）───────────
                        //
                        // 放在页面末尾而不是「基本信息」旁边：详情页首屏要同时露出
                        // 基本信息 / 处理动作 / 三次验证 三个区块，插入中间的关联题目
                        // 列表会把后两者挤到折叠线以下。基本信息卡片里已经有「关联题目
                        // N 道」这一行给出数量提示。
                        const SizedBox(height: 20),
                        const SectionHeader(text: '关联题目'),
                        CardShell(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              DefectQuestionList(
                                questions: _questions,
                                loading: _loadingQuestions,
                                questionLoader: () =>
                                    _api.fetchSelectableQuestions(),
                                onReorder: _reorderQuestions,
                                onRemove: _unlinkQuestion,
                                onLink: _linkQuestions,
                              ),
                              if (_questionsError != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    '关联题目加载失败：$_questionsError',
                                    style: const TextStyle(
                                      fontFamily: kFontFamily,
                                      fontSize: 12,
                                      color: AppColors.overdue,
                                    ),
                                  ),
                                ),
                            ],
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

/// R4a：离线修改撞上服务端版本号时的橙色提示条。
///
/// 这一轮只做「提示 + 以云端为准重新拉取」，不做字段级仲裁（R4b）。
class _ConflictBanner extends StatelessWidget {
  const _ConflictBanner({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.dueSoon.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.chip),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            CupertinoIcons.exclamationmark_triangle,
            size: 18,
            color: AppColors.dueSoon,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '该单已被修改，请刷新后重试',
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
            onPressed: () {
              unawaited(onRefresh());
            },
            child: const Text(
              '刷新',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.dueSoon,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
