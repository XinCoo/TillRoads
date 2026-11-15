// server/routes/subjects.mjs
// 题路 TillRoad · BE-01 第 4 步：subjects 路由（T3）+ AC-KM-02 自定义层级副本（T5）
//
// 端点（6 个）：
//   POST   /subjects                   建科目
//   GET    /subjects/:id               取单个科目
//   GET    /exam-profiles/:id/subjects 列该目标下科目（在 exam_profiles 路由里，URL 前缀归它）
//   PATCH  /subjects/:id               更新（base_version 必填）
//   DELETE /subjects/:id               软删（base_version 必填）
//   POST   /subjects/:id/customize-layers  AC-KM-02：复制层级模板并把科目重指向副本（事务）

import * as rep from '../repositories/subjects.mjs';
import * as layerRep from '../repositories/capability_layers.mjs';
import { withTransaction } from '../repositories/base.mjs';
import {
  assertValid,
  ok,
  pagination,
  readBaseVersion,
} from './_http.mjs';
import {
  validateLayers,
  validateSubjectKind,
} from '../../core/validators.mjs';

/** 挑出 subjects 可写列并做值域校验（partial=true 时只处理出现过的键）。 */
function pickSubjectFields(body, { partial = false } = {}) {
  const out = {};
  const has = (k) => Object.prototype.hasOwnProperty.call(body, k);

  if (!partial || has('name')) {
    if (has('name')) out.name = body.name;
  }
  if (has('kind')) {
    assertValid(validateSubjectKind(body.kind));
    out.kind = body.kind;
  }
  if (has('layer_template_id')) out.layer_template_id = body.layer_template_id;
  return out;
}

/**
 * POST /subjects/:id/customize-layers —— AC-KM-02 自定义能力层级副本（决策 10）。
 *
 * 为什么必须「复制副本 + 重指向」而不是就地改共享模板：
 *   capability_layers 没有 user_id / exam_profile_id（schema.sql:213-224），是全局共享表。
 *   就地改会污染所有其他用户的科目。所以：
 *     1) 用用户给的 {name, layers} 建一张**新的** capability_layers（customizable=true）；
 *     2) 把该科目的 layer_template_id 重指向新模板（带 base_version 的乐观锁）。
 *
 * 事务边界：两步同事务。若第 2 步因 409 失败，第 1 步建的模板必须回滚，
 *   否则数据库里会积累一批「没人指向的孤儿模板」。
 *
 * 决策 10 明确：**不因为当前模板 customizable=true 就拦截**。
 *   用户常常「基于官方模板改几层」，此时官方模板是可自定义的，但用户要的是
 *   自己的一份、与官方后续变更解耦。加拦截会把最常见的用法挡在门外。
 *
 * base_version 必填：因为第 2 步要改 subject 行，走同一套乐观锁规则。
 */
async function customizeLayers(client, subjectId, body) {
  const baseVersion = readBaseVersion(body);

  // layers 结构校验用 mode:'create' —— 这里确实是新建一条 capability_layers。
  assertValid(validateLayers(body.layers, { mode: 'create' }));

  const name = body.name;

  // 第 1 步：建副本模板（customizable=true，因为它是用户私有的，应可继续改）
  const layer = await layerRep.create(client, {
    name,
    layers: body.layers,
    customizable: true,
  });

  // 第 2 步：科目重指向。若 subject 已被并发改过 -> 409 conflictError 抛出 -> 整笔回滚。
  const subject = await rep.update(
    client,
    subjectId,
    { layer_template_id: layer.id },
    baseVersion,
  );

  return { subject, capability_layer: layer };
}

export function match(method, seg, ctx) {
  const { pool, searchParams, body } = ctx;

  // POST /subjects
  if (method === 'POST' && seg.length === 1 && seg[0] === 'subjects') {
    return (async () => {
      const fields = pickSubjectFields(body);
      if (!body.exam_profile_id) {
        const err = new TypeError('exam_profile_id 必填');
        err.code = 'missing_exam_profile_id';
        err.statusCode = 400;
        err.body = { error: 'missing_exam_profile_id', message: 'exam_profile_id 必填' };
        throw err;
      }
      // create 内部要锁父行 + 查重，必须在一个事务里（否则锁在自动提交后立即释放）。
      const row = await withTransaction(pool, (client) => rep.create(client, {
        exam_profile_id: body.exam_profile_id,
        ...fields,
      }));
      return ok(row, 201);
    })();
  }

  if (seg[0] !== 'subjects' || seg.length < 2) return null;

  const id = seg[1];

  // POST /subjects/:id/customize-layers
  if (method === 'POST' && seg.length === 3 && seg[2] === 'customize-layers') {
    return (async () => {
      const result = await withTransaction(pool, (client) => customizeLayers(client, id, body));
      return ok(result, 201);
    })();
  }

  // GET /subjects/:id
  if (method === 'GET' && seg.length === 2) {
    return (async () => ok(await rep.getById(pool, id)))();
  }

  // PATCH /subjects/:id（base_version 必填）
  if (method === 'PATCH' && seg.length === 2) {
    return (async () => {
      const baseVersion = readBaseVersion(body);
      const patch = pickSubjectFields(body, { partial: true });
      const row = await withTransaction(pool, (client) => rep.update(client, id, patch, baseVersion));
      return ok(row);
    })();
  }

  // DELETE /subjects/:id（base_version 必填）
  if (method === 'DELETE' && seg.length === 2) {
    return (async () => {
      const baseVersion = readBaseVersion(body);
      const row = await withTransaction(pool, (client) => rep.archive(client, id, baseVersion));
      return ok(row);
    })();
  }

  // GET /subjects/:id/knowledge-nodes（扁平列表）与 /knowledge-tree（嵌套树）
  //   放在 knowledge_nodes 路由里处理，这里不拦。

  return null;
}

export { pickSubjectFields, customizeLayers };
