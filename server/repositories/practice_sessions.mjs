// server/repositories/practice_sessions.mjs
// 题路 TillRoad · 练习模式 R1：practice_sessions / practice_answers 仓储
//
// ── 为什么单独一个模块 ────────────────────────────────────────────────────
// 练习不是模考：模考有考试目标、限时、报告；练习是「随手抽 N 道做一下」。
// 数据上它只需要两张小表：一次练习的头 + 每道题的作答明细。
//
// ── 三条硬规则（都写在这层，不靠路由层自觉）────────────────────────────
// 1. **归属只认 token**：所有写方法的 userId 由调用方从 ctx.authUserId 传入，
//    读方法一律带 `user_id = $n` 过滤。别人的练习记录一律 404（不是 403，
//    403 等于告诉对方「这个 id 存在」，可以用来枚举）。
// 2. **答案不下发给公共题**：抽题时只有 owner_user_id = 当前用户 的题才带 answer；
//    公共题（owner_user_id IS NULL）的 answer 一律置 null，由前端做「自评」。
//    这个判断放在仓储层（buildPracticeQuestion），路由层拿到的就已经是安全形状。
// 3. **统计口径在服务端算**：total / correct / wrong 由服务端按作答明细算，
//    客户端传来的 is_correct 只作为「公共题自评」的输入。
import { queryMany, queryOne } from './base.mjs';
import { notFoundError } from './_common.mjs';

export const SESSIONS_TABLE = 'practice_sessions';
export const ANSWERS_TABLE = 'practice_answers';

/** 抽题来源：mine=只自己的题 / public=只公共题 / all=公共+自己的。 */
export const PRACTICE_SOURCES = Object.freeze(['mine', 'public', 'all']);

/** 单次抽题上限（防止把整个题库拉下来）。 */
export const PRACTICE_MAX_COUNT = 50;
export const PRACTICE_DEFAULT_COUNT = 10;

/**
 * 抽题。
 *
 * @param client
 * @param {object} opts
 * @param {string|null} opts.userId        token 映射出的 userId（必填）
 * @param {string|null} opts.subjectId
 * @param {string|null} opts.knowledgeNodeId
 * @param {'mine'|'public'|'all'} opts.source
 * @param {number} opts.count
 * @returns {Promise<{items: object[], available: number}>}
 */
export async function pickQuestions(
  client,
  { userId, subjectId = null, knowledgeNodeId = null, source = 'all', count = PRACTICE_DEFAULT_COUNT } = {},
) {
  if (!userId) {
    const err = new Error('练习需要有效的 Bearer Token');
    err.code = 'UNAUTHORIZED';
    err.statusCode = 401;
    err.body = { error: 'unauthorized', message: err.message };
    throw err;
  }
  const scope = PRACTICE_SOURCES.includes(source) ? source : 'all';

  const where = ['deleted_at IS NULL'];
  const params = [];

  if (subjectId) {
    params.push(subjectId);
    where.push(`subject_id = $${params.length}`);
  }
  if (knowledgeNodeId) {
    params.push(knowledgeNodeId);
    where.push(`knowledge_node_id = $${params.length}`);
  }

  // 来源分域：mine → 只自己的题；public → 只公共题；all → 公共 + 自己的。
  // 无论哪种，**别人的私有题永远不在范围内**。
  //
  // 注意：public 分支的 where 里没有 user_id 引用，所以**不能**把 userId
  // 提前塞进 params —— 否则这条 count 查询会带一个没人用的 $1，
  // PG 会直接报「bind message supplies 1 parameters, but prepared statement requires 0」，
  // 在 httpError 里又被吞成 500 internal（很难查）。
  if (scope === 'mine') {
    params.push(userId);
    where.push(`owner_user_id = $${params.length}`);
  } else if (scope === 'public') {
    where.push(`owner_user_id IS NULL`);
  } else {
    params.push(userId);
    where.push(`(owner_user_id IS NULL OR owner_user_id = $${params.length})`);
  }

  const whereSql = where.join(' AND ');

  const availableRow = await queryOne(
    client,
    `SELECT count(*)::int AS available FROM questions WHERE ${whereSql}`,
    params,
  );
  const available = availableRow?.available ?? 0;

  const want = Math.max(1, Math.min(Number(count) || PRACTICE_DEFAULT_COUNT, PRACTICE_MAX_COUNT));

  // ★ 答案只在仓储层决定下发与否：SQL 里直接把公共题的 answer 置 null，
  //   而不是「先查出来再在路由层删」——那样漏一处就会泄题。
  // 答案用独立的占位符（放在 where 参数之后），避免污染 count 查询的参数个数。
  const caseParamIndex = params.length + 1;
  const rows = await queryMany(
    client,
    `SELECT id, subject_id, knowledge_node_id, type, stem, options,
            CASE WHEN owner_user_id = $${caseParamIndex} THEN answer ELSE NULL END AS answer,
            CASE WHEN owner_user_id = $${caseParamIndex} THEN analysis ELSE NULL END AS analysis,
            difficulty, is_subjective, tags, owner_user_id
       FROM questions
      WHERE ${whereSql}
      ORDER BY random()
      LIMIT $${caseParamIndex + 1}`,
    [...params, userId, want],
  );

  return { items: rows.map((r) => buildPracticeQuestion(r, userId)), available };
}

/**
 * 把一行题转成练习用的形状。
 *
 * has_answer = 客户端拿得到标准答案 → 可以自动判分；
 *             没有 → 前端显示「该题不提供答案，请自评」。
 */
export function buildPracticeQuestion(row, userId) {
  const owner = row.owner_user_id ?? null;
  const isMine = owner !== null && owner === userId;
  return {
    id: row.id,
    subject_id: row.subject_id ?? null,
    knowledge_node_id: row.knowledge_node_id ?? null,
    type: row.type,
    stem: row.stem,
    options: row.options ?? null,
    // 公共题的 answer 在 SQL 里已经是 null，这里再兜一层（防止 SQL 被改）。
    answer: isMine ? (row.answer ?? null) : null,
    analysis: isMine ? (row.analysis ?? null) : null,
    difficulty: row.difficulty ?? null,
    is_subjective: row.is_subjective ?? false,
    tags: row.tags ?? null,
    owner_user_id: owner,
    is_mine: isMine,
    // 有答案才判分；没有就自评。
    has_answer: isMine && row.answer !== null && row.answer !== undefined && String(row.answer).trim() !== '',
  };
}

/**
 * 创建一次练习会话（头 + 作答明细，同一事务）。
 *
 * answers: [{question_id, user_answer, is_correct, duration_ms}]
 * - is_correct 为 null 的条目按「未判定」计入 total，不计入 correct/wrong。
 * - 统计口径在服务端算，客户端传什么都改不了 total/correct/wrong。
 */
export async function createSession(
  client,
  { userId, subjectId = null, knowledgeNodeId = null, source = 'all', answers = [] } = {},
) {
  if (!userId) {
    const err = new Error('练习需要有效的 Bearer Token');
    err.code = 'UNAUTHORIZED';
    err.statusCode = 401;
    err.body = { error: 'unauthorized', message: err.message };
    throw err;
  }
  const list = Array.isArray(answers) ? answers : [];
  let correct = 0;
  let wrong = 0;
  let unjudged = 0;
  for (const a of list) {
    if (a?.is_correct === true) correct += 1;
    else if (a?.is_correct === false) wrong += 1;
    else unjudged += 1;
  }
  const total = list.length;

  const sessionRow = await queryOne(
    client,
    `INSERT INTO ${SESSIONS_TABLE}
       (user_id, subject_id, knowledge_node_id, source, total, correct, wrong)
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     RETURNING *`,
    [userId, subjectId, knowledgeNodeId, source, total, correct, wrong],
  );

  for (const a of list) {
    if (!a || !a.question_id) continue;
    await queryOne(
      client,
      `INSERT INTO ${ANSWERS_TABLE}
         (session_id, question_id, user_answer, is_correct, duration_ms)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING id`,
      [
        sessionRow.id,
        a.question_id,
        a.user_answer === undefined || a.user_answer === null ? null : String(a.user_answer),
        a.is_correct === true ? true : a.is_correct === false ? false : null,
        Number.isFinite(Number(a.duration_ms)) ? Math.trunc(Number(a.duration_ms)) : null,
      ],
    );
  }

  return {
    session: sessionRow,
    total,
    correct,
    wrong,
    unjudged,
    accuracy: total > 0 ? Math.round((correct / total) * 1000) / 10 : 0,
  };
}

/** 列某个用户的练习历史（最近的在前）。 */
export async function listSessions(client, userId, { limit = 20, offset = 0 } = {}) {
  const l = Number.isInteger(Number(limit)) && Number(limit) > 0 ? Math.min(Number(limit), 100) : 20;
  const o = Number.isInteger(Number(offset)) && Number(offset) >= 0 ? Number(offset) : 0;
  const rows = await queryMany(
    client,
    `SELECT * FROM ${SESSIONS_TABLE}
      WHERE user_id = $1 AND deleted_at IS NULL
      ORDER BY created_at DESC, id DESC
      LIMIT $2 OFFSET $3`,
    [userId, l, o],
  );
  const totalRow = await queryOne(
    client,
    `SELECT count(*)::int AS total FROM ${SESSIONS_TABLE} WHERE user_id = $1 AND deleted_at IS NULL`,
    [userId],
  );
  return { items: rows, total: totalRow?.total ?? 0, limit: l, offset: o };
}

/**
 * 读一次练习详情（会话 + 每题作答 + 题干）。
 *
 * ★ 归属过滤在 SQL 里：别人的会话 → 一行都取不到 → 404。
 */
export async function getSessionDetail(client, userId, sessionId) {
  const session = await queryOne(
    client,
    `SELECT * FROM ${SESSIONS_TABLE}
      WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
    [sessionId, userId],
  );
  if (!session) throw notFoundError(SESSIONS_TABLE, sessionId);

  const answers = await queryMany(
    client,
    `SELECT pa.id, pa.question_id, pa.user_answer, pa.is_correct, pa.duration_ms,
            q.stem, q.type, q.options, q.answer AS correct_answer, q.analysis,
            q.owner_user_id
       FROM ${ANSWERS_TABLE} pa
       JOIN questions q ON q.id = pa.question_id
      WHERE pa.session_id = $1 AND pa.deleted_at IS NULL
      ORDER BY pa.created_at ASC, pa.id ASC`,
    [sessionId],
  );

  return {
    session,
    answers: answers.map((a) => ({
      id: a.id,
      question_id: a.question_id,
      user_answer: a.user_answer ?? null,
      is_correct: a.is_correct ?? null,
      duration_ms: a.duration_ms ?? null,
      stem: a.stem,
      type: a.type,
      options: a.options ?? null,
      // 正确答案：自己的题才给；公共题（owner_user_id IS NULL）不给。
      correct_answer:
        a.owner_user_id !== null && a.owner_user_id === userId ? (a.correct_answer ?? null) : null,
      analysis: a.owner_user_id !== null && a.owner_user_id === userId ? (a.analysis ?? null) : null,
      is_mine: a.owner_user_id !== null && a.owner_user_id === userId,
    })),
  };
}
