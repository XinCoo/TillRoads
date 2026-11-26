// 考试配置 · 目标列表页。
//
// ── 这一页解决什么问题 ──────────────────────────────────────────────────
// 「考试配置」是整条备考链路的根：目标（exam_profiles）→ 科目（subjects）
// → 考点树（knowledge_nodes）。后端 BE-01 的四张表和端点早就有了，
// 但前端一直没有入口，用户建不了目标也就没法建科目/考点。
// 本页是这条链路的第一个落地点：列出「我建过的考试目标」，
// 右上角「新建」跳到创建页，点某一行进科目管理。
//
// ── 为什么倒计时要在前端算 ──────────────────────────────────────────────
// 后端只存 `exam_date`（date 列，JSON 里是 'YYYY-MM-DD' 字符串），
// 不存「还剩几天」——那是随当天变化的派生值，存下来必然过期。
// 这里两边都归零到当天 00:00 再相减，避免「今晚 23:00 与明早 01:00
// 只差 2 小时却跨了一天」这类按时间戳直接相减的错。
// 归零用 UTC 日历日（DateTime.utc(y, m, d)）：夏令时切换当天本地日长
// 不是 24 小时，用本地时间相减会出现 23/25 小时 -> inDays 截断成 0 天。
//
// ── 数据来源 ────────────────────────────────────────────────────────────
// `GET /users/{userId}/exam-profiles`，走 `ExamApi.fetchExamProfiles`
// （内部已做 Map{items:[]} / 裸 List 的容错）。返回的是 `List<Map>`，
// 不是强类型模型 —— 字段按 map key 取，且每个值都可能是 null。

import 'package:flutter/cupertino.dart';

import '../api/api_client.dart' show ApiException;
import '../api/exam_api.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart' show EmptyState, PressableCard;
import '../local/local.dart' show kLocalFirstEnabled, refreshLocalFromCloud;
import 'exam_profile_create_page.dart';
import 'subject_config_page.dart';

/// 删除时的二次确认文案（集中在这里，避免散落在 UI 代码里）。
const String kDeleteConfirmMessage =
    '删除后该目标下的科目、考点会一并移除，且不可恢复。确认删除？';

/// 后端返回 409 时的提示文案（文案照抄后端契约）。
const String kExamProfileInUseMessage = '该配置正在使用中，无法删除';

class ExamConfigPage extends StatefulWidget {
  const ExamConfigPage({super.key});

  @override
  State<ExamConfigPage> createState() => _ExamConfigPageState();
}

class _ExamConfigPageState extends State<ExamConfigPage> {
  final ExamApi _api = ExamApi();

  List<Map<String, Object?>> _profiles = const <Map<String, Object?>>[];
  bool _loading = true;
  String? _error;

  /// 正在删除的目标 id（null = 无删除进行中）。用于行内 loading 态与防重复点击。
  String? _deletingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // ExamApi 内部持有一个 http.Client；不关会泄漏连接池。
    _api.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<Map<String, Object?>> list = await _api.fetchExamProfiles(
        kDemoUserId,
      );
      if (!mounted) return;
      setState(() {
        _profiles = list;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '考试目标加载失败：$e';
        _loading = false;
      });
    }
  }

  /// 新建页用 `push<bool>`：创建成功时它会 `pop(true)`，据此决定是否刷新。
  Future<void> _openCreate() async {
    final bool? changed = await Navigator.of(context).push<bool>(
      appRoute<bool>(context, const ExamProfileCreatePage()),
    );
    if (!mounted) return;
    if (changed == true) {
      await _load();
      await _syncLocalCache();
    }
  }

  Future<void> _openSubjects(String profileId, String label) async {
    await Navigator.of(context).push<void>(
      appRoute<void>(
        context,
        SubjectConfigPage(profileId: profileId, targetLabel: label),
      ),
    );
    await _syncLocalCache();
  }

  /// 把云端最新的考试目标/科目/考点写回本地库（m27163 A1④）。
  ///
  /// 根因：新建或删除考试目标后，本地 `exam_profiles` 表还是旧的，
  /// 首页读的是本地表，所以卡片还显示旧目标、甚至「还没有设置考试目标」。
  /// `refreshLocalFromCloud()` 写回本地后会 `kLocalDataRevision++`，
  /// 首页的监听器收到通知就会重读 —— 整个 App 只需这一处通知点。
  Future<void> _syncLocalCache() async {
    if (!kLocalFirstEnabled) return;
    try {
      await refreshLocalFromCloud();
    } catch (e) {
      // 本地同步失败不影响云端已成功的操作，只是首页可能晚一点才更新。
      debugPrint('[exam-config] 写回本地失败：$e');
    }
  }

  /// 手动刷新（导航栏「刷新」按钮）。首页卡片不同步时用户可点这里拉最新数据。
  Future<void> _refresh() async {
    await _load();
  }

  // ── 删除流程 ──────────────────────────────────────────────────────────

  /// 删除某条目标：二次确认 → DELETE（带 version）→ 刷新列表。
  Future<void> _deleteProfile(Map<String, Object?> profile) async {
    final String id = '${profile['id'] ?? ''}'.trim();
    if (id.isEmpty) return;

    final bool confirmed = await _confirmDelete();
    if (!confirmed) return;
    if (!mounted) return;

    // 乐观锁：`version` 必填。取不到说明这条数据不是本次列表拉到的
    // （例如后端尚未返回该列），此时不要瞎猜一个值去调删除。
    final int? version = _versionOf(profile);
    if (version == null) {
      await _showMessage(
        '无法删除',
        '该配置缺少版本信息，请下拉刷新后重试',
      );
      return;
    }

    setState(() => _deletingId = id);
    try {
      await _api.deleteExamProfile(id, version: version);
      if (!mounted) return;
      setState(() => _deletingId = null);
      await _load();
      await _syncLocalCache();
      if (!mounted) return;
      await _showMessage('已删除', '该考试目标及其科目、考点已移除');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _deletingId = null);
      await _showMessage('删除失败', _deleteErrorText(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _deletingId = null);
      await _showMessage('删除失败', '$e');
    }
  }

  /// 409（目标正被缺陷单/模考引用）→ 固定文案；其它错误 → 后端给的 e.message。
  String _deleteErrorText(ApiException e) {
    if (e.statusCode == 409 || _errorCodeOf(e) == 'exam_profile_in_use') {
      return kExamProfileInUseMessage;
    }
    return e.message;
  }

  /// 从响应体里取业务错误码（`{ "error": "exam_profile_in_use" }`）。
  String? _errorCodeOf(ApiException e) {
    final Object? body = e.body;
    if (body is Map) {
      final Object? code = body['error'];
      if (code != null) return '$code';
    }
    return null;
  }

  /// 乐观锁版本号。后端给的是 int，但 json 解析出来也可能是数字字符串。
  int? _versionOf(Map<String, Object?> profile) {
    final Object? raw = profile['version'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  /// 二次确认弹窗。返回 true = 用户点了红色的「删除」。
  Future<bool> _confirmDelete() async {
    final bool? result = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text(
          '删除这个考试目标？',
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
            kDeleteConfirmMessage,
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
              '删除',
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
    return result == true;
  }

  /// 统一的提示弹窗（标题 + 正文 + 「好」）。
  Future<void> _showMessage(String title, String message) {
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
          CupertinoSliverNavigationBar(
            largeTitle: const Text(
              '考试配置',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                color: AppColors.label,
              ),
            ),
            // trailing 放两个动作：新建（+）与刷新（arrow.clockwise）。
            // 首页卡片不同步时，用户可以在这里手动拉一次最新数据。
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(36, 36),
                  onPressed: _openCreate,
                  child: const Text(
                    '新建',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 17,
                      color: AppColors.accent,
                    ),
                  ),
                ),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(36, 36),
                  onPressed: _refresh,
                  child: const Icon(
                    CupertinoIcons.arrow_clockwise,
                    size: 20,
                    color: AppColors.accent,
                  ),
                ),
              ],
            ),
          ),
          ..._buildBody(),
        ],
      ),
    );
  }

  List<Widget> _buildBody() {
    if (_loading) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CupertinoActivityIndicator(radius: 12)),
        ),
      ];
    }

    if (_error != null) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _ErrorView(message: _error!, onRetry: _load),
        ),
      ];
    }

    if (_profiles.isEmpty) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            title: '还没有考试目标',
            message: '点右上角「新建」创建第一个考试目标。',
            icon: CupertinoIcons.flag,
          ),
        ),
      ];
    }

    return <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        sliver: SliverList.separated(
          itemCount: _profiles.length,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 8),
          itemBuilder: (BuildContext context, int index) =>
              _buildRow(_profiles[index]),
        ),
      ),
    ];
  }

  Widget _buildRow(Map<String, Object?> profile) {
    final String id = '${profile['id'] ?? ''}'.trim();
    final String label = _labelOf(profile);
    final String? dateText = _dateText(profile['exam_date']);
    final ({String text, Color color})? countdown = _countdown(profile['exam_date']);
    final bool deleting = _deletingId != null && _deletingId == id;

    return PressableCard(
      onTap: id.isEmpty ? null : () => _openSubjects(id, label),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: <Widget>[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: const Color(0x14007AFF),
                borderRadius: BorderRadius.circular(AppRadii.chip),
              ),
              child: const Icon(
                CupertinoIcons.flag,
                size: 18,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.label,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Text(
                        dateText ?? '未设置考试日期',
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 13,
                          color: AppColors.secondaryLabel,
                        ),
                      ),
                      if (countdown != null) ...<Widget>[
                        const SizedBox(width: 8),
                        Text(
                          '·',
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 13,
                            color: AppColors.tertiaryLabel,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          countdown.text,
                          style: TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: countdown.color,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // 删除按钮在行内，必须与「整行可点」隔离：
            // 用 GestureDetector（而不是 CupertinoButton）包一个 SizedBox，
            // 命中测试里内层的 recognizer 优先于外层 PressableCard 的，
            // 点删除不会顺带 push 科目管理页。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 注意：即使在删除中也要保留 onTap（内部再判断），
              // 否则内层 GestureDetector 不注册 recognizer，点下去会落到
              // 外层 PressableCard → 顺带 push 科目管理页。
              onTap: () {
                if (deleting) return;
                _deleteProfile(profile);
              },
              child: SizedBox(
                width: 30,
                height: 30,
                child: deleting
                    ? const Center(
                        child: CupertinoActivityIndicator(radius: 9),
                      )
                    : const Icon(
                        CupertinoIcons.delete,
                        size: 18,
                        color: AppColors.overdue,
                      ),
              ),
            ),
            const SizedBox(width: 6),
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

  /// 主标题：优先 `exam_type_custom`（自定义类型填的名字），
  /// 再退到 `target_label`，最后退到考试类型的中文名。
  ///
  /// 显示格式：自定义类型显示「自定义 · <名称>」；其余类型直接显示
  /// `target_label`（为空才用类型中文名兜底）。
  String _labelOf(Map<String, Object?> profile) {
    final String type = '${profile['exam_type'] ?? ''}'.trim();
    final String custom = '${profile['exam_type_custom'] ?? ''}'.trim();
    if (custom.isNotEmpty) {
      return type == 'custom' ? '自定义 · $custom' : custom;
    }
    final String label = '${profile['target_label'] ?? ''}'.trim();
    if (label.isNotEmpty) return label;
    return kExamTypeLabels[type] ?? '未命名考试目标';
  }

  /// `exam_date` 后端是 date 列 → JSON 里固定是 'YYYY-MM-DD'（`server/db/pool.mjs`
  /// 对 date(1082) 原样返回字符串）。这里只做展示，不再二次格式化。
  String? _dateText(Object? raw) {
    final DateTime? date = _parseDate(raw);
    if (date == null) return null;
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  DateTime? _parseDate(Object? raw) {
    if (raw is DateTime) return raw;
    if (raw is! String) return null;
    final String s = raw.trim();
    if (s.length < 10) return null;
    final int? year = int.tryParse(s.substring(0, 4));
    final int? month = int.tryParse(s.substring(5, 7));
    final int? day = int.tryParse(s.substring(8, 10));
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }

  /// 倒计时：两边归零到当天 00:00 再相减（UTC 日历日，规避夏令时）。
  ({String text, Color color})? _countdown(Object? raw) {
    final DateTime? date = _parseDate(raw);
    if (date == null) return null;
    final DateTime now = DateTime.now();
    final DateTime today = DateTime.utc(now.year, now.month, now.day);
    final DateTime target = DateTime.utc(date.year, date.month, date.day);
    final int days = target.difference(today).inDays;
    if (days > 0) {
      return (
        text: '还剩 $days 天',
        color: days <= 7 ? AppColors.dueSoon : AppColors.normal,
      );
    }
    if (days == 0) {
      return (text: '就是今天', color: AppColors.dueSoon);
    }
    return (text: '已过 ${-days} 天', color: AppColors.overdue);
  }
}

/// 错误态：可重试。
///
/// `question_bank_page.dart` / `mock_page.dart` 里各有一份同名私有实现；
/// 私有类不能跨文件复用，而硬约束不允许新建共享 widget 文件，故此处再复制一份。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              CupertinoIcons.exclamationmark_triangle,
              size: 40,
              color: AppColors.dueSoon,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                color: AppColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton(
              onPressed: () {
                onRetry();
              },
              child: const Text(
                '重试',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  color: AppColors.accent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
