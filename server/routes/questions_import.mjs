// server/routes/questions_import.mjs
// 题路 TillRoad · BE-02：题目导入端点
//
// 端点：POST /questions/import
//
// 四阶段管线（用户拍板 T3）：
//   1. extractText(file)      —— 按 mime 分派；PDF 走 pdfjs-dist，XLSX 走自研最小解析
//   2. splitQuestions(text)   —— 纯函数规则切题（server/import/splitter.mjs）
//   3. dedupe(questions,client) —— 按 content_hash 与库内已有题比对
//   4. questions.create(...)  —— 逐题入库
//
// 事务边界（用户拍板 T4）：**整段包 withTransaction**，要么全部入库要么一条不留。
//   理由：导入是用户主动发起的一批操作，部分成功比全失败更难处理 ——
//   用户重传会撞上「已存在」而不知道该跳过哪些，只能人工逐条比对。
//   但「去重命中的题」不算失败：它们是 duplicates 而不是 errors，正常返回。
//
// 请求体（JSON，不走 multipart）：
//   为什么只支持 base64 JSON 不做 multipart：
//     Node 原生没有 multipart 解析器，为它引一个依赖（busboy/formidable）违背
//     「运行时依赖只保留 pg + pdfjs-dist」的取舍；而导入是低频操作，
//     base64 的体积放大（约 +33%）在 10MB 上限内完全可接受。
//     multipart 留到 V1 与 import_jobs 异步队列一起做。此点在 README 明确写出。
//
//   {
//     "filename": "questions.md",          // 必填，扩展名是 mime 缺失时的兜底判据
//     "mime": "text/markdown",             // 可选
//     "content_base64": "...",             // 必填，文件内容
//     "subject_id": "uuid",                // 可选，归属科目
//     "knowledge_node_id": "uuid",         // 可选，归属知识点
//     "source": "import",                  // 可选，默认 import
//     "default_type": "choice"             // 可选，切题结果无 type 信息时使用的题型
//   }
//
// 响应 200：
//   {
//     "imported": 10,
//     "duplicates": [{ "content_hash": "...", "existing_id": "uuid", "stem": "..." }],
//     "errors": [{ "line": 42, "reason": "..." }],
//     "stats": { "kind": "markdown", "mime": "text/markdown", "pages": null,
//                "total": 12, "preamble_lines": 3, "bytes": 2931,
//                "image_placeholders": 0 }
//   }
//
// 错误码（详见 server/import/extract.mjs 的 importError）：
//   * 413 PAYLOAD_TOO_LARGE —— 文件 >10MB 或 PDF >100 页
//   * 422 UNSUPPORTED_PDF  —— 扫描版 PDF（无文本层）/ PDF 损坏
//   * 422 UNSUPPORTED_IMAGE—— 图片（OCR 在 V1）
//   * 422 UNSUPPORTED_XLSX —— XLSX 解析失败
//   * 415 UNSUPPORTED_MEDIA—— 不认识的类型
//   * 400 EMPTY_CONTENT    —— 文件为空 / 抽不出文本 / 切不出题
//   * 400 INVALID_BASE64 / MISSING_FILENAME / MISSING_CONTENT —— 请求体本身有问题
//
// 注意 splitter 与 extract 都不 import pg；本文件是唯一把它们和仓储串起来的地方。

import { withTransaction } from '../repositories/base.mjs';
import * as questionsRep from '../repositories/questions.mjs';
import * as importBatchesRep from '../repositories/import_batches.mjs';
import { extractText, importError } from '../import/extract.mjs';
import { splitQuestions } from '../import/splitter.mjs';
import { parseQuestionJson, hasAnySubject } from '../import/json_import.mjs';
import { createSubjectResolver } from '../import/resolve_subject.mjs';
import { createNodeResolver, splitNodePath } from '../import/resolve_node.mjs';
import { remapTillroad } from '../import/remap_tillroad.mjs';
import { dedupe, contentHashOf } from '../import/dedupe.mjs';
import { separateAssets } from '../import/separate.mjs';
import { toJsonbParam } from '../repositories/_common.mjs';
import { fail, ok } from './_http.mjs';
import { sanitizeQuestionText } from '../../core/index.mjs';
/** 这些分隔符编号不再作为题干前缀入库（splitter 已剥离），这里只用于报错行号。 */

const DEFAULT_SOURCE = 'import';
const DEFAULT_TYPE = 'choice';

// m30197：科目归属的两种模式。
//   from_file —— 每题用文件里的 subject 文本去 match（推荐，AI 生成的 JSON 走这条）；
//   uniform   —— 所有题都进前端选定的那一个科目（旧行为，缺省）。
// 不传 subject_mode 时按 uniform 走，保证老客户端和新客户端的默认行为不变。
const SUBJECT_MODE_FROM_FILE = 'from_file';
const SUBJECT_MODE_UNIFORM = 'uniform';

// 主观类题型：这些题型的 is_subjective 必须为 true。
// 取值口径见 tillroad_app/lib/api/question_api.dart 的 BankQuestion.typeLabel。
const SUBJECTIVE_TYPES = new Set(['short_answer', 'essay', 'subjective', 'material']);

// ★ m32773：重复题的两种处理方式（body.decisions.duplicate_action）。
//   skip      —— 默认，重复题原样留在库里，本次不写（与 m32773 之前的行为完全一致）；
//   overwrite —— 用文件里的内容覆盖库里同 hash 的题（只覆盖内容字段，保留 id / owner / created_at）。
// 刻意不做逐条决策、不做「保留两份」、不做相似度判定 —— 全是用户未要求的复杂度。
const DUPLICATE_ACTION_SKIP = 'skip';
const DUPLICATE_ACTION_OVERWRITE = 'overwrite';

/**
 * 解析 body.decisions.duplicate_action。
 *
 * 非法值不报 400 而是回落 skip：
 *   导入是「用户点了确认就希望有结果」的操作，为一个拼错的枚举把整批挡在门外体验更差。
 *   缺省（不传 decisions）必须等价于 skip —— 硬约束：不能改旧客户端的行为。
 */
function parseDuplicateAction(body) {
  const raw = body && body.decisions ? body.decisions.duplicate_action : null;
  return String(raw ?? '').trim().toLowerCase() === DUPLICATE_ACTION_OVERWRITE
    ? DUPLICATE_ACTION_OVERWRITE
    : DUPLICATE_ACTION_SKIP;
}

/**
 * 把任意字段值压成一个可比较的字符串。
 * jsonb 列（如 tags）经 pg 回来后可能已是对象/数组，不能直接 ===。
 */
function signature(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value.trim();
  return JSON.stringify(value);
}

/**
 * 对比「文件里的题」与「库里已有的题」，给出人话层面的差异清单。
 *
 * 注意 content_hash 只由 stem + options + formula_text 算出，
 * 所以同 hash 的两道题在前三项上必然一致（归一化之后）；
 * 真正可能不同的是 answer / analysis / difficulty / tags / type。
 * 用户关心的是「覆盖会不会丢掉我本地改过的答案」，所以默认展示这几项。
 */
function diffAgainst(incoming, existing) {
  const out = [];
  const pairs = [
    ['answer', '答案不同'],
    ['analysis', '解析不同'],
    ['difficulty', '难度不同'],
    ['tags', '标签不同'],
    ['type', '题型不同'],
  ];
  for (const [field, label] of pairs) {
    if (signature(incoming[field]) !== signature(existing[field])) out.push(label);
  }
  return out;
}

/**
 * 把 dedupe() 给出的重复项补齐成预检页要展示的形状。
 *
 * dedupe 的 duplicate 只有 {content_hash, existing_id, stem}：
 *   - incoming.type 得从候选里按 hash 取；
 *   - existing.stem / created_at / 各字段得回库查一次。
 * 用一次 ANY(uuid[]) 批量查，不逐题往返。
 */
async function describeDuplicates(client, duplicates, candidateByHash, ownerUserId) {
  const ids = [...new Set(duplicates.map((d) => d.existing_id).filter(Boolean))];
  const existingRows = new Map();
  if (ids.length > 0) {
    // 只查「自己的题」：公共题与别人的题在 overwrite 时也不会被改，
    // 提前过滤掉能让 diff 与真实可覆盖范围保持一致。
    const ownerClause = ownerUserId ? 'AND owner_user_id = $2' : 'AND owner_user_id IS NULL';
    const params = ownerUserId ? [ids, ownerUserId] : [ids];
    const { rows } = await client.query(
      `SELECT id, stem, type, options, answer, analysis, difficulty, tags, created_at
         FROM questions
        WHERE id = ANY($1::uuid[])
          AND deleted_at IS NULL
          ${ownerClause}`,
      params,
    );
    for (const row of rows) existingRows.set(row.id, row);
  }

  return duplicates.map((d) => {
    const incoming = candidateByHash.get(d.content_hash) ?? {};
    const existing = d.existing_id ? existingRows.get(d.existing_id) ?? null : null;
    return {
      incoming: {
        stem: incoming.stem ?? d.stem ?? '',
        type: incoming.type ?? null,
        content_hash: d.content_hash,
      },
      existing: existing
        ? { id: existing.id, stem: existing.stem, created_at: existing.created_at }
        : null,
      diff: existing
        ? diffAgainst(incoming, existing)
        : ['同一份文件里重复出现（库内还没有这道题）'],
    };
  });
}

/**
 * overwrite 分支：按 content_hash 对应的库内行做内容覆盖。
 *
 * 为什么直写 SQL 而不用 questionsRep.update：
 *   1. rep.update 需要 baseVersion（乐观锁），导入管线手上没有当前版本号；
 *   2. rep.update 会重算 content_hash —— 覆盖场景我们的语义就是「同 hash 的两道题」,
 *      不该因为它去改 hash（更不该触发与自己的重复判定）。
 * 只改内容字段：id / owner_user_id / created_at / batch_id 等档案列全部保留。
 * 只改自己的题：WHERE 带 owner_user_id，公共题与别人的题静默跳过。
 *
 * @returns {Promise<number>} 实际覆盖的行数
 */
async function overwriteDuplicates(client, duplicates, candidateByHash, ownerUserId) {
  if (!ownerUserId) return 0;
  const ids = [...new Set(duplicates.map((d) => d.existing_id).filter(Boolean))];
  if (ids.length === 0) return 0;

  const { rows } = await client.query(
    `SELECT id FROM questions
      WHERE id = ANY($1::uuid[])
        AND deleted_at IS NULL
        AND owner_user_id = $2`,
    [ids, ownerUserId],
  );
  const own = new Set(rows.map((r) => r.id));

  let overwritten = 0;
  for (const d of duplicates) {
    if (!own.has(d.existing_id)) continue;
    const item = candidateByHash.get(d.content_hash);
    if (!item) continue;
    await client.query(
      `UPDATE questions
          SET stem = $2,
              options = $3,
              answer = $4,
              analysis = $5,
              difficulty = $6,
              tags = $7
        WHERE id = $1
          AND owner_user_id = $8
          AND deleted_at IS NULL`,
      [
        d.existing_id,
        item.stem,
        toJsonbParam(item.options ?? null),
        item.answer ?? null,
        item.analysis ?? null,
        item.difficulty ?? null,
        toJsonbParam(item.tags ?? null),
        ownerUserId,
      ],
    );
    overwritten += 1;
  }
  return overwritten;
}

/**
 * 预检：跑完解析与查重后立刻返回统计，**不写任何数据**。
 *
 * 三条硬约束（任务书 B4）：
 *   - 不写 import_batches；
 *   - 不建 knowledge_nodes（所以这里刻意不调用 resolveNode）；
 *   - 不插 questions。
 * 因为全流程只读，所以不需要事务包裹 —— 用 pool 直接查即可。
 */
export async function previewImport(pool, body = {}, ownerUserId = null) {
  const { extracted, split, parseProblems, createCtx, cleanedQuestions, sanitizedCount } =
    await parseImportBody(body, ownerUserId);

  // 预检不做 subject/node 解析：resolveNode 会建考点（写库），违反「预检不创建任何数据」。
  // 归属字段一律用请求里的默认值，预检页只关心「新题/重复」两个数字。
  const candidates = cleanedQuestions.map((q) => toCreateInput(q, createCtx));

  const candidateByHash = new Map();
  for (const item of candidates) candidateByHash.set(contentHashOf(item), item);

  const { newQuestions, duplicates } = await dedupe(candidates, pool, ownerUserId ?? null);
  const details = await describeDuplicates(pool, duplicates, candidateByHash, ownerUserId ?? null);

  console.log(
    `[IMPORT] 预检：新题 ${newQuestions.length} 条 / 重复 ${duplicates.length} 条（owner=${ownerUserId ?? 'public'}）`,
  );

  return {
    new_count: newQuestions.length,
    duplicate_count: duplicates.length,
    duplicates: details,
    // 单题级解析问题（JSON 里某条形状不对）也一并返回，前端预检页直接展示。
    parse_errors: parseProblems.map((p) => p.message),
    stats: {
      kind: extracted.kind,
      mime: extracted.mime,
      bytes: Buffer.byteLength(extracted.text ?? '', 'utf8'),
      total: split.total ?? split.questions.length,
      sanitized: sanitizedCount,
    },
  };
}
/**
 * 把 base64 解成 Buffer。
 * Node 的 Buffer.from(str,'base64') 对非法字符是**静默跳过**而不是抛错，
 * 所以必须回头校验长度：解出来的东西比预期短太多说明内容不是合法 base64。
 */
function decodeBase64(input) {
  // 「字段缺失」与「文件是空的」是两件事，不能都回 MISSING_CONTENT：
  //   缺失 -> 调用方漏传，改请求参数即可；
  //   空文件 -> 文件本身 0 字节，属于内容问题（EMPTY_CONTENT）。
  // base64 里空文件的编码就是空串，所以只能靠「键在不在」区分这两者。
  if (input === undefined || input === null) {
    throw Object.assign(new Error('content_base64 必填'), { code: 'MISSING_CONTENT' });
  }
  if (typeof input !== 'string') {
    throw Object.assign(new Error('content_base64 必须是字符串'), { code: 'INVALID_BASE64' });
  }
  if (input.trim() === '') {
    throw importError('EMPTY_CONTENT', 400, '文件内容为空（0 字节），没有可导入的题目');
  }
  const cleaned = input.replace(/\s+/g, '');
  const buf = Buffer.from(cleaned, 'base64');
  if (buf.length === 0) {
    throw Object.assign(new Error('content_base64 不是合法的 base64'), { code: 'INVALID_BASE64' });
  }
  return buf;
}

/**
 * 切题结果 -> 待入库的题（补上归属、题型、source）。
 *
 * 题型来源有两条路：
 *   1. splitter 的自动识别结果（question.detected_type）；
 *      只有 needsReview === false（识别可靠）时才采用。
 *   2. 调用方给的 default_type（识别不确定 / 没有识别结果时的兜底）。
 *
 * 识别不确定就退回默认题型，是刻意的：宁可沿用调用方的默认口径，
 * 也不要把「猜的题型」写进库里让人以为识别成功（needs_review 会记在 generation_meta 里）。
 */
function toCreateInput(question, ctx) {
  // 第四阶段：资产分离（MVP 只识别占位、不落库，asset_refs 恒为空数组）
  const assets = separateAssets(question);

  const detected = question.detected_type ?? null;
  const useDetected = Boolean(detected) && detected.needsReview === false;
  const type = useDetected ? detected.type : ctx.default_type;

  // generation_meta 记录本次的识别结论（jsonb，列已存在，不需要迁移）。
  const generation_meta = {
    type_source: useDetected ? 'auto' : 'default',
    detected_type: detected?.type ?? null,
    confidence: detected?.confidence ?? null,
    needs_review: detected ? detected.needsReview === true : true,
    reason: detected?.reason ?? null,
  };

  return {
    source: ctx.source,
    subject_id: ctx.subject_id,
    knowledge_node_id: ctx.knowledge_node_id,
    type,
    stem: question.stem,
    // splitter 把选项解析成 [{key,text}]，正好是 schema 里 options jsonb 的形状
    options: question.options,
    answer: question.answer,
    analysis: question.analysis,
    // ★ m17431：归属由服务端按 token 决定（ctx.owner_user_id），
    //   不信任请求体里的 user_id。缺省 null = 公共题。
    owner_user_id: ctx.owner_user_id ?? null,
    // V1 接入对象存储后这里会是真 asset 引用；MVP 恒为 null（见 server/import/separate.mjs）
    asset_refs: assets.asset_refs.length > 0 ? assets.asset_refs : null,
    is_subjective: SUBJECTIVE_TYPES.has(type),
    generation_meta,
    // ★ m31124：导入批次档案。ctx.batch_id 由 runImport 在事务内先建批次再注入；
    //   手动建题（POST /questions）不经过这里，三列为 NULL。
    batch_id: ctx.batch_id ?? null,
    import_filename: ctx.batch_id ? (ctx.import_filename ?? null) : null,
    imported_at: ctx.batch_id ? (ctx.imported_at ?? null) : null,
  };
}

/**
 * 执行导入（四阶段）。
 * 单独导出，便于集成测试直接调用而不必起 HTTP。
 */

/**
 * 阶段 1–2：解码 → 文本抽取 → 切题 → 题干清洗。
 *
 * ★ m32773：抽成独立函数，供「预检」与「真导入」共用。
 *   两条路径必须拿到**同一份**解析结果 —— 否则预检说 300 道新题、真导入只进 298 道，
 *   用户无法理解差在哪。本函数不碰数据库（纯解码 + 纯计算），所以预检可以直接调。
 *
 * @returns {Promise<{buffer: Buffer, filename: string, extracted: object, isJson: boolean,
 *   split: object, parseProblems: Array<{message: string}>, createCtx: object,
 *   sanitizedCount: number, cleanedQuestions: Array<object>}>}
 */
async function parseImportBody(body, ownerUserId) {
  if (!body.filename || String(body.filename).trim() === '') {
    throw Object.assign(new Error('filename 必填'), { code: 'MISSING_FILENAME' });
  }

  const buffer = decodeBase64(body.content_base64);
  const filename = String(body.filename);

  // 阶段 1：文本抽取（内部负责 10MB / 100 页 / 扫描版判定，抛 413/422/415）。
  // ★ m32773：.tillroad 的 gzip 解压也在这层（extract.mjs 看字节头判定）。
  const extracted = await extractText({ buffer, mime: body.mime, filename });

  // 阶段 2：切题（纯函数，无需事务）
  //
  // ★ m30197：JSON 题库（AI 按 docs/question-recognition-prompt.md 产出）走另一条路。
  //   原因：subject / node 是**结构化的每题字段**，纯文本切题拿不到它们。
  //   两者的产出形状刻意对齐（stem/options/answer/analysis/detected_type），
  //   所以后面的清洗 / 判重 / 入库一行都不用改。
  const isJson = extracted.kind === 'json';
  const split = isJson
    ? parseQuestionJson(extracted.text)
    : splitQuestions(extracted.text);

  // 单题级的解析问题（只可能来自 JSON）：不整份失败，先收集起来随结果返回，
  // 让用户看得见「哪几条没进来」，而不是莫名其妙少了几题。
  const parseProblems = (split.errors ?? []).map((e) => ({
    message:
      e.index >= 0
        ? `第 ${e.index + 1} 条未导入：${e.reason}`
        : `文件解析失败：${e.reason}`,
  }));

  if (split.questions.length === 0) {
    // 抽到文字但一条题都没切出来：多半是分隔符不在四类里 / JSON 形状不对。
    // 用 importError 而不是裸 Error：message 必须进 body，否则 httpError 的
    // 「有 code 的普通 Error -> 400 {error:code}」分支会把提示文案丢弃，
    // 用户只看到一个没有下文的 EMPTY_CONTENT（CI 实际踩过）。
    const hint = parseProblems.length > 0
      ? parseProblems[0].message
      : '请确认题号以「1.」「（1）」「一、」「第1题」开头，或手动录入';
    throw importError('EMPTY_CONTENT', 400, `未识别到任何题目：${hint}`);
  }

  // ★ m18680 A3：导入进度日志。50 题在 Neon 冷启动下实测 20s+，
  //   没有这行日志时线上只能看到「客户端超时」，分不清卡在抽取、切题还是入库。
  console.log(
    `[IMPORT] 切题 ${split.questions.length} 道（kind=${extracted.kind}, mime=${extracted.mime}, bytes=${buffer.length}, owner=${ownerUserId ?? 'public'}）`,
  );
  const createCtx = {
    source: body.source || DEFAULT_SOURCE,
    subject_id: body.subject_id || null,
    knowledge_node_id: body.knowledge_node_id || null,
    default_type: body.default_type || DEFAULT_TYPE,
    // ★ m17431：归属只认 token 映射出来的 userId，不信任请求体里的 user_id。
    //   请求体里的 user_id 会被 server/index.mjs 改写成 authUserId，
    //   但这里仍显式用 ownerUserId 参数，避免任何调用方绕过鉴权。
    owner_user_id: ownerUserId ?? null,
  };

  // ★ 清洗（core/text.mjs 的 sanitizeQuestionText）：把题干里连续的下划线占位符
  //   （____ / ＿＿）统一替换成「（  ）」，只影响**展示文本**。
  //   options / answer / analysis 不清洗（选项与答案里的下划线可能是数学符号）。
  //
  //   ★ 关于 content_hash：core.normalizeQuestionText **一行未动**，哈希口径本身没变；
  //     但仓储层 questions.create() 是用**传进去的 stem** 现算 hash 的
  //     （server/repositories/questions.mjs 的 contentHashOf(input)），
  //     而本轮不允许改 questions.mjs —— 所以含占位符的题，
  //     其 content_hash 会是「清洗后题干」的哈希，与清洗前导入的同一道题不同。
  //     这一点已作为已知偏差记录在交付说明里。
  let sanitizedCount = 0;
  const cleanedQuestions = split.questions.map((q) => {
    const cleaned = sanitizeQuestionText(q.stem);
    if (cleaned !== q.stem) sanitizedCount += 1;
    return { ...q, stem: cleaned };
  });

  return {
    buffer,
    filename,
    extracted,
    isJson,
    // ★ m34301：.tillroad 导出文件带 subjects / knowledge_nodes 两张表，需要跨设备重映射。
    isTillroad: split.isTillroad === true,
    fileSubjects: split.subjects ?? [],
    fileNodes: split.knowledgeNodes ?? [],
    split,
    parseProblems,
    createCtx,
    sanitizedCount,
    cleanedQuestions,
  };
}

export async function runImport(pool, body = {}, ownerUserId = null) {
  const {
    buffer,
    filename,
    isJson,
    split,
    parseProblems,
    createCtx,
    sanitizedCount,
    cleanedQuestions,
    extracted,
    // ★ m34301：.tillroad 的分类树（普通 AI JSON 为空数组 / false）。
    isTillroad,
    fileSubjects,
    fileNodes,
  } = await parseImportBody(body, ownerUserId);

  // 阶段 3 + 4：去重与入库必须在同一事务内 —— 否则两个并发导入同一份文件时，
  // 双方都能通过 dedupe（此时还都没写），然后双双插入同 hash 的两行。
  //
  // ★ m30197：subject / node 解析也放在事务内 —— 它会**自动创建考点**（写库），
  //   必须与题目入库同生共死；抽到事务外会出现「题目回滚了但考点留在库里」。
  return withTransaction(pool, async (client) => {
    // ── m34301：.tillroad 跨设备 ID 重映射 ────────────────────────────────
    // 导出文件里的 subject_id / knowledge_node_id 是**原设备的 uuid**，目标库里不存在。
    // 先把文件里的科目树 / 考点树在目标库重建（已有同名同路径则复用），拿到
    // 「旧 uuid → 新 uuid」映射表，再拿它改写每道题的归属。
    //
    // 放在同一事务里的理由：它会建科目与考点（写库），必须与题目入库同生共死；
    // 否则「题全重复没入库」时会在库里白留一堆空科目/空考点。
    // 只有真带 subjects / knowledge_nodes 的文件（.tillroad）才走这条路，
    // 普通 AI JSON（只有 questions）里 isTillroad 为 false，行为一字未改。
    const tillroad = isTillroad
      ? await remapTillroad(client, ownerUserId ?? '', { subjects: fileSubjects, knowledgeNodes: fileNodes })
      : null;
    // ── m30197 A3：逐题解析 subject / node ──────────────────────────────────
    // 只有 from_file 模式才看文件里的 subject/node：uniform 模式要保证
    // 「所有题都进界面选的那个科目」的旧行为，不能被文件里的字段意外带跑。
    const fromFile = String(body.subject_mode ?? '').trim() === SUBJECT_MODE_FROM_FILE;

    // ── m31124：先建导入批次，再入库题目 ────────────────────────────────
    // 为什么在事务里「先占位后回填」：题目行必须在本轮 INSERT 时就带上 batch_id，
    // 而 batch_id 由 DB 生成（gen_random_uuid），所以得先插批次行拿到 id。
    // question_count 先写 0，题目全部插完后回填成真实条数。
    // 整段在同一个 withTransaction 里 —— 导入失败就整体回滚，不会留「空批次」。
    // 公共题（ownerUserId 为空）没有归属用户，不建批次（三列恒为 NULL）。
    let batchId = null;
    if (ownerUserId) {
      const batchRow = await importBatchesRep.create(client, {
        userId: ownerUserId,
        filename,
      });
      batchId = batchRow.id;
    }
    // 注入了 batch_id 的 createCtx；后续逐题 toCreateInput 用这个而不是外层 createCtx。
    const batchCtx = {
      ...createCtx,
      batch_id: batchId,
      import_filename: batchId ? filename : null,
      imported_at: batchId ? new Date() : null,
    };
    // 同一科目文本只查一次库；同一科目下的同一路径也只解析一次（含只建一次的考点）。
    const subjectResolver = createSubjectResolver(client, ownerUserId ?? '');
    const nodeResolvers = new Map();
    const nodeResolverFor = (subjectId) => {
      let r = nodeResolvers.get(subjectId);
      if (!r) {
        r = createNodeResolver(client, subjectId);
        nodeResolvers.set(subjectId, r);
      }
      return r;
    };

    const matchedBySubject = new Map(); // subject_id -> {subject_id, name, count}
    const unmatchedSubjects = new Map(); // 文件里的原文 -> 出现次数
    let matchedCount = 0;
    let unmatchedCount = 0;
    const createdPaths = [];
    const createdSeen = new Set();

    const candidates = [];
    for (const q of cleanedQuestions) {
      let subjectId = createCtx.subject_id;
      let nodeId = createCtx.knowledge_node_id;
      // subject 是否「可信」（用于决定能否解析 node）：文件没写 subject、或写且匹配成功。
      // 不能用 subjectId !== 默认值 判断 —— 匹配到的科目恰好等于默认科目时会误判。
      let subjectResolved = true;

      // ★ m34301：.tillroad 文件里的题带的是**原设备的** subject_id / knowledge_node_id，
      //   用导出时重建的映射表换成本机 uuid。这是与 from_file 并列的另一条归属来源：
      //   导出文件没有 subject / node 文本字段，只能靠 uuid 映射。
      //   两个字段都没带（普通 AI JSON）时 resolveQuestion 返回 undefined，不覆盖默认值。
      if (tillroad) {
        const mapped = tillroad.resolveQuestion(q);
        if (mapped.subject_id !== undefined) {
          subjectId = mapped.subject_id;
          nodeId = mapped.knowledge_node_id;
        }
      }

      if (fromFile) {
        const subjectText = String(q.subject ?? '').trim();
        const nodeText = String(q.node ?? '').trim();

        if (subjectText !== '') {
          const hit = await subjectResolver(subjectText);
          if (hit) {
            subjectId = hit.subject_id;
            subjectResolved = true;
            matchedCount += 1;
            const prev = matchedBySubject.get(hit.subject_id);
            if (prev) prev.count += 1;
            else matchedBySubject.set(hit.subject_id, { subject_id: hit.subject_id, name: hit.name, count: 1 });
          } else {
            // ★ 硬约束：subject 匹配失败不自动建科目，只记下来让用户手动分配。
            //   此时 subjectId 仍是请求里的默认值（可能为 null = 未分类）。
            subjectResolved = false;
            unmatchedCount += 1;
            unmatchedSubjects.set(subjectText, (unmatchedSubjects.get(subjectText) ?? 0) + 1);
          }
        }

        // ★ 只有「文件里的 subject 为空（走兜底科目）」或「subject 匹配成功」时才解析 node。
        //   文件写了 subject 但库里匹配不到时，这条 node 路径属于一个我们并不掌握的科目树；
        //   若把它挂在兜底科目下，会把别的科目的考点污染进来（用户看到莫名其妙的考点）。
        const subjectUsable = subjectResolved;
        if (nodeText !== '' && subjectUsable) {
          // 没有科目就没有考点树可挂（knowledge_node 必须属于某个 subject）。
          const nodeHit = subjectId ? await nodeResolverFor(subjectId)(nodeText) : null;
          nodeId = nodeHit ? nodeHit.knowledge_node_id : null;
          if (nodeHit && nodeHit.created.length > 0) {
            const path = splitNodePath(nodeText).join('/');
            if (!createdSeen.has(path)) {
              createdSeen.add(path);
              createdPaths.push(path);
            }
          }
        }
      }

      candidates.push(
        toCreateInput(q, { ...batchCtx, subject_id: subjectId, knowledge_node_id: nodeId }),
      );
    }

    if (fromFile) {
      console.log(
        `[IMPORT] 科目匹配：命中 ${matchedCount} 题 / 未命中 ${unmatchedCount} 题，自动新建考点 ${createdPaths.length} 条`,
      );
    }

    // 题型识别统计：自动识别成功 / 需要人工确认。
    const typeDetected = candidates.filter((c) => c.generation_meta.type_source === 'auto').length;
    const typeNeedsReview = candidates.filter((c) => c.generation_meta.needs_review === true).length;

    // 题干/选项里的图片占位：MVP 不落存储，但要把数量告诉用户，
    // 否则「我的题图去哪了」会成为最常见的支持问题。
    const imageCount = candidates.reduce(
      (n, item) => n + separateAssets({ stem: item.stem, options: item.options, analysis: item.analysis }).placeholders.length,
      0,
    );

    const { newQuestions, duplicates } = await dedupe(
      candidates,
      client,
      ownerUserId ?? null,
    );

    // ★ m32773：重复题的处理方式（skip / overwrite）。
    //   skip      —— 默认。重复题原样留在库里，本次不写（与 m32773 之前完全一致）。
    //   overwrite —— 用文件里的内容覆盖库里同 hash 的题（只改内容字段，保留 id / owner / created_at）。
    // 非法值回落 skip（见 parseDuplicateAction 的注释）。
    const duplicateAction = parseDuplicateAction(body);
    const candidateByHash = new Map();
    for (const item of candidates) candidateByHash.set(contentHashOf(item), item);

    let overwritten = 0;
    if (duplicateAction === DUPLICATE_ACTION_OVERWRITE) {
      overwritten = await overwriteDuplicates(client, duplicates, candidateByHash, ownerUserId ?? null);
    }
    // skipped = 本次没写进去的重复题数（overwrite 模式下已覆盖的不算跳过）。
    let skipped = duplicates.length - overwritten;

    // A3：查重结果 —— 与「插入成功」分开打，才能区分「都是重复题」与「插入失败」。
    console.log(
      `[IMPORT] 查重命中 ${duplicates.length} 条，待插入 ${newQuestions.length} 条`,
    );
    const imported = [];
    for (const item of newQuestions) {
      // create 内部会再查一次 hash：dedupe 与 create 之间可能被并发写入抢先。
      // 这一层不是冗余 —— dedupe 解决「告诉用户哪些被跳过」，
      // create 解决「不论如何不允许两行同 hash」。撞上了就跳过，不整批失败。
      try {
        imported.push(await questionsRep.create(client, item));
        // ★ m18680 A6：每 10 题打一次点。只加日志，不改事务语义 ——
        //   仍然是整段一个事务，中途失败会整笔回滚。
        if (imported.length % 10 === 0) {
          console.log(`[IMPORT] 已插入 ${imported.length}/${newQuestions.length}`);
        }
      } catch (err) {
        if (err && err.code === 'DUPLICATE_QUESTION') {
          duplicates.push({
            content_hash: err.body?.incoming?.content_hash ?? null,
            existing_id: err.body?.current?.id ?? null,
            stem: item.stem,
            raced: true,
          });
          // 并发撞车的那条也不可能被本次覆盖（它是刚被别人插进去的）。
          skipped += 1;
          continue;
        }
        throw err;
      }
    }
    // ★ m31124：把批次行上的 question_count 回填成**实际插入成功**的条数
    //   （不是 candidates.length —— 判重跳过的题不属本批新增）。
    //   UPDATE 走 (id, user_id) 双条件，仓储层已保证只改自己的批次。
    if (batchId && ownerUserId) {
      try {
        await importBatchesRep.updateQuestionCount(client, {
          batchId,
          userId: ownerUserId,
          questionCount: imported.length,
        });
      } catch (err) {
        // 回填失败不该让整批导入回滚：题已经插好了，批次只是少了统计数字。
        // 批次下拉会显示「N 题」为 0，用户仍能看到批次并删除。
        console.warn(`[IMPORT] 批次统计回填失败（batch=${batchId}）：${err && err.message}`);
      }
    }

    console.log(
      `[IMPORT] 完成：新增 ${imported.length} 条，覆盖 ${overwritten} 条，跳过 ${skipped} 条（action=${duplicateAction}）`,
    );
    return {
      // ★ m32773 C3：响应拆分。
      //   imported.new       —— 新写入库的题数
      //   imported.overwritten —— 重复题里被覆盖的条数（只有 overwrite 模式才可能 > 0）
      //   duplicates.skipped  —— 因库内已存在而没写进去的条数
      //   duplicates.overwritten —— 与 imported.overwritten 同口径（保留给前端按「重复题」维度展示）
      // 旧字段 imported(数字) / duplicates(数组) 不能再用：前端要能分别显示「新增 / 覆盖 / 跳过」，
      // 所以这里改成对象，并把明细挪到 duplicate_details（数组，形状与旧 duplicates 一致）。
      imported: { new: imported.length, overwritten },
      batch_id: batchId,
      import_filename: batchId ? filename : null,
      duplicates: { skipped, overwritten },
      duplicate_details: duplicates,
      // 单题级的解析问题（JSON 里某条形状不对）也走 errors，前端已有展示位。
      errors: parseProblems,
      // ★ m30197 A4：按科目匹配与考点自动创建的统计（旧字段一个都没删）。
      subject_matched: {
        matched_count: matchedCount,
        unmatched_count: unmatchedCount,
        unmatched_subjects: [...unmatchedSubjects.keys()],
        matched_subjects: [...matchedBySubject.values()],
      },
      node_created: {
        created_count: createdPaths.length,
        created_paths: createdPaths,
      },
      // ★ m34301 B2：跨设备恢复的统计。只有带 subjects / knowledge_nodes 的文件
      //   （.tillroad）才有意义；普通 AI JSON / 文本导入时全为 0（前端据此不渲染该区块）。
      //   subjects_mapped / nodes_mapped —— 复用已有同名科目 / 同路径考点（未新建）
      //   subjects_created / nodes_created —— 目标库里没有、本次新建的
      //   questions_without_subject —— 文件里给了 subject_id 但映射不到（脏数据 / 旧版）
      remap_result: {
        subjects_mapped: tillroad ? tillroad.stats.subjects_mapped : 0,
        subjects_created: tillroad ? tillroad.stats.subjects_created : 0,
        nodes_mapped: tillroad ? tillroad.stats.nodes_mapped : 0,
        nodes_created: tillroad ? tillroad.stats.nodes_created : 0,
        questions_without_subject: tillroad ? tillroad.countQuestionsWithoutSubject() : 0,
        created_subject_names: tillroad ? tillroad.createdSubjectNames : [],
        created_node_paths: tillroad ? tillroad.createdNodePaths : [],
      },
      stats: {
        kind: extracted.kind,
        mime: extracted.mime,
        pages: extracted.pages ?? null,
        // JSON 的总条数以文件里声明的条数为准（含形状不对、没进来的），
        // 文本类则等于切出来的题数 —— 两者都是「用户以为文件里有多少题」。
        total: split.total ?? split.questions.length,
        preamble_lines: split.preamble ? split.preamble.length : 0,
        bytes: buffer.length,
        image_placeholders: imageCount,
        // 本轮新增：清洗与题型识别的统计（原有字段一个都没删）
        sanitized: sanitizedCount,
        type_detected: typeDetected,
        type_needs_review: typeNeedsReview,
        subject_mode: fromFile ? SUBJECT_MODE_FROM_FILE : SUBJECT_MODE_UNIFORM,
        subject_from_file_available: isJson && hasAnySubject(split.questions),
      },
    };
  });
}

export function match(method, seg, ctx) {
  const { pool, body, authUserId } = ctx;

  // ★ m32773：预检端点必须排在真正导入之前。
  //   路径长度不同（3 段 vs 2 段）本来不会误匹配，但顺序仍按「更具体的在前」写，
  //   免得以后有人把判断写成前缀匹配时踩坑。
  if (method === 'POST' && seg.length === 3 && seg[0] === 'questions' && seg[1] === 'import' && seg[2] === 'preview') {
    return (async () => {
      try {
        const result = await previewImport(pool, body, authUserId ?? null);
        return ok(result, 200);
      } catch (err) {
        if (err && !err.statusCode && typeof err.code === 'string' && err.code.startsWith('MISSING')) {
          return fail(err.code, 400, { message: err.message });
        }
        if (err && !err.statusCode && err.code === 'INVALID_BASE64') {
          return fail('INVALID_BASE64', 400, { message: err.message });
        }
        throw err;
      }
    })();
  }

  if (method === 'POST' && seg.length === 2 && seg[0] === 'questions' && seg[1] === 'import') {
    return (async () => {
      try {
        const result = await runImport(pool, body, authUserId ?? null);
        return ok(result, 200);
      } catch (err) {
        // 请求体形状问题（缺 filename / base64 非法）在本层翻译成 400，
        // 其余带 statusCode 的（413/422/415）由 _http.httpError 原样透出。
        if (err && !err.statusCode && typeof err.code === 'string' && err.code.startsWith('MISSING')) {
          return fail(err.code, 400, { message: err.message });
        }
        if (err && !err.statusCode && err.code === 'INVALID_BASE64') {
          return fail('INVALID_BASE64', 400, { message: err.message });
        }
        throw err;
      }
    })();
  }

  if (method === 'POST' && seg.length === 1 && seg[0] === 'questions-import') {
    // 兼容别名：早期文档里写成 /questions-import，保留以免调用方改两次。
    return (async () => {
      try {
        const result = await runImport(pool, body, authUserId ?? null);
        return ok(result, 200);
      } catch (err) {
        if (err && !err.statusCode && typeof err.code === 'string' && err.code.startsWith('MISSING')) {
          return fail(err.code, 400, { message: err.message });
        }
        if (err && !err.statusCode && err.code === 'INVALID_BASE64') {
          return fail('INVALID_BASE64', 400, { message: err.message });
        }
        throw err;
      }
    })();
  }

  return null;
}
