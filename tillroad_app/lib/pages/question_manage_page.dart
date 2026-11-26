// 题库管理页（m26090 练习模式 R3）。
//
// ── 这一页解决什么问题 ──────────────────────────────────────────────────
// R2 加了掌握度标记后，用户反馈：「题库里已掌握的题我不想再看到」。
// R3 的做法是给题库加一个「移除」动作：
//   * 移除 = 软删（deleted_at），**连模考组卷都抽不到**（组卷 SQL 里恒带
//     `deleted_at IS NULL`），这跟「隐藏」只是不显示、仍会被抽到，有本质区别。
//   * 公共题不属于任何用户，所以**不能软删**，只能「只对我隐藏」。
//   * 软删是墓碑不是坟墓 —— 管理页的「已删除」筛选可以批量恢复。
//
// ── 四个筛选 ────────────────────────────────────────────────────────────
//   全部 / 已掌握 / 未掌握 / 已删除。
//   「已掌握 / 未掌握」复用 R2 的 mastered 过滤（后端 EXISTS 子查询）；
//   「已删除」走独立的 `GET /questions/deleted`（只列自己的题）。
//
// ── 批量操作的诚实口径 ──────────────────────────────────────────────────
// 后端批量软删时会把「公共题 / 别人的题」静默跳过（SQL 的 owner_user_id
// 条件），并回一个 skipped 计数。前端**必须**把这个数字告诉用户 ——
// 不能显示「已删除 5 道」而实际只删了 3 道。

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
import '../api/question_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart' show EmptyState;
import 'question_bank_page.dart';

/// 四个筛选档。
enum _ManageFilter {
  all('全部'),
  mastered('已掌握'),
  unmastered('未掌握'),
  deleted('已删除');

  const _ManageFilter(this.label);

  final String label;

  /// 「已删除」是独立端点，不走 mastered 参数。
  bool get isDeleted => this == _ManageFilter.deleted;

  /// 传给后端的 mastered 参数（null = 不筛选）。
  bool? get masteredParam {
    switch (this) {
      case _ManageFilter.mastered:
        return true;
      case _ManageFilter.unmastered:
        return false;
      case _ManageFilter.all:
      case _ManageFilter.deleted:
        return null;
    }
  }
}

class QuestionManagePage extends StatefulWidget {
  const QuestionManagePage({super.key});

  @override
  State<QuestionManagePage> createState() => _QuestionManagePageState();
}

class _QuestionManagePageState extends State<QuestionManagePage> {
  final QuestionApi _api = QuestionApi();

  _ManageFilter _filter = _ManageFilter.all;

  /// 当前列表（按筛选取回来的题）。
  List<BankQuestion> _questions = const <BankQuestion>[];

  /// 多选：选中的题 id。
  final Set<String> _selected = <String>{};

  bool _loading = true;
  bool _busy = false;
  String? _error;

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
      _loading = true;
      _error = null;
      _selected.clear();
    });
    try {
      final List<BankQuestion> list = _filter.isDeleted
          ? await _api.fetchDeletedQuestions(limit: 100, currentUserId: kDemoUserId)
          : await _api.fetchQuestions(
              limit: 100,
              mastered: _filter.masteredParam,
              currentUserId: kDemoUserId,
            );
      if (!mounted) return;
      setState(() {
        _questions = list;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '题库加载失败：$e';
        _loading = false;
      });
    }
  }

  /// 切换筛选。切档时清空多选 —— 上一档的勾选对下一档没有意义。
  void _switchFilter(_ManageFilter f) {
    if (f == _filter) return;
    setState(() {
      _filter = f;
      _selected.clear();
    });
    _load();
  }

  void _toggleSelect(BankQuestion q) {
    setState(() {
      if (!_selected.remove(q.id)) _selected.add(q.id);
    });
  }

  /// ★ A2③：全选 / 取消全选。
  ///
  /// 把当前列表里所有题的 id 批量加入/移出 [_selected] —— 口径与 [_toggleSelect] 一致。
  void _toggleSelectAll() {
    if (_questions.isEmpty) return;
    setState(() {
      final bool allSelected =
          _questions.every((BankQuestion q) => _selected.contains(q.id));
      if (allSelected) {
        for (final BankQuestion q in _questions) {
          _selected.remove(q.id);
        }
      } else {
        for (final BankQuestion q in _questions) {
          _selected.add(q.id);
        }
      }
    });
  }

  /// ★ A2③：批量编辑考点标签。
  ///
  /// 弹窗里用逗号分隔输入多个标签，提交时 `PATCH /questions/batch/tags`。
  /// 后端会跳过公共题 / 别人的题并回一个 skipped 计数 ——
  /// 这里如实告诉用户「其中 N 道没更新」。
  Future<void> _batchTags() async {
    if (_selected.isEmpty || _busy || _filter.isDeleted) return;
    final int count = _selected.length;
    final List<String>? tags = await _showTagEditor(count);
    if (tags == null || tags.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final BatchResult result = await _api.updateQuestionTags(
        _selected.toList(),
        tags,
        mode: 'replace',
      );
      if (!mounted) return;
      final String skippedNote = result.skipped > 0
          ? '\n其中 ${result.skipped} 道没更新（公共题或别人的题不属于你）。'
          : '';
      await _showMessage(
        '已更新 ${result.updated} 道题的标签',
        '标签：${tags.join('、')}$skippedNote',
      );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      await _showMessage('更新标签失败', e.message);
    } catch (e) {
      if (!mounted) return;
      await _showMessage('更新标签失败', '请求失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// ★ m26090：批量移除（软删自己的题）。
  ///
  /// 后端会跳过公共题 / 别人的题并回一个 skipped 计数 ——
  /// 这里如实告诉用户「其中 N 道没删掉（公共题不属于你）」。
  Future<void> _batchRemove() async {
    if (_selected.isEmpty || _busy) return;
    final int count = _selected.length;
    final bool ok = await _confirm(
      '移除这 $count 道题？',
      '移除后题库里就看不到它们了，模考组卷也不会再抽到。\n'
          '可以在「已删除」里恢复回来。',
      confirmText: '移除',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final BatchResult result = await _api.deleteQuestionsBatch(_selected.toList());
      if (!mounted) return;
      final String skippedNote = result.skipped > 0
          ? '\n其中 ${result.skipped} 道没移除（公共题或别人的题不属于你）。'
          : '';
      await _showMessage('已移除 ${result.deleted} 道题', '移除的是软删，可以随时恢复。$skippedNote');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      await _showMessage('移除失败', e.message);
    } catch (e) {
      if (!mounted) return;
      await _showMessage('移除失败', '请求失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// ★ m26090：批量恢复。
  Future<void> _batchRestore() async {
    if (_selected.isEmpty || _busy) return;
    final int count = _selected.length;
    final bool ok = await _confirm(
      '恢复这 $count 道题？',
      '恢复后它们会重新出现在题库里，也能被模考抽到。',
      confirmText: '恢复',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final BatchResult result = await _api.restoreQuestionsBatch(_selected.toList());
      if (!mounted) return;
      final String skippedNote = result.skipped > 0 ? '\n其中 ${result.skipped} 道没能恢复。' : '';
      await _showMessage('已恢复 ${result.deleted} 道题', '它们已回到题库列表。$skippedNote');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      await _showMessage('恢复失败', e.message);
    } catch (e) {
      if (!mounted) return;
      await _showMessage('恢复失败', '请求失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  /// ★ A2③：弹出标签编辑弹窗。
  ///
  /// 返回 null = 用户取消；返回空列表 = 用户没填标签（当作取消）。
  Future<List<String>?> _showTagEditor(int count) {
    return showCupertinoModalPopup<List<String>>(
      context: context,
      builder: (BuildContext ctx) => _TagEditorSheet(count: count),
    );
  }

  /// ★ m26090：单题移除（软删）。
  ///
  /// 删除要带 version（乐观锁），而列表口径的 [BankQuestion] 不带 version，
  /// 所以先拉一次详情拿 version —— 顺带避免「拿旧 version 去删」被判 409。
  Future<void> _removeOne(BankQuestion question) async {
    if (_busy) return;
    final bool ok = await _confirm(
      '移除这道题？',
      '移除后题库里就看不到它了，模考组卷也不会再抽到。\n'
          '可以在「已删除」里恢复回来。',
      confirmText: '移除',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final QuestionDetail detail = await _api.fetchQuestion(question.id);
      await _api.deleteQuestion(id: detail.id, version: detail.version);
      if (!mounted) return;
      await _showMessage('已移除', '这道题已从题库移除，可以随时恢复。');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      final Object? body = e.body;
      final String code = body is Map && body['error'] != null ? '${body['error']}' : '';
      if (code == 'FORBIDDEN_DELETE') {
        await _showMessage('移除不掉', '公共题不能移除，只能隐藏。');
      } else if (code == 'not_found') {
        await _showMessage('移除不掉', '只能移除自己导入或自己创建的题。');
      } else if (code == 'conflict') {
        await _showMessage('移除失败', '这道题在你打开期间被改过，请刷新后再试。');
      } else {
        await _showMessage('移除失败', e.message);
      }
    } catch (e) {
      if (!mounted) return;
      await _showMessage('移除失败', '请求失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// ★ m26090：单题恢复。
  Future<void> _restoreOne(BankQuestion question) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _api.restoreQuestion(id: question.id);
      if (!mounted) return;
      await _showMessage('已恢复', '这道题已回到题库列表。');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      final Object? body = e.body;
      final String code = body is Map && body['error'] != null ? '${body['error']}' : '';
      if (code == 'not_deleted') {
        await _showMessage('无需恢复', '这道题没有被移除。');
      } else if (code == 'not_found') {
        await _showMessage('恢复不了', '只能恢复自己移除的题。');
      } else {
        await _showMessage('恢复失败', e.message);
      }
    } catch (e) {
      if (!mounted) return;
      await _showMessage('恢复失败', '请求失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 打开题库浏览页（导入 / 建题 / 练习的入口在那儿）。
  Future<void> _openBank() async {
    await Navigator.of(context).push<void>(
      appRoute<void>(context, const QuestionBankPage()),
    );
    if (mounted) await _load();
  }

  Future<bool> _confirm(String title, String message, {required String confirmText}) async {
    final bool? ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        return CupertinoAlertDialog(
          title: Text(
            title,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppColors.overdue,
            ),
          ),
          content: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              message,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: AppColors.secondaryLabel,
              ),
            ),
          ),
          actions: <Widget>[
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text(
                '取消',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
            CupertinoDialogAction(
              isDestructiveAction: confirmText == '移除',
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                confirmText,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: confirmText == '移除' ? AppColors.overdue : AppColors.accent,
                ),
              ),
            ),
          ],
        );
      },
    );
    return ok == true;
  }

  Future<void> _showMessage(String title, String message) {
    return showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        return CupertinoAlertDialog(
          title: Text(
            title,
            style: const TextStyle(
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
                color: AppColors.secondaryLabel,
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
                  color: AppColors.accent,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: const Text(
              '题库管理',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                color: AppColors.label,
              ),
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(36, 36),
              onPressed: _openBank,
              child: const Text(
                '浏览',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            sliver: SliverToBoxAdapter(child: _buildFilterRow()),
          ),
          if (!_loading && _error == null && _questions.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
              sliver: SliverToBoxAdapter(child: _buildSelectAllRow()),
            ),
          if (_selected.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              sliver: SliverToBoxAdapter(child: _buildBatchBar()),
            ),
          ..._buildBody(),
        ],
      ),
    );
  }

  Widget _buildFilterRow() {
    return Row(
      children: <Widget>[
        for (final _ManageFilter f in _ManageFilter.values) ...<Widget>[
          _FilterChip(
            label: f.label,
            selected: f == _filter,
            onTap: () => _switchFilter(f),
          ),
          const SizedBox(width: 8),
        ],
      ],
    );
  }

  /// 全选 / 取消全选行（需求：表头要有「全选」）。
  Widget _buildSelectAllRow() {
    final bool allSelected =
        _questions.every((BankQuestion q) => _selected.contains(q.id));
    return Row(
      children: <Widget>[
        const Spacer(),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: const Size(0, 28),
          onPressed: _toggleSelectAll,
          child: Text(
            allSelected ? '取消全选' : '全选',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.accent,
            ),
          ),
        ),
      ],
    );
  }

  /// 批量操作条：只在有勾选时出现。
  Widget _buildBatchBar() {
    final bool isDeleted = _filter.isDeleted;
    final int count = _selected.length;
    final String label = isDeleted ? '批量恢复（$count）' : '批量移除（$count）';
    final Color color = isDeleted ? AppColors.accent : AppColors.overdue;
    return Row(
      children: <Widget>[
        Expanded(
          child: CupertinoButton(
            padding: const EdgeInsets.symmetric(vertical: 10),
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(AppRadii.chip),
            onPressed: _busy ? null : (isDeleted ? _batchRestore : _batchRemove),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ),
        // ★ A2③：批量标签 —— 「已删除」档不显示（给墓碑改标签没意义）。
        if (!isDeleted) ...<Widget>[
          const SizedBox(width: 8),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(vertical: 10),
            color: AppColors.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(AppRadii.chip),
            onPressed: _busy ? null : _batchTags,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  CupertinoIcons.tag,
                  size: 18,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 4),
                Text(
                  '批量标签',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(width: 8),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(vertical: 10),
          onPressed: () => setState(_selected.clear),
          child: const Text(
            '取消选择',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 14,
              color: AppColors.secondaryLabel,
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildBody() {
    if (_loading) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CupertinoActivityIndicator(radius: 12)),
        ),
      ];
    }

    if (_error != null) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _ErrorView(message: _error!, onRetry: _load),
        ),
      ];
    }

    if (_questions.isEmpty) {
      final bool isDeleted = _filter.isDeleted;
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: isDeleted ? CupertinoIcons.trash : CupertinoIcons.doc_text,
            title: isDeleted ? '没有被移除的题' : '这个筛选下没有题',
            message: isDeleted
                ? '你还没有移除过任何题。'
                : '换个筛选看看，或者去「浏览」导入 / 建几道题。',
            actionLabel: '去题库',
            onAction: _openBank,
          ),
        ),
      ];
    }

    final bool isDeleted = _filter.isDeleted;
    return <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        sliver: SliverToBoxAdapter(
          child: Text(
            isDeleted
                ? '共 ${_questions.length} 道被移除的题，可批量恢复'
                : '共 ${_questions.length} 道题',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.secondaryLabel,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        sliver: SliverList.list(
          children: <Widget>[
            for (final BankQuestion q in _questions)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ManageCard(
                  question: q,
                  selected: _selected.contains(q.id),
                  isDeleted: isDeleted,
                  busy: _busy,
                  onToggle: () => _toggleSelect(q),
                  onRemove: () => _removeOne(q),
                  onRestore: () => _restoreOne(q),
                ),
              ),
          ],
        ),
      ),
    ];
  }
}

/// 一张可勾选、可移除/恢复的题卡。
class _ManageCard extends StatelessWidget {
  const _ManageCard({
    required this.question,
    required this.selected,
    required this.isDeleted,
    required this.busy,
    required this.onToggle,
    required this.onRemove,
    required this.onRestore,
  });

  final BankQuestion question;
  final bool selected;
  final bool isDeleted;
  final bool busy;
  final VoidCallback onToggle;
  final VoidCallback onRemove;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: busy ? null : onToggle,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadii.card),
          border: selected
              ? Border.all(color: AppColors.accent, width: 1.5)
              : null,
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x0F000000),
              blurRadius: 12,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 10),
              child: Icon(
                selected
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.circle,
                size: 20,
                color: selected ? AppColors.accent : AppColors.tertiaryLabel,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    question.preview,
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
                      if (question.mastered != null) ...<Widget>[
                        _Tag(
                          text: question.mastered! ? '已掌握' : '未掌握',
                          color: question.mastered! ? AppColors.normal : AppColors.dueSoon,
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (isDeleted)
                        const _Tag(text: '已移除', color: AppColors.secondaryLabel),
                    ],
                  ),
                  // ★ A2③：考点标签（批量标签编辑后这里会更新）。
                  if (question.tags.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final String tag in question.tags)
                          _Tag(text: tag, color: AppColors.tertiaryLabel),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(28, 28),
              onPressed: busy ? null : (isDeleted ? onRestore : onRemove),
              child: Icon(
                isDeleted ? CupertinoIcons.arrow_uturn_left : CupertinoIcons.trash,
                size: 18,
                color: isDeleted ? AppColors.accent : AppColors.overdue,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一颗筛选 chip。
class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      color: selected ? AppColors.accent.withValues(alpha: 0.14) : AppColors.card,
      borderRadius: BorderRadius.circular(AppRadii.chip),
      onPressed: onTap,
      child: Text(
        label,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 13,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? AppColors.accent : AppColors.secondaryLabel,
        ),
      ),
    );
  }
}

/// 小徽标。
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

/// 错误态：可重试。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

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
              onPressed: () {
                onRetry();
              },
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

/// ★ A2③：批量标签编辑弹窗。
///
/// 一个输入框，用逗号 / 顿号 / 空格分隔多个标签；
/// 「保存」时切分、trim、剔空串、去重后回传给调用方。
class _TagEditorSheet extends StatefulWidget {
  const _TagEditorSheet({required this.count});

  /// 本次要改多少道题（展示给用户看）。
  final int count;

  @override
  State<_TagEditorSheet> createState() => _TagEditorSheetState();
}

class _TagEditorSheetState extends State<_TagEditorSheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 把输入切分成标签数组：逗号 / 顿号 / 空格分隔，trim、剔空串、去重。
  List<String> _parseTags(String raw) {
    final List<String> parts = raw
        .split(RegExp(r'[,，、\s]+'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    final Set<String> seen = <String>{};
    return parts.where(seen.add).toList(growable: false);
  }

  void _submit() {
    final List<String> tags = _parseTags(_controller.text);
    if (tags.isEmpty) {
      Navigator.of(context).pop(<String>[]);
      return;
    }
    Navigator.of(context).pop(tags);
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoActionSheet(
      title: Text(
        '批量编辑考点标签（${widget.count} 道题）',
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      message: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 8),
          const Text(
            '用逗号分隔多个标签，例如：资料分析,速算',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 12),
          CupertinoTextField(
            controller: _controller,
            autofocus: true,
            placeholder: '例如：资料分析,速算',
            placeholderStyle: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              color: AppColors.tertiaryLabel,
            ),
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              color: AppColors.label,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.groupedBackground,
              borderRadius: BorderRadius.circular(AppRadii.chip),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: _submit,
          child: const Text(
            '保存',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppColors.accent,
            ),
          ),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(context).pop(<String>[]),
        child: const Text(
          '取消',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            color: AppColors.secondaryLabel,
          ),
        ),
      ),
    );
  }
}
