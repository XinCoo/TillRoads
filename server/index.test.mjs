// server/index.test.mjs
// 题路 TillRoad · BE-01 第 4 步 / BE-03 T6：路由层「本机可跑」的 fake 层测试
//
// 为什么要有这一份：
//   四表与缺陷单端点接 PG 后，它们的**成功路径**只能连真库验证
//   （index.integration.test.mjs / routes/defect_tickets.integration.test.mjs）。
//   但「路由分发对不对、入参解析对不对、base_version 缺失是否 400、409 body 是否两种形状、
//   actor=ai 是否 403、状态机能否按 core 流转」这些逻辑与数据库无关 —— 用 fake 就能验，
//   且 CI 与本机都能跑。决策 13 的底线：不能因为切 PG 就让本机测试从 74 条掉下来。
//
// BE-03：缺陷单注入内存 fake 仓储（server/_fake_repos.mjs），忠实复刻三个 PG 仓储的语义
//   （core 纯函数前置校验 + 触发器派生列模拟 + 乐观锁）。全链路的真库验证放集成层。
//
// 这一份**不连 PG**（不设 RUN_PG_INTEGRATION 也能跑）。

import test from 'node:test';
import assert from 'node:assert/strict';

import { createApp } from './index.mjs';
import { httpError, readBody } from './routes/_http.mjs';
import { conflictError } from './repositories/base.mjs';
import { duplicateError, notFoundError, validationError } from './repositories/_common.mjs';
import { createFakeRepos } from './_fake_repos.mjs';

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

/** 起一个注入了 fake 缺陷单仓储的 app。 */
async function startDefectServer(t) {
  const { base, app } = await startServer({ repos: createFakeRepos() });
  t.after(() => app.close());
  return base;
}

/** 建一张 ANALYZED 缺陷单（fake 仓储）。 */
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

/** 读当前缺陷单（回带 verifications/actions）。 */
async function getTicket(base, id) {
  const r = await req(base, 'GET', `/defect-tickets/${id}`);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  return r.data;
}

/**
 * 走拍板项 4 的手动「进入验证」流程：
 *   ANALYZED --加 action--> mark done --> PATCH begin-verification --> V1
 * 返回推进后的 ticket（status='V1'）。
 */
async function toV1(base, id, { action = '重做同类题 10 道' } = {}) {
  const a = await req(base, 'POST', `/defect-tickets/${id}/actions`, { action });
  assert.equal(a.status, 201, JSON.stringify(a.data));
  const m = await req(base, 'PATCH', `/defect-tickets/${id}/actions/${a.data.id}`, { version: a.data.version });
  assert.equal(m.status, 200, JSON.stringify(m.data));
  const t = await getTicket(base, id);
  const b = await req(base, 'PATCH', `/defect-tickets/${id}/begin-verification`, { version: t.version });
  assert.equal(b.status, 200, JSON.stringify(b.data));
  return b.data;
}

/** 提交验证（自动带上当前 ticket version，满足拍板项 5 的 base_version 强制）。 */
async function submitVer(base, id, body) {
  const t = await getTicket(base, id);
  return req(base, 'POST', `/defect-tickets/${id}/verifications`, { ...body, version: t.version });
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

  const r2 = await req(base, 'GET', '/health/');
  assert.equal(r2.status, 200);
});

// ---------------------------------------------------------------------------
// 2) 路由分发：长路径优先
// ---------------------------------------------------------------------------

test('路由分发：/subjects/:id/knowledge-tree 归 knowledge_nodes 模块，不被 subjects 抢走', async (t) => {
  const fakePool = {
    async query() {
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
// 3) base_version 强制（决策 8 / 拍板项 5）—— 缺失即 400，且不触达 DB
// ---------------------------------------------------------------------------

test('base_version 缺失 -> 400 INVALID_BASE_VERSION（四表 PATCH，不触达 DB）', async (t) => {
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

test('缺陷单 PATCH/DELETE/迁移端点 base_version 缺失 -> 400 INVALID_BASE_VERSION', async (t) => {
  const base = await startDefectServer(t);
  const id = await newAnalyzed(base);

  const cases = [
    ['PATCH', `/defect-tickets/${id}`, { q_type: 'choice' }],
    ['DELETE', `/defect-tickets/${id}`, {}],
    ['POST', `/defect-tickets/${id}/analyze`, { error_layer: 'concept', error_cause: '归因' }],
    ['PATCH', `/defect-tickets/${id}/reanalyze`, { error_layer: 'concept', error_cause: '归因' }],
    ['POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'pass' }],
  ];
  for (const [method, path, body] of cases) {
    const r = await req(base, method, path, body);
    assert.equal(r.status, 400, `${method} ${path} 应为 400，实际 ${r.status} ${JSON.stringify(r.data)}`);
    assert.equal(r.data.error, 'INVALID_BASE_VERSION', `${method} ${path}`);
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
  const deadlock = Object.assign(new Error('deadlock detected'), { code: '40P01' });
  assert.deepEqual(httpError(deadlock), { status: 500, body: { error: 'internal' } });

  const serialization = Object.assign(new Error('could not serialize access'), { code: '40001' });
  assert.deepEqual(httpError(serialization), { status: 500, body: { error: 'internal' } });

  const conn = Object.assign(new Error('connection terminated'), { code: '08006' });
  assert.deepEqual(httpError(conn), { status: 500, body: { error: 'internal' } });

  const mapped = Object.assign(new Error('fk'), {
    code: 'foreign_key_not_found',
    sqlState: '23503',
    statusCode: 404,
    body: { error: 'not_found', resource: 'subject', id: 'x' },
  });
  assert.equal(httpError(mapped).status, 404);

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
// 6) 缺陷单状态机（BE-03：fake repository 注入，验证路由层逻辑 + core 流转）
// ---------------------------------------------------------------------------

test('缺陷单全链路：ANALYZED -> V1 -> V2 -> V3 -> CLOSED', async (t) => {
  const base = await startDefectServer(t);
  const id = await newAnalyzed(base);

  const v1 = await toV1(base, id);
  assert.equal(v1.status, 'V1');

  let r = await submitVer(base, id, { stage: 'V1', result: 'pass', type: 'redo_hidden' });
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.ticket.status, 'V2');

  r = await submitVer(base, id, { stage: 'V2', result: 'pass', type: 'variant' });
  assert.equal(r.status, 201);
  assert.equal(r.data.ticket.status, 'V3');

  r = await submitVer(base, id, { stage: 'V3', result: 'pass', type: 'timed_mock' });
  assert.equal(r.status, 201);
  assert.equal(r.data.ticket.status, 'CLOSED');
  assert.ok(r.data.ticket.closed_at);
});

test('ACTION_DONE 不能直接 CLOSED（POST /close 守卫 400；通用 PATCH 忽略 status 不迁移）', async (t) => {
  const base = await startDefectServer(t);
  const id = await newAnalyzed(base);

  const r1 = await req(base, 'POST', `/defect-tickets/${id}/close`, {});
  assert.equal(r1.status, 400);
  assert.equal(r1.data.error, 'ILLEGAL_DEFECT_TRANSITION');

  // 通用 PATCH 不接受 status 字段（被忽略），状态保持不变——证明不能绕过状态机。
  const cur = await getTicket(base, id);
  const r2 = await req(base, 'PATCH', `/defect-tickets/${id}`, { status: 'CLOSED', version: cur.version });
  assert.equal(r2.status, 200);
  assert.equal((await getTicket(base, id)).status, 'ANALYZED');
});

test('验证 fail -> REOPENED 且 reopen_count +1', async (t) => {
  const base = await startDefectServer(t);
  const id = await newAnalyzed(base);
  await toV1(base, id);

  // fail 只能在「正处于该 stage」提交：先 V1 pass（->V2）再在 V2 上 fail（->REOPENED）。
  const v1 = await submitVer(base, id, { stage: 'V1', result: 'pass' });
  assert.equal(v1.status, 201);
  assert.equal(v1.data.ticket.status, 'V2');

  const r = await submitVer(base, id, { stage: 'V2', result: 'fail' });
  assert.equal(r.status, 201);
  assert.equal(r.data.ticket.status, 'REOPENED');
  assert.equal(r.data.ticket.reopen_count, 1);
});

test('非当前阶段直接提交 V1 fail -> 400（阶段不匹配）', async (t) => {
  const base = await startDefectServer(t);
  const id = await newAnalyzed(base);

  // ANALYZED 尚未进入 V1，直接提交 V1 fail 应被 core 判定阶段不匹配。
  const r = await submitVer(base, id, { stage: 'V1', result: 'fail' });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'INVALID_VERIFICATION_STAGE');
});

test('REOPENED 再 analyze -> verification_round 2，且新 round 可重新提交 V1', async (t) => {
  const base = await startDefectServer(t);
  const id = await newAnalyzed(base);
  await toV1(base, id);
  await submitVer(base, id, { stage: 'V1', result: 'pass' });
  const failed = await submitVer(base, id, { stage: 'V2', result: 'fail' });
  assert.equal(failed.status, 201);
  assert.equal(failed.data.ticket.status, 'REOPENED');

  const cur = await getTicket(base, id);
  const a = await req(base, 'POST', `/defect-tickets/${id}/analyze`, {
    error_layer: 'method',
    error_cause: '解题步骤缺少边界条件检查',
    version: cur.version,
  });
  assert.equal(a.status, 200, JSON.stringify(a.data));
  assert.equal(a.data.status, 'ANALYZED');
  assert.equal(a.data.verification_round, 2);

  await toV1(base, id);
  const v = await submitVer(base, id, { stage: 'V1', result: 'pass' });
  assert.equal(v.status, 201, JSON.stringify(v.data));
  assert.equal(v.data.verification.round, 2);
});

test('禁用语 -> 400 forbidden_phrase', async (t) => {
  const base = await startDefectServer(t);
  const r = await req(base, 'POST', '/defect-tickets', {
    user_id: 'u-1',
    exam_profile_id: 'ep-1',
    error_layer: 'concept',
    error_cause: '我粗心了',
  });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'forbidden_phrase');
});

test('缺 error_layer/error_cause -> 400 missing_error_layer_or_cause', async (t) => {
  const base = await startDefectServer(t);
  const r = await req(base, 'POST', '/defect-tickets', { user_id: 'u-1', exam_profile_id: 'ep-1', error_cause: '边界条件没检查' });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'missing_error_layer_or_cause');
});

test('DRAFT 草稿可未归因建单，再 analyze 补齐', async (t) => {
  const base = await startDefectServer(t);
  const d = await req(base, 'POST', '/defect-tickets', { user_id: 'u-1', exam_profile_id: 'ep-1', draft: true });
  assert.equal(d.status, 201);
  assert.equal(d.data.status, 'DRAFT');

  const a = await req(base, 'POST', `/defect-tickets/${d.data.id}/analyze`, {
    error_layer: 'concept',
    error_cause: '把充分条件当成必要条件',
    version: d.data.version,
  });
  assert.equal(a.status, 200);
  assert.equal(a.data.status, 'ANALYZED');
});

test('begin-verification 前置：无 action -> 400 NO_ACTIONS；有未完成 -> 400 ACTIONS_NOT_DONE', async (t) => {
  const base = await startDefectServer(t);

  // 无 action
  const id1 = await newAnalyzed(base);
  let t1 = await getTicket(base, id1);
  let r = await req(base, 'PATCH', `/defect-tickets/${id1}/begin-verification`, { version: t1.version });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'NO_ACTIONS');

  // 有未完成 action
  const id2 = await newAnalyzed(base);
  await req(base, 'POST', `/defect-tickets/${id2}/actions`, { action: '重做同类题' });
  let t2 = await getTicket(base, id2);
  r = await req(base, 'PATCH', `/defect-tickets/${id2}/begin-verification`, { version: t2.version });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'ACTIONS_NOT_DONE');
});

test('actor=ai + pass -> 403 ai_cannot_close（仅用户可关单）', async (t) => {
  const base = await startDefectServer(t);
  const id = await newAnalyzed(base);
  await toV1(base, id);

  const r = await submitVer(base, id, { stage: 'V1', result: 'pass', actor: 'ai' });
  assert.equal(r.status, 403);
  assert.equal(r.data.error, 'ai_cannot_close');
});

test('非法阶段/结果 -> 400', async (t) => {
  const base = await startDefectServer(t);
  const id = await newAnalyzed(base);
  await toV1(base, id);

  const r1 = await submitVer(base, id, { stage: 'V9', result: 'pass' });
  assert.equal(r1.status, 400);
  assert.equal(r1.data.error, 'INVALID_VERIFICATION_STAGE');

  const r2 = await submitVer(base, id, { stage: 'V1', result: 'maybe' });
  assert.equal(r2.status, 400);
  assert.equal(r2.data.error, 'INVALID_VERIFICATION_RESULT');
});

test('缺陷单乐观锁：version 显式不符 -> 409 client_merge', async (t) => {
  const base = await startDefectServer(t);
  const id = await newAnalyzed(base);

  const r1 = await req(base, 'PATCH', `/defect-tickets/${id}`, { version: 1, reopen_reason: '先记一笔' });
  assert.equal(r1.status, 200);
  assert.equal(r1.data.version, 2);

  const r2 = await req(base, 'PATCH', `/defect-tickets/${id}`, { version: 1, reopen_reason: '再改' });
  assert.equal(r2.status, 409);
  assert.deepEqual(r2.data, { error: 'conflict', current: 2, incoming: 1, resolution: 'client_merge' });

  // action 的 markDone 同样受乐观锁保护
  const a = await req(base, 'POST', `/defect-tickets/${id}/actions`, { action: '重做' });
  assert.equal(a.status, 201);
  const wrong = await req(base, 'PATCH', `/defect-tickets/${id}/actions/${a.data.id}`, { version: 999 });
  assert.equal(wrong.status, 409);
  assert.equal(wrong.data.error, 'conflict');
});

// ---------------------------------------------------------------------------
// 7) AI 生成 / 模考报告 / 复盘（AI 仍内存；报告/复盘读 fake 缺陷单）
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

test('GET /review-cycles 字段完整，GET /mock-exams/:id/report 未提交 -> 404 not_submitted', async (t) => {
  const base = await startDefectServer(t);
  const id = await newAnalyzed(base);

  const rc = await req(base, 'GET', '/review-cycles?type=weekly');
  assert.equal(rc.status, 200);
  assert.equal(rc.data.type, 'weekly');
  assert.equal(typeof rc.data.closed_count, 'number');
  assert.equal(typeof rc.data.reopened_count, 'number');
  assert.equal(rc.data.new_defects, 1);
  assert.ok(Array.isArray(rc.data.timeline));

  // BE-05：模考报告已改为真实现（不再是假数据常量）。
  // 本用例只验证「不存在的模考 -> 404」，真报告的字段形状由
  // mock_report.test.mjs（纯函数 22 条）与 mock_exams.integration.test.mjs（真 PG）覆盖。
  const rep = await req(base, 'GET', '/mock-exams/me-does-not-exist/report');
  assert.equal(rep.status, 404);
  assert.equal(rep.data.error, 'not_found');
  void id;
});

// ---------------------------------------------------------------------------
// 8) 规范契约别名（POST /analyze 与 PATCH /analyze、POST /verifications）
// ---------------------------------------------------------------------------

test('规范契约：POST /analyze 与 PATCH /analyze 别名可用，POST /verifications 可用', async (t) => {
  const base = await startDefectServer(t);

  // POST /analyze
  const d1 = await req(base, 'POST', '/defect-tickets', { user_id: 'u-1', exam_profile_id: 'ep-1', draft: true });
  const a1 = await req(base, 'POST', `/defect-tickets/${d1.data.id}/analyze`, {
    error_layer: 'concept',
    error_cause: '概念混淆',
    version: d1.data.version,
  });
  assert.equal(a1.status, 200);
  assert.equal(a1.data.status, 'ANALYZED');

  // PATCH /analyze 别名
  const d2 = await req(base, 'POST', '/defect-tickets', { user_id: 'u-1', exam_profile_id: 'ep-1', draft: true });
  const a2 = await req(base, 'PATCH', `/defect-tickets/${d2.data.id}/analyze`, {
    error_layer: 'method',
    error_cause: '步骤缺失',
    version: d2.data.version,
  });
  assert.equal(a2.status, 200);
  assert.equal(a2.data.status, 'ANALYZED');

  // POST /verifications 规范路径（body 带 defect_ticket_id）
  const id = await newAnalyzed(base);
  await toV1(base, id);
  const cur = await getTicket(base, id);
  const v = await req(base, 'POST', '/verifications', {
    defect_ticket_id: id,
    stage: 'V1',
    result: 'pass',
    version: cur.version,
  });
  assert.equal(v.status, 201, JSON.stringify(v.data));
  assert.equal(v.data.ticket.status, 'V2');
  assert.equal(v.data.verification.round, 1);
});

// ---------------------------------------------------------------------------
// 9) 题目导入的请求体/内容错误（fake 层，不需要 PG）
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
  assert.ok(
    typeof r.data.message === 'string' && r.data.message.includes('第1题'),
    `message 应列出可用的分隔符：${JSON.stringify(r.data.message)}`,
  );
  assert.ok(r.data.message.includes('（1）') && r.data.message.includes('一、'), '四类分隔符都要提到');
});

// ---------------------------------------------------------------------------
// BE-04：验证任务查询端点（纯读，fake 层验参数解析与 400）
// ---------------------------------------------------------------------------
// 窗口值 / urgency 三态的**数学**已由 server/verify_window.test.mjs 的 13 条纯函数单测覆盖；
// 这里只验「路由层有没有把脏参数拦下来」与「注入 fake 后能否正确转发」。
// 真库的 JOIN / 进入时间推断放集成层（routes/verification_tasks.integration.test.mjs）。

test('GET /users/:id/verification-tasks：非法 stage -> 400 INVALID_STAGE', async (t) => {
  const base = await startDefectServer(t);
  for (const bad of ['V4', 'v1', 'V9']) {
    const r = await req(base, 'GET', `/users/u-1/verification-tasks?status=${bad}`);
    assert.equal(r.status, 400, `status=${bad} 应 400`);
    assert.equal(r.data.error, 'INVALID_STAGE');
    assert.ok(typeof r.data.message === 'string' && r.data.message.includes('V1'), 'message 应列出合法值');
  }
});

test('GET /users/:id/verification-tasks：非法 urgency -> 400 INVALID_URGENCY', async (t) => {
  const base = await startDefectServer(t);
  for (const bad of ['urgent', 'OVERDUE', 'late']) {
    const r = await req(base, 'GET', `/users/u-1/verification-tasks?urgency=${bad}`);
    assert.equal(r.status, 400, `urgency=${bad} 应 400`);
    assert.equal(r.data.error, 'INVALID_URGENCY');
    assert.ok(r.data.message.includes('overdue'), 'message 应列出合法值');
  }
});

test('GET /users/:id/verification-tasks：合法参数 -> 200，返回 items/total/limit/offset', async (t) => {
  const base = await startDefectServer(t);
  const r = await req(base, 'GET', '/users/u-1/verification-tasks');
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.ok(Array.isArray(r.data.items));
  assert.equal(typeof r.data.total, 'number');
  assert.equal(typeof r.data.limit, 'number');
  assert.equal(typeof r.data.offset, 'number');
});

test('GET /users/:id/verification-tasks：逗号分隔多值可接受、重复值去重不报错', async (t) => {
  const base = await startDefectServer(t);
  const r = await req(base, 'GET', '/users/u-1/verification-tasks?status=V1,V2,V1&urgency=overdue,due_soon');
  assert.equal(r.status, 200, JSON.stringify(r.data));
});

test('GET /users/:id/verification-summary：返回 by_stage / by_urgency / 三个计数', async (t) => {
  const base = await startDefectServer(t);
  const r = await req(base, 'GET', '/users/u-1/verification-summary');
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(typeof r.data.total, 'number');
  assert.deepEqual(Object.keys(r.data.by_stage).sort(), ['V1', 'V2', 'V3']);
  assert.deepEqual(Object.keys(r.data.by_urgency).sort(), ['due_soon', 'normal', 'overdue']);
  assert.equal(typeof r.data.overdue, 'number');
  assert.equal(typeof r.data.due_soon, 'number');
  assert.equal(typeof r.data.normal, 'number');
});

test('BE-04 端点只读：POST/PATCH/DELETE 一律落 404（不暴露写入口）', async (t) => {
  const base = await startDefectServer(t);
  for (const method of ['POST', 'PATCH', 'DELETE']) {
    const r = await req(base, method, '/users/u-1/verification-tasks', {});
    assert.equal(r.status, 404, `${method} 应 404（BE-04 纯查询）`);
    assert.equal(r.data.error, 'not_found');
  }
});

test('GET /users/:id/verification-tasks：空结果时 items 为空数组且 total=0', async (t) => {
  const base = await startDefectServer(t);
  const r = await req(base, 'GET', '/users/u-9/verification-tasks');
  assert.equal(r.status, 200);
  assert.deepEqual(r.data.items, []);
  assert.equal(r.data.total, 0);
});

test('GET /users/:id/verification-tasks：V1 单子出现在列表中且带 urgency 字段', async (t) => {
  const base = await startDefectServer(t);
  const id = await newAnalyzed(base);
  await toV1(base, id);

  const r = await req(base, 'GET', '/users/u-1/verification-tasks');
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.total, 1, '只有一张 V1 单');
  const row = r.data.items[0];
  assert.equal(row.id, id);
  assert.equal(row.stage, 'V1');
  assert.equal(row.window_days, 7, 'V1 窗口 7 天');
  assert.equal(row.urgency, 'normal', '刚进入 V1 不临期');
  assert.equal(typeof row.days_left, 'number');
  assert.equal(typeof row.entered_at, 'string');
  assert.equal(typeof row.due_at, 'string');
});

test('GET /users/:id/verification-tasks：尚未进入验证的 ANALYZED 不进列表', async (t) => {
  const base = await startDefectServer(t);
  const analyzed = await newAnalyzed(base);
  const act = await req(base, 'POST', `/defect-tickets/${analyzed}/actions`, { action: '重做' });
  await req(base, 'PATCH', `/defect-tickets/${analyzed}/actions/${act.data.id}`, { version: act.data.version });

  const r = await req(base, 'GET', '/users/u-1/verification-tasks');
  assert.equal(r.status, 200);
  assert.equal(r.data.total, 0, 'ANALYZED（尚未 begin-verification）不应出现');
});

test('GET /users/:id/verification-tasks：stage 过滤只返回指定 stage', async (t) => {
  const base = await startDefectServer(t);
  const id1 = await newAnalyzed(base);
  await toV1(base, id1);
  const id2 = await newAnalyzed(base);
  await toV1(base, id2);

  const t2 = await getTicket(base, id2);
  const v2 = await req(base, 'POST', `/defect-tickets/${id2}/verifications`, {
    stage: 'V1', result: 'pass', verify_type: 'redo_hidden', version: t2.version,
  });
  assert.equal(v2.status, 201, JSON.stringify(v2.data));

  const all = await req(base, 'GET', '/users/u-1/verification-tasks');
  assert.equal(all.data.total, 2);

  const onlyV2 = await req(base, 'GET', '/users/u-1/verification-tasks?status=V2');
  assert.equal(onlyV2.data.total, 1);
  assert.equal(onlyV2.data.items[0].id, id2);
  assert.equal(onlyV2.data.items[0].stage, 'V2');
});

test('GET /users/:id/verification-summary：聚合数字与列表一致', async (t) => {
  const base = await startDefectServer(t);
  const id1 = await newAnalyzed(base);
  await toV1(base, id1);
  const id2 = await newAnalyzed(base);
  await toV1(base, id2);

  const s = await req(base, 'GET', '/users/u-1/verification-summary');
  assert.equal(s.status, 200, JSON.stringify(s.data));
  assert.equal(s.data.total, 2);
  assert.equal(s.data.by_stage.V1, 2);
  assert.equal(s.data.by_urgency.normal, 2);
  assert.equal(s.data.overdue, 0);
});

// ---------- BE-05：限时模考 fake 层 ----------

/** 起一个注入了 fake 仓储、且题库已灌好若干题的 app。 */
async function startMockServer(t, { questions = 5 } = {}) {
  const repos = createFakeRepos();
  const rows = [];
  for (let i = 0; i < questions; i += 1) {
    rows.push({
      id: `q-${i + 1}`,
      subject_id: 'sub-1',
      knowledge_node_id: 'kn-1',
      type: 'choice',
      stem: `题干 ${i + 1}`,
      options: [{ key: 'A', text: 'a' }, { key: 'B', text: 'b' }],
      answer: 'A',
      analysis: '解析不应出现在组卷响应里',
      is_subjective: false,
      difficulty: 0.5,
      tags: [],
      deleted_at: null,
    });
  }
  repos.questions.seedRows(rows);
  const { base, app } = await startServer({ repos });
  t.after(() => app.close());
  return base;
}

async function createMock(base, body) {
  const r = await req(base, 'POST', '/mock-exams', {
    exam_profile_id: 'ep-1',
    mode: 'full',
    subject_id: 'sub-1',
    question_count: 3,
    ...body,
  });
  return r;
}

test('POST /mock-exams：组卷成功且不泄题', async (t) => {
  const base = await startMockServer(t);
  const r = await createMock(base);
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.question_count, 3);
  assert.equal(r.data.questions.length, 3);
  // 提交前绝不返回标准答案与解析
  for (const q of r.data.questions) {
    assert.equal(q.answer, undefined);
    assert.equal(q.analysis, undefined);
  }
  // questions jsonb 初始 attempt_id 为 null
  for (const e of r.data.mock_exam.questions) {
    assert.equal(e.attempt_id, null);
    assert.equal(e.is_correct, null);
  }
});

test('POST /mock-exams：题量不足 -> 400 INSUFFICIENT_QUESTIONS 带 available', async (t) => {
  const base = await startMockServer(t, { questions: 2 });
  const r = await createMock(base, { question_count: 5 });
  assert.equal(r.status, 400, JSON.stringify(r.data));
  assert.equal(r.data.error, 'INSUFFICIENT_QUESTIONS');
  assert.equal(r.data.available, 2);
  assert.equal(r.data.requested, 5);
});

test('POST /mock-exams：full 缺 subject_id / module 缺 knowledge_node_id -> 400', async (t) => {
  const base = await startMockServer(t);

  const noSubject = await req(base, 'POST', '/mock-exams', {
    exam_profile_id: 'ep-1',
    mode: 'full',
    question_count: 3,
  });
  assert.equal(noSubject.status, 400, JSON.stringify(noSubject.data));
  assert.equal(noSubject.data.error, 'MISSING_SUBJECT_ID');

  const noNode = await req(base, 'POST', '/mock-exams', {
    exam_profile_id: 'ep-1',
    mode: 'module',
    question_count: 3,
  });
  assert.equal(noNode.status, 400, JSON.stringify(noNode.data));
  assert.equal(noNode.data.error, 'MISSING_KNOWLEDGE_NODE_ID');
});

test('POST /mock-exams/:id/submit：缺 base_version -> 400', async (t) => {
  const base = await startMockServer(t);
  const created = await createMock(base);
  const r = await req(base, 'POST', `/mock-exams/${created.data.mock_exam.id}/submit`, {
    answers: [],
  });
  assert.equal(r.status, 400, JSON.stringify(r.data));
  assert.equal(r.data.error, 'INVALID_BASE_VERSION');
});

test('POST /mock-exams/:id/submit：提交出报告，未提交时读报告 404', async (t) => {
  const base = await startMockServer(t);
  const created = await createMock(base);
  const id = created.data.mock_exam.id;

  const before = await req(base, 'GET', `/mock-exams/${id}/report`);
  assert.equal(before.status, 404, JSON.stringify(before.data));
  assert.equal(before.data.error, 'not_submitted');

  const answers = created.data.questions.map((q) => ({
    question_id: q.id,
    answer_text: 'A',
    duration_ms: 1200,
  }));
  const sub = await req(base, 'POST', `/mock-exams/${id}/submit`, {
    version: created.data.mock_exam.version,
    answers,
  });
  assert.equal(sub.status, 200, JSON.stringify(sub.data));
  assert.equal(sub.data.timed_out, false);
  assert.equal(sub.data.report.strategy_execution, null);
  assert.equal(sub.data.report.overall.total, 3);
  assert.equal(sub.data.report.overall.correct, 3);

  const after = await req(base, 'GET', `/mock-exams/${id}/report`);
  assert.equal(after.status, 200, JSON.stringify(after.data));
  assert.equal(after.data.report.overall.total, 3);
});

test('POST /mock-exams/:id/submit：重复提交 -> 409 already_submitted', async (t) => {
  const base = await startMockServer(t);
  const created = await createMock(base);
  const id = created.data.mock_exam.id;
  const answers = created.data.questions.map((q) => ({ question_id: q.id, answer_text: 'A' }));

  const first = await req(base, 'POST', `/mock-exams/${id}/submit`, {
    version: created.data.mock_exam.version,
    answers,
  });
  assert.equal(first.status, 200, JSON.stringify(first.data));

  const second = await req(base, 'POST', `/mock-exams/${id}/submit`, {
    version: first.data.mock_exam.version,
    answers,
  });
  assert.equal(second.status, 409, JSON.stringify(second.data));
  assert.equal(second.data.error, 'already_submitted');
});

test('POST /mock-exams/:id/submit：超时收卷，未答计错', async (t) => {
  const base = await startMockServer(t);
  const created = await createMock(base, { duration_limit_ms: 60_000 });
  const id = created.data.mock_exam.id;

  // 只答一题，且 submitted_at 推到限时 + 60s 宽限之后
  const late = new Date(Date.now() + 60_000 + 61_000).toISOString();
  const sub = await req(base, 'POST', `/mock-exams/${id}/submit`, {
    version: created.data.mock_exam.version,
    submitted_at: late,
    answers: [{ question_id: created.data.questions[0].id, answer_text: 'A', duration_ms: 1000 }],
  });
  assert.equal(sub.status, 200, JSON.stringify(sub.data));
  assert.equal(sub.data.timed_out, true);
  assert.equal(sub.data.report.overall.total, 3);
  assert.equal(sub.data.report.overall.correct, 1);
});

test('GET /exam-profiles/:id/mock-exams：列表与 mode 过滤', async (t) => {
  const base = await startMockServer(t);
  await createMock(base, { mode: 'full' });
  await createMock(base, { mode: 'module', knowledge_node_id: 'kn-1', subject_id: undefined });

  const all = await req(base, 'GET', '/exam-profiles/ep-1/mock-exams');
  assert.equal(all.status, 200, JSON.stringify(all.data));
  assert.equal(all.data.total, 2);

  const onlyModule = await req(base, 'GET', '/exam-profiles/ep-1/mock-exams?mode=module');
  assert.equal(onlyModule.data.total, 1);
  assert.equal(onlyModule.data.items[0].mode, 'module');
});

test('DELETE /mock-exams/:id：需 base_version，软删后 404', async (t) => {
  const base = await startMockServer(t);
  const created = await createMock(base);
  const id = created.data.mock_exam.id;

  const noVer = await req(base, 'DELETE', `/mock-exams/${id}`);
  assert.equal(noVer.status, 400, JSON.stringify(noVer.data));
  assert.equal(noVer.data.error, 'INVALID_BASE_VERSION');

  const ok = await req(base, 'DELETE', `/mock-exams/${id}`, { version: created.data.mock_exam.version });
  assert.equal(ok.status, 200, JSON.stringify(ok.data));

  const gone = await req(base, 'GET', `/mock-exams/${id}`);
  assert.equal(gone.status, 404, JSON.stringify(gone.data));
});
