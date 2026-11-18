// 探活 + 结构自检：确认 schema.sql 真的落库（而不是只看脚本 exit 0）。
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
try {
  process.loadEnvFile(join(ROOT, '.env'));
} catch {
  /* .env 可选 */
}

const { createPool } = await import('../server/db/pool.mjs');
const pool = createPool();

try {
  const { rows: tables } = await pool.query(
    `SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      ORDER BY table_name`,
  );
  console.log(`[verify] BASE TABLE 共 ${tables.length} 张：`);
  console.log('  ' + tables.map((r) => r.table_name).join(', '));

  const { rows: types } = await pool.query(
    `SELECT typname FROM pg_type t
       JOIN pg_namespace n ON n.oid = t.typnamespace
      WHERE n.nspname = 'public' AND t.typtype = 'e'
      ORDER BY typname`,
  );
  console.log(`[verify] ENUM 共 ${types.length} 个：`);
  console.log('  ' + types.map((r) => r.typname).join(', '));

  const { rows: triggers } = await pool.query(
    `SELECT tgname FROM pg_trigger WHERE NOT tgisinternal ORDER BY tgname`,
  );
  console.log(`[verify] 触发器共 ${triggers.length} 个：`);
  console.log('  ' + triggers.map((r) => r.tgname).join(', '));

  // 关键列存在性（P0-2 round 维度）
  const { rows: cols } = await pool.query(
    `SELECT table_name, column_name FROM information_schema.columns
      WHERE table_schema='public'
        AND ((table_name='defect_tickets' AND column_name IN ('verification_round','error_layer','error_cause','reopen_count'))
          OR (table_name='verifications' AND column_name IN ('round','stage','result')))
      ORDER BY table_name, column_name`,
  );
  console.log('[verify] 关键列：');
  for (const r of cols) console.log(`  ${r.table_name}.${r.column_name}`);

  // 唯一索引含 round（P0-2 修复点）
  const { rows: idx } = await pool.query(
    `SELECT indexdef FROM pg_indexes WHERE indexname = 'idx_ver_dt_stage'`,
  );
  console.log('[verify] idx_ver_dt_stage =', idx[0]?.indexdef ?? 'MISSING');

  // 函数存在性
  const { rows: fns } = await pool.query(
    `SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname='public' ORDER BY proname`,
  );
  console.log(`[verify] 函数 ${fns.length} 个：` + fns.map((r) => r.proname).join(', '));
} catch (err) {
  console.error(`[verify] 失败：${err.code || ''} ${err.message}`);
  process.exitCode = 1;
} finally {
  await pool.end();
}
