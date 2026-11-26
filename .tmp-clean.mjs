import { readFileSync } from 'node:fs';
import { Pool } from '@neondatabase/serverless';
const env = {};
for (const line of readFileSync('.env','utf8').split(/\r?\n/)) {
  const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)$/.exec(line);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g,'');
}
const pool = new Pool({host: env.PGHOST, port: env.PGPORT, user: env.PGUSER, password: env.PGPASSWORD, database: env.PGDATABASE, ssl:{rejectUnauthorized:false}, ws:true, max:1, idleTimeoutMillis:0});
pool.on('error',()=>{});
const r = await pool.query(`DELETE FROM exam_profiles WHERE target_label='MyCustomExam' RETURNING id`);
console.log('DELETED', JSON.stringify(r.rows));
await pool.end();
