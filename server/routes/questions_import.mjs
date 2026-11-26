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
import { extractText, importError } from '../import/extract.mjs';
import { splitQuestions } from '../import/splitter.mjs';
import { dedupe } from '../import/dedupe.mjs';
import { separateAssets } from '../import/separate.mjs';
import { fail, ok } from './_http.mjs';
import { sanitizeQuestionText } from '../../core/index.mjs';
/** 这些分隔符编号不再作为题干前缀入库（splitter 已剥离），这里只用于报错行号。 */

const DEFAULT_SOURCE = 'import';
const DEFAULT_TYPE = 'choice';

// 主观类题型：这些题型的 is_subjective 必须为 true。
// 取值口径见 tillroad_app/lib/api/question_api.dart 的 BankQuestion.typeLabel。
const SUBJECTIVE_TYPES = new Set(['short_answer', 'essay', 'subjective', 'material']);

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
  };
}

/**
 * 执行导入（四阶段）。
 * 单独导出，便于集成测试直接调用而不必起 HTTP。
 */
export async function runImport(pool, body = {}, ownerUserId = null) {
  if (!body.filename || String(body.filename).trim() === '') {
    throw Object.assign(new Error('filename 必填'), { code: 'MISSING_FILENAME' });
  }

  const buffer = decodeBase64(body.content_base64);
  const filename = String(body.filename);

  // 阶段 1：文本抽取（内部负责 10MB / 100 页 / 扫描版判定，抛 413/422/415）
  const extracted = await extractText({ buffer, mime: body.mime, filename });

  // 阶段 2：规则切题（纯函数，无需事务）
  const split = splitQuestions(extracted.text);

  if (split.questions.length === 0) {
    // 抽到文字但一条题都没切出来：多半是分隔符不在四类里。
    // 明确告诉用户「支持哪四类」，而不是含糊地说「没有可用内容」。
    // 用 importError 而不是裸 Error：message 必须进 body，否则 httpError 的
    // 「有 code 的普通 Error -> 400 {error:code}」分支会把提示文案丢弃，
    // 用户只看到一个没有下文的 EMPTY_CONTENT（CI 实际踩过）。
    throw importError(
      'EMPTY_CONTENT',
      400,
      '未识别到任何题目：请确认题号以「1.」「（1）」「一、」「第1题」开头，或手动录入',
    );
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

  const candidates = cleanedQuestions.map((q) => toCreateInput(q, createCtx));

  // 题型识别统计：自动识别成功 / 需要人工确认。
  const typeDetected = candidates.filter((c) => c.generation_meta.type_source === 'auto').length;
  const typeNeedsReview = candidates.filter((c) => c.generation_meta.needs_review === true).length;

  // 题干/选项里的图片占位：MVP 不落存储，但要把数量告诉用户，
  // 否则「我的题图去哪了」会成为最常见的支持问题。
  const imageCount = candidates.reduce(
    (n, item) => n + separateAssets({ stem: item.stem, options: item.options, analysis: item.analysis }).placeholders.length,
    0,
  );

  // 阶段 3 + 4：去重与入库必须在同一事务内 —— 否则两个并发导入同一份文件时，
  // 双方都能通过 dedupe（此时还都没写），然后双双插入同 hash 的两行。
  return withTransaction(pool, async (client) => {
    const { newQuestions, duplicates } = await dedupe(
      candidates,
      client,
      ownerUserId ?? null,
    );

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
          continue;
        }
        throw err;
      }
    }

    console.log(
      `[IMPORT] 完成：插入 ${imported.length} 条，重复 ${duplicates.length} 条，耗时见上游`,
    );
    return {
      imported: imported.length,
      duplicates,
      errors: [],
      stats: {
        kind: extracted.kind,
        mime: extracted.mime,
        pages: extracted.pages ?? null,
        total: split.questions.length,
        preamble_lines: split.preamble.length,
        bytes: buffer.length,
        image_placeholders: imageCount,
        // 本轮新增：清洗与题型识别的统计（原有字段一个都没删）
        sanitized: sanitizedCount,
        type_detected: typeDetected,
        type_needs_review: typeNeedsReview,
      },
    };
  });
}

export function match(method, seg, ctx) {
  const { pool, body, authUserId } = ctx;

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
