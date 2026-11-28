// server/import/resolve_subject.mjs
// 题路 TillRoad · m30197 任务 A1：按「题目自带的科目文本」匹配已有科目
//
// 背景：题库生成提示词扩展后，AI 产出的每道题都带 subject（用户填的科目名）。
// 导入时用它决定题目归属，比「整批塞进同一个 subject_id」更贴近真实使用。
//
// 匹配顺序（命中即停）：
//   1. 该用户全部 active 目标下的科目里，name 与文本**完全相等**（大小写不敏感）；
//   2. name 包含文本（"行测" 命中 "行测-资料分析"）；
//   3. 文本包含 name（"行测-资料分析" 命中 "行测"，名字更短更泛）；
//   4. 都没有 → 返回 null，由调用方回落到请求里的默认 subject_id。
//      ★ 硬约束：subject 匹配失败**不自动建科目**（自动建会让一个错别字凭空长出一个科目）。
//
// 为什么不用 subjects 表上的 user_id 过滤：subjects 没有 user_id 列，归属靠
//   exam_profile_id。所以「某用户的科目」= subjects JOIN exam_profiles ON user_id。
//
// 为什么要排除 archived 目标：归档目标下的科目不该再接收新题（用户已明确不考了），
//   否则导入会悄悄往旧目标里塞数据。
//
// 纯查询 + 纯返回，不抛业务错误：导入是「尽量归对」，匹配不上不是错误。

import { isBlank, queryMany } from '../repositories/_common.mjs';

/** 一次导入最多缓存多少条科目（用户科目量级为几十，设 500 足够且不会失控）。 */
const CACHE_LIMIT = 500;

/**
 * 取某用户所有可接收新题的科目（含所属目标 id，便于返回给前端展示）。
 *
 * @param {object} client PG 客户端（事务内）
 * @param {string} userId
 * @returns {Promise<Array<{id:string,name:string,exam_profile_id:string}>>}
 */
async function listCandidateSubjects(client, userId) {
  return queryMany(
    client,
    `SELECT s.id, s.name, s.exam_profile_id
       FROM subjects s
       JOIN exam_profiles ep ON ep.id = s.exam_profile_id
      WHERE ep.user_id = $1
        AND ep.deleted_at IS NULL
        AND ep.status = 'active'
        AND s.deleted_at IS NULL
      ORDER BY s.created_at ASC, s.id ASC
      LIMIT ${CACHE_LIMIT}`,
    [userId],
  );
}

/** 归一化用于比较的文本：去首尾空白 + 折叠中间空白 + 小写。 */
function normalize(text) {
  return String(text).replace(/\s+/g, ' ').trim().toLowerCase();
}

/**
 * 在候选科目里挑一个最贴合的。
 *
 * 「最贴合」的判定刻意按档位（exact > name-contains > text-contains），
 * 同档位内取**名字最短**的那个 —— 短名更泛、更像用户心里的「大科目」，
 * 也更不容易是某个误建的怪名字。
 *
 * @param {Array<{id:string,name:string}>} candidates
 * @param {string} subjectText
 * @returns {{row:object, how:'exact'|'contains'|'contained'}|null}
 */
function pickBest(candidates, subjectText) {
  const want = normalize(subjectText);

  const exact = candidates.filter((s) => normalize(s.name) === want);
  if (exact.length > 0) {
    return { row: shortest(exact), how: 'exact' };
  }

  const nameContainsWant = candidates.filter((s) => normalize(s.name).includes(want));
  if (nameContainsWant.length > 0) {
    return { row: shortest(nameContainsWant), how: 'contains' };
  }

  const wantContainsName = candidates.filter((s) => {
    const name = normalize(s.name);
    return name !== '' && want.includes(name);
  });
  if (wantContainsName.length > 0) {
    return { row: shortest(wantContainsName), how: 'contained' };
  }

  return null;
}

function shortest(rows) {
  return rows.reduce((best, cur) => (cur.name.length < best.name.length ? cur : best), rows[0]);
}

/**
 * 解析每道题的 subject 文本 → 库里的科目。
 *
 * 为了「一次导入内不重复查库」，这里带一个小缓存：同样的科目文本只查一次。
 *
 * @param {object} client
 * @param {{subjectText?: string, userId?: string}} input
 * @returns {Promise<{subject_id: string, name: string, how: string}|null>}
 */
export async function resolveSubject(client, { subjectText = '', userId = '' } = {}) {
  if (isBlank(subjectText) || isBlank(userId)) return null;

  const candidates = await listCandidateSubjects(client, userId);
  if (candidates.length === 0) return null;

  const picked = pickBest(candidates, subjectText);
  if (!picked) return null;

  return { subject_id: picked.row.id, name: picked.row.name, how: picked.how };
}

/**
 * 带缓存的批量解析器：一次导入里 N 道题往往只有 1~3 个不同科目文本，
 * 每道题都跑一次全表查询既慢又没必要。
 *
 * 用法：
 *   const resolver = createSubjectResolver(client, userId);
 *   const hit = await resolver('行测');   // 内部只对第一次 '行测' 查库
 *
 * @param {object} client
 * @param {string} userId
 */
export function createSubjectResolver(client, userId) {
  const cache = new Map();

  return async function resolve(subjectText) {
    if (isBlank(subjectText)) return null;
    const key = normalize(subjectText);
    if (cache.has(key)) return cache.get(key);
    const hit = await resolveSubject(client, { subjectText, userId });
    cache.set(key, hit);
    return hit;
  };
}
