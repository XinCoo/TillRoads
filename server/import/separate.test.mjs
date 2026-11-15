// server/import/separate.test.mjs
// 题路 TillRoad · BE-02：第四阶段 separateAssets 的单元测试
//
// 这个阶段本轮不写库、不上传、不产生 assets 行，所以测试的「价值锚点」是：
//   1. asset_refs 恒为空数组 —— 防止有人顺手把占位塞进去，导致入库后
//      questions.asset_refs 指向不存在的资产（比没有更糟）。
//   2. 三种占位形态都能识别 —— V1 接对象存储时这份清单直接可用。
//   3. 带 g 标志的正则多次调用不串味 —— lastIndex 残留是最常见的隐性 bug：
//      第一次调用返回 2 条、第二次返回 0 条，而且只在连续调用时复现。

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { findImagePlaceholders, separateAssets } from './separate.mjs';

test('findImagePlaceholders: 识别三种占位形态并正确分类', () => {
  const text = [
    '题的题干在这里 ![图1](asset:abc-123) 后半句',
    '选项 A ![图2](data:image/png;base64,iVBORw0KGgo=) 尾巴',
    '解析里引用 ![图3](https://example.com/x.png)',
  ].join('\n');

  const found = findImagePlaceholders(text);
  assert.equal(found.length, 3);
  assert.deepEqual(found.map((x) => x.kind), ['asset', 'data', 'remote']);
  assert.equal(found[0].url, 'asset:abc-123');
  assert.ok(found[1].url.startsWith('data:image/png'));
  assert.equal(found[2].url, 'https://example.com/x.png');
});

test('findImagePlaceholders: 识别 <img src="..."> 形态', () => {
  const found = findImagePlaceholders('<p>看图 <img src="asset:pic.png" alt="x" /></p>');
  assert.equal(found.length, 1);
  assert.equal(found[0].kind, 'asset');
  assert.equal(found[0].url, 'asset:pic.png');
});

test('findImagePlaceholders: 连续调用结果一致（正则 lastIndex 不残留）', () => {
  const text = '![a](asset:1) 和 ![b](asset:2)';
  const first = findImagePlaceholders(text);
  const second = findImagePlaceholders(text);
  assert.equal(first.length, 2);
  assert.equal(second.length, 2, '第二次调用必须仍返回 2 条（g 标志未重置的典型症状是返回 0 条）');
  assert.deepEqual(first, second);
});

test('findImagePlaceholders: 无图 / 空输入 / 非字符串都返回空数组', () => {
  assert.deepEqual(findImagePlaceholders('纯文字没有图片'), []);
  assert.deepEqual(findImagePlaceholders(''), []);
  assert.deepEqual(findImagePlaceholders(undefined), []);
  assert.deepEqual(findImagePlaceholders(null), []);
  assert.deepEqual(findImagePlaceholders(123), []);
  // 普通链接不是图片，不能被当成占位
  assert.deepEqual(findImagePlaceholders('参考 [文档](https://example.com/doc)'), []);
});

test('separateAssets: asset_refs 恒为空数组（MVP 不落库）', () => {
  const out = separateAssets({
    stem: '看图作答 ![图](asset:xyz)',
    options: [{ key: 'A', text: '选项里也有 ![图2](asset:uvw)' }],
    analysis: '解析里没有图',
  });

  assert.deepEqual(out.asset_refs, [], 'MVP 阶段 asset_refs 必须为空，占位不能进库');
  assert.equal(out.placeholders.length, 2, '题干 1 张 + 选项 1 张');
  assert.deepEqual(out.placeholders.map((p) => p.url), ['asset:xyz', 'asset:uvw']);
});

test('separateAssets: 无图题目返回空数组且不抛错', () => {
  const out = separateAssets({ stem: '一道普通的文字题' });
  assert.deepEqual(out.asset_refs, []);
  assert.deepEqual(out.placeholders, []);
});

test('separateAssets: options 不是数组时不影响题干扫描', () => {
  const out = separateAssets({ stem: '题干有图 ![图](asset:1)', options: null });
  assert.equal(out.placeholders.length, 1);

  const out2 = separateAssets({ stem: '题干有图 ![图](asset:1)', options: 'not-an-array' });
  assert.equal(out2.placeholders.length, 1);
});

test('separateAssets: rawText 参数也会被扫描（V1 定位原图位置用）', () => {
  const out = separateAssets({ stem: '题干' }, '原始文本 ![原图](asset:raw)');
  assert.equal(out.placeholders.length, 1);
  assert.equal(out.placeholders[0].url, 'asset:raw');
});
