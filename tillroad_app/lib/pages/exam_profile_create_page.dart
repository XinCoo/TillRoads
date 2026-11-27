// 考试配置 · 新建考试目标页。
//
// ── 这一页解决什么问题 ──────────────────────────────────────────────────
// `POST /exam-profiles` 是 AC-KM-01 的事务端点：建目标的同时按 exam_type
// 套用官方科目模板（`core/templates.mjs`），返回 `{profile, subjects}`。
// 也就是说「建目标」这一步本身就决定了后面有多少科目要管，所以本页
// 创建成功后要把预置科目数告诉用户，否则用户进科目页看到一堆没见过的
// 科目会以为是别人的数据。
//
// ── 与后端契约的三处对齐（都做过源码确认，不是猜的）───────────────
// 1. `user_id` 必填。目标文本给的 body 里没有它，但
//    `server/routes/exam_profiles.mjs:96` 在缺 user_id 时直接
//    `400 {error:'missing_user_id'}`。本页固定带 `kDemoUserId`
//    （与全工程其它页面一致的演示账号）。
// 2. `source_scope` 在库里是 **jsonb**（`schema.sql:172`），
//    `_common.mjs` 的 `toJsonbParam` 对字符串是**原样下发当 JSON 文本**，
//    裸字符串会被 PG 判成非法 JSON → 22P02 → 500。故包成 `{'raw': text}`。
// 3. `target_score` 是 numeric(6,2)，`validateTargetScore` 拒绝 >2 位小数；
//    `daily_minutes` 是正整数（0 会被 V6 拒绝）。两者留空时**不传键**，
//    而不是传空字符串（空串会以 INVALID_* 冒出来）。
//
// ── 「自定义」考试类型（A1）────────────────────────────────────────────
// `exam_type` 新增 `'custom'`（后端迁移 0006），同时新增可空列
// `exam_type_custom`（自定义名称文本，≤20 字）。选中「自定义」时：
//   * 必须填「自定义名称」（≤20 字，超了在前端就红字拦下，不等后端 400）；
//   * 提交体额外带 `exam_type_custom`；
//   * `target_label` 若为空则用自定义名称填充 —— 后端 AC-EXAM-01 要求
//     `target_score` 或 `target_label` 至少一个非空。
//
// ── 日期为什么手拼 'YYYY-MM-DD' ─────────────────────────────────────────
// `validateExamDate` 也接受 ISO datetime，但 `exam_date` 是 date 列，
// 带 `T00:00:00.000` 会被 PG 截断；且列表页按 'YYYY-MM-DD' 展示，
// 两处格式统一才不会有「提交 2026-03-01T00:00:00 却显示 2026-03-01」的割裂。

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
import '../api/exam_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/form_field.dart' show FormFieldGroup, FormTextField;

class ExamProfileCreatePage extends StatefulWidget {
  const ExamProfileCreatePage({super.key, this.initial});

  /// 编辑模式（m29656 任务 B5：首页卡片长按进入编辑）。
  ///
  /// 为 null = 新建；非 null = 用这条 profile 回填表单，提交时走
  /// `PATCH /exam-profiles/:id` 而不是 `POST`。
  ///
  /// 为什么复用本页而不是新建一个 `ExamProfileEditPage`：
  ///   两页的字段、校验、日期选择器完全一样，唯一差别是「提交到哪个端点」
  ///   与「标题叫什么」。复制一份 600 行的页面会让以后的表单改动多一个
  ///   必改点，而这类「改了一处忘了另一处」正是本工程反复踩过的坑。
  ///
  /// 注意：本地表 `exam_profiles` 没有 `exam_type_custom` 列（见
  /// `local_schema.dart`），所以从本地读出来的初始值里没有这个字段。
  /// 编辑时只在用户真的改了「自定义名称」才把该键带上去（`PATCH` 是部分
  /// 更新，不传的键不会被覆盖）。
  final Map<String, Object?>? initial;

  /// 是否处于编辑模式。
  bool get isEditing => initial != null;

  @override
  State<ExamProfileCreatePage> createState() => _ExamProfileCreatePageState();
}
class _ExamProfileCreatePageState extends State<ExamProfileCreatePage> {
  final ExamApi _api = ExamApi();

  final TextEditingController _labelCtrl = TextEditingController();
  final TextEditingController _scoreCtrl = TextEditingController();
  final TextEditingController _minutesCtrl = TextEditingController(text: '120');
  final TextEditingController _scopeCtrl = TextEditingController();

  /// 「自定义」类型的名称（≤20 字）。
  final TextEditingController _customCtrl = TextEditingController();

  String _examType = 'civil_service';
  late DateTime _examDate;
  bool _datePickerOpen = false;
  bool _submitting = false;

  /// 「自定义名称」的行内错误（非空时显示红字）。
  String? _customError;

  @override
  void initState() {
    super.initState();
    // 默认 90 天后：给一个「备考周期约三个月」的合理起点，
    // 用户不改也能直接提交（exam_date 是 AC-EXAM-01 的必填项）。
    final DateTime now = DateTime.now();
    _examDate = DateTime(now.year, now.month, now.day).add(
      const Duration(days: 90),
    );
    _prefillFromInitial();
  }

  /// 编辑模式：把 [ExamProfileCreatePage.initial] 回填到各输入框。
  ///
  /// 逐字段读、逐字段判类型：后端/B 端返回的 map 值可能是 String / num / null，
  /// 直接强转会在某个字段为空时抛类型错误，用户只会看到一片红屏。
  void _prefillFromInitial() {
    final Map<String, Object?>? initial = widget.initial;
    if (initial == null) return;

    final Object? label = initial['target_label'];
    if (label is String) _labelCtrl.text = label;

    final Object? custom = initial['exam_type_custom'];
    if (custom is String) _customCtrl.text = custom;

    final Object? type = initial['exam_type'];
    if (type is String && kExamTypeLabels.containsKey(type)) {
      _examType = type;
    }

    final Object? score = initial['target_score'];
    if (score is num) {
      // numeric(6,2) 回来可能是 130.00，直接 toString 会显示成 130.0。
      _scoreCtrl.text = score == score.roundToDouble()
          ? score.toInt().toString()
          : score.toString();
    } else if (score is String && score.trim().isNotEmpty) {
      _scoreCtrl.text = score.trim();
    }

    final Object? minutes = initial['daily_minutes'];
    if (minutes is int) {
      _minutesCtrl.text = minutes.toString();
    } else if (minutes is num) {
      _minutesCtrl.text = minutes.toInt().toString();
    }

    // source_scope 是 jsonb：可能是 {'raw': '...'}，也可能是裸字符串。
    final Object? scope = initial['source_scope'];
    if (scope is Map) {
      final Object? rawScope = scope['raw'];
      if (rawScope is String) _scopeCtrl.text = rawScope;
    } else if (scope is String) {
      _scopeCtrl.text = scope;
    }

    final Object? date = initial['exam_date'];
    if (date is String) {
      final DateTime? parsed = DateTime.tryParse(date.trim());
      if (parsed != null) {
        _examDate = DateTime(parsed.year, parsed.month, parsed.day);
      }
    }
  }

  /// 从 profile 里取乐观锁版本号（取不到返回 null → 不允许提交）。
  ///
  /// 与 `exam_config_page.dart` 的 `_versionOf` 同一套容错：Pg 的 int8
  /// 经 JSON 过来可能是 int / num / String，三种都得认。
  static int? _versionOf(Map<String, Object?> profile) {
    final Object? raw = profile['version'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _scoreCtrl.dispose();
    _minutesCtrl.dispose();
    _scopeCtrl.dispose();
    _customCtrl.dispose();
    _api.close();
    super.dispose();
  }

  /// 是不是「自定义」类型。
  bool get _isCustom => _examType == 'custom';

  /// 手拼 'YYYY-MM-DD'（不用 toIso8601String：它会带上 T00:00:00.000）。
  String get _examDateText {
    final String month = _examDate.month.toString().padLeft(2, '0');
    final String day = _examDate.day.toString().padLeft(2, '0');
    return '${_examDate.year}-$month-$day';
  }

  /// 切换考试类型。切走时清掉自定义输入框的内容（避免残留的旧名称
  /// 在切回「自定义」时莫名出现在输入框里）。
  void _selectType(String value) {
    if (_examType == value) return;
    setState(() {
      _examType = value;
      if (value != 'custom') {
        _customCtrl.clear();
        _customError = null;
      }
    });
  }

  Future<void> _submit() async {
    final String custom = _customCtrl.text.trim();

    // 自定义类型的名称：必填 + ≤20 字。前端先拦一道，别只靠后端 400。
    if (_isCustom) {
      if (custom.isEmpty) {
        setState(() => _customError = '请填写自定义名称');
        await _alert('无法提交', '请填写「自定义名称」，它会作为这个考试类型的名字。');
        return;
      }
      if (custom.length > kExamTypeCustomMaxLength) {
        setState(
          () => _customError =
              '自定义名称不能超过 $kExamTypeCustomMaxLength 个字',
        );
        return;
      }
    }

    // `target_label`：用户填了就用用户的；自定义类型下留空则用自定义名称
    // 兜底（后端 AC-EXAM-01 要求 target_score 或 target_label 至少一个非空）。
    final String label = _labelCtrl.text.trim().isEmpty
        ? (custom)
        : _labelCtrl.text.trim();
    if (label.isEmpty) {
      await _alert('无法提交', '请填写「目标名称」，它是这个考试目标的唯一标识。');
      return;
    }

    // 数字字段留空 = 不传这个键（不是传空串）。
    final double? score = double.tryParse(_scoreCtrl.text.trim());
    final int? minutes = int.tryParse(_minutesCtrl.text.trim());
    final String scope = _scopeCtrl.text.trim();

    setState(() => _submitting = true);
    try {
      final Map<String, Object?> initial = widget.initial ?? const <String, Object?>{};
      final String? profileId = widget.initial == null
          ? null
          : (initial['id'] is String ? initial['id']! as String : null);
      final int? baseVersion = widget.initial == null
          ? null
          : _versionOf(initial);
      if (widget.initial != null && (profileId == null || baseVersion == null)) {
        await _alert('无法保存', '这条考试目标缺少有效的 id 或版本号，请返回列表下拉刷新后重试。');
        return;
      }
      final Map<String, Object?> raw = widget.initial == null
          ? await _api.createExamProfile(
              userId: kDemoUserId,
              examType: _examType,
              targetLabel: label,
              examDate: _examDateText,
              targetScore: score,
              dailyMinutes: minutes,
              sourceScope: scope,
              examTypeCustom: _isCustom ? custom : null,
            )
          : await _api.updateExamProfile(
              profileId!,
              version: baseVersion!,
              examType: _examType,
              // 只有用户真的填了自定义名称才传：本地表没这列，回填时
              // 拿不到原值，硬传空串会覆盖掉云端已有的自定义名称。
              examTypeCustom: (_isCustom && custom.isNotEmpty) ? custom : null,
              targetLabel: label,
              examDate: _examDateText,
              targetScore: score,
              dailyMinutes: minutes,
              sourceScope: scope,
            );
      if (!mounted) return;

      if (widget.initial != null) {
        // 编辑模式：不报「预置科目」，只确认保存。
        await _alert('已保存', '考试目标已更新，首页卡片会同步刷新。');
      } else {
        final int preset = _countSubjects(raw);
        await _alert(
          '创建成功',
          preset > 0
              ? '已为你预置 $preset 个科目，可以直接进入科目管理补充考点。'
              : '请进入科目管理手动添加',
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      await _alert(widget.initial == null ? '创建失败' : '保存失败', _errorText(e));
    }
  }

  /// ApiException 有面向用户的中文 message；其它异常退化成异常文本。
  String _errorText(Object e) {
    if (e is ApiException) return e.message;
    return '$e';
  }

  /// 201 的 body 是 `{profile, subjects}`（不是裸 profile）。
  /// 兼容「裸 profile」与「subjects 为 null」两种意外形状，一律回 0。
  int _countSubjects(Object? raw) {
    if (raw is Map) {
      final Object? subjects = raw['subjects'];
      if (subjects is List) return subjects.length;
    }
    return 0;
  }

  Future<void> _alert(String title, String message) {
    return showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: Text(
          title,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            message,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.35,
              color: AppColors.label,
            ),
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '好',
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

  /// 「每日可用分钟」说明弹窗。
  ///
  /// 本工程全前端没有任何 Flutter `Tooltip` 组件先例（grep Tooltip 零命中），
  /// 所以这里用 CupertinoAlertDialog 而不是引入 Tooltip。
  Future<void> _showDailyMinutesHelp() {
    return showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '每日可用分钟',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            kDailyMinutesHelp,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.35,
              color: AppColors.label,
            ),
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '知道了',
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
            previousPageTitle: '返回',
            largeTitle: Text(
              widget.initial == null ? '新建考试目标' : '编辑考试目标',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                color: AppColors.label,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            sliver: SliverList.list(
              children: <Widget>[
                _sectionTitle('考试类型'),
                _card(child: _buildTypeChips()),
                if (_isCustom) ...<Widget>[
                  const SizedBox(height: 20),
                  _sectionTitle('自定义名称'),
                  _card(
                    child: FormFieldGroup(
                      label: '自定义名称',
                      required: true,
                      error: _customError,
                      child: FormTextField(
                        controller: _customCtrl,
                        placeholder: '例如：公司法务岗考试',
                        hasError: _customError != null,
                        onChanged: (String _) {
                          if (_customError != null) {
                            setState(() => _customError = null);
                          }
                        },
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                _sectionTitle('目标名称'),
                _card(
                  child: _field(
                    controller: _labelCtrl,
                    placeholder: '例如：2026 省考 A 类',
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle('目标分数（可选）'),
                _card(
                  child: _field(
                    controller: _scoreCtrl,
                    placeholder: '例如：130',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle('考试日期'),
                _card(child: _buildDateSection()),
                const SizedBox(height: 20),
                _sectionTitle(
                  '每日可用分钟',
                  trailing: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _submitting ? null : _showDailyMinutesHelp,
                    child: const SizedBox(
                      width: 24,
                      height: 24,
                      child: Icon(
                        CupertinoIcons.info_circle,
                        size: 16,
                        color: AppColors.secondaryLabel,
                      ),
                    ),
                  ),
                ),
                _card(
                  child: _field(
                    controller: _minutesCtrl,
                    placeholder: '例如：120',
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle('资料范围（可选）'),
                _card(
                  child: _field(
                    controller: _scopeCtrl,
                    placeholder: '例如：教材 + 近五年真题',
                  ),
                ),
                const SizedBox(height: 28),
                _buildSubmitButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 小标题。[trailing] 用于在标题行右侧挂图标按钮（如「每日可用分钟」的
  /// 说明图标）。
  Widget _sectionTitle(String text, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(
        children: <Widget>[
          Text(
            text,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.secondaryLabel,
            ),
          ),
          if (trailing != null) ...<Widget>[
            const Spacer(),
            trailing,
          ],
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
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
      child: child,
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String placeholder,
    TextInputType? keyboardType,
  }) {
    return CupertinoTextField(
      controller: controller,
      placeholder: placeholder,
      keyboardType: keyboardType,
      enabled: !_submitting,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      placeholderStyle: const TextStyle(
        fontFamily: kFontFamily,
        fontSize: 15,
        color: AppColors.tertiaryLabel,
      ),
      style: const TextStyle(
        fontFamily: kFontFamily,
        fontSize: 15,
        color: AppColors.label,
      ),
      decoration: BoxDecoration(
        color: AppColors.groupedBackground,
        borderRadius: BorderRadius.circular(AppRadii.chip),
      ),
    );
  }

  Widget _buildTypeChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final ({String value, String label}) type in kExamTypeOptions)
          _OptionChip(
            label: type.label,
            selected: _examType == type.value,
            onTap: _submitting ? null : () => _selectType(type.value),
          ),
      ],
    );
  }

  Widget _buildDateSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _datePickerOpen = !_datePickerOpen),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _examDateText,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 16,
                    color: AppColors.label,
                  ),
                ),
              ),
              Icon(
                _datePickerOpen
                    ? CupertinoIcons.chevron_up
                    : CupertinoIcons.chevron_down,
                size: 16,
                color: AppColors.tertiaryLabel,
              ),
            ],
          ),
        ),
        if (_datePickerOpen) ...<Widget>[
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: CupertinoDatePicker(
              mode: CupertinoDatePickerMode.date,
              initialDateTime: _examDate,
              // 允许往前选：已经考过一次、想补录历史目标也说得通。
              minimumDate: DateTime(2000),
              maximumDate: DateTime(2100),
              dateOrder: DatePickerDateOrder.ymd,
              onDateTimeChanged: (DateTime value) {
                setState(() {
                  _examDate = DateTime(value.year, value.month, value.day);
                });
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: CupertinoButton(
        color: AppColors.accent,
        // 传了 color 之后文字默认仍取主题 primaryColor（= accent），
        // 不显式给前景色会变成「蓝底蓝字」。
        foregroundColor: CupertinoColors.white,
        borderRadius: BorderRadius.circular(AppRadii.chip),
        onPressed: _submitting ? null : _submit,
        child: _submitting
            ? const CupertinoActivityIndicator(radius: 10)
            : Text(
                widget.initial == null ? '创建考试目标' : '保存修改',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.white,
                ),
              ),
      ),
    );
  }
}

/// 单选 chip：选中 = 主色描边 + 淡底，未选中 = 灰描边。
class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color fg = selected ? AppColors.accent : AppColors.secondaryLabel;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? const Color(0x14007AFF) : AppColors.groupedBackground,
          borderRadius: BorderRadius.circular(AppRadii.chip),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.separator,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: fg,
          ),
        ),
      ),
    );
  }
}
