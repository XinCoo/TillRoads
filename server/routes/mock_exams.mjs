// server/routes/mock_exams.mjs
// 题路 TillRoad · BE-05 T4：限时模考端点（组卷 / 读卷 / 提交 / 报告 / 列表）
//
// 五个端点：
//   POST   /mock-exams                 组卷（创建即 in_progress）
//   GET    /mock-exams/:id             读卷面（已提交后含 questions 回填结果，但不含标准答案）
//   POST   /mock-exams/:id/submit      提交收卷 + 同步生成报告（同一事务）
//   GET    /mock-exams/:id/report      读已生成报告（未提交 -> 404 not_submitted）
//   GET    /exam-profiles/:id/mock-exams  列表
//
// ★ 本模块必须挂在 ROUTE_MODULES 中 defect_tickets **之前**：
//   BE-03 遗留的 GET /mock-exams/:id/report 假数据端点已从 defect_tickets 删除，
//   但保留顺序约束可避免将来回退时被旧分支截胡。
//
// ★ 组卷返回不含 answer / analysis（提交前不许泄题）；
//   提交后 GET /mock-exams/:id 也不返回标准答案，只返回判分结果与报告。

import * as mockExamsRepo from '../repositories/mock_exams.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { ok, fail, pagination, readBaseVersion } from './_http.mjs';

/** 依赖注入缝：ctx.repos.mockExams 存在时走 fake（与 defect_tickets 路由同形）。 */
function resolve(ctx) {
  if (ctx.repos && ctx.repos.mockExams) {
    return { repo: ctx.repos.mockExams, client: ctx.repos.client ?? null };
  }
  return { repo: mockExamsRepo, client: ctx.pool };
}

async function run(ctx, fn) {
  const { repo, client } = resolve(ctx);
  if (ctx.repos && ctx.repos.mockExams) return fn(repo, client);
  return withTransaction(ctx.pool, (tx) => fn(repo, tx));
}

async function read(ctx, fn) {
  const { repo, client } = resolve(ctx);
  return fn(repo, client);
}

/** POST /mock-exams —— 组卷。 */
async function createMockExam(ctx) {
  const body = ctx.body ?? {};

  if (!body.exam_profile_id) {
    return fail('missing_exam_profile_id', 400, { message: 'exam_profile_id 必填' });
  }
  if (!body.mode) return fail('missing_mode', 400, { message: 'mode 必填（module / full）' });
  if (body.question_count == null) {
    return fail('missing_question_count', 400, { message: 'question_count 必填' });
  }

  try {
    const result = await run(ctx, (repo, client) =>
      repo.create(client, {
        exam_profile_id: body.exam_profile_id,
        mode: body.mode,
        question_count: body.question_count,
        duration_limit_ms: body.duration_limit_ms ?? null,
        subject_id: body.subject_id,
        knowledge_node_id: body.knowledge_node_id,
        // ★ m17431：归属只认 token 映射出来的 userId（不信任请求体里的 user_id），
        //   组卷时只在「公共题 + 自己的题」里抽，别人的私有题不会被抽到。
        owner_user_id: ctx.authUserId ?? null,
      }),
    );

    // 卷面里不含 answer / analysis（组卷 SELECT 已排除），这里再显式剔除防御。
    const questions = (result.questions ?? []).map(sanitizeQuestion);

    return ok(
      {
        mock_exam: publicMockExam(result.mock_exam),
        questions,
        question_count: questions.length,
      },
      201,
    );
  } catch (e) {
    return mapError(e);
  }
}

/** GET /mock-exams/:id —— 读卷。 */
async function getMockExam(ctx, id) {
  try {
    const row = await read(ctx, (repo, client) => repo.getById(client, id));
    return ok({ mock_exam: publicMockExam(row) });
  } catch (e) {
    return mapError(e);
  }
}

/** POST /mock-exams/:id/submit —— 提交收卷 + 生成报告（同一事务）。 */
async function submitMockExam(ctx, id) {
  // readBaseVersion 返回 number 或 **抛异常**（不返回 {error}），所以取版本号必须包在 try 内。
  let baseVersion;
  try {
    baseVersion = readBaseVersion(ctx.body ?? {});
  } catch (e) {
    return mapError(e);
  }

  const body = ctx.body ?? {};
  const answers = Array.isArray(body.answers) ? body.answers : [];

  try {
    const result = await run(ctx, (repo, client) =>
      repo.submit(client, id, {
        baseVersion,
        answers,
        submitted_at: body.submitted_at ?? body.submittedAt,
      }),
    );

    return ok({
      mock_exam: publicMockExam(result.mock_exam),
      report: result.report,
      timed_out: result.timed_out === true,
      elapsed_ms: result.elapsed_ms,
    });
  } catch (e) {
    return mapError(e);
  }
}

/** GET /mock-exams/:id/report —— 读已生成报告。 */
async function getReport(ctx, id) {
  try {
    const row = await read(ctx, (repo, client) => repo.getById(client, id));
    if (!row.report) {
      return fail('not_submitted', 404, {
        message: '该模考尚未提交，没有报告',
        mock_exam_id: id,
      });
    }
    return ok({ mock_exam: publicMockExam(row), report: row.report });
  } catch (e) {
    return mapError(e);
  }
}

/** GET /exam-profiles/:id/mock-exams —— 列表。 */
async function listMockExams(ctx, examProfileId) {
  const page = paginationOf(ctx.searchParams);
  const mode = ctx.searchParams.get('mode') ?? undefined;

  try {
    const items = await read(ctx, (repo, client) =>
      repo.listByProfile(client, examProfileId, {
        ...page,
        mode: mode || undefined,
        submittedOnly: ctx.searchParams.get('submitted') === 'true',
      }),
    );
    return ok({
      items: items.map(publicMockExam),
      total: items.length,
      limit: page.limit,
      offset: page.offset,
    });
  } catch (e) {
    return mapError(e);
  }
}

// ---------------------------------------------------------------------------
// 序列化：绝不把标准答案 / 解析带出
// ---------------------------------------------------------------------------
const HIDDEN_FIELDS = ['answer', 'analysis'];

function sanitizeQuestion(q) {
  if (!q || typeof q !== 'object') return q;
  const out = { ...q };
  for (const f of HIDDEN_FIELDS) delete out[f];
  return out;
}

/** mock_exams 行对外形状：剔除内部字段，report 单独给（不在列表里塞大 jsonb）。 */
function publicMockExam(row) {
  if (!row) return row;
  const { deleted_at: _ignored, ...rest } = row;
  return rest;
}

function paginationOf(searchParams) {
  const p = pagination(searchParams);
  const limit = Number.isFinite(p.limit) ? Math.min(Math.max(Math.trunc(p.limit), 1), 200) : 20;
  const offset = Number.isFinite(p.offset) && p.offset >= 0 ? Math.trunc(p.offset) : 0;
  return { limit, offset };
}

/** 仓储抛的错误 -> HTTP 响应。 */
function mapError(e) {
  if (e && typeof e.statusCode === 'number' && e.body && typeof e.body === 'object') {
    return { status: e.statusCode, body: e.body };
  }
  if (e && e.name === 'NotFoundError' && e.body) return { status: 404, body: e.body };
  if (e && typeof e.code === 'string' && !isPgSqlState(e.code)) {
    return fail(e.code, 400, e.message ? { message: e.message } : undefined);
  }
  throw e;
}

function isPgSqlState(code) {
  return typeof code === 'string' && /^[0-9A-Z]{5}$/.test(code);
}

export async function match(method, seg, ctx) {
  // /mock-exams
  if (seg.length === 1 && seg[0] === 'mock-exams') {
    if (method === 'POST') return createMockExam(ctx);
    return null;
  }

  // /mock-exams/:id
  if (seg.length === 2 && seg[0] === 'mock-exams') {
    if (method === 'GET') return getMockExam(ctx, seg[1]);
    if (method === 'DELETE') return deleteMockExam(ctx, seg[1]);
    return null;
  }

  // /mock-exams/:id/submit
  if (method === 'POST' && seg.length === 3 && seg[0] === 'mock-exams' && seg[2] === 'submit') {
    return submitMockExam(ctx, seg[1]);
  }

  // /mock-exams/:id/report
  if (method === 'GET' && seg.length === 3 && seg[0] === 'mock-exams' && seg[2] === 'report') {
    return getReport(ctx, seg[1]);
  }

  // /exam-profiles/:id/mock-exams
  if (
    method === 'GET' &&
    seg.length === 3 &&
    seg[0] === 'exam-profiles' &&
    seg[2] === 'mock-exams'
  ) {
    return listMockExams(ctx, seg[1]);
  }

  return null;
}

/** DELETE /mock-exams/:id —— 软删（需 base_version）。 */
async function deleteMockExam(ctx, id) {
  // 同 submit：readBaseVersion 抛异常而非返回 {error}
  let baseVersion;
  try {
    baseVersion = readBaseVersion(ctx.body ?? {});
  } catch (e) {
    return mapError(e);
  }
  try {
    const row = await run(ctx, (repo, client) => repo.archive(client, id, baseVersion));
    return ok({ mock_exam: publicMockExam(row) });
  } catch (e) {
    return mapError(e);
  }
}

