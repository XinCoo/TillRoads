// server/repositories/verifications.mjs
// 题路 TillRoad · BE-03 T3：三次验证记录仓储（PG）
//
// 与四表仓储同形：只依赖 client.query()（鸭子类型，不 import pg），
// 所有写操作必须由调用方包在 withTransaction 内（同一 client）。
//
// round 维度（P0-2 / 拍板项 3 已核实）：
//   schema.sql:338 verifications.round int NOT NULL DEFAULT 1
//   schema.sql:351 UNIQUE (defect_ticket_id, stage, round)
//   → 重开后 verification_round+1，新 round 可重新插 V1，历史证据保留。
//   round 由 defect_tickets.submitVerification 从当前 ticket.verification_round 取，
//   本仓储不自己 +1（verification_round 是 defect_tickets 的派生列，由触发器维护）。

import { queryOne } from './_common.mjs';
import {
  archiveWithVersion,
  insertRow,
  listRows,
  pageParams,
  requireRow,
  selectRow,
} from './_common.mjs';

export const TABLE = 'verifications';

/** 可由调用方写入的列（不含 id / 系统列 / defect_ticket_id，后者单列强制必填）。 */
export const WRITABLE_COLUMNS = Object.freeze([
  'stage',
  'round',
  'verify_type',
  'question_id',
  'result',
  'evidence',
  'verified_at',
]);

const INSERT_COLUMNS = Object.freeze(['defect_ticket_id', ...WRITABLE_COLUMNS]);

// 有 DB DEFAULT 的列：调用方不传就不要出现在 INSERT 里，交给 DB 填默认值。
// result 是 NOT NULL DEFAULT 'pending'，塞 null 会违反 NOT NULL。
const DB_DEFAULTED = Object.freeze(['result', 'verified_at', 'round']);
/**
 * 写一条验证记录。
 * @param client 事务内 PoolClient
 * @param input  {defect_ticket_id, stage, round, verify_type, result, question_id?, evidence?, verified_at?}
 */
export async function create(client, input = {}) {
  if (!input.defect_ticket_id) throw new TypeError('verifications.create: defect_ticket_id 必填');
  if (!input.stage) throw new TypeError('verifications.create: stage 必填');
  // 只插入调用方显式提供、且不在 DB_DEFAULTED 缺省集合里的可写列。
  const cols = INSERT_COLUMNS.filter(
    (c) => input[c] !== undefined && !(DB_DEFAULTED.includes(c) && input[c] == null),
  );
  const values = cols.map((c) => input[c]);
  return insertRow(client, TABLE, cols, values);
}

export async function getById(client, id) {
  return requireRow(client, TABLE, id);
}

/** 含历史 round 的列表；排序 (round, stage, created_at, id) 保证时间线稳定。 */
export async function listByDefect(client, defectTicketId, opts = {}) {
  if (!defectTicketId) throw new TypeError('verifications.listByDefect: defectTicketId 必填');
  const { limit, offset } = pageParams(opts);
  const where = ['defect_ticket_id = $1'];
  const params = [defectTicketId];
  if (opts.stage) {
    params.push(opts.stage);
    where.push(`stage = $${params.length}`);
  }
  if (opts.round != null) {
    params.push(opts.round);
    where.push(`round = $${params.length}`);
  }
  return listRows(client, TABLE, where, params, {
    limit,
    offset,
    orderBy: 'round ASC, stage ASC, created_at ASC, id ASC',
  });
}

/** 同一 (ticket, stage, round) 是否已存在——用于给出比 23505 更友好的 409。 */
export async function findByStageRound(client, defectTicketId, stage, round) {
  const sql = `SELECT * FROM ${TABLE}
    WHERE defect_ticket_id = $1 AND stage = $2 AND round = $3 AND deleted_at IS NULL`;
  return queryOne(client, sql, [defectTicketId, stage, round]);
}

/** 乐观锁更新（本表较少用：验证记录一旦写入一般不改；保留以备证据补录）。 */
export async function update(client, id, patch, baseVersion, allowedColumns = WRITABLE_COLUMNS) {
  const { updateWithVersion } = await import('./_common.mjs');
  return updateWithVersion(client, { table: TABLE, id, baseVersion, patch, allowedColumns });
}

export async function archive(client, id, baseVersion) {
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
}

export async function findByIdIncludingDeleted(client, id) {
  return selectRow(client, TABLE, id, { includeDeleted: true });
}
