// core/templates.mjs
// 题路 TillRoad · BE-01 第 4 步：AC-KM-01「官方考点模板一键套用」的纯数据层
//
// 定位与硬约束（本轮）：
//   * **纯数据 + 纯函数**：无 I/O、无 SQL、不 import pg、不 import server/、
//     不读环境变量、不读文件。因此可被 core 消费方直接 import，不破坏端无关性。
//   * 与 core/validators.mjs 并列：validators 管「输入是否合法」，
//     本文件管「某个考试类型默认应该有哪些科目」。互不 import（只单向复用常量可由测试做）。
//
// 为什么把模板放 core/ 而不是放 DB 或 server/：
//   1. AC-KM-01 是「按考试类型给默认科目」的产品规则，不是数据录入 —— 与
//      DEFECT_STATUSES / STAGE_WINDOWS 同属规则层，放 core/ 才能被 Dart 端复用。
//   2. 若放 DB 需要一张 seed 表 + 迁移；MVP 阶段模板会频繁微调，改动落在代码里
//      code review 更直观，也避免「空库跑起来没有模板」的部署顺序问题。
//   3. 若放 server/，将来做离线端时本地无法套模板（设备不连服务端也要能建目标）。
//
// 与 schema.sql 的关系：
//   * subject.kind ∈ schema.sql:50 的 subject_kind ENUM('objective','subjective','essay')；
//     本文件所有 kind 都必须落在这个枚举内（由 core/templates.test.mjs 断言，不在此处
//     硬编码校验，避免数据文件变成校验器）。
//   * exam_type ∈ schema.sql:46-48 的 5 个值；未知类型返回空数组而不是抛错，
//     原因见 getTemplateSubjects 注释（用户可后续手动加科目，不该因缺模板而建不了目标）。
//
// 版本标记：模板内容变更时递增，便于将来「导入时记录套用的是哪一版模板」
// （当前 schema 无该列，MVP 不落库，仅作为交付可追溯性）。
export const TEMPLATE_VERSION = 'tpl-1';

// 每个 exam_type 的默认科目清单。
//   name —— 用户看到的科目名（中文，符合产品「中文母语备考」定位）
//   kind —— 决定该科目默认走客观题还是主观题流程
// 说明：刻意保持 2~6 个科目，不做细到章节的预置 —— 考点树由用户在自己的
//   subjects 下用 knowledge_nodes 增删（AC-KM-03），预置过细会变成「替用户做决定」。
const TEMPLATES = Object.freeze({
  // 公务员：行测五模块 + 申论。行测全部客观题，申论是主观题。
  civil_service: Object.freeze([
    Object.freeze({ name: '言语理解与表达', kind: 'objective' }),
    Object.freeze({ name: '数量关系', kind: 'objective' }),
    Object.freeze({ name: '判断推理', kind: 'objective' }),
    Object.freeze({ name: '资料分析', kind: 'objective' }),
    Object.freeze({ name: '常识判断', kind: 'objective' }),
    Object.freeze({ name: '申论', kind: 'subjective' }),
  ]),

  // 考研：政治 + 外国语 + 两门业务课（业务课二常为院校自命题主观题）。
  postgrad: Object.freeze([
    Object.freeze({ name: '思想政治理论', kind: 'objective' }),
    Object.freeze({ name: '外国语', kind: 'objective' }),
    Object.freeze({ name: '业务课一', kind: 'objective' }),
    Object.freeze({ name: '业务课二', kind: 'subjective' }),
  ]),

  // 期末：以「课程」为粒度，含主课笔试、实验实践、课程论文三类形态。
  final_exam: Object.freeze([
    Object.freeze({ name: '专业主课', kind: 'objective' }),
    Object.freeze({ name: '实验与实践', kind: 'subjective' }),
    Object.freeze({ name: '课程论文', kind: 'essay' }),
  ]),

  // 职业资格：公共基础 + 专业实务（后两者常含案例分析，归主观题）。
  vocational: Object.freeze([
    Object.freeze({ name: '公共基础', kind: 'objective' }),
    Object.freeze({ name: '专业实务', kind: 'subjective' }),
  ]),

  // 成人自考：公共课 + 专业课 + 实践环节。
  adult_self_study: Object.freeze([
    Object.freeze({ name: '公共课', kind: 'objective' }),
    Object.freeze({ name: '专业课', kind: 'subjective' }),
    Object.freeze({ name: '实践环节', kind: 'essay' }),
  ]),
});

/** 有预置模板的 exam_type 列表（供测试/文档对齐，不含未知类型）。 */
export const TEMPLATE_EXAM_TYPES = Object.freeze(Object.keys(TEMPLATES));

/**
 * 取某考试类型的默认科目清单（AC-KM-01）。
 *
 * @param {string} examType  schema.sql:46-48 的 exam_type 之一
 * @returns {Array<{name: string, kind: 'objective'|'subjective'|'essay'}>}
 *          每次返回**新数组 + 新对象**（调用方可安全修改/传出，不会污染模板常量）。
 *
 * 未知类型返回 []，**不抛错**（决策 9）：
 *   「没有预置模板」不是错误输入 —— exam_type 已由 validateExamType 校验过合法性，
 *   这里只是恰好没有默认科目（例如将来新增考试类型还没补模板）。若在此抛错，
 *   建目标会因「模板缺失」而失败，把「可选优化」变成了硬门禁，用户反而无法建目标。
 *   返回空数组时 POST /exam-profiles 只建 profile，科目由用户后续手动添加。
 */
export function getTemplateSubjects(examType) {
  // 必须用 hasOwnProperty 而不是 `TEMPLATES[examType]` 直接取：后者会命中原型链上的
  // 'constructor' / 'toString' / '__proto__' 等键，把函数当模板数组去 map 而抛 TypeError。
  if (!hasTemplate(examType)) return [];
  return TEMPLATES[examType].map((s) => ({ name: s.name, kind: s.kind }));
}

/** 是否配了预置模板（不区分模板是否为空数组）。 */
export function hasTemplate(examType) {
  return Object.prototype.hasOwnProperty.call(TEMPLATES, examType);
}
