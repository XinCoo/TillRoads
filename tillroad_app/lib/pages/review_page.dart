// 复盘列表页（FE-06 任务 C）——替换 FE-01 的空状态。
//
// ── 为什么一次拉全量、类型切换在本地过滤 ─────────────────────────────────
// 后端 `GET /review-cycles` 支持 `cycle_type` 服务端过滤，但这里刻意不带：
//   ① 切换「日 / 周 / 月」chip 不需要等网络，手感与缺陷单页的筛选条一致；
//   ② 只有拿到全量才能区分「一条复盘都没有」与「该类型下没有记录」这两种
//      空态（任务 C6 明确要求区分），否则得为三种类型各发一次请求来探空。
// 代价是列表一次拉全量 —— MVP 的复盘量级（每人每周一条）完全可接受。
//
// ── 生成流程（任务 C4/C5）──────────────────────────────────────────────
// 右上角「生成复盘」→ ActionSheet 选周期类型 → POST。
//   · 成功：刷新列表 + 直接进详情（用户刚点「生成」，想看的必然是它）。
//   · 409 ALREADY_EXISTS：后端 body 带 `existing_id`，弹窗告知「该周期已有
//     复盘」并提供「查看已有」——直接把那条拉出来进详情，而不是把用户
//     晾在一个错误文案上。
//   · 其余错误：区分「连不上后端」与「HTTP 4xx/5xx」两种文案。
import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/review_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/defect_badges.dart';
import 'review_detail_page.dart';

class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  final ReviewApi _api = ReviewApi();

  /// 当前选中的周期类型。默认「周」——备考最常见的复盘粒度。
  ReviewCycleType _type = ReviewCycleType.weekly;

  /// null = 正在加载；非 null = 已拿到全量结果（可能是空列表）。
  List<ReviewCycle>? _all;
  ApiException? _error;

  /// 生成请求在飞时禁掉按钮，避免连点造出两份（虽然后端会用 409 兜住）。
  bool _creating = false;

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

  /// [silent] 为 true 时不清空 `_all`：用于从详情页返回后的静默刷新，
  /// 避免整页闪一下骨架把用户的滚动位置重置掉。
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _all = null;
        _error = null;
      });
    }

    if (kUseMock) {
      // 离线演示：复盘没有 mock 数据（它天然依赖真实历史），给空列表。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      setState(() => _all = const <ReviewCycle>[]);
      return;
    }

    try {
      final ReviewCyclePage page =
          await _api.fetchReviewCycles(kDemoUserId, limit: 100);
      if (!mounted) return;
      setState(() {
        _all = page.items;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (silent) return; // 静默刷新失败就保持旧数据，不打断用户
      setState(() => _error = e);
    } catch (_) {
      if (!mounted) return;
      if (silent) return;
      setState(() => _error = ApiException('加载复盘记录时出现未知错误'));
    }
  }

  List<ReviewCycle> get _visible {
    final List<ReviewCycle>? all = _all;
    if (all == null) return const <ReviewCycle>[];
    return all
        .where((ReviewCycle c) => c.cycleType == _type)
        .toList(growable: false);
  }

  Map<ReviewCycleType, int> get _counts {
    final List<ReviewCycle> all = _all ?? const <ReviewCycle>[];
    final Map<ReviewCycleType, int> out = <ReviewCycleType, int>{};
    for (final ReviewCycleType t in ReviewCycleType.values) {
      out[t] = all.where((ReviewCycle c) => c.cycleType == t).length;
    }
    return out;
  }

  // ─────────── 生成 ───────────

  Future<void> _generate() async {
    if (_creating) return;

    if (kUseMock) {
      _toast('当前是离线演示模式（kUseMock=true），生成复盘不会真的提交。');
      return;
    }

    final ReviewCycleType? picked = await showCupertinoModalPopup<ReviewCycleType>(
      context: context,
      builder: (BuildContext ctx) => CupertinoActionSheet(
        title: const Text(
          '生成复盘',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        message: const Text(
          '按当前时间算出周期后生成一份快照。\n快照不会随后续数据变化而更新。',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            height: 1.4,
            color: AppColors.secondaryLabel,
          ),
        ),
        actions: <Widget>[
          for (final ReviewCycleType t in ReviewCycleType.values)
            CupertinoActionSheetAction(
              // 不在按钮上预告具体周期字符串：ISO 周/月的计算在后端
              // （review_period.mjs，含 Asia/Shanghai 日界），前端重算一遍
              // 只会引入两处口径不一致的风险。
              onPressed: () => Navigator.of(ctx).pop(t),
              child: Text(
                '生成${t.label}',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 20,
                  fontWeight: FontWeight.w400,
                  color: AppColors.accent,
                ),
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text(
            '取消',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppColors.accent,
            ),
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;

    setState(() => _creating = true);
    try {
      final ReviewCycle created = await _api.createReviewCycle(
        userId: kDemoUserId,
        cycleType: picked.wire,
      );
      if (!mounted) return;
      setState(() {
        _creating = false;
        _type = picked;
      });
      await _load(silent: true);
      if (!mounted) return;
      await _openDetail(created);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);

      // 409 ALREADY_EXISTS 是「这一周期的复盘已经存在」，语义上不是错误，
      // 而是「去查看那份」——body 里有 existing_id 就直接导航过去。
      final Object? body = e.body;
      final Object? existing =
          body is Map ? (body as Map<Object?, Object?>)['existing_id'] : null;
      if (e.statusCode == 409 && existing is String && existing.isNotEmpty) {
        await _handleAlreadyExists(existing, picked);
        return;
      }

      if (e.isNetworkError) {
        _toast('无法连接后端，请确认服务已启动（node scripts/dev-start.mjs）。');
      } else {
        _toast('生成复盘失败（HTTP ${e.statusCode}）：${e.message}');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _creating = false);
      _toast('生成复盘时出现未知错误。');
    }
  }

  Future<void> _handleAlreadyExists(String existingId, ReviewCycleType type) async {
    final bool? go = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '该周期已有复盘',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '${type.label}的当前周期已经生成过一份。\n'
            '如需重新生成：先打开已有那份删除，再生成新的。',
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
            child: const Text(
              '知道了',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                color: AppColors.accent,
              ),
            ),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              '查看已有',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    try {
      final ReviewCycle cycle = await _api.fetchReviewCycle(existingId);
      if (!mounted) return;
      setState(() => _type = cycle.cycleType);
      await _load(silent: true);
      if (!mounted) return;
      await _openDetail(cycle);
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast('打开已有复盘失败（HTTP ${e.statusCode}）：${e.message}');
    }
  }

  Future<void> _openDetail(ReviewCycle cycle) async {
    await Navigator.of(context).push<bool>(
      appRoute<bool>(context, ReviewDetailPage(cycle: cycle)),
    );
    if (!mounted) return;
    // 详情页可能改了 completed 或删掉了这条，回来一律静默刷新。
    await _load(silent: true);
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
              height: 1.45,
            ),
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '好',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
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
    final List<ReviewCycle> visible = _visible;
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
            largeTitle: const Text('复盘'),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: _creating ? null : _generate,
              child: Text(
                _creating ? '生成中…' : '生成复盘',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _creating ? AppColors.tertiaryLabel : AppColors.accent,
                ),
              ),
            ),
            border: const Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),

          // 下拉刷新（静默失败不打断）
          CupertinoSliverRefreshControl(
            onRefresh: () => _load(silent: true),
          ),

          // 周期类型切换条：加载/出错时不显示，避免 0 计数误导
          if (!loading && !failed)
            SliverToBoxAdapter(
              child: _TypeChipRow(
                selected: _type,
                counts: _counts,
                onChanged: (ReviewCycleType next) {
                  if (next == _type) return;
                  setState(() => _type = next);
                },
              ),
            ),

          if (loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CupertinoActivityIndicator(radius: 14)),
            )
          else if (failed)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _LoadErrorView(error: _error!, onRetry: _load),
            )
          else if ((_all ?? const <ReviewCycle>[]).isEmpty)
            // 空态一：这个人从来没生成过复盘
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: CupertinoIcons.chart_bar,
                title: '还没有复盘记录',
                message: '点右上角「生成复盘」，选日 / 周 / 月就能生成一份快照',
                actionLabel: '生成复盘',
                onAction: _generate,
              ),
            )
          else if (visible.isEmpty)
            // 空态二：有复盘，但当前类型下没有 —— 文案必须换，否则用户会以为
            // 数据丢了（这是两个完全不同的状态，任务 C6 要求区分）。
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: CupertinoIcons.chart_bar,
                title: '「${_type.label}」下暂无记录',
                message: '切到其它周期类型看看，或直接生成一份${_type.label}',
                actionLabel: '生成${_type.label}',
                onAction: _generate,
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
                  final ReviewCycle cycle = visible[index];
                  return _CycleCard(
                    cycle: cycle,
                    onTap: () => _openDetail(cycle),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// 日 / 周 / 月三档切换（任务 C2 要求 AnimatedContainer 250ms 过渡）。
class _TypeChipRow extends StatelessWidget {
  const _TypeChipRow({
    required this.selected,
    required this.counts,
    required this.onChanged,
  });

  final ReviewCycleType selected;
  final Map<ReviewCycleType, int> counts;
  final ValueChanged<ReviewCycleType> onChanged;

  @override
  Widget build(BuildContext context) {
    final bool reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final List<ReviewCycleType> all = ReviewCycleType.values;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        8,
        AppSpacing.page,
        12,
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < all.length; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == all.length - 1 ? 0 : 8),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (all[i] != selected) onChanged(all[i]);
                  },
                  child: AnimatedContainer(
                    // Reduce Motion 下直接切色，不做 250ms 插值
                    duration: reduce
                        ? Duration.zero
                        : AppDurations.countdown,
                    curve: Curves.easeInOut,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: all[i] == selected
                          ? AppColors.accent.withValues(alpha: 0.12)
                          : AppColors.card,
                      borderRadius: BorderRadius.circular(AppRadii.chip),
                      border: Border.all(
                        color: all[i] == selected
                            ? AppColors.accent.withValues(alpha: 0.55)
                            : AppColors.separator,
                        width: all[i] == selected ? 1.2 : 0.5,
                      ),
                    ),
                    child: Text(
                      '${all[i].label} ${counts[all[i]] ?? 0}',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 14,
                        fontWeight: all[i] == selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: all[i] == selected
                            ? AppColors.accent
                            : AppColors.secondaryLabel,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 列表卡片：周期 + 完成徽标 + 三格关键指标 + 相对时间。
class _CycleCard extends StatelessWidget {
  const _CycleCard({required this.cycle, required this.onTap});

  final ReviewCycle cycle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ReviewMetrics m = cycle.metrics;

    return PressableCard(
      onTap: onTap,
      child: CardShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        cycle.period,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: AppColors.label,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        cycle.cycleType.label,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 12,
                          color: AppColors.secondaryLabel,
                        ),
                      ),
                    ],
                  ),
                ),
                _CompletedBadge(completed: cycle.completed),
                const SizedBox(width: 4),
                const Icon(
                  CupertinoIcons.chevron_right,
                  size: 16,
                  color: AppColors.tertiaryLabel,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(height: 0.5, color: AppColors.separator),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: _MiniMetric(
                    label: '未关闭缺陷',
                    value: '${m.openDefects.total}',
                  ),
                ),
                Expanded(
                  child: _MiniMetric(
                    label: '验证通过率',
                    value: m.verifyPassRate.ratePercent,
                    // 通过率低于 60% 用橙色提醒：这是「复盘里最该动手的项」
                    color: (m.verifyPassRate.rate ?? 1) < 0.6
                        ? AppColors.dueSoon
                        : null,
                  ),
                ),
                Expanded(
                  child: _MiniMetric(
                    label: '模考稳定性',
                    value: m.mockStability == null
                        ? '—'
                        : m.mockStability!.toStringAsFixed(2),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '生成于 ${_relativeTime(cycle.createdAt)}',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                color: AppColors.tertiaryLabel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11,
            color: AppColors.secondaryLabel,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: color ?? AppColors.label,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _CompletedBadge extends StatelessWidget {
  const _CompletedBadge({required this.completed});

  final bool completed;

  @override
  Widget build(BuildContext context) {
    final Color color =
        completed ? AppColors.normal : AppColors.secondaryLabel;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        completed ? '已完成' : '未读',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
          height: 1.25,
        ),
      ),
    );
  }
}

/// 相对时间：<60s 刚刚 / <60min N 分钟前 / <24h N 小时前 / <30d N 天前 / 更早给日期。
///
/// 未来时间（设备时钟比服务端慢）也会落进 `<= 0` 分支返回「刚刚」，
/// 而不是显示「-3 分钟前」这种让用户困惑的文案。
String _relativeTime(DateTime t) {
  final Duration d = DateTime.now().difference(t);
  if (d.inSeconds <= 60) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays < 30) return '${d.inDays} 天前';
  return '${t.year}-${_two(t.month)}-${_two(t.day)}';
}

String _two(int v) => v < 10 ? '0$v' : '$v';

/// 错误态：与缺陷单页保持同一套文案策略
/// （连不上后端 → 提示启动命令；4xx/5xx → 暴露状态码便于排查）。
class _LoadErrorView extends StatelessWidget {
  const _LoadErrorView({required this.error, required this.onRetry});

  final ApiException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
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
