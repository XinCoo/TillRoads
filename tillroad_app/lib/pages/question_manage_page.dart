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
// ── 五个筛选 ────────────────────────────────────────────────────────────
//   全部 / 已掌握 / 未掌握 / 已删除 / 已隐藏。
//   「已掌握 / 未掌握」复用 R2 的 mastered 过滤（后端 EXISTS 子查询）；
//   「已删除」走独立的 `GET /questions/deleted`（只列自己的题）。
//   「已隐藏」**完全走本地快照**（lib/local/hidden_questions_store.dart）：
//   后端没有「列出已隐藏题」的端点，且 `GET /questions` 默认排除已隐藏的题，
//   所以这一档只能读本机记录 —— 跨设备看不到，这是已知限制，不是 bug。
// ── 批量操作的诚实口径 ──────────────────────────────────────────────────
// 后端批量软删时会把「公共题 / 别人的题」静默跳过（SQL 的 owner_user_id
// 条件），并回一个 skipped 计数。前端**必须**把这个数字告诉用户 ——
// 不能显示「已删除 5 道」而实际只删了 3 道。

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
import '../api/defect_api.dart' show DefectApi;
import '../api/exam_api.dart' show ExamApi;
import '../api/question_api.dart';
import '../config/api_config.dart';
import '../local/hidden_questions_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart' show EmptyState;
import 'question_bank_page.dart';
// ★ m31635：只取 `QuestionEditPage`。`question_edit_page.dart` 里也声明了
// 一个同名的 `kQuestionTypeLabels`，不限定会与本文件从 `question_api.dart`
// 导入的同名常量冲突（`ambiguous_import`）。
import 'question_edit_page.dart' show QuestionEditPage;

/// 五个筛选档。
///
/// [hidden] 与其它四个档有一点本质不同：它**没有网络请求**，
/// 数据源是本机快照 `HiddenQuestionStore`（原因见文件头注释）。
enum _ManageFilter {
  all('全部'),
  mastered('已掌握'),
  unmastered('未掌握'),
  deleted('已删除'),
  hidden('已隐藏');

  const _ManageFilter(this.label);

  final String label;

  /// 「已删除」是独立端点，不走 mastered 参数。
  bool get isDeleted => this == _ManageFilter.deleted;

  /// 「已隐藏」只读本地快照，不走网络。
  bool get isHidden => this == _ManageFilter.hidden;

  /// 传给后端的 mastered 参数（null = 不筛选）。
  bool? get masteredParam {
    switch (this) {
      case _ManageFilter.mastered:
        return true;
      case _ManageFilter.unmastered:
        return false;
      case _ManageFilter.all:
      case _ManageFilter.deleted:
      // 「已隐藏」不发请求，但 switch 是穷举的，必须给一个返回值。
      case _ManageFilter.hidden:
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

  /// 「已隐藏」档的数据源（本机快照，见 lib/local/hidden_questions_store.dart）。
  final HiddenQuestionStore _store = const HiddenQuestionStore();
  _ManageFilter _filter = _ManageFilter.all;

  /// 当前列表（按筛选取回来的题）。
  List<BankQuestion> _questions = const <BankQuestion>[];

  /// 多选：选中的题 id。
  final Set<String> _selected = <String>{};

  bool _loading = true;
  bool _busy = false;
  String? _error;

  /// ★ m31124：导入批次下拉的数据源（`GET /import-batches`）。
  ///
  /// 只在「全部 / 已掌握 / 未掌握」三档拉取并使用 —— 已删除和已隐藏档的
  /// 数据源分别是 `GET /questions/deleted` 和本机快照，都不带批次语义。
  List<ImportBatch> _batches = const <ImportBatch>[];

  /// 当前选中的批次 id；null = 「全部批次」。
  String? _batchId;

  /// 批次列表 / 整批删除进行中（避免连点）。
  bool _batchBusy = false;

  /// ★ m31635：科目维度。null = 全部科目。
  ///
  /// 与「掌握状态」维度并列，不再互斥：`_filter` 管掌握度/删除/隐藏，
  /// `_subjectId` / `_typeSelection` / `_batchId` 各自独立叠加。
  String? _subjectId;

  /// ★ m31635：题型维度（多选）。空集合 = 全部题型。
  ///
  /// 存 Set 而不是单个 string：UI 要能按用户点选顺序稳定渲染，且
  /// 判断「是否选中」需 O(1)。发请求时用逗号拼成 `type=choice,multi`。
  Set<String> _typeSelection = <String>{};

  /// 科目下拉的选项缓存（首次打开下拉时懒加载）。
  List<_OptionItem> _subjectOptions = const <_OptionItem>[];
  void initState() {
    super.initState();
    _load();
    // ★ m31124：批次下拉的数据与题目列表独立 —— 拉失败不该拖垮列表。
    _loadBatches();
  }

  /// ★ m31124：拉导入批次列表（`GET /import-batches`）。
  ///
  /// 失败只记日志、保持空列表（下拉只剩「全部批次」），不弹错：
  /// 批次是辅助信息，不能因为它拉不到就让用户连题都看不了。
  Future<void> _loadBatches() async {
    try {
      final List<ImportBatch> list = await _api.fetchImportBatches();
      if (!mounted) return;
      setState(() {
        _batches = list;
        // 选中的批次被删了（或换账号了）—— 回落「全部批次」，否则会定格在一个
        // 永远查不到题的空列表上。
        if (_batchId != null && !list.any((ImportBatch b) => b.id == _batchId)) {
          _batchId = null;
        }
      });
    } on ApiException catch (e) {
      debugPrint('[manage] 批次列表加载失败：${e.message}（status=${e.statusCode}）');
    } catch (e) {
      debugPrint('[manage] 批次列表加载异常：$e');
    }
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
    // ★ 「已隐藏」没有网络数据源：后端没有 list-hidden 端点，且
    // `GET /questions` 默认排除已隐藏的题。只能读本机快照。
    if (_filter.isHidden) {
      final List<HiddenQuestion> hidden = await _store.load(kDemoUserId);
      if (!mounted) return;
      setState(() {
        _questions = hidden
            .map(
              (HiddenQuestion h) => BankQuestion(
                id: h.id,
                stem: h.stem,
                type: h.type,
                source: h.source,
                // 隐藏只对公共题开放（自己的题给的是「编辑 / 删除」），
                // 所以快照里的题一律按公共题展示。
                isMine: false,
              ),
            )
            .toList(growable: false);
        _loading = false;
      });
      return;
    }

    try {
      final List<BankQuestion> list = _filter.isDeleted
          ? await _api.fetchDeletedQuestions(limit: 100, currentUserId: kDemoUserId)
          : await _api.fetchQuestions(
              limit: 100,
              mastered: _filter.masteredParam,
              currentUserId: kDemoUserId,
              // ★ m31124：已删除档的数据源是 `/questions/deleted`，不支持批次筛选，
              // 所以只在正常三档把 _batchId 传下去。
              batchId: _batchId,
              // ★ m31635：科目 / 题型两个新维度。三者与 mastered 是 AND 关系，
              // 都在同一次请求里表达，不在客户端做二次过滤（分页会错）。
              subjectId: _subjectId,
              type: _typeParam,
            );
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
      // ★ m31124：已删除 / 已隐藏档不走 `GET /questions`，批次筛选对它们无意义，
      // 切过去时一并清掉（否则切回来会莫名其妙只剩一个批次）。
      if (f.isDeleted || f.isHidden) {
        // ★ m31635：科目 / 题型同样是 `GET /questions` 的参数，一并清掉。
        _batchId = null;
        _subjectId = null;
        _typeSelection = <String>{};
      }
    });
    _load();
  }

  /// ★ m31635：题型维度的请求参数（`choice,multi`）。空集合返回 null。
  String? get _typeParam {
    if (_typeSelection.isEmpty) return null;
    final List<String> sorted = _typeSelection.toList()..sort();
    return sorted.join(',');
  }

  /// 是否已有任何非「掌握状态」的维度被选中。
  bool get _hasExtraFilter =>
      _subjectId != null || _typeSelection.isNotEmpty || _batchId != null;

  /// 科目名（找不到回退 id 截断，避免标签行显示空白）。
  String _subjectLabel(String id) {
    for (final _OptionItem item in _subjectOptions) {
      if (item.id == id) return item.label;
    }
    return id.length > 8 ? '${id.substring(0, 8)}…' : id;
  }

  /// 题型名（用 `kQuestionTypeLabels` 映射，未知回退原值）。
  String _typeLabel(String type) => questionTypeLabel(type);

  /// ★ m31635：清除所有维度（掌握状态回到「全部」）。
  ///
  /// 只改 State 再发一次请求 —— 四个维度本质上都是查询参数，没有本地过滤
  /// 残留需要清理（唯一例外是已隐藏档的本地快照，它不参与维度叠加）。
  Future<void> _clearAllFilters() async {
    if (!_hasExtraFilter && _filter == _ManageFilter.all) return;
    setState(() {
      _filter = _ManageFilter.all;
      _subjectId = null;
      _typeSelection = <String>{};
      _batchId = null;
      _selected.clear();
    });
    await _load();
  }

  /// ★ m31635：科目下拉（复用 `_loadBatchSubjects` 的数据源，首次打开时懒加载）。
  Future<void> _pickSubject() async {
    if (_busy) return;
    if (_subjectOptions.isEmpty) {
      final List<_OptionItem> loaded = await _loadBatchSubjects();
      if (!mounted) return;
      _subjectOptions = loaded;
    }
    if (!mounted) return;
    if (_subjectOptions.isEmpty) {
      await _showMessage('还没有科目', '先去「考试配置」里建一个考试目标并添加科目。');
      return;
    }
    final _OptionPick? picked = await _showBatchPicker(
      title: '按科目筛选',
      message: '只列题库里的题所属的科目。“全部科目”会清掉这一条筛选。',
      options: _subjectOptions,
    );
    if (picked == null || picked.id == null || !mounted) return;
    if (picked.id == _subjectId) return;
    setState(() {
      _subjectId = picked.id;
      _selected.clear();
    });
    await _load();
  }

  /// ★ m31635：题型下拉（多选，可反复点选叠加）。
  ///
  /// 用带勾选标记的 ActionSheet 而不是单选的 `_OptionPickerSheet`：题型
  /// 是少而稳定的枚举（`kQuestionTypeLabels` 十来项），多选比“选一次再
  /// 回来选一次”高效。
  Future<void> _pickType() async {
    if (_busy) return;
    final Set<String> draft = <String>{..._typeSelection};
    final bool? applied = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setSheetState) {
          return CupertinoActionSheet(
            title: Text(
              '按题型筛选',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.label,
              ),
            ),
            message: Text(
              '可多选，多个题型之间是“或”的关系；已选 ${draft.length} 项。',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: AppColors.secondaryLabel,
              ),
            ),
            actions: <Widget>[
              CupertinoActionSheetAction(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(
                  '完成',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                  ),
                ),
              ),
              for (final String type in kQuestionTypeLabels.keys)
                CupertinoActionSheetAction(
                  onPressed: () {
                    setSheetState(() {
                      if (!draft.remove(type)) draft.add(type);
                    });
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      // 勾选标记用固定宽度占位，否则选中/未选中时文字会左右跳。
                      SizedBox(
                        width: 20,
                        child: draft.contains(type)
                            ? const Icon(
                                CupertinoIcons.check_mark,
                                size: 16,
                                color: AppColors.accent,
                              )
                            : null,
                      ),
                      Text(
                        questionTypeLabel(type),
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 16,
                          color: draft.contains(type)
                              ? AppColors.accent
                              : AppColors.label,
                          fontWeight: draft.contains(type)
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            cancelButton: CupertinoActionSheetAction(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text(
                '取消',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        },
      ),
    );
    // 取消 / 点遮罩 → applied 为 null，draft 的挂改丢弃。
    if (!mounted || applied != true) return;
    if (_sameTypes(draft, _typeSelection)) return;
    setState(() {
      _typeSelection = draft;
      _selected.clear();
    });
    await _load();
  }

  /// 两个题型集合是否等价（不用 `setEquals`，本文件没 import foundation）。
  bool _sameTypes(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final String type in a) {
      if (!b.contains(type)) return false;
    }
    return true;
  }

  /// ★ m31124：批次下拉 —— 「全部批次」+ 每个批次一行。
  ///
  /// 用 `CupertinoActionSheet` 而不是 `showMenu`：纯 Cupertino 工程里
  /// 底部弹出列表与其它操作表（`_openActions`）风格一致，手指也好点。
  Future<void> _pickBatch() async {
    if (_batchBusy) return;
    final String? picked = await showCupertinoModalPopup<String>(
      context: context,
      builder: (BuildContext ctx) => CupertinoActionSheet(
        title: Text(
          '导入批次',
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        message: _batches.isEmpty
            ? Text(
                '还没有导入记录',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  color: AppColors.secondaryLabel,
                ),
              )
            : null,
        actions: <Widget>[
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop(''),
            child: Text(
              '全部批次',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 16,
                color: _batchId == null ? AppColors.accent : AppColors.label,
              ),
            ),
          ),
          for (final ImportBatch b in _batches)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(ctx).pop(b.id),
              child: Text(
                b.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 16,
                  color: b.id == _batchId ? AppColors.accent : AppColors.label,
                ),
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDestructiveAction: false,
          onPressed: () => Navigator.of(ctx).pop(null),
          child: const Text(
            '取消',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    final String? next = picked.trim().isEmpty ? null : picked.trim();
    if (next == _batchId) return;
    setState(() {
      _batchId = next;
      _selected.clear();
    });
    await _load();
  }

  /// ★ m31124：删除整批（软删，只删自己的）。
  ///
  /// 确认文案里的 N 用**当前该批还剩多少道**（`requested` 是删前计数、
  /// `ImportBatch.questionCount` 是导入时的历史数量，两者可能不同）。
  /// 所以先说「将删除该批次的所有题」，删除后再用 returned deleted 报准确结果。
  Future<void> _deleteBatch() async {
    final String? batchId = _batchId;
    if (batchId == null || _batchBusy) return;
    // 不用 `firstOrNull`（Project 没引 package:collection 的 IterableExtension）。
    ImportBatch? batch;
    for (final ImportBatch b in _batches) {
      if (b.id == batchId) {
        batch = b;
        break;
      }
    }
    final String name = batch?.filename ?? '这个批次';

    final bool ok = await _confirm(
      '删除整批',
      '将删除「$name」导入的所有题（共 ${batch?.questionCount ?? 0} 道）。\n'
          '删除后可到「已删除」列表逐题恢复。',
      confirmText: '删除整批',
      destructive: true,
    );
    if (!ok || !mounted) return;

    setState(() => _batchBusy = true);
    try {
      final BatchResult result = await _api.deleteQuestionsByBatch(batchId);
      if (!mounted) return;
      await _loadBatches();
      if (!mounted) return;
      // 批次档案还在（账本不随题删），所以仍停在该批次上：列表变空是正确反馈。
      _batchId = null;
      await _load();
      if (!mounted) return;
      _showMessage(
        result.deleted > 0 ? '已删除整批' : '该批次没有可删的题',
        '共删除 ${result.deleted} 道题'
            '${result.skipped > 0 ? '，${result.skipped} 道属于他人已跳过' : ''}。',
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      _showMessage('删除失败', e.message);
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
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
  /// ★ 批量「移动到科目」：把勾选的题批量改归属科目。
  ///
  /// 没有「列出我的全部科目」的端点，只能先拉考试目标再逐个拉科目。
  /// 后端 `PATCH /questions/batch` 只改自己的题，公共题/别人的题会被
  /// 静默跳过并回一个 skipped 计数 —— 这里如实告诉用户。
  Future<void> _batchMoveToSubject() async {
    if (_selected.isEmpty || _busy || _filter.isDeleted || _filter.isHidden) {
      return;
    }
    final int count = _selected.length;
    final List<_OptionItem> subjects = await _loadBatchSubjects();
    if (!mounted) return;
    if (subjects.isEmpty) {
      await _showMessage('还没有科目', '先去「考试配置」里建一个考试目标并添加科目，再回来批量移动。');
      return;
    }
    final _OptionPick? picked = await _showBatchPicker(
      title: '移动到科目（$count 道题）',
      message: '选中后这些题会归入该科目。',
      options: subjects,
    );
    if (picked == null || picked.id == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final BatchResult result = await _api.updateQuestionsBatch(
        _selected.toList(),
        subjectId: picked.id,
      );
      if (!mounted) return;
      final String skippedNote = result.skipped > 0
          ? '\n其中 ${result.skipped} 道没移动（公共题或别人的题不属于你）。'
          : '';
      await _showMessage(
        '已移动 ${result.updated} 道题',
        '已归入「${picked.label}」。$skippedNote',
      );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      await _showMessage('移动失败', e.message);
    } catch (e) {
      if (!mounted) return;
      await _showMessage('移动失败', '请求失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// ★ 批量「设置考点」：先选科目，再列该科目的考点。
  ///
  /// 考点按科目组织（`GET /subjects/:id/knowledge-nodes`），所以必须
  /// 先让用户选科目。最后一项「不指定考点」会把 `knowledge_node_id`
  /// 显式置空（传 null，而不是不传）。
  Future<void> _batchSetKnowledgeNode() async {
    if (_selected.isEmpty || _busy || _filter.isDeleted || _filter.isHidden) {
      return;
    }
    final int count = _selected.length;
    final List<_OptionItem> subjects = await _loadBatchSubjects();
    if (!mounted) return;
    if (subjects.isEmpty) {
      await _showMessage('还没有科目', '先去「考试配置」里建一个考试目标并添加科目，再回来设置考点。');
      return;
    }
    final _OptionPick? subjectPick = await _showBatchPicker(
      title: '先选科目（$count 道题）',
      message: '考点是按科目组织的，先选一个科目。',
      options: subjects,
    );
    if (subjectPick == null || subjectPick.id == null || !mounted) return;
    final String subjectId = subjectPick.id!;
    final String subjectLabel = subjectPick.label;

    final DefectApi defectApi = DefectApi();
    setState(() => _busy = true);
    List<_OptionItem> nodes = const <_OptionItem>[];
    try {
      final List<Map<String, Object?>> raw =
          await defectApi.fetchKnowledgeNodes(subjectId);
      nodes = <_OptionItem>[
        for (final Map<String, Object?> node in raw)
          if ('${node['id'] ?? ''}'.trim().isNotEmpty)
            _OptionItem(
              id: '${node['id']}'.trim(),
              label: '${node['title'] ?? ''}'.trim().isEmpty
                  ? '未命名考点'
                  : '${node['title']}'.trim(),
              detail: '${node['freq_tag'] ?? ''}'.trim().isEmpty
                  ? null
                  : '${node['freq_tag']}'.trim(),
            ),
      ];
    } on ApiException catch (e) {
      defectApi.close();
      if (mounted) setState(() => _busy = false);
      if (!mounted) return;
      await _showMessage('加载考点失败', e.message);
      return;
    } catch (e) {
      defectApi.close();
      if (mounted) setState(() => _busy = false);
      if (!mounted) return;
      await _showMessage('加载考点失败', '请求失败：$e');
      return;
    }
    defectApi.close();
    if (mounted) setState(() => _busy = false);
    if (!mounted) return;

    final _OptionPick? nodePick = await _showBatchPicker(
      title: '设置考点（$count 道题）',
      message: '科目：$subjectLabel。选「不指定考点」会清空这些题现有的考点。',
      options: nodes,
      clearLabel: '不指定考点（清空）',
    );
    if (nodePick == null || !mounted) return;

    final bool clearing = nodePick.cleared;
    setState(() => _busy = true);
    try {
      final BatchResult result = clearing
          ? await _api.updateQuestionsBatch(
              _selected.toList(),
              clearKnowledgeNode: true,
            )
          : await _api.updateQuestionsBatch(
              _selected.toList(),
              knowledgeNodeId: nodePick.id,
            );
      if (!mounted) return;
      final String skippedNote = result.skipped > 0
          ? '\n其中 ${result.skipped} 道没更新（公共题或别人的题不属于你）。'
          : '';
      await _showMessage(
        clearing ? '已清空 ${result.updated} 道题的考点' : '已设置 ${result.updated} 道题的考点',
        clearing ? '这些题现在不属于任何考点。$skippedNote' : '考点：${nodePick.label}$skippedNote',
      );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      await _showMessage('设置考点失败', e.message);
    } catch (e) {
      if (!mounted) return;
      await _showMessage('设置考点失败', '请求失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 拉当前用户所有考试目标下的科目（批量移动用）。
  ///
  /// 客户端用完即 `close()`，避免连接泄漏；失败时向上抛，由调用方报错。
  Future<List<_OptionItem>> _loadBatchSubjects() async {
    final DefectApi defectApi = DefectApi();
    final ExamApi examApi = ExamApi();
    setState(() => _busy = true);
    final List<_OptionItem> items = <_OptionItem>[];
    final Set<String> seen = <String>{};
    try {
      final List<Map<String, Object?>> profiles =
          await defectApi.fetchExamProfiles(kDemoUserId);
      for (final Map<String, Object?> profile in profiles) {
        final String profileId = '${profile['id'] ?? ''}'.trim();
        if (profileId.isEmpty) continue;
        final String profileLabel =
            '${profile['target_label'] ?? profile['exam_type'] ?? '考试目标'}'.trim();
        final List<Map<String, Object?>> subjects =
            await examApi.fetchSubjects(profileId);
        for (final Map<String, Object?> subject in subjects) {
          final String id = '${subject['id'] ?? ''}'.trim();
          final String name =
              '${subject['name'] ?? subject['title'] ?? ''}'.trim();
          if (id.isEmpty || !seen.add(id)) continue;
          items.add(
            _OptionItem(
              id: id,
              label: name.isEmpty ? '未命名科目' : name,
              detail: profileLabel.isEmpty ? null : profileLabel,
            ),
          );
        }
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _busy = false);
      if (!mounted) return items;
      await _showMessage('加载科目失败', e.message);
      return items;
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      if (!mounted) return items;
      await _showMessage('加载科目失败', '请求失败：$e');
      return items;
    } finally {
      defectApi.close();
      examApi.close();
    }
    if (mounted) setState(() => _busy = false);
    return items;
  }

  /// 弹一个可滚动选项列表（批量移动 / 设置考点共用）。
  Future<_OptionPick?> _showBatchPicker({
    required String title,
    required String message,
    required List<_OptionItem> options,
    String? clearLabel,
  }) {
    return showCupertinoModalPopup<_OptionPick>(
      context: context,
      builder: (BuildContext ctx) => _OptionPickerSheet(
        title: title,
        message: message,
        options: options,
        clearLabel: clearLabel,
      ),
    );
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

  /// 打开一道题的编辑页（只对自己的题开放）。
  ///
  /// 列表口径的 [BankQuestion] 不带 answer / analysis / version，
  /// 所以先拉一次详情（`GET /questions/:id`）再进编辑页 ——
  /// 与 `question_bank_page.dart` 的 `_openEdit` 保持同一个做法。
  Future<void> _openEdit(BankQuestion question) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final QuestionDetail detail = await _api.fetchQuestion(question.id);
      if (!mounted) return;
      final bool? changed = await Navigator.of(context).push<bool>(
        appRoute<bool>(context, QuestionEditPage(existing: detail)),
      );
      if (changed == true) await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      await _showMessage('打不开这道题', e.message);
    } catch (e) {
      if (!mounted) return;
      await _showMessage('打不开这道题', '加载详情失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// ★ 隐藏一道公共题：`PATCH /questions/:id/hide {hidden:true}`。
  ///
  /// 成功后做两件事：
  ///   1. 写一条本机快照（后端不提供「已隐藏」列表，只能自己记）；
  ///   2. 从当前列表里移除这道题 —— 因为服务端已经会排除它，
  ///      如果不移除，用户会看到「提示说隐藏了、题还在列表里」的怪异观感。
  Future<void> _hideOne(BankQuestion question) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _api.setHidden(id: question.id, hidden: true);
      await _store.add(
        kDemoUserId,
        HiddenQuestion(
          id: question.id,
          stem: question.stem,
          type: question.type,
          source: question.source,
          hiddenAt: DateTime.now().toIso8601String(),
        ),
      );
      if (!mounted) return;
      setState(() {
        _questions = _questions
            .where((BankQuestion q) => q.id != question.id)
            .toList(growable: false);
      });
      await _showMessage(
        '已隐藏',
        '这道题不会再出现在你的题库列表里；模考仍可能抽到它。',
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      await _showMessage('隐藏失败', e.message);
    } catch (e) {
      if (!mounted) return;
      await _showMessage('隐藏失败', '请求失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// ★ 取消隐藏：`PATCH /questions/:id/hide {hidden:false}`。
  ///
  /// 后端不校验当前状态（幂等），所以直接调即可；
  /// 本地快照与列表都在成功后同步删除，避免两边不一致。
  Future<void> _unhideOne(BankQuestion question) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _api.setHidden(id: question.id, hidden: false);
      await _store.remove(kDemoUserId, question.id);
      if (!mounted) return;
      setState(() {
        _questions = _questions
            .where((BankQuestion q) => q.id != question.id)
            .toList(growable: false);
      });
      await _showMessage('已取消隐藏', '这道题已回到题库列表。');
    } on ApiException catch (e) {
      if (!mounted) return;
      await _showMessage('取消隐藏失败', e.message);
    } catch (e) {
      if (!mounted) return;
      await _showMessage('取消隐藏失败', '请求失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 卡片右侧「⋯」：按当前筛选档 + 题目归属弹不同的菜单。
  ///
  /// 口径：
  ///   * 自己的题（isMine）→ 编辑 / 删除；**不给隐藏**。
  ///     取舍理由：自己的题本来就能直接删，再给一个「隐藏」只会让
  ///     「为什么这题不见了」变得难解释；公共题不能删，才需要「隐藏」当退路。
  ///   * 公共题 → 隐藏（不显示删除：后端会回 403 FORBIDDEN_DELETE），
  ///     并在菜单里用一行小字说明「公共题不能删除，只能隐藏」；
  ///   * 已删除档 → 恢复；已隐藏档 → 取消隐藏。
  Future<void> _openActions(BankQuestion question) async {
    final bool isDeleted = _filter.isDeleted;
    final bool isHidden = _filter.isHidden;
    final bool canManage = !isDeleted && !isHidden;

    final String? action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (BuildContext ctx) {
        return CupertinoActionSheet(
          title: const Text(
            '题目操作',
            style: TextStyle(fontFamily: kFontFamily, fontSize: 14),
          ),
          message: Column(
            children: <Widget>[
              Text(
                question.preview,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  color: AppColors.secondaryLabel,
                ),
              ),
              if (canManage && !question.isMine) ...<Widget>[
                const SizedBox(height: 8),
                const Text(
                  '公共题不能删除，只能隐藏',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    color: AppColors.tertiaryLabel,
                  ),
                ),
              ],
            ],
          ),
          actions: <Widget>[
            if (isDeleted)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.of(ctx).pop('restore'),
                child: const Text(
                  '恢复',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 17,
                    color: AppColors.accent,
                  ),
                ),
              ),
            if (isHidden)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.of(ctx).pop('unhide'),
                child: const Text(
                  '取消隐藏',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 17,
                    color: AppColors.accent,
                  ),
                ),
              ),
            if (canManage && question.isMine) ...<Widget>[
              CupertinoActionSheetAction(
                onPressed: () => Navigator.of(ctx).pop('edit'),
                child: const Text(
                  '编辑',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 17,
                    color: AppColors.accent,
                  ),
                ),
              ),
              CupertinoActionSheetAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.of(ctx).pop('remove'),
                child: const Text(
                  '删除',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 17,
                    color: AppColors.overdue,
                  ),
                ),
              ),
            ],
            if (canManage && !question.isMine)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.of(ctx).pop('hide'),
                child: const Text(
                  '隐藏',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 17,
                    color: AppColors.accent,
                  ),
                ),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '取消',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'edit':
        await _openEdit(question);
      case 'remove':
        await _removeOne(question);
      case 'hide':
        await _hideOne(question);
      case 'unhide':
        await _unhideOne(question);
      case 'restore':
        await _restoreOne(question);
    }
  }

  /// 打开题库浏览页（导入 / 建题 / 练习的入口在那儿）。
  Future<void> _openBank() async {
    await Navigator.of(context).push<void>(
      appRoute<void>(context, const QuestionBankPage()),
    );
    if (mounted) await _load();
  }

  /// 确认弹窗。
  ///
  /// [destructive] 为 true 时按钮用红色（默认沿用旧口径：`confirmText == '移除'`），
  /// 供 m31124 的「删除整批」这类不可逆操作使用。
  Future<bool> _confirm(
    String title,
    String message, {
    required String confirmText,
    bool? destructive,
  }) async {
    final bool danger = destructive ?? (confirmText == '移除');
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
              isDestructiveAction: danger,
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                confirmText,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: danger ? AppColors.overdue : AppColors.accent,
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
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _buildFilterRow(),
                  // ★ m31635：科目 / 题型维度与当前筛选标签。
                  //   已删除 / 已隐藏档不走 `GET /questions`，这两行对它们无意义。
                  if (!_filter.isDeleted && !_filter.isHidden) ...<Widget>[
                    const SizedBox(height: 8),
                    _buildDimensionRow(),
                    _buildActiveFilterTags(),
                  ],
                ],
              ),
            ),
          ),
          // ★ m31124：导入批次筛选。只给「全部 / 已掌握 / 未掌握」三档 ——
          // 已删除档走 /questions/deleted、已隐藏档走本机快照，两者都不带批次语义。
          if (!_filter.isDeleted && !_filter.isHidden)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
              sliver: SliverToBoxAdapter(child: _buildBatchRow()),
            ),
          // ★ 已隐藏档没有批量操作（批量移除 / 批量恢复 / 批量标签对隐藏列表
          // 都没意义），所以全选行和批量条都不渲染，也避免 _selected 里
          // 残留一批无法执行的 id。
          if (!_loading &&
              _error == null &&
              _questions.isNotEmpty &&
              !_filter.isHidden)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
              sliver: SliverToBoxAdapter(child: _buildSelectAllRow()),
            ),
          if (_selected.isNotEmpty && !_filter.isHidden)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              sliver: SliverToBoxAdapter(child: _buildBatchBar()),
            ),
          ..._buildBody(),
        ],
      ),
    );
  }

  /// 按 id 找批次（找不到返回 null）。不用 `firstOrNull` —— 本工程没有依赖
  /// `package:collection` 的 IterableExtension，Dart 核心库没这个 getter。
  ImportBatch? _batchById(String? id) {
    if (id == null) return null;
    for (final ImportBatch b in _batches) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// ★ m31124：导入批次行 —— 左侧下拉入口，右侧「删除整批」（仅选中具体批次时显示）。
  Widget _buildBatchRow() {
    final ImportBatch? current = _batchId == null
        ? null
        : _batchById(_batchId);
    final String label = current == null ? '全部批次' : current.label;
    return Row(
      children: <Widget>[
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _batchBusy ? null : _pickBatch,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(AppRadii.chip),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    CupertinoIcons.tray_arrow_down,
                    size: 14,
                    color: _batchId == null
                        ? AppColors.secondaryLabel
                        : AppColors.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 13,
                        color: _batchId == null
                            ? AppColors.secondaryLabel
                            : AppColors.label,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 只有选中具体批次才出现「删除整批」—— 「全部批次」下按整批删是灾难性的。
        if (_batchId != null) ...<Widget>[
          const SizedBox(width: 8),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            minimumSize: const Size(0, 32),
            color: AppColors.overdue.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadii.chip),
            onPressed: _batchBusy ? null : _deleteBatch,
            child: Text(
              _batchBusy ? '删除中…' : '删除整批',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.overdue,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFilterRow() {
    // ★ m31635：五个档位横着排会超出屏幕（iPhone 上 5 个 chip + 间距约 500pt），
    // 改成横向滚动 —— 保持 chip 尺寸一致，手指也能滑到最后一档。
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
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
      ),
    );
  }

  /// ★ m31635：科目 / 题型两个新维度（与上面的掌握状态档位叠加，不是互斥）。
  ///
  /// 两个按钮包成 chip 形状，选中后文字变强调色，与 `_FilterChip` 视觉一致；
  /// 右端在有任何维度时出现「清除全部」。
  Widget _buildDimensionRow() {
    final String subjectText = _subjectId == null
        ? '科目'
        : _subjectLabel(_subjectId!);
    final String typeText = _typeSelection.isEmpty
        ? '题型'
        : (_typeSelection.length == 1
            ? _typeLabel(_typeSelection.first)
            : '题型 ${_typeSelection.length} 项');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          _FilterChip(
            label: subjectText,
            selected: _subjectId != null,
            onTap: () => _pickSubject(),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: typeText,
            selected: _typeSelection.isNotEmpty,
            onTap: () => _pickType(),
          ),
          if (_subjectId != null) ...<Widget>[
            const SizedBox(width: 8),
            // 科目单独一个「×」：它的选项可能要重新拉，所以不并到「清除全部」。
            _FilterChip(label: '× 科目', selected: false, onTap: _clearSubject),
          ],
          if (_typeSelection.isNotEmpty) ...<Widget>[
            const SizedBox(width: 8),
            _FilterChip(label: '× 题型', selected: false, onTap: _clearTypes),
          ],
          if (_subjectId != null ||
              _typeSelection.isNotEmpty ||
              _batchId != null ||
              _filter != _ManageFilter.all) ...<Widget>[
            const SizedBox(width: 8),
            _FilterChip(
              label: '清除全部',
              selected: false,
              onTap: () => _clearAllFilters(),
            ),
          ],
        ],
      ),
    );
  }

  /// ★ m31635：当前筛选标签行 —— 用一个可换行的容器把已生效的维度列出来。
  ///
  /// 每一项都能单独点掉（需求 B4）。不把「全部」这一档列出来，因为它等于
  /// 「没有这条筛选」。
  Widget _buildActiveFilterTags() {
    final List<Widget> tags = <Widget>[];
    void addTag(String text, VoidCallback onClear) {
      if (tags.isNotEmpty) {
        tags.add(const SizedBox(width: 6));
      }
      tags.add(
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onClear,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppRadii.chip),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  text,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    color: AppColors.accent,
                  ),
                ),
                const SizedBox(width: 3),
                const Icon(
                  CupertinoIcons.xmark,
                  size: 11,
                  color: AppColors.accent,
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_subjectId != null) {
      addTag('科目=${_subjectLabel(_subjectId!)}', _clearSubject);
    }
    if (_typeSelection.isNotEmpty) {
      addTag('题型=${_typeSelection.map(_typeLabel).join('、')}', _clearTypes);
    }
    if (_filter == _ManageFilter.mastered ||
        _filter == _ManageFilter.unmastered) {
      addTag(_filter.label, () => _switchFilter(_ManageFilter.all));
    }
    if (_batchId != null) {
      final ImportBatch? batch = _batchById(_batchId);
      addTag(
        '批次=${batch?.filename ?? '已选批次'}',
        () async {
          setState(() {
            _batchId = null;
            _selected.clear();
          });
          await _load();
        },
      );
    }

    if (tags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          const Text(
            '当前筛选：',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
          ...tags,
        ],
      ),
    );
  }

  /// ★ m31635：清除科目维度。
  Future<void> _clearSubject() async {
    if (_subjectId == null) return;
    setState(() {
      _subjectId = null;
      _selected.clear();
    });
    await _load();
  }

  /// ★ m31635：清除题型维度。
  Future<void> _clearTypes() async {
    if (_typeSelection.isEmpty) return;
    setState(() {
      _typeSelection = <String>{};
      _selected.clear();
    });
    await _load();
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
    // ★ 新增两个批量动作（「移动到科目」「设置考点」）后，单行装不下
    // 6 个控件（会 RenderFlex overflow），所以拆成两行：
    //   第一行：主操作（批量移除 / 批量恢复）+ 取消选择
    //   第二行：批量标签 / 移动到科目 / 设置考点
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
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
        ),
        // ★ 「已删除」档不显示这些动作（给墓碑改科目 / 考点没意义）。
        if (!isDeleted) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: _BatchActionButton(
                  icon: CupertinoIcons.tag,
                  label: '批量标签',
                  onPressed: _busy ? null : _batchTags,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _BatchActionButton(
                  icon: CupertinoIcons.arrow_right_arrow_left,
                  label: '移动到科目',
                  onPressed: _busy ? null : _batchMoveToSubject,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _BatchActionButton(
                  icon: CupertinoIcons.arrow_branch,
                  label: '设置考点',
                  onPressed: _busy ? null : _batchSetKnowledgeNode,
                ),
              ),
            ],
          ),
        ],
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
      final bool isHidden = _filter.isHidden;
      // ★ m31635：有任何叠加维度时，空态要给「清除所有筛选」而不是「去题库」——
      // 用户当前最可能想做的事是放宽条件，而不是跳到另一个页面。
      final bool narrowed = !isDeleted && !isHidden &&
          (_hasExtraFilter || _filter != _ManageFilter.all);
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: isDeleted
                ? CupertinoIcons.trash
                : (isHidden ? CupertinoIcons.eye_slash : CupertinoIcons.doc_text),
            title: narrowed
                ? '该筛选条件下没有题目'
                : (isDeleted
                    ? '没有被移除的题'
                    : (isHidden ? '没有隐藏的题' : '这个筛选下没有题')),
            message: narrowed
                ? '试试减少几个条件，或者清除所有筛选重新开始。'
                : (isDeleted
                    ? '你还没有移除过任何题。'
                    : (isHidden
                        ? '只有在题库里对公共题点「隐藏」后，才会出现在这里。'
                        : '换个筛选看看，或者去「浏览」导入 / 建几道题。')),
            actionLabel: narrowed ? '清除所有筛选' : '去题库',
            onAction: narrowed ? () => _clearAllFilters() : _openBank,
          ),
        ),
      ];
    }

    final bool isDeleted = _filter.isDeleted;
    final bool isHidden = _filter.isHidden;
    final String countLabel = isDeleted
        ? '共 ${_questions.length} 道被移除的题，可批量恢复'
        : (isHidden
            ? '共 ${_questions.length} 道被隐藏的题'
            : '共 ${_questions.length} 道题');
    return <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                countLabel,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  color: AppColors.secondaryLabel,
                ),
              ),
              // ★ 已隐藏档的说明行：避免用户把「隐藏」误解成删除 / 不再考。
              if (isHidden) ...<Widget>[
                const SizedBox(height: 4),
                const Text(
                  '隐藏只影响题库列表，模考仍会抽到这些题',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    color: AppColors.tertiaryLabel,
                  ),
                ),
              ],
            ],
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
                  isHidden: isHidden,
                  selectable: !isHidden,
                  busy: _busy,
                  onToggle: () => _toggleSelect(q),
                  onActions: () => _openActions(q),
                ),
              ),
          ],
        ),
      ),
    ];
  }
}

/// 一张题卡：左侧可勾选（仅批量有意义的两档），右侧是「⋯」操作菜单。
///
/// ★ 改造点：原本右侧只有一个「删除 / 恢复」按钮，而按档位 + 题目归属
/// 实际需要的动作已经到 5 种（编辑 / 删除 / 恢复 / 隐藏 / 取消隐藏），
/// 单按钮装不下，所以统一交给 [_openActions] 弹 CupertinoActionSheet。
/// 三个档位共用同一个入口，交互风格保持一致。
class _ManageCard extends StatelessWidget {
  const _ManageCard({
    required this.question,
    required this.selected,
    required this.isDeleted,
    required this.isHidden,
    required this.selectable,
    required this.busy,
    required this.onToggle,
    required this.onActions,
  });

  final BankQuestion question;
  final bool selected;
  final bool isDeleted;
  final bool isHidden;

  /// 这张卡是否参与批量选择。
  ///
  /// 「已隐藏」档没有批量操作（见 `_buildBody` 上方注释），
  /// 所以那里不画勾选圈、整卡点击也不切勾选 —— 避免出现「勾了却不能操作」。
  final bool selectable;
  final bool busy;
  final VoidCallback onToggle;
  final VoidCallback onActions;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: (!selectable || busy) ? null : onToggle,
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
            if (selectable)
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 10),
                child: Icon(
                  selected
                      ? CupertinoIcons.checkmark_circle_fill
                      : CupertinoIcons.circle,
                  size: 20,
                  color:
                      selected ? AppColors.accent : AppColors.tertiaryLabel,
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
                      if (isHidden)
                        const _Tag(text: '已隐藏', color: AppColors.secondaryLabel),
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
              onPressed: busy ? null : onActions,
              child: const Icon(
                CupertinoIcons.ellipsis,
                size: 20,
                color: AppColors.secondaryLabel,
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

/// 批量条副行上的小按钮（图标 + 文字，等宽并排）。
///
/// 原本「批量标签」是行内直接写的 CupertinoButton，新增两个动作后
/// 重复三遍太多，抽成一个无状态组件（样式与原先一致）。
class _BatchActionButton extends StatelessWidget {
  const _BatchActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(vertical: 10),
      color: AppColors.accent.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(AppRadii.chip),
      onPressed: onPressed,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 16, color: AppColors.accent),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
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

/// 批量选择器里的一个选项（科目 / 考点）。
class _OptionItem {
  const _OptionItem({required this.id, required this.label, this.detail});

  final String id;
  final String label;

  /// 次要说明（科目属于哪个考试目标 / 考点的频标）。
  final String? detail;
}

/// 选择器的返回结果。
///
/// [cleared] 为 true 表示用户选了「不指定考点」——此时 [id] 为 null，
/// 调用方要把 `knowledge_node_id` 显式置空（传 null，而不是不传）。
class _OptionPick {
  const _OptionPick({this.id, required this.label, this.cleared = false});

  final String? id;
  final String label;
  final bool cleared;
}

/// 批量移动 / 设置考点共用的选项弹窗（纯 CupertinoActionSheet）。
///
/// 选项多时 CupertinoActionSheet 自己会滚动，所以不再套 ScrollView
/// （套了会和 sheet 自身的滚动抢手势）。
class _OptionPickerSheet extends StatelessWidget {
  const _OptionPickerSheet({
    required this.title,
    required this.message,
    required this.options,
    this.clearLabel,
  });

  final String title;
  final String message;
  final List<_OptionItem> options;

  /// 非空时在列表末尾追加一个「清空」项。
  final String? clearLabel;

  @override
  Widget build(BuildContext context) {
    final String? clearText = clearLabel;
    return CupertinoActionSheet(
      title: Text(
        title,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      message: Column(
        children: <Widget>[
          const SizedBox(height: 6),
          Text(
            message,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.secondaryLabel,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        for (final _OptionItem item in options)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(
              _OptionPick(id: item.id, label: item.label),
            ),
            child: Column(
              children: <Widget>[
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 17,
                    color: AppColors.accent,
                  ),
                ),
                if (item.detail != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    item.detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12,
                      color: AppColors.tertiaryLabel,
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (clearText != null)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(
              _OptionPick(label: clearText, cleared: true),
            ),
            child: Text(
              clearText,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                color: AppColors.overdue,
              ),
            ),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text(
          '取消',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.accent,
          ),
        ),
      ),
    );
  }
}
