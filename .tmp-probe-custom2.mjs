import { readFileSync } from 'node:fs';
import { Pool } from '@neondatabase/serverless';
import * as prof from './server/routes/exam_profiles.mjs';
import { withTransaction } from './server/repositories/base.mjs';
const env = {};
for (const line of readFileSync('.env','utf8').split(/\r?\n/)) {
  const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)$/.exec(line);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g,'');
}
const ws = new Pool({host: env.PGHOST, port: env.PGPORT, user: env.PGUSER, password: env.PGPASSWORD, database: env.PGDATABASE, ssl:{rejectUnauthorized:false}, ws:true, max:2, idleTimeoutMillis:0});
ws.on('error',()=>{});
const adapter = { query: async (t,p)=>{ try { return await ws.query(t,p); } catch(e){ console.log('SQL_ERR', e.code, e.message); console.log('SQL_TEXT', t); console.log('SQL_PARAMS', JSON.stringify(p)); throw e; } }, connect: ()=>ws.connect(), end: ()=>ws.end() };
const body = { exam_type:'custom', exam_type_custom:'CustomTypeName', target_label:'MyCustomExam', exam_date:'2027-02-24', daily_minutes:120, user_id:'11111111-1111-4111-8111-111111111111' };
const out = await prof.match('POST', ['exam-profiles'], { pool: adapter, body, authUserId: body.user_id, searchParams: new URLSearchParams() });
console.log('RESULT', JSON.stringify(out));
await ws.end();
