// 执行 schema.sql 建库（本机无 psql 的替代方案）。
//
// 为什么需要这个脚本：
//   migrations/0001_init_up.sql 只有一行 `\ir ../schema.sql`，那是 psql 的元命令，
//   node-postgres 无法执行。而 schema.sql 本身是纯 SQL（零 psql 元命令），
//   且 server/ 的集成测试早就在用 client.query(SCHEMA_SQL) 一次性跑完整文件，
//   所以这里复用同一手法，无需安装 psql。
//
// 用法：
//   node scripts/migrate.mjs          # 建表（幂等，可重复执行）
//   node scripts/migrate.mjs --down   # 删表
//
// 环境变量从 .env 读取（PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE/PGSSLMODE），
// pg 8.x 原生支持 PGSSLMODE，故 server/db/pool.mjs 无需任何改动。

import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');

// Node >= 20.12 提供 process.loadEnvFile()；.env 不存在时静默跳过（CI 用 job env）。
try {
  process.loadEnvFile(join(ROOT, '.env'));
} catch {
  // .env 可选；缺失时依赖已导出的环境变量
}

const { createPool } = await import('../server/db/pool.mjs');

const down = process.argv.includes('--down');
const file = down ? 'migrations/0001_init_down.sql' : 'schema.sql';
const label = down ? 'DROP（清理）' : 'CREATE（建表）';

console.log(`[migrate] ${label} ← ${file}`);

let sql;
if (down) {
  // down 脚本是普通 SQL（DROP TABLE/FUNCTION/TYPE），可直接执行
  sql = await readFile(join(ROOT, file), 'utf8');
} else {
  // up 走 schema.sql 单一事实来源（0001_init_up.sql 只是 \ir 包装）
  sql = await readFile(join(ROOT, 'schema.sql'), 'utf8');
}

if (/^\s*\\/m.test(sql)) {
  console.error('[migrate] 检测到 psql 元命令（行首 \\）——本脚本只能执行纯 SQL 文件');
  process.exit(1);
}

const pool = createPool();
const started = Date.now();
let client;
try {
  // 先探活：Neon 免费层空闲会挂起实例，冷启动可能超过 pool 的 connectionTimeoutMillis
  await pool.query('SELECT 1 AS ok');
  console.log('[migrate] 连接成功，开始执行 DDL…');

  client = await pool.connect();
  await client.query(sql);
  console.log(`[migrate] 执行完成，用时 ${Date.now() - started} ms`);
} catch (err) {
  console.error(`[migrate] 失败：${err.code || ''} ${err.message}`);
  if (err.detail) console.error(`[migrate] detail: ${err.detail}`);
  if (err.hint) console.error(`[migrate] hint: ${err.hint}`);
  if (err.position) console.error(`[migrate] position: ${err.position}`);
  process.exitCode = 1;
} finally {
  if (client) client.release();
  await pool.end();
}
