// server/import/remap_tillroad.mjs
// 题路 TillRoad · m34301：`.tillroad` 导出文件导入时的「跨设备 ID 重映射」
//
// 背景（这是本轮要修的真问题）：
//   `GET /export/questions` 导出的快照里，questions.subject_id / knowledge_node_id 是
//   **原设备库里的 uuid**。把这份文件导入到另一台设备（或另一个用户）时，这些 uuid
//   在目标库里根本不存在 —— 直接写进去要么被外键拦下报错，要么（若能绕过）让题挂在
//   一个不存在的科目/考点上，表现为「题目全部落在未分类」。
//
// 解决思路：
//   导出文件除了 questions，还带 subjects / knowledge_nodes 两张表（含 name / title /
//   parent_id），所以可以在目标库里**按名字与层级重建**这套分类树，并得到一张
//   `旧 uuid → 新 uuid` 的映射表，再拿它去改写每道题的归属字段。
//
// 三条关键取舍：
//   1. **匹配优先、创建兜底**。同名科目/同路径考点已存在就复用（这正是「导入回自己
//      设备」的场景，必须不重复创建）；找不到才建。创建出来的科目挂在当前用户的默认
//      active 目标下（文件里的 exam_profile_id 也是原设备的 uuid，同样不可用）。
//   2. **考点按层级逐层重建**。先处理 parent 为空的根节点，再处理子节点，每层用
//      「目标 subject + 已映射的 parent + title」三段定位。不这么做的话，
//      「资料分析/增长率」与「数量关系/增长率」会被合到一起。
//   3. **映射失败不报错**。某道题的 subject_id 在文件里查不到（脏数据 / 旧版文件），
//      就把该题的 subject_id 置 null 并计一个数，题仍然入库 —— 导入是「尽量恢复」，
//      不是原子事务式的严格校验；让整批因为一条脏数据失败，用户只会觉得「导入坏了」。
//
// 事务边界：本模块的所有写操作都由调用方（runImport）在同一个 withTransaction 里调用，
//   所以「建了科目但题目没插进去」的孤儿状态不可能出现（失败整体回滚）。

import * as subjectsRep from '../repositories/subjects.mjs';
import * as knRepo from '../repositories/knowledge_nodes.mjs';
import { isBlank, queryMany, queryOne } from '../repositories/_common.mjs';

/** 合法的 subject_kind 取值（与 schema 的枚举一致）。文件里给了别的值就回落 objective。 */
const SUBJECT_KINDS = new Set(['objective', 'subjective', 'essay']);

/** 合法的 freq_tag（schema 上有 CHECK 约束，非法值会让 INSERT 直接失败）。 */
const FREQ_TAGS = new Set(['high', 'mid', 'low']);

/** 与 resolve_node 一致：考点路径最多 3 层。 */
const MAX_DEPTH = 3;

/** 一次导入最多读取多少条目标库内的候选科目（量级为几十，500 足够）。 */
const CACHE_LIMIT = 500;

/** 归一化用于比较的文本：折叠空白 + 去首尾 + 小写。 */
function normalize(text) {
  return String(text ?? '').replace(/\s+/g, ' ').trim().toLowerCase();
}

/** 取该用户所有可接收新题的科目（带所属目标 id，用于「优先同目标」的匹配偏好）。 */
async function listCandidateSubjects(client, userId) {
  return queryMany(
    client,
    `SELECT s.id, s.name, s.exam_profile_id, s.kind
       FROM subjects s
       JOIN exam_profiles ep ON ep.id = s.exam_profile_id
      WHERE ep.user_id = $1
        AND ep.deleted_at IS NULL
        AND ep.status = 'active'
        AND s.deleted_at IS NULL
      ORDER BY s.created_at ASC, s.id ASC
      LIMIT ${CACHE_LIMIT}`,
    [userId],
  );
}

/**
 * 取当前用户的默认落点目标：最新创建的 active 目标。
 * 文件里的 exam_profile_id 是原设备的 uuid，只有在「导入回同一台设备」时才可能命中，
 * 所以创建新科目/考点时一律用这个默认目标。
 */
async function defaultProfileIdOf(client, userId) {
  const row = await queryOne(
    client,
    `SELECT id
       FROM exam_profiles
      WHERE user_id = $1
        AND deleted_at IS NULL
        AND status = 'active'
      ORDER BY created_at DESC, id DESC
      LIMIT 1`,
    [userId],
  );
  return row ? row.id : null;
}

/**
 * 在候选科目里挑最贴合的一个，**优先同一目标下的**。
 *
 * 档位与 resolve_subject 保持一致（exact > name 包含文本 > 文本包含 name），
 * 同档位内取名字最短者（短名更泛，也更不像某个误建的怪名字）。
 * 差别只在于：先只在本目标下找，找不到再跨目标找（任务书 A3 的第三条）。
 */
function pickSubject(candidates, want, preferredProfileId) {
  const text = normalize(want);
  if (text === '') return null;

  const tiers = [
    (s) => normalize(s.name) === text,
    (s) => normalize(s.name).includes(text),
    (s) => {
      const name = normalize(s.name);
      return name !== '' && text.includes(name);
    },
  ];

  // 两轮：第一轮只在本目标下找，第二轮跨目标。命中即停。
  const scopes = [];
  if (preferredProfileId) {
    scopes.push(candidates.filter((s) => s.exam_profile_id === preferredProfileId));
  }
  scopes.push(candidates);

  for (const pool of scopes) {
    for (const match of tiers) {
      const hits = pool.filter(match);
      if (hits.length > 0) return shortest(hits);
    }
  }
  return null;
}

function shortest(rows) {
  return rows.reduce((best, cur) => (cur.name.length < best.name.length ? cur : best), rows[0]);
}

/**
 * 科目重映射：文件里的科目 → 本机科目。
 *
 * @param {object} client 事务内的 PG 客户端
 * @param {string} userId 当前用户
 * @param {Array<{id:string,name:string,kind?:string,exam_profile_id?:string}>} fileSubjects
 * @returns {Promise<{map: Map<string,string>, mapped: number, created: number, createdNames: string[]}>}
 */
export async function remapSubjects(client, userId, fileSubjects = []) {
  const map = new Map();
  const createdNames = [];
  /** 新科目 id → 展示名（用于导入结果里「归入哪些科目」）。 */
  const names = new Map();
  let mapped = 0;
  let created = 0;

  if (!Array.isArray(fileSubjects) || fileSubjects.length === 0) {
    return { map, mapped, created, createdNames, names };
  }

  const candidates = await listCandidateSubjects(client, userId);
  const defaultProfileId = await defaultProfileIdOf(client, userId);

  for (const raw of fileSubjects) {
    if (!raw || typeof raw !== 'object') continue;
    const oldId = raw.id === null || raw.id === undefined ? '' : String(raw.id);
    const name = String(raw.name ?? '').replace(/\s+/g, ' ').trim();
    // 没有旧 id 就没法建映射；没有名字就没法匹配也没法建（name 是 NOT NULL 且不空）。
    if (oldId === '' || name === '') continue;

    // 文件里的 exam_profile_id 若恰好是本机已存在的目标，就优先在它下面找/建。
    const fileProfileId = raw.exam_profile_id ? String(raw.exam_profile_id) : null;
    const preferredProfileId =
      fileProfileId && candidates.some((s) => s.exam_profile_id === fileProfileId)
        ? fileProfileId
        : defaultProfileId;

    const hit = pickSubject(candidates, name, preferredProfileId);
    if (hit) {
      map.set(oldId, hit.id);
      names.set(hit.id, hit.name);
      mapped += 1;
      continue;
    }

    if (!preferredProfileId) {
      // 用户一个 active 目标都没有：不能凭空建科目（科目必须挂在目标下）。
      console.warn(`[IMPORT] 科目无法映射（没有 active 目标）：${name}`);
      continue;
    }

    const kind = SUBJECT_KINDS.has(String(raw.kind ?? '')) ? String(raw.kind) : 'objective';
    try {
      const row = await subjectsRep.create(client, {
        exam_profile_id: preferredProfileId,
        name,
        kind,
      });
      map.set(oldId, row.id);
      names.set(row.id, name);
      created += 1;
      createdNames.push(name);
      // 建出来的科目也要进候选池：文件里两个不同旧 id 同名时不该建两次。
      candidates.push({ id: row.id, name, exam_profile_id: preferredProfileId, kind });
    } catch (err) {
      if (err && (err.code === 'conflict' || err.statusCode === 409)) {
        const retried = await queryOne(
          client,
          `SELECT id FROM subjects
            WHERE exam_profile_id = $1 AND name = $2 AND deleted_at IS NULL
            LIMIT 1`,
          [preferredProfileId, name],
        );
        if (retried) {
          map.set(oldId, retried.id);
          names.set(retried.id, name);
          candidates.push({ id: retried.id, name, exam_profile_id: preferredProfileId, kind });
          continue;
        }
      }
      console.warn(`[IMPORT] 科目创建失败（${name}）：${err?.message ?? err}`);
    }
  }

  return { map, mapped, created, createdNames, names };
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
 * 把文件里的节点按「深度」排成处理顺序：父在前、子在後。
 *
 * 导出文件的 knowledge_nodes 是按 created_at 排序的，父节点通常在前，但不能依赖这点
 * （用户可以后来把节点移动过）。这里做一次拓扑排序；遇到环或父节点缺失的，排不进去
 * 就留在 unresolved 里，由调用方当作「无法映射」跳过。
 */
function orderByDepth(nodes) {
  const byOldId = new Map();
  for (const n of nodes) {
    if (!n || typeof n !== 'object') continue;
    const id = n.id === null || n.id === undefined ? '' : String(n.id);
    if (id === '') continue;
    byOldId.set(id, n);
  }

  const ordered = [];
  const done = new Set();
  let progress = true;

  while (progress) {
    progress = false;
    for (const [id, node] of byOldId) {
      if (done.has(id)) continue;
      const parent = node.parent_id === null || node.parent_id === undefined ? null : String(node.parent_id);
      // 根节点（parent 为 null）或「父节点已经处理完」的节点可以现在处理。
      if (parent === null || done.has(parent) || !byOldId.has(parent)) {
        ordered.push(node);
        done.add(id);
        progress = true;
      }
    }
  }

  const unresolved = [...byOldId.entries()].filter(([id]) => !done.has(id)).map(([, n]) => n);
  return { ordered, unresolved };
}

/**
 * 考点重映射：文件里的考点 → 本机考点（必要时创建）。
 *
 * @param {object} client
 * @param {Map<string,string>} subjectMap remapSubjects 的产出
 * @param {Array<object>} fileNodes
 * @returns {Promise<{map: Map<string,string>, mapped: number, created: number, createdPaths: string[]}>}
 */
export async function remapNodes(client, subjectMap, fileNodes = []) {
  const map = new Map();
  const createdPaths = [];
  let mapped = 0;
  let created = 0;

  if (!Array.isArray(fileNodes) || fileNodes.length === 0) {
    return { map, mapped, created, createdPaths };
  }

  const { ordered, unresolved } = orderByDepth(fileNodes);
  if (unresolved.length > 0) {
    console.warn(`[IMPORT] 考点层级不完整，跳过 ${unresolved.length} 个节点（可能存在环或父节点缺失）`);
  }

  /** 记录节点路径（用于前端展示「新建了哪些考点」）。只做到父链已有的层级。 */
  const pathOf = new Map();
  const pathFor = (oldId, title) => {
    const parentPath = pathOf.get(String(oldId));
    const full = parentPath ? `${parentPath}/${title}` : title;
    return full.split('/').slice(-MAX_DEPTH).join('/');
  };

  for (const node of ordered) {
    const oldId = String(node.id);
    const title = String(node.title ?? '').replace(/\s+/g, ' ').trim();
    if (title === '') continue;

    const oldSubjectId = node.subject_id === null || node.subject_id === undefined ? '' : String(node.subject_id);
    const newSubjectId = subjectMap.get(oldSubjectId);
    if (!newSubjectId) {
      // 科目都没映射上，考点必然挂不了（knowledge_nodes.subject_id 是 NOT NULL + 外键）。
      console.warn(`[IMPORT] 考点跳过（科目未映射）：${title}`);
      continue;
    }

    const oldParentId = node.parent_id === null || node.parent_id === undefined ? null : String(node.parent_id);
    let newParentId = null;
    if (oldParentId !== null) {
      newParentId = map.get(oldParentId) ?? null;
      if (!newParentId) {
        // 父节点没映射上（脏数据/层级断链）→ 这个节点也没有可挂的地方。
        console.warn(`[IMPORT] 考点跳过（父节点未映射）：${title}`);
        continue;
      }
    }

    const existing = await findNode(client, newSubjectId, newParentId, title);
    if (existing) {
      map.set(oldId, existing.id);
      pathOf.set(oldId, pathFor(oldParentId, title));
      mapped += 1;
      continue;
    }

    // 与 resolve_node 一致：freq_tag / weight 来自文件但要先校验，
    // 否则 schema 的 CHECK 会让整批导入失败。
    const freqTag = FREQ_TAGS.has(String(node.freq_tag ?? '')) ? String(node.freq_tag) : null;
    const weightRaw = Number(node.weight_to_target);
    const weight = Number.isFinite(weightRaw) && weightRaw >= 0 && weightRaw <= 1 ? weightRaw : null;

    try {
      const row = await knRepo.create(client, {
        subject_id: newSubjectId,
        title,
        parent_id: newParentId,
        freq_tag: freqTag,
        weight_to_target: weight,
      });
      map.set(oldId, row.id);
      const path = pathFor(oldParentId, title);
      pathOf.set(oldId, path);
      created += 1;
      createdPaths.push(path);
    } catch (err) {
      if (err && (err.code === 'conflict' || err.statusCode === 409)) {
        const retried = await findNode(client, newSubjectId, newParentId, title);
        if (retried) {
          map.set(oldId, retried.id);
          pathOf.set(oldId, pathFor(oldParentId, title));
          continue;
        }
      }
      console.warn(`[IMPORT] 考点创建失败（${title}）：${err?.message ?? err}`);
    }
  }

  return { map, mapped, created, createdPaths };
}

/**
 * 一次 `.tillroad` 导入的完整重映射：科目树 + 考点树，并给出逐题改写的查表器。
 *
 * @param {object} client 事务内客户端
 * @param {string} userId
 * @param {{subjects?: Array<object>, knowledgeNodes?: Array<object>}} file
 * @returns {Promise<{
 *   subjectMap: Map<string,string>, nodeMap: Map<string,string>,
 *   stats: {subjects_mapped:number, subjects_created:number, nodes_mapped:number, nodes_created:number},
 *   createdSubjectNames: string[], createdNodePaths: string[],
 *   resolveQuestion: (q: object) => {subject_id: string|null, knowledge_node_id: string|null, lostSubject: boolean}
 * }>}
 */
export async function remapTillroad(client, userId, file = {}) {
  const subjectResult = isBlank(userId)
    ? { map: new Map(), mapped: 0, created: 0, createdNames: [] }
    : await remapSubjects(client, userId, file.subjects ?? []);
  const nodeResult = await remapNodes(client, subjectResult.map, file.knowledgeNodes ?? []);

  let questionsWithoutSubject = 0;

  /**
   * 把一道题的原设备归属换成新 uuid。
   *
   * - 两个字段都没有（普通 AI JSON）→ 返回 null / null，由调用方用请求里的默认值；
   * - 有 subject_id 但查不到映射（脏数据 / 旧版文件没有 subjects 数组）→ 置 null 并计数。
   */
  function resolveQuestion(question) {
    const rawSubject = question ? question.source_subject_id : null;
    const rawNode = question ? question.source_knowledge_node_id : null;

    if (rawSubject === null && rawNode === null) {
      return { subject_id: undefined, knowledge_node_id: undefined, lostSubject: false };
    }

    const subjectId = rawSubject === null ? null : subjectResult.map.get(String(rawSubject)) ?? null;
    const nodeId = rawNode === null ? null : nodeResult.map.get(String(rawNode)) ?? null;
    const lostSubject = subjectId === null;
    if (lostSubject) questionsWithoutSubject += 1;
    return { subject_id: subjectId, knowledge_node_id: nodeId, lostSubject };
  }

  return {
    subjectMap: subjectResult.map,
    nodeMap: nodeResult.map,
    stats: {
      subjects_mapped: subjectResult.mapped,
      subjects_created: subjectResult.created,
      nodes_mapped: nodeResult.mapped,
      nodes_created: nodeResult.created,
    },
    createdSubjectNames: subjectResult.createdNames,
    createdNodePaths: nodeResult.createdPaths,
    resolveQuestion,
    /** 全部题处理完后由调用方取（resolveQuestion 内部累计）。 */
    countQuestionsWithoutSubject: () => questionsWithoutSubject,
  };
}
