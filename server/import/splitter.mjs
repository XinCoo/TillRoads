// server/import/splitter.mjs
// 题路 TillRoad · BE-02：规则切题（纯函数，零依赖）
//
// 为什么单独一个文件、且必须是纯函数：
//   * 它是整条导入管线里唯一「可能错得很隐蔽」的一段——切错边界会把两道题粘成一道，
//     入库后 content_hash 也一起错，事后极难回溯。独立 + 可单测是唯一防线。
//   * 不 import pdfjs-dist（文本抽取在 extract.mjs）、不 import pg（不碰库）。
//     这样它能被 Node 直接跑、被 Dart 端移植时逐字对照。
//
// MVP 只做规则切题，不上 AI（拍板项 2）。分隔符假设固定四类，见 SEPARATORS。
// 已知局限（写进 README）：题干内部的编号列表会被误判为新题起点；这只能靠
//   「切完人工校对」兜住，V1 上 AI 切题才能真正解决。

/**
 * 四类题目起始分隔符（拍板项 2）。
 * 顺序即优先级：`第1题` 必须在 `1.` 之前判，否则「第1题：」不会被识别为 di 型
 * （它本身不以数字开头，实际不会冲突，但保持「更具体的在前」这个习惯）。
 *
 * 每个正则都必须只吃「行首」的编号，且把编号后的分隔标点一并吃掉，
 * 否则切出来的 stem 会残留 "1." 前缀，导致同一道题两次导入 hash 不同。
 */
export const SEPARATORS = Object.freeze([
  {
    key: 'di',
    // 第1题 / 第 12 题 —— 中文试卷最常见的写法
    re: /^\s*第\s*(\d{1,3})\s*题\s*[.、．:：]?\s*/,
  },
  {
    key: 'arabic',
    // 1. / 1、 / 1．（全角点）
    // 注意不匹配 "1.5" 这种小数：要求标点后不是数字。
    re: /^\s*(\d{1,3})\s*[.、．]\s*(?!\d)/,
  },
  {
    key: 'paren',
    // （1） / (1) —— 全角半角都收
    re: /^\s*[（(]\s*(\d{1,3})\s*[）)]\s*/,
  },
  {
    key: 'cn_num',
    // 一、 / 十二、
    re: /^\s*([一二三四五六七八九十百]{1,4})\s*、\s*/,
  },
]);

/** 选项行：A. / A、 / （A） / (A) */
const OPTION_RE = /^\s*[（(]?([A-Ha-h])\s*[）)]?\s*[.、．:：]\s*(.*)$/;

/** 答案行：答案：/ 参考答案:/ */
const ANSWER_RE = /^\s*(?:参考答案|正确答案|答案)\s*[:：]\s*(.*)$/;

/** 解析行：解析：/ 答案解析:/ */
const ANALYSIS_RE = /^\s*(?:答案解析|解析)\s*[:：]\s*(.*)$/;

/**
 * 判断一行是否是「新题起点」。
 * @returns {{key: string, label: string} | null}
 */
export function matchSeparator(line) {
  if (typeof line !== 'string') return null;
  const text = line.replace(/\r$/, '');
  for (const sep of SEPARATORS) {
    const m = sep.re.exec(text);
    if (m) {
      // 把编号本身也回传，便于日志与人工校对定位（不进 content_hash）
      return { key: sep.key, label: m[1] };
    }
  }
  return null;
}

/**
 * 切题主函数。
 *
 * @param {string} text 原始文本（任意换行风格）
 * @returns {{questions: Array<{stem:string,options:Array<{key:string,text:string}>|null,
 *            answer:string|null,analysis:string|null,separator:string,
 *            startLine:number,endLine:number}>, preamble: string[]}}
 *   preamble = 第一道题之前的行（卷头说明等），不计入题目，但保留给调用方做
 *   「本文件其实没切出题」的提示。
 */
export function splitQuestions(text) {
  const lines = String(text ?? '').replace(/\r\n?/g, '\n').split('\n');

  const blocks = [];
  let current = null;
  const preamble = [];

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const sep = matchSeparator(line);

    if (sep) {
      if (current) blocks.push(current);
      // 丢掉分隔符本身（含编号），只保留其后的内容
      const body = line.replace(SEPARATORS.find((s) => s.key === sep.key).re, '');
      current = { separator: sep.key, label: sep.label, startLine: i + 1, lines: [body] };
      continue;
    }

    if (current) {
      current.lines.push(line);
    } else if (line.trim() !== '') {
      preamble.push(line);
    }
  }
  if (current) blocks.push(current);

  const questions = [];
  for (const block of blocks) {
    const parsed = parseBlock(block);
    if (parsed) questions.push(parsed);
  }

  // 每题附一份题型识别结果（detected_type）；不改动 stem/options/answer/analysis
  // 等既有字段形状，向后兼容（老调用方只会多看到一个新字段）。
  for (const q of questions) {
    q.detected_type = detectQuestionType(q);
  }

  return { questions, preamble };
}

// ---------------------------------------------------------------------------
// 题型自动识别（关键词 + 结构启发式，纯函数、零依赖）
//
// 输入：parseBlock 的产物 { stem, options, answer, analysis }
// 输出：{ type, confidence: 'high'|'medium'|'low', needsReview: boolean, reason }
//
// 规则表（判定顺序自上而下，命中即止）：
//   1. 判断题  judge       —— 题干/答案出现「判断/对错/正确与否/是否正确」等关键词，
//                              或答案是「正确/错误/对/错/√/×/T/F」
//   2. 多选题  multi       —— 有选项(≥2) 且答案是多个选项字母（ABC / A、B / ABD）
//   3. 单选题  choice      —— 有选项(≥2) 且答案是单个字母（A / A. / A、）
//   4. 填空题  fill        —— 无选项 且 题干含成对空括号（）/( )/（  ）或连续下划线占位
//   5. 主观题  short_answer —— 无选项 且 题干较长（简述/论述/解答/分析/说明/证明 或 长度 > 60）
//   6. 兜底    choice      —— 以上都不命中：沿用历史默认题型，但 needsReview=true、
//                              confidence='low'，提示人工确认
//
// 其它约定：
//   * answer 为 null（没有答案行）时 confidence 降为 'medium'（无法判分）；
//   * 有选项但没答案 → 给 'choice'（不判多选），needsReview=true（单选/多选不可分）；
//   * 识别失败**不阻塞导入**：调用方拿 needsReview 决定是否落库为默认题型。
// ---------------------------------------------------------------------------

/** 判断题关键词：题干或答案里出现即判 judge。 */
const JUDGE_KEYWORDS = ['判断', '对错', '正确与否', '是否正确', '正误'];

/** 判断题的「答案值」：正确/错误/对/错/√/×/T/F。 */
const JUDGE_ANSWER_VALUES = new Set(['正确', '错误', '对', '错', '√', '×', 'T', 'F', 't', 'f']);

/** 主观题关键词：题干里出现即判 short_answer（无选项时）。 */
const SUBJECTIVE_KEYWORDS = ['简述', '论述', '解答', '分析', '说明', '证明'];

/** 填空占位：成对空括号（各种写法）或连续 ≥2 个下划线（ASCII / 全角）。 */
const FILL_PLACEHOLDER_RE = /（\s*）|\(\s*\)|[_\uFF3F]{2,}/;

/** 从答案串里抽出「选项字母集合」：按 ,、;；/ 空格 分隔，纯字母 token 逐字展开。 */
function answerLetters(answer) {
  if (typeof answer !== 'string') return [];
  const out = [];
  for (const token of answer.split(/[,、;；\/\s]+/)) {
    const t = token.replace(/[.。．:：]/g, '');
    if (!t) continue;
    if (/^[A-Ha-h]+$/.test(t)) {
      for (const ch of t.toUpperCase()) out.push(ch);
    }
  }
  return out;
}

/** 答案是否「只含一个选项字母」（允许 A / A. / A、 / （A） 等写法）。 */
function isSingleLetterAnswer(answer) {
  if (typeof answer !== 'string') return false;
  const t = answer.trim();
  if (!t) return false;
  return /^[（(]?[A-Ha-h][）)]?\s*[.、．:：]?$/.test(t);
}

/**
 * 识别单道题的题型。
 *
 * @param {{stem?:string, options?:Array<{key:string,text:string}>|null,
 *          answer?:string|null, analysis?:string|null}} question
 * @returns {{type:string, confidence:'high'|'medium'|'low', needsReview:boolean, reason:string}}
 */
export function detectQuestionType(question) {
  const q = question || {};
  const stem = typeof q.stem === 'string' ? q.stem : '';
  const answer = typeof q.answer === 'string' ? q.answer.trim() : '';
  const hasAnswer = answer !== '';
  const optionCount = Array.isArray(q.options) ? q.options.length : 0;
  const hasOptions = optionCount >= 2;

  // 规则 1：判断题
  const stemHit = JUDGE_KEYWORDS.some((k) => stem.includes(k));
  const ansHit = JUDGE_KEYWORDS.some((k) => answer.includes(k));
  const ansValueHit = JUDGE_ANSWER_VALUES.has(answer);
  if (stemHit || ansHit || ansValueHit) {
    return {
      type: 'judge',
      confidence: hasAnswer ? 'high' : 'medium',
      needsReview: false,
      reason: ansValueHit
        ? '命中判断题答案值（正确/错误/对/错/√/×/T/F）'
        : '命中判断题关键词（判断/对错/正确与否/是否正确）',
    };
  }

  // 规则 2 / 3：有选项的单选 / 多选
  if (hasOptions) {
    const letters = [...new Set(answerLetters(answer))];
    if (letters.length >= 2) {
      return {
        type: 'multi',
        confidence: hasAnswer ? 'high' : 'medium',
        needsReview: false,
        reason: `命中选项行（${optionCount} 项）且答案为多个选项字母（${letters.join('')}）`,
      };
    }
    if (isSingleLetterAnswer(answer) || letters.length === 1) {
      return {
        type: 'choice',
        confidence: hasAnswer ? 'high' : 'medium',
        needsReview: false,
        reason: '命中选项行且答案为单个选项字母',
      };
    }
    // 有选项但没有答案行：无法区分单选 / 多选
    if (!hasAnswer) {
      return {
        type: 'choice',
        confidence: 'medium',
        needsReview: true,
        reason: '命中选项行但没有答案行，无法区分单选与多选，请人工确认',
      };
    }
    // 有选项但答案不是字母（如「正确」「以上都对」）：结构上是选择题
    return {
      type: 'choice',
      confidence: 'medium',
      needsReview: true,
      reason: '命中选项行但答案不是选项字母，无法判定单选或多选，请人工确认',
    };
  }

  // 规则 4：填空题（无选项 + 占位符）
  if (!hasOptions && FILL_PLACEHOLDER_RE.test(stem)) {
    return {
      type: 'fill',
      confidence: hasAnswer ? 'high' : 'medium',
      needsReview: false,
      reason: '无选项且题干含空括号或下划线占位符，判为填空题',
    };
  }

  // 规则 5：主观 / 解答题（无选项 + 题干较长或含主观题关键词）
  if (!hasOptions) {
    const kw = SUBJECTIVE_KEYWORDS.find((k) => stem.includes(k));
    if (kw || stem.length > 60) {
      return {
        type: 'short_answer',
        confidence: hasAnswer ? 'high' : 'medium',
        needsReview: false,
        reason: kw
          ? `无选项且题干含「${kw}」等主观题关键词`
          : `无选项且题干长度 ${stem.length} > 60，判为主观题`,
      };
    }
  }

  // 规则 6：兜底
  return {
    type: 'choice',
    confidence: 'low',
    needsReview: true,
    reason: '无法可靠识别，请人工确认',
  };
}

/**
 * 把一个 block 拆成 stem / options / answer / analysis。
 * 返回 null 表示这个 block 是空壳（只有编号没有内容）——直接丢弃，
 * 否则会往库里塞一群空题。
 */
function parseBlock(block) {
  const stemLines = [];
  const options = [];
  let answer = null;
  let analysis = null;
  let mode = 'stem'; // stem -> options -> answer -> analysis

  for (const raw of block.lines) {
    const line = raw.replace(/\s+$/, '');
    if (line.trim() === '') {
      // 空行不打断选项/答案收集，只在 stem 阶段算作分隔
      if (mode === 'stem' && stemLines.length > 0) stemLines.push('');
      continue;
    }

    // 答案解析要在选项之前判：答案行本身可能长得像 "A. 3"
    const answerMatch = ANSWER_RE.exec(line);
    if (answerMatch) {
      mode = 'answer';
      answer = answerMatch[1].trim();
      continue;
    }

    const analysisMatch = ANALYSIS_RE.exec(line);
    if (analysisMatch) {
      mode = 'analysis';
      analysis = analysisMatch[1].trim();
      continue;
    }

    if (mode === 'answer') {
      // 答案可能折行，继续拼接
      answer = `${answer} ${line.trim()}`.trim();
      continue;
    }
    if (mode === 'analysis') {
      analysis = `${analysis} ${line.trim()}`.trim();
      continue;
    }

    // stem 阶段之后遇到选项行才进 options 模式，避免把题干里的 "A." 误判
    const optionMatch = OPTION_RE.exec(line);
    if (optionMatch && (mode === 'stem' || mode === 'options')) {
      mode = 'options';
      options.push({ key: optionMatch[1].toUpperCase(), text: optionMatch[2].trim() });
      continue;
    }

    if (mode === 'stem') stemLines.push(line);
    else if (mode === 'options') {
      // 选项文字折行
      const last = options[options.length - 1];
      last.text = `${last.text} ${line.trim()}`.trim();
    }
  }

  const stem = stemLines.join('\n').trim();
  if (!stem) return null;

  return {
    stem,
    options: options.length > 0 ? options : null,
    answer: answer || null,
    analysis: analysis || null,
    separator: block.separator,
    startLine: block.startLine,
    endLine: block.startLine + block.lines.length,
  };
}

/**
 * 切题质量自检：给集成测试与人工校对共用。
 * 准确率定义（拍板项 2 的 ≥90% 怎么算）：以「样本里标注的题目数」为分母，
 * 切出的题数、以及每道题 stem 是否非空为分子——空题/漏题都算错。
 */
export function splitStats(result, expectedCount) {
  const questions = (result && result.questions) || [];
  const nonEmpty = questions.filter((q) => q.stem && q.stem.trim() !== '').length;
  const expected = Number(expectedCount) || 0;
  const countOk = questions.length === expected;
  return {
    expected,
    actual: questions.length,
    nonEmpty,
    countOk,
    accuracy: expected === 0 ? 0 : Math.min(1, nonEmpty / expected),
  };
}
