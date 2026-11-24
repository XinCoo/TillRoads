// 考试配置 · 考点树页。
//
// ── 这一页解决什么问题 ──────────────────────────────────────────────────
// 考点（knowledge_node）是整条备考链的最底层：目标 → 科目 → 考点树。
// 后面的「掌握度」「复习计划」都挂在这棵树上，所以这里是唯一需要
// 支持「层级」的配置页——父子考点、缩进、展开折叠都在这一页。
//
// ── 为什么前端自己建树 ──────────────────────────────────────────────────
// `GET /subjects/:id/knowledge-nodes` 回的是**扁平**列表
// （`{items:[...], limit, offset}`，按 created_at ASC）。后端另有
// `GET /subjects/:id/knowledge-tree` 直接给嵌套树，但任务书要求用
// `DefectApi.fetchKnowledgeNodes`（它固定走扁平端点、limit=200），
// 且扁平列表让「按 parent_id 重挂父节点」这类操作在内存里更好推理。
// 故本页在 `_buildTree()` 里把扁平行拼成 `_Node` 树。
//
// ── 200 条上限 ─────────────────────────────────────────────────────────
// `fetchKnowledgeNodes` 内部写死 `limit=200`，后端 `pageParams` 也把
// limit 钳到 200，所以超过 200 个考点会被静默截断。这是既有 API 的
// 限制（不在本次可改范围内），页面上不做分页——单科目的考点树超过
// 200 个节点本身说明该拆科目了，故不为此增加复杂度。
//
// ── 乐观锁（version）──────────────────────────────────────────────────
// PATCH / DELETE 都必须带 `version`，后端据此判断「你看到的是不是最新」。
// 不匹配回 `409 {error:'conflict', resolution:'client_merge'}`；此时**不能**
// 盲目重试（会用旧 version 再撞一次），正确做法是提示用户并重拉最新数据，
// 让用户在新的数据上重新操作。

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show TextInputType;

import '../api/api_client.dart';
import '../api/defect_api.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart' show EmptyState, PressableCard;

/// `schema.sql:202` 的 freq_tag 枚举 → 中文标签。
const List<({String value, String label})> _kFreqTags =
    <({String value, String label})>[
  (value: 'high', label: '高频'),
  (value: 'mid', label: '中频'),
  (value: 'low', label: '低频'),
];

String _freqLabel(String? tag) {
  for (final ({String value, String label}) item in _kFreqTags) {
    if (item.value == tag) return item.label;
  }
  return '未标注';
}

Color _freqColor(String? tag) {
  switch (tag) {
    case 'high':
      return AppColors.overdue;
    case 'mid':
      return AppColors.dueSoon;
    case 'low':
      return AppColors.secondaryLabel;
    default:
      return AppColors.tertiaryLabel;
  }
}

String _asText(Object? raw) => raw == null ? '' : '$raw'.trim();

double? _asDouble(Object? raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toDouble();
  return double.tryParse('$raw');
}

int? _asInt(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse('$raw');
}

/// 内存里的考点节点。
class _Node {
  _Node({
    required this.id,
    required this.title,
    required this.parentId,
    required this.freqTag,
    required this.weight,
    required this.version,
  });

  final String id;
  final String title;
  final String? parentId;
  final String? freqTag;
  final double? weight;
  final int? version;
  final List<_Node> children = <_Node>[];

  bool get hasChildren => children.isNotEmpty;
}

/// 摊平后的一行（缩进由 depth 决定）。
class _FlatNode {
  const _FlatNode({required this.node, required this.depth});

  final _Node node;
  final int depth;
}

class KnowledgeNodePage extends StatefulWidget {
  const KnowledgeNodePage({
    super.key,
    required this.subjectId,
    required this.subjectName,
  });

  final String subjectId;
  final String subjectName;

  @override
  State<KnowledgeNodePage> createState() => _KnowledgeNodePageState();
}

class _KnowledgeNodePageState extends State<KnowledgeNodePage> {
  final DefectApi _api = DefectApi();
  final ApiClient _client = ApiClient();

  List<Map<String, Object?>> _rows = const <Map<String, Object?>>[];
  bool _loading = true;
  String? _error;

  /// 折叠的节点 id 集合。用「折叠集」而不是「展开集」是为了实现
  /// 「默认全展开」：新拉到的节点默认不在集合里 = 展开。
  final Set<String> _collapsed = <String>{};

  /// 写操作进行中：禁掉重复提交（尤其是删除，连点两次会第二次 404）。
  bool _busy = false;

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
      final List<Map<String, Object?>> list = await _api.fetchKnowledgeNodes(
        widget.subjectId,
      );
      if (!mounted) return;
      setState(() {
        _rows = list;
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
        _error = '考点加载失败：$e';
        _loading = false;
      });
    }
  }

  /// 扁平列表 → 树。父节点不在列表里的行按根处理
  /// （父节点被删/被截断时不能让整行消失，否则用户没法收拾）。
  ({List<_Node> roots, Map<String, _Node> byId}) _buildTree() {
    final Map<String, _Node> byId = <String, _Node>{};
    final List<_Node> roots = <_Node>[];

    for (final Map<String, Object?> row in _rows) {
      final String id = _asText(row['id']);
      if (id.isEmpty) continue;
      final String parent = _asText(row['parent_id']);
      byId[id] = _Node(
        id: id,
        title: _asText(row['title']),
        parentId: parent.isEmpty ? null : parent,
        freqTag: _asText(row['freq_tag']).isEmpty
            ? null
            : _asText(row['freq_tag']),
        weight: _asDouble(row['weight_to_target']),
        version: _asInt(row['version']),
      );
    }

    for (final _Node node in byId.values) {
      final String? parentId = node.parentId;
      final _Node? parent = parentId == null ? null : byId[parentId];
      if (parent == null || parent.id == node.id) {
        roots.add(node);
      } else {
        parent.children.add(node);
      }
    }
    return (roots: roots, byId: byId);
  }

  /// 按当前折叠状态摊平成可渲染的行。
  List<_FlatNode> _flatten(List<_Node> roots) {
    final List<_FlatNode> out = <_FlatNode>[];
    void walk(_Node node, int depth) {
      out.add(_FlatNode(node: node, depth: depth));
      if (_collapsed.contains(node.id)) return;
      for (final _Node child in node.children) {
        walk(child, depth + 1);
      }
    }

    for (final _Node root in roots) {
      walk(root, 0);
    }
    return out;
  }

  // ── 写操作 ────────────────────────────────────────────────────────────

  Future<void> _createNode({
    required String title,
    required String freqTag,
    required double? weight,
    String? parentId,
  }) async {
    setState(() => _busy = true);
    try {
      await _client.post(
        '/knowledge-nodes',
        body: <String, Object?>{
          'subject_id': widget.subjectId,
          'title': title,
          'freq_tag': freqTag,
          // 加根考点时不传 parent_id（不是传 null）。
          if (parentId != null) 'parent_id': parentId,
          if (weight != null) 'weight_to_target': weight,
        },
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _handleWriteError('添加失败', e);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _alert('添加失败', '$e');
    }
  }

  Future<void> _updateNode({
    required _Node node,
    required String title,
    required String freqTag,
    required double? weight,
  }) async {
    final int? version = node.version;
    if (version == null) {
      await _alert('无法编辑', '这条数据缺少版本号，请刷新后重试。');
      return;
    }

    setState(() => _busy = true);
    try {
      await _client.patch(
        '/knowledge-nodes/${node.id}',
        body: <String, Object?>{
          // 乐观锁：后端拿它比对，不匹配回 409。
          'version': version,
          'title': title,
          'freq_tag': freqTag,
          if (weight != null) 'weight_to_target': weight,
        },
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _handleWriteError('编辑失败', e);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _alert('编辑失败', '$e');
    }
  }

  Future<void> _deleteNode(_Node node) async {
    final int? version = node.version;
    if (version == null) {
      await _alert('无法删除', '这条数据缺少版本号，请刷新后重试。');
      return;
    }

    setState(() => _busy = true);
    try {
      await _client.delete(
        '/knowledge-nodes/${node.id}',
        body: <String, Object?>{'version': version},
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _handleWriteError('删除失败', e);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _alert('删除失败', '$e');
    }
  }

  /// 409 是版本冲突：**不要**拿旧 version 重试（会再撞一次），
  /// 而是提示「已被修改」并重拉，让用户在新数据上重做。
  Future<void> _handleWriteError(String title, ApiException e) async {
    if (e.statusCode == 409) {
      await _alert(title, '该内容已被修改，请刷新后重试');
      if (!mounted) return;
      await _load();
      return;
    }
    await _alert(title, e.message);
  }

  // ── 弹窗 ──────────────────────────────────────────────────────────────

  Future<void> _openAddDialog({_Node? parent}) async {
    final _NodeDraft? draft = await showCupertinoDialog<_NodeDraft>(
      context: context,
      builder: (BuildContext ctx) => _NodeDialog(
        heading: parent == null ? '添加考点' : '在「${parent.title}」下添加',
      ),
    );
    if (draft == null || !mounted) return;
    await _createNode(
      title: draft.title,
      freqTag: draft.freqTag,
      weight: draft.weight,
      parentId: parent?.id,
    );
  }

  Future<void> _openEditDialog(_Node node) async {
    final _NodeDraft? draft = await showCupertinoDialog<_NodeDraft>(
      context: context,
      builder: (BuildContext ctx) => _NodeDialog(
        heading: '编辑考点',
        initialTitle: node.title,
        initialFreqTag: node.freqTag,
        initialWeight: node.weight,
      ),
    );
    if (draft == null || !mounted) return;
    await _updateNode(
      node: node,
      title: draft.title,
      freqTag: draft.freqTag,
      weight: draft.weight,
    );
  }

  Future<void> _openActions(_Node node) async {
    // Flutter 没有 `showCupertinoActionSheet` 这个函数（很容易误写）：
    // `CupertinoActionSheet` 本身是普通 Widget，要用 `showCupertinoModalPopup` 弹。
    final String? action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (BuildContext ctx) => CupertinoActionSheet(
        title: Text(
          node.title.isEmpty ? '未命名考点' : node.title,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        message: Text(
          '${_freqLabel(node.freqTag)} · 权重 ${node.weight == null ? '未设置' : node.weight!.toStringAsFixed(3)}',
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            color: AppColors.secondaryLabel,
          ),
        ),
        actions: <Widget>[
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
            onPressed: () => Navigator.of(ctx).pop('delete'),
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
      ),
    );

    if (!mounted || action == null) return;
    if (action == 'edit') {
      await _openEditDialog(node);
    } else if (action == 'delete') {
      await _confirmDelete(node);
    }
  }

  Future<void> _confirmDelete(_Node node) async {
    final bool? ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '删除考点',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            node.hasChildren
                ? '「${node.title}」下还有 ${node.children.length} 个子考点，删除后它们会失去父节点。确定删除？'
                : '确定删除「${node.title}」？',
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
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              '删除',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.overdue,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _deleteNode(node);
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

  // ── UI ────────────────────────────────────────────────────────────────

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
              widget.subjectName,
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
              onPressed: _busy ? null : () => _openAddDialog(),
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

    final ({List<_Node> roots, Map<String, _Node> byId}) tree = _buildTree();
    if (tree.roots.isEmpty) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            title: '还没有考点',
            message: '点右上角「添加」创建第一个考点。',
            icon: CupertinoIcons.list_bullet,
          ),
        ),
      ];
    }

    final List<_FlatNode> flat = _flatten(tree.roots);
    return <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        sliver: SliverList.separated(
          itemCount: flat.length,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 8),
          itemBuilder: (BuildContext context, int index) =>
              _buildRow(flat[index]),
        ),
      ),
    ];
  }

  Widget _buildRow(_FlatNode item) {
    final _Node node = item.node;
    final bool collapsed = _collapsed.contains(node.id);

    return Padding(
      // 缩进 depth * 16：树的层级感全靠这个，别用更小的值，
      // 三级以后会看不出层级。
      padding: EdgeInsets.only(left: item.depth * 16),
      child: PressableCard(
        onTap: _busy ? null : () => _openActions(node),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 6, 10),
          child: Row(
            children: <Widget>[
              // 折叠箭头：没有子节点时占位保持文字左对齐一致。
              SizedBox(
                width: 26,
                child: node.hasChildren
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          setState(() {
                            if (collapsed) {
                              _collapsed.remove(node.id);
                            } else {
                              _collapsed.add(node.id);
                            }
                          });
                        },
                        child: Icon(
                          collapsed
                              ? CupertinoIcons.chevron_right
                              : CupertinoIcons.chevron_down,
                          size: 15,
                          color: AppColors.secondaryLabel,
                        ),
                      )
                    : null,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      node.title.isEmpty ? '未命名考点' : node.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 15,
                        color: AppColors.label,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _freqColor(node.freqTag).withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _freqLabel(node.freqTag),
                            style: TextStyle(
                              fontFamily: kFontFamily,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: _freqColor(node.freqTag),
                            ),
                          ),
                        ),
                        if (node.weight != null) ...<Widget>[
                          const SizedBox(width: 6),
                          Text(
                            '权重 ${node.weight!.toStringAsFixed(3)}',
                            style: const TextStyle(
                              fontFamily: kFontFamily,
                              fontSize: 11,
                              color: AppColors.secondaryLabel,
                            ),
                          ),
                        ],
                        if (node.hasChildren) ...<Widget>[
                          const SizedBox(width: 6),
                          Text(
                            '${node.children.length} 个子考点',
                            style: const TextStyle(
                              fontFamily: kFontFamily,
                              fontSize: 11,
                              color: AppColors.tertiaryLabel,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // 加子考点：比「点整行再选」少一步，树深的时候很常用。
              CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: const Size(32, 32),
                onPressed: _busy ? null : () => _openAddDialog(parent: node),
                child: const Icon(
                  CupertinoIcons.plus_circle,
                  size: 20,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 新建/编辑考点弹窗的返回值。
class _NodeDraft {
  const _NodeDraft({
    required this.title,
    required this.freqTag,
    required this.weight,
  });

  final String title;
  final String freqTag;
  final double? weight;
}

/// 新建 / 编辑共用的表单弹窗。
///
/// 新建与编辑的字段完全相同（title + freq_tag + weight_to_target），
/// 只有标题和初值不同，故合成一个类；`initialXxx` 为 null 即新建。
class _NodeDialog extends StatefulWidget {
  const _NodeDialog({
    required this.heading,
    this.initialTitle,
    this.initialFreqTag,
    this.initialWeight,
  });

  final String heading;
  final String? initialTitle;
  final String? initialFreqTag;
  final double? initialWeight;

  @override
  State<_NodeDialog> createState() => _NodeDialogState();
}

class _NodeDialogState extends State<_NodeDialog> {
  late final TextEditingController _titleCtrl = TextEditingController(
    text: widget.initialTitle ?? '',
  );
  late final TextEditingController _weightCtrl = TextEditingController(
    text: widget.initialWeight == null
        ? ''
        : widget.initialWeight!.toStringAsFixed(3),
  );
  late String _freqTag = widget.initialFreqTag ?? 'mid';
  String? _hint;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _weightCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final String title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _hint = '请填写考点名称');
      return;
    }

    final String weightText = _weightCtrl.text.trim();
    double? weight;
    if (weightText.isNotEmpty) {
      weight = double.tryParse(weightText);
      if (weight == null) {
        setState(() => _hint = '权重需为数字，例如 0.250');
        return;
      }
      // 后端是 numeric(4,3)：范围 [0, 9.999]，最多 3 位小数。
      // 前端先挡一道，省得提交后吃 400 INVALID_WEIGHT。
      if (weight < 0 || weight > 9.999) {
        setState(() => _hint = '权重需在 0 ~ 9.999 之间');
        return;
      }
    }

    Navigator.of(context).pop(
      _NodeDraft(title: title, freqTag: _freqTag, weight: weight),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: Text(
        widget.heading,
        maxLines: 2,
        style: const TextStyle(
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
              controller: _titleCtrl,
              placeholder: '考点名称',
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
            const SizedBox(height: 10),
            CupertinoTextField(
              controller: _weightCtrl,
              placeholder: '目标权重（可选，0~9.999）',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
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
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final ({String value, String label}) tag in _kFreqTags)
                  _DialogChip(
                    label: tag.label,
                    selected: _freqTag == tag.value,
                    color: _freqColor(tag.value),
                    onTap: () => setState(() {
                      _freqTag = tag.value;
                      _hint = null;
                    }),
                  ),
              ],
            ),
            if (_hint != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _hint!,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  color: AppColors.overdue,
                ),
              ),
            ],
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
    );
  }
}

/// 弹窗内的频次 chip。
class _DialogChip extends StatelessWidget {
  const _DialogChip({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.12)
              : AppColors.groupedBackground,
          borderRadius: BorderRadius.circular(AppRadii.chip),
          border: Border.all(
            color: selected ? color : AppColors.separator,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? color : AppColors.secondaryLabel,
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
