// 本地状态机校验（R4a · 设计文档 §6.4 风险 R-9 的落地）。
//
// 为什么客户端也要有一份状态机：R4a 起，建单 / 归因 / 标记动作 / 进入验证 /
// 提交验证这五个写操作在离线时先落本地库并进队列。如果本地不校验，用户可以在
// 断网时把 DRAFT 直接推进到 V1、或提交一条带「粗心」的归因，等联网推送时才被
// 后端 400 拒绝 —— 此时本地已经写脏，还要回滚乐观修改（见设计 §3.2 失败分类）。
// 所以入队前先在本地拦一道，非法操作根本不会落库。
//
// 移植来源：`core/index.mjs`（Node 侧规则层，零依赖纯函数）。**这是独立移植，
// 不是共享代码** —— core 仍是后端与 schema 触发器的唯一权威，本文件只是把同一套
// 规则搬一份到 Dart，供离线校验用。两边不一致时以 core + schema 为准。
//
// 与 core 的已知差异（刻意为之，逐条记录）：
//   1. core 的 `STAGE_WINDOWS.V3.types` 只有 `['timed_mock']`；本文件按 R4a 任务书
//      放行 `timed_mock` 与 `teach_back`（V3 讲题复述是允许的复习动作）。
//      注意：后端 `submitVerification` **不校验** stage 与 verify_type 的搭配，
//      schema 只校验 verify_type 是合法 enum 值，所以放宽不会造成推送 400。
//   2. core 抛的是带 `.code` 的 `Error`；这里抛 `LocalValidationException`，
//      字段一一对应（`code`/`message`/`details`），页面可照旧按 code 分支。
//   3. core 的 `fail()` 用 `Object.assign` 挂 `phrases`/`from`/`to` 等附加字段；
//      这里统一收进 `details` Map，避免为每种错误定义子类。

import 'dart:convert';

/// 缺陷单八态（与 `schema.sql` 的 `defect_status` ENUM 一致）。
const List<String> kDefectStatuses = <String>[
  'DRAFT',
  'ANALYZED',
  'ACTION_DONE',
  'V1',
  'V2',
  'V3',
  'REOPENED',
  'CLOSED',
];

/// 合法状态迁移表（与 `core/index.mjs` 的 `TRANSITIONS` 逐条一致）。
const Map<String, List<String>> kDefectTransitions = <String, List<String>>{
  'DRAFT': <String>['ANALYZED'],
  'ANALYZED': <String>['ACTION_DONE'],
  'ACTION_DONE': <String>['V1'],
  'V1': <String>['V2', 'REOPENED'],
  'V2': <String>['V3', 'REOPENED'],
  'V3': <String>['CLOSED', 'REOPENED'],
  'REOPENED': <String>['ANALYZED'],
  'CLOSED': <String>[],
};

/// 主文档 AC-DT-02 禁用语。**必须与 `core/index.mjs` 的 `FORBIDDEN_PHRASES`
/// 和 `schema.sql` 的 `check_defect_forbidden_phrase()` 正则逐字一致**，
/// 否则会出现「本地放过、后端 400」或反过来的双向不一致。
const List<String> kForbiddenPhrases = <String>[
  '粗心',
  '马虎',
  '没掌握',
  '我懂了',
  '大意',
  '差不多',
  '忘了',
];

/// 三个验证阶段。
const List<String> kVerifyStages = <String>['V1', 'V2', 'V3'];

/// 合法验证方式（与 `schema.sql` 的 `verify_type` ENUM 一致）。
const List<String> kVerifyTypes = <String>[
  'redo_hidden',
  'similar_variant',
  'new_question',
  'timed_mock',
  'teach_back',
  'peer_check',
];

/// 每个阶段允许的验证方式（任务书 A1 的白名单）。
const Map<String, List<String>> kStageVerifyTypes = <String, List<String>>{
  'V1': <String>['redo_hidden', 'similar_variant', 'teach_back'],
  'V2': <String>['new_question'],
  'V3': <String>['timed_mock', 'teach_back'],
};

/// 验证结果只有两种（`pending` 是库默认值，不能由用户提交）。
const List<String> kVerifyResults = <String>['pass', 'fail'];

/// 本地校验失败。字段与 `core/index.mjs` 抛出的 `Error` 一一对应：
/// `.code` 是业务码（页面按它分支），`details` 承载附加信息。
class LocalValidationException implements Exception {
  LocalValidationException(this.code, this.message, {Map<String, Object?>? details})
    : details = details ?? const <String, Object?>{};

  /// 业务错误码，例如 `ILLEGAL_DEFECT_TRANSITION` / `FORBIDDEN_PHRASE_IN_ERROR_CAUSE`。
  final String code;

  /// 可直接上屏的中文说明。
  final String message;

  /// 附加信息（如 `{from, to}` / `{phrases}` / `{stage, currentStatus}`）。
  final Map<String, Object?> details;

  @override
  String toString() => 'LocalValidationException($code): $message';
}

/// 需要校验状态的缺陷单快照（只取状态机关心的三个字段）。
///
/// 为什么不复用 `DefectTicket`：那是有 20 多个字段的 UI 模型，且可能来自 mock；
/// 状态机只需要 status + 两个计数器，用窄类型可以单测不依赖任何页面模型。
class LocalTicketState {
  const LocalTicketState({
    required this.status,
    this.reopenCount = 0,
    this.verificationRound = 1,
  });

  final String status;
  final int reopenCount;
  final int verificationRound;
}

/// 动作快照（进入验证的门禁）。
class LocalActionState {
  const LocalActionState({required this.content, this.done = false});

  final String content;
  final bool done;
}

/// `applyVerification` 的返回值（与 core 的 `{status, reopen_count, reopenWarning}` 对齐）。
class VerificationDecision {
  const VerificationDecision({
    required this.status,
    required this.reopenCount,
    this.reopenWarning = false,
  });

  final String status;
  final int reopenCount;

  /// 连续重开 >= 3 时置 true，页面据此提示「建议抽验」（主文档 4.5）。
  final bool reopenWarning;

  @override
  String toString() =>
      'VerificationDecision($status, reopen=$reopenCount, warning=$reopenWarning)';
}

/// `reanalyze` 的返回值。
class ReanalyzeDecision {
  const ReanalyzeDecision({
    required this.status,
    required this.verificationRound,
    required this.reopenCount,
  });

  final String status;
  final int verificationRound;
  final int reopenCount;
}

/// 迁移是否合法。两个值都必须合法，且目标在来源的允许集合里。
bool canTransition(String from, String to) {
  if (!kDefectStatuses.contains(from) || !kDefectStatuses.contains(to)) {
    return false;
  }
  final List<String> allowed = kDefectTransitions[from] ?? const <String>[];
  return allowed.contains(to);
}

/// 断言迁移合法，否则抛 `ILLEGAL_DEFECT_TRANSITION`。
void assertTransition(String from, String to) {
  if (!canTransition(from, to)) {
    throw LocalValidationException(
      'ILLEGAL_DEFECT_TRANSITION',
      '不允许从 $from 直接变成 $to。',
      details: <String, Object?>{'from': from, 'to': to},
    );
  }
}

/// 返回命中禁用语的列表；非字符串或空串返回空列表（与 core 同语义）。
List<String> findForbiddenPhrases(Object? text) {
  if (text is! String || text.isEmpty) {
    return const <String>[];
  }
  return kForbiddenPhrases
      .where((String p) => text.contains(p))
      .toList(growable: false);
}

/// 是否含禁用语。
bool containsForbiddenPhrase(Object? text) => findForbiddenPhrases(text).isNotEmpty;

/// 断言归因原因不含禁用语，否则抛 `FORBIDDEN_PHRASE_IN_ERROR_CAUSE`。
void assertNoForbiddenPhrase(Object? text) {
  final List<String> phrases = findForbiddenPhrases(text);
  if (phrases.isNotEmpty) {
    throw LocalValidationException(
      'FORBIDDEN_PHRASE_IN_ERROR_CAUSE',
      '归因原因不能写「${phrases.join('、')}」，请写具体是哪个知识点、哪一步没想通。',
      details: <String, Object?>{'phrases': phrases},
    );
  }
}

/// 归因校验（转入 ANALYZED 时）：状态迁移合法 + 层级与原因必填 + 原因无禁用语。
///
/// 与 core 的 `assertAnalyzable({status, error_layer, error_cause})` 一一对应：
/// DRAFT 建单允许未归因，但一旦要进入 ANALYZED 就三项全查。
void assertAnalyzable({
  required String status,
  required Object? errorLayer,
  required Object? errorCause,
}) {
  // 仅 DRAFT 或 REOPENED 能进入 ANALYZED（由迁移表保证）。
  assertTransition(status, 'ANALYZED');
  if (errorLayer is! String || errorLayer.trim().isEmpty) {
    throw LocalValidationException('MISSING_ERROR_LAYER', '请选择错误层级（概念/方法/计算/审题）。');
  }
  if (errorCause is! String || errorCause.trim().isEmpty) {
    throw LocalValidationException('MISSING_ERROR_CAUSE', '请写清楚错误原因。');
  }
  assertNoForbiddenPhrase(errorCause);
}

/// 进入验证的门禁：至少一条动作，且全部已完成。
///
/// 对应后端 `actions.assertAllDone()`（`server/repositories/defect_tickets.mjs`
/// 的 `beginVerification`），错误码沿用后端的 `NO_ACTIONS` / `ACTIONS_NOT_DONE`，
/// 这样页面既能处理离线拦截、也能处理联网后的同样错误。
void assertCanBeginVerification(List<LocalActionState> actions) {
  final List<LocalActionState> nonEmpty = actions
      .where((LocalActionState a) => a.content.trim().isNotEmpty)
      .toList(growable: false);
  if (nonEmpty.isEmpty) {
    throw LocalValidationException('NO_ACTIONS', '先添加至少一条处理动作，再进入验证。');
  }
  final int pending = nonEmpty.where((LocalActionState a) => !a.done).length;
  if (pending > 0) {
    throw LocalValidationException(
      'ACTIONS_NOT_DONE',
      '还有 $pending 条处理动作未完成，全部勾选后才能进入验证。',
      details: <String, Object?>{'pendingCount': pending},
    );
  }
}

/// 校验阶段与验证方式的搭配是否合法，否则抛 `INVALID_VERIFY_TYPE`。
///
/// 后端不校验这层搭配（schema 只校验 verify_type 是合法 enum），所以在本地拦
/// 不会造成「本地拒绝但后端接受」的推送失败；它纯粹是为了让用户选对方式。
void validateVerifyType({required String stage, required String verifyType}) {
  if (!kVerifyStages.contains(stage)) {
    throw LocalValidationException(
      'INVALID_VERIFICATION_STAGE',
      '未知的验证阶段：$stage',
      details: <String, Object?>{'stage': stage},
    );
  }
  if (!kVerifyTypes.contains(verifyType)) {
    throw LocalValidationException(
      'INVALID_VERIFY_TYPE',
      '未知的验证方式：$verifyType',
      details: <String, Object?>{'stage': stage, 'verifyType': verifyType},
    );
  }
  final List<String> allowed = kStageVerifyTypes[stage] ?? const <String>[];
  if (!allowed.contains(verifyType)) {
    throw LocalValidationException(
      'INVALID_VERIFY_TYPE',
      '$stage 阶段不支持该验证方式，可选：${allowed.join(' / ')}。',
      details: <String, Object?>{
        'stage': stage,
        'verifyType': verifyType,
        'allowed': allowed,
      },
    );
  }
}

/// 验证推进（核心不变量），与 core 的 `applyVerification(ticket, stage, result)` 等价：
///   pass → 按状态机推进 V1→V2→V3→CLOSED
///   fail → REOPENED，reopen_count+1，连续 >=3 置 reopenWarning
/// 前置条件：`ticket.status` 必须等于当前 stage（即正处于该验证阶段）。
VerificationDecision applyVerification(
  LocalTicketState ticket,
  String stage,
  String result,
) {
  if (!kVerifyStages.contains(stage)) {
    throw LocalValidationException(
      'INVALID_VERIFICATION_STAGE',
      '未知的验证阶段：$stage',
      details: <String, Object?>{'stage': stage},
    );
  }
  if (!kVerifyResults.contains(result)) {
    throw LocalValidationException(
      'INVALID_VERIFICATION_RESULT',
      '验证结果只能是 pass 或 fail，收到：$result',
      details: <String, Object?>{'result': result},
    );
  }
  if (ticket.status != stage) {
    throw LocalValidationException(
      'INVALID_VERIFICATION_STAGE',
      '当前单据不处于 $stage 阶段（实际 $ticket.status），不能提交该阶段验证。',
      details: <String, Object?>{'stage': stage, 'currentStatus': ticket.status},
    );
  }

  if (result == 'fail') {
    final int nextCount = ticket.reopenCount + 1;
    return VerificationDecision(
      status: 'REOPENED',
      reopenCount: nextCount,
      reopenWarning: nextCount >= 3,
    );
  }

  const Map<String, String> nextStage = <String, String>{
    'V1': 'V2',
    'V2': 'V3',
    'V3': 'CLOSED',
  };
  final String next = nextStage[stage]!;
  assertTransition(ticket.status, next);
  return VerificationDecision(
    status: next,
    reopenCount: ticket.reopenCount,
    reopenWarning: false,
  );
}

/// 进入验证：只允许 **ANALYZED** → V1（对应用户点「进入验证」的真实入口）。
///
/// 这里刻意与 core 的 `beginVerification(ticket, stage='V1')` **不同口径**，原因是
/// 后端的 `beginVerification`（`server/repositories/defect_tickets.mjs`）是「一次请求
/// 写两步」：先 `C.assertTransition(cur.status, 'ACTION_DONE')`（要求当前是
/// ANALYZED），在同一事务里写 ANALYZED→ACTION_DONE，再用第一跳返回的 version
/// 写 ACTION_DONE→V1。所以端点的入参状态是 ANALYZED，不是 ACTION_DONE。
///
/// 实机验证踩到过：写成 `assertTransition(status,'V1')`（只认 ACTION_DONE）会让
/// 所有正常单子在离线入队时被本地拦住，且即使入了队也会被服务端 400
/// ILLEGAL_DEFECT_TRANSITION 判死。
///
/// 因此本地只检查「当前是 ANALYZED」+「动作全完成」，**不预测 version**：
/// 云端两跳 version +2，推送前重新 GET 拿最新 version（任务书 C3）。
void assertBeginVerification(String status, {String stage = 'V1'}) {
  if (stage != 'V1') {
    throw LocalValidationException(
      'INVALID_VERIFICATION_STAGE',
      '进入验证只能从 V1 开始，收到：$stage',
      details: <String, Object?>{'stage': stage},
    );
  }
  // 云端端点要求当前是 ANALYZED（它自己两跳）；本地不许用 ACTION_DONE。
  assertTransition(status, 'ACTION_DONE');
}

/// 重开后的再归因：只允许 REOPENED → ANALYZED，且 verification_round +1。
///
/// 与 core 的 `reanalyze(ticket)` 等价。DB 触发器也会把 round +1，本地这一步是
/// 为了让 UI 在离线时就能显示「第 N 轮」。
ReanalyzeDecision reanalyze(LocalTicketState ticket) {
  assertTransition(ticket.status, 'ANALYZED');
  if (ticket.status != 'REOPENED') {
    throw LocalValidationException(
      'ILLEGAL_DEFECT_TRANSITION',
      '只有重开（REOPENED）的单才能重新归因。',
      details: <String, Object?>{'from': ticket.status, 'to': 'ANALYZED'},
    );
  }
  return ReanalyzeDecision(
    status: 'ANALYZED',
    verificationRound: ticket.verificationRound + 1,
    reopenCount: ticket.reopenCount,
  );
}

/// 调试用：把规则表序列化成 JSON，便于日志里核对「这份规则是哪一版」。
String describeLocalStateMachine() => jsonEncode(<String, Object?>{
  'transitions': kDefectTransitions,
  'forbiddenPhrases': kForbiddenPhrases,
  'stageVerifyTypes': kStageVerifyTypes,
});
