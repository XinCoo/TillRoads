// server/repositories/subjects.mjs
// 题路 TillRoad · BE-01 第 3 步：subjects（科目）仓储
//
// 决策 4（同事务查重加锁）：创建/改名先锁**父行 exam_profiles**，
//   再查同 exam_profile_id 下 name 是否重复。
//   锁父行而非锁子表：PG 没有「锁住一个不存在的键」的能力（那需要 advisory lock），
//   而「同一目标下科目名唯一」的作用域天然是父行，锁它即可让并发 create 串行化。

import {
  archiveWithVersion,
  duplicateError,
  findDuplicate,
  insertRow,
  isBlank,
  listRows,
  lockParentRow,
  pageParams,
  requireRow,
  updateWithVersion,
} from './_common.mjs';

export const TABLE = 'subjects';

// 可写列白名单：
//   * exam_profile_id 只出现在 INSERT —— 科目换归属等于换一条记录，不在 update 语义内；
//   * layer_template_id 可在 update 里改（第 4 步 AC-KM-02 自定义副本会重指向它）。
export const WRITABLE_COLUMNS = Object.freeze(['name', 'kind', 'layer_template_id']);
export const INSERT_COLUMNS = Object.freeze(['exam_profile_id', ...WRITABLE_COLUMNS]);

/**
 * 查重：同 exam_profile_id 下 name 重复。
 * name 是 NOT NULL 列，理论上不会空；仍用 isBlank 兜一层，避免空串绕过唯一性。
 */
async function findNameConflict(client, examProfileId, name, excludeId = null) {
  if (isBlank(name)) return null;
  const params = [examProfileId, name];
  let sql = `SELECT * FROM ${TABLE}
              WHERE exam_profile_id = $1 AND name = $2 AND deleted_at IS NULL`;
  if (excludeId) {
    params.push(excludeId);
    sql += ` AND id <> $3`;
  }
  return findDuplicate(client, sql, params);
}

/**
 * 创建科目。
 * 先锁 exam_profiles 行 -> 父不存在/已软删直接 404（不产生孤儿科目），
 * 再查重 -> 冲突 409 {field:'name'}。
 */
export async function create(client, input = {}) {
  const examProfileId = input.exam_profile_id;
  if (!examProfileId) throw new TypeError('subjects.create: exam_profile_id 必填');

  await lockParentRow(client, 'exam_profiles', examProfileId);

  const dup = await findNameConflict(client, examProfileId, input.name);
  if (dup) throw duplicateError('name', dup, { name: input.name });

  return insertRow(client, TABLE, INSERT_COLUMNS, [
    examProfileId,
    input.name,
    input.kind,
    input.layer_template_id ?? null,
  ]);
}

export async function getById(client, id) {
  return requireRow(client, TABLE, id);
}

/** 列某目标下的科目（分页、稳定排序）。 */
export async function listByProfile(client, examProfileId, { limit, offset } = {}) {
  const p = pageParams({ limit, offset });
  return listRows(
    client,
    TABLE,
    ['exam_profile_id = $1', 'deleted_at IS NULL'],
    [examProfileId],
    p,
  );
}

/**
 * 更新（乐观锁）。
 * 只有 patch 含 name 时才需要锁父行 + 查重（排除自己）；
 * 只改 kind / layer_template_id 不触及唯一性，不必加锁，减少争用。
 */
export async function update(client, id, patch = {}, baseVersion) {
  const current = await requireRow(client, TABLE, id);

  if (Object.prototype.hasOwnProperty.call(patch, 'name')) {
    await lockParentRow(client, 'exam_profiles', current.exam_profile_id);
    const dup = await findNameConflict(client, current.exam_profile_id, patch.name, id);
    if (dup) throw duplicateError('name', dup, { name: patch.name });
  }

  return updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch,
    allowedColumns: WRITABLE_COLUMNS,
  });
}

export async function archive(client, id, baseVersion) {
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
}
