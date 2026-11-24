// 考试配置 · 科目管理页。
//
// ── 这一页解决什么问题 ──────────────────────────────────────────────────
// 一个考试目标下有若干科目（subjects），每个科目下才是考点树。
// 目标创建时后端会按 exam_type 套用模板预置 2~6 个科目
// （`core/templates.mjs`），但模板是「常见配置」不是「你的配置」：
// 自考可能要拆成两门专业课，期末可能要加一门实验。本页就是那条
// 「模板之外自己加科目」的路，点某一行继续往考点树走。
//
// ── 为什么不显示考点数 ──────────────────────────────────────────────────
// `GET /exam-profiles/:id/subjects` 返回的科目行里没有考点数，
// 要显示就得对每个科目再发一次 `GET /subjects/:id/knowledge-nodes`
// —— N+1 请求，且列表页根本不需要这个数。故每行只显示 name + kind。
//
// ── kind 为什么给三个选项 ───────────────────────────────────────────────
// `subject_kind` 是 `objective|subjective|essay`（`schema.sql:50`），
// 三个值后端都接受。模板里 `essay` 真的在用（final_exam 的「课程论文」、
// adult_self_study 的「实践环节」），只给两个选项会让用户无法建出
// 与模板同形态的科目，故三个都暴露。

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/defect_api.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart' show EmptyState, PressableCard;
import 'knowledge_node_page.dart';

/// `schema.sql:50` 的 subject_kind 枚举 → 中文标签。
const List<({String value, String label})> _kSubjectKinds =
    <({String value, String label})>[
  (value: 'objective', label: '客观题'),
  (value: 'subjective', label: '主观题'),
  (value: 'essay', label: '写作'),
];

String _kindLabel(Object? raw) {
  final String kind = '${raw ?? ''}'.trim();
  for (final ({String value, String label}) item in _kSubjectKinds) {
    if (item.value == kind) return item.label;
  }
  return '未分类';
}

class SubjectConfigPage extends StatefulWidget {
  const SubjectConfigPage({
    super.key,
    required this.profileId,
    required this.targetLabel,
  });

  final String profileId;
  final String targetLabel;

  @override
  State<SubjectConfigPage> createState() => _SubjectConfigPageState();
}

class _SubjectConfigPageState extends State<SubjectConfigPage> {
  final DefectApi _api = DefectApi();
  // 写操作用裸 ApiClient：DefectApi 只封装了三个 GET，没有 createSubject。
  final ApiClient _client = ApiClient();

  List<Map<String, Object?>> _subjects = const <Map<String, Object?>>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _api.close();
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<Map<String, Object?>> list = await _api.fetchSubjects(
        widget.profileId,
      );
      if (!mounted) return;
      setState(() {
        _subjects = list;
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
        _error = '科目加载失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _openNodes(String subjectId, String subjectName) async {
    await Navigator.of(context).push<void>(
      appRoute<void>(
        context,
        KnowledgeNodePage(subjectId: subjectId, subjectName: subjectName),
      ),
    );
  }

  /// 「添加」弹窗：名称 + kind 三选一。
  ///
  /// 用 `showCupertinoDialog<_SubjectDraft>` 而不是自己 setState 管表单：
  /// 弹窗关掉就该丢掉半截输入，把状态留在页面里反而要额外写清理逻辑。
  Future<void> _openAddDialog() async {
    final _SubjectDraft? draft = await showCupertinoDialog<_SubjectDraft>(
      context: context,
      builder: (BuildContext ctx) => const _SubjectDialog(),
    );
    if (draft == null || !mounted) return;

    try {
      // `exam_profile_id` 必填（缺了后端回 400 missing_exam_profile_id），
      // 本页构造参数里就有，直接带上。
      await _client.post(
        '/subjects',
        body: <String, Object?>{
          'exam_profile_id': widget.profileId,
          'name': draft.name,
          'kind': draft.kind,
        },
      );
      if (!mounted) return;
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      await _alert('添加失败', e.message);
    } catch (e) {
      if (!mounted) return;
      await _alert('添加失败', '$e');
    }
  }

  Future<void> _alert(String title, String message) {
    return showCupertinoDialog<void>(
      context: context,
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
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            message,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.35,
              color: AppColors.label,
            ),
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            isDefaultAction: true,
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
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            previousPageTitle: '返回',
            largeTitle: Text(
              widget.targetLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                color: AppColors.label,
              ),
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(36, 36),
              onPressed: _openAddDialog,
              child: const Text(
                '添加',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
          ),
          ..._buildBody(),
        ],
      ),
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

    if (_subjects.isEmpty) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            title: '还没有科目',
            message: '点右上角「添加」创建科目。',
            icon: CupertinoIcons.folder,
          ),
        ),
      ];
    }

    return <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        sliver: SliverList.separated(
          itemCount: _subjects.length,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 8),
          itemBuilder: (BuildContext context, int index) =>
              _buildRow(_subjects[index]),
        ),
      ),
    ];
  }

  Widget _buildRow(Map<String, Object?> subject) {
    final String id = '${subject['id'] ?? ''}'.trim();
    final String name = '${subject['name'] ?? subject['title'] ?? ''}'.trim();
    final String kind = _kindLabel(subject['kind']);

    return PressableCard(
      onTap: id.isEmpty || name.isEmpty ? null : () => _openNodes(id, name),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: <Widget>[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: const Color(0x14007AFF),
                borderRadius: BorderRadius.circular(AppRadii.chip),
              ),
              child: const Icon(
                CupertinoIcons.folder,
                size: 17,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name.isEmpty ? '未命名科目' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 16,
                      color: AppColors.label,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    kind,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 13,
                      color: AppColors.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
            const CupertinoListTileChevron(),
          ],
        ),
      ),
    );
  }
}

/// 「添加科目」弹窗的返回值。
class _SubjectDraft {
  const _SubjectDraft({required this.name, required this.kind});

  final String name;
  final String kind;
}

/// 添加科目的表单弹窗：名称 + kind 三选一。
///
/// 独立成 StatefulWidget 是因为 chip 的选中态需要 `setState`；
/// 用 `showCupertinoDialog<_SubjectDraft>` 让它自己 `pop` 出结果。
class _SubjectDialog extends StatefulWidget {
  const _SubjectDialog();

  @override
  State<_SubjectDialog> createState() => _SubjectDialogState();
}

class _SubjectDialogState extends State<_SubjectDialog> {
  final TextEditingController _nameCtrl = TextEditingController();
  String _kind = 'objective';

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(_SubjectDraft(name: name, kind: _kind));
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text(
        '添加科目',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: AppColors.label,
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            CupertinoTextField(
              controller: _nameCtrl,
              placeholder: '科目名称，例如：专业课一',
              autofocus: true,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              placeholderStyle: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                color: AppColors.tertiaryLabel,
              ),
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                color: AppColors.label,
              ),
              decoration: BoxDecoration(
                color: AppColors.groupedBackground,
                borderRadius: BorderRadius.circular(AppRadii.chip),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final ({String value, String label}) kind in _kSubjectKinds)
                  _DialogChip(
                    label: kind.label,
                    selected: _kind == kind.value,
                    onTap: () => setState(() => _kind = kind.value),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(),
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
          isDefaultAction: true,
          onPressed: _submit,
          child: const Text(
            '添加',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppColors.accent,
            ),
          ),
        ),
      ],
    );
  }
}

/// 弹窗内的小 chip（比页面级 chip 更紧凑）。
class _DialogChip extends StatelessWidget {
  const _DialogChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0x14007AFF) : AppColors.groupedBackground,
          borderRadius: BorderRadius.circular(AppRadii.chip),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.separator,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.accent : AppColors.secondaryLabel,
          ),
        ),
      ),
    );
  }
}

/// 错误态：可重试（私有类不能跨文件复用，故每页各留一份）。
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
