// 题库列表页（m17431）。
//
// ── 这一页解决什么问题 ──────────────────────────────────────────────────
// 分发前的阻塞项：测试人员装上 APK 后只能看到预置的 9 条缺陷单，
// 没法把自己的题导进来。后端 BE-02 的导入管线早就有了
// （POST /questions/import，支持 md/txt/csv/pdf/xlsx），
// 但前端从来没有入口。本页是那个入口的落地点：列出「我能看到的题」，
// 右上角一个「导入」按钮跳到导入页。
//
// ── 可见范围与后端一致 ──────────────────────────────────────────────────
// `GET /questions` 只返回**公共题 + 当前 token 用户自己的题**，
// 别人的私有题根本不会出现在响应里。所以本页不需要（也不应该）
// 在前端再做一次 owner 过滤 —— 重复实现一遍只会引入不一致。
//
// ── 为什么按科目分组 ────────────────────────────────────────────────────
// 题是按科目组织的（后端 questions.subject_id → exam_profiles）。
// 用 CupertinoListSection 分组，跟 iOS 设置页的观感一致，
// 也让「我导的题属于哪一科」一眼可见。
//
// ── 本页不走本地优先 ────────────────────────────────────────────────────
// 题库是低频操作（一次导入看一次），而本地缓存 questions_cache 是
// R5 才定的设计。题量也不大（一次拉 50 条），每次从云端拉更简单，
// 不会出现「本地缓存了旧题库、与云端不一致」的困惑。

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
import '../api/defect_api.dart';
import '../api/question_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart' show EmptyState, SectionHeader;
import 'question_import_page.dart';

class QuestionBankPage extends StatefulWidget {
  const QuestionBankPage({super.key});

  @override
  State<QuestionBankPage> createState() => _QuestionBankPageState();
}

class _QuestionBankPageState extends State<QuestionBankPage> {
  final QuestionApi _api = QuestionApi();

  List<BankQuestion> _questions = const <BankQuestion>[];
  bool _loading = true;
  String? _error;

  /// 科目 id → 科目名（用于分组标题）。
  Map<String, String> _subjectNames = const <String, String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<BankQuestion> list = await _api.fetchQuestions(
        limit: 50,
        currentUserId: kDemoUserId,
      );
      final Map<String, String> names = await _loadSubjectNames();
      if (!mounted) return;
      setState(() {
        _questions = list;
        _subjectNames = names;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '题库加载失败：$e';
        _loading = false;
      });
    }
  }

  /// 拉科目名用于分组。拉不到不影响主流程 —— 分组退化成「未分科」。
  Future<Map<String, String>> _loadSubjectNames() async {
    try {
      final DefectApi helper = DefectApi();
      final List<Map<String, Object?>> profiles = await helper.fetchExamProfiles(
        kDemoUserId,
      );
      final Map<String, String> names = <String, String>{};
      for (final Map<String, Object?> profile in profiles) {
        final String profileId = '${profile['id'] ?? ''}';
        if (profileId.isEmpty) continue;
        final List<Map<String, Object?>> subjects = await helper.fetchSubjects(
          profileId,
        );
        for (final Map<String, Object?> subject in subjects) {
          final String id = '${subject['id'] ?? ''}';
          final String name = '${subject['name'] ?? subject['title'] ?? ''}';
          if (id.isNotEmpty && name.isNotEmpty) names[id] = name;
        }
      }
      return names;
    } catch (_) {
      return const <String, String>{};
    }
  }

  Future<void> _openImport() async {
    final bool? changed = await Navigator.of(context).push<bool>(
      appRoute<bool>(context, const QuestionImportPage()),
    );
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: const Text(
              '题库',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                color: AppColors.label,
              ),
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(36, 36),
              onPressed: _openImport,
              child: const Text(
                '导入',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
          ),
          ..._buildBody(),
        ],
      ),
    );
  }

  List<Widget> _buildBody() {
    if (_loading) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CupertinoActivityIndicator(radius: 12)),
        ),
      ];
    }

    if (_error != null) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _ErrorView(message: _error!, onRetry: _load),
        ),
      ];
    }

    if (_questions.isEmpty) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: CupertinoIcons.doc_text,
            title: '还没有题目',
            message: '还没有题目，点右上角导入',
            actionLabel: '导入题目',
            onAction: _openImport,
          ),
        ),
      ];
    }

    // 按科目分组；没有科目的题归到「未分科」。
    final Map<String, List<BankQuestion>> groups = <String, List<BankQuestion>>{};
    for (final BankQuestion q in _questions) {
      final String key = q.subjectId.isEmpty ? '' : q.subjectId;
      groups.putIfAbsent(key, () => <BankQuestion>[]).add(q);
    }

    final List<Widget> slivers = <Widget>[];
    for (final MapEntry<String, List<BankQuestion>> entry in groups.entries) {
      final String title = entry.key.isEmpty
          ? '未分科'
          : (_subjectNames[entry.key] ?? '未分科');
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverToBoxAdapter(
            child: SectionHeader(
              text: title,
              trailing: Text(
                '${entry.value.length} 题',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  color: AppColors.secondaryLabel,
                ),
              ),
            ),
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          sliver: SliverList.list(
            children: <Widget>[
              for (final BankQuestion q in entry.value)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _QuestionCard(question: q),
                ),
            ],
          ),
        ),
      );
    }

    slivers.add(
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    );
    return slivers;
  }
}

/// 一道题的卡片：题干前两行 + 题型徽标 + 来源徽标 + 「我的」标记。
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({required this.question});

  final BankQuestion question;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 12,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            question.preview,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              height: 1.4,
              color: AppColors.label,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              _Tag(text: question.typeLabel, color: AppColors.accent),
              const SizedBox(width: 6),
              _Tag(text: question.sourceLabel, color: AppColors.secondaryLabel),
              if (question.isMine) ...<Widget>[
                const SizedBox(width: 6),
                const _Tag(text: '我导入的', color: AppColors.normal),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 小徽标（题型 / 来源 / 归属）。
class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.chip),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 11,
          color: color,
        ),
      ),
    );
  }
}

/// 错误态：可重试。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              CupertinoIcons.exclamationmark_triangle,
              size: 40,
              color: AppColors.dueSoon,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                color: AppColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton(
              onPressed: () {
                onRetry();
              },
              child: const Text(
                '重试',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
