// server/repositories/review_cycles.mjs
// 题路 TillRoad · BE-06 T1：复盘记录仓储
//
// 这张表是「快照」而不是「计算视图」：
//   POST 时算一次 metrics 落库，之后 GET 读到的永远是当时那份数字。
//   这样用户上周看到的复盘，下周再看不会因为新数据涌入而变形 ——
//   复盘的意义就是「当时我是怎么看这件事的」。
//   因此同周期重复生成不允许覆盖，只能显式 DELETE 后重生成（拍板项 2）。
//
// 与四表仓储的差异：
//   · 没有业务唯一约束（schema 只有索引 idx_rc_user，无 UNIQUE），
//     所以「同周期只能有一条」必须靠 create 里同事务查重实现；
//   · metrics 是 jsonb，序列化交给 _common.insertRow / updateWithVersion 统一处理。

import {
  archiveWithVersion,
  insertRow,
  pageParams,
  queryMany,
  lockParentRow,
  queryOne,
  requireRow,
  updateWithVersion,
} from './_common.mjs';

export const TABLE = 'review_cycles';

/** 允许写入的列（不含 id / 同步列）。 */
export const WRITABLE_COLUMNS = Object.freeze(['user_id', 'cycle_type', 'period', 'metrics', 'completed']);

/**
 * 可 PATCH 的列。
 * user_id / cycle_type / period 是这条快照的身份，改了就是另一条记录，必须重建；
 * metrics 是历史快照，不允许事后篡改（否则复盘失去审计意义）。
 * 所以只有 completed 可改。
 */
export const PATCHABLE_COLUMNS = Object.freeze(['completed']);

export const INSERT_COLUMNS = Object.freeze([...WRITABLE_COLUMNS]);

/**
 * 同周期已存在的错误：409 ALREADY_EXISTS，body 带 existing_id。
 *
 * 为什么不用 _common.duplicateError：
 *   那个是「同名冲突，让用户在两条记录里选一条」（resolution:'user_choice'），
 *   这里语义不同 —— 不是二选一，而是「这条已经生成过了，要重做请先删」。
 *   因此用独立错误码 ALREADY_EXISTS，body 形状也不同。
 */
export function alreadyExistsError(existing) {
  const err = new Error(
    `review_cycles: 该周期复盘已存在（${existing.cycle_type} ${existing.period}），如需重新生成请先 DELETE`,
  );
  err.name = 'ConflictError';
  err.code = 'ALREADY_EXISTS';
  err.statusCode = 409;
  err.status = 409;
  err.body = {
    error: 'ALREADY_EXISTS',
    cycle_type: existing.cycle_type,
    period: existing.period,
    existing_id: existing.id,
    resolution: 'delete_then_recreate',
  };
  return err;
}

/**
 * 查同 user + cycle_type + period 的未软删记录。
 * @returns {Promise<object|null>}
 */
export async function findByPeriod(client, userId, cycleType, period, { excludeId = null } = {}) {
  const where = ['user_id = $1', 'cycle_type = $2', 'period = $3', 'deleted_at IS NULL'];
  const params = [userId, cycleType, period];
  if (excludeId) {
    params.push(excludeId);
    where.push(`id <> $${params.length}`);
  }
  return queryOne(
    client,
    `SELECT * FROM ${TABLE} WHERE ${where.join(' AND ')} ORDER BY created_at ASC, id ASC LIMIT 1`,
    params,
  );
}

/**
 * 创建复盘快照。
 *
 * @param {object} client               事务内 client（必须已在 withTransaction 中）
 * @param {{user_id:string, cycle_type:string, period:string, metrics:object, completed?:boolean}} input
 * @returns {Promise<object>} 新建行
 *
 * ★ 必须在事务内调用：下面「锁父行 + 查重 + 插入」三步要原子，
 *   否则两个并发 POST 会各自查重通过、双写同周期复盘。
 */
export async function create(client, input = {}) {
  const { user_id: userId, cycle_type: cycleType, period, metrics } = input;

  if (!userId) throw new TypeError('review_cycles.create: user_id 必填');
  if (!cycleType) throw new TypeError('review_cycles.create: cycle_type 必填');
  if (!period) throw new TypeError('review_cycles.create: period 必填');
  if (metrics == null || typeof metrics !== 'object' || Array.isArray(metrics)) {
    throw new TypeError('review_cycles.create: metrics 必须是对象');
  }

  // 先对 users 行加锁：同一用户的复盘生成串行化（与 exam_profiles 的查重同款做法）。
  await lockParentRow(client, 'users', userId);

  const existing = await findByPeriod(client, userId, cycleType, period);
  if (existing) throw alreadyExistsError(existing);

  const values = [userId, cycleType, period, metrics, input.completed === true];
  return insertRow(client, TABLE, INSERT_COLUMNS, values);
}

/** 读单条（软删即 404）。 */
export async function getById(client, id) {
  return requireRow(client, TABLE, id);
}

/**
 * 按用户列复盘记录，period DESC（最近的周期在前）。
 *
 * 注意不能用 _common.listRows 的默认 orderBy（created_at ASC）：
 * 列表页要的是「最近周期优先」，period 是零填充字符串，字典序即时间序。
 */
export async function listByUser(client, userId, opts = {}) {
  if (!userId) throw new TypeError('review_cycles.listByUser: user_id 必填');

  const where = ['user_id = $1', 'deleted_at IS NULL'];
  const params = [userId];

  if (opts.cycleType) {
    params.push(opts.cycleType);
    where.push(`cycle_type = $${params.length}`);
  }
  if (opts.period) {
    params.push(opts.period);
    where.push(`period = $${params.length}`);
  }
  if (opts.completed !== undefined && opts.completed !== null) {
    params.push(opts.completed === true);
    where.push(`completed = $${params.length}`);
  }

  const countRow = await queryOne(
    client,
    `SELECT count(*)::int AS total FROM ${TABLE} WHERE ${where.join(' AND ')}`,
    params,
  );
  const total = countRow ? Number(countRow.total) : 0;

  const { limit, offset } = pageParams(opts);
  const items = await queryMany(
    client,
    `SELECT * FROM ${TABLE}
      WHERE ${where.join(' AND ')}
      ORDER BY period DESC, created_at DESC, id DESC
      LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, limit, offset],
  );

  return { items, total, limit, offset };
}

/**
 * 标记复盘已读（completed=true）。
 *
 * 只允许改 completed（见 PATCHABLE_COLUMNS）：metrics 是历史快照，
 * 不允许事后改写，否则复盘就失去「当时怎么判断」的审计价值。
 */
export async function markCompleted(client, id, completed, baseVersion) {
  if (typeof completed !== 'boolean') {
    throw new TypeError('review_cycles.markCompleted: completed 必须是布尔值');
  }
  return updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch: { completed },
    allowedColumns: PATCHABLE_COLUMNS,
  });
}

/** 通用 PATCH（当前只有 completed 可用，保留扩展位）。 */
export async function update(client, id, patch = {}, baseVersion) {
  return updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch,
    allowedColumns: PATCHABLE_COLUMNS,
  });
}

/** 软删（复用 deleted_at）。 */
export async function archive(client, id, baseVersion) {
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
}

/** 查单条（含已软删），用于 404 与 409 的现状回传。 */
export async function findByIdIncludingDeleted(client, id) {
  return requireRow(client, TABLE, id, { includeDeleted: true });
}
