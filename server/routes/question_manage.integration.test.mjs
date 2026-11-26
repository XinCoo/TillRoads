// server/routes/question_manage.integration.test.mjs
// 题路 TillRoad · 练习模式 R3（m26090）：已掌握题移除 + 恢复 + 公共题隐藏
//
// 只有 RUN_PG_INTEGRATION=1 才跑（CI 会设），本机无 PG 时整文件跳过。
//
// 覆盖任务书要求的六件事：
//   1. **软删只对自己的题生效**（DELETE /questions/:id），删后列表不再出现、
//      GET /questions/deleted 能看到、恢复后重新出现；
//   2. **公共题不能软删 → 403 FORBIDDEN_DELETE**（公共题不属于任何用户，
//      用户无权把它从公共题库里拿走；只能隐藏）；
//   3. **批量删除 / 批量恢复**（DELETE /questions/batch、PATCH /questions/batch/restore）；
//   4. **隐藏公共题后，题库列表与练习抽题都排除它**（但题还在，别人照常看得到）；
//   5. **多用户隔离**：A 删/隐藏的题不影响 B；
//   6. **别人的私有题 → 404**（不可见，避免枚举）。
//
// 为什么必须连真库：
//   * 「恢复」依赖 deleted_at 的软删语义与 set_updated() 触发器；
//   * 「隐藏过滤」依赖 NOT EXISTS 子查询真的在 SQL 里生效；
//   * 批量操作依赖 `id = ANY($1::uuid[])` 与 owner_user_id 条件；
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

const TOKEN_A = 'tk_manage_a';
const TOKEN_B = 'tk_manage_b';

let pool;
let app;
let base;
let seed; // { userA, userB, profileA, profileB, subjectA, subjectB, ownA, ownB, publicId }

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
      `hash-manage-${stem}`,
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
    const a = await makeUser(c, '管理用户A');
    const b = await makeUser(c, '管理用户B');
    seed = {
      userA: a.userId,
      userB: b.userId,
      profileA: a.profileId,
      profileB: b.profileId,
      subjectA: a.subjectId,
      subjectB: b.subjectId,
    };

    // A 名下 4 道私有题（够批量操作）；B 名下 1 道；另加 1 道公共题。
    seed.ownA = [];
    for (let i = 1; i <= 4; i += 1) {
      seed.ownA.push(
        await makeQuestion(c, {
          subjectId: seed.subjectA,
          ownerUserId: seed.userA,
          stem: `A自有管理题${i}`,
        }),
      );
    }
    seed.ownB = [
      await makeQuestion(c, {
        subjectId: seed.subjectB,
        ownerUserId: seed.userB,
        stem: 'B自有管理题',
      }),
    ];
    seed.publicId = await makeQuestion(c, {
      subjectId: seed.subjectA,
      ownerUserId: null,
      stem: '公共管理题',
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
    // 顺序要紧：先删引用表（FK 指向 questions / users），再删题。
    await c.query(`DELETE FROM question_hidden WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
    await c.query(`DELETE FROM question_mastery WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
    await c.query(`DELETE FROM practice_answers WHERE question_id IN (SELECT id FROM questions)`);
    await c.query(`DELETE FROM practice_sessions WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
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

test('m26090：软删自己的题 -> 列表不再出现、已删除列表能看到、恢复后重新出现', skipOpt, async () => {
  const id = seed.ownA[0];
  const c = await pool.connect();
  let version;
  try {
    const row = await c.query(`SELECT version FROM questions WHERE id = $1`, [id]);
    version = row.rows[0].version;
  } finally {
    c.release();
  }

  const del = await req('DELETE', `/questions/${id}`, { version }, TOKEN_A);
  assert.equal(del.status, 200, JSON.stringify(del.data));
  assert.equal(del.data.deleted, true);
  assert.equal(del.data.id, id);

  const listed = await req('GET', '/questions?limit=200', undefined, TOKEN_A);
  assert.equal(listed.status, 200);
  assert.ok(!listed.data.items.some((q) => q.id === id), '软删的题不应出现在题库列表');

  const gone = await req('GET', `/questions/${id}`, undefined, TOKEN_A);
  assert.equal(gone.status, 404, JSON.stringify(gone.data));

  const deletedList = await req('GET', '/questions/deleted?limit=200', undefined, TOKEN_A);
  assert.equal(deletedList.status, 200, JSON.stringify(deletedList.data));
  assert.ok(
    deletedList.data.items.some((q) => q.id === id),
    '软删的题应出现在「已删除」列表里',
  );

  const restored = await req('PATCH', `/questions/${id}/restore`, {}, TOKEN_A);
  assert.equal(restored.status, 200, JSON.stringify(restored.data));
  assert.equal(restored.data.deleted, false);

  const listedAgain = await req('GET', '/questions?limit=200', undefined, TOKEN_A);
  assert.ok(
    listedAgain.data.items.some((q) => q.id === id),
    '恢复后题应重新出现在题库列表',
  );
});

test('m26090：公共题不能软删 -> 403 FORBIDDEN_DELETE；别人的私有题 -> 404', skipOpt, async () => {
  const delPublic = await req('DELETE', `/questions/${seed.publicId}`, { version: 1 }, TOKEN_A);
  assert.equal(delPublic.status, 403, JSON.stringify(delPublic.data));
  assert.equal(delPublic.data.error, 'FORBIDDEN_DELETE');
  assert.match(String(delPublic.data.message), /公共题/);

  const delOther = await req('DELETE', `/questions/${seed.ownB[0]}`, { version: 1 }, TOKEN_A);
  assert.equal(delOther.status, 404, JSON.stringify(delOther.data));

  const noToken = await req('DELETE', `/questions/${seed.ownA[1]}`, { version: 1 });
  assert.equal(noToken.status, 401, JSON.stringify(noToken.data));
});

test('m26090：批量软删 + 批量恢复；公共题被静默跳过并计入 skipped', skipOpt, async () => {
  const ids = [seed.ownA[1], seed.ownA[2], seed.publicId];
  const del = await req('DELETE', '/questions/batch', { ids }, TOKEN_A);
  assert.equal(del.status, 200, JSON.stringify(del.data));
  assert.equal(del.data.requested, 3);
  assert.equal(del.data.deleted, 2, '公共题不该被删');
  assert.equal(del.data.skipped, 1);

  const listed = await req('GET', '/questions?limit=200', undefined, TOKEN_A);
  assert.ok(!listed.data.items.some((q) => q.id === ids[0]));
  assert.ok(!listed.data.items.some((q) => q.id === ids[1]));
  assert.ok(listed.data.items.some((q) => q.id === seed.publicId), '公共题应仍在列表里');

  const restore = await req('PATCH', '/questions/batch/restore', { ids: [ids[0], ids[1]] }, TOKEN_A);
  assert.equal(restore.status, 200, JSON.stringify(restore.data));
  assert.equal(restore.data.restored, 2);
  assert.equal(restore.data.skipped, 0);

  const listedAgain = await req('GET', '/questions?limit=200', undefined, TOKEN_A);
  assert.ok(listedAgain.data.items.some((q) => q.id === ids[0]));
  assert.ok(listedAgain.data.items.some((q) => q.id === ids[1]));

  const empty = await req('DELETE', '/questions/batch', { ids: [] }, TOKEN_A);
  assert.equal(empty.status, 400, JSON.stringify(empty.data));
  assert.equal(empty.data.error, 'EMPTY_IDS');
});

test('m26090：隐藏公共题 -> 题库列表与练习抽题都排除它；取消隐藏后恢复', skipOpt, async () => {
  const hide = await req('PATCH', `/questions/${seed.publicId}/hide`, { hidden: true }, TOKEN_A);
  assert.equal(hide.status, 200, JSON.stringify(hide.data));
  assert.equal(hide.data.hidden, true);

  const listed = await req('GET', '/questions?limit=200', undefined, TOKEN_A);
  assert.ok(
    !listed.data.items.some((q) => q.id === seed.publicId),
    '被隐藏的题不应出现在 A 的题库列表',
  );

  const picked = await req('GET', '/questions/practice?source=public&count=50', undefined, TOKEN_A);
  assert.equal(picked.status, 200, JSON.stringify(picked.data));
  assert.ok(
    !picked.data.items.some((q) => q.id === seed.publicId),
    '被隐藏的题不应被练习抽到',
  );

  // ★ 多用户隔离：B 看不到 A 的隐藏记录，公共题对 B 照常可见。
  const listedB = await req('GET', '/questions?limit=200', undefined, TOKEN_B);
  assert.ok(
    listedB.data.items.some((q) => q.id === seed.publicId),
    'A 的隐藏不应该影响 B 看到公共题',
  );

  const unhide = await req('PATCH', `/questions/${seed.publicId}/hide`, { hidden: false }, TOKEN_A);
  assert.equal(unhide.status, 200, JSON.stringify(unhide.data));

  const listedAgain = await req('GET', '/questions?limit=200', undefined, TOKEN_A);
  assert.ok(
    listedAgain.data.items.some((q) => q.id === seed.publicId),
    '取消隐藏后题应重新出现',
  );

  const bad = await req('PATCH', `/questions/${seed.publicId}/hide`, { hidden: 'yes' }, TOKEN_A);
  assert.equal(bad.status, 400, JSON.stringify(bad.data));
  assert.equal(bad.data.error, 'INVALID_HIDDEN');
});

test('m26090：已删除列表只列自己的题；恢复别人或未删除的题 → 404 / 400', skipOpt, async () => {
  const deletedList = await req('GET', '/questions/deleted?limit=200', undefined, TOKEN_A);
  assert.equal(deletedList.status, 200, JSON.stringify(deletedList.data));
  for (const item of deletedList.data.items) {
    assert.equal(item.owner_user_id, seed.userA, '「已删除」列表不应出现别人的题');
  }

  const restoreOther = await req('PATCH', `/questions/${seed.ownB[0]}/restore`, {}, TOKEN_A);
  assert.equal(restoreOther.status, 404, JSON.stringify(restoreOther.data));

  const restoreAlive = await req('PATCH', `/questions/${seed.ownA[3]}/restore`, {}, TOKEN_A);
  assert.equal(restoreAlive.status, 400, JSON.stringify(restoreAlive.data));
  assert.equal(restoreAlive.data.error, 'not_deleted');
});

test('m26090：软删的题模考组卷抽不到（deleted_at IS NULL 已在 SQL 里）', skipOpt, async () => {
  const c = await pool.connect();
  let version;
  try {
    const row = await c.query(`SELECT version FROM questions WHERE id = $1`, [seed.ownA[3]]);
    version = row.rows[0].version;
  } finally {
    c.release();
  }
  const del = await req('DELETE', `/questions/${seed.ownA[3]}`, { version }, TOKEN_A);
  assert.equal(del.status, 200, JSON.stringify(del.data));

  const picked = await req('GET', '/questions/practice?source=mine&count=50', undefined, TOKEN_A);
  assert.equal(picked.status, 200, JSON.stringify(picked.data));
  assert.ok(
    !picked.data.items.some((q) => q.id === seed.ownA[3]),
    '软删的题不应被练习抽到',
  );
});
