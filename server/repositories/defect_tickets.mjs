// server/repositories/defect_tickets.mjs
// 题路 TillRoad · BE-03 T1：缺陷单仓储（PG）——完整状态机
//
// ★ 双层防线（拍板项 2）：
//   · 应用层：本文件每次状态迁移前调用 core/index.mjs 的纯函数前置校验，
//     失败抛带 .code 的 Error（HTTP 层映射 400 + 可读错误码）。
//   · DB 层：schema.sql 的 check_defect_transition / check_defect_forbidden_phrase
//     触发器最后兜底（ILLEGAL_DEFECT_TRANSITION / FORBIDDEN_PHRASE_IN_ERROR_CAUSE），
//     防绕过（例如直接改库）。
//   两者已对齐，本轮不重做审计，也不重写触发器。
//
// ★ 派生列铁律（关键）：
//   verification_round / reopen_count / closed_at / updated_at / version
//   全部由 schema.sql 的触发器（set_updated + check_defect_transition）维护。
//   应用层**只写 status 与业务字段**，绝不把这些派生列放进 SET，否则 double+1。
//   这与此前四表「SET 不写系统列」是同一条原则的延伸。
//
// ★ 鸭子类型：只依赖 client.query()，不 import pg；所有写操作由调用方包 withTransaction。

import * as C from '../../core/index.mjs';
import {
  archiveWithVersion,
  insertRow,
  listRows,
  pageParams,
  requireRow,
  selectRow,
  toJsonbParam,
  updateWithVersion,
} from './_common.mjs';
import * as actions from './actions.mjs';
import * as verifications from './verifications.mjs';

export const TABLE = 'defect_tickets';

/** 通用字段可写白名单（不含任何状态机派生列与 status，状态只能走专用方法）。 */
export const WRITABLE_COLUMNS = Object.freeze([
  'q_type',
  'error_layer',
  'error_cause',
  'actions',
  'priority',
  'verification_state',
  'knowledge_node_id',
  'question_id',
  'exam_profile_id',
  'user_id',
  'reopen_reason',
]);

// create 时的列（status 显式给定，由调用方按 DRAFT / ANALYZED 决定；
// 派生列 verification_round/reopen_count/version 等交给 DB DEFAULT）。
const INSERT_COLUMNS = Object.freeze([
  'user_id',
  'exam_profile_id',
  'knowledge_node_id',
  'question_id',
  'q_type',
  'error_layer',
  'error_cause',
  'actions',
  'priority',
  'status',
]);

/** core 抛出的带 .code Error 原样上抛（httpError 第 3 分支 → 400 {error:code}）。 */
function asAppError(e) {
  if (e && typeof e.code === 'string' && !/^[0-9A-Z]{5}$/.test(e.code)) return e;
  return e;
}

function priorityOf(body = {}) {
  const src = body.priority && typeof body.priority === 'object' ? body.priority : body;
  const num = (v) => {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
  };
  return C.computePriority({
    frequency: num(src.frequency),
    loss: num(src.loss),
    closability: num(src.closability),
    targetContribution: num(src.targetContribution),
  });
}

/**
 * T5：建单即算 priority 并落库。
 * @param client 事务内 client
 * @param input  {user_id, exam_profile_id, status='DRAFT', error_layer?, error_cause?, ...}
 */
export async function create(client, input = {}) {
  if (!input.user_id) throw new TypeError('defect_tickets.create: user_id 必填');
  if (!input.exam_profile_id) throw new TypeError('defect_tickets.create: exam_profile_id 必填');
  const status = input.status === 'ANALYZED' ? 'ANALYZED' : 'DRAFT';
  // 直接 ANALYZED 也要过应用层归因校验（与 DB 触发器同规则，给可读错误）。
  if (status === 'ANALYZED') {
    C.assertAnalyzable({ status: 'DRAFT', error_layer: input.error_layer, error_cause: input.error_cause });
  }
  const values = INSERT_COLUMNS.map((c) => {
    if (c === 'status') return status;
    if (c === 'priority') return input.priority ?? priorityOf(input);
    if (c === 'actions') return toJsonbParam(input.actions ?? []);
    return input[c] ?? null;
  });
  return insertRow(client, TABLE, INSERT_COLUMNS, values);
}

export async function getById(client, id, { includeDeleted = false } = {}) {
  return requireRow(client, TABLE, id, { includeDeleted });
}

/** 可选 includeDeleted，用于乐观锁冲突时回带软删当前行。 */
export async function findById(client, id, { includeDeleted = false } = {}) {
  return selectRow(client, TABLE, id, { includeDeleted });
}

export async function listByUser(client, userId, opts = {}) {
  if (!userId) throw new TypeError('defect_tickets.listByUser: userId 必填');
  const { limit, offset } = pageParams(opts);
  const where = ['user_id = $1'];
  const params = [userId];
  if (opts.status) {
    params.push(opts.status);
    where.push(`status = $${params.length}`);
  }
  return listRows(client, TABLE, where, params, { limit, offset });
}

/** 全表列表（供模考报告 / 复盘统计这类跨用户聚合端点使用）。 */
export async function listAll(client, opts = {}) {
  return listRows(client, TABLE, [], [], opts);
}

/**
 * 通用字段更新（priority/q_type/knowledge_node_id/…）。
 * status 与派生列不接受：状态迁移必须走下面的专用方法。
 */
export async function update(client, id, patch = {}, baseVersion) {
  const forbidden = ['status', 'verification_round', 'reopen_count', 'closed_at'];
  for (const k of forbidden) {
    if (Object.prototype.hasOwnProperty.call(patch, k)) {
      throw new TypeError(`defect_tickets.update: 字段 ${k} 只能通过状态机方法修改`);
    }
  }
  return updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch,
    allowedColumns: WRITABLE_COLUMNS,
  });
}

/** T5：按新的 q_type / 归因因子重算 priority（factor 来自请求体，schema 不存这些因子）。 */
export function recomputePriority(body = {}) {
  return priorityOf(body);
}

/**
 * DRAFT → ANALYZED（或 REOPENED → ANALYZED）。
 * 应用层前置：C.assertAnalyzable 校验迁移合法 + 归因必填 + 禁用语。
 * 只写 status/error_layer/error_cause；DB 触发器在 REOPENED→ANALYZED 时 +verification_round。
 */
export async function analyze(client, id, { error_layer, error_cause }, baseVersion) {
  const cur = await requireRow(client, TABLE, id);
  try {
    C.assertAnalyzable({ status: cur.status, error_layer, error_cause });
  } catch (e) {
    throw asAppError(e);
  }
  return updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch: { status: 'ANALYZED', error_layer, error_cause },
    allowedColumns: [...WRITABLE_COLUMNS, 'status'],
  });
}

/** REOPENED → ANALYZED 的显式端点：先过 C.reanalyze（要求 status===REOPENED），再走 analyze。 */
export async function reanalyze(client, id, { error_layer, error_cause }, baseVersion) {
  const cur = await requireRow(client, TABLE, id);
  try {
    const r = C.reanalyze(cur); // 仅 REOPENED 合法
    void r; // verification_round 由 DB 触发器维护，这里只借它做校验
  } catch (e) {
    throw asAppError(e);
  }
  return analyze(client, id, { error_layer, error_cause }, baseVersion);
}

/**
 * ACTION_DONE → V1（拍板项 4：手动触发，要求至少一条 action 且全部 done）。
 * 应用层：C.beginVerification 校验迁移；actions.assertAllDone 校验前置条件。
 * 只写 status='V1'。
 */
export async function beginVerification(client, id, baseVersion) {
  const cur = await requireRow(client, TABLE, id);
  // 第一跳前置校验：ANALYZED → ACTION_DONE（core 纯函数，可读错误）。
  try {
    C.assertTransition(cur.status, 'ACTION_DONE');
  } catch (e) {
    throw asAppError(e);
  }
  const gate = await actions.assertAllDone(client, id);
  if (!gate.ok) {
    const err = new Error(
      gate.reason === 'NO_ACTIONS' ? '至少添加一条处理动作后才能进入验证' : '还有处理动作未完成',
    );
    err.code = gate.reason; // NO_ACTIONS / ACTIONS_NOT_DONE
    err.statusCode = 400;
    err.body = { error: err.code, message: err.message, pendingCount: gate.pendingCount ?? 0 };
    throw err;
  }
  // 两跳必须在同一事务内逐步落库：DB 触发器 check_defect_transition 只接受
  // ANALYZED→ACTION_DONE→V1，直接跳到 V1 会被判 ILLEGAL_DEFECT_TRANSITION。
  // 每跳都用 core 纯函数校验（应用层防线），触发器再兜底（DB 防线）。
  const actionDone = await updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch: { status: 'ACTION_DONE' },
    allowedColumns: [...WRITABLE_COLUMNS, 'status'],
  });
  // 第二跳前置校验：ACTION_DONE → V1。
  try {
    C.beginVerification({ status: 'ACTION_DONE' }, 'V1');
  } catch (e) {
    throw asAppError(e);
  }
  // 用第一跳返回的 version 做乐观锁（set_updated 已 +1）。
  return updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion: Number(actionDone.version),
    patch: { status: 'V1' },
    allowedColumns: [...WRITABLE_COLUMNS, 'status'],
  });
}

/**
 * V1/V2/V3 提交验证（拍板项 5：base_version 必填；actor=ai+pass → 403 在路由层）。
 * 应用层：C.applyVerification 校验当前阶段 + 结果 + 状态机，得到 next status。
 * 只写 status=next；reopen_count / closed_at 由 DB 触发器维护。
 * 同 (ticket, stage, round) 重复提交 → 409（友好 409，先于 DB 23505）。
 *
 * @returns {{ticket, verification}}
 */
export async function submitVerification(
  client,
  id,
  { stage, result, verify_type, question_id, evidence },
  baseVersion,
) {
  const cur = await requireRow(client, TABLE, id);
  let applied;
  try {
    applied = C.applyVerification(cur, stage, result);
  } catch (e) {
    throw asAppError(e);
  }
  const round = Number(cur.verification_round) || 1;
  const dup = await verifications.findByStageRound(client, id, stage, round);
  if (dup) {
    const err = new Error('duplicate verification in this round');
    err.code = 'conflict';
    err.statusCode = 409;
    err.body = {
      error: 'conflict',
      field: 'stage',
      current: dup,
      incoming: { stage, round },
      resolution: 'user_choice',
    };
    throw err;
  }
  // 先推进主单状态（触发器维护派生列），再写验证记录（round 用推进前读到的当前轮次）。
  const ticket = await updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch: { status: applied.status },
    allowedColumns: [...WRITABLE_COLUMNS, 'status'],
  });
  const verification = await verifications.create(client, {
    defect_ticket_id: id,
    stage,
    round,
    verify_type: verify_type || 'redo_hidden',
    question_id: question_id ?? null,
    result,
    evidence: evidence ?? null,
    verified_at: new Date().toISOString(),
  });
  return { ticket, verification };
}

/** 软删（与 exam_profiles.status='archived' 业务态不同）。 */
export async function archive(client, id, baseVersion) {
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
}

/** 读该单的验证时间线（含历史 round），供 GET 详情回带。 */
export async function verificationTimeline(client, id, opts = {}) {
  return verifications.listByDefect(client, id, opts);
}

/** 读该单的动作列表，供 GET 详情回带。 */
export async function actionList(client, id, opts = {}) {
  return actions.listByDefect(client, id, opts);
}
