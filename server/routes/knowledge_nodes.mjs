// server/routes/knowledge_nodes.mjs
// 题路 TillRoad · BE-01 第 4 步：knowledge_nodes 路由（T3）
//
// 端点（7 个）：
//   POST   /knowledge-nodes                      建考点
//   GET    /knowledge-nodes/:id                  取单个考点
//   GET    /subjects/:id/knowledge-nodes         某科目下扁平列表（分页）
//   GET    /subjects/:id/knowledge-tree          某科目下嵌套考点树（AC-KM-03）
//   PUT/PATCH /knowledge-nodes/:id               更新（含移动/改名；base_version 必填）
//   DELETE /knowledge-nodes/:id                  软删（base_version 必填）
//
// 注意 AC-KM-03 只要求「自关联展开/折叠 + freq_tag / weight_to_target」，
//   并未要求服务端分页树；树规模 = 一个科目的所有考点（几十到几百），
//   一次取回在客户端展开是最稳的做法（避免逐层请求的瀑布）。

import * as rep from '../repositories/knowledge_nodes.mjs';
import { withTransaction } from '../repositories/base.mjs';
import {
  assertValid,
  ok,
  pagination,
  readBaseVersion,
} from './_http.mjs';
import {
  validateFreqTag,
  validateWeightToTarget,
} from '../../core/validators.mjs';

/** 挑出 knowledge_nodes 可写列并做值域校验。 */
function pickNodeFields(body, { partial = false } = {}) {
  const out = {};
  const has = (k) => Object.prototype.hasOwnProperty.call(body, k);

  if (!partial || has('title')) {
    if (has('title')) out.title = body.title;
  }
  if (has('parent_id')) out.parent_id = body.parent_id;
  if (has('freq_tag')) {
    assertValid(validateFreqTag(body.freq_tag));
    out.freq_tag = body.freq_tag;
  }
  if (has('weight_to_target')) {
    assertValid(validateWeightToTarget(body.weight_to_target));
    out.weight_to_target = body.weight_to_target;
  }
  return out;
}

export function match(method, seg, ctx) {
  const { pool, searchParams, body } = ctx;

  // POST /knowledge-nodes
  if (method === 'POST' && seg.length === 1 && seg[0] === 'knowledge-nodes') {
    return (async () => {
      if (!body.subject_id) {
        const err = new TypeError('subject_id 必填');
        err.code = 'missing_subject_id';
        err.statusCode = 400;
        err.body = { error: 'missing_subject_id', message: 'subject_id 必填' };
        throw err;
      }
      const fields = pickNodeFields(body);
      // create 内部要锁 subjects 父行 + 查重（同 subject + 同 parent 下 title 唯一），
      // 且要校验 parent 与节点同 subject —— 必须在事务里。
      const row = await withTransaction(pool, (client) => rep.create(client, {
        subject_id: body.subject_id,
        ...fields,
      }));
      return ok(row, 201);
    })();
  }

  // GET /subjects/:id/knowledge-nodes | /subjects/:id/knowledge-tree
  if (seg.length === 3 && seg[0] === 'subjects') {
    if (method === 'GET' && seg[2] === 'knowledge-nodes') {
      return (async () => {
        const page = pagination(searchParams);
        const rows = await rep.listBySubject(pool, seg[1], page);
        return ok({ items: rows, ...page });
      })();
    }
    if (method === 'GET' && seg[2] === 'knowledge-tree') {
      // 树一次性返回，不分页：AC-KM-03 的展开/折叠需要完整层级。
      return (async () => ok({ items: await rep.getTree(pool, seg[1]) }))();
    }
    return null;
  }

  if (seg[0] !== 'knowledge-nodes' || seg.length < 2) return null;

  const id = seg[1];

  // GET /knowledge-nodes/:id
  if (method === 'GET' && seg.length === 2) {
    return (async () => ok(await rep.getById(pool, id)))();
  }

  // PATCH（也接受 PUT：幂等语义下两者对客户端无差别，PUT 更容易被 REST 客户端默认发出）
  if ((method === 'PATCH' || method === 'PUT') && seg.length === 2) {
    return (async () => {
      const baseVersion = readBaseVersion(body);
      const patch = pickNodeFields(body, { partial: true });
      // update 内部要做「移动节点 -> 校验不跨科目 / 不成环 / 不挂自己」的判定，
      // 且这些判定依赖当前树状态，必须在事务里做，否则并发移动可能绕过防环检查。
      const row = await withTransaction(pool, (client) => rep.update(client, id, patch, baseVersion));
      return ok(row);
    })();
  }

  // DELETE /knowledge-nodes/:id
  if (method === 'DELETE' && seg.length === 2) {
    return (async () => {
      const baseVersion = readBaseVersion(body);
      const row = await withTransaction(pool, (client) => rep.archive(client, id, baseVersion));
      return ok(row);
    })();
  }

  return null;
}

export { pickNodeFields };
