// server/routes/exam_progress.mjs
// 题路 TillRoad · 考试目标进度端点（GET /exam-profiles/:id/progress）
//
// 端点（1 个）：
//   GET /exam-profiles/:id/progress   取某个考试目标的学习进度汇总
//
// ★ 归属口径：跨用户一律 404（不用 403）。
//   与本仓库既有口径一致（「别人的东西一律当作不存在」）：
//   404 既不泄露「这个 id 存在」，也避免客户端把 403 当成可重试的错误。
//   没有 token -> 401。
//
// ★ 口径定义（本文件的核心，客户端拿它渲染进度条必须按这套算）：
//
//   minutes_used（学习用时，分钟）
//     = (a) 该目标下所有 mock_exams 关联的 attempts 的 duration_ms 之和
//     + (b) 该目标下所有科目（subjects.exam_profile_id = 本目标）关联的练习会话
//           （practice_sessions.subject_id -> subjects.exam_profile_id）里的
//           practice_answers 的 duration_ms 之和
//     两部分毫秒数相加后除以 60000 并**向下取整**为分钟。
//     （取整向下：不足 1 分钟的零头不进账，避免「刷 10 秒就显示 1 分钟」。）
//
//   questions_done = (a) attempts 条数 + (b) practice_answers 条数
//   correct        = (a)+(b) 中 is_correct IS TRUE 的条数
//   total_answered = (a)+(b) 中 is_correct IS NOT NULL 的条数
//                    （is_correct 为 NULL 表示未判定，不计入分母）
//   accuracy       = total_answered > 0 ? round(correct / total_answered, 2) : null
//   minutes_progress = daily_minutes > 0
//                       ? round(min(1, minutes_used / daily_minutes), 2)
//                       : null
//                    （daily_minutes 为空或 <= 0 时无法算进度，返回 null 而不是 0 ——
//                      「不知道」和「进度是 0」是两件事。）
//
//   所有统计都过滤 deleted_at IS NULL（软删的作答/练习/科目/模考都不计入）。
//
// ★ 为什么用一条聚合 SQL 而不是多次查询：
//   进度页要的是「一个数字」，多次查询既慢又会看到互相不一致的快照（两次查询之间
//   数据可能变了）。这里用两个 CTE 各自聚合，最后 UNION ALL 求和 —— 一次往返、一个快照。
import { fail, ok } from './_http.mjs';

/** 保留 2 位小数（四舍五入），返回 number。 */
function round2(n) {
  return Math.round((n + Number.EPSILON) * 100) / 100;
}

/**
 * GET /exam-profiles/:id/progress
 *
 * @param {string} method
 * @param {string[]} seg
 * @param {object} ctx { pool, authUserId, ... }
 * @returns {{status:number, body:any}|null}
 */
export function match(method, seg, ctx) {
  // 只认 /exam-profiles/:id/progress（seg.length === 3）。
  // exam_profiles 模块对 seg.length===3 只认 seg[2]==='subjects'，所以本模块与它不冲突；
  // 但在 ROUTE_MODULES 里本模块**排在 exam_profiles 之前**更稳妥（更长路径优先）。
  if (method !== 'GET' || seg.length !== 3) return null;
  if (seg[0] !== 'exam-profiles' || seg[2] !== 'progress') return null;

  const { pool, authUserId } = ctx;

  if (!authUserId) {
    return fail('unauthorized', 401, { message: '需要有效的 Bearer Token' });
  }

  const id = seg[1];

  return (async () => {
    // 1) 目标本身（含归属与每日目标分钟数）
    const profileRes = await pool.query(
      'SELECT id, user_id, daily_minutes FROM exam_profiles WHERE id = $1 AND deleted_at IS NULL',
      [id],
    );
    const profile = profileRes.rows[0];
    // 不存在 / 已软删 / 属于别人 —— 一律 404。
    if (!profile || profile.user_id !== authUserId) {
      return fail('not_found', 404, { message: '考试目标不存在' });
    }

    // 2) 一次聚合：模考作答 + 练习作答
    const aggRes = await pool.query(
      `WITH mock_attempts AS (
         SELECT COALESCE(SUM(a.duration_ms), 0)::bigint AS ms,
                COUNT(*)::bigint                          AS cnt,
                COUNT(*) FILTER (WHERE a.is_correct IS TRUE)::bigint     AS correct,
                COUNT(*) FILTER (WHERE a.is_correct IS NOT NULL)::bigint AS answered
           FROM attempts a
           JOIN mock_exams m ON m.id = a.mock_exam_id
          WHERE a.deleted_at IS NULL
            AND m.deleted_at IS NULL
            AND m.exam_profile_id = $1
       ),
       practice_rows AS (
         SELECT COALESCE(SUM(pa.duration_ms), 0)::bigint AS ms,
                COUNT(*)::bigint                          AS cnt,
                COUNT(*) FILTER (WHERE pa.is_correct IS TRUE)::bigint     AS correct,
                COUNT(*) FILTER (WHERE pa.is_correct IS NOT NULL)::bigint AS answered
           FROM practice_answers pa
           JOIN practice_sessions ps ON ps.id = pa.session_id
           JOIN subjects s ON s.id = ps.subject_id
          WHERE pa.deleted_at IS NULL
            AND ps.deleted_at IS NULL
            AND s.deleted_at IS NULL
            AND s.exam_profile_id = $1
       )
       SELECT (SELECT ms FROM mock_attempts) + (SELECT ms FROM practice_rows) AS total_ms,
              (SELECT cnt FROM mock_attempts) + (SELECT cnt FROM practice_rows) AS questions_done,
              (SELECT correct FROM mock_attempts) + (SELECT correct FROM practice_rows) AS correct,
              (SELECT answered FROM mock_attempts) + (SELECT answered FROM practice_rows) AS total_answered`,
      [id],
    );

    const row = aggRes.rows[0] ?? {};
    const totalMs = Number(row.total_ms ?? 0);
    const questionsDone = Number(row.questions_done ?? 0);
    const correct = Number(row.correct ?? 0);
    const totalAnswered = Number(row.total_answered ?? 0);

    // 毫秒 -> 分钟，向下取整
    const minutesUsed = Math.floor(totalMs / 60000);
    const dailyMinutes = profile.daily_minutes == null ? null : Number(profile.daily_minutes);

    const accuracy = totalAnswered > 0 ? round2(correct / totalAnswered) : null;
    const minutesProgress =
      dailyMinutes && dailyMinutes > 0 ? round2(Math.min(1, minutesUsed / dailyMinutes)) : null;

    return ok({
      exam_profile_id: profile.id,
      daily_minutes: dailyMinutes,
      minutes_used: minutesUsed,
      minutes_progress: minutesProgress,
      questions_done: questionsDone,
      correct,
      total_answered: totalAnswered,
      accuracy,
    });
  })();
}
