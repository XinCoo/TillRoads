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
  notFoundError,
  pageParams,
  queryMany,
  queryOne,
  requireRow,
  selectRow,
  toJsonbParam,
  updateWithVersion,
} from './_common.mjs';
import { computeUrgency, isVerifyStage, windowDaysFor } from '../verify_window.mjs';
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
  // ★ m27163：自定义错因（可复用短标签，如「计算失误」）；DB 列 varchar(60)，限长在应用层做。
  'custom_reason',
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
  // ★ m27163：自定义错因（建单时透传 input.custom_reason）
  'custom_reason',
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
  const ticket = await insertRow(client, TABLE, INSERT_COLUMNS, values);

  // ★ FE-04 A2：建单时同步把 actions 落成 actions 表的真实行。
  //
  // 背景（FE-03 写操作联调发现的缺口）：此前 create 只把 actions 写进
  // defect_tickets.actions 这个 jsonb 列，actions 表一行都没有；而
  // beginVerification 的门禁 actions.assertAllDone() 读的是 actions 表，
  // 于是「建单带动作 → 进入验证」必然 NO_ACTIONS。前端一度在客户端逐条补 POST，
  // 但那只能救本 App 一个客户端，任何直接调后端 API 的调用方都会踩同一个坑。
  //
  // 这里把「写单行」+「逐条写 actions 行」收进调用方的同一个 withTransaction
  // （create 本身不 BEGIN，它总是被 withTransaction 包着跑），任一条动作失败
  // 整笔回滚，不会留下「单子在、动作丢了」的半截数据。
  //
  // 入参兼容两种形状：`['重做同类题']` 与 `[{content:'重做同类题', due:'2026-01-01'}]`。
  const created = await insertActionsForTicket(client, ticket.id, input.actions);
  return { ...ticket, actions: created };
}

/**
 * 把建单入参里的 actions 批量写成 actions 表行（done=false）。
 *
 * @param client 事务内 client
 * @param defectTicketId 刚落库的缺陷单 id
 * @param rawActions  `['文案'] | [{content, due}] | null | undefined`
 * @returns {Promise<Array<object>>} 新建的动作行（与 GET 详情的 actions 形状一致）
 */
async function insertActionsForTicket(client, defectTicketId, rawActions) {
  if (!Array.isArray(rawActions) || rawActions.length === 0) return [];
  const rows = [];
  for (const item of rawActions) {
    // 字符串直接当 content；对象取 content，并允许带 due。
    const content = typeof item === 'string' ? item : item?.content;
    const trimmed = content == null ? '' : String(content).trim();
    // 空白动作静默跳过（前端「添加动作」可能留空行，不该因此整单失败）。
    if (trimmed === '') continue;
    const due = typeof item === 'object' && item !== null ? (item.due ?? null) : null;
    rows.push(await actions.create(client, { defect_ticket_id: defectTicketId, content: trimmed, due }));
  }
  return rows;
}

/**
 * GET /defect-tickets/:id 的投影：在 `SELECT *` 基础上 LEFT JOIN 考点与科目。
 *
 * FE-03 联调发现：原实现直接 `SELECT *`，前端只拿到 knowledge_node_id，
 * 无法显示考点名与科目名（只能拿 id 前 8 位当占位）。这里补三个展示字段：
 *   knowledge_node_title / knowledge_node_freq_tag / subject_name。
 *
 * 为什么用 LEFT JOIN 而不是 INNER JOIN：knowledge_node_id 在 schema 里可空
 * （手写建单可以不带考点），INNER JOIN 会把这类单子直接从结果里丢掉。
 *
 * 注意：这是**读路径专用投影**。写方法（analyze / beginVerification /
 * submitVerification / update）仍走 updateWithVersion(... RETURNING *)，
 * 返回的是裸行（不带 JOIN 字段）——前端写完后会重新 GET 详情，不影响正确性。
 */
const SELECT_WITH_DISPLAY = `
  SELECT
    dt.*,
    kn.title AS knowledge_node_title,
    kn.freq_tag AS knowledge_node_freq_tag,
    sub.name AS subject_name
  FROM defect_tickets dt
  LEFT JOIN knowledge_nodes kn ON kn.id = dt.knowledge_node_id AND kn.deleted_at IS NULL
  LEFT JOIN subjects sub ON sub.id = kn.subject_id AND sub.deleted_at IS NULL
`;

export async function getById(client, id, { includeDeleted = false } = {}) {
  const sql = includeDeleted
    ? `${SELECT_WITH_DISPLAY} WHERE dt.id = $1`
    : `${SELECT_WITH_DISPLAY} WHERE dt.id = $1 AND dt.deleted_at IS NULL`;
  const row = await queryOne(client, sql, [id]);
  // 语义与 requireRow 保持一致：不存在或已软删 → 404。
  if (!row) throw notFoundError(TABLE, id);
  return row;
}

/** 可选 includeDeleted，用于乐观锁冲突时回带软删当前行（不 JOIN，只要原值）。 */
export async function findById(client, id, { includeDeleted = false } = {}) {
  return selectRow(client, TABLE, id, { includeDeleted });
}

/**
 * 列表（读路径专用投影，理由同 getById）。
 *
 * status 支持**多值**（FE-03 写操作联调 A2）：前端「进行中」= DRAFT+ANALYZED+
 * ACTION_DONE+REOPENED、「待验证」= V1+V2+V3 都是多状态集合，若只支持单值
 * 就只能拉全量在客户端过滤。
 *
 * 入参形态（opts.status）三种都接受，便利路由层与测试：
 *   · 字符串 `'V1,V2,V3'`（来自 query string）
 *   · 字符串数组 `['V1','V2']`
 *   · 单值 `'V1'`（等价于一元素集合）
 *
 * SQL 用 `status::text = ANY($n::text[])` 而不是拼字符串：
 *   · status 是 enum 类型，直接 = ANY(enum[] 字面量) 需要先造类型数组，
 *     转 text 比较最稳且能复用现有参数化路径；
 *   · 数组作为**一个**参数下发，不可能注入。
 */
export async function listByUser(client, userId, opts = {}) {
  if (!userId) throw new TypeError('defect_tickets.listByUser: userId 必填');
  const { limit, offset } = pageParams(opts);
  const where = ['dt.user_id = $1', 'dt.deleted_at IS NULL'];
  const params = [userId];

  const wanted = parseStatusFilter(opts.status);
  if (wanted.length > 0) {
    params.push(wanted);
    where.push(`dt.status::text = ANY($${params.length}::text[])`);
  }

  const sql = `${SELECT_WITH_DISPLAY}
    WHERE ${where.join(' AND ')}
    ORDER BY dt.created_at ASC, dt.id ASC
    LIMIT $${params.length + 1} OFFSET $${params.length + 2}`;
  return (await client.query(sql, [...params, limit, offset])).rows || [];
}

/** `'V1,V2,V3'` / `['V1','V2']` / `'V1'` → 去空白去空项的数组；非法输入返回 []（不过滤）。 */
function parseStatusFilter(status) {
  if (status == null) return [];
  const raw = Array.isArray(status) ? status : String(status).split(',');
  return raw.map((s) => String(s).trim()).filter((s) => s !== '');
}

/** 全表列表（供模考报告 / 复盘统计这类跨用户聚合端点使用）。 */
export async function listAll(client, opts = {}) {
  return listRows(client, TABLE, [], [], opts);
}

/**
 * 首页缺陷分布聚合（FE-07）。
 *
 * 为什么放在 SQL 层而不是让前端拉全量后本地 GROUP BY：
 *   · 前端已经要拉一次全量列表给缺陷单页，再拉一次给首页就是两次全量；
 *   · 「未关闭」的定义（`status::text <> 'CLOSED'`）属于业务口径，
 *     放在两处各写一遍必然漂移；
 *   · 八态计数用 `GROUP BY status` 一次算完，比前端遍历再累加省事且不会漏键。
 *
 * 返回两个聚合（结构固定，调用方不用兜底）：
 *   by_layer   [{error_layer,count}]  按 count DESC, error_layer ASC；只算未关闭
 *   by_status  {DRAFT:n,...,CLOSED:n}  八个键全部预填 0
 *   open_total / closed_total / total
 *
 * 口径（写进 README，避免下次有人改错）：
 *   · 一律 `deleted_at IS NULL`；
 *   · by_layer 只统计 **未关闭**（CLOSED 已经是收尾单，不影响“当前缺陷分布”）；
 *   · error_layer 为 NULL/空串/纯空白时归入 `unclassified`，前端显示「未分类」。
 */
export const OPEN_STATUSES = Object.freeze([
  'DRAFT',
  'ANALYZED',
  'ACTION_DONE',
  'V1',
  'V2',
  'V3',
  'REOPENED',
]);

export const ALL_STATUSES = Object.freeze([...OPEN_STATUSES, 'CLOSED']);

export const UNCLASSIFIED_LAYER = 'unclassified';

export async function defectStats(client, userId) {
  if (!userId) throw new TypeError('defect_tickets.defectStats: userId 必填');

  // 两条 SQL：status 用 GROUP BY 算八态，layer 用 GROUP BY + ORDER BY 算分布。
  // 没有合并成一条是因为两个聚合的过滤条件不同（status 算全部，layer 只算未关闭），
  // 硬合并要用 FILTER 套子查询，可读性反而差；两条都只扫同一用户的几十行，成本可接受。
  const statusRes = await client.query(
    `SELECT dt.status::text AS status, count(*)::int AS count
       FROM ${TABLE} dt
      WHERE dt.user_id = $1 AND dt.deleted_at IS NULL
      GROUP BY dt.status`,
    [userId],
  );

  const byStatus = {};
  for (const s of ALL_STATUSES) byStatus[s] = 0;
  for (const row of statusRes.rows || []) {
    // 只认白名单键：未来 schema 新增状态时不会静默改动契约形状
    if (Object.prototype.hasOwnProperty.call(byStatus, row.status)) {
      byStatus[row.status] = Number(row.count) || 0;
    }
  }

  const layerRes = await client.query(
    `SELECT COALESCE(NULLIF(btrim(dt.error_layer), ''), $2) AS error_layer,
            count(*)::int AS count
       FROM ${TABLE} dt
      WHERE dt.user_id = $1
        AND dt.deleted_at IS NULL
        AND dt.status::text <> 'CLOSED'
      GROUP BY 1
      ORDER BY count DESC, 1 ASC`,
    [userId, UNCLASSIFIED_LAYER],
  );

  const byLayer = (layerRes.rows || []).map((r) => ({
    error_layer: r.error_layer,
    count: Number(r.count) || 0,
  }));

  let openTotal = 0;
  for (const s of OPEN_STATUSES) openTotal += byStatus[s];
  const closedTotal = byStatus.CLOSED;

  return {
    user_id: userId,
    by_layer: byLayer,
    by_status: byStatus,
    open_total: openTotal,
    closed_total: closedTotal,
    total: openTotal + closedTotal,
  };
}

/**
 * 进入当前验证状态的时间（BE-04 核心难点，schema 无专用列）。
 *
 * schema.sql 的 defect_tickets **没有** v1/v2/v3_started_at，也没有通用 status_changed_at，
 * 只有 created_at / closed_at / updated_at。因此分而治之：
 *
 *   · **V2 可精确推断**：进入 V2 的时刻就是「本 round 内 V1 pass」那一刻，verifications
 *     有该行的 stage/round/created_at（V1 → V2 迁移与写 V1 记录在同一事务，见 submitVerification）。
 *   · **V3 可精确推断**：同理，V2 pass 那条记录。
 *   · **V1 不能精确推断**：begin-verification 只写 status，不落任何 verifications 行，
 *     所以 V1 只能用 updated_at 近似。
 *
 * 近似语义偏差（必须写进文档）：updated_at 被 set_updated() 在**任何** UPDATE 时刷新，
 * 包括非状态变更的 patch（改 q_type/priority 等）。因此某个 V1 单子如果被 patch 过，
 * 它的「已过天数」会被**少算**（进入时间看起来更晚），可能导致应逾期显示为临期。
 * 方向是「宁可晚报，不误报逾期」，对学习提醒场景是可接受的退化。
 *
 * SQL 取法：一次 LEFT JOIN LATERAL 拿「上一 stage 在当前 round 的 pass 时间」，
 * 避免 N+1（列表 50 条时逐条查会变 51 次往返）。
 */
const ENTERED_AT_SQL = `
  COALESCE(
    CASE dt.status
      WHEN 'V2' THEN prev.created_at
      WHEN 'V3' THEN prev.created_at
    END,
    dt.updated_at
  ) AS entered_at
`;

/**
 * 「上一 stage pass 时间」的 LATERAL 子查询。
 * - status='V2' 时上一 stage 是 V1；status='V3' 时是 V2。
 * - 限定 round = dt.verification_round：重开后旧 round 的历史记录不能当成本轮的进入时间。
 * - result='pass' 才算迁移发生过（fail 走的是 →REOPENED，不会进 V2/V3）。
 * - 软删的行不参与。
 */
const PREV_STAGE_LATERAL = `
  LEFT JOIN LATERAL (
    SELECT v.created_at
    FROM verifications v
    WHERE v.defect_ticket_id = dt.id
      AND v.round = dt.verification_round
      AND v.deleted_at IS NULL
      AND v.result = 'pass'
      AND v.stage = CASE dt.status WHEN 'V2' THEN 'V1'::verify_stage WHEN 'V3' THEN 'V2'::verify_stage END
    ORDER BY v.created_at DESC, v.id DESC
    LIMIT 1
  ) prev ON true
`;

/**
 * 验证任务列表（拍板项 1：只查 status IN (V1,V2,V3) 且未软删；不含 REOPENED / ACTION_DONE）。
 *
 * @param {object} client pg client / pool（鸭子类型，只需 query）
 * @param {string} userId 必填
 * @param {{stages?: string[], urgency?: string[], limit?: number, offset?: number}} opts
 * @returns {Promise<{items: object[], total: number, limit: number, offset: number}>}
 */
export async function listVerificationTasks(client, userId, opts = {}) {
  if (!userId) throw new TypeError('defect_tickets.listVerificationTasks: userId 必填');

  // stage 过滤：默认全部三态；给了就必须是合法 stage。
  const stages = Array.isArray(opts.stages) && opts.stages.length > 0 ? opts.stages : C.VERIFY_STAGES.slice();
  for (const s of stages) {
    if (!isVerifyStage(s)) throw new TypeError(`defect_tickets.listVerificationTasks: 非法 stage ${String(s)}`);
  }
  const urgencies = Array.isArray(opts.urgency) && opts.urgency.length > 0 ? opts.urgency : null;

  const params = [userId, stages];
  const where = [
    'dt.user_id = $1',
    'dt.deleted_at IS NULL',
    // 拍板项 1：只看正在验证中的三态。
    `dt.status::text = ANY($2::text[])`,
  ];

  // JOIN 展示信息：考点（knowledge_nodes）与科目（subjects）都可能为空，用 LEFT JOIN。
  const fromSql = `
    FROM defect_tickets dt
    LEFT JOIN knowledge_nodes kn ON kn.id = dt.knowledge_node_id AND kn.deleted_at IS NULL
    LEFT JOIN subjects sub ON sub.id = kn.subject_id AND sub.deleted_at IS NULL
    ${PREV_STAGE_LATERAL}
  `;

  const selectSql = `
    SELECT
      dt.id, dt.user_id, dt.exam_profile_id, dt.knowledge_node_id, dt.question_id,
      dt.q_type, dt.priority, dt.status::text AS stage,
      dt.verification_round, dt.reopen_count,
      dt.created_at, dt.updated_at, dt.version,
      kn.title AS knowledge_node_title,
      kn.freq_tag AS knowledge_node_freq_tag,
      sub.id AS subject_id, sub.name AS subject_name,
      ${ENTERED_AT_SQL}
    ${fromSql}
    WHERE ${where.join(' AND ')}
    ORDER BY entered_at ASC, dt.id ASC
  `;

  // 注意：不单独查 count()。因为 urgency 过滤发生在 JS（窗口值不进 SQL），
  // 过滤后的 total 只能在全量行上算，否则 total 与 items 会对不上。
  const allRows = await queryMany(client, selectSql, params);
  const now = opts.now ?? new Date();

  // urgency 在 JS 里算（拍板项：窗口值不进 SQL），所以必须先算完再过滤、再分页。
  const enriched = allRows.map((row) => {
    const windowDays = windowDaysFor(row.stage);
    const u = computeUrgency(row.entered_at, windowDays, now);
    return {
      ...row,
      entered_at: u.enteredAt,
      window_days: u.windowDays,
      days_left: u.daysLeft,
      overdue_days: u.overdueDays,
      elapsed_days: u.elapsedDays,
      due_at: u.dueAt,
      urgency: u.urgency,
    };
  });

  const filtered = urgencies ? enriched.filter((r) => urgencies.includes(r.urgency)) : enriched;
  const { limit, offset } = pageParams(opts);
  const items = filtered.slice(offset, offset + limit);

  return { items, total: filtered.length, limit, offset };
}

/**
 * 验证看板聚合（拍板项 4 第二个端点）。
 *
 * 与 listVerificationTasks 同源，因此直接复用它（stages 全量、urgency 不过滤）再在内存聚合，
 * 保证两个端点的数字**永远不会因为两份 SQL 漂移而不一致**。
 * 规模上：一个用户的验证中缺陷单是十数量级，全量取回再聚合是合理的。
 *
 * @returns {Promise<{total:number, by_stage:object, by_urgency:object, overdue:number, due_soon:number, normal:number}>}
 */
export async function verificationSummary(client, userId, opts = {}) {
  if (!userId) throw new TypeError('defect_tickets.verificationSummary: userId 必填');
  const { items } = await listVerificationTasks(client, userId, { now: opts.now, limit: 200, offset: 0 });

  const by_stage = { V1: 0, V2: 0, V3: 0 };
  const by_urgency = { overdue: 0, due_soon: 0, normal: 0 };
  for (const row of items) {
    if (Object.prototype.hasOwnProperty.call(by_stage, row.stage)) by_stage[row.stage] += 1;
    if (Object.prototype.hasOwnProperty.call(by_urgency, row.urgency)) by_urgency[row.urgency] += 1;
  }

  return {
    total: items.length,
    by_stage,
    by_urgency,
    overdue: by_urgency.overdue,
    due_soon: by_urgency.due_soon,
    normal: by_urgency.normal,
  };
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

/**
 * ★ m27163：缺陷单 ↔ 题目 一对多关联（defect_questions 表）。
 *
 * 表结构（migrations/0006_exam_custom_defect_questions.sql）：
 *   defect_questions(id uuid PK, defect_ticket_id uuid NOT NULL REFERENCES defect_tickets(id) ON DELETE CASCADE,
 *                     question_id uuid NOT NULL REFERENCES questions(id), sort int NOT NULL DEFAULT 0, created_at)
 *   + uk_defect_question(defect_ticket_id, question_id) 唯一索引
 *   + idx_dq_ticket(defect_ticket_id, sort)
 *
 * 这些函数只做 DB 读写；归属校验（缺陷单是否属于当前用户）在路由层做。
 */

export const LINK_TABLE = 'defect_questions';

const LINK_SELECT = `SELECT dq.id, dq.defect_ticket_id, dq.question_id, dq.sort, dq.created_at
    FROM ${LINK_TABLE} dq`;

/** 列某缺陷单的全部关联（按 sort ASC, id ASC）。 */
export async function listQuestionLinks(client, defectTicketId) {
  return queryMany(
    client,
    `${LINK_SELECT} WHERE dq.defect_ticket_id = $1 ORDER BY dq.sort ASC, dq.id ASC`,
    [defectTicketId],
  );
}

/** 列某缺陷单的关联 + 题目展示字段（JOIN questions），返回完整 stem。 */
export async function listQuestionLinksWithQuestions(client, defectTicketId) {
  const rows = await queryMany(
    client,
    `SELECT dq.id, dq.question_id, dq.sort, dq.created_at,
            q.stem, q.type, q.source, q.difficulty
       FROM ${LINK_TABLE} dq
       JOIN questions q ON q.id = dq.question_id
      WHERE dq.defect_ticket_id = $1
      ORDER BY dq.sort ASC, dq.id ASC`,
    [defectTicketId],
  );
  return rows;
}

/** 当前关联数（新增时的 sort = 该值，追加到末尾）。 */
export async function countQuestionLinks(client, defectTicketId) {
  const row = await queryOne(
    client,
    `SELECT COUNT(*)::int AS count FROM ${LINK_TABLE} WHERE defect_ticket_id = $1`,
    [defectTicketId],
  );
  return Number(row?.count ?? 0);
}

/** 是否已关联（用于 409 duplicate_defect_question）。 */
export async function findQuestionLink(client, defectTicketId, questionId) {
  return queryOne(
    client,
    `${LINK_SELECT} WHERE dq.defect_ticket_id = $1 AND dq.question_id = $2 LIMIT 1`,
    [defectTicketId, questionId],
  );
}

/** 新增一条关联（sort 显式给定）。唯一索引冲突由上层转成 409。 */
export async function createQuestionLink(client, { defect_ticket_id, question_id, sort }) {
  return queryOne(
    client,
    `INSERT INTO ${LINK_TABLE} (defect_ticket_id, question_id, sort)
     VALUES ($1, $2, $3)
     RETURNING id, defect_ticket_id, question_id, sort, created_at`,
    [defect_ticket_id, question_id, sort],
  );
}

/** 解除一条关联（返回被删行；无行 → null，路由层转 404）。 */
export async function deleteQuestionLink(client, defectTicketId, questionId) {
  return queryOne(
    client,
    `DELETE FROM ${LINK_TABLE}
      WHERE defect_ticket_id = $1 AND question_id = $2
      RETURNING id, defect_ticket_id, question_id, sort`,
    [defectTicketId, questionId],
  );
}

/**
 * 按传入顺序重排（只重排传入的那些，sort 取其在新列表中的下标 +1）。
 * 返回受影响行。
 */
export async function reorderQuestionLinks(client, defectTicketId, questionIds) {
  const rows = [];
  for (let i = 0; i < questionIds.length; i += 1) {
    const row = await queryOne(
      client,
      `UPDATE ${LINK_TABLE} SET sort = $3
        WHERE defect_ticket_id = $1 AND question_id = $2
        RETURNING id, defect_ticket_id, question_id, sort`,
      [defectTicketId, questionIds[i], i + 1],
    );
    if (row) rows.push(row);
  }
  return rows;
}

/**
 * ★ m27163：当前用户历史上用过的自定义错因 + 出现次数（错因下拉框的候选来源）。
 * 可选 exam_profile_id 限定同一考试目标。
 */
export async function listCustomReasons(client, userId, { examProfileId = null } = {}) {
  const params = [userId];
  let where = `user_id = $1 AND deleted_at IS NULL
      AND custom_reason IS NOT NULL AND TRIM(custom_reason) <> ''`;
  if (examProfileId) {
    params.push(examProfileId);
    where += ` AND exam_profile_id = $${params.length}`;
  }
  return queryMany(
    client,
    `SELECT custom_reason, COUNT(*)::int AS count
       FROM ${TABLE}
      WHERE ${where}
      GROUP BY custom_reason
      ORDER BY count DESC, custom_reason ASC`,
    params,
  );
}
