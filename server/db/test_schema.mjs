// server/db/test_schema.mjs
// 集成测试用的「完整 schema」加载器。
//
// 为什么需要它（m17431）：
//   schema.sql 是**基线** schema，0001 迁移只是它的 \ir 包装。
//   m17431 之后 schema 解冻：新增的 owner_user_id 列不在 schema.sql 里，
//   而在 migrations/0002_questions_owner.sql 里。
//   集成测试要连真库，所以必须把「基线 + 所有增量迁移」都执行一遍，
//   否则用到新列的 SQL 会报 42703 column does not exist。
//
// 用法：
//   import { applyFullSchema } from './test_schema.mjs';
//   await applyFullSchema(client);
//
// 注意：这个文件只在测试里用，不要被生产代码 import。

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');

/** 基线 schema（纯 SQL，无 psql 元命令）。 */
export const SCHEMA_SQL = readFileSync(join(ROOT, 'schema.sql'), 'utf8');

/**
 * 增量迁移（按顺序）。都是幂等的纯 SQL。
 * 新增迁移时把文件加进这个数组即可 —— 顺序即执行顺序。
 */
export const MIGRATION_FILES = Object.freeze([
  'migrations/0002_questions_owner.sql',
  'migrations/0003_practice.sql',
  'migrations/0004_question_mastery.sql',
  'migrations/0005_question_hidden.sql',
  'migrations/0006_exam_custom_defect_questions.sql',
]);

const MIGRATION_SQL = MIGRATION_FILES.map((f) => ({
  file: f,
  sql: readFileSync(join(ROOT, f), 'utf8'),
}));

/** 全部 DDL 拼成一个字符串（node-postgres 无参数时走简单查询协议，可一次执行）。 */
export const FULL_SCHEMA_SQL = [
  SCHEMA_SQL,
  ...MIGRATION_SQL.map((m) => m.sql),
].join('\n');

/**
 * 在给定 client 上执行「基线 + 增量迁移」。
 * @param {{query: Function}} client pg PoolClient / Pool
 */
export async function applyFullSchema(client) {
  await client.query(FULL_SCHEMA_SQL);
}
