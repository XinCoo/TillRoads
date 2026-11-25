// server/routes/practice.integration.test.mjs
// 题路 TillRoad · 练习模式 R1：真实 PG 集成测试
//
// 只有 RUN_PG_INTEGRATION=1 才跑（CI 会设），本机无 PG 时整文件跳过。
//
// 覆盖任务书要求的四件事：
//   1. **自己题的 answer 有值**（能自动判分）；
//   2. **公共题的 answer 为 null**（安全底线，题目说必须由仓储层保证）；
//   3. **多用户隔离**：B 看不到 A 的练习记录，A 看不到 B 的会话（404 不是 403）；
//   4. **题量不足时返回 available 字段**（不报错，前端据此提示）。
//
// 为什么必须连真库：
//   「公共题 answer 为 null」这条依赖 SQL 里的 CASE WHEN 判断；
//   「多用户隔离」依赖 practice_sessions.user_id 真写进了列；
//   fake 仓储伪造不出这些。
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

const TOKEN_A = 'tk_practice_a';
const TOKEN_B = 'tk_practice_b';

let pool;
let app;
let base;
let seed; // { userA, userB, profileA, profileB, subjectA, subjectB, publicQuestionId }

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

/** 造一个用户 + 考试目标 + 科目，返回 id。 */
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

/**
 * 插一道题。
 * ownerUserId=null → 公共题（owner_user_id IS NULL）。
 */
async function makeQuestion(c, { subjectId, ownerUserId, stem, answer }) {
  const r = await c.query(
    `INSERT INTO questions
       (source, subject_id, type, stem, options, answer, content_hash, owner_user_id)
     VALUES ('import', $1, 'choice', $2, $3::jsonb, $4, $5, $6)
     RETURNING id`,
    [
      subjectId,
      stem,
      JSON.stringify([{ key: 'A', text: '选项甲' }, { key: 'B', text: '选项乙' }]),
      answer,
      `hash-practice-${stem}`,
      ownerUserId,
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
    const a = await makeUser(c, '练习用户A');
    const b = await makeUser(c, '练习用户B');
    seed = {
      userA: a.userId,
      userB: b.userId,
      profileA: a.profileId,
      profileB: b.profileId,
      subjectA: a.subjectId,
      subjectB: b.subjectId,
    };
    // A 名下 3 道私有题（带答案）
    for (let i = 1; i <= 3; i += 1) {
      await makeQuestion(c, {
        subjectId: seed.subjectA,
        ownerUserId: seed.userA,
        stem: `A私有练习题${i}`,
        answer: 'A',
      });
    }
    // B 名下 2 道私有题（带答案）
    for (let i = 1; i <= 2; i += 1) {
      await makeQuestion(c, {
        subjectId: seed.subjectB,
        ownerUserId: seed.userB,
        stem: `B私有练习题${i}`,
        answer: 'B',
      });
    }
    // 2 道公共题（owner_user_id IS NULL，**也带答案** —— 用来验证练习端点把它抹掉）
    for (let i = 1; i <= 2; i += 1) {
      await makeQuestion(c, {
        subjectId: seed.subjectA,
        ownerUserId: null,
        stem: `公共练习题${i}`,
        answer: 'A',
      });
    }
  } finally {
    c.release();
  }

  process.env.TOKENS = `${TOKEN_A}:${seed.userA},${TOKEN_B}:${seed.userB}`;
  app = createApp({ pool });
  await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${app.server.address().port}`;
});

after(async () => {
  if (!RUN || !app) return;

  const c = await pool.connect();
  let cleanupFailure = null;
  try {
    // 先删练习记录（practice_answers 有 FK 指向 practice_sessions 与 questions）
    await c.query(
      `DELETE FROM practice_answers WHERE session_id IN (SELECT id FROM practice_sessions WHERE user_id IN ($1, $2))`,
      [seed.userA, seed.userB],
    );
    await c.query(`DELETE FROM practice_sessions WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
    // 再删题：owner 归属的 + 挂在这些科目下的公共题
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

// ---------------------------------------------------------------------------
// 1) 自己抽到的题带答案
// ---------------------------------------------------------------------------
test('练习 R1：source=mine 抽到的自己的题带 answer（能自动判分）', skipOpt, async () => {
  const r = await req('GET', '/questions/practice?source=mine&count=10', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.items.length, 3, 'A 自己的科目下只有 3 道题');
  assert.equal(r.data.available, 3);
  for (const item of r.data.items) {
    assert.equal(item.answer, 'A', '自己的题必须带答案');
    assert.equal(item.has_answer, true);
    assert.equal(item.is_mine, true);
  }
});

// ---------------------------------------------------------------------------
// 2) 公共题的 answer 必须是 null（安全底线）
// ---------------------------------------------------------------------------
test('练习 R1：公共题 answer 返回 null（仓储层保证，不依赖路由过滤）', skipOpt, async () => {
  const r = await req('GET', '/questions/practice?source=public&count=10', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.items.length, 2, '公共题 2 道');
  for (const item of r.data.items) {
    assert.equal(item.answer, null, '公共题不能下发答案');
    assert.equal(item.analysis, null);
    assert.equal(item.has_answer, false, '没有答案 → 前端显示「请自评」');
    assert.equal(item.is_mine, false);
  }
});

test('练习 R1：source=all 混合抽题时，只有自己的题带答案', skipOpt, async () => {
  const r = await req('GET', '/questions/practice?source=all&count=10', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.items.length, 5, '公共 2 + 自己 3');
  const mine = r.data.items.filter((i) => i.is_mine);
  const pub = r.data.items.filter((i) => !i.is_mine);
  assert.equal(mine.length, 3);
  assert.equal(pub.length, 2);
  for (const item of mine) assert.equal(item.answer, 'A');
  for (const item of pub) assert.equal(item.answer, null);
});

// ---------------------------------------------------------------------------
// 3) 题量不足 → available 字段（不报错）
// ---------------------------------------------------------------------------
test('练习 R1：题量不足时返回 available，不报错', skipOpt, async () => {
  const r = await req('GET', '/questions/practice?source=mine&count=50', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.items.length, 3);
  assert.equal(r.data.available, 3, 'available 必须告诉前端实际有多少题');
  assert.equal(r.data.requested, 50);
});

// ---------------------------------------------------------------------------
// 4) 提交练习 → 统计口径在服务端算
// ---------------------------------------------------------------------------
test('练习 R1：POST /practice-sessions 返回服务端算出的 total/correct/wrong/accuracy', skipOpt, async () => {
  const pick = await req('GET', '/questions/practice?source=mine&count=3', undefined, TOKEN_A);
  assert.equal(pick.status, 200);
  const answers = pick.data.items.map((item, idx) => ({
    question_id: item.id,
    user_answer: 'A',
    is_correct: idx === 0 ? true : idx === 1 ? false : null,
    duration_ms: 1000 * (idx + 1),
  }));
  const r = await req(
    'POST',
    '/practice-sessions',
    { subject_id: seed.subjectA, source: 'mine', answers },
    TOKEN_A,
  );
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.total, 3);
  assert.equal(r.data.correct, 1);
  assert.equal(r.data.wrong, 1);
  assert.equal(r.data.unjudged, 1, 'is_correct=null 的题算「未判定」');
  assert.ok(r.data.session_id, '必须返回 session_id');

  // 详情能读到每题对错
  const detail = await req('GET', `/practice-sessions/${r.data.session_id}`, undefined, TOKEN_A);
  assert.equal(detail.status, 200, JSON.stringify(detail.data));
  assert.equal(detail.data.answers.length, 3);
  assert.equal(detail.data.session.correct, 1);
  const judged = detail.data.answers.filter((a) => a.is_correct !== null);
  assert.equal(judged.length, 2);
});

// ---------------------------------------------------------------------------
// 5) 多用户隔离
// ---------------------------------------------------------------------------
test('练习 R1：练习历史只返回自己的会话', skipOpt, async () => {
  const r = await req('GET', '/practice-sessions', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.items.length, 1, 'A 只有自己刚做的那一次');
  assert.equal(r.data.total, 1);

  const b = await req('GET', '/practice-sessions', undefined, TOKEN_B);
  assert.equal(b.status, 200);
  assert.equal(b.data.items.length, 0, 'B 不该看到 A 的练习记录');
  assert.equal(b.data.total, 0);
});

test('练习 R1：读别人的会话 → 404（不是 403）', skipOpt, async () => {
  const list = await req('GET', '/practice-sessions', undefined, TOKEN_A);
  const sessionId = list.data.items[0].id;
  const r = await req('GET', `/practice-sessions/${sessionId}`, undefined, TOKEN_B);
  assert.equal(r.status, 404, '别人的练习应当当作不存在');
});

// ---------------------------------------------------------------------------
// 6) 未鉴权
// ---------------------------------------------------------------------------
test('练习 R1：未带 Token 一律 401', skipOpt, async () => {
  const pick = await req('GET', '/questions/practice?count=10', undefined, undefined);
  assert.equal(pick.status, 401);
  const list = await req('GET', '/practice-sessions', undefined, undefined);
  assert.equal(list.status, 401);
});
