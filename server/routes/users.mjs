// server/routes/users.mjs
// 题路 TillRoad · 当前用户信息端点（GET /me / PATCH /me）
//
// 端点（2 个）：
//   GET   /me   取当前 Bearer Token 对应用户的基础信息
//   PATCH /me   修改当前用户的昵称（m28943，多端同步靠 users.nickname 这个唯一真源）
//
// ★ 为什么是 `GET /me` 而不是 `GET /users/me`：
//   server/index.mjs 在鉴权后会**无条件**把任何 `/users/<任意段>` 路径的第 2 段
//   替换成 authUserId（pathParts[1] = authUserId）。
//   于是 `/users/me` 会被改写成 `/users/<uuid>` —— 「me」这个字面量根本活不到路由层。
//   所以「当前用户」必须走 `/me`（单段路径，不触发那段改写）。
//
// ★ 为什么直接用 ctx.pool.query 而不建仓储层：
//   users 表在 server/repositories/ 下**没有**对应模块（只有 exam_profiles/subjects/
//   knowledge_nodes/capability_layers 四张表有仓储）。为一个「只读两列」的端点新建
//   一个仓储模块不划算，也违反本仓库「每表一个 route 模块」的既有粒度约定。
//   这里直接写一条 SELECT，语义最直白。
//
// ★ 安全边界：
//   * 响应里**只有** id / nickname / display_name / masked_id；
//   * 绝不下发 token、密码哈希、邮箱等任何凭据；
//   * id 是**故意**完整返回的（前端要拿它复制、拼链接），masked_id 只是给「展示/日志」用的
//     打码副本，不是安全边界本身。
import { validateNickname } from '../../core/validators.mjs';
import { fail, ok } from './_http.mjs';

/**
 * 把 uuid 打成展示用的掩码串。
 * 与前端 tillroad_app/lib/logging/app_logger.dart 的 maskUuid 同口径：
 *   去掉连字符后取**前** 4 位 + '****'。
 * @param {string} id
 * @returns {string}
 */
export function maskUuid(id) {
  const compact = String(id ?? '').replace(/-/g, '');
  if (compact.length < 4) return '****';
  return `${compact.slice(0, 4)}****`;
}

/**
 * 显示名：昵称优先；没有昵称时用「用户_ + id 去连字符后的末 4 位」兜底。
 * @param {string|null|undefined} nickname
 * @param {string} id
 * @returns {string}
 */
export function displayName(nickname, id) {
  if (nickname !== null && nickname !== undefined && String(nickname).trim() !== '') {
    return nickname;
  }
  const compact = String(id ?? '').replace(/-/g, '');
  const tail = compact.length >= 4 ? compact.slice(-4) : compact;
  return `用户_${tail}`;
}

/**
 * GET /me —— 当前用户基础信息。
 *
 * @param {string} method
 * @param {string[]} seg
 * @param {object} ctx { pool, authUserId, ... }
 * @returns {{status:number, body:any}|null}
 */
async function readMe(pool, authUserId) {
  const result = await pool.query(
    'SELECT id, nickname FROM users WHERE id = $1 AND deleted_at IS NULL',
    [authUserId],
  );
  return result.rows[0];
}

/**
 * PATCH /me —— 修改当前用户的昵称（m28943）。
 *
 * 请求体：{ "nickname": "新名字" }
 *   · 只接受 nickname 一个字段；未传 → 400 MISSING_NICKNAME；
 *   · 合法字符集与长度由 core/validators.mjs 的 validateNickname 统一管：
 *     中文 / 英文 / 数字组合，2–20 字符，不允许空格与符号。
 *
 * 为什么昵称不需要 base_version：
 *   昵称是**单值覆盖语义**（"我叫什么"），不存在「基于旧值改一部分」的字段级冲突；
 *   两个端同时改名时后到的覆盖先到的正是用户预期。这也和 R4a 的「冲突只对
 *   状态机字段做」口径一致。version 仍会由 users 表的 set_updated 触发器自增，
 *   便于排查与将来做「基于 version 的改名历史」时能对上号。
 *
 * 多端同步：昵称存在 users 表里，GET /me 每次都从库里读，所以任何一端保存后，
 *   其他端下次拉 /me 就是新名字（前端在切换回前台 / 下拉刷新时重拉）。
 */
async function updateMe(pool, authUserId, body) {
  const hasNickname = body !== null && typeof body === 'object'
    && Object.prototype.hasOwnProperty.call(body, 'nickname');
  if (!hasNickname) {
    return fail('MISSING_NICKNAME', 400, { message: 'nickname 必填' });
  }

  const check = validateNickname(body.nickname);
  if (!check.ok) {
    return fail(check.code, 400, { message: check.message });
  }

  const nickname = String(body.nickname).trim();
  const result = await pool.query(
    `UPDATE users SET nickname = $2
      WHERE id = $1 AND deleted_at IS NULL
      RETURNING id, nickname`,
    [authUserId, nickname],
  );
  const user = result.rows[0];
  if (!user) {
    return fail('not_found', 404, { message: '用户不存在' });
  }
  return ok({
    id: user.id,
    nickname: user.nickname ?? null,
    display_name: displayName(user.nickname, user.id),
    masked_id: maskUuid(user.id),
  });
}

/**
 * 当前用户信息路由：GET /me 读、PATCH /me 改名。
 *
 * @param {string} method
 * @param {string[]} seg
 * @param {object} ctx { pool, authUserId, body, ... }
 * @returns {{status:number, body:any}|null}
 */
export function match(method, seg, ctx) {
  // 只认单段路径 'me'。/users/me 不会走到这里（见文件头注释）。
  if (seg.length !== 1 || seg[0] !== 'me') return null;
  if (method !== 'GET' && method !== 'PATCH') return null;

  const { pool, authUserId, body } = ctx;

  // 没带/带错 token：401。注意 server/index.mjs 在 TOKENS 未配置时**不**鉴权，
  // 此时 authUserId 为 undefined —— 同样按 401 处理（没有身份就没有「我」）。
  if (!authUserId) {
    return fail('unauthorized', 401, { message: '需要有效的 Bearer Token' });
  }

  return (async () => {
    if (method === 'GET') {
      const user = await readMe(pool, authUserId);
      if (!user) {
        return fail('not_found', 404, { message: '用户不存在' });
      }
      return ok({
        id: user.id,
        nickname: user.nickname ?? null,
        display_name: displayName(user.nickname, user.id),
        masked_id: maskUuid(user.id),
      });
    }
    return updateMe(pool, authUserId, body);
  })();
}
