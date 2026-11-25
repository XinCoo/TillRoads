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
//    概要。掌握度标记（R2）还没做，这里刻意不做。
import 'package:flutter/cupertino.dart';

import '../api/practice_api.dart';
import '../theme/app_theme.dart';
import '../widgets/form_field.dart';
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
                child: Text(
                  q.stem,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    height: 1.5,
                    color: AppColors.label,
                  ),
                ),
              );
            }),
        ],
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
