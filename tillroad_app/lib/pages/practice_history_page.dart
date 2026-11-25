// 练习历史（练习 R1 · 任务 D1/D2）。
//
// 职责：列出自己的练习会话，点进去看每题对错，底部可「重做这次练习」。
//
// 归属：接口按 token 映射 userId，服务端只返回自己的会话，
// 所以这里不需要（也不应该）传 user_id。
import 'package:flutter/cupertino.dart';

import '../api/api_client.dart';
import '../api/practice_api.dart';
import '../theme/app_theme.dart';
import 'practice_config_page.dart';

class PracticeHistoryPage extends StatefulWidget {
  const PracticeHistoryPage({super.key});

  @override
  State<PracticeHistoryPage> createState() => _PracticeHistoryPageState();
}

class _PracticeHistoryPageState extends State<PracticeHistoryPage> {
  final PracticeApi _api = PracticeApi();

  List<PracticeSessionSummary> _sessions = const <PracticeSessionSummary>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<PracticeSessionSummary> list = await _api.listSessions();
      if (!mounted) return;
      setState(() {
        _sessions = list;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.isNetworkError
            ? '${e.message}\n请确认后端在运行，然后重试。'
            : e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      navigationBar: CupertinoNavigationBar(
        middle: const Text(
          '练习记录',
          style: TextStyle(fontFamily: kFontFamily, fontSize: 17),
        ),
        border: null,
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          onPressed: _loading ? null : _load,
          child: const Icon(CupertinoIcons.refresh, size: 20),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : _error != null
            ? _buildError()
            : _sessions.isEmpty
            ? _buildEmpty()
            : ListView.separated(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  16,
                  AppSpacing.page,
                  32,
                ),
                itemCount: _sessions.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (BuildContext context, int index) =>
                    _buildCard(_sessions[index]),
              ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(
              CupertinoIcons.wifi_exclamationmark,
              size: 40,
              color: AppColors.tertiaryLabel,
            ),
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                height: 1.5,
                color: AppColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(AppRadii.chip + 4),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
              onPressed: _load,
              child: const Text(
                '重试',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 15,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(
              CupertinoIcons.pencil_outline,
              size: 40,
              color: AppColors.tertiaryLabel,
            ),
            const SizedBox(height: 12),
            const Text(
              '还没有练习记录',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.label,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '做一组练习，提交后这里会留下记录。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                height: 1.5,
                color: AppColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(AppRadii.chip + 4),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
              onPressed: () => Navigator.of(context).push<void>(
                appRoute<void>(context, const PracticeConfigPage()),
              ),
              child: const Text(
                '开始练习',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 15,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(PracticeSessionSummary s) {
    final String when = s.createdAt == null
        ? '时间未知'
        : '${s.createdAt!.year}-${_two(s.createdAt!.month)}-${_two(s.createdAt!.day)} '
              '${_two(s.createdAt!.hour)}:${_two(s.createdAt!.minute)}';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push<void>(
        appRoute<void>(context, PracticeSessionDetailPage(sessionId: s.id)),
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '$when · ${s.total} 道题',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.label,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '答对 ${s.correct} · 答错 ${s.wrong} · 正确率 ${s.accuracy.toStringAsFixed(1)}%',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 13,
                      color: AppColors.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              CupertinoIcons.chevron_forward,
              size: 16,
              color: AppColors.tertiaryLabel,
            ),
          ],
        ),
      ),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

/// 单次练习详情（任务 D1 的「点击进详情」）。
///
/// 与「练习结果页」的区别：结果页是刚提交完的即时反馈（本地数据），
/// 这里是从服务端重新拉的历史记录 —— 所以逐题数据来自
/// `GET /practice-sessions/:id`。
class PracticeSessionDetailPage extends StatefulWidget {
  const PracticeSessionDetailPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  State<PracticeSessionDetailPage> createState() =>
      _PracticeSessionDetailPageState();
}

class _PracticeSessionDetailPageState extends State<PracticeSessionDetailPage> {
  final PracticeApi _api = PracticeApi();

  PracticeSessionDetail? _detail;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final PracticeSessionDetail d = await _api.fetchSession(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.isNetworkError
            ? '${e.message}\n请确认后端在运行，然后重试。'
            : e.message;
      });
    }
  }

  Future<void> _redo() async {
    // 「重做这次练习」：用同样的范围（科目/来源）重新抽题。
    final PracticeSessionDetail? d = _detail;
    await Navigator.of(context).push<void>(
      appRoute<void>(
        context,
        PracticeConfigPage(
          initialSubjectId: d?.session.subjectId,
          initialKnowledgeNodeId: d?.session.knowledgeNodeId,
          initialSource: PracticeSource.fromWire(d?.session.source),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      navigationBar: const CupertinoNavigationBar(
        middle: Text(
          '练习详情',
          style: TextStyle(fontFamily: kFontFamily, fontSize: 17),
        ),
        border: null,
      ),
      child: SafeArea(
        bottom: false,
        child: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 14,
                      height: 1.5,
                      color: AppColors.secondaryLabel,
                    ),
                  ),
                ),
              )
            : _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final PracticeSessionDetail d = _detail!;
    final PracticeSessionSummary s = d.session;
    return ListView(
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
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadii.card),
          ),
          child: Row(
            children: <Widget>[
              _cell('答对', '${s.correct}', AppColors.normal),
              _cell('答错', '${s.wrong}', AppColors.overdue),
              _cell('总题数', '${s.total}', AppColors.label),
              _cell(
                '正确率',
                '${s.accuracy.toStringAsFixed(1)}%',
                AppColors.accent,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (d.answers.isEmpty)
          const Text(
            '这次练习没有留下作答明细。',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.secondaryLabel,
            ),
          ),
        ...d.answers.map(_buildAnswer),
        const SizedBox(height: 24),
        CupertinoButton(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(AppRadii.chip + 4),
          padding: const EdgeInsets.symmetric(vertical: 13),
          onPressed: _redo,
          child: const Text(
            '重做这次练习',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _cell(String label, String value, Color color) {
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 20,
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

  Widget _buildAnswer(PracticeAnswerRecord a) {
    final Color color = a.isCorrect == true
        ? AppColors.normal
        : a.isCorrect == false
        ? AppColors.overdue
        : AppColors.secondaryLabel;
    final String badge = a.isCorrect == true
        ? '答对'
        : a.isCorrect == false
        ? '答错'
        : '未判定';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    a.stem,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 14,
                      height: 1.5,
                      color: AppColors.label,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  badge,
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '你的答案：${(a.userAnswer == null || a.userAnswer!.isEmpty) ? '未作答' : a.userAnswer}',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                color: AppColors.secondaryLabel,
              ),
            ),
            if (a.correctAnswer != null && a.correctAnswer!.isNotEmpty)
              Text(
                '正确答案：${a.correctAnswer}',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  color: AppColors.secondaryLabel,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
