// server/review_period.test.mjs
// 题路 TillRoad · BE-06 T5（fake/纯函数层）：复盘周期计算的单元测试
//
// 这些用例全部零依赖、不需要 PG，`npm test` 本机就会跑。
// 重点是「跨年 ISO 周」与「本地时区午夜」这两个最容易悄悄算错的点：
// 它们错了不会抛异常，只会让复盘统计错周期。

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  CYCLE_TYPES,
  DEFAULT_TIME_ZONE,
  PERIOD_FORMATS,
  currentPeriod,
  isoWeekOf,
  periodBounds,
  resolvePeriod,
} from './review_period.mjs';

test('T0 常量与 schema 的 cycle_type 枚举对齐', () => {
  assert.deepEqual([...CYCLE_TYPES], ['daily', 'weekly', 'monthly']);
  assert.equal(DEFAULT_TIME_ZONE, 'Asia/Shanghai');
  assert.deepEqual({ ...PERIOD_FORMATS }, { daily: 'YYYY-MM-DD', weekly: 'YYYY-Www', monthly: 'YYYY-MM' });
  assert.ok(Object.isFrozen(CYCLE_TYPES));
  assert.ok(Object.isFrozen(PERIOD_FORMATS));
});

test('T1 isoWeekOf：跨年周归属 ISO 年而非日历年', () => {
  // 2026-12-31 是周四 → 2026 年最后一周是第 53 周
  assert.deepEqual(isoWeekOf(2026, 12, 31), { isoYear: 2026, week: 53 });
  // 2027-01-01 是周五，仍属 2026-W53
  assert.deepEqual(isoWeekOf(2027, 1, 1), { isoYear: 2026, week: 53 });
  // 2026-01-01 是周四，属 2026-W01
  assert.deepEqual(isoWeekOf(2026, 1, 1), { isoYear: 2026, week: 1 });
  // 2024-12-30 是周一，属 2025-W01
  assert.deepEqual(isoWeekOf(2024, 12, 30), { isoYear: 2025, week: 1 });
  // 2021-01-03 是周日，属 2020-W53
  assert.deepEqual(isoWeekOf(2021, 1, 3), { isoYear: 2020, week: 53 });
});

test('T2 currentPeriod：按 Asia/Shanghai 日历日切分（不是 UTC 日界）', () => {
  // 2026-11-16T16:30Z = 上海 2026-11-17 00:30 → daily 应算 11-17
  assert.equal(currentPeriod('daily', new Date('2026-11-16T16:30:00Z')), '2026-11-17');
  // 2026-11-16T15:30Z = 上海 2026-11-16 23:30 → 仍是 11-16
  assert.equal(currentPeriod('daily', new Date('2026-11-16T15:30:00Z')), '2026-11-16');
  assert.equal(currentPeriod('weekly', new Date('2026-11-17T04:00:00Z')), '2026-W47');
  assert.equal(currentPeriod('monthly', new Date('2026-11-17T04:00:00Z')), '2026-11');
  // 跨年：上海 2027-01-01 01:00 = 2026-12-31T17:00Z，但 ISO 周仍是 2026-W53
  assert.equal(currentPeriod('daily', new Date('2026-12-31T17:00:00Z')), '2027-01-01');
  assert.equal(currentPeriod('weekly', new Date('2026-12-31T17:00:00Z')), '2026-W53');
  assert.equal(currentPeriod('monthly', new Date('2026-12-31T17:00:00Z')), '2027-01');
});

test('T3 periodBounds daily：左闭右开，边界落在上海午夜', () => {
  const b = periodBounds('daily', '2026-11-17');
  assert.equal(b.startAt, '2026-11-16T16:00:00.000Z');
  assert.equal(b.endAt, '2026-11-17T16:00:00.000Z');
  // 月末跨月
  const m = periodBounds('daily', '2026-11-30');
  assert.equal(m.startAt, '2026-11-29T16:00:00.000Z');
  assert.equal(m.endAt, '2026-11-30T16:00:00.000Z');
  // 年末跨年
  const y = periodBounds('daily', '2026-12-31');
  assert.equal(y.startAt, '2026-12-30T16:00:00.000Z');
  assert.equal(y.endAt, '2026-12-31T16:00:00.000Z');
});

test('T4 periodBounds weekly：周一 00:00 到次周一 00:00，含跨年周', () => {
  const w47 = periodBounds('weekly', '2026-W47');
  assert.equal(w47.startAt, '2026-11-15T16:00:00.000Z'); // 上海 2026-11-16 00:00（周一）
  assert.equal(w47.endAt, '2026-11-22T16:00:00.000Z');

  // 2026-W01 从 2025-12-29（周一）开始 —— 跨日历年
  const w01 = periodBounds('weekly', '2026-W01');
  assert.equal(w01.startAt, '2025-12-28T16:00:00.000Z');
  assert.equal(w01.endAt, '2026-01-04T16:00:00.000Z');

  // 2026-W53（2026 恰有 53 周）从 2026-12-28 到 2027-01-04
  const w53 = periodBounds('weekly', '2026-W53');
  assert.equal(w53.startAt, '2026-12-27T16:00:00.000Z');
  assert.equal(w53.endAt, '2027-01-03T16:00:00.000Z');

  // 2027-W01 从 2027-01-04 开始（因为 2027-01-01 属 2026-W53）
  const w01next = periodBounds('weekly', '2027-W01');
  assert.equal(w01next.startAt, '2027-01-03T16:00:00.000Z');
  assert.equal(w01next.endAt, '2027-01-10T16:00:00.000Z');

  // 相邻周首尾相接，不留缝不重叠
  assert.equal(w53.endAt, w01next.startAt);
});

test('T5 periodBounds monthly：月首到次月首，含闰年二月', () => {
  const feb2026 = periodBounds('monthly', '2026-02');
  assert.equal(feb2026.startAt, '2026-01-31T16:00:00.000Z');
  assert.equal(feb2026.endAt, '2026-02-28T16:00:00.000Z'); // 2026 非闰年

  const feb2028 = periodBounds('monthly', '2028-02');
  assert.equal(feb2028.startAt, '2028-01-31T16:00:00.000Z');
  assert.equal(feb2028.endAt, '2028-02-29T16:00:00.000Z'); // 2028 闰年

  const dec = periodBounds('monthly', '2026-12');
  assert.equal(dec.startAt, '2026-11-30T16:00:00.000Z');
  assert.equal(dec.endAt, '2026-12-31T16:00:00.000Z');
});

test('T6 拒绝非法 period（格式错 / 日期不存在 / 周号不存在 / 枚举错）', () => {
  assert.throws(() => periodBounds('daily', '2026-02-30'), /日期不存在/);
  assert.throws(() => periodBounds('daily', '2026-1-1'), /非法 daily period/);
  assert.throws(() => periodBounds('weekly', '2026-W1'), /非法 weekly period/);
  assert.throws(() => periodBounds('weekly', '2026-W00'), /周号须在 01–53/);
  // 2025 只有 52 周 → 2025-W53 不存在
  assert.throws(() => periodBounds('weekly', '2025-W53'), /该年不存在第 53 周/);
  assert.throws(() => periodBounds('weekly', '2027-W53'), /该年不存在第 53 周/);
  assert.throws(() => periodBounds('monthly', '2026-13'), /月份须在 01–12/);
  assert.throws(() => periodBounds('monthly', '2026-1'), /非法 monthly period/);
  assert.throws(() => periodBounds('hourly', '2026-11-17'), /非法 cycle_type/);
  assert.throws(() => periodBounds('daily', ''), /period 必填/);
  assert.throws(() => periodBounds('daily', null), /period 必填/);
  assert.throws(() => currentPeriod('yearly'), /非法 cycle_type/);
});

test('T7 resolvePeriod：空 period 用当前周期兜底，非空原样采纳', () => {
  const now = new Date('2026-11-17T04:00:00Z');
  const empty = resolvePeriod('weekly', '', { now });
  assert.equal(empty.period, '2026-W47');
  assert.equal(empty.timeZone, 'Asia/Shanghai');
  assert.equal(empty.startAt, '2026-11-15T16:00:00.000Z');

  const nullish = resolvePeriod('daily', null, { now });
  assert.equal(nullish.period, '2026-11-17');

  const explicit = resolvePeriod('monthly', ' 2026-03 ', { now });
  assert.equal(explicit.period, '2026-03'); // 前后空白被裁掉
  assert.equal(explicit.startAt, '2026-02-28T16:00:00.000Z');
});

test('T8 timeZone 可覆盖：UTC 下边界恰好是 UTC 午夜', () => {
  const b = periodBounds('daily', '2026-11-17', 'UTC');
  assert.equal(b.startAt, '2026-11-17T00:00:00.000Z');
  assert.equal(b.endAt, '2026-11-18T00:00:00.000Z');
  // 同一周期在不同时区边界不同 —— 证明时区参数真的生效
  const sh = periodBounds('daily', '2026-11-17', 'Asia/Shanghai');
  assert.notEqual(b.startAt, sh.startAt);
  // 时长都必须是 24 小时
  assert.equal(new Date(b.endAt) - new Date(b.startAt), 86_400_000);
});

test('T9 周期边界时长自洽：daily=24h / weekly=168h（非夏令时时区）', () => {
  for (const period of ['2026-01-01', '2026-06-15', '2026-12-31']) {
    const b = periodBounds('daily', period);
    assert.equal(new Date(b.endAt) - new Date(b.startAt), 24 * 3_600_000, `daily ${period}`);
  }
  for (const period of ['2026-W01', '2026-W26', '2026-W53']) {
    const b = periodBounds('weekly', period);
    assert.equal(new Date(b.endAt) - new Date(b.startAt), 7 * 24 * 3_600_000, `weekly ${period}`);
  }
});
