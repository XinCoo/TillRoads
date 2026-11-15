// server/index.test.mjs — 集成测试（node:test + 内置 fetch，零第三方依赖）
// 启动真实 server 监听 0 端口，每个用例独立 server/state，测试后 close。
import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from './index.mjs';

async function startServer() {
  const app = createApp();
  await new Promise((resolve) => app.listen(0, '127.0.0.1', resolve));
  const port = app.server.address().port;
  return {
    base: `http://127.0.0.1:${port}`,
    close() {
      return new Promise((resolve, reject) => app.close((e) => (e ? reject(e) : resolve())));
    },
  };
}

async function req(base, method, path, body) {
  const opts = { method };
  if (body !== undefined) {
    opts.headers = { 'Content-Type': 'application/json' };
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(base + path, opts);
  const data = await r.json();
  return { status: r.status, data, headers: r.headers };
}

// 建一张已归因（ANALYZED）缺陷单
async function newAnalyzed(base, extra = {}) {
  return req(base, 'POST', '/defect-tickets', {
    user_id: 'u-1',
    exam_profile_id: 'ep-1',
    knowledge_node_id: 'kn-1',
    question_id: 'q-1',
    q_type: 'single',
    error_layer: 'concept',
    error_cause: '把充分条件当成必要条件导致判断错误',
    ...extra,
  });
}

// 把 ANALYZED 单推进到 ACTION_DONE
async function toActionDone(base, id, extra = {}) {
  return req(base, 'POST', `/defect-tickets/${id}/action`, { action: '重做同类题并整理错因', ...extra });
}

// ---------------------------------------------------------------------------

test('GET /health -> 200 {status:ok} 且 Content-Type 正确', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const r = await req(s.base, 'GET', '/health');
  assert.equal(r.status, 200);
  assert.deepEqual(r.data, { status: 'ok' });
  assert.match(r.headers.get('content-type'), /application\/json; charset=utf-8/);
});

test('POST /exam-profiles -> 201 目标配置', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const r = await req(s.base, 'POST', '/exam-profiles', {
    user_id: 'u-1', exam_type: 'postgrad', target_score: 80,
  });
  assert.equal(r.status, 201);
  assert.ok(r.data.id);
  assert.equal(r.data.exam_type, 'postgrad');
  assert.equal(r.data.status, 'active');
  assert.equal(r.data.version, 1);
});

test('建单(ANALYZED) -> action(ACTION_DONE) -> 三次验证全 pass(V1->V2->V3->CLOSED) 全链路', async (t) => {
  const s = await startServer();
  t.after(() => s.close());

  const c = await newAnalyzed(s.base);
  assert.equal(c.status, 201);
  assert.equal(c.data.status, 'ANALYZED');
  assert.equal(c.data.version, 1);
  assert.equal(c.data.reopen_count, 0);
  assert.equal(c.data.verification_round, 1);
  assert.ok(c.data.created_at);
  assert.ok(c.data.priority);
  const id = c.data.id;

  const a = await toActionDone(s.base, id);
  assert.equal(a.status, 200);
  assert.equal(a.data.status, 'ACTION_DONE');
  assert.ok(Array.isArray(a.data.actions) && a.data.actions.length === 1);

  const v1 = await req(s.base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'pass', type: 'redo_hidden' });
  assert.equal(v1.status, 201);
  assert.equal(v1.data.ticket.status, 'V2');
  assert.equal(v1.data.verification.stage, 'V1');
  assert.equal(v1.data.verification.round, 1);

  const v2 = await req(s.base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V2', result: 'pass', type: 'new_question' });
  assert.equal(v2.status, 201);
  assert.equal(v2.data.ticket.status, 'V3');
  assert.equal(v2.data.verification.stage, 'V2');

  const v3 = await req(s.base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V3', result: 'pass', type: 'timed_mock' });
  assert.equal(v3.status, 201);
  assert.equal(v3.data.ticket.status, 'CLOSED');
  assert.equal(v3.data.verification.stage, 'V3');
  assert.equal(v3.data.verification.round, 1);
});

test('ACTION_DONE 不能直接跳 CLOSED（/close 与通用 PATCH 均 4xx）', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const id = (await newAnalyzed(s.base)).data.id;
  await toActionDone(s.base, id);

  const close = await req(s.base, 'POST', `/defect-tickets/${id}/close`, {});
  assert.equal(close.status, 400);
  assert.equal(close.data.error, 'ILLEGAL_DEFECT_TRANSITION');

  const patch = await req(s.base, 'PATCH', `/defect-tickets/${id}`, { status: 'CLOSED' });
  assert.equal(patch.status, 400);
  assert.equal(patch.data.error, 'ILLEGAL_DEFECT_TRANSITION');
});

test('fail -> REOPENED 且 reopen_count 递增', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const id = (await newAnalyzed(s.base)).data.id;
  await toActionDone(s.base, id);
  await req(s.base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'pass' }); // -> V2

  const f = await req(s.base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V2', result: 'fail' });
  assert.equal(f.status, 201);
  assert.equal(f.data.ticket.status, 'REOPENED');
  assert.equal(f.data.ticket.reopen_count, 1);
  assert.equal(f.data.verification.result, 'fail');
});

test('REOPENED 再 analyze -> verification_round+1，且新 round 能重新插入 V1（P0-2）', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const id = (await newAnalyzed(s.base)).data.id;
  await toActionDone(s.base, id);
  await req(s.base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'pass' }); // V2 round1
  const f = await req(s.base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V2', result: 'fail' }); // REOPENED
  assert.equal(f.data.ticket.status, 'REOPENED');
  assert.equal(f.data.ticket.reopen_count, 1);

  const an = await req(s.base, 'POST', `/defect-tickets/${id}/analyze`, {
    error_layer: 'process',
    error_cause: '计算步骤跳步导致符号错误',
  });
  assert.equal(an.status, 200);
  assert.equal(an.data.status, 'ANALYZED');
  assert.equal(an.data.verification_round, 2);
  assert.equal(an.data.reopen_count, 1);

  await toActionDone(s.base, id);
  const v1again = await req(s.base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'pass' });
  assert.equal(v1again.status, 201, '新 round 的 V1 应可重新插入（不被 round1 的 V1 唯一冲突挡住）');
  assert.equal(v1again.data.verification.round, 2);
  assert.equal(v1again.data.verification.stage, 'V1');
  assert.equal(v1again.data.ticket.status, 'V2');
});

test('禁用语建单 -> 400 {error:forbidden_phrase}', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const r = await req(s.base, 'POST', '/defect-tickets', {
    error_layer: 'concept', error_cause: '这次是粗心了',
  });
  assert.equal(r.status, 400);
  assert.deepEqual(r.data, { error: 'forbidden_phrase' });
});

test('缺 error_layer / error_cause -> 400 {error:missing_error_layer_or_cause}', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const r1 = await req(s.base, 'POST', '/defect-tickets', { error_cause: '漏写条件' });
  assert.equal(r1.status, 400);
  assert.deepEqual(r1.data, { error: 'missing_error_layer_or_cause' });
  const r2 = await req(s.base, 'POST', '/defect-tickets', { error_layer: 'concept' });
  assert.equal(r2.status, 400);
  assert.deepEqual(r2.data, { error: 'missing_error_layer_or_cause' });
});

test('DRAFT 草稿建单（无归因）-> 201 status=DRAFT；再 analyze -> ANALYZED', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const d = await req(s.base, 'POST', '/defect-tickets', { draft: true, question_id: 'q-9' });
  assert.equal(d.status, 201);
  assert.equal(d.data.status, 'DRAFT');
  assert.equal(d.data.error_cause, '');

  const d2 = await req(s.base, 'POST', '/defect-tickets', { status: 'DRAFT' });
  assert.equal(d2.status, 201);
  assert.equal(d2.data.status, 'DRAFT');

  const an = await req(s.base, 'POST', `/defect-tickets/${d.data.id}/analyze`, {
    error_layer: 'concept', error_cause: '概念边界没分清',
  });
  assert.equal(an.status, 200);
  assert.equal(an.data.status, 'ANALYZED');
});

test('actor=ai 且 result=pass -> 403 {error:ai_cannot_close}', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const id = (await newAnalyzed(s.base)).data.id;
  await toActionDone(s.base, id);
  const r = await req(s.base, 'POST', `/defect-tickets/${id}/verifications`, {
    stage: 'V1', result: 'pass', actor: 'ai',
  });
  assert.equal(r.status, 403);
  assert.deepEqual(r.data, { error: 'ai_cannot_close' });
});

test('非法阶段/状态不匹配 -> 400 {error:e.code}', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const id = (await newAnalyzed(s.base)).data.id;
  await toActionDone(s.base, id);
  // ACTION_DONE 直接提交 V2（状态不匹配，且非 V1 特例）
  const bad = await req(s.base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V2', result: 'pass' });
  assert.equal(bad.status, 400);
  assert.equal(bad.data.error, 'INVALID_VERIFICATION_STAGE');
  const badResult = await req(s.base, 'POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'maybe' });
  assert.equal(badResult.status, 400);
  assert.equal(badResult.data.error, 'INVALID_VERIFICATION_RESULT');
});

test('POST /ai/questions:generate count=0 / 21 -> 400；count=5 -> 202 且自持 provider/model 快照', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const r0 = await req(s.base, 'POST', '/ai/questions:generate', { count: 0 });
  assert.equal(r0.status, 400);
  assert.equal(r0.data.error, 'INVALID_COUNT');
  assert.ok(r0.data.message);

  const r21 = await req(s.base, 'POST', '/ai/questions:generate', { count: 21 });
  assert.equal(r21.status, 400);
  assert.equal(r21.data.error, 'INVALID_COUNT');

  const ok = await req(s.base, 'POST', '/ai/questions:generate', {
    count: 5, provider: 'deepseek', model: 'deepseek-chat', knowledge_node_id: 'kn-1',
  });
  assert.equal(ok.status, 202);
  assert.ok(ok.data.job_id);
  assert.equal(ok.data.status, 'pending');
  assert.equal(ok.data.provider_snapshot, 'deepseek');
  assert.equal(ok.data.model_snapshot, 'deepseek-chat');

  // /ai-jobs 别名同样可用，校验失败映射一致
  const jobBad = await req(s.base, 'POST', '/ai-jobs', { count: 99 });
  assert.equal(jobBad.status, 400);
  assert.equal(jobBad.data.error, 'INVALID_COUNT');
});

test('乐观锁：version 匹配成功；version 不符 -> 409 {error:conflict,...}', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const c = await newAnalyzed(s.base);
  const id = c.data.id;
  assert.equal(c.data.version, 1);

  const good = await req(s.base, 'PATCH', `/defect-tickets/${id}`, { version: 1, q_type: 'fill' });
  assert.equal(good.status, 200);
  assert.equal(good.data.version, 2);

  const bad = await req(s.base, 'PATCH', `/defect-tickets/${id}`, { version: 1, q_type: 'essay' });
  assert.equal(bad.status, 409);
  assert.deepEqual(bad.data, {
    error: 'conflict', current: 2, incoming: 1, resolution: 'client_merge',
  });

  // action 端点同样实现乐观锁
  const badAction = await req(s.base, 'POST', `/defect-tickets/${id}/action`, { version: 999, action: 'x' });
  assert.equal(badAction.status, 409);
  assert.equal(badAction.data.resolution, 'client_merge');
});

test('GET /review-cycles?type=weekly 与 GET /mock-exams/:id/report 可访问', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  await newAnalyzed(s.base);
  await toActionDone(s.base, (await req(s.base, 'POST', '/defect-tickets', {
    error_layer: 'concept', error_cause: '步骤遗漏',
  })).data.id);

  const rc = await req(s.base, 'GET', '/review-cycles?type=weekly');
  assert.equal(rc.status, 200);
  assert.equal(rc.data.type, 'weekly');
  for (const k of ['closed_count', 'reopened_count', 'new_defects', 'timeline']) {
    assert.ok(Object.prototype.hasOwnProperty.call(rc.data, k), `缺少字段 ${k}`);
  }
  assert.ok(Array.isArray(rc.data.timeline));

  const rep = await req(s.base, 'GET', '/mock-exams/me-1/report');
  assert.equal(rep.status, 200);
  assert.equal(rep.data.mock_exam_id, 'me-1');
  assert.equal(typeof rep.data.total_score, 'number');
  assert.ok(Array.isArray(rep.data.by_knowledge_node));
  assert.ok(Array.isArray(rep.data.defect_links));
  assert.equal(typeof rep.data.stability_index, 'number');
});

test('规范契约：POST /analyze + POST /verifications 可用，PATCH /analyze 为兼容别名', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const bad = await req(s.base, 'POST', '/defect-tickets', { error_cause: '漏写条件' });
  assert.equal(bad.status, 400);
  assert.deepEqual(bad.data, { error: 'missing_error_layer_or_cause' });
  const d = await req(s.base, 'POST', '/defect-tickets', { draft: true, question_id: 'q-1' });
  const id = d.data.id;
  const an = await req(s.base, 'POST', `/defect-tickets/${id}/analyze`, {
    error_layer: 'concept', error_cause: '概念边界没分清',
  });
  assert.equal(an.status, 200);
  assert.equal(an.data.status, 'ANALYZED');
  const d2 = await req(s.base, 'POST', '/defect-tickets', { draft: true });
  const an2 = await req(s.base, 'PATCH', `/defect-tickets/${d2.data.id}/analyze`, {
    error_layer: 'concept', error_cause: '条件遗漏',
  });
  assert.equal(an2.status, 200, 'PATCH /analyze 兼容别名仍可用');
  await toActionDone(s.base, id);
  const v = await req(s.base, 'POST', '/verifications', {
    defect_ticket_id: id, stage: 'V1', result: 'pass', verify_type: 'redo_hidden',
  });
  assert.equal(v.status, 201);
  assert.equal(v.data.ticket.status, 'V2');
  assert.equal(v.data.verification.round, 1);
});

test('未知路由 -> 404 {error:not_found}', async (t) => {
  const s = await startServer();
  t.after(() => s.close());
  const r = await req(s.base, 'GET', '/no-such-route');
  assert.equal(r.status, 404);
  assert.deepEqual(r.data, { error: 'not_found' });
});
