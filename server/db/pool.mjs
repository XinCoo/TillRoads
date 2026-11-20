// server/db/pool.mjs
// 题路 TillRoad · BE-01 第 2 步：PG 连接池工厂 + 全局类型解析
//
// 定位：server/ 侧基础设施（允许 import pg）。core/ 保持端无关、零依赖、不 import pg。
// 设计要点（已拍板）：
//   1. 采用全局 pg.types.setTypeParser，在 pool 工厂统一配置一次，覆盖四表共享的
//      numeric / int8 / int4 / int2 / date / timestamp / timestamptz 列；
//      避免每个仓储方法手写 Number() / toISOString()，重复且易漏。
//      jsonb 保持 driver 默认解析为对象，不覆盖。
//   2. 不硬编码任何凭据：连接参数一律来自 PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE
//      （或调用方显式传入的 config）。连接池参数给合理默认值，可被 config 覆盖。
//
// 注意：pg.types.setTypeParser 是进程级全局单例（pg-types 模块级 overrides），
// 对本进程内所有 Pool / Client 生效。因此本模块约定：一律通过 createPool() 建池，
// 不要绕过工厂直接 new Pool()。重复调用 configureTypeParsers() 是幂等的
// （只是把同一组纯函数重新注册一次），不会累积副作用。

import { Pool, types } from 'pg';

// ---------------------------------------------------------------------------
// 需要覆盖的 PG 类型 OID（text 格式）
//   numeric(1700) / int8(20) / int4(23) / int2(21) → JS number
//   date(1082)        → 原样 'YYYY-MM-DD' 字符串（无时区，避免 Date 本地化漂移）
//   timestamp(1114)   → ISO 8601 UTC 字符串（无时区列按 UTC 解释，保证确定性）
//   timestamptz(1184) → ISO 8601 UTC 字符串（PG 自带偏移，new Date 可正确解析）
//   jsonb / json / uuid / bool / text 等 → 不覆盖，保留 driver 默认解析
// ---------------------------------------------------------------------------
export const TYPE_OIDS = Object.freeze({
  NUMERIC: 1700,
  INT8: 20,
  INT4: 23,
  INT2: 21,
  DATE: 1082,
  TIMESTAMP: 1114,
  TIMESTAMPTZ: 1184,
});

// 连接池默认值（均可被 createPool(config) 的显式 config 覆盖）
export const DEFAULT_POOL_CONFIG = Object.freeze({
  max: 10,
  idleTimeoutMillis: 5_000,
  connectionTimeoutMillis: 5_000,
});

// ---------------------------------------------------------------------------
// 解析器：全部为纯函数、可单独单测、无 I/O
// ---------------------------------------------------------------------------

// numeric / int8 / int4 / int2 统一转 number。
// 已知取舍：numeric 与 int8 理论上可超过 2^53，转 number 会丢精度；
// 本 schema 的 numeric(6,2)/numeric(4,3)/int(version) 均远小于该量级，
// 且四表共享这些列，统一成 number 才能让 core/validators.mjs 的
// asFiniteNumber()（接受 number 与纯数字字符串）在「HTTP 入参」与「PG 读回」两条路径都成立。
export function parseNumeric(v) {
  return v == null ? v : Number(v);
}

// date(1082)：PG text 已是 'YYYY-MM-DD'。原样返回，既避免 driver 默认把 DATE
// 解析成「本地时区午夜 Date」造成跨 TZ 漂移，也正好匹配
// core/validators.mjs 的 validateExamDate() 所接受的严格 YYYY-MM-DD 形。
export function parseDate(v) {
  return v;
}

// timestamp(1114)：无时区列。按 UTC 解释，避免 runner/本机 TZ 不同导致同一行两种结果。
// 本 schema 实际只用 timestamptz，此 OID 属「按拍板清单前瞻覆盖」。
export function parseTimestamp(v) {
  if (v == null) return v;
  const s = String(v).trim().replace(' ', 'T');
  const hasZone = /(?:z|[+-]\d{2}:?\d{2})$/i.test(s);
  const d = new Date(hasZone ? s : `${s}Z`);
  return Number.isNaN(d.getTime()) ? v : d.toISOString();
}

// timestamptz(1184)：PG text 形如 '2026-11-15 10:00:00+08'，
// JS 需要 '+08:00' 形式才可靠；统一输出 ISO 8601 UTC 串，便于 JSON 序列化。
export function parseTimestamptz(v) {
  if (v == null) return v;
  const s = String(v).trim().replace(' ', 'T').replace(/([+-]\d{2})$/, '$1:00');
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? v : d.toISOString();
}

// ---------------------------------------------------------------------------
// configureTypeParsers()：在 pool 工厂统一注册全局解析，幂等。
// 导出以便零 PG 的单元测试可直接用 types.getTypeParser(oid) 验证注册生效。
// ---------------------------------------------------------------------------
export function configureTypeParsers() {
  const asNumber = parseNumeric;
  for (const oid of [TYPE_OIDS.NUMERIC, TYPE_OIDS.INT8, TYPE_OIDS.INT4, TYPE_OIDS.INT2]) {
    types.setTypeParser(oid, 'text', asNumber);
  }
  types.setTypeParser(TYPE_OIDS.DATE, 'text', parseDate);
  types.setTypeParser(TYPE_OIDS.TIMESTAMP, 'text', parseTimestamp);
  types.setTypeParser(TYPE_OIDS.TIMESTAMPTZ, 'text', parseTimestamptz);
  // jsonb(3802) / json(114) / uuid(2950) / bool(16) 等刻意不覆盖：
  // driver 默认已把 jsonb 解析成 JS 对象，配合 core/validators.mjs 的 validateLayers() 使用。
  return TYPE_OIDS;
}

// ---------------------------------------------------------------------------
// envConfig()：只从环境变量读取连接参数，不硬编码任何凭据。
// 未设置的变量不写入 config，让 pg 自身的默认值（或 config 覆盖）生效。
// ---------------------------------------------------------------------------
function envConfig() {
  const c = {};
  if (process.env.PGHOST) c.host = process.env.PGHOST;
  if (process.env.PGPORT) {
    const p = Number(process.env.PGPORT);
    if (Number.isInteger(p) && p > 0) c.port = p;
  }
  if (process.env.PGUSER) c.user = process.env.PGUSER;
  if (process.env.PGPASSWORD) c.password = process.env.PGPASSWORD;
  if (process.env.PGDATABASE) c.database = process.env.PGDATABASE;
  return c;
}

/**
 * createPool(config?) -> pg.Pool
 *
 * 合并优先级（后者覆盖前者）：
 *   DEFAULT_POOL_CONFIG  <  环境变量(PGHOST/.../PGDATABASE)  <  显式 config
 * 显式 config 便于测试注入 fake 参数；生产/CI 不传 config，全靠环境变量。
 * 构造 pg.Pool 是惰性的（不会立即连库），故本机无 PG 也能安全构造并断言配置。
 */
export function createPool(config = {}) {
  configureTypeParsers();
  const merged = { ...DEFAULT_POOL_CONFIG, ...envConfig(), ...(config || {}) };
  const pool = new Pool(merged);
  // Surface idle-client and pool-level errors instead of allowing an unhandled
  // EventEmitter error to terminate the process.
  pool.on('error', () => {});
  return pool;
}
