import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/defect_api.dart';
import '../config/api_config.dart';
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
///   · `kUseMock == true`            → `kDefectTickets` 本地假数据（离线演示用）
///
/// 三态：加载中（CupertinoActivityIndicator）/ 出错（错误文案 + 重试）/ 成功。
///
/// 筛选策略说明（重要）：
///   后端 `listByUser` 只支持**单值** `status = $n`，而且「进行中 / 待验证」
///   是多个状态的集合。所以：
///     · 选「全部」→ 不带 status 参数，一次拉全量，分组在本地算
///     · 选具体分组 → 也在本地算（因为需要 OR 多个状态）
///   这样筛选条切换是纯本地操作，不会每次点都打一次网络，交互更跟手。
///   代价是列表一次性拉全量 —— MVP 的缺陷单量级（几十条）完全可接受；
///   真到需要服务端分页时，后端得支持 `status IN (...)`，已记入遗留项。
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _all = null;
      _error = null;
    });

    if (kUseMock) {
      // 模拟一点延迟，让加载态在离线演示时也能被看到
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      setState(() => _all = List<DefectTicket>.of(kDefectTickets));
      return;
    }

    try {
      final list = await _api.fetchDefectTickets(kDemoUserId);
      if (!mounted) return;
      setState(() => _all = list);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
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

  // ─────────── 建单（FE-03 写操作联调 · 任务 B）───────────

  bool _creating = false;

  /// 建单需要 examProfileId + subjectId（后端两列都是 NOT NULL FK）。
  ///
  /// 取法：先拉用户下最新的 exam_profile，再拉它第一个 subject。
  /// 任一拿不到就给出可操作提示，而不是把 null 传给后端换一个 500。
  Future<void> _openCreate() async {
    if (_creating) return;

    if (kUseMock) {
      _toast('当前是离线演示模式（kUseMock=true），建单不会真的提交。');
      return;
    }

    setState(() => _creating = true);
    try {
      final profiles = await _api.fetchExamProfiles(kDemoUserId);
      if (!mounted) return;
      if (profiles.isEmpty) {
        setState(() => _creating = false);
        _toast('还没有考试目标。请先创建考试目标（FE-02）后再建缺陷单。');
        return;
      }

      final Map<String, Object?> first = profiles.first;
      final String profileId = '${first['id']}';
      final String examLabel =
          '${first['target_label'] ?? first['exam_type'] ?? '考试目标'}';
      final subjects = await _api.fetchSubjects(profileId);
      if (!mounted) return;
      if (subjects.isEmpty) {
        setState(() => _creating = false);
        _toast('这个考试目标下还没有科目。请先套用模板或添加科目后再建缺陷单。');
        return;
      }

      final Map<String, Object?> subject = subjects.first;
      final String subjectId = '${subject['id']}';
      final String subjectName = '${subject['name'] ?? '未命名科目'}';
      setState(() => _creating = false);

      final bool? created = await Navigator.of(context).push<bool>(
        appRoute<bool>(
          context,
          DefectCreatePage(
            examProfileId: profileId,
            subjectId: subjectId,
            subjectName: '$examLabel · $subjectName',
          ),
        ),
      );
      if (!mounted) return;
      if (created == true) {
        await _load();
        if (!mounted) return;
        _toast('缺陷单已创建。');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      _toast(
        e.isNetworkError ? '${e.message}\n请确认后端在运行。' : e.message,
      );
    }
  }

  /// 统一的轻提示（为什么不用 SnackBar：纯 Cupertino 工程没有 Material 的
  /// ScaffoldMessenger；CupertinoAlertDialog 又要逐 Text 覆盖字体，包一层
  /// 避免在各处重复写五段 TextStyle）。
  void _toast(String message) {
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

  /// 列表点进详情：传 ticket 同时把 id 传过去。
  ///
  /// 详情页在真实 API 模式下会用 id 重新拉一次（拿 verifications/actions），
  /// 但先展示列表已有的数据，避免白屏等待。
  void _openDetail(DefectTicket ticket) {
    // appRoute 在 Reduce Motion 下自动降级为 200ms 淡入淡出，
    // 否则用 CupertinoPageRoute（右滑入 + 旧页 30% 视差）
    Navigator.of(context).push(
      appRoute<void>(context, DefectDetailPage(ticket: ticket)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<DefectTicket> visible = _visible;
    final bool loading = _all == null && _error == null;
    final bool failed = _error != null;

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
                letterSpacing: -0.4,
                color: AppColors.label,
              ),
            ),
            // 大标题展开时不重复显示中间的「缺陷单」
            alwaysShowMiddle: false,
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
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

          // ── 筛选条（随内容一起滚动）──
          // 加载/出错时不显示：空计数会让用户误以为真的没有数据。
          if (!loading && !failed)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 12),
                child: FilterChipRow(
                  selected: _filter,
                  counts: _counts,
                  onChanged: (DefectFilter next) {
                    if (next == _filter) return;
                    setState(() => _filter = next);
                  },
                ),
              ),
            ),

          // ── 三态 ──
          if (loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: CupertinoActivityIndicator(radius: 14),
              ),
            )
          else if (failed)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _LoadErrorView(error: _error!, onRetry: _load),
            )
          else if (visible.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: CupertinoIcons.doc_text,
                title: '还没有缺陷单',
                message: _filter == DefectFilter.all
                    ? '暂无数据，从一次模考或错题开始'
                    : '「${_filter.label}」分组下暂无缺陷单',
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
                  return DefectCard(
                    ticket: ticket,
                    onTap: () => _openDetail(ticket),
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
        : '${error.message}\n（HTTP ${error.statusCode}）';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(
            CupertinoIcons.exclamationmark_triangle,
            size: 40,
            color: AppColors.dueSoon,
          ),
          const SizedBox(height: 14),
          const Text(
            '加载失败',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppColors.label,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.4,
              color: AppColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 20),
          CupertinoButton.filled(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 10),
            onPressed: onRetry,
            child: const Text(
              '重试',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
