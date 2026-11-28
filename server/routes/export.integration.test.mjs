// server/routes/export.integration.test.mjs
// 题路 TillRoad · m32406：题库导出端点（GET /export/questions）集成测试
//
// 只有 RUN_PG_INTEGRATION=1 才跑（CI 会设），本机无 PG 时整文件跳过。
//
// 为什么必须连真库：
//   * 导出是「整库快照」，涉及 users / exam_profiles / subjects / knowledge_nodes /
//     questions 五表 JOIN，任何一处 owner 条件写错都只有真库能暴露；
//   * 最容易错的一条是「只导自己的题」——listVisible 的 owner 条件是
//     `owner_user_id IS NULL OR owner_user_id = $n`（会带公共题），导出必须**不带**，
//     这类口径差别只有拿公共题一起断言才看得出。
//
// 断言口径：本文档**自建用户 + 自建科目 + 自建题目**，不依赖别的集成测试留下的数据。

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

const TOKEN_A = 'tk_export_a';
const TOKEN_B = 'tk_export_b';

let pool;
let app;
let base;
let seed; // { userA, userB, profileA, profileB, subjectA, subjectB, nodeA, nodeB, q }

async function req(method, path, token) {
  const init = { method };
  if (token) init.headers = { Authorization: `Bearer ${token}` };
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
  return { userId, profileId: p.rows[0].id };
}

async function makeSubject(c, profileId, name) {
  const r = await c.query(
    `INSERT INTO subjects (exam_profile_id, name, kind) VALUES ($1, $2, 'objective') RETURNING id`,
    [profileId, name],
  );
  return r.rows[0].id;
}

async function makeNode(c, subjectId, title, parentId = null) {
  const r = await c.query(
    `INSERT INTO knowledge_nodes (subject_id, parent_id, title, freq_tag, weight_to_target)
     VALUES ($1, $2, $3, 'high', 0.5) RETURNING id`,
    [subjectId, parentId, title],
  );
  return r.rows[0].id;
}

/** 插一道题。ownerUserId=null → 公共题。 */
/** 插一道题。ownerUserId=null → 公共题。 */
async function makeQuestion(
  c,
  {
    subjectId,
    nodeId = null,
    ownerUserId,
    stem,
    type = 'choice',
    hash,
    answer = 'A',
    isSubjective = false,
  },
) {
  const r = await c.query(
    `INSERT INTO questions
       (source, subject_id, knowledge_node_id, type, stem, options, answer, analysis,
        content_hash, owner_user_id, is_subjective)
     VALUES ('import', $1, $2, $3, $4, $5::jsonb, $6, $7, $8, $9, $10)
     RETURNING id`,
    [
      subjectId,
      nodeId,
      type,
      stem,
      JSON.stringify([
        { key: 'A', text: '选项甲' },
        { key: 'B', text: '选项乙' },
      ]),
      answer,
      `${stem} 的解析`,
      hash,
      ownerUserId,
      isSubjective,
    ],
  );
  return r.rows[0].id;
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
    const a = await makeUser(c, '导出用户A');
    const b = await makeUser(c, '导出用户B');
    const subjectA = await makeSubject(c, a.profileId, '导出科目A');
    const subjectB = await makeSubject(c, b.profileId, '导出科目B');
    const nodeA = await makeNode(c, subjectA, '导出考点A');
    const nodeB = await makeNode(c, subjectB, '导出考点B');

    seed = {
      userA: a.userId,
      userB: b.userId,
      profileA: a.profileId,
      profileB: b.profileId,
      subjectA,
      subjectB,
      nodeA,
      nodeB,
      q: {},
    };

    // A 的 5 道自有题（覆盖不同题型 / 有考点与无考点）。
    seed.q.a1 = await makeQuestion(c, {
      subjectId: subjectA,
      nodeId: nodeA,
      ownerUserId: a.userId,
      stem: '导出一道选择题',
      type: 'choice',
      hash: 'hash-export-a1',
    });
    seed.q.a2 = await makeQuestion(c, {
      subjectId: subjectA,
      ownerUserId: a.userId,
      stem: '导出二道多选题',
      type: 'multi',
      hash: 'hash-export-a2',
    });
    seed.q.a3 = await makeQuestion(c, {
      subjectId: subjectA,
      ownerUserId: a.userId,
      stem: '导出三道判断题',
      type: 'judge',
      hash: 'hash-export-a3',
    });
    seed.q.a4 = await makeQuestion(c, {
      subjectId: null,
      ownerUserId: a.userId,
      stem: '导出四道无科目题',
      type: 'fill',
      hash: 'hash-export-a4',
    });
    seed.q.a5 = await makeQuestion(c, {
      subjectId: subjectA,
      ownerUserId: a.userId,
      stem: '导出五道简答题',
      type: 'short_answer',
      hash: 'hash-export-a5',
      // is_subjective 是导入时按题型写入的存量字段（不是触发器派生），
      // 这里显式写成 true 来验证导出端点原样透传。
      isSubjective: true,
    });

    // 干扰项：公共题（owner NULL）与 B 的私有题 —— 都不应出现在 A 的导出里。
    seed.q.publicQ = await makeQuestion(c, {
      subjectId: subjectA,
      ownerUserId: null,
      stem: '公共题不该被导出',
      hash: 'hash-export-public',
    });
    seed.q.bQ = await makeQuestion(c, {
      subjectId: subjectB,
      nodeId: nodeB,
      ownerUserId: b.userId,
      stem: 'B的题不该被导出',
      hash: 'hash-export-b1',
    });

    process.env.TOKENS = `${TOKEN_A}:${seed.userA},${TOKEN_B}:${seed.userB}`;
    app = createApp({ pool });
    await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
    base = `http://127.0.0.1:${app.server.address().port}`;
  } finally {
    c.release();
  }
});

after(async () => {
  if (!RUN || !app) return;

  const c = await pool.connect();
  let cleanupFailure = null;
  try {
    // 顺序要紧：先删引用表（FK 指向 questions / users），再删题。
    await c.query(`DELETE FROM question_mastery WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
    await c.query(`DELETE FROM question_hidden WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
    await c.query(`DELETE FROM import_batches WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
    await c.query(
      `DELETE FROM questions
        WHERE owner_user_id IN ($1, $2)
           OR subject_id IN (
                SELECT s.id FROM subjects s
                  JOIN exam_profiles p ON p.id = s.exam_profile_id
                 WHERE p.user_id IN ($1, $2))`,
      [seed.userA, seed.userB],
    );
    await c.query(
      `DELETE FROM subjects WHERE exam_profile_id IN (SELECT id FROM exam_profiles WHERE user_id IN ($1, $2))`,
      [seed.userA, seed.userB],
    );
    await c.query(`DELETE FROM exam_profiles WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
    await c.query(`DELETE FROM users WHERE id IN ($1, $2)`, [seed.userA, seed.userB]);
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
    throw new Error(`after(): 清理数据失败：${cleanupFailure.message}`);
  }
});

test('GET /export/questions：A 导 5 道题 + 相关科目/考点/用户信息', skipOpt, async () => {
  const res = await req('GET', '/export/questions', TOKEN_A);
  assert.equal(res.status, 200, `导出应 200，实得 ${res.status}：${JSON.stringify(res.data)}`);

  const body = res.data;

  // ── 顶层骨架 ──────────────────────────────────────────────────
  assert.equal(body.version, '1.0');
  assert.ok(typeof body.exported_at === 'string' && body.exported_at.length > 0, 'exported_at 必须是非空字符串');
  assert.equal(body.user.id, seed.userA);
  assert.equal(body.user.nickname, '导出用户A');

  // ── 题目：只有自己的 5 道 ───────────────────────────────────────
  const stems = body.questions.map((q) => q.stem).sort();
  assert.deepEqual(stems, [
    '导出五道简答题',
    '导出一道选择题',
    '导出三道判断题',
    '导出二道多选题',
    '导出四道无科目题',
  ].sort());
  assert.equal(body.questions.length, 5, '只应导出 A 自己的 5 道题');

  // 公共题与 B 的题绝不能出现（A2 口径：导出 ≠ 列表可见性）。
  const allStems = body.questions.map((q) => q.stem).join('|');
  assert.ok(!allStems.includes('公共题不该被导出'), '公共题不该被导出');
  assert.ok(!allStems.includes('B的题不该被导出'), 'B 的私有题不该被导出');

  // ── 题目字段完整性（含 answer / analysis，A2 要求）────────────
  const withNode = body.questions.find((q) => q.stem === '导出一道选择题');
  assert.ok(withNode, '应能按题干定位到带考点的那道题');
  assert.equal(withNode.subject_id, seed.subjectA);
  assert.equal(withNode.knowledge_node_id, seed.nodeA);
  assert.equal(withNode.type, 'choice');
  assert.equal(withNode.answer, 'A', 'answer 必须导出（导给用户自己的备份）');
  assert.ok(typeof withNode.analysis === 'string' && withNode.analysis.length > 0, 'analysis 必须导出');
  assert.equal(withNode.content_hash, 'hash-export-a1');
  assert.equal(withNode.is_subjective, false);
  assert.ok(Array.isArray(withNode.options), 'options 应是数组');
  assert.equal(withNode.options.length, 2);

  // 无科目题：subject_id / knowledge_node_id 都是 null，字段仍要存在（不是缺键）。
  const noSubject = body.questions.find((q) => q.stem === '导出四道无科目题');
  assert.ok(noSubject);
  assert.equal(noSubject.subject_id, null);
  assert.equal(noSubject.knowledge_node_id, null);
  assert.ok('subject_id' in noSubject && 'knowledge_node_id' in noSubject);

  // 主观题标记（short_answer 属 SUBJECTIVE_TYPES）
  const subjective = body.questions.find((q) => q.stem === '导出五道简答题');
  assert.equal(subjective.is_subjective, true, 'short_answer 应标 is_subjective=true');
});

test('GET /export/questions：科目与考点取用户全量（不只被引用的）', skipOpt, async () => {
  const res = await req('GET', '/export/questions', TOKEN_A);
  assert.equal(res.status, 200);

  // 科目：A 只有 1 个，且 exam_profile_id 归属正确。
  const subjectIds = res.data.subjects.map((s) => s.id);
  assert.deepEqual(subjectIds, [seed.subjectA]);
  const subjectA = res.data.subjects[0];
  assert.equal(subjectA.name, '导出科目A');
  assert.equal(subjectA.kind, 'objective');
  assert.equal(subjectA.exam_profile_id, seed.profileA);

  // 考点：A 只有 1 个；weight_to_target 必须是数字（numeric(4,3) 经 pg 是字符串，
  // 导出端点负责转 number —— 这是 shapeNode 的唯一存在理由）。
  const nodeIds = res.data.knowledge_nodes.map((n) => n.id);
  assert.deepEqual(nodeIds, [seed.nodeA]);
  const nodeA = res.data.knowledge_nodes[0];
  assert.equal(nodeA.subject_id, seed.subjectA);
  assert.equal(nodeA.parent_id, null);
  assert.equal(nodeA.title, '导出考点A');
  assert.equal(nodeA.freq_tag, 'high');
  assert.equal(typeof nodeA.weight_to_target, 'number', 'weight_to_target 应转成 number');
  assert.equal(nodeA.weight_to_target, 0.5);

  // B 的科目 / 考点绝不能混进来。
  assert.ok(!subjectIds.includes(seed.subjectB), 'B 的科目不该出现');
  assert.ok(!nodeIds.includes(seed.nodeB), 'B 的考点不该出现');
});

test('GET /export/questions：不导出练习记录 / 缺陷单', skipOpt, async () => {
  const res = await req('GET', '/export/questions', TOKEN_A);
  assert.equal(res.status, 200);

  // 顶层只应有这 6 个键：多出任何「练习/缺陷单」类字段都是超范围（A3）。
  assert.deepEqual(
    Object.keys(res.data).sort(),
    ['exported_at', 'knowledge_nodes', 'questions', 'subjects', 'user', 'version'],
  );
});

test('GET /export/questions：B 导出只看到自己的 1 道题', skipOpt, async () => {
  const res = await req('GET', '/export/questions', TOKEN_B);
  assert.equal(res.status, 200);
  assert.equal(res.data.user.id, seed.userB);
  assert.equal(res.data.user.nickname, '导出用户B');
  assert.deepEqual(res.data.questions.map((q) => q.stem), ['B的题不该被导出']);
  assert.deepEqual(res.data.subjects.map((s) => s.id), [seed.subjectB]);
  assert.deepEqual(res.data.knowledge_nodes.map((n) => n.id), [seed.nodeB]);
});

test('GET /export/questions：无 Token → 401', skipOpt, async () => {
  const res = await req('GET', '/export/questions', null);
  assert.equal(res.status, 401);
  assert.equal(res.data.error, 'unauthorized');
});

test('GET /export/questions：软删的题不出现在导出里', skipOpt, async () => {
  // 先把 a2 软删，导出应只剩 4 道；再恢复（用 UPDATE，不走接口，避免依赖别的端点）。
  const c = await pool.connect();
  try {
    await c.query(`UPDATE questions SET deleted_at = now() WHERE id = $1`, [seed.q.a2]);
  } finally {
    c.release();
  }

  const res = await req('GET', '/export/questions', TOKEN_A);
  assert.equal(res.status, 200);
  assert.equal(res.data.questions.length, 4, '软删的题不该导出');
  assert.ok(!res.data.questions.some((q) => q.stem === '导出二道多选题'));

  const c2 = await pool.connect();
  try {
    await c2.query(`UPDATE questions SET deleted_at = NULL WHERE id = $1`, [seed.q.a2]);
  } finally {
    c2.release();
  }
});
