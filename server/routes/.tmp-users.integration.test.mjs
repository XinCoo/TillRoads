// server/routes/users.integration.test.mjs
// 题路 TillRoad · m27163：GET /me（当前用户信息）的真实 PG 集成测试
//
// 覆盖：
//   1) 带有效 token → 200，返回 id / nickname / display_name / masked_id
//   2) 无 token → 401
//   3) masked_id 与前端 maskUuid 同口径（前 4 位 + ****）
//   4) display_name：有昵称用昵称；无昵称用「用户_<末 4 位>」
//   5) 响应体**不含**任何凭据（token / 密码字段）
//   6) 软删的用户 → 404
//
// 只有 RUN_PG_INTEGRATION=1 才跑，CI 会设。

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';

import { createPool } from '../../.tmp-pglite-pool.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { createApp } from '../index.mjs';
import { FULL_SCHEMA_SQL } from '../db/test_schema.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN
  ? {}
  : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

const TOKEN_A = 'tk_me_a';
const TOKEN_ANON = 'tk_me_anon';
const TOKEN_GHOST = 'tk_me_ghost';

let pool;
let app;
let base;
let seed; // { userId, nickname, profileId }
let anonId; // 无昵称用户
let ghostId; // 已软删用户

/**
 * 起一个临时 app（带指定 TOKENS）。
 *
 * ★ 为什么需要临时 app：createApp() 在**创建时**就把 parseTokens() 的结果
 *   读进闭包（server/index.mjs 的 `const tokens = parseTokens()`），
 *   之后再改 process.env.TOKENS 不会生效。所以要换一组 token，
 *   必须另起一个 app 实例。
 */
async function startApp(tokensValue) {
  const prev = process.env.TOKENS;
  process.env.TOKENS = tokensValue;
  const tmp = createApp({ pool });
  await new Promise((resolve) => tmp.server.listen(0, '127.0.0.1', resolve));
  const tmpBase = `http://127.0.0.1:${tmp.server.address().port}`;
  return {
    tmp,
    tmpBase,
    restore: () => {
      process.env.TOKENS = prev;
    },
  };
}

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
  return { userId, nickname, profileId: p.rows[0].id };
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
    seed = await makeUser(c, '阿测');
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

test('GET /me 带有效 token → 200，返回 id / nickname / display_name / masked_id', skipOpt, async () => {
  const r = await req('GET', '/me', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.id, seed.userId);
  assert.equal(r.data.nickname, '阿测');
  assert.equal(r.data.display_name, '阿测');
  assert.equal(typeof r.data.masked_id, 'string');
});

test('GET /me 无 token → 401', skipOpt, async () => {
  const r = await req('GET', '/me');
  assert.equal(r.status, 401, JSON.stringify(r.data));
  assert.equal(r.data.error, 'unauthorized');
});

test('GET /me masked_id 与前端 maskUuid 同口径（前 4 位 + ****）', skipOpt, async () => {
  const r = await req('GET', '/me', undefined, TOKEN_A);
  assert.equal(r.status, 200);
  const compact = seed.userId.replace(/-/g, '');
  assert.equal(r.data.masked_id, `${compact.slice(0, 4)}****`);
});

test('GET /me 无昵称时 display_name 为「用户_<末 4 位>」', skipOpt, async () => {
  const c = await pool.connect();
  try {
    const u = await c.query(
      `INSERT INTO users (nickname, timezone, role) VALUES (NULL, 'Asia/Shanghai', 'student') RETURNING id`,
    );
    anonId = u.rows[0].id;
    await c.query(
      `INSERT INTO exam_profiles (user_id, exam_type, target_label, exam_date, daily_minutes)
       VALUES ($1, 'postgrad', '匿名目标', '2027-12-20', 60)`,
      [anonId],
    );
  } finally {
    c.release();
  }

  const extra = await startApp(`${TOKEN_A}:${seed.userId},${TOKEN_ANON}:${anonId}`);
  try {
    const res = await fetch(`${extra.tmpBase}/me`, {
      headers: { Authorization: `Bearer ${TOKEN_ANON}` },
    });
    const data = await res.json();
    assert.equal(res.status, 200, JSON.stringify(data));
    assert.equal(data.nickname, null);
    assert.equal(data.display_name, `用户_${anonId.replace(/-/g, '').slice(-4)}`);
  } finally {
    await new Promise((resolve) => extra.tmp.close(resolve));
    extra.restore();
    const c2 = await pool.connect();
    try {
      await c2.query(`DELETE FROM exam_profiles WHERE user_id=$1`, [anonId]);
      await c2.query(`DELETE FROM users WHERE id=$1`, [anonId]);
    } finally {
      c2.release();
    }
  }
});

test('GET /me 响应体不含任何凭据字段', skipOpt, async () => {
  const r = await req('GET', '/me', undefined, TOKEN_A);
  assert.equal(r.status, 200);
  const keys = Object.keys(r.data);
  for (const key of keys) {
    assert.ok(
      !/token|secret|password|hash|credential/i.test(key),
      `响应体不该出现凭据类字段：${key}`,
    );
  }
});

test('GET /me 用户被软删 → 404', skipOpt, async () => {
  const c = await pool.connect();
  try {
    const u = await c.query(
      `INSERT INTO users (nickname, timezone, role, deleted_at) VALUES ('已删用户', 'Asia/Shanghai', 'student', now()) RETURNING id`,
    );
    ghostId = u.rows[0].id;
  } finally {
    c.release();
  }

  const extra = await startApp(`${TOKEN_A}:${seed.userId},${TOKEN_GHOST}:${ghostId}`);
  try {
    const res = await fetch(`${extra.tmpBase}/me`, {
      headers: { Authorization: `Bearer ${TOKEN_GHOST}` },
    });
    const data = await res.json();
    assert.equal(res.status, 404, JSON.stringify(data));
    assert.equal(data.error, 'not_found');
  } finally {
    await new Promise((resolve) => extra.tmp.close(resolve));
    extra.restore();
    const c2 = await pool.connect();
    try {
      await c2.query(`DELETE FROM users WHERE id=$1`, [ghostId]);
    } finally {
      c2.release();
    }
  }
});
