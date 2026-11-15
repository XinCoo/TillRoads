// server/repositories/base.test.mjs
// BE-01 第 2 步 · base.mjs 工具函数逻辑层单测（fake pool / fake client，零 PG）
// 本机无 PostgreSQL；这些用例不连库，只验证 SQL 结构 / 参数顺序 / 错误映射 / 事务边界。

import test from 'node:test';
import assert from 'node:assert/strict';
import * as B from './base.mjs';

// ---------------------------------------------------------------------------
// fake client：记录每条 query 的 (sql, params)，按 sql 前缀返回可配置结果。
// ---------------------------------------------------------------------------
function fakeClient(handler) {
  const calls = [];
  return {
    calls,
    released: 0,
    async query(sql, params = []) {
      calls.push({ sql, params });
      if (handler) return handler(sql, params, calls.length) || { rows: [] };
      return { rows: [] };
    },
    release() { this.released += 1; },
  };
}

function fakePool(client) {
  return {
    connects: 0,
    async connect() { this.connects += 1; return client; },
  };
}

// ---------------------------------------------------------------------------
// queryOne / queryMany
// ---------------------------------------------------------------------------
test('queryOne：SQL 与参数顺序原样下传；多行取首行；无行返回 null', async () => {
  const c = fakeClient(() => ({ rows: [{ id: 'a', n: 1 }, { id: 'b', n: 2 }] }));
  const row = await B.queryOne(c, 'SELECT * FROM exam_profiles WHERE id=$1 AND version=$2', ['a', 3]);
  assert.deepEqual(row, { id: 'a', n: 1 });
  assert.equal(c.calls.length, 1);
  assert.equal(c.calls[0].sql, 'SELECT * FROM exam_profiles WHERE id=$1 AND version=$2');
  assert.deepEqual(c.calls[0].params, ['a', 3]);

  const empty = fakeClient(() => ({ rows: [] }));
  assert.equal(await B.queryOne(empty, 'SELECT 1'), null);
  const noRows = fakeClient(() => ({}));
  assert.equal(await B.queryOne(noRows, 'SELECT 1'), null);
});

test('queryMany：返回行数组；无行 / rows 缺失返回 []；参数原样下传', async () => {
  const c = fakeClient(() => ({ rows: [{ id: 1 }, { id: 2 }] }));
  const rows = await B.queryMany(c, 'SELECT * FROM subjects WHERE exam_profile_id=$1 ORDER BY created_at ASC, id ASC LIMIT $2 OFFSET $3', ['p', 20, 0]);
  assert.deepEqual(rows, [{ id: 1 }, { id: 2 }]);
  assert.deepEqual(c.calls[0].params, ['p', 20, 0]);
  assert.deepEqual(await B.queryMany(fakeClient(() => ({ rows: [] })), 'SELECT 1'), []);
  assert.deepEqual(await B.queryMany(fakeClient(() => ({})), 'SELECT 1'), []);
});

test('queryOne/queryMany：不传 params 时默认空数组（对接 pg 的 query(sql, [])）', async () => {
  const c = fakeClient(() => ({ rows: [] }));
  await B.queryOne(c, 'SELECT 1');
  await B.queryMany(c, 'SELECT 1');
  assert.deepEqual(c.calls[0].params, []);
  assert.deepEqual(c.calls[1].params, []);
});

// ---------------------------------------------------------------------------
// conflictError：与 server/index.mjs conflictBody 逐字段对照
// ---------------------------------------------------------------------------
test('conflictError：409 body 与 server/index.mjs 现有形状逐字段一致', () => {
  // server/index.mjs 的 conflictBody({current,incoming}) 返回：
  //   { error:'conflict', current, incoming, resolution:'client_merge' }
  const expected = { error: 'conflict', current: 5, incoming: 4, resolution: 'client_merge' };
  const e = B.conflictError(5, 4);
  assert.ok(e instanceof Error);
  assert.equal(e.statusCode, 409);
  assert.equal(e.status, 409);
  assert.equal(e.code, 'conflict');
  assert.deepEqual(e.body, expected);
  // resolution 可覆盖（仍然带齐四个字段）
  assert.deepEqual(B.conflictError(5, 4, 'server_wins').body,
    { error: 'conflict', current: 5, incoming: 4, resolution: 'server_wins' });
  // 传对象型 current（服务端当前行）也保持形状
  const cur = { id: 'x', version: 7 };
  assert.deepEqual(B.conflictError(cur, 4).body,
    { error: 'conflict', current: cur, incoming: 4, resolution: 'client_merge' });
});

// ---------------------------------------------------------------------------
// mapPgError：SQLSTATE 映射表
// ---------------------------------------------------------------------------
test('mapPgError：23503→404 / 22P02→400 / 23505→409，带 sqlState 与 cause', () => {
  const fk = Object.assign(new Error('fk'), { code: '23503' });
  const m1 = B.mapPgError(fk);
  assert.equal(m1.statusCode, 404);
  assert.equal(m1.code, 'foreign_key_not_found');
  assert.equal(m1.sqlState, '23503');
  assert.equal(m1.cause, fk);
  assert.equal(m1.body.error, 'foreign_key_not_found');

  assert.equal(B.mapPgError(Object.assign(new Error('x'), { code: '22P02' })).statusCode, 400);
  assert.equal(B.mapPgError(Object.assign(new Error('x'), { code: '22P02' })).code, 'invalid_input_syntax');

  const m3 = B.mapPgError(Object.assign(new Error('u'), { code: '23505' }));
  assert.equal(m3.statusCode, 409);
  assert.equal(m3.code, 'unique_violation');   // 第 3 步查重时 23505 兜底用
});

test('mapPgError：未命中 SQLSTATE / 非对象 → 原样返回同一引用', () => {
  const plain = Object.assign(new Error('boom'), { code: '08006' });
  assert.equal(B.mapPgError(plain), plain);          // 不擅自改写连接错误等
  assert.equal(B.mapPgError(null), null);
  assert.equal(B.mapPgError(undefined), undefined);
  const noCode = new Error('no code');
  assert.equal(B.mapPgError(noCode), noCode);
});

test('SQLSTATE_MAP 表结构：三条映射齐全且冻结', () => {
  assert.deepEqual(Object.keys(B.SQLSTATE_MAP).sort(), ['22P02', '23503', '23505']);
  assert.equal(Object.isFrozen(B.SQLSTATE_MAP), true);
  assert.equal(B.SQLSTATE_MAP['23503'].status, 404);
  assert.equal(B.SQLSTATE_MAP['22P02'].status, 400);
  assert.equal(B.SQLSTATE_MAP['23505'].status, 409);
});

// ---------------------------------------------------------------------------
// buildUpdateSet：白名单 / 参数化 / 系统列拒绝 / 空 patch
// ---------------------------------------------------------------------------
const ALLOWED = ['exam_type', 'target_label', 'target_score', 'exam_date', 'daily_minutes', 'status', 'subject_target'];

test('buildUpdateSet：值全部参数化，列名只来自白名单，占位符连续 $1..$N', () => {
  const patch = { exam_type: 'postgrad', target_score: 400, daily_minutes: 120 };
  const { setClauses, values } = B.buildUpdateSet(patch, ALLOWED);
  assert.deepEqual(setClauses, ['"exam_type" = $1', '"target_score" = $2', '"daily_minutes" = $3']);
  assert.deepEqual(values, ['postgrad', 400, 120]);
  // SQL 文本里不得出现任何外部值
  for (const c of setClauses) {
    assert.ok(!c.includes('postgrad') && !c.includes('400') && !c.includes('120'));
  }
});

test('buildUpdateSet：null 是合法值（置 NULL），undefined 视为未提供跳过', () => {
  const { setClauses, values } = B.buildUpdateSet(
    { target_label: null, exam_type: undefined, target_score: 0 }, ALLOWED);
  assert.deepEqual(setClauses, ['"target_label" = $1', '"target_score" = $2']);
  assert.deepEqual(values, [null, 0]);
});

test('buildUpdateSet：空 patch / 全 undefined → { setClauses:[], values:[] }（调用方应跳过 UPDATE）', () => {
  assert.deepEqual(B.buildUpdateSet({}, ALLOWED), { setClauses: [], values: [] });
  assert.deepEqual(B.buildUpdateSet(null, ALLOWED), { setClauses: [], values: [] });
  assert.deepEqual(B.buildUpdateSet(undefined, ALLOWED), { setClauses: [], values: [] });
  assert.deepEqual(B.buildUpdateSet({ exam_type: undefined }, ALLOWED), { setClauses: [], values: [] });
});

test('buildUpdateSet：尝试写 id / version / updated_at / created_at / deleted_at 一律拒绝', () => {
  for (const col of B.SYSTEM_COLUMNS) {
    assert.throws(() => B.buildUpdateSet({ [col]: 999 }, ALLOWED),
      /禁止写入系统列/);
  }
});

test('buildUpdateSet：白名单外的列 / 非法标识符 / 注入式列名全部拒绝', () => {
  assert.throws(() => B.buildUpdateSet({ evil: 1 }, ALLOWED), /不在白名单内/);
  assert.throws(() => B.buildUpdateSet({ 'a; DROP TABLE users': 1 }, ALLOWED), /非法列名/);
  assert.throws(() => B.buildUpdateSet({ 'exam_type"; DROP TABLE users--': 1 }, ALLOWED), /非法列名/);
  assert.throws(() => B.buildUpdateSet({ '1bad': 1 }, ALLOWED), /非法列名/);
});

test('buildUpdateSet：白名单本身若含系统列 / 非法标识符也拒绝（防调用方配错绕过）', () => {
  assert.throws(() => B.buildUpdateSet({ exam_type: 'x' }, [...ALLOWED, 'version']), /不得包含系统列/);
  assert.throws(() => B.buildUpdateSet({ exam_type: 'x' }, ['bad;DROP']), /非法列名/);
  // 支持 Set 形态白名单
  const r = B.buildUpdateSet({ status: 'archived' }, new Set(['status']));
  assert.deepEqual(r.setClauses, ['"status" = $1']);
});

test('SYSTEM_COLUMNS 与 schema.sql 同步列对齐且冻结', () => {
  assert.deepEqual([...B.SYSTEM_COLUMNS],
    ['id', 'created_at', 'updated_at', 'version', 'deleted_at']);
  assert.equal(Object.isFrozen(B.SYSTEM_COLUMNS), true);
});

// ---------------------------------------------------------------------------
// withTransaction：BEGIN/COMMIT/ROLLBACK 与 finally 释放
// ---------------------------------------------------------------------------
test('withTransaction：正常路径 BEGIN → fn → COMMIT，返回值透传，client 必释放', async () => {
  const c = fakeClient(() => ({ rows: [] }));
  const pool = fakePool(c);
  const seen = [];
  const result = await B.withTransaction(pool, async (client) => {
    assert.equal(client, c);            // 首参就是同一个 PoolClient
    seen.push(...client.calls.map(x => x.sql));
    await client.query('INSERT INTO subjects(name) VALUES($1) RETURNING *', ['数学']);
    return { id: 'p1' };
  });
  assert.deepEqual(result, { id: 'p1' });
  assert.deepEqual(c.calls.map(x => x.sql),
    ['BEGIN', 'INSERT INTO subjects(name) VALUES($1) RETURNING *', 'COMMIT']);
  assert.equal(c.calls[1].params[0], '数学');
  assert.equal(c.released, 1);
  assert.equal(pool.connects, 1);
  assert.ok(seen.includes('BEGIN'));   // fn 执行时 BEGIN 已发出
});

test('withTransaction：fn 抛错 → ROLLBACK + 原异常重新抛出 + 仍释放', async () => {
  const c = fakeClient(() => ({ rows: [] }));
  const boom = new Error('boom');
  await assert.rejects(
    B.withTransaction(fakePool(c), async () => { throw boom; }),
    (e) => e === boom);
  assert.deepEqual(c.calls.map(x => x.sql), ['BEGIN', 'ROLLBACK']);
  assert.equal(c.released, 1);
});

test('withTransaction：BEGIN 本身失败 → 不发 ROLLBACK，仍释放并抛原错', async () => {
  const beginErr = new Error('connect lost');
  const c = fakeClient((sql) => { if (sql === 'BEGIN') throw beginErr; return { rows: [] }; });
  await assert.rejects(B.withTransaction(fakePool(c), async () => 'x'), (e) => e === beginErr);
  assert.deepEqual(c.calls.map(x => x.sql), ['BEGIN']);
  assert.equal(c.released, 1);
});

test('withTransaction：COMMIT 失败也算异常 → 尝试 ROLLBACK + 抛 COMMIT 错 + 释放', async () => {
  const commitErr = new Error('commit failed');
  const c = fakeClient((sql) => { if (sql === 'COMMIT') throw commitErr; return { rows: [] }; });
  await assert.rejects(B.withTransaction(fakePool(c), async () => 42), (e) => e === commitErr);
  assert.deepEqual(c.calls.map(x => x.sql), ['BEGIN', 'COMMIT', 'ROLLBACK']);
  assert.equal(c.released, 1);
});

test('withTransaction：ROLLBACK 也失败时不掩盖原异常，挂到 rollbackError 上', async () => {
  const orig = new Error('orig');
  const rbErr = new Error('rollback failed');
  const c = fakeClient((sql) => {
    if (sql === 'ROLLBACK') throw rbErr;
    return { rows: [] };
  });
  await assert.rejects(
    B.withTransaction(fakePool(c), async () => { throw orig; }),
    (e) => e === orig && e.rollbackError === rbErr);
  assert.equal(c.released, 1);
});

test('withTransaction：参数校验（pool.connect 缺失 / fn 非函数）快速失败', async () => {
  await assert.rejects(B.withTransaction({}, async () => 1), /pool 必须提供 connect/);
  await assert.rejects(B.withTransaction(fakePool(fakeClient()), null), /fn 必须是函数/);
});
