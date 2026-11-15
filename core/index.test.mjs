// core/index.test.mjs — node:test 单元测试（零第三方依赖）
import test from 'node:test';
import assert from 'node:assert/strict';
import * as C from './index.mjs';

test('状态机：合法迁移', () => {
  assert.equal(C.canTransition('DRAFT', 'ANALYZED'), true);
  assert.equal(C.canTransition('ACTION_DONE', 'V1'), true);
  assert.equal(C.canTransition('V3', 'CLOSED'), true);
  assert.equal(C.canTransition('V1', 'REOPENED'), true);
  assert.equal(C.assertTransition('DRAFT', 'ANALYZED'), undefined);
});

test('状态机：ACTION_DONE 不能直接 CLOSED（核心不变量 已处理≠已解决）', () => {
  assert.equal(C.canTransition('ACTION_DONE', 'CLOSED'), false);
  assert.throws(() => C.assertTransition('ACTION_DONE', 'CLOSED'),
    e => e.code === 'ILLEGAL_DEFECT_TRANSITION');
});

test('状态机：非法迁移 DRAFT->CLOSED / CLOSED 为终态', () => {
  assert.equal(C.canTransition('DRAFT', 'CLOSED'), false);
  assert.equal(C.canTransition('CLOSED', 'ANALYZED'), false);
  assert.equal(C.canTransition('NOPE', 'ANALYZED'), false);
});

test('禁用语：命中与未命中', () => {
  assert.equal(C.containsForbiddenPhrase('这次是粗心了'), true);
  assert.equal(C.containsForbiddenPhrase('概念混淆：把 A 当成 B'), false);
  assert.equal(C.containsForbiddenPhrase(null), false);
  assert.deepEqual(C.findForbiddenPhrases('马虎且没掌握'), ['马虎', '没掌握']);
  assert.throws(() => C.assertNoForbiddenPhrase('我懂了'),
    e => e.code === 'FORBIDDEN_PHRASE_IN_ERROR_CAUSE');
});

test('归因：转 ANALYZED 必须层级+原因且无禁用语（AC-DT-03 / P0-3）', () => {
  assert.doesNotThrow(() => C.assertAnalyzable({
    status: 'DRAFT', error_layer: 'concept', error_cause: '把充分条件当成必要条件'
  }));
  assert.throws(() => C.assertAnalyzable({ status: 'DRAFT', error_layer: null, error_cause: 'x' }),
    e => e.code === 'MISSING_ERROR_LAYER');
  assert.throws(() => C.assertAnalyzable({ status: 'DRAFT', error_layer: 'concept', error_cause: '' }),
    e => e.code === 'MISSING_ERROR_CAUSE');
  assert.throws(() => C.assertAnalyzable({ status: 'DRAFT', error_layer: 'concept', error_cause: '粗心' }),
    e => e.code === 'FORBIDDEN_PHRASE_IN_ERROR_CAUSE');
  assert.throws(() => C.assertAnalyzable({ status: 'CLOSED', error_layer: 'concept', error_cause: 'x' }),
    e => e.code === 'ILLEGAL_DEFECT_TRANSITION');
});

test('验证：V1->V2->V3->CLOSED 全 pass 链路', () => {
  assert.equal(C.applyVerification({ status: 'V1', reopen_count: 0 }, 'V1', 'pass').status, 'V2');
  assert.equal(C.applyVerification({ status: 'V2', reopen_count: 0 }, 'V2', 'pass').status, 'V3');
  assert.equal(C.applyVerification({ status: 'V3', reopen_count: 0 }, 'V3', 'pass').status, 'CLOSED');
});

test('验证：fail->REOPENED，reopen_count+1，连续重开>=3 提示抽验', () => {
  const r1 = C.applyVerification({ status: 'V1', reopen_count: 0 }, 'V1', 'fail');
  assert.equal(r1.status, 'REOPENED');
  assert.equal(r1.reopen_count, 1);
  assert.equal(r1.reopenWarning, false);
  const r2 = C.applyVerification({ status: 'V2', reopen_count: 2 }, 'V2', 'fail');
  assert.equal(r2.reopen_count, 3);
  assert.equal(r2.reopenWarning, true);
});

test('验证：阶段不匹配 / 非法结果报错', () => {
  assert.throws(() => C.applyVerification({ status: 'ACTION_DONE' }, 'V1', 'pass'),
    e => e.code === 'INVALID_VERIFICATION_STAGE');
  assert.throws(() => C.applyVerification({ status: 'V1' }, 'V1', 'maybe'),
    e => e.code === 'INVALID_VERIFICATION_RESULT');
});

test('beginVerification：仅 ACTION_DONE->V1', () => {
  assert.equal(C.beginVerification({ status: 'ACTION_DONE' }).status, 'V1');
  assert.throws(() => C.beginVerification({ status: 'DRAFT' }),
    e => e.code === 'ILLEGAL_DEFECT_TRANSITION');
});

test('reanalyze：REOPENED->ANALYZED 且 verification_round+1（P0-2 轮次）', () => {
  const r = C.reanalyze({ status: 'REOPENED', verification_round: 2, reopen_count: 3 });
  assert.equal(r.status, 'ANALYZED');
  assert.equal(r.verification_round, 3);
  assert.equal(r.reopen_count, 3);
});

test('normalizeQuestionText：全角标点归一化后等价（含顿号）', () => {
  const a = C.normalizeQuestionText('甲、乙，丙。', '', null);
  const b = C.normalizeQuestionText('甲,乙,丙.', '', null);
  assert.equal(a, b);
  assert.match(a, /^[0-9a-f]{64}$/);
  // 顿号映射为半角逗号，防「甲、乙」与「甲乙」误合并（schema 自检 9.1）
  assert.notEqual(
    C.normalizeQuestionText('甲、乙', '', null),
    C.normalizeQuestionText('甲乙', '', null)
  );
});

test('isSimilarQuestion：同知识点+同层级+同题型+未作答过', () => {
  const base = { knowledge_node_id: 'k1', error_layer: 'concept', question_type: 'single' };
  assert.equal(C.isSimilarQuestion(base, { ...base, id: 'q2' }, ['q1']), true);
  assert.equal(C.isSimilarQuestion(base, { ...base, id: 'q1' }, ['q1']), false); // 已作答
  assert.equal(C.isSimilarQuestion(base, { ...base, knowledge_node_id: 'k2', id: 'q2' }, []), false);
  assert.equal(C.isSimilarQuestion(base, { ...base, error_layer: 'process', id: 'q2' }, []), false);
});

test('computePriority：P0/P1/P2 分档', () => {
  assert.equal(C.computePriority({ frequency: 1, loss: 1, closability: 1, targetContribution: 1 }), 'P0');
  assert.equal(C.computePriority({ frequency: 0, loss: 1, closability: 1, targetContribution: 1 }), 'P2');
});

test('validateAIGenerateRequest：count 1-20 / provider 锁死 / SSRF 拦截', () => {
  assert.equal(C.validateAIGenerateRequest({ count: 5 }).ok, true);
  assert.equal(C.validateAIGenerateRequest({ count: 0 }).error.code, 'INVALID_COUNT');
  assert.equal(C.validateAIGenerateRequest({ count: 21 }).error.code, 'INVALID_COUNT');
  assert.equal(C.validateAIGenerateRequest({ count: 2.5 }).error.code, 'INVALID_COUNT');
  assert.equal(C.validateAIGenerateRequest({ count: 5, provider: 'anthropic' }).error.code, 'INVALID_PROVIDER');
  assert.equal(C.validateAIGenerateRequest({ count: 5, provider: 'openai_compatible', base_url: 'https://api.example.com' }).ok, true);
  assert.equal(C.validateAIGenerateRequest({ count: 5, provider: 'openai_compatible', base_url: 'http://x' }).error.code, 'INVALID_BASE_URL');
  assert.equal(C.validateAIGenerateRequest({ count: 5, provider: 'openai_compatible', base_url: 'https://169.254.169.254' }).error.code, 'SSRF_BLOCKED');
  assert.equal(C.validateAIGenerateRequest({ count: 5, provider: 'openai_compatible', base_url: 'https://192.168.1.1' }).error.code, 'SSRF_BLOCKED');
  assert.equal(C.validateAIGenerateRequest({ count: 5, provider: 'openai_compatible', base_url: 'https://localhost' }).error.code, 'SSRF_BLOCKED');
});
