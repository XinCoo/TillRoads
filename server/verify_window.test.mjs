// server/verify_window.test.mjs
// 题路 TillRoad · BE-04 T4：computeUrgency 纯函数单测（零依赖、零 PG）
//
// 边界是本文件的核心价值：daysLeft = 0 / 3 / 4 / 负数，以及「不足一天」
// 与「刚过窗口」这类浮点/整除易错点。所有用例都注入固定 now，不依赖真实时间。

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  DAY_MS,
  DUE_SOON_DAYS,
  URGENCY,
  URGENCY_VALUES,
  VERIFY_WINDOWS,
  computeUrgency,
  isUrgency,
  isVerifyStage,
  windowDaysFor,
} from './verify_window.mjs';
import { VERIFY_STAGES } from '../core/index.mjs';

const T0 = new Date('2026-11-01T00:00:00.000Z');
const daysAfter = (n) => new Date(T0.getTime() + n * DAY_MS);

test('T0 常量：窗口键与 core VERIFY_STAGES 完全对齐，三态值齐全', () => {
  assert.deepEqual(Object.keys(VERIFY_WINDOWS).sort(), VERIFY_STAGES.slice().sort());
  assert.deepEqual([...URGENCY_VALUES].sort(), ['due_soon', 'normal', 'overdue']);
  assert.equal(DUE_SOON_DAYS, 3);
  // 拍板项 2：V1「3–7 天」取上限 7、V2「1–2 周」取上限 14、V3 给 21 天宽松期。
  assert.equal(VERIFY_WINDOWS.V1, 7);
  assert.equal(VERIFY_WINDOWS.V2, 14);
  assert.equal(VERIFY_WINDOWS.V3, 21);
  // 冻结：防止运行期被误改。
  assert.ok(Object.isFrozen(VERIFY_WINDOWS));
  assert.ok(Object.isFrozen(URGENCY));
  assert.ok(Object.isFrozen(URGENCY_VALUES));
});

test('T1 windowDaysFor：三态正确；未知 stage / 原型链键抛 TypeError', () => {
  assert.equal(windowDaysFor('V1'), 7);
  assert.equal(windowDaysFor('V2'), 14);
  assert.equal(windowDaysFor('V3'), 21);
  // 原型链陷阱（BE-01 第 4 步踩过 Object.freeze 模板命中原型链）。
  for (const bad of ['constructor', '__proto__', 'toString', 'V4', '', null, undefined]) {
    assert.throws(() => windowDaysFor(bad), TypeError, `windowDaysFor(${String(bad)}) 应抛 TypeError`);
  }
});

test('T2 刚进入（0 天）：剩余 = 窗口，状态 normal', () => {
  const r = computeUrgency(T0, 7, T0);
  assert.equal(r.urgency, URGENCY.NORMAL);
  assert.equal(r.elapsedDays, 0);
  assert.equal(r.daysLeft, 7);
  assert.equal(r.overdueDays, 0);
  assert.equal(r.windowDays, 7);
  assert.equal(r.enteredAt, T0.toISOString());
  assert.equal(r.dueAt, new Date(T0.getTime() + 7 * DAY_MS).toISOString());
});

test('T3 daysLeft=4 仍是 normal（临期阈值是 ≤3，4 不算临期）', () => {
  const r = computeUrgency(T0, 7, daysAfter(3));
  assert.equal(r.daysLeft, 4);
  assert.equal(r.urgency, URGENCY.NORMAL);
});

test('T4 daysLeft=3 进入 due_soon（边界：等于阈值即临期）', () => {
  const r = computeUrgency(T0, 7, daysAfter(4));
  assert.equal(r.daysLeft, 3);
  assert.equal(r.urgency, URGENCY.DUE_SOON);
  assert.equal(r.overdueDays, 0);
});

test('T5 daysLeft=1 仍 due_soon；daysLeft=0 转 overdue（今天到期算逾期）', () => {
  const soon = computeUrgency(T0, 7, daysAfter(6));
  assert.equal(soon.daysLeft, 1);
  assert.equal(soon.urgency, URGENCY.DUE_SOON);

  const due = computeUrgency(T0, 7, daysAfter(7));
  assert.equal(due.daysLeft, 0, '第 7 天整好到期，剩余 0');
  assert.equal(due.urgency, URGENCY.OVERDUE, '剩余 0 即已逾期（拍板项：≤0 为已逾期）');
  assert.equal(due.overdueDays, 0, '正好到期当天 overdueDays 为 0');
});

test('T6 逾期：daysLeft 为负，overdueDays 取正值', () => {
  const r = computeUrgency(T0, 7, daysAfter(10));
  assert.equal(r.elapsedDays, 10);
  assert.equal(r.daysLeft, -3);
  assert.equal(r.overdueDays, 3, 'overdueDays = |daysLeft|');
  assert.equal(r.urgency, URGENCY.OVERDUE);
});

test('T7 不足一天向下取整：23 小时不计为 1 天', () => {
  const r = computeUrgency(T0, 7, new Date(T0.getTime() + DAY_MS - 1));
  assert.equal(r.elapsedDays, 0, '不满一天算 0 天');
  assert.equal(r.daysLeft, 7, '不会出现 6.99 之类的浮点抖动');
  assert.equal(r.urgency, URGENCY.NORMAL);
});

test('T8 V2/V3 各自窗口生效（同一 enteredAt 不同 stage 结论不同）', () => {
  // 已过 8 天：V1(7) 逾期；V2(14) 剩 6 天 normal；V3(21) 剩 13 天 normal。
  const now = daysAfter(8);
  const v1 = computeUrgency(T0, windowDaysFor('V1'), now);
  const v2 = computeUrgency(T0, windowDaysFor('V2'), now);
  const v3 = computeUrgency(T0, windowDaysFor('V3'), now);
  assert.equal(v1.urgency, URGENCY.OVERDUE);
  assert.equal(v1.daysLeft, -1);
  assert.equal(v2.urgency, URGENCY.NORMAL);
  assert.equal(v2.daysLeft, 6);
  assert.equal(v3.urgency, URGENCY.NORMAL);
  assert.equal(v3.daysLeft, 13);
});

test('T9 时间入参三种形态等价：Date / ISO 字符串 / 毫秒数', () => {
  const now = daysAfter(5);
  const a = computeUrgency(T0, 7, now);
  const b = computeUrgency(T0.toISOString(), 7, now.toISOString());
  const c = computeUrgency(T0.getTime(), 7, now.getTime());
  assert.deepEqual(a, b);
  assert.deepEqual(a, c);
});

test('T10 非法入参抛 TypeError（不让 NaN 静默流进响应）', () => {
  assert.throws(() => computeUrgency('not-a-date', 7, T0), TypeError);
  assert.throws(() => computeUrgency(null, 7, T0), TypeError);
  assert.throws(() => computeUrgency(T0, Number.NaN, T0), TypeError);
  assert.throws(() => computeUrgency(T0, -1, T0), TypeError);
  assert.throws(() => computeUrgency(T0, '7', T0), TypeError);
  assert.throws(() => computeUrgency(T0, 7, 'bad'), TypeError);
});

test('T11 isVerifyStage / isUrgency 供路由校验 query 用', () => {
  for (const s of VERIFY_STAGES) assert.equal(isVerifyStage(s), true);
  for (const bad of ['V4', 'v1', '', null, undefined, 'constructor']) assert.equal(isVerifyStage(bad), false);
  for (const u of URGENCY_VALUES) assert.equal(isUrgency(u), true);
  for (const bad of ['urgent', 'OVERDUE', '', null, undefined]) assert.equal(isUrgency(bad), false);
});

test('T12 windowDays=0 边界：任何时刻都算逾期', () => {
  const r = computeUrgency(T0, 0, T0);
  assert.equal(r.daysLeft, 0);
  assert.equal(r.urgency, URGENCY.OVERDUE, '窗口为 0 时立即逾期');
});
