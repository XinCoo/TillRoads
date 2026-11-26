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
import 'dart:async' show Timer, unawaited;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart' show ApiException;
import '../api/defect_api.dart';
import '../api/user_api.dart';
// 只取 summary 相关的两个类型：`VerificationTask` 与首页 mock 里的同名类型
// 不是一回事，这里不需要任务级模型，用 show 收窄可避免将来 ambiguous_import。
import '../api/verification_api.dart' show VerificationApi, VerificationSummary;
import '../config/api_config.dart';
import '../config/local_config.dart';
import '../local/local.dart';
import '../theme/app_theme.dart';
import '../utils/session.dart';
import '../widgets/common.dart';
import '../widgets/toast_overlay.dart';
import 'api_token_page.dart';
import 'exam_config_page.dart';
import 'mock_page.dart';
import 'practice_history_page.dart';
import 'question_manage_page.dart';
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

  /// 当前用户资料（`GET /me`）。
  final UserApi _userApi = UserApi();

  /// 后端返回的用户资料；null 表示还没拿到（或拿失败）。
  UserProfile? _user;

  /// 用户资料是否还在加载中。
  bool _userLoading = true;

  /// 用户资料加载失败的原因（非 null 时在卡片上给一行小字提示）。
  String? _userError;

  /// 切换 Token 成功后的高亮闪烁（账户卡片背景变淡蓝 600ms 后复原）。
  bool _highlight = false;

  /// 负责关掉高亮的定时器；dispose 时必须取消，否则会在页面销毁后 setState。
  Timer? _highlightTimer;

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
      _loadUser();
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
    _highlightTimer?.cancel();
    _defectApi.close();
    _verifyApi.close();
    _userApi.close();
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
      // 昵称不在本地库里（唯一真源是云端 users.nickname），所以必须单独重拉：
      // 否则「另一端改了名，这台下拉刷新」看不到变化，就不是真·多端同步。
      await _loadUser();
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
  /// 拉取当前用户资料（`GET /me`）。
  ///
  /// 失败只记日志 + 记下 `_userError`：昵称与 id 有本地回退（见 `_buildAccountCard`），
  /// 页面不能因为这一个请求失败就变错误页。
  Future<void> _loadUser() async {
    try {
      final UserProfile profile = await _userApi.fetchMe();
      if (!mounted) return;
      setState(() {
        _user = profile;
        _userLoading = false;
        _userError = null;
      });
      // 后端给的才是真实 id；记下来，之后即使接口挂了也能显示正确的 id。
      if (profile.id.isNotEmpty) {
        await persistCurrentUserId(profile.id);
      }
    } on ApiException catch (e) {
      debugPrint('[profile] 用户信息加载失败：${e.message}（uri=${e.uri}）');
      if (!mounted) return;
      setState(() {
        _userLoading = false;
        _userError = e.message;
      });
    } catch (e) {
      debugPrint('[profile] 用户信息解析异常：$e');
      if (!mounted) return;
      setState(() {
        _userLoading = false;
        _userError = '$e';
      });
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

  /// 切换 Token：弹框输入 → 共享的 [switchApiToken]（校验 + 落盘 + 清旧账号）
  /// → 刷新本页数据 + 顶部 toast + 账户卡片高亮闪烁。
  ///
  /// 为什么不直接跳 `ApiTokenPage`：那个页面是「首次启动」形态（带大标题与说明），
  /// 用在这里会让人以为登录态丢了。弹框更贴近「换一个凭证继续用」的意图。
  ///
  /// 与设置页的「切换 Token」共用同一段核心逻辑（`lib/utils/session.dart`），
  /// 两边的校验、清理与报错口径完全一致。
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

    // 共享实现：先用新 token 校验 `GET /me`，通过后才写盘 + 清旧账号残留。
    // 校验失败会抛异常（此时**旧 token 仍然有效**，本机数据也没被动过）。
    SwitchTokenResult result;
    try {
      result = await switchApiToken(token);
    } on ApiException catch (e) {
      if (!mounted) return;
      await _showSwitchError(e.message);
      return;
    } catch (e) {
      if (!mounted) return;
      await _showSwitchError('$e');
      return;
    }
    if (!mounted) return;
    // 旧数字属于旧账号，先清空再重拉，避免「新 token + 旧缺陷统计」的错配。
    setState(() {
      _stats = null;
      _summary = null;
      _loading = true;
    });
    await _loadAll();
    if (!mounted) return;
    await _loadUser();
    if (!mounted) return;
    // 账户卡片高亮闪烁 600ms：让用户看到「切换真的生效了」。
    _flashHighlight();
    showAppToast(context, '已切换至 ${result.displayName}');
  }

  /// 修改用户名（m28943）。
  ///
  /// 需求：入口就在用户名旁边（不新增独立页面），点击弹框修改；并且必须
  /// 「多端同步」。所以这里**不写任何本地缓存**，成功后直接用后端返回的
  /// 最新资料覆盖 `_user`。`users.nickname` 是唯一真源，其他端下次
  /// `GET /me` 自然读到新值（下拉刷新 / 切 Token 都会重拉）。
  ///
  /// 失败必须报错，不得静默失败（与 A3 同一条要求）。
  Future<void> _renameNickname() async {
    final String? name = await showCupertinoDialog<String>(
      context: context,
      builder: (BuildContext ctx) =>
          _RenameNicknameDialog(initialName: _user?.nickname ?? ''),
    );
    // 弹框已出栈；null = 用户取消。
    if (name == null || name.isEmpty) return;
    if (!mounted) return;
    try {
      final UserProfile profile = await _userApi.updateNickname(name);
      if (!mounted) return;
      setState(() {
        _user = profile;
        _userError = null;
      });
      // 与切换 Token 同一套反馈：高亮闪一下 + 顶部 toast。
      _flashHighlight();
      showAppToast(context, '用户名已更新');
    } on ApiException catch (e) {
      if (!mounted) return;
      await _showRenameError(_renameErrorText(e));
    } catch (e) {
      if (!mounted) return;
      await _showRenameError('$e');
    }
  }

  /// 把 `PATCH /me` 的错误翻成能直接给人看的一句话。
  ///
  /// 后端 400 的 `message` 就是面向用户的（与前端本地校验同一套规则），
  /// 优先用它；拿不到 message 时才退回通用文案。
  static String _renameErrorText(ApiException e) {
    final Object? body = e.body;
    if (body is Map) {
      final Object? code = body['error'];
      final Object? message = body['message'];
      if (code == 'INVALID_NICKNAME' &&
          message is String &&
          message.isNotEmpty) {
        return message;
      }
      if (code == 'MISSING_NICKNAME') return '没有收到新的用户名，请重试。';
      if (code == 'not_found') return '这个账号已不存在，请重新输入 Token。';
    }
    if (e.statusCode == 401) return '当前 Token 已失效，请重新输入 Token。';
    return e.message;
  }

  /// 修改用户名失败时的报错弹窗（与 `_showSwitchError` 同形，只是文案不同）。
  Future<void> _showRenameError(String reason) async {
    if (!mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '修改失败',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.overdue,
          ),
        ),
        content: Text(
          '$reason\n\n用户名没有改动，请重试。',
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

  /// 切换 Token 失败时的报错弹窗。
  ///
  /// 需求明确要求「切换失败必须报错，不得静默失败」，所以这里用弹窗而不是
  /// 只打日志：用户必须看到「为什么没切成」。
  Future<void> _showSwitchError(String reason) async {
    if (!mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '切换失败',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.overdue,
          ),
        ),
        content: Text(
          '$reason\n\n原 Token 仍然有效，本机数据未做任何更改。',
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

  /// 账户卡片高亮闪烁 600ms（切换 Token 成功时）。
  void _flashHighlight() {
    _highlightTimer?.cancel();
    setState(() => _highlight = true);
    _highlightTimer = Timer(const Duration(milliseconds: 600), () {
      _highlightTimer = null;
      if (!mounted) return;
      setState(() => _highlight = false);
    });
  }

  /// 复制完整用户 ID 到剪贴板，并给一个轻提示。
  ///
  /// 「没有 nickname / id 时也要能复制」：拿不到后端 id 时回退到本地的
  /// `kDemoUserId`（它已经是当前用户的 id 了）。
  Future<void> _copyUserId() async {
    final String id = (_user?.id ?? '').trim().isNotEmpty
        ? _user!.id.trim()
        : kDemoUserId;
    await Clipboard.setData(ClipboardData(text: id));
    if (!mounted) return;
    showAppToast(context, '已复制用户 ID');
  }

  /// 长按 ID 行：说明「点击可复制完整 ID」，并给一个显式的「复制」按钮。
  ///
  /// 本工程没有 Tooltip 组件先例（纯 Cupertino，不引 Material），所以长按
  /// 用 CupertinoAlertDialog 代替 tooltip。
  Future<void> _showUserIdHelp() async {
    if (!mounted) return;
    final String id = (_user?.id ?? '').trim().isNotEmpty
        ? _user!.id.trim()
        : kDemoUserId;
    final bool? copy = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '用户 ID',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppColors.label,
          ),
        ),
        content: Text(
          '完整 ID：\n$id\n\n点击 ID 这一行可以直接复制；也可以点下方「复制」。',
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            height: 1.35,
            color: AppColors.label,
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              '关闭',
              style: TextStyle(fontFamily: kFontFamily, fontSize: 17),
            ),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              '复制',
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
    if (copy == true) {
      await _copyUserId();
    }
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

  /// 题库管理（R3）：批量移除 / 恢复、掌握度筛选。
  ///
  /// 页面右上角的「浏览」才是原来那个题库列表（导入 / 建题 / 练习入口）。
  void _openQuestionBank() {
    Navigator.of(
      context,
    ).push<void>(appRoute<void>(context, const QuestionManagePage()));
  }

  /// 考试配置：目标 → 科目 → 考点树。
  /// 这条链路是「建题 / 导入 / 组卷」的前置 —— 没有科目就选不了归属。
  void _openExamConfig() {
    Navigator.of(
      context,
    ).push<void>(appRoute<void>(context, const ExamConfigPage()));
  }
  /// 练习记录（练习模式 R1 的历史入口）。
  ///
  /// 服务端按 token 映射 userId，只能看到自己的练习，所以这里不做筛选。
  void _openPracticeHistory() {
    Navigator.of(
      context,
    ).push<void>(appRoute<void>(context, const PracticeHistoryPage()));
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
      // 切换 Token 成功后账户卡片高亮闪烁 600ms（由 _CardBox 内部做淡入淡出）。
      highlight: _highlight,
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
                      // 昵称来自后端 `GET /me`（display_name）；拿不到时回退到占位文案，
                      // 不伪造一个看起来像真的名字。
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              _user?.displayName ?? '未命名用户',
                              style: const TextStyle(
                                fontFamily: kFontFamily,
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.45,
                                color: AppColors.label,
                              ),
                            ),
                          ),
                          // 修改用户名入口（m28943）：紧挨昵称，不新增独立入口。
                          // 只在拿到后端资料后出现 —— 昵称还没加载出来时改名
                          // 会把「未命名用户」当成初值，容易误存。
                          if (!_userLoading && _user != null) ...<Widget>[
                            const SizedBox(width: 6),
                            Semantics(
                              button: true,
                              label: '修改用户名',
                              child: CupertinoButton(
                                padding: EdgeInsets.zero,
                                minimumSize: Size.zero,
                                pressedOpacity: 0.4,
                                onPressed: _renameNickname,
                                child: const Icon(
                                  CupertinoIcons.pencil,
                                  size: 15,
                                  color: AppColors.accent,
                                ),
                              ),
                            ),
                          ],
                          if (_userLoading) ...<Widget>[
                            const SizedBox(width: 8),
                            const CupertinoActivityIndicator(radius: 7),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      // ID 行：点击复制完整 ID，长按弹出说明 + 复制按钮。
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _copyUserId,
                        onLongPress: _showUserIdHelp,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                'ID  ${_user?.maskedId ?? _maskedUserId}',
                                style: const TextStyle(
                                  fontFamily: kFontFamily,
                                  fontSize: 13,
                                  color: AppColors.secondaryLabel,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(
                              CupertinoIcons.doc_on_clipboard,
                              size: 12,
                              color: AppColors.tertiaryLabel,
                            ),
                          ],
                        ),
                      ),
                      if (_userError != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          '无法获取用户信息，请检查连接',
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 11,
                            color: AppColors.overdue,
                          ),
                        ),
                      ],
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
        icon: CupertinoIcons.square_stack_3d_up,
        title: '考试配置',
        onTap: _openExamConfig,
      ),
      _EntryRow(
        icon: CupertinoIcons.pencil_outline,
        title: '练习记录',
        onTap: _openPracticeHistory,
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

/// 「修改用户名」弹窗（m28943）。
///
/// 单独做成 StatefulWidget 只为一件事：`TextEditingController` 必须有人
/// dispose —— 与设置页 `_TokenDialog` 同样的理由，放在 `_ProfilePageState`
/// 里会因为弹窗反复开关而泄漏。
///
/// 校验做两层，规则必须一致：
///   1. 这里本地先校验一遍，用户输错立刻看到红字，不必等一次网络往返；
///   2. 后端 `PATCH /me` 仍会再校验一次并返回 400 `INVALID_NICKNAME`
///      （规则在 `core/validators.mjs` 的 V15）——本地校验只是体验，
///      不能当成防线。
class _RenameNicknameDialog extends StatefulWidget {
  const _RenameNicknameDialog({this.initialName});

  /// 当前昵称，作为输入框初值（用户多半只想改一两个字）。
  final String? initialName;

  @override
  State<_RenameNicknameDialog> createState() => _RenameNicknameDialogState();
}

class _RenameNicknameDialogState extends State<_RenameNicknameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName ?? '');

  /// 本地校验错误；null 表示当前输入没问题。
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 与后端 V15 逐条对齐：trim → 非空 → 只允许中文基本区 / 英文 / 数字
  /// → 长度 2–20（按 code point 计，与 JS 的 `Array.from().length` 同口径）。
  static String? _validate(String raw) {
    final String name = raw.trim();
    if (name.isEmpty) return '用户名不能为空';
    if (!RegExp(r'^[\u4e00-\u9fa5A-Za-z0-9]+$').hasMatch(name)) {
      return '用户名只能包含中文、英文、数字，不能有空格或符号';
    }
    final int length = name.runes.length;
    if (length < 2) return '用户名至少 2 个字符';
    if (length > 20) return '用户名不能超过 20 个字符';
    return null;
  }

  void _submit() {
    final String name = _controller.text.trim();
    final String? problem = _validate(name);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text(
        '修改用户名',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: AppColors.label,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            '只能用中文、英文、数字，2–20 个字。修改后会同步到所有端。',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.35,
              color: AppColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 12),
          CupertinoTextField(
            controller: _controller,
            autofocus: true,
            maxLength: 20,
            placeholder: '输入新的用户名',
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            style: const TextStyle(fontFamily: kFontFamily, fontSize: 15),
            placeholderStyle: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              color: AppColors.tertiaryLabel,
            ),
            onChanged: (_) {
              // 用户开始改就撕掉上一次的红字，避免「已经改对了还报错」。
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                height: 1.3,
                color: AppColors.overdue,
              ),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(),
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
          onPressed: _submit,
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
    );
  }
}

/// 白底圆角卡片（与首页卡片同一套观感：16 圆角 + 极淡投影）。
class _CardBox extends StatelessWidget {
  const _CardBox({required this.child, this.highlight = false});

  final Widget child;

  /// 高亮闪烁（切换 Token 成功后短暂置 true，600ms 后复原）。
  ///
  /// 背景色用 [AnimatedContainer] 做淡入淡出：纯 Cupertino 工程没有
  /// `Colors.transparent`，透明色用 `const Color(0x00000000)`。
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: highlight
            ? AppColors.accent.withValues(alpha: 0.12)
            : AppColors.card,
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
