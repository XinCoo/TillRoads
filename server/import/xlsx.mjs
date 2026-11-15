// server/import/xlsx.mjs
// 题路 TillRoad · BE-02：最小 xlsx 文本读取（纯 Node，零第三方依赖）
//
// 为什么要自己写：
//   BE-02 禁做「Excel 复杂版式解析」，只要求「单 sheet 纯文本」（拍板项 2 / T3）。
//   为这一个用途引入 exceljs（及其 zip/stream 依赖树）不划算，而 xlsx 本质是
//   zip + 若干 XML。这里只做两件事：解 zip、把 sharedStrings + 第一张 sheet
//   的单元格按行拼成 tab 分隔文本。样式、合并单元格、公式、多 sheet 一律不管。
//
// 已知局限（写进 README）：
//   * 只读第一张 sheet；
//   * 公式取缓存值（<v>），公式文本（<f>）忽略；
//   * 合并单元格只有左上角有值，其余为空 —— 靠人工校对兜。
//
// 不 import pg、不 import pdfjs-dist：和 splitter.mjs 一样保持可独立单测。

import { inflateRawSync } from 'node:zlib';

const SIG_EOCD = 0x06054b50;
const SIG_CEN = 0x02014b50;
const SIG_LOC = 0x04034b50;

/**
 * 从 zip buffer 里读出指定文件名的内容。
 * 只支持 stored(0) 与 deflate(8) —— 这两种覆盖了 Excel/WPS/Numbers 的全部产出。
 */
export function readZipEntries(buffer) {
  // EOCD 在文件末尾，后面最多跟 65535 字节注释，所以从尾部往回找。
  let eocd = -1;
  const minPos = Math.max(0, buffer.length - 0xffff - 22);
  for (let i = buffer.length - 22; i >= minPos; i -= 1) {
    if (buffer.readUInt32LE(i) === SIG_EOCD) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('xlsx: 不是合法 zip（未找到 EOCD）');

  const count = buffer.readUInt16LE(eocd + 10);
  const cenOffset = buffer.readUInt32LE(eocd + 16);

  const entries = new Map();
  let p = cenOffset;
  for (let i = 0; i < count; i += 1) {
    if (buffer.readUInt32LE(p) !== SIG_CEN) break;
    const method = buffer.readUInt16LE(p + 10);
    const compSize = buffer.readUInt32LE(p + 20);
    const nameLen = buffer.readUInt16LE(p + 28);
    const extraLen = buffer.readUInt16LE(p + 30);
    const commentLen = buffer.readUInt16LE(p + 32);
    const localOffset = buffer.readUInt32LE(p + 42);
    const name = buffer.slice(p + 46, p + 46 + nameLen).toString('utf8');

    // 本地文件头里的 nameLen/extraLen 可能与中央目录不同，必须以本地头为准。
    if (buffer.readUInt32LE(localOffset) === SIG_LOC) {
      const locNameLen = buffer.readUInt16LE(localOffset + 26);
      const locExtraLen = buffer.readUInt16LE(localOffset + 28);
      const dataStart = localOffset + 30 + locNameLen + locExtraLen;
      const raw = buffer.slice(dataStart, dataStart + compSize);
      entries.set(name, { method, raw });
    }

    p += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

/** 解出某个 entry 的文本（stored 直接转码，deflate 用 inflateRaw）。 */
export function readEntryText(entries, name) {
  const entry = entries.get(name);
  if (!entry) return null;
  if (entry.method === 0) return entry.raw.toString('utf8');
  if (entry.method === 8) return inflateRawSync(entry.raw).toString('utf8');
  throw new Error(`xlsx: 不支持的压缩方式 ${entry.method}（${name}）`);
}

/** XML 实体反转义（只处理 Excel 会产出的那几种）。 */
export function decodeXmlEntities(s) {
  return String(s)
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&#x([0-9a-fA-F]+);/g, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&amp;/g, '&');
}

/** 从 sharedStrings.xml 抽出共享字符串数组（下标即 <c t="s"><v>n</v> 的 n）。 */
export function parseSharedStrings(xml) {
  if (!xml) return [];
  const out = [];
  // <si> 里可能有多段 <t>（富文本 run），要拼接而不是只取第一个。
  const siRe = /<si\b[^>]*>([\s\S]*?)<\/si>/g;
  let m;
  while ((m = siRe.exec(xml)) !== null) {
    const inner = m[1];
    const tRe = /<t\b[^>]*>([\s\S]*?)<\/t>/g;
    let t;
    let acc = '';
    while ((t = tRe.exec(inner)) !== null) acc += t[1];
    out.push(decodeXmlEntities(acc));
  }
  return out;
}

/** 列名 A1/C12 -> 列序号 0/2（用于按行拼 tab 分隔）。 */
function columnIndex(ref) {
  const m = /^([A-Z]+)/.exec(String(ref || ''));
  if (!m) return null;
  let n = 0;
  for (const ch of m[1]) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n - 1;
}

/**
 * 解析第一张 worksheet，返回「每行 tab 拼接」的文本。
 * 单元格取值规则：t="s" 查 sharedStrings；t="inlineStr" 取 <is><t>；
 * 其它取 <v> 原始数字/布尔字面量（不转格式，够用于切题）。
 */
export function parseSheet(sheetXml, sharedStrings) {
  if (!sheetXml) return '';
  const lines = [];
  const rowRe = /<row\b[^>]*>([\s\S]*?)<\/row>/g;
  let r;
  while ((r = rowRe.exec(sheetXml)) !== null) {
    const cells = [];
    const cellRe = /<c\b([^>]*)>([\s\S]*?)<\/c>/g;
    let c;
    while ((c = cellRe.exec(r[1])) !== null) {
      const attrs = c[1];
      const inner = c[2];
      const ref = /\br="([^"]+)"/.exec(attrs);
      const type = /\bt="([^"]+)"/.exec(attrs);
      let value = '';

      if (type && type[1] === 's') {
        const v = /<v>([\s\S]*?)<\/v>/.exec(inner);
        if (v) value = sharedStrings[Number(v[1])] ?? '';
      } else if (type && type[1] === 'inlineStr') {
        const tRe = /<t\b[^>]*>([\s\S]*?)<\/t>/g;
        let t;
        while ((t = tRe.exec(inner)) !== null) value += t[1];
        value = decodeXmlEntities(value);
      } else {
        const v = /<v>([\s\S]*?)<\/v>/.exec(inner);
        if (v) value = decodeXmlEntities(v[1]);
      }

      const idx = ref ? columnIndex(ref[1]) : cells.length;
      cells[idx === null ? cells.length : idx] = value;
    }
    // 稀疏数组要先补空再 join，否则 A、C 两列会被拼成相邻两格
    const normalized = Array.from(cells, (v) => (v == null ? '' : v));
    const line = normalized.join('\t').replace(/\t+$/, '');
    if (line.trim() !== '') lines.push(line);
  }
  return lines.join('\n');
}

/** 从 xlsx buffer 抽出纯文本（第一张 sheet）。 */
export function readXlsxText(buffer) {
  const entries = readZipEntries(buffer);
  const shared = parseSharedStrings(readEntryText(entries, 'xl/sharedStrings.xml'));

  // 第一张 sheet 的文件名不一定是 sheet1.xml（取决于 workbook.xml 的 r:id 映射），
  // 取 worksheets 目录下编号最小的那个即可覆盖绝大多数导出工具。
  const sheetNames = [...entries.keys()]
    .filter((n) => /^xl\/worksheets\/sheet\d+\.xml$/.test(n))
    .sort((a, b) => {
      const na = Number(/(\d+)\.xml$/.exec(a)[1]);
      const nb = Number(/(\d+)\.xml$/.exec(b)[1]);
      return na - nb;
    });
  if (sheetNames.length === 0) throw new Error('xlsx: 未找到 worksheet（不是 Excel 2007+ 文件？）');

  return parseSheet(readEntryText(entries, sheetNames[0]), shared);
}
