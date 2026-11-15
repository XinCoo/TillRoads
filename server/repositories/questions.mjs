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
]);

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

/** 查同 hash 的未软删行（返回整行，便于 409 body 里带上已有题让客户端展示）。 */
async function findHashConflict(client, contentHash) {
  return findDuplicate(
    client,
    `SELECT * FROM ${TABLE} WHERE content_hash = $1 AND deleted_at IS NULL`,
    [contentHash],
  );
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

  const dup = await findHashConflict(client, contentHash);
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
  ];

  return insertRow(client, TABLE, INSERT_COLUMNS, values);
}

/** 按主键读（软删行视为不存在 -> 404）。 */
export async function getById(client, id) {
  return requireRow(client, TABLE, id);
}

/** 列某科目的题（分页，稳定排序）。 */
export async function listBySubject(client, subjectId, { limit, offset } = {}) {
  const p = pageParams({ limit, offset });
  return listRows(client, TABLE, ['subject_id = $1', 'deleted_at IS NULL'], [subjectId], p);
}

/** 列某知识点下的题（分页）。知识点为空时前端多半会退回到按科目列。 */
export async function listByKnowledgeNode(client, knowledgeNodeId, { limit, offset } = {}) {
  const p = pageParams({ limit, offset });
  return listRows(
    client,
    TABLE,
    ['knowledge_node_id = $1', 'deleted_at IS NULL'],
    [knowledgeNodeId],
    p,
  );
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
    const dup = await findDuplicate(
      client,
      `SELECT * FROM ${TABLE}
        WHERE content_hash = $1 AND deleted_at IS NULL AND id <> $2`,
      [contentHash, id],
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
    allowedColumns: WRITABLE_COLUMNS,
  });
}

/** 软删（软删后同 hash 的题可以重新导入 —— 查重只看 deleted_at IS NULL）。 */
export async function archive(client, id, baseVersion) {
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
}
