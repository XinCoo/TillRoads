// server/routes/question_mastery.integration.test.mjs
// 题路 TillRoad · 练习模式 R2（m25316）：题目掌握度真实 PG 集成测试
//
// 只有 RUN_PG_INTEGRATION=1 才跑（CI 会设），本机无 PG 时整文件跳过。
//
// 覆盖任务书要求的四件事：
//   1. **自己题的 upsert 成功**（且重复标记幂等，不产生第二行）；
//   2. **公共题 403**（不能标记别人的题 —— 公共题是别人上传的，标记会污染他人内容）；
//   3. **mastered 过滤正确**（GET /questions?mastered=true 只回已掌握，false 只回未掌握，
//      且「未标记」的题两个值都不匹配）；
//   4. **多用户隔离**（B 的标记不影响 A 的过滤结果）。
//
// 为什么必须连真库：
//   * 「upsert 幂等」依赖 UNIQUE(user_id, question_id) 约束 + ON CONFLICT；
//   * 「mastered 过滤」依赖 EXISTS 子查询真的在 SQL 里生效；
//   * fake 仓储伪造不出这些。
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

const TOKEN_A = 'tk_mastery_a';
const TOKEN_B = 'tk_mastery_b';

let pool;
let app;
let base;
let seed; // { userA, userB, profileA, profileB, subjectA, subjectB, ownA: [id...], ownB: [id...], publicId }

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

/** 插一道题。ownerUserId=null → 公共题（owner_user_id IS NULL）。 */
async function makeQuestion(c, { subjectId, ownerUserId, stem, answer = 'A' }) {
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
      `hash-mastery-${stem}`,
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
    const a = await makeUser(c, '掌握用户A');
    const b = await makeUser(c, '掌握用户B');
    seed = {
      userA: a.userId,
      userB: b.userId,
      profileA: a.profileId,
      profileB: b.profileId,
      subjectA: a.subjectId,
      subjectB: b.subjectId,
    };

    // A 名下 3 道私有题；B 名下 2 道私有题；另加 1 道公共题。
    seed.ownA = [];
    for (let i = 1; i <= 3; i += 1) {
      seed.ownA.push(
        await makeQuestion(c, {
          subjectId: seed.subjectA,
          ownerUserId: seed.userA,
          stem: `A自有掌握题${i}`,
        }),
      );
    }
    seed.ownB = [];
    for (let i = 1; i <= 2; i += 1) {
      seed.ownB.push(
        await makeQuestion(c, {
          subjectId: seed.subjectB,
          ownerUserId: seed.userB,
          stem: `B自有掌握题${i}`,
        }),
      );
    }
    seed.publicId = await makeQuestion(c, {
      subjectId: seed.subjectA,
      ownerUserId: null,
      stem: '公共掌握题',
    });
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
    // 先删掌握度（question_mastery 有 FK 指向 questions 与 users）
    await c.query(`DELETE FROM question_mastery WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
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

test('m25316：PATCH /questions/:id/mastery —— 自己题 upsert 成功且幂等', skipOpt, async () => {
  const id = seed.ownA[0];
  const r1 = await req('PATCH', `/questions/${id}/mastery`, { mastered: true }, TOKEN_A);
  assert.equal(r1.status, 200);
  assert.equal(r1.data.mastered, true);
  assert.equal(r1.data.question_id, id);

  // 幂等：重复标记同一状态，仍然只有一行。
  const r2 = await req('PATCH', `/questions/${id}/mastery`, { mastered: true }, TOKEN_A);
  assert.equal(r2.status, 200);
  assert.equal(r2.data.mastered, true);

  const c = await pool.connect();
  try {
    const rows = await c.query(
      `SELECT COUNT(*)::int AS n FROM question_mastery WHERE user_id = $1 AND question_id = $2`,
      [seed.userA, id],
    );
    assert.equal(rows.rows[0].n, 1);
  } finally {
    c.release();
  }
});

test('m25316：公共题标记 -> 403 FORBIDDEN_MASTERY', skipOpt, async () => {
  const r = await req('PATCH', `/questions/${seed.publicId}/mastery`, { mastered: true }, TOKEN_A);
  assert.equal(r.status, 403);
  assert.equal(r.data.error, 'FORBIDDEN_MASTERY');
});

test('m25316：标记别人的私有题 -> 403；未鉴权 -> 401；mastered 非布尔 -> 400', skipOpt, async () => {
  const other = await req('PATCH', `/questions/${seed.ownB[0]}/mastery`, { mastered: true }, TOKEN_A);
  assert.equal(other.status, 403);
  assert.equal(other.data.error, 'FORBIDDEN_MASTERY');

  const anon = await req('PATCH', `/questions/${seed.ownA[0]}/mastery`, { mastered: true });
  assert.equal(anon.status, 401);
  assert.equal(anon.data.error, 'unauthorized');

  const bad = await req('PATCH', `/questions/${seed.ownA[0]}/mastery`, { mastered: 'yes' }, TOKEN_A);
  assert.equal(bad.status, 400);
  assert.equal(bad.data.error, 'INVALID_MASTERY');
});

test('m25316：GET /questions?mastered=true|false 过滤正确（未标记的题两边都不出现）', skipOpt, async () => {
  // A1 已掌握；A2 未掌握；A3 未标记。
  await req('PATCH', `/questions/${seed.ownA[1]}/mastery`, { mastered: false }, TOKEN_A);

  const yes = await req('GET', '/questions?mastered=true&limit=200', undefined, TOKEN_A);
  assert.equal(yes.status, 200);
  const yesIds = yes.data.items.map((it) => it.id);
  assert.ok(yesIds.includes(seed.ownA[0]), '已掌握的题应出现在 mastered=true 结果里');
  assert.ok(!yesIds.includes(seed.ownA[1]), '未掌握的题不该出现在 mastered=true 结果里');
  assert.ok(!yesIds.includes(seed.ownA[2]), '未标记的题不该出现在 mastered=true 结果里');

  const no = await req('GET', '/questions?mastered=false&limit=200', undefined, TOKEN_A);
  assert.equal(no.status, 200);
  const noIds = no.data.items.map((it) => it.id);
  assert.ok(noIds.includes(seed.ownA[1]), '未掌握的题应出现在 mastered=false 结果里');
  assert.ok(!noIds.includes(seed.ownA[0]), '已掌握的题不该出现在 mastered=false 结果里');
  assert.ok(!noIds.includes(seed.ownA[2]), '未标记的题不该出现在 mastered=false 结果里');
});

test('m25316：题库列表每项带 mastered 三态（true / false / null）', skipOpt, async () => {
  const list = await req('GET', '/questions?limit=200', undefined, TOKEN_A);
  assert.equal(list.status, 200);
  const byId = new Map(list.data.items.map((it) => [it.id, it]));
  assert.equal(byId.get(seed.ownA[0]).mastered, true);
  assert.equal(byId.get(seed.ownA[1]).mastered, false);
  assert.equal(byId.get(seed.ownA[2]).mastered, null);
});

test('m25316：多用户隔离 —— B 的标记不影响 A 的过滤结果', skipOpt, async () => {
  // B 把自己的题标为已掌握。
  const rb = await req('PATCH', `/questions/${seed.ownB[0]}/mastery`, { mastered: true }, TOKEN_B);
  assert.equal(rb.status, 200);

  // A 视角：mastered=true 里不该出现 B 的题。
  const aYes = await req('GET', '/questions?mastered=true&limit=200', undefined, TOKEN_A);
  const aIds = aYes.data.items.map((it) => it.id);
  assert.ok(!aIds.includes(seed.ownB[0]), 'B 标记的题不该出现在 A 的已掌握列表里');

  // B 视角：B 自己的题在已掌握列表里。
  const bYes = await req('GET', '/questions?mastered=true&limit=200', undefined, TOKEN_B);
  const bIds = bYes.data.items.map((it) => it.id);
  assert.ok(bIds.includes(seed.ownB[0]), 'B 应能看到自己标记的题');
});
