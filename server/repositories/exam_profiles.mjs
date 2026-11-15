// server/repositories/exam_profiles.mjs
// 题路 TillRoad · BE-01 第 3 步：exam_profiles（考试目标与约束）仓储
//
// 组织方式（交付说明第 1 项）：**每表一个独立模块**，不用工厂函数。
//   理由：四表的可写列白名单、查重父行、getTree / customizable gate 各不相同；
//   工厂函数会把「表名 + 列 + 特例分支」塞进同一处，静态审计可写列时反而更难。
//   独立模块 = 每张表的白名单是一个可 grep 的常量，改错表也改不到别的表。
//
// 事务契约：create / update / archive **必须**在调用方的 withTransaction 内执行，
//   因为「锁父行 → 查重 → 写入」必须是同一事务同一连接（见 _common.mjs 顶部注释）。
//   getById / list* 是单条读，可直接传 pool（两者都有 query()）。
//
// core 校验：调用方在传进来之前先用 core/validators.mjs 校验（V1/V4/V5/V6/V8/V11），
//   本模块不重复做值域校验，只做「DB 才能判定」的事：FK 存在性、乐观锁、软删、查重。

import {
  archiveWithVersion,
  duplicateError,
  insertRow,
  listRows,
  lockParentRow,
  pageParams,
  requireRow,
  updateWithVersion,
  findDuplicate,
  isBlank,
} from './_common.mjs';

export const TABLE = 'exam_profiles';

// 可写列白名单（INSERT 与 UPDATE 共用一份）：
//   * 不含 id / created_at / updated_at / version / deleted_at（系统列，由 DEFAULT/触发器维护）；
//   * 不含 user_id —— 归属不可变，换用户等于换一条记录，不在 update 语义内。
export const WRITABLE_COLUMNS = Object.freeze([
  'exam_type',
  'target_label',
  'target_score',
  'subject_target',
  'exam_date',
  'daily_minutes',
  'source_scope',
  'baseline',
  'status',
]);

const INSERT_COLUMNS = Object.freeze(['user_id', ...WRITABLE_COLUMNS]);

function duplicateLabelError(current, incoming) {
  return duplicateError('target_label', current, incoming);
}

/**
 * 查重（决策 4）：同一 user 下 target_label 重复。
 * target_label 可空——空值不参与查重（否则「未命名目标」会互相冲突，毫无意义）。
 * 调用方需已在本事务内对 users 行加锁（见 create / update）。
 */
async function findLabelConflict(client, userId, targetLabel, excludeId = null) {
  if (isBlank(targetLabel)) return null;
  const params = [userId, targetLabel];
  let sql = `SELECT * FROM ${TABLE}
              WHERE user_id = $1 AND target_label = $2 AND deleted_at IS NULL`;
  if (excludeId) {
    params.push(excludeId);
    sql += ` AND id <> $3`;
  }
  return findDuplicate(client, sql, params);
}

/**
 * 创建目标配置。
 * 加锁对象是 **users 行**（决策 4：exam_profiles 创建对 users 行加锁）——
 * 因为「同一用户下 target_label 唯一」这条不变量的作用域是 user，
 * 锁 user 行才能让两个并发 create 串行化；去锁 exam_profiles 表没有可锁的锚点。
 */
export async function create(client, input = {}) {
  const userId = input.user_id;
  if (!userId) throw new TypeError('exam_profiles.create: user_id 必填');

  await lockParentRow(client, 'users', userId);

  const dup = await findLabelConflict(client, userId, input.target_label);
  if (dup) throw duplicateLabelError(dup, { target_label: input.target_label });

  const values = [
    input.exam_type,
    input.target_label ?? null,
    input.target_score ?? null,
    input.subject_target ?? null,
    input.exam_date ?? null,
    input.daily_minutes ?? null,
    input.source_scope ?? null,
    input.baseline ?? null,
    // 列 NOT NULL DEFAULT 'active'：显式给值，不依赖 DEFAULT，避免 insertRow 拼出缺列
    input.status ?? 'active',
  ];

  return insertRow(client, TABLE, INSERT_COLUMNS, [userId, ...values]);
}

/** 按主键读（软删行视为不存在 -> 404）。 */
export async function getById(client, id) {
  return requireRow(client, TABLE, id);
}

/** 列某用户的目标配置（分页，稳定排序）。 */
export async function listByUser(client, userId, { limit, offset } = {}) {
  const p = pageParams({ limit, offset });
  return listRows(client, TABLE, ['user_id = $1', 'deleted_at IS NULL'], [userId], p);
}

/**
 * 更新（乐观锁）。
 * 若 patch 触及 target_label，则按决策 4 先锁 users 行再查重（排除自己，否则改名撞自己）。
 * 注意：锁用 current.user_id（归属不可变），不用 patch 里的任何 user 字段。
 */
export async function update(client, id, patch = {}, baseVersion) {
  const current = await requireRow(client, TABLE, id);

  if (Object.prototype.hasOwnProperty.call(patch, 'target_label')) {
    await lockParentRow(client, 'users', current.user_id);
    const dup = await findLabelConflict(client, current.user_id, patch.target_label, id);
    if (dup) throw duplicateLabelError(dup, { target_label: patch.target_label });
  }

  return updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch,
    allowedColumns: WRITABLE_COLUMNS,
  });
}

/**
 * 软删。
 * 与 status='archived' 的**业务态**不同：archived 是「目标归档但仍可查」，
 * archive() 是「行删除」。两者都保留，由调用方选语义。
 */
export async function archive(client, id, baseVersion) {
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
}
