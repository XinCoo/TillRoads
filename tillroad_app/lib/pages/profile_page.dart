// 「我的」页（FE-UI 重构：底部 Tab 5 → 3 后的第三个根页）。
//
// ── 这个页面存在的理由 ──────────────────────────────────────────────────
// 5 个 Tab 收敛成 3 个之后，「验证 / 模考 / 复盘」不再是并列分区，而是从
// 「我的」按需 push 的二级页。所以本页是那三个入口的**唯一收口处**：
// 首页只留一个「今日待验证」摘要位，「我的」负责把三块学习资产 + 设置
// 集中呈现，避免二级页在首页快捷入口里越堆越多。
//
// ── 为什么所有入口都是 push，不是切 Tab ─────────────────────────────────
// 只剩 3 个 Tab 时，「验证任务」不再是 Tab 之一。若仍用切 Tab 语义，就得
// 为它保留一个不存在的 Tab 索引（旧代码里 verify=2 / mock=3 / review=4），
// 一旦 Tab 数量变化，这些索引会静默指到别的页面。全部改 `appRoute()` push
// 后，导航意图用类型表达，不再依赖数字索引。
//
// ── 逐项降级（不整页报错）──────────────────────────────────────────────
// 数据概览的四格来自两路接口（defect-stats / verification-summary），
// **每一路各自 try/catch**，失败只让对应那几格显示「—」。理由与首页一致：
// Neon 免费版空闲会挂起，唤醒要 20–40s；若一个请求超时就把整页变错误页，
// 用户连「设置」「切换 Token」都点不了 —— 而这两件事恰恰是排查离线时的
// 第一反应。账户卡片与功能列表完全不依赖网络，必须无条件可用。
//
// ── 「验证完成率」的口径（重要，别改成想当然的算法）────────────────────
// 后端 `verification-summary` 只给**当前**处于 V1/V2/V3 的单量，没有
// 「历史已完成验证数」；能代表「验证走完」的只有 `defect-stats` 里的
// CLOSED —— 状态机（core/index.mjs）规定只有 V3 pass 才能进 CLOSED，
// 所以 `CLOSED / total` 就是严格意义上的验证完成率。
// 而 `verification-summary.total` 作为「进行中 N」的副标题展示，
// 两个数字并排才能看出「已完成 / 还在队列里」的真实比例。
import 'dart:async' show unawaited;

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart' show ApiException;
import '../api/defect_api.dart';
// 只取 summary 相关的两个类型：`VerificationTask` 与首页 mock 里的同名类型
// 不是一回事，这里不需要任务级模型，用 show 收窄可避免将来 ambiguous_import。
import '../api/verification_api.dart' show VerificationApi, VerificationSummary;
import '../config/api_config.dart';
import '../config/local_config.dart';
import '../local/local.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'api_token_page.dart';
import 'mock_page.dart';
import 'question_bank_page.dart';
import 'review_page.dart';
import 'settings_page.dart';
import 'verify_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final DefectApi _defectApi = DefectApi();
  final VerificationApi _verifyApi = VerificationApi();

  /// 缺陷聚合（`defect-stats`）。null 表示「尚未拿到」——用于把对应格子降级成「—」，
  /// 不额外维护 error 字段：本页的失败语义只有一种，就是「这项没有数字」。
  Map<String, Object?>? _stats;

  /// 验证摘要（`verification-summary`），只用来显示「进行中 N」。
  VerificationSummary? _summary;

  /// 首帧就按是否需要联网初始化，避免 mock 模式（含 widget test）里空转。
  bool _loading = !kUseMock;

  @override
  void initState() {
    super.initState();
    if (kLocalFirstEnabled) kLocalDataRevision.addListener(_onLocalDataChanged);
    if (!kUseMock) {
      _loadAll();
    }
  }

  /// 首次填充 / 后台刷新写完本地表后重读（无需用户下拉）。
  void _onLocalDataChanged() {
    if (!mounted) return;
    unawaited(_loadFromLocal());
  }

  @override
  void dispose() {
    if (kLocalFirstEnabled) kLocalDataRevision.removeListener(_onLocalDataChanged);
    _defectApi.close();
    _verifyApi.close();
    super.dispose();
  }

  /// 三段式加载（本地优先 R2）。
  ///
  /// `kLocalFirstEnabled = false` 时走旧路径（两路并发直连），完全不变。
  Future<void> _loadAll() async {
    if (!kLocalFirstEnabled) {
      // 旧路径：两路各自吞异常（见各 loader），所以 Future.wait 不会整体抛出，
      // 一路超时也不影响另一路已经拿到的数字。
      await Future.wait<void>(<Future<void>>[_loadStats(), _loadSummary()]);
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }
    await _loadFromLocal();
    unawaited(_refreshFromCloud());
  }

  /// 本地读取：本页只需要两样东西——缺陷聚合 + 进行中的验证数。
  ///
  /// 本地为空时保持 `_loading`（四格显示骨架）而不显示「0 条」：
  /// 还没同步下来不等于你确实没有数据（任务书 C5）。
  Future<void> _loadFromLocal() async {
    try {
      final bool hasData = await localHasAnyData();
      if (!hasData && !await isFirstFillComplete()) {
        if (!mounted) return;
        setState(() => _loading = true);
        return;
      }
      final Map<String, Object?> stats = await loadDefectStats(kDemoUserId);
      final VerificationSummary summary = await loadVerificationSummary(kDemoUserId);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _summary = summary;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[profile] 本地读取失败：$e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 后台刷新：失败只记日志，四格继续显示本地数字。
  Future<void> _refreshFromCloud() async {
    await refreshLocalFromCloud();
  }

  Future<void> _refresh() async {
    if (kUseMock) return;
    setState(() => _loading = true);
    if (kLocalFirstEnabled) {
      await _loadFromLocal();
      await refreshLocalFromCloud();
      await _loadFromLocal();
      if (mounted) setState(() => _loading = false);
      return;
    }
    await _loadAll();
  }

  Future<void> _loadStats() async {
    try {
      final Map<String, Object?> stats =
          await _defectApi.fetchDefectStats(kDemoUserId);
      if (!mounted) return;
      setState(() => _stats = stats);
    } on ApiException catch (e) {
      // 不往界面上抛：这一路的失败只该让三个数字变成「—」。
      debugPrint('[profile] 缺陷统计加载失败：${e.message}（uri=${e.uri}）');
    } catch (e) {
      debugPrint('[profile] 缺陷统计解析异常：$e');
    }
  }

  Future<void> _loadSummary() async {
    try {
      final VerificationSummary summary =
          await _verifyApi.fetchVerificationSummary(kDemoUserId);
      if (!mounted) return;
      setState(() => _summary = summary);
    } on ApiException catch (e) {
      debugPrint('[profile] 验证摘要加载失败：${e.message}（uri=${e.uri}）');
    } catch (e) {
      debugPrint('[profile] 验证摘要解析异常：$e');
    }
  }

  // ───────────────────────── 账户 ─────────────────────────

  /// 脱敏：只保留前 4 位。kDemoUserId 是 UUID，前 4 位足以说明「是哪一个账号」
  /// 又不至于把完整标识暴露在截图/投屏里。
  String get _maskedUserId {
    final String id = kDemoUserId.trim();
    if (id.isEmpty) return '—';
    final String head = id.length <= 4 ? id : id.substring(0, 4);
    return '$head****';
  }

  /// 切换 Token：弹框输入 → `saveApiToken()` → 清掉本页缓存重拉。
  ///
  /// 为什么不直接跳 `ApiTokenPage`：那个页面是「首次启动」形态（带大标题与说明），
  /// 用在这里会让人以为登录态丢了。弹框更贴近「换一个凭证继续用」的意图。
  Future<void> _switchToken() async {
    // 不用 TextEditingController：弹框 pop 之后退出动画还会再跑一帧，
    // 若此时 dispose controller，退场动画重建 TextField 就会踩到
    // "controller used after being disposed"。改用局部变量收集输入。
    String draft = '';
    final String? token = await showCupertinoDialog<String>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        // CupertinoAlertDialog 内部把 title/content/action 的字体硬编码成
        // `CupertinoSystemText`（cupertino/dialog.dart 的三个 _kCupertinoDialog*Style），
        // 且不暴露 textStyle 参数 —— 所以每个 Text 都要显式写 fontFamily，
        // 靠 TextStyle.merge 让显式值胜出。
        title: Text(
          '切换 API Token',
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '新 Token 只保存在本机，保存后立即生效。',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                height: 1.35,
                color: AppColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 12),
            CupertinoTextField(
              autofocus: true,
              obscureText: true,
              placeholder: 'API Token',
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              style: const TextStyle(fontFamily: kFontFamily, fontSize: 15),
              placeholderStyle: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 15,
                color: AppColors.tertiaryLabel,
              ),
              onChanged: (String value) => draft = value,
              onSubmitted: (String value) =>
                  Navigator.of(ctx).pop(value.trim()),
            ),
          ],
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
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
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(draft.trim()),
            child: const Text(
              '保存',
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
    // 弹框已出栈，draft 是纯 Dart 字符串，不存在控制器生命周期问题。
    if (token == null || token.isEmpty) return;

    await saveApiToken(token);
    if (!mounted) return;
    // 旧数字属于旧账号，先清空再重拉，避免「新 token + 旧缺陷统计」的错配。
    setState(() {
      _stats = null;
      _summary = null;
      _loading = true;
    });
    await _loadAll();
    if (!mounted) return;
    _toast('已切换 Token', '新凭证已生效，概览数据已重新拉取。');
  }

  /// 退出：清掉本机 token，回到 token 输入页。
  ///
  /// 用 shared_preferences 直接删 `api_config.dart` 实际使用的那个 key
  /// （`'api_token'`），而不是自己另起一个 key —— 否则下次启动
  /// `initializeApiToken()` 读到的还是旧值，「退出」就成了假的。
  /// 同时调 `saveApiToken('')` 把进程内的 `_apiToken` 一起置空，
  /// 这样已持有的 ApiClient 下一次请求就不会再带旧凭证。
  Future<void> _logout() async {
    final bool? confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: Text(
          '退出登录',
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        content: Text(
          '将清除本机保存的 API Token。云端数据不受影响，重新输入 Token 即可继续使用。',
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            height: 1.35,
            color: AppColors.secondaryLabel,
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
              '退出',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.overdue,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.remove('api_token');
    await saveApiToken('');
    if (!mounted) return;

    setState(() {
      _stats = null;
      _summary = null;
    });
    // push 而不是 pushAndRemoveUntil：本页只是 Tab 根页，把 RootTabs 从根
    // Navigator 上剥掉之后就再也回不来（本页无权重建 ApiTokenGate）。
    // 保存新 token 后自动回到本页 —— 与「换一个凭证继续用」的预期一致。
    await Navigator.of(context).push<void>(
      appRoute<void>(
        context,
        ApiTokenPage(
          onSaved: () {
            Navigator.of(context).pop();
          },
        ),
      ),
    );
    if (!mounted) return;
    await _refresh();
  }

  void _toast(String title, String message) {
    showCupertinoDialog<void>(
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
        content: Text(
          message,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            height: 1.35,
            color: AppColors.label,
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

  // ───────────────────────── 导航（全部 push）─────────────────────────

  void _openVerify() {
    Navigator.of(context).push<void>(appRoute<void>(context, const VerifyPage()));
  }

  void _openMock() {
    Navigator.of(context).push<void>(appRoute<void>(context, const MockPage()));
  }

  void _openReview() {
    Navigator.of(context).push<void>(appRoute<void>(context, const ReviewPage()));
  }

  void _openQuestionBank() {
    Navigator.of(
      context,
    ).push<void>(appRoute<void>(context, const QuestionBankPage()));
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push<void>(appRoute<void>(context, const SettingsPage()));
  }

  // ───────────────────────── 数据取值 ─────────────────────────

  /// 后端数字可能是 int / double / 数字字符串（`pg` 的 count 走 ::int，
  /// 但聚合对象经过 JSON 往返后类型不保证），统一收口成一个可空 int。
  static int? _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  String get _totalLabel {
    final int? total = _intOf(_stats?['total']);
    return total == null ? '—' : '$total';
  }

  String get _closedLabel {
    final int? closed = _intOf(_stats?['closed_total']);
    return closed == null ? '—' : '$closed';
  }

  /// `CLOSED / total`；total 为 0（新账号）时没有「率」可言，显示「—」。
  String get _completionLabel {
    final int? total = _intOf(_stats?['total']);
    final int? closed = _intOf(_stats?['closed_total']);
    if (total == null || closed == null || total <= 0) return '—';
    return '${(closed / total * 100).round()}%';
  }

  String get _inProgressLabel {
    final VerificationSummary? summary = _summary;
    if (summary == null) return '进行中 —';
    return '进行中 ${summary.total}';
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
            // 作为 Tab 根页：没有可 pop 的路由，CupertinoSliverNavigationBar
            // 不会自动长出返回按钮，符合「根页不显示 back」的预期。
            largeTitle: const Text(
              '我的',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.37,
              ),
            ),
            // 与首页一致：折叠前只显示大标题，折叠后才淡入中间标题，
            // 否则会同时出现两个「我的」。
            alwaysShowMiddle: false,
            middle: const Text('我的'),
            border: const Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          CupertinoSliverRefreshControl(onRefresh: _refresh),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              12,
              AppSpacing.page,
              32,
            ),
            sliver: SliverList(
              delegate: SliverChildListDelegate(<Widget>[
                _buildAccountCard(),
                const SizedBox(height: 24),
                SectionHeader(
                  text: '数据概览',
                  trailing: _loading
                      ? const CupertinoActivityIndicator(radius: 6)
                      : null,
                ),
                _buildStatsCard(),
                const SizedBox(height: 24),
                const SectionHeader(text: '功能'),
                _buildEntryCard(),
                const SizedBox(height: 16),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '账户信息来自本机保存的 API Token，云端资料由 API 提供。',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11,
                      height: 1.35,
                      color: AppColors.tertiaryLabel,
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountCard() {
    return _CardBox(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    color: Color(0x14007AFF),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    CupertinoIcons.person_fill,
                    size: 26,
                    color: AppColors.accent,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      // 仓库没有 `/users/:id` 或 `/me` 接口（本轮不新增 API 调用），
                      // 所以昵称只能给占位，不伪造一个看起来像真的名字。
                      const Text(
                        '未命名用户',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.45,
                          color: AppColors.label,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ID  $_maskedUserId',
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 13,
                          color: AppColors.secondaryLabel,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                _AccountAction(
                  label: '切换 Token',
                  color: AppColors.accent,
                  background: const Color(0x14007AFF),
                  onTap: _switchToken,
                ),
                const SizedBox(width: 10),
                _AccountAction(
                  label: '退出',
                  color: AppColors.overdue,
                  background: const Color(0x14FF3B30),
                  onTap: _logout,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCard() {
    return _CardBox(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        child: Column(
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: _MetricCell(
                    value: _totalLabel,
                    label: '缺陷单总数',
                    sub: '含已关闭',
                  ),
                ),
                const _MetricDivider(),
                Expanded(
                  child: _MetricCell(
                    value: _closedLabel,
                    label: '已关闭',
                    sub: '验证全通过',
                  ),
                ),
              ],
            ),
            // 横向分隔线用 Container 手写：`Divider` 来自 material.dart，
            // 本工程刻意不依赖 Material 组件（pubspec 也没直接引 material 主题）。
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: SizedBox(
                height: 0.5,
                child: ColoredBox(color: AppColors.separator),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: _MetricCell(
                    value: _completionLabel,
                    label: '验证完成率',
                    sub: '已关闭 / 总数',
                  ),
                ),
                const _MetricDivider(),
                Expanded(
                  child: _MetricCell(
                    value: '—',
                    label: '学习天数',
                    // 后端没有连续学习天数的统计口径（见遗留项），
                    // 这里给「—」而不是编一个数字。
                    sub: '暂无数据',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                const Icon(
                  CupertinoIcons.check_mark_circled,
                  size: 14,
                  color: AppColors.secondaryLabel,
                ),
                const SizedBox(width: 6),
                Text(
                  _inProgressLabel,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    color: AppColors.secondaryLabel,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntryCard() {
    final List<Widget> rows = <Widget>[
      _EntryRow(
        icon: CupertinoIcons.check_mark_circled,
        title: '验证任务',
        badge: _summary == null ? null : '${_summary!.total} 项',
        onTap: _openVerify,
      ),
      _EntryRow(
        icon: CupertinoIcons.timer,
        title: '我的模考',
        onTap: _openMock,
      ),
      _EntryRow(
        icon: CupertinoIcons.chart_bar,
        title: '我的复盘',
        onTap: _openReview,
      ),
      _EntryRow(
        icon: CupertinoIcons.doc_text,
        title: '题库管理',
        onTap: _openQuestionBank,
      ),
      _EntryRow(
        icon: CupertinoIcons.gear,
        title: '设置',
        onTap: _openSettings,
      ),
    ];

    return _CardBox(
      child: Column(
        children: <Widget>[
          for (int i = 0; i < rows.length; i++) ...<Widget>[
            rows[i],
            if (i != rows.length - 1)
              // 缩进 0.5px 分隔线：左侧让出图标宽度，视觉上贴住 iOS 分组列表。
              const Padding(
                padding: EdgeInsets.only(left: 56),
                child: SizedBox(
                  height: 0.5,
                  child: ColoredBox(color: AppColors.separator),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 白底圆角卡片（与首页卡片同一套观感：16 圆角 + 极淡投影）。
class _CardBox extends StatelessWidget {
  const _CardBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
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

/// 概览里的一格：大号数字 + 说明 + 可选副标题。
///
/// 降级策略在调用方完成（拿不到就传「—」），本组件对「有没有数据」无感知，
/// 这样新增格子不必再改一套状态判断。
class _MetricCell extends StatelessWidget {
  const _MetricCell({required this.value, required this.label, this.sub});

  final String value;
  final String label;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          value,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 24,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.5,
            color: AppColors.label,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            color: AppColors.secondaryLabel,
          ),
        ),
        if (sub != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            sub!,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11,
              color: AppColors.tertiaryLabel,
            ),
          ),
        ],
      ],
    );
  }
}

/// 两格之间的竖向细分隔线。
class _MetricDivider extends StatelessWidget {
  const _MetricDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 0.5,
      height: 44,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: AppColors.separator,
    );
  }
}

/// 账户卡片里的胶囊按钮。
///
/// 不用 `CupertinoButton` 的原因：它的默认内边距与最小宽度会把两个按钮
/// 撑到换行；这里需要的是「小号 tinted 胶囊」，手写一层更可控。
class _AccountAction extends StatelessWidget {
  const _AccountAction({
    required this.label,
    required this.color,
    required this.background,
    required this.onTap,
  });

  final String label;
  final Color color;
  final Color background;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppRadii.chip),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// 功能列表的一行：图标 + 标题 + 可选徽标 + 右箭头。
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: <Widget>[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: const Color(0x14007AFF),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 17, color: AppColors.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 16,
                  color: AppColors.label,
                ),
              ),
            ),
            if (badge != null) ...<Widget>[
              Text(
                badge!,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  color: AppColors.secondaryLabel,
                ),
              ),
              const SizedBox(width: 6),
            ],
            const Icon(
              CupertinoIcons.chevron_forward,
              size: 16,
              color: AppColors.tertiaryLabel,
            ),
          ],
        ),
      ),
    );
  }
}
