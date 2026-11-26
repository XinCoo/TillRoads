// 临时：把 PGlite 包成 pg.Pool 的最小形状，供集成测试在本机（无 PG）跑真实 plpgsql / 触发器。
// 用完即删；不要提交，也不要写进 package.json。
import { PGlite } from '@electric-sql/pglite';

let dbPromise = null;

function getDb() {
  if (!dbPromise) {
    dbPromise = (async () => {
      const db = new PGlite();
      await db.waitReady;
      return db;
    })();
  }
  return dbPromise;
}

async function exec(text, params) {
  const db = await getDb();
  const hasParams = Array.isArray(params) && params.length > 0;
  // 多语句只能走 exec（简单查询协议）；预处理语句不允许一次多条命令（42601）。
  if (!hasParams && /;\s*\S/.test(text)) {
    await db.exec(text);
    return { rows: [], rowCount: 0, affectedRows: 0 };
  }
  const res = await db.query(text, params ?? []);
  const rows = res.rows ?? [];
  const rowCount = rows.length > 0 ? rows.length : (res.affectedRows ?? 0);
  return { rows, rowCount, affectedRows: res.affectedRows ?? 0 };
}

const client = {
  query: (text, params) => exec(text, params),
  release: () => {},
};

export function createPool() {
  // ★ 必须同步返回：测试里 `pool = createPool()` 之后立刻用，async 会拿到 Promise。
  return {
    query: (text, params) => exec(text, params),
    connect: async () => client,
    end: async () => {},
    on: () => {},
  };
}

export const __pool = createPool;
