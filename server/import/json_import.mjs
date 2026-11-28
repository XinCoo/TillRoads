// server/import/json_import.mjs
// 题路 TillRoad · m30197：AI 生成 JSON 题库的解析（第 2 阶段的 JSON 分支）
//
// 为什么需要这个文件：
//   m30197 要让「每题自带 subject / node」生效，而 md/txt/csv/pdf/xlsx 都是纯文本，
//   切题阶段 parseBlock 只产出 stem/options/answer/analysis，**拿不到科目与考点**。
//   subject / node 只存在于 AI 按 docs/question-recognition-prompt.md 产出的 JSON 里，
//   所以导入管线必须能直接吃 `questions.json`（提示词文档「五、导入路径」也是这么写的）。
//
// 设计取舍：
//   - 只做「JSON → 与 splitter 输出同形状的题目数组」这一件事，不碰入库；
//   - 形状对齐 splitter：{ stem, options, answer, analysis, detected_type, subject, node }，
//     这样 runImport 后面的清洗 / 判重 / 入库一行都不用改；
//   - 容错从宽：AI 产出常见走样（顶层包一层 {questions:[...]}、类型写成中文、
//     options 写成 ["A. xx"] 或 {"A":"xx"}）都在这里归一化，归不了就记一条 error 跳过该题，
//     **不让整份文件因为一道题的形状问题失败**。
//
// 不引新依赖：JSON.parse 是运行时内置能力。

import { detectQuestionType } from './splitter.mjs';

/** 与 schema 的 question 类型集合一致；用于校验 AI 给的 type 是否可直接采用。 */
const KNOWN_TYPES = new Set([
  'choice',
  'multi',
  'judge',
  'fill',
  'calculation',
  'short_answer',
  'subjective',
  'essay',
  'material',
]);

/**
 * 把 AI 常写的中文题型归一成内部 type。
 * 归一不了返回 null（交给 detectQuestionType 去猜）。
 */
function normalizeType(raw) {
  const text = String(raw ?? '').trim().toLowerCase();
  if (text === '') return null;
  if (KNOWN_TYPES.has(text)) return text;
  const map = {
    单选: 'choice',
    单选题: 'choice',
    选择: 'choice',
    选择题: 'choice',
    多选: 'multi',
    多选题: 'multi',
    判断: 'judge',
    判断题: 'judge',
    填空: 'fill',
    填空题: 'fill',
    计算: 'calculation',
    计算题: 'calculation',
    简答: 'short_answer',
    简答题: 'short_answer',
    论述: 'essay',
    论述题: 'essay',
    材料: 'material',
    材料题: 'material',
    主观: 'subjective',
    主观题: 'subjective',
  };
  return map[text] ?? null;
}

/**
 * 选项归一化成 schema 的 options jsonb 形状：[{key:'A', text:'...'}]。
 *
 * 接受三种常见写法：
 *   1. [{key:'A', text:'...'}]（提示词要求的标准形状）
 *   2. ['A. 选项文字', 'B、选项文字']（人/模型手写的行文本）
 *   3. {'A': '选项文字'}（对象字典）
 */
function normalizeOptions(raw) {
  if (raw === null || raw === undefined) return null;

  if (Array.isArray(raw)) {
    const out = [];
    for (let i = 0; i < raw.length; i += 1) {
      const item = raw[i];
      if (item && typeof item === 'object' && !Array.isArray(item)) {
        const key = String(item.key ?? item.label ?? '').trim();
        const text = String(item.text ?? item.content ?? item.value ?? '').trim();
        if (text === '') continue;
        out.push({ key: key === '' ? letterOf(out.length) : key.toUpperCase(), text });
        continue;
      }
      const line = String(item ?? '').trim();
      if (line === '') continue;
      // "A. 文字" / "A、文字" / "A）文字" / "A" 单字母
      const m = line.match(/^([A-Za-z])[\s.、,，:：)）]\s*(.*)$/);
      if (m) {
        out.push({ key: m[1].toUpperCase(), text: m[2].trim() });
      } else {
        out.push({ key: letterOf(out.length), text: line });
      }
    }
    return out.length > 0 ? out : null;
  }

  if (typeof raw === 'object') {
    const out = [];
    for (const [key, value] of Object.entries(raw)) {
      const text = String(value ?? '').trim();
      if (text === '') continue;
      out.push({ key: String(key).trim().toUpperCase(), text });
    }
    return out.length > 0 ? out : null;
  }

  return null;
}

function letterOf(index) {
  return String.fromCharCode(65 + (index % 26));
}

/** 答案归一化：数组 → 拼字母；"A、B" → "AB"（多选判分要求连写）。 */
function normalizeAnswer(raw) {
  if (raw === null || raw === undefined) return null;
  if (Array.isArray(raw)) {
    const keys = raw
      .map((v) => String(v ?? '').trim().toUpperCase())
      .filter((v) => v !== '');
    return keys.length > 0 ? keys.join('') : null;
  }
  const text = String(raw).trim();
  return text === '' ? null : text;
}

/**
 * 解析 JSON 文本 → 题目数组（与 splitter 的产出同形状，额外保留 subject / node）。
 *
 * @param {string} text JSON 文本（已去 BOM）
 * @returns {{questions: Array<object>, errors: Array<{index:number,reason:string}>, total:number}}
 */
export function parseQuestionJson(text) {
  let data;
  try {
    data = JSON.parse(String(text ?? ''));
  } catch (err) {
    const reason = err && err.message ? String(err.message).slice(0, 200) : 'JSON 解析失败';
    return { questions: [], errors: [{ index: -1, reason }], total: 0 };
  }

  // 允许顶层直接是数组，或包一层 { questions: [...] }
  let list = null;
  if (Array.isArray(data)) {
    list = data;
  } else if (data && typeof data === 'object') {
    for (const key of ['questions', 'items', 'data', 'list']) {
      if (Array.isArray(data[key])) {
        list = data[key];
        break;
      }
    }
  }

  if (!list) {
    return { questions: [], errors: [{ index: -1, reason: 'JSON 顶层既不是数组，也没有 questions 数组' }], total: 0 };
  }

  const questions = [];
  const errors = [];

  list.forEach((raw, index) => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      errors.push({ index, reason: '这一项不是对象' });
      return;
    }

    const stem = String(raw.stem ?? raw.question ?? raw.title ?? '').trim();
    if (stem === '') {
      errors.push({ index, reason: '缺少 stem（题干）' });
      return;
    }

    const options = normalizeOptions(raw.options ?? raw.choices ?? null);
    const answer = normalizeAnswer(raw.answer ?? raw.correct_answer ?? null);
    const analysis = raw.analysis ?? raw.explain ?? raw.explanation ?? null;

    // 题型：AI 给的能认就用，认不出或没给就交给规则层识别（needs_review 会如实记录）
    const declared = normalizeType(raw.type);
    const detected = detectQuestionType({ stem, options, answer });
    const detected_type = declared
      ? { type: declared, confidence: 'high', needsReview: false, reason: 'json_declared' }
      : detected;

    questions.push({
      stem,
      options,
      answer,
      analysis: analysis === null || analysis === undefined ? null : String(analysis).trim() || null,
      separator: 'json',
      startLine: index + 1,
      endLine: index + 1,
      detected_type,
      // ★ 本轮新增：每题自带的归属信息（只有 JSON 才有）
      subject: raw.subject === null || raw.subject === undefined ? '' : String(raw.subject).trim(),
      node: raw.node === null || raw.node === undefined ? '' : String(raw.node).trim(),
    });
  });

  return { questions, errors, total: list.length };
}

/** JSON 题库里是否有任何一道题带 subject（B1 的「文件里没有 subject 字段就回落统一指定」据此判断）。 */
export function hasAnySubject(questions = []) {
  return questions.some((q) => String(q?.subject ?? '').trim() !== '');
}
