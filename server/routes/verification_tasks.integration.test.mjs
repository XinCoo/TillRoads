// server/routes/verification_tasks.integration.test.mjs
// 题路 TillRoad · BE-04 T4：验证任务列表 + 临期提醒的真实 PG 集成测试
//
// 与 server/index.test.mjs（fake 层）分工：
//   * index.test.mjs                —— 路由层：参数解析、非法 stage/urgency -> 400、只读（POST/PATCH/DELETE -> 404）。
//   * server/verify_window.test.mjs —— urgency 的**数学**边界（daysLeft = 0/3/4、负数、向下取整）。
//   * 本文件                         —— 真库验证三件 fake 证明不了的事：
//                                      ① 数据源过滤：只出 V1/V2/V3，ACTION_DONE / REOPENED / 软删都不出；
//                                      ② entered_at 的**混合取法**在真 SQL 里的行为：
//                                         V2/V3 取「上一阶段 pass 记录的 created_at」（精确），V1 退化取 updated_at；
//                                      ③ JOIN knowledge_nodes / subjects 的展示字段。
//
// ★测试隔离：每个用例用自己的 user（`freshUser()`）。
//   共享一个 user 会让「total === N」这类绝对断言被前面用例的单子污染——这类 bug 本机全 skip 时看不见，
//   一到 CI 真跑就爆。宁可每个用例多插一行 users，也不要留下顺序依赖。
// 只有 RUN_PG_INTEGRATION=1 才跑，CI 会设。

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { createPool } from '../db/pool.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { createApp } from '../index.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN ? {} : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

const HERE = dirname(fileURLToPath(import.meta.url));
// ★ m17431：schema 解冻后要连「基线 schema + 增量迁移」一起跑
//   （owner_user_id 列在 migrations/0002_questions_owner.sql 里，不在 schema.sql 里）。
import { FULL_SCHEMA_SQL } from './../db/test_schema.mjs';

let pool;
let app;
let base;
let seed; // { profileId, subjectId, nodeId } —— 共享的科目/考点基线
const createdUsers = [];

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

/** 建一个只属于本用例的用户，返回其 id。 */
async function freshUser(nickname = '验证任务用例用户') {
  const c = await pool.connect();
  try {
    const u = await c.query(
      `INSERT INTO users (nickname, timezone, role) VALUES ($1,$2,$3) RETURNING id`,
      [nickname, 'Asia/Shanghai', 'student'],
    );
    const id = u.rows[0].id;
    createdUsers.push(id);
    return id;
  } finally {
    c.release();
  }
}

async function getTicket(id) {
  const r = await req('GET', `/defect-tickets/${id}`);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  return r.data;
}

/** 建一张 ANALYZED 缺陷单（带完整归因 + 考点，直接过 core 前置校验）。 */
async function newAnalyzed(userId, extra = {}) {
  const r = await req('POST', '/defect-tickets', {
    user_id: userId,
    exam_profile_id: seed.profileId,
    knowledge_node_id: seed.nodeId,
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
async function submitVer(id, stage, result, verifyType = 'redo_hidden') {
  const cur = await getTicket(id);
  return req('POST', `/defect-tickets/${id}/verifications`, {
    stage,
    result,
    verify_type: verifyType,
    version: cur.version,
  });
}

/** 推到 V2：toV1 后 V1 pass。 */
async function toV2(id) {
  await toV1(id);
  const r = await submitVer(id, 'V1', 'pass', 'redo_hidden');
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.ticket.status, 'V2');
  return r.data.ticket;
}

/** 推到 V3：toV2 后 V2 pass。 */
async function toV3(id) {
  await toV2(id);
  const r = await submitVer(id, 'V2', 'pass', 'similar_variant');
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.ticket.status, 'V3');
  return r.data.ticket;
}

/**
 * 把某张单「进入当前阶段」的时间往前推 N 天。
 * V2/V3 的 entered_at 取的是上一阶段 pass 记录的 created_at —— 直接改那条记录即可，
 * 不需要等，也不需要碰 defect_tickets（那是触发器管的）。
 */
async function backdateStagePass(defectTicketId, stage, days) {
  const r = await pool.query(
    `UPDATE verifications
        SET created_at = now() - ($3 || ' days')::interval
      WHERE defect_ticket_id = $1 AND stage = $2 AND result = 'pass' AND deleted_at IS NULL
      RETURNING id`,
    [defectTicketId, stage, String(days)],
  );
  assert.ok(r.rowCount >= 1, `backdate: 找不到 ${defectTicketId} 的 ${stage} pass 记录`);
}

/** 读某用户的验证任务列表。 */
async function listTasks(userId, query = '') {
  return req('GET', `/users/${userId}/verification-tasks${query}`);
}

/** 读某用户的看板聚合。 */
async function getSummary(userId) {
  return req('GET', `/users/${userId}/verification-summary`);
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

  // 共享基线：一个 owner user + exam_profile + subject + knowledge_node
  // （defect_tickets 的 exam_profile_id 是 NOT NULL FK；考点用于验 JOIN 展示字段）
  const c = await pool.connect();
  let ownerId;
  try {
    const u = await c.query(
      `INSERT INTO users (nickname, timezone, role) VALUES ($1,$2,$3) RETURNING id`,
      ['验证任务基线用户', 'Asia/Shanghai', 'student'],
    );
    ownerId = u.rows[0].id;
    createdUsers.push(ownerId);

    const p = await c.query(
      `INSERT INTO exam_profiles (user_id, exam_type, target_label, exam_date, daily_minutes, status)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
      [ownerId, 'postgrad', '验证任务集成目标', '2027-12-20', 120, 'active'],
    );
    const s = await c.query(
      `INSERT INTO subjects (exam_profile_id, name, kind) VALUES ($1,$2,$3) RETURNING id`,
      [p.rows[0].id, '数学一', 'objective'],
    );
    const n = await c.query(
      `INSERT INTO knowledge_nodes (subject_id, title, freq_tag, weight_to_target)
       VALUES ($1,$2,$3,$4) RETURNING id`,
      [s.rows[0].id, '极限与连续', 'high', 0.35],
    );
    seed = { profileId: p.rows[0].id, subjectId: s.rows[0].id, nodeId: n.rows[0].id };
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
    if (createdUsers.length > 0) {
      await c.query(
        `DELETE FROM verifications WHERE defect_ticket_id IN (SELECT id FROM defect_tickets WHERE user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      await c.query(
        `DELETE FROM actions WHERE defect_ticket_id IN (SELECT id FROM defect_tickets WHERE user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      await c.query(`DELETE FROM defect_tickets WHERE user_id = ANY($1::uuid[])`, [createdUsers]);
      await c.query(`DELETE FROM exam_profiles WHERE user_id = ANY($1::uuid[])`, [createdUsers]);
    }
    if (seed) {
      await c.query(`DELETE FROM knowledge_nodes WHERE subject_id=$1`, [seed.subjectId]);
      await c.query(`DELETE FROM subjects WHERE exam_profile_id=$1`, [seed.profileId]);
    }
    if (createdUsers.length > 0) {
      await c.query(`DELETE FROM users WHERE id = ANY($1::uuid[])`, [createdUsers]);
    }
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
// 1) 数据源过滤：只出 V1/V2/V3
// ---------------------------------------------------------------------------

test('列表只返回 V1/V2/V3：ACTION_DONE / REOPENED / ANALYZED 都不出现', skipOpt, async () => {
  const uid = await freshUser('过滤用例');

  // 一张停在 ACTION_DONE（action 全完成但没 begin-verification）
  const doneId = await newAnalyzed(uid);
  const a = await req('POST', `/defect-tickets/${doneId}/actions`, { action: '重做' });
  await req('PATCH', `/defect-tickets/${doneId}/actions/${a.data.id}`, { version: a.data.version });

  // 一张停在 ANALYZED
  const analyzedId = await newAnalyzed(uid);
  assert.ok(analyzedId);

  // 一张 REOPENED（V1 fail）
  const reopenedId = await newAnalyzed(uid);
  await toV1(reopenedId);
  const f = await submitVer(reopenedId, 'V1', 'fail', 'redo_hidden');
  assert.equal(f.status, 201, JSON.stringify(f.data));
  assert.equal(f.data.ticket.status, 'REOPENED');

  // 三张处于 V1 / V2 / V3
  const v1Id = await newAnalyzed(uid);
  await toV1(v1Id);
  const v2Id = await newAnalyzed(uid);
  await toV2(v2Id);
  const v3Id = await newAnalyzed(uid);
  await toV3(v3Id);

  const r = await listTasks(uid);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.total, 3, '只有 V1/V2/V3 三张进列表');
  assert.deepEqual(r.data.items.map((it) => it.id).sort(), [v1Id, v2Id, v3Id].sort());
  assert.deepEqual(r.data.items.map((it) => it.stage).sort(), ['V1', 'V2', 'V3']);
});

test('未进入验证窗口的 ANALYZED / ACTION_DONE 不进列表', skipOpt, async () => {
  const uid = await freshUser('未进窗口用例');
  const analyzedId = await newAnalyzed(uid);
  assert.ok(analyzedId);

  const r = await listTasks(uid);
  assert.equal(r.status, 200);
  assert.equal(r.data.total, 0, 'ANALYZED 不应出现在验证任务列表');
  assert.deepEqual(r.data.items, []);
});

// ---------------------------------------------------------------------------
// 2) entered_at 的混合取法
// ---------------------------------------------------------------------------

test('V2 的 entered_at 取「本 round 内 V1 pass 的 created_at」（精确）', skipOpt, async () => {
  const uid = await freshUser('V2 进入时间用例');
  const id = await newAnalyzed(uid);
  await toV2(id);
  await backdateStagePass(id, 'V1', 5);

  const r = await listTasks(uid, '?status=V2');
  const row = r.data.items.find((it) => it.id === id);
  assert.ok(row, 'V2 单应出现在列表');

  // 已过 5 天（V2 窗口 14）→ 剩 9 天，normal
  assert.equal(row.window_days, 14);
  assert.equal(row.elapsed_days, 5);
  assert.equal(row.days_left, 9);
  assert.equal(row.urgency, 'normal');
});

test('V3 的 entered_at 取「本 round 内 V2 pass 的 created_at」（精确）', skipOpt, async () => {
  const uid = await freshUser('V3 进入时间用例');
  const id = await newAnalyzed(uid);
  await toV3(id);
  await backdateStagePass(id, 'V2', 19);

  const r = await listTasks(uid, '?status=V3');
  const row = r.data.items.find((it) => it.id === id);
  assert.ok(row, 'V3 单应出现在列表');

  // 已过 19 天（V3 窗口 21）→ 剩 2 天 → due_soon
  assert.equal(row.window_days, 21);
  assert.equal(row.elapsed_days, 19);
  assert.equal(row.days_left, 2);
  assert.equal(row.urgency, 'due_soon');
});

test('V1 的 entered_at 退化取 updated_at（近似）：非状态字段被 patch 会让它后移', skipOpt, async () => {
  const uid = await freshUser('V1 近似取法用例');
  const id = await newAnalyzed(uid);
  const v1 = await toV1(id);

  const before = await listTasks(uid, '?status=V1');
  const rowBefore = before.data.items.find((it) => it.id === id);
  assert.ok(rowBefore, 'V1 单应出现在列表');
  const enteredBefore = new Date(rowBefore.entered_at).getTime();

  // patch 一个与状态无关的字段（priority），只为了让 set_updated() 抬高 updated_at
  await new Promise((resolve) => setTimeout(resolve, 20));
  const p = await req('PATCH', `/defect-tickets/${id}`, { version: v1.version, priority: 'P1' });
  assert.equal(p.status, 200, JSON.stringify(p.data));

  const afterwards = await listTasks(uid, '?status=V1');
  const rowAfter = afterwards.data.items.find((it) => it.id === id);
  const enteredAfter = new Date(rowAfter.entered_at).getTime();

  assert.ok(
    enteredAfter > enteredBefore,
    `V1 的 entered_at 应随 updated_at 漂移（近似取法的已知偏差）：${rowBefore.entered_at} -> ${rowAfter.entered_at}`,
  );
});

test('重开后新 round 的进入时间不复用旧 round 的 pass 记录', skipOpt, async () => {
  const uid = await freshUser('round 隔离用例');
  const id = await newAnalyzed(uid);

  // round 1：V1 pass → V2 → V2 fail → REOPENED
  await toV2(id);
  const f = await submitVer(id, 'V2', 'fail', 'similar_variant');
  assert.equal(f.status, 201, JSON.stringify(f.data));
  assert.equal(f.data.ticket.status, 'REOPENED');

  // 把 round 1 的 V1 pass 记录推得很早
  await backdateStagePass(id, 'V1', 40);

  // reanalyze → round 2，再进 V2（round 2 的 V1 pass 是刚刚发生的）
  const cur = await getTicket(id);
  const re = await req('PATCH', `/defect-tickets/${id}/reanalyze`, {
    version: cur.version,
    error_layer: 'concept',
    error_cause: '重开后再归因一次',
  });
  assert.equal(re.status, 200, JSON.stringify(re.data));
  assert.equal(re.data.verification_round, 2);
  await toV2(id);

  const r = await listTasks(uid, '?status=V2');
  const row = r.data.items.find((it) => it.id === id);
  assert.ok(row);
  assert.equal(row.verification_round, 2);
  // round 2 的 V1 pass 是刚发生的 → elapsedDays 0、daysLeft 14
  // 若错误地取了 round 1 那条 40 天前的记录，这里会是负数
  assert.equal(row.elapsed_days, 0, '不能取旧 round 的 pass 记录当进入时间');
  assert.equal(row.days_left, 14);
});

// ---------------------------------------------------------------------------
// 3) urgency 三态
// ---------------------------------------------------------------------------

test('urgency 三态：overdue / due_soon / normal 三种同时成立', skipOpt, async () => {
  const uid = await freshUser('三态用例');

  // overdue：V2，已过 20 天 > 窗口 14
  const overdueId = await newAnalyzed(uid);
  await toV2(overdueId);
  await backdateStagePass(overdueId, 'V1', 20);

  // due_soon：V3，已过 19 天，窗口 21 → 剩 2
  const dueSoonId = await newAnalyzed(uid);
  await toV3(dueSoonId);
  await backdateStagePass(dueSoonId, 'V2', 19);

  // normal：刚进 V1
  const normalId = await newAnalyzed(uid);
  await toV1(normalId);

  const all = await listTasks(uid);
  assert.equal(all.data.total, 3);
  const byId = new Map(all.data.items.map((it) => [it.id, it]));

  assert.equal(byId.get(overdueId).urgency, 'overdue');
  assert.equal(byId.get(overdueId).days_left, -6);
  assert.equal(byId.get(overdueId).overdue_days, 6);

  assert.equal(byId.get(dueSoonId).urgency, 'due_soon');
  assert.equal(byId.get(dueSoonId).days_left, 2);
  assert.equal(byId.get(dueSoonId).overdue_days, 0);

  assert.equal(byId.get(normalId).urgency, 'normal');
  assert.equal(byId.get(normalId).days_left, 7);
  assert.equal(byId.get(normalId).overdue_days, 0);
});

test('urgency 过滤：?urgency=overdue 只返回逾期单', skipOpt, async () => {
  const uid = await freshUser('urgency 单值过滤用例');
  const overdueId = await newAnalyzed(uid);
  await toV2(overdueId);
  await backdateStagePass(overdueId, 'V1', 25);

  const justIn = await newAnalyzed(uid);
  await toV1(justIn);

  const r = await listTasks(uid, '?urgency=overdue');
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.total, 1);
  assert.equal(r.data.items[0].id, overdueId);
  assert.equal(r.data.items[0].urgency, 'overdue');
});

test('urgency 过滤：多值逗号分隔可用（overdue,due_soon）', skipOpt, async () => {
  const uid = await freshUser('urgency 多值过滤用例');
  const overdueId = await newAnalyzed(uid);
  await toV2(overdueId);
  await backdateStagePass(overdueId, 'V1', 30);

  const dueSoonId = await newAnalyzed(uid);
  await toV3(dueSoonId);
  await backdateStagePass(dueSoonId, 'V2', 20);

  const normalId = await newAnalyzed(uid);
  await toV1(normalId);

  const r = await listTasks(uid, '?urgency=overdue,due_soon');
  assert.equal(r.status, 200, JSON.stringify(r.data));
  const ids = r.data.items.map((it) => it.id).sort();
  assert.deepEqual(ids, [overdueId, dueSoonId].sort());
  assert.ok(!ids.includes(normalId), 'normal 单不应出现');
});

// ---------------------------------------------------------------------------
// 4) stage 过滤 + 排序
// ---------------------------------------------------------------------------

test('stage 过滤：?status=V2 只返回 V2', skipOpt, async () => {
  const uid = await freshUser('stage 过滤用例');
  const v1Id = await newAnalyzed(uid);
  await toV1(v1Id);
  const v2Id = await newAnalyzed(uid);
  await toV2(v2Id);

  const r = await listTasks(uid, '?status=V2');
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.total, 1);
  assert.equal(r.data.items[0].id, v2Id);
  assert.equal(r.data.items[0].stage, 'V2');
});

test('排序：按 entered_at 升序（越早进入越靠前）', skipOpt, async () => {
  const uid = await freshUser('排序用例');
  const early = await newAnalyzed(uid);
  await toV2(early);
  await backdateStagePass(early, 'V1', 12);

  const late = await newAnalyzed(uid);
  await toV1(late);

  const r = await listTasks(uid);
  const idxEarly = r.data.items.findIndex((it) => it.id === early);
  const idxLate = r.data.items.findIndex((it) => it.id === late);
  assert.ok(idxEarly >= 0 && idxLate >= 0);
  assert.ok(idxEarly < idxLate, `进入更早的应排前面：early@${idxEarly} vs late@${idxLate}`);
});

// ---------------------------------------------------------------------------
// 5) summary 聚合
// ---------------------------------------------------------------------------

test('summary：by_stage / by_urgency 与列表逐项一致', skipOpt, async () => {
  const uid = await freshUser('summary 用例');
  const id1 = await newAnalyzed(uid);
  await toV1(id1);
  const id2 = await newAnalyzed(uid);
  await toV2(id2);
  const id3 = await newAnalyzed(uid);
  await toV3(id3);
  await backdateStagePass(id3, 'V2', 22); // V3 逾期（窗口 21）

  const list = await listTasks(uid);
  const sum = await getSummary(uid);
  assert.equal(sum.status, 200, JSON.stringify(sum.data));

  assert.equal(sum.data.total, list.data.total, 'summary.total 必须等于列表 total');
  assert.equal(
    sum.data.by_stage.V1 + sum.data.by_stage.V2 + sum.data.by_stage.V3,
    sum.data.total,
    'by_stage 三项之和应等于 total',
  );
  assert.equal(
    sum.data.by_urgency.overdue + sum.data.by_urgency.due_soon + sum.data.by_urgency.normal,
    sum.data.total,
    'by_urgency 三项之和应等于 total',
  );

  // 与列表实际分布逐项对账
  const countBy = (key) =>
    list.data.items.reduce((acc, it) => {
      acc[it[key]] = (acc[it[key]] || 0) + 1;
      return acc;
    }, {});
  const stageCount = countBy('stage');
  const urgencyCount = countBy('urgency');
  for (const stage of ['V1', 'V2', 'V3']) {
    assert.equal(sum.data.by_stage[stage], stageCount[stage] || 0, `by_stage.${stage} 对不上`);
  }
  for (const u of ['overdue', 'due_soon', 'normal']) {
    assert.equal(sum.data.by_urgency[u], urgencyCount[u] || 0, `by_urgency.${u} 对不上`);
  }

  // 顶层扁平计数与 by_urgency 同源
  assert.equal(sum.data.overdue, sum.data.by_urgency.overdue);
  assert.equal(sum.data.due_soon, sum.data.by_urgency.due_soon);
  assert.equal(sum.data.normal, sum.data.by_urgency.normal);
});

// ---------------------------------------------------------------------------
// 6) JOIN 展示字段
// ---------------------------------------------------------------------------

test('列表带出考点与科目展示字段（JOIN knowledge_nodes / subjects）', skipOpt, async () => {
  const uid = await freshUser('JOIN 用例');
  const id = await newAnalyzed(uid);
  await toV1(id);

  const r = await listTasks(uid, '?status=V1');
  const row = r.data.items.find((it) => it.id === id);
  assert.ok(row);
  assert.equal(row.knowledge_node_id, seed.nodeId);
  assert.equal(row.knowledge_node_title, '极限与连续');
  assert.equal(row.knowledge_node_freq_tag, 'high');
  assert.equal(row.subject_id, seed.subjectId);
  assert.equal(row.subject_name, '数学一');
});

test('没有考点的单子也能出列表（LEFT JOIN 不丢行，展示字段为 null）', skipOpt, async () => {
  const uid = await freshUser('无考点用例');
  // 建一张不带 knowledge_node_id 的
  const r0 = await req('POST', '/defect-tickets', {
    user_id: uid,
    exam_profile_id: seed.profileId,
    error_layer: 'concept',
    error_cause: '把充分条件当成必要条件导致判断错误',
  });
  assert.equal(r0.status, 201, JSON.stringify(r0.data));
  const id = r0.data.id;
  await toV1(id);

  const r = await listTasks(uid, '?status=V1');
  const row = r.data.items.find((it) => it.id === id);
  assert.ok(row, 'LEFT JOIN 必须保留没有考点的行');
  assert.equal(row.knowledge_node_title, null);
  assert.equal(row.subject_name, null);
  assert.equal(row.stage, 'V1');
});

// ---------------------------------------------------------------------------
// 7) 软删排除
// ---------------------------------------------------------------------------

test('软删的缺陷单不进列表（deleted_at IS NULL）', skipOpt, async () => {
  const uid = await freshUser('软删用例');
  const id = await newAnalyzed(uid);
  await toV1(id);

  const beforeDel = await listTasks(uid, '?status=V1');
  assert.equal(beforeDel.data.total, 1, '删除前应在列表');

  const cur = await getTicket(id);
  const del = await req('DELETE', `/defect-tickets/${id}`, { version: cur.version });
  assert.equal(del.status, 200, JSON.stringify(del.data));

  const afterDel = await listTasks(uid, '?status=V1');
  assert.equal(afterDel.data.total, 0, '软删后不应在列表');
  assert.ok(!afterDel.data.items.some((it) => it.id === id));
});

// ---------------------------------------------------------------------------
// 8) 分页 + 空用户
// ---------------------------------------------------------------------------

test('分页：limit/offset 生效，total 是分页前的总数', skipOpt, async () => {
  const uid = await freshUser('分页用例');
  for (let i = 0; i < 3; i += 1) {
    const id = await newAnalyzed(uid);
    await toV1(id);
  }

  const all = await listTasks(uid);
  assert.equal(all.data.total, 3);

  const page1 = await listTasks(uid, '?limit=2&offset=0');
  assert.equal(page1.status, 200);
  assert.equal(page1.data.items.length, 2);
  assert.equal(page1.data.limit, 2);
  assert.equal(page1.data.offset, 0);
  assert.equal(page1.data.total, 3, 'total 不随分页变化');

  const page2 = await listTasks(uid, '?limit=2&offset=2');
  assert.equal(page2.status, 200);
  assert.equal(page2.data.items.length, 1);
  assert.notDeepEqual(
    page1.data.items.map((it) => it.id),
    page2.data.items.map((it) => it.id),
    '第二页不应与第一页重复',
  );
});

test('空用户返回空列表与全零 summary', skipOpt, async () => {
  const ghostId = await freshUser('空用户');

  const list = await listTasks(ghostId);
  assert.equal(list.status, 200);
  assert.deepEqual(list.data.items, []);
  assert.equal(list.data.total, 0);

  const sum = await getSummary(ghostId);
  assert.equal(sum.status, 200);
  assert.equal(sum.data.total, 0);
  assert.deepEqual(sum.data.by_stage, { V1: 0, V2: 0, V3: 0 });
  assert.deepEqual(sum.data.by_urgency, { overdue: 0, due_soon: 0, normal: 0 });
});

// ---------------------------------------------------------------------------
// 9) 响应字段形态
// ---------------------------------------------------------------------------

test('行字段形态：entered_at/due_at 是 ISO 字符串，数值字段是 number', skipOpt, async () => {
  const uid = await freshUser('字段形态用例');
  const id = await newAnalyzed(uid);
  await toV2(id);
  await backdateStagePass(id, 'V1', 3);

  const r = await listTasks(uid, '?status=V2');
  const row = r.data.items.find((it) => it.id === id);
  assert.ok(row);

  assert.equal(typeof row.entered_at, 'string');
  assert.ok(!Number.isNaN(Date.parse(row.entered_at)), 'entered_at 应可被 Date.parse');
  assert.equal(typeof row.due_at, 'string');
  assert.ok(!Number.isNaN(Date.parse(row.due_at)), 'due_at 应可被 Date.parse');

  for (const k of ['window_days', 'days_left', 'overdue_days', 'elapsed_days', 'verification_round', 'reopen_count']) {
    assert.equal(typeof row[k], 'number', `${k} 应为 number（pg numeric/int 已由 pool 类型解析转 number）`);
  }

  // due_at = entered_at + window_days 天
  const deltaDays = Math.round((Date.parse(row.due_at) - Date.parse(row.entered_at)) / 86400000);
  assert.equal(deltaDays, row.window_days);
});

// ---------------------------------------------------------------------------
// 10) 用户隔离
// ---------------------------------------------------------------------------

test('用户隔离：别人看不到我的验证任务', skipOpt, async () => {
  const mine = await freshUser('隔离-我');
  const theirs = await freshUser('隔离-别人');

  const id = await newAnalyzed(mine);
  await toV1(id);

  const myList = await listTasks(mine);
  const theirList = await listTasks(theirs);
  assert.equal(myList.data.total, 1);
  assert.equal(theirList.status, 200);
  assert.equal(theirList.data.total, 0, '另一个用户不应看到我的单');

  const theirSum = await getSummary(theirs);
  assert.equal(theirSum.data.total, 0);
});
