// core/index.mjs
// 题路 TillRoad · 核心业务规则层（端无关，零第三方依赖，仅用 Node 内置模块）
// 与 schema.sql 的触发器/约束严格对齐：
//   check_defect_transition() / check_defect_forbidden_phrase() / normalize_question_text()
// 这一层不依赖 Flutter / PostgreSQL，可在 Node 24 直接运行并测试；后续可平滑移植到
// Dart(Flutter) 与 NestJS 后端。所有函数均为纯函数或抛带 .code 的 Error。

import { createHash } from 'node:crypto';

// ---------------------------------------------------------------------------
// 枚举与常量（与 schema.sql 的 ENUM 类型一一对应）
// ---------------------------------------------------------------------------
export const DEFECT_STATUSES = Object.freeze([
  'DRAFT', 'ANALYZED', 'ACTION_DONE', 'V1', 'V2', 'V3', 'REOPENED', 'CLOSED'
]);

export const TRANSITIONS = Object.freeze({
  DRAFT:       ['ANALYZED'],
  ANALYZED:    ['ACTION_DONE'],
  ACTION_DONE: ['V1'],
  V1:          ['V2', 'REOPENED'],
  V2:          ['V3', 'REOPENED'],
  V3:          ['CLOSED', 'REOPENED'],
  REOPENED:    ['ANALYZED'],
  CLOSED:      []
});

// 主文档 AC-DT-02 禁用语（schema.sql check_defect_forbidden_phrase 正则）
export const FORBIDDEN_PHRASES = Object.freeze([
  '粗心', '马虎', '没掌握', '我懂了', '大意', '差不多', '忘了'
]);

export const VERIFY_STAGES = Object.freeze(['V1', 'V2', 'V3']);

export const VERIFY_TYPES = Object.freeze([
  'redo_hidden', 'similar_variant', 'new_question', 'timed_mock', 'teach_back', 'peer_check'
]);

// 主文档 4.5 / FE-06 三次验证窗口
export const STAGE_WINDOWS = Object.freeze({
  V1: Object.freeze({ minDays: 3,   maxDays: 7,   types: ['redo_hidden', 'similar_variant', 'teach_back'] }),
  V2: Object.freeze({ minDays: 7,   maxDays: 14,  types: ['new_question'] }),
  V3: Object.freeze({ minDays: null, maxDays: null, types: ['timed_mock'] })
});

// byok-key-lifecycle.md：MVP provider 锁死
export const AI_PROVIDERS = Object.freeze(['deepseek', 'openai_compatible']);

export const PRIORITY_LEVELS = Object.freeze(['P0', 'P1', 'P2']);

// ---------------------------------------------------------------------------
// 错误工具：统一为带 .code 的 Error，便于 HTTP 层映射状态码
// ---------------------------------------------------------------------------
function fail(code, message, extra = {}) {
  throw Object.assign(new Error(message || code), { code, ...extra });
}

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------
export function canTransition(from, to) {
  if (!DEFECT_STATUSES.includes(from) || !DEFECT_STATUSES.includes(to)) return false;
  return (TRANSITIONS[from] || []).includes(to);
}

export function assertTransition(from, to) {
  if (!canTransition(from, to)) {
    fail('ILLEGAL_DEFECT_TRANSITION', `ILLEGAL_DEFECT_TRANSITION: ${from} -> ${to}`, { from, to });
  }
}

// ---------------------------------------------------------------------------
// 禁用语
// ---------------------------------------------------------------------------
export function findForbiddenPhrases(text) {
  if (typeof text !== 'string' || text.length === 0) return [];
  return FORBIDDEN_PHRASES.filter(p => text.includes(p));
}

export function containsForbiddenPhrase(text) {
  return findForbiddenPhrases(text).length > 0;
}

export function assertNoForbiddenPhrase(text) {
  const phrases = findForbiddenPhrases(text);
  if (phrases.length) {
    fail('FORBIDDEN_PHRASE_IN_ERROR_CAUSE', 'FORBIDDEN_PHRASE_IN_ERROR_CAUSE', { phrases });
  }
}

// ---------------------------------------------------------------------------
// 归因校验（转入 ANALYZED 时）：AC-DT-03 / P0-3 修复
// DRAFT 建单可未归因；仅当进入 ANALYZED 才强制 error_layer/error_cause 且无禁用语。
// ---------------------------------------------------------------------------
export function assertAnalyzable({ status, error_layer, error_cause }) {
  assertTransition(status, 'ANALYZED'); // 仅 DRAFT 或 REOPENED 可进入 ANALYZED
  if (!error_layer || String(error_layer).trim() === '') {
    fail('MISSING_ERROR_LAYER', 'MISSING_ERROR_LAYER');
  }
  if (!error_cause || String(error_cause).trim() === '') {
    fail('MISSING_ERROR_CAUSE', 'MISSING_ERROR_CAUSE');
  }
  assertNoForbiddenPhrase(error_cause);
}

// ---------------------------------------------------------------------------
// 验证推进（核心不变量）
//   pass  -> 按状态机推进 V1->V2->V3->CLOSED
//   fail  -> REOPENED，reopen_count+1，连续重开 >=3 时 reopenWarning=true（提示抽验）
//   ticket.status 必须等于当前 stage（即正处于该验证阶段）
// ---------------------------------------------------------------------------
export function applyVerification(ticket, stage, result) {
  if (!VERIFY_STAGES.includes(stage)) {
    fail('INVALID_VERIFICATION_STAGE', `INVALID_VERIFICATION_STAGE: ${stage}`, { stage });
  }
  if (result !== 'pass' && result !== 'fail') {
    fail('INVALID_VERIFICATION_RESULT', `INVALID_VERIFICATION_RESULT: ${result}`, { result });
  }
  const cur = ticket && ticket.status;
  if (cur !== stage) {
    fail('INVALID_VERIFICATION_STAGE',
      `INVALID_VERIFICATION_STAGE: ticket.status=${cur}, stage=${stage}`,
      { stage, currentStatus: cur });
  }
  const reopen_count = Number(ticket.reopen_count) || 0;
  if (result === 'fail') {
    return {
      status: 'REOPENED',
      reopen_count: reopen_count + 1,
      reopenWarning: (reopen_count + 1) >= 3
    };
  }
  const next = { V1: 'V2', V2: 'V3', V3: 'CLOSED' }[stage];
  assertTransition(cur, next);
  return { status: next, reopen_count, reopenWarning: false };
}

// 从 ACTION_DONE 进入第一轮 V1（server 插入 verification 记录时调用）
export function beginVerification(ticket, stage = 'V1') {
  if (stage !== 'V1') {
    fail('INVALID_VERIFICATION_STAGE', `beginVerification only supports V1, got ${stage}`, { stage });
  }
  assertTransition(ticket && ticket.status, 'V1');
  return { status: 'V1' };
}

// 重开后重新归因 REOPENED -> ANALYZED，并开启新一轮验证轮次（P0-2 修复）
export function reanalyze(ticket) {
  assertTransition(ticket && ticket.status, 'ANALYZED');
  if (ticket.status !== 'REOPENED') {
    fail('ILLEGAL_DEFECT_TRANSITION', 'reanalyze requires REOPENED', { from: ticket.status });
  }
  return {
    status: 'ANALYZED',
    verification_round: (Number(ticket.verification_round) || 1) + 1,
    reopen_count: Number(ticket.reopen_count) || 0
  };
}

// ---------------------------------------------------------------------------
// 同类题判定（主文档 4.5）：同知识点 + 同层级 + 同题型 + 未作答过
// ---------------------------------------------------------------------------
export function isSimilarQuestion(base, candidate, answeredIds = []) {
  if (!base || !candidate) return false;
  if (base.knowledge_node_id !== candidate.knowledge_node_id) return false;
  if (base.error_layer !== candidate.error_layer) return false;
  if (base.question_type !== candidate.question_type) return false;
  const answered = answeredIds instanceof Set ? answeredIds : new Set(answeredIds || []);
  if (candidate.id && answered.has(candidate.id)) return false;
  return true;
}

// ---------------------------------------------------------------------------
// content_hash 归一化（对齐 schema.sql normalize_question_text）
//   全角标点 -> 半角；顿号 -> 半角逗号；去所有空白；options 规范化排序后序列化
//   返回 64 位小写 hex sha256
// ---------------------------------------------------------------------------
const FULLWIDTH_MAP = {
  '，': ',', '。': '.', '！': '!', '？': '?', '；': ';', '：': ':',
  '（': '(', '）': ')', '【': '[', '】': ']', '《': '<', '》': '>',
  '、': ',', '　': ''
};

function normalizePunct(s) {
  return String(s).replace(/[，。！？；：（）【】《》、　]/g, ch => FULLWIDTH_MAP[ch]);
}

function stableSortObj(obj) {
  return Object.keys(obj).sort().reduce((acc, k) => { acc[k] = obj[k]; return acc; }, {});
}

function stableOptions(options) {
  if (options == null) return '';
  if (Array.isArray(options)) {
    return JSON.stringify(options.map(o => (o && typeof o === 'object') ? stableSortObj(o) : o));
  }
  if (typeof options === 'object') return JSON.stringify(stableSortObj(options));
  return String(options);
}

export function normalizeQuestionText(stem, options, formula) {
  const s = normalizePunct(stem == null ? '' : stem)
          + normalizePunct(stableOptions(options))
          + normalizePunct(formula == null ? '' : formula);
  const noSpace = s.replace(/\s+/g, '');
  return createHash('sha256').update(noSpace, 'utf8').digest('hex');
}

// ---------------------------------------------------------------------------
// 优先级（主文档 4.5）：f(高频 x 失分 x 可关闭性 x 目标分贡献) -> P0/P1/P2
// ---------------------------------------------------------------------------
export function computePriority({ frequency = 0, loss = 0, closability = 0, targetContribution = 0 } = {}) {
  const score = Number(frequency) * Number(loss) * Number(closability) * Number(targetContribution);
  if (score >= 0.6) return 'P0';
  if (score >= 0.3) return 'P1';
  return 'P2';
}

// ---------------------------------------------------------------------------
// AI 生成请求校验（byok-key-lifecycle.md）
//   count 必须为 1..20 整数；provider 锁死；openai_compatible 必填 https base_url；
//   拒绝 localhost / 私有 IP / 169.254.169.254 / .local（SSRF，DB 不兜底）
// ---------------------------------------------------------------------------
export function validateAIGenerateRequest(payload = {}) {
  const count = payload.count;
  if (!Number.isInteger(count) || count < 1 || count > 20) {
    return { ok: false, error: { code: 'INVALID_COUNT', message: 'count must be an integer in [1,20]' } };
  }
  const provider = payload.provider;
  if (provider != null && !AI_PROVIDERS.includes(provider)) {
    return { ok: false, error: { code: 'INVALID_PROVIDER', message: 'provider must be deepseek or openai_compatible' } };
  }
  if (provider === 'openai_compatible') {
    const url = payload.base_url;
    if (!url || typeof url !== 'string') {
      return { ok: false, error: { code: 'MISSING_BASE_URL', message: 'openai_compatible requires base_url' } };
    }
    if (!/^https:\/\//i.test(url)) {
      return { ok: false, error: { code: 'INVALID_BASE_URL', message: 'base_url must be https' } };
    }
    let host;
    try { host = new URL(url).hostname.toLowerCase(); }
    catch { return { ok: false, error: { code: 'INVALID_BASE_URL', message: 'base_url is not a valid URL' } }; }
    if (host === 'localhost' || host === '127.0.0.1' || host === '::1' ||
        host === '169.254.169.254' || host.endsWith('.local') ||
        /^10\./.test(host) || /^192\.168\./.test(host) ||
        /^172\.(1[6-9]|2\d|3[01])\./.test(host)) {
      return { ok: false, error: { code: 'SSRF_BLOCKED', message: 'base_url resolves to a private/local address' } };
    }
  }
  return { ok: true };
}
