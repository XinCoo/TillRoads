// 表单共用组件（FE-03 写操作联调）。
//
// 为什么单独抽一个文件：建单页、归因页、验证页三处都要用
// 「带标题的输入区 + 内联红字错误 + chip 单选组 + 动态列表行」，
// 复制三份会让 iOS 风格细节（圆角、字号、错误色）漂移。
//
// 刻意不引表单库：字段数最多 6 个，手写 `TextEditingController` 更可控，
// 也满足任务书「不引第三方表单库」的硬约束。

import 'package:flutter/cupertino.dart';

import '../theme/app_theme.dart';

/// 表单中的一段：小标题 + 内容 + 可选错误提示。
///
/// 错误用**内联红字**而不是弹窗 —— iOS 原生的表单校验就是在字段下方给红字，
/// 弹 alert 会打断输入流（任务书也明确要求内联）。
class FormFieldGroup extends StatelessWidget {
  const FormFieldGroup({
    super.key,
    required this.label,
    required this.child,
    this.hint,
    this.error,
    this.required = false,
  });

  /// 字段名，如「题型 / 考点摘要」。
  final String label;

  /// 字段控件本体。
  final Widget child;

  /// 补充说明（灰色小字，常驻）。
  final String? hint;

  /// 校验错误（红字）。非空时显示，并让标签变红。
  final String? error;

  /// 是否标红星（视觉提示，不做校验逻辑）。
  final bool required;

  @override
  Widget build(BuildContext context) {
    final hasError = error != null && error!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.cardGap + 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: hasError ? AppColors.overdue : AppColors.label,
                ),
              ),
              if (required)
                const Padding(
                  padding: EdgeInsets.only(left: 2),
                  child: Text(
                    '*',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.overdue,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          child,
          if (hint != null && hint!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              hint!,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                height: 1.35,
                color: AppColors.tertiaryLabel,
              ),
            ),
          ],
          if (hasError) ...<Widget>[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(
                    CupertinoIcons.exclamationmark_circle_fill,
                    size: 13,
                    color: AppColors.overdue,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    error!,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12,
                      height: 1.35,
                      color: AppColors.overdue,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 单行 / 多行输入框（Cupertino 风格，白底圆角）。
class FormTextField extends StatelessWidget {
  const FormTextField({
    super.key,
    required this.controller,
    this.placeholder,
    this.maxLines = 1,
    this.autofocus = false,
    this.hasError = false,
    this.textInputAction,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? placeholder;
  final int maxLines;
  final bool autofocus;

  /// 有错误时描边变红，与 `FormFieldGroup.error` 联动。
  final bool hasError;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.chip + 2),
        border: Border.all(
          color: hasError ? AppColors.overdue : AppColors.separator,
          width: hasError ? 1 : 0.5,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: CupertinoTextField.borderless(
        controller: controller,
        placeholder: placeholder,
        placeholderStyle: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 15,
          color: AppColors.tertiaryLabel,
        ),
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 15,
          height: 1.4,
          color: AppColors.label,
        ),
        maxLines: maxLines,
        autofocus: autofocus,
        textInputAction: textInputAction,
        onChanged: onChanged,
        padding: EdgeInsets.zero,
      ),
    );
  }
}

/// chip 单选组（用于 priority / error_layer / verify_type / result 这类小集合）。
///
/// 不用 `CupertinoSegmentedControl`：它把选项文字截断成等宽段，
/// 「策略取舍」「稳定迁移」这类 4 字标签会被压成省略号。
class FormChipGroup extends StatelessWidget {
  const FormChipGroup({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.labelOf,
    this.colorOf,
  });

  /// 选项值（wire 形式，如 `'P0'`、`'redo_hidden'`）。
  final List<String> options;

  /// 当前选中值；null 表示未选。
  final String? selected;

  final ValueChanged<String> onChanged;

  /// 值 → 显示文案（默认原样显示）。
  final String Function(String value)? labelOf;

  /// 值 → 选中态颜色（默认主色）。用于 priority 三档着色。
  final Color Function(String value)? colorOf;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((String option) {
        final bool active = option == selected;
        final Color accent = colorOf?.call(option) ?? AppColors.accent;
        return GestureDetector(
          onTap: () => onChanged(option),
          child: AnimatedContainer(
            duration: AppDurations.countdown,
            curve: Curves.easeInOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: active ? accent : AppColors.card,
              borderRadius: BorderRadius.circular(AppRadii.chip + 4),
              border: Border.all(
                color: active ? accent : AppColors.separator,
                width: active ? 0 : 0.5,
              ),
            ),
            child: Text(
              labelOf?.call(option) ?? option,
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? CupertinoColors.white : AppColors.label,
              ),
            ),
          ),
        );
      }).toList(growable: false),
    );
  }
}

/// 提交按钮（内联 loading 态）。
///
/// `CupertinoButton.filled` 在 `onPressed == null` 时自动置灰，
/// 所以 loading 期间把 onPressed 传 null 即可，不必手写禁用样式。
class FormSubmitButton extends StatelessWidget {
  const FormSubmitButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: CupertinoButton(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(AppRadii.chip + 4),
        padding: const EdgeInsets.symmetric(vertical: 14),
        onPressed: busy ? null : onPressed,
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CupertinoActivityIndicator(
                  radius: 9,
                  color: CupertinoColors.white,
                ),
              )
            : Text(
                label,
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

/// 顶部错误条（网络错误 / 409 冲突 / 403 等无法内联到具体字段的错误）。
///
/// 与字段级红字的分工：
///   * 能定位到字段 → `FormFieldGroup.error`（内联）；
///   * 不能定位（后端不可达、版本冲突） → 本组件（顶部条）。
class FormErrorBanner extends StatelessWidget {
  const FormErrorBanner({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.cardGap),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.dueSoon.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.chip + 2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              CupertinoIcons.exclamationmark_triangle_fill,
              size: 16,
              color: AppColors.dueSoon,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                height: 1.4,
                color: AppColors.label,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(width: 8),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: onAction,
              child: Text(
                actionLabel!,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 页面外壳：白底 + 大标题导航 + 内边距，三张表单页共用。
class FormScaffold extends StatelessWidget {
  const FormScaffold({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final Widget? trailing;

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
            largeTitle: Text(
              title,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 30,
                fontWeight: FontWeight.w700,
              ),
            ),
            middle: Text(
              title,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            // 与首页/列表页一致：避免大标题与中间标题同时可见导致重影
            alwaysShowMiddle: false,
            trailing: trailing,
            border: const Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          SliverSafeArea(
            top: false,
            bottom: false,
            sliver: SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                12,
                AppSpacing.page,
                32,
              ),
              sliver: SliverList.list(children: children),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「没有任何内容」的行内提示（动作列表清空时用）。
class FormEmptyHint extends StatelessWidget {
  const FormEmptyHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 13,
          color: AppColors.tertiaryLabel,
        ),
      ),
    );
  }
}
