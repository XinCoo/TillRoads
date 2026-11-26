// 临时脚本：本地起后端连 Neon（WebSocket 通道），供模拟器真机验收 m27163 的 A/B/C 改动。
// 本机 pg 直连 Neon pooler 会 ECONNRESET，必须走 Neon serverless 的 WebSocket 通道。
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Pool } from '@neondatabase/serverless';

import { createApp } from './server/index.mjs';
const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = HERE; // 脚本就在仓库根，'..' 会指到 D:\DSH

process.loadEnvFile(join(ROOT, '.env'));

const ws = new Pool({
  host: process.env.PGHOST,
  port: process.env.PGPORT || '5432',
  user: process.env.PGUSER,
  password: process.env.PGPASSWORD,
  database: process.env.PGDATABASE,
  ssl: { rejectUnauthorized: false },
  ws: true,
  max: 5,
  idleTimeoutMillis: 0,
});
ws.on('error', () => {});

// 适配成 pg.Pool 的形状：server/db/pool.mjs 的 createPool 返回的对象。
const adapter = {
  query: (text, params) => ws.query(text, params),
  connect: () => ws.connect(),
  end: () => ws.end(),
};

const app = createApp({ pool: adapter });

const count = await ws.query(`SELECT count(*)::int AS n FROM users`);
console.log('[dev-ws] DB_OK users=', count.rows[0].n);

app.server.listen(3000, '0.0.0.0', () => {
  console.log('[dev-ws] LISTENING http://0.0.0.0:3000');
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    app.server.close();
    ws.end();
    process.exit(0);
  });
}
