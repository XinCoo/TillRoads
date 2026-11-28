// server/import/resolve_node.mjs
// 题路 TillRoad · m30197 任务 A2：按「题目自带的考点路径」匹配或创建考点树
//
// 背景：题库生成提示词扩展后，AI 产出的每道题都带 node（如 "资料分析/增长率"）。
// 导入时用它把题目挂到正确的考点上，比「整批挂同一个 knowledge_node_id」有用得多。
//
// 匹配规则：
//   1. 按 "/" 拆层级（最多 3 层，与提示词约定一致；超过 3 层只取前 3 层）；
//   2. 逐级在 knowledge_nodes 里匹配：同 subject_id + 同 parent_id（根层 parent 为 NULL）+ 同 title；
//   3. 某一级找不到 → **自动创建**（title = 该级文本，parent_id = 上一级 id），
//      并继续往下走（否则后面的层级没有父节点可挂）；
//   4. subject_id 为空 → 直接返回 null（没有科目就没有考点树可挂）。
//
// ★ 硬约束：自动创建**只在导入时开启**。手动建题走 POST /questions，
//   那里 knowledge_node_id 只接受已存在的 id（仓储层外键会拦），不会触发本模块。
//
// 为什么要「逐级 parent 限定」而不是全局按 title 查：
//   不同分支下可以有同名考点（"资料分析/增长率" 与 "数量关系/增长率" 都叫「增长率」），
//   全局查会把题挂到别人的分支上去。
//
// 为什么创建失败不抛错：导入是「尽量归对」，某道题的考点建不出来不该让整批导入失败。
//   这里把失败吞成 null + 一行 warn 日志，题目仍会入库（knowledge_node_id 为 null）。

import * as knRepo from '../repositories/knowledge_nodes.mjs';
import { isBlank, queryOne } from '../repositories/_common.mjs';
/** 与提示词约定一致：考点路径最多 3 层。 */
const MAX_DEPTH = 3;

/** 单层标题的合理上限（提示词要求每层 ≤10 字，这里放宽到 40 防止误伤真实长考点名）。 */
const MAX_TITLE_LENGTH = 40;

/**
 * 把 "资料分析/增长率" 拆成 ['资料分析','增长率']。
 *
 * 同时兼容中文全角斜杠「／」和前后空格；空段丢弃
 * （"资料分析//增长率" 与 "/资料分析/增长率/" 都能正确解析）。
 *
 * @param {string} pathText
 * @returns {string[]}
 */
export function splitNodePath(pathText) {
  if (typeof pathText !== 'string') return [];
  return pathText
    .split(/[/／]/)
    .map((part) => part.replace(/\s+/g, ' ').trim())
    .filter((part) => part !== '')
    .slice(0, MAX_DEPTH)
    .map((part) => Array.from(part).slice(0, MAX_TITLE_LENGTH).join(''));
}

/** 查同科目、同父节点下的同名考点（parent 为 null 时用 IS NOT DISTINCT FROM 才能命中根层）。 */
async function findNode(client, subjectId, parentId, title) {
  return queryOne(
    client,
    `SELECT id, title, parent_id
       FROM knowledge_nodes
      WHERE subject_id = $1
        AND parent_id IS NOT DISTINCT FROM $2
        AND title = $3
        AND deleted_at IS NULL
      LIMIT 1`,
    [subjectId, parentId, title],
  );
}

/**
 * 单条路径解析（不带缓存）。
 *
 * @param {object} client
 * @param {{pathText?: string, subjectId?: string}} input
 * @returns {Promise<{knowledge_node_id: string, created: string[], depth: number}|null>}
 *   created 是本路径下**本次新建**的层级标题（已存在的层级不会出现）。
 */
export async function resolveNode(client, { pathText = '', subjectId = '' } = {}) {
  if (isBlank(subjectId)) return null;

  const segments = splitNodePath(pathText);
  if (segments.length === 0) return null;

  let parentId = null;
  const created = [];

  for (const title of segments) {
    const existing = await findNode(client, subjectId, parentId, title);
    if (existing) {
      parentId = existing.id;
      continue;
    }

    // 不存在 → 建（导入专用）。create 内部会锁父行、校验父节点同科目、再查一次重名。
    try {
      const row = await knRepo.create(client, { subject_id: subjectId, title, parent_id: parentId });
      parentId = row.id;
      created.push(title);
    } catch (err) {
      // 并发导入时另一条连接可能刚建出同名节点（409 duplicate）→ 重查一次即可。
      if (err && (err.code === 'conflict' || err.statusCode === 409)) {
        const retried = await findNode(client, subjectId, parentId, title);
        if (retried) {
          parentId = retried.id;
          continue;
        }
      }
      console.warn(
        `[IMPORT] 考点创建失败（subject=${subjectId}, title=${title}）：${err?.message ?? err}`,
      );
      return null;
    }
  }

  if (!parentId) return null;
  return { knowledge_node_id: parentId, created, depth: segments.length };
}

/**
 * 带缓存的批量解析器。
 *
 * 一次导入里 N 道题通常只有少数几条不同路径，且同一条路径会被反复命中。
 * 缓存 key 用「路径原文归一化」；同一路径解析一次即可（创建也只做一次）。
 *
 * 注意 subjectId 不同必须用不同的 resolver 实例（缓存不跨科目共享）。
 *
 * @param {object} client
 * @param {string} subjectId
 */
export function createNodeResolver(client, subjectId) {
  const cache = new Map();

  return async function resolve(pathText) {
    if (isBlank(subjectId) || isBlank(pathText)) return null;
    const key = splitNodePath(pathText).join('/');
    if (key === '') return null;
    if (cache.has(key)) return cache.get(key);
    const hit = await resolveNode(client, { pathText, subjectId });
    cache.set(key, hit);
    return hit;
  };
}
