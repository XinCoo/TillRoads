// server/routes/questions.mjs
// 题路 TillRoad · m17431：题库列表读取端点（纯读）
//
// 端点：
//   GET /questions?subject_id=&knowledge_node_id=&limit=&offset=
//
// 为什么需要它：BE-02 只做了「导入」端点（POST /questions/import），
// 前端从来没有「读题库」的入口 —— 测试人员装完 APK 只能看到预置的 9 条缺陷单，
// 导入自己的题目后也无处查看。本端点补上读取侧。
//
// ★ m17431 的可见性口径：
//   可见集合 = 公共题（owner_user_id IS NULL）+ 当前 token 用户自己的题。
//   别人的私有题一律不可见。归属只认 token 映射出来的 userId（ctx.authUserId），
//   不信任请求体 / query 里的 user_id。
//
// 列表不含 answer / analysis：题库列表只是「看看有哪些题」，
// 答案与解析在真正做这题时才需要（避免在列表页泄露答案）。

import * as qRepo from '../repositories/questions.mjs';
import { ok, fail, pagination } from './_http.mjs';

/** 依赖注入缝：与其它路由同形（ctx.repos 可注入 fake）。 */
function resolve(ctx) {
  if (ctx.repos && ctx.repos.questions) {
    return { repo: ctx.repos.questions, client: ctx.repos.client ?? null };
  }
  return { repo: qRepo, client: ctx.pool };
}

/** 题库列表。 */
async function listQuestions(ctx) {
  const subjectId = ctx.searchParams.get('subject_id');
  const knowledgeNodeId = ctx.searchParams.get('knowledge_node_id');

  // limit/offset 复用 pagination（字符串→数字），非法值由仓储层 pageParams 兜底。
  const page = pagination(ctx.searchParams);

  const { repo, client } = resolve(ctx);
  const rows = await repo.listVisible(client, {
    limit: page.limit,
    offset: page.offset,
    ownerUserId: ctx.authUserId ?? null,
    subjectId: subjectId || null,
  });

  const items = rows.map((r) => ({
    id: r.id,
    source: r.source,
    subject_id: r.subject_id,
    knowledge_node_id: r.knowledge_node_id,
    type: r.type,
    stem: r.stem,
    options: r.options ?? null,
    difficulty: r.difficulty ?? null,
    tags: r.tags ?? null,
    is_subjective: r.is_subjective ?? false,
    content_hash: r.content_hash,
    // 归属：null = 公共题。前端可以用它给「我导入的题」加个小标记。
    owner_user_id: r.owner_user_id ?? null,
    created_at: r.created_at,
    updated_at: r.updated_at,
    version: r.version,
  }));

  return ok({
    items,
    total: items.length,
    limit: page.limit,
    offset: page.offset,
  });
}

/** GET /questions */
export async function match(method, seg, ctx) {
  if (method !== 'GET') return null;

  // /questions
  if (seg.length === 1 && seg[0] === 'questions') {
    return listQuestions(ctx);
  }

  // /subjects/:id/questions —— 题库按科目分组时前端可能按科目拉。
  if (seg.length === 3 && seg[0] === 'subjects' && seg[2] === 'questions') {
    const page = pagination(ctx.searchParams);
    const { repo, client } = resolve(ctx);
    const rows = await repo.listVisible(client, {
      limit: page.limit,
      offset: page.offset,
      ownerUserId: ctx.authUserId ?? null,
      subjectId: seg[1],
    });
    return ok({
      items: rows.map((r) => ({
        id: r.id,
        source: r.source,
        subject_id: r.subject_id,
        knowledge_node_id: r.knowledge_node_id,
        type: r.type,
        stem: r.stem,
        options: r.options ?? null,
        difficulty: r.difficulty ?? null,
        tags: r.tags ?? null,
        is_subjective: r.is_subjective ?? false,
        owner_user_id: r.owner_user_id ?? null,
        created_at: r.created_at,
        updated_at: r.updated_at,
        version: r.version,
      })),
      total: rows.length,
      limit: page.limit,
      offset: page.offset,
    });
  }

  return null;
}
