import 'package:flutter/foundation.dart';

/// 缺陷单状态（与后端 `defect_status` 枚举一一对应）
///
/// 状态机不变量（来自开发文档与 schema.sql 触发器，UI 层也要体现）：
/// - `ACTION_DONE` **不等于** 已关闭，只是「处理动作都做完了，还没验证」
/// - 任一阶段 `fail` → `REOPENED`，且 `reopen_count + 1`
/// - 只有用户在 V3 通过后显式关闭才进入 `CLOSED`
enum DefectStatus {
  draft('DRAFT', '草稿'),
  analyzed('ANALYZED', '已归因'),
  actionDone('ACTION_DONE', '待验证'),
  v1('V1', '第1次验证'),
  v2('V2', '第2次验证'),
  v3('V3', '第3次验证'),
  reopened('REOPENED', '已重开'),
  closed('CLOSED', '已关闭');

  const DefectStatus(this.wire, this.label);

  /// 与后端 JSON 的 status 字段完全一致的字符串
  final String wire;

  /// 中文短标签（徽标用）
  final String label;

  /// 未知值回落到 draft 而不是抛错——后端将来新增状态时旧客户端不该崩
  static DefectStatus fromWire(String value) {
    for (final DefectStatus s in DefectStatus.values) {
      if (s.wire == value) return s;
    }
    return DefectStatus.draft;
  }

  /// 是否处于「处理动作已做完、等待进入/进行三次验证」的阶段
  bool get isVerifying =>
      this == DefectStatus.v1 ||
      this == DefectStatus.v2 ||
      this == DefectStatus.v3;

  /// 是否需要展示「重开次数」红色角标
  bool get isReopened => this == DefectStatus.reopened;
}

/// 优先级 P0/P1/P2
///
/// 后端由 `f(高频 × 失分 × 可关闭性 × 目标分贡献)` 算出，前端只负责展示，
/// 不重算（算分逻辑在 core/index.mjs 的 computePriority）。
enum DefectPriority {
  p0('P0', '立即处理'),
  p1('P1', '尽快处理'),
  p2('P2', '有空再看');

  const DefectPriority(this.wire, this.hint);

  final String wire;
  final String hint;

  static DefectPriority fromWire(String? value) {
    for (final DefectPriority p in DefectPriority.values) {
      if (p.wire == value) return p;
    }
    return DefectPriority.p2;
  }
}

/// 单个处理动作
///
/// 后端 `actions` 是订单上的 jsonb 数组，元素形如 `{id, content, done}`。
@immutable
class DefectAction {
  const DefectAction({
    required this.id,
    required this.content,
    required this.done,
  });

  final String id;
  final String content;
  final bool done;
}

/// 单个阶段的验证结果
enum VerifyResult {
  pending('pending', '未验证'),
  pass('pass', '通过'),
  fail('fail', '未通过');

  const VerifyResult(this.wire, this.label);

  final String wire;
  final String label;

  static VerifyResult fromWire(String? value) {
    for (final VerifyResult r in VerifyResult.values) {
      if (r.wire == value) return r;
    }
    return VerifyResult.pending;
  }
}

/// 状态流转历史的一个节点（详情页时间线用）
///
/// 后端 schema 目前没有独立的 status_history 表（`defect_tickets` 只有
/// created_at / closed_at / updated_at），所以这一层在接真实 API 时
/// 要么由服务端补事件表，要么由前端根据 verifications + 时间戳推导。
/// 本轮 mock 直接给出完整链路。
@immutable
class StatusEvent {
  const StatusEvent({required this.status, required this.at});

  final DefectStatus status;
  final DateTime at;
}

/// 缺陷单（字段与后端 `GET /users/:userId/defect-tickets` 的 item 对齐）
///
/// 对齐的字段：id / q_type / error_layer / error_cause / priority / status /
/// verification_round / reopen_count / created_at / knowledge_node_id /
/// knowledge_node_title / subject_name / actions / verification_state。
/// 额外一个仅前端用的派生数据：`statusHistory`（时间线）。
///
/// 注意：后端 schema 没有 status_history 表，这一项在接真实 API 时
/// 需要服务端补事件表，或由前端用 verifications + 时间戳推导。
@immutable
class DefectTicket {
  const DefectTicket({
    required this.id,
    required this.qType,
    required this.errorLayer,
    required this.errorCause,
    required this.priority,
    required this.status,
    required this.verificationRound,
    required this.reopenCount,
    required this.createdAt,
    required this.knowledgeNodeId,
    required this.knowledgeNodeTitle,
    required this.subjectName,
    required this.actions,
    required this.v1,
    required this.v2,
    required this.v3,
    required this.statusHistory,
    this.version = 1,
  });

  final String id;

  /// 题型/考点摘要（后端字段名就是 q_type，这里保持同名语义）
  final String qType;

  /// 归因层级（概念不清 / 方法不会 / 计算失误 / 审题偏差 …）
  final String errorLayer;

  /// 归因说明。**禁止出现「粗心/马虎/没掌握/我懂了/大意/差不多/忘了」**
  final String errorCause;

  final DefectPriority priority;
  final DefectStatus status;

  /// 当前验证轮次，≥2 表示重开后进入的新一轮
  final int verificationRound;

  /// 累计重开次数（0 表示从未失败过）
  final int reopenCount;

  final DateTime createdAt;
  final String knowledgeNodeId;
  final String knowledgeNodeTitle;
  final String subjectName;

  final List<DefectAction> actions;

  final VerifyResult v1;
  final VerifyResult v2;
  final VerifyResult v3;

  final List<StatusEvent> statusHistory;

  /// 乐观锁版本号（后端每写一次 +1）。
  ///
  /// FE-03 写操作联调新增：所有写请求都必须带当前 version，
  /// 后端 0 行命中即返回 409 + 服务端当前行，前端提示用户刷新。
  /// mock 数据里没有版本概念，故默认 1 且不参与 mock 构造参数。
  final int version;
  /// 已完成动作数
  int get doneActionCount => actions.where((DefectAction a) => a.done).length;

  /// 当前处于哪个验证阶段（不在验证阶段时返回 null）
  DefectStatus? get currentStage =>
      status.isVerifying ? status : null;

  /// 各阶段的结果，按 V1/V2/V3 顺序
  List<(String, VerifyResult)> get verifyTrack => <(String, VerifyResult)>[
    ('V1', v1),
    ('V2', v2),
    ('V3', v3),
  ];
}

/// 状态 → 筛选分组
///
/// 与任务书约定一致：
/// - 进行中 = DRAFT + ANALYZED + ACTION_DONE
/// - 待验证 = V1 + V2 + V3
/// - 已关闭 = CLOSED
/// - REOPENED **归入进行中**（并带红色角标），因为它需要用户重新归因
enum DefectFilter {
  all('全部'),
  ongoing('进行中'),
  verifying('待验证'),
  closed('已关闭');

  const DefectFilter(this.label);

  final String label;

  bool matches(DefectTicket ticket) => switch (this) {
    DefectFilter.all => true,
    DefectFilter.ongoing =>
      ticket.status == DefectStatus.draft ||
          ticket.status == DefectStatus.analyzed ||
          ticket.status == DefectStatus.actionDone ||
          ticket.status == DefectStatus.reopened,
    DefectFilter.verifying => ticket.status.isVerifying,
    DefectFilter.closed => ticket.status == DefectStatus.closed,
  };
}

/// 相对时间（「3 天前」「刚刚」…）
///
/// 刻意不引 intl 之类的格式化库：任务书禁止第三方时间库，
/// 而这里只需要三种粒度（分钟 / 小时 / 天）。
String relativeTime(DateTime at, {DateTime? now}) {
  final DateTime base = now ?? DateTime.now();
  final Duration d = base.difference(at);

  if (d.inMinutes < 1) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays < 30) return '${d.inDays} 天前';
  if (d.inDays < 365) return '${(d.inDays / 30).floor()} 个月前';
  return '${(d.inDays / 365).floor()} 年前';
}

/// 绝对时间（详情页「创建时间」那一栏的小字）
String absoluteTime(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}

// ---------------------------------------------------------------------------
// mock 数据：8 条，覆盖全部 8 个 status
// ---------------------------------------------------------------------------
//
// 时间全部用 `now.subtract(...)` 相对构造，**不硬编码绝对日期**，
// 这样截图与「3 天前」这类文案永远自洽。
// 每天晚上跑测试也不会因为日期过期而文案跳变。

final DateTime _now = DateTime.now();

DateTime _ago({int days = 0, int hours = 0, int minutes = 0}) =>
    _now.subtract(Duration(days: days, hours: hours, minutes: minutes));

const List<DefectAction> _noActions = <DefectAction>[];

/// 构造一条 mock 缺陷单的简写
DefectTicket _ticket({
  required String id,
  required String qType,
  required String errorLayer,
  required String errorCause,
  required DefectPriority priority,
  required DefectStatus status,
  required String knowledgeNodeId,
  required String knowledgeNodeTitle,
  required String subjectName,
  required DateTime createdAt,
  int verificationRound = 1,
  int reopenCount = 0,
  List<DefectAction> actions = _noActions,
  VerifyResult v1 = VerifyResult.pending,
  VerifyResult v2 = VerifyResult.pending,
  VerifyResult v3 = VerifyResult.pending,
  required List<StatusEvent> history,
}) {
  return DefectTicket(
    id: id,
    qType: qType,
    errorLayer: errorLayer,
    errorCause: errorCause,
    priority: priority,
    status: status,
    verificationRound: verificationRound,
    reopenCount: reopenCount,
    createdAt: createdAt,
    knowledgeNodeId: knowledgeNodeId,
    knowledgeNodeTitle: knowledgeNodeTitle,
    subjectName: subjectName,
    actions: actions,
    v1: v1,
    v2: v2,
    v3: v3,
    statusHistory: history,
  );
}

/// 8 条 mock，每个 status 各一条
///
/// 任务书额外要求：
/// - V2 带 2 条 actions（1 完成 1 未完成）√
/// - CLOSED 带 3 条验证全 pass √
/// - REOPENED 带 reopen_count = 2 √
final List<DefectTicket> kDefectTickets = <DefectTicket>[
  // ① DRAFT —— 只记了错题，还没归因（因此 error_layer 是占位文案）
  _ticket(
    id: 'dt-0001',
    qType: '判断推理 · 类比推理',
    errorLayer: '未归因',
    errorCause: '刚记下这道错题，还没做归因分析。',
    priority: DefectPriority.p1,
    status: DefectStatus.draft,
    knowledgeNodeId: 'kn-analogy',
    knowledgeNodeTitle: '类比推理',
    subjectName: '行测',
    createdAt: _ago(days: 0, hours: 2),
    history: <StatusEvent>[
      StatusEvent(status: DefectStatus.draft, at: _ago(days: 0, hours: 2)),
    ],
  ),

  // ② ANALYZED —— 归因完成，但处理动作还没做
  _ticket(
    id: 'dt-0002',
    qType: '数量关系 · 行程问题',
    errorLayer: '方法不会',
    errorCause: '相遇问题里把速度相加当成相对速度，没有区分同向与相向两种情况。',
    priority: DefectPriority.p0,
    status: DefectStatus.analyzed,
    knowledgeNodeId: 'kn-journey',
    knowledgeNodeTitle: '行程问题',
    subjectName: '行测',
    createdAt: _ago(days: 2),
    history: <StatusEvent>[
      StatusEvent(status: DefectStatus.draft, at: _ago(days: 2, hours: 3)),
      StatusEvent(status: DefectStatus.analyzed, at: _ago(days: 2)),
    ],
  ),

  // ③ ACTION_DONE —— 动作都做完了，但**还没关闭**（核心不变量的展示样本）
  _ticket(
    id: 'dt-0003',
    qType: '言语理解 · 逻辑填空',
    errorLayer: '概念不清',
    errorCause: '把「相得益彰」和「相辅相成」的适用对象记混，前者要求两者互相映衬。',
    priority: DefectPriority.p1,
    status: DefectStatus.actionDone,
    knowledgeNodeId: 'kn-logic-fill',
    knowledgeNodeTitle: '逻辑填空',
    subjectName: '行测',
    createdAt: _ago(days: 3),
    actions: const <DefectAction>[
      DefectAction(id: 'ac-301', content: '重读成语辨析笔记 30 分钟', done: true),
      DefectAction(id: 'ac-302', content: '整理 10 组近义成语对照表', done: true),
    ],
    history: <StatusEvent>[
      StatusEvent(status: DefectStatus.draft, at: _ago(days: 3, hours: 5)),
      StatusEvent(status: DefectStatus.analyzed, at: _ago(days: 3, hours: 2)),
      StatusEvent(status: DefectStatus.actionDone, at: _ago(days: 1)),
    ],
  ),

  // ④ V1 —— 进入第一次验证，V1 待提交
  _ticket(
    id: 'dt-0004',
    qType: '资料分析 · 增长率比较',
    errorLayer: '计算失误',
    errorCause: '把基期值和现期值代反，导致增长率正负号算反。',
    priority: DefectPriority.p0,
    status: DefectStatus.v1,
    knowledgeNodeId: 'kn-growth',
    knowledgeNodeTitle: '增长率比较',
    subjectName: '行测',
    createdAt: _ago(days: 4),
    actions: const <DefectAction>[
      DefectAction(id: 'ac-401', content: '默写增长率的三个变形公式', done: true),
    ],
    history: <StatusEvent>[
      StatusEvent(status: DefectStatus.draft, at: _ago(days: 4, hours: 6)),
      StatusEvent(status: DefectStatus.analyzed, at: _ago(days: 4, hours: 3)),
      StatusEvent(status: DefectStatus.actionDone, at: _ago(days: 2)),
      StatusEvent(status: DefectStatus.v1, at: _ago(days: 1)),
    ],
  ),

  // ⑤ V2 —— 任务书要求：2 条 actions，1 done 1 未 done；V1 已 pass
  _ticket(
    id: 'dt-0005',
    qType: '判断推理 · 充分必要条件',
    errorLayer: '概念不清',
    errorCause: '把充分条件当成必要条件，忽略了「A 推 B」与「B 推 A」方向相反。',
    priority: DefectPriority.p0,
    status: DefectStatus.v2,
    knowledgeNodeId: 'kn-sufficient',
    knowledgeNodeTitle: '充分必要条件',
    subjectName: '行测',
    createdAt: _ago(days: 6),
    actions: const <DefectAction>[
      DefectAction(id: 'ac-501', content: '重做同类题 10 道（无答案）', done: true),
      DefectAction(id: 'ac-502', content: '画出蕴含关系方向图并口述一遍', done: false),
    ],
    v1: VerifyResult.pass,
    history: <StatusEvent>[
      StatusEvent(status: DefectStatus.draft, at: _ago(days: 6, hours: 8)),
      StatusEvent(status: DefectStatus.analyzed, at: _ago(days: 6, hours: 4)),
      StatusEvent(status: DefectStatus.actionDone, at: _ago(days: 5)),
      StatusEvent(status: DefectStatus.v1, at: _ago(days: 4)),
      StatusEvent(status: DefectStatus.v2, at: _ago(days: 2)),
    ],
  ),

  // ⑥ V3 —— V1/V2 都 pass，正在最后一次验证
  _ticket(
    id: 'dt-0006',
    qType: '常识判断 · 法律常识',
    errorLayer: '审题偏差',
    errorCause: '题干问「不属于」，按「属于」作答，漏看了否定词。',
    priority: DefectPriority.p2,
    status: DefectStatus.v3,
    knowledgeNodeId: 'kn-law',
    knowledgeNodeTitle: '法律常识',
    subjectName: '行测',
    createdAt: _ago(days: 9),
    actions: const <DefectAction>[
      DefectAction(id: 'ac-601', content: '圈出题干否定词再作答，练 20 题', done: true),
    ],
    v1: VerifyResult.pass,
    v2: VerifyResult.pass,
    history: <StatusEvent>[
      StatusEvent(status: DefectStatus.draft, at: _ago(days: 9, hours: 6)),
      StatusEvent(status: DefectStatus.analyzed, at: _ago(days: 9, hours: 2)),
      StatusEvent(status: DefectStatus.actionDone, at: _ago(days: 8)),
      StatusEvent(status: DefectStatus.v1, at: _ago(days: 7)),
      StatusEvent(status: DefectStatus.v2, at: _ago(days: 5)),
      StatusEvent(status: DefectStatus.v3, at: _ago(days: 2)),
    ],
  ),

  // ⑦ REOPENED —— 任务书要求 reopen_count = 2，第 3 轮待重新归因
  _ticket(
    id: 'dt-0007',
    qType: '判断推理 · 图形推理',
    errorLayer: '方法不会',
    errorCause: '只数了封闭区域数量，没看交点数与对称轴的复合规律。',
    priority: DefectPriority.p0,
    status: DefectStatus.reopened,
    verificationRound: 3,
    reopenCount: 2,
    knowledgeNodeId: 'kn-graphic',
    knowledgeNodeTitle: '图形推理',
    subjectName: '行测',
    createdAt: _ago(days: 21),
    actions: const <DefectAction>[
      DefectAction(id: 'ac-701', content: '整理图形推理五类规律清单', done: true),
      DefectAction(id: 'ac-702', content: '限时 15 分钟做 20 道图推', done: true),
    ],
    v1: VerifyResult.fail,
    v2: VerifyResult.pass,
    v3: VerifyResult.pass,
    history: <StatusEvent>[
      StatusEvent(status: DefectStatus.draft, at: _ago(days: 21, hours: 8)),
      StatusEvent(status: DefectStatus.analyzed, at: _ago(days: 21, hours: 3)),
      StatusEvent(status: DefectStatus.actionDone, at: _ago(days: 20)),
      StatusEvent(status: DefectStatus.v1, at: _ago(days: 18)),
      StatusEvent(status: DefectStatus.v2, at: _ago(days: 15)),
      StatusEvent(status: DefectStatus.v3, at: _ago(days: 10)),
      // 两次重开：V2 与 V3 各失败一次
      StatusEvent(status: DefectStatus.reopened, at: _ago(days: 12)),
      StatusEvent(status: DefectStatus.reopened, at: _ago(days: 3)),
    ],
  ),

  // ⑧ CLOSED —— 任务书要求三次验证全 pass
  _ticket(
    id: 'dt-0008',
    qType: '资料分析 · 比重变化',
    errorLayer: '计算失误',
    errorCause: '比重差公式里部分量/整体量的顺序写反，导致增减方向判断错误。',
    priority: DefectPriority.p1,
    status: DefectStatus.closed,
    knowledgeNodeId: 'kn-ratio',
    knowledgeNodeTitle: '比重变化',
    subjectName: '行测',
    createdAt: _ago(days: 30),
    actions: const <DefectAction>[
      DefectAction(id: 'ac-801', content: '抄写比重差公式并标注各量含义', done: true),
      DefectAction(id: 'ac-802', content: '做 15 道比重变化题并复盘', done: true),
    ],
    v1: VerifyResult.pass,
    v2: VerifyResult.pass,
    v3: VerifyResult.pass,
    history: <StatusEvent>[
      StatusEvent(status: DefectStatus.draft, at: _ago(days: 30, hours: 7)),
      StatusEvent(status: DefectStatus.analyzed, at: _ago(days: 30, hours: 2)),
      StatusEvent(status: DefectStatus.actionDone, at: _ago(days: 28)),
      StatusEvent(status: DefectStatus.v1, at: _ago(days: 26)),
      StatusEvent(status: DefectStatus.v2, at: _ago(days: 22)),
      StatusEvent(status: DefectStatus.v3, at: _ago(days: 18)),
      StatusEvent(status: DefectStatus.closed, at: _ago(days: 15)),
    ],
  ),
];
