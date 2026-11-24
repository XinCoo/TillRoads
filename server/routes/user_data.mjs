// server/routes/user_data.mjs
// 题路 TillRoad · m18680 B1：删除「我的所有数据」（云端侧）
//
// 端点：
//   DELETE /users/:userId/data
//
// 为什么需要它：设置页原来的「清除所有数据」只清了本地（shared_preferences +
// SQLite + 日志），云端一行没动 —— 用户以为删干净了，重装 App / 换设备后
// 所有缺陷单、模考、复盘又回来了。名字与行为不符，是分发前的信任问题。
//
// ★ 只认 token 映射出来的 userId（ctx.authUserId）：
//   server/index.mjs 对 `users/:userId` 的 seg[1] 做**无条件改写**为 authUserId
//   （见 server/index.mjs 的 `pathParts[1] = authUserId`），所以客户端即使传
//   别人的 id，到这里也已经变成自己 —— 跨用户删除在物理上不可能。
//   下面的 `seg[1] !== authUserId` 分支是**第二道闸**（defense-in-depth）：
//   若将来 index.mjs 的改写逻辑被改掉或路由顺序调整，这里仍能拦住。
//   实测（.tmp-verify-data.mjs）：用 D 的 token 请求 /users/A/data，删的是 D 的行，
//   A 的行一行未动。
// ★ 软删而不是物理删：
//   schema 的每一张业务表都有 deleted_at，读路径全部带 `deleted_at IS NULL`。
//   物理删会牵动 FK（verifications/actions → defect_tickets ON DELETE CASCADE，
//   但 mock_exams → exam_profiles 没有级联），一旦顺序错就是 23503。
//   软删顺序无关紧要、可回滚、且与其它写路径语义一致。
//
// ★ 顺序按「子 → 父」：
//   verifications / actions 依附缺陷单；questions 依附 subjects；
//   mock_exams 依附 exam_profiles。父行软删不影响子行的 FK（外键只看行是否存在，
//   不看 deleted_at），所以顺序其实不强制，但按子→父写便于阅读与将来加物理删。

import { withTransaction } from '../repositories/base.mjs';
import { ok, fail } from './_http.mjs';

/** 一张表 + 它的归属条件。`where` 里用 $1 占位 userId。 */
const TABLES = Object.freeze([
  // 缺陷单的子行
  {
    key: 'verifications',
    sql: `UPDATE verifications SET deleted_at = now(), version = version + 1
           WHERE deleted_at IS NULL
             AND defect_ticket_id IN (
               SELECT id FROM defect_tickets WHERE user_id = $1 AND deleted_at IS NULL
             )`,
  },
  {
    key: 'actions',
    sql: `UPDATE actions SET deleted_at = now(), version = version + 1
           WHERE deleted_at IS NULL
             AND defect_ticket_id IN (
               SELECT id FROM defect_tickets WHERE user_id = $1 AND deleted_at IS NULL
             )`,
  },
  {
    key: 'defect_tickets',
    sql: `UPDATE defect_tickets SET deleted_at = now(), version = version + 1
           WHERE user_id = $1 AND deleted_at IS NULL`,
  },
  // 用户自己导入的题（公共题 owner_user_id IS NULL 不在此列，绝不删）
  {
    key: 'questions',
    sql: `UPDATE questions SET deleted_at = now(), version = version + 1
           WHERE owner_user_id = $1 AND deleted_at IS NULL`,
  },
  // 模考依附考试目标
  {
    key: 'mock_exams',
    sql: `UPDATE mock_exams SET deleted_at = now(), version = version + 1
           WHERE deleted_at IS NULL
             AND exam_profile_id IN (
               SELECT id FROM exam_profiles WHERE user_id = $1 AND deleted_at IS NULL
             )`,
  },
  {
    key: 'review_cycles',
    sql: `UPDATE review_cycles SET deleted_at = now(), version = version + 1
           WHERE user_id = $1 AND deleted_at IS NULL`,
  },
  // 考试配置：考点 → 科目 → 目标
  {
    key: 'knowledge_nodes',
    sql: `UPDATE knowledge_nodes SET deleted_at = now(), version = version + 1
           WHERE deleted_at IS NULL
             AND subject_id IN (
               SELECT s.id FROM subjects s
                 JOIN exam_profiles p ON p.id = s.exam_profile_id
                WHERE p.user_id = $1 AND p.deleted_at IS NULL AND s.deleted_at IS NULL
             )`,
  },
  {
    key: 'subjects',
    sql: `UPDATE subjects SET deleted_at = now(), version = version + 1
           WHERE deleted_at IS NULL
             AND exam_profile_id IN (
               SELECT id FROM exam_profiles WHERE user_id = $1 AND deleted_at IS NULL
             )`,
  },
  {
    key: 'exam_profiles',
    sql: `UPDATE exam_profiles SET deleted_at = now(), version = version + 1
           WHERE user_id = $1 AND deleted_at IS NULL`,
  },
]);

/**
 * DELETE /users/:userId/data
 *
 * 返回每一类被软删的行数，便于前端展示「已删除 N 条缺陷单 / M 道题」。
 * 全在一个事务里：任一步失败则整笔回滚，不会留下删了一半的状态。
 */
async function deleteAllUserData(ctx) {
  const userId = ctx.authUserId ?? null;
  if (!userId) {
    // 没配 TOKENS 的本地开发环境允许无 token 访问，但「删数据」不能无主。
    return fail('UNAUTHORIZED', 401, { message: '删除数据需要有效的 Bearer Token' });
  }

  const counts = await withTransaction(ctx.pool, async (client) => {
    const out = {};
    for (const t of TABLES) {
      const res = await client.query(t.sql, [userId]);
      out[t.key] = res.rowCount ?? 0;
    }
    return out;
  });

  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  return ok({ user_id: userId, deleted: counts, total });
}

/** 路由匹配：只认 DELETE /users/:id/data。 */
export async function match(method, seg, ctx) {
  if (method !== 'DELETE') return null;
  if (seg.length !== 3) return null;
  if (seg[0] !== 'users' || seg[2] !== 'data') return null;

  // 有 token 时必须与自己一致。注意：index.mjs 已把 seg[1] 改写成 authUserId，
  // 所以正常情况下走不到这里；保留是为了 index.mjs 改写逻辑变更时仍有兜底。
  if (ctx.authUserId && seg[1] !== ctx.authUserId) {
    return fail('FORBIDDEN', 403, { message: '只能删除自己的数据' });
  }
  return deleteAllUserData(ctx);
}
