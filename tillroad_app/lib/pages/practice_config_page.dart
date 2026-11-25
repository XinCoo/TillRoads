// 练习配置页（练习 R1 · 任务 C1）。
//
// 职责：选范围 → 抽题 → 把题交给答题页。
//   · 科目：来自 exam_profiles → subjects（与建单页同一套数据源）。
//   · 考点：可选，来自 subjects/:id/knowledge-nodes。
//   · 来源：我导入的 / 公共题 / 全部。
//   · 题量：10 / 20 / 30 / 50。
//
// ── 一条关键设计：题量不足不报错 ──────────────────────────────────────────
// 后端 `GET /questions/practice` 在该范围题量不足时返回 **200**，
// items 短于请求数，并额外给 `available` 字段（这是 R1 任务书的明确要求，
// 与模考的 `INSUFFICIENT_QUESTIONS` 400 行为不同）。
// 所以这一页不能把「不足」当错误处理，要先问用户「按 N 道开始？」。
import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/defect_api.dart';
import '../api/practice_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/form_field.dart';
import 'practice_answering_page.dart';

/// 可选题量（任务书 C1：10/20/30/50）。
const List<int> kPracticeCounts = <int>[10, 20, 30, 50];

class PracticeConfigPage extends StatefulWidget {
  const PracticeConfigPage({
    super.key,
    this.initialSubjectId,
    this.initialKnowledgeNodeId,
    this.initialSource = PracticeSource.all,
    this.initialExamProfileId,
    this.initialSubjectName,
  });

  /// 题库页「练习这批题」带进来的科目。
  final String? initialSubjectId;
  final String? initialKnowledgeNodeId;
  final PracticeSource initialSource;

  /// 题库页带进来的考试目标与科目名（「去归因」建单页要用）。
  final String? initialExamProfileId;
  final String? initialSubjectName;

  @override
  State<PracticeConfigPage> createState() => _PracticeConfigPageState();
}

class _PracticeConfigPageState extends State<PracticeConfigPage> {
  final DefectApi _defectApi = DefectApi();
  final PracticeApi _practiceApi = PracticeApi();

  List<Map<String, Object?>> _profiles = const <Map<String, Object?>>[];
  List<Map<String, Object?>> _subjects = const <Map<String, Object?>>[];
  List<Map<String, Object?>> _nodes = const <Map<String, Object?>>[];

  String? _profileId;
  String? _subjectId;
  String? _nodeId;
  PracticeSource _source = PracticeSource.all;
  int _count = 10;

  bool _loadingProfiles = true;
  bool _loadingSubjects = false;
  bool _loadingNodes = false;
  bool _busy = false;
  String? _bannerError;

  @override
  void initState() {
    super.initState();
    _source = widget.initialSource;
    _subjectId = widget.initialSubjectId;
    _nodeId = widget.initialKnowledgeNodeId;
    _profileId = widget.initialExamProfileId;
    _loadProfiles();
  }

  @override
  void dispose() {
    _defectApi.close();
    _practiceApi.close();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    try {
      final List<Map<String, Object?>> profiles =
          await _defectApi.fetchExamProfiles(kDemoUserId);
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _profileId = _profileId ??
            (profiles.isEmpty ? null : '${profiles.first['id']}');
        _loadingProfiles = false;
      });
      if (_profileId != null) await _loadSubjects(_profileId!);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingProfiles = false;
        _bannerError = '考试目标加载失败：${e.message}';
      });
    }
  }

  Future<void> _loadSubjects(String profileId) async {
    setState(() => _loadingSubjects = true);
    try {
      final List<Map<String, Object?>> subjects =
          await _defectApi.fetchSubjects(profileId);
      if (!mounted) return;
      setState(() {
        _subjects = subjects;
        _loadingSubjects = false;
        // 预置的科目若不存在（题库页带来的），清掉避免对不上。
        if (_subjectId != null &&
            !subjects.any((Map<String, Object?> s) => '${s['id']}' == _subjectId)) {
          _subjectId = null;
          _nodeId = null;
        }
        if (_subjectId == null && subjects.isNotEmpty) {
          _subjectId = '${subjects.first['id']}';
        }
      });
      if (_subjectId != null) await _loadNodes(_subjectId!);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingSubjects = false;
        _bannerError = '科目加载失败：${e.message}';
      });
    }
  }

  Future<void> _loadNodes(String subjectId) async {
    setState(() => _loadingNodes = true);
    try {
      final List<Map<String, Object?>> nodes =
          await _defectApi.fetchKnowledgeNodes(subjectId);
      if (!mounted) return;
      setState(() {
        _nodes = nodes;
        _loadingNodes = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingNodes = false;
        _bannerError = '考点加载失败：${e.message}';
      });
    }
  }

  void _pickSubject(String? subjectId) {
    setState(() {
      _subjectId = subjectId;
      _nodeId = null;
      _nodes = const <Map<String, Object?>>[];
    });
    if (subjectId != null) _loadNodes(subjectId);
  }

  String _subjectName(String? id) {
    if (id == null) return '';
    for (final Map<String, Object?> s in _subjects) {
      if ('${s['id']}' == id) return '${s['name'] ?? ''}';
    }
    return widget.initialSubjectName ?? '';
  }

  /// 抽题并进入答题页。
  Future<void> _start() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _bannerError = null;
    });
    try {
      final PracticePick pick = await _practiceApi.pickQuestions(
        subjectId: _subjectId,
        knowledgeNodeId: _nodeId,
        source: _source,
        count: _count,
      );
      if (!mounted) return;

      if (pick.items.isEmpty) {
        setState(() {
          _busy = false;
          _bannerError = '这个范围里还没有题目。先导入或建几道题再来练习。';
        });
        return;
      }

      // 题量不足 → 先问用户，不擅自缩水。
      int count = pick.items.length;
      if (pick.insufficient) {
        final bool? go = await _confirmFewQuestions(pick.items.length);
        if (!mounted) return;
        if (go != true) {
          setState(() => _busy = false);
          return;
        }
        count = pick.items.length;
      }

      setState(() => _busy = false);
      await Navigator.of(context).push<void>(
        appRoute<void>(
          context,
          PracticeAnsweringPage(
            questions: pick.items,
            source: _source,
            subjectId: _subjectId,
            knowledgeNodeId: _nodeId,
            examProfileId: _profileId,
            subjectName: _subjectName(_subjectId),
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _bannerError = e.isNetworkError
            ? '${e.message}\n请确认后端在运行，然后重试。'
            : e.message;
      });
    }
  }

  Future<bool?> _confirmFewQuestions(int available) {
    return showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '题目不够',
          style: TextStyle(fontFamily: kFontFamily, fontSize: 17),
        ),
        content: Text(
          '该范围只有 $available 道题，是否按 $available 道开始？',
          style: const TextStyle(fontFamily: kFontFamily, fontSize: 14),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              '取消',
              style: TextStyle(fontFamily: kFontFamily),
            ),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              '开始练习',
              style: TextStyle(fontFamily: kFontFamily),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FormScaffold(
      title: '开始练习',
      children: <Widget>[
        if (_bannerError != null)
          FormErrorBanner(message: _bannerError!),
        FormFieldGroup(
          label: '来源',
          required: true,
          hint: '「我导入的」的题有标准答案，可自动判分；「公共题」没有答案，需要你自己评对错',
          child: FormChipGroup(
            options: PracticeSource.values
                .map((PracticeSource s) => s.wire)
                .toList(growable: false),
            selected: _source.wire,
            labelOf: (String wire) =>
                PracticeSource.fromWire(wire).label,
            onChanged: (String wire) =>
                setState(() => _source = PracticeSource.fromWire(wire)),
          ),
        ),
        FormFieldGroup(
          label: '题量',
          required: true,
          hint: '实际能抽到多少题由题库决定；不够时会先问你',
          child: FormChipGroup(
            options: kPracticeCounts.map((int c) => '$c').toList(growable: false),
            selected: '$_count',
            labelOf: (String c) => '$c 道',
            onChanged: (String c) => setState(() => _count = int.parse(c)),
          ),
        ),
        FormFieldGroup(
          label: '科目',
          hint: _loadingProfiles
              ? '正在加载考试目标…'
              : (_loadingSubjects
                  ? '正在加载科目…'
                  : '不选则从全部科目里抽题'),
          child: _loadingProfiles || _loadingSubjects
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CupertinoActivityIndicator(radius: 9),
                  ),
                )
              : (_subjects.isEmpty
                  ? const FormEmptyHint(text: '暂无科目，请先在「考试配置」里建一个')
                  : FormChipGroup(
                      options: _subjects
                          .map((Map<String, Object?> s) => '${s['id']}')
                          .toList(growable: false),
                      selected: _subjectId,
                      labelOf: (String id) {
                        for (final Map<String, Object?> s in _subjects) {
                          if ('${s['id']}' == id) return '${s['name'] ?? ''}';
                        }
                        return id;
                      },
                      onChanged: _pickSubject,
                    )),
        ),
        FormFieldGroup(
          label: '考点',
          hint: _loadingNodes
              ? '正在加载考点…'
              : (_nodes.isEmpty ? '该科目下暂无考点，可不选' : '可不选；选了只抽该考点的题'),
          child: _loadingNodes
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CupertinoActivityIndicator(radius: 9),
                  ),
                )
              : (_nodes.isEmpty
                  ? const FormEmptyHint(text: '暂无可选考点')
                  : FormChipGroup(
                      options: _nodes
                          .map((Map<String, Object?> n) => '${n['id']}')
                          .toList(growable: false),
                      selected: _nodeId,
                      labelOf: (String id) {
                        final int idx = _nodes.indexWhere(
                          (Map<String, Object?> n) => '${n['id']}' == id,
                        );
                        if (idx < 0) return id;
                        final String freq = '${_nodes[idx]['freq_tag'] ?? ''}';
                        final String suffix = switch (freq) {
                          'high' => ' · 高频',
                          'mid' => ' · 中频',
                          'low' => ' · 低频',
                          _ => '',
                        };
                        return '${_nodes[idx]['title'] ?? ''}$suffix';
                      },
                      onChanged: (String v) => setState(() {
                        _nodeId = _nodeId == v ? null : v;
                      }),
                    )),
        ),
        const SizedBox(height: 8),
        FormSubmitButton(
          label: '抽题并开始',
          busy: _busy,
          onPressed: _start,
        ),
        const SizedBox(height: 12),
        Text(
          '练习不限时。提交后会保存一次练习记录，可以在「我的 → 练习记录」里回看。',
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 12,
            height: 1.4,
            color: AppColors.tertiaryLabel,
          ),
        ),
      ],
    );
  }
}
