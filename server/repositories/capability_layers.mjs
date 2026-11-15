// server/repositories/capability_layers.mjs
// 题路 TillRoad · BE-01 第 3 步：capability_layers（能力层级模板）仓储
//
// 决策 4（不查重，只加 customizable gate）：这是共享模板表，
//   **没有 user_id / exam_profile_id**（见 schema.sql:213-224），
//   谁都能读同一份官方模板。因此：
//     * 不查重（模板名允许重复，产品上「官方模板」「我的模板」本就可能同名）；
//     * 但删除/改写必须过 customizable gate（AC-KM-02：customizable=false 的模板
//       任何人不许改；要自定义必须复制成自己的副本 —— 复制在 BE-01 第 4 步做）。
//
// 决策 9（gate 位置）：update 内部先 getById 取 current，再调
//   core/validators.mjs 的 validateCustomizableGate(current, patch)。
//   gate 是**纯函数**，所以本模块 import 它不会把 core 端无关性破坏——
//   core/validators.mjs 不 import pg，反向依赖是允许的（HTTP 层同样这么用）。

import { validateCustomizableGate } from '../../core/validators.mjs';
import {
  archiveWithVersion,
  insertRow,
  listRows,
  pageParams,
  queryOne,
  requireRow,
  updateWithVersion,
  validationError,
} from './_common.mjs';

export const TABLE = 'capability_layers';

// 可写列白名单：name / layers / customizable 三者都可改（但能否改由 gate 决定）。
export const WRITABLE_COLUMNS = Object.freeze(['name', 'layers', 'customizable']);
export const INSERT_COLUMNS = Object.freeze(['name', 'layers', 'customizable']);

/**
 * 创建模板。
 * customizable 缺省走 DB 的 DEFAULT true（插入前显式给 true，避免 insertRow 少列）；
 * layers 结构校验由调用方先用 V9 validateLayers(layers, {mode:'create'}) 完成，
 * 这里再兜一次：layers 必须是数组（jsonb 列，DB 只校验 NOT NULL 不校验结构），
 * 免得把 null 写进 NOT NULL 列后由 PG 抛出难以理解的 23502。
 */
export async function create(client, input = {}) {
  if (!Array.isArray(input.layers)) {
    throw validationError({ code: 'LAYERS_REQUIRED', message: 'capability_layers.create: layers 必须为数组' });
  }
  return insertRow(client, TABLE, INSERT_COLUMNS, [
    input.name,
    input.layers,
    input.customizable ?? true,
  ]);
}

export async function getById(client, id) {
  return requireRow(client, TABLE, id);
}

export async function list(client, { limit, offset } = {}) {
  const p = pageParams({ limit, offset });
  return listRows(client, TABLE, ['deleted_at IS NULL'], [], p);
}

/**
 * 更新（乐观锁 + customizable gate）。
 *
 * gate 语义（失败关闭）：current.customizable !== true 时，patch 只要触碰
 *   layers / customizable 就抛 CUSTOMIZABLE_LOCKED（400）；
 *   只改 name 则放行（改名不改变层级语义，不必复制副本）。
 *
 * 注意 gate 必须在**读 current 之后、写之前**，且在同一事务内：
 *   若先写后判，锁定模板已被污染，回滚也可能因并发读已看到脏数据而无效。
 */
export async function update(client, id, patch = {}, baseVersion) {
  const current = await requireRow(client, TABLE, id);

  // 决策 8：空 patch 直接返回当前行，不发 UPDATE（避免 version 无意义 +1）
  if (!patch || Object.keys(patch).filter((k) => patch[k] !== undefined).length === 0) {
    return current;
  }

  const gate = validateCustomizableGate(current, patch);
  if (!gate.ok) throw validationError(gate);

  return updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch,
    allowedColumns: WRITABLE_COLUMNS,
  });
}

/**
 * 软删（同样受 gate 保护）。
 * 删除共享模板的破坏性比改 layers 更大（别人的科目都指向它），
 * 因此对 customizable=false 的模板也拒绝，并给出可识别的错误码。
 */
export async function archive(client, id, baseVersion) {
  const current = await requireRow(client, TABLE, id);
  if (current.customizable !== true) {
    throw validationError({
      code: 'CUSTOMIZABLE_LOCKED',
      message: 'capability_layers.archive: 该模板不可自定义（customizable=false），不允许删除；请复制为自定义副本',
    });
  }
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
}

// 供 HTTP 层复用的单条查（比如「按 id 取模板并渲染层级」），
// 与 list 分开是因为模板详情是高频只读路径。
export async function findByName(client, name) {
  return queryOne(client, `SELECT * FROM ${TABLE} WHERE name = $1 AND deleted_at IS NULL`, [name]);
}
