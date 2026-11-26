import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../api/exam_progress_api.dart';
import '../theme/app_theme.dart';

/// 考试目标卡片：正面是「名称 + 距考试天数」，背面是「学习进度」。
///
/// 为什么要翻转：
///   首页顶部这块是用户每天第一眼看到的地方。正面放倒计时（最关心的「还有多久考试」），
///   背面放「今天学了多少 / 做了几道 / 正确率」——这两组信息都想占第一屏，
///   但塞在一张卡里会挤成一团。翻转让用户在需要时把进度翻出来，不看时又只有倒计时。
///
/// 翻转动效用 3D（rotateY）而不是 crossfade：
///   crossfade 读起来像「内容被换掉了」，而 3D 翻转读起来像「同一张卡翻了一面」，
///   符合 iOS 的空间感。300ms 是 iOS 常用的轻交互时长。
///
/// 无障碍：
///   · 整卡是一个可聚焦控件（Focus + onKeyEvent），键盘 Enter / Space 也能翻；
///   · Semantics(button: true, label: …) 让读屏软件把它当按钮念出来；
///   · 开启「减弱动态效果」（系统设置 → 辅助功能 → 减弱动态效果）时直接切换，
///     不做 3D 旋转。
class ExamFlipCard extends StatefulWidget {
  const ExamFlipCard({
    super.key,
    required this.examProfileId,
    required this.examLabel,
    required this.examDateText,
    required this.daysToExam,
  });

  /// 考试目标 id（用来拉学习进度）。
  final String examProfileId;

  /// 正面标题（考试名称）。
  final String examLabel;

  /// 正面副标题（考试日期，形如 2027-01-04）。
  final String examDateText;

  /// 距离考试的天数。
  final int daysToExam;

  @override
  State<ExamFlipCard> createState() => _ExamFlipCardState();
}

class _ExamFlipCardState extends State<ExamFlipCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  /// 进度 API。**持有实例**而不是每次现建：ApiClient 内部持 http.Client，
  /// 每次 new 都会多一个连接池，且不 close 会漏连接。dispose 时统一关。
  final ExamProgressApi _progressApi = ExamProgressApi();
  /// null = 还没翻到背面 / 还没拉过数据。
  ExamProgress? _progress;
  /// 进度拉取中。
  bool _loadingProgress = false;

  /// 进度拉取失败。
  bool _progressFailed = false;

  bool get _isBack => _controller.value > 0.5;

  @override
  void dispose() {
    _controller.dispose();
    _progressApi.close();
    super.dispose();
  }

  Future<void> _flip() async {
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      // 减弱动态效果：不做旋转，直接换面。
      setState(() {
        if (_controller.value > 0.5) {
          _controller.value = 0;
        } else {
          _controller.value = 1;
        }
      });
    } else {
      if (_controller.value > 0.5) {
        await _controller.reverse();
      } else {
        await _controller.forward();
      }
    }
    if (_isBack) await _ensureProgress();
  }

  /// 翻到背面时才拉进度：正面的倒计时不需要网络，
  /// 不该让首页一进来就打三个接口（实测冷启动期 Neon/Railway 冷启动会拖 10s+）。
  Future<void> _ensureProgress() async {
    if (_progress != null || _loadingProgress) return;
    setState(() {
      _loadingProgress = true;
      _progressFailed = false;
    });
    try {
      final ExamProgress progress =
          await _progressApi.fetchProgress(widget.examProfileId);
      if (!mounted) return;
      setState(() {
        _progress = progress;
        _loadingProgress = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingProgress = false;
        _progressFailed = true;
      });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      unawaitedFlip();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void unawaitedFlip() {
    _flip();
  }

  @override
  Widget build(BuildContext context) {
    // 这里的 reduceMotion 只用于「是否要做 3D 翻转」；
    // 实际判断在 _flip() 内部（那时才读得到最新的 MediaQuery）。
    // build 里不需要再算一份，否则 analyzer 会报 unused_local_variable。
    return Semantics(
      button: true,
      label: '考试目标卡片，当前显示${_isBack ? '学习进度' : '考试倒计时'}，按回车或空格切换',
      child: Focus(
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _flip,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (BuildContext context, Widget? child) {
              final double t = _controller.value;
              // 0 → 正面（0 度）；1 → 背面（180 度）。
              final double angle = t * 3.141592653589793;
              final Matrix4 matrix = Matrix4.identity()
                ..setEntry(3, 2, 0.0012)
                ..rotateY(angle);
              final Widget face = t > 0.5
                  ? _buildBack()
                  : _buildFront();
              return Transform(
                alignment: Alignment.center,
                transform: matrix,
                child: Transform(
                  // 背面那一面在 180 度时是镜像的，再转 180 度把它转正。
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..rotateY(t > 0.5 ? 3.141592653589793 : 0.0),
                  child: face,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildFront() {
    return _shell(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  widget.examLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.examDateText.isEmpty
                      ? '距离考试'
                      : '${widget.examDateText} · 距离考试',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    color: AppColors.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                '${widget.daysToExam}',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 44,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: AppColors.label,
                  letterSpacing: -1,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 4),
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  '天',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: AppColors.secondaryLabel,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBack() {
    final ExamProgress? progress = _progress;
    return _shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  widget.examLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              const Text(
                '学习进度',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  color: AppColors.secondaryLabel,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_loadingProgress)
            const Row(
              children: <Widget>[
                CupertinoActivityIndicator(radius: 6),
                SizedBox(width: 8),
                Text(
                  '正在统计…',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    color: AppColors.secondaryLabel,
                  ),
                ),
              ],
            )
          else if (_progressFailed)
            const Text(
              '进度暂时取不到，检查网络后再试',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: AppColors.secondaryLabel,
              ),
            )
          else if (progress == null)
            const SizedBox.shrink()
          else
            _buildProgressBody(progress),
        ],
      ),
    );
  }

  Widget _buildProgressBody(ExamProgress progress) {
    final double? ratio = progress.minutesProgress;
    final int daily = progress.dailyMinutes ?? 0;
    final int used = progress.minutesUsed;
    final String minutesText = daily > 0
        ? '今天已学 $used / $daily 分钟'
        : '今天已学 $used 分钟';
    final String accuracyText = progress.accuracy == null
        ? '暂无正确率'
        : '正确率 ${(progress.accuracy! * 100).round()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          minutesText,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            color: AppColors.label,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 6,
            child: Stack(
              children: <Widget>[
                const ColoredBox(color: Color(0x14000000)),
                FractionallySizedBox(
                  widthFactor: ratio == null
                      ? 0.0
                      : ratio.clamp(0.0, 1.0).toDouble(),
                  child: const ColoredBox(color: AppColors.accent),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '完成 ${progress.questionsDone} 题',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  color: AppColors.secondaryLabel,
                ),
              ),
            ),
            Text(
              accuracyText,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                color: AppColors.secondaryLabel,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _shell({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.cardPadding,
        vertical: 18,
      ),
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
      child: child,
    );
  }
}
