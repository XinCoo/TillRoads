// 限时答题页（FE-05 任务 C）。
//
// 职责：渲染组卷返回的题目、本地保存作答、倒计时与到点自动交卷、交卷后进报告页。
//
// ── 为什么没有「中断恢复」──────────────────────────────────────────────────
// 任务书硬约束：MVP 不做持久化。作答只存在本 State 的内存里（`_answers`），
// 杀了进程或退出页面就丢。这里刻意不写 `shared_preferences`：
// 半成品恢复比「没有恢复」更容易让用户以为数据还在。
//
// ── 计时口径 ──────────────────────────────────────────────────────────────
// 用**绝对截止时间**（`_deadline`）而不是每秒减一：
//   * `Timer.periodic` 在 iOS/Android 上会被调度延迟，减法会越跑越慢；
//   * 截止时间由 `DateTime.now()` 反算剩余，误差不累积，锁屏回来也能立刻对齐。
//
// ── 与任务书的命名差异 ────────────────────────────────────────────────────
// 任务书写 `mock_answering_page.dart`；这里叫 `mock_exam_page.dart`，
// 因为它是「一次模考」的完整容器（答题 + 交卷 + 跳报告），
// 且仓库既有页面命名都是 `xxx_page.dart`（defect_detail_page / verify_page）。
//
// ── 交卷的两种触发 ────────────────────────────────────────────────────────
//   1. 手动：点右上角「交卷」→ 确认弹窗（提示未答题数）→ 提交；
//   2. 自动：倒计时到 0 → 立即提交（不再弹确认），提交成功后提示「时间到，已自动交卷」。
// 两者都带 `submitted_at`（客户端时间），后端据此判断是否超过
// `duration_limit_ms + 60s` 宽限并回填 `timed_out`。
import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/mock_api.dart';
import '../theme/app_theme.dart';
import 'mock_report_page.dart';

class MockExamPage extends StatefulWidget {
  const MockExamPage({
    super.key,
    required this.exam,
    required this.questions,
  });

  /// 卷子元数据（含 version —— 交卷的乐观锁基准）。
  final MockExam exam;

  /// 组卷响应顶层 `questions`（含题干与选项；`exam.entries` 只有索引）。
  final List<MockQuestion> questions;

  @override
  State<MockExamPage> createState() => _MockExamPageState();
}

class _MockExamPageState extends State<MockExamPage> {
  final MockExamApi _api = MockExamApi();
  final Map<String, String> _answers = <String, String>{};

  /// 每题的累计停留时长（毫秒），随 `answers` 一起提交给后端做 avg_duration_ms。
  final Map<String, int> _spentMs = <String, int>{};

  int _index = 0;
  Timer? _ticker;
  DateTime? _deadline;
  DateTime _lastTick = DateTime.now();
  int _remainingMs = 0;

  bool _submitting = false;
  bool _allowPop = false;
  String? _bannerError;

  MockQuestion get _current => widget.questions[_index];

  int get _answeredCount => widget.questions
      .where((MockQuestion q) {
        final String? a = _answers[q.questionId];
        return a != null && a.trim().isNotEmpty;
      })
      .length;

  int get _unansweredCount => widget.questions.length - _answeredCount;

  bool get _isUrgent => _remainingMs <= 60 * 1000;

  /// 闪烁用：剩余时间按秒取奇偶，每两秒一个明暗循环。
  bool get _blinkOn => (_remainingMs ~/ 1000).isEven;

  @override
  void initState() {
    super.initState();
    final int? limit = widget.exam.durationLimitMs;
    if (limit != null && limit > 0) {
      _deadline = DateTime.now().add(Duration(milliseconds: limit));
      _remainingMs = limit;
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _api.close();
    super.dispose();
  }

  void _onTick() {
    if (!mounted || _submitting) return;
    final DateTime now = DateTime.now();
    final int deltaMs = now.difference(_lastTick).inMilliseconds;
    _lastTick = now;

    // 计时只累计「当前正在看的那道题」，切题后自然分到新题上。
    final String qid = _current.questionId;
    _spentMs[qid] = (_spentMs[qid] ?? 0) + deltaMs;

    final DateTime? deadline = _deadline;
    if (deadline != null) {
      final int left = deadline.difference(now).inMilliseconds;
      setState(() => _remainingMs = left < 0 ? 0 : left);
      if (left <= 0) {
        // 到点：不再等用户确认（任务书 C4）
        _autoSubmit();
      }
    }
  }

  /// 把毫秒格式化成 `MM:SS`（超过 1 小时显示 `H:MM:SS`）。
  String _formatRemaining(int ms) {
    final int totalSeconds = (ms / 1000).ceil();
    final int h = totalSeconds ~/ 3600;
    final int m = (totalSeconds % 3600) ~/ 60;
    final int s = totalSeconds % 60;
    final String mm = m.toString().padLeft(2, '0');
    final String ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  List<MockAnswer> _buildAnswers() {
    final List<MockAnswer> out = <MockAnswer>[];
    for (final MockQuestion q in widget.questions) {
      final String text = (_answers[q.questionId] ?? '').trim();
      if (text.isEmpty) continue; // 未答的题不必上报，后端按「未作答」计错
      out.add(MockAnswer(
        questionId: q.questionId,
        answerText: text,
        // 没被停留过（直接跳到别处）的题给 0，后端 avg_duration_ms 只统计非空值
        durationMs: _spentMs[q.questionId] ?? 0,
      ));
    }
    return out;
  }

  Future<void> _autoSubmit() async {
    if (_submitting) return;
    await _submit(auto: true);
  }

  /// 交卷。`auto=true` 表示倒计时归零触发。
  Future<void> _submit({required bool auto}) async {
    if (_submitting) return;
    _ticker?.cancel();
    setState(() {
      _submitting = true;
      _bannerError = null;
    });

    try {
      final MockSubmitResult result = await _api.submitMockExam(
        widget.exam.id,
        version: widget.exam.version,
        answers: _buildAnswers(),
        submittedAt: DateTime.now(),
      );
      if (!mounted) return;
      await _goToReport(result, auto: auto);
    } on ApiException catch (e) {
      if (!mounted) return;
      // 409 already_submitted：可能是另一路（如超时自动交卷）已经提交成功，
      // 不算失败 —— 直接去读已生成的报告，而不是把用户留在答题页。
      if (e.statusCode == 409) {
        await _openExistingReport();
        return;
      }
      setState(() {
        _submitting = false;
        _bannerError = e.isNetworkError
            ? '${e.message}\n作答仍在本机，恢复网络后可再试一次。'
            : e.message;
      });
      // 网络类失败允许继续计时，否则用户会被卡死在「已超时但没交上」的状态
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    }
  }

  Future<void> _openExistingReport() async {
    try {
      final MockReport report = await _api.fetchMockExamReport(widget.exam.id);
      if (!mounted) return;
      _ticker?.cancel();
      Navigator.of(context).pushReplacement<void, void>(
        appRoute<void>(
          context,
          MockReportPage(
            examId: widget.exam.id,
            report: report,
            questions: widget.questions,
            timedOut: false,
            elapsedMs: 0,
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _bannerError = e.isNetworkError ? e.message : '该卷已提交，但读取报告失败：${e.message}';
      });
    }
  }

  Future<void> _goToReport(MockSubmitResult result, {required bool auto}) async {
    if (auto) {
      await _showTimedOutDialog();
      if (!mounted) return;
    }
    Navigator.of(context).pushReplacement<void, void>(
      appRoute<void>(
        context,
        MockReportPage(
          examId: widget.exam.id,
          report: result.report,
          questions: widget.questions,
          timedOut: result.timedOut || auto,
          elapsedMs: result.elapsedMs,
        ),
      ),
    );
  }

  Future<void> _showTimedOutDialog() async {
    await showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '时间到，已自动交卷',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            '未作答的题按答错计入正确率。',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '查看报告',
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

  Future<void> _confirmSubmit() async {
    if (_submitting) return;
    final int missing = _unansweredCount;
    final bool? ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '确定交卷？',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            missing > 0 ? '还有 $missing 题未作答，未答的题按答错计入。' : '全部题目已作答，交卷后立即生成报告。',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              '继续作答',
              style: TextStyle(fontFamily: kFontFamily, fontSize: 17),
            ),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              '交卷',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok == true) await _submit(auto: false);
  }

  Future<void> _confirmExit() async {
    if (_submitting) return;
    final bool? quit = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '退出模考？',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            '退出将丢失本次作答，确定退出？',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              '继续作答',
              style: TextStyle(fontFamily: kFontFamily, fontSize: 17),
            ),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              '退出',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (quit == true && mounted) {
      // PopScope 拦住了第一次 pop，这里先放开再 pop，避免死循环。
      setState(() => _allowPop = true);
      _ticker?.cancel();
      Navigator.of(context).pop();
    }
  }

  void _go(int delta) {
    final int next = _index + delta;
    if (next < 0 || next >= widget.questions.length) return;
    setState(() {
      // 记下方向，让 AnimatedSwitcher 往用户翻页的方向滑入
      _lastDirection = delta;
      _index = next;
    });
  }

  void _setAnswer(String value) {
    setState(() {
      if (value.trim().isEmpty) {
        _answers.remove(_current.questionId);
      } else {
        _answers[_current.questionId] = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool limited = _deadline != null;
    return PopScope<Object?>(
      canPop: _allowPop,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _confirmExit();
      },
      child: CupertinoPageScaffold(
        backgroundColor: AppColors.groupedBackground,
        navigationBar: CupertinoNavigationBar(
          middle: _TitleBar(
            index: _index + 1,
            total: widget.questions.length,
            timeText: limited ? _formatRemaining(_remainingMs) : '不限时',
            urgent: limited && _isUrgent,
            blinkOn: _blinkOn,
          ),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            onPressed: _submitting ? null : _confirmSubmit,
            child: Text(
              _submitting ? '提交中…' : '交卷',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: _submitting ? AppColors.tertiaryLabel : AppColors.accent,
              ),
            ),
          ),
          // 必须不透明：CupertinoPageScaffold 仅在 shouldFullyObstruct（alpha==0xFF）
          // 时替 child 预留导航栏高度；半透明 + SafeArea(top:false) 会让题目正文
          // 被导航栏盖住（真机实测）。
          backgroundColor: AppColors.groupedBackground,
          border: const Border(
            bottom: BorderSide(color: AppColors.separator, width: 0.5),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: <Widget>[
              if (_bannerError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.page,
                    8,
                    AppSpacing.page,
                    0,
                  ),
                  child: _InlineError(
                    message: _bannerError!,
                    onRetry: () => _submit(auto: false),
                  ),
                ),
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.page,
                    12,
                    AppSpacing.page,
                    20,
                  ),
                  child: AnimatedSwitcher(
                    duration: AppDurations.countdown,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (Widget child, Animation<double> anim) {
                      // 按前进/后退方向做水平位移，避免「总是从右边滑进来」
                      final Animation<Offset> offset = Tween<Offset>(
                        begin: Offset(_lastDirection >= 0 ? 0.06 : -0.06, 0),
                        end: Offset.zero,
                      ).animate(anim);
                      return FadeTransition(
                        opacity: anim,
                        child: SlideTransition(position: offset, child: child),
                      );
                    },
                    child: KeyedSubtree(
                      key: ValueKey<int>(_index),
                      child: _QuestionBody(
                        index: _index,
                        total: widget.questions.length,
                        question: _current,
                        answer: _answers[_current.questionId] ?? '',
                        onAnswer: _setAnswer,
                      ),
                    ),
                  ),
                ),
              ),
              _Footer(
                index: _index,
                total: widget.questions.length,
                answered: List<bool>.generate(
                  widget.questions.length,
                  (int i) => (_answers[widget.questions[i].questionId] ?? '')
                      .trim()
                      .isNotEmpty,
                ),
                onPrev: _index == 0 ? null : () => _go(-1),
                onNext:
                    _index >= widget.questions.length - 1 ? null : () => _go(1),
                onJump: (int i) {
                  if (i < 0 || i >= widget.questions.length) return;
                  setState(() {
                    if (i != _index) _lastDirection = i > _index ? 1 : -1;
                    _index = i;
                  });
                },
                onSubmit: _submitting ? null : _confirmSubmit,
                answeredCount: _answeredCount,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 最近一次切题方向，供 AnimatedSwitcher 决定滑入方向。
  int _lastDirection = 1;
}

/// 顶部导航栏的中间标题：左「第 X / Y 题」，右剩余时间。
class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.index,
    required this.total,
    required this.timeText,
    required this.urgent,
    required this.blinkOn,
  });

  final int index;
  final int total;
  final String timeText;
  final bool urgent;
  final bool blinkOn;

  @override
  Widget build(BuildContext context) {
    final Color timeColor = urgent ? AppColors.overdue : AppColors.label;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '第 $index/$total 题',
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        const SizedBox(width: 10),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 400),
          opacity: urgent && !blinkOn ? 0.35 : 1,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                CupertinoIcons.timer,
                size: 14,
                color: timeColor,
              ),
              const SizedBox(width: 3),
              Text(
                timeText,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: timeColor,
                  // 等宽数字：每秒变化时宽度不抖
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 一题的内容区（题干 + 选项 / 输入框）。
class _QuestionBody extends StatelessWidget {
  const _QuestionBody({
    required this.index,
    required this.total,
    required this.question,
    required this.answer,
    required this.onAnswer,
  });

  final int index;
  final int total;
  final MockQuestion question;
  final String answer;
  final ValueChanged<String> onAnswer;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            _TinyBadge(
              text: question.isSubjective
                  ? '主观题'
                  : (question.type == 'choice' ? '单选题' : question.type),
            ),
            if (question.difficulty != null) ...<Widget>[
              const SizedBox(width: 6),
              _TinyBadge(text: _difficultyLabel(question.difficulty!), muted: true),
            ],
            const Spacer(),
            Text(
              '${index + 1} / $total',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                color: AppColors.tertiaryLabel,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadii.card),
          ),
          child: Text(
            question.stem,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 17,
              height: 1.5,
              color: AppColors.label,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.cardGap),
        if (question.wantsFreeText)
          _FreeTextAnswer(answer: answer, onChanged: onAnswer)
        else
          _ChoiceAnswer(
            options: question.options,
            answer: answer,
            onChanged: onAnswer,
          ),
      ],
    );
  }

  static String _difficultyLabel(String d) => switch (d) {
        'easy' => '简单',
        'medium' => '中等',
        'hard' => '困难',
        _ => d,
      };
}

/// 选择题的选项列表（单选，选中态 = 边框 + 背景）。
class _ChoiceAnswer extends StatelessWidget {
  const _ChoiceAnswer({
    required this.options,
    required this.answer,
    required this.onChanged,
  });

  final List<MockOption> options;
  final String answer;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) {
      // 题型是 choice 但题库没给 options（脏数据）：退回自由输入，避免空白页
      return _FreeTextAnswer(answer: answer, onChanged: onChanged);
    }
    return Column(
      children: options.map((MockOption o) {
        final bool active = answer.trim().toUpperCase() == o.key.toUpperCase();
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(active ? '' : o.key),
            child: AnimatedContainer(
              duration: AppDurations.countdown,
              curve: Curves.easeInOut,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              decoration: BoxDecoration(
                color: active
                    ? AppColors.accent.withValues(alpha: 0.08)
                    : AppColors.card,
                borderRadius: BorderRadius.circular(AppRadii.card - 4),
                border: Border.all(
                  color: active ? AppColors.accent : AppColors.separator,
                  width: active ? 1.5 : 0.5,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _OptionKey(keyText: o.key, active: active),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      o.text,
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 15,
                        height: 1.4,
                        color: active ? AppColors.accent : AppColors.label,
                      ),
                    ),
                  ),
                  if (active)
                    const Icon(
                      CupertinoIcons.check_mark_circled_solid,
                      size: 18,
                      color: AppColors.accent,
                    ),
                ],
              ),
            ),
          ),
        );
      }).toList(growable: false),
    );
  }
}

class _OptionKey extends StatelessWidget {
  const _OptionKey({required this.keyText, required this.active});

  final String keyText;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? AppColors.accent : AppColors.groupedBackground,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        keyText,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: active ? CupertinoColors.white : AppColors.secondaryLabel,
        ),
      ),
    );
  }
}

/// 主观题 / 非选择题的作答框。
class _FreeTextAnswer extends StatefulWidget {
  const _FreeTextAnswer({required this.answer, required this.onChanged});

  final String answer;
  final ValueChanged<String> onChanged;

  @override
  State<_FreeTextAnswer> createState() => _FreeTextAnswerState();
}

class _FreeTextAnswerState extends State<_FreeTextAnswer> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.answer);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card - 4),
        border: Border.all(color: AppColors.separator, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: CupertinoTextField.borderless(
        controller: _controller,
        placeholder: '在此作答（主观题不参与自动判分）',
        placeholderStyle: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 15,
          color: AppColors.tertiaryLabel,
        ),
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 15,
          height: 1.45,
          color: AppColors.label,
        ),
        maxLines: 6,
        minLines: 4,
        padding: EdgeInsets.zero,
        onChanged: widget.onChanged,
      ),
    );
  }
}

/// 底部：上一题 / 题目点阵 / 下一题 + 交卷。
class _Footer extends StatelessWidget {
  const _Footer({
    required this.index,
    required this.total,
    required this.answered,
    required this.onPrev,
    required this.onNext,
    required this.onJump,
    required this.onSubmit,
    required this.answeredCount,
  });

  final int index;
  final int total;
  final List<bool> answered;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final ValueChanged<int> onJump;
  final VoidCallback? onSubmit;
  final int answeredCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.separator, width: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 10, AppSpacing.page, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 点阵：已答实心、未答描边；点一下直接跳题（50 题时靠 Wrap 换行）
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: List<Widget>.generate(total, (int i) {
              final bool done = answered[i];
              final bool active = i == index;
              return GestureDetector(
                onTap: () => onJump(i),
                child: Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: done
                        ? AppColors.accent.withValues(alpha: 0.14)
                        : CupertinoColors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: active
                          ? AppColors.accent
                          : (done ? AppColors.accent.withValues(alpha: 0.5) : AppColors.separator),
                      width: active ? 1.5 : 0.5,
                    ),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                      color: done || active ? AppColors.accent : AppColors.tertiaryLabel,
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  color: AppColors.groupedBackground,
                  borderRadius: BorderRadius.circular(AppRadii.chip + 4),
                  onPressed: onPrev,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Icon(CupertinoIcons.chevron_left, size: 16, color: AppColors.label),
                      SizedBox(width: 4),
                      Text(
                        '上一题',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: AppColors.label,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  color: AppColors.groupedBackground,
                  borderRadius: BorderRadius.circular(AppRadii.chip + 4),
                  onPressed: onNext,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        '下一题',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: onNext == null
                              ? AppColors.tertiaryLabel
                              : AppColors.label,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        CupertinoIcons.chevron_right,
                        size: 16,
                        color: onNext == null
                            ? AppColors.tertiaryLabel
                            : AppColors.label,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(AppRadii.chip + 4),
              padding: const EdgeInsets.symmetric(vertical: 12),
              onPressed: onSubmit,
              child: Text(
                '交卷（已答 $answeredCount / $total）',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TinyBadge extends StatelessWidget {
  const _TinyBadge({required this.text, this.muted = false});

  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final Color c = muted ? AppColors.secondaryLabel : AppColors.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.chip),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: c,
        ),
      ),
    );
  }
}

/// 顶部内联错误条（交卷失败时用）。
class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.overdue.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.chip + 2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              CupertinoIcons.exclamationmark_triangle_fill,
              size: 15,
              color: AppColors.overdue,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                height: 1.4,
                color: AppColors.label,
              ),
            ),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            onPressed: onRetry,
            child: const Text(
              '重试',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
