// 题目选择器（m21780）。
//
// ── 为什么需要它 ────────────────────────────────────────────────────────
// 提交验证时「关联题目」原来是一格手输 UUID 的输入框。人记不住 UUID，
// 也没有地方能查到它 —— 这个字段事实上永远是空的，而它恰恰是把
// 「这次做错的题」与「同名考点下的同类错误」聚起来的唯一外键。
// 本页把那一格换成「从题库里挑一道题」。
//
// ── 搜索/筛选的分工（刻意如此）──────────────────────────────────────────
// · 题干关键字 q 与考点 knowledge_node_id 走**后端**：题库可能上千条，
//   本地过滤只能过滤已加载的那 50 条，会漏。
// · 来源（我导入的 / 公共题）、题型、导入时间走**前端**：这三项都是当前
//   已加载集合的属性，且后端 `GET /questions` 的返回已经带 owner_user_id
//   与 created_at，本地算既省一次往返也不会漏（因为分页时逐页都过滤）。
//   注意：本地过滤 + 分页时，「本页被过滤光了」不代表没有下一页，
//   所以 `_loadMore` 的终止条件永远是 `items.length < limit`（原始条数），
//   绝不能看过滤后的条数。
//
// ── 防抖 ────────────────────────────────────────────────────────────────
// 300ms Timer（不引 rxdart）。每次输入先 cancel 上一个 Timer，再起新的；
// 页面 dispose 时必须 cancel，否则会 setState after dispose。
//
// ── 选中结果 ────────────────────────────────────────────────────────────
// pop 回 `_PickedQuestion`（id + stem）。只回 id 也能用，但验证页要显示
// 「已选：题干前 30 字」，多带一个题干能省掉一次详情请求。

import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
import '../api/question_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';

/// 选择器返回给调用方的结果。
@immutable
class PickedQuestion {
  const PickedQuestion({required this.id, required this.stem});

  final String id;
  final String stem;

  /// 「已选」行里展示的短题干。
  String get shortStem {
    final String flat = stem.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= 30) return flat;
    return '${flat.substring(0, 30)}…';
  }
}

/// 来源筛选。
enum _SourceFilter {
  all('全部', null),
  mine('我导入的', 'mine'),
  public('公共题', 'public');

  const _SourceFilter(this.label, this.wire);

  final String label;
  final String? wire;

  bool matches(BankQuestion q) => switch (this) {
        _SourceFilter.all => true,
        _SourceFilter.mine => q.isMine,
        _SourceFilter.public => !q.isMine,
      };
}

/// 题型筛选（取值是后端 `questions.type` 的 wire 形式）。
enum _TypeFilter {
  all('全部', null),
  choice('单选', 'choice'),
  multi('多选', 'multi'),
  judge('判断', 'judge');

  const _TypeFilter(this.label, this.wire);

  final String label;
  final String? wire;

  bool matches(BankQuestion q) => wire == null || q.type == wire;
}

/// 导入时间筛选。
enum _TimeFilter {
  all('全部', null),
  last7('最近 7 天', 7),
  last30('最近 30 天', 30);

  const _TimeFilter(this.label, this.days);

  final String label;
  final int? days;

  /// `created_at` 缺失时按「不在窗口内」处理：宁可少显示，也不把时间不明的
  /// 旧题混进「最近 7 天」里误导用户。
  bool matches(BankQuestion q, DateTime now) {
    if (days == null) return true;
    final DateTime? created = q.createdAt;
    if (created == null) return false;
    return now.difference(created).inDays <= days!;
  }
}

class QuestionPickerPage extends StatefulWidget {
  const QuestionPickerPage({super.key, this.initialSelectedId});

  /// 已选中的题 id（进来时高亮那一条）。
  final String? initialSelectedId;

  @override
  State<QuestionPickerPage> createState() => _QuestionPickerPageState();
}

class _QuestionPickerPageState extends State<QuestionPickerPage> {
  static const int _pageSize = 50;
  static const Duration _debounce = Duration(milliseconds: 300);

  final QuestionApi _api = QuestionApi();

  final TextEditingController _search = TextEditingController();
  Timer? _debounceTimer;

  /// 后端已返回的原始集合（分页累加）。筛选在前端对它做投影。
  List<BankQuestion> _items = const <BankQuestion>[];

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  _SourceFilter _source = _SourceFilter.all;
  _TypeFilter _type = _TypeFilter.all;
  _TimeFilter _time = _TimeFilter.all;

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    // 顺序要紧：先停 Timer，再 dispose controller 与 ScrollController。
    _debounceTimer?.cancel();
    _search.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _api.close();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final double remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 400) _loadMore();
  }

  void _onSearchChanged(String _) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
      if (!mounted) return;
      _load(reset: true);
    });
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final List<BankQuestion> page = await _api.fetchQuestions(
        q: _search.text,
        limit: _pageSize,
        offset: 0,
        currentUserId: kDemoUserId,
      );
      if (!mounted) return;
      setState(() {
        _items = page;
        // 终止条件只能看**原始条数**，不能看过滤后的条数。
        _hasMore = page.length >= _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.isNetworkError ? '无法连接后端，请检查网络' : '加载题目失败（HTTP ${e.statusCode}）';
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载题目失败：$e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final List<BankQuestion> page = await _api.fetchQuestions(
        q: _search.text,
        limit: _pageSize,
        offset: _items.length,
        currentUserId: kDemoUserId,
      );
      if (!mounted) return;
      setState(() {
        // 去重：后端按 created_at DESC 排序，翻页期间若有新题插入，
        // 同一条可能出现在两页里，按 id 去重避免列表出现重复卡片。
        final Set<String> seen = _items.map((BankQuestion q) => q.id).toSet();
        _items = <BankQuestion>[
          ..._items,
          ...page.where((BankQuestion q) => !seen.contains(q.id)),
        ];
        _hasMore = page.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      // 翻页失败不打断已有列表，只停掉「还有更多」避免无限重试。
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
    }
  }

  List<BankQuestion> get _visible {
    final DateTime now = DateTime.now();
    return _items
        .where((BankQuestion q) =>
            _source.matches(q) &&
            _type.matches(q) &&
            _time.matches(q, now))
        .toList(growable: false);
  }

  bool get _hasAnyFilter =>
      _source != _SourceFilter.all ||
      _type != _TypeFilter.all ||
      _time != _TimeFilter.all ||
      _search.text.trim().isNotEmpty;

  void _clearAll() {
    _debounceTimer?.cancel();
    _search.clear();
    setState(() {
      _source = _SourceFilter.all;
      _type = _TypeFilter.all;
      _time = _TimeFilter.all;
    });
    _load(reset: true);
  }

  void _pick(BankQuestion q) {
    Navigator.of(context).pop(PickedQuestion(id: q.id, stem: q.stem));
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: CustomScrollView(
        controller: _scroll,
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: const Text(
              '选择题目',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                color: AppColors.label,
              ),
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(44, 36),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                '不关联',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(child: _buildSearchBar()),
          SliverToBoxAdapter(child: _buildFilters()),
          // 搜索/翻页时的细进度条。
          // 纯 Cupertino 工程里没有 Material 的 LinearProgressIndicator，也不为
          // 一条进度条去引动画控制器 —— 用一条 3px 实色线做「正在加载」的信号，
          // 高度固定（不加载时是透明占位），避免内容上下跳动。
          SliverToBoxAdapter(
            child: SizedBox(
              height: 3,
              child: _loading || _loadingMore
                  ? ColoredBox(
                      color: AppColors.accent.withValues(alpha: 0.55),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          ..._buildBody(),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: CupertinoSearchTextField(
        controller: _search,
        placeholder: '搜索题干关键字',
        style: const TextStyle(fontFamily: kFontFamily, fontSize: 15),
        onChanged: _onSearchChanged,
        onSubmitted: (_) {
          _debounceTimer?.cancel();
          _load(reset: true);
        },
        onSuffixTap: () {
          _debounceTimer?.cancel();
          _search.clear();
          _load(reset: true);
        },
      ),
    );
  }

  Widget _buildFilters() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: <Widget>[
          for (final _SourceFilter v in _SourceFilter.values)
            _FilterChip(
              label: v.label,
              selected: _source == v,
              onTap: () => setState(() => _source = v),
            ),
          const _FilterDivider(),
          for (final _TypeFilter v in _TypeFilter.values)
            _FilterChip(
              label: v.label,
              selected: _type == v,
              onTap: () => setState(() => _type = v),
            ),
          const _FilterDivider(),
          for (final _TimeFilter v in _TimeFilter.values)
            _FilterChip(
              label: v.label,
              selected: _time == v,
              onTap: () => setState(() => _time = v),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildBody() {
    if (_loading && _items.isEmpty) {
      return const <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CupertinoActivityIndicator(radius: 12)),
        ),
      ];
    }

    if (_error != null && _items.isEmpty) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _ErrorView(
            message: _error!,
            onRetry: () => _load(reset: true),
          ),
        ),
      ];
    }

    final List<BankQuestion> visible = _visible;

    if (visible.isEmpty) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyView(
            hasFilter: _hasAnyFilter,
            onClear: _clearAll,
          ),
        ),
      ];
    }

    return <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        sliver: SliverToBoxAdapter(
          child: Text(
            '共 ${visible.length} 道'
            '${_hasAnyFilter ? '（已筛选）' : ''}',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.secondaryLabel,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        sliver: SliverList.list(
          children: <Widget>[
            for (final BankQuestion q in visible)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _PickerCard(
                  question: q,
                  selected: q.id == widget.initialSelectedId,
                  onTap: () => _pick(q),
                ),
              ),
          ],
        ),
      ),
      if (_loadingMore)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CupertinoActivityIndicator(radius: 10)),
          ),
        ),
      if (!_hasMore && visible.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 24),
            child: Center(
              child: Text(
                '没有更多了',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  color: AppColors.tertiaryLabel,
                ),
              ),
            ),
          ),
        ),
    ];
  }
}

/// 一道可选中的题：题干前 2 行 + 题型 / 来源 / 「我导入的」徽标。
class _PickerCard extends StatelessWidget {
  const _PickerCard({
    required this.question,
    required this.selected,
    required this.onTap,
  });

  final BankQuestion question;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadii.card),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.separator,
            width: selected ? 1.5 : 0.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    question.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 15,
                      height: 1.4,
                      color: AppColors.label,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      _Tag(text: question.typeLabel, color: AppColors.accent),
                      const SizedBox(width: 6),
                      _Tag(
                        text: question.isMine ? '我导入的' : '公共题',
                        color: question.isMine
                            ? AppColors.normal
                            : AppColors.secondaryLabel,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (selected) ...<Widget>[
              const SizedBox(width: 8),
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(
                  CupertinoIcons.check_mark_circled_solid,
                  size: 20,
                  color: AppColors.accent,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.chip),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          color: color,
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : AppColors.card,
            borderRadius: BorderRadius.circular(AppRadii.chip + 4),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.separator,
              width: 0.5,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: selected ? const Color(0xFFFFFFFF) : AppColors.label,
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterDivider extends StatelessWidget {
  const _FilterDivider();

  @override
  Widget build(BuildContext context) {
    // 纯 Cupertino 工程里没有 Material 的 VerticalDivider。
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: SizedBox(
          height: 16,
          width: 0.5,
          child: ColoredBox(color: AppColors.separator),
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.hasFilter, required this.onClear});

  final bool hasFilter;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              CupertinoIcons.search_circle_fill,
              size: 44,
              color: AppColors.tertiaryLabel,
            ),
            const SizedBox(height: 12),
            Text(
              hasFilter ? '没有匹配的题目，换个关键词试试' : '题库里还没有题目',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 15,
                color: AppColors.secondaryLabel,
              ),
            ),
            if (hasFilter) ...<Widget>[
              const SizedBox(height: 14),
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: onClear,
                child: const Text(
                  '清空搜索与筛选',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 15,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
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
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                color: AppColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: onRetry,
              child: const Text(
                '重试',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
