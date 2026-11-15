// server/routes/exam_profiles.mjs
// 题路 TillRoad · BE-01 第 4 步：exam_profiles 路由（T3）
//
// 端点（6 个）：
//   POST   /exam-profiles                       创建目标配置（AC-KM-01 事务：profile + 默认科目）
//   GET    /exam-profiles/:id                   取单个目标
//   GET    /users/:userId/exam-profiles         列某用户的目标
//   PATCH  /exam-profiles/:id                   更新（base_version 必填）
//   DELETE /exam-profiles/:id                   级联软删（profile + subjects + knowledge_nodes）
//   POST   /exam-profiles/:id/subjects          建科目（委托给 subjects 路由，见 handler 注释）
//
// 组织方式（交付说明第 1 项）：**每表一个 route 模块**，不用一个 routes.mjs 大文件。
//   理由：四组端点的 URL 前缀不同、依赖的仓储不同、事务边界不同；拆开后
//   「哪个端点碰哪张表」一眼可查，加新表时也不动别人的文件。公共的响应/错误/校验
//   工具集中在 _http.mjs，避免拆文件的代价变成复制粘贴。

import * as rep from '../repositories/exam_profiles.mjs';
import * as subjectRep from '../repositories/subjects.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { getTemplateSubjects } from '../../core/templates.mjs';
import {
  assertValid,
  fail,
  ok,
  pagination,
  readBaseVersion,
} from './_http.mjs';
import {
  validateDailyMinutes,
  validateExamDate,
  validateExamProfileRequired,
  validateExamType,
  validateProfileStatus,
  validateTargetScore,
  firstInvalid,
} from '../../core/validators.mjs';

/**
 * 把请求体里「exam_profiles 可写列」挑出来，并逐项走 core 校验。
 *
 * 为什么不是直接把整个 body 丢给仓储：
 *   仓储只做 DB 才能判定的事（FK / 乐观锁 / 软删 / 查重），值域校验必须在这里先做，
 *   否则非法值会以 PG 的 22P02 / 23514 形式冒出来，错误码对客户端不可读。
 *
 * partial=true（PATCH）：只校验**出现过的键**。未出现的键不传下去，
 *   否则 updateWithVersion 会用 undefined 覆盖（buildUpdateSet 会跳过 undefined，
 *   但显式的 null 是合法值，两者语义必须区分）。
 */
function pickProfileFields(body, { partial = false } = {}) {
  const out = {};
  const has = (k) => Object.prototype.hasOwnProperty.call(body, k);

  if (!partial || has('exam_type')) {
    if (has('exam_type')) {
      assertValid(validateExamType(body.exam_type));
      out.exam_type = body.exam_type;
    }
  }
  if (has('target_label')) out.target_label = body.target_label;
  if (has('target_score')) {
    assertValid(validateTargetScore(body.target_score));
    out.target_score = body.target_score;
  }
  if (has('subject_target')) out.subject_target = body.subject_target;
  if (has('exam_date')) {
    assertValid(validateExamDate(body.exam_date));
    out.exam_date = body.exam_date;
  }
  if (has('daily_minutes')) {
    assertValid(validateDailyMinutes(body.daily_minutes));
    out.daily_minutes = body.daily_minutes;
  }
  if (has('source_scope')) out.source_scope = body.source_scope;
  if (has('baseline')) out.baseline = body.baseline;
  if (has('status')) {
    assertValid(validateProfileStatus(body.status));
    out.status = body.status;
  }
  return out;
}

/**
 * POST /exam-profiles —— AC-KM-01：建目标 + 一键套用默认科目，同一事务。
 *
 * 事务边界（交付说明第 4 项）：
 *   withTransaction 包住「建 profile -> 取模板 -> 逐个建 subject」整段。
 *   任一 subject 建失败（如模板里两个科目名撞了、或被中途并发改名）则整笔回滚，
 *   不会留下「有目标但科目建了一半」的半成品 —— 用户重试即可，不必手工清理。
 *
 * 为什么不在这里调 subjectRep.create 之前先查模板是否为空：
 *   getTemplateSubjects 对未知 exam_type 返回 []（决策 9），此时只建 profile，
 *   事务仍然正常提交，不发生 subject 写入，也不报错。
 */
async function createProfile(pool, body) {
  const fields = pickProfileFields(body, { partial: false });

  // AC-EXAM-01：exam_type / (target_score 或 target_label) / exam_date / daily_minutes
  assertValid(validateExamProfileRequired({ ...body, ...fields }));

  if (!body.user_id) {
    return fail('missing_user_id', 400, { message: 'user_id 必填' });
  }

  const template = getTemplateSubjects(fields.exam_type);

  const created = await withTransaction(pool, async (client) => {
    const profile = await rep.create(client, { ...fields, user_id: body.user_id });

    const subjects = [];
    for (const tpl of template) {
      // 逐个 create 而不是批量 INSERT：create 内部要做「锁父行 + 查重 + 插入」，
      // 复用它才能保证「手动加科目」与「模板套用」走完全相同的唯一性规则。
      // 模板规模 2~6 条，串行开销可忽略；换来的是一致性。
      // eslint-disable-next-line no-await-in-loop
      const s = await subjectRep.create(client, {
        exam_profile_id: profile.id,
        name: tpl.name,
        kind: tpl.kind,
      });
      subjects.push(s);
    }

    return { profile, subjects };
  });

  return ok(created, 201);
}

/**
 * DELETE /exam-profiles/:id —— 级联软删（决策 11）。
 *
 * 为什么不能只 archive profile：
 *   subjects / knowledge_nodes 的 FK 是 ON DELETE CASCADE，那只在**物理删除**时触发；
 *   软删（SET deleted_at）不会级联。若只删 profile，子表行仍是 deleted_at IS NULL，
 *   listByProfile / getTree 依然能查到「属于一个已删除目标」的科目和考点树。
 *
 * 用**三条批量 UPDATE**在同一个事务里打 tombstone，不逐行循环：
 *   1) profile 本行（带 base_version，冲突则整笔回滚 -> 409）
 *   2) 该目标下所有未删的 subjects
 *   3) 这些 subjects 下所有未删的 knowledge_nodes
 *   第 2/3 步用 `WHERE ... IN (SELECT ...)` 一条语句覆盖全部子行，
 *   行数再多也是一次往返，且 profile 的乐观锁失败会让另两条根本没执行。
 *
 * 注意 2/3 两步**不带 version 条件**：它们不是用户直接编辑的对象，
 *   而是「随父级一起消失」的从属数据；要求客户端持有每个子行的版本号不现实
 *   （列表可能只加载了第一页）。这也是这里不用 archiveWithVersion 的原因。
 */
async function deleteProfile(client, id, baseVersion) {
  const archived = await rep.archive(client, id, baseVersion);

  const subjectsRes = await client.query(
    `UPDATE subjects SET deleted_at = now()
      WHERE exam_profile_id = $1 AND deleted_at IS NULL`,
    [id],
  );

  const nodesRes = await client.query(
    `UPDATE knowledge_nodes SET deleted_at = now()
      WHERE subject_id IN (SELECT id FROM subjects WHERE exam_profile_id = $1)
        AND deleted_at IS NULL`,
    [id],
  );

  return {
    ...archived,
    cascaded: {
      subjects: subjectsRes.rowCount ?? 0,
      knowledge_nodes: nodesRes.rowCount ?? 0,
    },
  };
}

/**
 * 每个 route 模块导出 shape 一致的 match 函数：
 *   match(method, seg, ctx) -> {status, body} | null
 * 返回 null 表示「这个模块不认这个请求」，由 index.mjs 继续问下一个模块。
 *
 * ctx：{ pool, searchParams, body }
 */
export function match(method, seg, ctx) {
  const { pool, searchParams, body } = ctx;

  // POST /exam-profiles
  if (method === 'POST' && seg.length === 1 && seg[0] === 'exam-profiles') {
    // 路由层是 async 的（要查 PG），match 直接返回 Promise。
    return createProfile(pool, body);
  }

  // GET /users/:userId/exam-profiles
  if (method === 'GET' && seg.length === 3 && seg[0] === 'users' && seg[2] === 'exam-profiles') {
    return (async () => {
      const rows = await rep.listByUser(pool, seg[1], pagination(searchParams));
      return ok({ items: rows, ...pagination(searchParams) });
    })();
  }

  if (seg[0] !== 'exam-profiles' || seg.length < 2) return null;

  const id = seg[1];

  // GET /exam-profiles/:id
  if (method === 'GET' && seg.length === 2) {
    return (async () => ok(await rep.getById(pool, id)))();
  }

  // PATCH /exam-profiles/:id（base_version 必填）
  if (method === 'PATCH' && seg.length === 2) {
    return (async () => {
      const baseVersion = readBaseVersion(body);
      const patch = pickProfileFields(body, { partial: true });

      // 必须包事务：exam_profiles.update 在 patch 含 target_label 时会
      // lockParentRow(users) 再查重。若不入事务，FOR UPDATE 的锁在语句
      // 自动提交后立刻释放，查重与写入落在两个快照里，两个并发改名会
      // 双双通过查重 -> 同一 user 下出现重复 target_label。
      const row = await withTransaction(pool, (client) => rep.update(client, id, patch, baseVersion));
      return ok(row);
    })();
  }

  // DELETE /exam-profiles/:id（级联软删事务）
  if (method === 'DELETE' && seg.length === 2) {
    return (async () => {
      const baseVersion = readBaseVersion(body);
      const result = await withTransaction(pool, (client) => deleteProfile(client, id, baseVersion));
      return ok(result);
    })();
  }

  // GET /exam-profiles/:id/subjects —— 列该目标下的科目
  if (method === 'GET' && seg.length === 3 && seg[2] === 'subjects') {
    return (async () => {
      const rows = await subjectRep.listByProfile(pool, id, pagination(searchParams));
      return ok({ items: rows, ...pagination(searchParams) });
    })();
  }

  return null;
}

// 供 server/index.mjs 在 DELETE 级联里复用（避免与 subjects 路由重复实现）。
export { deleteProfile, pickProfileFields };
