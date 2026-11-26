// 临时脚本：把 migrations（含 0006）跑到 Neon。
// 本机 pg 直连 Neon pooler 会 ECONNRESET，必须走 Neon serverless 的 WebSocket 通道。
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Pool } from '@neondatabase/serverless';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = HERE;

process.loadEnvFile(join(ROOT, '.env'));

const ws = new Pool({
  host: process.env.PGHOST,
  port: process.env.PGPORT || '5432',
  user: process.env.PGUSER,
  password: process.env.PGPASSWORD,
  database: process.env.PGDATABASE,
  ssl: { rejectUnauthorized: false },
  ws: true,
  max: 1,
  idleTimeoutMillis: 0,
});
ws.on('error', () => {});

const files = [
  'schema.sql',
  'migrations/0002_questions_owner.sql',
  'migrations/0003_practice.sql',
  'migrations/0004_question_mastery.sql',
  'migrations/0005_question_hidden.sql',
  'migrations/0006_exam_custom_defect_questions.sql',
];

const started = Date.now();
try {
  await ws.query('SELECT 1 AS ok');
  console.log('[migrate-ws] 连接成功');
  for (const f of files) {
    const text = await readFile(join(ROOT, f), 'utf8');
    await ws.query(text);
    console.log(`[migrate-ws] OK ${f}`);
  }
  const t = await ws.query(
    `SELECT table_name FROM information_schema.tables WHERE table_name IN ('defect_questions','question_hidden','question_mastery','practice_sessions') ORDER BY table_name`,
  );
  console.log('[migrate-ws] TABLES', t.rows.map((r) => r.table_name).join(','));
  const et = await ws.query(`SELECT unnest(enum_range(NULL::exam_type)) AS t`);
  console.log('[migrate-ws] EXAM_TYPE', et.rows.map((r) => r.t).join(','));
  const col = await ws.query(
    `SELECT column_name FROM information_schema.columns WHERE table_name='defect_tickets' AND column_name IN ('custom_reason')`,
  );
  console.log('[migrate-ws] DEFECT_COLS', col.rows.map((r) => r.column_name).join(','));
  console.log(`[migrate-ws] DONE ms ${Date.now() - started}`);
} catch (err) {
  console.error('[migrate-ws] FAIL', err.message);
  process.exitCode = 1;
} finally {
  await ws.end();
}
