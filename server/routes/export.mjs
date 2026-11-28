// server/routes/export.mjs
// 题路 TillRoad · m32406：题库导出（只读端点）
//
// 为什么单独一个模块而不是塞进 questions.mjs：
//   * 这是一个**整体快照**接口，不是「列表 + 分页」；它一次返回 user + subjects +
//     knowledge_nodes + questions，语义上属于「备份」，与题库 CRUD 的鉴权/过滤规则不同
//     （见下面 A2 的取舍）。
//   * 塞进 questions.mjs 会让那份已经很长的 match() 再长一截，且导出与「可见性过滤」
//     正好相反：列表给的是「我的 + 公共」，导出只要「我的」。
//
// 端点：GET /export/questions
//   query: 无（当前用户由 Bearer Token 决定）
//   响应 200：
//   {
//     "version": "1.0",
//     "exported_at": "2026-11-28T12:00:00.000Z",
//     "user": { "id": "...", "nickname": "..." },
//     "subjects": [{ id, name, kind, exam_profile_id }],
//     "knowledge_nodes": [{ id, subject_id, parent_id, title, freq_tag, weight_to_target }],
//     "questions": [{ id, subject_id, knowledge_node_id, type, stem, options, answer,
//                     analysis, formula_text, difficulty, tags, is_subjective,
//                     content_hash, created_at }]
//   }
//
// 三条口径（与 m32406 任务书 A2/A3 对齐）：
//   1. **只导 `owner_user_id = 当前用户` 的题**。刻意复用 `listVisible` 会带上公共题
//      （它的 owner 条件是 `owner_user_id IS NULL OR owner_user_id = $n`），而公共题不是
//      这个用户的资产，导回去再导入会变成「复制公共题」——所以这里手写 WHERE。
//   2. **含 answer / analysis**。这是导给用户自己的备份，不是分发给别人的题面；
//      所以不做「公共题抹答案」那套脱敏。也正因如此，导出文件不加密（任务书硬约束），
//      安全性完全由用户选的 SAF 目录决定。
//   3. **不导出练习记录 / 缺陷单 / 模考 / 复盘**。它们属于「学习过程」，恢复时会与
//      现有数据撞 id 且语义依赖题库当前状态；本轮只承诺题库可搬走。
//
// 为什么分类体系取「该用户全部科目 / 考点」而不是只取被引用到的：
//   导出是给「换设备 / 备份」用的，用户可能这次只导了几道题但科目树是完整的；
//   只导被引用的会让空科目、空考点在恢复后消失。所以按 exam_profiles.user_id 取全量
//   （含 archived 目标下的科目——它们仍有历史题引用）。
//
// 软删的行一律不出：`deleted_at IS NULL`（软删的题在「已删除」档可恢复，但不属于导出
// 语义上的「我的题库当前内容」）。

import { queryMany, queryOne } from '../repositories/_common.mjs';
import { ok, fail } from './_http.mjs';

/** 导出格式版本。将来改结构必须升这个号，导入端据此分支。 */
export const EXPORT_FORMAT_VERSION = '1.0';

/** 单次导出上限：防御性上限，避免误操作把巨型库一次性读进内存。 */
const MAX_QUESTIONS = 50000;

function toNumberOrNull(value) {
  if (value === null || value === undefined) return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

async function loadUser(client, userId) {
  return queryOne(
    client,
    'SELECT id, nickname FROM users WHERE id = $1 AND deleted_at IS NULL',
    [userId],
  );
}

async function loadSubjects(client, userId) {
  return queryMany(
    client,
    `SELECT s.id, s.name, s.kind, s.exam_profile_id
       FROM subjects s
       JOIN exam_profiles ep ON ep.id = s.exam_profile_id
      WHERE ep.user_id = $1
        AND ep.deleted_at IS NULL
        AND s.deleted_at IS NULL
      ORDER BY s.created_at ASC, s.id ASC`,
    [userId],
  );
}

async function loadKnowledgeNodes(client, userId) {
  return queryMany(
    client,
    `SELECT kn.id, kn.subject_id, kn.parent_id, kn.title, kn.freq_tag, kn.weight_to_target
       FROM knowledge_nodes kn
       JOIN subjects s ON s.id = kn.subject_id
       JOIN exam_profiles ep ON ep.id = s.exam_profile_id
      WHERE ep.user_id = $1
        AND ep.deleted_at IS NULL
        AND s.deleted_at IS NULL
        AND kn.deleted_at IS NULL
      ORDER BY kn.created_at ASC, kn.id ASC`,
    [userId],
  );
}

async function loadQuestions(client, userId) {
  return queryMany(
    client,
    `SELECT id, subject_id, knowledge_node_id, type, stem, options, answer, analysis,
            formula_text, difficulty, tags, is_subjective, content_hash, created_at
       FROM questions
      WHERE owner_user_id = $1
        AND deleted_at IS NULL
      ORDER BY created_at ASC, id ASC
      LIMIT $2`,
    [userId, MAX_QUESTIONS],
  );
}

/** 把仓储行整成导出形状（去掉 user_id 之类内部字段，numeric 转 number）。 */
function shapeQuestion(row) {
  return {
    id: row.id,
    subject_id: row.subject_id ?? null,
    knowledge_node_id: row.knowledge_node_id ?? null,
    type: row.type,
    stem: row.stem,
    options: row.options ?? null,
    answer: row.answer ?? null,
    analysis: row.analysis ?? null,
    formula_text: row.formula_text ?? null,
    difficulty: row.difficulty ?? null,
    tags: row.tags ?? null,
    is_subjective: row.is_subjective === true,
    content_hash: row.content_hash ?? null,
    created_at: row.created_at ?? null,
  };
}

function shapeNode(row) {
  return {
    id: row.id,
    subject_id: row.subject_id,
    parent_id: row.parent_id ?? null,
    title: row.title,
    freq_tag: row.freq_tag ?? null,
    // numeric(4,3) 经 pg 是字符串，导出成数字更好被下游消费。
    weight_to_target: toNumberOrNull(row.weight_to_target),
  };
}

function shapeSubject(row) {
  return {
    id: row.id,
    name: row.name,
    kind: row.kind,
    exam_profile_id: row.exam_profile_id ?? null,
  };
}

async function exportQuestions(ctx) {
  if (!ctx.authUserId) {
    return fail('unauthorized', 401, {
      message: '导出题库需要有效的 Bearer Token',
    });
  }

  const client = ctx.pool;
  const user = await loadUser(client, ctx.authUserId);
  if (!user) {
    // token 指向的用户已被删除：当作未授权，而不是导出空壳。
    return fail('unauthorized', 401, {
      message: '当前 Token 对应的用户不存在或已删除',
    });
  }

  const [subjects, nodes, questions] = await Promise.all([
    loadSubjects(client, ctx.authUserId),
    loadKnowledgeNodes(client, ctx.authUserId),
    loadQuestions(client, ctx.authUserId),
  ]);

  return ok({
    version: EXPORT_FORMAT_VERSION,
    exported_at: new Date().toISOString(),
    user: { id: user.id, nickname: user.nickname ?? null },
    subjects: subjects.map(shapeSubject),
    knowledge_nodes: nodes.map(shapeNode),
    questions: questions.map(shapeQuestion),
  });
}

export async function match(method, seg, ctx) {
  // GET /export/questions —— 单段路径，不会遮蔽任何「/export/...」以外的路由。
  if (method !== 'GET' || seg.length !== 2 || seg[0] !== 'export' || seg[1] !== 'questions') {
    return null;
  }
  return exportQuestions(ctx);
}
