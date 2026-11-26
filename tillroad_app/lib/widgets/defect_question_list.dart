// 缺陷单 ↔ 题目 关联列表（任务 C4）。
//
// 纯 Cupertino 实现（工程禁用 Material）：没有 ListTile / Divider / IconButton，
// 分隔线用 `SizedBox(height: 0.5, child: ColoredBox(color: AppColors.separator))`，
// 图标用 `CupertinoIcons.*`。
//
// 组件只负责**呈现与交互**，不直接调 API：
//   · 排序：拖拽结束后回调 `onReorder(List<String> orderedQuestionIds)`，
//     由页面负责调用 `PUT /defect-tickets/:id/questions/sort`；
//   · 移除：回调 `onRemove(String questionId)`；
//   · 关联：弹层里多选题干，回调 `onLink(List<String> questionIds)`。
// 这样页面层能统一处理「后端 409 重复关联」等错误提示，组件不用关心 ApiException。

import 'package:flutter/cupertino.dart';

import '../api/defect_api.dart';
import '../theme/app_theme.dart';

/// 缺陷单关联的题目列表。
class DefectQuestionList extends StatelessWidget {
  const DefectQuestionList({
    super.key,
    required this.questions,
    required this.onReorder,
    required this.onRemove,
    required this.onLink,
    this.questionLoader,
    this.loading = false,
    this.emptyBuilder,
    this.title = '关联题目',
  });

  /// 当前已关联的题目（按 sort ASC）。
  final List<DefectLinkedQuestion> questions;

  /// 拖拽排序完成回调，参数是**目标顺序**的 question_id 列表。
  final void Function(List<String> orderedQuestionIds) onReorder;

  /// 点「移除」回调，参数是被移除的 question_id。
  final void Function(String questionId) onRemove;

  /// 点「关联」并提交后回调，参数是**要新增关联**的 question_id 列表
  /// （已在列表里的由弹层先行剔除，见 [_QuestionPickerSheet]）。
  final void Function(List<String> questionIds) onLink;

  /// 候选题目加载器（弹层打开时调用，一般是
  /// `DefectApi.fetchSelectableQuestions`）。为空时弹层提示「加载器未初始化」。
  final Future<List<SelectableQuestion>> Function()? questionLoader;

  /// 加载中（此时显示 loading 文案，禁用操作）。
  final bool loading;

  /// 空态定制。
  final WidgetBuilder? emptyBuilder;

  /// 区块标题。
  final String title;

  @override
  Widget build(BuildContext context) {
    final bool isEmpty = questions.isEmpty && !loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.label,
                ),
              ),
            ),
            Text(
              '${questions.length} 道',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: AppColors.secondaryLabel,
              ),
            ),
            const SizedBox(width: 8),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minSize: 28,
              onPressed: loading ? null : () => _openPicker(context),
              child: const Text(
                '关联题目',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 14,
                  color: AppColors.accent,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '加载中…',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: AppColors.secondaryLabel,
              ),
            ),
          )
        else if (isEmpty)
          emptyBuilder?.call(context) ??
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '还没有关联题目',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    color: AppColors.tertiaryLabel,
                  ),
                ),
              )
        else
          _QuestionList(
            questions: questions,
            onReorder: onReorder,
            onRemove: onRemove,
          ),
      ],
    );
  }

  Future<void> _openPicker(BuildContext context) async {
    final List<String>? picked = await showCupertinoModalPopup<List<String>>(
      context: context,
      builder: (BuildContext ctx) => _QuestionPickerSheet(
        loader: questionLoader,
        existingQuestionIds: questions
            .map((DefectLinkedQuestion q) => q.questionId)
            .toList(growable: false),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    onLink(picked);
  }
}

/// 关联题目弹层：多选题干 → 返回「要新增关联」的 question_id 列表。
///
/// 已经在列表里的题会被**剔除**（并在界面上标出「已在列表中」），
/// 避免把后端 409 `duplicate_defect_question` 当成错误弹给用户。
class _QuestionPickerSheet extends StatefulWidget {
  const _QuestionPickerSheet({
    required this.loader,
    required this.existingQuestionIds,
  });

  /// 候选题加载器。
  final Future<List<SelectableQuestion>> Function()? loader;

  /// 已在列表中的 question_id（这些题不可再选）。
  final List<String> existingQuestionIds;

  @override
  State<_QuestionPickerSheet> createState() => _QuestionPickerSheetState();
}

class _QuestionPickerSheetState extends State<_QuestionPickerSheet> {
  List<SelectableQuestion> _items = const <SelectableQuestion>[];
  final Set<String> _selected = <String>{};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Future<List<SelectableQuestion>> Function()? loader = widget.loader;
    if (loader == null) {
      setState(() {
        _loading = false;
        _error = '题目列表加载器未初始化';
      });
      return;
    }
    try {
      final List<SelectableQuestion> items = await loader();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  bool _isExisting(String id) => widget.existingQuestionIds.contains(id);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: AppColors.groupedBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.card)),
      ),
      child: Column(
        children: <Widget>[
          Container(
            color: AppColors.card,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: <Widget>[
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minSize: 32,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    '取消',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 15,
                      color: AppColors.secondaryLabel,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '选择要关联的题目',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.label,
                    ),
                  ),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minSize: 32,
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(
                            _selected
                                .where((String id) => !_isExisting(id))
                                .toList(growable: false),
                          ),
                  child: Text(
                    '关联${_selected.isEmpty ? '' : '(${_selected.length})'}',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 15,
                      color: _selected.isEmpty
                          ? AppColors.tertiaryLabel
                          : AppColors.accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CupertinoActivityIndicator())
                : _error != null
                    ? _ErrorHint(message: _error!, onRetry: _load)
                    : _items.isEmpty
                        ? const _Hint(
                            message: '题库里还没有题目，先去题库导入题目。',
                          )
                        : ListView.separated(
                            itemCount: _items.length,
                            separatorBuilder: (_, __) => const SizedBox(
                              height: 0.5,
                              child: ColoredBox(color: AppColors.separator),
                            ),
                            itemBuilder: (BuildContext ctx, int index) {
                              final SelectableQuestion item = _items[index];
                              final bool existing = _isExisting(item.id);
                              final bool checked = _selected.contains(item.id);
                              return _PickerRow(
                                item: item,
                                checked: checked,
                                existing: existing,
                                onTap: existing
                                    ? null
                                    : () => setState(() {
                                          if (checked) {
                                            _selected.remove(item.id);
                                          } else {
                                            _selected.add(item.id);
                                          }
                                        }),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

/// 关联题目列表本体（可拖拽排序）。
class _QuestionList extends StatelessWidget {
  const _QuestionList({
    required this.questions,
    required this.onReorder,
    required this.onRemove,
  });

  final List<DefectLinkedQuestion> questions;
  final void Function(List<String> orderedQuestionIds) onReorder;
  final void Function(String questionId) onRemove;

  @override
  Widget build(BuildContext context) {
    return ReorderableList(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: questions.length,
      onReorderItem: (int oldIndex, int newIndex) {
        // `onReorderItem` 给的 newIndex 已经是「移除旧项之后」的下标，
        // 直接按它重排即可（不需要再手动 +1）。
        final List<DefectLinkedQuestion> next =
            List<DefectLinkedQuestion>.of(questions);
        final DefectLinkedQuestion moved = next.removeAt(oldIndex);
        next.insert(newIndex.clamp(0, next.length), moved);
        onReorder(
          next
              .map((DefectLinkedQuestion q) => q.questionId)
              .toList(growable: false),
        );
      },
      itemBuilder: (BuildContext context, int index) {
        final DefectLinkedQuestion q = questions[index];
        return _QuestionRow(
          key: ValueKey<String>(q.questionId),
          index: index,
          question: q,
          onRemove: () => onRemove(q.questionId),
        );
      },
    );
  }
}

/// 单行：序号 + 题干摘要 + 类型标签 + 移除按钮（左侧带拖拽手柄）。
class _QuestionRow extends StatelessWidget {
  const _QuestionRow({
    super.key,
    required this.index,
    required this.question,
    required this.onRemove,
  });

  final int index;
  final DefectLinkedQuestion question;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final String stem = question.stem.trim();
    final String excerpt = stem.length > 60
        ? '${stem.substring(0, 60)}…'
        : (stem.isEmpty ? '（无题干）' : stem);
    return Container(
      color: AppColors.card,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(
                CupertinoIcons.line_horizontal_3,
                size: 18,
                color: AppColors.tertiaryLabel,
              ),
            ),
          ),
          SizedBox(
            width: 22,
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: AppColors.tertiaryLabel,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  excerpt,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 14,
                    color: AppColors.label,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  question.typeLabel,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    color: AppColors.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minSize: 28,
            onPressed: onRemove,
            child: const Text(
              '移除',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: AppColors.overdue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 弹层里的一行候选题。
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.item,
    required this.checked,
    required this.existing,
    required this.onTap,
  });

  final SelectableQuestion item;
  final bool checked;
  final bool existing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final String stem = item.stem.trim();
    final String excerpt = stem.length > 60
        ? '${stem.substring(0, 60)}…'
        : (stem.isEmpty ? '（无题干）' : stem);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: AppColors.card,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            Icon(
              checked
                  ? CupertinoIcons.check_mark_circled
                  : CupertinoIcons.circle,
              size: 20,
              color: checked ? AppColors.accent : AppColors.tertiaryLabel,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    excerpt,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 14,
                      color: AppColors.label,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    existing ? '${item.typeLabel} · 已在列表中' : item.typeLabel,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12,
                      color: AppColors.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            color: AppColors.secondaryLabel,
          ),
        ),
      ),
    );
  }
}

class _ErrorHint extends StatelessWidget {
  const _ErrorHint({required this.message, required this.onRetry});

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
            Text(
              '题目列表加载失败',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                color: AppColors.label,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                color: AppColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 8),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              minSize: 30,
              onPressed: onRetry,
              child: const Text(
                '重试',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 14,
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
