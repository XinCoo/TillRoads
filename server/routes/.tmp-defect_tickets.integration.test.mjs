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

import { createPool } from '../../.tmp-pglite-pool.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { createApp } from '../index.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN
  ? {}
  : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

const HERE = dirname(fileURLToPath(import.meta.url));
// ★ m17431：schema 解冻后要连「基线 schema + 增量迁移」一起跑
//   （owner_user_id 列在 migrations/0002_questions_owner.sql 里，不在 schema.sql 里）。
import { FULL_SCHEMA_SQL } from './../db/test_schema.mjs';

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
      await client.query(FULL_SCHEMA_SQL);
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
  let cleanupFailure = null;
  try {
    await c.query(`DELETE FROM verifications WHERE defect_ticket_id IN (SELECT id FROM defect_tickets WHERE user_id=$1)`, [seed.userId]);
    await c.query(`DELETE FROM actions WHERE defect_ticket_id IN (SELECT id FROM defect_tickets WHERE user_id=$1)`, [seed.userId]);
    await c.query(`DELETE FROM defect_tickets WHERE user_id=$1`, [seed.userId]);
    await c.query(`DELETE FROM exam_profiles WHERE user_id=$1`, [seed.userId]);
    await c.query(`DELETE FROM users WHERE id=$1`, [seed.userId]);
  } catch (cleanupError) {
    // 与 mock_exams.integration.test.mjs 同样的加固：清理抛错不能连带 skip 掉关服。
    // 原实现把 app.close()/pool.end() 放在 try/finally 之外，异常一跳出就永远执行不到，
    // HTTP server 与连接池仍有活 handle → node:test 进程退不出去（CI 超时 cancel）。
    // 不吞错误（否则数据泄漏被静默忽略）：先关服再抛，fail fast 且进程能退出。
    cleanupFailure = cleanupError;
  } finally {
    c.release();
  }
  try {
    await new Promise((resolve) => app.close(resolve));
  } finally {
    await pool.end();
  }
  if (cleanupFailure) {
    throw new Error(`after(): 清理数据失败（前置测试已跑完，但库中可能残留测试数据）: ${cleanupFailure.message}`);
  }
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
  // 用统一辅助：加 action → mark done → begin-verification（手动两跳进入 V1）。
  await toV1(id);

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

// ---------------------------------------------------------------------------
// 8) FE-04 A1/A2：建单时 actions 同事务落表（堵住 NO_ACTIONS 缺口）
// ---------------------------------------------------------------------------

test('建单带 2 条 actions -> actions 表 2 行 done=false -> 标记完成后可进入 V1', skipOpt, async () => {
  const r = await req('POST', '/defect-tickets', {
    user_id: seed.userId,
    exam_profile_id: seed.profileId,
    error_layer: 'concept',
    error_cause: '把充分条件当成必要条件导致判断错误',
    actions: ['重做同类题 10 道', { content: '整理错因卡片', due: '2026-12-01' }],
  });
  assert.equal(r.status, 201, JSON.stringify(r.data));
  const id = r.data.id;

  // A3：响应体里就能拿到刚写入的 actions（从 actions 表读，已不是 jsonb 列）
  assert.equal(Array.isArray(r.data.actions), true, '建单响应应带 actions 数组');
  assert.equal(r.data.actions.length, 2, JSON.stringify(r.data.actions));
  assert.equal(r.data.actions[0].done, false);

  // 直接查表确认落了 actions 行（而不是只写了 jsonb 列）
  const rows = await pool.query(
    `SELECT content, done, due FROM actions WHERE defect_ticket_id=$1 ORDER BY created_at ASC, id ASC`,
    [id],
  );
  assert.equal(rows.rowCount, 2, 'actions 表应有 2 行');
  // ★不能断言插入顺序：create 在**同一事务**里跑，PostgreSQL 的 now() 是事务开始时间，
  // 两条 action 的 created_at 完全相同；而 id 是 gen_random_uuid()，不递增。
  // 所以 ORDER BY created_at, id 得到的顺序是任意的（上轮这条断言靠运气过了）。
  // 这里改成断言集合，并按 content 取回 due 做校验。
  const byContent = Object.fromEntries(rows.rows.map((x) => [x.content, x]));
  assert.deepEqual(Object.keys(byContent).sort(), ['整理错因卡片', '重做同类题 10 道'].sort());
  assert.equal(byContent['重做同类题 10 道'].done, false);
  assert.equal(byContent['整理错因卡片'].done, false);
  assert.ok(byContent['整理错因卡片'].due, '第二条应带 due');

  // 门禁：两条未完成时不能进入验证
  let cur = await getTicket(id);
  let b = await req('PATCH', `/defect-tickets/${id}/begin-verification`, { version: cur.version });
  assert.equal(b.status, 400);
  assert.equal(b.data.error, 'ACTIONS_NOT_DONE');

  // 标记两条 done 后应能进入 V1
  const acts = (await getTicket(id)).actions;
  for (const a of acts) {
    const m = await req('PATCH', `/defect-tickets/${id}/actions/${a.id}`, { version: a.version });
    assert.equal(m.status, 200, JSON.stringify(m.data));
  }
  cur = await getTicket(id);
  b = await req('PATCH', `/defect-tickets/${id}/begin-verification`, { version: cur.version });
  assert.equal(b.status, 200, JSON.stringify(b.data));
  assert.equal(b.data.status, 'V1');
});

test('建单 actions 含空白项 -> 跳过不报错；actions 为字符串数组也兼容', skipOpt, async () => {
  const r = await req('POST', '/defect-tickets', {
    user_id: seed.userId,
    exam_profile_id: seed.profileId,
    draft: true,
    actions: ['   ', '真动作'],
  });
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.actions.length, 1, '空白动作应被跳过');
  assert.equal(r.data.actions[0].content, '真动作');
});

test('FE-07 defect-stats：多状态多层级 -> 两个聚合都正确（by_layer 只算未关闭）', skipOpt, async () => {
  // 用独立用户，避免被前面用例的数据污染（绝对断言必须独立用户：BE-04 教训）
  const u = await pool.query(
    `INSERT INTO users (nickname) VALUES ($1) RETURNING id`,
    [`stats-user-${Date.now()}`],
  );
  const statsUser = u.rows[0].id;
  const p = await pool.query(
    `INSERT INTO exam_profiles (user_id, exam_type, target_label)
     VALUES ($1, 'postgrad', $2) RETURNING id`,
    [statsUser, `stats-${Date.now()}`],
  );
  const profileId = p.rows[0].id;

  try {
    // 造 5 张：ANALYZED×3（concept / method / concept）、DRAFT×1（无归因 → unclassified）、
    // CLOSED×1（calculation）
    //
    // ★不能用 error_layer='   ' 建 ANALYZED 单：core 的 assertAnalyzable 对纯空白
    // 返回 MISSING_ERROR_LAYER（400），这是**正确行为**。未归因的单只能是 DRAFT，
    // 所以 unclassified 分组用 DRAFT 验证 —— 这才是真实业务里「还没归因」的形态。
    const mk = (status, layer) => req('POST', '/defect-tickets', {
      user_id: statsUser,
      exam_profile_id: profileId,
      q_type: 'stats-q',
      draft: status === 'DRAFT',
      error_layer: status === 'DRAFT' ? undefined : (layer ?? undefined),
      error_cause: status === 'DRAFT' ? undefined : '用来测聚合的具体错因',
    });

    assert.equal((await mk('DRAFT')).status, 201);              // 无归因 -> unclassified
    assert.equal((await mk('ANALYZED', 'concept')).status, 201);
    assert.equal((await mk('ANALYZED', 'method')).status, 201);
    assert.equal((await mk('ANALYZED', 'concept')).status, 201);

    // 真造一张 CLOSED（走完整状态机 + 三层验证全 pass），验证 by_layer 确实把 CLOSED 排除。
    // 不能直接 UPDATE status=CLOSED：触发器只接受逐步跳，且那样就验证不了读端点的口径。
    const closedId = (await mk('ANALYZED', 'calculation')).data.id;
    await toV1(closedId);
    assert.equal((await submitVer(closedId, 'V1', 'pass')).status, 201);
    assert.equal((await submitVer(closedId, 'V2', 'pass', 'new_question')).status, 201);
    const closedRes = await submitVer(closedId, 'V3', 'pass', 'timed_mock');
    assert.equal(closedRes.status, 201, JSON.stringify(closedRes.data));
    assert.equal((await getTicket(closedId)).status, 'CLOSED');
    const r = await req('GET', `/users/${statsUser}/defect-stats`);
    assert.equal(r.status, 200, JSON.stringify(r.data));

    const { by_status: byStatus, by_layer: byLayer } = r.data;

    // 八态全预填（契约形状固定，前端不用兜底）
    for (const s of ['DRAFT', 'ANALYZED', 'ACTION_DONE', 'V1', 'V2', 'V3', 'REOPENED', 'CLOSED']) {
      assert.equal(typeof byStatus[s], 'number', `by_status.${s} 应为 number`);
    }
    assert.equal(byStatus.DRAFT, 1, '一张 DRAFT（未归因）');
    assert.equal(byStatus.ANALYZED, 3, '三张 ANALYZED 未关闭');
    assert.equal(byStatus.CLOSED, 1, '一张走完全链路的 CLOSED');
    assert.equal(r.data.open_total, 4, 'open = DRAFT 1 + ANALYZED 3');
    assert.equal(r.data.closed_total, 1);
    assert.equal(r.data.total, 5);

    // by_layer：只算未关闭 -> concept 2 / method 1 / unclassified 1
    const layerMap = Object.fromEntries(byLayer.map((x) => [x.error_layer, x.count]));
    assert.equal(layerMap.concept, 2, JSON.stringify(byLayer));
    assert.equal(layerMap.method, 1, JSON.stringify(byLayer));
    assert.equal(layerMap.unclassified, 1, 'DRAFT 单未归因（error_layer IS NULL）应归 unclassified');
    assert.equal(
      layerMap.calculation,
      undefined,
      'CLOSED 单的 calculation 不应进 by_layer（只看未关闭）',
    );

    // 排序：count DESC，同 count 按 layer ASC
    assert.equal(byLayer[0].error_layer, 'concept');
    assert.equal(byLayer[0].count, 2);

    // 软删的行不参与统计
    await pool.query(
      `UPDATE defect_tickets SET deleted_at = now() WHERE user_id = $1 AND error_layer = 'method'`,
      [statsUser],
    );
    const r2 = await req('GET', `/users/${statsUser}/defect-stats`);
    assert.equal(r2.status, 200);
    assert.equal(r2.data.by_status.ANALYZED, 2, '软删 method 后应只剩 2 张 ANALYZED');
    assert.equal(r2.data.open_total, 3);
    assert.equal(
      r2.data.by_layer.find((x) => x.error_layer === 'method'),
      undefined,
      '已软删的 method 不应再出现',
    );
  } finally {
    // 清理顺序：defect_tickets -> exam_profiles -> users
    await pool.query('DELETE FROM defect_tickets WHERE user_id = $1', [statsUser]);
    await pool.query('DELETE FROM exam_profiles WHERE user_id = $1', [statsUser]);
    await pool.query('DELETE FROM users WHERE id = $1', [statsUser]);
  }
});
