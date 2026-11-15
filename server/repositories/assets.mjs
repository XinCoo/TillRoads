// server/repositories/assets.mjs
// 题路 TillRoad · BE-02：assets（外置资产引用）仓储
//
// 与 questions 的关键差异（用户拍板 T2）：
//   * assets **有 version 列**（schema.sql:265，set_updated 触发器维护），
//     但**不走乐观锁** —— 资产是「一次性写入、几乎不改」的引用行，
//     用不到基版号；archive 只按 id + deleted_at IS NULL 软删。
//   * assets 没有 FK：owner_id 是多态引用（owner_type ∈ question/attempt/defect），
//     PG 无法校验，所以「owner 是否存在」由调用方保证（本轮 separateAssets 返回空，
//     等 V1 真正做图片分离时再补 owner 校验）。
//
// storage_key 规范（schema.sql:254-256）：
//   tillroad://{scope}/{owner_type}/{owner_id}/{asset_type}/{uuid}.{ext}
//   scope = local | oss:<bucket>
// 本模块**只存引用**，不碰对象存储；上传由 V1 的资产服务负责。

import { insertRow, listRows, pageParams, requireRow, selectRow } from './_common.mjs';

export const TABLE = 'assets';

export const WRITABLE_COLUMNS = Object.freeze([
  'owner_type',
  'owner_id',
  'storage_key',
  'mime',
  'size_bytes',
]);

const INSERT_COLUMNS = Object.freeze([...WRITABLE_COLUMNS]);

/** owner_type 的合法值（与 schema.sql:69 的 asset_owner 枚举一致）。 */
export const OWNER_TYPES = Object.freeze(['question', 'attempt', 'defect']);

/**
 * 建资产引用。
 * 不做查重：同一道题可以有多张图（题干图、解析图），storage_key 里带 uuid 天然唯一。
 */
export async function create(client, input = {}) {
  if (!input.owner_type) throw new TypeError('assets.create: owner_type 必填');
  if (!OWNER_TYPES.includes(input.owner_type)) {
    throw new TypeError(`assets.create: owner_type 非法（${input.owner_type}）`);
  }
  if (!input.owner_id) throw new TypeError('assets.create: owner_id 必填');
  if (!input.storage_key) throw new TypeError('assets.create: storage_key 必填');

  const values = [
    input.owner_type,
    input.owner_id,
    input.storage_key,
    input.mime ?? null,
    input.size_bytes ?? null,
  ];

  return insertRow(client, TABLE, INSERT_COLUMNS, values);
}

/** 按主键读（软删行视为不存在 -> 404）。 */
export async function getById(client, id) {
  return requireRow(client, TABLE, id);
}

/**
 * 列某 owner 的所有资产（分页）。
 * 走 idx_asset_owner (owner_type, owner_id)，顺序按 created_at, id 稳定排序。
 */
export async function listByOwner(client, ownerType, ownerId, { limit, offset } = {}) {
  const p = pageParams({ limit, offset });
  return listRows(
    client,
    TABLE,
    ['owner_type = $1', 'owner_id = $2', 'deleted_at IS NULL'],
    [ownerType, ownerId],
    p,
  );
}

/**
 * 软删。
 * 不走乐观锁（见文件头）：assets 没有「并发编辑同一行」的业务场景，
 * 传 baseVersion 只会让调用方多维护一个它并不需要的数字。
 * 但仍要求「未软删」才删，重复删返回 404 而不是静默成功 —— 与四表一致。
 */
export async function archive(client, id) {
  const sql = `UPDATE ${TABLE} SET deleted_at = now()
                WHERE id = $1 AND deleted_at IS NULL
                RETURNING *`;
  const { rows } = await client.query(sql, [id]);
  if (rows && rows[0]) return rows[0];
  // 已被软删 / 不存在：统一按未找到处理（includeDeleted 读一次只为给出准确的 404）
  const current = await selectRow(client, TABLE, id, { includeDeleted: true });
  if (!current) {
    const err = new Error(`assets not found: ${id}`);
    err.name = 'NotFoundError';
    err.code = 'not_found';
    err.statusCode = 404;
    err.status = 404;
    err.body = { error: 'not_found', resource: TABLE, id };
    throw err;
  }
  // 已软删：幂等语义下也算「不存在」
  const err = new Error(`assets already archived: ${id}`);
  err.name = 'NotFoundError';
  err.code = 'not_found';
  err.statusCode = 404;
  err.status = 404;
  err.body = { error: 'not_found', resource: TABLE, id, archived: true };
  throw err;
}
