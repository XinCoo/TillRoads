/**
 * 缺陷单 ↔ 题目 一对多关联（m27163）。
 *
 * 背景：一个缺陷单（错题记录）往往对应**多道**题（同一知识点反复错、同一套卷子里的
 * 同类题）。原先 defect_tickets 只有单个 question_id 字段，表达不了「一单多题」，
 * 所以 0006 迁移新建了 defect_questions 关联表：
 *   defect_questions(id, defect_ticket_id → defect_tickets(id) ON DELETE CASCADE,
 *                     question_id → questions(id), sort int, created_at)
 *   + uk_defect_question(defect_ticket_id, question_id) 唯一索引
 *   + idx_dq_ticket(defect_ticket_id, sort)
 *
 * 路由（本模块）：
 *   POST   /defect-tickets/:id/questions          关联一道题
 *   DELETE /defect-tickets/:id/questions/:qid     解除关联
 *   PUT    /defect-tickets/:id/questions/sort     重排
 *   GET    /defect-tickets/:id/questions          列关联题目（带题干）
 *   GET    /defect-tickets/custom-reasons         当前用户用过的自定义错因（错因下拉框候选）
 *
 * ★ 跨用户口径：本仓库一律回 404（不泄露 id 是否存在）。
 *   注意：server/index.mjs 在 dispatch **之前**还有一层归属检查，
 *   它对 /defect-tickets/:id 形状的路径会先查 owner，不匹配就抛 403 forbidden。
 *   所以本模块内部的 404 语义只在「不经过 index.mjs 归属层」时可见（例如 fake pool 单测）；
 *   真实 HTTP 下跨用户访问会先被 index.mjs 拦成 403（属既有行为，未改）。
 *
 * ★ 匹配顺序：本模块必须排在 routes/defect_tickets.mjs **之前**（ROUTE_MODULES 里），
 *   否则：
 *   1) GET /defect-tickets/custom-reasons 会被 defect_tickets 的「GET /defect-tickets/:id」
 *      抢走 → 把 'custom-reasons' 当 uuid → PG 22P02 → 500 internal；
 *   2) 其余 /defect-tickets/:id/questions… 的 seg.length ≥ 3，与 defect_tickets 的
 *      len3 分支（analyze/actions/verifications…）不重叠，但 :id/questions/sort 是 len4，
 *      同样与 actions/:actionId 不重叠 —— 顺序上仍以「先 defect_questions」为准，最稳。
 */

import * as dtRepo from '../repositories/defect_tickets.mjs';
import * as qRepo from '../repositories/questions.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { ok, fail } from './_http.mjs';

const LINK_ITEM_FIELDS = ['id', 'question_id', 'sort', 'created_at'];

function unauthorized(message) {
  return fail('unauthorized', 401, { message });
}

/** 题干等展示字段（GET /defect-tickets/:id/questions 与详情回带共用）。 */
function toLinkItem(row, { withStem = false } = {}) {
  const item = {
    id: row.id,
    question_id: row.question_id,
    sort: row.sort,
    created_at: row.created_at,
  };
  if (withStem) {
    item.stem = row.stem ?? null;
    item.type = row.type ?? null;
    item.source = row.source ?? null;
    item.difficulty = row.difficulty ?? null;
  }
  return item;
}

/**
 * 取出缺陷单并校验归属：
 *   * 无 token → 401
 *   * 不存在 / 已软删 → 404
 *   * 属于别人 → 404（不泄露 id 是否存在）
 */
async function requireOwnTicket(ctx, id) {
  if (!ctx.authUserId) return { error: unauthorized('操作缺陷单需要有效的 Bearer Token') };
  const ticket = await dtRepo.getById(ctx.pool, id).catch(() => null);
  if (!ticket) return { error: fail('not_found', 404, { message: '缺陷单不存在' }) };
  if (ticket.user_id !== ctx.authUserId) {
    return { error: fail('not_found', 404, { message: '缺陷单不存在' }) };
  }
  return { ticket };
}

/**
 * POST /defect-tickets/:id/questions —— 关联一道题（m27163）。
 *
 * body: { "question_id": "<uuid>" }
 * 201 → { id, question_id, sort, created_at }
 * 400 → INVALID_QUESTION_ID（缺 question_id）
 * 404 → 缺陷单不存在 / 不属于当前用户 / 题目不存在或已软删
 * 409 → duplicate_defect_question（同一题已关联过这单）
 */
async function createLink(ctx, ticketId) {
  const auth = await requireOwnTicket(ctx, ticketId);
  if (auth.error) return auth.error;
  const body = ctx.body ?? {};
  const questionId = typeof body.question_id === 'string' ? body.question_id.trim() : '';
  if (!questionId) {
    return fail('INVALID_QUESTION_ID', 400, { message: 'question_id 必填' });
  }
  // 题目必须存在且未软删（否则 404）
  const question = await qRepo.getById(ctx.pool, questionId).catch(() => null);
  if (!question) {
    return fail('not_found', 404, { message: '题目不存在' });
  }
  try {
    const row = await withTransaction(ctx.pool, async (client) => {
      const existing = await dtRepo.findQuestionLink(client, ticketId, questionId);
      if (existing) {
        const err = new Error('该题目已关联此缺陷单');
        err.statusCode = 409;
        err.body = { error: 'duplicate_defect_question', message: '该题目已关联此缺陷单' };
        throw err;
      }
      const count = await dtRepo.countQuestionLinks(client, ticketId);
      return dtRepo.createQuestionLink(client, {
        defect_ticket_id: ticketId,
        question_id: questionId,
        sort: count + 1,
      });
    });
    return ok(
      {
        id: row.id,
        question_id: row.question_id,
        sort: row.sort,
        created_at: row.created_at,
      },
      201,
    );
  } catch (e) {
    if (e && e.statusCode === 409 && e.body) return { status: 409, body: e.body };
    // 唯一索引兜底（并发下两个请求同时插入）
    if (e && e.code === '23505') {
      return {
        status: 409,
        body: { error: 'duplicate_defect_question', message: '该题目已关联此缺陷单' },
      };
    }
    throw e;
  }
}

/**
 * DELETE /defect-tickets/:id/questions/:questionId —— 解除关联（m27163）。
 *
 * 200 → { removed: true, question_id }
 * 404 → 缺陷单不存在 / 不属于当前用户 / 该关联不存在
 */
async function removeLink(ctx, ticketId, questionId) {
  const auth = await requireOwnTicket(ctx, ticketId);
  if (auth.error) return auth.error;
  const qid = typeof questionId === 'string' ? questionId.trim() : '';
  if (!qid) {
    return fail('INVALID_QUESTION_ID', 400, { message: 'question_id 必填' });
  }
  const removed = await withTransaction(ctx.pool, (client) =>
    dtRepo.deleteQuestionLink(client, ticketId, qid),
  );
  if (!removed) {
    return fail('not_found', 404, { message: '该题目未关联此缺陷单' });
  }
  return ok({ removed: true, question_id: qid });
}

/**
 * PUT /defect-tickets/:id/questions/sort —— 重排（m27163）。
 *
 * body: { "ids": ["q1", "q2", ...] } —— 按目标顺序排列的 question_id 列表
 *   * 允许只传部分 id（只重排传入的那些，sort 取在新列表里的下标 +1）
 * 200 → { "items": [ { "question_id": ..., "sort": ... } ] }
 * 400 → INVALID_SORT_LIST（列表里有不属于该缺陷单的 question_id / id 重复 / 非法）
 */
async function reorderLinks(ctx, ticketId) {
  const auth = await requireOwnTicket(ctx, ticketId);
  if (auth.error) return auth.error;
  const body = ctx.body ?? {};
  if (!Array.isArray(body.ids)) {
    return fail('INVALID_SORT_LIST', 400, { message: 'ids 必须是数组' });
  }
  const ids = body.ids.map((v) => (typeof v === 'string' ? v.trim() : '')).filter((v) => v !== '');
  if (ids.length !== body.ids.length) {
    return fail('INVALID_SORT_LIST', 400, { message: 'ids 必须是字符串数组' });
  }
  if (new Set(ids).size !== ids.length) {
    return fail('INVALID_SORT_LIST', 400, { message: 'ids 不能重复' });
  }
  const items = await withTransaction(ctx.pool, async (client) => {
    const current = await dtRepo.listQuestionLinks(client, ticketId);
    const owned = new Set(current.map((r) => r.question_id));
    for (const id of ids) {
      if (!owned.has(id)) {
        const err = new Error('ids 中包含不属于该缺陷单的题目');
        err.statusCode = 400;
        err.body = { error: 'INVALID_SORT_LIST', message: 'ids 中包含不属于该缺陷单的题目' };
        throw err;
      }
    }
    const rows = await dtRepo.reorderQuestionLinks(client, ticketId, ids);
    return rows.map((r) => ({ question_id: r.question_id, sort: r.sort }));
  }).catch((e) => {
    if (e && e.statusCode === 400 && e.body) return e.body;
    throw e;
  });
  if (items && items.error) {
    return fail(items.error, 400, { message: items.message });
  }
  return ok({ items });
}

/**
 * GET /defect-tickets/:id/questions —— 列该缺陷单关联的题目（m27163）。
 *
 * 200 → { items: [ { id, question_id, sort, stem, type, source, difficulty, created_at } ] }
 *      （stem 返回**完整题干**，前端自己截断做摘要）
 * 404 → 缺陷单不存在 / 不属于当前用户
 */
async function listLinks(ctx, ticketId) {
  const auth = await requireOwnTicket(ctx, ticketId);
  if (auth.error) return auth.error;
  const rows = await dtRepo.listQuestionLinksWithQuestions(ctx.pool, ticketId);
  return ok({ items: rows.map((r) => toLinkItem(r, { withStem: true })) });
}

/**
 * GET /defect-tickets/custom-reasons —— 当前用户用过的自定义错因 + 次数（m27163）。
 *
 * query: exam_profile_id=<uuid>（可选，限定同一考试目标）
 * 200 → { "items": [ { "custom_reason": "计算失误", "count": 3 } ] }
 * 401 → 无 token
 */
async function listCustomReasons(ctx) {
  if (!ctx.authUserId) {
    return unauthorized('查看历史错因需要有效的 Bearer Token');
  }
  const params = ctx.searchParams ?? new URLSearchParams();
  const examProfileId = params.get('exam_profile_id');
  const rows = await dtRepo.listCustomReasons(ctx.pool, ctx.authUserId, {
    examProfileId: examProfileId && examProfileId !== '' ? examProfileId : null,
  });
  return ok({
    items: rows.map((r) => ({ custom_reason: r.custom_reason, count: Number(r.count) })),
  });
}

export async function match(method, seg, ctx) {
  // ★ 必须最先判定：GET /defect-tickets/custom-reasons（seg.length===2）
  //   若落到 defect_tickets 的「GET /defect-tickets/:id」分支，'custom-reasons'
  //   会被当 uuid → PG 22P02 → 500 internal。
  if (method === 'GET' && seg.length === 2 && seg[0] === 'defect-tickets' && seg[1] === 'custom-reasons') {
    return listCustomReasons(ctx);
  }

  if (seg[0] !== 'defect-tickets' || seg.length < 3 || seg[2] !== 'questions') {
    return null;
  }
  const ticketId = seg[1];

  // GET/POST /defect-tickets/:id/questions
  if (seg.length === 3 && method === 'GET') return listLinks(ctx, ticketId);
  if (seg.length === 3 && method === 'POST') return createLink(ctx, ticketId);

  // PUT /defect-tickets/:id/questions/sort（len4，seg[3]==='sort'）
  if (seg.length === 4 && method === 'PUT' && seg[3] === 'sort') {
    return reorderLinks(ctx, ticketId);
  }

  // DELETE /defect-tickets/:id/questions/:questionId（len4）
  if (seg.length === 4 && method === 'DELETE') {
    return removeLink(ctx, ticketId, seg[3]);
  }

  return null;
}

export { LINK_ITEM_FIELDS };
