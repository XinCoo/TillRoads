import 'package:flutter/cupertino.dart';

import '../mock/defects_mock.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/defect_card.dart';
import 'defect_detail_page.dart';

/// 缺陷单列表页（FE-03A）
///
/// 数据全部来自 `lib/mock/defects_mock.dart` 的 `kDefectTickets`，
/// 不连后端、不发 HTTP。
///
/// 列表用 `CustomScrollView` + `CupertinoSliverNavigationBar`，
/// 这样滚动时大标题会连续插值折叠成导航栏标题（FE-01 定下的动效规格）。
class DefectsPage extends StatefulWidget {
  const DefectsPage({super.key});

  @override
  State<DefectsPage> createState() => _DefectsPageState();
}

class _DefectsPageState extends State<DefectsPage> {
  DefectFilter _filter = DefectFilter.all;

  List<DefectTicket> get _visible =>
      kDefectTickets.where((DefectTicket t) => _filter.matches(t)).toList();

  /// 每个分组下的条数（用于 chip 右侧小数字）
  Map<DefectFilter, int> get _counts {
    final Map<DefectFilter, int> result = <DefectFilter, int>{};
    for (final DefectFilter f in DefectFilter.values) {
      result[f] = kDefectTickets.where((DefectTicket t) => f.matches(t)).length;
    }
    return result;
  }

  void _showNewTicketHint() {
    // CupertinoAlertDialog 硬编码 CupertinoSystemText，只能逐 Text 覆盖
    showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: Text(
          '新建缺陷单',
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        content: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '建单与归因功能将在 FE-02 / FE-04 实现。',
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
      ),
    );
  }

  void _openDetail(DefectTicket ticket) {
    // appRoute 在 Reduce Motion 下自动降级为 200ms 淡入淡出，
    // 否则用 CupertinoPageRoute（右滑入 + 旧页 30% 视差）
    Navigator.of(context).push(
      appRoute<void>(context, DefectDetailPage(ticket: ticket)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<DefectTicket> visible = _visible;

    return CupertinoPageScaffold(
      backgroundColor: AppColors.groupedBackground,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: const Text(
              '缺陷单',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.37,
                color: AppColors.label,
              ),
            ),
            middle: const Text(
              '缺陷单',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.4,
                color: AppColors.label,
              ),
            ),
            // 大标题展开时不重复显示中间的「缺陷单」
            alwaysShowMiddle: false,
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: _showNewTicketHint,
              child: const Text(
                '新建',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
            border: const Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),

          // ── 筛选条（随内容一起滚动）──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 12),
              child: FilterChipRow(
                selected: _filter,
                counts: _counts,
                onChanged: (DefectFilter next) {
                  if (next == _filter) return;
                  setState(() => _filter = next);
                },
              ),
            ),
          ),

          // ── 列表 / 空状态 ──
          if (visible.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: CupertinoIcons.doc_text,
                title: '还没有缺陷单',
                message: _filter == DefectFilter.all
                    ? '暂无数据，从一次模考或错题开始'
                    : '「${_filter.label}」分组下暂无缺陷单',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                0,
                AppSpacing.page,
                24,
              ),
              sliver: SliverList.separated(
                itemCount: visible.length,
                separatorBuilder: (_, _) => const SizedBox(
                  height: AppSpacing.cardGap,
                ),
                itemBuilder: (BuildContext context, int index) {
                  final DefectTicket ticket = visible[index];
                  return DefectCard(
                    ticket: ticket,
                    onTap: () => _openDetail(ticket),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
