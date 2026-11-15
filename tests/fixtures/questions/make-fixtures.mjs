// tests/fixtures/questions/make-fixtures.mjs
// 生成 BE-02 集成测试所需的两个最小 PDF（手写 PDF，不引入生成库）。
//
// 为什么手写：为了一条「扫描版 PDF → 422」的断言去装一个 PDF 生成库不划算，
// 而 PDF 1.4 的最小结构是文本可拼的。两个文件都用固定内容，生成结果可复现。
//
// 用法：node tests/fixtures/questions/make-fixtures.mjs
// 产物：same dir 下的 scanned-no-text.pdf / text-simple.pdf（已提交，无需重生成）

import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * 拼一个单页 PDF。
 * @param {string[] | null} textLines 为 null 时不写任何文本绘制指令（模拟扫描件）
 */
function buildPdf(textLines) {
  const objects = [];
  const hasFont = Array.isArray(textLines) && textLines.length > 0;

  const contentLines = hasFont
    ? [
        'BT',
        '/F1 12 Tf',
        '14 TL',
        '50 780 Td',
        ...textLines.map((l) => `(${l.replace(/([()\\])/g, '\\$1')}) Tj T*`),
        'ET',
      ]
    : ['% 扫描件无文本层：本例不产生任何文本绘制指令', '0 0 1 rg 0 0 595 842 re f'];

  const content = contentLines.join('\n');
  const contentBytes = Buffer.from(content, 'latin1');

  objects.push('<< /Type /Catalog /Pages 2 0 R >>');
  objects.push('<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  objects.push(
    hasFont
      ? '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>'
      : '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << >> /Contents 5 0 R >>',
  );
  if (hasFont) objects.push('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  objects.push({ stream: contentBytes });

  // 组装 + 记录每个对象的字节偏移
  const chunks = [];
  let offset = 0;
  const push = (buf) => {
    chunks.push(buf);
    offset += buf.length;
  };

  push(Buffer.from('%PDF-1.4\n', 'latin1'));

  const offsets = [];
  objects.forEach((obj, i) => {
    offsets.push(offset);
    const head = Buffer.from(`${i + 1} 0 obj\n`, 'latin1');
    push(head);
    if (typeof obj === 'string') {
      push(Buffer.from(`${obj}\n`, 'latin1'));
      push(Buffer.from('endobj\n', 'latin1'));
    } else {
      push(Buffer.from(`<< /Length ${obj.stream.length} >>\nstream\n`, 'latin1'));
      push(obj.stream);
      push(Buffer.from('\nendstream\nendobj\n', 'latin1'));
    }
  });

  const xrefOffset = offset;
  const xref = [
    'xref',
    `0 ${objects.length + 1}`,
    '0000000000 65535 f ',
    ...offsets.map((o) => `${String(o).padStart(10, '0')} 00000 n `),
    'trailer',
    `<< /Size ${objects.length + 1} /Root 1 0 R >>`,
    'startxref',
    String(xrefOffset),
    '%%EOF',
    '',
  ].join('\n');
  push(Buffer.from(xref, 'latin1'));

  return Buffer.concat(chunks);
}

// 1) 扫描件：单页、无文本层 —— extractText 必须识别为「无可提取文本」→ 422
const scanned = buildPdf(null);
writeFileSync(join(HERE, 'scanned-no-text.pdf'), scanned);

// 2) 文字型 PDF：单页、Helvetica 纯 ASCII 文本 —— 验证 pdfjs 抽取链路真的能出字
const textLines = [
  // 注意：手写 PDF 用 base-14 的 Helvetica，只有 WinAnsi 字形集，**没有中日韩字形**。
  // 所以这份 PDF 只能放 ASCII 题干；它的使命是证明「pdfjs 真能抽出带换行的文本」
  // 且抽出的文本能被 splitQuestions 切开，而不是承担中文切题准确率验收
  // （那份验收由 sample-01/02/03 三份中文样本负责）。
  // 题号用 `1.` / `(1)` 两种 ASCII 可表达的分隔符；中文的 `一、` 与 `第1题` 放不进 PDF。
  '1. What is the derivative of x^2?',
  'A. 2x',
  'B. x',
  '(1) What is the integral of 1/x?',
  'A. ln(x)',
  'B. x',
  '2. Which of these is a prime number?',
  'A. 9',
  'B. 7',
];
const textPdf = buildPdf(textLines);
writeFileSync(join(HERE, 'text-simple.pdf'), textPdf);

console.log(`scanned-no-text.pdf ${scanned.length} bytes`);
console.log(`text-simple.pdf    ${textPdf.length} bytes`);
