// server/verify_window.mjs
// 题路 TillRoad · BE-04 T2：验证窗口与临期判定（纯函数，零依赖）
//
// ★ 为什么单独一个文件：
//   窗口天数与 urgency 判定是**业务规则**，必须只有一份定义。
//   如果写成 SQL 字面量（`INTERVAL '7 days'`），规则就会在「SQL 里一份、JS 里一份」，
//   改窗口时要改两处、且容易漂移。因此：
//     · 天数只在本文件常量里出现；
//     · 判定只看 enteredAt / windowDays / now 三个输入，可脱离数据库单测；
//     · 仓储层把行取出来后在 JS 里算，SQL 里不出现任何窗口数字。
//
// ★ 为什么不引入依赖：core/ 与 server/ 的规则层一贯零第三方依赖（core 甚至不能 import pg），
//   用 Date 的毫秒差足够，没必要为日期加减引 dayjs/luxon。

import { VERIFY_STAGES } from '../core/index.mjs';

/**
 * 验证窗口（天）。拍板项 2：
 *   · 参考开发文档的区间，取其**上限**作为宽松期限——
 *     V1「3–7 天」→ 7；V2「1–2 周」→ 14；V3 模考另给 21 天宽松期（文档未定时长，避免误判逾期）。
 *   · 键必须与 core/index.mjs 的 VERIFY_STAGES 对齐（下方有断言式校验）。
 */
export const VERIFY_WINDOWS = Object.freeze({ V1: 7, V2: 14, V3: 21 });

/** urgency 三态。 */
export const URGENCY = Object.freeze({
  OVERDUE: 'overdue',
  DUE_SOON: 'due_soon',
  NORMAL: 'normal',
});

/** 合法 urgency 值（供路由校验 query 参数）。 */
export const URGENCY_VALUES = Object.freeze([URGENCY.OVERDUE, URGENCY.DUE_SOON, URGENCY.NORMAL]);

/** 剩余天数 ≤ 该值即为「临期」（拍板项 2）。 */
export const DUE_SOON_DAYS = 3;

/** 一天的毫秒数。 */
export const DAY_MS = 24 * 60 * 60 * 1000;

// 防止 VERIFY_WINDOWS 与 core 的 stage 枚举漂移（模块加载即失败，比运行时才发现好）。
const missingStages = VERIFY_STAGES.filter((s) => !Object.prototype.hasOwnProperty.call(VERIFY_WINDOWS, s));
if (missingStages.length > 0) {
  throw new Error(`verify_window: VERIFY_WINDOWS 缺少 stage ${missingStages.join(',')}（必须与 core VERIFY_STAGES 对齐）`);
}

/**
 * 取某 stage 的窗口天数。
 * @param {string} stage 'V1' | 'V2' | 'V3'
 * @returns {number}
 */
export function windowDaysFor(stage) {
  // 用 hasOwnProperty 而不是直接索引：'constructor'/'__proto__' 会命中原型链（BE-01 第 4 步踩过）。
  if (!Object.prototype.hasOwnProperty.call(VERIFY_WINDOWS, stage)) {
    throw new TypeError(`verify_window.windowDaysFor: 未知 stage ${String(stage)}`);
  }
  return VERIFY_WINDOWS[stage];
}

/** 把各种时间表示归一成毫秒数；无法解析返回 NaN。 */
function toMs(value) {
  if (value instanceof Date) return value.getTime();
  if (typeof value === 'number') return value;
  if (typeof value === 'string' && value.trim() !== '') return new Date(value).getTime();
  return NaN;
}

/**
 * 计算某验证任务的紧迫度。
 *
 * @param {string|Date|number} enteredAt 进入当前验证状态的时间
 * @param {number} windowDays 该 stage 的窗口天数
 * @param {string|Date|number} [now] 参照时间，默认当前时刻（测试可注入）
 * @returns {{
 *   urgency: 'overdue'|'due_soon'|'normal',
 *   daysLeft: number,       // 剩余天数 = 窗口 − 已过天数；≤0 表示已逾期（0 = 今天到期）
 *   overdueDays: number,    // 已逾期天数（未逾期为 0）
 *   elapsedDays: number,    // 已过天数（向下取整）
 *   windowDays: number,
 *   enteredAt: string,      // ISO 8601
 *   dueAt: string           // 到期时刻（enteredAt + windowDays）
 * }}
 */
export function computeUrgency(enteredAt, windowDays, now = new Date()) {
  const startMs = toMs(enteredAt);
  if (Number.isNaN(startMs)) {
    throw new TypeError(`verify_window.computeUrgency: enteredAt 无法解析为时间（${String(enteredAt)}）`);
  }
  if (typeof windowDays !== 'number' || !Number.isFinite(windowDays) || windowDays < 0) {
    throw new TypeError(`verify_window.computeUrgency: windowDays 必须是非负有限数（${String(windowDays)}）`);
  }
  const nowMs = toMs(now);
  if (Number.isNaN(nowMs)) {
    throw new TypeError(`verify_window.computeUrgency: now 无法解析为时间（${String(now)}）`);
  }

  // 向下取整：不足一天算 0 天，避免「刚进入 V1 就剩 6.99 天」这种浮点抖动。
  const elapsedDays = Math.floor((nowMs - startMs) / DAY_MS);
  const daysLeft = windowDays - elapsedDays;

  let urgency = URGENCY.NORMAL;
  if (daysLeft <= 0) urgency = URGENCY.OVERDUE;
  else if (daysLeft <= DUE_SOON_DAYS) urgency = URGENCY.DUE_SOON;

  return {
    urgency,
    daysLeft,
    overdueDays: daysLeft < 0 ? -daysLeft : 0,
    elapsedDays,
    windowDays,
    enteredAt: new Date(startMs).toISOString(),
    dueAt: new Date(startMs + windowDays * DAY_MS).toISOString(),
  };
}

/** 校验一个 stage 是否是 V1/V2/V3（供路由解析 query 用）。 */
export function isVerifyStage(stage) {
  return VERIFY_STAGES.includes(stage);
}

/** 校验一个 urgency 值是否合法（供路由解析 query 用）。 */
export function isUrgency(value) {
  return URGENCY_VALUES.includes(value);
}
