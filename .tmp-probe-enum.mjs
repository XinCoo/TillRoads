import { readFileSync } from 'node:fs';
import { Pool } from '@neondatabase/serverless';
const env = {};
for (const line of readFileSync('.env','utf8').split(/\r?\n/)) {
  const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)$/.exec(line);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g,'');
}
const pool = new Pool({host: env.PGHOST, port: env.PGPORT, user: env.PGUSER, password: env.PGPASSWORD, database: env.PGDATABASE, ssl:{rejectUnauthorized:false}, ws:true, max:1, idleTimeoutMillis:0});
pool.on('error',()=>{});
const r1 = await pool.query(`SELECT unnest(enum_range(NULL::exam_type))::text AS v`);
console.log('EXAM_TYPE', r1.rows.map(x=>x.v).join(','));
const r2 = await pool.query(`SELECT column_name FROM information_schema.columns WHERE table_name='exam_profiles' ORDER BY column_name`);
console.log('COLS', r2.rows.map(x=>x.column_name).join(','));
const r3 = await pool.query(`SELECT column_name FROM information_schema.columns WHERE table_name='defect_tickets' AND column_name LIKE '%custom%'`);
console.log('DEFECT_CUSTOM', JSON.stringify(r3.rows));
try {
  const r4 = await pool.query(`INSERT INTO exam_profiles (user_id, exam_type, exam_type_custom, target_label, exam_date, daily_minutes) VALUES ('11111111-1111-4111-8111-111111111111','custom','ProbeType','探针','2027-03-01',60) RETURNING id`);
  console.log('INSERT_OK', JSON.stringify(r4.rows));
  await pool.query(`DELETE FROM exam_profiles WHERE id=$1`, [r4.rows[0].id]);
  console.log('CLEANED');
} catch (e) {
  console.log('INSERT_FAIL', e.code, e.message);
}
await pool.end();
