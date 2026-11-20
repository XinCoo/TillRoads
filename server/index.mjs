// server/index.mjs
// 题路 TillRoad · REST API 入口（BE-01 第 4 步：只做启动 + 依赖注入 + 路由挂载）
//
// 本文件在第 4 步被**瘦身**：所有业务端点已迁到 server/routes/ 下的模块。
// 这里只剩四件事：
//   1. 创建 HTTP server；
//   2. 组装依赖（{ pool, state }）并注入路由层（决策 7：依赖注入，不做模块级单例）；
//   3. 每请求解析 body / URL / 分段，交给 routes/index.mjs 的 dispatch()；
//   4. 作为主模块运行时监听 PORT（默认 3000）。
//
// 为什么 state 还留在这里而不是各 route 模块自建：
//   缺陷单 / 验证 / AI 任务仍是内存 Map（BE-03/BE-04 才会接 PG）。它们需要**共享同一份**
//   状态（建单后 validation 端点要能查到）。若每个模块自己 new 一份 Map，测试之间会互相污染，
//   生产上会出现「建了单但查不到」。所以 state 由本文件拥有，通过 ctx 传给所有模块。

import { createServer as httpCreateServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import { dispatch } from './routes/index.mjs';
import { json, preflight, readBody, sendError } from './routes/_http.mjs';
import { parseTokens, requireBearer } from './auth.mjs';
/**
 * 每个 app 实例持有独立的内存状态，便于集成测试隔离。
 * 这些 Map 是 BE-03/BE-04 的临时着陆点，接 PG 后会被删掉。
 */
function createState() {
  return {
    examProfiles: new Map(),
    defectTickets: new Map(),
    verifications: [],
    aiJobs: new Map(),
  };
}

function resourcePath(pathname) {
  const parts = pathname.split('/').filter(Boolean);
  if (parts.length < 2) return null;
  const [kind, id] = parts;
  if (!['defect-tickets', 'mock-exams', 'review-cycles'].includes(kind)) return null;
  return { kind, id };
}

async function findResourceOwner(pool, kind, id) {
  if (!id) return null;
  if (kind === 'defect-tickets') {
    const result = await pool.query('SELECT user_id FROM defect_tickets WHERE id = $1 AND deleted_at IS NULL', [id]);
    return result.rows[0]?.user_id ?? null;
  }
  if (kind === 'review-cycles') {
    const result = await pool.query('SELECT user_id FROM review_cycles WHERE id = $1 AND deleted_at IS NULL', [id]);
    return result.rows[0]?.user_id ?? null;
  }
  const result = await pool.query(
    `SELECT p.user_id
       FROM mock_exams m
       JOIN exam_profiles p ON p.id = m.exam_profile_id
      WHERE m.id = $1 AND m.deleted_at IS NULL AND p.deleted_at IS NULL`,
    [id],
  );
  return result.rows[0]?.user_id ?? null;
}
/**
 * 创建 API 应用。
 *
 * @param {object} [options]
 * @param {object} [options.pool]  pg.Pool 或测试用 fake pool。
 *   四表路由（exam_profiles/subjects/knowledge_nodes/capability_layers）需要它做真实读写。
 *   不传时这些端点会在访问 DB 时抛错（500 internal），而**纯内存端点仍然可用**
 *   —— 这正是本机无 PG 时 fake 单测可行的原因：base_version 缺失等入参错误在碰 DB 之前
 *   就已经被判成 400 了。
 * @returns {{server: import('node:http').Server, listen: Function, close: Function, state: object, pool: object|undefined}}
 */
export function createApp(options = {}) {
  const { pool, repos } = options || {};
  const state = createState();
  // TOKENS is optional for local development; when configured, every API request
  // (including health) must present one of the configured Bearer tokens.
  const tokens = parseTokens();
  // BE-03：仓储可注入（fake 测试用）。真库走 pool + PG 仓储，fake 走注入的 repos。
  const reposCtx = repos;
  const server = httpCreateServer(async (req, res) => {
    try {
      const u = new URL(req.url, 'http://localhost');
      const isHealth = req.method === 'GET' && (u.pathname === '/health' || u.pathname === '/health/');
      let authUserId;
      if (req.method !== 'OPTIONS' && !isHealth && tokens.length) authUserId = requireBearer(req, tokens);
      req.authUserId = authUserId;
      // FE-03 联调：CORS 预检必须在读 body / 路由分发**之前**处理.
      // OPTIONS 不带业务 body，进 dispatch 只会落 404，浏览器就把预检判失败。
      if (req.method === 'OPTIONS') {
        preflight(res);
        return;
      }

      const body = await readBody(req);
      const scopedBody = authUserId && body && typeof body === 'object'
        ? { ...body, user_id: authUserId }
        : body;
      let pathname = u.pathname;
      if (authUserId) {
        const pathParts = pathname.split('/').filter(Boolean);
        if (pathParts[0] === 'users' && pathParts.length >= 2) {
          pathParts[1] = authUserId;
          pathname = `/${pathParts.join('/')}`;
        }
        u.searchParams.set('user_id', authUserId);
      }
      // 容忍尾部斜杠：/health/ 与 /health 等价（客户端拼接 URL 时常见）。
      if (pathname.length > 1 && pathname.endsWith('/')) pathname = pathname.slice(0, -1);

      if (authUserId && pool) {
        const resource = resourcePath(pathname);
        if (resource) {
          const owner = await findResourceOwner(pool, resource.kind, resource.id);
          if (owner && owner !== authUserId) {
            const error = new Error('forbidden');
            error.statusCode = 403;
            error.body = { error: 'forbidden' };
            throw error;
          }
        }
      }

      const seg = pathname.split('/').filter(Boolean);
      const out = await dispatch(req.method, seg, {
        pool,
        repos: reposCtx,
        state,
        authUserId,
        searchParams: u.searchParams,
        body: scopedBody,
      });

      if (out === null || out === undefined) {
        json(res, 404, { error: 'not_found' });
        return;
      }
      json(res, out.status, out.body);
    } catch (e) {
      // 统一错误出口：带 statusCode 的 Error 走 err.body（409 两种形状不在此处重拼），
      // 带 code 的走 400，其它走 500。见 routes/_http.mjs 的 httpError。
      sendError(res, e);
    }
  });

  return {
    server,
    state,
    pool,
    listen(...args) {
      return server.listen(...args);
    },
    close(...args) {
      return server.close(...args);
    },
  };
}

// 同时导出 createServer 别名，便于不同工厂命名习惯。
export const createServer = createApp;

// 作为主模块直接启动：node server/index.mjs（监听 PORT 或 3000）。
const invoked = process.argv[1] ? path.resolve(process.argv[1]) : '';
if (invoked && fileURLToPath(import.meta.url) === invoked) {
  const port = Number(process.env.PORT) || 3000;
  // 主模块才建真实连接池：createPool() 惰性不连库，缺 PGHOST 等环境变量也不会启动失败。
  const { createPool } = await import('./db/pool.mjs');
  const pool = createPool();
  const app = createApp({ pool });
  // 显式绑 0.0.0.0：默认不传 host 时 Node 绑 '::'（dual-stack），多数情况下
  // Android 模拟器走 10.0.2.2 也能访问，但这依赖系统 IPv6/双栈行为，不够确定。
  // 显式绑 IPv4 全部网卡可直接覆盖模拟器与局域网真机两种场景。
  app.listen(port, '0.0.0.0', () => {
    // eslint-disable-next-line no-console
    console.log(`TillRoad API listening on http://0.0.0.0:${port}`);
    // eslint-disable-next-line no-console
    console.log(`  · Android 模拟器访问: http://10.0.2.2:${port}`);
    // eslint-disable-next-line no-console
    console.log(`  · 本机/桌面/iOS 模拟器: http://localhost:${port}`);
  });
}
