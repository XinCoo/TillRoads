// server/db/pg-smoke.integration.test.mjs
// BE-01 第 2 步 · 唯一一条 PG smoke 集成测试（连真实 PG，CI 提供）
//
// 本机无 PostgreSQL / Docker：默认**跳过**，绝不假装跑过。
// 只有显式 RUN_PG_INTEGRATION=1 时才连库（CI 的 node-tests job 会设该变量）。
//
// 验证三件事：
//   ① pool 工厂能连上 PG 并执行 SELECT 1；
//   ② 全局 pg.types.setTypeParser 在真实结果上生效：
//      SELECT 1.5::numeric 返回 JS number 而不是字符串（未配置时 pg 返回 '1.5'）；
//   ③ withTransaction 正常提交 + 异常回滚（用临时表观测，不碰业务表）。
//
// 四表 CRUD 集成测试留 BE-01 第 3 步，本文件刻意不写。

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPool, TYPE_OIDS } from './pool.mjs';
import { withTransaction, queryOne } from '../repositories/base.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN ? {} : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

let pool;

test('PG smoke：SELECT 1 + 全局类型解析生效', skipOpt, async (t) => {
  pool = createPool();
  t.after(async () => { await pool.end(); });

  // ① 连通性
  const one = await queryOne(pool, 'SELECT 1 AS v');
  assert.equal(one.v, 1, 'SELECT 1 应返回数字 1（int4 OID 23 已被解析成 number）');

  // ② numeric(1700) 全局解析：未配置解析器时 pg 返回字符串 '1.5'
  const num = await queryOne(pool,
    'SELECT 1.5::numeric AS n, 7::int8 AS b, 3::int4 AS i, 2::int2 AS s');
  assert.equal(typeof num.n, 'number', `numeric 应被解析成 number，实际 ${typeof num.n}`);
  assert.equal(num.n, 1.5);
  assert.equal(typeof num.b, 'number');
  assert.equal(num.b, 7);
  assert.equal(typeof num.i, 'number');
  assert.equal(num.i, 3);
  assert.equal(typeof num.s, 'number');
  assert.equal(num.s, 2);

  // ③ date(1082) 原样字符串 / timestamptz(1184) → ISO 8601 UTC 串
  const dates = await queryOne(pool,
    "SELECT '2027-12-20'::date AS d, '2026-11-15 10:00:00+08'::timestamptz AS ts");
  assert.equal(dates.d, '2027-12-20', 'date 应保持 YYYY-MM-DD 字符串');
  assert.equal(dates.ts, '2026-11-15T02:00:00.000Z', 'timestamptz 应转成 ISO 8601 UTC');

  // ④ jsonb 保持 driver 默认解析为对象（未被覆盖）
  const j = await queryOne(pool, "SELECT '{\"a\":1}'::jsonb AS j");
  assert.deepEqual(j.j, { a: 1 });
});

test('PG smoke：TYPE_OIDS 常量与真实 ::regtype 一致', skipOpt, async (t) => {
  pool = createPool();
  t.after(async () => { await pool.end(); });
  // 用 PG 自己的系统表核对我们硬编码的 OID，防止版本漂移
  const rows = await queryOne(pool,
    "SELECT 'numeric'::regtype::oid::int AS n, 'int8'::regtype::oid::int AS b," +
    " 'int4'::regtype::oid::int AS i, 'int2'::regtype::oid::int AS s," +
    " 'date'::regtype::oid::int AS d, 'timestamp'::regtype::oid::int AS ts," +
    " 'timestamptz'::regtype::oid::int AS tstz");
  assert.equal(rows.n, TYPE_OIDS.NUMERIC);
  assert.equal(rows.b, TYPE_OIDS.INT8);
  assert.equal(rows.i, TYPE_OIDS.INT4);
  assert.equal(rows.s, TYPE_OIDS.INT2);
  assert.equal(rows.d, TYPE_OIDS.DATE);
  assert.equal(rows.ts, TYPE_OIDS.TIMESTAMP);
  assert.equal(rows.tstz, TYPE_OIDS.TIMESTAMPTZ);
});

// TEMP TABLE 是「按连接(session)」可见的，而 pg.Pool 每次 checkout 可能给不同连接。
// 为让「事务提交/回滚后的观测查询」与事务本身落在同一 session，这里显式 checkout
// 单个 client，并包装成 withTransaction 需要的 pool 形状（connect 恒返回同一 client，
// release 设为 no-op，真实释放交给 t.after）。这样测试不依赖池的 LIFO 复用运气。
function singleClientPool(client) {
  return {
    async connect() {
      return {
        query: (sql, params) => client.query(sql, params),
        release() {},   // 由外层 t.after 统一释放
      };
    },
  };
}

test('PG smoke：withTransaction 正常提交（写入在 COMMIT 后可见）', skipOpt, async (t) => {
  pool = createPool();
  const client = await pool.connect();
  t.after(async () => { client.release(); await pool.end(); });

  await client.query('CREATE TEMP TABLE be01_smoke_commit (id int)');
  await withTransaction(singleClientPool(client), async (c) => {
    await c.query('INSERT INTO be01_smoke_commit(id) VALUES($1)', [7]);
  });
  const row = await queryOne(client, 'SELECT id FROM be01_smoke_commit');
  assert.equal(row.id, 7, 'COMMIT 后写入应在同一 session 可见');
});

test('PG smoke：withTransaction 异常回滚（写入不留痕）', skipOpt, async (t) => {
  pool = createPool();
  const client = await pool.connect();
  t.after(async () => { client.release(); await pool.end(); });

  await client.query('CREATE TEMP TABLE be01_smoke_rollback (id int)');
  await assert.rejects(
    withTransaction(singleClientPool(client), async (c) => {
      await c.query('INSERT INTO be01_smoke_rollback(id) VALUES($1)', [99]);
      throw new Error('force rollback');
    }),
    /force rollback/
  );
  const row = await queryOne(client, 'SELECT count(*)::int AS c FROM be01_smoke_rollback');
  assert.equal(row.c, 0, 'ROLLBACK 后写入不应可见');
});
