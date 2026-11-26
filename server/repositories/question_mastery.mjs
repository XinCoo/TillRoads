// server/repositories/question_mastery.mjs
// 题路 TillRoad · 练习模式 R2（m25316）：题目掌握度仓储
//
// 这张表回答一个问题：**「这道题我现在到底会不会？」**
// R1 只有一次性的「这次答对没答对」，用一周之后用户明确提出「答对的题想标一下掌握状态」，
// 因为同一个人同一道题，今天做对不代表三天后还记得。掌握度必须是**可长期保存、可按状态筛题**的一等数据。
//
// 设计要点：
//   1. 归属在 (user_id, question_id) 上，不在题上 —— 同一道公共题，
//      每个人的掌握度不同；自己的题也只标自己的那份。
//   2. 「行不存在」= 从没标记过（未标记），与「mastered=false」（标过、还没掌握）语义不同，
//      所以用「行存在与否」承载三态，而不是把 mastered 设成可空三态布尔。
//   3. 只读 public 的用户没有自己的题，**不允许标记**（路由层返回 403）——
//      否则公共题会被某个用户的标记污染掉，而公共题是别人上传的。
//   4. upsert 用 ON CONFLICT，因为「同一对用户-题目只留一行」是硬约束（UNIQUE 约束保证）。

import { queryMany, queryOne } from './base.mjs';

export const MASTERY_TABLE = 'question_mastery';

/**
 * 写入/更新一条掌握度标记（upsert）。
 *
 * 幂等：同一对 (user_id, question_id) 重复调用只会更新 mastered 与 updated_at，
 * 不会产生第二行（依赖表上的 UNIQUE(user_id, question_id) 约束）。
 */
export async function upsertMastery(client, { userId, questionId, mastered }) {
  const sql = `
    INSERT INTO ${MASTERY_TABLE} (user_id, question_id, mastered, updated_at)
    VALUES ($1, $2, $3, now())
    ON CONFLICT (user_id, question_id)
    DO UPDATE SET mastered = EXCLUDED.mastered, updated_at = now()
    RETURNING *`;
  const row = await queryOne(client, sql, [userId, questionId, Boolean(mastered)]);
  return row;
}

/**
 * 读取某个用户在一批题目上的掌握度。
 *
 * 返回 Map<question_id, mastered>；没有标记过的题目**不在 Map 里**（= 未标记）。
 * 题库列表页要用它给每张卡片挂「已掌握 / 未掌握 / 未标记」徽标，
 * 所以一次查完批量题，而不是每题查一次。
 */
export async function listMasteryMap(client, { userId, questionIds }) {
  if (!userId || !Array.isArray(questionIds) || questionIds.length === 0) {
    return new Map();
  }
  const sql = `
    SELECT question_id, mastered
    FROM ${MASTERY_TABLE}
    WHERE user_id = $1 AND question_id = ANY($2::uuid[])`;
  const rows = await queryMany(client, sql, [userId, questionIds]);
  const map = new Map();
  for (const row of rows || []) {
    map.set(row.question_id, Boolean(row.mastered));
  }
  return map;
}

/**
 * 按掌握状态过滤题目（题库列表页的「掌握状态」筛选器用）。
 *
 * 返回 where 片段与参数，供 listVisible 拼进主查询。
 *   * mastered=true  → 有标记且标记为已掌握。
 *   * mastered=false → 有标记且标记为未掌握（**不含从未标记过的题**）。
 * 刻意用 EXISTS 子查询而不是 JOIN：JOIN 会因为「一题多标记」产生重复行，
 * 而 UNIQUE(user_id, question_id) 虽然保证了一对一，但用子查询更直白，
 * 也便于在同一条 SELECT 里继续加别的过滤条件。
 *
 * @returns {{clause: string, params: Array<string>}|null}
 */
export function masteryFilterClause({ userId, mastered, tableAlias = 'questions', paramIndex = 1 }) {
  if (!userId || typeof mastered !== 'boolean') return null;
  const clause = `EXISTS (SELECT 1 FROM ${MASTERY_TABLE} qm
      WHERE qm.question_id = ${tableAlias}.id AND qm.user_id = $${paramIndex} AND qm.mastered = ${mastered ? 'true' : 'false'})`;
  return { clause, params: [userId] };
}

