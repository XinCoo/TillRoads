// 练习结果页（练习 R1 · 任务 C3）。
//
// 职责：展示本次练习的分数、错题与对题，并提供「去归因」入口。
//
// ── 三条设计决定 ──────────────────────────────────────────────────────────
// 1) **统计以服务端为准**：页面顶部的 correct/total/accuracy 用
//    `POST /practice-sessions` 返回值，不用客户端本地算的 —— 服务端才是
//    真正的账本（本地判分只是为了让用户立刻看到反馈）。
// 2) **错题可一键归因**：错题卡上的「去归因」直接跳建单页，
//    并把 question_id 与「练习中未掌握」预填进去 —— 用户不用再选一次题、
//    也不用重写错因。这一步是练习模式与缺陷单闭环的接口。
// 3) **对题折叠**：对题没有错因要写，默认折叠，只给一个「已答对 N 道」的
//    概要。练习 R2 在展开后的每道对题上加了「已掌握 / 未掌握」标记按钮 ——
//    用户答对之后最想做的事就是「记住了」，让这一步立刻落地。
import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
import '../api/defect_api.dart';
import '../api/practice_api.dart';
import '../api/question_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import 'defect_create_page.dart';

class PracticeResultPage extends StatefulWidget {
  const PracticeResultPage({
    super.key,
    required this.sessionId,
    required this.questions,
    required this.states,
    required this.submitResult,
    required this.source,
    this.subjectId,
    this.knowledgeNodeId,
    this.examProfileId,
    this.subjectName,
  });

  final String sessionId;
  final List<PracticeQuestion> questions;
  final List<PracticeLocalAnswer> states;
  final PracticeSubmitResult submitResult;
  final PracticeSource source;
  final String? subjectId;
  final String? knowledgeNodeId;
  final String? examProfileId;
  final String? subjectName;

  @override
  State<PracticeResultPage> createState() => _PracticeResultPageState();
}

class _PracticeResultPageState extends State<PracticeResultPage> {
  bool _showRight = false;

  /// 掌握度标记（练习 R2）：question_id → true(已掌握) / false(未掌握)。
  ///
  /// 初始为空 —— 页面刚进来时并不预取掌握度（那要多发一次列表请求），
  /// 用户点按钮时才知道真值。标记成功的题会写进这里，按钮状态立刻变。
  final Map<String, bool> _mastery = <String, bool>{};

  /// 正在标记中的题（防止重复点）。
  final Set<String> _marking = <String>{};

  final QuestionApi _questionApi = QuestionApi();
  final DefectApi _defectApi = DefectApi();

  @override
  void dispose() {
    _questionApi.close();
    _defectApi.close();
    super.dispose();
  }

  PracticeQuestion _questionOf(String questionId) {
    for (final PracticeQuestion q in widget.questions) {
      if (q.id == questionId) return q;
    }
    return const PracticeQuestion(id: '', stem: '', type: '');
  }

  List<PracticeLocalAnswer> get _wrong {
    return widget.states
        .where((PracticeLocalAnswer a) => a.isCorrect == false)
        .toList(growable: false);
  }

  List<PracticeLocalAnswer> get _right {
    return widget.states
        .where((PracticeLocalAnswer a) => a.isCorrect == true)
        .toList(growable: false);
  }

  List<PracticeLocalAnswer> get _unjudged {
    return widget.states
        .where((PracticeLocalAnswer a) => a.isCorrect == null)
        .toList(growable: false);
  }

  /// 「去归因」：跳建单页，把题目和错因预填好。
  Future<void> _goAttribute(PracticeLocalAnswer a) async {
    final PracticeQuestion q = _questionOf(a.questionId);
    if (widget.examProfileId == null ||
        widget.subjectId == null ||
        widget.subjectName == null) {
      _showMessage(
        '还不能建单',
        '这次练习没有关联科目。先在「考试配置」里给科目建好考点，'
        '再来这里把错题归因。',
      );
      return;
    }
    await Navigator.of(context).push<void>(
      appRoute<void>(
        context,
        DefectCreatePage(
          examProfileId: widget.examProfileId!,
          subjectId: widget.subjectId!,
          subjectName: widget.subjectName!,
          initialQuestionId: a.questionId,
          initialErrorCause: '练习中未掌握',
          initialQType: q.stem.isEmpty ? null : q.stem,
        ),
      ),
    );
  }

  /// 「标记已掌握」（练习 R2）：PATCH mastery(true)。
  ///
  /// 后端只允许标记自己的题；公共题会 403 —— 那时提示用户
  /// 「公共题不能标记」，而不是静默失败。
  Future<void> _markMastered(PracticeLocalAnswer a) async {
    if (_marking.contains(a.questionId)) return;
    setState(() => _marking.add(a.questionId));
    try {
      await _questionApi.setMastery(id: a.questionId, mastered: true);
      if (!mounted) return;
      setState(() => _mastery[a.questionId] = true);
    } on ApiException catch (e) {
      if (!mounted) return;
      _showMessage('标记失败', _masteryErrorText(e));
    } finally {
      if (mounted) setState(() => _marking.remove(a.questionId));
    }
  }

  /// 「标记未掌握」（练习 R2）：确认后 PATCH mastery(false) + 自动建缺陷单。
  ///
  /// 为什么自动建单：用户点「未掌握」的意思就是「这道题我没掌握」，
  /// 而缺陷单就是「未掌握的题」的载体。让这一步顺手完成，比让用户
  /// 自己去缺陷单页再选一次题省事得多。
  Future<void> _markUnmastered(PracticeLocalAnswer a) async {
    if (_marking.contains(a.questionId)) return;
    final PracticeQuestion q = _questionOf(a.questionId);
    final bool ok = await _confirm(
      '将创建一条缺陷单，并标记该题未掌握',
      '这道题会进入你的「未掌握」列表，并自动建一条缺陷单。\n'
      '之后可以在缺陷单里补充具体错因。',
    );
    if (!ok || !mounted) return;

    setState(() => _marking.add(a.questionId));
    try {
      await _questionApi.setMastery(id: a.questionId, mastered: false);
      await _createDefectForUnmastered(q);
      if (!mounted) return;
      setState(() => _mastery[a.questionId] = false);
    } on ApiException catch (e) {
      if (!mounted) return;
      _showMessage('操作失败', _masteryErrorText(e));
    } finally {
      if (mounted) setState(() => _marking.remove(a.questionId));
    }
  }

  /// 给未掌握的题自动建一条缺陷单（question_id 带上，错因预填）。
  Future<void> _createDefectForUnmastered(PracticeQuestion q) async {
    if (widget.examProfileId == null ||
        widget.subjectId == null ||
        widget.subjectName == null) {
      _showMessage(
        '未标记',
        '这道题已标为未掌握，但没能建缺陷单：'
        '这次练习没有关联科目。先在「考试配置」里给科目建好考点，再来归因。',
      );
      return;
    }
    await _defectApi.createDefectTicket(
      userId: kDemoUserId,
      examProfileId: widget.examProfileId!,
      qType: q.stem.isEmpty ? '练习题' : q.stem,
      errorCause: '练习中未掌握，需复习',
      errorLayer: kPracticeDefaultErrorLayer,
      questionId: q.id,
      priority: 'P1',
    );
  }

  /// 「全部标记已掌握」（练习 R2）：把展开后的对题批量标为已掌握。
  Future<void> _markAllMastered() async {
    final List<PracticeLocalAnswer> pending = _right
        .where((PracticeLocalAnswer a) =>
            _mastery[a.questionId] == null &&
            _questionOf(a.questionId).isMine)
        .toList(growable: false);
    if (pending.isEmpty) {
      _showMessage('无需标记', '本次答对的题都已经标为「已掌握」了。');
      return;
    }
    int ok = 0;
    int failed = 0;
    for (final PracticeLocalAnswer a in pending) {
      try {
        await _questionApi.setMastery(id: a.questionId, mastered: true);
        _mastery[a.questionId] = true;
        ok += 1;
      } on ApiException {
        failed += 1;
      }
    }
    if (!mounted) return;
    setState(() {});
    if (failed == 0) {
      _showMessage('已标记', '已把 $ok 道答对的题标为「已掌握」。');
    } else {
      _showMessage('部分成功', '$ok 道已标记，$failed 道没成功（可能是公共题）。');
    }
  }

  /// 掌握度相关的错误文案。
  String _masteryErrorText(ApiException e) {
    final Object? body = e.body;
    final String code =
        body is Map && body['error'] != null ? '${body['error']}' : '';
    if (code == 'FORBIDDEN_MASTERY') {
      return '公共题不能标记掌握度 —— 这道题是别人上传的，标记只会影响你自己。\n'
          '（实际后端仍会拒绝，所以这里如实告诉你不行。）';
    }
    if (e.statusCode == 403) return '这道题不属于你，不能标记掌握度。';
    return e.message;
  }

  /// 确认弹窗（返回 true 表示用户点了确认）。
  Future<bool> _confirm(String title, String message) async {
    final bool? result = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: Text(title, style: const TextStyle(fontFamily: kFontFamily)),
        content: Text(
          message,
          style: const TextStyle(fontFamily: kFontFamily, fontSize: 14),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(fontFamily: kFontFamily)),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定', style: TextStyle(fontFamily: kFontFamily)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _retry() async {
    // 「再练一次」：回到配置页重新抽题（题目是随机的，重抽更有意义）。
    Navigator.of(context).popUntil((Route<void> route) => route.isFirst);
  }

  void _showMessage(String title, String message) {
    showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: Text(title, style: const TextStyle(fontFamily: kFontFamily)),
        content: Text(
          message,
          style: const TextStyle(fontFamily: kFontFamily, fontSize: 14),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了', style: TextStyle(fontFamily: kFontFamily)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final PracticeSubmitResult r = widget.submitResult;
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      navigationBar: const CupertinoNavigationBar(
        middle: Text(
          '练习结果',
          style: TextStyle(fontFamily: kFontFamily, fontSize: 17),
        ),
        border: null,
      ),
      child: SafeArea(
        bottom: false,
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            16,
            AppSpacing.page,
            32,
          ),
          children: <Widget>[
            _buildScoreCard(r),
            const SizedBox(height: 20),
            if (_wrong.isNotEmpty) ...<Widget>[
              _buildSectionTitle('错题（${_wrong.length}）'),
              const SizedBox(height: 8),
              ..._wrong.map(_buildWrongCard),
              const SizedBox(height: 16),
            ],
            if (_unjudged.isNotEmpty) ...<Widget>[
              _buildSectionTitle('未判定（${_unjudged.length}）'),
              const SizedBox(height: 8),
              _buildUnjudgedCard(),
              const SizedBox(height: 16),
            ],
            _buildSectionTitle('答对的题（${_right.length}）'),
            const SizedBox(height: 8),
            _buildRightCard(),
            if (_right.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              _buildBatchMasteryButton(),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 28),
            _buildBottomButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreCard(PracticeSubmitResult r) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Column(
        children: <Widget>[
          Text(
            '${r.accuracy.toStringAsFixed(1)}%',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 40,
              fontWeight: FontWeight.w700,
              color: AppColors.label,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '本次练习正确率',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              _scoreCell('答对', '${r.correct}', AppColors.normal),
              _scoreCell('答错', '${r.wrong}', AppColors.overdue),
              _scoreCell('未判定', '${r.unjudged}', AppColors.secondaryLabel),
              _scoreCell('总题数', '${r.total}', AppColors.label),
            ],
          ),
        ],
      ),
    );
  }

  Widget _scoreCell(String label, String value, Color color) {
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: kFontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppColors.label,
      ),
    );
  }

  Widget _buildWrongCard(PracticeLocalAnswer a) {
    final PracticeQuestion q = _questionOf(a.questionId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadii.card),
          border: Border.all(
            color: AppColors.overdue.withValues(alpha: 0.35),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              q.stem,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 15,
                height: 1.5,
                color: AppColors.label,
              ),
            ),
            const SizedBox(height: 10),
            _answerRow('你的答案', a.userAnswer, AppColors.overdue),
            if (a.correctAnswer != null && a.correctAnswer!.isNotEmpty)
              _answerRow('正确答案', a.correctAnswer, AppColors.normal),
            if (!a.hasAnswer)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '这道题没有标准答案（公共题），对错由你自己评。',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    color: AppColors.secondaryLabel,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(AppRadii.chip + 4),
                onPressed: () => _goAttribute(a),
                child: const Text(
                  '去归因',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _answerRow(String label, String? value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$label：',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.secondaryLabel,
            ),
          ),
          Text(
            (value == null || value.isEmpty) ? '未作答' : value,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: (value == null || value.isEmpty)
                  ? AppColors.tertiaryLabel
                  : color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnjudgedCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: const Text(
        '这些题没有作答，或公共题还没自评对错，因此不计入正确率。',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 13,
          height: 1.5,
          color: AppColors.secondaryLabel,
        ),
      ),
    );
  }

  Widget _buildRightCard() {
    if (_right.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: const Text(
          '这次没有答对的题。',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            color: AppColors.secondaryLabel,
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Column(
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showRight = !_showRight),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      '展开查看答对的题',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 14,
                        color: AppColors.label,
                      ),
                    ),
                  ),
                  Icon(
                    _showRight
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    size: 18,
                    color: AppColors.secondaryLabel,
                  ),
                ],
              ),
            ),
          ),
          if (_showRight)
            ..._right.map((PracticeLocalAnswer a) {
              final PracticeQuestion q = _questionOf(a.questionId);
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: AppColors.separator, width: 0.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      q.stem,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 13,
                        height: 1.5,
                        color: AppColors.label,
                      ),
                    ),
                    // 掌握度标记只对自己的题开放（公共题是别人上传的，
                    // 后端会 403，所以干脆不显示按钮）。
                    if (q.isMine) ...<Widget>[
                      const SizedBox(height: 8),
                      _buildMasteryRow(a),
                    ],
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
  /// 单题掌握度标记行：「已掌握 / 未掌握」两个按钮。
  Widget _buildMasteryRow(PracticeLocalAnswer a) {
    final bool? marked = _mastery[a.questionId];
    final bool busy = _marking.contains(a.questionId);
    if (busy) {
      return Row(
        children: <Widget>[
          const CupertinoActivityIndicator(radius: 7),
          const SizedBox(width: 8),
          const Text(
            '标记中…',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
        ],
      );
    }
    if (marked == true) {
      return Row(
        children: <Widget>[
          const Icon(
            CupertinoIcons.checkmark_seal_fill,
            size: 16,
            color: AppColors.normal,
          ),
          const SizedBox(width: 6),
          const Text(
            '✓ 已掌握',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.normal,
            ),
          ),
        ],
      );
    }
    if (marked == false) {
      return Row(
        children: <Widget>[
          const Icon(
            CupertinoIcons.clock,
            size: 16,
            color: AppColors.dueSoon,
          ),
          const SizedBox(width: 6),
          const Text(
            '待复习',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.dueSoon,
            ),
          ),
        ],
      );
    }
    return Row(
      children: <Widget>[
        _masteryButton(
          label: '已掌握',
          color: AppColors.normal,
          onPressed: () => _markMastered(a),
        ),
        const SizedBox(width: 8),
        _masteryButton(
          label: '未掌握',
          color: AppColors.dueSoon,
          onPressed: () => _markUnmastered(a),
        ),
      ],
    );
  }

  Widget _masteryButton({
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(AppRadii.chip),
      onPressed: onPressed,
      child: Text(
        label,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  /// 「全部标记已掌握」批量按钮。
  Widget _buildBatchMasteryButton() {
    return SizedBox(
      width: double.infinity,
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(vertical: 11),
        color: AppColors.normal.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.chip + 4),
        onPressed: _markAllMastered,
        child: const Text(
          '全部标记已掌握',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildBottomButtons() {
    return Row(
      children: <Widget>[
        Expanded(
          child: CupertinoButton(
            padding: const EdgeInsets.symmetric(vertical: 13),
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(AppRadii.chip + 4),
            onPressed: _retry,
            child: const Text(
              '再练一次',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.white,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: CupertinoButton(
            padding: const EdgeInsets.symmetric(vertical: 13),
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadii.chip + 4),
            onPressed: () =>
                Navigator.of(context).popUntil((Route<void> route) => route.isFirst),
            child: const Text(
              '返回首页',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 16,
                color: AppColors.accent,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
