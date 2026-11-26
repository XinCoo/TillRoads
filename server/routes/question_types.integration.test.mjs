// server/routes/question_types.integration.test.mjs
// 题路 TillRoad · m27163：GET /question-types（题型词表）的真实 PG 集成测试
//
// 与 server/routes/questions.integration.test.mjs 分工：
//   * questions.integration.test.mjs —— 题目 CRUD / 批量软删 / 批量恢复
//   * 本文件 —— 「已导入题目中出现的题型」列表的口径（scope / q / 鉴权）
//
// 覆盖：
//   1) 默认 scope=imported：只统计 source='import' 的题（choice=2、multi=1）
//   2) scope=all：包含全部来源（manual 那道也计入）
//   3) scope=other：只统计非 import 来源
//   4) q=ch 模糊匹配：只返回 type 含 'ch' 的
//   5) 无 token → 401
//   6) 非法 scope → 400 INVALID_SCOPE
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

const TOKEN_A = 'tk_qtypes_a';

let pool;
let app;
let base;
let seed; // { userId, profileId, subjectId }

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

/** 造用户 + 考试目标 + 科目。 */
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

/** 插一道指定 source / type 的题。 */
async function makeQuestion(c, { subjectId, ownerUserId, source, type, stem }) {
  const r = await c.query(
    `INSERT INTO questions
       (source, subject_id, type, stem, options, answer, content_hash, owner_user_id)
     VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7, $8)
     RETURNING id`,
    [
      source,
      subjectId,
      type,
      stem,
      JSON.stringify([{ key: 'A', text: '选项甲' }]),
      'A',
      `hash-qtypes-${stem}`,
      ownerUserId ?? null,
    ],
  );
  return r.rows[0].id;
}

function byType(items) {
  const map = new Map();
  for (const it of items) map.set(it.type, it.count);
  return map;
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
    const u = await makeUser(c, '题型用户');
    seed = { userId: u.userId, profileId: u.profileId, subjectId: u.subjectId };
    // 3 道 import：choice / multi / choice
    await makeQuestion(c, { subjectId: seed.subjectId, ownerUserId: seed.userId, source: 'import', type: 'choice', stem: '导入选择题1' });
    await makeQuestion(c, { subjectId: seed.subjectId, ownerUserId: seed.userId, source: 'import', type: 'multi', stem: '导入多选题' });
    await makeQuestion(c, { subjectId: seed.subjectId, ownerUserId: seed.userId, source: 'import', type: 'choice', stem: '导入选择题2' });
    // 1 道 manual（type 独有：manual_only）→ 默认口径下不应出现
    await makeQuestion(c, { subjectId: seed.subjectId, ownerUserId: seed.userId, source: 'manual', type: 'manual_only', stem: '手动录入题' });
  } finally {
    c.release();
  }

  process.env.TOKENS = `${TOKEN_A}:${seed.userId}`;
  app = createApp({ pool });
  await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${app.server.address().port}`;
});

after(async () => {
  if (!RUN || !app) return;
  const c = await pool.connect();
  let cleanupFailure = null;
  try {
    await c.query(`DELETE FROM defect_questions WHERE question_id IN (SELECT id FROM questions WHERE subject_id=$1)`, [seed.subjectId]);
    await c.query(`DELETE FROM questions WHERE subject_id=$1`, [seed.subjectId]);
    await c.query(`DELETE FROM subjects WHERE id=$1`, [seed.subjectId]);
    await c.query(`DELETE FROM exam_profiles WHERE id=$1`, [seed.profileId]);
    await c.query(`DELETE FROM users WHERE id=$1`, [seed.userId]);
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

test('GET /question-types 无 token → 401', skipOpt, async () => {
  const r = await req('GET', '/question-types');
  assert.equal(r.status, 401, JSON.stringify(r.data));
  assert.equal(r.data.error, 'unauthorized');
});

test('GET /question-types 默认 scope=imported：只统计导入题（choice=2、multi=1）', skipOpt, async () => {
  const r = await req('GET', '/question-types', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.scope, 'imported');
  const map = byType(r.data.items);
  assert.equal(map.get('choice'), 2);
  assert.equal(map.get('multi'), 1);
  // manual 那道题的独有 type 不该出现
  assert.equal(map.has('manual_only'), false);
  assert.equal(r.data.total, r.data.items.length);
  // 排序：count DESC, type ASC
  const counts = r.data.items.map((i) => i.count);
  assert.deepEqual([...counts].sort((a, b) => b - a), counts);
});

test('GET /question-types?scope=all：包含全部来源', skipOpt, async () => {
  const r = await req('GET', '/question-types?scope=all', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.scope, 'all');
  const map = byType(r.data.items);
  assert.equal(map.get('choice'), 2);
  assert.equal(map.get('multi'), 1);
  assert.equal(map.get('manual_only'), 1);
});

test('GET /question-types?scope=other：只统计非导入来源', skipOpt, async () => {
  const r = await req('GET', '/question-types?scope=other', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.scope, 'other');
  const map = byType(r.data.items);
  assert.equal(map.get('manual_only'), 1);
  assert.equal(map.has('choice'), false);
});

test('GET /question-types?q=ch：模糊匹配只返回含 ch 的题型', skipOpt, async () => {
  const r = await req('GET', '/question-types?q=ch', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  const map = byType(r.data.items);
  assert.equal(map.has('choice'), true);
  assert.equal(map.get('choice'), 2);
  assert.equal(map.has('multi'), false);
  assert.equal(map.has('manual_only'), false);
});

test('GET /question-types?scope=bogus → 400 INVALID_SCOPE', skipOpt, async () => {
  const r = await req('GET', '/question-types?scope=bogus', undefined, TOKEN_A);
  assert.equal(r.status, 400, JSON.stringify(r.data));
  assert.equal(r.data.error, 'INVALID_SCOPE');
});
