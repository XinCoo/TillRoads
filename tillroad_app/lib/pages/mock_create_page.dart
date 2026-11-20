// 组卷配置页（FE-05 任务 B）。
//
// 职责：收集「考试目标 / 模式 / 范围 / 题量 / 限时」，调 POST /mock-exams 组卷，
// 成功后用 **replace** 进答题页 —— 这样用户在答题页按返回不会退回配置页
// （否则会误触「再组一次卷」，而上一张卷已经落库）。
//
// ── 与任务书的偏差（已记入答复）─────────────────────────────────────────────
//
// 任务书 B2 说 module 模式的考点选择「文本输入 或 从 subjects 下拉，二选一」。
// 这里选**下拉**：先拉 `GET /exam-profiles/:id/subjects`，再按所选科目拉
// `GET /subjects/:id/knowledge-nodes`。原因：后端 `knowledge_node_id` 是 uuid，
// 让用户手输 uuid 不可用，而手输「考点中文名」又需要后端按名称反查（没有该端点）。
//
// ── 后端契约（curl 实测）───────────────────────────────────────────────────
//   * 缺范围字段时后端分别返回 MISSING_KNOWLEDGE_NODE_ID / MISSING_SUBJECT_ID，
//     所以本地先拦一层，避免一次无意义的往返。
//   * 题库不足 → 400 `INSUFFICIENT_QUESTIONS`，body 带 `{available, requested}`。
//     任务书要求**内联**提示，不弹 alert，故错误挂在「题量」字段下方。
//   * `duration_limit_ms` 可空（null = 不限时），但本页总是给一个值：
//     限时模考才有意义，V3 验证也按「时间压力下做对」口径。
import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/defect_api.dart';
import '../api/mock_api.dart';
import '../config/api_config.dart';
import '../pages/mock_exam_page.dart';
import '../theme/app_theme.dart';
import '../widgets/form_field.dart';

/// 可选题量（任务书 B2 的 10/20/30/50）。
const List<int> kMockQuestionCounts = <int>[10, 20, 30, 50];

/// 默认限时（分钟）：整套 120，模块 30（任务书 B2）。
const Map<String, int> kMockDefaultMinutes = <String, int>{
  'full': 120,
  'module': 30,
};

class MockCreatePage extends StatefulWidget {
  const MockCreatePage({super.key});

  @override
  State<MockCreatePage> createState() => _MockCreatePageState();
}

class _MockCreatePageState extends State<MockCreatePage> {
  final DefectApi _defectApi = DefectApi();
  final MockExamApi _mockApi = MockExamApi();
  final TextEditingController _minutes = TextEditingController(text: '30');

  List<Map<String, Object?>> _profiles = const <Map<String, Object?>>[];
  List<Map<String, Object?>> _subjects = const <Map<String, Object?>>[];
  List<Map<String, Object?>> _nodes = const <Map<String, Object?>>[];

  String? _profileId;
  String _mode = 'module';
  String? _subjectId;
  String? _nodeId;
  int _questionCount = 10;

  bool _loadingProfiles = true;
  bool _loadingSubjects = false;
  bool _loadingNodes = false;
  bool _busy = false;

  String? _bannerError;
  String? _countError;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  @override
  void dispose() {
    _minutes.dispose();
    _defectApi.close();
    _mockApi.close();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    try {
      final List<Map<String, Object?>> profiles =
          await _defectApi.fetchExamProfiles(kDemoUserId);
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _profileId = profiles.isEmpty ? null : '${profiles.first['id']}';
        _loadingProfiles = false;
        _bannerError = null;
      });
      if (_profileId != null) await _loadSubjects(_profileId!);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingProfiles = false;
        _bannerError = e.isNetworkError
            ? '${e.message}\n请确认后端在运行，然后重试。'
            : e.message;
      });
    }
  }

  Future<void> _loadSubjects(String profileId) async {
    setState(() {
      _loadingSubjects = true;
      _subjects = const <Map<String, Object?>>[];
      _subjectId = null;
      _nodes = const <Map<String, Object?>>[];
      _nodeId = null;
    });
    try {
      final List<Map<String, Object?>> subjects =
          await _defectApi.fetchSubjects(profileId);
      if (!mounted) return;
      setState(() {
        _subjects = subjects;
        _subjectId = subjects.isEmpty ? null : '${subjects.first['id']}';
        _loadingSubjects = false;
      });
      // module 模式需要考点，先按默认科目拉一次，省用户一次点击。
      if (_mode == 'module' && _subjectId != null) {
        await _loadNodes(_subjectId!);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingSubjects = false;
        _bannerError = e.message;
      });
    }
  }

  Future<void> _loadNodes(String subjectId) async {
    setState(() {
      _loadingNodes = true;
      _nodes = const <Map<String, Object?>>[];
      _nodeId = null;
    });
    try {
      final List<Map<String, Object?>> nodes =
          await _defectApi.fetchKnowledgeNodes(subjectId);
      if (!mounted) return;
      setState(() {
        _nodes = nodes;
        _nodeId = nodes.isEmpty ? null : '${nodes.first['id']}';
        _loadingNodes = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingNodes = false;
        _bannerError = e.message;
      });
    }
  }

  void _setMode(String mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _countError = null;
      _bannerError = null;
      // 限时默认值随模式变（用户手动改过则保留不了，MVP 可接受：
      // 模式切换本来就是「换一套参数」，回到默认值比沿用 30 分钟更符合预期）
      _minutes.text = '${kMockDefaultMinutes[mode] ?? 30}';
    });
    if (mode == 'module' && _subjectId != null) {
      _loadNodes(_subjectId!);
    }
  }

  int? get _minutesValue {
    final int? v = int.tryParse(_minutes.text.trim());
    if (v == null || v <= 0 || v > 600) return null;
    return v;
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_profileId == null) {
      setState(() => _bannerError = '请先创建考试目标');
      return;
    }
    if (_mode == 'module' && _nodeId == null) {
      setState(() => _bannerError = '请选择要模考的考点');
      return;
    }
    if (_mode == 'full' && _subjectId == null) {
      setState(() => _bannerError = '请选择要模考的科目');
      return;
    }
    final int? minutes = _minutesValue;
    if (minutes == null) {
      setState(() => _bannerError = '限时需为正整数分钟（1–600）');
      return;
    }

    setState(() {
      _busy = true;
      _bannerError = null;
      _countError = null;
    });

    try {
      final MockExamCreated created = await _mockApi.createMockExam(
        examProfileId: _profileId!,
        mode: _mode,
        subjectId: _mode == 'full' ? _subjectId : null,
        knowledgeNodeId: _mode == 'module' ? _nodeId : null,
        questionCount: _questionCount,
        durationLimitMs: minutes * 60 * 1000,
      );
      if (!mounted) return;
      if (created.questions.isEmpty) {
        setState(() {
          _busy = false;
          _bannerError = '组卷成功但未返回题目，请重试';
        });
        return;
      }
      // replace：答题页返回时直接回模考列表，不再回到配置页
      Navigator.of(context).pushReplacement<void, void>(
        appRoute<void>(
          context,
          MockExamPage(exam: created.exam, questions: created.questions),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // 题库不足：内联挂在题量字段下（任务书 B3 明确不弹 alert）
        if (_isInsufficient(e)) {
          _countError = _insufficientMessage(e);
        } else {
          _bannerError = e.isNetworkError
              ? '${e.message}\n请确认后端在运行，然后重试。'
              : e.message;
        }
      });
    }
  }

  bool _isInsufficient(ApiException e) {
    final Object? body = e.body;
    return e.statusCode == 400 &&
        body is Map &&
        '${body['error']}' == 'INSUFFICIENT_QUESTIONS';
  }

  /// 把后端 `{error, available, requested}` 拼成任务书要求的那句话。
  String _insufficientMessage(ApiException e) {
    final Object? body = e.body;
    int? available;
    int? requested;
    if (body is Map) {
      final Object? a = body['available'];
      final Object? r = body['requested'];
      available = a is num ? a.toInt() : int.tryParse('$a');
      requested = r is num ? r.toInt() : int.tryParse('$r');
    }
    final String range = _mode == 'full' ? '该科目' : '该考点';
    if (available == null) {
      return '题库中$range题目不足，请减少题量或换范围';
    }
    if (available <= 0) {
      return '题库中$range还没有题目，请换范围或先导入题目';
    }
    final String tail =
        requested == null ? '' : '（本次要 $requested 题）';
    return '题库中$range仅剩 $available 题，请减少题量或换范围$tail';
  }

  @override
  Widget build(BuildContext context) {
    return FormScaffold(
      title: '开始模考',
      children: <Widget>[
        if (_bannerError != null)
          FormErrorBanner(
            message: _bannerError!,
            actionLabel: _loadingProfiles ? null : '重试',
            onAction: _loadingProfiles ? null : _loadProfiles,
          ),
        _buildProfileField(),
        FormFieldGroup(
          label: '模考模式',
          required: true,
          hint: _mode == 'full'
              ? '整套限时：按科目随机抽题，模拟整场考试的时间压力'
              : '模块模考：只考一个考点，适合刚完成 V1/V2 后自测',
          child: FormChipGroup(
            options: const <String>['module', 'full'],
            selected: _mode,
            labelOf: (String v) => v == 'full' ? '整套限时' : '模块模考',
            onChanged: _setMode,
          ),
        ),
        if (_mode == 'module') _buildNodeField() else _buildSubjectField(),
        FormFieldGroup(
          label: '题量',
          required: true,
          error: _countError,
          hint: '题量越多用时越长；题库不足时会提示可用数量',
          child: FormChipGroup(
            options: kMockQuestionCounts.map((int n) => '$n').toList(growable: false),
            selected: '$_questionCount',
            labelOf: (String v) => '$v 题',
            onChanged: (String v) {
              final int? parsed = int.tryParse(v);
              if (parsed == null) return;
              setState(() {
                _questionCount = parsed;
                _countError = null;
              });
            },
          ),
        ),
        FormFieldGroup(
          label: '限时（分钟）',
          required: true,
          hint: _mode == 'full'
              ? '整套默认 120 分钟；到点自动交卷，未答题计错'
              : '模块默认 30 分钟；到点自动交卷，未答题计错',
          child: FormTextField(
            controller: _minutes,
            placeholder: '${kMockDefaultMinutes[_mode]}',
            textInputAction: TextInputAction.done,
          ),
        ),
        FormSubmitButton(
          label: _busy ? '正在组卷…' : '开始组卷',
          busy: _busy,
          onPressed: _submit,
        ),
        const SizedBox(height: 12),
        const Text(
          '组卷会在题库中随机抽题，同一范围每次抽到的题不同。'
          '开始后计时立即生效，退出页面会丢失本次作答（MVP 不支持中断恢复）。',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 12,
            height: 1.4,
            color: AppColors.tertiaryLabel,
          ),
        ),
      ],
    );
  }

  Widget _buildProfileField() {
    if (_loadingProfiles) {
      return const FormFieldGroup(
        label: '考试目标',
        required: true,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CupertinoActivityIndicator(radius: 9),
          ),
        ),
      );
    }
    if (_profiles.isEmpty) {
      return const FormFieldGroup(
        label: '考试目标',
        required: true,
        child: FormEmptyHint(text: '还没有考试目标，请先在首页创建'),
      );
    }
    return FormFieldGroup(
      label: '考试目标',
      required: true,
      hint: _profiles.length == 1 ? '当前只有一个考试目标' : '选择本次模考归属的考试目标',
      child: FormChipGroup(
        options: _profiles.map((Map<String, Object?> p) => '${p['id']}').toList(growable: false),
        selected: _profileId,
        labelOf: (String id) {
          final int idx = _profiles.indexWhere(
            (Map<String, Object?> p) => '${p['id']}' == id,
          );
          if (idx < 0) return id;
          final Object? label = _profiles[idx]['target_label'];
          return label is String && label.isNotEmpty ? label : '考试目标 ${idx + 1}';
        },
        onChanged: (String id) {
          if (id == _profileId) return;
          setState(() => _profileId = id);
          _loadSubjects(id);
        },
      ),
    );
  }

  Widget _buildSubjectField() {
    if (_loadingSubjects) {
      return const FormFieldGroup(
        label: '科目',
        required: true,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CupertinoActivityIndicator(radius: 9),
          ),
        ),
      );
    }
    if (_subjects.isEmpty) {
      return const FormFieldGroup(
        label: '科目',
        required: true,
        child: FormEmptyHint(text: '该考试目标下没有科目'),
      );
    }
    return FormFieldGroup(
      label: '科目',
      required: true,
      hint: '整套限时按科目抽题',
      child: FormChipGroup(
        options: _subjects.map((Map<String, Object?> s) => '${s['id']}').toList(growable: false),
        selected: _subjectId,
        labelOf: (String id) {
          final int idx = _subjects.indexWhere(
            (Map<String, Object?> s) => '${s['id']}' == id,
          );
          if (idx < 0) return id;
          return '${_subjects[idx]['name'] ?? '科目'}';
        },
        onChanged: (String id) => setState(() => _subjectId = id),
      ),
    );
  }

  Widget _buildNodeField() {
    if (_loadingNodes || _loadingSubjects) {
      return const FormFieldGroup(
        label: '考点',
        required: true,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CupertinoActivityIndicator(radius: 9),
          ),
        ),
      );
    }
    if (_nodes.isEmpty) {
      return const FormFieldGroup(
        label: '考点',
        required: true,
        child: FormEmptyHint(text: '该科目下暂无可选考点'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FormFieldGroup(
          label: '科目',
          hint: '先选科目，再选该科目下的考点',
          child: _subjects.isEmpty
              ? const FormEmptyHint(text: '该考试目标下没有科目')
              : FormChipGroup(
                  options: _subjects
                      .map((Map<String, Object?> s) => '${s['id']}')
                      .toList(growable: false),
                  selected: _subjectId,
                  labelOf: (String id) {
                    final int idx = _subjects.indexWhere(
                      (Map<String, Object?> s) => '${s['id']}' == id,
                    );
                    if (idx < 0) return id;
                    return '${_subjects[idx]['name'] ?? '科目'}';
                  },
                  onChanged: (String id) {
                    if (id == _subjectId) return;
                    setState(() => _subjectId = id);
                    _loadNodes(id);
                  },
                ),
        ),
        FormFieldGroup(
          label: '考点',
          required: true,
          hint: '模块模考只考这一个考点',
          child: FormChipGroup(
            options:
                _nodes.map((Map<String, Object?> n) => '${n['id']}').toList(growable: false),
            selected: _nodeId,
            labelOf: (String id) {
              final int idx = _nodes.indexWhere(
                (Map<String, Object?> n) => '${n['id']}' == id,
              );
              if (idx < 0) return id;
              return '${_nodes[idx]['title'] ?? '考点'}';
            },
            onChanged: (String id) => setState(() {
              _nodeId = id;
              _countError = null;
            }),
          ),
        ),
      ],
    );
  }
}
