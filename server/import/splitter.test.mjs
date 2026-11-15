// server/import/splitter.test.mjs
// 题路 TillRoad · BE-02：规则切题单测（AC-Q-02 的验收锚点）
//
// 为什么这些断言值得写死：
//   AC-Q-02 的通过线是「切题准确率 ≥90%」。准确率不是感觉，是
//   splitStats(result, expected).accuracy —— expected 就是本节里写死的题数。
//   样本或规则任何一侧被改动，这里会立刻红，而不是等到导入了 200 道题
//   才发现「怎么少了几道」。
//
// 三份样本的分工（对应三种真实输入形态）：
//   sample-01-markdown.md        —— 带 Markdown 标题的题库导出（12 题）
//   sample-02-plain.txt          —— 纯文本，题干/选项折行（10 题）
//   sample-03-pdf-extracted.txt  —— 模拟 PDF 抽取结果，换行更碎（12 题）
// 另有一条用真实文字型 PDF 走 extractText + splitQuestions 的端到端用例（3 题），
// 证明「pdfjs 抽取出来的文本真的能喂进 splitter」，用 ASCII 是因为
// 手写 PDF 用的 Helvetica 没有中日韩字形。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { SEPARATORS, matchSeparator, splitQuestions, splitStats } from './splitter.mjs';
import { extractText } from './extract.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURES = join(HERE, '..', '..', 'tests', 'fixtures', 'questions');

function readFixture(name) {
  return readFileSync(join(FIXTURES, name), 'utf8');
}

// ---------------------------------------------------------------------------
// 样本 1：Markdown 题库（12 题，四种分隔符各 3 组）
// ---------------------------------------------------------------------------
test('sample-01-markdown：切出 12 题且准确率 100%', () => {
  const text = readFixture('sample-01-markdown.md');
  const result = splitQuestions(text);

  assert.equal(result.questions.length, 12, '题数必须与样本声明一致');

  const stats = splitStats(result, 12);
  assert.equal(stats.actual, 12);
  assert.equal(stats.nonEmpty, 12);
  assert.equal(stats.countOk, true);
  // AC-Q-02 的通过线：>= 0.9
  assert.ok(stats.accuracy >= 0.9, `准确率 ${stats.accuracy} 未达 0.9`);

  // 四种分隔符都必须在这份样本里出现过 —— 否则「覆盖四类」是假覆盖
  const kinds = new Set(result.questions.map((q) => q.separator));
  for (const key of ['arabic', 'paren', 'cn_num', 'di']) {
    assert.ok(kinds.has(key), `样本 1 未覆盖分隔符 ${key}`);
  }

  // 首尾题题干：用来锁住「编号被正确剥离」与「最后一题没被吞」
  assert.equal(result.questions[0].stem, '马克思主义哲学的直接理论来源是（ ）');
  assert.equal(result.questions.at(-1).stem, '下列属于上层建筑的是（ ）');

  // 每题都有 4 个选项和答案
  for (const q of result.questions) {
    assert.ok(Array.isArray(q.options) && q.options.length === 4, `选项缺失：${q.stem}`);
    assert.ok(q.answer && q.answer.length > 0, `答案缺失：${q.stem}`);
    assert.ok(q.analysis && q.analysis.length > 0, `解析缺失：${q.stem}`);
  }

  // 卷头的标题与说明必须落在 preamble，不能混进第一题题干
  assert.ok(result.preamble.length > 0, 'preamble 应包含卷头');
  assert.ok(
    result.preamble.some((l) => l.includes('考研政治')),
    'preamble 应包含标题行',
  );
});

// ---------------------------------------------------------------------------
// 样本 2：纯文本，题干与选项都折行
// ---------------------------------------------------------------------------
test('sample-02-plain：切出 10 题，折行题干被拼接成一题而非两题', () => {
  const text = readFixture('sample-02-plain.txt');
  const result = splitQuestions(text);

  assert.equal(result.questions.length, 10);

  const stats = splitStats(result, 10);
  assert.equal(stats.countOk, true);
  assert.ok(stats.accuracy >= 0.9);

  // 第一题题干跨两行：折行若被当成新题，这里只会剩前半句
  const first = result.questions[0];
  assert.ok(first.stem.includes('依次填入下列横线处的词语'), '首题前半句丢失');
  assert.ok(first.stem.includes('难以____'), '折行后半句丢失（折行拼接失效）');
  assert.ok(first.stem.includes('\n'), '折行应以换行保留，便于前端显示');

  const kinds = new Set(result.questions.map((q) => q.separator));
  for (const key of ['arabic', 'paren', 'cn_num', 'di']) {
    assert.ok(kinds.has(key), `样本 2 未覆盖分隔符 ${key}`);
  }

  // 第八题（第1题 分隔符）的选项行含中文标点，检验 OPTION_RE 不被 `A.` 之外的形式干扰
  const diQuestion = result.questions.find((q) => q.separator === 'di');
  assert.ok(diQuestion, '样本 2 应包含「第N题」分隔符的题');
  assert.ok(diQuestion.options.length === 4);
});

// ---------------------------------------------------------------------------
// 样本 3：模拟 PDF 抽取结果（换行更碎）
// ---------------------------------------------------------------------------
test('sample-03-pdf-extracted：切出 12 题且准确率 100%', () => {
  const text = readFixture('sample-03-pdf-extracted.txt');
  const result = splitQuestions(text);

  assert.equal(result.questions.length, 12);
  const stats = splitStats(result, 12);
  assert.equal(stats.countOk, true);
  assert.ok(stats.accuracy >= 0.9);

  // PDF 抽取的第一题常常把题号与题干黏在一起，这里确认 `第1题` 被吃干净
  assert.equal(result.questions[0].stem, '教育观的核心是（ ）');
  assert.equal(result.questions.at(-1).stem, '素质教育的重点是培养学生的（ ）');

  for (const q of result.questions) {
    assert.ok(q.options && q.options.length === 4);
  }
});

// ---------------------------------------------------------------------------
// 真实 PDF：extractText -> splitQuestions 的端到端链路
// ---------------------------------------------------------------------------
test('text-simple.pdf：pdfjs 抽出的文本能被 splitter 切开（3 题）', async () => {
  const buffer = readFileSync(join(FIXTURES, 'text-simple.pdf'));
  const extracted = await extractText({
    buffer,
    mime: 'application/pdf',
    filename: 'text-simple.pdf',
  });

  assert.equal(extracted.kind, 'pdf');
  assert.equal(extracted.pages, 1);
  assert.ok(extracted.text.length > 0, 'PDF 应抽出文本');

  const result = splitQuestions(extracted.text);
  assert.equal(result.questions.length, 3, 'PDF 抽出的 3 题应全部切开');
  assert.equal(result.questions[0].stem, 'What is the derivative of x^2?');
  assert.equal(result.questions[2].stem, 'Which of these is a prime number?');
});

// ---------------------------------------------------------------------------
// matchSeparator 逐类断言（规则本身的单测，不依赖样本）
// ---------------------------------------------------------------------------
test('matchSeparator：四类分隔符各自命中，且不误判小数与年份', () => {
  assert.equal(matchSeparator('1. 第一题').key, 'arabic');
  assert.equal(matchSeparator('12、第十二题').key, 'arabic');
  assert.equal(matchSeparator('（3）第三题').key, 'paren');
  assert.equal(matchSeparator('(3) 第三题').key, 'paren');
  assert.equal(matchSeparator('二、第二题').key, 'cn_num');
  assert.equal(matchSeparator('十一、第十一题').key, 'cn_num');
  assert.equal(matchSeparator('第7题 第七题').key, 'di');
  assert.equal(matchSeparator('第 7 题 第七题').key, 'di');

  // 关键否定用例：
  // `1.5` 是小数不是题号 —— arabic 的 (?!\d) 就是为它写的
  assert.equal(matchSeparator('1.5 倍于原值'), null);
  // `2024年` 开头的年份不能被当成 3 位题号
  assert.equal(matchSeparator('2024年度总结'), null);
  // 普通句子
  assert.equal(matchSeparator('这是普通的一行说明文字。'), null);

  // SEPARATORS 必须是冻结的常量，避免调用方就地改成别的顺序
  assert.ok(Object.isFrozen(SEPARATORS));
  assert.equal(SEPARATORS.length, 4);
});

// ---------------------------------------------------------------------------
// splitStats 的算法本身
// ---------------------------------------------------------------------------
test('splitStats：accuracy 封顶 1、题数不符时 countOk=false', () => {
  const text = readFixture('sample-02-plain.txt');
  const result = splitQuestions(text);

  // 声明 10 题、实际 10 题 -> 全对
  assert.equal(splitStats(result, 10).countOk, true);
  assert.equal(splitStats(result, 10).accuracy, 1);

  // 声明 20 题、实际 10 题 -> countOk=false，accuracy=0.5（低于 0.9 即不达标）
  const under = splitStats(result, 20);
  assert.equal(under.countOk, false);
  assert.equal(under.accuracy, 0.5);

  // 实际多于声明时封顶 1，不出现 2.0 这种荒谬值
  const over = splitStats(result, 5);
  assert.equal(over.accuracy, 1);

  // expected=0 时不能除零
  assert.equal(splitStats(result, 0).accuracy, 0);
});

// ---------------------------------------------------------------------------
// 边界：空输入、纯编号空壳、编号必须被剥离
// ---------------------------------------------------------------------------
test('splitQuestions：空文本返回空结果，纯编号空壳被丢弃，编号剥离干净', () => {
  assert.deepEqual(splitQuestions('').questions, []);
  assert.deepEqual(splitQuestions('   \n\n  ').questions, []);

  // 只有编号没有内容块的题不能入库（否则会塞一堆空题）
  const shell = splitQuestions('1.\n2.\n3.\n');
  assert.deepEqual(shell.questions, []);

  // 编号必须被吃掉：两次导入同一道题要算出同一个 content_hash，
  // 如果 stem 残留 "1."，polish 过的版本与原始版本就会变成两道题。
  const text = readFixture('sample-01-markdown.md');
  const result = splitQuestions(text);
  for (const q of result.questions) {
    assert.ok(!/^\s*(?:\d{1,3}\s*[.、．]|第\s*\d{1,3}\s*题|[（(]\s*\d{1,3}\s*[）)])/.test(q.stem), `题干残留编号：${q.stem.slice(0, 20)}`);
  }
});

// ---------------------------------------------------------------------------
// 已知局限（写成测试是为了不让它悄悄变得更糟）
// ---------------------------------------------------------------------------
test('已知局限：题干内部的编号列表会被误判为新题起点', () => {
  // 这是规则切题的固有缺陷（用户拍板项 2 接受：V1 上 AI 切题解决）。
  // 写在这里是为了：将来若有人改规则，能看到这条**预期行为**的基线。
  const text = [
    '1. 下列关于步骤的说法正确的是（ ）',
    'A. 步骤如下',
    '（1）先洗菜',
    '（2）再切菜',
    'B. 以上都对',
    '答案：A',
  ].join('\n');

  const result = splitQuestions(text);
  // 预期：`（1）` `（2）` 被当成新题起点 —— 题数 > 1 就是局限仍在
  assert.ok(result.questions.length > 1, '局限已被修复！请更新本测试并同步 README 的已知局限');
});
