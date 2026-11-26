/**
 * GET /question-types —— 已导入题目中出现的「题型词表」（m27163）。
 *
 * 语义：前端题库管理页/录入页需要一个**题型下拉框**，选项不应该写死在前端，
 * 而应该来自库里真实出现过的题型（外加每种题型有多少道题）。
 *
 * 口径（与 scope 参数）：
 *   * imported（默认）：只统计 source='import' 的题（导入题库里的题型）
 *   * other            ：只统计 source<>'import' 的题（手动录入 / 拍照 / AI 生成）
 *   * all              ：全部来源
 * 软删的题不计入。题型是**全局词表**，所以不按 owner_user_id 过滤。
 *
 * query:
 *   * scope=imported|other|all
 *   * q=<关键词>  —— 对 type 做 ILIKE 模糊匹配（% / _ 会被转义）
 *
 * 响应：
 *   { "items": [ { "type": "choice", "count": 38 } ], "total": 2, "scope": "imported" }
 */

import * as qRepo from '../repositories/questions.mjs';
import { ok, fail, pagination } from './_http.mjs';

const VALID_SCOPES = new Set(['imported', 'other', 'all']);

export async function match(method, seg, ctx) {
  if (method !== 'GET' || seg.length !== 1 || seg[0] !== 'question-types') {
    return null;
  }
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '查看题型需要有效的 Bearer Token' });
  }
  const params = ctx.searchParams ?? new URLSearchParams();
  const rawScope = params.get('scope');
  const scope = rawScope === null || rawScope === '' ? 'imported' : String(rawScope).trim();
  if (!VALID_SCOPES.has(scope)) {
    return fail('INVALID_SCOPE', 400, { message: "scope 只能是 'imported'、'other' 或 'all'" });
  }
  const q = params.get('q');
  const { limit } = pagination(params);
  const items = await qRepo.listTypesBySource(ctx.pool, {
    scope,
    q: q === null || q === '' ? null : q,
    limit,
  });
  return ok({ items, total: items.length, scope });
}
