// server/repositories/questions.mjs
// 题路 TillRoad · BE-02：questions（题库）仓储
//
// 与四表仓储同形：首参 client（供调用方在 withTransaction 内使用）、乐观锁、软删。
// 差异只有一处：questions 有 content_hash 业务唯一键（schema 上**没有** UNIQUE 约束，
//   见 REVIEW-NOTES §8「四表无业务唯一约束」的同类问题），所以查重必须在仓储层做，
//   且必须与写入在同一事务里 —— 否则两个并发导入同一份文件会双双通过查重。
//
// import 方向说明：本模块从 core/index.mjs 取 normalizeQuestionText，不重复实现归一化。
//   同一道题在 schema.sql（normalize_question_text）、Node 规则层、导入管线里
//   必须算出同一个 hash，只允许有一处归一化实现。

import {
  archiveWithVersion,
  duplicateError,
  findDuplicate,
  insertRow,
  listRows,
  pageParams,
  requireRow,
  updateWithVersion,
} from './_common.mjs';
import { normalizeQuestionText } from '../../core/index.mjs';
import { masteryFilterClause } from './question_mastery.mjs';

export const TABLE = 'questions';

// 可写列白名单（INSERT 与 UPDATE 共用）：
//   * 不含 id / created_at / updated_at / version / deleted_at（系统列）；
//   * content_hash 在列内（NOT NULL 且无 DEFAULT），但**只能由 create/update 内部计算**，
//     调用方传什么都会被覆盖 —— 见 computeHash 的用法。
export const WRITABLE_COLUMNS = Object.freeze([
  'source',
  'subject_id',
  'knowledge_node_id',
  'type',
  'stem',
  'options',
  'answer',
  'analysis',
  'formula_text',
  'difficulty',
  'tags',
  'generation_meta',
  'content_hash',
  'asset_refs',
  'is_subjective',
  // 归属用户（m17431）：NULL = 公共题（seed / 系统题），非 NULL = 用户私有题。
  // 查重与组卷抽题都按这一列分域，见 findHashConflict 的注释。
  'owner_user_id',
]);

/**
 * UPDATE 允许列（乐观锁）。
 *
 * 刻意**不含** owner_user_id：归属是「谁导进来的」，只能由服务端按 token 决定，
 * 不允许客户端 PATCH 把它改成别人的 id（否则就能「认领」别人的题）。
 */
const UPDATE_COLUMNS = Object.freeze(
  WRITABLE_COLUMNS.filter((c) => c !== 'owner_user_id'),
);

const INSERT_COLUMNS = Object.freeze([...WRITABLE_COLUMNS]);

/**
 * 一题的 content_hash。
 *
 * 复用 core/index.mjs 的 normalizeQuestionText：全角标点归一、顿号→逗号、
 * 去空白、选项稳定排序后 sha256。所以「选项顺序不同、标点全半角不同」的同一道题
 * 会得到同一个 hash —— 这正是 AC-Q-02 要的「同 hash 提示合并」。
 *
 * 导出它的原因：server/import/dedupe.mjs 也要用同一个定义，不能各写一份。
 */
export function contentHashOf(question = {}) {
  return normalizeQuestionText(
    question.stem ?? '',
    question.options ?? null,
    question.formula_text ?? question.formula ?? null,
  );
}

/**
 * 409：content_hash 已存在。
 *
 * 为什么不用 duplicateError 默认的 code='conflict'：
 *   客户端需要对「导入去重」做专门提示（跳过这题 / 查看已有题），
 *   与「改名撞名」这类冲突的处理动作不同。所以 body.error 用 DUPLICATE_QUESTION
 *   这个稳定令牌，其余字段（field/current/incoming/resolution）保持与
 *   duplicateError 完全一致，客户端不必为它写第二套解析。
 */
function duplicateQuestionError(current, incoming) {
  const err = duplicateError('content_hash', current, incoming);
  err.code = 'DUPLICATE_QUESTION';
  err.body = { ...err.body, error: 'DUPLICATE_QUESTION' };
  return err;
}

/**
 * 查同 hash 的未软删行（返回整行，便于 409 body 里带上已有题让客户端展示）。
 *
 * ★ m17431：查重**按 owner 分域**。
 *   - ownerUserId 非空（用户导入的题）：只在**该用户自己**的题里查重
 *     `owner_user_id = $2`。这样用户 A 导入过的题，用户 B 导入同一份文件不会
 *     被判重 —— 否则题库就变成「第一个人的题库」。
 *   - ownerUserId 为空（公共题 / seed 数据）：只在公共题里查重
 *     `owner_user_id IS NULL`；公共题不参与用户去重。
 *   - 公共题对所有用户可见，所以用户导入的题与公共题同 hash 也不算重复
 *     （用户可以有自己的副本，组卷时抽到哪份都不影响正确性）。
 */
async function findHashConflict(client, contentHash, ownerUserId = null) {
  const sql = ownerUserId
    ? `SELECT * FROM ${TABLE}
        WHERE content_hash = $1 AND deleted_at IS NULL AND owner_user_id = $2`
    : `SELECT * FROM ${TABLE}
        WHERE content_hash = $1 AND deleted_at IS NULL AND owner_user_id IS NULL`;
  const params = ownerUserId ? [contentHash, ownerUserId] : [contentHash];
  return findDuplicate(client, sql, params);
}
/**
 * 建题。
 *
 * 调用方（导入端点 / 手动建题）需已用 core/validators.mjs 校验过枚举与必填，
 * 本模块只做「DB 才能判定」的事：查重、FK 存在性（交给 PG 的 23503）、写入。
 *
 * 必须在 withTransaction 内调用：查重与插入要同一事务，
 * 否则并发导入同一份文件会有两条同 hash 记录。
 */
export async function create(client, input = {}) {
  if (!input.source) throw new TypeError('questions.create: source 必填');
  if (!input.type) throw new TypeError('questions.create: type 必填');
  if (!input.stem || String(input.stem).trim() === '') {
    throw new TypeError('questions.create: stem 必填');
  }

  const contentHash = contentHashOf(input);

  // owner_user_id 由调用方（导入路由）传入，且只认 token 映射出来的 userId，
  // 不信任请求体里的 user_id（m17431 A4）。
  const ownerUserId = input.owner_user_id ?? null;
  const dup = await findHashConflict(client, contentHash, ownerUserId);
  if (dup) {
    throw duplicateQuestionError(dup, { content_hash: contentHash, stem: input.stem });
  }
  const values = [
    input.source,
    input.subject_id ?? null,
    input.knowledge_node_id ?? null,
    input.type,
    input.stem,
    input.options ?? null,
    input.answer ?? null,
    input.analysis ?? null,
    input.formula_text ?? null,
    input.difficulty ?? null,
    input.tags ?? null,
    input.generation_meta ?? null,
    contentHash,
    input.asset_refs ?? null,
    // 列 NOT NULL DEFAULT false：显式给值，不依赖 DEFAULT（与四表仓储的 status 同处理）
    input.is_subjective ?? false,
    // 归属：NULL = 公共题。列可空（不设 NOT NULL），公共题必须是 NULL。
    ownerUserId,
  ];

  return insertRow(client, TABLE, INSERT_COLUMNS, values);
}

/** 按主键读（软删行视为不存在 -> 404）。 */
export async function getById(client, id) {
  return requireRow(client, TABLE, id);
}

/** 列某科目的题（分页，稳定排序）。 */
/**
 * 列某科目的题（分页，稳定排序）。
 *
 * ★ m17431：加 ownerUserId 后按域过滤 ——
 *   - ownerUserId 非空：只看「公共题 + 该用户自己的题」，别人的私有题不可见；
 *   - ownerUserId 为空（未鉴权的内部调用）：不加 owner 过滤（保持旧行为）。
 */
export async function listBySubject(client, subjectId, { limit, offset, ownerUserId } = {}) {
  const p = pageParams({ limit, offset });
  const where = ['subject_id = $1', 'deleted_at IS NULL'];
  const params = [subjectId];
  if (ownerUserId) {
    params.push(ownerUserId);
    where.push(`(owner_user_id IS NULL OR owner_user_id = $${params.length})`);
  }
  return listRows(client, TABLE, where, params, p);
}

/** 列某知识点下的题（分页）。知识点为空时前端多半会退回到按科目列。 */
/**
 * 列某知识点下的题（分页）。知识点为空时前端多半会退回到按科目列。
 * owner 过滤口径同 listBySubject。
 */
export async function listByKnowledgeNode(
  client,
  knowledgeNodeId,
  { limit, offset, ownerUserId } = {},
) {
  const p = pageParams({ limit, offset });
  const where = ['knowledge_node_id = $1', 'deleted_at IS NULL'];
  const params = [knowledgeNodeId];
  if (ownerUserId) {
    params.push(ownerUserId);
    where.push(`(owner_user_id IS NULL OR owner_user_id = $${params.length})`);
  }
  return listRows(client, TABLE, where, params, p);
}

/**
 * 列某个用户可见的全部题（题库列表页用）。
 *
 * 可见集合 = 公共题（owner_user_id IS NULL）+ 该用户自己的题。
 * 只读端点，不含 answer / analysis 的剔除 —— 那由路由层做。
 */
export async function listVisible(
  client,
  { limit, offset, ownerUserId, subjectId, knowledgeNodeId, q, mastered, orderBy } = {},
) {
  const p = pageParams({ limit, offset });
  const where = ['deleted_at IS NULL'];
  const params = [];
  if (subjectId) {
    params.push(subjectId);
    where.push(`subject_id = $${params.length}`);
  }
  // m21780：考点过滤。前端题目选择器按考点筛题用。
  if (knowledgeNodeId) {
    params.push(knowledgeNodeId);
    where.push(`knowledge_node_id = $${params.length}`);
  }
  // m21780：题干关键字。参数化拼接进 ILIKE 模式，不拼进 SQL 字符串。
  // %% 由数据库侧做模糊匹配，这里只转义 LIKE 的元字符（\ % _），
  // 否则用户搜 "100%" 会变成通配符。（ESCAPE '\' 显式声明，不依赖默认行为。）
  if (q) {
    params.push(`%${escapeLikePattern(q)}%`);
    where.push(`stem ILIKE $${params.length} ESCAPE '\\'`);
  }
  if (ownerUserId) {
    params.push(ownerUserId);
    where.push(`(owner_user_id IS NULL OR owner_user_id = $${params.length})`);
  }
  // m25316：掌握状态过滤（练习模式 R2）。
  //   mastered=true  → 有标记且标为已掌握；mastered=false → 有标记且标为未掌握。
  //   「从没标记过」的题两个值都不匹配（未标记是第三种状态，单独筛暂不做）。
  // 用 EXISTS 子查询（不是 JOIN），避免同一题因多行标记产生重复行。
  if (typeof mastered === 'boolean' && ownerUserId) {
    const mFilter = masteryFilterClause({
      userId: ownerUserId,
      mastered,
      tableAlias: 'questions',
      paramIndex: params.length + 1,
    });
    params.push(...mFilter.params);
    where.push(mFilter.clause);
  }

  // 题库列表默认「最新导入的排最前」—— 用户刚导入完要能立刻在第一屏看到自己导入的题。
  // 其余调用方（目前只有题库端点）可传 orderBy 覆盖。
  return listRows(client, TABLE, where, params, { ...p, orderBy: orderBy || 'created_at DESC, id DESC' });
}

/**
 * 把用户输入转成 LIKE 模式里的字面量：转义 `\`、`%`、`_`。
 *
 * 不转义的话搜「100%」会匹配一切、搜「a_b」会匹配「axb」。
 * 只处理这三个字符——因为调用方固定用 `ESCAPE '\'`。
 */
function escapeLikePattern(value) {
  return `${value}`.replace(/[\\%_]/g, (ch) => `\\${ch}`);
}

/**
 * 更新（乐观锁）。
 *
 * 若 patch 动了 stem / options / formula_text 中任一（即 hash 的输入），
 * 必须重算 content_hash 并重新查重 —— 改题干改到与库里另一道题一样，
 * 本质就是「制造重复题」，不能因为「只是改文字」就绕过唯一性。
 * 调用方传上来的 content_hash 一律忽略（由本函数计算），避免客户端写入与题干不符的 hash。
 *
 * 必须在 withTransaction 内调用（重算 hash + 查重 + 写入要同一事务）。
 */
export async function update(client, id, patch = {}, baseVersion) {
  const next = { ...(patch || {}) };
  delete next.content_hash;

  const stemChanged =
    Object.prototype.hasOwnProperty.call(next, 'stem') ||
    Object.prototype.hasOwnProperty.call(next, 'options') ||
    Object.prototype.hasOwnProperty.call(next, 'formula_text');

  if (stemChanged) {
    const current = await requireRow(client, TABLE, id);
    const merged = {
      stem: Object.prototype.hasOwnProperty.call(next, 'stem') ? next.stem : current.stem,
      options: Object.prototype.hasOwnProperty.call(next, 'options') ? next.options : current.options,
      formula_text: Object.prototype.hasOwnProperty.call(next, 'formula_text')
        ? next.formula_text
        : current.formula_text,
    };
    const contentHash = contentHashOf(merged);

    // 排除自己：只改标点导致 hash 变化时不该撞自己；hash 反而变回原值时也不该 409。
    // ★ m17431：查重按**这一行自己的归属**分域（公共题在公共题域里查，
    //   用户私有题在该用户域里查），避免改公共题时撞上别人的同名私有题。
    const ownerSql = current.owner_user_id
      ? 'AND owner_user_id = $3'
      : 'AND owner_user_id IS NULL';
    const dup = await findDuplicate(
      client,
      `SELECT * FROM ${TABLE}
        WHERE content_hash = $1 AND deleted_at IS NULL AND id <> $2 ${ownerSql}`,
      current.owner_user_id
        ? [contentHash, id, current.owner_user_id]
        : [contentHash, id],
    );
    if (dup) {
      throw duplicateQuestionError(dup, { content_hash: contentHash, stem: merged.stem });
    }
    next.content_hash = contentHash;
  }

  return updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch: next,
    allowedColumns: UPDATE_COLUMNS,
  });
}

/** 软删（软删后同 hash 的题可以重新导入 —— 查重只看 deleted_at IS NULL）。 */
export async function archive(client, id, baseVersion) {
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
}
