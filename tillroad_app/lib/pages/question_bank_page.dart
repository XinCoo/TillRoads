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
import '../pages/practice_config_page.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart' show EmptyState, SectionHeader;
import 'question_edit_page.dart';
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

  /// 掌握状态筛选（练习 R2）。
  ///
  /// 三档：全部 / 已掌握 / 未掌握。
  /// 注意「未掌握」是**标记过的**（mastered=false），
  /// 跟「从没标记过」（mastered=null）不是一回事 ——
  /// 后端 `mastered=false` 的过滤只回显真正标过「未掌握」的题。
  _MasteryFilter _masteryFilter = _MasteryFilter.all;


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
        mastered: _masteryFilter.masteredParam,
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

  /// 新建题目（FE-02）。建完回来刷新列表。
  Future<void> _openCreate() async {
    final bool? created = await Navigator.of(context).push<bool>(
      appRoute<bool>(context, const QuestionEditPage()),
    );
    if (created == true) await _load();
  }

  /// 「练习这批题」：带当前范围去练习配置页（练习模式 R1）。
  ///
  /// 题库页目前**没有**科目/考点筛选 UI（只有按科目分组的标题），
  /// 所以这里不预置范围 —— 练习配置页自己会列科目让用户选。
  Future<void> _openPractice() async {
    await Navigator.of(context).push<void>(
      appRoute<void>(context, const PracticeConfigPage()),
    );
  }


  /// 打开一道已有题的编辑页。
  ///
  /// 列表口径的 [BankQuestion] 不带 answer / analysis / version，
  /// 所以先拉详情（`GET /questions/:id`）再进编辑页；
  /// 顺带这一步也是「这题还在不在」的一次确认 —— 后端对别人的私有题返回 404。
  Future<void> _openEdit(BankQuestion question) async {
    try {
      final QuestionDetail detail = await _api.fetchQuestion(question.id);
      if (!mounted) return;
      final bool? changed = await Navigator.of(context).push<bool>(
        appRoute<bool>(context, QuestionEditPage(existing: detail)),
      );
      if (changed == true) await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      await _showMessage('打不开这道题', e.message);
    } catch (e) {
      if (!mounted) return;
      await _showMessage('打不开这道题', '加载详情失败：$e');
    }
  }

  /// 卡片上的「⋯」：编辑 / 删除。
  ///
  /// 删除要带 version（乐观锁），而列表没有这个字段，
  /// 所以删除前先拉一次详情拿 version —— 顺带避免「拿旧 version 去删」被判 409。
  Future<void> _openActions(BankQuestion question) async {
    final String? action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (BuildContext ctx) {
        return CupertinoActionSheet(
          title: const Text(
            '题目操作',
            style: TextStyle(fontFamily: kFontFamily, fontSize: 14),
          ),
          message: Text(
            question.preview,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.secondaryLabel,
            ),
          ),
          actions: <Widget>[
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(ctx).pop('edit'),
              child: const Text(
                '编辑',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(ctx).pop('delete'),
              child: const Text(
                '删除',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.overdue,
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
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    if (action == 'edit') {
      await _openEdit(question);
      return;
    }
    if (action == 'delete') {
      await _deleteQuestion(question);
    }
  }

  Future<void> _deleteQuestion(BankQuestion question) async {
    final bool confirmed = await _confirmDelete(question);
    if (!confirmed || !mounted) return;
    try {
      final QuestionDetail detail = await _api.fetchQuestion(question.id);
      await _api.deleteQuestion(id: detail.id, version: detail.version);
      if (!mounted) return;
      await _showMessage('已删除', '这道题已从题库移除。');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      final Object? body = e.body;
      final String code = body is Map && body['error'] != null
          ? '${body['error']}'
          : '';
      if (code == 'not_found') {
        await _showMessage(
          '删不掉',
          '只能删除自己建的题。公共题和别人的题不能删。',
        );
      } else if (code == 'conflict') {
        await _showMessage(
          '删除失败',
          '这道题在你打开期间被改过，请刷新列表后再试。',
        );
      } else {
        await _showMessage('删除失败', e.message);
      }
    } catch (e) {
      if (!mounted) return;
      await _showMessage('删除失败', '请求失败：$e');
    }
  }

  Future<bool> _confirmDelete(BankQuestion question) async {
    final bool? ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        return CupertinoAlertDialog(
          title: const Text(
            '删除这道题？',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppColors.overdue,
            ),
          ),
          content: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '删除后题库里就看不到它了。',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: AppColors.secondaryLabel,
              ),
            ),
          ),
          actions: <Widget>[
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text(
                '取消',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text(
                '删除',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppColors.overdue,
                ),
              ),
            ),
          ],
        );
      },
    );
    return ok == true;
  }

  Future<void> _showMessage(String title, String message) {
    return showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        return CupertinoAlertDialog(
          title: Text(
            title,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              message,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: AppColors.secondaryLabel,
              ),
            ),
          ),
          actions: <Widget>[
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text(
                '好',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
          ],
        );
      },
    );
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
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(36, 36),
                  onPressed: _openCreate,
                  child: const Text(
                    '建题',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 17,
                      color: AppColors.accent,
                    ),
                  ),
                ),
                CupertinoButton(
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
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(36, 36),
                  onPressed: _openPractice,
                  child: const Text(
                    '练习',
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
            message: '还没有题目。点右上角「建题」手动录一道，或用「导入」批量灌题。',
            actionLabel: '建第一道题',
            onAction: _openCreate,
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
    slivers.add(
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        sliver: SliverToBoxAdapter(child: _buildMasteryFilterRow()),
      ),
    );
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
                  child: _QuestionCard(
                    question: q,
                    onTap: () => _openEdit(q),
                    onMore: () => _openActions(q),
                  ),
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
  /// 掌握状态筛选行（练习 R2）：三颗 chip，点一下就重新拉列表。
  Widget _buildMasteryFilterRow() {
    return Row(
      children: <Widget>[
        for (final _MasteryFilter f in _MasteryFilter.values) ...<Widget>[
          _MasteryChip(
            label: f.label,
            selected: f == _masteryFilter,
            onTap: () {
              if (f == _masteryFilter) return;
              setState(() => _masteryFilter = f);
              _load();
            },
          ),
          const SizedBox(width: 8),
        ],
      ],
    );
  }
}

/// 一颗筛选 chip。
class _MasteryChip extends StatelessWidget {
  const _MasteryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      color: selected
          ? AppColors.accent.withValues(alpha: 0.14)
          : AppColors.card,
      borderRadius: BorderRadius.circular(AppRadii.chip),
      onPressed: onTap,
      child: Text(
        label,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 13,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? AppColors.accent : AppColors.secondaryLabel,
        ),
      ),
    );
  }
}

/// 一道题的卡片：题干前两行 + 题型徽标 + 来源徽标 + 「我的」标记。
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    this.onTap,
    this.onMore,
  });

  final BankQuestion question;
  final VoidCallback? onTap;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    // 题干 + 徽标。
    final Widget content = Column(
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
              _Tag(
                text: question.source == 'manual' ? '我建的' : '我导入的',
                color: AppColors.normal,
              ),
            ],
            // 掌握度徽标（练习 R2）：已掌握绿 / 未掌握橙 / 未标记不显示。
            if (question.mastered != null) ...<Widget>[
              const SizedBox(width: 6),
              _Tag(
                text: question.mastered! ? '已掌握' : '未掌握',
                color: question.mastered! ? AppColors.normal : AppColors.dueSoon,
              ),
            ],
          ],
        ),
      ],
    );

    final Widget card = Container(
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: content),
          if (onMore != null) ...<Widget>[
            const SizedBox(width: 8),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(28, 28),
              onPressed: onMore,
              child: const Icon(
                CupertinoIcons.ellipsis,
                size: 18,
                color: AppColors.secondaryLabel,
              ),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return card;

    // 整张卡片可点（去编辑页）；右上角「⋯」给「编辑 / 删除」动作表。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: card,
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

/// 掌握状态筛选（练习 R2）。
enum _MasteryFilter {
  all('全部', null),
  mastered('已掌握', true),
  unmastered('未掌握', false);

  const _MasteryFilter(this.label, this.masteredParam);

  /// 展示名。
  final String label;

  /// 传给后端的 `mastered` 参数（null = 不筛选）。
  final bool? masteredParam;
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
