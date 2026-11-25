// 手动建题 / 编辑题目页（m23700 FE-02）。
//
// ── 为什么建题与编辑共用一页 ────────────────────────────────────────────
// 两边的字段完全一样（题型 / 题干 / 选项 / 答案 / 解析 / 难度 / 标签 / 科目 / 考点），
// 只有「提交时是 POST 还是 PATCH」不同。拆成两页会让同一套表单维护两遍，
// 迟早出现「建题页能填的字段编辑页不能填」的漂移。
//
// ── 为什么选项要单独编辑而不是塞进一个 TextField ────────────────────────
// 后端 `questions.options` 是 jsonb，形状统一为 `[{key, text}]`（m23700 后端
// `normalizeOptions` 做的归一）。如果前端发 `['A. xxx']` 这样的字符串数组，
// 同一道题从「导入」和「手动录入」进去形状会不一样，答案解析要写两套。
// 所以这里让用户按「A / B / C」逐条填，key 由前端给出，不让用户操心。
//
// ── 乐观锁 ────────────────────────────────────────────────────────────
// 编辑与删除都要带 `version`。别人改过这题就会 409 conflict，
// 这时提示「题已被修改」并让用户重新载入，而不是静默覆盖别人的改动。

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
import '../api/defect_api.dart';
import '../api/question_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/form_field.dart';

/// 可选题型（与后端 `QUESTION_TYPES` 同口径）。
const List<String> kQuestionTypeOptions = <String>[
  'choice',
  'multi',
  'judge',
  'fill',
  'calculation',
  'short_answer',
  'subjective',
  'essay',
  'material',
];

/// 题型中文名。
const Map<String, String> kQuestionTypeLabels = <String, String>{
  'choice': '单选题',
  'multi': '多选题',
  'judge': '判断题',
  'fill': '填空题',
  'calculation': '计算题',
  'short_answer': '简答题',
  'subjective': '主观题',
  'essay': '论述题',
  'material': '材料题',
};

/// 可选难度（与后端 `DIFFICULTIES` 同口径）。
const List<String> kQuestionDifficultyOptions = <String>['easy', 'medium', 'hard'];

/// 难度中文名。
const Map<String, String> kQuestionDifficultyLabels = <String, String>{
  'easy': '简单',
  'medium': '中等',
  'hard': '困难',
};

/// 需要选项的题型（其余题型不显示选项编辑区）。
const Set<String> kTypesWithOptions = <String>{
  'choice',
  'multi',
  'judge',
  'calculation',
};

class QuestionEditPage extends StatefulWidget {
  const QuestionEditPage({super.key, this.existing});

  /// 传 null = 手动建题；传一道题 = 编辑它。
  final QuestionDetail? existing;

  @override
  State<QuestionEditPage> createState() => _QuestionEditPageState();
}

class _QuestionEditPageState extends State<QuestionEditPage> {
  final QuestionApi _api = QuestionApi();
  final DefectApi _defectApi = DefectApi();

  final TextEditingController _stem = TextEditingController();
  final TextEditingController _answer = TextEditingController();
  final TextEditingController _analysis = TextEditingController();
  final TextEditingController _formula = TextEditingController();
  final TextEditingController _tags = TextEditingController();

  /// 选项编辑器（key + text 两组 controller）。
  List<_OptionDraft> _options = <_OptionDraft>[];

  String _type = 'choice';
  String _difficulty = '';
  bool _isSubjective = false;

  String _subjectId = '';
  String _knowledgeNodeId = '';

  List<Map<String, Object?>> _profiles = const <Map<String, Object?>>[];
  List<Map<String, Object?>> _nodes = const <Map<String, Object?>>[];

  bool _loading = true;
  bool _busy = false;
  String? _bannerError;
  final Map<String, String> _errors = <String, String>{};

  /// 编辑模式的原始 version（乐观锁基准）。
  int _version = 1;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final QuestionDetail? existing = widget.existing;
    if (existing != null) {
      _version = existing.version;
      _type = existing.type.isEmpty ? 'choice' : existing.type;
      _difficulty = existing.difficulty;
      _isSubjective = existing.looksSubjective;
      _subjectId = existing.subjectId;
      _knowledgeNodeId = existing.knowledgeNodeId;
      _stem.text = existing.stem;
      _answer.text = existing.answer;
      _analysis.text = existing.analysis;
      _formula.text = existing.formulaText;
      _tags.text = existing.tags.join('、');
      _options = existing.options
          .map((QuestionOption o) => _OptionDraft(key: o.key, text: o.text))
          .toList();
    }
    _load();
  }

  @override
  void dispose() {
    _stem.dispose();
    _answer.dispose();
    _analysis.dispose();
    _formula.dispose();
    _tags.dispose();
    for (final _OptionDraft o in _options) {
      o.dispose();
    }
    _api.close();
    _defectApi.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final List<Map<String, Object?>> profiles = await _defectApi
          .fetchExamProfiles(kDemoUserId);
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _bannerError = '科目列表加载失败：$e';
      });
    }
  }


  Future<void> _pickSubject(String subjectId) async {
    setState(() {
      _subjectId = subjectId;
      _knowledgeNodeId = '';
      _nodes = const <Map<String, Object?>>[];
    });
    if (subjectId.isEmpty) return;
    try {
      final List<Map<String, Object?>> nodes = await _defectApi
          .fetchKnowledgeNodes(subjectId);
      if (!mounted) return;
      setState(() => _nodes = nodes);
    } catch (_) {
      // 考点拉不到不影响建题。
    }
  }

  void _addOption() {
    final String key = String.fromCharCode(65 + _options.length);
    setState(() => _options = <_OptionDraft>[..._options, _OptionDraft(key: key)]);
  }

  void _removeOption(int index) {
    final List<_OptionDraft> next = List<_OptionDraft>.from(_options);
    next.removeAt(index).dispose();
    setState(() => _options = next);
  }

  /// 组装要发给后端的选项（跳过空行；key 由前端给出）。
  List<Map<String, String>> _buildOptions() {
    final List<Map<String, String>> out = <Map<String, String>>[];
    for (final _OptionDraft o in _options) {
      final String text = o.text.text.trim();
      if (text.isEmpty) continue;
      out.add(<String, String>{'key': o.key, 'text': text});
    }
    return out;
  }

  /// 组装标签（顿号 / 逗号 / 空格分隔）。
  List<String> _buildTags() {
    return _tags.text
        .split(RegExp(r'[、,，\s]+'))
        .map((String t) => t.trim())
        .where((String t) => t.isNotEmpty)
        .toList(growable: false);
  }

  bool _validate() {
    final Map<String, String> errors = <String, String>{};
    if (_stem.text.trim().isEmpty) {
      errors['stem'] = '题干不能为空';
    }
    if (kTypesWithOptions.contains(_type) && _buildOptions().length < 2) {
      errors['options'] = '选择题至少要有两个选项';
    }
    setState(() => _errors..clear()..addAll(errors));
    return errors.isEmpty;
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_validate()) return;

    setState(() {
      _busy = true;
      _bannerError = null;
    });

    try {
      final List<Map<String, String>> options = _buildOptions();
      final List<String> tags = _buildTags();

      if (_isEditing) {
        await _api.updateQuestion(
          id: widget.existing!.id,
          version: _version,
          type: _type,
          stem: _stem.text.trim(),
          subjectId: _subjectId,
          knowledgeNodeId: _knowledgeNodeId,
          options: options,
          answer: _answer.text.trim(),
          analysis: _analysis.text.trim(),
          formulaText: _formula.text.trim(),
          difficulty: _difficulty,
          tags: tags,
          isSubjective: _isSubjective,
        );
      } else {
        await _api.createQuestion(
          type: _type,
          stem: _stem.text.trim(),
          subjectId: _subjectId,
          knowledgeNodeId: _knowledgeNodeId,
          options: options,
          answer: _answer.text.trim(),
          analysis: _analysis.text.trim(),
          formulaText: _formula.text.trim(),
          difficulty: _difficulty,
          tags: tags,
          isSubjective: _isSubjective,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _applyError(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _bannerError = '保存失败：$e';
      });
    }
  }

  /// 把后端错误映射到字段（能定位就内联红字，定位不了就顶部条）。
  void _applyError(ApiException e) {
    final String code = e.body is Map
        ? '${(e.body! as Map)['error'] ?? ''}'
        : '';
    final String message = e.body is Map
        ? '${(e.body! as Map)['message'] ?? e.message}'
        : e.message;

    switch (code) {
      case 'MISSING_QUESTION_STEM':
        _errors['stem'] = '题干不能为空';
        return;
      case 'INVALID_QUESTION_TYPE':
        _errors['type'] = '题型不受支持，请重新选择';
        return;
      case 'INVALID_DIFFICULTY':
        _errors['difficulty'] = '难度取值不合法';
        return;
      case 'INVALID_OPTIONS':
        _errors['options'] = '选项格式不合法';
        return;
      case 'DUPLICATE_QUESTION':
        _errors['stem'] = '题库里已有同样的题干（同一科目下不重复建题）';
        return;
      case 'INVALID_BASE_VERSION':
        _bannerError = '缺少版本号，请重新打开这一页再试';
        return;
      case 'conflict':
        _bannerError = '这道题在你编辑期间被改过（版本冲突）。'
            '请关闭本页重新打开，以免覆盖别人的修改。';
        return;
      case 'unauthorized':
        _bannerError = '登录状态已失效，请到「我的 → 设置」重新填 Token';
        return;
      default:
        _bannerError = message;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FormScaffold(
      title: _isEditing ? '编辑题目' : '手动建题',
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        onPressed: _busy ? null : _submit,
        child: Text(
          '保存',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: _busy ? AppColors.tertiaryLabel : AppColors.accent,
          ),
        ),
      ),
      children: <Widget>[
        if (_bannerError != null)
          FormErrorBanner(message: _bannerError!, actionLabel: '重试', onAction: _submit),
        FormFieldGroup(
          label: '题型',
          required: true,
          error: _errors['type'],
          hint: '决定后面要不要填选项',
          child: FormChipGroup(
            options: kQuestionTypeOptions,
            selected: _type,
            labelOf: (String v) => kQuestionTypeLabels[v] ?? v,
            onChanged: (String v) => setState(() {
              _type = v;
              _errors.remove('type');
              // 主观题类不需要选项，切过去时清掉已有选项，避免留下无意义的行。
              if (!kTypesWithOptions.contains(v) && _options.isNotEmpty) {
                for (final _OptionDraft o in _options) {
                  o.dispose();
                }
                _options = <_OptionDraft>[];
              }
            }),
          ),
        ),
        FormFieldGroup(
          label: '题干',
          required: true,
          error: _errors['stem'],
          hint: '写清题目问什么。同一科目下题干相同会被判重，不会重复建题。',
          child: FormTextField(
            controller: _stem,
            placeholder: '如：某市 2023 年 GDP 同比增长 5.2%，则 2022 年 GDP 约为多少？',
            maxLines: 6,
            hasError: _errors.containsKey('stem'),
            onChanged: (_) {
              if (_errors.containsKey('stem')) {
                setState(() => _errors.remove('stem'));
              }
            },
          ),
        ),
        if (kTypesWithOptions.contains(_type))
          FormFieldGroup(
            label: '选项',
            required: true,
            error: _errors['options'],
            hint: '至少两条；标号（A/B/C…）由系统给出',
            child: _buildOptionsEditor(),
          ),
        FormFieldGroup(
          label: '答案',
          hint: '选择题填标号（如 B）；主观题填要点',
          child: FormTextField(
            controller: _answer,
            placeholder: '如：B',
            hasError: _errors.containsKey('answer'),
            onChanged: (_) {
              if (_errors.containsKey('answer')) {
                setState(() => _errors.remove('answer'));
              }
            },
          ),
        ),
        FormFieldGroup(
          label: '解析',
          hint: '讲清怎么算出来的，这段会在刷题时给用户看',
          child: FormTextField(
            controller: _analysis,
            placeholder: '如：先用 2023 年 GDP ÷ 1.052 反推 2022 年',
            maxLines: 4,
          ),
        ),
        FormFieldGroup(
          label: '公式（可选）',
          hint: r'LaTeX 文本，如 $\frac{a}{b}$',
          child: FormTextField(controller: _formula, placeholder: r'$\frac{a}{b}$'),
        ),
        FormFieldGroup(
          label: '难度',
          error: _errors['difficulty'],
          hint: '不选就是「未标难度」',
          child: FormChipGroup(
            options: kQuestionDifficultyOptions,
            selected: _difficulty.isEmpty ? null : _difficulty,
            labelOf: (String v) => kQuestionDifficultyLabels[v] ?? v,
            onChanged: (String v) => setState(() {
              _difficulty = _difficulty == v ? '' : v;
              _errors.remove('difficulty');
            }),
          ),
        ),
        FormFieldGroup(
          label: '标签（可选）',
          hint: '用顿号或逗号分隔，如「资料分析、比重」',
          child: FormTextField(controller: _tags, placeholder: '资料分析、比重'),
        ),
        FormFieldGroup(
          label: '主观题',
          hint: '打开后按「要人工判分」处理（刷题时不自动判对错）',
          child: Row(
            children: <Widget>[
              Text(
                _isSubjective ? '是' : '否',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 15,
                  color: AppColors.label,
                ),
              ),
              const Spacer(),
              CupertinoSwitch(
                value: _isSubjective,
                activeTrackColor: AppColors.accent,
                onChanged: (bool v) => setState(() => _isSubjective = v),
              ),
            ],
          ),
        ),
        FormFieldGroup(
          label: '所属科目（可选）',
          hint: _loading
              ? '正在加载科目…'
              : (_profiles.isEmpty
                    ? '还没有考试档案，请先在「我的 → 考试配置」里添加'
                    : '不选也能建题；选了才方便按科目抽题'),
          child: _loading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CupertinoActivityIndicator(radius: 9),
                  ),
                )
              : _buildSubjectPicker(),
        ),
        if (_nodes.isNotEmpty)
          FormFieldGroup(
            label: '关联考点（可选）',
            hint: '不选也能建题',
            child: _buildNodeChips(),
          ),
        const SizedBox(height: 8),
        FormSubmitButton(
          label: _isEditing ? '保存修改' : '创建题目',
          busy: _busy,
          onPressed: _submit,
        ),
      ],
    );
  }

  /// 选项编辑区（可增删的行）。
  Widget _buildOptionsEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < _options.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 28,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _options[i].key,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.secondaryLabel,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: FormTextField(
                    controller: _options[i].text,
                    placeholder: '选项内容',
                  ),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.only(left: 8, top: 8),
                  minimumSize: Size.zero,
                  onPressed: () => _removeOption(i),
                  child: const Icon(
                    CupertinoIcons.minus_circle,
                    size: 20,
                    color: AppColors.overdue,
                  ),
                ),
              ],
            ),
          ),
        CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          onPressed: _addOption,
          child: const Text(
            '添加选项',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 14,
              color: AppColors.accent,
            ),
          ),
        ),
      ],
    );
  }

  /// 科目选择（按考试档案分组）。
  Widget _buildSubjectPicker() {
    if (_profiles.isEmpty) {
      return const FormEmptyHint(text: '暂无可选科目');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final Map<String, Object?> profile in _profiles) ...<Widget>[
          Text(
            '${profile['target_label'] ?? profile['label'] ?? '考试档案'}',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 6),
          FutureBuilder<List<Map<String, Object?>>>(
            future: _subjectsOf('${profile['id'] ?? ''}'),
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<List<Map<String, Object?>>> snapshot,
                ) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(6),
                      child: CupertinoActivityIndicator(radius: 8),
                    );
                  }
                  final List<Map<String, Object?>> subjects =
                      snapshot.data ?? const <Map<String, Object?>>[];
                  if (subjects.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(6),
                      child: Text(
                        '（该档案下没有科目）',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 12,
                          color: AppColors.tertiaryLabel,
                        ),
                      ),
                    );
                  }
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final Map<String, Object?> s in subjects)
                        _MiniChip(
                          label: '${s['name'] ?? s['title'] ?? ''}',
                          selected: '${s['id'] ?? ''}' == _subjectId,
                          onTap: () => _pickSubject('${s['id'] ?? ''}'),
                        ),
                    ],
                  );
                },
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  /// 科目缓存（同一档案只拉一次）。
  static final Map<String, List<Map<String, Object?>>> _subjectCache =
      <String, List<Map<String, Object?>>>{};

  Future<List<Map<String, Object?>>> _subjectsOf(String profileId) async {
    if (profileId.isEmpty) return const <Map<String, Object?>>[];
    final List<Map<String, Object?>>? cached = _subjectCache[profileId];
    if (cached != null) return cached;
    try {
      final List<Map<String, Object?>> list = await _defectApi.fetchSubjects(
        profileId,
      );
      _subjectCache[profileId] = list;
      return list;
    } catch (_) {
      return const <Map<String, Object?>>[];
    }
  }

  Widget _buildNodeChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        _MiniChip(
          label: '不指定考点',
          selected: _knowledgeNodeId.isEmpty,
          onTap: () => setState(() => _knowledgeNodeId = ''),
        ),
        for (final Map<String, Object?> n in _nodes)
          _MiniChip(
            label: '${n['title'] ?? ''}',
            selected: '${n['id'] ?? ''}' == _knowledgeNodeId,
            onTap: () => setState(() => _knowledgeNodeId = '${n['id'] ?? ''}'),
          ),
      ],
    );
  }
}

/// 一个选项草稿（标号 + 内容）。
class _OptionDraft {
  _OptionDraft({required this.key, String text = ''})
    : text = TextEditingController(text: text);

  final String key;
  final TextEditingController text;

  void dispose() => text.dispose();
}

/// 小圆角 chip（科目 / 考点选择用）。
class _MiniChip extends StatelessWidget {
  const _MiniChip({
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
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.card,
          borderRadius: BorderRadius.circular(AppRadii.chip),
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
            color: selected ? CupertinoColors.white : AppColors.label,
          ),
        ),
      ),
    );
  }
}
