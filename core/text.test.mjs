// core/text.test.mjs — node:test 单元测试（零第三方依赖）
import test from 'node:test';
import assert from 'node:assert/strict';
import { sanitizeQuestionText, countUnderscorePlaceholders } from './text.mjs';

const PH = '（  ）'; // 全角左括号 + 两个空格 + 全角右括号

test('清洗：连续 2 个 ASCII 下划线被替换成括号占位符', () => {
  assert.equal(sanitizeQuestionText('____'.slice(0, 2)), PH);
  assert.equal(sanitizeQuestionText('__'), PH);
});

test('清洗：连续 3 个 / 4 个 ASCII 下划线被替换成括号占位符', () => {
  assert.equal(sanitizeQuestionText('___'), PH);
  assert.equal(sanitizeQuestionText('____'), PH);
});

test('清洗：全角下划线 2 个被替换', () => {
  assert.equal(sanitizeQuestionText('＿＿'), PH);
  assert.equal(sanitizeQuestionText('＿＿＿'), PH);
});

test('清洗：ASCII 与全角混排的连续序列整体替换', () => {
  assert.equal(sanitizeQuestionText('__＿'), PH);
  assert.equal(sanitizeQuestionText('＿__'), PH);
  assert.equal(sanitizeQuestionText('_＿_'), PH);
});

test('清洗：单个下划线保留原样（不是占位符）', () => {
  assert.equal(sanitizeQuestionText('a_b'), 'a_b');
  assert.equal(sanitizeQuestionText('1_2'), '1_2');
  assert.equal(sanitizeQuestionText('＿'), '＿');
  assert.equal(sanitizeQuestionText('a_b_c'), 'a_b_c');
});

test('清洗：中间带空格的下划线不算连续，保持原样', () => {
  assert.equal(sanitizeQuestionText('_ _'), '_ _');
  assert.equal(sanitizeQuestionText('__ _ __'), `${PH} _ ${PH}`);
});

test('清洗：空字符串 / null / undefined', () => {
  assert.equal(sanitizeQuestionText(''), '');
  assert.equal(sanitizeQuestionText(null), '');
  assert.equal(sanitizeQuestionText(undefined), '');
});

test('清洗：非字符串先 String() 再处理', () => {
  assert.equal(sanitizeQuestionText(123), '123');
  assert.equal(sanitizeQuestionText(true), 'true');
  assert.equal(sanitizeQuestionText(0), '0');
  assert.equal(sanitizeQuestionText(12.5), '12.5');
});

test('清洗：文本前后有其它内容时只替换占位符部分', () => {
  assert.equal(sanitizeQuestionText('题干____选项'), `题干${PH}选项`);
  assert.equal(sanitizeQuestionText('这是题干____'), `这是题干${PH}`);
  assert.equal(sanitizeQuestionText('____是答案'), `${PH}是答案`);
});

test('清洗：两个独立占位符都被替换', () => {
  assert.equal(sanitizeQuestionText('____和____'), `${PH}和${PH}`);
  assert.equal(sanitizeQuestionText('a____b____c'), `a${PH}b${PH}c`);
});

test('清洗：其余内容原样保留（不 trim、不转半角、不删空白）', () => {
  assert.equal(sanitizeQuestionText('  甲、乙。  ____  '), '  甲、乙。  ' + PH + '  ');
  assert.equal(sanitizeQuestionText('   '), '   ');
  assert.equal(sanitizeQuestionText('\n\t'), '\n\t');
});

test('计数：countUnderscorePlaceholders 统计被替换的占位符个数', () => {
  assert.equal(countUnderscorePlaceholders('____'), 1);
  assert.equal(countUnderscorePlaceholders('____和____'), 2);
  assert.equal(countUnderscorePlaceholders('a_b'), 0);
  assert.equal(countUnderscorePlaceholders('_ _'), 0);
  assert.equal(countUnderscorePlaceholders('＿＿__'), 1);
  assert.equal(countUnderscorePlaceholders(''), 0);
  assert.equal(countUnderscorePlaceholders(null), 0);
  assert.equal(countUnderscorePlaceholders(undefined), 0);
  assert.equal(countUnderscorePlaceholders(123), 0);
});
