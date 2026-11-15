// server/import/separate.mjs
// 题路 TillRoad · BE-02：管线第四阶段 separateAssets（题干图片资产分离）
//
// MVP 的范围（用户拍板：题干图片实际分离放 V1）：
//   - 只**识别**题干里的图片占位，不下载、不落存储、不写 assets 行。
//   - 返回值里的 asset_refs 恒为空数组 —— 入库后 questions.asset_refs 仍是 null。
//   - 识别结果放进 placeholders 供调用方记录/日志，V1 接对象存储时直接用这份清单。
//
// 为什么仍然要这个函数而不是在端点里留一行注释：
//   1. T3 把管线固定为四阶段，第四阶段缺失会让后续 V1 接入时找不到落点；
//   2. 「识别出几张图」是导入结果里对用户最有用的信息之一（用户会立刻发现
//      「我的题图丢了」），即便这轮不落地也应该能报出来；
//   3. 纯函数、零依赖，与 splitter.mjs 同级可单测，不引入任何新的运行时依赖。
//
// 支持的占位形态（只这三种，够覆盖 Markdown/剪贴板粘贴的常见产出）：
//   ![alt](asset:xxx)          —— 本项目约定的本地资产引用
//   ![alt](data:image/png;...) —— 剪贴板粘贴的内联图
//   ![alt](http(s)://...)      —— 外部图片链接
// 统一用一条正则覆盖：![...](...) 或 <img src="...">。

/**
 * 图片占位正则。
 * 说明：不追求完整 Markdown 解析（没有嵌套括号、转义序列等），
 * 因为 MVP 只是计数 + 留痕；真正的解析放到 V1 与 OCR 一起做。
 */
const IMAGE_RE = /!\[[^\]]*\]\(([^)\s]+)[^)]*\)|<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>/gi;

/**
 * 从一段文本里抽出图片引用。
 *
 * @param {string} text
 * @returns {{url: string, kind: 'asset'|'data'|'remote'|'other'}[]}
 */
export function findImagePlaceholders(text) {
  if (typeof text !== 'string' || text === '') return [];

  const out = [];
  // 每次调用都要重置 lastIndex —— 正则带 g 标志时 lastIndex 会在调用间残留
  IMAGE_RE.lastIndex = 0;
  let m;
  while ((m = IMAGE_RE.exec(text)) !== null) {
    const url = m[1] ?? m[2] ?? '';
    if (!url) continue;
    let kind = 'other';
    if (url.startsWith('asset:')) kind = 'asset';
    else if (url.startsWith('data:')) kind = 'data';
    else if (/^https?:\/\//i.test(url)) kind = 'remote';
    out.push({ url, kind });
  }
  return out;
}

/**
 * 第四阶段：资产分离。
 *
 * 本轮固定返回空 asset_refs（不写 assets 表、不产生 storage_key），
 * 但把识别到的占位一并返回，便于端点计入 stats 让用户知道「有图未处理」。
 *
 * @param {{ stem?: string, options?: unknown, analysis?: string }} question 切题结果
 * @param {string} [rawText] 该题对应的原始文本片段（本轮未使用，留给 V1 定位图片在原文里的位置）
 * @returns {{ asset_refs: never[], placeholders: {url: string, kind: string}[] }}
 */
export function separateAssets(question = {}, rawText = '') {
  // options 是 [{key,text}] 数组，题干与选项都可能有图，一起扫
  const optionText = Array.isArray(question.options)
    ? question.options.map((o) => (o && typeof o.text === 'string' ? o.text : '')).join('\n')
    : '';

  const haystack = [question.stem ?? '', optionText, question.analysis ?? '', rawText ?? ''].join('\n');

  return {
    // MVP 恒为空：真正的资产落库（写 assets 行 + 上传对象存储）在 V1
    asset_refs: [],
    placeholders: findImagePlaceholders(haystack),
  };
}
