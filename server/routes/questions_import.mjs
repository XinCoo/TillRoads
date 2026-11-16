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

/** 这些分隔符编号不再作为题干前缀入库（splitter 已剥离），这里只用于报错行号。 */

const DEFAULT_SOURCE = 'import';
const DEFAULT_TYPE = 'choice';

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

/** 切题结果 -> 待入库的题（补上归属、默认题型、source）。 */
function toCreateInput(question, ctx) {
  // 第四阶段：资产分离（MVP 只识别占位、不落库，asset_refs 恒为空数组）
  const assets = separateAssets(question);
  return {
    source: ctx.source,
    subject_id: ctx.subject_id,
    knowledge_node_id: ctx.knowledge_node_id,
    type: ctx.default_type,
    stem: question.stem,
    // splitter 把选项解析成 [{key,text}]，正好是 schema 里 options jsonb 的形状
    options: question.options,
    answer: question.answer,
    analysis: question.analysis,
    // V1 接入对象存储后这里会是真 asset 引用；MVP 恒为 null（见 server/import/separate.mjs）
    asset_refs: assets.asset_refs.length > 0 ? assets.asset_refs : null,
    is_subjective: ctx.default_type === 'short_answer' || ctx.default_type === 'essay',
  };
}

/**
 * 执行导入（四阶段）。
 * 单独导出，便于集成测试直接调用而不必起 HTTP。
 */
export async function runImport(pool, body = {}) {
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

  const createCtx = {
    source: body.source || DEFAULT_SOURCE,
    subject_id: body.subject_id || null,
    knowledge_node_id: body.knowledge_node_id || null,
    default_type: body.default_type || DEFAULT_TYPE,
  };

  const candidates = split.questions.map((q) => toCreateInput(q, createCtx));

  // 题干/选项里的图片占位：MVP 不落存储，但要把数量告诉用户，
  // 否则「我的题图去哪了」会成为最常见的支持问题。
  const imageCount = candidates.reduce(
    (n, item) => n + separateAssets({ stem: item.stem, options: item.options, analysis: item.analysis }).placeholders.length,
    0,
  );

  // 阶段 3 + 4：去重与入库必须在同一事务内 —— 否则两个并发导入同一份文件时，
  // 双方都能通过 dedupe（此时还都没写），然后双双插入同 hash 的两行。
  return withTransaction(pool, async (client) => {
    const { newQuestions, duplicates } = await dedupe(candidates, client);

    const imported = [];
    for (const item of newQuestions) {
      // create 内部会再查一次 hash：dedupe 与 create 之间可能被并发写入抢先。
      // 这一层不是冗余 —— dedupe 解决「告诉用户哪些被跳过」，
      // create 解决「不论如何不允许两行同 hash」。撞上了就跳过，不整批失败。
      try {
        imported.push(await questionsRep.create(client, item));
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
      },
    };
  });
}

export function match(method, seg, ctx) {
  const { pool, body } = ctx;

  if (method === 'POST' && seg.length === 2 && seg[0] === 'questions' && seg[1] === 'import') {
    return (async () => {
      try {
        const result = await runImport(pool, body);
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
        const result = await runImport(pool, body);
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
