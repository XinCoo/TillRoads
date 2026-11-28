// server/_fake_repos.mjs
// 题路 TillRoad · BE-03 T6：缺陷单仓储的内存 fake（仅测试用，不入库、不 import pg）
//
// 忠实复刻 server/repositories/{defect_tickets,actions,verifications}.mjs 的语义：
//   · 所有状态迁移先经 core/index.mjs 纯函数前置校验（应用层防线）
//   · 派生列 verification_round / reopen_count / closed_at / version 由 fake 内部维护，
//     模拟 schema.sql 触发器的行为（真库由 DB 触发器维护）
//   · 乐观锁：baseVersion 不符 → 409 client_merge（含当前行）
// 这样 fake 层测试能在无 PG 的本机验证「路由分发 / 参数解析 / base_version 400 /
// actor=ai 403 / 409 映射 / 状态机流转」，而不必连真库。
//
// 注入方式：createApp({ repos: createFakeRepos() })。

import * as C from '../core/index.mjs';
import { computeUrgency, isVerifyStage, windowDaysFor } from './verify_window.mjs';
import { reportGenerator } from './mock_report.mjs';

function appError(code, message, extra = {}) {
  return Object.assign(new Error(message || code), { code, ...extra });
}

function conflict(current, incoming) {
  const e = new Error('version conflict');
  e.code = 'conflict';
  e.statusCode = 409;
  e.body = { error: 'conflict', current: current.version, incoming, resolution: 'client_merge' };
  return e;
}

function notFound(resource, id) {
  const e = new Error(`${resource} not found`);
  e.code = 'not_found';
  e.statusCode = 404;
  e.body = { error: 'not_found', resource, id };
  return e;
}
/**
 * fake 侧的 status 过滤归一（与真仓储 parseStatusFilter 同语义）：
 * 'V1,V2,V3' / ['V1'] / 'V1' → 去空白去空项数组；null → [] 表示不过滤。
 */
function parseFakeStatusFilter(status) {
  if (status == null) return [];
  const raw = Array.isArray(status) ? status : String(status).split(',');
  return raw.map((s) => String(s).trim()).filter((s) => s !== '');
}

/**
 * 建一组互相共享状态的 fake 仓储。
 * @returns {{client:null, defectTickets, actions, verifications}}
 */
export function createFakeRepos() {
  const tickets = new Map();
  const actionRows = new Map();
  const verRows = new Map();
  let seq = 1;
  const newId = (p) => `${p}-${seq++}`;

  function need(id) {
    const t = tickets.get(id);
    if (!t || t.deleted_at) throw notFound('defect_tickets', id);
    return t;
  }
  function versionGuard(t, baseVersion) {
    if (Number(baseVersion) !== Number(t.version)) throw conflict(t, baseVersion);
  }
  function publicCode(e) {
    const map = {
      FORBIDDEN_PHRASE_IN_ERROR_CAUSE: 'forbidden_phrase',
      MISSING_ERROR_LAYER: 'missing_error_layer_or_cause',
      MISSING_ERROR_CAUSE: 'missing_error_layer_or_cause',
      MISSING_ERROR_LAYER_OR_CAUSE: 'missing_error_layer_or_cause',
    };
    if (e && map[e.code]) {
      const out = appError(map[e.code], e.message);
      out.statusCode = 400;
      out.body = { error: out.code };
      return out;
    }
    return e;
  }

  const actions = {
    async create(_client, input = {}) {
      if (!input.defect_ticket_id) throw new TypeError('actions.create: defect_ticket_id 必填');
      if (!input.content || String(input.content).trim() === '') {
        throw new TypeError('actions.create: content 必填');
      }
      const row = {
        id: newId('act'),
        defect_ticket_id: input.defect_ticket_id,
        content: input.content,
        done: input.done == null ? false : !!input.done,
        due: input.due ?? null,
        version: 1,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        deleted_at: null,
      };
      actionRows.set(row.id, row);
      return { ...row };
    },
    async listByDefect(_client, defectTicketId, _opts = {}) {
      return [...actionRows.values()]
        .filter((a) => a.defect_ticket_id === defectTicketId && !a.deleted_at)
        .map((a) => ({ ...a }));
    },
    async markDone(_client, id, done, baseVersion) {
      const a = actionRows.get(id);
      if (!a || a.deleted_at) throw notFound('actions', id);
      versionGuard(a, baseVersion);
      a.done = done === undefined ? true : !!done;
      a.version += 1;
      a.updated_at = new Date().toISOString();
      return { ...a };
    },
    async assertAllDone(_client, defectTicketId) {
      const rows = await actions.listByDefect(null, defectTicketId);
      if (rows.length === 0) return { ok: false, reason: 'NO_ACTIONS', actions: rows };
      const pending = rows.filter((r) => !r.done);
      if (pending.length > 0) {
        return { ok: false, reason: 'ACTIONS_NOT_DONE', actions: rows, pendingCount: pending.length };
      }
      return { ok: true, actions: rows };
    },
  };

  const verifications = {
    async create(_client, input = {}) {
      const row = {
        id: newId('ver'),
        defect_ticket_id: input.defect_ticket_id,
        stage: input.stage,
        round: input.round ?? 1,
        verify_type: input.verify_type ?? 'redo_hidden',
        question_id: input.question_id ?? null,
        result: input.result ?? 'pending',
        evidence: input.evidence ?? null,
        verified_at: input.verified_at ?? null,
        version: 1,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        deleted_at: null,
      };
      verRows.set(row.id, row);
      return { ...row };
    },
    async listByDefect(_client, defectTicketId, _opts = {}) {
      return [...verRows.values()]
        .filter((v) => v.defect_ticket_id === defectTicketId && !v.deleted_at)
        .sort((a, b) => a.round - b.round || a.stage.localeCompare(b.stage))
        .map((v) => ({ ...v }));
    },
    async findByStageRound(_client, defectTicketId, stage, round) {
      const row = [...verRows.values()].find(
        (v) => v.defect_ticket_id === defectTicketId && v.stage === stage &&
          Number(v.round) === Number(round) && !v.deleted_at,
      );
      return row ? { ...row } : null;
    },
  };

  const defectTickets = {
    async create(_client, input = {}) {
      if (!input.user_id) throw new TypeError('defect_tickets.create: user_id 必填');
      if (!input.exam_profile_id) throw new TypeError('defect_tickets.create: exam_profile_id 必填');
      const status = input.status === 'ANALYZED' ? 'ANALYZED' : 'DRAFT';
      if (status === 'ANALYZED') {
        try {
          C.assertAnalyzable({ status: 'DRAFT', error_layer: input.error_layer, error_cause: input.error_cause });
        } catch (e) {
          throw publicCode(e);
        }
      }
      const row = {
        id: newId('dt'),
        user_id: input.user_id,
        exam_profile_id: input.exam_profile_id,
        knowledge_node_id: input.knowledge_node_id ?? null,
        question_id: input.question_id ?? null,
        q_type: input.q_type ?? null,
        error_layer: input.error_layer ?? null,
        error_cause: input.error_cause ?? null,
        actions: input.actions ?? [],
        priority: input.priority ?? C.computePriority(input),
        verification_state: null,
        reopen_reason: input.reopen_reason ?? null,
        status,
        verification_round: 1,
        reopen_count: 0,
        closed_at: null,
        version: 1,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        deleted_at: null,
      };
      tickets.set(row.id, row);
      // ★ FE-04 A2：与真仓储保持一致——建单时 actions 也落成 actions 表的行，
      // 否则 fake 层的 begin-verification 门禁永远 NO_ACTIONS，测不出真行为。
      const createdActions = [];
      if (Array.isArray(input.actions)) {
        for (const item of input.actions) {
          const content = typeof item === 'string' ? item : item?.content;
          const trimmed = content == null ? '' : String(content).trim();
          if (trimmed === '') continue;
          const due = typeof item === 'object' && item !== null ? (item.due ?? null) : null;
          createdActions.push(await actions.create(null, { defect_ticket_id: row.id, content: trimmed, due }));
        }
      }
      return { ...row, actions: createdActions };
    },
    async getById(_client, id) {
      return { ...need(id) };
    },
    async findById(_client, id, opts = {}) {
      const t = tickets.get(id);
      if (!t || (t.deleted_at && !opts.includeDeleted)) return null;
      return { ...t };
    },
    // FE-03 联调 A2：status 改多值（对齐真仓储的 'V1,V2,V3' / ['V1'] 三形态）。
    // 真仓储走 SQL LEFT JOIN 补考点名/科目名；fake 没有 knowledge_nodes 表，
    // 只把三个展示字段补成 null，保证响应形状一致（前端不用分支）。
    async listByUser(_client, userId, opts = {}) {
      let rows = [...tickets.values()].filter((t) => t.user_id === userId && !t.deleted_at);
      const wanted = parseFakeStatusFilter(opts.status);
      if (wanted.length > 0) rows = rows.filter((t) => wanted.includes(t.status));
      return rows.map((t) => ({
        ...t,
        knowledge_node_title: t.knowledge_node_title ?? null,
        knowledge_node_freq_tag: t.knowledge_node_freq_tag ?? null,
        subject_name: t.subject_name ?? null,
      }));
    },
    async listAll(_client, _opts = {}) {
      return [...tickets.values()].filter((t) => !t.deleted_at).map((t) => ({ ...t }));
    },
    // FE-07：首页缺陷分布聚合。与真仓储同口径（排除软删 / by_layer 只算未关闭 /
    // 空白 error_layer 归 unclassified / 八态全预填 0），否则 fake 层测不出真行为。
    async defectStats(_client, userId) {
      const mine = [...tickets.values()].filter(
        (t) => t.user_id === userId && !t.deleted_at,
      );
      const byStatus = {};
      for (const s of ['DRAFT', 'ANALYZED', 'ACTION_DONE', 'V1', 'V2', 'V3', 'REOPENED', 'CLOSED']) {
        byStatus[s] = 0;
      }
      for (const t of mine) {
        if (Object.prototype.hasOwnProperty.call(byStatus, t.status)) byStatus[t.status] += 1;
      }

      const layerCounts = new Map();
      for (const t of mine) {
        if (t.status === 'CLOSED') continue;
        const raw = typeof t.error_layer === 'string' ? t.error_layer.trim() : '';
        const key = raw === '' ? 'unclassified' : raw;
        layerCounts.set(key, (layerCounts.get(key) || 0) + 1);
      }
      const byLayer = [...layerCounts.entries()]
        .map(([error_layer, count]) => ({ error_layer, count }))
        .sort((a, b) => (b.count - a.count) || a.error_layer.localeCompare(b.error_layer));

      let openTotal = 0;
      for (const [k, v] of Object.entries(byStatus)) {
        if (k !== 'CLOSED') openTotal += v;
      }
      return {
        user_id: userId,
        by_layer: byLayer,
        by_status: byStatus,
        open_total: openTotal,
        closed_total: byStatus.CLOSED,
        total: openTotal + byStatus.CLOSED,
      };
    },
    recomputePriority(body = {}) {
      return C.computePriority({
        frequency: Number(body.frequency) || 0,
        loss: Number(body.loss) || 0,
        closability: Number(body.closability) || 0,
        targetContribution: Number(body.targetContribution) || 0,
      });
    },
    async update(_client, id, patch = {}, baseVersion) {
      const t = need(id);
      for (const k of ['status', 'verification_round', 'reopen_count', 'closed_at']) {
        if (Object.prototype.hasOwnProperty.call(patch, k)) {
          throw new TypeError(`defect_tickets.update: 字段 ${k} 只能通过状态机方法修改`);
        }
      }
      versionGuard(t, baseVersion);
      Object.assign(t, patch);
      t.version += 1;
      t.updated_at = new Date().toISOString();
      return { ...t };
    },
    async analyze(_client, id, { error_layer, error_cause }, baseVersion) {
      const t = need(id);
      try {
        C.assertAnalyzable({ status: t.status, error_layer, error_cause });
      } catch (e) {
        throw publicCode(e);
      }
      versionGuard(t, baseVersion);
      // 模拟 DB 触发器：REOPENED→ANALYZED 时 verification_round+1
      if (t.status === 'REOPENED') t.verification_round += 1;
      t.status = 'ANALYZED';
      t.error_layer = error_layer;
      t.error_cause = error_cause;
      t.version += 1;
      t.updated_at = new Date().toISOString();
      return { ...t };
    },
    async reanalyze(_client, id, attrs, baseVersion) {
      const t = need(id);
      try {
        C.reanalyze(t);
      } catch (e) {
        throw publicCode(e);
      }
      return defectTickets.analyze(null, id, attrs, baseVersion);
    },
    async beginVerification(_client, id, baseVersion) {
      const t = need(id);
      try {
        C.assertTransition(t.status, 'ACTION_DONE');
      } catch (e) {
        throw publicCode(e);
      }
      const gate = await actions.assertAllDone(null, id);
      if (!gate.ok) {
        const err = new Error(
          gate.reason === 'NO_ACTIONS' ? '至少添加一条处理动作后才能进入验证' : '还有处理动作未完成',
        );
        err.code = gate.reason;
        err.statusCode = 400;
        err.body = { error: err.code, message: err.message, pendingCount: gate.pendingCount ?? 0 };
        throw err;
      }
      versionGuard(t, baseVersion);
      // 两跳：ANALYZED→ACTION_DONE→V1，逐步维护 version
      t.status = 'ACTION_DONE';
      t.version += 1;
      try {
        C.beginVerification({ status: 'ACTION_DONE' }, 'V1');
      } catch (e) {
        throw publicCode(e);
      }
      t.status = 'V1';
      t.version += 1;
      t.updated_at = new Date().toISOString();
      return { ...t };
    },
    async submitVerification(_client, id, attrs, baseVersion) {
      const t = need(id);
      let applied;
      try {
        applied = C.applyVerification(t, attrs.stage, attrs.result);
      } catch (e) {
        throw publicCode(e);
      }
      const round = Number(t.verification_round) || 1;
      const dup = await verifications.findByStageRound(null, id, attrs.stage, round);
      if (dup) {
        const err = new Error('duplicate verification in this round');
        err.code = 'conflict';
        err.statusCode = 409;
        err.body = {
          error: 'conflict', field: 'stage', current: dup,
          incoming: { stage: attrs.stage, round }, resolution: 'user_choice',
        };
        throw err;
      }
      versionGuard(t, baseVersion);
      t.status = applied.status;
      if (t.status === 'REOPENED') t.reopen_count += 1;
      if (t.status === 'CLOSED') t.closed_at = new Date().toISOString();
      t.version += 1;
      t.updated_at = new Date().toISOString();
      const verification = await verifications.create(null, {
        defect_ticket_id: id,
        stage: attrs.stage,
        round,
        verify_type: attrs.verify_type ?? 'redo_hidden',
        question_id: attrs.question_id ?? null,
        result: attrs.result,
        evidence: attrs.evidence ?? null,
        verified_at: new Date().toISOString(),
      });
      return { ticket: { ...t }, verification };
    },
    async archive(_client, id, baseVersion) {
      const t = need(id);
      versionGuard(t, baseVersion);
      t.deleted_at = new Date().toISOString();
      t.version += 1;
      return { ...t };
    },
    async verificationTimeline(_client, id, opts = {}) {
      return verifications.listByDefect(null, id, opts);
    },
    async actionList(_client, id, opts = {}) {
      return actions.listByDefect(null, id, opts);
    },

    /**
     * BE-04：验证任务列表（fake 复刻真仓储的语义，含进入时间取法与 urgency 计算）。
     *
     * 进入时间与真库同规则：
     *   · V2 → 本 round 内 V1 pass 的 created_at
     *   · V3 → 本 round 内 V2 pass 的 created_at
     *   · V1 → updated_at（近似）
     * 这样 fake 层与真库对同一条数据给出一致的 entered_at，测试才有意义。
     */
    async listVerificationTasks(_client, userId, opts = {}) {
      if (!userId) throw new TypeError('defect_tickets.listVerificationTasks: userId 必填');
      const stages = Array.isArray(opts.stages) && opts.stages.length > 0 ? opts.stages : C.VERIFY_STAGES.slice();
      for (const s of stages) {
        if (!isVerifyStage(s)) throw new TypeError(`非法 stage ${String(s)}`);
      }
      const urgencies = Array.isArray(opts.urgency) && opts.urgency.length > 0 ? opts.urgency : null;

      const rows = [...tickets.values()]
        .filter((t) => t.user_id === userId && !t.deleted_at && stages.includes(t.status));

      const now = opts.now ?? new Date();
      const enriched = rows.map((t) => {
        const prevStage = t.status === 'V2' ? 'V1' : t.status === 'V3' ? 'V2' : null;
        let enteredAt = t.updated_at;
        if (prevStage) {
          const rec = [...verRows.values()]
            .filter((v) => v.defect_ticket_id === t.id && v.stage === prevStage &&
              Number(v.round) === Number(t.verification_round) &&
              v.result === 'pass' && !v.deleted_at)
            .sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)))[0];
          if (rec) enteredAt = rec.created_at;
        }
        const u = computeUrgency(enteredAt, windowDaysFor(t.status), now);
        return {
          id: t.id,
          user_id: t.user_id,
          exam_profile_id: t.exam_profile_id,
          knowledge_node_id: t.knowledge_node_id,
          question_id: t.question_id,
          q_type: t.q_type,
          priority: t.priority,
          stage: t.status,
          verification_round: t.verification_round,
          reopen_count: t.reopen_count,
          created_at: t.created_at,
          updated_at: t.updated_at,
          version: t.version,
          knowledge_node_title: null,
          knowledge_node_freq_tag: null,
          subject_id: null,
          subject_name: null,
          entered_at: u.enteredAt,
          window_days: u.windowDays,
          days_left: u.daysLeft,
          overdue_days: u.overdueDays,
          elapsed_days: u.elapsedDays,
          due_at: u.dueAt,
          urgency: u.urgency,
        };
      }).sort((a, b) => String(a.entered_at).localeCompare(String(b.entered_at)) || a.id.localeCompare(b.id));

      const filtered = urgencies ? enriched.filter((r) => urgencies.includes(r.urgency)) : enriched;
      const limit = Number.isInteger(opts.limit) && opts.limit > 0 ? Math.min(opts.limit, 200) : 50;
      const offset = Number.isInteger(opts.offset) && opts.offset > 0 ? opts.offset : 0;
      return { items: filtered.slice(offset, offset + limit), total: filtered.length, limit, offset };
    },

    /** BE-04：看板聚合（与列表同源，保证数字不漂移）。 */
    async verificationSummary(_client, userId, opts = {}) {
      if (!userId) throw new TypeError('defect_tickets.verificationSummary: userId 必填');
      const { items } = await this.listVerificationTasks(null, userId, { now: opts.now, limit: 200, offset: 0 });
      const by_stage = { V1: 0, V2: 0, V3: 0 };
      const by_urgency = { overdue: 0, due_soon: 0, normal: 0 };
      for (const row of items) {
        if (Object.prototype.hasOwnProperty.call(by_stage, row.stage)) by_stage[row.stage] += 1;
        if (Object.prototype.hasOwnProperty.call(by_urgency, row.urgency)) by_urgency[row.urgency] += 1;
      }
      return { total: items.length, by_stage, by_urgency, overdue: by_urgency.overdue, due_soon: by_urgency.due_soon, normal: by_urgency.normal };
    },
  };

  // -------------------------------------------------------------------------
  // BE-05：模考 + 作答（内存 fake）
  // -------------------------------------------------------------------------
  const mockRows = new Map();
  const attemptRows = new Map();
  // 题库 fake：测试用 seedQuestions([...]) 注入，create() 从中抽样。
  let questionPool = [];

  const questions = {
    seedRows(rows) {
      questionPool = rows.map((r) => ({ ...r }));
      return questionPool.length;
    },
    rows() {
      return questionPool.map((r) => ({ ...r }));
    },
    // ★ m17431：与真实仓储 listVisible 同口径（公共题 + 自己的题）。
    async listVisible(
      _client,
      {
        limit = 50,
        offset = 0,
        ownerUserId = null,
        subjectId = null,
        knowledgeNodeId = null,
        batchId = null,
        types,
        mastered,
        masteryState,
      } = {},
    ) {
      const typeList = Array.isArray(types) ? types : [];
      const rows = questionPool.filter((q) => {
        if (q.deleted_at) return false;
        if (subjectId && q.subject_id !== subjectId) return false;
        if (knowledgeNodeId && q.knowledge_node_id !== knowledgeNodeId) return false;
        if (batchId && q.batch_id !== batchId) return false;
        // ★ m31635：题型多选（与真实仓储 `type = ANY(...)` 同口径）。
        if (typeList.length > 0 && !typeList.includes(q.type)) return false;
        if (ownerUserId && q.owner_user_id != null && q.owner_user_id !== ownerUserId) {
          return false;
        }
        // m25316 / ★ m31635：掌握状态过滤（与真实仓储同口径）。
        //   masteryState 优先（多一个 unmarked：一行标记都没有才算）。
        if (masteryState && ownerUserId) {
          const m = masteryRows.get(`${ownerUserId}:${q.id}`);
          if (masteryState === 'unmarked') {
            if (m) return false;
          } else if (masteryState === 'mastered' || masteryState === 'unmastered') {
            const want = masteryState === 'mastered';
            if (!m || m.mastered !== want) return false;
          }
        } else if (typeof mastered === 'boolean' && ownerUserId) {
          const m = masteryRows.get(`${ownerUserId}:${q.id}`);
          if (!m || m.mastered !== mastered) return false;
        }
        return true;
      });
      return rows.slice(offset, offset + limit).map((r) => ({ ...r }));
    },
  };

  // m25316：掌握度 fake（key = `${userId}:${questionId}`）。
  const masteryRows = new Map();

  const questionMastery = {
    seedRows(rows) {
      for (const r of rows) {
        masteryRows.set(`${r.user_id}:${r.question_id}`, { ...r });
      }
      return masteryRows.size;
    },
    rows() {
      return [...masteryRows.values()].map((r) => ({ ...r }));
    },
    async upsertMastery(_client, { userId, questionId, mastered }) {
      const key = `${userId}:${questionId}`;
      const row = {
        id: newId('qm'),
        user_id: userId,
        question_id: questionId,
        mastered: Boolean(mastered),
        updated_at: new Date().toISOString(),
      };
      masteryRows.set(key, row);
      return { ...row };
    },
    async listMasteryMap(_client, { userId, questionIds }) {
      const map = new Map();
      if (!userId || !Array.isArray(questionIds)) return map;
      for (const qid of questionIds) {
        const row = masteryRows.get(`${userId}:${qid}`);
        if (row) map.set(qid, Boolean(row.mastered));
      }
      return map;
    },
  };


  const attempts = {
    async create(_client, input = {}) {
      if (!input.question_id) throw new TypeError('attempts.create: question_id 必填');
      if (!input.user_id) throw new TypeError('attempts.create: user_id 必填');
      const now = new Date().toISOString();
      const row = {
        id: newId('att'),
        question_id: input.question_id,
        user_id: input.user_id,
        is_correct: input.is_correct === true ? true : input.is_correct === false ? false : null,
        duration_ms: input.duration_ms ?? null,
        answer_text: input.answer_text ?? null,
        mock_exam_id: input.mock_exam_id ?? null,
        created_at: now,
        updated_at: now,
        version: 1,
        deleted_at: null,
      };
      attemptRows.set(row.id, row);
      return { ...row };
    },
    async getById(_client, id) {
      const row = attemptRows.get(id);
      if (!row || row.deleted_at) throw notFound('attempts', id);
      return { ...row };
    },
    async listByMock(_client, mockExamId, opts = {}) {
      const rows = [...attemptRows.values()]
        .filter((r) => r.mock_exam_id === mockExamId && !r.deleted_at)
        .map((r) => ({ ...r }));
      const limit = opts.limit ?? 200;
      const offset = opts.offset ?? 0;
      return rows.slice(offset, offset + limit);
    },
  };

  const mockExams = {
    async create(_client, input = {}) {
      if (!input.exam_profile_id) throw new TypeError('mock_exams.create: exam_profile_id 必填');
      if (input.mode !== 'module' && input.mode !== 'full') {
        const e = new TypeError('mock_exams.create: 非法 mode');
        e.code = 'INVALID_MODE';
        throw e;
      }
      const count = Number(input.question_count);
      if (!Number.isInteger(count) || count < 1 || count > 200) {
        const e = new TypeError('mock_exams.create: question_count 必须是 1..200 的整数');
        e.code = 'INVALID_QUESTION_COUNT';
        throw e;
      }
      if (input.mode === 'full' && !input.subject_id) {
        const e = new TypeError('mock_exams.create: full 模式必须提供 subject_id');
        e.code = 'MISSING_SUBJECT_ID';
        throw e;
      }
      if (input.mode === 'module' && !input.knowledge_node_id) {
        const e = new TypeError('mock_exams.create: module 模式必须提供 knowledge_node_id');
        e.code = 'MISSING_KNOWLEDGE_NODE_ID';
        throw e;
      }
      const scope = input.mode === 'full' ? input.subject_id : input.knowledge_node_id;
      const field = input.mode === 'full' ? 'subject_id' : 'knowledge_node_id';
      // ★ m17431：只抽「公共题 + 该用户自己的题」，别人的私有题不可见。
      //   owner_user_id 为空（未鉴权调用 / seed）时不过滤，保持旧行为。
      const ownerUserId = input.owner_user_id ?? null;
      const visible = questionPool.filter(
        (q) =>
          !q.deleted_at &&
          q[field] === scope &&
          (ownerUserId ? q.owner_user_id == null || q.owner_user_id === ownerUserId : true),
      );
      const available = visible;
      if (available.length < count) {
        const e = new Error('INSUFFICIENT_QUESTIONS');
        e.code = 'INSUFFICIENT_QUESTIONS';
        e.statusCode = 400;
        e.body = { error: 'INSUFFICIENT_QUESTIONS', available: available.length, requested: count };
        throw e;
      }
      const picked = available.slice(0, count);
      const now = new Date().toISOString();
      const row = {
        id: newId('me'),
        exam_profile_id: input.exam_profile_id,
        mode: input.mode,
        duration_limit_ms: input.duration_limit_ms ?? null,
        questions: picked.map((q) => ({
          question_id: q.id,
          attempt_id: null,
          is_correct: null,
          duration_ms: null,
        })),
        report: null,
        created_at: now,
        updated_at: now,
        version: 1,
        deleted_at: null,
      };
      mockRows.set(row.id, row);
      return {
        mock_exam: { ...row },
        questions: picked.map((q) => {
          const { answer: _a, analysis: _b, ...rest } = q;
          return { ...rest };
        }),
        available: available.length,
      };
    },
    async getById(_client, id) {
      const row = mockRows.get(id);
      if (!row || row.deleted_at) throw notFound('mock_exams', id);
      return { ...row };
    },
    async listByProfile(_client, examProfileId, opts = {}) {
      let rows = [...mockRows.values()].filter(
        (r) => r.exam_profile_id === examProfileId && !r.deleted_at,
      );
      if (opts.mode) rows = rows.filter((r) => r.mode === opts.mode);
      if (opts.submittedOnly === true) rows = rows.filter((r) => r.report != null);
      rows.sort((a, b) => (a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0));
      const limit = opts.limit ?? 20;
      const offset = opts.offset ?? 0;
      return rows.slice(offset, offset + limit).map((r) => ({ ...r }));
    },
    async submit(_client, id, input = {}) {
      const row = mockRows.get(id);
      if (!row || row.deleted_at) throw notFound('mock_exams', id);
      if (row.report) {
        const e = new Error('already_submitted');
        e.code = 'already_submitted';
        e.statusCode = 409;
        e.body = { error: 'already_submitted', mock_exam_id: id };
        throw e;
      }
      const baseVersion = input.baseVersion;
      if (!Number.isInteger(baseVersion) || baseVersion < 1) {
        throw new TypeError('mock_exams.submit: baseVersion 必填');
      }
      if (Number(baseVersion) !== Number(row.version)) throw conflict(row, baseVersion);

      const answers = Array.isArray(input.answers) ? input.answers : [];
      const byQ = new Map(answers.filter((a) => a && a.question_id).map((a) => [a.question_id, a]));
      const byId = new Map(questionPool.map((q) => [q.id, q]));

      const submittedMs = input.submitted_at ? new Date(input.submitted_at).getTime() : Date.now();
      const startedMs = new Date(row.created_at).getTime();
      const elapsedMs = submittedMs - startedMs;
      const timedOut =
        row.duration_limit_ms != null && elapsedMs > Number(row.duration_limit_ms) + 60000;

      const filled = [];
      for (const entry of row.questions) {
        const q = byId.get(entry.question_id) ?? null;
        const ans = byQ.get(entry.question_id) ?? null;
        const answered = Boolean(ans && String(ans.answer_text ?? '').trim() !== '');
        let isCorrect = null;
        if (q && q.is_subjective !== true && q.type !== 'essay' && q.type !== 'short_answer') {
          const expected = q.answer == null ? '' : String(q.answer).trim();
          if (expected !== '') {
            isCorrect = norm(answered ? ans.answer_text : '') === norm(expected);
          }
        }
        if (timedOut && !answered) isCorrect = false;
        const att = await attempts.create(null, {
          question_id: entry.question_id,
          user_id: input.userId ?? 'u-1',
          is_correct: isCorrect,
          duration_ms: Number.isFinite(Number(ans?.duration_ms)) ? Number(ans.duration_ms) : null,
          answer_text: answered ? String(ans.answer_text) : null,
          mock_exam_id: id,
        });
        filled.push({
          question_id: entry.question_id,
          attempt_id: att.id,
          is_correct: isCorrect,
          duration_ms: att.duration_ms,
        });
      }

      const closedDefects = [...tickets.values()]
        .filter(
          (t) => !t.deleted_at && (t.status === 'CLOSED' || t.status === 'V3') && t.question_id,
        )
        .map((t) => ({
          id: t.id,
          question_id: t.question_id,
          knowledge_node_id: t.knowledge_node_id,
          status: t.status,
        }));

      // 近 3 次同 mode 已提交模考（不含本次）
      const recentMocks = [...mockRows.values()]
        .filter(
          (r) =>
            r.id !== id &&
            !r.deleted_at &&
            r.exam_profile_id === row.exam_profile_id &&
            r.mode === row.mode &&
            r.report != null,
        )
        .sort((a, b) => (a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0))
        .slice(0, 3)
        .map((r) => ({ ...r }));

      const report = reportGenerator({
        questions: row.questions.map((e) => {
          const q = byId.get(e.question_id);
          return {
            question_id: e.question_id,
            knowledge_node_id: q?.knowledge_node_id ?? null,
            title: q?.knowledge_node_title ?? null,
          };
        }),
        attempts: filled,
        closedDefects,
        recentMocks,
      });

      row.questions = filled;
      row.report = report;
      row.version += 1;
      row.updated_at = new Date().toISOString();
      mockRows.set(id, row);

      return { mock_exam: { ...row }, report, timed_out: timedOut, elapsed_ms: Math.max(0, elapsedMs) };
    },
    async getReport(_client, id) {
      const row = mockRows.get(id);
      if (!row || row.deleted_at) throw notFound('mock_exams', id);
      return row.report ?? null;
    },
    async archive(_client, id, baseVersion) {
      const row = mockRows.get(id);
      if (!row || row.deleted_at) throw notFound('mock_exams', id);
      if (Number(baseVersion) !== Number(row.version)) throw conflict(row, baseVersion);
      row.deleted_at = new Date().toISOString();
      row.version += 1;
      mockRows.set(id, row);
      return { ...row };
    },
  };
  // -------------------------------------------------------------------------
  // 复盘快照（BE-06）：与真仓储同语义 —— 同周期重复 create 抛 409 ALREADY_EXISTS，
  // body 带 existing_id + resolution:'delete_then_recreate'（不是 user_choice：
  // 复盘已经生成过，要重做必须先删，不存在「合并」选项）。
  // -------------------------------------------------------------------------
  const reviewRows = new Map();

  function reviewNotFound(id) {
    return notFound('review_cycles', id);
  }

  function alreadyExists(row) {
    const e = new Error(`review_cycles already exists: ${row.cycle_type} ${row.period}`);
    e.name = 'ConflictError';
    e.code = 'ALREADY_EXISTS';
    e.statusCode = 409;
    e.status = 409;
    e.body = {
      error: 'ALREADY_EXISTS',
      cycle_type: row.cycle_type,
      period: row.period,
      existing_id: row.id,
      resolution: 'delete_then_recreate',
    };
    return e;
  }

  const reviewCycles = {
    async create(_client, input = {}) {
      const { user_id, cycle_type, period } = input;
      if (!user_id) throw new TypeError('review_cycles.create: user_id 必填');
      if (!cycle_type) throw new TypeError('review_cycles.create: cycle_type 必填');
      if (!period) throw new TypeError('review_cycles.create: period 必填');
      if (!input.metrics || typeof input.metrics !== 'object' || Array.isArray(input.metrics)) {
        throw new TypeError('review_cycles.create: metrics 必须是对象');
      }

      // 查重：只看未软删的同周期行。软删后允许重新生成（与真仓储一致）。
      for (const row of reviewRows.values()) {
        if (
          !row.deleted_at &&
          row.user_id === user_id &&
          row.cycle_type === cycle_type &&
          row.period === period
        ) {
          throw alreadyExists(row);
        }
      }

      const nowIso = new Date().toISOString();
      const row = {
        id: newId('rc'),
        user_id,
        cycle_type,
        period,
        metrics: input.metrics,
        completed: input.completed === true,
        created_at: nowIso,
        updated_at: nowIso,
        version: 1,
        deleted_at: null,
      };
      reviewRows.set(row.id, row);
      return { ...row };
    },

    async getById(_client, id) {
      const row = reviewRows.get(id);
      if (!row || row.deleted_at) throw reviewNotFound(id);
      return { ...row };
    },

    async findByPeriod(_client, userId, cycleType, period, opts = {}) {
      for (const row of reviewRows.values()) {
        if (row.deleted_at) continue;
        if (opts.excludeId && row.id === opts.excludeId) continue;
        if (row.user_id === userId && row.cycle_type === cycleType && row.period === period) {
          return { ...row };
        }
      }
      return null;
    },

    async listByUser(_client, userId, opts = {}) {
      const limit = Number.isFinite(opts.limit) && opts.limit > 0 ? opts.limit : 50;
      const offset = Number.isFinite(opts.offset) && opts.offset > 0 ? opts.offset : 0;

      const filtered = [...reviewRows.values()]
        .filter((row) => !row.deleted_at && row.user_id === userId)
        .filter((row) => (opts.cycleType ? row.cycle_type === opts.cycleType : true))
        .filter((row) => (opts.period ? row.period === opts.period : true))
        .filter((row) => (opts.completed === undefined ? true : row.completed === opts.completed))
        // period DESC, created_at DESC, id DESC —— 与真仓储 ORDER BY 完全一致
        .sort((a, b) => {
          if (a.period !== b.period) return a.period < b.period ? 1 : -1;
          if (a.created_at !== b.created_at) return a.created_at < b.created_at ? 1 : -1;
          return a.id < b.id ? 1 : -1;
        });

      return {
        items: filtered.slice(offset, offset + limit).map((row) => ({ ...row })),
        total: filtered.length,
        limit,
        offset,
      };
    },

    async markCompleted(_client, id, completed, baseVersion) {
      const row = reviewRows.get(id);
      if (!row || row.deleted_at) throw reviewNotFound(id);
      if (Number(baseVersion) !== Number(row.version)) throw conflict(row, baseVersion);
      row.completed = completed === true;
      row.version += 1;
      row.updated_at = new Date().toISOString();
      reviewRows.set(id, row);
      return { ...row };
    },

    async archive(_client, id, baseVersion) {
      const row = reviewRows.get(id);
      if (!row || row.deleted_at) throw reviewNotFound(id);
      if (Number(baseVersion) !== Number(row.version)) throw conflict(row, baseVersion);
      row.deleted_at = new Date().toISOString();
      row.version += 1;
      reviewRows.set(id, row);
      return { ...row };
    },

    async findByIdIncludingDeleted(_client, id) {
      const row = reviewRows.get(id);
      return row ? { ...row } : null;
    },
  };

  // fake 的 metrics 实现：零值骨架，只为让路由层可在无 PG 下单测。
  // 六项键与 review_stats.computeMetrics 完全一致（契约不漂移），
  // 真口径由 server/routes/review_cycles.integration.test.mjs 覆盖。
  reviewCycles.computeMetrics = async (_client, _userId, _bounds) => ({
    open_defects: {
      total: 0,
      by_status: {
        DRAFT: 0,
        ANALYZED: 0,
        ACTION_DONE: 0,
        V1: 0,
        V2: 0,
        V3: 0,
        REOPENED: 0,
      },
    },
    layer_dist: {},
    verify_pass_rate: { pass: 0, fail: 0, total: 0, rate: null },
    mock_stability: null,
    target_progress: { target_score: null, latest_mock_score: null, rate: null },
    reopen_hotspots: [],
  });

  function norm(value) {
    return String(value ?? '')
      .normalize('NFKC')
      .replace(/[\s\u3000，。！？；：（）【】《》、,.!?;:()[\]<>"'`]/g, '')
      .toUpperCase();
  }

  return { client: null, defectTickets, actions, verifications, mockExams, attempts, questions, questionMastery, reviewCycles };
}
