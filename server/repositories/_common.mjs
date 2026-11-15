// server/repositories/_common.mjs
// 题路 TillRoad · BE-01 第 3 步：四表仓储共享原语（内部模块，不对外导出的契约面）
//
// 定位：server/repositories/ 内部的「SQL 拼装 + 乐观锁 + 查重 + 软删」公共实现。
//   四张表（exam_profiles / subjects / knowledge_nodes / capability_layers）的
//   仓储模块都复用这里，避免 5 份几乎相同的 UPDATE / FOR UPDATE / 409 逻辑漂移。
//
// 刻意不 import pg（沿用第 2 步 base.mjs 的鸭子类型约定）：
//   所有函数只依赖传进来的 client 的 query()，因此可用 fake client 单测；
//   集成测试才在真实 PG 上跑。
//
// 首参约定：一律是**同一个事务内的 client**（PoolClient）。
//   * 单条读也可以直接传 pg.Pool（两者都有 query()），但写操作必须在一个 client 上，
//     否则 BEGIN/COMMIT 与写语句会落到不同连接（PG 事务按连接隔离）。
//   * 本模块自己也遇到「写入后再读当前行」的场景，仍沿用同一个 client，保证读到事务内视角。

import { buildUpdateSet, conflictError, queryOne, SYSTEM_COLUMNS } from './base.mjs';

// 透传：四表模块只需要从 _common 拿依赖，不必各自再去 import base.mjs，
// 保证「仓储层对 base 的唯一入口」是 _common（第 2 步约定）。
export { queryOne, queryMany } from './base.mjs';

// ---------------------------------------------------------------------------
// 表名白名单校验
//   本文件里所有表名都来自各仓储模块的硬编码常量，绝不来自请求输入。
//   仍加一道断言：一旦有人把表名改成动态拼接，立刻 fail loud 而不是悄悄注入。
// ---------------------------------------------------------------------------
const IDENT_RE = /^[a-z_][a-z0-9_]*$/;

/**
 * 「空」的统一判定：null / undefined / 纯空白字符串。
 * 与 core/validators.mjs 内部的 isBlank 同义（那边是私有函数、不导出；
 * 本文件刻意不 import core，保持 server 仓储层对 core 的依赖只发生在调用方 / HTTP 层）。
 * 用途：查重时把「未填」排除在唯一性之外（未命名的 target_label 不应互相冲突）。
 */
export function isBlank(v) {
  return v == null || (typeof v === 'string' && v.trim() === '');
}

// ---------------------------------------------------------------------------
// jsonb 列参数处理（BE-01 第 3 步 CI 修复 A）
//   根因**不是**「我们手动 stringify 了一次、驱动又处理一次」（仓储层从未调用
//   JSON.stringify）；而是 pg 驱动的 prepareValue() 先判 Array.isArray()：
//     * JS 数组 -> PG 数组字面量 {"{\"order\":1}"}，jsonb 列解析必失败（22P02
//       `Expected ":", but found ","`）；
//     * JS 对象 -> JSON.stringify，恰好正确；
//     * JS 字符串 -> 原样下发，当作 JSON 文本，也正确。
//   所以对 jsonb 列必须**自己序列化数组/对象**（对象虽侥幸可用，仍统一处理避免歧义）。
//   作用范围是 schema.sql 里全部 jsonb 列，不只 capability_layers.layers。
// ---------------------------------------------------------------------------

export const JSONB_COLUMNS = Object.freeze({
  ai_generation_jobs: Object.freeze(['payload']),
  exam_profiles: Object.freeze(['subject_target', 'source_scope', 'baseline']),
  capability_layers: Object.freeze(['layers']),
  questions: Object.freeze(['options', 'tags', 'generation_meta', 'asset_refs']),
  defect_tickets: Object.freeze(['actions', 'verification_state']),
  mock_exams: Object.freeze(['questions', 'report']),
  review_cycles: Object.freeze(['metrics']),
  plans: Object.freeze(['items']),
});

/** 该表该列是否为 jsonb（表名/列名都来自硬编码常量，不来自请求输入）。 */
export function isJsonbColumn(table, column) {
  const cols = JSONB_COLUMNS[table];
  return Array.isArray(cols) && cols.includes(column);
}

/**
 * jsonb 参数归一：
 *   * null / undefined 原样（NULL 合法，且 undefined 要留给 buildUpdateSet 跳过）；
 *   * 字符串视为「调用方已序列化好的 JSON 文本」，原样下发（二次 stringify 会变成 JSON 字符串字面量，反而错）；
 *   * 其他（数组 / 对象 / 数字 / 布尔）用 JSON.stringify —— 数组是关键，见上方根因。
 */
export function toJsonbParam(value) {
  if (value === null || value === undefined) return value;
  if (typeof value === 'string') return value;
  return JSON.stringify(value);
}

export function assertSafeTable(table) {
  if (typeof table !== 'string' || !IDENT_RE.test(table)) {
    throw new TypeError(`assertSafeTable: 非法表名 ${table}`);
  }
  if (SYSTEM_COLUMNS.includes(table)) {
    throw new TypeError(`assertSafeTable: 表名不得与系统列同名 ${table}`);
  }
  return table;
}

// ---------------------------------------------------------------------------
// 错误构造
//   三者都抛 Error（不是返回 result 对象）——因为它们都是「已通过校验、但数据库层
//   没能完成」的分支，与 core/validators.mjs 的输入校验（返回 result）语义不同。
//   形状对齐 server/index.mjs 现有错误映射：err.code + err.statusCode + err.body。
// ---------------------------------------------------------------------------

/** 404：目标行不存在，或已软删且调用方未要求包含软删行。 */
export function notFoundError(resource, id) {
  const err = new Error(`${resource} not found: ${id}`);
  err.name = 'NotFoundError';
  err.code = 'not_found';
  err.statusCode = 404;
  err.status = 404;
  err.body = { error: 'not_found', resource, id };
  return err;
}

/**
 * 409：业务唯一键冲突（查重失败）。
 * 与乐观锁 conflictError 同为 409，但语义与 body 不同（决策 5）：
 *   { error:'conflict', field, current:{...冲突行}, incoming:{...}, resolution:'user_choice' }
 * resolution='user_choice' 表示「由用户决定怎么处理」（改名 / 覆盖 / 放弃），
 * 与乐观锁的 resolution='client_merge'（客户端合并）明确区分。
 */
export function duplicateError(field, current, incoming) {
  const err = new Error(`${field} duplicated`);
  err.name = 'ConflictError';
  err.code = 'conflict';
  err.statusCode = 409;
  err.status = 409;
  err.body = {
    error: 'conflict',
    field,
    current,
    incoming,
    resolution: 'user_choice',
  };
  return err;
}

/**
 * 400：core/validators.mjs 的校验失败（或本层 gate 判定）转成可抛错误。
 * body 保留 code + message，HTTP 层只需 sendError 即可（err.code 已是稳定令牌）。
 */
export function validationError(result) {
  const err = new Error(result.message || result.code || 'validation failed');
  err.name = 'ValidationError';
  err.code = result.code || 'invalid_input';
  err.statusCode = 400;
  err.status = 400;
  err.body = { error: err.code, message: result.message, fields: result.fields };
  return err;
}

// ---------------------------------------------------------------------------
// 读：单行 / 多行
// ---------------------------------------------------------------------------

/**
 * 按主键读一行。
 * includeDeleted=false（默认）只看未软删行——业务上的「存在」。
 * includeDeleted=true 用于乐观锁冲突时把**软删行**也回给客户端，
 *   否则 archive 冲突会变成「404 + 409 两难」（决策继承第 2 步 SQL 骨架铁律）。
 */
export async function selectRow(client, table, id, { includeDeleted = false } = {}) {
  assertSafeTable(table);
  const sql = includeDeleted
    ? `SELECT * FROM ${table} WHERE id = $1`
    : `SELECT * FROM ${table} WHERE id = $1 AND deleted_at IS NULL`;
  return queryOne(client, sql, [id]);
}

/** getById 的公开语义：不存在或已软删 → 404。 */
export async function requireRow(client, table, id, { includeDeleted = false } = {}) {
  const row = await selectRow(client, table, id, { includeDeleted });
  if (!row) throw notFoundError(table, id);
  return row;
}

/** 列表分页：排序固定 (created_at, id)，保证分页稳定（决策继承第 2 步）。 */
export async function listRows(client, table, whereClauses, params, { limit = 50, offset = 0, orderBy = 'created_at ASC, id ASC' } = {}) {
  assertSafeTable(table);
  const where = whereClauses.length ? `WHERE ${whereClauses.join(' AND ')}` : '';
  const sql = `SELECT * FROM ${table} ${where} ORDER BY ${orderBy} LIMIT $${params.length + 1} OFFSET $${params.length + 2}`;
  return (await client.query(sql, [...params, limit, offset])).rows || [];
}

/** 分页参数归一：非法/缺省一律回落到安全默认值，避免拼出 LIMIT null。 */
export function pageParams({ limit, offset } = {}) {
  const l = Number(limit);
  const o = Number(offset);
  return {
    limit: Number.isInteger(l) && l > 0 && l <= 200 ? l : 50,
    offset: Number.isInteger(o) && o >= 0 ? o : 0,
  };
}

// ---------------------------------------------------------------------------
// 父行加锁（决策 4：同事务查重加锁策略）
//   在父行上 SELECT ... FOR UPDATE，再查子表同名。
//   锁父行而不是锁子表，是因为「同一父下名字唯一」这条业务不变量天然属于父。
//   并发下第二个事务会阻塞在父行锁上，等第一个提交后再查重 -> 稳定的 409，
//   不会出现「两边都查不到、两边都插入」的竞态。
// ---------------------------------------------------------------------------

/**
 * 锁住一行已存在且未软删的父行；不存在 -> 404（而不是静默继续，避免产生孤儿行）。
 * 只 SELECT 主键，避免把父行全部内容读进来。
 */
export async function lockParentRow(client, table, id) {
  assertSafeTable(table);
  const sql = `SELECT id FROM ${table} WHERE id = $1 AND deleted_at IS NULL FOR UPDATE`;
  const row = await queryOne(client, sql, [id]);
  if (!row) throw notFoundError(table, id);
  return row.id;
}

/**
 * 查重：给定「命中即冲突」的 SQL，返回冲突行或 null。
 * excludeId 用于改名场景（排除自己这一行，否则改名成同名会误判）。
 */
export async function findDuplicate(client, sql, params) {
  return queryOne(client, sql, params);
}

// ---------------------------------------------------------------------------
// 写：INSERT / 乐观锁 UPDATE / 软删
// ---------------------------------------------------------------------------

/**
 * INSERT 并返回整行。
 * 列名由各仓储模块以**硬编码数组**传入（columnList），值全部参数化。
 * 这样做而不是「按 input 的键动态拼列」：
 *   * 客户端多传的字段会被忽略/拒绝，不会偷偷写进不该写的列；
 *   * NOT NULL 列即使漏传也由 DB 直接报错，而不是拼出一条缺列 SQL；
 *   * 列集合是模块常量，可被静态审计。
 */
export async function insertRow(client, table, columnList, values, { returning = '*' } = {}) {
  assertSafeTable(table);
  for (const c of columnList) {
    if (!IDENT_RE.test(c)) throw new TypeError(`insertRow: 非法列名 ${c}`);
    if (SYSTEM_COLUMNS.includes(c)) {
      throw new TypeError(`insertRow: 不得显式写系统列 ${c}（由 DEFAULT/触发器维护）`);
    }
  }
  if (columnList.length !== values.length) {
    throw new TypeError(`insertRow: 列数(${columnList.length})与值数(${values.length})不一致`);
  }
  const cols = columnList.map((c) => `"${c}"`).join(', ');
  const holders = columnList.map((_, i) => `$${i + 1}`).join(', ');
  const sql = `INSERT INTO ${table} (${cols}) VALUES (${holders}) RETURNING ${returning}`;
  // jsonb 列统一在这里序列化，调用方（各仓储模块）只管传 JS 数组/对象。
  const boundValues = columnList.map((c, i) => (isJsonbColumn(table, c) ? toJsonbParam(values[i]) : values[i]));
  return queryOne(client, sql, boundValues);
}

/**
 * 乐观锁 UPDATE（决策继承第 2 步 SQL 骨架铁律）：
 *   * SET 永不出现 id/created_at/updated_at/version/deleted_at
 *     （updated_at/version 由 set_updated() 触发器维护，SQL 里手写会被 buildUpdateSet 拒绝）；
 *   * WHERE 恒含 id + version=$base_version + deleted_at IS NULL；
 *   * 0 行受影响 -> 取当前行（**含软删**）并抛 409 conflict，把服务端现状交回客户端合并。
 *
 * 空 patch（或全为 undefined）：直接返回当前行、**不发 UPDATE**（决策 8）。
 *   否则触发器会把 version 无意义地 +1，破坏客户端持有的基版号，
 *   产生「什么都没改却收到 409」的幽灵冲突。
 */
export async function updateWithVersion(client, { table, id, baseVersion, patch, allowedColumns }) {
  assertSafeTable(table);
  if (baseVersion === undefined || baseVersion === null) {
    throw new TypeError('updateWithVersion: baseVersion 必填（乐观锁不允许无基版号写入）');
  }
  // jsonb 列统一在这里序列化（数组必须显式 stringify，否则驱动当 PG 数组下发）
  const boundPatch = {};
  for (const key of Object.keys(patch || {})) {
    boundPatch[key] = isJsonbColumn(table, key) ? toJsonbParam(patch[key]) : patch[key];
  }
  const { setClauses, values } = buildUpdateSet(boundPatch, allowedColumns);
  if (setClauses.length === 0) {
    return requireRow(client, table, id, { includeDeleted: false });
  }

  values.push(id);
  const idIdx = values.length;
  values.push(baseVersion);
  const verIdx = values.length;

  const sql = `UPDATE ${table} SET ${setClauses.join(', ')}
    WHERE id = $${idIdx} AND version = $${verIdx} AND deleted_at IS NULL
    RETURNING *`;
  const row = await queryOne(client, sql, values);
  if (row) return row;

  // 冲突：把服务端当前行（含软删，便于客户端区分「被别人改了」与「已被归档」）交回去
  const current = await selectRow(client, table, id, { includeDeleted: true });
  if (!current) throw notFoundError(table, id);
  throw conflictError(current, baseVersion, 'client_merge');
}

/**
 * 软删（archive）：语义是 deleted_at=now()，与 exam_profiles.status='archived'
 * 的**业务态**明确不同（后者是「目标已归档但仍存在」，前者是「行已删除」）。
 *   * FK 的 ON DELETE CASCADE 对软删**不触发**，所以子树级联软删必须在
 *     server 层用同一个 withTransaction 自己打 tombstone（第 4 步编排，本步不做）。
 */
export async function archiveWithVersion(client, { table, id, baseVersion }) {
  assertSafeTable(table);
  if (baseVersion === undefined || baseVersion === null) {
    throw new TypeError('archiveWithVersion: baseVersion 必填（乐观锁不允许无基版号写入）');
  }
  const sql = `UPDATE ${table} SET deleted_at = now()
    WHERE id = $1 AND version = $2 AND deleted_at IS NULL
    RETURNING *`;
  const row = await queryOne(client, sql, [id, baseVersion]);
  if (row) return row;

  const current = await selectRow(client, table, id, { includeDeleted: true });
  if (!current) throw notFoundError(table, id);
  throw conflictError(current, baseVersion, 'client_merge');
}
