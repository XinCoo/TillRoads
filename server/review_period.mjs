// server/review_period.mjs
// 题路 TillRoad · BE-06 T2（周期部分）：复盘周期的解析、格式化与边界计算
//
// 为什么单独一个纯函数文件：
//   「2026-W47 是哪八天到哪八天」这种换算最容易算错，而错了不会抛异常，
//   只会让复盘悄悄统计错周期（BUG 极难发现）。抽成零依赖纯函数后，
//   可以用 node:test 直接把跨年周、月末、闰年全钉死。
//
// 为什么不用 UTC 日界：
//   schema.sql 的 users.timezone 默认 'Asia/Shanghai'，用户心里的「今天」
//   是本地 00:00–24:00。若按 UTC 切，中国用户的 daily 复盘会横跨两天
//   （08:00 到次日 08:00），复盘数字与用户直觉不符。
//   因此这里用 Intl 取指定时区的日历日期，再把「本地午夜」换算成 UTC 瞬时，
//   periodStart/periodEnd 是可直接与 timestamptz 比较的 ISO 字符串。
//
// 为什么不用第三方库：
//   任务硬约束「ISO 周解析用标准算法，不引第三方库」。下面 ISO 周的实现
//   就是「第 1 周 = 含 1 月 4 日的那一周」，与 ISO-8601 定义等价。

export const DAY_MS = 86_400_000;

/** 允许的复盘周期类型（与 schema.sql:63 的 cycle_type 枚举一致）。 */
export const CYCLE_TYPES = Object.freeze(['daily', 'weekly', 'monthly']);

/**
 * 默认时区。与 schema.sql 的 `users.timezone DEFAULT 'Asia/Shanghai'` 对齐。
 * 调用方可用 user.timezone 覆盖（本轮路由层不查 users，留给后续按用户时区化）。
 */
export const DEFAULT_TIME_ZONE = 'Asia/Shanghai';

/** 周期格式（用于 400 校验与文档）。 */
export const PERIOD_FORMATS = Object.freeze({
  daily: 'YYYY-MM-DD',
  weekly: 'YYYY-Www',
  monthly: 'YYYY-MM',
});

const DAILY_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const WEEKLY_RE = /^(\d{4})-W(\d{2})$/;
const MONTHLY_RE = /^(\d{4})-(\d{2})$/;

function pad2(n) {
  return String(n).padStart(2, '0');
}

function isCycleType(value) {
  return CYCLE_TYPES.includes(value);
}

/**
 * 取某个瞬时在指定时区的日历字段。
 * hourCycle:'h23' 避免 en-US 的 hour12 把午夜报成 "24"。
 */
function partsInZone(date, timeZone) {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });
  const out = {};
  for (const part of dtf.formatToParts(date)) {
    if (part.type !== 'literal') out[part.type] = part.value;
  }
  return {
    year: Number(out.year),
    month: Number(out.month),
    day: Number(out.day),
    hour: Number(out.hour),
    minute: Number(out.minute),
    second: Number(out.second),
  };
}

/** 某瞬时在该时区的 UTC 偏移（分钟）。上海恒 +480；有夏令时的时区会变。 */
function offsetMinutesAt(date, timeZone) {
  const p = partsInZone(date, timeZone);
  // formatToParts 只到秒，先裁掉毫秒再比，避免毫秒被算进偏移。
  const whole = date.getTime() - (date.getTime() % 1000);
  const asIfUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return Math.round((asIfUtc - whole) / 60_000);
}

/**
 * 把「指定时区的某个日历日 00:00」换算成 UTC 瞬时。
 *
 * 两遍求解：先用猜测偏移算出瞬时，再取该瞬时的真实偏移修正一次。
 * 这是处理夏令时切换日（当地 00:00 可能不存在或偏移不同）的标准做法。
 */
function zonedMidnightUtc(year, month, day, timeZone) {
  const naive = Date.UTC(year, month - 1, day, 0, 0, 0);
  const firstOffset = offsetMinutesAt(new Date(naive), timeZone);
  let timestamp = naive - firstOffset * 60_000;
  const secondOffset = offsetMinutesAt(new Date(timestamp), timeZone);
  if (secondOffset !== firstOffset) {
    timestamp = naive - secondOffset * 60_000;
  }
  return new Date(timestamp);
}

/** 日历日 (y,m,d) 在时区内的午夜 → ISO 字符串。 */
function midnightIso(year, month, day, timeZone) {
  return zonedMidnightUtc(year, month, day, timeZone).toISOString();
}

/**
 * ISO-8601 周号：第 1 周是「含 1 月 4 日的那一周」，周一为一周之始。
 * @returns {{isoYear:number, week:number}}
 */
export function isoWeekOf(year, month, day) {
  const dt = new Date(Date.UTC(year, month - 1, day));
  const dayNum = dt.getUTCDay() || 7; // 周日=0 → 7，使周一=1
  dt.setUTCDate(dt.getUTCDate() + 4 - dayNum); // 挪到本周的周四
  const isoYear = dt.getUTCFullYear();
  const yearStart = Date.UTC(isoYear, 0, 1);
  const week = Math.ceil(((dt.getTime() - yearStart) / DAY_MS + 1) / 7);
  return { isoYear, week };
}

/**
 * 指定 ISO 年 + 周号的周一（作为 UTC 午夜的时间戳，仅用于取日历日期）。
 * 跨年例：2027-W01 的周一是 2027-01-04；2026-W53 的周一是 2026-12-28。
 */
function isoWeekMondayUtcTimestamp(isoYear, week) {
  const jan4 = Date.UTC(isoYear, 0, 4);
  const jan4DayNum = new Date(jan4).getUTCDay() || 7;
  const week1Monday = jan4 - (jan4DayNum - 1) * DAY_MS;
  return week1Monday + (week - 1) * 7 * DAY_MS;
}

function parseDaily(period) {
  const m = DAILY_RE.exec(period);
  if (!m) throw new TypeError(`review_period: 非法 daily period「${period}」（应为 YYYY-MM-DD）`);
  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  const probe = new Date(Date.UTC(year, month - 1, day));
  // 2026-02-30 会被 Date 归一成 03-02，必须回读比对才能拒掉。
  if (probe.getUTCFullYear() !== year || probe.getUTCMonth() !== month - 1 || probe.getUTCDate() !== day) {
    throw new TypeError(`review_period: 非法 daily period「${period}」（日期不存在）`);
  }
  return { year, month, day };
}

function parseWeekly(period) {
  const m = WEEKLY_RE.exec(period);
  if (!m) throw new TypeError(`review_period: 非法 weekly period「${period}」（应为 YYYY-Www）`);
  const isoYear = Number(m[1]);
  const week = Number(m[2]);
  if (week < 1 || week > 53) {
    throw new TypeError(`review_period: 非法 weekly period「${period}」（周号须在 01–53）`);
  }
  const mondayTs = isoWeekMondayUtcTimestamp(isoYear, week);
  const monday = new Date(mondayTs);
  const roundTrip = isoWeekOf(monday.getUTCFullYear(), monday.getUTCMonth() + 1, monday.getUTCDate());
  // 有些年份只有 52 周（如 2025-W53、2027-W53 不存在；而 2026 恰有 53 周）：回读不一致就拒。
  if (roundTrip.isoYear !== isoYear || roundTrip.week !== week) {
    throw new TypeError(`review_period: 非法 weekly period「${period}」（该年不存在第 ${week} 周）`);
  }
  return { mondayTs };
}

function parseMonthly(period) {
  const m = MONTHLY_RE.exec(period);
  if (!m) throw new TypeError(`review_period: 非法 monthly period「${period}」（应为 YYYY-MM）`);
  const year = Number(m[1]);
  const month = Number(m[2]);
  if (month < 1 || month > 12) {
    throw new TypeError(`review_period: 非法 monthly period「${period}」（月份须在 01–12）`);
  }
  return { year, month };
}

/**
 * 当前周期字符串。
 *
 * @param {'daily'|'weekly'|'monthly'} cycleType
 * @param {Date} now
 * @param {string} timeZone
 * @returns {string} daily → '2026-11-17'；weekly → '2026-W47'；monthly → '2026-11'
 */
export function currentPeriod(cycleType, now = new Date(), timeZone = DEFAULT_TIME_ZONE) {
  if (!isCycleType(cycleType)) {
    throw new TypeError(`review_period.currentPeriod: 非法 cycle_type「${cycleType}」（允许 ${CYCLE_TYPES.join(',')}）`);
  }
  const p = partsInZone(now, timeZone);
  if (cycleType === 'daily') return `${p.year}-${pad2(p.month)}-${pad2(p.day)}`;
  if (cycleType === 'monthly') return `${p.year}-${pad2(p.month)}`;
  const { isoYear, week } = isoWeekOf(p.year, p.month, p.day);
  return `${isoYear}-W${pad2(week)}`;
}

/**
 * 周期 → 起止边界（左闭右开）。
 *
 * @returns {{startAt:string, endAt:string}} ISO 8601 UTC 字符串
 *   语义为 `created_at >= startAt AND created_at < endAt`。
 */
export function periodBounds(cycleType, period, timeZone = DEFAULT_TIME_ZONE) {
  if (!isCycleType(cycleType)) {
    throw new TypeError(`review_period.periodBounds: 非法 cycle_type「${cycleType}」（允许 ${CYCLE_TYPES.join(',')}）`);
  }
  if (typeof period !== 'string' || period.trim() === '') {
    throw new TypeError('review_period.periodBounds: period 必填');
  }
  const value = period.trim();

  if (cycleType === 'daily') {
    const { year, month, day } = parseDaily(value);
    const next = new Date(Date.UTC(year, month - 1, day + 1)); // Date 自动进位到次月/次年
    return {
      startAt: midnightIso(year, month, day, timeZone),
      endAt: midnightIso(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate(), timeZone),
    };
  }

  if (cycleType === 'weekly') {
    const { mondayTs } = parseWeekly(value);
    const monday = new Date(mondayTs);
    const nextMonday = new Date(mondayTs + 7 * DAY_MS);
    return {
      startAt: midnightIso(monday.getUTCFullYear(), monday.getUTCMonth() + 1, monday.getUTCDate(), timeZone),
      endAt: midnightIso(nextMonday.getUTCFullYear(), nextMonday.getUTCMonth() + 1, nextMonday.getUTCDate(), timeZone),
    };
  }

  const { year, month } = parseMonthly(value);
  const next = new Date(Date.UTC(year, month, 1)); // month 已是 1-based，此处等价于「下月 1 日」
  return {
    startAt: midnightIso(year, month, 1, timeZone),
    endAt: midnightIso(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate(), timeZone),
  };
}

/**
 * 一次解析：空 period 用当前周期兜底，返回 period + 起止边界。
 *
 * @param {'daily'|'weekly'|'monthly'} cycleType
 * @param {string|null|undefined} periodInput
 * @param {{now?:Date, timeZone?:string}} opts
 * @returns {{period:string, startAt:string, endAt:string, timeZone:string}}
 */
export function resolvePeriod(cycleType, periodInput, opts = {}) {
  const { now = new Date(), timeZone = DEFAULT_TIME_ZONE } = opts;
  const raw = periodInput == null ? '' : String(periodInput).trim();
  const period = raw === '' ? currentPeriod(cycleType, now, timeZone) : raw;
  const { startAt, endAt } = periodBounds(cycleType, period, timeZone);
  return { period, startAt, endAt, timeZone };
}
