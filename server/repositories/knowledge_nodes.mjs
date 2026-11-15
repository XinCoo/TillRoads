// server/repositories/knowledge_nodes.mjs
// 题路 TillRoad · BE-01 第 3 步：knowledge_nodes（考点树节点）仓储
//
// 决策 4（同事务查重加锁）：创建/改名先锁**父行 subjects**，
//   再查同 subject_id + 同 parent_id 下 title 是否重复。
//   注意作用域里含 parent_id：不同父节点下允许同名考点（「数与式」可以出现在
//   不同章节里），只有「同一个父下的同级标题」才必须唯一。
//
// 决策 6（getTree 形状）：返回**扁平数组 + 构建好的 children 引用**，
//   即 [{...row, children: [...]}, ...] 的根节点列表（详见下方 getTree 注释）。

import {
  archiveWithVersion,
  duplicateError,
  findDuplicate,
  insertRow,
  isBlank,
  listRows,
  lockParentRow,
  pageParams,
  queryMany,
  requireRow,
  updateWithVersion,
} from './_common.mjs';

export const TABLE = 'knowledge_nodes';

// 可写列白名单：
//   * subject_id 仅 INSERT（换科目等于换一条记录）；
//   * parent_id 可 update（考点树允许移动节点）。
export const WRITABLE_COLUMNS = Object.freeze([
  'title',
  'parent_id',
  'freq_tag',
  'weight_to_target',
]);
export const INSERT_COLUMNS = Object.freeze(['subject_id', ...WRITABLE_COLUMNS]);

/**
 * 查重：同 subject_id + 同 parent_id（含「都是根」即 parent_id IS NULL）下 title 重复。
 *
 * parent_id IS NULL 不能写成 `parent_id = $3`（NULL = NULL 恒为 unknown，永远查不到），
 * 必须用 `IS NOT DISTINCT FROM`，它对 NULL 按「相同」比较，这正是我们要的语义。
 */
async function findTitleConflict(client, subjectId, parentId, title, excludeId = null) {
  if (isBlank(title)) return null;
  const params = [subjectId, parentId ?? null, title];
  let sql = `SELECT * FROM ${TABLE}
              WHERE subject_id = $1
                AND parent_id IS NOT DISTINCT FROM $2
                AND title = $3
                AND deleted_at IS NULL`;
  if (excludeId) {
    params.push(excludeId);
    sql += ` AND id <> $4`;
  }
  return findDuplicate(client, sql, params);
}

/**
 * 创建考点。
 * 先锁 subjects 行（父不存在/已软删 -> 404，杜绝孤儿节点）；
 * 若给了 parent_id，还要确认父节点存在、未软删、且属于同一 subject
 * （跨科目挂子节点会让树结构错乱，DB 的 FK 只约束「存在」不约束「同科目」）。
 */
export async function create(client, input = {}) {
  const subjectId = input.subject_id;
  if (!subjectId) throw new TypeError('knowledge_nodes.create: subject_id 必填');

  await lockParentRow(client, 'subjects', subjectId);

  const parentId = input.parent_id ?? null;
  if (parentId) {
    const parent = await requireRow(client, TABLE, parentId);
    if (parent.subject_id !== subjectId) {
      const err = new TypeError(
        `knowledge_nodes.create: parent_id ${parentId} 属于 subject ${parent.subject_id}，与 subject_id ${subjectId} 不一致`,
      );
      err.code = 'parent_subject_mismatch';
      err.statusCode = 400;
      throw err;
    }
  }

  const dup = await findTitleConflict(client, subjectId, parentId, input.title);
  if (dup) throw duplicateError('title', dup, { title: input.title });

  return insertRow(client, TABLE, INSERT_COLUMNS, [
    subjectId,
    input.title,
    parentId,
    input.freq_tag ?? null,
    input.weight_to_target ?? 0,
  ]);
}

export async function getById(client, id) {
  return requireRow(client, TABLE, id);
}

/** 列某科目下的节点（扁平，分页）。树形请用 getTree。 */
export async function listBySubject(client, subjectId, { limit, offset } = {}) {
  const p = pageParams({ limit, offset });
  return listRows(
    client,
    TABLE,
    ['subject_id = $1', 'deleted_at IS NULL'],
    [subjectId],
    p,
  );
}

/**
 * 取整棵考点树（决策 6）。
 *
 * 形状选择：**返回根节点数组，每个节点带 children: []**（嵌套树）。
 *   理由：
 *   1. 产品侧 AC-KM-03 是「考点树展开/折叠」，UI 直接消费嵌套结构，不必在前端
 *      二次 groupBy + 排序；把组装放在仓储层只有一次 O(n) 遍历成本。
 *   2. 仍保留每个节点原始字段（扁平行 + children），前端要扁平列表时用 treeless 版本
 *      （listBySubject）即可，两种需求都覆盖。
 *   3. 不做「所有节点塞进一个数组 + parent_id 指针」的扁平返回：那样调用方要么自己
 *      再建树、要么每层递归查询（N+1）。
 *
 * 一次查询取全部节点（单科目节点量级为百级，远小于分页阈值），
 * 内存里按 parent_id 归组；排序沿用 created_at ASC, id ASC 保证同级稳定。
 * **不设 LIMIT**：树必须完整才可渲染；若将来出现超大科目，再改惰性加载（按 parent 分页）。
 */
export async function getTree(client, subjectId) {
  const rows = await queryMany(
    client,
    `SELECT * FROM ${TABLE}
      WHERE subject_id = $1 AND deleted_at IS NULL
      ORDER BY created_at ASC, id ASC`,
    [subjectId],
  );

  const byId = new Map();
  for (const row of rows) byId.set(row.id, { ...row, children: [] });

  const roots = [];
  for (const row of rows) {
    const node = byId.get(row.id);
    const parent = row.parent_id ? byId.get(row.parent_id) : null;
    if (parent) parent.children.push(node);
    else roots.push(node);
  }
  return roots;
}

/**
 * 更新（乐观锁）。
 * 查重触发条件：patch 含 title **或** parent_id —— 两者任一变化都会改变
 *   (subject_id, parent_id, title) 这个业务唯一键；只移动不改名时，新父下
 *   已存在同名节点也必须 409（BE-01 第 3 步 CI 修复 D：原实现只判 title，漏掉移动）。
 * 若 patch 移动节点（含 parent_id），用「生效后的 subject_id + parent_id」查重，
 * 否则「移到另一个父下、与目标父下某节点同名」会漏检。
 * 移动节点还需校验目标父与节点同科目（同 create）。
 */
export async function update(client, id, patch = {}, baseVersion) {
  const current = await requireRow(client, TABLE, id);

  const movesParent = Object.prototype.hasOwnProperty.call(patch, 'parent_id');
  const renames = Object.prototype.hasOwnProperty.call(patch, 'title');

  if (movesParent) {
    const nextParentId = patch.parent_id ?? null;
    if (nextParentId) {
      // 防环：不允许把节点挂到自己或自己的后代下（DB 的 FK 只查存在性，不查环）
      if (nextParentId === id) {
        const err = new TypeError('knowledge_nodes.update: 不允许把节点挂到自己下面');
        err.code = 'cyclic_parent';
        err.statusCode = 400;
        throw err;
      }
      const parent = await requireRow(client, TABLE, nextParentId);
      if (parent.subject_id !== current.subject_id) {
        const err = new TypeError(
          `knowledge_nodes.update: parent_id ${nextParentId} 属于 subject ${parent.subject_id}，与节点 subject ${current.subject_id} 不一致`,
        );
        err.code = 'parent_subject_mismatch';
        err.statusCode = 400;
        throw err;
      }
      const descendants = await collectDescendantIds(client, id);
      if (descendants.has(nextParentId)) {
        const err = new TypeError('knowledge_nodes.update: 不允许把节点挂到自己的后代下面（会形成环）');
        err.code = 'cyclic_parent';
        err.statusCode = 400;
        throw err;
      }
    }
    await lockParentRow(client, 'subjects', current.subject_id);
  }

  // 查重：title 或 parent_id 任一变化都要查（只移动也必须查新父下的同名）。
  //   上面 movesParent 块已锁 subject 父行做串行化，这里只补「同名判定」。
  if (renames || movesParent) {
    if (!movesParent) await lockParentRow(client, 'subjects', current.subject_id); // 移动路径已在上方锁过，避免重复加锁
    const effectiveParentId = movesParent ? (patch.parent_id ?? null) : current.parent_id;
    const effectiveTitle = renames ? patch.title : current.title;
    const dup = await findTitleConflict(
      client,
      current.subject_id,
      effectiveParentId,
      effectiveTitle,
      id,
    );
    if (dup) throw duplicateError('title', dup, { title: effectiveTitle });
  }

  return updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch,
    allowedColumns: WRITABLE_COLUMNS,
  });
}

/**
 * 收集某节点的全部后代 id（递归 CTE）。
 * 只在「移动节点」时调用一次，用量很小；用 CTE 而非逐层查询避免 N+1。
 */
async function collectDescendantIds(client, rootId) {
  const rows = await queryMany(
    client,
    `WITH RECURSIVE subtree AS (
       SELECT id FROM ${TABLE} WHERE id = $1 AND deleted_at IS NULL
       UNION ALL
       SELECT k.id FROM ${TABLE} k
         JOIN subtree s ON k.parent_id = s.id
        WHERE k.deleted_at IS NULL
     )
     SELECT id FROM subtree WHERE id <> $1`,
    [rootId],
  );
  return new Set(rows.map((r) => r.id));
}

export async function archive(client, id, baseVersion) {
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
}
