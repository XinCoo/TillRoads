// server/routes/review_cycles.integration.test.mjs
// 题路 TillRoad · BE-06 T5：复盘快照端点（真 PG 集成测试）
//
// 只在 CI（RUN_PG_INTEGRATION=1）跑；本机无 PG 时全部 skip。
//
// 隔离设计（吸收 BE-04 / BE-05 的教训）：
//   · 每个用例 `freshUser()` 建独立用户，**绝不共享 seed 用户** ——
//     共享 seed 时 `total === 3` 这类绝对断言会被前面用例的数据污染，
//     本机全 skip 根本看不见，一到 CI 就爆（BE-03 为此刻过 8 条失败）。
//   · `after()` 里清理失败不得连带跳过关服：清理语句一律 try/catch 收进
//     cleanupFailure，finally 里无条件 app.close() + pool.end()，最后再抛。
//     否则一个 23503 就会让 HTTP server 与连接池留着活 handle，进程退不出去，
//     CI 挂 3 小时被 cancel（BE-05 的真实事故）。
//   · 外键删除顺序按引用图排：
//     attempts → mock_exams → verifications → actions → defect_tickets →
//     questions → knowledge_nodes → subjects → exam_profiles → users →
//     review_cycles（review_cycles 引用 users，必须在 users 之前删）

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
const SCHEMA_SQL = readFileSync(join(HERE, '..', '..', 'schema.sql'), 'utf8');

let pool;
let app;
let base;
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
async function freshUser(nickname = '复盘用例用户') {
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

/**
 * 给用户建一套 profile/subject/knowledge_node，返回 id 三元组。
 * 复盘要 JOIN 考点标题、要按 profile 取 target_score，所以这些都得真建。
 */
async function freshTree(userId, { targetScore = 420, nodeTitle = '极限与连续' } = {}) {
  const c = await pool.connect();
  try {
    const p = await c.query(
      `INSERT INTO exam_profiles (user_id, exam_type, target_label, target_score, exam_date, daily_minutes, status)
       VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
      [userId, 'postgrad', '复盘集成目标', targetScore, '2027-12-20', 120, 'active'],
    );
    const s = await c.query(
      `INSERT INTO subjects (exam_profile_id, name, kind) VALUES ($1,$2,$3) RETURNING id`,
      [p.rows[0].id, '数学一', 'objective'],
    );
    const n = await c.query(
      `INSERT INTO knowledge_nodes (subject_id, title, freq_tag, weight_to_target)
       VALUES ($1,$2,$3,$4) RETURNING id`,
      [s.rows[0].id, nodeTitle, 'high', 0.35],
    );
    return { profileId: p.rows[0].id, subjectId: s.rows[0].id, nodeId: n.rows[0].id };
  } finally {
    c.release();
  }
}


/** 建一张指定状态的缺陷单（直接写库，绕开状态机以保证构造速度）。 */
async function insertTicket(userId, tree, { status = 'ANALYZED', errorLayer = 'concept', reopenCount = 0, nodeId } = {}) {
  const c = await pool.connect();
  try {
    const r = await c.query(
      `INSERT INTO defect_tickets
         (user_id, exam_profile_id, knowledge_node_id, error_layer, error_cause, status, reopen_count)
       VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
      [userId, tree.profileId, nodeId ?? tree.nodeId, errorLayer, '复盘集成用归因', status, reopenCount],
    );
    return r.rows[0].id;
  } finally {
    c.release();
  }
}

/** 直接写一条验证记录（result 用枚举值）。 */
async function insertVerification(defectTicketId, { stage = 'V1', round = 1, result = 'pass', verifyType = 'redo_hidden' } = {}) {
  const c = await pool.connect();
  try {
    const r = await c.query(
      `INSERT INTO verifications (defect_ticket_id, stage, round, verify_type, result)
       VALUES ($1,$2,$3,$4,$5) RETURNING id`,
      [defectTicketId, stage, round, verifyType, result],
    );
    return r.rows[0].id;
  } finally {
    c.release();
  }
}

/**
 * 按目标准确率造出 questions 判分行。
 *
 * 关键：mockAccuracy() / computeStability() 只认 mock_exams.questions 里的
 * is_correct 字段，**不读** report.overall.accuracy。两者都要写，且必须一致，
 * 否则 stability 恒为 0（PGlite 真库验证踩过）。
 * 固定 2 行：accuracy>=1 -> 2 真；0.5 -> 1 真 1 假；<=0 -> 2 假。
 */
function buildJudgeRows(accuracy = 0.5) {
  const total = 2;
  const correct = Math.max(0, Math.min(total, Math.round(accuracy * total)));
  return Array.from({ length: total }, (_, i) => ({
    question_id: null,
    attempt_id: null,
    is_correct: i < correct,
    duration_ms: 1000,
  }));
}

/** 建一场已提交的模考（带 report，供 mock_stability / target_progress 用）。 */
async function insertSubmittedMock(tree, { accuracy = 0.5, ageDays = 0 } = {}) {
  const c = await pool.connect();
  try {
    const report = {
      module_accuracy: {},
      avg_duration_ms: { overall: 1000, by_knowledge_node: {} },
      stability: null,
      defect_repeat_rate: { repeat_count: 0, total_wrong: 0, rate: 0 },
      strategy_execution: null,
      v3_candidates: [],
      overall: { correct: Math.round(accuracy * 2), total: 2, accuracy, ungraded: 0 },
      ungraded_count: 0,
    };
    const r = await c.query(
      `INSERT INTO mock_exams (exam_profile_id, mode, duration_limit_ms, questions, report, updated_at)
       VALUES ($1,$2,$3,$4::jsonb,$5::jsonb, now() - ($6 || ' days')::interval)
       RETURNING id`,
      [
        tree.profileId,
        'module',
        1_800_000,
        // mockAccuracy() 读的是 questions 里的 is_correct（不是 report.overall），
        // 故必须按 accuracy 造出对应数量的判分行，否则稳定度恒为 0（PGlite 踩过）。
        JSON.stringify(buildJudgeRows(accuracy)),
        JSON.stringify(report),
        String(ageDays),
      ],
    );
    return r.rows[0].id;
  } finally {
    c.release();
  }
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
      // 外键顺序：引用者先删。
      await c.query(
        `DELETE FROM attempts WHERE user_id = ANY($1::uuid[])`,
        [createdUsers],
      );
      await c.query(
        `DELETE FROM mock_exams WHERE exam_profile_id IN (SELECT id FROM exam_profiles WHERE user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      await c.query(
        `DELETE FROM verifications WHERE defect_ticket_id IN (SELECT id FROM defect_tickets WHERE user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      await c.query(
        `DELETE FROM actions WHERE defect_ticket_id IN (SELECT id FROM defect_tickets WHERE user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      // defect_tickets 必须先于 questions（defect_tickets.question_id 引用它）
      await c.query(`DELETE FROM defect_tickets WHERE user_id = ANY($1::uuid[])`, [createdUsers]);
      await c.query(
        `DELETE FROM questions WHERE subject_id IN (
           SELECT s.id FROM subjects s
             JOIN exam_profiles p ON p.id = s.exam_profile_id
            WHERE p.user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      await c.query(
        `DELETE FROM knowledge_nodes WHERE subject_id IN (
           SELECT s.id FROM subjects s
             JOIN exam_profiles p ON p.id = s.exam_profile_id
            WHERE p.user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      await c.query(
        `DELETE FROM subjects WHERE exam_profile_id IN (SELECT id FROM exam_profiles WHERE user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      await c.query(`DELETE FROM exam_profiles WHERE user_id = ANY($1::uuid[])`, [createdUsers]);
      // review_cycles 引用 users，必须在 users 之前删
      await c.query(`DELETE FROM review_cycles WHERE user_id = ANY($1::uuid[])`, [createdUsers]);
      await c.query(`DELETE FROM users WHERE id = ANY($1::uuid[])`, [createdUsers]);
    }
  } catch (cleanupError) {
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
// 1) 生成 + 读取一致性
// ---------------------------------------------------------------------------

test('POST /review-cycles：生成 weekly 快照，metrics 六项真实聚合', skipOpt, async () => {
  const userId = await freshUser('复盘-生成');
  const tree = await freshTree(userId, { targetScore: 400 });

  // 两张未关闭的单（ANALYZED / V1），一张已关闭（CLOSED）
  await insertTicket(userId, tree, { status: 'ANALYZED', errorLayer: 'concept' });
  await insertTicket(userId, tree, { status: 'V1', errorLayer: 'method' });
  await insertTicket(userId, tree, { status: 'CLOSED', errorLayer: 'concept' });

  // V1 单上一条 pass、一条 fail（验 pass_rate）
  const v1Id = await insertTicket(userId, tree, { status: 'V2', errorLayer: 'concept' });
  await insertVerification(v1Id, { stage: 'V1', result: 'pass' });
  await insertVerification(v1Id, { stage: 'V2', result: 'fail' });

  // 一场已提交模考（accuracy 0.5 -> 折算 50 分，target 400 -> rate 0.125）
  await insertSubmittedMock(tree, { accuracy: 0.5 });

  const r = await req('POST', '/review-cycles', { user_id: userId, cycle_type: 'weekly' });
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.match(r.data.period, /^\d{4}-W\d{2}$/);
  assert.equal(r.data.cycle_type, 'weekly');
  assert.equal(r.data.completed, false);
  assert.equal(r.data.time_zone, 'Asia/Shanghai');
  assert.ok(r.data.period_start_at && r.data.period_end_at);
  assert.ok(new Date(r.data.period_end_at) > new Date(r.data.period_start_at));

  const m = r.data.metrics;

  // open_defects：时点量，排除 CLOSED，by_status 只含有数据的键（预填七态为 0）
  assert.equal(m.open_defects.total, 4, JSON.stringify(m.open_defects));
  assert.equal(m.open_defects.by_status.ANALYZED, 1);
  assert.equal(m.open_defects.by_status.V1, 1);
  assert.equal(m.open_defects.by_status.V2, 1);
  assert.equal(m.open_defects.by_status.CLOSED, undefined, 'CLOSED 不该出现在 by_status');
  assert.equal(m.open_defects.by_status.DRAFT, 0);

  // layer_dist：周期内新建，按 error_layer 分组
  assert.equal(m.layer_dist.concept, 4, JSON.stringify(m.layer_dist));
  assert.equal(m.layer_dist.method, 1);

  // verify_pass_rate：1 pass / 1 fail / total 2 -> 0.5
  assert.equal(m.verify_pass_rate.pass, 1);
  assert.equal(m.verify_pass_rate.fail, 1);
  assert.equal(m.verify_pass_rate.total, 2);
  assert.equal(m.verify_pass_rate.rate, 0.5);

  // mock_stability：只有 1 场模考 -> 样本不足返回 null
  assert.equal(m.mock_stability, null);

  // target_progress：accuracy 0.5 -> 50 分 / target 400 -> 0.125
  assert.equal(m.target_progress.target_score, 400);
  assert.equal(m.target_progress.latest_mock_score, 50);
  assert.equal(m.target_progress.rate, 0.125);

  // reopen_hotspots：本用例没有重开过的单
  assert.deepEqual(m.reopen_hotspots, []);

  // GET 单条与 GET 列表都能读回同一份快照
  const one = await req('GET', `/review-cycles/${r.data.id}`);
  assert.equal(one.status, 200, JSON.stringify(one.data));
  assert.deepEqual(one.data.metrics, m);

  const list = await req('GET', `/review-cycles?user_id=${userId}`);
  assert.equal(list.status, 200, JSON.stringify(list.data));
  assert.equal(list.data.total, 1);
  assert.equal(list.data.items[0].id, r.data.id);
});

test('POST /review-cycles：空数据用户所有指标为零值/null，不报错', skipOpt, async () => {
  const userId = await freshUser('复盘-空数据');
  await freshTree(userId);

  const r = await req('POST', '/review-cycles', { user_id: userId, cycle_type: 'daily' });
  assert.equal(r.status, 201, JSON.stringify(r.data));

  const m = r.data.metrics;
  assert.equal(m.open_defects.total, 0);
  assert.equal(m.open_defects.by_status.V1, 0);
  assert.deepEqual(m.layer_dist, {});
  assert.equal(m.verify_pass_rate.total, 0);
  assert.equal(m.verify_pass_rate.rate, null, 'total=0 时 rate 必须是 null，不能是 0 或 NaN');
  assert.equal(m.mock_stability, null);
  assert.equal(m.target_progress.latest_mock_score, null);
  assert.equal(m.target_progress.rate, null);
  assert.deepEqual(m.reopen_hotspots, []);
});

// ---------------------------------------------------------------------------
// 2) 查重与并发
// ---------------------------------------------------------------------------

test('POST /review-cycles：同 user+cycle_type+period 重复 -> 409 ALREADY_EXISTS 带 existing_id', skipOpt, async () => {
  const userId = await freshUser('复盘-查重');
  await freshTree(userId);

  const first = await req('POST', '/review-cycles', {
    user_id: userId,
    cycle_type: 'weekly',
    period: '2026-W47',
  });
  assert.equal(first.status, 201, JSON.stringify(first.data));

  const dup = await req('POST', '/review-cycles', {
    user_id: userId,
    cycle_type: 'weekly',
    period: '2026-W47',
  });
  assert.equal(dup.status, 409, JSON.stringify(dup.data));
  assert.equal(dup.data.error, 'ALREADY_EXISTS');
  assert.equal(dup.data.existing_id, first.data.id);
  assert.equal(dup.data.resolution, 'delete_then_recreate');

  // 快照不可被覆盖：库里仍然只有 1 条
  const list = await req('GET', `/review-cycles?user_id=${userId}`);
  assert.equal(list.data.total, 1);
});

test('POST /review-cycles：并发两次同周期 -> 一成一败，库里只有一条', skipOpt, async () => {
  const userId = await freshUser('复盘-并发');
  await freshTree(userId);

  const body = { user_id: userId, cycle_type: 'monthly', period: '2026-11' };
  const [a, b] = await Promise.all([
    req('POST', '/review-cycles', body),
    req('POST', '/review-cycles', body),
  ]);

  const statuses = [a.status, b.status].sort();
  assert.deepEqual(statuses, [201, 409], `并发结果应为 201+409，实际 ${JSON.stringify(statuses)}`);

  const list = await req('GET', `/review-cycles?user_id=${userId}`);
  assert.equal(list.data.total, 1, '查重的 FOR UPDATE 必须真的生效');
});

// ---------------------------------------------------------------------------
// 3) 周期隔离
// ---------------------------------------------------------------------------

test('周期隔离：不同 period 的快照互不影响，列表按 period DESC', skipOpt, async () => {
  const userId = await freshUser('复盘-周期隔离');
  const tree = await freshTree(userId);

  await insertTicket(userId, tree, { status: 'ANALYZED' });

  const w1 = await req('POST', '/review-cycles', {
    user_id: userId,
    cycle_type: 'weekly',
    period: '2026-W45',
  });
  assert.equal(w1.status, 201, JSON.stringify(w1.data));

  const w2 = await req('POST', '/review-cycles', {
    user_id: userId,
    cycle_type: 'weekly',
    period: '2026-W47',
  });
  assert.equal(w2.status, 201, JSON.stringify(w2.data));

  const w3 = await req('POST', '/review-cycles', {
    user_id: userId,
    cycle_type: 'weekly',
    period: '2026-W46',
  });
  assert.equal(w3.status, 201, JSON.stringify(w3.data));

  const list = await req('GET', `/review-cycles?user_id=${userId}`);
  assert.equal(list.status, 200, JSON.stringify(list.data));
  assert.equal(list.data.total, 3);
  assert.deepEqual(
    list.data.items.map((x) => x.period),
    ['2026-W47', '2026-W46', '2026-W45'],
  );

  // 不同 cycle_type 不串
  const daily = await req('POST', '/review-cycles', {
    user_id: userId,
    cycle_type: 'daily',
    period: '2026-11-17',
  });
  assert.equal(daily.status, 201, JSON.stringify(daily.data));

  const onlyWeekly = await req('GET', `/review-cycles?user_id=${userId}&cycle_type=weekly`);
  assert.equal(onlyWeekly.data.total, 3);

  const onlyDaily = await req('GET', `/review-cycles?user_id=${userId}&cycle_type=daily`);
  assert.equal(onlyDaily.data.total, 1);
});

test('周期隔离：上一周的单子不计入本周 layer_dist / 本周开的单', skipOpt, async () => {
  const userId = await freshUser('复盘-跨周期');
  const tree = await freshTree(userId);

  // 造一张「20 天前」建的单：用 updated_at 改不了 created_at（那是插入默认值），
  // 但 layer_dist / reopen_hotspots 过滤的是 created_at —— 直接 UPDATE 造历史。
  const oldId = await insertTicket(userId, tree, { status: 'ANALYZED', errorLayer: 'ancient' });
  const c = await pool.connect();
  try {
    await c.query(`UPDATE defect_tickets SET created_at = now() - interval '20 days' WHERE id = $1`, [oldId]);
  } finally {
    c.release();
  }

  await insertTicket(userId, tree, { status: 'V1', errorLayer: 'fresh' });

  const r = await req('POST', '/review-cycles', { user_id: userId, cycle_type: 'daily' });
  assert.equal(r.status, 201, JSON.stringify(r.data));

  const m = r.data.metrics;
  // layer_dist 是「本周新建」-> 只剩 fresh
  assert.equal(m.layer_dist.fresh, 1, JSON.stringify(m.layer_dist));
  assert.equal(m.layer_dist.ancient, undefined, '20 天前的单不该进本周 layer_dist');

  // 但 open_defects 是时点量 -> 两张都算
  assert.equal(m.open_defects.total, 2, 'open_defects 是时点量，历史单仍算未关闭');
});

// ---------------------------------------------------------------------------
// 4) reopen_hotspots / mock_stability / target_progress 深水区
// ---------------------------------------------------------------------------

test('reopen_hotspots：按 SUM(reopen_count) 取 top5，带考点标题', skipOpt, async () => {
  const userId = await freshUser('复盘-热点');
  const tree = await freshTree(userId, { nodeTitle: '概率论' });

  await insertTicket(userId, tree, { status: 'REOPENED', reopenCount: 3 });
  await insertTicket(userId, tree, { status: 'V1', reopenCount: 2 });
  await insertTicket(userId, tree, { status: 'ANALYZED', reopenCount: 0 }); // 不计：reopen_count=0

  const r = await req('POST', '/review-cycles', { user_id: userId, cycle_type: 'weekly' });
  assert.equal(r.status, 201, JSON.stringify(r.data));

  const hs = r.data.metrics.reopen_hotspots;
  assert.equal(hs.length, 1, '同一个考点应合并成一条');
  assert.equal(hs[0].knowledge_node_id, tree.nodeId);
  assert.equal(hs[0].title, '概率论');
  assert.equal(hs[0].reopen_count_sum, 5);
});

test('mock_stability：三次模考准确率 [1,0.5,0] -> 变异系数约 0.816497', skipOpt, async () => {
  const userId = await freshUser('复盘-稳定性');
  const tree = await freshTree(userId);

  await insertSubmittedMock(tree, { accuracy: 1, ageDays: 3 });
  await insertSubmittedMock(tree, { accuracy: 0.5, ageDays: 2 });
  await insertSubmittedMock(tree, { accuracy: 0, ageDays: 1 });

  const r = await req('POST', '/review-cycles', { user_id: userId, cycle_type: 'weekly' });
  assert.equal(r.status, 201, JSON.stringify(r.data));

  const s = r.data.metrics.mock_stability;
  assert.ok(typeof s === 'number', `stability 应为 number，实际 ${JSON.stringify(s)}`);
  // 总体口径 cv：mean=0.5，population sd = sqrt(((0.5)^2+(0)^2+(0.5)^2)/3)=0.408248...，cv=0.8164965...
  assert.ok(Math.abs(s - 0.816497) < 1e-5, `stability 期望约 0.816497，实际 ${s}`);
});

test('target_progress：target_score 为 NULL 时 rate 为 null（不能除零）', skipOpt, async () => {
  const userId = await freshUser('复盘-无目标分');
  const tree = await freshTree(userId, { targetScore: null });
  await insertSubmittedMock(tree, { accuracy: 0.8 });

  const r = await req('POST', '/review-cycles', { user_id: userId, cycle_type: 'weekly' });
  assert.equal(r.status, 201, JSON.stringify(r.data));

  const tp = r.data.metrics.target_progress;
  assert.equal(tp.target_score, null);
  assert.equal(tp.latest_mock_score, 80);
  assert.equal(tp.rate, null, '目标分为 NULL 时 rate 必须 null');
});

// ---------------------------------------------------------------------------
// 5) PATCH / DELETE / 权限隔离
// ---------------------------------------------------------------------------

test('PATCH /review-cycles/:id：只允许 completed，乐观锁生效', skipOpt, async () => {
  const userId = await freshUser('复盘-标记');
  await freshTree(userId);

  const created = await req('POST', '/review-cycles', { user_id: userId, cycle_type: 'weekly' });
  assert.equal(created.status, 201, JSON.stringify(created.data));
  const id = created.data.id;

  // 缺 version
  const noVer = await req('PATCH', `/review-cycles/${id}`, { completed: true });
  assert.equal(noVer.status, 400, JSON.stringify(noVer.data));
  assert.equal(noVer.data.error, 'INVALID_BASE_VERSION');

  // 改 metrics -> IMMUTABLE_FIELD
  const immutable = await req('PATCH', `/review-cycles/${id}`, {
    version: created.data.version,
    completed: true,
    metrics: { open_defects: { total: 99 } },
  });
  assert.equal(immutable.status, 400, JSON.stringify(immutable.data));
  assert.equal(immutable.data.error, 'IMMUTABLE_FIELD');

  // 正常标记
  const done = await req('PATCH', `/review-cycles/${id}`, {
    version: created.data.version,
    completed: true,
  });
  assert.equal(done.status, 200, JSON.stringify(done.data));
  assert.equal(done.data.completed, true);
  assert.equal(done.data.version, created.data.version + 1);

  // completed 过滤
  const onlyDone = await req('GET', `/review-cycles?user_id=${userId}&completed=true`);
  assert.equal(onlyDone.data.total, 1);
  const onlyOpen = await req('GET', `/review-cycles?user_id=${userId}&completed=false`);
  assert.equal(onlyOpen.data.total, 0);
});

test('DELETE /review-cycles/:id：软删后 404，同周期可重新生成', skipOpt, async () => {
  const userId = await freshUser('复盘-软删');
  await freshTree(userId);

  const created = await req('POST', '/review-cycles', {
    user_id: userId,
    cycle_type: 'monthly',
    period: '2026-11',
  });
  assert.equal(created.status, 201, JSON.stringify(created.data));

  const del = await req('DELETE', `/review-cycles/${created.data.id}`, { version: created.data.version });
  assert.equal(del.status, 200, JSON.stringify(del.data));

  const gone = await req('GET', `/review-cycles/${created.data.id}`);
  assert.equal(gone.status, 404, JSON.stringify(gone.data));

  // 软删后同周期允许重新生成（查重只看未软删行）
  const again = await req('POST', '/review-cycles', {
    user_id: userId,
    cycle_type: 'monthly',
    period: '2026-11',
  });
  assert.equal(again.status, 201, JSON.stringify(again.data));
  assert.notEqual(again.data.id, created.data.id);
});

test('用户隔离：别人看不到我的复盘快照', skipOpt, async () => {
  const mine = await freshUser('复盘-我的');
  const other = await freshUser('复盘-别人的');
  await freshTree(mine);
  await freshTree(other);

  const created = await req('POST', '/review-cycles', { user_id: mine, cycle_type: 'weekly' });
  assert.equal(created.status, 201, JSON.stringify(created.data));

  const theirList = await req('GET', `/review-cycles?user_id=${other}`);
  assert.equal(theirList.status, 200);
  assert.equal(theirList.data.total, 0);

  // 单条读不做权限校验（与其它模块一致：鉴权属 FE/网关层，本轮不做）
  const byId = await req('GET', `/review-cycles/${created.data.id}`);
  assert.equal(byId.status, 200);
});
