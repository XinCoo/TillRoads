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
// ── 日期为什么手拼 'YYYY-MM-DD' ─────────────────────────────────────────
// `validateExamDate` 也接受 ISO datetime，但 `exam_date` 是 date 列，
// 带 `T00:00:00.000` 会被 PG 截断；且列表页按 'YYYY-MM-DD' 展示，
// 两处格式统一才不会有「提交 2026-03-01T00:00:00 却显示 2026-03-01」的割裂。

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show TextInputType;

import '../api/api_client.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';

/// `schema.sql:46-48` 的 exam_type 枚举（顺序即 UI 顺序）。
///
/// 值与标签必须与后端 ENUM 逐字一致：拼错不会被前端拦住，
/// 但会以 `400 INVALID_EXAM_TYPE` 的形式在提交时才失败。
const List<({String value, String label})> _kExamTypes =
    <({String value, String label})>[
  (value: 'civil_service', label: '公务员'),
  (value: 'postgrad', label: '考研'),
  (value: 'final_exam', label: '期末'),
  (value: 'vocational', label: '职业资格'),
  (value: 'adult_self_study', label: '成人自考'),
];

class ExamProfileCreatePage extends StatefulWidget {
  const ExamProfileCreatePage({super.key});

  @override
  State<ExamProfileCreatePage> createState() => _ExamProfileCreatePageState();
}

class _ExamProfileCreatePageState extends State<ExamProfileCreatePage> {
  final ApiClient _api = ApiClient();

  final TextEditingController _labelCtrl = TextEditingController();
  final TextEditingController _scoreCtrl = TextEditingController();
  final TextEditingController _minutesCtrl = TextEditingController(text: '120');
  final TextEditingController _scopeCtrl = TextEditingController();

  String _examType = 'civil_service';
  late DateTime _examDate;
  bool _datePickerOpen = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // 默认 90 天后：给一个「备考周期约三个月」的合理起点，
    // 用户不改也能直接提交（exam_date 是 AC-EXAM-01 的必填项）。
    final DateTime now = DateTime.now();
    _examDate = DateTime(now.year, now.month, now.day).add(
      const Duration(days: 90),
    );
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _scoreCtrl.dispose();
    _minutesCtrl.dispose();
    _scopeCtrl.dispose();
    _api.close();
    super.dispose();
  }

  /// 手拼 'YYYY-MM-DD'（不用 toIso8601String：它会带上 T00:00:00.000）。
  String get _examDateText {
    final String month = _examDate.month.toString().padLeft(2, '0');
    final String day = _examDate.day.toString().padLeft(2, '0');
    return '${_examDate.year}-$month-$day';
  }

  Future<void> _submit() async {
    final String label = _labelCtrl.text.trim();
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
      final Map<String, Object?> body = <String, Object?>{
        'user_id': kDemoUserId,
        'exam_type': _examType,
        'target_label': label,
        'exam_date': _examDateText,
        if (score != null) 'target_score': score,
        if (minutes != null) 'daily_minutes': minutes,
        // jsonb 列：必须给合法 JSON 文本，{'raw': ...} 由 toJsonbParam 序列化。
        if (scope.isNotEmpty) 'source_scope': <String, Object?>{'raw': scope},
      };

      final Object? raw = await _api.post('/exam-profiles', body: body);
      if (!mounted) return;

      final int preset = _countSubjects(raw);
      await _alert(
        '创建成功',
        preset > 0
            ? '已为你预置 $preset 个科目，可以直接进入科目管理补充考点。'
            : '请进入科目管理手动添加',
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      await _alert('创建失败', e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      await _alert('创建失败', '$e');
    }
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

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: <Widget>[
          const CupertinoSliverNavigationBar(
            previousPageTitle: '返回',
            largeTitle: Text(
              '新建考试目标',
              style: TextStyle(
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
                _sectionTitle('每日可用分钟'),
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

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.secondaryLabel,
        ),
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
        for (final ({String value, String label}) type in _kExamTypes)
          _OptionChip(
            label: type.label,
            selected: _examType == type.value,
            onTap: _submitting
                ? null
                : () => setState(() => _examType = type.value),
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
            : const Text(
                '创建考试目标',
                style: TextStyle(
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
