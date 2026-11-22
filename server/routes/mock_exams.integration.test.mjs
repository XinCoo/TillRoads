// server/routes/mock_exams.integration.test.mjs
// 题路 TillRoad · BE-05 T5：限时模考 + 报告生成的真实 PG 集成测试
//
// 与 server/mock_report.test.mjs（纯函数层）分工：
//   * mock_report.test.mjs —— 四项指标算法本身的边界（全对/全错/首次 cv=null/…），零依赖可跑；
//   * 本文件 —— 组卷→提交→报告全链路走真库：随机抽题的 SQL、attempts 落库、
//                questions jsonb 回填 attempt_id、报告四项与 v3_candidates 的真数据正确性、
//                超时收卷、题量不足 400。
//   只有 RUN_PG_INTEGRATION=1 才跑，CI 会设。
//
// ★ 隔离设计（BE-03 的教训）：每个用例用 freshUser() 建自己的 user + exam_profile，
//   绝不复用共享 seed。否则「total === 1」这类绝对断言会被前面的用例污染 ——
//   本机 100% skip 时看不见，一到 CI 就爆。

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

/** 本次测试创建的所有 user id（after() 批量清理）。 */
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

/** 独立 user + exam_profile（每用例一份，互不干扰）。 */
async function freshProfile(label = '模考集成测试') {
  const c = await pool.connect();
  try {
    const u = await c.query(
      `INSERT INTO users (nickname, timezone, role) VALUES ($1,$2,$3) RETURNING id`,
      [`${label}-${createdUsers.length + 1}`, 'Asia/Shanghai', 'student'],
    );
    const userId = u.rows[0].id;
    createdUsers.push(userId);
    const p = await c.query(
      `INSERT INTO exam_profiles (user_id, exam_type, target_label, exam_date, daily_minutes, status)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
      [userId, 'postgrad', `${label}目标`, '2027-12-20', 120, 'active'],
    );
    return { userId, profileId: p.rows[0].id };
  } finally {
    c.release();
  }
}

/** 在某个 profile 下造一棵 科目 → 考点 树，返回 { subjectId, nodeIds }。 */
async function freshTree(profileId, nodeTitles) {
  const c = await pool.connect();
  try {
    const sub = await c.query(
      `INSERT INTO subjects (exam_profile_id, name, kind) VALUES ($1,$2,'objective') RETURNING id`,
      [profileId, '模考科目'],
    );
    const subjectId = sub.rows[0].id;
    const nodeIds = [];
    for (const title of nodeTitles) {
      const n = await c.query(
        `INSERT INTO knowledge_nodes (subject_id, title, freq_tag, weight_to_target)
         VALUES ($1,$2,'high',0.25) RETURNING id`,
        [subjectId, title],
      );
      nodeIds.push(n.rows[0].id);
    }
    return { subjectId, nodeIds };
  } finally {
    c.release();
  }
}

/** 往题库塞一批可自动判分的单选题。 */
async function seedQuestions({ subjectId, knowledgeNodeId, count, answer = 'A', type = 'choice', isSubjective = false }) {
  const c = await pool.connect();
  try {
    const ids = [];
    for (let i = 0; i < count; i += 1) {
      // content_hash 有唯一性参与去重（NOT NULL），这里保证互不重复
      const hash = `mock-round-${Date.now()}-${Math.random().toString(36).slice(2)}-${i}`;
      const q = await c.query(
        `INSERT INTO questions
           (source, subject_id, knowledge_node_id, type, stem, options, answer, analysis,
            difficulty, tags, content_hash, is_subjective)
         VALUES ('manual',$1,$2,$3,$4,$5,$6,$7,$8,'[]'::jsonb,$9,$10) RETURNING id`,
        [
          subjectId,
          knowledgeNodeId,
          type,
          `模考集成测试题干 ${i + 1}`,
          JSON.stringify([{ key: 'A', text: '选项 A' }, { key: 'B', text: '选项 B' }]),
          answer,
          '因为这是测试题',
          'medium', // schema.sql:57 difficulty 是 ENUM('easy','medium','hard')，不是 numeric
          hash,
          isSubjective,
        ],
      );
      ids.push(q.rows[0].id);
    }
    return ids;
  } finally {
    c.release();
  }
}

/** 组卷。 */
async function createMock(profileId, body) {
  const r = await req('POST', '/mock-exams', {
    exam_profile_id: profileId,
    ...body,
  });
  return r;
}

/** 提交（自动带当前 version）。 */
async function submitMock(id, answers, extra = {}) {
  const cur = await req('GET', `/mock-exams/${id}`);
  assert.equal(cur.status, 200, JSON.stringify(cur.data));
  return req('POST', `/mock-exams/${id}/submit`, {
    version: cur.data.mock_exam.version,
    answers,
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
        `DELETE FROM attempts WHERE mock_exam_id IN (
           SELECT id FROM mock_exams WHERE exam_profile_id IN (
             SELECT id FROM exam_profiles WHERE user_id = ANY($1::uuid[])))`,
        [createdUsers],
      );
      await c.query(
        `DELETE FROM mock_exams WHERE exam_profile_id IN (
           SELECT id FROM exam_profiles WHERE user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      await c.query(
        `DELETE FROM verifications WHERE defect_ticket_id IN (
           SELECT id FROM defect_tickets WHERE user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      await c.query(
        `DELETE FROM actions WHERE defect_ticket_id IN (
           SELECT id FROM defect_tickets WHERE user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      // 顺序陷阱：defect_tickets.question_id 引用 questions(id)，必须先删缺陷单再删题目。
      // 之前 questions 排在 defect_tickets 之前，一旦本文件真跑完并造出「引用了题目的缺陷单」，
      // after() 就报 23503 defect_tickets_question_id_fkey（外键约束失败）→ 文件级 ✖ 且
      // 未捕获的 rejection 让进程挂住不退出（CI 跑 3 小时被 cancel）。早期 18 fail 时测试在
      // seedQuestions 就崩、after() 删不到这种缺陷单，故这个顺序错误一直没暴露。见 REVIEW-NOTES。
      await c.query(`DELETE FROM defect_tickets WHERE user_id = ANY($1::uuid[])`, [createdUsers]);
      await c.query(
        `DELETE FROM questions WHERE subject_id IN (
           SELECT s.id FROM subjects s JOIN exam_profiles p ON p.id = s.exam_profile_id
            WHERE p.user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      await c.query(
        `DELETE FROM knowledge_nodes WHERE subject_id IN (
           SELECT s.id FROM subjects s JOIN exam_profiles p ON p.id = s.exam_profile_id
            WHERE p.user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      await c.query(
        `DELETE FROM subjects WHERE exam_profile_id IN (
           SELECT id FROM exam_profiles WHERE user_id = ANY($1::uuid[]))`,
        [createdUsers],
      );
      await c.query(`DELETE FROM exam_profiles WHERE user_id = ANY($1::uuid[])`, [createdUsers]);
      await c.query(`DELETE FROM users WHERE id = ANY($1::uuid[])`, [createdUsers]);
    }
  } catch (cleanupError) {
    // 挂起根因（二）：清理语句抛错后，原实现把 app.close()/pool.end() 放在 try/finally 之外，
    // 异常一跳出就永远执行不到它们 —— HTTP server 仍在监听、连接池仍开着，
    // 事件循环有活 handle，node:test 进程永远退不出去（CI 表现为 3 小时后被 cancel）。
    // 处理方式：不吞掉错误（否则数据泄漏会被静默忽略）而是记下来，先把服务器与连接池关掉，
    // 再抛出去 —— 让 CI 看到一个明确的失败，且进程能正常退出（fail fast，不挂死）。
    cleanupFailure = cleanupError;
  } finally {
    c.release();
  }
  // 无论如何先关服 + 断开连接池，保证进程能退出。
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
// 1) 组卷：随机抽题 + 题量不足 + 模式约束
// ---------------------------------------------------------------------------

test('组卷（full）：抽满指定题量，卷面不含 answer/analysis', skipOpt, async () => {
  const { profileId } = await freshProfile('组卷full');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 5 });

  const r = await createMock(profileId, { mode: 'full', subject_id: subjectId, question_count: 3 });
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.question_count, 3);
  assert.equal(r.data.questions.length, 3);
  assert.equal(r.data.mock_exam.mode, 'full');
  assert.equal(r.data.mock_exam.report, null);

  // 泄题防线：绝不返回答案与解析
  for (const q of r.data.questions) {
    assert.equal(q.answer, undefined, '组卷响应不得含 answer');
    assert.equal(q.analysis, undefined, '组卷响应不得含 analysis');
    assert.ok(q.stem);
  }

  // questions jsonb 结构严格按 schema 注释
  const qs = r.data.mock_exam.questions;
  assert.equal(qs.length, 3);
  for (const entry of qs) {
    assert.deepEqual(Object.keys(entry).sort(), ['attempt_id', 'duration_ms', 'is_correct', 'question_id']);
    assert.equal(entry.attempt_id, null);
    assert.equal(entry.is_correct, null);
    assert.equal(entry.duration_ms, null);
  }
});

test('组卷（module）：按 knowledge_node 抽题', skipOpt, async () => {
  const { profileId } = await freshProfile('组卷module');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A', '考点B']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 4 });
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[1], count: 4 });

  const r = await createMock(profileId, {
    mode: 'module',
    knowledge_node_id: nodeIds[0],
    question_count: 4,
  });
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.question_count, 4);
  // 只抽考点A 的题
  for (const q of r.data.questions) {
    assert.equal(q.knowledge_node_id, nodeIds[0]);
  }
});

test('题量不足 -> 400 INSUFFICIENT_QUESTIONS（body 含 available）', skipOpt, async () => {
  const { profileId } = await freshProfile('题量不足');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 2 });

  const r = await createMock(profileId, { mode: 'full', subject_id: subjectId, question_count: 9 });
  assert.equal(r.status, 400, JSON.stringify(r.data));
  assert.equal(r.data.error, 'INSUFFICIENT_QUESTIONS');
  assert.equal(r.data.available, 2);
  assert.equal(r.data.requested, 9);
});

test('mode 缺 subject_id / knowledge_node_id -> 400', skipOpt, async () => {
  const { profileId } = await freshProfile('模式约束');

  const full = await createMock(profileId, { mode: 'full', question_count: 1 });
  assert.equal(full.status, 400, JSON.stringify(full.data));
  assert.equal(full.data.error, 'MISSING_SUBJECT_ID');

  const mod = await createMock(profileId, { mode: 'module', question_count: 1 });
  assert.equal(mod.status, 400, JSON.stringify(mod.data));
  assert.equal(mod.data.error, 'MISSING_KNOWLEDGE_NODE_ID');
});

// ---------------------------------------------------------------------------
// 2) 提交：attempts 落库 + questions 回填 + 报告生成
// ---------------------------------------------------------------------------

test('提交全链路：attempts 落库、questions 回填 attempt_id、报告四项齐备', skipOpt, async () => {
  const { profileId } = await freshProfile('提交全链路');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A', '考点B']);
  // 考点A 2 题、考点B 1 题，标准答案都是 A
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 2, answer: 'A' });
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[1], count: 1, answer: 'A' });

  const created = await createMock(profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 3,
    duration_limit_ms: 600000,
  });
  assert.equal(created.status, 201, JSON.stringify(created.data));
  const id = created.data.mock_exam.id;
  const qs = created.data.questions;

  // 按考点固定判分：考点A 的题答对（'A'），考点B 的题答错（'B'）。
  // 因为组卷是 ORDER BY random()，不能按下标写死答案，否则断言依赖抽题顺序。
  const answerFor = (q) => (q.knowledge_node_id === nodeIds[1] ? 'B' : 'A');
  const durationFor = (q) => (q.knowledge_node_id === nodeIds[1] ? 3000 : 1000);
  const answers = qs.map((q) => ({
    question_id: q.id,
    answer_text: answerFor(q),
    duration_ms: durationFor(q),
  }));

  const sub = await submitMock(id, answers);
  assert.equal(sub.status, 200, JSON.stringify(sub.data));
  assert.equal(sub.data.timed_out, false);

  const report = sub.data.report;
  assert.ok(report, 'report 必须生成');
  assert.equal(report.strategy_execution, null, 'strategy_execution 恒为 null（拍板项 4）');
  assert.equal(report.overall.total, 3);
  assert.equal(report.overall.correct, 2);
  assert.equal(report.defect_repeat_rate.total_wrong, 1);

  // module_accuracy 按 knowledge_node 分组（两个考点）
  const keys = Object.keys(report.module_accuracy);
  assert.equal(keys.length, 2);
  const a = report.module_accuracy[nodeIds[0]];
  assert.equal(a.total, 2);
  assert.equal(a.correct, 2);
  assert.equal(a.accuracy, 1);
  const b = report.module_accuracy[nodeIds[1]];
  assert.equal(b.total, 1);
  assert.equal(b.correct, 0);
  assert.equal(b.accuracy, 0);

  // avg_duration_ms
  // avg_duration_ms：考点A 两题各 1000，考点B 一题 3000
  assert.equal(report.avg_duration_ms.overall, 1667); // round((1000+1000+3000)/3)
  assert.equal(report.avg_duration_ms.by_knowledge_node[nodeIds[0]].avg_duration_ms, 1000);
  assert.equal(report.avg_duration_ms.by_knowledge_node[nodeIds[1]].avg_duration_ms, 3000);

  // 首次模考 stability = null
  assert.equal(report.stability, null);

  // attempts 真落库了 3 条，且 question_id 都在卷面上
  const c = await pool.connect();
  try {
    const rows = await c.query(
      `SELECT id, question_id, is_correct, duration_ms FROM attempts
        WHERE mock_exam_id = $1 AND deleted_at IS NULL`,
      [id],
    );
    assert.equal(rows.rowCount, 3);
    const byQ = new Map(rows.rows.map((r) => [r.question_id, r]));
    // 考点A 的题全对、考点B 的题全错（与上面的 answerFor 一致）
    const qByKn = new Map(qs.map((q) => [q.id, q.knowledge_node_id]));
    for (const row of rows.rows) {
      const expected = qByKn.get(row.question_id) === nodeIds[1] ? false : true;
      assert.equal(row.is_correct, expected);
    }
    assert.equal(rows.rows.find((r) => qByKn.get(r.question_id) === nodeIds[1]).duration_ms, 3000);

    // questions jsonb 已按 attempt_id 回填
    const me = await c.query(`SELECT questions, report FROM mock_exams WHERE id = $1`, [id]);
    const stored = me.rows[0].questions;
    assert.equal(stored.length, 3);
    for (const entry of stored) {
      assert.ok(entry.attempt_id, 'attempt_id 必须回填');
      assert.equal(byQ.has(entry.question_id), true);
      assert.equal(entry.attempt_id, byQ.get(entry.question_id).id);
    }
    assert.ok(me.rows[0].report, 'report jsonb 已落库');
  } finally {
    c.release();
  }

  // GET /report 能读回同一份
  const rep = await req('GET', `/mock-exams/${id}/report`);
  assert.equal(rep.status, 200, JSON.stringify(rep.data));
  assert.deepEqual(rep.data.report.overall, report.overall);
});

test('未提交时 GET /report -> 404 not_submitted', skipOpt, async () => {
  const { profileId } = await freshProfile('未提交报告');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 1 });

  const created = await createMock(profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 1,
  });
  assert.equal(created.status, 201);

  const rep = await req('GET', `/mock-exams/${created.data.mock_exam.id}/report`);
  assert.equal(rep.status, 404, JSON.stringify(rep.data));
  assert.equal(rep.data.error, 'not_submitted');
});

test('重复提交 -> 409 already_submitted', skipOpt, async () => {
  const { profileId } = await freshProfile('重复提交');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 1 });

  const created = await createMock(profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 1,
  });
  const id = created.data.mock_exam.id;
  const qs = created.data.questions;

  const first = await submitMock(id, [{ question_id: qs[0].id, answer_text: 'A', duration_ms: 100 }]);
  assert.equal(first.status, 200, JSON.stringify(first.data));

  const second = await submitMock(id, [{ question_id: qs[0].id, answer_text: 'A', duration_ms: 100 }]);
  assert.equal(second.status, 409, JSON.stringify(second.data));
  assert.equal(second.data.error, 'already_submitted');
});

test('提交缺 base_version -> 400 INVALID_BASE_VERSION', skipOpt, async () => {
  const { profileId } = await freshProfile('提交缺版本');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 1 });

  const created = await createMock(profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 1,
  });
  const r = await req('POST', `/mock-exams/${created.data.mock_exam.id}/submit`, { answers: [] });
  assert.equal(r.status, 400, JSON.stringify(r.data));
  assert.equal(r.data.error, 'INVALID_BASE_VERSION');
});

// ---------------------------------------------------------------------------
// 3) 超时收卷
// ---------------------------------------------------------------------------

test('超时收卷：未作答题计错，已作答题正常判', skipOpt, async () => {
  const { profileId } = await freshProfile('超时收卷');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 2, answer: 'A' });

  const created = await createMock(profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 2,
    duration_limit_ms: 60000, // 1 分钟限时
  });
  const id = created.data.mock_exam.id;
  const qs = created.data.questions;

  // 只答第一题，但提交时间假装是 1 分钟限时 + 61s 宽限之后
  const submittedAt = new Date(Date.now() + 60000 + 61000).toISOString();
  const r = await req('POST', `/mock-exams/${id}/submit`, {
    version: created.data.mock_exam.version,
    submitted_at: submittedAt,
    answers: [{ question_id: qs[0].id, answer_text: 'A', duration_ms: 5000 }],
  });

  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.timed_out, true, '超过 限时 + 60s 宽限 -> 超时收卷');
  // 已作答的正确；未作答的计错
  assert.equal(r.data.report.overall.correct, 1);
  assert.equal(r.data.report.overall.total, 2);
});

test('未超时（宽限内）不算超时', skipOpt, async () => {
  const { profileId } = await freshProfile('宽限内');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 1, answer: 'A' });

  const created = await createMock(profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 1,
    duration_limit_ms: 60000,
  });
  const id = created.data.mock_exam.id;
  const qs = created.data.questions;

  // 限时 60s，实际提交 60s + 30s（在 60s 宽限内）-> 不算超时
  const submittedAt = new Date(Date.now() + 90000).toISOString();
  const r = await req('POST', `/mock-exams/${id}/submit`, {
    version: created.data.mock_exam.version,
    submitted_at: submittedAt,
    answers: [{ question_id: qs[0].id, answer_text: 'A', duration_ms: 5000 }],
  });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.timed_out, false);
});

// ---------------------------------------------------------------------------
// 4) stability（近 3 次同 mode）
// ---------------------------------------------------------------------------

test('stability：第 2、3 次模考返回变异系数，第 1 次为 null', skipOpt, async () => {
  const { profileId } = await freshProfile('稳定性');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  // 每题都一样，便于控制正确率
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 2, answer: 'A' });

  const accuracies = [];

  // 第 1 次：全对 -> stability null
  {
    const made = await createMock(profileId, {
      mode: 'full',
      subject_id: subjectId,
      question_count: 2,
    });
    const id = made.data.mock_exam.id;
    const qs = made.data.questions;
    const r = await submitMock(
      id,
      qs.map((q) => ({ question_id: q.id, answer_text: 'A', duration_ms: 1000 })),
    );
    assert.equal(r.status, 200, JSON.stringify(r.data));
    assert.equal(r.data.report.stability, null, '首次模考 stability 必须 null');
    accuracies.push(r.data.report.overall.accuracy);
  }

  // 第 2 次：一半对 -> stability 有值
  {
    const made = await createMock(profileId, {
      mode: 'full',
      subject_id: subjectId,
      question_count: 2,
    });
    const id = made.data.mock_exam.id;
    const qs = made.data.questions;
    const r = await submitMock(id, [
      { question_id: qs[0].id, answer_text: 'A', duration_ms: 1000 },
      { question_id: qs[1].id, answer_text: 'B', duration_ms: 1000 },
    ]);
    assert.equal(r.status, 200, JSON.stringify(r.data));
    assert.equal(typeof r.data.report.stability, 'number', '第 2 次应有 cv');
    assert.ok(r.data.report.stability > 0);
    accuracies.push(r.data.report.overall.accuracy);
  }

  // 第 3 次：全错
  {
    const made = await createMock(profileId, {
      mode: 'full',
      subject_id: subjectId,
      question_count: 2,
    });
    const id = made.data.mock_exam.id;
    const qs = made.data.questions;
    const r = await submitMock(
      id,
      qs.map((q) => ({ question_id: q.id, answer_text: 'B', duration_ms: 1000 })),
    );
    assert.equal(r.status, 200, JSON.stringify(r.data));
    assert.equal(typeof r.data.report.stability, 'number');
    // 三次准确率 [1, 0.5, 0] -> 均值 0.5，总体标准差 sqrt(0.5/3)≈0.40825, cv≈0.816497
    assert.ok(Math.abs(r.data.report.stability - 0.816497) < 1e-5, `cv=${r.data.report.stability}`);
  }
});

// ---------------------------------------------------------------------------
// 5) defect_repeat_rate（与 CLOSED 缺陷单关联）
// ---------------------------------------------------------------------------

test('defect_repeat_rate：错题命中用户已 CLOSED 缺陷单时计入 repeat', skipOpt, async () => {
  const { userId, profileId } = await freshProfile('重复缺陷');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  const qIds = await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 2, answer: 'A' });

  // 造一条 CLOSED 缺陷单，绑定到第一道题
  const c = await pool.connect();
  try {
    await c.query(
      `INSERT INTO defect_tickets (user_id, exam_profile_id, knowledge_node_id, question_id,
                                   error_layer, error_cause, status)
       VALUES ($1,$2,$3,$4,'concept','概念混淆','CLOSED')`,
      [userId, profileId, nodeIds[0], qIds[0]],
    );
  } finally {
    c.release();
  }

  const made = await createMock(profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 2,
  });
  const id = made.data.mock_exam.id;
  const qs = made.data.questions;

  // 两题全答错
  const r = await submitMock(
    id,
    qs.map((q) => ({ question_id: q.id, answer_text: 'B', duration_ms: 1000 })),
  );
  assert.equal(r.status, 200, JSON.stringify(r.data));

  const rr = r.data.report.defect_repeat_rate;
  assert.equal(rr.total_wrong, 2);
  // 命中的题数取决于随机抽到的那两道题里是否有 qIds[0]
  const pickedHasClosed = qs.some((q) => q.id === qIds[0]);
  assert.equal(rr.repeat_count, pickedHasClosed ? 1 : 0);
  assert.equal(rr.rate, pickedHasClosed ? 0.5 : 0);
});

test('defect_repeat_rate：全部答对时 total_wrong=0 且 rate=0（不是 NaN）', skipOpt, async () => {
  const { profileId } = await freshProfile('全对重复率');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 1, answer: 'A' });

  const made = await createMock(profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 1,
  });
  const r = await submitMock(made.data.mock_exam.id, [
    { question_id: made.data.questions[0].id, answer_text: 'A', duration_ms: 100 },
  ]);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  const rr = r.data.report.defect_repeat_rate;
  assert.equal(rr.total_wrong, 0);
  assert.equal(rr.repeat_count, 0);
  assert.equal(rr.rate, 0);
  assert.equal(Number.isNaN(rr.rate), false);
});

// ---------------------------------------------------------------------------
// 6) v3_candidates（V3 缺陷单绑定）
// ---------------------------------------------------------------------------

test('v3_candidates：错题的考点命中用户 V3 缺陷单时返回候选', skipOpt, async () => {
  const { userId, profileId } = await freshProfile('V3候选');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 2, answer: 'A' });

  // 造一条 V3 缺陷单（status 由触发器保证只能经合法迁移到达，此处直接 INSERT 为 V3）
  const c = await pool.connect();
  try {
    await c.query(
      `INSERT INTO defect_tickets (user_id, exam_profile_id, knowledge_node_id,
                                   error_layer, error_cause, status)
       VALUES ($1,$2,$3,'concept','概念混淆','V3')`,
      [userId, profileId, nodeIds[0]],
    );
  } finally {
    c.release();
  }

  const made = await createMock(profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 2,
  });
  const r = await submitMock(
    made.data.mock_exam.id,
    made.data.questions.map((q) => ({ question_id: q.id, answer_text: 'B', duration_ms: 100 })),
  );
  assert.equal(r.status, 200, JSON.stringify(r.data));

  const v3 = r.data.report.v3_candidates;
  assert.equal(v3.length, 2, '两道错题同属考点A，应各出一条候选');
  for (const cand of v3) {
    assert.ok(cand.defect_ticket_id);
    assert.equal(cand.knowledge_node_id, nodeIds[0]);
    assert.ok(cand.question_id);
  }
  // 两条候选的 defect_ticket_id 相同（同一条 V3 缺陷单），question_id 不同
  assert.equal(v3[0].defect_ticket_id, v3[1].defect_ticket_id);
  assert.notEqual(v3[0].question_id, v3[1].question_id);
});

test('v3_candidates：全答对时为空数组', skipOpt, async () => {
  const { userId, profileId } = await freshProfile('V3无候选');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 1, answer: 'A' });

  const c = await pool.connect();
  try {
    await c.query(
      `INSERT INTO defect_tickets (user_id, exam_profile_id, knowledge_node_id,
                                   error_layer, error_cause, status)
       VALUES ($1,$2,$3,'concept','概念混淆','V3')`,
      [userId, profileId, nodeIds[0]],
    );
  } finally {
    c.release();
  }

  const made = await createMock(profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 1,
  });
  const r = await submitMock(made.data.mock_exam.id, [
    { question_id: made.data.questions[0].id, answer_text: 'A', duration_ms: 100 },
  ]);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.deepEqual(r.data.report.v3_candidates, []);
});

// ---------------------------------------------------------------------------
// 7) 列表 + 用户隔离
// ---------------------------------------------------------------------------

test('列表 GET /exam-profiles/:id/mock-exams：最新的在前，可按 mode 过滤', skipOpt, async () => {
  const { profileId } = await freshProfile('模考列表');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 4 });

  const m1 = await createMock(profileId, { mode: 'full', subject_id: subjectId, question_count: 1 });
  assert.equal(m1.status, 201);
  const m2 = await createMock(profileId, {
    mode: 'module',
    knowledge_node_id: nodeIds[0],
    question_count: 1,
  });
  assert.equal(m2.status, 201);

  const all = await req('GET', `/exam-profiles/${profileId}/mock-exams`);
  assert.equal(all.status, 200, JSON.stringify(all.data));
  assert.equal(all.data.items.length, 2);
  // 最新的在前
  assert.equal(all.data.items[0].id, m2.data.mock_exam.id);
  assert.equal(all.data.items[1].id, m1.data.mock_exam.id);

  const onlyFull = await req('GET', `/exam-profiles/${profileId}/mock-exams?mode=full`);
  assert.equal(onlyFull.status, 200);
  assert.equal(onlyFull.data.items.length, 1);
  assert.equal(onlyFull.data.items[0].mode, 'full');
});

test('用户隔离：别人的模考读不到（404）', skipOpt, async () => {
  const a = await freshProfile('隔离A');
  const { subjectId, nodeIds } = await freshTree(a.profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 1 });

  const made = await createMock(a.profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 1,
  });
  const id = made.data.mock_exam.id;

  const b = await freshProfile('隔离B');
  const other = await req('GET', `/exam-profiles/${b.profileId}/mock-exams`);
  assert.equal(other.status, 200);
  assert.equal(other.data.items.length, 0, 'B 的列表里不该出现 A 的模考');

  // 但按 id 直读仍是 200（本接口无鉴权，属已知遗留项）
  const byId = await req('GET', `/mock-exams/${id}`);
  assert.equal(byId.status, 200);
});

// ---------------------------------------------------------------------------
// 8) 软删
// ---------------------------------------------------------------------------

test('DELETE /mock-exams/:id 软删后 404，且需 base_version', skipOpt, async () => {
  const { profileId } = await freshProfile('模考软删');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 1 });

  const made = await createMock(profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 1,
  });
  const id = made.data.mock_exam.id;

  const noVersion = await req('DELETE', `/mock-exams/${id}`, {});
  assert.equal(noVersion.status, 400, JSON.stringify(noVersion.data));
  assert.equal(noVersion.data.error, 'INVALID_BASE_VERSION');

  const del = await req('DELETE', `/mock-exams/${id}`, { version: made.data.mock_exam.version });
  assert.equal(del.status, 200, JSON.stringify(del.data));

  const gone = await req('GET', `/mock-exams/${id}`);
  assert.equal(gone.status, 404, JSON.stringify(gone.data));
});

// ---------------------------------------------------------------------------
// 9) 主观题不参与自动判分
// ---------------------------------------------------------------------------

test('主观题 is_correct 记 null，不进正确率分母', skipOpt, async () => {
  const { profileId } = await freshProfile('主观题');
  const { subjectId, nodeIds } = await freshTree(profileId, ['考点A']);
  await seedQuestions({ subjectId, knowledgeNodeId: nodeIds[0], count: 1, answer: 'A' });

  const c = await pool.connect();
  try {
    await c.query(
      `INSERT INTO questions
         (source, subject_id, knowledge_node_id, type, stem, answer, content_hash, is_subjective)
       VALUES ('manual',$1,$2,'short_answer','简述题',$3,$4,true)`,
      [subjectId, nodeIds[0], '参考答案文本', `mock-subj-${Date.now()}`],
    );
  } finally {
    c.release();
  }

  const made = await createMock(profileId, {
    mode: 'full',
    subject_id: subjectId,
    question_count: 2,
  });
  const r = await submitMock(
    made.data.mock_exam.id,
    made.data.questions.map((q) => ({ question_id: q.id, answer_text: '随便写', duration_ms: 100 })),
  );
  assert.equal(r.status, 200, JSON.stringify(r.data));
  // 至少一道未判分
  assert.ok(r.data.report.overall.ungraded >= 1, `ungraded=${r.data.report.overall.ungraded}`);
  assert.ok(r.data.report.ungraded_count >= 1);
});
