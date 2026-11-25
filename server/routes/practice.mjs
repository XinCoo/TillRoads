// server/routes/practice.mjs
// 题路 TillRoad · 练习模式 R1：抽题 / 提交 / 历史 / 详情
//
// 端点：
//   GET  /questions/practice?subject_id=&knowledge_node_id=&count=&source=  抽题
//   POST /practice-sessions                                          提交一次练习
//   GET  /practice-sessions?limit=&offset=                            练习历史
//   GET  /practice-sessions/:id                                      单次详情
//
// ── 与模考的关系 ────────────────────────────────────────────────────────
// 练习**不复用**模考的组卷与提交逻辑：模考限时、绑定考试目标、生成报告、
// 抽题不足直接报错；练习不限时、可以只抽几道、题量不足就按实际的来。
// 唯一共用的是「ORDER BY random() 随机抽题」这个手法（写在各自仓储里）。
//
// ── 安全底线 ────────────────────────────────────────────────────────────
// 1. 归属只认 token（ctx.authUserId），请求体里的 user_id 一律忽略；
// 2. **答案只下发给用户自己的题**：公共题（owner_user_id IS NULL）的
//    answer 在仓储层的 SQL 里就被置 null —— 不依赖路由层过滤；
// 3. 别人的练习会话 → 404（不是 403，避免枚举）。
import * as pRepo from '../repositories/practice_sessions.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { ok, fail, pagination } from './_http.mjs';

/** 来源取值（与仓储层 PRACTICE_SOURCES 一致）。 */
const SOURCES = new Set(['mine', 'public', 'all']);

/** 400 的请求体校验失败（走 httpError 第①分支，透出 message）。 */
function badRequest(code, message) {
  const err = new Error(message);
  err.code = code;
  err.statusCode = 400;
  err.body = { error: code, message };
  return err;
}

/** 可空的 uuid 字段：空串/null → null。 */
function optionalId(value) {
  if (value === undefined || value === null) return null;
  const s = String(value).trim();
  return s === '' ? null : s;
}

/** GET /questions/practice —— 抽题。 */
async function pickPracticeQuestions(ctx) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '练习需要有效的 Bearer Token' });
  }
  const subjectId = optionalId(ctx.searchParams.get('subject_id'));
  const knowledgeNodeId = optionalId(ctx.searchParams.get('knowledge_node_id'));
  const rawSource = ctx.searchParams.get('source');
  const source = rawSource && SOURCES.has(rawSource) ? rawSource : 'all';
  const rawCount = ctx.searchParams.get('count');
  const count = rawCount === null ? pRepo.PRACTICE_DEFAULT_COUNT : Number(rawCount);

  if (!Number.isFinite(count) || count <= 0) {
    throw badRequest('INVALID_COUNT', 'count 必须是正整数');
  }

  const { items, available } = await pRepo.pickQuestions(ctx.pool, {
    userId: ctx.authUserId,
    subjectId,
    knowledgeNodeId,
    source,
    count,
  });

  // ★ 题量不足不报错：返回 200 + 实际条数 + available，
  //   让前端问用户「该范围只有 N 道题，是否按 N 道开始？」。
  return ok({
    items,
    total: items.length,
    requested: Math.min(Math.trunc(count), pRepo.PRACTICE_MAX_COUNT),
    available,
    source,
  });
}

/** POST /practice-sessions —— 提交一次练习（会话头 + 每题作答）。 */
async function createPracticeSession(ctx) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '练习需要有效的 Bearer Token' });
  }
  const body = ctx.body ?? {};
  const subjectId = optionalId(body.subject_id);
  const knowledgeNodeId = optionalId(body.knowledge_node_id);
  const rawSource = body.source;
  const source = rawSource && SOURCES.has(rawSource) ? rawSource : 'all';

  const rawAnswers = body.answers;
  if (!Array.isArray(rawAnswers)) {
    throw badRequest('INVALID_ANSWERS', 'answers 必须是数组');
  }
  const answers = rawAnswers
    .map((a) => ({
      question_id: optionalId(a?.question_id),
      user_answer: a?.user_answer ?? null,
      is_correct: a?.is_correct === true ? true : a?.is_correct === false ? false : null,
      duration_ms: Number.isFinite(Number(a?.duration_ms)) ? Number(a.duration_ms) : null,
    }))
    .filter((a) => a.question_id !== null);

  if (answers.length === 0) {
    throw badRequest('EMPTY_ANSWERS', '至少提交一道题的作答');
  }

  const result = await withTransaction(ctx.pool, (client) =>
    pRepo.createSession(client, {
      userId: ctx.authUserId,
      subjectId,
      knowledgeNodeId,
      source,
      answers,
    }),
  );

  return ok(
    {
      session_id: result.session.id,
      total: result.total,
      correct: result.correct,
      wrong: result.wrong,
      unjudged: result.unjudged,
      accuracy: result.accuracy,
      created_at: result.session.created_at,
    },
    201,
  );
}

/** GET /practice-sessions —— 练习历史（按 token 映射的 userId）。 */
async function listPracticeSessions(ctx) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '练习需要有效的 Bearer Token' });
  }
  const page = pagination(ctx.searchParams);
  const { items, total, limit, offset } = await pRepo.listSessions(ctx.pool, ctx.authUserId, {
    limit: page.limit,
    offset: page.offset,
  });
  return ok({
    items: items.map((s) => ({
      id: s.id,
      subject_id: s.subject_id ?? null,
      knowledge_node_id: s.knowledge_node_id ?? null,
      source: s.source ?? null,
      total: s.total ?? 0,
      correct: s.correct ?? 0,
      wrong: s.wrong ?? 0,
      accuracy:
        (s.total ?? 0) > 0 ? Math.round(((s.correct ?? 0) / s.total) * 1000) / 10 : 0,
      created_at: s.created_at,
    })),
    total,
    limit,
    offset,
  });
}

/** GET /practice-sessions/:id —— 单次详情（含每题对错）。 */
async function getPracticeSession(ctx, id) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, { message: '练习需要有效的 Bearer Token' });
  }
  try {
    const detail = await pRepo.getSessionDetail(ctx.pool, ctx.authUserId, id);
    const s = detail.session;
    return ok({
      session: {
        id: s.id,
        subject_id: s.subject_id ?? null,
        knowledge_node_id: s.knowledge_node_id ?? null,
        source: s.source ?? null,
        total: s.total ?? 0,
        correct: s.correct ?? 0,
        wrong: s.wrong ?? 0,
        accuracy:
          (s.total ?? 0) > 0 ? Math.round(((s.correct ?? 0) / s.total) * 1000) / 10 : 0,
        created_at: s.created_at,
      },
      answers: detail.answers,
    });
  } catch (e) {
    // 别人的会话 → 仓储层抛 notFoundError → 404（不泄露「存在但不是你的」）。
    throw e;
  }
}

/** 路由分发。 */
export async function match(method, seg, ctx) {
  // GET /questions/practice —— 必须排在 questions 模块之前吗？
  // 不必：questions 模块只认 seg.length===1 或 2（'questions'/'practice'），
  // 这里 seg.length===2 且 seg[0]==='questions'，questions 模块会把它当成
  // GET /questions/:id（单题详情）！所以本模块必须**排在 questions 之前**。
  if (method === 'GET' && seg.length === 2 && seg[0] === 'questions' && seg[1] === 'practice') {
    return pickPracticeQuestions(ctx);
  }

  if (seg[0] === 'practice-sessions') {
    if (method === 'POST' && seg.length === 1) return createPracticeSession(ctx);
    if (method === 'GET' && seg.length === 1) return listPracticeSessions(ctx);
    if (method === 'GET' && seg.length === 2) return getPracticeSession(ctx, seg[1]);
  }

  return null;
}
