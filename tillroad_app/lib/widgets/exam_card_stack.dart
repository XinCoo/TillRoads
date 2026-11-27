import 'package:flutter/cupertino.dart';

import '../theme/app_theme.dart';
import 'exam_flip_card.dart';

/// 首页「考试目标」卡片堆叠容器（m29656 任务 B）。
///
/// 为什么选 PageView（B3 要求「二选一并说明理由」）：
///   1. PageView 自带「拖拽跟手 + 松手吸附」，`PageScrollPhysics` 在松手时用
///      弹簧收敛到目标页，正好是 B8 要的「跟手 + 松手回弹或完成」；
///   2. 边界行为免费：第一张右滑 / 最后一张左滑被 `ClampingScrollPhysics` 挡住，
///      不需要自己写 clamp 与越界回弹；
///   3. B6 要求「单击翻转 / 长按编辑 / 水平滑动切卡」三者互斥：PageView 的水平
///      拖拽识别器与卡片内的 Tap / LongPress 进的是同一个手势竞技场，拖拽必须
///      位移超过 kTouchSlop（18px）才可能胜出，因此三者天然互斥。若自己写
///      `GestureDetector` + `AnimationController`，这套竞技场、位移阈值、速度
///      阈值、松手吸附全得手写，反而更容易出现「单击与滑动同时触发」。
///
/// 与 `ExamFlipCard` 的分工：本组件只管堆叠、翻页与长按路由；单卡翻面仍在
/// `ExamFlipCard` 内部完成。切页时通过 `flipResetToken` 让卡片复位到正面
/// （B4：翻转状态不跨卡片保留）。
class ExamCardStack extends StatefulWidget {
  const ExamCardStack({
    super.key,
    required this.profiles,
    required this.onEdit,
    required this.daysUntil,
    this.onOverflowTap,
    this.onIndexChanged,
  }) : assert(profiles.length > 0, '空列表请由调用方渲染空状态');

  /// 全部考试目标，第 0 条在最上层（顺序即堆叠顺序）。
  final List<Map<String, Object?>> profiles;

  /// 长按某张卡（≥500ms）→ 进入编辑。参数是被长按的那条 profile。
  final ValueChanged<Map<String, Object?>> onEdit;

  /// 距考试天数。复用 home_page 的本地时区算法，避免两处口径不一致。
  final int Function(Object? examDate) daysUntil;

  /// 点最深一层的「+N」徽标（堆叠超过 3 层时出现）。
  final VoidCallback? onOverflowTap;

  /// 当前卡片变化时回调（父层用它同步「当前是哪一张」，
  /// 比如建题时要知道该建在哪个考试目标下）。
  final ValueChanged<int>? onIndexChanged;

  @override
  State<ExamCardStack> createState() => _ExamCardStackState();
}

/// 卡片堆叠的几何参数（B2）。
class _StackMetrics {
  const _StackMetrics._();

  /// 层间高度差：约 12px。
  static const double layerGap = 12.0;

  /// 第 2 层（当前卡后面第一层）缩放。
  static const double scale1 = 0.95;

  /// 第 3 层（最深一层）缩放。
  static const double scale2 = 0.90;


  /// 单个分页的高度 = 单卡高度 + 最深一层的下移量（层差 × 2）。
  static const double pageHeight = kExamFlipCardHeight + layerGap * 2;
}

/// B6 的滑动位移阈值（写死，不靠运气）。与 Flutter 的 `kTouchSlop` 恰好都是 18。
const double _kSwipeDistance = 18.0;

/// B6 的速度阈值。
const double _kSwipeVelocity = 300.0;

/// 把 PageView 的「甩动速度阈值」从默认 `kMinFlingVelocity`（50px/s）
/// 抬到任务书要求的 300px/s：不到 300 的轻扫只回弹到原页，超过 300 才翻页。
class _CardPageScrollPhysics extends PageScrollPhysics {
  const _CardPageScrollPhysics({super.parent});

  @override
  double get minFlingVelocity => _kSwipeVelocity;

  @override
  _CardPageScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _CardPageScrollPhysics(parent: buildParent(ancestor));
  }
}

class _ExamCardStackState extends State<ExamCardStack> {
  late final PageController _controller = PageController();
  int _index = 0;

  /// 每次切页 +1：传给所有 `ExamFlipCard`，让它把翻转角与已拉到的进度归零
  /// （B4「翻转状态不跨卡片保留」）。
  int _flipToken = 0;

  /// Reduce Motion 下自己累计横向拖拽位移（那时不用 PageView）。
  double _dragDx = 0;

  @override
  void didUpdateWidget(covariant ExamCardStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表条数变化（编辑/新建/删除后刷新）时把索引夹回合法范围。
    if (_index >= widget.profiles.length) {
      _index = widget.profiles.length - 1;
      if (_controller.hasClients) {
        _controller.jumpToPage(_index);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _reduceMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  void _goTo(int next) {
    if (next == _index) return;
    setState(() {
      _index = next;
      // 切页即复位：保证滑到下一张时是正面（B4）。
      _flipToken++;
    });
    widget.onIndexChanged?.call(next);
  }

  void _onPageChanged(int value) {
    setState(() {
      _index = value;
      _flipToken++;
    });
    widget.onIndexChanged?.call(value);
  }

  /// 当前滚动进度（驱动堆叠跟手联动）。没有 position 时退回整页索引。
  double get _pageOffset {
    if (_controller.hasClients && _controller.position.haveDimensions) {
      return _controller.page ?? _index.toDouble();
    }
    return _index.toDouble();
  }

  String _labelOf(Map<String, Object?> profile) {
    final Object? raw = profile['target_label'];
    return (raw is String && raw.trim().isNotEmpty) ? raw.trim() : '我的考试';
  }

  String _dateTextOf(Map<String, Object?> profile) {
    final Object? raw = profile['exam_date'];
    return (raw is String) ? raw.trim() : '';
  }

  Widget _frontCard(int index) {
    final Map<String, Object?> profile = widget.profiles[index];
    return ExamFlipCard(
      // 用 id 做 key：列表刷新时避免把 A 的翻转/进度状态错挂到 B 上。
      key: ValueKey<String>('exam-card-${profile['id'] ?? index}'),
      examProfileId: '${profile['id'] ?? ''}',
      examLabel: _labelOf(profile),
      examDateText: _dateTextOf(profile),
      daysToExam: widget.daysUntil(profile['exam_date']),
      flipResetToken: _flipToken,
      onLongPress: () => widget.onEdit(profile),
    );
  }

  /// 后面某一层的「卡背」：一块同高的空卡壳。
  ///
  /// 刻意不复用 `ExamFlipCard`：后面两层永远看不到内容，用完整的有状态卡片
  /// 只会白建 HTTP client、白挂动画控制器。
  Widget _stackShell({
    required double scale,
    required double top,
    String? overflowLabel,
  }) {
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: IgnorePointer(
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.topCenter,
          child: Container(
            height: kExamFlipCardHeight,
            alignment: Alignment.topRight,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[Color(0xFFEAF2FF), Color(0xFFFFFFFF)],
              ),
              borderRadius: BorderRadius.circular(AppRadii.card),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x0F000000),
                  blurRadius: 12,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: overflowLabel == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 10, right: 14),
                    child: GestureDetector(
                      onTap: widget.onOverflowTap,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          overflowLabel,
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  /// 一页 = 当前卡（最上层）+ 后面最多 2 层空卡壳（B2）。
  ///
  /// 跟手联动：本页被拖出多少（progress 0→1），后面两层就往当前卡收拢多少，
  /// 读起来像「卡片被抽走、下一张顶上来」。
  Widget _buildPageLayers(int index) {
    final double progress =
        (_pageOffset - index).abs().clamp(0.0, 1.0).toDouble();
    final double settle = _StackMetrics.layerGap * progress;

    final List<Widget> layers = <Widget>[];
    // 先画最深的，再画较浅的，最后画当前卡（Stack 后画的在上）。
    if (index + 2 < widget.profiles.length) {
      final int hidden = widget.profiles.length - (index + 3);
      layers.add(_stackShell(
        scale: _StackMetrics.scale2,
        top: _StackMetrics.layerGap * 2 - settle,
        overflowLabel: hidden > 0 ? '+$hidden' : null,
      ));
    }
    if (index + 1 < widget.profiles.length) {
      layers.add(_stackShell(
        scale: _StackMetrics.scale1,
        top: _StackMetrics.layerGap - settle / 2,
      ));
    }
    layers.add(Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Transform.scale(
        // 当前卡滑出时轻微缩小，读起来像「这张卡正被翻过去」。
        scale: 1 - 0.05 * progress,
        alignment: Alignment.topCenter,
        child: _frontCard(index),
      ),
    ));

    return SizedBox(
      height: _StackMetrics.pageHeight,
      child: Stack(clipBehavior: Clip.none, children: layers),
    );
  }

  Widget _buildPage(int index) {
    // 滚动过程中每帧重算堆叠位置（每页都很轻：一张卡 + 两个空壳）。
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) =>
          _buildPageLayers(index),
    );
  }

  /// Reduce Motion（B8 第三处降级）：
  ///   · 不渲染堆叠层（单卡、无缩放）；
  ///   · 切卡改为淡入淡出，不做横向位移；
  ///   · 翻转动画由 `ExamFlipCard` 自己降级成「直接换面」。
  Widget _buildReduceMotion() {
    void handleEnd(DragEndDetails details) {
      final double velocity = details.primaryVelocity ?? 0;
      final bool farEnough = _dragDx.abs() > _kSwipeDistance;
      final bool fastEnough = velocity.abs() > _kSwipeVelocity;
      // 方向以位移为主、速度为辅；两者矛盾时听位移的。
      final double direction = farEnough ? _dragDx : velocity;
      int next = _index;
      if ((farEnough || fastEnough) && direction != 0) {
        next = direction < 0
            ? (_index + 1).clamp(0, widget.profiles.length - 1)
            : (_index - 1).clamp(0, widget.profiles.length - 1);
      }
      _dragDx = 0;
      _goTo(next);
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (DragStartDetails details) => _dragDx = 0,
      onHorizontalDragUpdate: (DragUpdateDetails details) =>
          _dragDx += details.delta.dx,
      onHorizontalDragEnd: handleEnd,
      child: SizedBox(
        height: _StackMetrics.pageHeight,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (Widget child, Animation<double> animation) =>
              FadeTransition(opacity: animation, child: child),
          child: KeyedSubtree(
            key: ValueKey<int>(_index),
            child: Align(
              alignment: Alignment.topCenter,
              child: _frontCard(_index),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_reduceMotion) return _buildReduceMotion();
    // 单卡（B2：单卡片无堆叠，与改造前外观一致）。
    if (widget.profiles.length == 1) {
      return SizedBox(
        height: _StackMetrics.pageHeight,
        child: Align(alignment: Alignment.topCenter, child: _frontCard(0)),
      );
    }
    return SizedBox(
      height: _StackMetrics.pageHeight,
      child: PageView.builder(
        controller: _controller,
        // ClampingScrollPhysics：第一张右滑 / 最后一张左滑被夹住（B3）。
        physics: const _CardPageScrollPhysics(parent: ClampingScrollPhysics()),
        itemCount: widget.profiles.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (BuildContext context, int index) => _buildPage(index),
      ),
    );
  }
}
