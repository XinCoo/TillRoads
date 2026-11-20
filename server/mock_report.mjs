// server/mock_report.mjs
// 题路 TillRoad · BE-05 T3：模考报告生成（纯函数、零依赖、可单测）
//
// 为什么单独一个文件：
//   报告的四项指标全是「一堆数进去、几个数出来」的计算，没有任何 I/O。
//   放进仓储模块会被 pg / 事务搅在一起，只能靠集成测试验证；
//   抽成纯函数就能用 node:test 直接跑边界（全对 / 全错 / 首次 stability=null）。
//
// 与 grader 的分工：
//   gradeAnswer() 负责「这道题的答案对不对」，reportGenerator() 负责「整卷的四项指标」。
//   两者都在本文件，因为判分口径（大小写、全半角、空白）会直接影响正确率口径，
//   拆到两个文件迟早漂移。
//
// ★ 关于 strategy_execution：刻意不做，恒返回 null。
//   该指标的定义是「该跳的题是否跳了」，但 MVP 没有记录「跳过」这个行为
//   （提交只带作答数组，没作答与主动跳过无法区分），强行计算就是伪指标。
//   等前端能上报 skip 事件后再实现，届时本文件加第五项即可。

/** 无法归属到任何考点的题，在 module_accuracy / avg_duration_ms 里用这个键兜底。 */
export const UNGROUPED = '__ungrouped__';

/** 报告里出现的四个业务键（strategy_execution 恒 null，不计入）。 */
export const REPORT_METRICS = Object.freeze([
  'module_accuracy',
  'avg_duration_ms',
  'stability',
  'defect_repeat_rate',
]);

// ---------------------------------------------------------------------------
// 判分
// ---------------------------------------------------------------------------

/** 判分时忽略的字符：空白（含全角空格）与常见全半角标点。 */
const IGNORED_IN_ANSWER_RE = /[\s\u3000，。！？；：（）【】《》、,.!?;:()[\]<>"'`]/g;

/**
 * 答案归一：去空白、去标点、统一大写。
 *
 * 只做这一层，不做同义词 / 数学等价 / 单位换算 —— 那是「智能判分」，不在 MVP 范围。
 * 目的仅是让 `A`、`a `、`Ａ` 之类的手写差异不误判（全角字母由 toUpperCase 之后的
 * 全角字符不受影响，故另用 normalize('NFKC') 折半）。
 */
export function normalizeAnswerText(value) {
  if (value === null || value === undefined) return '';
  return String(value)
    .normalize('NFKC')
    .replace(IGNORED_IN_ANSWER_RE, '')
    .toUpperCase();
}

/**
 * 该题能否自动判分。
 *
 * 主观题（is_subjective=true）与 essay / short_answer 没有唯一答案，
 * 自动判分必然错，故返回 false，其作答记为 is_correct=null（不参与正确率分母）。
 */
export function isAutoGradable(question = {}) {
  if (question.is_subjective === true) return false;
  const type = question.type == null ? '' : String(question.type);
  if (type === 'essay' || type === 'short_answer') return false;
  return true;
}

/**
 * 判一道题。
 *
 * @param {object} question  {answer, type, is_subjective}
 * @param {*} answerText     用户作答（字符串或 null）
 * @returns {boolean|null}   true/false；无法判分（主观题、题库无标准答案）→ null
 */
export function gradeAnswer(question = {}, answerText) {
  if (!isAutoGradable(question)) return null;
  const expected = normalizeAnswerText(question.answer);
  // 题库里没有标准答案（answer 为 null/空）时不能判错 —— 那是数据缺失，不是用户答错。
  if (expected === '') return null;
  const actual = normalizeAnswerText(answerText);
  if (actual === '') return false; // 有标准答案但没作答 = 错
  return actual === expected;
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

function round6(x) {
  return Math.round(x * 1e6) / 1e6;
}

/**
 * 变异系数 cv = 标准差 / 均值（popluation 口径，除以 n）。
 *
 * 用总体口径而非样本口径：这里把「近 3 次」当作完整总体，不是从更大总体抽样。
 * 均值 == 0 时 cv 无定义（分母为 0）→ null，避免 Infinity / NaN 流进 JSON。
 */
export function coefficientOfVariation(values = []) {
  const nums = (values || []).filter((v) => typeof v === 'number' && Number.isFinite(v));
  if (nums.length === 0) return null;
  const mean = nums.reduce((a, b) => a + b, 0) / nums.length;
  if (mean === 0) return null;
  const variance = nums.reduce((a, b) => a + (b - mean) ** 2, 0) / nums.length;
  return round6(Math.sqrt(variance) / mean);
}

/**
 * 一张模考卷的总正确率（供 stability 读取历史模考）。
 *
 * mock.questions 是 schema 里 jsonb 的原始形状：
 *   [{question_id, attempt_id, is_correct, duration_ms}]
 * 未判分（is_correct=null）的行不计入分母。
 *
 * @returns {number|null} 无有效判分行时 null
 */
export function mockAccuracy(mock = {}) {
  const rows = Array.isArray(mock.questions) ? mock.questions : [];
  let correct = 0;
  let total = 0;
  for (const row of rows) {
    if (!row || typeof row !== 'object') continue;
    if (row.is_correct === true) {
      correct += 1;
      total += 1;
    } else if (row.is_correct === false) {
      total += 1;
    }
  }
  return total > 0 ? correct / total : null;
}

/**
 * 稳定度 = 近 N 次（默认 3）模考总正确率的变异系数。
 *
 * 抽出来供 BE-06 复盘复用：复盘只需要这一个数，若让复盘再去调完整
 * reportGenerator，就得先造出 questions/attempts 等一堆它用不着的数据。
 * 本函数只依赖 mockAccuracy()，与 reportGenerator 内的算法逐字一致
 * （reportGenerator 现在也调本函数，不会出现两份口径）。
 *
 * @param {Array<object>} mocks  按时间倒序的模考记录（取前 3 条有效值）
 * @param {number} window        窗口大小，默认 3
 * @returns {number|null}        有效样本 <2 个时 null（单点无「波动」可言）
 */
export function computeStability(mocks = [], window = 3) {
  const accuracies = [];
  for (const m of mocks || []) {
    const a = mockAccuracy(m);
    if (a !== null) accuracies.push(round6(a));
    if (accuracies.length >= window) break;
  }
  const win = accuracies.slice(0, window);
  return win.length < 2 ? null : coefficientOfVariation(win);
}

// ---------------------------------------------------------------------------
// 报告
// ---------------------------------------------------------------------------

/**
 * 生成模考报告。
 *
 * @param {object}   input
 * @param {Array}    input.questions     本次卷子的题：[{question_id, knowledge_node_id, knowledge_node_title}]，
 *                                      考点名兼容 `knowledge_node_title` 与 `title` 两种键名
 *                                      （仓储 mock_exams.mjs 传的是后者）
 * @param {Array}    input.attempts      判分后的作答：[{question_id, is_correct, duration_ms}]
 * @param {Array}    input.closedDefects 该用户的缺陷单（**status 为 'CLOSED' 或 'V3'**）：
 *                                       [{id|defect_ticket_id, question_id, knowledge_node_id, status}]
 *                                       名字叫 closedDefects 是历史原因（第一版只要 CLOSED），
 *                                       现在同时承载 V3 候选匹配所需的行 —— 统一一次查询取回两种状态。
 * @param {Array}    input.recentMocks   同 mode + 同 exam_profile 的历史已提交模考（不含本次）：[{questions}]
 *
 * @returns {{
 *   module_accuracy: Object<string,{title,correct,total,accuracy,ungraded}>,
 *   avg_duration_ms: {overall:number|null, by_knowledge_node:Object},
 *   stability: number|null,
 *   defect_repeat_rate: {repeat_count:number,total_wrong:number,rate:number},
 *   strategy_execution: null,
 *   v3_candidates: Array<{defect_ticket_id,question_id,knowledge_node_id}>,
 *   overall: {correct:number,total:number,accuracy:number|null,ungraded:number},
 *   ungraded_count: number
 * }}
 */
export function reportGenerator({
  questions = [],
  attempts = [],
  closedDefects = [],
  recentMocks = [],
} = {}) {
  const attemptByQuestion = new Map();
  for (const a of attempts || []) {
    if (a && a.question_id != null) attemptByQuestion.set(String(a.question_id), a);
  }

  const moduleAcc = new Map();
  const moduleDur = new Map();
  let correct = 0;
  let gradedTotal = 0;
  let wrong = 0;
  let ungraded = 0;
  let durSum = 0;
  let durCount = 0;

  for (const q of questions || []) {
    if (!q || q.question_id == null) continue;
    const qid = String(q.question_id);
    const attempt = attemptByQuestion.get(qid) || null;
    const key = q.knowledge_node_id == null ? UNGROUPED : String(q.knowledge_node_id);
    // 考点名兼容两种键名：仓储 mock_exams.mjs 提交时传的是 `title`，
    // 而本文件旧版只读 `knowledge_node_title` → 报告里 title 恒 null，
    // 前端只能把考点显示成「考点 <uuid 前 8 位>」。这里同时接受两种，
    // 既修掉新生成的报告，也让库里已有的旧报告不受影响。
    const title = q.knowledge_node_title ?? q.title ?? null;

    if (!moduleAcc.has(key)) moduleAcc.set(key, { title, correct: 0, total: 0, ungraded: 0 });
    const acc = moduleAcc.get(key);
    if (acc.title == null && title != null) acc.title = title;

    if (!moduleDur.has(key)) moduleDur.set(key, { title, count: 0, totalMs: 0 });
    const dur = moduleDur.get(key);
    if (dur.title == null && title != null) dur.title = title;

    const isCorrect = attempt ? attempt.is_correct : null;
    if (isCorrect === true) {
      correct += 1;
      gradedTotal += 1;
      acc.correct += 1;
      acc.total += 1;
    } else if (isCorrect === false) {
      gradedTotal += 1;
      wrong += 1;
      acc.total += 1;
    } else {
      ungraded += 1;
      acc.ungraded += 1;
    }

    const ms =
      attempt && typeof attempt.duration_ms === 'number' && Number.isFinite(attempt.duration_ms)
        ? attempt.duration_ms
        : null;
    if (ms !== null) {
      dur.count += 1;
      dur.totalMs += ms;
      durSum += ms;
      durCount += 1;
    }
  }

  const module_accuracy = {};
  for (const [key, v] of moduleAcc) {
    module_accuracy[key] = {
      title: v.title,
      correct: v.correct,
      total: v.total,
      accuracy: v.total > 0 ? round6(v.correct / v.total) : null,
      ungraded: v.ungraded,
    };
  }

  const byKnowledgeNode = {};
  for (const [key, v] of moduleDur) {
    byKnowledgeNode[key] = {
      title: v.title,
      count: v.count,
      avg_duration_ms: v.count > 0 ? Math.round(v.totalMs / v.count) : null,
    };
  }

  // ---- stability：本次 + 历史（最多共 3 次）的变异系数 ----
  const accuracies = [];
  const currentAccuracy = gradedTotal > 0 ? correct / gradedTotal : null;
  if (currentAccuracy !== null) accuracies.push(round6(currentAccuracy));
  for (const m of recentMocks || []) {
    const a = mockAccuracy(m);
    if (a !== null) accuracies.push(round6(a));
    if (accuracies.length >= 3) break;
  }
  const window3 = accuracies.slice(0, 3);
  const stability = window3.length < 2 ? null : coefficientOfVariation(window3);

  // ---- defect_repeat_rate + v3_candidates ----
  //   两者数据源相同（一次查询取回 status IN ('CLOSED','V3')），但匹配键不同：
  //     · repeat rate 按 question_id 匹配（「这道题我以前错过并已关闭」）
  //     · v3 candidate 按 knowledge_node_id 匹配（拍板项 5 原文）
  const closedByQuestion = new Map();
  const v3ByKnowledgeNode = new Map();
  for (const d of closedDefects || []) {
    if (!d || typeof d !== 'object') continue;
    const defectId = d.defect_ticket_id ?? d.id;
    if (defectId == null) continue;
    if (d.status === 'CLOSED') {
      if (d.question_id == null) continue;
      const qid = String(d.question_id);
      if (!closedByQuestion.has(qid)) closedByQuestion.set(qid, []);
      closedByQuestion.get(qid).push(defectId);
    } else if (d.status === 'V3') {
      if (d.knowledge_node_id == null) continue;
      const kn = String(d.knowledge_node_id);
      if (!v3ByKnowledgeNode.has(kn)) v3ByKnowledgeNode.set(kn, []);
      v3ByKnowledgeNode.get(kn).push(defectId);
    }
  }

  const repeatQuestions = new Set();
  const v3_candidates = [];
  const seenV3 = new Set();
  for (const q of questions || []) {
    if (!q || q.question_id == null) continue;
    const qid = String(q.question_id);
    const attempt = attemptByQuestion.get(qid) || null;
    if (!attempt || attempt.is_correct !== false) continue; // 只看错题

    if (closedByQuestion.has(qid)) repeatQuestions.add(qid);

    if (q.knowledge_node_id == null) continue;
    const kn = String(q.knowledge_node_id);
    for (const defectId of v3ByKnowledgeNode.get(kn) || []) {
      const key = `${defectId}::${qid}`;
      if (seenV3.has(key)) continue;
      seenV3.add(key);
      v3_candidates.push({
        defect_ticket_id: defectId,
        question_id: qid,
        knowledge_node_id: kn,
      });
    }
  }

  const totalWrong = wrong;
  const repeat_count = repeatQuestions.size;
  const defect_repeat_rate = {
    repeat_count,
    total_wrong: totalWrong,
    rate: totalWrong > 0 ? round6(repeat_count / totalWrong) : 0,
  };

  return {
    module_accuracy,
    avg_duration_ms: {
      overall: durCount > 0 ? Math.round(durSum / durCount) : null,
      by_knowledge_node: byKnowledgeNode,
    },
    stability,
    defect_repeat_rate,
    // 拍板项 4：strategy_execution 刻意跳过，恒 null（理由见文件头）
    strategy_execution: null,
    v3_candidates,
    // 以下两项不属「四项指标」，但报告与前端都需要「这次考了多少分」的口径，
    // 且 stability 之外的正确率展示若各算一遍必然漂移，故一并返回。
    overall: {
      correct,
      total: gradedTotal,
      accuracy: gradedTotal > 0 ? round6(correct / gradedTotal) : null,
      ungraded,
    },
    ungraded_count: ungraded,
  };
}
