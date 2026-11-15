// server/routes/capability_layers.mjs
// 题路 TillRoad · BE-01 第 4 步：capability_layers 路由（T3）
//
// 端点（5 个）：
//   POST   /capability-layers        建模板
//   GET    /capability-layers/:id    取单个
//   GET    /capability-layers        列表（分页）
//   PATCH  /capability-layers/:id    更新（base_version 必填；受 customizable gate 约束）
//   DELETE /capability-layers/:id    软删（base_version 必填；受 customizable gate 约束）
//
// 关于 gate（决策 6 / 第 3 步已实现、本轮确认保留）：
//   capability_layers.customizable = false 表示「官方/共享模板，不允许用户改」。
//   gate 的判定在仓储 update/archive 内部（validateCustomizableGate，**失败关闭**：
//   current.customizable !== true 即锁定）。路由层不重复实现该规则，只保证：
//     - 把整个请求走 withTransaction，让「先读 current、再判定、再写」在同一快照里，
//       否则「读到时 customizable=true，写入前被别人改成 false」的窗口拦不住。
//     - 不把 gate 失败翻译成别的东西：仓储抛的 ValidationError 带 statusCode=400
//       + code=CUSTOMIZABLE_LOCKED，_http.httpError 原样输出。
//
// 【刻意加严，非遗漏】archive 也受 gate 拦截 —— 见 REVIEW-NOTES.md 第 4 步条目。
//   共享模板被某个用户删掉会影响所有人（软删后 list 查不到，其他人的 subject
//   仍指向它）。所以「不是你的东西就不能删」这条比「不是你的东西不能改」更强。

import * as rep from '../repositories/capability_layers.mjs';
import { withTransaction } from '../repositories/base.mjs';
import {
  assertValid,
  ok,
  pagination,
  readBaseVersion,
} from './_http.mjs';
import { validateLayers } from '../../core/validators.mjs';

export function match(method, seg, ctx) {
  const { pool, searchParams, body } = ctx;

  // POST /capability-layers
  if (method === 'POST' && seg.length === 1 && seg[0] === 'capability-layers') {
    return (async () => {
      // create 模式：layers 必填（null/undefined -> LAYERS_REQUIRED）
      assertValid(validateLayers(body.layers, { mode: 'create' }));
      const row = await rep.create(pool, {
        name: body.name,
        layers: body.layers,
        // customizable 未显式给定时交给仓储默认值（true），不要在这里塞 false。
        ...(Object.prototype.hasOwnProperty.call(body, 'customizable')
          ? { customizable: body.customizable }
          : {}),
      });
      return ok(row, 201);
    })();
  }

  // GET /capability-layers（列表）
  if (method === 'GET' && seg.length === 1 && seg[0] === 'capability-layers') {
    return (async () => {
      const page = pagination(searchParams);
      const rows = await rep.list(pool, page);
      return ok({ items: rows, ...page });
    })();
  }

  if (seg[0] !== 'capability-layers' || seg.length < 2) return null;

  const id = seg[1];

  // GET /capability-layers/:id
  if (method === 'GET' && seg.length === 2) {
    return (async () => ok(await rep.getById(pool, id)))();
  }

  // PATCH /capability-layers/:id
  if (method === 'PATCH' && seg.length === 2) {
    return (async () => {
      const baseVersion = readBaseVersion(body);

      const patch = {};
      if (Object.prototype.hasOwnProperty.call(body, 'name')) patch.name = body.name;
      if (Object.prototype.hasOwnProperty.call(body, 'customizable')) {
        patch.customizable = body.customizable;
      }
      if (Object.prototype.hasOwnProperty.call(body, 'layers')) {
        // update 模式的 validateLayers：允许 patch 里不带 layers，带了就必须结构合法。
        assertValid(validateLayers(body.layers, { mode: 'update' }));
        patch.layers = body.layers;
      }

      // gate 在 rep.update 内部判定，须与「读 current」同一事务快照。
      const row = await withTransaction(pool, (client) => rep.update(client, id, patch, baseVersion));
      return ok(row);
    })();
  }

  // DELETE /capability-layers/:id
  if (method === 'DELETE' && seg.length === 2) {
    return (async () => {
      const baseVersion = readBaseVersion(body);
      const row = await withTransaction(pool, (client) => rep.archive(client, id, baseVersion));
      return ok(row);
    })();
  }

  return null;
}
