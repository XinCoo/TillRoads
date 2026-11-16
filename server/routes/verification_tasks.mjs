// server/routes/verification_tasks.mjs
// 题路 TillRoad · BE-04 T3：验证任务查询端点（纯读，无状态迁移）
//
// ★ 本轮只做查询层：
//   · 不加 POST/PATCH/DELETE —— 状态迁移属 BE-03（已完成），推送/定时任务刻意不做；
//   · 提醒由前端轮询本接口自行展示（拍板项 3）：返回 urgency 三态 + 剩余天数足够，
//     推送需要额外基础设施、定时任务在无后台服务时不可靠。
//
// 端点：
//   GET /users/:userId/verification-tasks?status=V1,V2&urgency=overdue,due_soon&limit&offset
//   GET /users/:userId/verification-summary
//
// 参数校验全部前置到本层：非法 stage / urgency / limit 一律 400，
// 不把脏参数透到仓储层（那里抛的是 TypeError，会被 httpError 归到 500）。

import * as dtRepo from '../repositories/defect_tickets.mjs';
import { ok, fail, pagination } from './_http.mjs';
import { isUrgency, isVerifyStage, URGENCY_VALUES } from '../verify_window.mjs';
import * as C from '../../core/index.mjs';

/**
 * 解析逗号分隔的 query 参数。
 * 'a,b' -> ['a','b']；空串/缺省 -> []。
 * 去重（同一个值重复给不报错，也不重复过滤）。
 */
function parseCsv(value) {
  if (value == null) return [];
  const out = [];
  for (const part of String(value).split(',')) {
    const s = part.trim();
    if (s !== '' && !out.includes(s)) out.push(s);
  }
  return out;
}

/**
 * 解析 stage 过滤（query 名 `status`，与 BE-03 的列表端点保持一致，
 * 但语义是「当前验证 stage」而非缺陷单 status）。
 */
function parseStages(searchParams) {
  const raw = parseCsv(searchParams.get('status') ?? searchParams.get('stage'));
  for (const s of raw) {
    if (!isVerifyStage(s)) {
      return { error: fail('INVALID_STAGE', 400, { message: `非法 stage：${s}（允许 ${C.VERIFY_STAGES.join(',')}）` }) };
    }
  }
  return { stages: raw };
}

/** 解析 urgency 过滤。 */
function parseUrgency(searchParams) {
  const raw = parseCsv(searchParams.get('urgency'));
  for (const u of raw) {
    if (!isUrgency(u)) {
      return { error: fail('INVALID_URGENCY', 400, { message: `非法 urgency：${u}（允许 ${URGENCY_VALUES.join(',')}）` }) };
    }
  }
  return { urgency: raw };
}

/** 依赖注入缝：与 defect_tickets 路由同形（ctx.repos 可注入 fake）。 */
function resolve(ctx) {
  if (ctx.repos && ctx.repos.defectTickets) {
    return { repo: ctx.repos.defectTickets, client: ctx.repos.client ?? null };
  }
  return { repo: dtRepo, client: ctx.pool };
}

/** GET /users/:userId/verification-tasks */
async function listTasks(ctx, userId) {
  const stagesRes = parseStages(ctx.searchParams);
  if (stagesRes.error) return stagesRes.error;

  const urgencyRes = parseUrgency(ctx.searchParams);
  if (urgencyRes.error) return urgencyRes.error;

  // limit/offset 复用 pageParams（在仓储层生效）；这里只做类型归一，
  // 非法值（NaN/负数）由 pageParams 兜底成默认值，与四表端点行为一致。
  const page = pagination(ctx.searchParams);

  const { repo, client } = resolve(ctx);
  const result = await repo.listVerificationTasks(client, userId, {
    stages: stagesRes.stages,
    urgency: urgencyRes.urgency,
    ...page,
  });

  return ok({
    items: result.items,
    total: result.total,
    limit: result.limit,
    offset: result.offset,
  });
}

/** GET /users/:userId/verification-summary */
async function summary(ctx, userId) {
  const { repo, client } = resolve(ctx);
  const data = await repo.verificationSummary(client, userId);
  return ok(data);
}

export async function match(method, seg, ctx) {
  if (method !== 'GET') return null;

  // /users/:userId/verification-tasks
  if (seg.length === 3 && seg[0] === 'users' && seg[2] === 'verification-tasks') {
    return listTasks(ctx, seg[1]);
  }

  // /users/:userId/verification-summary
  if (seg.length === 3 && seg[0] === 'users' && seg[2] === 'verification-summary') {
    return summary(ctx, seg[1]);
  }

  return null;
}
