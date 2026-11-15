// server/repositories/_common.test.mjs
// BE-01 第 3 步 CI 修复 A：jsonb 参数序列化的逻辑层单测（fake client，零 PG）
//
// 为什么需要这组测试（CI 的 8 个 fail 里有 5 条源于此）：
//   pg 驱动的 utils.prepareValue() 在判断「怎么待参数」时，先看 Array.isArray(val)：
//     * JS 数组 -> PG **数组**字面量 '{"{\"order\":1}"}'，jsonb 列解析必失败（22P02）；
//     * JS 对象 -> JSON.stringify，恰好正确；
//     * JS 字符串 -> 原样下发（被当成 JSON 文本），也正确。
//   所以仓储层必须对 jsonb 列自己序列化数组/对象，否则 capability_layers.layers
//   这类「数组型 jsonb」永远写不进去。本文件锁死这条行为，防回归。

import test from 'node:test';
import assert from 'node:assert/strict';

import { insertRow, JSONB_COLUMNS, isJsonbColumn, toJsonbParam, updateWithVersion } from './_common.mjs';

// fake client：只记录 (sql, params)，不连库
function fakeClient(handler) {
  const calls = [];
  return {
    calls,
    async query(sql, params = []) {
      calls.push({ sql, params });
      if (handler) return handler(sql, params, calls.length) || { rows: [] };
      return { rows: [] };
    },
  };
}

const LAYERS = [
  { order: 1, key: 'concept', label: '概念理解', desc: '能说出定义' },
  { order: 2, key: 'apply', label: '应用', desc: '能做对基础题' },
];

test('toJsonbParam：数组/对象 -> JSON 字符串；字符串原样；null/undefined 原样', () => {
  // 关键：数组必须变成 JSON **文本**，不能留数组（否则驱动发 PG 数组字面量）
  assert.equal(toJsonbParam(LAYERS), JSON.stringify(LAYERS));
  assert.equal(typeof toJsonbParam(LAYERS), 'string');
  assert.deepEqual(JSON.parse(toJsonbParam(LAYERS)), LAYERS);

  assert.equal(toJsonbParam({ v1: 'pending' }), '{"v1":"pending"}');

  // 已经是字符串：视为调用方已序列化好的 JSON 文本，原样下发（二次 stringify 会变成 JSON 字符串字面量，反而错）
  assert.equal(toJsonbParam('[{"a":1}]'), '[{"a":1}]');

  // NULL 与 undefined 不能被序列化成 "null" 字符串
  assert.equal(toJsonbParam(null), null);
  assert.equal(toJsonbParam(undefined), undefined);

  // 标量也走 JSON.stringify（jsonb 允许标量）
  assert.equal(toJsonbParam(1), '1');
  assert.equal(toJsonbParam(true), 'true');
});

test('JSONB_COLUMNS / isJsonbColumn：覆盖 schema 全部 jsonb 列，且不误伤普通列', () => {
  // schema.sql 的 jsonb 列（22 处命中，去重到 8 张表）
  const expected = {
    ai_generation_jobs: ['payload'],
    exam_profiles: ['subject_target', 'source_scope', 'baseline'],
    capability_layers: ['layers'],
    questions: ['options', 'tags', 'generation_meta', 'asset_refs'],
    defect_tickets: ['actions', 'verification_state'],
    mock_exams: ['questions', 'report'],
    review_cycles: ['metrics'],
    plans: ['items'],
  };
  for (const [table, cols] of Object.entries(expected)) {
    for (const col of cols) {
      assert.equal(isJsonbColumn(table, col), true, `${table}.${col} 应被识别为 jsonb`);
    }
  }

  // 普通列不能被当成 jsonb（否则会被多序列化一次，写进 text 列就变成 JSON 字符串）
  assert.equal(isJsonbColumn('capability_layers', 'name'), false);
  assert.equal(isJsonbColumn('capability_layers', 'customizable'), false);
  assert.equal(isJsonbColumn('exam_profiles', 'target_label'), false);
  assert.equal(isJsonbColumn('exam_profiles', 'target_score'), false);
  assert.equal(isJsonbColumn('defect_tickets', 'error_cause'), false);

  // 未知表安全返回 false（不抛错）
  assert.equal(isJsonbColumn('no_such_table', 'layers'), false);
  assert.equal(isJsonbColumn(undefined, 'layers'), false);

  // 常量冻结，防运行期被改写
  assert.equal(Object.isFrozen(JSONB_COLUMNS), true);
  assert.equal(Object.isFrozen(JSONB_COLUMNS.capability_layers), true);
});

test('insertRow：jsonb 列的数组参数最终以 JSON 字符串下传（这是 CI 修复 A 的核心断言）', async () => {
  const c = fakeClient(() => ({ rows: [{ id: 'x' }] }));
  await insertRow(c, 'capability_layers', ['name', 'layers', 'customizable'], ['三层模板', LAYERS, true]);

  assert.equal(c.calls.length, 1);
  const { sql, params } = c.calls[0];
  assert.match(sql, /^INSERT INTO capability_layers/);

  // 非 jsonb 列原样
  assert.equal(params[0], '三层模板');
  assert.equal(params[2], true);

  // jsonb 列：必须是字符串，且能被 JSON.parse 回原数组 —— 绝不能是 JS 数组本身
  assert.equal(typeof params[1], 'string', 'layers 必须以 JSON 文本下传，不能传 JS 数组');
  assert.deepEqual(JSON.parse(params[1]), LAYERS);
});

test('insertRow：jsonb 列传字符串时不二次序列化（已是 JSON 文本则原样）', async () => {
  const c = fakeClient(() => ({ rows: [{ id: 'x' }] }));
  const text = '[{"order":1,"key":"only","label":"唯一层","desc":""}]';
  await insertRow(c, 'capability_layers', ['name', 'layers'], ['t', text]);
  assert.equal(c.calls[0].params[1], text);
});

test('insertRow：jsonb 列为 null 时保持 SQL NULL（不写成字符串 "null"）', async () => {
  const c = fakeClient(() => ({ rows: [{ id: 'x' }] }));
  await insertRow(c, 'exam_profiles', ['user_id', 'subject_target', 'baseline'], ['u', null, undefined]);
  assert.equal(c.calls[0].params[1], null);
  assert.equal(c.calls[0].params[2], undefined);
});

test('updateWithVersion：jsonb 列的数组 patch 以 JSON 字符串下传；非 jsonb 列不受影响', async () => {
  const c = fakeClient((sql) => {
    if (/^UPDATE/.test(sql)) return { rows: [{ id: 'x', version: 2 }], rowCount: 1 };
    return { rows: [] };
  });
  await updateWithVersion(c, {
    table: 'capability_layers',
    id: 'row-1',
    baseVersion: 1,
    patch: { name: '新名', layers: LAYERS },
    allowedColumns: ['name', 'layers', 'customizable'],
  });

  const { sql, params } = c.calls[0];
  assert.match(sql, /^UPDATE capability_layers SET/);
  // buildUpdateSet 按 patch 键序生成；name 是普通列，layers 是 jsonb 列
  const nameIdx = params.indexOf('新名');
  const layersIdx = params.findIndex((v) => typeof v === 'string' && v.startsWith('[{'));
  assert.ok(nameIdx >= 0, 'name 应原样下传');
  assert.ok(layersIdx >= 0, 'layers 应以 JSON 文本下传');
  assert.deepEqual(JSON.parse(params[layersIdx]), LAYERS);
  assert.equal(typeof params[layersIdx], 'string');
});

test('updateWithVersion：jsonb 字段传 undefined 时不参与 SET（交给 buildUpdateSet 跳过）', async () => {
  const c = fakeClient((sql) => {
    if (/^UPDATE/.test(sql)) return { rows: [{ id: 'x', version: 2 }], rowCount: 1 };
    return { rows: [{ id: 'x', version: 1 }] };
  });
  await updateWithVersion(c, {
    table: 'capability_layers',
    id: 'row-1',
    baseVersion: 1,
    patch: { layers: undefined, name: '只改名' },
    allowedColumns: ['name', 'layers', 'customizable'],
  });

  const { sql } = c.calls[0];
  assert.match(sql, /"name" = \$1/);
  assert.doesNotMatch(sql, /"layers"/);
});
