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
      return { ...row };
    },
    async getById(_client, id) {
      return { ...need(id) };
    },
    async findById(_client, id, opts = {}) {
      const t = tickets.get(id);
      if (!t || (t.deleted_at && !opts.includeDeleted)) return null;
      return { ...t };
    },
    async listByUser(_client, userId, opts = {}) {
      let rows = [...tickets.values()].filter((t) => t.user_id === userId && !t.deleted_at);
      if (opts.status) rows = rows.filter((t) => t.status === opts.status);
      return rows.map((t) => ({ ...t }));
    },
    async listAll(_client, _opts = {}) {
      return [...tickets.values()].filter((t) => !t.deleted_at).map((t) => ({ ...t }));
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
  };

  return { client: null, defectTickets, actions, verifications };
}
