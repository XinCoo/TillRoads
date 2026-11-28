// server/routes/import_batches.mjs
// 题路 TillRoad · m31124：导入批次列表（GET /import-batches）
//
// 背景：用户反馈「导入多次后题库很乱，不知道哪些题是哪次导的」。
// 本模块只提供**只读**的批次列表；整批删除走 questions 模块的
// DELETE /questions/batch { batch_id }（那里已经有 owner 过滤与事务）。
//
// 端点：GET /import-batches
//   query: limit / offset（分页，默认 100，上限 500）
//   res  : { items: [ { id, user_id, filename, question_count, created_at } ], total, limit, offset }
//
// 为什么 user_id 从 token 来而不是从 query 来：
//   server/index.mjs 若有 authUserId，会把 `/users/<段>` 改写成 authUserId 并
//   `searchParams.set('user_id', authUserId)`，也就是说 query 里的 user_id
//   在鉴权模式下**本来就已被覆盖**。为了不依赖那条改写规则，这里直接认
//   ctx.authUserId —— 没 token 就 401，绝不回退到「列出所有人的批次」。
//
// 为什么不返回 deleted_at / version：
//   import_batches 是账本，没有软删（删批次不删账本行，题被软删后
//   question_count 仍是当初导入的条数）。前端只需要「哪个文件、多少题、什么时候」。

import * as rep from '../repositories/import_batches.mjs';
import { fail, ok, pagination } from './_http.mjs';

export async function match(method, seg, ctx) {
  if (method !== 'GET' || seg.length !== 1 || seg[0] !== 'import-batches') {
    return null;
  }
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '查看导入批次需要有效的 Bearer Token' });
  }

  const params = ctx.searchParams ?? new URLSearchParams();
  const page = pagination(params);
  const rows = await rep.listByUser(ctx.pool, ctx.authUserId, {
    limit: page.limit,
    offset: page.offset,
  });

  // 只挑前端要用的四列 + id，不把 user_id 之外的内部字段漏出去。
  const items = rows.map((r) => ({
    id: r.id,
    filename: r.filename,
    question_count: r.question_count,
    created_at: r.created_at,
  }));

  return ok({
    items,
    total: items.length,
    limit: page.limit ?? null,
    offset: page.offset ?? 0,
  });
}
