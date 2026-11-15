// server/db/pool.test.mjs
// BE-01 第 2 步 · pool 工厂与全局类型解析单测（零 PG；不建立真实连接）
//
// 本机无 PostgreSQL：这些用例只验证
//   (a) 解析器纯函数行为；
//   (b) configureTypeParsers() 确实把 7 个 OID 注册进 pg.types 全局表；
//   (c) createPool() 的配置合并优先级与「不硬编码凭据」；
//   (d) 构造 Pool 是惰性的，本机无 PG 也能安全构造并 pool.end()。
// 真正连库的类型解析验证在 PG smoke 集成测试里（RUN_PG_INTEGRATION=1 才跑）。

import test from 'node:test';
import assert from 'node:assert/strict';
import { types } from 'pg';
import * as P from './pool.mjs';

// ---------------------------------------------------------------------------
// 解析器纯函数
// ---------------------------------------------------------------------------
test('parseNumeric：numeric/int8/int4/int2 文本 → number；null/undefined 原样', () => {
  assert.equal(P.parseNumeric('400.00'), 400);
  assert.equal(P.parseNumeric('9.999'), 9.999);
  assert.equal(P.parseNumeric('1'), 1);
  assert.equal(P.parseNumeric(5), 5);
  assert.equal(P.parseNumeric('abc'), NaN);       // 交给上层校验，不擅自吞掉
  assert.equal(P.parseNumeric(null), null);
  assert.equal(P.parseNumeric(undefined), undefined);
});

test('parseDate：date(1082) 原样返回 YYYY-MM-DD，不做 Date 本地化', () => {
  assert.equal(P.parseDate('2027-12-20'), '2027-12-20');
  assert.equal(P.parseDate('2024-02-29'), '2024-02-29');
  assert.equal(P.parseDate(null), null);
});

test('parseTimestamp：无时区列按 UTC 解释 → ISO 8601；带偏移时不重复加 Z', () => {
  assert.equal(P.parseTimestamp('2026-11-15 10:00:00'), '2026-11-15T10:00:00.000Z');
  assert.equal(P.parseTimestamp('2026-11-15 10:00:00.123'), '2026-11-15T10:00:00.123Z');
  assert.equal(P.parseTimestamp('2026-11-15T10:00:00+08:00'), '2026-11-15T02:00:00.000Z');
  assert.equal(P.parseTimestamp('garbage'), 'garbage');   // 无法解析则原样返回
  assert.equal(P.parseTimestamp(null), null);
});

test('parseTimestamptz：PG "+08" 偏移补成 "+08:00" → ISO 8601 UTC', () => {
  assert.equal(P.parseTimestamptz('2026-11-15 10:00:00+08'), '2026-11-15T02:00:00.000Z');
  assert.equal(P.parseTimestamptz('2026-11-15 10:00:00+08:00'), '2026-11-15T02:00:00.000Z');
  assert.equal(P.parseTimestamptz('2026-11-15 10:00:00Z'), '2026-11-15T10:00:00.000Z');
  assert.equal(P.parseTimestamptz('garbage'), 'garbage');
  assert.equal(P.parseTimestamptz(null), null);
});

// ---------------------------------------------------------------------------
// 全局注册（幂等）
// ---------------------------------------------------------------------------
test('configureTypeParsers：7 个 OID 全部注册生效，jsonb 未被覆盖；重复调用幂等', () => {
  P.configureTypeParsers();
  P.configureTypeParsers();   // 幂等：再调一次结果一致

  for (const oid of [P.TYPE_OIDS.NUMERIC, P.TYPE_OIDS.INT8, P.TYPE_OIDS.INT4, P.TYPE_OIDS.INT2]) {
    assert.equal(types.getTypeParser(oid, 'text')('400.00'), 400);
  }
  assert.equal(types.getTypeParser(P.TYPE_OIDS.DATE, 'text')('2027-12-20'), '2027-12-20');
  assert.equal(types.getTypeParser(P.TYPE_OIDS.TIMESTAMP, 'text')('2026-11-15 10:00:00'),
    '2026-11-15T10:00:00.000Z');
  assert.equal(types.getTypeParser(P.TYPE_OIDS.TIMESTAMPTZ, 'text')('2026-11-15 10:00:00+08'),
    '2026-11-15T02:00:00.000Z');

  // jsonb(3802) 必须保持 driver 默认（解析为对象），不被我们的解析器接管
  const jsonbParser = types.getTypeParser(3802, 'text');
  assert.deepEqual(jsonbParser('{"a":1}'), { a: 1 });
  assert.notEqual(jsonbParser, P.parseNumeric);

  // uuid(2950) 保持默认字符串
  assert.equal(types.getTypeParser(2950, 'text')('abc'), 'abc');
});

test('TYPE_OIDS / DEFAULT_POOL_CONFIG 与拍板值一致且冻结', () => {
  assert.deepEqual({ ...P.TYPE_OIDS },
    { NUMERIC: 1700, INT8: 20, INT4: 23, INT2: 21, DATE: 1082, TIMESTAMP: 1114, TIMESTAMPTZ: 1184 });
  assert.equal(Object.isFrozen(P.TYPE_OIDS), true);
  assert.deepEqual({ ...P.DEFAULT_POOL_CONFIG },
    { max: 10, idleTimeoutMillis: 30000, connectionTimeoutMillis: 5000 });
  assert.equal(Object.isFrozen(P.DEFAULT_POOL_CONFIG), true);
});

// ---------------------------------------------------------------------------
// createPool：配置合并优先级 + 不硬编码凭据
// ---------------------------------------------------------------------------
test('createPool：默认池参数生效，Pool 惰性构造（无 PG 也安全），显式 config 可覆盖', async () => {
  const pool = P.createPool();
  assert.equal(pool.options.max, 10);
  assert.equal(pool.options.idleTimeoutMillis, 30000);
  assert.equal(pool.options.connectionTimeoutMillis, 5000);
  await pool.end();                       // 惰性：无连接可直接关闭

  const custom = P.createPool({ max: 2, idleTimeoutMillis: 999, connectionTimeoutMillis: 111 });
  assert.equal(custom.options.max, 2);
  assert.equal(custom.options.idleTimeoutMillis, 999);
  assert.equal(custom.options.connectionTimeoutMillis, 111);
  await custom.end();
});

test('createPool：连接参数来自 PG* 环境变量，且显式 config 优先级最高', async () => {
  const saved = {};
  const keys = ['PGHOST', 'PGPORT', 'PGUSER', 'PGPASSWORD', 'PGDATABASE'];
  for (const k of keys) { saved[k] = process.env[k]; }
  try {
    process.env.PGHOST = 'env-host';
    process.env.PGPORT = '6543';
    process.env.PGUSER = 'env-user';
    process.env.PGPASSWORD = 'env-pw';
    process.env.PGDATABASE = 'env-db';

    const p1 = P.createPool();
    assert.equal(p1.options.host, 'env-host');
    assert.equal(p1.options.port, 6543);
    assert.equal(p1.options.user, 'env-user');
    assert.equal(p1.options.password, 'env-pw');
    assert.equal(p1.options.database, 'env-db');
    await p1.end();

    const p2 = P.createPool({ host: 'explicit-host', max: 3 });
    assert.equal(p2.options.host, 'explicit-host');   // 显式 > 环境变量
    assert.equal(p2.options.max, 3);
    assert.equal(p2.options.user, 'env-user');       // 未覆盖的仍来自环境变量
    await p2.end();
  } finally {
    for (const k of keys) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
});

test('createPool：源码不含任何硬编码凭据；未设环境变量时不写入连接参数', async () => {
  const saved = {};
  const keys = ['PGHOST', 'PGPORT', 'PGUSER', 'PGPASSWORD', 'PGDATABASE'];
  for (const k of keys) { saved[k] = process.env[k]; delete process.env[k]; }
  try {
    const pool = P.createPool();
    // 不硬编码：这些值应该是 undefined（交给 pg 自身默认）
    assert.equal(pool.options.user, undefined);
    assert.equal(pool.options.password, undefined);
    assert.equal(pool.options.host, undefined);
    await pool.end();
  } finally {
    for (const k of keys) if (saved[k] !== undefined) process.env[k] = saved[k];
  }
});
