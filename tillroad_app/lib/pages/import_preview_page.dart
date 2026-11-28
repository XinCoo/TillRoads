// 题库导入「预检」页（m23700 题库导入预检 + 批量决策）。
//
// ── 这一页解决什么问题 ───────────────────────────────────────────────────
// 原来点「开始导入」就是把文件直接怼给后端，用户看不到这次到底会发生什么：
// 有多少道会新进库、多少道撞了库里已有的题（被静默跳过）、哪些条目根本
// 解析不出来。等看到结果页时，库已经被改（或没改）了，没有反悔的机会。
//
// 现在拆成两步：
//   1. 本页调 `POST /questions/import/preview`（**不写库**）拿预检结果；
//   2. 用户看清「新题 N / 重复 M / 解析失败 K」并决定重复题怎么处理
//      （全部跳过 / 全部覆盖），点确认后 pop 回决策字符串；
//      真正的导入由 `QuestionImportPage._upload(duplicateAction)` 执行。
//
// ── 为什么 pop 出去才导入 ────────────────────────────────────────────────
// 导入的三态进度（编码 → 服务端处理 → 完成）与结果页已经做在
// `question_import_page.dart` 里了。本页只管「看清单 + 做决定」，
// 不重复造一套进度 UI，也不搬结果页 —— 改动面最小，且两页职责清楚。
//
// ── 为什么不用 Material ──────────────────────────────────────────────────
// 整个工程是纯 Cupertino（无 Material 依赖）。`ExpansionTile`、`RadioListTile`
// 这些便利组件都在 Material 里，所以「重复处理」的单选行与「查看重复题目」
// 的展开列表都在这页里自己写。
import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiClient, ApiException;
import '../api/question_api.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart' show SectionHeader;

/// 导入预检页。
///
/// 参数就是「这次打算导入什么」的完整快照 —— 页面自己不读文件、不看全局状态，
/// 只把这份快照发给预检端点，所以好测（可注入 [api]）。
class ImportPreviewPage extends StatefulWidget {
  const ImportPreviewPage({
    super.key,
    required this.filename,
    required this.contentBase64,
    this.mime,
    this.subjectId,
    this.knowledgeNodeId,
    this.subjectMode = 'uniform',
    this.fileBytes = 0,
    this.api,
  });

  final String filename;
  final String contentBase64;
  final String? mime;
  final String? subjectId;
  final String? knowledgeNodeId;
  final String subjectMode;

  /// 文件大小（字节），只用于页头展示。
  final int fileBytes;

  /// 可注入的 API（测试用）；为 null 时本页自建并在 dispose 关闭。
  final QuestionApi? api;

  @override
  State<ImportPreviewPage> createState() => _ImportPreviewPageState();
}

class _ImportPreviewPageState extends State<ImportPreviewPage> {
  /// 预检要等后端把整份文件解析一遍（切题 + 逐条算指纹 + 查重），
  /// 大文件比导入本身只慢一点，所以同样给 60s —— 与导入页保持同一口径，
  /// 不要用全局 15s（会误报「超时」）。
  QuestionApi? _ownedApi;

  QuestionApi get _api =>
      widget.api ??
      (_ownedApi ??= QuestionApi(
        client: ApiClient(timeout: const Duration(seconds: 60)),
      ));

  bool _loading = true;
  String? _error;
  ImportPreviewResult? _result;

  /// 重复题的展开状态。
  bool _expanded = false;

  /// 用户选的重复处理决策：`skip`（默认）/ `overwrite`。
  String _duplicateAction = 'skip';

  @override
  void initState() {
    super.initState();
    _preview();
  }

  @override
  void dispose() {
    // 只关自己建的 client；注入进来的由调用方负责。
    _ownedApi?.close();
    super.dispose();
  }

  Future<void> _preview() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ImportPreviewResult result = await _api.previewImport(
        filename: widget.filename,
        contentBase64: widget.contentBase64,
        mime: widget.mime,
        subjectId: widget.subjectId,
        knowledgeNodeId: widget.knowledgeNodeId,
        subjectMode: widget.subjectMode,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
        // 预检结果变了，展开状态与决策都回到默认，避免用户对着上一份清单做的
        // 选择被默默保留到这一次（尤其是重试之后）。
        _expanded = false;
        _duplicateAction = 'skip';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(e);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '预检失败：$e';
        _loading = false;
      });
    }
  }

  /// 把后端错误码翻成人话（与导入页 `_friendlyError` 同口径的子集）。
  ///
  /// 预检失败的原因比导入少：它不写库，所以不会有「部分写入」这种歧义，
  /// 可以放心让用户直接重试。
  String _friendlyError(ApiException e) {
    final int code = e.statusCode ?? 0;
    final String body = e.body is Map ? '${(e.body! as Map)['error'] ?? ''}' : '';
    if (code == 413) {
      return '文件太大（后端限制 10MB），请拆分成多份再导入。';
    }
    if (code == 415) {
      return '不支持的文件格式：${widget.filename}';
    }
    if (code == 422) {
      if (body.contains('PDF')) {
        return '这份 PDF 是扫描件（没有文字层），请改成文字版或用 txt/md 上传。';
      }
      return '这个文件里有后端不支持的内容（扫描版 PDF / 图片 / 复杂 xlsx），请换成 md/txt/csv。';
    }
    if (code == 400) {
      if (body.contains('EMPTY_CONTENT')) {
        return '没从文件里切出任何题目，请检查是否包含题号与题干。';
      }
      return '预检失败，请检查题号格式（例如「1.」「第1题」「1、」）。';
    }
    return e.message;
  }

  void _confirm() {
    final ImportPreviewResult? result = _result;
    if (result == null) return;
    // 没有重复题时决策无所谓（后端收到 skip 也是同样的行为），
    // 统一回 `skip`，调用方不必为此分支。
    final String decision =
        result.hasDuplicates && _duplicateAction == 'overwrite' ? 'overwrite' : 'skip';
    Navigator.of(context).pop<String>(decision);
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      // 注意：这里**必须**用 CustomScrollView + CupertinoSliverNavigationBar。
      // 用 `navigationBar:` 参数时导航栏会叠在内容上方，长列表会被遮住一截。
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            previousPageTitle: '返回',
            largeTitle: const Text(
              '导入预检',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                color: AppColors.label,
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
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                CupertinoActivityIndicator(radius: 12),
                SizedBox(height: 12),
                Text(
                  '正在预检文件…',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 15,
                    color: AppColors.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
        ),
      ];
    }

    final String? error = _error;
    if (error != null) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.page),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(
                  CupertinoIcons.exclamationmark_triangle,
                  size: 40,
                  color: AppColors.dueSoon,
                ),
                const SizedBox(height: 12),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 15,
                    height: 1.4,
                    color: AppColors.label,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: CupertinoButton.filled(
                    onPressed: _preview,
                    child: const Text(
                      '重试',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 17,
                        color: CupertinoColors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                CupertinoButton(
                  onPressed: () => Navigator.of(context).pop<String>(),
                  child: const Text(
                    '返回',
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
        ),
      ];
    }

    return _buildPreview(_result ?? const ImportPreviewResult());
  }

  List<Widget> _buildPreview(ImportPreviewResult result) {
    return <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.page,
          AppSpacing.page,
          32,
        ),
        sliver: SliverList(
          delegate: SliverChildListDelegate(<Widget>[
            _FileHeader(
              filename: widget.filename,
              fileBytes: widget.fileBytes,
            ),
            const SizedBox(height: AppSpacing.cardGap),
            _SummaryCard(result: result),
            // ── 没有重复题：不需要「怎么处理重复」这一组 ───────────────────
            if (result.hasDuplicates) ...<Widget>[
              const SizedBox(height: 16),
              const SectionHeader(text: '重复处理'),
              _CardBox(
                child: Column(
                  children: <Widget>[
                    _ChoiceRow(
                      selected: _duplicateAction == 'skip',
                      title: '全部跳过',
                      subtitle: '库里已有的题保持原样，只导入新题。',
                      onTap: () => setState(() => _duplicateAction = 'skip'),
                    ),
                    // 纯 Cupertino 工程没有 Material 的 Divider，用 0.5px 的 ColoredBox 画分隔线。
                    Container(
                      height: 0.5,
                      color: AppColors.separator,
                    ),
                    _ChoiceRow(
                      selected: _duplicateAction == 'overwrite',
                      title: '全部覆盖',
                      subtitle: '用文件里的内容更新库里同题（题干、选项、答案都会被替换）。',
                      onTap: () => setState(() => _duplicateAction = 'overwrite'),
                    ),
                  ],
                ),
              ),
              if (_duplicateAction == 'overwrite') ...<Widget>[
                const SizedBox(height: 8),
                const _NoticeCard(
                  icon: CupertinoIcons.arrow_counterclockwise,
                  color: AppColors.dueSoon,
                  text: '覆盖会改写库里已有的题，无法一键撤销。如果只是补新题，建议选「全部跳过」。',
                ),
              ],
              const SizedBox(height: 16),
              _DuplicatesSection(
                duplicates: result.duplicates,
                duplicateCount: result.duplicateCount,
                expanded: _expanded,
                onToggle: () => setState(() => _expanded = !_expanded),
              ),
            ],
            if (!result.hasDuplicates) ...<Widget>[
              const SizedBox(height: 16),
              _CardBox(
                child: Text(
                  result.isEmptyFile
                      ? '这份文件里没有解析出可用的题目。'
                      : '这份文件里的题目库里都没有，会全部作为新题导入。',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 14,
                    height: 1.5,
                    color: AppColors.secondaryLabel,
                  ),
                ),
              ),
            ],
            // ── 解析失败的条目：属于「这次不会导进去的部分」，单独告警 ────
            if (result.parseErrors.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              _ParseErrorCard(messages: result.parseErrors),
            ],
            const SizedBox(height: 24),
            _buildActions(result),
          ]),
        ),
      ),
    ];
  }

  Widget _buildActions(ImportPreviewResult result) {
    final String label;
    if (!result.hasDuplicates) {
      label = '确认导入 ${result.newCount} 道新题';
    } else {
      final String action =
          _duplicateAction == 'overwrite' ? '覆盖' : '跳过';
      label = '确认导入 ${result.newCount} 道新题 + $action ${result.duplicateCount} 道重复';
    }
    // 一道题都不会进库时（新题 0、重复全部跳过）不给个「确认导入」的按钮 ——
    // 点了也是空转，容易让人以为导入了什么。这时只留「取消」。
    final bool willChangeAnything = result.newCount > 0 ||
        (result.hasDuplicates && _duplicateAction == 'overwrite');

    return Column(
      children: <Widget>[
        SizedBox(
          width: double.infinity,
          child: CupertinoButton.filled(
            onPressed: willChangeAnything ? _confirm : null,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 16,
                color: CupertinoColors.white,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        CupertinoButton(
          onPressed: () => Navigator.of(context).pop<String>(),
          child: const Text(
            '取消',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 17,
              color: AppColors.accent,
            ),
          ),
        ),
      ],
    );
  }

  /// 文件信息（名字 + 体积），让用户确认自己没选错文件。
  static String _sizeLabel(int bytes) {
    if (bytes <= 0) return '—';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// 页头的文件信息行。
class _FileHeader extends StatelessWidget {
  const _FileHeader({required this.filename, required this.fileBytes});

  final String filename;
  final int fileBytes;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Icon(
          CupertinoIcons.doc_text,
          size: 16,
          color: AppColors.secondaryLabel,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: AppColors.secondaryLabel,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _ImportPreviewPageState._sizeLabel(fileBytes),
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            color: AppColors.tertiaryLabel,
          ),
        ),
      ],
    );
  }
}

/// 「新题 N 道 · 重复 M 道」的汇总卡。
///
/// 两个数字用等宽数字（tabular figures）：切换数值时不会左右抖动 ——
/// 这页的数字是用户判断「要不要继续」的依据，得一眼看清。
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.result});

  final ImportPreviewResult result;

  @override
  Widget build(BuildContext context) {
    return _CardBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _Stat(
                value: result.newCount,
                label: '道新题',
                color: AppColors.accent,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '·',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 18,
                    color: AppColors.tertiaryLabel,
                  ),
                ),
              ),
              _Stat(
                value: result.duplicateCount,
                label: '道重复',
                color: AppColors.dueSoon,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            result.isEmptyFile
                ? '没能从这份文件里解析出任何题目。'
                : (result.hasDuplicates
                    ? '重复的题会和库里已有的题对比，由你决定跳过还是覆盖。'
                    : '库里没有这些题，导入后会全部作为新题入库。'),
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.5,
              color: AppColors.secondaryLabel,
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.color});

  final int value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text(
          '$value',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: color,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 14,
            color: AppColors.secondaryLabel,
          ),
        ),
      ],
    );
  }
}

/// 单选行（自绘，工程不用 Material 的 RadioListTile）。
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              selected
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.circle,
              size: 22,
              color: selected ? AppColors.accent : AppColors.tertiaryLabel,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 15,
                      color: AppColors.label,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12,
                      height: 1.4,
                      color: AppColors.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「查看重复题目」的折叠区（自己实现，Material 的 ExpansionTile 不可用）。
class _DuplicatesSection extends StatelessWidget {
  const _DuplicatesSection({
    required this.duplicates,
    required this.duplicateCount,
    required this.expanded,
    required this.onToggle,
  });

  final List<ImportPreviewDuplicate> duplicates;
  final int duplicateCount;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _CardBox(
          child: Column(
            children: <Widget>[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onToggle,
                child: Row(
                  children: <Widget>[
                    const Icon(
                      CupertinoIcons.doc_on_doc,
                      size: 18,
                      color: AppColors.dueSoon,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '查看重复题目（$duplicateCount）',
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 15,
                          color: AppColors.label,
                        ),
                      ),
                    ),
                    Icon(
                      expanded
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      size: 16,
                      color: AppColors.tertiaryLabel,
                    ),
                  ],
                ),
              ),
              if (expanded) ...<Widget>[
                const SizedBox(height: 4),
                for (int i = 0; i < duplicates.length; i++) ...<Widget>[
                  if (i > 0)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: SizedBox(
                        height: 0.5,
                        child: ColoredBox(color: AppColors.separator),
                      ),
                    )
                  else
                    const SizedBox(height: 8),
                  _DuplicateItem(duplicate: duplicates[i], index: i + 1),
                ],
                // 明细条数少于总数时说明后端截断了（只回了一部分明细），
                // 如实告诉用户，别让人以为「就这几条」。
                if (duplicates.length < duplicateCount) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    '只列出了前 ${duplicates.length} 条明细，共 $duplicateCount 道重复。',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12,
                      color: AppColors.tertiaryLabel,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 一条重复题：文件里的题干 + 与库里的差异。
class _DuplicateItem extends StatelessWidget {
  const _DuplicateItem({required this.duplicate, required this.index});

  final ImportPreviewDuplicate duplicate;
  final int index;

  @override
  Widget build(BuildContext context) {
    final ImportPreviewDuplicate d = duplicate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '$index. ',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                height: 1.4,
                color: AppColors.secondaryLabel,
              ),
            ),
            Expanded(
              child: Text(
                // 题干是次要信息（用户主要看差异），所以用次要色。
                d.shortIncomingStem.isEmpty ? '（无题干）' : d.shortIncomingStem,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  height: 1.4,
                  color: AppColors.secondaryLabel,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Padding(
          padding: const EdgeInsets.only(left: 18),
          child: Text(
            // diff 是「差在哪」的关键信息，用暖色小字突出；内容一致时说「内容相同」。
            d.diffLabel,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              height: 1.4,
              color: AppColors.dueSoon,
            ),
          ),
        ),
        // 文件内互相重复、库里还没有时，后端给不出 existing —— 要说明，
        // 否则用户会以为「覆盖」能覆盖到一个库里并不存在的题。
        if (!d.hasExisting) ...<Widget>[
          const SizedBox(height: 2),
          const Padding(
            padding: EdgeInsets.only(left: 18),
            child: Text(
              '与文件里前面的题重复（库里还没有这道题）',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                height: 1.4,
                color: AppColors.tertiaryLabel,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 解析失败条目的告警卡（黄色系）。
class _ParseErrorCard extends StatelessWidget {
  const _ParseErrorCard({required this.messages});

  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    return _CardBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(
                CupertinoIcons.exclamationmark_triangle_fill,
                size: 18,
                color: AppColors.dueSoon,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '有 ${'条目'}没能解析（这些条目不会导入）',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 15,
                    color: AppColors.label,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final String message in messages)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '· $message',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  height: 1.45,
                  color: AppColors.dueSoon,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 提示行（带图标的浅色说明）。
class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadii.chip),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                height: 1.45,
                color: AppColors.secondaryLabel,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 白底圆角卡（与导入页的 `_CardBox` 视觉一致；私有类不可跨文件复用，故重写）。
class _CardBox extends StatelessWidget {
  const _CardBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: child,
    );
  }
}
