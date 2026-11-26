// server/repositories/question_hidden.mjs
// 题路 TillRoad · 练习模式 R3（m26090）：题目隐藏仓储
//
// 这张表回答的是另一个问题：**「这道题我不想再看到。」**
//
// 与 question_mastery（R2）的分工：
//   question_mastery：我的掌握状态（已掌握 / 未掌握 / 未标记），影响练习与筛选。
//   question_hidden：我的可见性偏好（我不想在题库里看到它），只影响列表。
//   两者互不影响：标记「已掌握」不隐藏，隐藏也不改掌握度。
//
// 为什么公共题只能隐藏、不能软删：
//   软删（questions.deleted_at）是「把题从整个公共题库里拿走」——
//   别人也看不到了。公共题不属于任何用户，用户无权这么做。
//   所以公共题给一条「只对我隐藏」的通路：题本身不动，只在自己的列表里消失。
//
// 与软删的分工：
//   自己的题 → 软删（questions.deleted_at）。它连模考组卷都抽不到，是「真移除」。
//   公共题   → 隐藏（本表）。只影响列表与练习抽题，题本身仍在公共题库里。

import { queryMany, queryOne } from './base.mjs';

export const HIDDEN_TABLE = 'question_hidden';

/**
 * 隐藏一道题（幂等 upsert）。
 *
 * 同一对 (user_id, question_id) 只会留一行；重复调用只刷新 hidden_at。
 */
export async function hideQuestion(client, { userId, questionId }) {
  const sql = `
    INSERT INTO ${HIDDEN_TABLE} (user_id, question_id, hidden_at)
    VALUES ($1, $2, now())
    ON CONFLICT (user_id, question_id)
    DO UPDATE SET hidden_at = now()
    RETURNING *`;
  return queryOne(client, sql, [userId, questionId]);
}

/**
 * 取消隐藏。
 *
 * 没有隐藏记录时返回 null（不是错误 —— 重复取消隐藏应当幂等成功）。
 */
export async function unhideQuestion(client, { userId, questionId }) {
  const sql = `
    DELETE FROM ${HIDDEN_TABLE}
    WHERE user_id = $1 AND question_id = $2
    RETURNING *`;
  return queryOne(client, sql, [userId, questionId]);
}

/**
 * 读取某个用户在一批题目上的隐藏状态。
 *
 * 返回 Set<question_id>；没隐藏过的题不在集合里。
 */
export async function listHiddenIds(client, { userId, questionIds }) {
  if (!userId || !Array.isArray(questionIds) || questionIds.length === 0) {
    return new Set();
  }
  const sql = `
    SELECT question_id
    FROM ${HIDDEN_TABLE}
    WHERE user_id = $1 AND question_id = ANY($2::uuid[])`;
  const rows = await queryMany(client, sql, [userId, questionIds]);
  const set = new Set();
  for (const row of rows || []) {
    set.add(row.question_id);
  }
  return set;
}

/**
 * 隐藏过滤片段：排除「当前用户隐藏了的题」。
 *
 * 用 NOT EXISTS 子查询（不是 JOIN）：JOIN 会因为一题多行产生重复行；
 * 子查询更直白，也便于主查询继续加别的条件。
 *
 * @returns {{clause: string, params: Array<string>}|null}
 */
export function hiddenFilterClause({ userId, tableAlias = 'questions', paramIndex = 1 }) {
  if (!userId) return null;
  const clause = `NOT EXISTS (SELECT 1 FROM ${HIDDEN_TABLE} qh
      WHERE qh.question_id = ${tableAlias}.id AND qh.user_id = $${paramIndex})`;
  return { clause, params: [userId] };
}
