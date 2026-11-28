// server/repositories/import_batches.mjs
// 题路 TillRoad · m31124：题库导入批次仓储
//
// 这张表回答的是「这批题是哪一次导进来的」：
//   用户反馈——多次导入之后题库变成一锅粥，看不出哪些题属于同一次导入，
//   删错题只能一道一道勾。批次把「一次导入」提升成一等公民：
//   一次导入 = import_batches 一行 + 该批所有题共享同一个 batch_id。
//
// 与 questions 的分工（见 migrations/0007_import_batch.sql 的设计取舍）：
//   * import_batches 是**账本**：文件名、题目数、时间。前端下拉框只读这张表。
//   * questions.batch_id 是**档案列**：让「按批次筛题」能直接走索引，
//     不必每条列表 SQL 都 JOIN 一次账本。
//   * 两者之间**刻意不建外键**：删账本行不该牵动题目本体。
//
// 生命周期：导入事务开始时就 INSERT（question_count = 0）占位，
// 题目全部入库后再 UPDATE 成真实条数。整个过程在同一个 withTransaction 里，
// 所以「有批次行但没有题」这种半成品状态不会留存 —— 除非导入真的失败了（那时整体回滚）。
import { queryMany, queryOne } from './base.mjs';

export const TABLE = 'import_batches';

/**
 * 建批次（占位）。
 *
 * 导入一开始就落一行，题数先写 0；等题目插完后由 updateQuestionCount 写成真实条数。
 * 为什么要先占位而不是最后一次性插入：题目需要 batch_id 才能在插入时就带上，
 * 而 batch_id 是数据库生成的（gen_random_uuid），必须先插入批次行拿到 id。
 *
 * @returns {Promise<{id: string, user_id: string, filename: string, question_count: number, created_at: Date}>}
 */
export async function create(client, { userId, filename } = {}) {
  if (!userId) throw new TypeError('import_batches.create: userId 必填');
  if (!filename || String(filename).trim() === '') {
    throw new TypeError('import_batches.create: filename 必填');
  }
  const sql = `INSERT INTO ${TABLE} (user_id, filename, question_count)
               VALUES ($1, $2, 0)
               RETURNING *`;
  return queryOne(client, sql, [userId, String(filename)]);
}

/**
 * 回填该批次实际入库的题数（判重跳过的不计入）。
 *
 * 只允许改自己的批次：WHERE 带 user_id，防止越权改别人的账本。
 * 返回值是更新后的行；找不到（不属于该用户 / 已被删）返回 null。
 */
export async function updateQuestionCount(client, { batchId, userId, questionCount } = {}) {
  if (!batchId || !userId) return null;
  const count = Number.isInteger(questionCount) && questionCount >= 0 ? questionCount : 0;
  const sql = `UPDATE ${TABLE}
                  SET question_count = $3
                WHERE id = $1 AND user_id = $2
                RETURNING *`;
  return queryOne(client, sql, [batchId, userId, count]);
}

/**
 * 列某个用户的全部批次，按创建时间倒序（最新的导入排最前）。
 *
 * 为什么固定排序、不给 orderBy 参数：下拉框天然要「最近的在上」，
 * 调用方换排序没有业务意义，反而多一个可被误用的口子。
 */
export async function listByUser(client, userId, { limit = 100, offset = 0 } = {}) {
  if (!userId) return [];
  const lim = Number.isInteger(limit) && limit > 0 ? Math.min(limit, 500) : 100;
  const off = Number.isInteger(offset) && offset > 0 ? offset : 0;
  const sql = `SELECT * FROM ${TABLE}
                WHERE user_id = $1
                ORDER BY created_at DESC, id DESC
                LIMIT $2 OFFSET $3`;
  return queryMany(client, sql, [userId, lim, off]);
}

/** 按主键读（校验归属，不属于该用户一律返回 null）。 */
export async function getById(client, batchId, userId) {
  if (!batchId || !userId) return null;
  const sql = `SELECT * FROM ${TABLE} WHERE id = $1 AND user_id = $2`;
  return queryOne(client, sql, [batchId, userId]);
}
