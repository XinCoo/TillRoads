// 分发前：向 Neon 插入测试用户，并打印 UUID 供配置 Railway 的 TOKENS 变量。
//
// ── 用法 ────────────────────────────────────────────────────────────────
//   node --env-file=.env --dns-result-order=ipv4first scripts/seed-users.mjs
//
//   · `.env` 需要包含 PGHOST / PGPORT / PGUSER / PGPASSWORD / PGDATABASE
//     （Neon 控制台 → Connection Details 里可复制；本仓库的 `.env` 已被 .gitignore 排除）。
//   · 若本机直连 Neon pooler 报 `ECONNRESET`（冷启动 / 网络路径问题），
//     可改用 Neon 的 WebSocket 通道：见 README「分发前检查清单」的备注。
//
// ── 为什么需要它 ────────────────────────────────────────────────────────
//   Railway 的 TOKENS 变量格式是 `token:user_uuid`。用户 UUID 必须真实存在于
//   Neon 的 users 表里，否则后端拿到 token 后查不到用户 → 全部端点 401/404。
//   本脚本负责「建号 → 打印 UUID → 你把 UUID 填进 Railway」。
//
// ── 幂等 ────────────────────────────────────────────────────────────────
//   按 nickname 查：已存在就复用它的 UUID（不重复插入、不改任何字段），
//   所以重复执行安全。nickname 改了就会新建一个用户，这是预期行为。
//
// ── 不做的事 ────────────────────────────────────────────────────────────
//   · 不建考试档案 / 科目 / 考点 —— 那些由 App 首次进入时自建，或由
//     `scripts/seed-dev.mjs` 给联调账号铺数据。
//   · 不碰 schema、不改 migrations、不写任何后端代码。
//   · 删用户请手动在 Neon 控制台操作（避免误删别人的数据）。
//
// ── 输出 ────────────────────────────────────────────────────────────────
//   打印每个用户的 UUID 与 nickname，并给出可直接粘贴进 Railway 的 TOKENS 行。

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
try {
  process.loadEnvFile(join(ROOT, '.env'));
} catch {
  /* .env 可选：也允许用 --env-file=.env 在命令行注入 */
}

const REQUIRED_ENV = ['PGHOST', 'PGUSER', 'PGPASSWORD', 'PGDATABASE'];
const missing = REQUIRED_ENV.filter((k) => !process.env[k] || !process.env[k].trim());
if (missing.length > 0) {
  console.error(`[seed-users] 缺少环境变量：${missing.join(', ')}`);
  console.error('[seed-users] 请从 Neon 控制台 Connection Details 复制，或先建 .env 再重跑：');
  console.error('[seed-users]   PGHOST=... / PGPORT=5432 / PGUSER=... / PGPASSWORD=... / PGDATABASE=...');
  console.error('[seed-users]   （PGSSLMODE=require 建议一并设置）');
  process.exit(1);
}

/** 本次要确保存在的用户。nickname 是幂等键。 */
const USERS = [
  { nickname: '测试用户C', token: 'tltest003' },
  { nickname: '测试用户D', token: 'tltest004' },
];

const { createPool } = await import('../server/db/pool.mjs');
const pool = createPool();
const client = await pool.connect();
const results = [];

try {
  for (const u of USERS) {
    // 已存在 → 复用；不存在 → 插入并回读 UUID。
    const existing = await client.query(
      `SELECT id, nickname FROM users
        WHERE nickname = $1 AND deleted_at IS NULL
        LIMIT 1`,
      [u.nickname],
    );
    if (existing.rows.length > 0) {
      const row = existing.rows[0];
      results.push({ token: u.token, id: row.id, nickname: row.nickname, created: false });
      console.log(`[seed-users] 已存在 ${row.nickname} → ${row.id}`);
      continue;
    }

    const inserted = await client.query(
      `INSERT INTO users (nickname, timezone)
       VALUES ($1, 'Asia/Shanghai')
       RETURNING id, nickname`,
      [u.nickname],
    );
    const row = inserted.rows[0];
    results.push({ token: u.token, id: row.id, nickname: row.nickname, created: true });
    console.log(`[seed-users] 新建 ${row.nickname} → ${row.id}`);
  }
} catch (err) {
  console.error(`[seed-users] 失败：${err.code || ''} ${err.message}`);
  if (err.detail) console.error(`[seed-users] detail: ${err.detail}`);
  if (err.hint) console.error(`[seed-users] hint: ${err.hint}`);
  process.exitCode = 1;
} finally {
  client.release();
  await pool.end();
}

if (results.length > 0) {
  console.log('');
  console.log('[seed-users] —— 请把下面这行填进 Railway 变量 TOKENS（与已有 token 逗号分隔）——');
  console.log(results.map((r) => `${r.token}:${r.id}`).join(','));
  console.log('');
  console.log('[seed-users] 填完后必须在 Railway 面板点 Redeploy / Restart（只保存变量不重启不生效）。');
  console.log('[seed-users] 验证：curl -H "Authorization: Bearer tltest003" https://tillroads-production.up.railway.app/health');
}
