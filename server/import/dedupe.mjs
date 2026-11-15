// server/import/dedupe.mjs
// 题路 TillRoad · BE-02：导入管线第 3 阶段（规范化去重）
//
// 关键约束：content_hash **必须复用 core/index.mjs 的 normalizeQuestionText**，
// 不许在这里另写一份归一化。理由：
//   1. schema.sql 的 normalize_question_text() 触发器函数、Node 规则层、导入管线
//      必须对「同一道题」算出同一个 hash，否则同一道题能进库两次；
//   2. 归一化规则（全角标点、顿号→逗号、去空白、选项稳定排序）有任何调整时，
//      只能改一处 —— 三份实现各自维护是历史 bug 的来源。
//
// 不落库、不 import pg：只吃一个「能 .query() 的 client」，
// 这样单测可以用 fake client，集成测试用真 PG。

import { normalizeQuestionText } from '../../core/index.mjs';

/**
 * 计算一题的 content_hash。
 * options 传数组（[{key,text}]）时 normalizeQuestionText 内部会做稳定排序 +
 * JSON.stringify，所以「选项顺序不同但内容相同」的两道题会得到同一个 hash。
 */
export function contentHashOf(question = {}) {
  return normalizeQuestionText(
    question.stem ?? '',
    question.options ?? null,
    question.formula_text ?? question.formula ?? null,
  );
}

/**
 * 去重：把「库里已存在的」与「新的」分开。
 *
 * @param {Array<object>} questions splitQuestions 的产出（可带 formula_text）
 * @param {{query: Function}} client pg Pool / PoolClient / fake client
 * @returns {Promise<{newQuestions: Array<object>, duplicates: Array<{content_hash: string, existing_id: string, stem: string}>}>}
 *
 * 为什么用一次 IN 查询而不是逐题 SELECT：一份 20 题的样本会产生 20 次往返，
 * 而 IN 一次就够。同时在批内也去重（同一份文件里出现两遍同一道题，
 * 第二次也应算重复，否则入库时唯一性判断会打架）。
 */
export async function dedupe(questions = [], client) {
  const prepared = [];
  const seenInBatch = new Map(); // hash -> stem，用于批内去重

  const duplicates = [];

  for (const q of questions) {
    const hash = contentHashOf(q);
    const withHash = { ...q, content_hash: hash };

    const prev = seenInBatch.get(hash);
    if (prev !== undefined) {
      // 批内重复：existing_id 留 null（库里还没有），但客户端仍应看到这条提示，
      // 否则「一导入就少一题」会让人以为是切题漏了。
      duplicates.push({ content_hash: hash, existing_id: null, stem: q.stem ?? '' });
      continue;
    }
    seenInBatch.set(hash, q.stem ?? '');
    prepared.push(withHash);
  }

  if (prepared.length === 0) {
    return { newQuestions: [], duplicates };
  }

  const hashes = prepared.map((q) => q.content_hash);
  const { rows } = await client.query(
    `SELECT id, content_hash
       FROM questions
      WHERE content_hash = ANY($1::text[])
        AND deleted_at IS NULL`,
    [hashes],
  );

  const existing = new Map(rows.map((r) => [r.content_hash, r.id]));

  const newQuestions = [];
  for (const q of prepared) {
    const existingId = existing.get(q.content_hash);
    if (existingId) {
      duplicates.push({ content_hash: q.content_hash, existing_id: existingId, stem: q.stem ?? '' });
    } else {
      newQuestions.push(q);
    }
  }

  return { newQuestions, duplicates };
}
