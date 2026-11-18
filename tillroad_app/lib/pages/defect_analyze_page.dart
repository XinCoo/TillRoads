// 归因页（FE-03 写操作联调 · 任务 C）。
//
// 两个入口共用一个页面：
//   * status == DRAFT     → 底部「去归因」→ PATCH /defect-tickets/:id/analyze
//   * status == REOPENED  → 底部「重新归因」→ PATCH /defect-tickets/:id/analyze
//     **带 `status: 'REOPENED'`**，后端据此走 `reanalyze`
//     （校验当前必须是 REOPENED，并由 DB 触发器把 verification_round +1）。
//
// 乐观锁：提交必带 `version`。后端 0 行命中 → 409 + `{error:'conflict',
// current, incoming, resolution:'client_merge'}`。任务书 C4 要求提示
// 「该单已被修改，请刷新后重试」并提供刷新入口 —— 这里用顶部条的「刷新」动作，
// 点它会重新拉详情并把表单回填成服务端最新值。

import 'package:flutter/cupertino.dart';

import '../../api/api_client.dart';
import '../../api/defect_api.dart';
import '../../theme/app_theme.dart';
// CardShell / InfoRow 等卡片壳复用 FE-03 列表页的组件，保证圆角/阴影一致
import '../../widgets/defect_badges.dart';
import '../../widgets/form_field.dart';
import '../mock/defects_mock.dart';

class DefectAnalyzePage extends StatefulWidget {
  const DefectAnalyzePage({super.key, required this.ticket});

  final DefectTicket ticket;

  @override
  State<DefectAnalyzePage> createState() => _DefectAnalyzePageState();
}

class _DefectAnalyzePageState extends State<DefectAnalyzePage> {
  final DefectApi _api = DefectApi();

  late final TextEditingController _errorCause =
      TextEditingController(text: _initialCause);
  String? _errorLayer;

  final Map<String, String> _errors = <String, String>{};
  String? _bannerError;

  /// 「已被修改」时顶部条显示「刷新」，点击后回填服务端最新值。
  bool _staleConflict = false;
  bool _busy = false;

  /// 当前版本号；409 后刷新会把最新服务端行写回来一起更新。
  late int _version = widget.ticket.version;

  bool get _isReopened => widget.ticket.status == DefectStatus.reopened;

  /// 初值：DRAFT 单后端可能返回 null（P0-3 允许），界面模型已回落成
  /// 「尚未填写归因说明」，这里不能把它当成用户输入回填，否则一提交就踩禁用语/无意义文本。
  String get _initialCause {
    final String c = widget.ticket.errorCause;
    return (c == '尚未填写归因说明' || c == '未归因') ? '' : c;
  }

  @override
  void initState() {
    super.initState();
    final String l = widget.ticket.errorLayer;
    if (l != '未归因' && kErrorLayerOptions.contains(l)) {
      _errorLayer = l;
    } else if (l != '未归因') {
      // 后端是自由文本：历史值不在候选集内时，先回填到「其他」不可行
      // （UI 只有六选项），因此不预选，由用户重新确认一次。已在 hint 说明。
      _errorLayer = null;
    }
  }

  @override
  void dispose() {
    _errorCause.dispose();
    _api.close();
    super.dispose();
  }

  bool _validate() {
    final Map<String, String> errors = <String, String>{};
    if (_errorLayer == null) {
      errors['errorLayer'] = '请选择错因层级';
    }
    final String cause = _errorCause.text.trim();
    if (cause.isEmpty) {
      errors['errorCause'] = '请填写具体错因';
    } else {
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
      _staleConflict = false;
    });
    return errors.isEmpty;
  }

  void _applyBackendError(ApiException e) {
    final Object? body = e.body;
    final String code =
        body is Map && body['error'] != null ? '${body['error']}' : '';

    if (code == 'conflict' || e.statusCode == 409) {
      setState(() {
        _staleConflict = true;
        _bannerError = '该单已被修改，请刷新后重试';
      });
      return;
    }
    if (code == 'forbidden_phrase' ||
        code == 'FORBIDDEN_PHRASE_IN_ERROR_CAUSE') {
      setState(() {
        _errors['errorCause'] =
            '请写出具体哪一步算错或记错，不要写粗心 / 没掌握 / 大意这类词';
      });
      return;
    }
    if (code == 'missing_error_layer_or_cause' ||
        code == 'MISSING_ERROR_LAYER' ||
        code == 'MISSING_ERROR_CAUSE') {
      setState(() {
        if (_errorLayer == null) _errors['errorLayer'] = '请选择错因层级';
        if (_errorCause.text.trim().isEmpty) {
          _errors['errorCause'] = '请填写具体错因';
        }
      });
      return;
    }
    if (code == 'ILLEGAL_DEFECT_TRANSITION' || code == 'INVALID_BASE_VERSION') {
      setState(() {
        _staleConflict = true;
        _bannerError = '当前状态不支持归因（可能已被验证/关闭），请刷新后查看';
      });
      return;
    }

    setState(() {
      _bannerError = e.isNetworkError
          ? '${e.message}\n请确认后端在运行，然后重试。'
          : e.message;
    });
  }

  Future<void> _refreshFromServer() async {
    setState(() => _busy = true);
    try {
      final DefectTicket fresh = await _api.fetchDefectDetail(widget.ticket.id);
      if (!mounted) return;
      setState(() {
        _version = fresh.version;
        _busy = false;
        _staleConflict = false;
        _bannerError = null;
        _errors.clear();
        final String l = fresh.errorLayer;
        _errorLayer =
            (l != '未归因' && kErrorLayerOptions.contains(l)) ? l : null;
        _errorCause.text = (fresh.errorCause == '尚未填写归因说明' ||
                fresh.errorCause == '未归因')
            ? ''
            : fresh.errorCause;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _bannerError = e.message;
      });
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_validate()) return;

    setState(() => _busy = true);
    try {
      await _api.analyzeDefectTicket(
        widget.ticket.id,
        errorLayer: _errorLayer!,
        errorCause: _errorCause.text.trim(),
        version: _version,
        reopened: _isReopened,
      );
      if (!mounted) return;
      // true 让详情页知道「归因成功，需要重新拉详情」。
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _applyBackendError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FormScaffold(
      title: _isReopened ? '重新归因' : '补充归因',
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
            actionLabel: _staleConflict ? '刷新' : '重试',
            onAction: _staleConflict ? _refreshFromServer : _submit,
          ),

        // 上下文卡片：避免用户忘了自己在归因哪张单
        CardShell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                widget.ticket.qType,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.label,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _isReopened
                    ? '这张单在上一次验证中未通过，已重开（第 ${widget.ticket.verificationRound + 1} 轮）。'
                        '重新归因后，验证轮次会 +1，可重走 V1/V2/V3。'
                    : '草稿单还没有归因。补齐后进入「已归因」，才能添加动作并进入验证。',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  height: 1.4,
                  color: AppColors.secondaryLabel,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.cardGap + 4),

        FormFieldGroup(
          label: '错因层级',
          required: true,
          error: _errors['errorLayer'],
          hint: '来自开发文档的行测六层；后端该字段是自由文本',
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
            maxLines: 5,
            autofocus: _errorCause.text.isEmpty,
            hasError: _errors.containsKey('errorCause'),
            onChanged: (_) {
              if (_errors.containsKey('errorCause')) {
                setState(() => _errors.remove('errorCause'));
              }
            },
          ),
        ),

        FormSubmitButton(
          label: _isReopened ? '保存并重开新一轮' : '保存归因',
          busy: _busy,
          onPressed: _submit,
        ),
        const SizedBox(height: 12),
        Text(
          _isReopened
              ? '保存后状态回到「已归因」，需重新添加动作并进入验证。'
              : '保存后状态变为「已归因」，接着去详情页标记动作完成。',
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
