// server/routes/questions.mjs
// 题路 TillRoad · m17431：题库列表读取端点（纯读）
//
// 端点：
//   GET    /questions?subject_id=&knowledge_node_id=&q=&mastered=&limit=&offset=   题库列表
//   GET    /questions/:id                单题详情（编辑页回填用）
//   POST   /questions                    手动建题（m23700 FE-02）
//   PATCH  /questions/:id                编辑（base_version 必填，m23700）
//   DELETE /questions/:id                软删（base_version 必填，m23700）
//   PATCH  /questions/:id/mastery        标记掌握度（m25316 练习模式 R2）
//   PATCH  /questions/:id/restore        恢复软删的题（m26090 练习模式 R3）
//   PATCH  /questions/:id/hide           隐藏/取消隐藏公共题（m26090）
//   DELETE /questions/batch              批量软删（m26090）
//   PATCH  /questions/batch/restore      批量恢复（m26090）
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
import * as masteryRepo from '../repositories/question_mastery.mjs';
import * as hiddenRepo from '../repositories/question_hidden.mjs';
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

  // m25316：掌握状态筛选。'true'/'false' 才是有效值；其它值（如 '1'、'yes'、空串）一律当作没传。
  const rawMastered = ctx.searchParams.get('mastered');
  const mastered = rawMastered === 'true' ? true : rawMastered === 'false' ? false : undefined;
  // m31124：按导入批次筛选。题库管理页选中某个批次时传 batch_id。
  //   空串/纯空白当作没传（「全部批次」走这条）。
  const rawBatchId = ctx.searchParams.get('batch_id');
  const batchId = rawBatchId && rawBatchId.trim().length > 0 ? rawBatchId.trim() : null;
  // ★ m31635：题型多选。`type=choice,multi` → ['choice','multi']。
  //   每个值都按 QUESTION_TYPES 校验：合法值保留，非法值直接忽略（不报 400）——
  //   报错会让旧客户端的脏参数把整页打成错误页，而忽略一个脏值退化成“少一个筛选维度”，
  //   用户能立刻看出列表没按预期缩窄。
  //   去空白 + 去重 + 保序（顺序不影响 SQL，但便于日志复现）。
  const types = parseTypeFilter(ctx.searchParams.get('type'));
  // ★ m31635：掌握状态三态。只有 mastered / unmastered / unmarked 有效，
  //   其余（含旧参数 mastered 的 true/false）一律不传 —— 旧参数由下方的
  //   mastered 布尔值单独兼容，路由层不做两者互转。
  const mastery = parseMasteryFilter(ctx.searchParams.get('mastery'));

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
    mastered,
    masteryState: mastery,
    types,
    batchId,
  });

  // m25316：题库列表带掌握度。批量查一次本批题的掌握度 Map（题库页要挂徽标）。
  // 「没有标记记录」不在 Map 里 → 前端显示灰色「未标记」。
  // client 为 null 说明走的是 fake 仓储注入（单元测试），此时没有真实表可查，跳过。
  const masteryMap = client
    ? await masteryRepo.listMasteryMap(client, {
        userId: ctx.authUserId ?? null,
        questionIds: rows.map((r) => r.id),
      })
    : new Map();

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
    // m25316：掌握度三态：true=已掌握 / false=未掌握 / null=未标记。
    mastered: masteryMap.has(r.id) ? masteryMap.get(r.id) : null,

  }));

  return ok({
    items,
    total: items.length,
    limit: page.limit,
    offset: page.offset,
  });
}

/**
 * ★ m31635：解析 `type=choice,multi` 这种逗号分隔的题型参数。
 *
 * 返回合法题型数组；没传 / 全是非法值时返回空数组（= 不加条件）。
 * 非法值静默忽略而不报 400：筛选器是「多选叠加」的辅助维度，
 * 一个脏值不应该把整页打成错误页。
 */
function parseTypeFilter(raw) {
  if (!raw || typeof raw !== 'string') return [];
  const out = [];
  for (const piece of raw.split(',')) {
    const value = piece.trim();
    if (!value) continue;
    if (!QUESTION_TYPES.includes(value)) continue;
    if (out.includes(value)) continue;
    out.push(value);
  }
  return out;
}

/**
 * ★ m31635：解析三态掌握度 `mastery=mastered|unmastered|unmarked`。
 *
 * 返回三态字符串；其它值（含旧参数 `mastered=true`）返回 undefined = 不筛。
 * 与旧参数 [mastered] 各走各的：路由层不把 `mastery=mastered` 翻译成
 * `mastered=true`，因为两者语义不同（`mastered=true` 不含 unmarked）。
 */
function parseMasteryFilter(raw) {
  if (!raw || typeof raw !== 'string') return undefined;
  const value = raw.trim();
  if (value === 'mastered' || value === 'unmastered' || value === 'unmarked') return value;
  return undefined;
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
 * tags 归一（m27163）：请求里的 tags → 「非空字符串数组 或 null」。
 *
 * 单题编辑（PATCH /questions/:id）与批量编辑（PATCH /questions/batch/tags）
 * 共用这一份语义，避免两处实现漂移（口径不同会让前端踩坑）。
 *   * null      → null（清空标签）
 *   * 非数组    → 400 INVALID_TAGS
 *   * 数组      → 去空白、剔空串；剔完为空 → null（等价于清空）
 */
function normalizeTags(value) {
  if (value === null) return null;
  if (!Array.isArray(value)) {
    throw badRequest('INVALID_TAGS', 'tags 必须是字符串数组');
  }
  const cleaned = value.map((t) => optionalText(t)).filter((t) => t !== null);
  return cleaned.length > 0 ? cleaned : null;
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
    out.tags = normalizeTags(body.tags);
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
 * 写操作的归属门禁（m23700，m26090 扩展）。
 *
 * 规则：只能改/删**自己**的题。
 *
 * ★ m26090（R3）：公共题（owner_user_id IS NULL）有两种处理，由调用方显式指定：
 *   * publicError='not_found'（默认，改题 / 编辑等）：公共题 → 404。
 *     公共题不属于任何人，改它没有意义；回 404 与「不存在」一致，不泄露存在性。
 *   * publicError='forbidden'（删除）：公共题 → **403 FORBIDDEN_DELETE**。
 *     软删是把题从**整个公共题库**里拿走，别人也看不到了，公共题不属于
 *     任何用户，用户无权这么做。403 是必要的语义 —— 前端要明确告诉用户
 *     「你不能删这道题，只能隐藏」，而不是含糊的「找不到」。
 *   * 别人的私有题 → 404 not_found（不可见，回 404 避免枚举题库 id）。
 *   * 隐藏（PATCH /questions/:id/hide）不走这个门禁，它自己判断：
 *     公共题与自己的题都可隐藏。
 *
 * 未鉴权直接 401：本轮的写端点不开放匿名建题（否则任何人可往公共题库塞题）。
 */
async function requireOwnQuestion(ctx, id, { publicError = 'not_found' } = {}) {
  if (!ctx.authUserId) {
    const err = new Error('建题/改题/删除需要有效的 Bearer Token');
    err.code = 'UNAUTHORIZED';
    err.statusCode = 401;
    err.body = { error: 'unauthorized', message: err.message };
    throw err;
  }
  const row = await qRepo.getById(ctx.pool, id);
  if (row.owner_user_id === ctx.authUserId) {
    return row;
  }
  // 公共题：归属为空。
  if (row.owner_user_id === null) {
    if (publicError === 'forbidden') {
      const err = new Error('公共题不能删除，只能隐藏');
      err.code = 'FORBIDDEN_DELETE';
      err.statusCode = 403;
      err.body = { error: 'FORBIDDEN_DELETE', message: err.message, id };
      throw err;
    }
    const err = new Error('找不到该题目');
    err.code = 'not_found';
    err.statusCode = 404;
    err.body = { error: 'not_found', resource: 'questions', id };
    throw err;
  }
  // 别人的私有题：不可见 → 404（避免枚举）。
  const err = new Error('找不到该题目');
  err.code = 'not_found';
  err.statusCode = 404;
  err.body = { error: 'not_found', resource: 'questions', id };
  throw err;
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

/**
 * DELETE /questions/:id —— 软删（base_version 必填）。
 *
 * ★ m26090（R3）：公共题（owner_user_id IS NULL）不能软删 → 403 FORBIDDEN_DELETE。
 *   理由：软删是把题从**整个公共题库**里拿走，别人也看不到了。
 *   公共题不属于任何用户，用户无权这么做。公共题想「不想再看到」请用隐藏
 *   （PATCH /questions/:id/hide）。
 *   注意与「删别人的私有题 → 404」的区别：公共题对所有人可见，所以回 403
 *   不泄露任何存在性；而别人的私有题不可见，回 404 避免枚举。
 */
async function deleteQuestion(ctx, id) {
  const row = await requireOwnQuestion(ctx, id, { publicError: 'forbidden' });
  const baseVersion = readBaseVersion(ctx.body ?? {});
  const archived = await withTransaction(ctx.pool, (client) => qRepo.archive(client, id, baseVersion));
  return ok({ id: archived.id, deleted: true, version: archived.version });
}

/**
 * PATCH /questions/:id/mastery —— 标记题目的掌握状态（m25316 练习模式 R2）。
 *
 * 规则：
 *   * 只能标记**自己**的题。公共题（owner_user_id IS NULL）与别人的题一律 403，
 *     与 requireOwnQuestion（编辑/删除用 404）刻意不同：
 *     这里的前端要明确告诉用户「公共题不能标记」，403 是必要的语义；
 *     而编辑/删除的 404 是为了避免枚举题库 id（存在性泄露）。
 *   * body 形如 { "mastered": true }；缺字段或不是布尔 → 400。
 *   * 幂等 upsert：同一对 (user_id, question_id) 永远只有一行。
 */
async function setQuestionMastery(ctx, id) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '标记掌握度需要有效的 Bearer Token' });
  }
  const body = ctx.body ?? {};
  if (typeof body.mastered !== 'boolean') {
    return fail('INVALID_MASTERY', 400, { message: 'mastered 必须是布尔值（true / false）' });
  }
  const { repo, client } = resolve(ctx);
  const mastery = (ctx.repos && ctx.repos.questionMastery) ? ctx.repos.questionMastery : masteryRepo;
  const row = await repo.getById(client, id);
  if (!row) {
    return fail('not_found', 404, { resource: 'questions', id });
  }
  if (row.owner_user_id !== ctx.authUserId) {
    // 公共题与别人的题都不允许标记（公共题不是自己的，标记会污染他人内容）。
    return fail('FORBIDDEN_MASTERY', 403, {
      message: '只能标记自己导入或自己创建的题目',
    });
  }
  // 单条 upsert，只需要一条语句 —— 不必开事务（也不必担心 client 为 null 的 fake 注入）。
  const saved = await mastery.upsertMastery(client, {
    userId: ctx.authUserId,
    questionId: id,
    mastered: body.mastered,
  });
  return ok({
    question_id: id,
    mastered: Boolean(saved.mastered),
    updated_at: saved.updated_at,
  });
}
/**
 * PATCH /questions/:id/restore —— 恢复软删的题（m26090 练习模式 R3）。
 *
 * 规则：只能恢复**自己**的题（公共题从来不会被软删，所以不涉及）。
 * 恢复后 version 由 set_updated() 触发器 +1，客户端拿到的 version 一定是最新的。
 *
 * 刻意**不带 base_version**：恢复的语义是「把它搬回来」，不是「基于某个版本改内容」。
 * 如果带了基线号，用户在管理页停留期间别人改了这道题，恢复就会失败 ——
 * 但恢复本身并不冲突（它只是把墓碑清掉），失败反而让人困惑。
 */
async function restoreQuestion(ctx, id) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '恢复题目需要有效的 Bearer Token' });
  }
  // ★ m26090：恢复时必须读得到**软删行**（墓碑）——
  //   getById 把软删行当不存在，所以这里用 getByIdIncludingDeleted，
  //   否则恢复永远在这一步就 404。
  const row = await qRepo.getByIdIncludingDeleted(ctx.pool, id);
  if (!row) {
    return fail('not_found', 404, { resource: 'questions', id });
  }
  if (row.owner_user_id !== ctx.authUserId) {
    return fail('not_found', 404, { resource: 'questions', id });
  }
  const restored = await withTransaction(ctx.pool, (client) => qRepo.restore(client, id));
  if (!restored) {
    // 行存在但没被软删 → 已经是不用恢复的状态（幂等）。
    return fail('not_deleted', 400, { message: '这道题没有被删除，无需恢复' });
  }
  return ok({ id: restored.id, deleted: false, version: restored.version });
}

/**
 * PATCH /questions/:id/hide —— 隐藏 / 取消隐藏题目（m26090 练习模式 R3）。
 *
 * 规则：
 *   * body 形如 { "hidden": true }；缺字段或不是布尔 → 400 INVALID_HIDDEN。
 *   * 自己的题：既可以隐藏也可以取消隐藏（隐藏自己的题等价于「从列表里收起」，
 *     但不动 deleted_at —— 自己的题想真移除请用删除）。
 *   * 公共题：只能隐藏，不能软删（见 deleteQuestion 的 403 FORBIDDEN_DELETE）。
 *   * 别人的私有题 → 404（不可见，避免枚举）。
 */
async function setQuestionHidden(ctx, id) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '隐藏题目需要有效的 Bearer Token' });
  }
  const body = ctx.body ?? {};
  if (typeof body.hidden !== 'boolean') {
    return fail('INVALID_HIDDEN', 400, { message: 'hidden 必须是布尔值（true / false）' });
  }
  const row = await qRepo.getById(ctx.pool, id);
  if (!row) {
    return fail('not_found', 404, { resource: 'questions', id });
  }
  if (row.owner_user_id !== null && row.owner_user_id !== ctx.authUserId) {
    return fail('not_found', 404, { resource: 'questions', id });
  }
  if (body.hidden) {
    await withTransaction(ctx.pool, (client) =>
      hiddenRepo.hideQuestion(client, { userId: ctx.authUserId, questionId: id }),
    );
  } else {
    await withTransaction(ctx.pool, (client) =>
      hiddenRepo.unhideQuestion(client, { userId: ctx.authUserId, questionId: id }),
    );
  }
  return ok({ question_id: id, hidden: body.hidden });
}

/**
 * DELETE /questions/batch —— 批量软删（m26090 练习模式 R3 / m31124 批次删除）。
 *
 * 两种 body 二选一（严格先看 batch_id，再看 ids）：
 *   * { "batch_id": "uuid" }   —— 删整个导入批次（m31124）
 *   * { "ids": ["uuid", ...] }  —— 按 id 列表删（原有行为）
 *
 * 规则：
 *   * 只能删**自己的**题；公共题与别人的题在 SQL 层就被 owner_user_id 条件排除了，
 *     所以它们会被静默跳过（响应里的 skipped 计）。
 *   * 不带 version（批量操作不做乐观锁，与单题删除的口径不同是刻意的）。
 *   * 两条路径都是软删（deleted_at），「已删除」档仍可恢复。
 */
async function deleteQuestionsBatch(ctx) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '批量删除需要有效的 Bearer Token' });
  }
  const body = ctx.body ?? {};

  // ★ m31124：按批次删 —— 前端只持有 batch_id，不该先拉整批再回传一堆 id。
  const rawBatchId = body.batch_id;
  if (rawBatchId !== undefined && rawBatchId !== null && rawBatchId !== '') {
    if (typeof rawBatchId !== 'string') {
      return fail('INVALID_BATCH_ID', 400, { message: 'batch_id 必须是字符串' });
    }
    const batchId = rawBatchId.trim();
    if (batchId.length === 0) {
      return fail('INVALID_BATCH_ID', 400, { message: 'batch_id 不能为空' });
    }
    // requested 取「该批次当前未删条数」，前端拿它算 skipped 才有意义。
    const requested = await withTransaction(ctx.pool, (client) =>
      qRepo.countByBatch(client, batchId, ctx.authUserId),
    );
    const deleted = await withTransaction(ctx.pool, (client) =>
      qRepo.archiveByBatch(client, batchId, ctx.authUserId),
    );
    return ok({ deleted, batch_id: batchId, requested, skipped: Math.max(0, requested - deleted) });
  }
  const ids = Array.isArray(body.ids) ? body.ids.filter((v) => typeof v === 'string' && v !== '') : [];
  if (ids.length === 0) {
    return fail('EMPTY_IDS', 400, { message: 'ids 不能为空' });
  }
  const deleted = await withTransaction(ctx.pool, (client) =>
    qRepo.archiveBatch(client, ids, ctx.authUserId),
  );
  return ok({ deleted, requested: ids.length, skipped: ids.length - deleted });
}

/**
 * PATCH /questions/batch/restore —— 批量恢复（m26090 练习模式 R3）。
 *
 * body: { "ids": ["uuid", ...] }
 */
async function restoreQuestionsBatch(ctx) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '批量恢复需要有效的 Bearer Token' });
  }
  const body = ctx.body ?? {};
  const ids = Array.isArray(body.ids) ? body.ids.filter((v) => typeof v === 'string' && v !== '') : [];
  if (ids.length === 0) {
    return fail('EMPTY_IDS', 400, { message: 'ids 不能为空' });
  }
  const restored = await withTransaction(ctx.pool, (client) =>
    qRepo.restoreBatch(client, ids, ctx.authUserId),
  );
  return ok({ restored, requested: ids.length, skipped: ids.length - restored });
}

/**
 * PATCH /questions/batch/tags —— 批量编辑标签（m27163）。
 *
 * body: { "ids": ["uuid", ...], "tags": ["考点A","考点B"], "mode": "replace" | "add" }
 *   * mode 缺省 replace（整组覆盖）；add = 与现有标签求并集。
 *   * tags 空数组在 replace 下合法（= 清空标签）；在 add 下无意义 → 400 INVALID_TAGS。
 *
 * 只改自己的题（owner_user_id = $2）：公共题与别人的题被静默跳过，
 * 体现在响应里的 skipped 计数（与 deleteQuestionsBatch 同口径）。
 */
async function updateQuestionsTagsBatch(ctx) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '批量编辑标签需要有效的 Bearer Token' });
  }
  const body = ctx.body ?? {};
  const ids = Array.isArray(body.ids)
    ? body.ids.map((v) => optionalId(v)).filter((v) => v !== null)
    : [];
  if (ids.length === 0) {
    return fail('EMPTY_IDS', 400, { message: 'ids 不能为空' });
  }
  const mode = body.mode === undefined || body.mode === null ? 'replace' : body.mode;
  if (mode !== 'replace' && mode !== 'add') {
    return fail('INVALID_TAGS_MODE', 400, { message: "mode 只能是 'replace' 或 'add'" });
  }
  if (!Array.isArray(body.tags)) {
    return fail('INVALID_TAGS', 400, { message: 'tags 必须是字符串数组' });
  }
  // 与单题编辑共用同一份归一语义（normalizeTags）
  const tags = normalizeTags(body.tags);
  if (mode === 'add' && (tags === null || tags.length === 0)) {
    return fail('INVALID_TAGS', 400, { message: "mode='add' 时 tags 不能为空" });
  }
  const updated = await withTransaction(ctx.pool, (client) =>
    qRepo.updateTagsBatch(client, ids, tags ?? [], mode, ctx.authUserId),
  );
  return ok({ updated, requested: ids.length, skipped: ids.length - updated });
  return ok({ updated, requested: ids.length, skipped: ids.length - updated });
}

/**
 * PATCH /questions/batch —— 批量改归属（科目 / 考点）—— m30197 任务 C。
 *
 * body: { ids: string[], subject_id?: uuid, knowledge_node_id?: uuid|null }
 *   - 只传 subject_id  —— 换科目，旧考点一并清空（旧考点不属于新科目）；
 *   - 传 knowledge_node_id —— 设考点；
 *   - 传 knowledge_node_id: null —— 只清考点。
 *
 * 与 /questions/batch/tags 同形状：只改自己的题，公共题与别人的题静默跳过
 * （响应里的 skipped 就是这部分的条数）。不带 version，理由见仓储注释。
 */
async function updateQuestionsAssignmentBatch(ctx) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '批量改归属需要有效的 Bearer Token' });
  }
  const body = ctx.body ?? {};
  const ids = Array.isArray(body.ids)
    ? body.ids.map((v) => optionalId(v)).filter((v) => v !== null)
    : [];
  if (ids.length === 0) {
    return fail('EMPTY_IDS', 400, { message: 'ids 不能为空' });
  }

  const subjectId = optionalId(body.subject_id);
  // 「键在不在」与「值是 null」是两件事：
  //   键不在     -> 完全不碰考点；
  //   键在且 null -> 用户选了「不指定考点」，必须清空。
  const hasNodeKey = Object.prototype.hasOwnProperty.call(body, 'knowledge_node_id');
  const knowledgeNodeId = hasNodeKey ? optionalId(body.knowledge_node_id) : null;
  const clearKnowledgeNode = hasNodeKey && knowledgeNodeId === null;

  if (!subjectId && !hasNodeKey) {
    return fail('NOTHING_TO_UPDATE', 400, {
      message: 'subject_id 与 knowledge_node_id 至少要给一个',
    });
  }

  const updated = await withTransaction(ctx.pool, (client) =>
    qRepo.updateAssignmentBatch(
      client,
      ids,
      { subjectId, knowledgeNodeId, clearKnowledgeNode },
      ctx.authUserId,
    ),
  );
  return ok({ updated, requested: ids.length, skipped: ids.length - updated });
}


/**
 * GET /questions/deleted —— 列某用户已软删的题（m26090 题库管理页「已删除」筛选）。
 *
 * 只列自己的题（公共题永远不会被软删）。
 */
async function listDeletedQuestions(ctx) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '查看已删除题目需要有效的 Bearer Token' });
  }
  const page = pagination(ctx.searchParams);
  const rows = await qRepo.listDeleted(ctx.pool, {
    ownerUserId: ctx.authUserId,
    limit: page.limit,
    offset: page.offset,
  });
  const items = rows.map((r) => ({
    id: r.id,
    source: r.source,
    subject_id: r.subject_id,
    knowledge_node_id: r.knowledge_node_id,
    type: r.type,
    stem: r.stem,
    difficulty: r.difficulty ?? null,
    owner_user_id: r.owner_user_id ?? null,
    deleted_at: r.deleted_at,
    version: r.version,
  }));
  return ok({ items, total: items.length, limit: page.limit, offset: page.offset });
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

  // PATCH /questions/:id/mastery（m25316）—— 必须在 seg.length===2 分支**之前**，
  // 否则 /questions/:id/mastery 会被当成 /questions/:id 抢走（seg.length 是 3，这里不会）。
  if (method === 'PATCH' && seg.length === 3 && seg[0] === 'questions' && seg[2] === 'mastery') {
    return setQuestionMastery(ctx, seg[1]);
  }
  // ★ m26090（R3）：下面几个分支也必须在 seg.length===2 分支之前。
  //   PATCH /questions/batch/restore —— 批量恢复。
  //   ★ 必须排在 PATCH /questions/:id/restore **之前**：
  //     /questions/batch/restore 的 seg = ['questions','batch','restore']，
  //     seg[2] 同样是 'restore'，若被 :id/restore 抢走就会拿 'batch' 当 uuid 查，
  //     PG 报 22P02 → 在 httpError 里被吞成 500 internal（极难查）。
  if (method === 'PATCH' && seg.length === 3 && seg[0] === 'questions' && seg[1] === 'batch' && seg[2] === 'restore') {
    return restoreQuestionsBatch(ctx);
  }
  //   PATCH /questions/batch/tags —— 批量编辑标签（m27163）
  //   ★ 必须排在 PATCH /questions/:id/... 系列**之前**：
  //     /questions/batch/tags 的 seg = ['questions','batch','tags']，
  //     若被 :id 分支抢走就会拿 'batch' 当 uuid 查，PG 报 22P02 → 被 httpError 吞成 500。
  if (method === 'PATCH' && seg.length === 3 && seg[0] === 'questions' && seg[1] === 'batch' && seg[2] === 'tags') {
    return updateQuestionsTagsBatch(ctx);
  }
  //   PATCH /questions/batch —— 批量改归属（科目 / 考点）（m30197）
  //   ★ seg.length === 2，会与文件末尾的通用 `PATCH /questions/:id` 撞车：
  //     被通用分支抢走就会拿 'batch' 当 uuid 查，PG 报 22P02 → 被 httpError 吞成 500。
  if (method === 'PATCH' && seg.length === 2 && seg[0] === 'questions' && seg[1] === 'batch') {
    return updateQuestionsAssignmentBatch(ctx);
  }

  //   PATCH /questions/:id/restore —— 恢复软删的题
  if (method === 'PATCH' && seg.length === 3 && seg[0] === 'questions' && seg[2] === 'restore') {
    return restoreQuestion(ctx, seg[1]);
  }
  //   PATCH /questions/:id/hide —— 隐藏/取消隐藏（公共题只能隐藏）
  if (method === 'PATCH' && seg.length === 3 && seg[0] === 'questions' && seg[2] === 'hide') {
    return setQuestionHidden(ctx, seg[1]);
  }
  //   PATCH /questions/batch/restore —— 批量恢复（见上方：必须先于 :id/restore 判定）
  //   DELETE /questions/batch —— 批量软删
  if (method === 'DELETE' && seg.length === 2 && seg[0] === 'questions' && seg[1] === 'batch') {
    return deleteQuestionsBatch(ctx);
  }
  //   GET /questions/deleted —— 列已软删的题
  if (method === 'GET' && seg.length === 2 && seg[0] === 'questions' && seg[1] === 'deleted') {
    return listDeletedQuestions(ctx);
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
