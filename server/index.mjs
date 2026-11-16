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
import { json, readBody, sendError } from './routes/_http.mjs';

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
  // BE-03：仓储可注入（fake 测试用）。真库走 pool + PG 仓储，fake 走注入的 repos。
  const reposCtx = repos;
  const server = httpCreateServer(async (req, res) => {
    try {
      const body = await readBody(req);
      const u = new URL(req.url, 'http://localhost');
      let pathname = u.pathname;
      // 容忍尾部斜杠：/health/ 与 /health 等价（客户端拼接 URL 时常见）。
      if (pathname.length > 1 && pathname.endsWith('/')) pathname = pathname.slice(0, -1);

      const seg = pathname.split('/').filter(Boolean);
      const out = await dispatch(req.method, seg, {
        pool,
        repos: reposCtx,
        state,
        searchParams: u.searchParams,
        body,
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
  app.listen(port, () => {
    // eslint-disable-next-line no-console
    console.log(`TillRoad API listening on http://127.0.0.1:${port}`);
  });
}
