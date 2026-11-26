// 建单页（FE-03 写操作联调 · 任务 B）。
//
// 对应后端 `POST /defect-tickets`（字段见 server/routes/defect_tickets.mjs:82）。
// 一次提交，不做草稿保存（任务书 B5）：失败时保留全部已填内容供重试。
//
// 校验分两层：
//   1. 前端内联预校验（必填 + 禁用语）—— 立即给红字，不往返；
//   2. 后端返回的字段级错误 —— 也映射到同一个 `_errors` 表，用同样的 UI 呈现。
//      后端错误体形如 `{error:'missing_error_layer_or_cause'}` 或
//      `{error:'forbidden_phrase'}`（httpError 第三分支只带 code，
//      所以这里按 code 反推字段，而不是依赖后端给字段名）。

import 'package:flutter/cupertino.dart';

import '../../api/api_client.dart';
import '../../api/defect_api.dart';
// 题型下拉的选项来源（GET /question-types）与中文标签口径。
import '../../api/question_api.dart';
import '../../config/api_config.dart';
import '../../logging/app_logger.dart';
// 只取写队列相关符号：`local.dart` 也导出 `findForbiddenPhrases`，
// 与 `defect_api.dart` 的同名函数冲突，故用 show 收窄。
import '../../local/local.dart'
    show
        kLocalDataRevision,
        kLocalDbReady,
        kLocalFirstEnabled,
        loadKnowledgeNodes,
        LocalValidationException,
        PushScheduler,
        WriteQueue,
        WriteQueueResult;
import '../../theme/app_theme.dart';
import '../../widgets/form_field.dart';
// 题型空态里的「去题库导入题目」入口。
import 'question_manage_page.dart';

class DefectCreatePage extends StatefulWidget {
  const DefectCreatePage({
    super.key,
    required this.examProfileId,
    required this.subjectId,
    required this.subjectName,
    this.initialQuestionId,
    this.initialErrorCause,
    this.initialQType,
  });

  /// 建单必填：后端 `defect_tickets.exam_profile_id` 是 NOT NULL 外键。
  final String examProfileId;

  /// 建单页从「当前科目」加载考点列表，避免一次性拉全库考点。
  final String subjectId;
  final String subjectName;

  /// 练习模式 R1：从练习结果页「去归因」进来时预填的题目 id。
  ///
  /// 后端 `POST /defect-tickets` 接受 `question_id`，所以这里直接带上，
  /// 用户不用再回题库挑一次题 —— 练习与缺陷单的闭环就靠这一条。
  final String? initialQuestionId;

  /// 预填的具体错因（练习场景默认「练习中未掌握」）。
  final String? initialErrorCause;

  /// 预填的题型 / 考点摘要（练习场景用题干前若干字）。
  final String? initialQType;

  @override
  State<DefectCreatePage> createState() => _DefectCreatePageState();
}

class _DefectCreatePageState extends State<DefectCreatePage> {
  final DefectApi _api = DefectApi();

  final TextEditingController _qType = TextEditingController();
  final TextEditingController _errorCause = TextEditingController();
  final List<TextEditingController> _actionControllers =
      <TextEditingController>[TextEditingController()];

  String? _errorLayer;
  String _priority = 'P1';
  String? _knowledgeNodeId;

  /// 字段级错误：key 与 `FormFieldGroup` 一一对应。
  final Map<String, String> _errors = <String, String>{};

  /// 顶部条错误（网络失败 / 无法归因到字段的后端错误）。
  String? _bannerError;

  bool _busy = false;
  bool _loadingNodes = true;
  List<Map<String, Object?>> _nodes = const <Map<String, Object?>>[];

  // ── 题型下拉（任务 C2）───────────────────────────────────────────────
  /// 题型下拉的选项来源：`GET /question-types?scope=imported`
  /// （只统计**用户自己导入**的题的题型）。
  List<QuestionTypeCount> _questionTypes = const <QuestionTypeCount>[];
  bool _loadingTypes = true;
  String? _typesError;

  /// 已选中的题型**原始值**（后端存的就是它，例如 `choice`）。
  String? _qTypeValue;

  /// 降级为「手动输入题型」。
  ///
  /// 降级理由：题型选项来自已导入的题目，题库里一题都没有时下拉是空的；
  /// 而建单是用户随时要做的动作，不能因为题库为空就把它卡死 ——
  /// 所以空态里同时给出「去题库导入题目」和「手动输入」两条路。
  bool _qTypeManual = false;

  // ── 自定义错因（任务 C3）─────────────────────────────────────────────
  /// 自定义错因文本（≤30 字），提交时进 `custom_reason` 字段。
  final TextEditingController _customReason = TextEditingController();

  /// 历史自定义错因（可复用），来自 `GET /defect-tickets/custom-reasons`。
  List<String> _customReasons = const <String>[];

  @override
  void initState() {
    super.initState();
    // 练习模式 R1：带参进来时预填题干摘要与错因，用户不用重写。
    if (widget.initialQType != null && widget.initialQType!.isNotEmpty) {
      _qType.text = widget.initialQType!;
    }
    if (widget.initialErrorCause != null &&
        widget.initialErrorCause!.isNotEmpty) {
      _errorCause.text = widget.initialErrorCause!;
    }
    _loadNodes();
    _loadQuestionTypes();
    _loadCustomReasons();
  }

  @override
  void dispose() {
    _qType.dispose();
    _customReason.dispose();
    _errorCause.dispose();
    for (final TextEditingController c in _actionControllers) {
      c.dispose();
    }
    _api.close();
    super.dispose();
  }

  Future<void> _loadNodes() async {
    if (kUseMock) {
      setState(() => _loadingNodes = false);
      return;
    }
    // R4a：本地优先时先读本地目录，离线也能建单（考点列表不是写操作的前置
    // 校验，选不到考点时后端 `knowledge_node_id` 本来就是可空的）。
    if (kLocalFirstEnabled) {
      try {
        final List<Map<String, Object?>> local =
            await loadKnowledgeNodes(widget.subjectId);
        if (local.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _nodes = local;
            _loadingNodes = false;
          });
          return;
        }
      } catch (e) {
        debugPrint('[create] 本地考点读取失败：$e');
      }
    }
    try {
      final nodes = await _api.fetchKnowledgeNodes(widget.subjectId);
      if (!mounted) return;
      final bool offline = !kLocalFirstEnabled;
      setState(() {
        _nodes = nodes;
        _loadingNodes = false;
        // 本地优先时拉不到考点不算致命错误：考点是可选项，允许不选直接提交。
        if (offline) _bannerError = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingNodes = false;
        if (!kLocalFirstEnabled) {
          _bannerError = '考点列表加载失败：${e.message}';
        }
      });
    }
  }

  // ── 题型下拉（任务 C2）───────────────────────────────────────────────

  /// 拉取题型选项：`GET /question-types?scope=imported`。
  ///
  /// 拉不到**不阻塞建单**：题型仍然可以在下拉里选（或手动输入），
  /// 拉取失败只提示一句并保留手动输入入口。
  Future<void> _loadQuestionTypes() async {
    if (kUseMock) {
      if (!mounted) return;
      setState(() => _loadingTypes = false);
      return;
    }
    try {
      final List<QuestionTypeCount> types =
          await _api.fetchQuestionTypes(scope: 'imported');
      if (!mounted) return;
      setState(() {
        _questionTypes = types;
        _loadingTypes = false;
        _typesError = null;
      });
      _matchPrefilledQuestionType();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingTypes = false;
        _typesError = e.message;
      });
    }
  }

  /// 练习模式带进来的题型摘要：如果正好是某个已知题型（原始值或中文名），
  /// 就自动切成下拉选中态；否则保持原样（当作自由文本摘要）。
  void _matchPrefilledQuestionType() {
    final String text = _qType.text.trim();
    if (text.isEmpty) return;
    for (final QuestionTypeCount t in _questionTypes) {
      if (t.type == text || questionTypeLabel(t.type) == text) {
        setState(() {
          _qTypeValue = t.type;
          _qType.text = t.type;
        });
        return;
      }
    }
    // 对不上已知题型（练习模式带进来的是题干摘要）→ 当成自由文本处理，
    // 切到「手动输入」模式，否则用户会被迫改写自己已有的摘要。
    setState(() => _qTypeManual = true);
  }

  /// 打开题型选择弹层。
  ///
  /// 两情形：
  ///   · 有题型选项 → 可搜索的选择面板（顶部 `CupertinoSearchTextField`）；
  ///   · 一个题型都没有 → 空态面板（「去题库导入题目」/「手动输入」）。
  Future<void> _openQuestionTypePicker() async {
    if (_questionTypes.isEmpty) {
      await _showQuestionTypeEmptySheet();
      return;
    }
    final String? picked = await showCupertinoModalPopup<String>(
      context: context,
      builder: (BuildContext ctx) => _QuestionTypeSheet(
        options: _questionTypes,
        selected: _qTypeValue,
        onManual: () {
          Navigator.of(ctx).pop();
          setState(() => _qTypeManual = true);
        },
      ),
    );
    if (picked == null || picked.isEmpty) return;
    setState(() {
      _qTypeValue = picked;
      _qType.text = picked;
      _errors.remove('qType');
    });
  }

  /// 空态面板：题库里还没有题型可选项。
  ///
  /// 降级理由：题型选项来自已导入的题目，题库为空时确实无从下拉；
  /// 但建单是用户随时要做的动作，不能因此卡死 —— 这里给「去题库导入题目」
  /// 与「手动输入题型」两条路。
  Future<void> _showQuestionTypeEmptySheet() async {
    final String? action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (BuildContext ctx) => CupertinoActionSheet(
        title: const Text(
          '还没有可选题型',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 15,
            color: AppColors.label,
          ),
        ),
        message: const Text(
          '题型下拉只列出已导入题目里出现过的题型。先去题库导入题目，'
          '这里就会出现可选项；也可以直接手动输入题型。',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            color: AppColors.secondaryLabel,
          ),
        ),
        actions: <Widget>[
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop('manage'),
            child: const Text(
              '去题库导入题目',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 16,
                color: AppColors.accent,
              ),
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(ctx).pop('manual'),
            child: const Text(
              '手动输入题型',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 16,
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
              fontSize: 16,
              color: AppColors.secondaryLabel,
            ),
          ),
        ),
      ),
    );
    if (action == 'manual') {
      setState(() => _qTypeManual = true);
      return;
    }
    if (action == 'manage') {
      if (!mounted) return;
      await Navigator.of(context).push(
        appRoute<void>(context, const QuestionManagePage()),
      );
    }
  }

  // ── 自定义错因（任务 C3）─────────────────────────────────────────────

  /// 拉历史自定义错因（可复用）：`GET /defect-tickets/custom-reasons`。
  ///
  /// 拉不到就当没有历史，不影响建单。
  Future<void> _loadCustomReasons() async {
    if (kUseMock) return;
    try {
      final List<String> reasons = await _api.fetchCustomReasons(
        examProfileId: widget.examProfileId,
      );
      if (!mounted) return;
      setState(() => _customReasons = reasons.take(5).toList(growable: false));
    } on ApiException catch (e) {
      debugPrint('[create] 历史自定义错因读取失败：${e.message}');
    }
  }

  /// 提交时真正发给后端的 `error_layer`。
  ///
  /// 约定：「自定义」只是 UI 层的哨兵值（[kCustomErrorLayerValue]），
  /// 后端 `error_layer` 仍要落在行测六层枚举里，所以选自定义时传
  /// [kPracticeDefaultErrorLayer]（识别），用户写的文本走 `custom_reason`。
  String? get _submitErrorLayer {
    if (_errorLayer == kCustomErrorLayerValue) return kPracticeDefaultErrorLayer;
    return _errorLayer;
  }

  /// 提交时真正发给后端的 `custom_reason`（空则不带该字段）。
  String? get _submitCustomReason {
    if (_errorLayer != kCustomErrorLayerValue) return null;
    final String text = _customReason.text.trim();
    if (text.isEmpty) return null;
    return text;
  }
  /// 提交时真正发给后端的 `q_type`。
  ///
  /// 下拉模式提交**原始值**（如 `choice`，后端存的就是它）；手动输入模式
  /// 提交用户输入的文本。
  String get _submitQType {
    if (!_qTypeManual && _qTypeValue != null && _qTypeValue!.isNotEmpty) {
      return _qTypeValue!;
    }
    return _qType.text.trim();
  }


  /// 前端预校验。返回 true 表示可以提交。
  bool _validate() {
    final Map<String, String> errors = <String, String>{};

    // 题型：下拉模式看选中的原始值；手动输入模式看输入框内容。
    if (_qTypeManual) {
      if (_qType.text.trim().isEmpty) {
        errors['qType'] = '请填写题型或考点摘要';
      }
    } else if (_qTypeValue == null || _qTypeValue!.isEmpty) {
      errors['qType'] = '请选择题型';
    }
    if (_errorLayer == null) {
      errors['errorLayer'] = '请选择错因层级';
    }
    final String cause = _errorCause.text.trim();
    if (cause.isEmpty) {
      errors['errorCause'] = '请填写具体错因';
    } else {
      // 禁用语在本地先拦一次：省一次往返，文案也更贴近输入位置。
      // 后端仍是最终权威（core/index.mjs 的 assertNoForbiddenPhrase）。
      final List<String> hits = findForbiddenPhrases(cause);
      if (hits.isNotEmpty) {
        errors['errorCause'] =
            '请写出具体哪一步算错或记错，不要写「${hits.first}」这类词';
      }
    }

    // 自定义错因：选「自定义」时必填且 ≤30 字（后端 400 INVALID_CUSTOM_REASON）。
    if (_errorLayer == kCustomErrorLayerValue) {
      final String custom = _customReason.text.trim();
      if (custom.isEmpty) {
        errors['customReason'] = '请填写自定义错因';
      } else if (custom.length > 30) {
        errors['customReason'] = '自定义错因最多 30 字（当前 ${custom.length} 字）';
      }
    }
    setState(() {
      _errors
        ..clear()
        ..addAll(errors);
      _bannerError = null;
    });
    return errors.isEmpty;
  }

  /// 把后端错误码映射回字段（httpError 只带 code，不带字段名）。
  void _applyBackendError(ApiException e) {
    final Object? body = e.body;
    final String code =
        body is Map && body['error'] != null ? '${body['error']}' : '';

    switch (code) {
      case 'forbidden_phrase':
      case 'FORBIDDEN_PHRASE_IN_ERROR_CAUSE':
        setState(() {
          _errors['errorCause'] =
              '请写出具体哪一步算错或记错，不要写粗心 / 没掌握 / 大意这类词';
        });
        return;
      case 'missing_error_layer_or_cause':
      case 'MISSING_ERROR_LAYER':
      case 'MISSING_ERROR_CAUSE':
        setState(() {
          if (_errorLayer == null) _errors['errorLayer'] = '请选择错因层级';
          if (_errorCause.text.trim().isEmpty) {
            _errors['errorCause'] = '请填写具体错因';
          }
        });
        return;
      case 'MISSING_QUESTION_TYPE':
        setState(() {
          _errors['qType'] = '请选择题型';
        });
        return;
      case 'INVALID_CUSTOM_REASON':
        setState(() {
          _errors['customReason'] = '自定义错因不合法（最多 30 字）';
        });
        return;
      case 'ILLEGAL_DEFECT_TRANSITION':
        setState(() => _bannerError = '当前状态不允许该操作，请返回列表刷新后重试');
        return;
      default:
        break;
    }

    if (e.isNetworkError) {
      setState(() => _bannerError = '${e.message}\n请确认后端在运行，然后重试。');
    } else {
      setState(() => _bannerError = e.message);
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_validate()) return;

    setState(() => _busy = true);

    // 空行忽略：用户点了「添加动作」却没填内容，不应该阻塞提交。
    final List<String> actions = _actionControllers
        .map((TextEditingController c) => c.text.trim())
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);

    try {
      // R4b：写路径判据改为 `kLocalDbReady`（本地库能不能用）。
      // 原来用 `kLocalFirstEnabled`，本地库初始化失败时会连写操作一起关掉，
      // 静默退回直连云端——用户看到「提交成功」但请求其实打到了云端。
      if (kLocalDbReady) {
        // 本地优先（R4a）：写本地库 + 入队，用户立刻看到新单；推送由后台完成。
        // 校验已在 WriteQueue 内部跑过一遍状态机，非法操作在这里抛出，不会落库。
        final WriteQueueResult queued = await WriteQueue.enqueueCreateDefect(
          userId: kDemoUserId,
          examProfileId: widget.examProfileId,
          qType: _submitQType,
          errorCause: _errorCause.text.trim(),
          errorLayer: _submitErrorLayer,
          // C3：自定义错因必须随入队 payload 一起上行，否则云端拿不到。
          customReason: _submitCustomReason,
          knowledgeNodeId: _knowledgeNodeId,
          priority: _priority,
          questionId: widget.initialQuestionId,
          actions: actions,
        );
        AppLogger.instance.info(
          'QUEUE',
          '入队 createDefect op_id=${queued.opId}'
          '（本地 status=${queued.status}）',
        );
        if (!mounted) return;
        kLocalDataRevision.value++;
        // 尽力而为地推一次；离线时会静默留在队列里，联网后自动补发。
        PushScheduler.schedule();
        Navigator.of(context).pop(true);
        return;
      }

      await _api.createDefectTicket(
        userId: kDemoUserId,
        examProfileId: widget.examProfileId,
        qType: _submitQType,
        errorCause: _errorCause.text.trim(),
        errorLayer: _submitErrorLayer,
        customReason: _submitCustomReason,
        knowledgeNodeId: _knowledgeNodeId,
        priority: _priority,
        questionId: widget.initialQuestionId,
        actions: actions,
      );
      if (!mounted) return;
      // 成功：把 true 传回列表页，由它决定刷新时机（避免 create 页自己
      // 再发一次列表请求，两处刷新容易产生闪烁）。
      Navigator.of(context).pop(true);
    } on LocalValidationException catch (e) {
      // 本地校验拦截（如归因写了禁用语）：留在本页，把错误映射到对应字段。
      if (!mounted) return;
      setState(() {
        _busy = false;
        switch (e.code) {
          case 'FORBIDDEN_PHRASE_IN_ERROR_CAUSE':
            _errors['errorCause'] = '不能写「${e.details['phrases'] ?? '这些词'}」，要写具体错因';
          case 'MISSING_ERROR_LAYER':
            _errors['errorLayer'] = '请选择错因层级';
          case 'MISSING_ERROR_CAUSE':
            _errors['errorCause'] = '请填写具体错因';
          default:
            _bannerError = e.message;
        }
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _applyBackendError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FormScaffold(
      title: '新建缺陷单',
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
          FormErrorBanner(
            message: _bannerError!,
            actionLabel: '重试',
            onAction: _submit,
          ),

        FormFieldGroup(
          label: '题型 / 考点摘要',
          required: true,
          error: _errors['qType'],
          hint: _qTypeManual
              ? '手动输入题型（题库里还没有可选项时可用）'
              : '从已导入题目里出现过的题型中选一个',
          child: _qTypeManual
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    FormTextField(
                      controller: _qType,
                      placeholder: '如：资料分析 · 比重变化',
                      hasError: _errors.containsKey('qType'),
                      textInputAction: TextInputAction.next,
                      onChanged: (_) {
                        if (_errors.containsKey('qType')) {
                          setState(() => _errors.remove('qType'));
                        }
                      },
                    ),
                    const SizedBox(height: 6),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      minimumSize: Size.zero,
                      onPressed: () => setState(() {
                        _qTypeManual = false;
                        _qType.clear();
                        _qTypeValue = null;
                      }),
                      child: const Text(
                        '改为选择题型',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 13,
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                  ],
                )
              : _QuestionTypeField(
                  loading: _loadingTypes,
                  errorText: _typesError,
                  selected: _qTypeValue,
                  hasError: _errors.containsKey('qType'),
                  onTap: _openQuestionTypePicker,
                  onManual: () => setState(() {
                    _qTypeManual = true;
                    _qTypeValue = null;
                  }),
                ),
        ),

        FormFieldGroup(
          label: '错因层级',
          required: true,
          error: _errors['errorLayer'],
          hint: '来自开发文档的行测六层；后端该字段是自由文本，此处只是常用选项',
          child: FormChipGroup(
            options: kErrorLayerOptions,
            selected: _errorLayer,
            onChanged: (String v) => setState(() {
              _errorLayer = v;
              _errors.remove('errorLayer');
            }),
          ),
        ),

        // 选了「自定义」才出现自定义错因输入框。
        //
        // 提交约定：`error_layer` 仍然只传六层枚举里的一个值（默认「识别」），
        // 用户写的这段文本走新字段 `custom_reason`；「自定义」两个字只是前端
        // 的哨兵值，永远不作为 error_layer 提交（后端 error_layer 是自由文本，
        // 但前端其它地方按枚举用，混进去会破坏统计口径）。
        if (_errorLayer == kCustomErrorLayerValue)
          FormFieldGroup(
            label: '自定义错因',
            required: true,
            error: _errors['customReason'],
            hint: '最多 30 字。提交时错因层级仍记为「$kPracticeDefaultErrorLayer」，这段文本单独保存。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FormTextField(
                  controller: _customReason,
                  placeholder: '如：计算失误（两位数乘法口诀不熟）',
                  hasError: _errors.containsKey('customReason'),
                  onChanged: (_) {
                    if (_errors.containsKey('customReason')) {
                      setState(() => _errors.remove('customReason'));
                    }
                  },
                ),
                if (_customReasons.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  const Text(
                    '最近用过',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12,
                      color: AppColors.secondaryLabel,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _customReasons
                        .map(
                          (String reason) => GestureDetector(
                            onTap: () => setState(() {
                              _customReason.text = reason;
                              _errors.remove('customReason');
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(AppRadii.chip),
                              ),
                              child: Text(
                                reason,
                                style: const TextStyle(
                                  fontFamily: kFontFamily,
                                  fontSize: 13,
                                  color: AppColors.accent,
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ],
                if (_customReason.text.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    '自定义错因：${_customReason.text.trim()}',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12,
                      color: AppColors.secondaryLabel,
                    ),
                  ),
                ],
              ],
            ),
          ),

        FormFieldGroup(
          label: '具体错因',
          required: true,
          error: _errors['errorCause'],
          hint: '写清哪一步、哪个概念、怎么想错的。禁用「粗心 / 马虎 / 没掌握 / 我懂了 / 大意 / 差不多 / 忘了」',
          child: FormTextField(
            controller: _errorCause,
            placeholder: '如：把充分条件当成必要条件，逆命题与原命题混用',
            maxLines: 4,
            hasError: _errors.containsKey('errorCause'),
            onChanged: (_) {
              if (_errors.containsKey('errorCause')) {
                setState(() => _errors.remove('errorCause'));
              }
            },
          ),
        ),

        FormFieldGroup(
          label: '关联考点',
          hint: _loadingNodes
              ? '正在加载考点…'
              : (_nodes.isEmpty ? '该科目下暂无考点，可先不选' : '可不选；选中后详情页会显示考点名'),
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
                      selected: _knowledgeNodeId,
                      labelOf: (String id) {
                        final idx = _nodes.indexWhere(
                          (Map<String, Object?> n) => '${n['id']}' == id,
                        );
                        if (idx < 0) return id;
                        final String title = '${_nodes[idx]['title'] ?? ''}';
                        final String freq =
                            '${_nodes[idx]['freq_tag'] ?? ''}';
                        final String suffix = switch (freq) {
                          'high' => ' · 高频',
                          'mid' => ' · 中频',
                          'low' => ' · 低频',
                          _ => '',
                        };
                        return '$title$suffix';
                      },
                      onChanged: (String v) => setState(() {
                        // 再点一次取消选择，允许留空
                        _knowledgeNodeId = _knowledgeNodeId == v ? null : v;
                      }),
                    )),
        ),

        FormFieldGroup(
          label: '优先级',
          required: true,
          hint: 'P0 立即处理 / P1 尽快处理 / P2 有空再看。后端会用四个因子重算，此处是初值',
          child: FormChipGroup(
            options: const <String>['P0', 'P1', 'P2'],
            selected: _priority,
            labelOf: (String v) => switch (v) {
              'P0' => 'P0 立即',
              'P1' => 'P1 尽快',
              'P2' => 'P2 有空',
              _ => v,
            },
            colorOf: (String v) => switch (v) {
              'P0' => AppColors.overdue,
              'P1' => AppColors.dueSoon,
              _ => AppColors.secondaryLabel,
            },
            onChanged: (String v) => setState(() => _priority = v),
          ),
        ),

        FormFieldGroup(
          label: '处理动作',
          hint: '至少一条才能「进入验证」；可后续在详情页继续添加或勾选完成',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ...List<Widget>.generate(_actionControllers.length, (int i) {
                final bool removable = _actionControllers.length > 1;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: FormTextField(
                          controller: _actionControllers[i],
                          placeholder: i == 0
                              ? '如：重推比重变化公式，再做 5 道同类题'
                              : '再补充一条动作',
                          textInputAction: i == _actionControllers.length - 1
                              ? TextInputAction.done
                              : TextInputAction.next,
                        ),
                      ),
                      if (removable)
                        Padding(
                          padding: const EdgeInsets.only(left: 4, top: 6),
                          child: CupertinoButton(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            onPressed: () {
                              setState(() {
                                _actionControllers.removeAt(i).dispose();
                              });
                            },
                            child: const Icon(
                              CupertinoIcons.minus_circle,
                              size: 22,
                              color: AppColors.tertiaryLabel,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 6),
                minimumSize: Size.zero,
                onPressed: () {
                  setState(() {
                    _actionControllers.add(TextEditingController());
                  });
                },
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(CupertinoIcons.add_circled,
                        size: 18, color: AppColors.accent),
                    SizedBox(width: 4),
                    Text(
                      '添加动作',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 14,
                        color: AppColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 8),
        FormSubmitButton(
          label: '保存缺陷单',
          busy: _busy,
          onPressed: _submit,
        ),
        const SizedBox(height: 12),
        Text(
          '提交后状态为「已归因」，可直接去详情页标记动作、进入验证。',
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

/// 题型下拉的表单控件（纯 Cupertino，没有 Material 的 DropdownButton）。
///
/// 只负责展示「当前选中值 + 点击回调」，弹层逻辑在 [_QuestionTypeSheet]。
class _QuestionTypeField extends StatelessWidget {
  const _QuestionTypeField({
    required this.loading,
    required this.errorText,
    required this.selected,
    required this.hasError,
    required this.onTap,
    required this.onManual,
  });

  final bool loading;
  final String? errorText;
  final String? selected;
  final bool hasError;
  final VoidCallback onTap;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    final String? value = selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        GestureDetector(
          onTap: loading ? null : onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(AppRadii.chip + 2),
              border: Border.all(
                color: hasError
                    ? CupertinoColors.systemRed
                    : AppColors.separator,
                width: hasError ? 1 : 0.5,
              ),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: loading
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CupertinoActivityIndicator(radius: 8),
                            ),
                            SizedBox(width: 8),
                            Text(
                              '正在加载题型…',
                              style: TextStyle(
                                fontFamily: kFontFamily,
                                fontSize: 15,
                                color: AppColors.tertiaryLabel,
                              ),
                            ),
                          ],
                        )
                      : Text(
                          value == null || value.isEmpty
                              ? '请选择题型'
                              : '${questionTypeLabel(value)}（$value）',
                          style: TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 15,
                            color: value == null || value.isEmpty
                                ? AppColors.tertiaryLabel
                                : AppColors.label,
                          ),
                        ),
                ),
                const Icon(
                  CupertinoIcons.chevron_down,
                  size: 16,
                  color: AppColors.secondaryLabel,
                ),
              ],
            ),
          ),
        ),
        if (errorText != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            errorText!,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: CupertinoColors.systemRed,
            ),
          ),
        ],
        const SizedBox(height: 6),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(vertical: 4),
          minimumSize: Size.zero,
          onPressed: onManual,
          child: const Text(
            '手动输入题型',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.accent,
            ),
          ),
        ),
      ],
    );
  }
}

/// 题型选择弹层：顶部可搜索，下方是可选题型列表。
///
/// 纯 Cupertino 没有 Material 的 DropdownButton，这里用
/// `showCupertinoModalPopup` + `CupertinoSearchTextField` 自建。
class _QuestionTypeSheet extends StatefulWidget {
  const _QuestionTypeSheet({
    required this.options,
    required this.selected,
    required this.onManual,
  });

  final List<QuestionTypeCount> options;
  final String? selected;
  final VoidCallback onManual;

  @override
  State<_QuestionTypeSheet> createState() => _QuestionTypeSheetState();
}

class _QuestionTypeSheetState extends State<_QuestionTypeSheet> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<QuestionTypeCount> get _filtered {
    final String q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return widget.options;
    return widget.options
        .where(
          (QuestionTypeCount t) =>
              t.type.toLowerCase().contains(q) ||
              questionTypeLabel(t.type).contains(q),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final List<QuestionTypeCount> items = _filtered;
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: AppColors.groupedBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.card)),
      ),
      child: Column(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            decoration: const BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.card)),
            ),
            child: Column(
              children: <Widget>[
                CupertinoSearchTextField(
                  controller: _query,
                  placeholder: '搜索题型',
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      minimumSize: Size.zero,
                      onPressed: widget.onManual,
                      child: const Text(
                        '手动输入',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 13,
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      minimumSize: Size.zero,
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        '取消',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 13,
                          color: AppColors.secondaryLabel,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 0.5, child: ColoredBox(color: AppColors.separator)),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text(
                      '没有匹配的题型',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 14,
                        color: AppColors.secondaryLabel,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.page,
                      vertical: 8,
                    ),
                    itemCount: items.length,
                    itemBuilder: (BuildContext context, int index) {
                      final QuestionTypeCount t = items[index];
                      final bool active = widget.selected == t.type;
                      return GestureDetector(
                        onTap: () => Navigator.of(context).pop(t.type),
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      questionTypeLabel(t.type),
                                      style: TextStyle(
                                        fontFamily: kFontFamily,
                                        fontSize: 15,
                                        color: AppColors.label,
                                      ),
                                    ),
                                    Text(
                                      '${t.type} · ${t.count} 道',
                                      style: const TextStyle(
                                        fontFamily: kFontFamily,
                                        fontSize: 12,
                                        color: AppColors.tertiaryLabel,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (active)
                                const Icon(
                                  CupertinoIcons.check_mark_circled,
                                  size: 18,
                                  color: AppColors.accent,
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
