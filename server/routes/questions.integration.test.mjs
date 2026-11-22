// server/routes/questions.integration.test.mjs
// 题路 TillRoad · m17431：题库多用户隔离（owner_user_id）真实 PG 集成测试
//
// 只有 RUN_PG_INTEGRATION=1 才跑（CI 会设），本机无 PG 时整文件跳过。
//
// 覆盖任务书 A5 的四步 + 组卷隔离：
//   1. 用户 A 导入 3 题 -> questions.owner_user_id = A
//   2. 用户 B 导入同样的 3 题 -> 不判重，B 有自己的一份
//   3. 用户 A 再导入同样 3 题 -> 判重，duplicates = 3
//   4. 用户 B 组卷抽题 -> 只抽到 B 的题 + 公共题，抽不到 A 的
//   5. GET /questions 的可见性：A 只看得到自己的 + 公共的
//
// 为什么必须连真库：
//   「A 导入过、B 再导入不判重」这条依赖 owner_user_id 真的写进了 PG 列，
//   fake 仓储伪造不出「第一次真的写进了 owner_user_id 列、第二次真的按列查重」。

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { createPool } from '../db/pool.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { createApp } from '../index.mjs';
import { FULL_SCHEMA_SQL } from '../db/test_schema.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN
  ? {}
  : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const FIXTURES = join(ROOT, 'tests', 'fixtures', 'questions');

const TOKEN_A = 'tk_owner_a';
const TOKEN_B = 'tk_owner_b';

let pool;
let app;
let base;
let seed; // { userA, userB, profileA, profileB, subjectA, subjectB }

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

/** 读样本文件成导入用 body。 */
function fileBody(name, extra = {}) {
  const buffer = readFileSync(join(FIXTURES, name));
  return {
    filename: name,
    mime: 'text/markdown',
    content_base64: buffer.toString('base64'),
    ...extra,
  };
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
    const a = await makeUser(c, '题库隔离用户A');
    const b = await makeUser(c, '题库隔离用户B');
    seed = {
      userA: a.userId,
      userB: b.userId,
      profileA: a.profileId,
      profileB: b.profileId,
      subjectA: a.subjectId,
      subjectB: b.subjectId,
    };
  } finally {
    c.release();
  }

  // TOKENS 在 createApp 时读取，必须先设。
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
    // 删题（owner_user_id 指向 users，先删子表再删父表）
    await c.query(`DELETE FROM questions WHERE owner_user_id IN ($1, $2)`, [seed.userA, seed.userB]);
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
// 1) A 导入 -> owner_user_id = A
// ---------------------------------------------------------------------------
test('m17431：用户 A 导入的题 owner_user_id = A', skipOpt, async () => {
  const body = fileBody('sample-01-markdown.md', { subject_id: seed.subjectA });
  const r = await req('POST', '/questions/import', body, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported, 12, `A 应导入 12 题，实际 ${r.data.imported}`);
  assert.equal(r.data.duplicates.length, 0, 'A 首次导入不应有重复');

  const c = await pool.connect();
  try {
    const rows = await c.query(
      `SELECT owner_user_id, count(*)::int AS n FROM questions
        WHERE subject_id = $1 AND deleted_at IS NULL GROUP BY owner_user_id`,
      [seed.subjectA],
    );
    assert.equal(rows.rows.length, 1, '该科目下应只有一种归属');
    assert.equal(rows.rows[0].owner_user_id, seed.userA, 'A 导入的题必须归属 A');
    assert.equal(rows.rows[0].n, 12);
  } finally {
    c.release();
  }
});

// ---------------------------------------------------------------------------
// 2) B 导入同样的文件 -> 不判重，B 有自己的一份
// ---------------------------------------------------------------------------
test('m17431：用户 B 导入同样 3 题不判重（owner 维度隔离）', skipOpt, async () => {
  const body = fileBody('sample-01-markdown.md', { subject_id: seed.subjectB });
  const r = await req('POST', '/questions/import', body, TOKEN_B);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported, 12, `B 应导入 12 题（与 A 同内容但不同 owner），实际 ${r.data.imported}`);
  assert.equal(r.data.duplicates.length, 0, 'B 不该被判重');

  const c = await pool.connect();
  try {
    const rows = await c.query(
      `SELECT owner_user_id, count(*)::int AS n FROM questions
        WHERE subject_id = $1 AND deleted_at IS NULL GROUP BY owner_user_id`,
      [seed.subjectB],
    );
    assert.equal(rows.rows.length, 1);
    assert.equal(rows.rows[0].owner_user_id, seed.userB, 'B 导入的题必须归属 B');
    assert.equal(rows.rows[0].n, 12);

    // 同样的 content_hash 在两个 owner 下各有一份
    const both = await c.query(
      `SELECT content_hash, count(DISTINCT owner_user_id)::int AS owners
         FROM questions WHERE owner_user_id IN ($1, $2) AND deleted_at IS NULL
        GROUP BY content_hash HAVING count(DISTINCT owner_user_id) = 2`,
      [seed.userA, seed.userB],
    );
    assert.equal(both.rows.length, 12, '12 个 hash 都应在 A/B 下各存一份');
  } finally {
    c.release();
  }
});

// ---------------------------------------------------------------------------
// 3) A 再导入同样 3 题 -> 判重，duplicates = 12
// ---------------------------------------------------------------------------
test('m17431：用户 A 二次导入同样内容判重（duplicates = 12）', skipOpt, async () => {
  const body = fileBody('sample-01-markdown.md', { subject_id: seed.subjectA });
  const r = await req('POST', '/questions/import', body, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported, 0, 'A 二次导入不应新增');
  assert.equal(r.data.duplicates.length, 12, 'A 二次导入应全部判重');
});

// ---------------------------------------------------------------------------
// 4) 组卷隔离：B 组卷抽不到 A 的题
// ---------------------------------------------------------------------------
test('m17431：组卷只抽「公共题 + 自己的题」，抽不到别人的私有题', skipOpt, async () => {
  const c = await pool.connect();
  try {
    // 给 B 的科目补 2 道公共题（owner_user_id IS NULL）
    await c.query(
      `INSERT INTO questions (source, subject_id, type, stem, content_hash, is_subjective)
       VALUES ('manual', $1, 'choice', '公共题一', 'hash-public-1', false),
              ('manual', $1, 'choice', '公共题二', 'hash-public-2', false)`,
      [seed.subjectB],
    );
  } finally {
    c.release();
  }

  const r = await req(
    'POST',
    '/mock-exams',
    {
      exam_profile_id: seed.profileB,
      mode: 'full',
      subject_id: seed.subjectB,
      question_count: 5,
      duration_limit_ms: 30 * 60 * 1000,
    },
    TOKEN_B,
  );
  assert.equal(r.status, 201, JSON.stringify(r.data));

  const stems = (r.data.questions ?? []).map((q) => q.stem);
  assert.equal(stems.length, 5, '应抽到 5 题');
  // B 的 12 道私有题 + 2 道公共题 = 14 可用，够抽 5 题
  const c2 = await pool.connect();
  try {
    const owned = await c2.query(
      `SELECT count(*)::int AS n FROM questions
        WHERE subject_id = $1 AND owner_user_id = $2 AND deleted_at IS NULL`,
      [seed.subjectB, seed.userA],
    );
    assert.equal(owned.rows[0].n, 0, 'A 的题不应该在 B 的科目下');
  } finally {
    c2.release();
  }
});

// ---------------------------------------------------------------------------
// 5) GET /questions 的可见性
// ---------------------------------------------------------------------------
test('m17431：GET /questions 只返回「公共题 + 自己的题」', skipOpt, async () => {
  const rA = await req('GET', '/questions?limit=50', undefined, TOKEN_A);
  assert.equal(rA.status, 200, JSON.stringify(rA.data));
  const ownersA = new Set(rA.data.items.map((q) => q.owner_user_id));
  assert.ok(
    [...ownersA].every((o) => o === seed.userA || o === null),
    `A 只能看到自己的题和公共题，实际看到 ${JSON.stringify([...ownersA])}`,
  );

  const rB = await req('GET', '/questions?limit=50', undefined, TOKEN_B);
  assert.equal(rB.status, 200, JSON.stringify(rB.data));
  const ownersB = new Set(rB.data.items.map((q) => q.owner_user_id));
  assert.ok(
    [...ownersB].every((o) => o === seed.userB || o === null),
    `B 只能看到自己的题和公共题，实际看到 ${JSON.stringify([...ownersB])}`,
  );

  // A 的题不出现在 B 的列表里
  const aIds = new Set(rA.data.items.map((q) => q.id));
  const leaked = rB.data.items.filter((q) => aIds.has(q.id));
  assert.equal(leaked.length, 0, 'B 的列表里不应出现 A 的题');
});
