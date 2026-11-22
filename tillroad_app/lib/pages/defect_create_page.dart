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
import '../../config/api_config.dart';
// 只取写队列相关符号：`local.dart` 也导出 `findForbiddenPhrases`，
// 与 `defect_api.dart` 的同名函数冲突，故用 show 收窄。
import '../../local/local.dart'
    show
        kLocalDataRevision,
        kLocalFirstEnabled,
        loadKnowledgeNodes,
        LocalValidationException,
        PushScheduler,
        WriteQueue;
import '../../theme/app_theme.dart';
import '../../widgets/form_field.dart';

class DefectCreatePage extends StatefulWidget {
  const DefectCreatePage({
    super.key,
    required this.examProfileId,
    required this.subjectId,
    required this.subjectName,
  });

  /// 建单必填：后端 `defect_tickets.exam_profile_id` 是 NOT NULL 外键。
  final String examProfileId;

  /// 建单页从「当前科目」加载考点列表，避免一次性拉全库考点。
  final String subjectId;
  final String subjectName;

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

  @override
  void initState() {
    super.initState();
    _loadNodes();
  }

  @override
  void dispose() {
    _qType.dispose();
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

  /// 前端预校验。返回 true 表示可以提交。
  bool _validate() {
    final Map<String, String> errors = <String, String>{};

    if (_qType.text.trim().isEmpty) {
      errors['qType'] = '请填写题型或考点摘要';
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
      if (kLocalFirstEnabled) {
        // 本地优先（R4a）：写本地库 + 入队，用户立刻看到新单；推送由后台完成。
        // 校验已在 WriteQueue 内部跑过一遍状态机，非法操作在这里抛出，不会落库。
        await WriteQueue.enqueueCreateDefect(
          userId: kDemoUserId,
          examProfileId: widget.examProfileId,
          qType: _qType.text.trim(),
          errorCause: _errorCause.text.trim(),
          errorLayer: _errorLayer,
          knowledgeNodeId: _knowledgeNodeId,
          priority: _priority,
          actions: actions,
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
        qType: _qType.text.trim(),
        errorCause: _errorCause.text.trim(),
        errorLayer: _errorLayer,
        knowledgeNodeId: _knowledgeNodeId,
        priority: _priority,
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
          hint: '一句话说清这道题考什么，如「资料分析 · 比重变化」',
          child: FormTextField(
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
