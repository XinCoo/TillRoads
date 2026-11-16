// server/index.test.mjs
// 题路 TillRoad · BE-01 第 4 步：路由层「本机可跑」的 fake 层测试（决策 13）
//
// 为什么要有这一份：
//   四表端点接 PG 后，它们的**成功路径**只能连真库验证（见 index.integration.test.mjs）。
//   但「路由分发对不对、入参解析对不对、base_version 缺失是否 400、409 body 是否两种形状」
//   这些逻辑与数据库无关 —— 用 fake 就能验，且 CI 与本机都能跑。
//   决策 13 的底线：不能因为切 PG 就让本机测试从 74 条掉到 58 条。
//
// 这一份**不连 PG**（不设 RUN_PG_INTEGRATION 也能跑），因此：
//   - 需要 DB 的成功路径（建目标/建科目/查树）只做「参数没走到 DB 就被拒」的负向断言；
//   - 正向断言留给 integration 那份。

import test from 'node:test';
import assert from 'node:assert/strict';

import { createApp } from './index.mjs';
import { httpError, readBody } from './routes/_http.mjs';
import { conflictError } from './repositories/base.mjs';
import { duplicateError, notFoundError, validationError } from './repositories/_common.mjs';

/** 起一个监听 0 端口的 app，返回 { base, app }。 */
async function startServer(options) {
  const app = createApp(options);
  await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
  const { port } = app.server.address();
  return { base: `http://127.0.0.1:${port}`, app };
}

/** 极简请求封装，返回 {status, data, headers}。 */
async function req(base, method, path, body) {
  const init = { method };
  if (body !== undefined) {
    init.headers = { 'Content-Type': 'application/json' };
    init.body = JSON.stringify(body);
  }
  const res = await fetch(base + path, init);
  const text = await res.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  return { status: res.status, data, headers: res.headers };
}

/** 建一张 ANALYZED 缺陷单（内存态，无需 PG）。 */
async function newAnalyzed(base, extra = {}) {
  const r = await req(base, 'POST', '/defect-tickets', {
    user_id: 'u-1',
    exam_profile_id: 'ep-1',
    error_layer: 'concept',
    error_cause: '把充分条件当成必要条件导致判断错误',
    ...extra,
  });
  assert.equal(r.status, 201, JSON.stringify(r.data));
  return r.data.id;
}

async function toActionDone(base, id, extra = {}) {
  const r = await req(base, 'POST', `/defect-tickets/${id}/action`, { action: '重做同类题 10 道', ...extra });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  return r.data;
}

// ---------------------------------------------------------------------------
// 1) 健康检查与基础契约
// ---------------------------------------------------------------------------

test('GET /health -> 200 {status:ok} 且 Content-Type 正确', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const r = await req(base, 'GET', '/health');
  assert.equal(r.status, 200);
  assert.equal(r.data.status, 'ok');
  assert.match(r.headers.get('content-type') || '', /application\/json;\s*charset=utf-8/);
});

test('未知路由 -> 404 {error:not_found}；尾部斜杠等价', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const r1 = await req(base, 'GET', '/no-such-thing');
  assert.equal(r1.status, 404);
  assert.deepEqual(r1.data, { error: 'not_found' });

  // 第 4 步 index.mjs 新增：/health/ 与 /health 等价
  const r2 = await req(base, 'GET', '/health/');
  assert.equal(r2.status, 200);
});

// ---------------------------------------------------------------------------
// 2) 路由分发：长路径优先（第 4 步新增的挂载顺序约束）
// ---------------------------------------------------------------------------

test('路由分发：/subjects/:id/knowledge-tree 归 knowledge_nodes 模块，不被 subjects 抢走', async (t) => {
  const fakePool = {
    async query() {
      // 只验证「打到哪条 SQL 形状」，不验证内容
      return { rows: [], rowCount: 0 };
    },
  };
  const { base, app } = await startServer({ pool: fakePool });
  t.after(() => app.close());

  const r = await req(base, 'GET', '/subjects/sub-1/knowledge-tree');
  assert.equal(r.status, 200);
  assert.deepEqual(r.data, { items: [] });
});

// ---------------------------------------------------------------------------
// 3) base_version 强制（决策 8）—— 四表 PATCH/DELETE 缺失即 400，且不触达 DB
// ---------------------------------------------------------------------------

test('base_version 缺失 -> 400 INVALID_BASE_VERSION（四表 PATCH，不触达 DB）', async (t) => {
  // pool 故意设为 undefined：若这些请求真的走到 DB，会 500 而不是 400，
  // 从而证明 400 是在路由层就给出的。
  const { base, app } = await startServer();
  t.after(() => app.close());

  const cases = [
    ['PATCH', '/exam-profiles/ep-1', { target_score: 80 }],
    ['PATCH', '/subjects/sub-1', { name: '新名字' }],
    ['PATCH', '/knowledge-nodes/kn-1', { title: '新标题' }],
    ['PATCH', '/capability-layers/cl-1', { name: '新模板名' }],
  ];
  for (const [method, path, body] of cases) {
    const r = await req(base, method, path, body);
    assert.equal(r.status, 400, `${method} ${path} 应为 400，实际 ${r.status}`);
    assert.equal(r.data.error, 'INVALID_BASE_VERSION', `${method} ${path}`);
  }
});

test('base_version 非正整数 -> 400 INVALID_BASE_VERSION（0 / -1 / 1.5 / 字符串）', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  for (const bad of [0, -1, 1.5, 'abc', null]) {
    const r = await req(base, 'PATCH', '/exam-profiles/ep-1', { target_score: 80, version: bad });
    assert.equal(r.status, 400, `version=${JSON.stringify(bad)} 应为 400`);
    assert.equal(r.data.error, 'INVALID_BASE_VERSION');
  }
});

test('base_version 缺失 -> DELETE 也 400（四表）', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  for (const path of ['/exam-profiles/ep-1', '/subjects/sub-1', '/knowledge-nodes/kn-1', '/capability-layers/cl-1']) {
    const r = await req(base, 'DELETE', path, {});
    assert.equal(r.status, 400, `DELETE ${path}`);
    assert.equal(r.data.error, 'INVALID_BASE_VERSION');
  }
});

// ---------------------------------------------------------------------------
// 4) 入参缺失（FK）与结构校验 400 —— 都在触达 DB 之前
// ---------------------------------------------------------------------------

test('POST /subjects 缺 exam_profile_id -> 400 missing_exam_profile_id', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const r = await req(base, 'POST', '/subjects', { name: '行测', kind: 'objective' });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'missing_exam_profile_id');
});

test('POST /knowledge-nodes 缺 subject_id -> 400 missing_subject_id', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const r = await req(base, 'POST', '/knowledge-nodes', { title: '函数与导数' });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'missing_subject_id');
});

test('POST /capability-layers 缺 layers -> 400 LAYERS_REQUIRED（create 模式必填）', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const r = await req(base, 'POST', '/capability-layers', { name: '三层模板' });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'LAYERS_REQUIRED');
});

test('POST /exam-profiles 缺 exam_date/daily_minutes -> 400 MISSING_REQUIRED_FIELD（AC-EXAM-01）', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const r = await req(base, 'POST', '/exam-profiles', {
    user_id: 'u-1',
    exam_type: 'postgrad',
    target_score: 80,
    // 故意不给 exam_date / daily_minutes
  });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'MISSING_REQUIRED_FIELD');
  assert.ok(Array.isArray(r.data.fields));
  assert.ok(r.data.fields.includes('exam_date'));
  assert.ok(r.data.fields.includes('daily_minutes'));
});

test('POST /exam-profiles 缺 user_id -> 400 missing_user_id', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const r = await req(base, 'POST', '/exam-profiles', {
    exam_type: 'postgrad',
    target_score: 80,
    exam_date: '2026-12-20',
    daily_minutes: 120,
  });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'missing_user_id');
});

// ---------------------------------------------------------------------------
// 5) 409 统一处理（决策 12）：HTTP 层不重拼，两种 resolution 各自原样透传
// ---------------------------------------------------------------------------

test('httpError：乐观锁冲突 -> 409 client_merge，body 原样透传', () => {
  const err = conflictError({ id: 'x', version: 2 }, 1);
  const out = httpError(err);
  assert.equal(out.status, 409);
  assert.deepEqual(out.body, {
    error: 'conflict',
    current: { id: 'x', version: 2 },
    incoming: 1,
    resolution: 'client_merge',
  });
});

test('httpError：查重冲突 -> 409 user_choice，带 field 与 current', () => {
  const err = duplicateError('name', { id: 's2', name: '行测' }, { name: '行测' });
  const out = httpError(err);
  assert.equal(out.status, 409);
  assert.equal(out.body.error, 'conflict');
  assert.equal(out.body.field, 'name');
  assert.equal(out.body.resolution, 'user_choice');
  assert.equal(out.body.current.id, 's2');
});

test('httpError：404 / 400 / 未知错误三种映射', () => {
  assert.deepEqual(httpError(notFoundError('subject', 'abc')), {
    status: 404,
    body: { error: 'not_found', resource: 'subject', id: 'abc' },
  });

  const v = validationError({ ok: false, code: 'INVALID_EXAM_TYPE', message: 'bad' });
  const out400 = httpError(v);
  assert.equal(out400.status, 400);
  assert.equal(out400.body.error, 'INVALID_EXAM_TYPE');

  const boom = new Error('kaboom');
  assert.deepEqual(httpError(boom), { status: 500, body: { error: 'internal' } });
});

test('httpError：PG SQLSTATE 一律 500，绝不当成客户端 400（CI 40P01 死锁事故）', () => {
  // 40P01 = deadlock_detected（CI 上真实发生过：被 httpError 降成 400 {error:'40P01'}，
  //   看起来很像是客户端参数错，实际上是并发故障该重试）。
  const deadlock = Object.assign(new Error('deadlock detected'), { code: '40P01' });
  assert.deepEqual(httpError(deadlock), { status: 500, body: { error: 'internal' } });

  // 40001 = serialization_failure 同理（可重试的并发失败）
  const serialization = Object.assign(new Error('could not serialize access'), { code: '40001' });
  assert.deepEqual(httpError(serialization), { status: 500, body: { error: 'internal' } });

  // 连接类错误（08 类）也不该泄成 400
  const conn = Object.assign(new Error('connection terminated'), { code: '08006' });
  assert.deepEqual(httpError(conn), { status: 500, body: { error: 'internal' } });

  // mapPgError 映射过的错误带 sqlState，同时也有 statusCode+body，应优先走 statusCode 分支
  const mapped = Object.assign(new Error('fk'), {
    code: 'foreign_key_not_found',
    sqlState: '23503',
    statusCode: 404,
    body: { error: 'not_found', resource: 'subject', id: 'x' },
  });
  assert.equal(httpError(mapped).status, 404);

  // 应用层业务码（不是 5 位大写）继续走 400，不能因为上面的规则被误伤
  const appCode = Object.assign(new Error('bad stage'), { code: 'INVALID_VERIFICATION_STAGE' });
  assert.deepEqual(httpError(appCode), { status: 400, body: { error: 'INVALID_VERIFICATION_STAGE' } });
});

test('readBody：非对象顶层 / 坏 JSON 分别 400', async () => {
  function fakeReq(text) {
    return {
      on(ev, cb) {
        if (ev === 'data') cb(Buffer.from(text));
        if (ev === 'end') cb();
        return this;
      },
    };
  }
  await assert.rejects(() => readBody(fakeReq('null')), /INVALID_BODY|must be a JSON object/);
  await assert.rejects(() => readBody(fakeReq('[]')), /INVALID_BODY|must be a JSON object/);
  await assert.rejects(() => readBody(fakeReq('{bad')), /INVALID_JSON|invalid json/);
  assert.deepEqual(await readBody(fakeReq('')), {});
});

// ---------------------------------------------------------------------------
// 6) 缺陷单状态机（BE-03/04 范围，当前内存态）—— 保持既有契约不被第 4 步破坏
// ---------------------------------------------------------------------------

test('缺陷单全链路：ANALYZED -> ACTION_DONE -> V1 -> V2 -> V3 -> CLOSED', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const id = await newAnalyzed(base);
  let tk = await toActionDone(base, id);
  assert.equal(tk.status, 'ACTION_DONE');

  let r = await req(base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'pass', type: 'redo_hidden' });
  assert.equal(r.status, 201);
  assert.equal(r.data.ticket.status, 'V2');

  r = await req(base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V2', result: 'pass', type: 'variant' });
  assert.equal(r.status, 201);
  assert.equal(r.data.ticket.status, 'V3');

  r = await req(base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V3', result: 'pass', type: 'timed_mock' });
  assert.equal(r.status, 201);
  assert.equal(r.data.ticket.status, 'CLOSED');
  assert.ok(r.data.ticket.closed_at);
});

test('ACTION_DONE 不能直接 CLOSED（非法迁移 400）', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const id = await newAnalyzed(base);
  await toActionDone(base, id);

  const r1 = await req(base, 'POST', `/defect-tickets/${id}/close`, {});
  assert.equal(r1.status, 400);
  assert.equal(r1.data.error, 'ILLEGAL_DEFECT_TRANSITION');

  const r2 = await req(base, 'PATCH', `/defect-tickets/${id}`, { status: 'CLOSED' });
  assert.equal(r2.status, 400);
  assert.equal(r2.data.error, 'ILLEGAL_DEFECT_TRANSITION');
});

test('验证 fail -> REOPENED 且 reopen_count +1', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const id = await newAnalyzed(base);
  await toActionDone(base, id);

  // 注意：fail 只能在「正处于该 stage」时提交 —— ACTION_DONE 不是 V1。
  // 所以走 V1 pass（->V2）再在 V2 上 fail（->REOPENED），这才是真实用户路径。
  const v1 = await req(base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'pass' });
  assert.equal(v1.status, 201);
  assert.equal(v1.data.ticket.status, 'V2');

  const r = await req(base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V2', result: 'fail' });
  assert.equal(r.status, 201);
  assert.equal(r.data.ticket.status, 'REOPENED');
  assert.equal(r.data.ticket.reopen_count, 1);
});

test('ACTION_DONE 直接提交 V1 fail -> 400（阶段不匹配，必须先 beginVerification）', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const id = await newAnalyzed(base);
  await toActionDone(base, id);

  const r = await req(base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'fail' });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'INVALID_VERIFICATION_STAGE');
});

test('REOPENED 再 analyze -> verification_round 2，且新 round 可重新提交 V1', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const id = await newAnalyzed(base);
  await toActionDone(base, id);
  // 先 V1 pass 进入 V2，才能在 V2 上 fail -> REOPENED（ACTION_DONE 不能直接 fail）。
  await req(base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'pass' });
  const failed = await req(base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V2', result: 'fail' });
  assert.equal(failed.status, 201);
  assert.equal(failed.data.ticket.status, 'REOPENED');

  const a = await req(base, 'POST', `/defect-tickets/${id}/analyze`, {
    error_layer: 'method',
    error_cause: '解题步骤缺少边界条件检查',
  });
  assert.equal(a.status, 200, JSON.stringify(a.data));
  assert.equal(a.data.status, 'ANALYZED');
  assert.equal(a.data.verification_round, 2);

  await toActionDone(base, id);
  const v = await req(base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'pass' });
  assert.equal(v.status, 201, JSON.stringify(v.data));
  assert.equal(v.data.verification.round, 2);
});

test('禁用语 -> 400 forbidden_phrase', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const r = await req(base, 'POST', '/defect-tickets', {
    user_id: 'u-1',
    error_layer: 'concept',
    error_cause: '我粗心了',
  });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'forbidden_phrase');
});

test('缺 error_layer/error_cause -> 400 missing_error_layer_or_cause', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const r = await req(base, 'POST', '/defect-tickets', { user_id: 'u-1', error_cause: '边界条件没检查' });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'missing_error_layer_or_cause');
});

test('DRAFT 草稿可未归因建单，再 analyze 补齐', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const d = await req(base, 'POST', '/defect-tickets', { user_id: 'u-1', draft: true });
  assert.equal(d.status, 201);
  assert.equal(d.data.status, 'DRAFT');

  const a = await req(base, 'POST', `/defect-tickets/${d.data.id}/analyze`, {
    error_layer: 'concept',
    error_cause: '把充分条件当成必要条件',
  });
  assert.equal(a.status, 200);
  assert.equal(a.data.status, 'ANALYZED');
});

test('actor=ai + pass -> 403 ai_cannot_close（仅用户可关单）', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const id = await newAnalyzed(base);
  await toActionDone(base, id);

  const r = await req(base, 'POST', `/defect-tickets/${id}/verifications`, {
    stage: 'V1',
    result: 'pass',
    actor: 'ai',
  });
  assert.equal(r.status, 403);
  assert.equal(r.data.error, 'ai_cannot_close');
});

test('非法阶段/结果 -> 400', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const id = await newAnalyzed(base);
  await toActionDone(base, id);

  const r1 = await req(base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V9', result: 'pass' });
  assert.equal(r1.status, 400);
  assert.equal(r1.data.error, 'INVALID_VERIFICATION_STAGE');

  const r2 = await req(base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'maybe' });
  assert.equal(r2.status, 400);
  assert.equal(r2.data.error, 'INVALID_VERIFICATION_RESULT');
});

test('缺陷单乐观锁：version 显式不符 -> 409 client_merge', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const id = await newAnalyzed(base);
  const r1 = await req(base, 'PATCH', `/defect-tickets/${id}`, { version: 1, reopen_reason: '先记一笔' });
  assert.equal(r1.status, 200);
  assert.equal(r1.data.version, 2);

  const r2 = await req(base, 'PATCH', `/defect-tickets/${id}`, { version: 1, reopen_reason: '再改' });
  assert.equal(r2.status, 409);
  assert.deepEqual(r2.data, { error: 'conflict', current: 2, incoming: 1, resolution: 'client_merge' });

  // action 端点同样受乐观锁保护
  await toActionDone(base, id, { version: 2 });
  const r3 = await req(base, 'POST', `/defect-tickets/${id}/action`, { version: 999, action: 'x' });
  assert.equal(r3.status, 409);
});

// ---------------------------------------------------------------------------
// 7) AI 生成 / 模考报告 / 复盘（内存态，保持既有契约）
// ---------------------------------------------------------------------------

test('POST /ai/questions:generate 校验 count 1..20 且返回 provider/model 快照；/ai-jobs 别名同校验', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  for (const bad of [0, 21]) {
    const r = await req(base, 'POST', '/ai/questions:generate', { count: bad });
    assert.equal(r.status, 400);
    assert.equal(r.data.error, 'INVALID_COUNT');
  }

  const okRes = await req(base, 'POST', '/ai/questions:generate', {
    count: 5,
    provider: 'deepseek',
    model: 'deepseek-v4.1-flash',
    knowledge_node_id: 'kn-1',
  });
  assert.equal(okRes.status, 202);
  assert.ok(okRes.data.job_id);
  assert.equal(okRes.data.status, 'pending');
  assert.equal(okRes.data.provider_snapshot, 'deepseek');
  assert.equal(okRes.data.model_snapshot, 'deepseek-v4.1-flash');

  const alias = await req(base, 'POST', '/ai-jobs', { count: 0 });
  assert.equal(alias.status, 400);
  assert.equal(alias.data.error, 'INVALID_COUNT');
});

test('GET /review-cycles 与 GET /mock-exams/:id/report 字段完整', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const id = await newAnalyzed(base);

  const rc = await req(base, 'GET', '/review-cycles?type=weekly');
  assert.equal(rc.status, 200);
  assert.equal(rc.data.type, 'weekly');
  assert.equal(typeof rc.data.closed_count, 'number');
  assert.equal(typeof rc.data.reopened_count, 'number');
  assert.equal(rc.data.new_defects, 1);
  assert.ok(Array.isArray(rc.data.timeline));

  const rep = await req(base, 'GET', `/mock-exams/me-1/report`);
  assert.equal(rep.status, 200);
  assert.equal(rep.data.mock_exam_id, 'me-1');
  assert.ok(Array.isArray(rep.data.by_knowledge_node));
  assert.ok(rep.data.defect_links.some((x) => x.defect_ticket_id === id));
  assert.equal(typeof rep.data.stability_index, 'number');
});

// ---------------------------------------------------------------------------
// 8) 规范契约别名（POST /analyze 与 PATCH /analyze、POST /verifications）
// ---------------------------------------------------------------------------

test('规范契约：POST /analyze 与 POST /verifications 可用，PATCH /analyze 为兼容别名', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  // POST /analyze
  const d1 = await req(base, 'POST', '/defect-tickets', { user_id: 'u-1', draft: true });
  const a1 = await req(base, 'POST', `/defect-tickets/${d1.data.id}/analyze`, {
    error_layer: 'concept',
    error_cause: '概念混淆',
  });
  assert.equal(a1.status, 200);
  assert.equal(a1.data.status, 'ANALYZED');

  // PATCH /analyze 别名
  const d2 = await req(base, 'POST', '/defect-tickets', { user_id: 'u-1', draft: true });
  const a2 = await req(base, 'PATCH', `/defect-tickets/${d2.data.id}/analyze`, {
    error_layer: 'method',
    error_cause: '步骤缺失',
  });
  assert.equal(a2.status, 200);
  assert.equal(a2.data.status, 'ANALYZED');

  // POST /verifications 规范路径（body 带 defect_ticket_id）
  const id = await newAnalyzed(base);
  await toActionDone(base, id);
  const v = await req(base, 'POST', '/verifications', {
    defect_ticket_id: id,
    stage: 'V1',
    result: 'pass',
  });
  assert.equal(v.status, 201, JSON.stringify(v.data));
  assert.equal(v.data.ticket.status, 'V2');
  assert.equal(v.data.verification.round, 1);
});

// ---------------------------------------------------------------------------
// 9) 题目导入的请求体/内容错误（fake 层，不需要 PG）
//
// 这四个 400 都在碰数据库之前就返回，所以不注入 pool 也能验。
// 它们是 CI 真跑时才暴露的两条缺陷的回归用例：
//   ① 空文件被误报成 MISSING_CONTENT（把「字段缺失」与「文件 0 字节」混为一读）
//   ② 切不出题时 message 在 httpError 里被丢掉（裸 Error 只有 code，没有 body）
// ---------------------------------------------------------------------------

test('POST /questions/import：空文件 -> 400 EMPTY_CONTENT（不是 MISSING_CONTENT）', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const r = await req(base, 'POST', '/questions/import', {
    filename: 'empty.txt',
    mime: 'text/plain',
    content_base64: '',
  });
  assert.equal(r.status, 400, JSON.stringify(r.data));
  assert.equal(r.data.error, 'EMPTY_CONTENT');
  assert.ok(typeof r.data.message === 'string' && r.data.message.length > 0, '空文件也要带提示文案');

  // 反向对照：字段真的缺了才是 MISSING_CONTENT
  const missing = await req(base, 'POST', '/questions/import', { filename: 'a.txt', mime: 'text/plain' });
  assert.equal(missing.status, 400, JSON.stringify(missing.data));
  assert.equal(missing.data.error, 'MISSING_CONTENT');
});

test('POST /questions/import：切不出题 -> 400 EMPTY_CONTENT，且 message 列出四类分隔符', async (t) => {
  const { base, app } = await startServer();
  t.after(() => app.close());

  const text = '这是一份没有任何题号的说明文档。\n只有几段普通文字，没有编号、没有选项。\n';
  const r = await req(base, 'POST', '/questions/import', {
    filename: 'no-separator.txt',
    mime: 'text/plain',
    content_base64: Buffer.from(text, 'utf8').toString('base64'),
  });

  assert.equal(r.status, 400, JSON.stringify(r.data));
  assert.equal(r.data.error, 'EMPTY_CONTENT');
  // 关键回归：message 必须出现在响应体里（裸 Error 的 message 会被 httpError 丢掉）
  assert.ok(
    typeof r.data.message === 'string' && r.data.message.includes('第1题'),
    `message 应列出可用的分隔符：${JSON.stringify(r.data.message)}`,
  );
  assert.ok(r.data.message.includes('（1）') && r.data.message.includes('一、'), '四类分隔符都要提到');
});
