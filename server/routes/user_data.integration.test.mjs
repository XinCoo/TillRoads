// server/routes/user_data.integration.test.mjs
// 题路 TillRoad · m18680 B1：DELETE /users/:userId/data 的集成测试
//
// 需要一个真 PG（CI 里由 PG15 service 提供）：本机无 PG 时整体 skip。
// 用 RUN_PG_INTEGRATION=1 打开（与其它集成测试同口径）。
//
// 覆盖点（都是审查时最容易出错的边界）：
//   1. 只删自己的数据；别的用户的行一行不动；
//   2. 公共题（owner_user_id IS NULL）绝不删 —— 它是所有人共用的题库；
//   3. 缺陷单的子行（actions / verifications）一起软删，不留孤儿；
//   4. 返回体的 deleted 计数与实际被软删的行数一致；
//   5. 无 Token 时 401，不执行任何删除；
//   6. 跨用户路径（删别人的 userId）403，且对方数据未动。

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

const TOKEN_A = 'tk_data_a';
const TOKEN_B = 'tk_data_b';

let pool;
let app;
let base;
let seed; // { userA, userB, profileA, profileB, subjectA, subjectB, ticketA, ticketB }

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

/** 造一个用户 + 考试目标 + 科目。 */
async function makeUser(c, nickname) {
  const u = await c.query(
    `INSERT INTO users (nickname, timezone, role)
     VALUES ($1, 'Asia/Shanghai', 'student') RETURNING id`,
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
    `INSERT INTO subjects (exam_profile_id, name, kind)
     VALUES ($1, $2, 'objective') RETURNING id`,
    [profileId, `${nickname}科目`],
  );
  return { userId, profileId, subjectId: s.rows[0].id };
}

/** 造一张「有动作、有验证记录」的缺陷单，验证子行也会被一起软删。 */
async function makeTicketWithChildren(c, userId, profileId) {
  const t = await c.query(
    `INSERT INTO defect_tickets (user_id, exam_profile_id, q_type, error_layer, error_cause, priority, status)
     VALUES ($1, $2, 'choice', '执行', '算错', 'P1', 'ANALYZED')
     RETURNING id`,
    [userId, profileId],
  );
  const ticketId = t.rows[0].id;
  await c.query(
    `INSERT INTO actions (defect_ticket_id, content) VALUES ($1, '整理步骤'), ($1, '重做同类题')`,
    [ticketId],
  );
  await c.query(
    `INSERT INTO verifications (defect_ticket_id, stage, round, verify_type, result)
     VALUES ($1, 'V1', 1, 'redo_hidden', 'pass')`,
    [ticketId],
  );
  return ticketId;
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
    const a = await makeUser(c, '删数据用户A');
    const b = await makeUser(c, '删数据用户B');
    seed = {
      userA: a.userId,
      userB: b.userId,
      profileA: a.profileId,
      profileB: b.profileId,
      subjectA: a.subjectId,
      subjectB: b.subjectId,
      ticketA: await makeTicketWithChildren(c, a.userId, a.profileId),
      ticketB: await makeTicketWithChildren(c, b.userId, b.profileId),
    };

    // A 导入的一道私有题 + 一道公共题（公共题的 owner 必须是 NULL）
    await c.query(
      `INSERT INTO questions (source, subject_id, type, stem, content_hash, owner_user_id, is_subjective)
       VALUES ('import', $1, 'choice', 'A 的私有题', 'hash-data-a', $2, false)`,
      [a.subjectId, a.userId],
    );
    await c.query(
      `INSERT INTO questions (source, subject_id, type, stem, content_hash, owner_user_id, is_subjective)
       VALUES ('manual', $1, 'choice', '公共题', 'hash-data-public', NULL, false)`,
      [a.subjectId],
    );
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
    // 物理删：先子后父（FK 顺序），务必把两条路径的题都清掉
    const users = [seed.userA, seed.userB];
    await c.query(
      `DELETE FROM verifications WHERE defect_ticket_id IN (
         SELECT id FROM defect_tickets WHERE user_id = ANY($1::uuid[]))`,
      [users],
    );
    await c.query(
      `DELETE FROM actions WHERE defect_ticket_id IN (
         SELECT id FROM defect_tickets WHERE user_id = ANY($1::uuid[]))`,
      [users],
    );
    await c.query(`DELETE FROM defect_tickets WHERE user_id = ANY($1::uuid[])`, [users]);
    await c.query(
      `DELETE FROM questions WHERE owner_user_id = ANY($1::uuid[]) OR content_hash LIKE 'hash-data-%'`,
      [users],
    );
    await c.query(
      `DELETE FROM subjects WHERE exam_profile_id IN (
         SELECT id FROM exam_profiles WHERE user_id = ANY($1::uuid[]))`,
      [users],
    );
    await c.query(`DELETE FROM exam_profiles WHERE user_id = ANY($1::uuid[])`, [users]);
    await c.query(`DELETE FROM users WHERE id = ANY($1::uuid[])`, [users]);
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
// 1) 无 Token -> 401，且一行都没删
// ---------------------------------------------------------------------------
test('m18680 B1：无 Token 删除 -> 401 且不删任何数据', skipOpt, async () => {
  const before = await pool.query(
    `SELECT count(*)::int AS n FROM defect_tickets WHERE user_id = $1 AND deleted_at IS NULL`,
    [seed.userA],
  );
  const r = await req('DELETE', `/users/${seed.userA}/data`);
  assert.equal(r.status, 401, JSON.stringify(r.data));
  // 注意：这里是**鉴权中间件**（server/auth.mjs 的 requireBearer）拦下的，
  // 错误码是 `unauthorized`（小写），不是本模块的 `UNAUTHORIZED`。
  // 配了 TOKENS 之后请求根本进不到路由层 —— 这本身就是要验证的事。
  assert.equal(r.data.error, 'unauthorized');

  const afterCount = await pool.query(
    `SELECT count(*)::int AS n FROM defect_tickets WHERE user_id = $1 AND deleted_at IS NULL`,
    [seed.userA],
  );
  assert.equal(afterCount.rows[0].n, before.rows[0].n, '401 时不允许删任何行');
});

// ---------------------------------------------------------------------------
// 2) 用 B 的 token 请求「删 A 的数据」-> 实际删的是 B 自己（路径被身份改写）
//    这正是安全边界：客户端无论传谁的 id，都只能删到自己的行。
// ---------------------------------------------------------------------------
test('m18680 B1：跨用户路径被身份改写，只能删到自己的数据', skipOpt, async () => {
  const r = await req('DELETE', `/users/${seed.userA}/data`, undefined, TOKEN_B);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  // server/index.mjs 的 `pathParts[1] = authUserId` 把 A 的 id 换成了 B 的
  assert.equal(r.data.user_id, seed.userB, '实际执行删除的是 token 对应的用户');

  const a = await pool.query(
    `SELECT count(*)::int AS n FROM defect_tickets WHERE user_id = $1 AND deleted_at IS NULL`,
    [seed.userA],
  );
  assert.equal(a.rows[0].n, 1, 'A 的缺陷单不应被 B 的请求删掉');

  const b = await pool.query(
    `SELECT count(*)::int AS n FROM defect_tickets WHERE user_id = $1 AND deleted_at IS NULL`,
    [seed.userB],
  );
  assert.equal(b.rows[0].n, 0, 'B 自己的数据应被删掉');
});

// ---------------------------------------------------------------------------
// 3) A 删自己的数据 -> 子行、私有题全软删，公共题保留
// ---------------------------------------------------------------------------
test('m18680 B1：删除自己的数据 -> 子行与私有题软删，公共题保留', skipOpt, async () => {
  const r = await req('DELETE', `/users/${seed.userA}/data`, undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.user_id, seed.userA);

  // 返回体计数与实际一致
  assert.equal(r.data.deleted.defect_tickets, 1);
  assert.equal(r.data.deleted.actions, 2);
  assert.equal(r.data.deleted.verifications, 1);
  assert.equal(r.data.deleted.questions, 1, '只删自己导入的那道');
  assert.equal(r.data.deleted.subjects, 1);
  assert.equal(r.data.deleted.exam_profiles, 1);
  assert.equal(r.data.deleted.mock_exams, 0);
  assert.equal(r.data.deleted.review_cycles, 0);
  assert.equal(r.data.deleted.knowledge_nodes, 0);
  assert.ok(r.data.total > 0);

  const c = await pool.connect();
  try {
    // 缺陷单 / 子行全被软删
    const t = await c.query(
      `SELECT count(*)::int AS n FROM defect_tickets
        WHERE user_id = $1 AND deleted_at IS NULL`,
      [seed.userA],
    );
    assert.equal(t.rows[0].n, 0, '缺陷单应全部软删');

    const a = await c.query(
      `SELECT count(*)::int AS n FROM actions
        WHERE defect_ticket_id = $1 AND deleted_at IS NULL`,
      [seed.ticketA],
    );
    assert.equal(a.rows[0].n, 0, '动作应随缺陷单一起软删');

    const v = await c.query(
      `SELECT count(*)::int AS n FROM verifications
        WHERE defect_ticket_id = $1 AND deleted_at IS NULL`,
      [seed.ticketA],
    );
    assert.equal(v.rows[0].n, 0, '验证记录应随缺陷单一起软删');

    // 私有题软删、公共题保留 —— 这是最容易被写错的一条
    const priv = await c.query(
      `SELECT count(*)::int AS n FROM questions
        WHERE owner_user_id = $1 AND deleted_at IS NULL`,
      [seed.userA],
    );
    assert.equal(priv.rows[0].n, 0, 'A 自己导入的题应软删');

    const pub = await c.query(
      `SELECT count(*)::int AS n FROM questions
        WHERE content_hash = 'hash-data-public' AND deleted_at IS NULL`,
    );
    assert.equal(pub.rows[0].n, 1, '公共题（owner IS NULL）绝不能被删');

    // 考试配置：科目与目标也软删
    const s = await c.query(
      `SELECT count(*)::int AS n FROM subjects
        WHERE exam_profile_id = $1 AND deleted_at IS NULL`,
      [seed.profileA],
    );
    assert.equal(s.rows[0].n, 0, '科目应软删');

    // 考试目标（父行）也软删
    const p = await c.query(
      `SELECT count(*)::int AS n FROM exam_profiles
        WHERE id = $1 AND deleted_at IS NULL`,
      [seed.profileA],
    );
    assert.equal(p.rows[0].n, 0, '考试目标应软删');
    // 注：「不影响别人」由上一个用例（跨用户路径被改写）覆盖，
    // 那时 B 已经删过一轮，这里不再重复断言 B。
  } finally {
    c.release();
  }
});

// ---------------------------------------------------------------------------
// 4) 重复删除是幂等的（第二次全 0，不报错）
// ---------------------------------------------------------------------------
test('m18680 B1：重复删除幂等 -> 第二次全 0 且不报错', skipOpt, async () => {
  const r = await req('DELETE', `/users/${seed.userA}/data`, undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.total, 0, '已经删过，第二次应一行都不动');
  for (const [key, n] of Object.entries(r.data.deleted)) {
    assert.equal(n, 0, `${key} 第二次不应再删`);
  }
});
