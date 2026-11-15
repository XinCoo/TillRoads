// core/templates.test.mjs
// core/templates.mjs 单测（BE-01 第 4 步 T1）
// 零依赖、零 I/O；只 import node:test / node:assert 与两个 core 模块。
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  getTemplateSubjects,
  hasTemplate,
  TEMPLATE_VERSION,
  TEMPLATE_EXAM_TYPES,
} from './templates.mjs';
import { EXAM_TYPES, SUBJECT_KINDS } from './validators.mjs';

const VALID_KINDS = new Set(SUBJECT_KINDS);

test('T0 常量对齐：模板覆盖全部 5 个 exam_type，kind 全落在 subject_kind 枚举内', () => {
  // 模板覆盖度：EXAM_TYPES 与 TEMPLATE_EXAM_TYPES 必须集合相等。
  // 若将来 schema 新增 exam_type 而模板没补，这条会红 —— 正是我们要的提醒，
  // 因为 getTemplateSubjects 对未知类型返回 []（不抛错），没有这条断言就没人发现漏补。
  assert.equal(TEMPLATE_EXAM_TYPES.length, EXAM_TYPES.length);
  for (const t of EXAM_TYPES) {
    assert.ok(hasTemplate(t), `exam_type ${t} 缺少预置模板`);
    assert.ok(TEMPLATE_EXAM_TYPES.includes(t), `TEMPLATE_EXAM_TYPES 缺少 ${t}`);
  }

  // 每个模板的每个科目：name 非空字符串、kind ∈ subject_kind ENUM。
  for (const t of EXAM_TYPES) {
    const list = getTemplateSubjects(t);
    assert.ok(Array.isArray(list), `${t} 应返回数组`);
    assert.ok(list.length > 0, `${t} 的模板不应为空（空模板请用 hasTemplate=false 表达）`);
    for (const s of list) {
      assert.equal(typeof s.name, 'string');
      assert.ok(s.name.trim().length > 0, `${t} 存在空科目名`);
      assert.ok(VALID_KINDS.has(s.kind), `${t} / ${s.name} 的 kind=${s.kind} 不在 subject_kind 枚举内`);
    }
  }

  assert.equal(typeof TEMPLATE_VERSION, 'string');
  assert.ok(TEMPLATE_VERSION.length > 0);
});

test('T1 getTemplateSubjects 五个 exam_type 各自返回预期科目', () => {
  assert.deepEqual(
    getTemplateSubjects('civil_service').map((s) => s.name),
    ['言语理解与表达', '数量关系', '判断推理', '资料分析', '常识判断', '申论'],
  );
  assert.deepEqual(
    getTemplateSubjects('civil_service').map((s) => s.kind),
    ['objective', 'objective', 'objective', 'objective', 'objective', 'subjective'],
  );

  assert.deepEqual(
    getTemplateSubjects('postgrad').map((s) => s.name),
    ['思想政治理论', '外国语', '业务课一', '业务课二'],
  );
  assert.equal(getTemplateSubjects('postgrad').at(-1).kind, 'subjective');

  assert.deepEqual(
    getTemplateSubjects('final_exam').map((s) => s.name),
    ['专业主课', '实验与实践', '课程论文'],
  );
  assert.deepEqual(
    getTemplateSubjects('final_exam').map((s) => s.kind),
    ['objective', 'subjective', 'essay'],
  );

  assert.deepEqual(
    getTemplateSubjects('vocational').map((s) => s.name),
    ['公共基础', '专业实务'],
  );

  assert.deepEqual(
    getTemplateSubjects('adult_self_study').map((s) => s.name),
    ['公共课', '专业课', '实践环节'],
  );
});

test('T2 未知 exam_type 返回空数组且不抛错（决策 9）', () => {
  for (const bad of ['k12', 'gaokao', '', 'POSTGRAD', 'civil-service', null, undefined, 123, {}]) {
    assert.deepEqual(getTemplateSubjects(bad), [], `未知类型 ${String(bad)} 应返回 []`);
  }
  // hasTemplate 与 getTemplateSubjects 的语义要对齐但不等价：
  // 「配了模板但模板为空数组」是合法状态（将来可能出现），此时 hasTemplate=true 而返回 []。
  assert.equal(hasTemplate('k12'), false);
  assert.equal(hasTemplate('postgrad'), true);
  // 原型链上的键不得被误认为模板（防 __proto__ / constructor 注入）
  assert.equal(hasTemplate('__proto__'), false);
  assert.equal(hasTemplate('constructor'), false);
  assert.deepEqual(getTemplateSubjects('__proto__'), []);
  assert.deepEqual(getTemplateSubjects('constructor'), []);
});

test('T3 返回的是副本：调用方修改不污染模板常量，两次调用互不影响', () => {
  const a = getTemplateSubjects('postgrad');
  a.push({ name: '注入的科目', kind: 'objective' });
  a[0].name = '被改了';

  const b = getTemplateSubjects('postgrad');
  assert.equal(b.length, 4, '模板长度不应被上一次调用的 push 影响');
  assert.equal(b[0].name, '思想政治理论', '模板内的科目名不应被外部修改');
  assert.notEqual(a, b);
  assert.notEqual(a[0], b[0], '每次应返回新对象，避免共享引用');
});
