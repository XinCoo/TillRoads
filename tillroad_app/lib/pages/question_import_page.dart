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

import '../api/api_client.dart' show ApiClient, ApiException;
import '../api/defect_api.dart';
import '../api/question_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart' show SectionHeader;

/// 后端限制：单文件最大 10MB。
const int kMaxImportBytes = 10 * 1024 * 1024;

/// 导入用的请求超时（秒）。
///
/// 50 题在 Neon 冷启动下实测要 20s+，所以导入单独放宽到 60s，
/// 不动全局 `kApiTimeout`（其他端点仍要快速失败）。
const int _importTimeoutSeconds = 60;

/// 「大文件」阈值：超过这个体积就提前提醒用户拆分，
/// 免得等上传完才看到 413。
const int kLargeImportBytes = 2 * 1024 * 1024;

/// 支持的文件类型（与后端 extract.mjs 的分派一致）。
///
/// m18680 C1：补上 `markdown` —— 不少编辑器/导出工具存的是 `.markdown` 后缀，
/// 后端 `extract.mjs` 按扩展名分派时也是 md/markdown 同等对待，前端不该比后端更严。
const List<String> kSupportedExtensions = <String>[
  'md',
  'markdown',
  'txt',
  'csv',
  'pdf',
  'xlsx',
];

/// 科目归属模式（与后端 `POST /questions/import` 的 `subject_mode` 同值）。
///
/// [kSubjectModeFromFile]：按文件里每题自带的 `subject` 文本匹配科目、
/// 按 `node` 文本匹配或创建考点；请求里的 `subject_id` 只当兜底科目。
/// [kSubjectModeUniform]：现有行为 —— 所有题都进请求里的 `subject_id`。
const String kSubjectModeFromFile = 'from_file';
const String kSubjectModeUniform = 'uniform';

/// 导入的三个阶段。
///
/// 后端 `POST /questions/import` 是**一次性同步接口**：没有 job id，
/// 也没有进度查询端点（本轮不建 import_jobs 表），
/// 所以进度只能在客户端分成三段呈现：
/// [encoding] 本地读文件 + base64 编码 → [processing] 服务端解析/切题/入库 → [done]。
enum ImportStage { encoding, processing, done }

class QuestionImportPage extends StatefulWidget {
  const QuestionImportPage({super.key});

  @override
  State<QuestionImportPage> createState() => _QuestionImportPageState();
}

class _QuestionImportPageState extends State<QuestionImportPage> {
  /// m18680 A6：导入是低频、批量、吃后端 CPU 的操作，
  /// 50 题在 Neon 冷启动下实测要 20s+，全局 15s 超时会误报「失败」——
  /// 用户看到超时就会重试，第二次因为已入库反而显示「判重 N」，
  /// 这正是「判重 50 但云端没有」那类误解的根源。
  /// 这里单独给导入页一个 60s 超时的 client，不动全局 `kApiTimeout`
  /// （其他端点的快速失败语义保持不变）。
  final QuestionApi _api = QuestionApi(
    client: ApiClient(timeout: const Duration(seconds: 60)),
  );
  final DefectApi _defectApi = DefectApi();

  /// 已选文件。
  PlatformFile? _file;

  /// 文件大小（字节）。
  int _fileBytes = 0;

  /// 考试档案列表（用于选科目）。
  List<Map<String, Object?>> _profiles = const <Map<String, Object?>>[];

  /// 选中的科目 id。
  String? _subjectId;

  /// 科目归属模式（对应后端 `subject_mode`）。
  ///
  /// 默认 [kSubjectModeFromFile]：题目自带的科目文本说了算，
  /// 用户选的 `_subjectId` 降级成「文件里没写科目名」时的兜底科目。
  String _subjectMode = kSubjectModeFromFile;

  bool get _isFromFile => _subjectMode == kSubjectModeFromFile;

  /// 选中的考点 id（可空）。
  String? _knowledgeNodeId;

  /// 当前科目的考点列表。
  List<Map<String, Object?>> _knowledgeNodes = const <Map<String, Object?>>[];

  bool _loadingOptions = true;
  bool _uploading = false;
  ImportResult? _result;
  String? _error;

  /// 导入的三个阶段（m23700 拍板「客户端进度 + 预检提示」）。
  ///
  /// 后端是一次性同步接口，没有进度查询端点（也不建 import_jobs 表），
  /// 所以客户端只能把「本地编码」和「服务端处理」分成两段显示：
  /// 读文件 + base64 编码是本地耗时，请求发出后是服务端耗时。
  ImportStage? _stage;

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

  /// 选择要导入的文件。
  ///
  /// [anyFile] = true 时用 `FileType.any`（系统文件选择器不做 MIME 过滤），
  /// 选完再按扩展名自己判 —— m18680 C2：Android 上 `FileType.custom` 是靠
  /// MIME type 过滤的，`.md` 的 `text/markdown` 在部分 ROM 里没注册，
  /// 文件会变灰选不到。两级兜底：默认按扩展名过滤（体验好），
  /// 选不到时用户可以点「所有文件」绕过系统过滤。
  Future<void> _pickFile({bool anyFile = false}) async {
    try {
      final List<PlatformFile> picked = await FilePicker.pickFiles(
        type: anyFile ? FileType.any : FileType.custom,
        allowedExtensions: anyFile ? null : kSupportedExtensions,
      );
      if (picked.isEmpty) return;
      final PlatformFile file = picked.first;

      // 「所有文件」模式下系统不过滤，这里必须自己拦：
      // 否则用户选了 .docx 会一路传到后端才拿到 415，白等一次上传。
      if (anyFile && !_isSupportedFilename(file.name)) {
        setState(() {
          _error =
              '不支持的格式（${_extOf(file.name)}），'
              '请用 ${kSupportedExtensions.join(' / ')}。';
        });
        return;
      }

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

  /// 文件后缀（含点，小写）。没有后缀时返回「无后缀」。
  String _extOf(String filename) {
    final int dot = filename.lastIndexOf('.');
    if (dot <= 0 || dot == filename.length - 1) return '无后缀';
    return filename.substring(dot).toLowerCase();
  }

  /// 扩展名是否在支持列表里（与后端 extract.mjs 的 EXT_KINDS 同口径）。
  bool _isSupportedFilename(String filename) {
    final String ext = _extOf(filename);
    if (ext == '无后缀') return false;
    return kSupportedExtensions.contains(ext.substring(1));
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

  /// 切换科目归属模式。
  ///
  /// 切回「统一指定」时如果用户之前已经选过科目、且考点列表为空，
  /// 重新拉一次考点（否则「3. 选择考点」卡片不会出现）。
  void _setSubjectMode(String mode) {
    if (mode == _subjectMode) return;
    setState(() {
      _subjectMode = mode;
      _error = null;
    });
    final String? subjectId = _subjectId;
    if (!_isFromFile &&
        subjectId != null &&
        subjectId.isNotEmpty &&
        _knowledgeNodes.isEmpty) {
      _pickSubject(subjectId);
    }
  }

  Future<void> _upload() async {
    final PlatformFile? file = _file;
    if (file == null) {
      setState(() => _error = '请先选择要导入的文件。');
      return;
    }
    // from_file 模式下「文件里没写科目名」需要有兜底科目，但没选也能导
    // （全部题都不带科目名时，后端会把它们记到未分类，用户可事后批量移动）。
    // uniform 模式仍然强制选科目（否则后端没有归属可写）。
    final String? subjectId = _subjectId;
    if (!_isFromFile && (subjectId == null || subjectId.isEmpty)) {
      setState(() => _error = '请选择题目所属的科目。');
      return;
    }

    setState(() {
      _uploading = true;
      _error = null;
      _result = null;
      _stage = ImportStage.encoding;
    });

    try {
      final String base64 = await _readBase64(file);
      if (!mounted) return;
      // 字节已读完、请求即将发出：后面都是服务端的时间。
      setState(() => _stage = ImportStage.processing);
      final ImportResult result = await _api.importQuestions(
        filename: file.name,
        contentBase64: base64,
        mime: _mimeOf(file.name),
        subjectMode: _subjectMode,
        subjectId: subjectId,
        // from_file 模式下考点由文件里的 node 决定，不再传界面选的考点。
        knowledgeNodeId: _isFromFile ? null : _knowledgeNodeId,
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
        _stage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '导入失败：$e';
        _uploading = false;
        _stage = null;
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
    // 超时是最容易让用户误判的一种失败：服务端可能已经把题写进去了，
    // 只是响应没在 60s 内回来。此时再让用户「重试」只会得到一堆「判重」。
    if (code == 0 && e.message.contains('超时')) {
      return '这次导入超时了（${_importTimeoutSeconds}s 没等到服务端回应）。\n'
          '但服务端可能已经写入了部分或全部题目，请先到题库页确认，'
          '确认后再决定要不要重传。';
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
              Text(
                '支持 ${kSupportedExtensions.join(' / ')}，单个文件不超过 10MB。',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  color: AppColors.secondaryLabel,
                ),
              ),
              // 大文件预检（m23700 拍板「客户端进度 + 预检提示」）：
              // 超过 2MB 就先提醒「建议拆分 + 会更慢」，不用等上传完才看到 413。
              if (_fileBytes > kLargeImportBytes) ...<Widget>[
                const SizedBox(height: 8),
                _ImportNotice(
                  icon: CupertinoIcons.exclamationmark_triangle,
                  color: AppColors.dueSoon,
                  text: '这个文件 ${_sizeLabel(_fileBytes)}，属于大文件。'
                      '导入会明显变慢（base64 上传体积约多三成），'
                      '建议先按题号拆成几份再导。',
                ),
              ],
              const SizedBox(height: 8),
              // m18680 C2：系统选择器按 MIME 过滤时 `.md` 可能变灰选不到，
              // 这里给一条不依赖 MIME 的通道：不过滤任何类型，选完自己按扩展名判。
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed:
                    _uploading ? null : () => _pickFile(anyFile: true),
                child: const Text(
                  '选不到文件？用「所有文件」打开',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    color: AppColors.accent,
                  ),
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
              // 科目归属两模式（与后端 subject_mode 同值）。默认「从文件读取」——
              // 文件里本来就写了科目，再让用户选一遍是重复劳动且容易选错。
              Row(
                children: <Widget>[
                  _Chip(
                    label: '从文件读取',
                    selected: _isFromFile,
                    onTap: () => _setSubjectMode(kSubjectModeFromFile),
                  ),
                  const SizedBox(width: 8),
                  _Chip(
                    label: '统一指定',
                    selected: !_isFromFile,
                    onTap: () => _setSubjectMode(kSubjectModeUniform),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _isFromFile
                    ? '每道题按自己携带的科目名入库；下面选的科目只当兜底：'
                        '文件里没有科目名时，会归到这里选的兜底科目。'
                    : '所有题都归到下面选中的科目。',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  height: 1.4,
                  color: AppColors.secondaryLabel,
                ),
              ),
              if (_isFromFile) ...<Widget>[
                const SizedBox(height: 8),
                const _ImportNotice(
                  icon: CupertinoIcons.arrow_branch,
                  color: AppColors.accent,
                  text: '不选科目也能直接导入。考点也由文件里的 node 自动匹配或创建，无需在这里选。',
                ),
              ],
              const SizedBox(height: 8),
              if (_profiles.isEmpty)
                const Text(
                  '还没有考试档案，请先在「我的 → 考试配置」中添加考试目标与科目。',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    color: AppColors.secondaryLabel,
                  ),
                )
                else ...<Widget>[
                  if (_isFromFile) ...<Widget>[
                    const Text(
                      '兜底科目（可选）',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 13,
                        color: AppColors.secondaryLabel,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  for (final Map<String, Object?> profile in _profiles)
                    _ProfileSubjectPicker(
                      profile: profile,
                      subjectId: subjectId,
                      onPickSubject: _pickSubject,
                    ),
                ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (!_isFromFile && _knowledgeNodes.isNotEmpty)
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
        // from_file 模式下考点由文件里的 node 决定，这里只做只读说明，
        // 不展示可选 chip（否则用户会以为选了就能生效）。
        if (_isFromFile) ...<Widget>[
          const SizedBox(height: 12),
          _CardBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SectionHeader(text: '3. 选择考点'),
                Text(
                  '考点由文件里每道题的 node 字段自动匹配；'
                  '文件里的考点在库里不存在时，后端会自动创建（结果页会列出新建的考点）。',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    height: 1.4,
                    color: AppColors.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_error != null) ...<Widget>[
          const SizedBox(height: 12),
          _ErrorBanner(message: _error!),
        ],
        const SizedBox(height: 20),
        CupertinoButton.filled(
          // from_file 模式下不要求选科目（只要有文件就能提交）；
          // uniform 模式仍需要科目。
          onPressed: (_uploading || file == null || (!_isFromFile && subjectId == null))
              ? null
              : _upload,
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
          const SizedBox(height: 12),
          _ImportProgress(stage: _stage),
        ],
      ],
    );
  }

  Widget _buildResult(ImportResult result) {
    final bool anySuccess = result.imported > 0;
    // ★ A2②：题型识别统计。这三个值旧后端可能不返回 ——
    // 缺失就整块不显示（显示 0 会让人误以为「一道都没识别出来」）。
    final int? detected = _statInt(result, 'type_detected');
    final int? review = _statInt(result, 'type_needs_review');
    final int? sanitized = _statInt(result, 'sanitized');
    final bool hasTypeStats = detected != null || review != null || sanitized != null;
    // ★ 科目匹配结果：旧后端没有这两段字段时 fromJson 会归零，
    // 全 0 就不显示（避免给用户看一个「匹配 0 题」的空区块）。
    final ImportSubjectMatch subjectMatch = result.subjectMatched;
    final ImportNodeCreated nodeCreated = result.nodeCreated;
    final bool hasSubjectMatch =
        subjectMatch.matchedCount > 0 || subjectMatch.unmatchedCount > 0;
    final bool hasNodeCreated = nodeCreated.createdCount > 0 || nodeCreated.createdPaths.isNotEmpty;
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
        if (hasTypeStats) ...<Widget>[
          const SizedBox(height: 16),
          const SectionHeader(text: '识别统计'),
          _CardBox(
            child: Column(
              children: <Widget>[
                if (detected != null)
                  _ResultRow(label: '自动识别题型', value: '$detected'),
                if (review != null)
                  _ResultRow(label: '待人工确认', value: '$review'),
                if (sanitized != null)
                  _ResultRow(label: '题干清洗', value: '$sanitized'),
                if (review != null && review > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '有 $review 道题的题型没能可靠识别，已按默认题型入库，可在题库里逐条调整。',
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 13,
                        height: 1.4,
                        color: AppColors.dueSoon,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        // ── 科目匹配结果（new）：识别统计之后、判重列表之前。
        if (hasSubjectMatch) ...<Widget>[
          const SizedBox(height: 16),
          const SectionHeader(text: '科目匹配结果'),
          _CardBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (subjectMatch.matchedCount > 0)
                  _ResultRow(
                    label: '按文件科目匹配',
                    value: '${subjectMatch.matchedCount}',
                  ),
                if (subjectMatch.matchedCount > 0 &&
                    subjectMatch.matchedSubjects.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '归入：${subjectMatch.matchedSubjects.map((ImportSubjectCount s) => '${s.name.isEmpty ? '未命名科目' : s.name}（${s.count} 题）').join('、')}',
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 13,
                        height: 1.4,
                        color: AppColors.secondaryLabel,
                      ),
                    ),
                  ),
                if (subjectMatch.unmatchedCount > 0)
                  _ResultRow(
                    label: '未能匹配科目',
                    value: '${subjectMatch.unmatchedCount}',
                  ),
                if (subjectMatch.unmatchedSubjects.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '文件里的科目名：${subjectMatch.unmatchedSubjects.join('、')}',
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 13,
                        height: 1.4,
                        color: AppColors.secondaryLabel,
                      ),
                    ),
                  ),
                if (subjectMatch.unmatchedCount > 0)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: _ImportNotice(
                      icon: CupertinoIcons.info_circle,
                      color: AppColors.dueSoon,
                      text: '这些题已归入你选的兜底科目，可到题库管理页批量移动到正确科目。',
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (hasNodeCreated) ...<Widget>[
          const SizedBox(height: 16),
          const SectionHeader(text: '自动创建的考点'),
          _CardBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _ResultRow(label: '新建考点', value: '${nodeCreated.createdCount}'),
                for (final String path in nodeCreated.createdPaths)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '· $path',
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

  /// ★ A2②：从后端 stats 里读一个整数字段。
  ///
  /// 缺失（旧后端没这个字段）返回 null —— 调用方据此决定「整块不显示」，
  /// 不用 0 冒充。
  static int? _statInt(ImportResult result, String key) {
    final Object? v = result.stats[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
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

/// 导入三段进度提示（m23700）。
///
/// 后端没有进度查询端点，所以这里只能把「本地编码」与「服务端处理」
/// 分开显示；具体百分比拿不到，就不假装有。
class _ImportProgress extends StatelessWidget {
  const _ImportProgress({this.stage});

  final ImportStage? stage;

  @override
  Widget build(BuildContext context) {
    final bool encoding = stage == ImportStage.encoding;
    final String title = encoding ? '正在读取并编码文件…' : '服务端正在解析与入库…';
    final String hint = encoding
        ? '这一步在手机本地做，base64 会让体积多约三成。'
        : '解析、切题、判重、入库都在后端完成，大文件可能要等一会儿。';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const CupertinoActivityIndicator(radius: 9),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.label,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hint,
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
    );
  }
}

/// 预检提示（颜色可调）。
class _ImportNotice extends StatelessWidget {
  const _ImportNotice({
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
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
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
                height: 1.4,
                color: AppColors.label,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
