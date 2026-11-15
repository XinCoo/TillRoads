// core/validators.mjs
// 题路 TillRoad · BE-01 第 1 步：目标配置四表的纯输入校验层
//
// 定位：端无关、零第三方依赖、无 I/O / 无 SQL / 不 import pg / 不 import server/。
// 与 core/index.mjs 的关系（并列模块，互不 import）：
//   * index.mjs     管「缺陷单状态机 / 三次验证 / 去重哈希」等核心不变量，
//                   用 assertXxx 抛带 .code 的 Error（违反不变量 = 异常）。
//   * validators.mjs 管 exam_profiles / subjects / knowledge_nodes /
//                   capability_layers 四表的输入合法性，用 result 对象（校验不通过
//                   = 预期内的普通结果，不是异常）。
//   分开成新文件而非改 index.mjs：BE-01 是表级输入校验，与已冻结的缺陷单规则层
//   关注点不同；且硬约束要求不动 index.mjs 现有导出。消费方直接 import 本文件。
//
// 统一返回形状：{ ok: true } | { ok: false, code, message, ...extra }
//   选 result 对象而非抛 typed error，理由（见文末「设计说明」）：
//   ① 校验失败是预期内分支，返回值比 throw/try-catch 更便宜、更易组合；
//   ② code 是稳定机器可读令牌，供 HTTP 层统一映射 400 / 前端 i18n；
//   ③ message 是人类可读原因，可单独覆盖而不动 code；
//   ④ 与 core/index.mjs 的 validateAIGenerateRequest 同属「validate*」族
//      （该函数返回 { ok:false, error:{code,message} } 的嵌套形，本文件用扁平形，
//      差异在交付说明里显式标注，未改动 index.mjs）。
//
// 枚举/取值范围来源（已读当前 on-disk schema.sql 确认，勿凭记忆改）：
//   schema.sql:46-48  exam_type   ENUM('civil_service','postgrad','final_exam','vocational','adult_self_study')
//   schema.sql:50     subject_kind ENUM('objective','subjective','essay')
//   schema.sql:163-180 exam_profiles  status CHECK('active','archived') / target_score numeric(6,2) / daily_minutes int
//   schema.sql:197-210 knowledge_nodes freq_tag CHECK('high','mid','low') / weight_to_target numeric(4,3)
//   schema.sql:213-224 capability_layers layers jsonb NOT NULL [{order,key,label,desc}] / customizable boolean

// ---------------------------------------------------------------------------
// 冻结常量（与 schema.sql 的 ENUM / CHECK 一一对应）
// ---------------------------------------------------------------------------
export const EXAM_TYPES = Object.freeze([
  'civil_service', 'postgrad', 'final_exam', 'vocational', 'adult_self_study'
]);
export const SUBJECT_KINDS = Object.freeze(['objective', 'subjective', 'essay']);
export const FREQ_TAGS = Object.freeze(['high', 'mid', 'low']);
export const PROFILE_STATUSES = Object.freeze(['active', 'archived']);

// 产品边界「仅成人考试、不碰 K12」的显式拒绝清单。
// schema 的 ENUM 本身已是白名单，这里额外给 K12 相关输入一个独立、可读的失败码，
// 做到「明确拒绝」而不是仅仅「不在白名单里」。这些模式与 5 个合法值均无交集。
const K12_DENY = Object.freeze([
  /k12/i, /gaokao/i, /zhongkao/i, /middle[_-]?school/i, /high[_-]?school/i,
  /primary[_-]?school/i, /elementary/i, /小学|初中|高中|中考|高考/
]);

// numeric(6,2) → 最大 9999.99；numeric(4,3) → 最大 9.999
const MAX_TARGET_SCORE = 9999.99;
const MAX_WEIGHT = 9.999;
const LAYER_KEYS = Object.freeze(['order', 'key', 'label', 'desc']);

// ---------------------------------------------------------------------------
// 内部工具（全部纯函数）
// ---------------------------------------------------------------------------
const OK = Object.freeze({ ok: true });

function invalid(code, message, extra) {
  return Object.freeze({ ok: false, code, message, ...(extra || {}) });
}

function isBlank(v) {
  return v == null || (typeof v === 'string' && v.trim() === '');
}

// 接受 number 或「纯数字字符串」：node-postgres 把 numeric/int 读回时是字符串
// （见 REVIEW-NOTES §6 / BE-01 设计 §6 风险 8），让同一套校验在
// 「HTTP 入参」与「PG 读回再校验」两条路径都成立。
function asFiniteNumber(v) {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  if (typeof v === 'string') {
    const s = v.trim();
    if (!/^-?\d+(\.\d+)?$/.test(s)) return null;   // 拒绝 '' / '  ' / '0x10' / '1e3'
    const n = Number(s);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

// 统计「有效小数位」：去掉末尾 0，避免 80.000 / "9999.990" 被误判超刻度。
// numeric(p,s) 在 DB 层会静默四舍五入，故在校验层提前拦下超刻度输入。
function significantDecimals(v) {
  const s = typeof v === 'string' ? v.trim() : String(v);
  if (/[eE]/.test(s)) return Infinity;              // 科学计数法：按超刻度处理
  const m = /^-?\d+\.(\d+)$/.exec(s);
  if (!m) return 0;
  return m[1].replace(/0+$/, '').length;
}

function isRealCalendarDate(y, mo, d) {
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return false;
  // 以 2000 为基准再 setUTCFullYear，规避 Date.UTC 把 0-99 年映射到 1900+ 的坑
  const dt = new Date(Date.UTC(2000, mo - 1, d));
  dt.setUTCFullYear(y);
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === mo - 1 && dt.getUTCDate() === d;
}

// ---------------------------------------------------------------------------
// V1. validateExamType(v)
//   exam_type ∈ EXAM_TYPES；明确拒绝 K12 相关值（独立失败码 EXAM_TYPE_K12_FORBIDDEN）
//   列 NOT NULL → null/undefined 不合法
// ---------------------------------------------------------------------------
export function validateExamType(v) {
  if (typeof v === 'string' && K12_DENY.some(re => re.test(v))) {
    return invalid('EXAM_TYPE_K12_FORBIDDEN',
      `exam_type 拒绝 K12 相关值: ${v}（产品边界：仅成人考试）`);
  }
  if (typeof v !== 'string' || !EXAM_TYPES.includes(v)) {
    return invalid('INVALID_EXAM_TYPE',
      `exam_type must be one of ${EXAM_TYPES.join(', ')}`);
  }
  return OK;
}

// ---------------------------------------------------------------------------
// V2. validateSubjectKind(v)
//   subject_kind ∈ SUBJECT_KINDS（列 NOT NULL，无 null 豁免）
// ---------------------------------------------------------------------------
export function validateSubjectKind(v) {
  if (typeof v !== 'string' || !SUBJECT_KINDS.includes(v)) {
    return invalid('INVALID_SUBJECT_KIND',
      `subject_kind must be one of ${SUBJECT_KINDS.join(', ')}`);
  }
  return OK;
}

// ---------------------------------------------------------------------------
// V3. validateFreqTag(v)
//   freq_tag ∈ FREQ_TAGS；schema 列可空 → null/undefined 合法
// ---------------------------------------------------------------------------
export function validateFreqTag(v) {
  if (v == null) return OK;
  if (typeof v !== 'string' || !FREQ_TAGS.includes(v)) {
    return invalid('INVALID_FREQ_TAG',
      `freq_tag must be one of ${FREQ_TAGS.join(', ')} or null`);
  }
  return OK;
}

// ---------------------------------------------------------------------------
// V4. validateProfileStatus(v)
//   status ∈ PROFILE_STATUSES（NOT NULL DEFAULT 'active'）
// ---------------------------------------------------------------------------
export function validateProfileStatus(v) {
  if (typeof v !== 'string' || !PROFILE_STATUSES.includes(v)) {
    return invalid('INVALID_PROFILE_STATUS',
      `status must be one of ${PROFILE_STATUSES.join(', ')}`);
  }
  return OK;
}

// ---------------------------------------------------------------------------
// V5. validateTargetScore(n)
//   numeric(6,2)：非负、≤ 9999.99、≤ 2 位有效小数；列可空 → null 合法
//   额外守卫：超 2 位小数会被 PG 静默四舍五入，故提前拒绝（同一 code，不同 message）
// ---------------------------------------------------------------------------
export function validateTargetScore(n) {
  if (n == null) return OK;
  const v = asFiniteNumber(n);
  if (v === null) return invalid('INVALID_TARGET_SCORE', 'target_score must be a number');
  if (v < 0) return invalid('INVALID_TARGET_SCORE', 'target_score must be >= 0');
  if (v > MAX_TARGET_SCORE) {
    return invalid('INVALID_TARGET_SCORE',
      `target_score must be <= ${MAX_TARGET_SCORE} (numeric(6,2))`);
  }
  if (significantDecimals(n) > 2) {
    return invalid('INVALID_TARGET_SCORE',
      'target_score has more than 2 decimal places (numeric(6,2) would round silently)');
  }
  return OK;
}

// ---------------------------------------------------------------------------
// V6. validateDailyMinutes(n)
//   正整数（≥1）；列可空 → null 合法。注意 0 不是正整数。
// ---------------------------------------------------------------------------
export function validateDailyMinutes(n) {
  if (n == null) return OK;
  const v = asFiniteNumber(n);
  if (v === null || !Number.isInteger(v) || v <= 0) {
    return invalid('INVALID_DAILY_MINUTES', 'daily_minutes must be a positive integer');
  }
  return OK;
}

// ---------------------------------------------------------------------------
// V7. validateWeightToTarget(n)
//   numeric(4,3)：[0, 9.999]、≤ 3 位有效小数；列可空 → null 合法
// ---------------------------------------------------------------------------
export function validateWeightToTarget(n) {
  if (n == null) return OK;
  const v = asFiniteNumber(n);
  if (v === null) return invalid('INVALID_WEIGHT_TO_TARGET', 'weight_to_target must be a number');
  if (v < 0) return invalid('INVALID_WEIGHT_TO_TARGET', 'weight_to_target must be >= 0');
  if (v > MAX_WEIGHT) {
    return invalid('INVALID_WEIGHT_TO_TARGET',
      `weight_to_target must be <= ${MAX_WEIGHT} (numeric(4,3))`);
  }
  if (significantDecimals(n) > 3) {
    return invalid('INVALID_WEIGHT_TO_TARGET',
      'weight_to_target has more than 3 decimal places (numeric(4,3) would round silently)');
  }
  return OK;
}

// ---------------------------------------------------------------------------
// V8. validateExamDate(d)
//   合法日期：Date 实例 / 'YYYY-MM-DD'（严格真实日历日）/ ISO 8601 datetime；
//   列可空 → null 合法（但 AC-EXAM-01 必填由 V11 负责，这里只管「值合法」）
//   不用 Date.parse：它会把 '2026-02-30' 静默归一到 3 月 2 日。
// ---------------------------------------------------------------------------
export function validateExamDate(d) {
  if (d == null) return OK;
  if (d instanceof Date) {
    return Number.isNaN(d.getTime())
      ? invalid('INVALID_EXAM_DATE', 'exam_date is an invalid Date')
      : OK;
  }
  if (typeof d !== 'string') {
    return invalid('INVALID_EXAM_DATE', 'exam_date must be a date string or Date');
  }
  const s = d.trim();
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
  if (m) {
    return isRealCalendarDate(Number(m[1]), Number(m[2]), Number(m[3]))
      ? OK
      : invalid('INVALID_EXAM_DATE', `exam_date is not a real calendar date: ${s}`);
  }
  const m2 = /^(\d{4})-(\d{2})-(\d{2})T/.exec(s);
  if (m2) {
    if (!isRealCalendarDate(Number(m2[1]), Number(m2[2]), Number(m2[3]))) {
      return invalid('INVALID_EXAM_DATE', `exam_date is not a real calendar date: ${s}`);
    }
    return Number.isNaN(new Date(s).getTime())
      ? invalid('INVALID_EXAM_DATE', `exam_date is not a valid ISO datetime: ${s}`)
      : OK;                                        // PG date 列会截断时间部分
  }
  return invalid('INVALID_EXAM_DATE',
    `exam_date must be YYYY-MM-DD or ISO 8601 datetime: ${s}`);
}

// ---------------------------------------------------------------------------
// V9. validateLayers(arr, opts)
//   capability_layers.layers jsonb NOT NULL，元素形如 {order:int,key:text,label:text,desc:text}
//   · 必填键存在、order 为整数、key 非空字符串、label/desc 为字符串
//   · order 与 key 各自不重复
//   · create/update 语义由 opts.mode 区分（本文件内区分，不甩给调用方）：
//       mode='create' → arr 为 null/undefined 时返回 LAYERS_REQUIRED（NOT NULL 必须提供）
//       mode='update'（默认）→ arr 为 null/undefined 时 OK（partial patch 不带 layers = 不修改）
//     [] 视为合法（DB 只要求 NOT NULL，不要求非空数组）
// ---------------------------------------------------------------------------
export function validateLayers(arr, opts = {}) {
  const mode = opts && opts.mode === 'create' ? 'create' : 'update';
  if (arr == null) {
    return mode === 'create'
      ? invalid('LAYERS_REQUIRED',
          'capability_layers.layers is NOT NULL; create 时必须提供数组')
      : OK;
  }
  if (!Array.isArray(arr)) return invalid('INVALID_LAYERS', 'layers must be an array');

  const orders = new Set();
  const keys = new Set();
  for (let i = 0; i < arr.length; i++) {
    const it = arr[i];
    if (!it || typeof it !== 'object' || Array.isArray(it)) {
      return invalid('INVALID_LAYERS', `layers[${i}] must be an object`);
    }
    for (const k of LAYER_KEYS) {
      if (!Object.prototype.hasOwnProperty.call(it, k)) {
        return invalid('INVALID_LAYERS', `layers[${i}] missing required key: ${k}`);
      }
    }
    if (!Number.isInteger(it.order)) {
      return invalid('INVALID_LAYERS', `layers[${i}].order must be an integer`);
    }
    if (typeof it.key !== 'string' || it.key.trim() === '') {
      return invalid('INVALID_LAYERS', `layers[${i}].key must be a non-empty string`);
    }
    if (typeof it.label !== 'string' || typeof it.desc !== 'string') {
      return invalid('INVALID_LAYERS', `layers[${i}].label / .desc must be strings`);
    }
    if (orders.has(it.order)) {
      return invalid('DUPLICATE_LAYER_ORDER', `duplicate layer order: ${it.order}`);
    }
    if (keys.has(it.key)) {
      return invalid('DUPLICATE_LAYER_KEY', `duplicate layer key: ${it.key}`);
    }
    orders.add(it.order);
    keys.add(it.key);
  }
  return OK;
}

// ---------------------------------------------------------------------------
// V10. validateCustomizableGate(current, patch)
//   AC-KM-02：customizable=false 的官方模板禁止修改 layers 或 customizable 本身；
//   返回 { ok:true } 表示允许，{ ok:false, code:'CUSTOMIZABLE_LOCKED' } 表示拒绝。
//   · 失败关闭：无法确认 current.customizable === true 一律视为锁定
//     （DB 该列 NOT NULL DEFAULT true，真实行必为布尔，取不到就保守锁住）
//   · patch 中出现 layers / customizable 键即视为「试图修改」，不比较值是否真变化
//   · 只改 name 等其它字段允许；patch 为空允许
// ---------------------------------------------------------------------------
export function validateCustomizableGate(current, patch) {
  const locked = !(current && current.customizable === true);
  if (!locked) return OK;
  if (!patch || typeof patch !== 'object') return OK;
  const attempts = [];
  if (Object.prototype.hasOwnProperty.call(patch, 'layers')) attempts.push('layers');
  if (Object.prototype.hasOwnProperty.call(patch, 'customizable')) attempts.push('customizable');
  if (attempts.length === 0) return OK;
  return invalid('CUSTOMIZABLE_LOCKED',
    `customizable=false 的官方模板禁止修改 ${attempts.join(' / ')}（AC-KM-02：请新建自定义副本）`);
}

// ---------------------------------------------------------------------------
// V11. validateExamProfileRequired(input)
//   AC-EXAM-01 必填：exam_type / (target_score 或 target_label 至少一项非空) /
//                    exam_date / daily_minutes
//   一次性收集全部缺失字段放进 fields[]，便于前端一次提示；值是否合法由 V1/V5/V6/V8 各自负责。
//   注：0 / '0' 视为「已填」（存在性判断），例如 daily_minutes=0 会被本函数放行、
//       再由 V6 以 INVALID_DAILY_MINUTES 拒绝，职责不重叠。
// ---------------------------------------------------------------------------
export function validateExamProfileRequired(input = {}) {
  const o = input || {};
  const missing = [];
  if (isBlank(o.exam_type)) missing.push('exam_type');
  if (isBlank(o.target_score) && isBlank(o.target_label)) missing.push('target_score_or_target_label');
  if (isBlank(o.exam_date)) missing.push('exam_date');
  if (isBlank(o.daily_minutes)) missing.push('daily_minutes');
  if (missing.length) {
    return invalid('MISSING_REQUIRED_FIELD',
      `AC-EXAM-01 missing required: ${missing.join(', ')}`, { fields: missing });
  }
  return OK;
}

// ---------------------------------------------------------------------------
// V12. validateBaseVersion(v)
//   乐观锁基版号：正整数（schema version int NOT NULL DEFAULT 1）；无 null 豁免
// ---------------------------------------------------------------------------
export function validateBaseVersion(v) {
  const n = asFiniteNumber(v);
  if (n === null || !Number.isInteger(n) || n <= 0) {
    return invalid('INVALID_BASE_VERSION', 'base_version must be a positive integer');
  }
  return OK;
}

// ---------------------------------------------------------------------------
// 组合原语（纯函数；本轮只提供，第 3/4 步才接线调用）
//   create/update 前把多个校验结果串起来，取第一个失败：
//     const r = firstInvalid(validateExamType(x), validateTargetScore(y), ...);
//   若某处复用了 validateAIGenerateRequest 的嵌套形 { ok:false, error:{...} }，
//   本函数仍会把它当失败返回，但消费方需自行处理 error 嵌套（见交付说明）。
// ---------------------------------------------------------------------------
export function firstInvalid(...results) {
  for (const r of results) {
    if (r && r.ok === false) return r;
  }
  return OK;
}

// ---------------------------------------------------------------------------
// 设计说明：为什么统一用 result 对象而不是抛 typed error
//   1. core/index.mjs 的 assertXxx 抛错，语义是「违反核心不变量 = 程序错误」；
//      本文件的 validateXxx 语义是「外部输入不合法 = 预期内分支」。二者不该混用。
//   2. 校验在 create/update 热路径上常要串 5~10 个函数，返回值天然可组合
//      （firstInvalid），抛错则每个调用点都要 try/catch，且无法一次收集多个字段错误
//      （V11 的 fields[] 就是为此）。
//   3. code 与 message 分离：code 稳定，供 HTTP 层映射 400 与前端 i18n；
//      message 可随文案迭代而不破坏契约。
//   4. 与 core/index.mjs 的 validateAIGenerateRequest 同属 validate* 族、同样不抛错；
//      唯一差异是它用 { ok:false, error:{code,message} } 嵌套形，本文件用扁平形。
//      因硬约束禁止改 index.mjs 现有导出，此处不强行统一，差异已在交付说明标注，
//      HTTP 层映射时写 `r.error?.code ?? r.code` 即可兼容两族。
// ---------------------------------------------------------------------------
