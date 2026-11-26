// server/routes/defect_question_links.integration.test.mjs
// 题路 TillRoad · m27163：缺陷单 ↔ 题目 一对多关联 + 自定义错因 的真实 PG 集成测试
//
// 覆盖：
//   1) POST /defect-tickets/:id/questions 关联一道题 → 201，GET 列表能看到、sort=1
//   2) 重复关联同一道题 → 409 duplicate_defect_question
//   3) 关联第二道题 → sort=2；PUT /questions/sort 倒序 → sort 正确
//   4) DELETE /defect-tickets/:id/questions/:qid → 200 removed；再删 → 404
//   5) 别人的缺陷单 → 不可见（404 语义；注意 index.mjs 的归属层会先拦成 403 forbidden）
//   6) GET /defect-tickets/:id 返回体含 questions 数组
//   7) GET /defect-tickets/custom-reasons 返回当前用户的历史自定义错因 + count，不含别人的
//   8) 建单带 custom_reason → 201 且详情读得回；超 30 字 → 400 INVALID_CUSTOM_REASON
//
// 只有 RUN_PG_INTEGRATION=1 才跑，CI 会设。

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';

import { createPool } from '../db/pool.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { createApp } from '../index.mjs';
import { FULL_SCHEMA_SQL } from '../db/test_schema.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN
  ? {}
  : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

const TOKEN_A = 'tk_dqlink_a';
const TOKEN_B = 'tk_dqlink_b';

let pool;
let app;
let base;
let seed; // { userA:{userId,profileId,subjectId}, userB:{...} }

async function req(method, path, body, token) {
  const init = { method };
  if (body !== undefined) {
    init.headers = { 'Content-Type': 'application/json' };
    init.body = JSON.stringify(body);
  }
  if (token) init.headers = { ...(init.headers ?? {}), Authorization: `Bearer ${token}` };
  const res = await fetch(base + path, init);
  const text = await res.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  return { status: res.status, data };
}

async function makeUser(c, nickname) {
  const u = await c.query(
    `INSERT INTO users (nickname, timezone, role) VALUES ($1, 'Asia/Shanghai', 'student') RETURNING id`,
    [nickname],
  );
  const userId = u.rows[0].id;
  const p = await c.query(
    `INSERT INTO exam_profiles (user_id, exam_type, target_label, exam_date, daily_minutes)
     VALUES ($1, 'postgrad', $2, '2027-12-20', 120) RETURNING id`,
    [userId, `${nickname}目标`],
  );
  const profileId = p.rows[0].id;
  const s = await c.query(
    `INSERT INTO subjects (exam_profile_id, name, kind) VALUES ($1, $2, 'objective') RETURNING id`,
    [profileId, `${nickname}科目`],
  );
  return { userId, profileId, subjectId: s.rows[0].id };
}

async function makeQuestion(c, { subjectId, ownerUserId, stem, type = 'choice' }) {
  const r = await c.query(
    `INSERT INTO questions
       (source, subject_id, type, stem, options, answer, content_hash, owner_user_id)
     VALUES ('import', $1, $2, $3, $4::jsonb, 'A', $5, $6)
     RETURNING id`,
    [subjectId, type, stem, JSON.stringify([{ key: 'A', text: '甲' }]), `hash-dqlink-${stem}`, ownerUserId],
  );
  return r.rows[0].id;
}

/** 建一张缺陷单（ANALYZED，带 error_layer/error_cause）。 */
async function createTicket(token, { profileId, questionId, customReason }) {
  const payload = {
    exam_profile_id: profileId,
    knowledge_node_id: null,
    question_id: questionId ?? null,
    q_type: 'choice',
    error_layer: 'concept',
    error_cause: '概念不清',
  };
  if (customReason !== undefined) payload.custom_reason = customReason;
  const r = await req('POST', '/defect-tickets', payload, token);
  assert.equal(r.status, 201, JSON.stringify(r.data));
  return r.data;
}

before(async () => {
  if (!RUN) return;
  pool = createPool();
  try {
    await withTransaction(pool, async (client) => {
      await client.query(FULL_SCHEMA_SQL);
    });
  } catch (err) {
    throw new Error(`before: 执行 schema 失败（已回滚）—— ${err.message}`);
  }

  const c = await pool.connect();
  try {
    const a = await makeUser(c, '关联用户A');
    const b = await makeUser(c, '关联用户B');
    const q1 = await makeQuestion(c, { subjectId: a.subjectId, ownerUserId: a.userId, stem: '关联题1' });
    const q2 = await makeQuestion(c, { subjectId: a.subjectId, ownerUserId: a.userId, stem: '关联题2' });
    const q3 = await makeQuestion(c, { subjectId: a.subjectId, ownerUserId: a.userId, stem: '关联题3' });
    seed = {
      userA: { ...a, q1, q2, q3 },
      userB: { ...b },
    };
  } finally {
    c.release();
  }

  process.env.TOKENS = `${TOKEN_A}:${seed.userA.userId},${TOKEN_B}:${seed.userB.userId}`;
  app = createApp({ pool });
  await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${app.server.address().port}`;
});

after(async () => {
  if (!RUN || !app) return;
  const c = await pool.connect();
  let cleanupFailure = null;
  try {
    // FK 顺序：defect_questions → defect_tickets(依赖 questions/exam_profiles) → questions → subjects → exam_profiles → users
    await c.query(`DELETE FROM defect_questions WHERE defect_ticket_id IN (SELECT id FROM defect_tickets WHERE user_id IN ($1, $2))`, [
      seed.userA.userId,
      seed.userB.userId,
    ]);
    await c.query(`DELETE FROM defect_tickets WHERE user_id IN ($1, $2)`, [seed.userA.userId, seed.userB.userId]);
    await c.query(`DELETE FROM questions WHERE subject_id IN ($1, $2)`, [seed.userA.subjectId, seed.userB.subjectId]);
    await c.query(`DELETE FROM subjects WHERE id IN ($1, $2)`, [seed.userA.subjectId, seed.userB.subjectId]);
    await c.query(`DELETE FROM exam_profiles WHERE id IN ($1, $2)`, [seed.userA.profileId, seed.userB.profileId]);
    await c.query(`DELETE FROM users WHERE id IN ($1, $2)`, [seed.userA.userId, seed.userB.userId]);
  } catch (cleanupError) {
    cleanupFailure = cleanupError;
  } finally {
    c.release();
  }
  try {
    await new Promise((resolve) => app.close(resolve));
  } finally {
    await pool.end();
    delete process.env.TOKENS;
  }
  if (cleanupFailure) {
    throw new Error(`after(): 清理数据失败: ${cleanupFailure.message}`);
  }
});

test('关联题目 → 201；GET 列表能看到（sort=1）', skipOpt, async () => {
  const ticket = await createTicket(TOKEN_A, { profileId: seed.userA.profileId });
  const r = await req('POST', `/defect-tickets/${ticket.id}/questions`, { question_id: seed.userA.q1 }, TOKEN_A);
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.question_id, seed.userA.q1);
  assert.equal(r.data.sort, 1);
  assert.ok(r.data.id);
  assert.ok(r.data.created_at);

  const list = await req('GET', `/defect-tickets/${ticket.id}/questions`, undefined, TOKEN_A);
  assert.equal(list.status, 200, JSON.stringify(list.data));
  assert.equal(list.data.items.length, 1);
  const item = list.data.items[0];
  assert.equal(item.question_id, seed.userA.q1);
  assert.equal(item.sort, 1);
  assert.equal(item.stem, '关联题1');
  assert.equal(item.type, 'choice');
  assert.equal(item.source, 'import');
});

test('重复关联同一道题 → 409 duplicate_defect_question', skipOpt, async () => {
  const ticket = await createTicket(TOKEN_A, { profileId: seed.userA.profileId });
  const first = await req('POST', `/defect-tickets/${ticket.id}/questions`, { question_id: seed.userA.q1 }, TOKEN_A);
  assert.equal(first.status, 201, JSON.stringify(first.data));
  const dup = await req('POST', `/defect-tickets/${ticket.id}/questions`, { question_id: seed.userA.q1 }, TOKEN_A);
  assert.equal(dup.status, 409, JSON.stringify(dup.data));
  assert.equal(dup.data.error, 'duplicate_defect_question');
  assert.equal(dup.data.message, '该题目已关联此缺陷单');
});

test('关联第二道题 → sort=2；PUT /questions/sort 倒序 → sort 正确', skipOpt, async () => {
  const ticket = await createTicket(TOKEN_A, { profileId: seed.userA.profileId });
  const l1 = await req('POST', `/defect-tickets/${ticket.id}/questions`, { question_id: seed.userA.q1 }, TOKEN_A);
  const l2 = await req('POST', `/defect-tickets/${ticket.id}/questions`, { question_id: seed.userA.q2 }, TOKEN_A);
  assert.equal(l1.status, 201);
  assert.equal(l2.status, 201, JSON.stringify(l2.data));
  assert.equal(l2.data.sort, 2);

  const reordered = await req(
    'PUT',
    `/defect-tickets/${ticket.id}/questions/sort`,
    { ids: [seed.userA.q2, seed.userA.q1] },
    TOKEN_A,
  );
  assert.equal(reordered.status, 200, JSON.stringify(reordered.data));
  const map = new Map(reordered.data.items.map((i) => [i.question_id, i.sort]));
  assert.equal(map.get(seed.userA.q2), 1);
  assert.equal(map.get(seed.userA.q1), 2);

  const list = await req('GET', `/defect-tickets/${ticket.id}/questions`, undefined, TOKEN_A);
  const order = list.data.items.map((i) => i.question_id);
  assert.deepEqual(order, [seed.userA.q2, seed.userA.q1]);
});

test('PUT /questions/sort 传不属于该单的题 → 400 INVALID_SORT_LIST', skipOpt, async () => {
  const ticket = await createTicket(TOKEN_A, { profileId: seed.userA.profileId });
  await req('POST', `/defect-tickets/${ticket.id}/questions`, { question_id: seed.userA.q1 }, TOKEN_A);
  const r = await req(
    'PUT',
    `/defect-tickets/${ticket.id}/questions/sort`,
    { ids: [seed.userA.q1, seed.userA.q3] },
    TOKEN_A,
  );
  assert.equal(r.status, 400, JSON.stringify(r.data));
  assert.equal(r.data.error, 'INVALID_SORT_LIST');
});

test('DELETE 解除关联 → 200 removed；再删 → 404', skipOpt, async () => {
  const ticket = await createTicket(TOKEN_A, { profileId: seed.userA.profileId });
  await req('POST', `/defect-tickets/${ticket.id}/questions`, { question_id: seed.userA.q1 }, TOKEN_A);
  const del = await req('DELETE', `/defect-tickets/${ticket.id}/questions/${seed.userA.q1}`, undefined, TOKEN_A);
  assert.equal(del.status, 200, JSON.stringify(del.data));
  assert.equal(del.data.removed, true);
  assert.equal(del.data.question_id, seed.userA.q1);

  const again = await req('DELETE', `/defect-tickets/${ticket.id}/questions/${seed.userA.q1}`, undefined, TOKEN_A);
  assert.equal(again.status, 404, JSON.stringify(again.data));
});

test('别人的缺陷单 → 不可见（404 语义；HTTP 层归属检查会先拦成 403 forbidden）', skipOpt, async () => {
  const ticketA = await createTicket(TOKEN_A, { profileId: seed.userA.profileId });
  const link = await req('POST', `/defect-tickets/${ticketA.id}/questions`, { question_id: seed.userA.q1 }, TOKEN_A);
  assert.equal(link.status, 201);

  // 用户 B 访问用户 A 的缺陷单
  const r = await req('GET', `/defect-tickets/${ticketA.id}/questions`, undefined, TOKEN_B);
  assert.ok([403, 404].includes(r.status), `期望 403/404，实际 ${r.status}：${JSON.stringify(r.data)}`);

  const r2 = await req('POST', `/defect-tickets/${ticketA.id}/questions`, { question_id: seed.userA.q2 }, TOKEN_B);
  assert.ok([403, 404].includes(r2.status), `期望 403/404，实际 ${r2.status}：${JSON.stringify(r2.data)}`);
});

test('GET /defect-tickets/:id 返回体含 questions 数组', skipOpt, async () => {
  const ticket = await createTicket(TOKEN_A, { profileId: seed.userA.profileId });
  await req('POST', `/defect-tickets/${ticket.id}/questions`, { question_id: seed.userA.q1 }, TOKEN_A);
  const r = await req('GET', `/defect-tickets/${ticket.id}`, undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.ok(Array.isArray(r.data.questions), 'questions 应是数组');
  assert.equal(r.data.questions.length, 1);
  assert.equal(r.data.questions[0].question_id, seed.userA.q1);
  assert.equal(r.data.questions[0].sort, 1);
  assert.equal(r.data.questions[0].stem, '关联题1');
  assert.equal(r.data.questions[0].type, 'choice');
});

test('GET /defect-tickets/custom-reasons 返回自己的历史错因 + count，不含别人的', skipOpt, async () => {
  await createTicket(TOKEN_A, { profileId: seed.userA.profileId, customReason: '计算失误' });
  await createTicket(TOKEN_A, { profileId: seed.userA.profileId, customReason: '计算失误' });
  await createTicket(TOKEN_A, { profileId: seed.userA.profileId, customReason: '审题不清' });
  await createTicket(TOKEN_B, { profileId: seed.userB.profileId, customReason: '别人的错因' });

  const r = await req('GET', '/defect-tickets/custom-reasons', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  const map = new Map(r.data.items.map((i) => [i.custom_reason, i.count]));
  assert.equal(map.get('计算失误'), 2);
  assert.equal(map.get('审题不清'), 1);
  assert.equal(map.has('别人的错因'), false);

  // 限定考试目标
  const scoped = await req(
    'GET',
    `/defect-tickets/custom-reasons?exam_profile_id=${seed.userA.profileId}`,
    undefined,
    TOKEN_A,
  );
  assert.equal(scoped.status, 200, JSON.stringify(scoped.data));
  assert.equal(scoped.data.items.length, 2);
});

test('建单带 custom_reason → 201 且详情读得回；超 30 字 → 400 INVALID_CUSTOM_REASON', skipOpt, async () => {
  const ticket = await createTicket(TOKEN_A, { profileId: seed.userA.profileId, customReason: '审题不清' });
  assert.equal(ticket.custom_reason, '审题不清');

  const detail = await req('GET', `/defect-tickets/${ticket.id}`, undefined, TOKEN_A);
  assert.equal(detail.status, 200, JSON.stringify(detail.data));
  assert.equal(detail.data.custom_reason, '审题不清');

  const tooLong = await req(
    'POST',
    '/defect-tickets',
    {
      exam_profile_id: seed.userA.profileId,
      q_type: 'choice',
      error_layer: 'concept',
      error_cause: '概念不清',
      custom_reason: '错'.repeat(31),
    },
    TOKEN_A,
  );
  assert.equal(tooLong.status, 400, JSON.stringify(tooLong.data));
  assert.equal(tooLong.data.error, 'INVALID_CUSTOM_REASON');

  const notString = await req(
    'POST',
    '/defect-tickets',
    {
      exam_profile_id: seed.userA.profileId,
      q_type: 'choice',
      error_layer: 'concept',
      error_cause: '概念不清',
      custom_reason: 123,
    },
    TOKEN_A,
  );
  assert.equal(notString.status, 400, JSON.stringify(notString.data));
  assert.equal(notString.data.error, 'INVALID_CUSTOM_REASON');
});

test('无 token → 401（缺陷单关联与 custom-reasons）', skipOpt, async () => {
  const ticket = await createTicket(TOKEN_A, { profileId: seed.userA.profileId });
  const r1 = await req('GET', `/defect-tickets/${ticket.id}/questions`);
  assert.equal(r1.status, 401, JSON.stringify(r1.data));
  const r2 = await req('GET', '/defect-tickets/custom-reasons');
  assert.equal(r2.status, 401, JSON.stringify(r2.data));
});
