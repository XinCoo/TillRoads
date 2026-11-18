// 本地开发启动器（FE-03 联调用）。
//
// 为什么不直接 `node server/index.mjs`：
//   1. server/index.mjs 不读 .env（生产靠容器注入环境变量），本机需要从 .env 拿
//      PGHOST/PGSSLMODE 等，否则 pool 会连到默认的 localhost:5432 然后报错。
//   2. 联调要求显式绑 0.0.0.0，让 Android 模拟器能通过 10.0.2.2 打到宿主机。
//
// 用法：
//   node scripts/dev-start.mjs
//   PORT=3001 node scripts/dev-start.mjs
//
// 注意：本脚本**只做环境装配 + 启动**，不改任何业务逻辑。

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');

const envPath = join(ROOT, '.env');
if (existsSync(envPath)) {
  process.loadEnvFile(envPath);
  console.log('[dev] 已加载 .env');
} else {
  console.warn('[dev] 未找到 .env，将依赖已导出的 PG* 环境变量');
}

// 数据库连通性自检：Neon 免费层空闲会挂起，先把实例唤醒并给出明确报错，
// 而不是等第一个 HTTP 请求才 500。
const { createPool } = await import('../server/db/pool.mjs');
// Neon 免费层挂起后冷启动要 20–40s，而 `server/db/pool.mjs` 的默认
// `connectionTimeoutMillis` 是 5000ms（生产容器内连本地 PG，5s 合理）。
// 这里显式放宽：createPool(config) 的合并顺序是「默认 < 环境变量 < 显式 config」，
// 所以传一个 config 就能覆盖，不需要改业务模块。
const probe = createPool({ connectionTimeoutMillis: 45000 });

// 空闲连接被服务端（Neon PgBouncer）断掉时，pg 会在 Pool 上冒一个 'error' 事件；
// 不监听它的话 Node 会把「Unhandled 'error' event」当致命错误直接杀进程
// （实测：后台跑几十分钟后被 Neon 回收空闲连接 → 整个 dev 服务消失）。
// 这里只记录日志：pg 会自动把坏连接从池里摘掉，下一次查询重开即可。
probe.on('error', (err) => {
  console.warn(`[dev] idle client error（已忽略，连接池会自愈）: ${err.code || ''} ${err.message}`);
});

try {
  const t0 = Date.now();
  const { rows } = await probe.query('SELECT current_database() AS db, current_user AS usr');
  console.log(`[dev] 数据库连通 OK（${Date.now() - t0} ms） db=${rows[0].db} user=${rows[0].usr}`);

  const { rows: cnt } = await probe.query(
    `SELECT count(*)::int AS n FROM defect_tickets WHERE deleted_at IS NULL`,
  );
  console.log(`[dev] defect_tickets 现有 ${cnt[0].n} 条未删除记录`);
  if (cnt[0].n === 0) {
    console.warn('[dev] 提示：表是空的，先跑 `node scripts/migrate.mjs && node scripts/seed-dev.mjs`');
  }
} catch (err) {
  console.error(`[dev] 数据库连接失败：${err.code || ''} ${err.message}`);
  console.error('[dev] 检查 .env 里的 PGHOST/PGUSER/PGPASSWORD/PGSSLMODE 是否正确');
  await probe.end();
  process.exit(1);
}

const { createApp } = await import('../server/index.mjs');
const app = createApp({ pool: probe });
const port = Number(process.env.PORT) || 3000;

app.listen(port, '0.0.0.0', () => {
  console.log(`[dev] TillRoad API listening on http://0.0.0.0:${port}`);
  console.log(`[dev]   · Android 模拟器: http://10.0.2.2:${port}`);
  console.log(`[dev]   · 桌面 / iOS 模拟器: http://localhost:${port}`);
  console.log('[dev] Ctrl+C 停止');
});

// 优雅退出：让 pg 池关闭，否则 Node 会挂住不退。
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, async () => {
    console.log(`\n[dev] 收到 ${sig}，正在关闭…`);
    app.close(() => {});
    await probe.end().catch(() => {});
    process.exit(0);
  });
}
