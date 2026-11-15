// server/routes/_http.mjs
// 题路 TillRoad · BE-01 第 4 步：路由层公共工具（HTTP 契约与错误映射的唯一出口）
//
// 设计要点（决策 12）：**HTTP 层不重新拼 409 body**。
//   仓储层抛出的错误已经带好 err.statusCode + err.body：
//     * 乐观锁冲突 conflictError  -> 409 { error:'conflict', current, incoming, resolution:'client_merge' }
//     * 查重冲突   duplicateError -> 409 { error:'conflict', field, current, incoming, resolution:'user_choice' }
//     * 未找到     notFoundError  -> 404 { error:'not_found', resource, id }
//     * 校验失败   validationError-> 400 { error: code, message, fields? }
//   所以这里只做「取出来照发」，保证两种 409 的形状差异只存在于构造处，不会在传输层被抹平。
//   客户端按 body.resolution 分支：'client_merge' 走合并流程，'user_choice' 走让用户选。
//
// 与 repositories/_common.mjs 的关系：
//   只复用它的 validationError（构造 400 的同一套形状），不复制粘贴一份。
//   方向是 routes -> repositories -> base，单向无环。

import { validationError } from '../repositories/_common.mjs';
import { validateBaseVersion } from '../../core/validators.mjs';

// ---------------------------------------------------------------------------
// 响应构造
// ---------------------------------------------------------------------------

/** 成功响应。handler 统一返回 {status, body}，由 server/index.mjs 落成 HTTP。 */
export function ok(body, status = 200) {
  return { status, body };
}

/** 简单错误响应（用于路由层自身能直接判定的 404/400，如未知路由）。 */
export function fail(error, status = 400, extra = {}) {
  return { status, body: { error, ...extra } };
}

/** handler 未命中该路径时的返回值（显式常量，避免用 undefined 表示两种含义）。 */
export const NOT_MATCHED = null;

// ---------------------------------------------------------------------------
// 校验结果 -> 可抛错误
// ---------------------------------------------------------------------------

/**
 * core/validators.mjs 的返回形状是 { ok:true } | { ok:false, code, message, fields? }。
 * 校验失败是**预期内分支**，但路由层统一用「抛带 statusCode 的 Error + 一处 catch」
 * 来避免每个 handler 都写 if (!r.ok) return ...（十几处重复且容易漏）。
 */
export function assertValid(result) {
  if (result && result.ok === false) throw validationError(result);
  return result;
}

// ---------------------------------------------------------------------------
// base_version（决策 8：强制必填）
// ---------------------------------------------------------------------------

/**
 * 取并校验乐观锁基版号。
 *
 * 传递方式拍板：**请求体 `version` 字段**（不是 If-Match header）。理由：
 *   1. 现有 16 个 server 测试、conflictBody、offline-sync-spec 的同步体、以及
 *      第 2 步已定的 SQL 骨架（`WHERE version = $base_version`）全部以 body 为准；
 *      改用 header 会让所有既有调用方同时改两处（URL 约定不变但取值位置变了）。
 *   2. 409 冲突时服务端要回当前行 + incoming，incoming 用 body 里的原值最直白；
 *      header 方案还得额外解析 `If-Match: "3"` 的引号与可能的 `W/` 弱校验前缀。
 *   3. 二选一就只认一种：同时支持 body 与 header 会产生「两处不一致时听谁的」
 *      的歧义，这比少一种写法危险得多。故 **If-Match 刻意不支持**，
 *      带了也仍然要求 body.version，否则 400 INVALID_BASE_VERSION。
 *
 * 缺失 / 非正整数 -> 400 { error:'INVALID_BASE_VERSION', message }
 * （复用 core/validators.mjs 的 V12，与第 1 步的失败码集合保持一致）
 */
export function readBaseVersion(body) {
  const raw = body == null ? undefined : body.version;
  const r = validateBaseVersion(raw);
  if (!r.ok) throw validationError(r);
  return Number(raw);
}

// ---------------------------------------------------------------------------
// 错误 -> HTTP 响应（唯一出口）
// ---------------------------------------------------------------------------

/**
 * 带 statusCode 的 Error -> {status, body}。
 *   1. 有 statusCode + body（仓储层构造的 404/409/400）-> 原样采用，**不重新拼**；
 *   2. 有 code 的普通 Error（core/index.mjs 的 assertXxx、路由层自造码）-> 400 {error:code}；
 *   3. 其它（含 PG 连接失败、编程错误）-> 500 {error:'internal'}，不泄漏内部信息。
 */
export function httpError(e) {
  if (e && typeof e.statusCode === 'number' && e.body && typeof e.body === 'object') {
    return { status: e.statusCode, body: e.body };
  }
  if (e && typeof e.code === 'string' && e.code) {
    return { status: 400, body: { error: e.code } };
  }
  return { status: 500, body: { error: 'internal' } };
}

// ---------------------------------------------------------------------------
// 底层 HTTP 工具（原来是 server/index.mjs 里的私有函数，搬到路由层共用）
// ---------------------------------------------------------------------------

export function json(res, status, obj) {
  const data = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(data),
  });
  res.end(data);
}

export function sendError(res, e) {
  const out = httpError(e);
  json(res, out.status, out.body);
}

export function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try {
        const parsed = JSON.parse(raw);
        // 顶层必须是对象：'null' / '3' / '[]' 合法 JSON 但不是合法请求体，
        // 放行会让 body.version 之类的属性访问路径变得不可预期。
        if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
          return reject(Object.assign(new Error('body must be a JSON object'), { code: 'INVALID_BODY' }));
        }
        resolve(parsed);
      } catch {
        reject(Object.assign(new Error('invalid json'), { code: 'INVALID_JSON' }));
      }
    });
    req.on('error', reject);
  });
}

/**
 * 分页参数：从 query string 取 limit/offset。
 * 具体归一（1..200、默认 50）由 repositories/_common.mjs 的 pageParams 负责，
 * 这里只做字符串->数字的初步转换，非法值交给 pageParams 回落。
 */
export function pagination(searchParams) {
  const out = {};
  const limit = searchParams.get('limit');
  const offset = searchParams.get('offset');
  if (limit !== null) out.limit = Number(limit);
  if (offset !== null) out.offset = Number(offset);
  return out;
}
