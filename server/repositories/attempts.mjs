// server/repositories/attempts.mjs
// 题路 TillRoad · BE-05 T2：作答记录仓储（PG）
//
// 与四表仓储同形：首参 client（供调用方在 withTransaction 内使用）、软删、乐观锁。
//
// ★ 本表在 BE-05 里是「纯写入 + 按模考读」的角色：
//   模考提交时一次性落全部作答（拍板项 3：MVP 不做「边答边存」），
//   报告计算时按 mock_exam_id 读回来对账。
//   所以只提供 create / listByMock / getById，不提供 update（改答案不在本次范围）。
//
// is_correct 允许 NULL：主观题（essay / short_answer）无法自动判分，
//   记 null 表示「未判分」，不参与正确率分母 —— 与 server/mock_report.mjs 的
//   gradeAnswer() 返回 null 的口径严格一致。这是 schema 允许 NULL 的原因。

import {
  archiveWithVersion,
  insertRow,
  listRows,
  pageParams,
  requireRow,
} from './_common.mjs';

export const TABLE = 'attempts';

/** 可写业务列（不含 id / 系统列）。 */
export const WRITABLE_COLUMNS = Object.freeze([
  'question_id',
  'user_id',
  'is_correct',
  'duration_ms',
  'answer_text',
  'mock_exam_id',
]);

const INSERT_COLUMNS = Object.freeze([...WRITABLE_COLUMNS]);

/**
 * 落一条作答。
 *
 * input:
 *   question_id  uuid  必填
 *   user_id      uuid  必填
 *   is_correct   boolean|null   null = 未判分（主观题 / 题库无标准答案）
 *   duration_ms  int|null
 *   answer_text  text|null
 *   mock_exam_id uuid|null      属于某次模考时传
 *
 * 必须在 withTransaction 内调用（与 mock_exams 回填同一事务）。
 */
export async function create(client, input = {}) {
  if (!input.question_id) throw new TypeError('attempts.create: question_id 必填');
  if (!input.user_id) throw new TypeError('attempts.create: user_id 必填');

  // is_correct 三态（true / false / null）都要原样保留：
  //   不能用 `?? null` 一刀切，否则 false 会被某些写法误当"缺省"。
  const values = INSERT_COLUMNS.map((c) => {
    if (c === 'is_correct') {
      return input.is_correct === true ? true : input.is_correct === false ? false : null;
    }
    return input[c] ?? null;
  });

  return insertRow(client, TABLE, INSERT_COLUMNS, values);
}

/** 按主键读（软删行视为不存在 -> 404）。 */
export async function getById(client, id) {
  return requireRow(client, TABLE, id);
}

/**
 * 列某次模考的全部作答，按创建顺序（= 提交时的题目顺序）。
 *
 * orderBy 显式指定为 created_at, id：同一事务里 now() 恒定，
 *   靠 created_at 无法区分先后，必须再以 id 兜底才有稳定顺序。
 */
export async function listByMock(client, mockExamId, opts = {}) {
  if (!mockExamId) throw new TypeError('attempts.listByMock: mockExamId 必填');
  const { limit, offset } = pageParams({ limit: opts.limit ?? 200, offset: opts.offset });
  return listRows(client, TABLE, ['mock_exam_id = $1', 'deleted_at IS NULL'], [mockExamId], {
    limit,
    offset,
    orderBy: 'created_at ASC, id ASC',
  });
}

/** 列某用户在某道题上的历史作答（BE-06 复盘可能会用；本轮不调用）。 */
export async function listByUserQuestion(client, userId, questionId, opts = {}) {
  if (!userId) throw new TypeError('attempts.listByUserQuestion: userId 必填');
  if (!questionId) throw new TypeError('attempts.listByUserQuestion: questionId 必填');
  const { limit, offset } = pageParams(opts);
  return listRows(
    client,
    TABLE,
    ['user_id = $1', 'question_id = $2', 'deleted_at IS NULL'],
    [userId, questionId],
    { limit, offset, orderBy: 'created_at DESC, id DESC' },
  );
}

/** 软删（保留但本轮不暴露端点；报告生成不删作答）。 */
export async function archive(client, id, baseVersion) {
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
  return archiveWithVersion(client, { table: TABLE, id, baseVersion });
}
