// 提交验证页（FE-03 写操作联调 · 任务 E2）。
//
// 对应后端 `POST /defect-tickets/:id/verifications`
// （handler 见 server/routes/defect_tickets.mjs:181，仓储在
//  server/repositories/defect_tickets.mjs 的 submitVerification）。
//
// 三个硬约束来自后端：
//   1. `stage` 必须是**当前阶段**（V1/V2/V3），否则 400 INVALID_VERIFICATION_STAGE
//      —— 页面直接读 ticket.status 作为 stage，不给用户选。
//   2. `verify_type` 受阶段白名单约束（core/index.mjs 的 STAGE_WINDOWS）：
//      V1 = redo_hidden / similar_variant / teach_back
//      V2 = new_question
//      V3 = timed_mock
//      → 用 verifyTypesForStage() 过滤，避免让用户选到必然 400 的值。
//   3. `version` 必填（乐观锁）。

import 'package:flutter/cupertino.dart';

import '../../api/api_client.dart';
import '../../api/defect_api.dart';
import '../../config/api_config.dart';
import '../../local/local.dart'
    show
        LocalValidationException,
        PushScheduler,
        WriteQueue,
        kLocalDataRevision,
        kLocalFirstEnabled;
import '../../theme/app_theme.dart';
import '../../widgets/defect_badges.dart';
import '../../widgets/form_field.dart';
import '../mock/defects_mock.dart';

class DefectVerifyPage extends StatefulWidget {
  const DefectVerifyPage({super.key, required this.ticket});

  final DefectTicket ticket;

  @override
  State<DefectVerifyPage> createState() => _DefectVerifyPageState();
}

class _DefectVerifyPageState extends State<DefectVerifyPage> {
  final DefectApi _api = DefectApi();

  final TextEditingController _evidence = TextEditingController();
  final TextEditingController _questionId = TextEditingController();

  /// 当前阶段（V1/V2/V3），来自 ticket.status，不可选。
  String get _stage => widget.ticket.status.wire.toUpperCase();

  late String? _verifyType = _defaultVerifyType();
  String _result = 'pass';

  final Map<String, String> _errors = <String, String>{};
  String? _bannerError;
  bool _staleConflict = false;
  bool _busy = false;

  late int _version = widget.ticket.version;

  String? _defaultVerifyType() {
    final List<String> allowed = verifyTypesForStage(_stage);
    return allowed.isEmpty ? null : allowed.first;
  }

  @override
  void dispose() {
    _evidence.dispose();
    _questionId.dispose();
    _api.close();
    super.dispose();
  }

  /// 当前阶段的说明文案（帮用户理解「这一步要做什么」）。
  String get _stageHint => switch (_stage) {
        'V1' => 'V1 · 3–7 天内不看答案重做一遍，或做同类变式、向别人讲清思路。',
        'V2' => 'V2 · 1–2 周后做一道同考点的新题，识别出这是同一类问题。',
        'V3' => 'V3 · 限时模考中稳定做对（时间压力下也不出错）。',
        _ => '',
      };

  bool _validate() {
    final Map<String, String> errors = <String, String>{};
    if (_verifyType == null) {
      errors['verifyType'] = '请选择验证方式';
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
    if (code == 'ai_cannot_close') {
      setState(() => _bannerError = 'AI 不能替用户关单：验证通过必须由你本人标记。');
      return;
    }
    if (code == 'INVALID_VERIFICATION_STAGE') {
      setState(() {
        _staleConflict = true;
        _bannerError = '当前阶段已变化（可能已在其他设备提交过），请刷新后重试';
      });
      return;
    }
    if (code == 'ILLEGAL_DEFECT_TRANSITION' ||
        code == 'INVALID_BASE_VERSION') {
      setState(() {
        _staleConflict = true;
        _bannerError = '当前状态不支持提交验证，请刷新后查看';
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
        // 阶段可能已经变了（比如另一端已经提交过 V1），重新按新阶段给默认值
        final List<String> allowed = verifyTypesForStage(_stage);
        _verifyType =
            allowed.contains(_verifyType) ? _verifyType : (allowed.isEmpty ? null : allowed.first);
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
      if (kLocalFirstEnabled) {
        // 本地优先（R4a）：本地立即推进状态（pass→下一阶段 / V3 pass→CLOSED），
        // 联网后由推送引擎发给云端。
        await WriteQueue.enqueueSubmitVerification(
          ticketId: widget.ticket.id,
          stage: _stage,
          verifyType: _verifyType!,
          result: _result,
          baseVersion: _version,
          questionId: _questionId.text,
          evidence: _evidence.text,
        );
        if (!mounted) return;
        kLocalDataRevision.value++;
        PushScheduler.schedule();
        Navigator.of(context).pop(true);
        return;
      }

      await _api.submitVerification(
        widget.ticket.id,
        stage: _stage,
        result: _result,
        verifyType: _verifyType!,
        version: _version,
        questionId: _questionId.text,
        evidence: _evidence.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on LocalValidationException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        switch (e.code) {
          case 'INVALID_VERIFICATION_STAGE':
            _bannerError = '当前阶段不支持这次提交，请返回详情刷新后重试';
          case 'INVALID_VERIFY_TYPE':
            _errors['verifyType'] = '这个验证方式不适用于 ${e.details['stage'] ?? _stage}';
          case 'INVALID_VERIFICATION_RESULT':
            _bannerError = '验证结果只能是「通过」或「未通过」';
          case 'DUPLICATE_VERIFICATION':
            _bannerError = '本轮此阶段已提交过，不能重复提交';
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
    final List<String> allowedTypes = verifyTypesForStage(_stage);
    final bool isV3 = _stage == 'V3';

    return FormScaffold(
      title: '提交验证',
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        onPressed: _busy ? null : _submit,
        child: Text(
          '提交',
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

        CardShell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  StatusBadge(status: widget.ticket.status, dense: true),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.ticket.qType,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.label,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _stageHint,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  height: 1.45,
                  color: AppColors.secondaryLabel,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.cardGap + 4),

        FormFieldGroup(
          label: '验证方式',
          required: true,
          error: _errors['verifyType'],
          hint: '只列出本阶段允许的方式（后端白名单）',
          child: FormChipGroup(
            options: allowedTypes,
            selected: _verifyType,
            labelOf: (String v) => kVerifyTypeLabels[v] ?? v,
            onChanged: (String v) => setState(() {
              _verifyType = v;
              _errors.remove('verifyType');
            }),
          ),
        ),

        FormFieldGroup(
          label: '验证结果',
          required: true,
          hint: isV3
              ? 'V3 通过即关闭缺陷单；未通过会重开并进入下一轮归因。'
              : '通过则进入下一阶段；未通过则重开（reopen_count +1）。',
          child: FormChipGroup(
            options: const <String>['pass', 'fail'],
            selected: _result,
            labelOf: (String v) => v == 'pass' ? '通过' : '未通过',
            colorOf: (String v) =>
                v == 'pass' ? AppColors.normal : AppColors.overdue,
            onChanged: (String v) => setState(() => _result = v),
          ),
        ),

        FormFieldGroup(
          label: '关联题目 ID',
          hint: '可选。填了就能在复盘里按题目聚合同类错误',
          child: FormTextField(
            controller: _questionId,
            placeholder: '如：f47ac10b-58cc-4372-a567-0e02b2c3d479',
          ),
        ),

        FormFieldGroup(
          label: '自证说明',
          hint: '可选但强烈建议：写清这次怎么做的、和上次错在哪里不同',
          child: FormTextField(
            controller: _evidence,
            placeholder: '如：这次先在稿纸上列出「现期/基期/增长率」三列，再判断比较方向，用时 1 分 40 秒',
            maxLines: 4,
          ),
        ),

        const SizedBox(height: 8),
        FormSubmitButton(
          label: _result == 'pass'
              ? (isV3 ? '标记通过并关闭' : '标记通过')
              : '标记未通过（会重开）',
          busy: _busy,
          onPressed: _submit,
        ),
        const SizedBox(height: 12),
        Text(
          '提交会推进缺陷单状态，产生一条不可修改的验证记录（当前第 '
          '${widget.ticket.verificationRound} 轮）。',
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
