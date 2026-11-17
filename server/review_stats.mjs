// server/review_stats.mjs
// 题路 TillRoad · BE-06 T2：复盘 metrics 聚合（六项 SQL + 一项纯函数）
//
// 为什么 metrics 全在 SQL 层算：
//   缺陷单/验证记录/模考会随时间线性增长。若拉全量到 JS 聚合，
//   一个用了两年的用户，一次复盘要把几万行搬进内存 —— 这是 O(数据量) 的
//   内存与网络开销，而 SQL 聚合是 O(索引扫描)。任务硬约束也明确要求「不拉全量」。
//
// 唯一的例外是 mock_stability：它复用 BE-05 的 computeStability()，
//   因为「近 3 次模考的正确率变异系数」需要读 jsonb 里的 questions 数组，
//   SQL 里算等于把 jsonb 展平再聚合，既难读又和 BE-05 的口径容易漂移。
//   但次数受限于 3 次，不是 O(数据量)。
//
// 七项口径见下方每个函数的 JSDoc；周期边界由 review_period.mjs 提供。

import { computeStability } from './mock_report.mjs';
import { queryMany, queryOne } from './repositories/_common.mjs';
import { listByProfile } from './repositories/mock_exams.mjs';

/** 缺陷单状态全集（顺序即前端展示顺序，与 schema.sql:29 的 defect_status 一致）。 */
export const DEFECT_STATUSES_OPEN = Object.freeze([
  'DRAFT',
  'ANALYZED',
  'ACTION_DONE',
  'V1',
  'V2',
  'V3',
  'REOPENED',
]);

/** reopen_hotspots 取前几名。 */
export const HOTSPOT_LIMIT = 5;

/** metrics 的固定键集合（顺序即文档顺序）。 */
export const METRIC_KEYS = Object.freeze([
  'open_defects',
  'layer_dist',
  'verify_pass_rate',
  'mock_stability',
  'target_progress',
  'reopen_hotspots',
]);

function toNumberOrNull(value) {
  if (value === null || value === undefined) return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function round4(x) {
  return Math.round(x * 1e4) / 1e4;
}

/**
 * ① open_defects —— 周期结束时点的未关闭缺陷分布（**时点量，不是增量**）。
 *
 * 口径说明：拍板项 3 写「周期结束时点该用户的未关闭缺陷分布」，
 * 所以这里按 `created_at < $periodEnd` 过滤而不是 `created_at` 落在周期内 ——
 * 上周建的单如果这周还没关，仍然算进本周的存量。这是复盘最需要的视角：
 * 「手上还压着多少活」。
 *
 * by_status 保证七个键都存在（无数据给 0），前端不用做 undefined 兜底。
 * CLOSED 不算未关闭，故不在枚举里。
 */
export async function openDefects(client, userId, { periodEnd }) {
  const rows = await queryMany(
    client,
    `SELECT status::text AS status, count(*)::int AS count
       FROM defect_tickets
      WHERE user_id = $1
        AND deleted_at IS NULL
        AND status::text <> 'CLOSED'
        AND created_at < $2::timestamptz
      GROUP BY status`,
    [userId, periodEnd],
  );

  const by_status = {};
  for (const s of DEFECT_STATUSES_OPEN) by_status[s] = 0;
  let total = 0;
  for (const row of rows || []) {
    const key = row.status;
    const count = Number(row.count) || 0;
    // 只认白名单键，防止 schema 将来新增状态时静默混进契约。
    if (Object.prototype.hasOwnProperty.call(by_status, key)) {
      by_status[key] += count;
      total += count;
    }
  }
  return { total, by_status };
}

/**
 * ② layer_dist —— **周期内新建**的缺陷单按 error_layer 分组（增量）。
 *
 * 与 open_defects 的区别：这个是「本周新长了多少」，那个是「手上还压着多少」。
 * error_layer 是 text 且 DRAFT 阶段可为 NULL，归到 'unclassified' 键，
 * 不让 null 变成 JSON 里奇怪的 "null" 字符串键。
 */
export async function layerDistribution(client, userId, { periodStart, periodEnd }) {
  const rows = await queryMany(
    client,
    `SELECT COALESCE(NULLIF(btrim(error_layer), ''), 'unclassified') AS layer,
            count(*)::int AS count
       FROM defect_tickets
      WHERE user_id = $1
        AND deleted_at IS NULL
        AND created_at >= $2::timestamptz
        AND created_at <  $3::timestamptz
      GROUP BY 1
      ORDER BY count DESC, layer ASC`,
    [userId, periodStart, periodEnd],
  );

  const dist = {};
  for (const row of rows || []) {
    dist[row.layer] = Number(row.count) || 0;
  }
  return dist;
}

/**
 * ③ verify_pass_rate —— 周期内 verifications.result 的 pass/fail 计数。
 *
 * 只数 pass/fail：pending（未验证）既不是通过也不是失败，计入分母会把
 * 通过率拖低，语义错误。total=0 时 rate 为 null 而不是 0 ——
 * 「本周没做验证」和「本周验证全错」是两回事，前端要能区分。
 *
 * 通过 defect_tickets 关联 user_id（verifications 表本身没有 user_id）。
 */
export async function verifyPassRate(client, userId, { periodStart, periodEnd }) {
  const row = await queryOne(
    client,
    `SELECT
       count(*) FILTER (WHERE v.result::text = 'pass')::int AS pass,
       count(*) FILTER (WHERE v.result::text = 'fail')::int AS fail
       FROM verifications v
       JOIN defect_tickets dt ON dt.id = v.defect_ticket_id
      WHERE dt.user_id = $1
        AND v.deleted_at IS NULL
        AND dt.deleted_at IS NULL
        AND v.created_at >= $2::timestamptz
        AND v.created_at <  $3::timestamptz`,
    [userId, periodStart, periodEnd],
  );

  const pass = Number(row?.pass) || 0;
  const fail = Number(row?.fail) || 0;
  const total = pass + fail;
  return { pass, fail, total, rate: total > 0 ? round4(pass / total) : null };
}

/**
 * ④ mock_stability —— 复用 BE-05 的 computeStability（近 3 次同 profile 已提交模考）。
 *
 * 为什么「同 profile」：不同考试目标（如考研 vs 公务员）的卷子难度不可比，
 * 混在一起算变异系数没有意义。取用户最近的 exam_profile 作为基准。
 *
 * 为什么只算已提交（report IS NOT NULL）：未提交的卷子没有正确率。
 */
export async function mockStability(client, userId, { beforeAt }) {
  const profileRow = await queryOne(
    client,
    `SELECT id FROM exam_profiles
      WHERE user_id = $1 AND deleted_at IS NULL
      ORDER BY created_at DESC, id DESC
      LIMIT 1`,
    [userId],
  );
  if (!profileRow || !profileRow.id) return null;

  const mocks = await listByProfile(client, profileRow.id, {
    limit: 3,
    offset: 0,
    submittedOnly: true,
  });

  // 只取周期结束前提交的（复盘是快照，不能用到「未来」的模考）。
  const inWindow = (mocks || []).filter(
    (m) => m && m.created_at && new Date(m.created_at).getTime() < new Date(beforeAt).getTime(),
  );
  return computeStability(inWindow, 3);
}

/**
 * ⑤ target_progress —— 目标分 vs 周期内最近一次模考折算分。
 *
 * 「从 report.overall.accuracy 折算到 100 分制」：accuracy 是 0–1 小数，
 * 乘 100 即百分制得分。不读 report 里的其它字段，因为 BE-05 契约
 * 保证 overall.accuracy 一定存在（无判分行时为 null）。
 *
 * target_score 来自 exam_profiles.target_score（numeric(6,2)），
 * 由 pg 的 numeric 解析器转成 number，这里再兜一层 Number()。
 */
export async function targetProgress(client, userId, { periodStart, periodEnd }) {
  const profileRow = await queryOne(
    client,
    `SELECT id, target_score
       FROM exam_profiles
      WHERE user_id = $1 AND deleted_at IS NULL
      ORDER BY created_at DESC, id DESC
      LIMIT 1`,
    [userId],
  );

  const target_score = toNumberOrNull(profileRow?.target_score);

  if (!profileRow || !profileRow.id) {
    return { target_score, latest_mock_score: null, rate: null };
  }

  // 周期内最近一次已提交模考（按提交时间倒序；mock_exams 无 submitted_at，
  // 用 updated_at —— report 是在提交那一次 UPDATE 写入的，与提交时刻同源）。
  const mockRow = await queryOne(
    client,
    `SELECT report
       FROM mock_exams
      WHERE exam_profile_id = $1
        AND deleted_at IS NULL
        AND report IS NOT NULL
        AND updated_at >= $2::timestamptz
        AND updated_at <  $3::timestamptz
      ORDER BY updated_at DESC, id DESC
      LIMIT 1`,
    [profileRow.id, periodStart, periodEnd],
  );

  const accuracy = toNumberOrNull(mockRow?.report?.overall?.accuracy);
  const latest_mock_score = accuracy == null ? null : round4(accuracy * 100);

  // rate = 达成度，不是「与满分的比」。target_score 缺失或为 0 时无意义 → null。
  const rate =
    latest_mock_score == null || target_score == null || target_score === 0
      ? null
      : round4(latest_mock_score / target_score);

  return { target_score, latest_mock_score, rate };
}

/**
 * ⑥ reopen_hotspots —— **周期内**重开次数累加最多的 top 5 考点。
 *
 * 口径说明：defect_tickets.reopen_count 是「这张单累计被重开过几次」的
 * 当前值，不是历史增量 —— schema 里没有重开事件表（verifications 只记
 * 验证结果，REOPENED 是状态迁移）。因此这里对「周期内建的单」求
 * SUM(reopen_count)，语义是「本周新建且反复重开的单集中在哪里」。
 *
 * 若要对整个生命周期的重开事件精确归因，需要额外的事件表（V1 待补）；
 * 当前口径已在文档中注明。
 */
export async function reopenHotspots(client, userId, { periodStart, periodEnd, limit = HOTSPOT_LIMIT }) {
  const rows = await queryMany(
    client,
    `SELECT dt.knowledge_node_id,
            kn.title AS title,
            SUM(dt.reopen_count)::int AS reopen_count_sum
       FROM defect_tickets dt
       LEFT JOIN knowledge_nodes kn ON kn.id = dt.knowledge_node_id AND kn.deleted_at IS NULL
      WHERE dt.user_id = $1
        AND dt.deleted_at IS NULL
        AND dt.knowledge_node_id IS NOT NULL
        AND dt.created_at >= $2::timestamptz
        AND dt.created_at <  $3::timestamptz
        AND dt.reopen_count > 0
      GROUP BY dt.knowledge_node_id, kn.title
      ORDER BY reopen_count_sum DESC, dt.knowledge_node_id ASC
      LIMIT $4`,
    [userId, periodStart, periodEnd, limit],
  );

  return (rows || []).map((row) => ({
    knowledge_node_id: row.knowledge_node_id,
    title: row.title ?? null,
    reopen_count_sum: Number(row.reopen_count_sum) || 0,
  }));
}

/**
 * 聚合出完整 metrics。
 *
 * @param {object} client   pg client / pool（鸭子类型）
 * @param {string} userId
 * @param {{startAt:string, endAt:string}} bounds  由 review_period.periodBounds 算出
 * @returns {Promise<object>} 六项 metrics（strategy_execution 不在复盘口径内）
 */
export async function computeMetrics(client, userId, bounds, opts = {}) {
  if (!userId) throw new TypeError('review_stats.computeMetrics: userId 必填');
  if (!bounds || !bounds.startAt || !bounds.endAt) {
    throw new TypeError('review_stats.computeMetrics: bounds.startAt / bounds.endAt 必填');
  }
  const periodStart = bounds.startAt;
  const periodEnd = bounds.endAt;

  const [open_defects, layer_dist, verify_pass_rate, mock_stability, target_progress, reopen_hotspots] =
    await Promise.all([
      openDefects(client, userId, { periodEnd }),
      layerDistribution(client, userId, { periodStart, periodEnd }),
      verifyPassRate(client, userId, { periodStart, periodEnd }),
      mockStability(client, userId, { beforeAt: periodEnd }),
      targetProgress(client, userId, { periodStart, periodEnd }),
      reopenHotspots(client, userId, { periodStart, periodEnd, limit: opts.hotspotLimit ?? HOTSPOT_LIMIT }),
    ]);

  return {
    open_defects,
    layer_dist,
    verify_pass_rate,
    mock_stability,
    target_progress,
    reopen_hotspots,
  };
}
