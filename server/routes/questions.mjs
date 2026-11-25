// server/routes/questions.mjs
// 题路 TillRoad · m17431：题库列表读取端点（纯读）
//
// 端点：
//   GET    /questions?subject_id=&knowledge_node_id=&q=&limit=&offset=   题库列表
//   GET    /questions/:id                单题详情（编辑页回填用）
//   POST   /questions                    手动建题（m23700 FE-02）
//   PATCH  /questions/:id                编辑（base_version 必填，m23700）
//   DELETE /questions/:id                软删（base_version 必填，m23700）
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
import { withTransaction } from '../repositories/base.mjs';
import { ok, fail, pagination, readBaseVersion } from './_http.mjs';

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
  // m21780：题干关键字。空串/纯空白当作没传，避免 `ILIKE '%%'` 白白走一次模糊匹配。
  const rawQ = ctx.searchParams.get('q');
  const q = rawQ && rawQ.trim().length > 0 ? rawQ.trim() : null;

  // limit/offset 复用 pagination（字符串→数字），非法值由仓储层 pageParams 兜底。
  const page = pagination(ctx.searchParams);

  const { repo, client } = resolve(ctx);
  const rows = await repo.listVisible(client, {
    limit: page.limit,
    offset: page.offset,
    ownerUserId: ctx.authUserId ?? null,
    subjectId: subjectId || null,
    knowledgeNodeId: knowledgeNodeId || null,
    q,
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

/**
 * m23700（FE-02）：手动建题允许的题型。
 *
 * schema 上 questions.type 是**无约束的 text**（注释列了 choice/fill/short_answer/essay/material），
 * 而前端题库页的题型徽标还认识 multi/judge/calculation/subjective 这几个历史值。
 * 两边取并集：太窄会把库里已有的题判成非法，太宽等于没校验。
 * 新增题型时只改这一处。
 */
const QUESTION_TYPES = Object.freeze([
  'choice',
  'multi',
  'judge',
  'fill',
  'calculation',
  'short_answer',
  'subjective',
  'essay',
  'material',
]);

const DIFFICULTIES = Object.freeze(['easy', 'medium', 'hard']);

/** 400 的请求体校验失败（走 httpError 第①分支，原样透出 message）。 */
function badRequest(code, message) {
  const err = new Error(message);
  err.code = code;
  err.statusCode = 400;
  err.body = { error: code, message };
  return err;
}

/** 可空的 uuid 字段：空串/null/undefined 归一成 null，其余交给 PG 的 22P02 拒绝。 */
function optionalId(value) {
  if (value === undefined || value === null) return null;
  const s = String(value).trim();
  return s === '' ? null : s;
}

/** 可空文本：空串归一成 null（避免入库一堆''）。 */
function optionalText(value) {
  if (value === undefined || value === null) return null;
  const s = String(value).trim();
  return s === '' ? null : s;
}

/**
 * options 归一：接受 [{key,text}] 或 ['A. xx','B. yy'] 两种前端写法。
 *
 * 统一成 schema 的 [{key,text}] —— 否则同一道题从导入和手动录入进去形状不一，
 * 公式/答案的解析都要写两套。空数组归一成 null（无选项的题，如填空/主观题）。
 */
function normalizeOptions(value) {
  if (value === undefined || value === null) return null;
  if (!Array.isArray(value)) {
    throw badRequest('INVALID_OPTIONS', 'options 必须是数组（[{key,text}] 或 ["A. xx"]）');
  }
  const out = [];
  value.forEach((raw, index) => {
    if (raw === null || raw === undefined) return;
    if (typeof raw === 'string') {
      const text = raw.trim();
      if (text === '') return;
      // 'A. 选项文本' / 'A、选项文本' / 'A 选项文本' 都取首字母当 key
      const m = /^([A-Za-z])\s*[.、．:：)]?\s*(.*)$/.exec(text);
      const key = m ? m[1].toUpperCase() : String.fromCharCode(65 + index);
      out.push({ key, text: m ? m[2] : text });
      return;
    }
    if (typeof raw === 'object') {
      const key = optionalText(raw.key) ?? String.fromCharCode(65 + index);
      const text = optionalText(raw.text ?? raw.content ?? raw.label);
      if (text === null) return;
      out.push({ key: key.toUpperCase(), text });
    }
  });
  return out.length > 0 ? out : null;
}

/**
 * 挑出可手动录入的列并做值域校验。
 *
 * partial=true 时只处理请求体里出现过的键（PATCH 语义）——
 * 与 subjects 路由的 pickSubjectFields 同形，避免「没传的字段被写成 null」。
 *
 * 刻意**不收** source / content_hash / owner_user_id：
 *   * source：手动建题恒为 manual（导入走 /questions/import，AI 生成走 BE-10）；
 *   * content_hash：仓储层 create/update 内部按归一化文本自己算，客户端传了也会被覆盖；
 *   * owner_user_id：归属只认 token（ctx.authUserId），否则就能伪造公共题或认领别人的题。
 */
function pickQuestionFields(body, { partial = false } = {}) {
  const out = {};
  const has = (k) => Object.prototype.hasOwnProperty.call(body, k);

  const touch = (k) => !partial || has(k);

  if (touch('subject_id')) out.subject_id = optionalId(body.subject_id);
  if (touch('knowledge_node_id')) out.knowledge_node_id = optionalId(body.knowledge_node_id);

  if (touch('type')) {
    const type = optionalText(body.type);
    if (type === null) {
      if (!partial) throw badRequest('MISSING_QUESTION_TYPE', 'type 必填（可选值：' + QUESTION_TYPES.join('/') + '）');
    } else if (!QUESTION_TYPES.includes(type)) {
      throw badRequest('INVALID_QUESTION_TYPE', `type 不支持：${type}（可选值：${QUESTION_TYPES.join('/')}）`);
    } else {
      out.type = type;
    }
  }

  if (touch('stem')) {
    const stem = optionalText(body.stem);
    if (stem === null) {
      if (!partial) throw badRequest('MISSING_QUESTION_STEM', '题干不能为空');
    } else {
      out.stem = stem;
    }
  }

  if (has('options')) out.options = normalizeOptions(body.options);
  if (has('answer')) out.answer = optionalText(body.answer);
  if (has('analysis')) out.analysis = optionalText(body.analysis);
  if (has('formula_text')) out.formula_text = optionalText(body.formula_text);

  if (has('difficulty')) {
    const difficulty = optionalText(body.difficulty);
    if (difficulty !== null && !DIFFICULTIES.includes(difficulty)) {
      throw badRequest('INVALID_DIFFICULTY', `difficulty 不支持：${difficulty}（可选值：${DIFFICULTIES.join('/')}）`);
    }
    out.difficulty = difficulty;
  }

  if (has('tags')) {
    const tags = body.tags;
    if (tags === null) {
      out.tags = null;
    } else if (!Array.isArray(tags)) {
      throw badRequest('INVALID_TAGS', 'tags 必须是字符串数组');
    } else {
      const cleaned = tags.map((t) => optionalText(t)).filter((t) => t !== null);
      out.tags = cleaned.length > 0 ? cleaned : null;
    }
  }

  if (has('is_subjective')) {
    const v = body.is_subjective;
    if (typeof v !== 'boolean') {
      throw badRequest('INVALID_IS_SUBJECTIVE', 'is_subjective 必须是布尔值');
    }
    out.is_subjective = v;
  }

  return out;
}

/**
 * 写操作的归属门禁（m23700）。
 *
 * 规则：只能改/删**自己**的题。公共题（owner_user_id IS NULL）与别人的题一律 404，
 * 不用 403 —— 403 等于告诉对方「这个 id 存在，只是不是你的」，可以拿来枚举题库。
 *
 * 未鉴权直接 401：本轮的写端点不开放匿名建题（否则任何人可往公共题库塞题）。
 */
async function requireOwnQuestion(ctx, id) {
  if (!ctx.authUserId) {
    const err = new Error('建题/改题/删除需要有效的 Bearer Token');
    err.code = 'UNAUTHORIZED';
    err.statusCode = 401;
    err.body = { error: 'unauthorized', message: err.message };
    throw err;
  }
  const row = await qRepo.getById(ctx.pool, id);
  if (row.owner_user_id !== ctx.authUserId) {
    const err = new Error('找不到该题目');
    err.code = 'not_found';
    err.statusCode = 404;
    err.body = { error: 'not_found', resource: 'questions', id };
    throw err;
  }
  return row;
}

/** 建/改/删后返回给客户端的题（含 answer/analysis —— 调用方就是出题人）。 */
function questionPayload(r) {
  return {
    id: r.id,
    source: r.source,
    subject_id: r.subject_id,
    knowledge_node_id: r.knowledge_node_id,
    type: r.type,
    stem: r.stem,
    options: r.options ?? null,
    answer: r.answer ?? null,
    analysis: r.analysis ?? null,
    formula_text: r.formula_text ?? null,
    difficulty: r.difficulty ?? null,
    tags: r.tags ?? null,
    is_subjective: r.is_subjective ?? false,
    content_hash: r.content_hash,
    owner_user_id: r.owner_user_id ?? null,
    created_at: r.created_at,
    updated_at: r.updated_at,
    version: r.version,
  };
}

/** POST /questions —— 手动建题（m23700 FE-02）。 */
async function createQuestion(ctx) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '建题需要有效的 Bearer Token' });
  }
  const fields = pickQuestionFields(ctx.body ?? {});
  const row = await withTransaction(ctx.pool, (client) => qRepo.create(client, {
    ...fields,
    // 手动录入恒为 manual：photo/import/ai_generated 各有自己的入口，不能靠请求体冒充。
    source: 'manual',
    owner_user_id: ctx.authUserId,
  }));
  return ok(questionPayload(row), 201);
}

/** GET /questions/:id —— 单题详情（编辑页回填；可见性同列表）。 */
async function getQuestion(ctx, id) {
  const row = await qRepo.getById(ctx.pool, id);
  const owner = row.owner_user_id ?? null;
  if (owner !== null && owner !== (ctx.authUserId ?? null)) {
    // 别人的私有题：与「不存在」同样处理，避免枚举。
    return fail('not_found', 404, { resource: 'questions', id });
  }
  return ok(questionPayload(row));
}

/** PATCH /questions/:id —— 编辑（base_version 必填）。 */
async function updateQuestion(ctx, id) {
  await requireOwnQuestion(ctx, id);
  const baseVersion = readBaseVersion(ctx.body ?? {});
  const patch = pickQuestionFields(ctx.body ?? {}, { partial: true });
  if (Object.keys(patch).length === 0) {
    return fail('empty_patch', 400, { message: '没有需要更新的字段' });
  }
  const row = await withTransaction(ctx.pool, (client) => qRepo.update(client, id, patch, baseVersion));
  return ok(questionPayload(row));
}

/** DELETE /questions/:id —— 软删（base_version 必填）。 */
async function deleteQuestion(ctx, id) {
  await requireOwnQuestion(ctx, id);
  const baseVersion = readBaseVersion(ctx.body ?? {});
  const row = await withTransaction(ctx.pool, (client) => qRepo.archive(client, id, baseVersion));
  return ok({ id: row.id, deleted: true, version: row.version });
}

/**
 * 路由分发。
 *
 * ★ m23700：本模块从「纯读」扩到「读 + 写」后，match 不能再一刀切 `if (method !== 'GET') return null`
 * （那样会把自己的 POST/PATCH/DELETE 也挡在外面）。改为按方法 + 路径形态逐个匹配，
 * 不匹配就返回 null 交给下一个模块 —— 与 subjects/questions_import 的写法保持一致。
 */
export async function match(method, seg, ctx) {

  // POST /questions —— 手动建题
  if (method === 'POST' && seg.length === 1 && seg[0] === 'questions') {
    return createQuestion(ctx);
  }

  // /questions（列表）与 /questions/:id（单题）
  if (seg[0] === 'questions' && seg.length === 1 && method === 'GET') {
    return listQuestions(ctx);
  }

  if (seg[0] === 'questions' && seg.length === 2) {
    const id = seg[1];
    if (method === 'GET') return getQuestion(ctx, id);
    if (method === 'PATCH') return updateQuestion(ctx, id);
    if (method === 'DELETE') return deleteQuestion(ctx, id);
    return null;
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
