// core/text.mjs
// 题路 TillRoad · 题目文本清洗（纯函数，零依赖、零 I/O）
//
// 与 core/index.mjs 的 normalizeQuestionText 是**两件事**，不要混：
//   * 清洗（本文件）= 展示层：把「下划线占位符」换成「括号占位符」，让题干读起来像人话；
//   * 归一化（index.mjs）= 指纹层：算 content_hash 用的规范化，口径不能因为清洗而变。
//
// 规则（逐条实现，测试逐条锁住）：
//   1. 输入 null / undefined → 返回 ''（空字符串）。
//   2. 非字符串 → 先 String(text) 转字符串再处理。
//   3. 把**连续 2 个及以上**的下划线占位符统一替换成 '（  ）'
//      （全角左括号 + 两个空格 + 全角右括号）。
//      - 匹配的下划线字符：ASCII '_'（U+005F）与全角 '＿'（U+FF3F）。
//      - 「连续」指同一段下划线序列长度 ≥ 2；ASCII 与全角混排时按整段序列处理。
//      - 序列内部**不允许**夹杂空格：'_ _' 不算连续，保持原样。
//      - 单个下划线保留原样（a_b、1_2 这类不是占位符）。
//   4. 替换后的文本其余部分**原样保留**：不做全角转半角、不删空白、不 trim。
//   5. 空字符串 / 全空白 → 原样返回（不 trim）。
//
// 为什么不做全角转半角 / 不删空白：清洗只负责「占位符长什么样」，
// 其它格式问题交给展示层或 normalizeQuestionText，避免这里悄悄改掉用户的原文。

/** 下划线占位符的统一形态：全角左括号 + 两个空格 + 全角右括号。 */
export const UNDERSCORE_PLACEHOLDER = '（  ）';

/**
 * 连续 ≥2 个下划线（ASCII 与全角混排算同一段序列）。
 * 注意：字符类里不含空格，所以 '_ _' 不会被当成一段 —— 这是需求明确要求的。
 */
const UNDERSCORE_RUN_RE = /[_\uFF3F]{2,}/g;

/**
 * 清洗题目文本：把下划线占位符换成括号占位符。
 *
 * @param {unknown} text 原始文本（null/undefined → ''；非字符串先 String()）
 * @returns {string} 清洗后的文本（其余部分原样保留，不 trim）
 */
export function sanitizeQuestionText(text) {
  if (text === null || text === undefined) return '';
  const s = typeof text === 'string' ? text : String(text);
  if (s === '') return '';
  // String.replace 遇到带 /g 的正则会自行重置 lastIndex，这里可安全复用常量正则。
  return s.replace(UNDERSCORE_RUN_RE, UNDERSCORE_PLACEHOLDER);
}

/**
 * 统计文本里被清洗掉的占位符个数（纯函数，给导入统计用）。
 *
 * @param {unknown} text
 * @returns {number} 占位符个数（0 表示没有连续下划线）
 */
export function countUnderscorePlaceholders(text) {
  if (text === null || text === undefined) return 0;
  const s = typeof text === 'string' ? text : String(text);
  if (s === '') return 0;
  const m = s.match(UNDERSCORE_RUN_RE);
  return m ? m.length : 0;
}
