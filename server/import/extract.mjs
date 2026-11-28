// server/import/extract.mjs
// 题路 TillRoad · BE-02：导入管线第 1 阶段（文本抽取）
//
// 职责：把「用户传上来的字节」变成「纯文本」，并按拍板项 1 做体积/页数硬上限。
// 不做的事（BE-02 禁做清单）：不 OCR、不解析扫描版 PDF、不做 Excel 复杂版式、
// 不落库。抽完就交给 splitter.mjs。
//
// 失败语义（错误码即 HTTP 契约，由 _http.httpError 原样输出）：
//   * 413 PAYLOAD_TOO_LARGE  —— 超过硬上限，客户端应拆分后重试（可重试，非用户输入错）
//   * 422 UNSUPPORTED_PDF    —— PDF 无文本层（扫描版），V1 才支持 OCR
//   * 422 UNSUPPORTED_IMAGE  —— 图片一律不支持（OCR 在 V1）
//   * 415 UNSUPPORTED_MEDIA  —— mime 不在白名单
//   * 400 EMPTY_CONTENT      —— 抽出来是空的（比如全是空白字符）
//   为什么扫描版用 422 而不是 400：请求本身合法（是一份真 PDF），只是服务端
//   当前能力不支持这种内容 —— 422 的语义正是「理解请求但无法处理」。

// ★ m32773：.tillroad 是 gzip 压缩的 JSON，导入时要解压。
//   用 node 内置 zlib，不引第三方解压库。
import { gunzipSync } from 'node:zlib';
import { readXlsxText } from './xlsx.mjs';

/** 拍板项 1 的硬上限。集中一处，避免散落在 handler 里各写一遍。 */
export const LIMITS = Object.freeze({
  maxBytes: 10 * 1024 * 1024, // 单文件 ≤10MB（比开发文档的 50MB 更严，MVP 收紧）
  maxPdfPages: 100, // 文字型 PDF ≤100 页（文档写 200，MVP 收紧）
  maxImages: 20, // 图片 ≤20 张（本轮没有 OCR，先留着给 V1 用）
});

/** 支持的 mime 白名单。别名归一后判定，避免 'text/x-markdown' 之类漏网。 */
export const MIME_ALIASES = Object.freeze({
  'text/markdown': 'markdown',
  'text/x-markdown': 'markdown',
  'text/plain': 'text',
  'text/csv': 'csv',
  'application/csv': 'csv',
  'application/pdf': 'pdf',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
  // ★ m30197：AI 按 docs/question-recognition-prompt.md 产出的题库 JSON。
  //   只有 JSON 里才有每题的 subject / node，所以必须能直接吃。
  'application/json': 'json',
  'text/json': 'json',
  'image/png': 'image',
  'image/jpeg': 'image',
  'image/jpg': 'image',
  'image/webp': 'image',
  'image/heic': 'image',
});

/** 按扩展名兜底：客户端常常发 application/octet-stream，靠文件名才认得出来。 */
const EXT_KINDS = Object.freeze({
  '.md': 'markdown',
  '.markdown': 'markdown',
  '.txt': 'text',
  '.csv': 'csv',
  '.pdf': 'pdf',
  '.xlsx': 'xlsx',
  '.png': 'image',
  '.jpg': 'image',
  '.jpeg': 'image',
  '.webp': 'image',
  '.heic': 'image',
  '.json': 'json',
  // ★ m32773：题库导出文件（JSON + gzip）。扩展名与 mime 都可能缺失
  //   （Android 上用户从「下载」里选，系统常给 application/octet-stream），
  //   所以 detectKind 靠扩展名就能认出来；真正的 gzip 解压看字节头。
  '.tillroad': 'json',
});
/**
 * 构造带 HTTP 语义的导入错误。
 * 形状对齐 repositories/_common.mjs：err.statusCode + err.code + err.body，
 * 这样 _http.httpError 的第一分支会原样采用，不需要路由层再翻译一次。
 */
export function importError(code, statusCode, message, extra = {}) {
  const err = new Error(message);
  err.name = 'ImportError';
  err.code = code;
  err.statusCode = statusCode;
  err.status = statusCode;
  err.body = { error: code, message, ...extra };
  return err;
}

/** 判定文件类型：先看 mime，再看扩展名（mime 缺失/泛型时）。 */
export function detectKind(mime, filename = '') {
  const m = String(mime || '').split(';')[0].trim().toLowerCase();
  if (MIME_ALIASES[m]) return MIME_ALIASES[m];
  const name = String(filename || '').toLowerCase();
  const dot = name.lastIndexOf('.');
  if (dot >= 0) {
    const ext = name.slice(dot);
    if (EXT_KINDS[ext]) return EXT_KINDS[ext];
  }
  return null;
}

/** 体积闸：超限立刻 413，不进解析（解析 10MB PDF 很贵）。 */
export function assertSize(buffer) {
  if (!buffer || typeof buffer.length !== 'number') {
    throw importError('EMPTY_CONTENT', 400, '没有收到文件内容');
  }
  if (buffer.length > LIMITS.maxBytes) {
    throw importError(
      'PAYLOAD_TOO_LARGE',
      413,
      `文件 ${(buffer.length / 1024 / 1024).toFixed(1)}MB 超过 ${LIMITS.maxBytes / 1024 / 1024}MB 上限，请拆分后重试`,
      { limit_bytes: LIMITS.maxBytes, actual_bytes: buffer.length },
    );
  }
}

/**
 * PDF：用 pdfjs-dist 抽文本层。
 *
 * 为什么用 legacy 构建：pdfjs-dist 的 package.json 没有 exports map，
 * 裸 import 'pdfjs-dist' 在 Node ESM 下会解析到 build/pdf.mjs（依赖 DOM 的现代构建），
 * 而 legacy/build/pdf.mjs 才是给非浏览器环境准备的。实测 61ms 可导入。
 * 它会往 stderr 打三条 "@napi-rs/canvas 缺失 / DOMMatrix 无法 polyfill" 的告警 ——
 * 我们只抽文本不渲染，这些告警无实际影响，测试里不要当失败。
 */
export async function extractPdfText(buffer) {
  const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs');
  const task = pdfjs.getDocument({
    data: new Uint8Array(buffer),
    // 不加载系统字体、不启用 eval：只是抽文本，减少不必要的环境依赖与攻击面。
    useSystemFonts: false,
    isEvalSupported: false,
  });

  let doc;
  try {
    doc = await task.promise;
  } catch (err) {
    throw importError('UNSUPPORTED_PDF', 422, 'PDF 无法解析，请确认文件未损坏或加密', {
      reason: err && err.message ? String(err.message).slice(0, 200) : 'parse_failed',
    });
  }

  try {
    if (doc.numPages > LIMITS.maxPdfPages) {
      throw importError(
        'PAYLOAD_TOO_LARGE',
        413,
        `PDF 共 ${doc.numPages} 页，超过 ${LIMITS.maxPdfPages} 页上限，请拆分后重试`,
        { limit_pages: LIMITS.maxPdfPages, actual_pages: doc.numPages },
      );
    }

    const pages = [];
    for (let p = 1; p <= doc.numPages; p += 1) {
      const page = await doc.getPage(p);
      const content = await page.getTextContent();
      // hasEOL 是 pdfjs 给出的「这里该换行」信号：不用它的话整页会被拼成一行，
      // 切题的「行首编号」判断就全废了。没有 hasEOL 的项之间补空格防止两个词粘住。
      let line = '';
      const lines = [];
      for (const item of content.items) {
        const str = item && typeof item.str === 'string' ? item.str : '';
        line += str;
        if (item && item.hasEOL) {
          lines.push(line);
          line = '';
        }
      }
      if (line !== '') lines.push(line);
      pages.push(lines.join('\n'));
    }

    const text = pages.join('\n');

    // 无文本层判定：扫描版 PDF 每页 items 为 0。用「去空白后字符数」而不是 trim，
    // 因为有些 PDF 会抽出不可见空格组成的空文本层。
    if (text.replace(/\s/g, '').length === 0) {
      throw importError(
        'UNSUPPORTED_PDF',
        422,
        '检测到扫描版 PDF，V1 将支持 OCR，当前请上传文字版或手动录入',
        { pages: doc.numPages, extracted_chars: 0 },
      );
    }

    return { text, pages: doc.numPages };
  } finally {
    // 释放 worker/文档资源。注意 destroy 在 loadingTask 上，不在 document 上
    // （实测 document 没有 destroy 方法，调用会 TypeError）。
    try {
      await task.destroy();
    } catch {
      /* 释放失败不影响已抽到的文本 */
    }
  }
}

/**
 * 主入口：抽出纯文本。
 *
 * @param {{buffer: Buffer, mime?: string, filename?: string}} file
 * @returns {Promise<{text: string, kind: string, mime: string, pages?: number}>}
 */
export async function extractText(file = {}) {
  const buffer = file.buffer;
  assertSize(buffer);

  const kind = detectKind(file.mime, file.filename);
  if (!kind) {
    throw importError(
      'UNSUPPORTED_MEDIA',
      415,
      '不支持的文件类型，请上传 Markdown / TXT / CSV / 文字版 PDF / XLSX / JSON / .tillroad',
      { mime: file.mime || null, filename: file.filename || null },
    );
  }

  let text;
  let pages;

  switch (kind) {
    case 'markdown':
    case 'text':
    case 'csv':
    case 'json': {
      // ★ m32773：.tillroad 是 gzip 后的 JSON（导出端压缩，导入端解压）。
      //   不看扩展名、只看字节头：`0x1f 0x8b` 是 gzip magic。这样即使
      //   用户把 .tillroad 改名成 .json（或反过来）也能正确解。
      //   解压后仍然只交给 utf8 → json_import.mjs 解析，抽取层不做 JSON.parse。
      const raw = Buffer.from(buffer);
      const isGzip = raw.length >= 2 && raw[0] === 0x1f && raw[1] === 0x8b;
      if (isGzip) {
        try {
          text = gunzipSync(raw).toString('utf8');
        } catch (err) {
          throw importError('INVALID_GZIP', 422, '题库文件解压失败，可能不是 .tillroad 导出文件或文件已损坏', {
            reason: err && err.message ? String(err.message).slice(0, 200) : 'gunzip_failed',
          });
        }
      } else {
        // JSON 与文本类一样直接转 utf8，"JSON 长什么样" 交给 json_import.mjs 解析。
        // 这里不 JSON.parse：抽取阶段只管「字节 → 文本」，解析失败在切题阶段报。
        text = raw.toString('utf8');
      }
      break;
    }
    case 'pdf': {
      const out = await extractPdfText(buffer);
      text = out.text;
      pages = out.pages;
      break;
    }
    case 'xlsx':
      try {
        // 单 sheet 纯文本（禁做复杂版式）：xlsx.mjs 只拼 tab 分隔的行。
        text = readXlsxText(Buffer.from(buffer));
      } catch (err) {
        throw importError('UNSUPPORTED_XLSX', 422, 'XLSX 解析失败，请另存为 .xlsx 或改用 CSV', {
          reason: err && err.message ? String(err.message).slice(0, 200) : 'parse_failed',
        });
      }
      break;
    case 'image':
      // 拍板项 3：OCR 放 V1，本轮不引 OCR 库。
      throw importError(
        'UNSUPPORTED_IMAGE',
        422,
        '检测到图片，V1 将支持 OCR，当前请上传文字版或手动录入',
        { limit_images: LIMITS.maxImages },
      );
    default:
      throw importError('UNSUPPORTED_MEDIA', 415, '不支持的文件类型');
  }

  // BOM 会让第一行以 \uFEFF 开头，切题时第一个分隔符判断会失效。
  text = String(text ?? '').replace(/^\uFEFF/, '');

  if (text.replace(/\s/g, '').length === 0) {
    throw importError('EMPTY_CONTENT', 400, '文件内容为空，没有可导入的题目', { kind });
  }

  return { text, kind, mime: String(file.mime || ''), ...(pages ? { pages } : {}) };
}
