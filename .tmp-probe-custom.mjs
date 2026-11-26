import { readFileSync } from 'node:fs';
import { Pool } from '@neondatabase/serverless';
import { createApp } from './server/index.mjs';
const env = {};
for (const line of readFileSync('.env','utf8').split(/\r?\n/)) {
  const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)$/.exec(line);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g,'');
}
const ws = new Pool({host: env.PGHOST, port: env.PGPORT, user: env.PGUSER, password: env.PGPASSWORD, database: env.PGDATABASE, ssl:{rejectUnauthorized:false}, ws:true, max:2, idleTimeoutMillis:0});
ws.on('error',()=>{});
const adapter = { query: (t,p)=>ws.query(t,p), connect: ()=>ws.connect(), end: ()=>ws.end() };
process.env.TOKENS = 'tltest001:11111111-1111-4111-8111-111111111111';
const app = createApp({ pool: adapter });
await new Promise(r=>app.server.listen(0,'127.0.0.1',r));
const base = `http://127.0.0.1:${app.server.address().port}`;
const res = await fetch(base+'/exam-profiles', { method:'POST', headers:{'Content-Type':'application/json','Authorization':'Bearer tltest001'}, body: JSON.stringify({ exam_type:'custom', exam_type_custom:'CustomTypeName', target_label:'MyCustomExam', exam_date:'2027-02-24', daily_minutes:120 }) });
console.log('STATUS', res.status, await res.text());
await new Promise(r=>app.close(r));
await ws.end();
