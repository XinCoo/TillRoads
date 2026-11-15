// server/repositories/base.mjs
// 题路 TillRoad · BE-01 第 2 步：通用 PG 仓储工具函数集 + withTransaction
//
// 定位：server/ 侧仓储基础设施。刻意**不 import pg** —— 所有函数只依赖「传进来的
// client / pool 对象」的鸭子类型接口（query()/connect()/release()），因此：
//   * 可以用 fake pool / fake client 做零 PG 的逻辑层单测；
//   * 与 core/ 的端无关定位不冲突（core 完全不认识 SQL）。
// 形态（已拍板）：不做类继承 / BaseRepository 类，做纯工具函数集。JS 无类型系统，
// 类继承收益低；工具函数易单测、易组合、易在同一事务内被不同仓储方法复用。
//
// 首参一律是 client（PoolClient）：create/update/archive 等仓储方法把同一个 client
// 串在一次 withTransaction 里，天然支持 BE-01 设计 §4 的三类事务。

// ---------------------------------------------------------------------------
// 系统列：由 DB / set_updated() 触发器维护，patch 永远不得写入。
// 依据 schema.sql 同步列约束（:618-625）与 set_updated()（:468-476）：
//   created_at / updated_at 默认 now()，version 由触发器 OLD.version+1，
//   deleted_at 是软删标记（archive 走专用方法），id 是主键。
// ---------------------------------------------------------------------------
export const SYSTEM_COLUMNS = Object.freeze([
  'id', 'created_at', 'updated_at', 'version', 'deleted_at',
]);

// SQLSTATE → HTTP 映射表（导出供单测与第 3 步查重时参考）
//   err.code 是 pg 放 SQLSTATE 的位置；映射后另存到 sqlState 保留原值。
export const SQLSTATE_MAP = Object.freeze({
  '23503': Object.freeze({ status: 404, code: 'foreign_key_not_found', message: '关联记录不存在（外键约束失败）' }),
  '22P02': Object.freeze({ status: 400, code: 'invalid_input_syntax', message: '输入类型解析失败' }),
  '23505': Object.freeze({ status: 409, code: 'unique_violation', message: '唯一约束冲突' }),
});

// ---------------------------------------------------------------------------
// 事务边界
//
// 必须用 withTransaction 的场景：
//   ① create exam_profile + 预置默认 subjects（AC-KM-01，多表 INSERT 要么全成要么全败）；
//   ② 自定义能力层级副本 + subject 重指向 layer_template_id（AC-KM-02）；
//   ③ 级联软删（FK ON DELETE CASCADE 对软删不触发，须同事务给整棵子树打 tombstone）；
//   ④ 同事务查重 + 写入（弥补四表无业务唯一约束的缺口，见 REVIEW-NOTES §8）。
// 不需要事务的场景：单条 SELECT（getById / list）、单表单行 INSERT/UPDATE。
//   这些用 pool.query() 即可（自动 checkout/release），别滥用事务增加往返。
// ---------------------------------------------------------------------------

/**
 * withTransaction(pool, fn) -> Promise<any>
 *
 * BEGIN → fn(client) → COMMIT；任何异常 → ROLLBACK；finally 必释放 client。
 * 首参传给 fn 的是同一个 PoolClient，保证事务内所有语句落在同一连接上
 * （PG 事务是按连接隔离的，不能混用 pool.query()）。
 * 返回值 = fn 的返回值，便于仓储方法直接 RETURNING * 的结果往外传。
 * @param {{connect: () => Promise<{query: Function, release: Function}>}} pool
 * @param {(client: {query: Function}) => Promise<any>} fn
 */
export async function withTransaction(pool, fn) {
  if (!pool || typeof pool.connect !== 'function') {
    throw new TypeError('withTransaction: pool 必须提供 connect()');
  }
  if (typeof fn !== 'function') {
    throw new TypeError('withTransaction: fn 必须是函数');
  }
  const client = await pool.connect();
  let begun = false;
  try {
    await client.query('BEGIN');
    begun = true;
    const result = await fn(client);
    await client.query('COMMIT');
    begun = false;
    return result;
  } catch (err) {
    if (begun) {
      try {
        await client.query('ROLLBACK');
      } catch (rollbackErr) {
        // 回滚失败不得掩盖原始异常：挂到原异常上，仍抛原异常
        err.rollbackError = rollbackErr;
      }
    }
    throw err;
  } finally {
    client.release();
  }
}

// ---------------------------------------------------------------------------
// 查询薄封装：只负责「执行 + 取行」，不做错误映射（映射留给上层边界统一处理）。
// ---------------------------------------------------------------------------

/** queryOne(client, sql, params?) -> 首行对象；无行返回 null */
export async function queryOne(client, sql, params = []) {
  const res = await client.query(sql, params);
  const rows = (res && res.rows) || [];
  return rows.length > 0 ? rows[0] : null;
}

/** queryMany(client, sql, params?) -> 行数组（无行返回 []） */
export async function queryMany(client, sql, params = []) {
  const res = await client.query(sql, params);
  return (res && res.rows) || [];
}

// ---------------------------------------------------------------------------
// 409 乐观锁冲突
//
// 与 server/index.mjs 的 conflictBody(v) 逐字段对齐：
//   { error:'conflict', current, incoming, resolution:'client_merge' }
// 区别仅在于这里返回的是「可抛出的 Error」，并把 body 挂在 err.body 上，
// 供 HTTP 层 json(res, 409, err.body)。resolution 默认 'client_merge'，
// 故 conflictError(current, incoming) 得到的 body 与现有 409 完全一致。
// ---------------------------------------------------------------------------
export function conflictError(current, incoming, resolution = 'client_merge') {
  const err = new Error('optimistic lock conflict');
  err.name = 'ConflictError';
  err.statusCode = 409;
  err.status = 409;            // 兼容两种读取习惯
  err.code = 'conflict';
  err.body = { error: 'conflict', current, incoming, resolution };
  return err;
}

// ---------------------------------------------------------------------------
// SQLSTATE → 应用错误。映射命中→新 Error（带 statusCode/code/body/sqlState/cause）；
// 未命中→**原样返回同一个 err 引用**（其它错误交给上层通用处理，不擅自改写）。
// ---------------------------------------------------------------------------
export function mapPgError(err) {
  if (!err || typeof err !== 'object') return err;
  const entry = SQLSTATE_MAP[err.code];   // pg 把 SQLSTATE 放在 err.code
  if (!entry) return err;
  const mapped = new Error(entry.message || err.message);
  mapped.name = 'PgMappedError';
  mapped.statusCode = entry.status;
  mapped.status = entry.status;
  mapped.code = entry.code;              // 稳定机器令牌，供 400/404/409 与前端 i18n
  mapped.sqlState = err.code;            // 保留原 SQLSTATE，便于排障
  mapped.body = { error: entry.code, message: entry.message || err.message };
  mapped.cause = err;
  return mapped;
}

// ---------------------------------------------------------------------------
// buildUpdateSet(patch, allowedColumns) -> { setClauses: string[], values: any[] }
//
// 防注入三道闸（列名永远不来自外部输入）：
//   ① allowedColumns 是各仓储方法内硬编码的白名单；本函数还校验其每个元素
//      必须是合法标识符、且不得含 SYSTEM_COLUMNS，防止调用方配错白名单绕过保护；
//   ② patch 的每个键：命中 SYSTEM_COLUMNS → 抛错；非法标识符 → 抛错；
//      不在白名单 → 抛错（fail loud，避免「以为改了其实被静默丢弃」）；
//   ③ 值一律参数化为 $N，SQL 文本里只出现「白名单列名 + 占位符」，
//      绝不拼接任何外部字符串。
// 约定：值为 undefined 的键视为「未提供」跳过（HTTP partial patch 常见）；
//       null 是合法值（表示置 NULL），会照常参数化。
// 返回：空 patch（或全为 undefined）→ { setClauses: [], values: [] }，
//       调用方见空数组应直接跳过 UPDATE（或改走其它分支），不要拼出非法 SQL。
// ---------------------------------------------------------------------------
const IDENT_RE = /^[a-z_][a-z0-9_]*$/;

function isSafeIdentifier(name) {
  return typeof name === 'string' && IDENT_RE.test(name);
}

function toColumnSet(cols) {
  if (cols instanceof Set) return new Set(cols);
  if (Array.isArray(cols)) return new Set(cols);
  return new Set();
}

export function buildUpdateSet(patch, allowedColumns) {
  const allowed = toColumnSet(allowedColumns);
  // 闸①：校验白名单本身
  for (const c of allowed) {
    if (!isSafeIdentifier(c)) {
      throw new TypeError(`buildUpdateSet: allowedColumns 含非法列名 ${c}`);
    }
    if (SYSTEM_COLUMNS.includes(c)) {
      throw new TypeError(`buildUpdateSet: allowedColumns 不得包含系统列 ${c}`);
    }
  }

  const source = patch && typeof patch === 'object' && !Array.isArray(patch) ? patch : {};
  const setClauses = [];
  const values = [];
  for (const key of Object.keys(source)) {
    if (SYSTEM_COLUMNS.includes(key)) {
      throw new TypeError(`buildUpdateSet: 禁止写入系统列 ${key}（由 DB/触发器维护）`);
    }
    if (!isSafeIdentifier(key)) {
      throw new TypeError(`buildUpdateSet: 非法列名 ${key}`);
    }
    if (!allowed.has(key)) {
      throw new TypeError(`buildUpdateSet: 列 ${key} 不在白名单内`);
    }
    const value = source[key];
    if (value === undefined) continue;
    values.push(value);
    // 双引号包裹合法标识符：可兼容日后出现的保留字列名，且 IDENT_RE 保证无引号可注入
    setClauses.push(`"${key}" = $${values.length}`);
  }
  return { setClauses, values };
}
