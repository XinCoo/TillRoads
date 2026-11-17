// server/routes/review_cycles.mjs
// 题路 TillRoad · BE-06 T3：日/周/月复盘端点
//
// 五个端点（拍板项 4）：
//   POST   /review-cycles            生成一条复盘快照（算 metrics 再落库）
//   GET    /review-cycles            列表（user_id 必填；按 period DESC）
//   GET    /review-cycles/:id        读单条快照
//   PATCH  /review-cycles/:id        标记已读（completed:true）
//   DELETE /review-cycles/:id        软删
//
// 设计要点：
//   · POST 是「算一次、存快照」而不是「实时视图」——
//     同周期重复 POST 返回 409 ALREADY_EXISTS（body 带 existing_id），
//     要重做必须先 DELETE。理由：复盘是用户当时的判断，不能被后算的数字覆盖。
//   · metrics 在同一个事务里算完就写：若 metrics 计算与落库分开，
//     并发下两个请求可能一个算出 A 一个算出 B 然后双写。
//     但 metrics 只读不写业务表，所以用 read 连接算、用事务连接写在技术上
//     会有「算的时刻与写的时刻之间数据变了」的窗口 —— 复盘是周期快照，
//     这个窗口正是「用户点按钮那一刻的数据」，可接受，且比把六条聚合
//     SQL 全塞进写事务更轻。因此：**先 read 算 metrics，再开事务写**。
//   · 单条读/列表读都不需要事务，直接走 pool。
//
// 与 BE-03 假端点的关系：那个固定返回 {type,closed_count,...} 的假
// GET /review-cycles 已从 defect_tickets.mjs 删除，改由本模块接管（T4）。

import * as repo from '../repositories/review_cycles.mjs';
import { computeMetrics } from '../review_stats.mjs';
import { CYCLE_TYPES, PERIOD_FORMATS, resolvePeriod } from '../review_period.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { ok, fail, pagination, readBaseVersion } from './_http.mjs';

/** 依赖注入缝：ctx.repos.reviewCycles 存在时走 fake（与其它模块同形）。 */
function resolve(ctx) {
  if (ctx.repos && ctx.repos.reviewCycles) {
    return { repo: ctx.repos.reviewCycles, client: ctx.repos.client ?? null };
  }
  return { repo, client: ctx.pool };
}

async function run(ctx, fn) {
  if (ctx.repos && ctx.repos.reviewCycles) {
    const { repo: r, client } = resolve(ctx);
    return fn(r, client);
  }
  return withTransaction(ctx.pool, (tx) => fn(repo, tx));
}
async function read(ctx, fn) {
  const { repo: r, client } = resolve(ctx);
  return fn(r, client);
}

/**
 * 算 metrics。
 *
 * 真库路径直接调 review_stats.computeMetrics（六条聚合 SQL 并行）。
 * fake 路径下没有 PG，若直接调会立刻炸 SQL —— 所以 fake 可以自带一个
 * computeMetrics 覆盖掉默认实现（fake 只需给出零值 metrics，让路由层的
 * 周期解析 / 查重 / 409 / 201 形状可测；真口径由集成测试覆盖）。
 */
async function computeMetricsFor(ctx, userId, bounds) {
  const fake = ctx.repos && ctx.repos.reviewCycles;
  if (fake && typeof fake.computeMetrics === 'function') {
    return fake.computeMetrics(ctx.repos.client ?? null, userId, bounds);
  }
  return computeMetrics(ctx.pool, userId, bounds);
}

function isPgSqlState(code) {
  return typeof code === 'string' && /^[0-9A-Z]{5}$/.test(code);
}

/** 仓储/纯函数抛的错 -> HTTP 响应。 */
function mapError(e) {
  if (e && typeof e.statusCode === 'number' && e.body && typeof e.body === 'object') {
    return { status: e.statusCode, body: e.body };
  }
  if (e && e.name === 'NotFoundError' && e.body) return { status: 404, body: e.body };
  // 周期解析抛的是 TypeError（非法 period / cycle_type）—— 属客户端错误。
  if (e instanceof TypeError) {
    return fail('INVALID_PERIOD', 400, { message: e.message });
  }
  if (e && typeof e.code === 'string' && !isPgSqlState(e.code)) {
    return fail(e.code, 400, e.message ? { message: e.message } : undefined);
  }
  throw e;
}

/**
 * 校验 cycle_type。
 * @returns {{value:string}|{error:object}}
 */
function parseCycleType(value) {
  if (value == null || String(value).trim() === '') {
    return { error: fail('MISSING_CYCLE_TYPE', 400, { message: `cycle_type 必填（允许 ${CYCLE_TYPES.join(',')}）` }) };
  }
  const v = String(value).trim();
  if (!CYCLE_TYPES.includes(v)) {
    return { error: fail('INVALID_CYCLE_TYPE', 400, { message: `非法 cycle_type：${v}（允许 ${CYCLE_TYPES.join(',')}）` }) };
  }
  return { value: v };
}

// ---------------------------------------------------------------------------
// POST /review-cycles
// ---------------------------------------------------------------------------
async function createCycle(ctx) {
  const body = ctx.body ?? {};

  if (!body.user_id) {
    return fail('missing_user_id', 400, { message: 'user_id 必填' });
  }

  const typeRes = parseCycleType(body.cycle_type ?? body.type);
  if (typeRes.error) return typeRes.error;
  const cycleType = typeRes.value;

  // 先解析周期（空 -> 当前周期）。非法 period 在写库前就拒掉。
  let resolved;
  try {
    resolved = resolvePeriod(cycleType, body.period, {
      now: ctx.now instanceof Date ? ctx.now : new Date(),
      timeZone: body.time_zone || undefined,
    });
  } catch (e) {
    return mapError(e);
  }

  try {
    // 第一步：算 metrics（六条聚合 SQL 并行）。
    // 不放进写事务，避免长时间持有连接锁住业务表。
    //
    // 注入缝：fake 模式（ctx.repos.reviewCycles 存在）下没有真 PG，
    // 由 fake 提供 computeMetrics（它返回一份零值 metrics，
    // 让路由层逻辑——周期解析/查重/409/201 形状——能被单测）。
    const metrics = await computeMetricsFor(ctx, body.user_id, {
      startAt: resolved.startAt,
      endAt: resolved.endAt,
    });

    // 第二步：开事务写。「锁父行 + 查重 + 插入」必须原子，
    // 否则并发 POST 会各自查重通过、双写同周期复盘。
    const created = await run(ctx, (r, client) =>
      r.create(client, {
        user_id: body.user_id,
        cycle_type: cycleType,
        period: resolved.period,
        metrics,
        completed: body.completed === true,
      }),
    );

    return ok(
      {
        id: created.id,
        user_id: created.user_id,
        cycle_type: created.cycle_type,
        period: created.period,
        metrics: created.metrics,
        completed: created.completed,
        version: created.version,
        created_at: created.created_at,
        period_start_at: resolved.startAt,
        period_end_at: resolved.endAt,
        time_zone: resolved.timeZone,
      },
      201,
    );
  } catch (e) {
    return mapError(e);
  }
}

// ---------------------------------------------------------------------------
// GET /review-cycles?user_id=&cycle_type=&period=&completed=
// ---------------------------------------------------------------------------
async function listCycles(ctx) {
  const userId = ctx.searchParams.get('user_id');
  if (!userId) {
    return fail('missing_user_id', 400, { message: 'user_id 必填（列表必须按用户过滤）' });
  }

  const cycleTypeRaw = ctx.searchParams.get('cycle_type') ?? ctx.searchParams.get('type');
  let cycleType = null;
  if (cycleTypeRaw != null && String(cycleTypeRaw).trim() !== '') {
    const typeRes = parseCycleType(cycleTypeRaw);
    if (typeRes.error) return typeRes.error;
    cycleType = typeRes.value;
  }

  const period = ctx.searchParams.get('period');
  const completedRaw = ctx.searchParams.get('completed');
  let completed;
  if (completedRaw != null && completedRaw !== '') {
    if (completedRaw === 'true') completed = true;
    else if (completedRaw === 'false') completed = false;
    else return fail('INVALID_COMPLETED', 400, { message: 'completed 只能是 true / false' });
  }

  const page = pagination(ctx.searchParams);

  try {
    const result = await read(ctx, (r, client) =>
      r.listByUser(client, userId, { cycleType, period, completed, ...page }),
    );
    return ok({
      items: result.items,
      total: result.total,
      limit: result.limit,
      offset: result.offset,
    });
  } catch (e) {
    return mapError(e);
  }
}

// ---------------------------------------------------------------------------
// GET /review-cycles/:id
// ---------------------------------------------------------------------------
async function getCycle(ctx, id) {
  try {
    const row = await read(ctx, (r, client) => r.getById(client, id));
    return ok(row);
  } catch (e) {
    return mapError(e);
  }
}

// ---------------------------------------------------------------------------
// PATCH /review-cycles/:id   只允许改 completed
// ---------------------------------------------------------------------------
async function patchCycle(ctx, id) {
  let baseVersion;
  try {
    baseVersion = readBaseVersion(ctx.body ?? {});
  } catch (e) {
    return mapError(e);
  }

  const body = ctx.body ?? {};
  const unknown = Object.keys(body).filter((k) => !['version', 'completed'].includes(k));
  if (unknown.length > 0) {
    // metrics / period / cycle_type 都是快照身份，不允许事后改。
    return fail('IMMUTABLE_FIELD', 400, {
      message: `复盘快照只允许修改 completed；不可改：${unknown.join(', ')}`,
      immutable_fields: unknown,
    });
  }

  if (typeof body.completed !== 'boolean') {
    return fail('INVALID_COMPLETED', 400, { message: 'completed 必须是布尔值' });
  }

  try {
    const updated = await run(ctx, (r, client) => r.markCompleted(client, id, body.completed, baseVersion));
    return ok(updated);
  } catch (e) {
    return mapError(e);
  }
}

// ---------------------------------------------------------------------------
// DELETE /review-cycles/:id
// ---------------------------------------------------------------------------
async function deleteCycle(ctx, id) {
  let baseVersion;
  try {
    baseVersion = readBaseVersion(ctx.body ?? {});
  } catch (e) {
    return mapError(e);
  }

  try {
    const archived = await run(ctx, (r, client) => r.archive(client, id, baseVersion));
    return ok(archived);
  } catch (e) {
    return mapError(e);
  }
}

// ---------------------------------------------------------------------------
// 挂载
// ---------------------------------------------------------------------------
export async function match(method, seg, ctx) {
  // /review-cycles
  if (seg.length === 1 && seg[0] === 'review-cycles') {
    if (method === 'POST') return createCycle(ctx);
    if (method === 'GET') return listCycles(ctx);
    return null;
  }

  // /review-cycles/:id
  if (seg.length === 2 && seg[0] === 'review-cycles') {
    if (method === 'GET') return getCycle(ctx, seg[1]);
    if (method === 'PATCH') return patchCycle(ctx, seg[1]);
    if (method === 'DELETE') return deleteCycle(ctx, seg[1]);
    return null;
  }

  return null;
}

export { PERIOD_FORMATS };
