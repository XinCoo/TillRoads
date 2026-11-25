import 'dart:async' show unawaited;

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/defect_api.dart';
import '../config/api_config.dart';
import '../config/local_config.dart';
import '../local/local.dart';
import '../logging/app_logger.dart';
import '../mock/defects_mock.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/defect_card.dart';
import 'defect_create_page.dart';
import 'defect_detail_page.dart';

/// 缺陷单列表页（FE-03A）。
///
/// 数据来源有两种（由 `kUseMock` 决定）：
///   · `kUseMock == false`（默认）→ `DefectApi.fetchDefectTickets` 打真实后端
///   · `kUseMock == true` → 使用 `kDefectTickets` 离线演示数据
class DefectsPage extends StatefulWidget {
  const DefectsPage({super.key});

  @override
  State<DefectsPage> createState() => _DefectsPageState();
}

class _DefectsPageState extends State<DefectsPage> {
  DefectFilter _filter = DefectFilter.all;

  final DefectApi _api = DefectApi();

  /// null = 正在加载；非 null = 已拿到结果（可能是空列表）
  List<DefectTicket>? _all;
  ApiException? _error;

  /// R4a：单 id → sync_state（只含有本地修改的行）。`_conflicts` 是其中有冲突的。
  Map<String, int> _syncStates = const <String, int>{};
  Set<String> _conflicts = const <String>{};

  /// 建单前要拉考试目标/科目，防止连点两次弹两个页面。
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    if (kLocalFirstEnabled) kLocalDataRevision.addListener(_onLocalDataChanged);
    _load();
  }

  /// 重读本地写队列状态（待同步角标 + 冲突标记）。
  Future<void> _readSyncStates() async {
    if (!kLocalFirstEnabled) return;
    try {
      final Map<String, int> states = await WriteQueueStatus.ticketSyncStates();
      final Set<String> conflicts = await WriteQueueStatus.ticketIdsInConflict();
      if (!mounted) return;
      setState(() {
        _syncStates = states;
        _conflicts = conflicts;
      });
    } catch (e) {
      debugPrint('[defects] 同步状态读取失败：$e');
    }
  }

  /// 首次填充 / 后台刷新写完本地表后重读（无需用户下拉）。
  void _onLocalDataChanged() {
    if (!mounted) return;
    unawaited(_readLocal(firstPaint: false));
    unawaited(_readSyncStates());
  }

  @override
  void dispose() {
    if (kLocalFirstEnabled) kLocalDataRevision.removeListener(_onLocalDataChanged);
    _api.close();
    super.dispose();
  }

  /// 三段式加载（本地优先 R2）。
  ///
  /// `kUseMock` 与 `kLocalFirstEnabled == false` 两条旧路径保持原样：
  /// 前者是离线演示，后者是出问题时改一行开关就能回退的逃生通道。
  Future<void> _load() async {
    if (kUseMock) {
      setState(() {
        _all = null;
        _error = null;
      });
      // 模拟一点延迟，让加载态在离线演示时也能被看到
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      setState(() => _all = List<DefectTicket>.of(kDefectTickets));
      return;
    }

    if (!kLocalFirstEnabled) {
      await _loadFromCloud();
      return;
    }

    await _readLocal(firstPaint: true);
    unawaited(_readSyncStates());
    unawaited(_refreshFromCloud());
  }

  /// 旧路径：直接请求云端（一次拉全量，筛选仍在内存做）。
  Future<void> _loadFromCloud() async {
    setState(() {
      _all = null;
      _error = null;
    });
    try {
      final list = await _api.fetchDefectTickets(kDemoUserId);
      if (!mounted) return;
      setState(() => _all = list);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  /// 本地读取。[firstPaint] 为 true 时才清空 `_all` 进加载态；
  /// 后台刷新触发的重读不能把已有列表清掉（否则会闪一下白屏）。
  Future<void> _readLocal({required bool firstPaint}) async {
    if (firstPaint) {
      setState(() {
        _all = null;
        _error = null;
      });
    }
    try {
      final List<DefectTicket> list = await loadDefectTickets(kDemoUserId);
      AppLogger.instance.info('LOCAL', '读取缺陷单 ${list.length} 条');
      // 本地为空且首次填充还没跑完 → 继续保持加载态（_all 仍为 null）。
      // 直接给空列表会把「还没同步下来」误报成「你确实没有缺陷单」（C5）。
      if (list.isEmpty && !await isFirstFillComplete()) return;
      if (!mounted) return;
      setState(() {
        _all = list;
        _error = null;
      });
    } catch (e) {
      debugPrint('[defects] 本地读取失败：$e');
      if (firstPaint && mounted) setState(() => _all = <DefectTicket>[]);
    }
  }

  /// 后台刷新：失败只记日志，本地列表继续可用（不弹错、不变错误页）。
  Future<void> _refreshFromCloud() async {
    await refreshLocalFromCloud();
  }

  List<DefectTicket> get _visible {
    final all = _all;
    if (all == null) return const <DefectTicket>[];
    return all.where((DefectTicket t) => _filter.matches(t)).toList();
  }

  /// 每个分组下的条数（用于 chip 右侧小数字）
  Map<DefectFilter, int> get _counts {
    final all = _all ?? const <DefectTicket>[];
    final Map<DefectFilter, int> result = <DefectFilter, int>{};
    for (final DefectFilter f in DefectFilter.values) {
      result[f] = all.where((DefectTicket t) => f.matches(t)).length;
    }
    return result;
  }

  void _openDetail(DefectTicket ticket) {
    Navigator.of(context).push<void>(
      appRoute<void>(context, DefectDetailPage(ticket: ticket)),
    );
  }

  /// 建单前要先知道「挂到哪个考试目标的哪个科目下」，这两个 id 只能从后端拿。
  ///
  /// R4a：本地优先时改为**先读本地**——离线也能建单（入队，联网再推）。
  /// 本地没同步过这两个目录表时才回落到云端，云端也拿不到就给出可操作提示。
  Future<void> _openCreate() async {
    if (_creating) return;

    if (kUseMock) {
      _toast('当前是离线演示模式（kUseMock=true），建单不会真的提交。');
      return;
    }

    setState(() => _creating = true);
    try {
      String? profileId;
      String examLabel = '考试目标';
      String? subjectId;
      String? subjectName;

      if (kLocalFirstEnabled) {
        final Map<String, Object?>? profile =
            await loadActiveExamProfile(kDemoUserId);
        if (profile != null) {
          profileId = '${profile['id']}';
          examLabel = '${profile['target_label'] ?? profile['exam_type'] ?? '考试目标'}';
          final Map<String, Object?>? subject =
              await loadFirstSubject(profileId);
          if (subject != null) {
            subjectId = '${subject['id']}';
            subjectName = '${subject['name'] ?? '未命名科目'}';
          }
        }
      }

      // 本地还没有目录数据（首次填充没跑完 / 已关闭本地优先）→ 走云端。
      if (profileId == null || subjectId == null) {
        try {
          final profiles = await _api.fetchExamProfiles(kDemoUserId);
          if (!mounted) return;
          if (profiles.isEmpty) {
            setState(() => _creating = false);
            _toast('还没有考试目标。请先创建考试目标（FE-02）后再建缺陷单。');
            return;
          }
          final Map<String, Object?> first = profiles.first;
          profileId = '${first['id']}';
          examLabel = '${first['target_label'] ?? first['exam_type'] ?? '考试目标'}';
          final subjects = await _api.fetchSubjects(profileId);
          if (!mounted) return;
          if (subjects.isEmpty) {
            setState(() => _creating = false);
            _toast('这个考试目标下还没有科目。请先套用模板或添加科目后再建缺陷单。');
            return;
          }
          final Map<String, Object?> subject = subjects.first;
          subjectId = '${subject['id']}';
          subjectName = '${subject['name'] ?? '未命名科目'}';
        } on ApiException catch (e) {
          if (!mounted) return;
          setState(() => _creating = false);
          _toast('无法获取考试目标：${e.message}');
          return;
        }
      }

      setState(() => _creating = false);
      if (!mounted) return;

      final bool? created = await Navigator.of(context).push<bool>(
        appRoute<bool>(
          context,
          DefectCreatePage(
            examProfileId: profileId,
            subjectId: subjectId,
            subjectName: '$examLabel · ${subjectName ?? '未命名科目'}',
          ),
        ),
      );
      if (!mounted) return;
      if (created == true) {
        await _load();
        if (!mounted) return;
        _toast(kLocalDbReady ? '缺陷单已保存，联网后会自动同步。' : '缺陷单已创建。');
      }
    } finally {
      if (mounted && _creating) setState(() => _creating = false);
    }
  }

  void _toast(String message) {
    showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            message,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '知道了',
              style: TextStyle(fontFamily: kFontFamily),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<DefectTicket> visible = _visible;

    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: const Text(
              '缺陷单',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.37,
                color: AppColors.label,
              ),
            ),
            middle: const Text(
              '缺陷单',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.label,
                letterSpacing: -0.4,
              ),
            ),
            trailing: CupertinoButton(
              padding: const EdgeInsets.only(right: 8),
              onPressed: _creating ? null : _openCreate,
              child: const Text(
                '新建',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
            border: const Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                8,
                AppSpacing.page,
                12,
              ),
              child: FilterChipRow(
                selected: _filter,
                onChanged: (DefectFilter f) => setState(() => _filter = f),
                counts: _counts,
              ),
            ),
          ),
          if (_all == null && _error == null)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CupertinoActivityIndicator(radius: 14)),
            )
          else if (_error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.page),
                child: _LoadErrorView(
                  error: _error!,
                  onRetry: _load,
                ),
              ),
            )
          else if (visible.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                title: '这个分组下没有缺陷单',
                message: '换个筛选条件看看，或者从一次模考、一道错题开始记录。',
                icon: CupertinoIcons.doc_text,
                actionLabel: '全部',
                onAction: () => setState(() => _filter = DefectFilter.all),
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
                itemCount: visible.length,
                separatorBuilder: (_, _) => const SizedBox(
                  height: AppSpacing.cardGap,
                ),
                itemBuilder: (BuildContext context, int index) {
                  final DefectTicket ticket = visible[index];
                  final int syncState = _syncStates[ticket.id] ?? 0;
                  return DefectCard(
                    ticket: ticket,
                    onTap: () => _openDetail(ticket),
                    // R4a：本地改过但还没推上去 → 角标；撞 409 → 橙色冲突角标。
                    pendingSync: syncState != 0,
                    hasConflict: _conflicts.contains(ticket.id),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// 错误态：必须给出「为什么失败」+ 一个可点的重试按钮，
/// 而不是白屏或只有一行「出错了」——任务 D3 明确要求。
class _LoadErrorView extends StatelessWidget {
  const _LoadErrorView({required this.error, required this.onRetry});

  final ApiException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // 传输层失败（后端没起）与业务错误（4xx/5xx）文案要区别对待：
    // 前者要提示"检查后端"，后者要暴露状态码便于排查。
    final String detail = error.isNetworkError
        ? '后端似乎没有运行。启动方式：\nnode scripts/dev-start.mjs'
        : 'HTTP ${error.statusCode}';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 40,
              color: AppColors.overdue,
            ),
            const SizedBox(height: 12),
            Text(
              '加载失败',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.label,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                color: AppColors.secondaryLabel,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              onPressed: onRetry,
              child: const Text(
                '重试',
                style: TextStyle(fontFamily: kFontFamily),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
