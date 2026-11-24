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
import * as mockExams from './mock_exams.mjs';
import * as defectTickets from './defect_tickets.mjs';
import * as questionsImport from './questions_import.mjs';
import * as questions from './questions.mjs';
import * as verificationTasks from './verification_tasks.mjs';
import * as reviewCycles from './review_cycles.mjs';
// m18680 B1：删除「我的所有数据」（DELETE /users/:userId/data）。
import * as userData from './user_data.mjs';

/**
 * 挂载顺序即匹配优先级。长路径模块在前，短路径在后。
 * @type {Array<{name: string, match: Function}>}
 */
export const ROUTE_MODULES = Object.freeze([
  { name: 'exam_profiles', match: examProfiles.match },
  { name: 'knowledge_nodes', match: knowledgeNodes.match },
  { name: 'subjects', match: subjects.match },
  { name: 'capability_layers', match: capabilityLayers.match },
  // BE-05：模考端点。必须排在 defect_tickets 之前 ——
  // BE-03 遗留的 GET /mock-exams/:id/report 假数据端点已从 defect_tickets 删除，
  // 但保留顺序约束可避免将来回退时被旧分支截胡。
  { name: 'mock_exams', match: mockExams.match },
  // BE-06：复盘快照。必须排在 defect_tickets 之前 ——
  // BE-03 遗留的假 GET /review-cycles 已从 defect_tickets 删除（T4），
  // 但前置可保证将来若有模块误认领 /review-cycles 也不被旧路径抢走。
  { name: 'review_cycles', match: reviewCycles.match },
  { name: 'defect_tickets', match: defectTickets.match },
  { name: 'questions_import', match: questionsImport.match },
  // m17431：题库列表读取端点（GET /questions）。
  // 必须排在 questions_import 之后 —— 前者只认 POST /questions/import，
  // 但保持「长/具体在前」的顺序习惯，将来加 POST /questions 时不会被截胡。
  { name: 'questions', match: questions.match },
  // BE-04：纯查询端点（GET /users/:id/verification-tasks|verification-summary）。
  // 放最后是因为它只认 seg.length===3 且 seg[2] 是固定字面量，不会遮蔽任何已有路径。
  { name: 'verification_tasks', match: verificationTasks.match },
  // m18680 B1：DELETE /users/:id/data。
  // 放在最后：只认 DELETE + seg.length===3 + seg[2]==='data'，
  // 与 GET /users/:id/verification-tasks|verification-summary 的方法不同、
  // 字面量不同，不会互相遮蔽。
  { name: 'user_data', match: userData.match },
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
 *
 * ★ 必须逐个 await：match() 可以是 async（BE-05 的 mock_exams 就是）。
 *   如果在循环里直接 `if (out !== null) return out`，async 模块返回的 Promise
 *   永远是真值，会把后面所有模块静默遮蔽 —— 整个缺陷单路由变成 404。
 */
export async function dispatch(method, seg, ctx) {
  // 健康检查放在最前：它不依赖任何模块，也不该被将来的路径前缀意外遮蔽。
  // 与 BE-00 的 Schema CI 无关，纯粹是「进程活着」的探针。
  if (method === 'GET' && seg.length === 1 && seg[0] === 'health') {
    return { status: 200, body: { status: 'ok' } };
  }

  for (const mod of ROUTE_MODULES) {
    const out = await mod.match(method, seg, ctx);
    if (out !== null && out !== undefined) return out;
  }
  return null;
}
