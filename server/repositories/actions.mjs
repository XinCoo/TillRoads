// server/repositories/actions.mjs
// 题路 TillRoad · BE-03 T2：处理动作仓储（PG）
//
// 一单多动作；done 只作参考，不自动推进状态机（拍板项 4：
// ACTION_DONE 只能由用户手动 PATCH /:id/begin-verification 触发，
// 届时在 defect_tickets.beginVerification 里检查「至少一条 action 且全部 done」）。
//
// 鸭子类型 client.query()，不 import pg；写操作由调用方包 withTransaction。

import {
  archiveWithVersion,
  insertRow,
  listRows,
  notFoundError,
  pageParams,
  queryOne,
  requireRow,
  updateWithVersion,
} from './_common.mjs';

export const TABLE = 'actions';

/** 可写业务列（不含 id / 系统列 / defect_ticket_id）。 */
export const WRITABLE_COLUMNS = Object.freeze(['content', 'done', 'due']);

const INSERT_COLUMNS = Object.freeze(['defect_ticket_id', ...WRITABLE_COLUMNS]);

export async function create(client, input = {}) {
  if (!input.defect_ticket_id) throw new TypeError('actions.create: defect_ticket_id 必填');
  if (!input.content || String(input.content).trim() === '') {
    throw new TypeError('actions.create: content 必填');
  }
  const values = INSERT_COLUMNS.map((c) => {
    if (c === 'done') return input.done == null ? false : input.done;
    return input[c] ?? null;
  });
  return insertRow(client, TABLE, INSERT_COLUMNS, values);
}

export async function getById(client, id) {
  return requireRow(client, TABLE, id);
}

export async function listByDefect(client, defectTicketId, opts = {}) {
  if (!defectTicketId) throw new TypeError('actions.listByDefect: defectTicketId 必填');
  const { limit, offset } = pageParams(opts);
  return listRows(client, TABLE, ['defect_ticket_id = $1'], [defectTicketId], {
    limit,
    offset,
    orderBy: 'created_at ASC, id ASC',
  });
}

/**
 * 标记一条动作 done（或撤销 done）。
 * 走乐观锁：baseVersion 必填，0 行 → 409（含软删当前行）。
 */
export async function markDone(client, id, done, baseVersion) {
  return updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch: { done: done === undefined ? true : !!done },
    allowedColumns: WRITABLE_COLUMNS,
  });
}

/** 通用更新（content/due），同样走乐观锁。 */
export async function update(client, id, patch, baseVersion) {
  return updateWithVersion(client, {
    table: TABLE,
    id,
    baseVersion,
    patch,
    allowedColumns: WRITABLE_COLUMNS,
  });
}

export async function archive(client, id, baseVersion) {
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
}

/**
 * BE-03 拍板项 4 的前置检查：该缺陷单至少一条 action 且全部 done。
 * 供 defect_tickets.beginVerification 在事务内调用；返回 {ok, reason, actions}。
 * 注意用同一个 client（事务内视角）。
 */
export async function assertAllDone(client, defectTicketId) {
  const rows = await listRows(client, TABLE, ['defect_ticket_id = $1'], [defectTicketId], {
    limit: 200,
    offset: 0,
    orderBy: 'created_at ASC, id ASC',
  });
  if (rows.length === 0) {
    return { ok: false, reason: 'NO_ACTIONS', actions: rows };
  }
  const pending = rows.filter((r) => !r.done);
  if (pending.length > 0) {
    return { ok: false, reason: 'ACTIONS_NOT_DONE', actions: rows, pendingCount: pending.length };
  }
  return { ok: true, actions: rows };
}

/** 统计该单的动作数（供响应体回带）。 */
export async function countByDefect(client, defectTicketId) {
  const row = await queryOne(
    client,
    `SELECT count(*)::int AS n FROM ${TABLE} WHERE defect_ticket_id = $1 AND deleted_at IS NULL`,
    [defectTicketId],
  );
  return row ? row.n : 0;
}
