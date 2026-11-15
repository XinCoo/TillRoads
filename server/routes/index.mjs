// server/routes/index.mjs
// 题路 TillRoad · BE-01 第 4 步：路由挂载器（T2）
//
// 职责只有一个：把 (method, seg) 依次交给每个模块的 match()，第一个返回非 null 的胜出；
// 全部未命中 -> 404 {error:'not_found'}。
//
// 为什么用「按顺序问」而不是「路径前缀表 + 正则」：
//   1. 模块自己最清楚自己的路径形状（/exam-profiles/:id/subjects 与 /subjects/:id
//      这类交叉前缀，用一张正则表反而要写死优先级，容易互相遮蔽）；
//   2. 新增一张表只需新增一个模块并在下面数组里插一行，不改别的文件；
//   3. 顺序是显式的、可读的、可测的 —— 谁抢了谁的路径一眼可见。
//
// 顺序约束（重要）：
//   - defect_tickets 里有 `POST /verifications` 的**别名委托**，
//     它只匹配 seg.length===1，不会遮蔽 /defect-tickets/:id/verifications；
//   - knowledge_nodes 认领 `/subjects/:id/knowledge-nodes` 与 `/subjects/:id/knowledge-tree`，
//     必须在 subjects 之前问，否则 subjects 的 `seg[0]==='subjects'` 分支会先 return null
//     —— 实际不会（它只认 seg.length===2），但把它排前面语义更清楚：更长路径优先。
//   - exam_profiles 认领 `/exam-profiles/:id/subjects`，同理排在 subjects 之前。

import * as examProfiles from './exam_profiles.mjs';
import * as knowledgeNodes from './knowledge_nodes.mjs';
import * as subjects from './subjects.mjs';
import * as capabilityLayers from './capability_layers.mjs';
import * as defectTickets from './defect_tickets.mjs';

/**
 * 挂载顺序即匹配优先级。长路径模块在前，短路径在后。
 * @type {Array<{name: string, match: Function}>}
 */
export const ROUTE_MODULES = Object.freeze([
  { name: 'exam_profiles', match: examProfiles.match },
  { name: 'knowledge_nodes', match: knowledgeNodes.match },
  { name: 'subjects', match: subjects.match },
  { name: 'capability_layers', match: capabilityLayers.match },
  { name: 'defect_tickets', match: defectTickets.match },
]);

/**
 * 分发一次请求。
 *
 * @param {string} method  HTTP 方法（大写）
 * @param {string[]} seg    已按 '/' 切分并去除空段的路径段
 * @param {object} ctx      { pool, state, searchParams, body }
 * @returns {{status:number, body:any}|null}  未命中原样返回 null
 *
 * 返回值可能是 Promise（接了 PG 的模块都是 async）；调用方统一 await。
 */
export function dispatch(method, seg, ctx) {
  // 健康检查放在最前：它不依赖任何模块，也不该被将来的路径前缀意外遮蔽。
  // 与 BE-00 的 Schema CI 无关，纯粹是「进程活着」的探针。
  if (method === 'GET' && seg.length === 1 && seg[0] === 'health') {
    return { status: 200, body: { status: 'ok' } };
  }

  for (const mod of ROUTE_MODULES) {
    const out = mod.match(method, seg, ctx);
    if (out !== null && out !== undefined) return out;
  }
  return null;
}
