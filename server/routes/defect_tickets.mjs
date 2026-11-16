// server/routes/defect_tickets.mjs
// 题路 TillRoad · BE-03 T4：缺陷单状态机路由（PG）
//
// **本轮重写**：第 4 步这里还是内存 Map 的「只搬不改」版本；BE-03 把整组端点
// 迁到 PG 仓储（defect_tickets / actions / verifications），并实现拍板项 2/4/5：
//   · 双层防线：每次状态迁移经仓储层的 core 纯函数前置校验，DB 触发器兜底；
//   · actions → ACTION_DONE 只能由手动 PATCH /:id/begin-verification 触发；
//   · 所有写状态迁移的端点强制 base_version（body.version）。
//
// 仍然留在内存态的只有 AI 任务（state.aiJobs）——BE-03 不碰 AI/模考/复盘的
// 持久化（分别属 BE-05/BE-06）。模考报告/复盘统计改为从 PG 读缺陷单，
// 不再依赖 state.defectTickets。
//
// 依赖注入（测试缝）：ctx.repos 可注入 fake 仓储（形如
//   { client, defectTickets, actions, verifications }，方法首参为 client 可忽略），
//   此时所有读写走 fake、不经 pool；未注入则走真的 PG 仓储 + withTransaction。

import { randomUUID } from 'node:crypto';
import * as C from '../../core/index.mjs';
import { withTransaction } from '../repositories/base.mjs';
import * as dtRepo from '../repositories/defect_tickets.mjs';
import * as actionRepo from '../repositories/actions.mjs';
import * as verRepo from '../repositories/verifications.mjs';
import { ok, fail, pagination, readBaseVersion } from './_http.mjs';

const now = () => new Date().toISOString();

/**
 * core 抛出的业务码 → 对外契约码（保持一致于既有 API，避免客户端改动）。
 * 仓储层不会改这些码，只是把它们从 Error.code 翻成 HTTP body.error。
 */
const PUBLIC_CODE = Object.freeze({
  FORBIDDEN_PHRASE_IN_ERROR_CAUSE: 'forbidden_phrase',
  MISSING_ERROR_LAYER: 'missing_error_layer_or_cause',
  MISSING_ERROR_CAUSE: 'missing_error_layer_or_cause',
  MISSING_ERROR_LAYER_OR_CAUSE: 'missing_error_layer_or_cause',
});

/** 把 core/仓储的业务 Error 映射成对外可读的 400；其余原样上抛交给 httpError。 */
function toHttpError(e) {
  if (e && typeof e.code === 'string' && PUBLIC_CODE[e.code]) {
    const out = new Error(e.message || e.code);
    out.code = PUBLIC_CODE[e.code];
    out.statusCode = 400;
    out.body = { error: out.code };
    return out;
  }
  return e;
}

/**
 * 解析仓储来源。返回：
 *   - repos: { defectTickets, actions, verifications }（方法与 PG 仓储同形，首参 client）
 *   - run(client => Promise)：写操作包装器（真库包事务，fake 直接调）
 *   - read(client => Promise)：读操作包装器（真库用 pool，fake 用 fake client）
 */
function resolve(ctx) {
  const injected = ctx.repos && ctx.repos.defectTickets;
  if (injected) {
    const client = ctx.repos.client ?? null;
    return {
      repos: {
        defectTickets: ctx.repos.defectTickets,
        actions: ctx.repos.actions,
        verifications: ctx.repos.verifications,
      },
      run: (fn) => fn(client),
      read: (fn) => fn(client),
    };
  }
  const { pool } = ctx;
  return {
    repos: { defectTickets: dtRepo, actions: actionRepo, verifications: verRepo },
    run: (fn) => withTransaction(pool, fn),
    read: (fn) => fn(pool),
  };
}

// ---------------------------------------------------------------------------
// 建单
// ---------------------------------------------------------------------------
async function createTicket(ctx) {
  const { body } = ctx;
  const { repos, run } = resolve(ctx);
  const wantDraft = body.status === 'DRAFT' || body.draft === true;

  try {
    // 带完整归因直接建 ANALYZED 时，仓储内会走 C.assertAnalyzable 前置校验；
    // DRAFT 草稿则允许 error_layer/error_cause 为空（P0-3）。
    const input = {
      user_id: body.user_id,
      exam_profile_id: body.exam_profile_id,
      knowledge_node_id: body.knowledge_node_id,
      question_id: body.question_id,
      q_type: body.q_type,
      error_layer: body.error_layer,
      error_cause: body.error_cause,
      actions: body.actions,
      // priority 由仓储用 C.computePriority 在事务内计算（T5）
      frequency: body.frequency,
      loss: body.loss,
      closability: body.closability,
      targetContribution: body.targetContribution,
      status: wantDraft ? 'DRAFT' : 'ANALYZED',
    };
    const ticket = await run((client) => repos.defectTickets.create(client, input));
    return ok(ticket, 201);
  } catch (e) {
    throw toHttpError(e);
  }
}

// ---------------------------------------------------------------------------
// 状态迁移 handlers（每次都强制 base_version）
// ---------------------------------------------------------------------------
async function analyzeTicket(ctx, id) {
  const { body } = ctx;
  const baseVersion = readBaseVersion(body); // 拍板项 5：PATCH/POST 迁移都强制
  const { repos, run } = resolve(ctx);
  try {
    const method = body.status === 'REOPENED' ? 'reanalyze' : 'analyze';
    const ticket = await run((client) =>
      repos.defectTickets[method](client, id, {
        error_layer: body.error_layer,
        error_cause: body.error_cause,
      }, baseVersion));
    return ok(ticket);
  } catch (e) {
    throw toHttpError(e);
  }
}

async function addAction(ctx, id) {
  const { body } = ctx;
  const { repos, run } = resolve(ctx);
  const content = body.action ?? body.content;
  if (!content || String(content).trim() === '') {
    throw Object.assign(new Error('action 内容必填'), { code: 'MISSING_ACTION_CONTENT' });
  }
  try {
    const action = await run((client) => repos.actions.create(client, {
      defect_ticket_id: id,
      content,
      done: body.done === undefined ? false : !!body.done,
      due: body.due,
    }));
    return ok(action, 201);
  } catch (e) {
    throw toHttpError(e);
  }
}

async function markActionDone(ctx, actionId) {
  const baseVersion = readBaseVersion(ctx.body);
  const { repos, run } = resolve(ctx);
  try {
    const action = await run((client) =>
      repos.actions.markDone(client, actionId, ctx.body.done === undefined ? true : !!ctx.body.done, baseVersion));
    return ok(action);
  } catch (e) {
    throw toHttpError(e);
  }
}

/**
 * 拍板项 4：ANALYZED → ACTION_DONE 不再由 POST /:id/action 自动推进。
 * 用户手动点「进入验证」→ PATCH /:id/begin-verification；
 * 仓储内 C.beginVerification 校验迁移 + actions.assertAllDone 校验前置。
 */
async function beginVerification(ctx, id) {
  const baseVersion = readBaseVersion(ctx.body);
  const { repos, run } = resolve(ctx);
  try {
    const ticket = await run((client) => repos.defectTickets.beginVerification(client, id, baseVersion));
    return ok(ticket);
  } catch (e) {
    throw toHttpError(e);
  }
}

async function submitVerification(ctx, id) {
  const { body } = ctx;
  const baseVersion = readBaseVersion(body); // 拍板项 5：防并发提交导致状态错乱
  // 「仅用户可标记 pass」：AI 不得把缺陷单推进/关闭（不变量，保留）。
  if (body.actor === 'ai' && body.result === 'pass') {
    return fail('ai_cannot_close', 403, { message: '仅用户可标记验证通过（AI 不能关闭缺陷单）' });
  }
  const { repos, run } = resolve(ctx);
  try {
    const out = await run((client) =>
      repos.defectTickets.submitVerification(client, id, {
        stage: body.stage,
        result: body.result,
        verify_type: body.verify_type ?? body.type,
        question_id: body.question_id,
        evidence: body.evidence,
      }, baseVersion));
    return ok(out, 201);
  } catch (e) {
    throw toHttpError(e);
  }
}

async function reanalyze(ctx, id) {
  const baseVersion = readBaseVersion(ctx.body);
  const { repos, run } = resolve(ctx);
  try {
    const ticket = await run((client) => repos.defectTickets.reanalyze(client, id, {
      error_layer: ctx.body.error_layer,
      error_cause: ctx.body.error_cause,
    }, baseVersion));
    return ok(ticket);
  } catch (e) {
    throw toHttpError(e);
  }
}

async function patchTicket(ctx, id) {
  const baseVersion = readBaseVersion(ctx.body);
  const { repos, run } = resolve(ctx);
  const { body } = ctx;
  // 通用 PATCH 只改非状态字段；status 变更必须走上面的专用方法（仓储层已拒绝）。
  const patch = {};
  for (const k of ['priority', 'q_type', 'error_layer', 'error_cause', 'knowledge_node_id',
    'question_id', 'exam_profile_id', 'user_id', 'actions', 'reopen_reason', 'verification_state']) {
    if (Object.prototype.hasOwnProperty.call(body, k)) patch[k] = body[k];
  }
  // T5：q_type / 归因因子变化则重算 priority（未显式传 priority 时）。
  if (!Object.prototype.hasOwnProperty.call(patch, 'priority') &&
      (Object.prototype.hasOwnProperty.call(body, 'frequency') ||
       Object.prototype.hasOwnProperty.call(body, 'loss') ||
       Object.prototype.hasOwnProperty.call(body, 'closability') ||
       Object.prototype.hasOwnProperty.call(body, 'targetContribution'))) {
    patch.priority = dtRepo.recomputePriority(body);
  }
  try {
    const ticket = await run((client) => repos.defectTickets.update(client, id, patch, baseVersion));
    return ok(ticket);
  } catch (e) {
    throw toHttpError(e);
  }
}

async function deleteTicket(ctx, id) {
  const baseVersion = readBaseVersion(ctx.body);
  const { repos, run } = resolve(ctx);
  try {
    const ticket = await run((client) => repos.defectTickets.archive(client, id, baseVersion));
    return ok(ticket);
  } catch (e) {
    throw toHttpError(e);
  }
}

// ---------------------------------------------------------------------------
// 读 handlers
// ---------------------------------------------------------------------------
async function getTicket(ctx, id) {
  const { repos, read } = resolve(ctx);
  try {
    const ticket = await read((c) => repos.defectTickets.getById(c, id));
    const [verifications, actions] = await Promise.all([
      read((c) => repos.verifications.listByDefect(c, id)),
      read((c) => repos.actions.listByDefect(c, id)),
    ]);
    return ok({ ...ticket, verifications, actions });
  } catch (e) {
    throw toHttpError(e);
  }
}

async function listTicketsByUser(ctx, userId) {
  const { repos, read } = resolve(ctx);
  const pg = pagination(ctx.searchParams);
  const rows = await read((c) => repos.defectTickets.listByUser(c, userId, {
    ...pg,
    status: ctx.searchParams.get('status') || undefined,
  }));
  return ok({ items: rows, ...pg });
}

/** 跨用户读全部（模考报告 / 复盘统计用）。fake 层没有 listAll 时回退空数组。 */
async function listTicketsForStats(ctx) {
  const { repos, read } = resolve(ctx);
  if (typeof repos.defectTickets.listAll !== 'function') return [];
  return read((c) => repos.defectTickets.listAll(c, { limit: 1000, offset: 0 }));
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// 复盘（读 PG 缺陷单；AI 任务仍走内存）
// 模考报告已移到 server/routes/mock_exams.mjs（BE-05）：原来的假数据端点已删除
// ---------------------------------------------------------------------------

async function reviewCycles(ctx) {
  const tickets = await listTicketsForStats(ctx);
  const type = ctx.searchParams.get('type') || 'weekly';
  return ok({
    type,
    closed_count: tickets.filter((x) => x.status === 'CLOSED').length,
    reopened_count: tickets.filter((x) => x.status === 'REOPENED').length,
    new_defects: tickets.length,
    timeline: tickets.slice(0, 10).map((x) => ({ id: x.id, status: x.status, created_at: x.created_at })),
  });
}

// ---------------------------------------------------------------------------
// AI 生成（仍内存；BE-03 不碰）
// ---------------------------------------------------------------------------
function submitAiJob(ctx) {
  const { body, state } = ctx;
  const v = C.validateAIGenerateRequest(body);
  if (!v.ok) return fail(v.error.code, 400, { message: v.error.message });
  const job_id = randomUUID();
  const provider_snapshot = body.provider ?? 'deepseek';
  const model_snapshot = body.model ?? body.model_name ?? 'deepseek-chat';
  state.aiJobs.set(job_id, {
    job_id,
    status: 'pending',
    provider_snapshot,
    model_snapshot,
    count: body.count,
    payload: { ...body },
    created_at: now(),
  });
  return ok({ job_id, status: 'pending', provider_snapshot, model_snapshot }, 202);
}

// ---------------------------------------------------------------------------
// 路由匹配
// ---------------------------------------------------------------------------
export function match(method, seg, ctx) {
  const { body } = ctx;

  // 规范路径 POST /verifications（body.defect_ticket_id）→ 委托给嵌套路径。
  if (method === 'POST' && seg.length === 1 && seg[0] === 'verifications' && body.defect_ticket_id) {
    return submitVerification(ctx, String(body.defect_ticket_id));
  }

  // POST /defect-tickets -> 201 建单
  if (method === 'POST' && seg.length === 1 && seg[0] === 'defect-tickets') {
    return createTicket(ctx);
  }

  // GET /users/:userId/defect-tickets?status=...
  if (method === 'GET' && seg.length === 3 && seg[0] === 'users' && seg[2] === 'defect-tickets') {
    return listTicketsByUser(ctx, seg[1]);
  }


  // GET /review-cycles?type=weekly
  if (method === 'GET' && seg.length === 1 && seg[0] === 'review-cycles') {
    return reviewCycles(ctx);
  }

  // AI 生成（含 /ai-jobs 别名）
  if (method === 'POST' && (
    (seg.length === 2 && seg[0] === 'ai' && seg[1] === 'questions:generate') ||
    (seg.length === 1 && seg[0] === 'ai-jobs')
  )) {
    return submitAiJob(ctx);
  }

  if (seg[0] !== 'defect-tickets' || seg.length < 2) return null;
  const id = seg[1];

  // POST/PATCH /defect-tickets/:id/analyze —— DRAFT/REOPENED → ANALYZED
  if ((method === 'POST' || method === 'PATCH') && seg.length === 3 && seg[2] === 'analyze') {
    return analyzeTicket(ctx, id);
  }

  // POST /defect-tickets/:id/actions —— 添加动作（不自动推进状态）
  if (method === 'POST' && seg.length === 3 && seg[2] === 'actions') {
    return addAction(ctx, id);
  }

  // PATCH /defect-tickets/:id/actions/:actionId —— 标记动作 done（base_version 必填）
  if (method === 'PATCH' && seg.length === 4 && seg[2] === 'actions') {
    return markActionDone(ctx, seg[3]);
  }

  // PATCH /defect-tickets/:id/begin-verification —— 拍板项 4 的手动触发点
  if (method === 'PATCH' && seg.length === 3 && seg[2] === 'begin-verification') {
    return beginVerification(ctx, id);
  }

  // POST /defect-tickets/:id/verifications —— V1/V2/V3 提交
  if (method === 'POST' && seg.length === 3 && seg[2] === 'verifications') {
    return submitVerification(ctx, id);
  }

  // PATCH /defect-tickets/:id/reanalyze —— REOPENED → ANALYZED（round+1）
  if (method === 'PATCH' && seg.length === 3 && seg[2] === 'reanalyze') {
    return reanalyze(ctx, id);
  }

  // POST /defect-tickets/:id/close —— 显式关单入口（不变量：只有 V3 pass 能到 CLOSED）
  // 保留为「非法迁移 400」的守卫：仓储层 update 拒绝 status，所以这里直接抛。
  if (method === 'POST' && seg.length === 3 && seg[2] === 'close') {
    return (async () => {
      const { repos, read } = resolve(ctx);
      const cur = await read((c) => repos.defectTickets.getById(c, id));
      const err = new Error(`ILLEGAL_DEFECT_TRANSITION: ${cur.status} -> CLOSED`);
      err.code = 'ILLEGAL_DEFECT_TRANSITION';
      err.statusCode = 400;
      err.body = { error: 'ILLEGAL_DEFECT_TRANSITION' };
      throw err;
    })();
  }

  // DELETE /defect-tickets/:id —— 软删
  if (method === 'DELETE' && seg.length === 2) {
    return deleteTicket(ctx, id);
  }

  // PATCH /defect-tickets/:id —— 通用字段更新
  if (method === 'PATCH' && seg.length === 2) {
    return patchTicket(ctx, id);
  }

  // GET /defect-tickets/:id
  if (method === 'GET' && seg.length === 2) {
    return getTicket(ctx, id);
  }

  return null;
}

export { toHttpError };
