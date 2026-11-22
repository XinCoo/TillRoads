// 题目导入页（m17431）。
//
// ── 流程 ────────────────────────────────────────────────────────────────
// 选文件 → 选科目（必填，决定题归到哪一科）→ 选考点（可选）→ 上传 → 看结果
//
// ── 为什么用 base64 + JSON 而不是 multipart ─────────────────────────────
// 后端 BE-02 的导入端点 `POST /questions/import` 收的就是
// `{filename, mime, content_base64, subject_id, knowledge_node_id}`。
// 前端不引入 dio/multipart 那套，就按后端已有的形状来。
// 代价是大文件 base64 会膨胀 ~33%，且编码要几秒 —— 所以有进度提示。
//
// ── file_picker 13 的 API 形状（与 8.x 不同，别照老写法抄）──────────────
//   · 入口是静态方法 `FilePicker.pickFiles(...)`，**没有** `.platform`；
//   · 返回值直接是 `List<PlatformFile>`，**没有** `FilePickerResult` 外壳；
//   · `PlatformFile` 没有 `size` 字段，用 `await file.length()` 拿字节数；
//   · 读内容用 `await file.readAsBytes()`（不需要 dart:io 的 File）。
//
// ── 前端先做的校验（与后端一致，但更早）────────────────────────────────
// 后端限制：单文件 ≤10MB。前端选完文件就先拦一次，
// 省得用户等上传完才看到 413。
//
// ── 错误码 → 人话 ───────────────────────────────────────────────────────
// 后端导入会返回这些错误码，页面上要给出「下一步怎么办」，而不是干巴巴
// 抛一个 code：413 文件太大（拆分）、422 扫描版 PDF / 图片（换文字版）、
// 415 不支持的格式（列出支持的）、400 切不出题（检查题号格式）。
//
// ── 判重不是错误 ────────────────────────────────────────────────────────
// `duplicates` 表示「这道题你之前导过」，后端不重复入库。这是正常结果，
// 要展示出来（题干让人核对），不能当成失败。

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
import '../api/defect_api.dart';
import '../api/question_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart' show SectionHeader;

/// 后端限制：单文件最大 10MB。
const int kMaxImportBytes = 10 * 1024 * 1024;

/// 支持的文件类型（与后端 extract.mjs 的分派一致）。
const List<String> kSupportedExtensions = <String>[
  'md',
  'txt',
  'csv',
  'pdf',
  'xlsx',
];

class QuestionImportPage extends StatefulWidget {
  const QuestionImportPage({super.key});

  @override
  State<QuestionImportPage> createState() => _QuestionImportPageState();
}

class _QuestionImportPageState extends State<QuestionImportPage> {
  final QuestionApi _api = QuestionApi();
  final DefectApi _defectApi = DefectApi();

  /// 已选文件。
  PlatformFile? _file;

  /// 文件大小（字节）。
  int _fileBytes = 0;

  /// 考试档案列表（用于选科目）。
  List<Map<String, Object?>> _profiles = const <Map<String, Object?>>[];

  /// 选中的科目 id。
  String? _subjectId;

  /// 选中的考点 id（可空）。
  String? _knowledgeNodeId;

  /// 当前科目的考点列表。
  List<Map<String, Object?>> _knowledgeNodes = const <Map<String, Object?>>[];

  bool _loadingOptions = true;
  bool _uploading = false;
  ImportResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    try {
      final List<Map<String, Object?>> profiles = await _defectApi
          .fetchExamProfiles(kDemoUserId);
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _loadingOptions = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '考试档案加载失败：$e';
        _loadingOptions = false;
      });
    }
  }

  Future<void> _pickFile() async {
    try {
      final List<PlatformFile> picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: kSupportedExtensions,
      );
      if (picked.isEmpty) return;
      final PlatformFile file = picked.first;

      // file_picker 13 没有 size 字段，要用 length() 读字节数。
      final int? size = await file.length();

      // 前端先校验大小，别让用户白等一次上传。
      if (size != null && size > kMaxImportBytes) {
        setState(() {
          _error =
              '文件太大（${(size / (1024 * 1024)).toStringAsFixed(1)}MB），'
              '单个文件不能超过 10MB，请拆分成多份再导入。';
        });
        return;
      }

      setState(() {
        _file = file;
        _fileBytes = size ?? 0;
        _error = null;
        _result = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '选择文件失败：$e');
    }
  }

  /// 选科目 → 拉该科目的考点（考点是可选的，不选也能导）。
  Future<void> _pickSubject(String subjectId) async {
    setState(() {
      _subjectId = subjectId;
      _knowledgeNodeId = null;
      _knowledgeNodes = const <Map<String, Object?>>[];
    });
    try {
      final List<Map<String, Object?>> nodes = await _defectApi
          .fetchKnowledgeNodes(subjectId);
      if (!mounted) return;
      setState(() => _knowledgeNodes = nodes);
    } catch (_) {
      // 考点拉不到不阻塞导入（考点是可选的）。
    }
  }

  Future<void> _upload() async {
    final PlatformFile? file = _file;
    if (file == null) {
      setState(() => _error = '请先选择要导入的文件。');
      return;
    }
    final String? subjectId = _subjectId;
    if (subjectId == null || subjectId.isEmpty) {
      setState(() => _error = '请选择题目所属的科目。');
      return;
    }

    setState(() {
      _uploading = true;
      _error = null;
      _result = null;
    });

    try {
      final String base64 = await _readBase64(file);
      final ImportResult result = await _api.importQuestions(
        filename: file.name,
        contentBase64: base64,
        mime: _mimeOf(file.name),
        subjectId: subjectId,
        knowledgeNodeId: _knowledgeNodeId,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _uploading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(e);
        _uploading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '导入失败：$e';
        _uploading = false;
      });
    }
  }

  /// 把后端错误码翻成「下一步怎么办」。
  String _friendlyError(ApiException e) {
    final int code = e.statusCode ?? 0;
    final String body = e.body is Map
        ? '${(e.body! as Map)['error'] ?? ''}'
        : '';
    if (code == 413) {
      return '文件太大（后端限制 10MB），请拆分成多份再导入。';
    }
    if (code == 422) {
      if (body.contains('PDF')) {
        return '这份 PDF 是扫描件（没有文字层），请改成文字版或用 txt/md 上传。';
      }
      if (body.contains('IMAGE')) {
        return '暂不支持图片导入，请把题目整理成文字后再导入。';
      }
      return '这个文件里有后端不支持的内容（扫描版 PDF / 图片 / 复杂 xlsx），请换成 md/txt/csv。';
    }
    if (code == 415) {
      return '不支持的文件格式。支持的格式：${kSupportedExtensions.join('、')}。';
    }
    if (code == 400) {
      if (body.contains('EMPTY_CONTENT')) {
        return '没从文件里切出任何题目，请检查是否包含题号与题干。';
      }
      if (body.contains('BASE64') || body.contains('CONTENT')) {
        return '文件内容读取失败，请重新选择文件。';
      }
      return '导入失败，请检查题号格式（例如「1.」「第1题」「1、」）。';
    }
    return e.message;
  }

  Future<String> _readBase64(PlatformFile file) async {
    final List<int> bytes = await file.readAsBytes();
    return encodeBase64(bytes);
  }

  String _mimeOf(String filename) {
    final String lower = filename.toLowerCase();
    if (lower.endsWith('.md')) return 'text/markdown';
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.csv')) return 'text/csv';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.xlsx')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    return 'application/octet-stream';
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      navigationBar: const CupertinoNavigationBar(
        middle: Text(
          '导入题目',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: _result != null ? _buildResult(_result!) : _buildForm(),
      ),
    );
  }

  Widget _buildForm() {
    if (_loadingOptions) {
      return const Center(child: CupertinoActivityIndicator(radius: 12));
    }

    final PlatformFile? file = _file;
    final String? subjectId = _subjectId;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        _CardBox(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SectionHeader(text: '1. 选择文件'),
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _uploading ? null : _pickFile,
                child: Row(
                  children: <Widget>[
                    const Icon(
                      CupertinoIcons.folder,
                      size: 20,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        file == null ? '选择文件' : file.name,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 15,
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                    if (file != null)
                      Text(
                        _sizeLabel(_fileBytes),
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 13,
                          color: AppColors.secondaryLabel,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '支持 md / txt / csv / pdf / xlsx，单个文件不超过 10MB。',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  color: AppColors.secondaryLabel,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _CardBox(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SectionHeader(text: '2. 选择科目'),
              if (_profiles.isEmpty)
                const Text(
                  '还没有考试档案，无法选科目。',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    color: AppColors.secondaryLabel,
                  ),
                )
              else
                for (final Map<String, Object?> profile in _profiles)
                  _ProfileSubjectPicker(
                    profile: profile,
                    subjectId: subjectId,
                    onPickSubject: _pickSubject,
                  ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_knowledgeNodes.isNotEmpty)
          _CardBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SectionHeader(text: '3. 选择考点（可选）'),
                _WrapChips(
                  options: <Map<String, Object?>>[
                    <String, Object?>{'id': '', 'title': '不指定考点'},
                    ..._knowledgeNodes,
                  ],
                  selectedId: _knowledgeNodeId ?? '',
                  onPick: (String id) {
                    setState(() {
                      _knowledgeNodeId = id.isEmpty ? null : id;
                    });
                  },
                ),
              ],
            ),
          ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 12),
          _ErrorBanner(message: _error!),
        ],
        const SizedBox(height: 20),
        CupertinoButton.filled(
          onPressed:
              (_uploading || file == null || subjectId == null) ? null : _upload,
          child: _uploading
              ? const CupertinoActivityIndicator(color: CupertinoColors.white)
              : const Text(
                  '开始导入',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 17,
                    color: CupertinoColors.white,
                  ),
                ),
        ),
        if (_uploading) ...<Widget>[
          const SizedBox(height: 10),
          const Text(
            '正在编码并上传，大文件可能需要几秒…',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: AppColors.secondaryLabel,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildResult(ImportResult result) {
    final bool anySuccess = result.imported > 0;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      children: <Widget>[
        Icon(
          anySuccess
              ? CupertinoIcons.checkmark_seal_fill
              : CupertinoIcons.info_circle,
          size: 44,
          color: anySuccess ? AppColors.normal : AppColors.dueSoon,
        ),
        const SizedBox(height: 12),
        Text(
          anySuccess ? '导入完成' : '没有新题入库',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        const SizedBox(height: 16),
        _CardBox(
          child: Column(
            children: <Widget>[
              _ResultRow(label: '新增题目', value: '${result.imported}'),
              _ResultRow(
                label: '已存在（判重）',
                value: '${result.duplicates.length}',
              ),
              _ResultRow(label: '解析失败', value: '${result.errors.length}'),
            ],
          ),
        ),
        if (result.duplicates.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          const SectionHeader(text: '已存在的题（未重复入库）'),
          _CardBox(
            child: Column(
              children: <Widget>[
                for (int i = 0; i < result.duplicates.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i == result.duplicates.length - 1 ? 0 : 8,
                    ),
                    child: Text(
                      '${i + 1}. ${result.duplicates[i].stem}',
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
          ),
        ],
        if (result.errors.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          const SectionHeader(text: '解析失败的题'),
          _CardBox(
            child: Column(
              children: <Widget>[
                for (final String e in result.errors)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      e,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 13,
                        color: AppColors.overdue,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        CupertinoButton.filled(
          onPressed: () {
            Navigator.of(context).pop(anySuccess);
          },
          child: const Text(
            '完成',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 17,
              color: CupertinoColors.white,
            ),
          ),
        ),
      ],
    );
  }

  static String _sizeLabel(int bytes) {
    if (bytes <= 0) return '—';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// 一个考试档案下的科目列表（点击即选中该科目）。
class _ProfileSubjectPicker extends StatefulWidget {
  const _ProfileSubjectPicker({
    required this.profile,
    required this.subjectId,
    required this.onPickSubject,
  });

  final Map<String, Object?> profile;
  final String? subjectId;
  final Future<void> Function(String subjectId) onPickSubject;

  @override
  State<_ProfileSubjectPicker> createState() => _ProfileSubjectPickerState();
}

class _ProfileSubjectPickerState extends State<_ProfileSubjectPicker> {
  /// 科目缓存（同一档案只拉一次）。
  static final Map<String, List<Map<String, Object?>>> _cache =
      <String, List<Map<String, Object?>>>{};

  late Future<List<Map<String, Object?>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _subjectsOf('${widget.profile['id'] ?? ''}');
  }

  Future<List<Map<String, Object?>>> _subjectsOf(String profileId) async {
    if (profileId.isEmpty) return const <Map<String, Object?>>[];
    final List<Map<String, Object?>>? cached = _cache[profileId];
    if (cached != null) return cached;
    try {
      final DefectApi api = DefectApi();
      final List<Map<String, Object?>> list = await api.fetchSubjects(profileId);
      _cache[profileId] = list;
      return list;
    } catch (_) {
      return const <Map<String, Object?>>[];
    }
  }

  @override
  Widget build(BuildContext context) {
    final String label =
        '${widget.profile['target_label'] ?? widget.profile['label'] ?? '考试档案'}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 6),
          FutureBuilder<List<Map<String, Object?>>>(
            future: _future,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<List<Map<String, Object?>>> snapshot,
                ) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(6),
                      child: CupertinoActivityIndicator(radius: 8),
                    );
                  }
                  final List<Map<String, Object?>> subjects =
                      snapshot.data ?? const <Map<String, Object?>>[];
                  if (subjects.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(6),
                      child: Text(
                        '（该档案下没有科目）',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 12,
                          color: AppColors.tertiaryLabel,
                        ),
                      ),
                    );
                  }
                  return _WrapChips(
                    options: subjects,
                    selectedId: widget.subjectId ?? '',
                    onPick: (String id) {
                      widget.onPickSubject(id);
                    },
                  );
                },
          ),
        ],
      ),
    );
  }
}

/// 一组可点选的 chip（科目 / 考点）。
class _WrapChips extends StatelessWidget {
  const _WrapChips({
    required this.options,
    required this.selectedId,
    required this.onPick,
  });

  final List<Map<String, Object?>> options;
  final String selectedId;
  final void Function(String id) onPick;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final Map<String, Object?> option in options)
          _Chip(
            label: '${option['name'] ?? option['title'] ?? ''}',
            selected: '${option['id'] ?? ''}' == selectedId,
            onTap: () {
              onPick('${option['id'] ?? ''}');
            },
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.card,
          borderRadius: BorderRadius.circular(AppRadii.chip),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.separator,
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            color: selected ? CupertinoColors.white : AppColors.label,
          ),
        ),
      ),
    );
  }
}

/// 结果页里的一行数字。
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              color: AppColors.label,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }
}

/// 红色错误条。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.overdue.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            CupertinoIcons.exclamationmark_circle,
            size: 18,
            color: AppColors.overdue,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                height: 1.4,
                color: AppColors.overdue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 白底圆角卡（与 profile_page / settings_page 同一套观感）。
class _CardBox extends StatelessWidget {
  const _CardBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
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
      child: child,
    );
  }
}
