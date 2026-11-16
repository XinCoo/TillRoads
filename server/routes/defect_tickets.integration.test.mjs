// server/routes/defect_tickets.integration.test.mjs
// 题路 TillRoad · BE-03 T6：缺陷单状态机 API 的真实 PG 集成测试
//
// 与 server/index.test.mjs（fake 层）分工：
//   * index.test.mjs —— 路由分发 / 入参解析 / base_version 400 / 409 两形状 / actor=ai 403
//                        用内存 fake 仓储，本机可跑。
//   * 本文件 —— 状态机全链路的**真库验证**：DRAFT→ANALYZED→ACTION_DONE→V1→V2→V3→CLOSED、
//              fail→REOPENED+verification_round+1、REOPENED 后新 round 可重走 V1、
//              并发提交 base_version 409、双层防线（core 前置 + DB 触发器）。
//              只有 RUN_PG_INTEGRATION=1 才跑，CI 会设。
//
// ★为什么必须连真库：
//   verification_round / reopen_count / closed_at / version 全由 schema.sql 的
//   check_defect_transition + set_updated 触发器维护，fake 只能模拟，证明不了
//   「REOPENED→ANALYZED 后触发器真的 +1、新 round 的 V1 唯一索引不冲突」。

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { createPool } from '../db/pool.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { createApp } from '../index.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN
  ? {}
  : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

const HERE = dirname(fileURLToPath(import.meta.url));
const SCHEMA_SQL = readFileSync(join(HERE, '..', '..', 'schema.sql'), 'utf8');

let pool;
let app;
let base;
let seed; // { userId, profileId }

async function req(method, path, body) {
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
  return { status: res.status, data };
}

async function getTicket(id) {
  const r = await req('GET', `/defect-tickets/${id}`);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  return r.data;
}

/** 建一张 ANALYZED 缺陷单（带完整归因，直接过 core 前置校验）。 */
async function newAnalyzed(extra = {}) {
  const r = await req('POST', '/defect-tickets', {
    user_id: seed.userId,
    exam_profile_id: seed.profileId,
    error_layer: 'concept',
    error_cause: '把充分条件当成必要条件导致判断错误',
    ...extra,
  });
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.status, 'ANALYZED');
  return r.data.id;
}

/** 手动「进入验证」：ANALYZED --加 action--> mark done --> begin-verification --> V1。 */
async function toV1(id, action = '重做同类题 10 道') {
  const a = await req('POST', `/defect-tickets/${id}/actions`, { action });
  assert.equal(a.status, 201, JSON.stringify(a.data));
  const m = await req('PATCH', `/defect-tickets/${id}/actions/${a.data.id}`, { version: a.data.version });
  assert.equal(m.status, 200, JSON.stringify(m.data));
  const cur = await getTicket(id);
  const b = await req('PATCH', `/defect-tickets/${id}/begin-verification`, { version: cur.version });
  assert.equal(b.status, 200, JSON.stringify(b.data));
  assert.equal(b.data.status, 'V1');
  return b.data;
}

/** 提交验证（自动带当前 version）。verify_type 用 schema 枚举合法值。 */
async function submitVer(id, stage, result, verifyType = 'redo_hidden', extra = {}) {
  const cur = await getTicket(id);
  return req('POST', `/defect-tickets/${id}/verifications`, {
    stage,
    result,
    verify_type: verifyType,
    version: cur.version,
    ...extra,
  });
}

before(async () => {
  if (!RUN) return;

  pool = createPool();
  try {
    await withTransaction(pool, async (client) => {
      await client.query(SCHEMA_SQL);
    });
  } catch (err) {
    throw new Error(`before: 执行 schema.sql 失败（已回滚）—— ${err.message}`);
  }

  // 已提交的基线：user + exam_profile（defect_tickets 两列都 NOT NULL FK）
  const c = await pool.connect();
  try {
    const u = await c.query(
      `INSERT INTO users (nickname, timezone, role) VALUES ($1,$2,$3) RETURNING id`,
      ['缺陷单集成测试用户', 'Asia/Shanghai', 'student'],
    );
    const p = await c.query(
      `INSERT INTO exam_profiles (user_id, exam_type, target_label, exam_date, daily_minutes, status)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
      [u.rows[0].id, 'postgrad', '缺陷单集成目标', '2027-12-20', 120, 'active'],
    );
    seed = { userId: u.rows[0].id, profileId: p.rows[0].id };
  } finally {
    c.release();
  }

  app = createApp({ pool });
  await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${app.server.address().port}`;
});

after(async () => {
  if (!RUN || !app) return;
  const c = await pool.connect();
  try {
    await c.query(`DELETE FROM verifications WHERE defect_ticket_id IN (SELECT id FROM defect_tickets WHERE user_id=$1)`, [seed.userId]);
    await c.query(`DELETE FROM actions WHERE defect_ticket_id IN (SELECT id FROM defect_tickets WHERE user_id=$1)`, [seed.userId]);
    await c.query(`DELETE FROM defect_tickets WHERE user_id=$1`, [seed.userId]);
    await c.query(`DELETE FROM exam_profiles WHERE user_id=$1`, [seed.userId]);
    await c.query(`DELETE FROM users WHERE id=$1`, [seed.userId]);
  } finally {
    c.release();
  }
  await new Promise((resolve) => app.close(resolve));
  await pool.end();
});

// ---------------------------------------------------------------------------
// 0) 健康
// ---------------------------------------------------------------------------

test('GET /health -> 200', skipOpt, async () => {
  const r = await req('GET', '/health');
  assert.equal(r.status, 200);
  assert.equal(r.data.status, 'ok');
});

// ---------------------------------------------------------------------------
// 1) 全链路 DRAFT→ANALYZED→ACTION_DONE→V1→V2→V3→CLOSED
// ---------------------------------------------------------------------------

test('全链路：ANALYZED → V1 → V2 → V3 → CLOSED（closed_at 由 DB 触发器写）', skipOpt, async () => {
  const id = await newAnalyzed();

  await toV1(id);

  let r = await submitVer(id, 'V1', 'pass', 'redo_hidden');
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.ticket.status, 'V2');

  r = await submitVer(id, 'V2', 'pass', 'similar_variant');
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.ticket.status, 'V3');

  r = await submitVer(id, 'V3', 'pass', 'timed_mock');
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.ticket.status, 'CLOSED');
  assert.ok(r.data.ticket.closed_at, 'CLOSED 时 closed_at 应由触发器写入');

  const t = await getTicket(id);
  assert.equal(t.status, 'CLOSED');
  assert.equal(t.verification_round, 1);
  // 三条验证记录（V1/V2/V3），同一 round
  assert.equal(t.verifications.length, 3);
  assert.deepEqual(
    t.verifications.map((v) => v.stage).sort(),
    ['V1', 'V2', 'V3'],
  );
  assert.ok(t.verifications.every((v) => Number(v.round) === 1));
});

// ---------------------------------------------------------------------------
// 2) ACTION_DONE 不能跳 CLOSED（DB 触发器兜底）
// ---------------------------------------------------------------------------

test('ACTION_DONE 不能直接 CLOSED（POST /close -> 400 ILLEGAL_DEFECT_TRANSITION）', skipOpt, async () => {
  const id = await newAnalyzed();
  const a = await req('POST', `/defect-tickets/${id}/actions`, { action: '重做' });
  assert.equal(a.status, 201);

  // 手动进入验证后处于 V1，V1 直跳 CLOSED 也应被 core 前置 / 触发器拒绝。
  const cur = await getTicket(id);
  const b = await req('PATCH', `/defect-tickets/${id}/begin-verification`, { version: cur.version });
  assert.equal(b.status, 200);

  const r = await req('POST', `/defect-tickets/${id}/close`, {});
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'ILLEGAL_DEFECT_TRANSITION');
});

// ---------------------------------------------------------------------------
// 3) fail → REOPENED + reopen_count +1
// ---------------------------------------------------------------------------

test('验证 fail → REOPENED，reopen_count +1（DB 触发器维护）', skipOpt, async () => {
  const id = await newAnalyzed();
  await toV1(id);

  // fail 必须在「正处于该 stage」提交：先 V1 pass（→V2）再 V2 fail（→REOPENED）。
  let r = await submitVer(id, 'V1', 'pass', 'redo_hidden');
  assert.equal(r.status, 201);
  assert.equal(r.data.ticket.status, 'V2');

  r = await submitVer(id, 'V2', 'fail', 'similar_variant');
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.ticket.status, 'REOPENED');
  assert.equal(r.data.ticket.reopen_count, 1);

  const t = await getTicket(id);
  assert.equal(t.status, 'REOPENED');
  assert.equal(t.reopen_count, 1);
  assert.equal(t.verification_round, 1); // 进 REOPENED 时不 +1，REOPENED→ANALYZED 才 +1
});

// ---------------------------------------------------------------------------
// 4) REOPENED → ANALYZED → round+1 → 新 round 可重走 V1（P0-2 硬点）
// ---------------------------------------------------------------------------

test('REOPENED 再 analyze → verification_round +1，新 round 可重新提交 V1 且保留历史', skipOpt, async () => {
  const id = await newAnalyzed();
  await toV1(id);
  await submitVer(id, 'V1', 'pass', 'redo_hidden');
  const failed = await submitVer(id, 'V2', 'fail', 'similar_variant');
  assert.equal(failed.data.ticket.status, 'REOPENED');

  // REOPENED → ANALYZED（走 /analyze 带 status=REOPENED 触发 reanalyze 分支）
  const cur = await getTicket(id);
  const a = await req('POST', `/defect-tickets/${id}/analyze`, {
    status: 'REOPENED',
    error_layer: 'method',
    error_cause: '解题步骤缺少边界条件检查',
    version: cur.version,
  });
  assert.equal(a.status, 200, JSON.stringify(a.data));
  assert.equal(a.data.status, 'ANALYZED');
  assert.equal(a.data.verification_round, 2, 'DB 触发器应在 REOPENED→ANALYZED 时 +1');

  // 新 round 可再次手动进入验证并提交 V1（唯一索引含 round，不冲突）
  await toV1(id);
  const v = await submitVer(id, 'V1', 'pass', 'redo_hidden');
  assert.equal(v.status, 201, JSON.stringify(v.data));
  assert.equal(v.data.verification.round, 2);

  // 历史 round=1 的 V1 记录仍在（P0-2 保留历史证据）
  const t = await getTicket(id);
  const v1Rows = t.verifications.filter((x) => x.stage === 'V1');
  assert.equal(v1Rows.length, 2, 'round 1 与 round 2 各有一条 V1');
  assert.deepEqual(v1Rows.map((x) => Number(x.round)).sort(), [1, 2]);
});

// ---------------------------------------------------------------------------
// 5) 应用层 + DB 触发器双层防线：禁用语 / 缺归因
// ---------------------------------------------------------------------------

test('应用层前置校验：禁用语 -> 400 forbidden_phrase（不入库）', skipOpt, async () => {
  const r = await req('POST', '/defect-tickets', {
    user_id: seed.userId,
    exam_profile_id: seed.profileId,
    error_layer: 'concept',
    error_cause: '我粗心了',
  });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'forbidden_phrase');
});

test('应用层前置校验：缺 error_layer -> 400 missing_error_layer_or_cause', skipOpt, async () => {
  const r = await req('POST', '/defect-tickets', {
    user_id: seed.userId,
    exam_profile_id: seed.profileId,
    error_cause: '边界条件没检查',
  });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'missing_error_layer_or_cause');
});

test('DRAFT 草稿可未归因建单，再 analyze 补齐归因', skipOpt, async () => {
  const d = await req('POST', '/defect-tickets', {
    user_id: seed.userId,
    exam_profile_id: seed.profileId,
    draft: true,
  });
  assert.equal(d.status, 201, JSON.stringify(d.data));
  assert.equal(d.data.status, 'DRAFT');

  const a = await req('POST', `/defect-tickets/${d.data.id}/analyze`, {
    error_layer: 'concept',
    error_cause: '把充分条件当成必要条件',
    version: d.data.version,
  });
  assert.equal(a.status, 200, JSON.stringify(a.data));
  assert.equal(a.data.status, 'ANALYZED');
});

// ---------------------------------------------------------------------------
// 6) 拍板项 4：actions 门禁
// ---------------------------------------------------------------------------

test('begin-verification 门禁：无 action -> 400 NO_ACTIONS；有未完成 -> 400 ACTIONS_NOT_DONE', skipOpt, async () => {
  const id1 = await newAnalyzed();
  let cur = await getTicket(id1);
  let r = await req('PATCH', `/defect-tickets/${id1}/begin-verification`, { version: cur.version });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'NO_ACTIONS');

  const id2 = await newAnalyzed();
  const a = await req('POST', `/defect-tickets/${id2}/actions`, { action: '重做同类题' });
  assert.equal(a.status, 201);
  cur = await getTicket(id2);
  r = await req('PATCH', `/defect-tickets/${id2}/begin-verification`, { version: cur.version });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'ACTIONS_NOT_DONE');
});

// ---------------------------------------------------------------------------
// 7) 拍板项 5：actor=ai + pass -> 403；base_version 强制；乐观锁 409
// ---------------------------------------------------------------------------

test('actor=ai + pass -> 403 ai_cannot_close（仅用户可关单）', skipOpt, async () => {
  const id = await newAnalyzed();
  await toV1(id);
  const r = await submitVer(id, 'V1', 'pass', 'redo_hidden', { actor: 'ai' });
  assert.equal(r.status, 403);
  assert.equal(r.data.error, 'ai_cannot_close');
});

test('POST /verifications 缺 base_version -> 400 INVALID_BASE_VERSION', skipOpt, async () => {
  const id = await newAnalyzed();
  await toV1(id);
  const r = await req('POST', `/defect-tickets/${id}/verifications`, { stage: 'V1', result: 'pass' });
  assert.equal(r.status, 400);
  assert.equal(r.data.error, 'INVALID_BASE_VERSION');
});

test('乐观锁：旧 version 提交 -> 409 client_merge，状态不被推进', skipOpt, async () => {
  const id = await newAnalyzed();
  const t = await getTicket(id);
  const r = await req('PATCH', `/defect-tickets/${id}`, { version: t.version, q_type: 'choice' });
  assert.equal(r.status, 200);
  assert.equal(r.data.version, t.version + 1);

  const stale = await req('PATCH', `/defect-tickets/${id}`, { version: t.version, q_type: 'fill' });
  assert.equal(stale.status, 409);
  assert.equal(stale.data.error, 'conflict');
  assert.equal(stale.data.resolution, 'client_merge');
  assert.equal((await getTicket(id)).q_type, 'choice', '旧 version 的写未生效');
});

test('并发提交：两个连接用同一 version 提交验证 -> 一个 201、一个 409', skipOpt, async () => {
  const id = await newAnalyzed();
  await toV1(id);
  const cur = await getTicket(id);

  const payload = {
    stage: 'V1',
    result: 'pass',
    verify_type: 'redo_hidden',
    version: cur.version,
  };
  const [a, b] = await Promise.all([
    req('POST', `/defect-tickets/${id}/verifications`, payload),
    req('POST', `/defect-tickets/${id}/verifications`, payload),
  ]);
  const codes = [a.status, b.status].sort();
  assert.deepEqual(codes, [201, 409], `期望一成一败，实际 ${a.status}/${b.status}`);

  const t = await getTicket(id);
  assert.equal(t.status, 'V2', '只有一个提交生效');
  assert.equal(t.verifications.filter((v) => v.stage === 'V1').length, 1, 'V1 记录只有一条');
});
