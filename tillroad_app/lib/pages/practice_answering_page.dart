// 练习答题页（练习 R1 · 任务 C2）。
//
// 职责：逐题作答 → 客户端判分 → 提交一次练习。
//
// ── 三条设计决定 ──────────────────────────────────────────────────────────
// 1) **不限时**：练习不是模考，不设倒计时，也不在离开时自动交卷。
//    用户可以中途退出（退出就当没提交，不留半截记录）。
// 2) **客户端判分**：自己的题后端下发了 answer，本地就能判对错，
//    提交后立刻能看到结果；公共题没有答案，必须由用户「自评」对/错。
// 3) **判分口径与服务端一致**：`is_correct` 只有三种值 ——
//    true（对）/ false（错）/ null（未判定）。
//    跳过未作答的题、以及还没自评的公共题，都记 null，
//    服务端把它们计入 total 但不计 correct/wrong（unjudged）。
import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/practice_api.dart';
import '../theme/app_theme.dart';
import '../widgets/form_field.dart';
import 'practice_result_page.dart';

class PracticeAnsweringPage extends StatefulWidget {
  const PracticeAnsweringPage({
    super.key,
    required this.questions,
    required this.source,
    this.subjectId,
    this.knowledgeNodeId,
    this.examProfileId,
    this.subjectName,
  });

  final List<PracticeQuestion> questions;
  final PracticeSource source;
  final String? subjectId;
  final String? knowledgeNodeId;
  final String? examProfileId;
  final String? subjectName;

  @override
  State<PracticeAnsweringPage> createState() => _PracticeAnsweringPageState();
}

/// 一道题在本地的作答状态。
class _AnswerState {
  _AnswerState(this.question);

  final PracticeQuestion question;

  /// 用户选中的选项 key 集合（多选会 >1）。
  final Set<String> selected = <String>{};

  /// 自评结果：null = 还没评 / 不需要评。
  bool? selfJudged;

  /// 看过这道题花了多久（毫秒），提交时一并上报。
  int elapsedMs = 0;

  bool get answered => selected.isNotEmpty || selfJudged != null;

  /// 客户端判分：自己的题用 answer 比对；公共题用自评。
  bool? get isCorrect {
    if (question.hasAnswer && question.answer != null) {
      final String expected = _normalizeAnswer(question.answer!);
      final String actual = _normalizeAnswer(selected.join(''));
      if (actual.isEmpty) return null; // 没作答 → 未判定
      return expected == actual;
    }
    // 没有标准答案：只认自评。
    return selfJudged;
  }

  /// 把答案归一成可比的形式：去空白、转大写、多选按字母排序。
  static String _normalizeAnswer(String raw) {
    final List<String> parts = raw
        .toUpperCase()
        .split(RegExp(r'[^A-Za-z]'))
        .where((String s) => s.isNotEmpty)
        .toList();
    parts.sort();
    return parts.join('');
  }

  /// 用户答案的展示文本（多选时按选项 key 顺序拼）。
  String get userAnswerText {
    if (selected.isEmpty) return '';
    final List<String> keys = selected.toList()..sort();
    return keys.join('');
  }
}

class _PracticeAnsweringPageState extends State<PracticeAnsweringPage> {
  final PracticeApi _api = PracticeApi();
  late final List<_AnswerState> _states;
  int _index = 0;
  bool _submitting = false;
  String? _bannerError;

  @override
  void initState() {
    super.initState();
    _states = widget.questions.map((PracticeQuestion q) => _AnswerState(q)).toList();
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  _AnswerState get _current => _states[_index];

  void _toggleOption(String key) {
    setState(() {
      final _AnswerState s = _current;
      if (s.question.isMulti) {
        if (s.selected.contains(key)) {
          s.selected.remove(key);
        } else {
          s.selected.add(key);
        }
      } else {
        // 单选：再点一次取消（让用户能改主意）。
        if (s.selected.contains(key)) {
          s.selected.clear();
        } else {
          s.selected
            ..clear()
            ..add(key);
        }
      }
      // 改了答案就作废之前的自评。
      s.selfJudged = null;
    });
  }

  void _selfJudge(bool correct) {
    setState(() => _current.selfJudged = correct);
  }

  void _go(int delta) {
    setState(() {
      _index = (_index + delta).clamp(0, _states.length - 1);
    });
  }

  /// 提交：把每题的作答汇总调 `POST /practice-sessions`。
  Future<void> _submit() async {
    if (_submitting) return;

    // 有没自评的公共题 → 先提醒一次（不强制，跳过就记未判定）。
    final List<int> pendingSelf = <int>[];
    for (int i = 0; i < _states.length; i += 1) {
      final _AnswerState s = _states[i];
      if (!s.question.hasAnswer && s.selected.isNotEmpty && s.selfJudged == null) {
        pendingSelf.add(i);
      }
    }
    if (pendingSelf.isNotEmpty) {
      final bool? ok = await _confirmPendingSelf(pendingSelf.length);
      if (!mounted) return;
      if (ok != true) {
        setState(() => _index = pendingSelf.first);
        return;
      }
    }

    setState(() {
      _submitting = true;
      _bannerError = null;
    });

    final List<PracticeAnswerInput> answers = _states.map((_AnswerState s) {
      return PracticeAnswerInput(
        questionId: s.question.id,
        userAnswer: s.userAnswerText.isEmpty ? null : s.userAnswerText,
        isCorrect: s.isCorrect,
        durationMs: s.elapsedMs,
      );
    }).toList(growable: false);

    try {
      final PracticeSubmitResult result = await _api.submitSession(
        answers: answers,
        subjectId: widget.subjectId,
        knowledgeNodeId: widget.knowledgeNodeId,
        source: widget.source,
      );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement<void, void>(
        appRoute<void>(
          context,
          PracticeResultPage(
            sessionId: result.sessionId,
            questions: widget.questions,
            states: _states
                .map(
                  (_AnswerState s) => PracticeLocalAnswer(
                    questionId: s.question.id,
                    userAnswer: s.userAnswerText,
                    correctAnswer: s.question.answer,
                    isCorrect: s.isCorrect,
                    hasAnswer: s.question.hasAnswer,
                  ),
                )
                .toList(growable: false),
            submitResult: result,
            source: widget.source,
            subjectId: widget.subjectId,
            knowledgeNodeId: widget.knowledgeNodeId,
            examProfileId: widget.examProfileId,
            subjectName: widget.subjectName,
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _bannerError = e.isNetworkError
            ? '${e.message}\n练习记录没有保存成功，请确认后端在运行后重试。'
            : e.message;
      });
    }
  }

  Future<bool?> _confirmPendingSelf(int count) {
    return showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '还有题没自评',
          style: TextStyle(fontFamily: kFontFamily, fontSize: 17),
        ),
        content: Text(
          '$count 道公共题还没有标对错。没标的会算作「未判定」，不计入正确率。\n'
          '现在要提交吗？',
          style: const TextStyle(fontFamily: kFontFamily, fontSize: 14),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('去自评', style: TextStyle(fontFamily: kFontFamily)),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('仍然提交', style: TextStyle(fontFamily: kFontFamily)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final _AnswerState s = _current;
    final PracticeQuestion q = s.question;
    final bool isLast = _index == _states.length - 1;

    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            _buildHeader(s),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  12,
                  AppSpacing.page,
                  24,
                ),
                children: <Widget>[
                  if (_bannerError != null)
                    FormErrorBanner(message: _bannerError!),
                  _buildStem(q),
                  const SizedBox(height: 16),
                  ..._buildOptions(s),
                  if (!q.hasAnswer) ...<Widget>[
                    const SizedBox(height: 16),
                    _buildSelfJudge(s),
                  ],
                ],
              ),
            ),
            _buildBottomBar(isLast),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(_AnswerState s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 8, AppSpacing.page, 10),
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(bottom: BorderSide(color: AppColors.separator, width: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          Text(
            '第 ${_index + 1}/${_states.length} 题',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.label,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              s.question.typeLabel,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: AppColors.secondaryLabel,
              ),
            ),
          ),
          Text(
            s.answered ? '已作答' : '未作答',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: s.answered ? AppColors.accent : AppColors.tertiaryLabel,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStem(PracticeQuestion q) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Text(
        q.stem,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 16,
          height: 1.55,
          color: AppColors.label,
        ),
      ),
    );
  }

  List<Widget> _buildOptions(_AnswerState s) {
    if (s.question.options.isEmpty) {
      return <Widget>[
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadii.card),
          ),
          child: const Text(
            '这是一道主观题，没有选项。写下你的答案后自行判断对错。',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 14,
              height: 1.5,
              color: AppColors.secondaryLabel,
            ),
          ),
        ),
      ];
    }
    return s.question.options.map((PracticeOption o) {
      final bool active = s.selected.contains(o.key);
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _toggleOption(o.key),
          child: AnimatedContainer(
            duration: AppDurations.countdown,
            curve: Curves.easeInOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: active ? AppColors.accent.withValues(alpha: 0.08) : AppColors.card,
              borderRadius: BorderRadius.circular(AppRadii.card),
              border: Border.all(
                color: active ? AppColors.accent : AppColors.separator,
                width: active ? 1 : 0.5,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: s.question.isMulti ? BoxShape.rectangle : BoxShape.circle,
                    color: active ? AppColors.accent : CupertinoColors.transparent,
                    borderRadius:
                        s.question.isMulti ? BorderRadius.circular(6) : null,
                    border: Border.all(
                      color: active ? AppColors.accent : AppColors.tertiaryLabel,
                      width: 1,
                    ),
                  ),
                  child: active
                      ? const Icon(
                          CupertinoIcons.check_mark,
                          size: 13,
                          color: CupertinoColors.white,
                        )
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    o.text,
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 15,
                      height: 1.45,
                      color: AppColors.label,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }).toList(growable: false);
  }

  Widget _buildSelfJudge(_AnswerState s) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.dueSoon.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '该题不提供答案，请自评',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.label,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '公共题由他人上传，标准答案不对外公开，所以只能由你自己判断对错。',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              height: 1.4,
              color: AppColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: CupertinoButton(
                  color: AppColors.normal,
                  borderRadius: BorderRadius.circular(AppRadii.chip + 4),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  onPressed: () => _selfJudge(true),
                  child: const Text(
                    '我答对了',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: CupertinoButton(
                  color: AppColors.overdue,
                  borderRadius: BorderRadius.circular(AppRadii.chip + 4),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  onPressed: () => _selfJudge(false),
                  child: const Text(
                    '我答错了',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (s.selfJudged != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              s.selfJudged == true ? '已标记：答对' : '已标记：答错',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                color: AppColors.secondaryLabel,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomBar(bool isLast) {
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 10, AppSpacing.page, 14),
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.separator, width: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            onPressed: _index == 0 ? null : () => _go(-1),
            child: const Text(
              '上一题',
              style: TextStyle(fontFamily: kFontFamily, fontSize: 15),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: CupertinoButton(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(AppRadii.chip + 4),
              padding: const EdgeInsets.symmetric(vertical: 12),
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CupertinoActivityIndicator(
                        radius: 9,
                        color: CupertinoColors.white,
                      ),
                    )
                  : Text(
                      isLast ? '提交练习' : '提交并看结果',
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.white,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            onPressed: isLast ? null : () => _go(1),
            child: const Text(
              '下一题',
              style: TextStyle(fontFamily: kFontFamily, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}
