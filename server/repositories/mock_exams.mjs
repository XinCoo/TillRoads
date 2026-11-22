// server/repositories/mock_exams.mjs
// 题路 TillRoad · BE-05 T1：模考仓储（PG）
//
// 生命周期只有两态（拍板项 1）：创建即 in_progress（组卷完成、计时开始），
//   提交即生成报告。schema 里没有 status 列，用 `report IS NULL` 表示「未提交」。
//
// 三个关键职责：
//   1. create  组卷：按 subject_id（full）或 knowledge_node_id（module）
//              随机抽 question_count 道未软删题；不足 -> 400 INSUFFICIENT_QUESTIONS
//   2. submit  收卷：写 attempts + 回填 questions jsonb + 生成 report，**同一事务**
//   3. listByProfile 供稳定性指标（近 3 次同 mode）与列表端点复用
//
// ★ 抽题不复用 questions.listBySubject/listByKnowledgeNode：
//   那两个函数是「按创建顺序分页」（orderBy created_at ASC, id ASC）且 limit 上限 200，
//   既无随机性也无法抽满大卷。组卷必须 `ORDER BY random()`。

import {
  archiveWithVersion,
  insertRow,
  pageParams,
  queryMany,
  queryOne,
  requireRow,
  updateWithVersion,
} from './_common.mjs';
import { create as createAttempt } from './attempts.mjs';
import { reportGenerator } from '../mock_report.mjs';

export const TABLE = 'mock_exams';

export const MODES = Object.freeze(['module', 'full']);

/** 可写业务列（不含 id / 系统列）。 */
export const WRITABLE_COLUMNS = Object.freeze([
  'exam_profile_id',
  'mode',
  'duration_limit_ms',
  'questions',
  'report',
]);

const INSERT_COLUMNS = Object.freeze([...WRITABLE_COLUMNS]);

/** 提交后允许更新的列（只此两个，绝不写 status —— 本表无 status）。 */
const SUBMIT_COLUMNS = Object.freeze(['questions', 'report']);

/** 超时宽限（拍板项 1：实际用时 ≤ duration_limit_ms + 60s）。 */
export const TIMEOUT_GRACE_MS = 60_000;

/** 组卷返回给客户端的题目字段：**刻意不含 answer / analysis**（提交前不能泄题）。 */
const PUBLIC_QUESTION_COLUMNS = `id, subject_id, knowledge_node_id, type, stem, options,
  difficulty, is_subjective, tags`;

function insufficientQuestions(available, requested) {
  const err = new Error(`题库题目不足：需要 ${requested} 道，可用 ${available} 道`);
  err.name = 'InsufficientQuestionsError';
  err.statusCode = 400;
  err.status = 400;
  err.code = 'INSUFFICIENT_QUESTIONS';
  err.body = { error: 'INSUFFICIENT_QUESTIONS', available, requested };
  return err;
}

function alreadySubmitted(id) {
  const err = new Error(`模考 ${id} 已提交，不能重复提交`);
  err.name = 'ConflictError';
  err.statusCode = 409;
  err.status = 409;
  err.code = 'already_submitted';
  err.body = { error: 'already_submitted', mock_exam_id: id };
  return err;
}

/**
 * 组卷并落库。
 *
 * input:
 *   exam_profile_id     uuid  必填
 *   mode                'module'|'full'  必填
 *   question_count      int   必填（1..200）
 *   duration_limit_ms   int|null  用户选的限时，null 表示不限时（则不做超时判定）
 *   subject_id          uuid  full 模式必填
 *   knowledge_node_id   uuid  module 模式必填
 *
 * 必须在 withTransaction 内调用。
 */
export async function create(client, input = {}) {
  const examProfileId = input.exam_profile_id;
  if (!examProfileId) throw new TypeError('mock_exams.create: exam_profile_id 必填');

  const mode = input.mode;
  if (!MODES.includes(mode)) {
    const err = new TypeError(`mock_exams.create: mode 必须是 ${MODES.join(' / ')}`);
    err.code = 'INVALID_MODE';
    throw err;
  }

  const count = Number(input.question_count);
  if (!Number.isInteger(count) || count < 1 || count > 200) {
    const err = new TypeError('mock_exams.create: question_count 必须是 1..200 的整数');
    err.code = 'INVALID_QUESTION_COUNT';
    throw err;
  }

  // 两种模式的抽题范围
  let scopeSql;
  let scopeParams;
  if (mode === 'full') {
    if (!input.subject_id) {
      const err = new TypeError('mock_exams.create: full 模式必须提供 subject_id');
      err.code = 'MISSING_SUBJECT_ID';
      throw err;
    }
    scopeSql = 'subject_id = $1';
    scopeParams = [input.subject_id];
  } else {
    if (!input.knowledge_node_id) {
      const err = new TypeError('mock_exams.create: module 模式必须提供 knowledge_node_id');
      err.code = 'MISSING_KNOWLEDGE_NODE_ID';
      throw err;
    }
    scopeSql = 'knowledge_node_id = $1';
    scopeParams = [input.knowledge_node_id];
  }

  // ★ m17431：抽题只在「公共题 + 该用户自己的题」范围内。
  //   以前所有题都是公共的（questions 表没有 owner 列），现在用户导入的题是
  //   私有题，别人的私有题绝不能被抽进自己的模考（否则会出现「我考到了别人的题」）。
  //   ownerUserId 为空（未鉴权的内部调用 / seed 数据）时不过滤，保持旧行为。
  const ownerUserId = input.owner_user_id ?? null;
  let ownerSql = '';
  if (ownerUserId) {
    scopeParams.push(ownerUserId);
    ownerSql = ' AND (owner_user_id IS NULL OR owner_user_id = $' + scopeParams.length + ')';
  }
  const whereSql = 'deleted_at IS NULL AND ' + scopeSql + ownerSql;

  // 可用题量（先查，给出准确的 available 数字）
  const countRow = await queryOne(
    client,
    'SELECT count(*)::int AS available FROM questions WHERE ' + whereSql,
    scopeParams,
  );
  const available = countRow?.available ?? 0;
  if (available < count) throw insufficientQuestions(available, count);

  // 随机抽题（ORDER BY random() 是 PG 原生随机，MVP 不引入抽样算法）
  const picked = await queryMany(
    client,
    'SELECT ' + PUBLIC_QUESTION_COLUMNS + ' FROM questions WHERE ' + whereSql +
      ' ORDER BY random() LIMIT $' + (scopeParams.length + 1),
    [...scopeParams, count],
  );

  if (picked.length < count) throw insufficientQuestions(picked.length, count);

  // questions jsonb 结构严格按 schema 注释（拍板项 3）：
  //   [{question_id, attempt_id, is_correct, duration_ms}]
  // 组卷时后三项均为 null，提交时回填。
  const questions = picked.map((q) => ({
    question_id: q.id,
    attempt_id: null,
    is_correct: null,
    duration_ms: null,
  }));

  const row = await insertRow(client, TABLE, INSERT_COLUMNS, [
    examProfileId,
    mode,
    input.duration_limit_ms ?? null,
    // insertRow 对 jsonb 列自动 toJsonbParam（mock_exams.questions 已在 JSONB_COLUMNS）
    JSON.stringify(questions),
    null,
  ]);

  return { mock_exam: row, questions: picked, available };
}

/** 按主键读（软删行视为不存在 -> 404）。 */
export async function getById(client, id) {
  return requireRow(client, TABLE, id);
}

/**
 * 列某考试目标下的模考，最新的在前。
 *
 * mode 过滤供稳定性指标用（「近 3 次**同 mode** 同 exam_profile」）。
 * 不走 listRows：它固定 orderBy created_at ASC，而这里需要 DESC。
 */
export async function listByProfile(client, examProfileId, opts = {}) {
  if (!examProfileId) throw new TypeError('mock_exams.listByProfile: examProfileId 必填');
  const { limit, offset } = pageParams({ limit: opts.limit ?? 20, offset: opts.offset });

  const where = ['exam_profile_id = $1', 'deleted_at IS NULL'];
  const params = [examProfileId];
  if (opts.mode) {
    if (!MODES.includes(opts.mode)) throw new TypeError('mock_exams.listByProfile: 非法 mode');
    params.push(opts.mode);
    where.push(`mode = $${params.length}`);
  }
  if (opts.submittedOnly === true) where.push('report IS NOT NULL');

  params.push(limit, offset);
  const rows = await queryMany(
    client,
    `SELECT * FROM mock_exams
      WHERE ${where.join(' AND ')}
      ORDER BY created_at DESC, id DESC
      LIMIT $${params.length - 1} OFFSET $${params.length}`,
    params,
  );
  return rows;
}

/**
 * 提交收卷：写 attempts + 回填 questions jsonb + 生成 report。
 *
 * 必须在 withTransaction 内调用（拍板项硬约束：三者要么全成要么全败）。
 *
 * input:
 *   answers       [{question_id, answer_text, duration_ms}]  必填（可为空数组）
 *   submitted_at  ISO 字符串或 Date，缺省 now
 *   baseVersion   乐观锁基准
 *
 * 超时判定（拍板项 1）：实际用时 > duration_limit_ms + 60s 视为超时收卷，
 *   不拒绝提交，而是把**未作答**的题计错（已作答的按对错正常算）。
 */
export async function submit(client, id, input = {}) {
  const current = await requireRow(client, TABLE, id);
  if (current.report) throw alreadySubmitted(id);

  const baseVersion = input.baseVersion ?? input.base_version;
  if (!Number.isInteger(baseVersion) || baseVersion < 1) {
    throw new TypeError('mock_exams.submit: baseVersion 必填（正整数）');
  }

  const answers = Array.isArray(input.answers) ? input.answers : [];
  const answerByQuestion = new Map();
  for (const a of answers) {
    if (a && a.question_id) answerByQuestion.set(String(a.question_id), a);
  }

  // 模考的归属用户（mock_exams 无 user_id 列，须经 exam_profiles 取）
  const profileRow = await queryOne(
    client,
    `SELECT user_id FROM exam_profiles WHERE id = $1`,
    [current.exam_profile_id],
  );
  const userId = profileRow?.user_id;
  if (!userId) throw new TypeError('mock_exams.submit: 找不到模考所属的 exam_profile');

  // 超时判定
  const planned = Number(current.questions?.length ?? 0);
  const startedMs = new Date(current.created_at).getTime();
  const submittedRaw = input.submitted_at ?? input.submittedAt ?? null;
  const submittedMs = submittedRaw ? new Date(submittedRaw).getTime() : Date.now();
  if (Number.isNaN(submittedMs)) {
    const err = new TypeError('mock_exams.submit: submitted_at 不是合法时间');
    err.code = 'INVALID_SUBMITTED_AT';
    throw err;
  }
  const limit = current.duration_limit_ms;
  const elapsedMs = planned > 0 ? submittedMs - startedMs : 0;
  const timedOut = limit != null && elapsedMs > Number(limit) + TIMEOUT_GRACE_MS;

  // 取题干（判分需要对标准答案）。注意：这一步只为判分，绝不回传给客户端。
  const questionIds = (current.questions ?? []).map((q) => q.question_id).filter(Boolean);
  const questionRows = questionIds.length
    ? await queryMany(
        client,
        `SELECT q.id, q.type, q.is_subjective, q.answer, q.knowledge_node_id,
                kn.title AS knowledge_node_title
           FROM questions q
           LEFT JOIN knowledge_nodes kn ON kn.id = q.knowledge_node_id
          WHERE q.id = ANY($1::uuid[]) AND q.deleted_at IS NULL`,
        [questionIds],
      )
    : [];
  const questionById = new Map(questionRows.map((q) => [String(q.id), q]));

  // 逐题判分 + 落 attempts
  const filled = [];
  for (const entry of current.questions ?? []) {
    const qid = entry.question_id;
    const answer = answerByQuestion.get(String(qid));
    const answered = Boolean(answer && String(answer.answer_text ?? '').trim() !== '');
    const durationMs = Number.isFinite(Number(answer?.duration_ms))
      ? Number(answer.duration_ms)
      : null;
    const question = questionById.get(String(qid)) ?? null;

    let isCorrect = gradeOne(question, answered ? answer.answer_text : null);
    // 超时收卷：未作答题计错（已作答的正常判）
    if (timedOut && !answered) isCorrect = false;

    const attempt = await createAttempt(client, {
      question_id: qid,
      user_id: userId,
      is_correct: isCorrect,
      duration_ms: durationMs,
      answer_text: answered ? String(answer.answer_text) : null,
      mock_exam_id: id,
    });

    filled.push({
      question_id: qid,
      attempt_id: attempt.id,
      is_correct: isCorrect,
      duration_ms: durationMs,
    });
  }

  // 报告所需的旁证数据
  const userDefects = await queryMany(
    client,
    `SELECT id, question_id, knowledge_node_id, status::text AS status
       FROM defect_tickets
      WHERE user_id = $1 AND deleted_at IS NULL
        AND status::text IN ('CLOSED','V3')
        -- 不限制 question_id 非空: CLOSED 按 question_id 匹配错题, V3 按 knowledge_node_id 匹配考点,
        -- 二者匹配键不同; 若在此过滤掉无 question_id 的 V3 单, v3_candidates 会恒为 0 (PGlite 实测踩过)
        `,
    [userId],
  );

  // 近 3 次同 mode 已提交模考（不含本次 —— 本次 report 尚为 null）
  const recentMocks = await listByProfile(client, current.exam_profile_id, {
    mode: current.mode,
    limit: 3,
    submittedOnly: true,
  });

  const report = reportGenerator({
    questions: questionRows.map((q) => ({
      question_id: q.id,
      knowledge_node_id: q.knowledge_node_id ?? null,
      title: q.knowledge_node_title ?? null,
    })),
    attempts: filled,
    closedDefects: userDefects,
    recentMocks,
  });

  // attempts 已落，questions jsonb 按 attempt_id 回填
  const updated = await updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch: { questions: JSON.stringify(filled), report: JSON.stringify(report) },
    allowedColumns: SUBMIT_COLUMNS,
  });

  return {
    mock_exam: updated,
    report,
    timed_out: timedOut,
    elapsed_ms: Math.max(0, elapsedMs),
  };
}

/** 仅读 report（未提交 -> 404，由路由层映射）。 */
export async function getReport(client, id) {
  const row = await getById(client, id);
  return row.report ?? null;
}

/** 软删。 */
export async function archive(client, id, baseVersion) {
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
}

// 内部：单题判分 —— 与 mock_report.gradeAnswer 同口径，但只需要 question 行。
function gradeOne(question, answerText) {
  if (!question) return null;
  if (question.is_subjective === true) return null;
  if (question.type === 'essay' || question.type === 'short_answer') return null;
  const expected = question.answer == null ? '' : String(question.answer).trim();
  if (expected === '') return null;
  const actual = answerText == null ? '' : String(answerText);
  return normalize(actual) === normalize(expected);
}

function normalize(value) {
  return String(value ?? '')
    .normalize('NFKC')
    .replace(/[\s\u3000，。！？；：（）【】《》、,.!?;:()[\]<>"'`]/g, '')
    .toUpperCase();
}

