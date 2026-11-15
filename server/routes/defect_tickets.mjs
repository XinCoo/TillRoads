// server/routes/defect_tickets.mjs
// 题路 TillRoad · BE-01 第 4 步：缺陷单 / 模考 / 复盘 / AI 生成端点迁移（T3）
//
// **本轮只搬不改**：这 4 组端点的业务语义属于 BE-03/BE-04（缺陷单状态机）与
// BE-02/BE-05（AI 生成、模考、复盘），第 4 步的硬约束是「不要实现 BE-03/04」。
// 因此这里逐字保留 server/index.mjs 原实现的行为与响应形状，只做两件结构调整：
//   1. 从 index.mjs 的 route() 里搬出来，改成 match(method, seg, ctx) 形状；
//   2. 内存 state 从「createApp 闭包内变量」改成「由 ctx.state 传入」，
//      这样 index.mjs 仍持有唯一一份 state，测试也能注入。
//
// 为什么不在这里改 base_version（决策 8 的强制化）：
//   决策 8 的范围是「PATCH/DELETE 必须带 version」——针对的是第 3 步那四张已经接 PG
//   的表（exam_profiles / subjects / knowledge_nodes / capability_layers）。
//   缺陷单现在还在内存 Map 里，它的乐观锁语义（versionConflict 仅在 version 显式
//   出现时校验）是现有 16 条测试的既定契约，且 BE-03 会把整组端点重写到 PG 上。
//   此时提前改这里只会让 16 条测试里的 9 条无谓失效，并在 BE-03 再改一遍。
//   —— 这一点已在交付说明「遗留项」里写明，不是遗漏。

import { randomUUID } from 'node:crypto';
import * as C from '../../core/index.mjs';

const now = () => new Date().toISOString();

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** 用 C.computePriority 计算优先级；支持 body 直接带字段或 body.priority 子对象。 */
function computePriority(body) {
  const src = body && body.priority && typeof body.priority === 'object' ? body.priority : (body || {});
  return C.computePriority({
    frequency: num(src.frequency),
    loss: num(src.loss),
    closability: num(src.closability),
    targetContribution: num(src.targetContribution),
  });
}

// 乐观锁：仅当请求显式携带 version 且与当前不符时判定冲突（内存态与既有契约一致）。
function versionConflict(ticket, body) {
  if (body && body.version !== undefined) {
    const incoming = Number(body.version);
    if (!Number.isFinite(incoming) || incoming !== Number(ticket.version)) {
      return { conflict: true, current: ticket.version, incoming: body.version };
    }
  }
  return { conflict: false };
}

function conflictBody(v) {
  return {
    error: 'conflict',
    current: v.current,
    incoming: v.incoming,
    resolution: 'client_merge',
  };
}

function newTicket(body, status) {
  const ts = now();
  return {
    id: randomUUID(),
    user_id: body.user_id ?? null,
    exam_profile_id: body.exam_profile_id ?? null,
    knowledge_node_id: body.knowledge_node_id ?? null,
    question_id: body.question_id ?? null,
    q_type: body.q_type ?? null,
    error_layer: body.error_layer ?? '',
    error_cause: body.error_cause ?? '',
    actions: Array.isArray(body.actions) ? body.actions : [],
    priority: computePriority(body),
    status,
    verification_state: { v1: 'pending', v2: 'pending', v3: 'pending' },
    reopen_count: 0,
    reopen_reason: null,
    verification_round: 1,
    version: 1,
    created_at: ts,
    updated_at: ts,
    closed_at: null,
  };
}

export function match(method, seg, ctx) {
  const { searchParams, body, state } = ctx;

  // 6') POST /verifications -> 规范路径（开发文档 §11 / schema.sql 附录）。
  //     内部委托给 /defect-tickets/:id/verifications，避免逻辑重复；嵌套路径保留为等价别名。
  if (method === 'POST' && seg.length === 1 && seg[0] === 'verifications' && body.defect_ticket_id) {
    return match('POST', ['defect-tickets', encodeURIComponent(String(body.defect_ticket_id)), 'verifications'], ctx);
  }

  // 3) POST /defect-tickets -> 201 建单
  if (method === 'POST' && seg.length === 1 && seg[0] === 'defect-tickets') {
    const wantDraft = body.status === 'DRAFT' || body.draft === true;
    if (wantDraft) {
      // P0-3：仅记录错题的 DRAFT 草稿可未归因
      const t = newTicket(body, 'DRAFT');
      state.defectTickets.set(t.id, t);
      return { status: 201, body: t };
    }
    // 系统建单即归因：status 固定 ANALYZED；用 DRAFT 作为归因前的来源态校验。
    try {
      C.assertAnalyzable({ status: 'DRAFT', error_layer: body.error_layer, error_cause: body.error_cause });
    } catch (e) {
      if (e.code === 'FORBIDDEN_PHRASE_IN_ERROR_CAUSE') return { status: 400, body: { error: 'forbidden_phrase' } };
      if (e.code === 'MISSING_ERROR_LAYER' || e.code === 'MISSING_ERROR_CAUSE') return { status: 400, body: { error: 'missing_error_layer_or_cause' } };
      throw e;
    }
    const t = newTicket(body, 'ANALYZED');
    state.defectTickets.set(t.id, t);
    return { status: 201, body: t };
  }

  // defect-tickets/:id 系列端点
  if (seg[0] === 'defect-tickets' && seg.length >= 2) {
    const id = seg[1];
    const t = state.defectTickets.get(id);
    if (!t) return { status: 404, body: { error: 'not_found' } };

    // 4) POST /defect-tickets/:id/analyze -> DRAFT/REOPENED -> ANALYZED
    //    契约权威：开发文档 §11 / schema.sql 附录（POST + missing_error_layer_or_cause）。
    //    兼容 PATCH 作为旧调用方别名，规范路径为 POST。
    if ((method === 'POST' || method === 'PATCH') && seg.length === 3 && seg[2] === 'analyze') {
      const v = versionConflict(t, body);
      if (v.conflict) return { status: 409, body: conflictBody(v) };
      try {
        C.assertAnalyzable({ status: t.status, error_layer: body.error_layer, error_cause: body.error_cause });
      } catch (e) {
        if (e.code === 'FORBIDDEN_PHRASE_IN_ERROR_CAUSE') return { status: 400, body: { error: 'forbidden_phrase' } };
        if (e.code === 'MISSING_ERROR_LAYER' || e.code === 'MISSING_ERROR_CAUSE') return { status: 400, body: { error: 'missing_error_layer_or_cause' } };
        throw e;
      }
      if (t.status === 'REOPENED') {
        // P0-2：重新归因后开启新一轮验证轮次
        const r = C.reanalyze(t);
        t.status = r.status;
        t.verification_round = r.verification_round;
        t.reopen_count = r.reopen_count;
      } else {
        t.status = 'ANALYZED';
      }
      t.error_layer = body.error_layer;
      t.error_cause = body.error_cause;
      t.version += 1;
      t.updated_at = now();
      return { status: 200, body: t };
    }

    // 5) POST /defect-tickets/:id/action -> ANALYZED -> ACTION_DONE
    //    强调「ACTION_DONE 不等于 CLOSED」：此端点只能推进到 ACTION_DONE。
    if (method === 'POST' && seg.length === 3 && seg[2] === 'action') {
      const v = versionConflict(t, body);
      if (v.conflict) return { status: 409, body: conflictBody(v) };
      C.assertTransition(t.status, 'ACTION_DONE');
      t.status = 'ACTION_DONE';
      t.actions.push({ content: body.action ?? body.content ?? '', done: true, created_at: now() });
      t.version += 1;
      t.updated_at = now();
      return { status: 200, body: t };
    }

    // 直接 close：非法迁移由 C.assertTransition 拒绝 -> 400。
    if (method === 'POST' && seg.length === 3 && seg[2] === 'close') {
      const v = versionConflict(t, body);
      if (v.conflict) return { status: 409, body: conflictBody(v) };
      C.assertTransition(t.status, 'CLOSED');
      t.status = 'CLOSED';
      t.closed_at = now();
      t.version += 1;
      t.updated_at = now();
      return { status: 200, body: t };
    }

    // 6) POST /defect-tickets/:id/verifications -> 三次验证
    if (method === 'POST' && seg.length === 3 && seg[2] === 'verifications') {
      const v = versionConflict(t, body);
      if (v.conflict) return { status: 409, body: conflictBody(v) };
      // 「仅用户可标记 pass」：AI 不得把缺陷单推进/关闭。
      if (body.actor === 'ai' && body.result === 'pass') {
        return { status: 403, body: { error: 'ai_cannot_close' } };
      }
      const stage = body.stage;
      const result = body.result;
      const round = t.verification_round;
      // P0-2：验证记录用 round 维度；同一 (ticket, stage) 在不同 round 可各有一条，
      // 但同一 round 内重复提交 -> 409（对齐 schema 的重复提交冲突）。
      const dup = state.verifications.find(
        (r) => r.defect_ticket_id === id && r.stage === stage && r.round === round,
      );
      if (dup) return { status: 409, body: { error: 'conflict', message: 'duplicate verification in this round' } };

      let applied;
      if (t.status === 'ACTION_DONE' && stage === 'V1' && result === 'pass') {
        // ACTION_DONE + V1 pass：先 beginVerification 进入 V1，再 applyVerification 推进到 V2。
        const b = C.beginVerification(t, 'V1');
        t.status = b.status; // 进入 V1
        applied = C.applyVerification(t, 'V1', 'pass'); // -> V2
      } else {
        // 其余情况：ticket.status 必须 === stage，由 core 校验阶段/结果/状态机。
        applied = C.applyVerification(t, stage, result);
      }
      t.status = applied.status;
      t.reopen_count = applied.reopen_count;
      t.version += 1;
      t.updated_at = now();
      if (t.status === 'CLOSED') t.closed_at = now();

      const ts = now();
      const record = {
        id: randomUUID(),
        defect_ticket_id: id,
        stage,
        result,
        verify_type: body.type ?? body.verify_type ?? 'redo_hidden',
        round,
        evidence: body.evidence ?? null,
        verified_at: ts,
        created_at: ts,
        version: 1,
      };
      state.verifications.push(record);
      return { status: 201, body: { ticket: t, verification: record } };
    }

    // 10) 通用 PATCH /defect-tickets/:id（乐观锁 + 合法状态迁移 + 字段更新）
    if (method === 'PATCH' && seg.length === 2) {
      const v = versionConflict(t, body);
      if (v.conflict) return { status: 409, body: conflictBody(v) };
      if (body.status && body.status !== t.status) {
        C.assertTransition(t.status, body.status);
        if (body.status === 'REOPENED' && t.status !== 'REOPENED') {
          t.reopen_count = (Number(t.reopen_count) || 0) + 1;
        }
        if (body.status === 'CLOSED') t.closed_at = now();
        t.status = body.status;
      }
      const allowed = ['error_layer', 'error_cause', 'priority', 'q_type',
        'knowledge_node_id', 'question_id', 'exam_profile_id', 'user_id', 'actions', 'reopen_reason'];
      for (const k of allowed) {
        if (Object.prototype.hasOwnProperty.call(body, k)) t[k] = body[k];
      }
      t.version += 1;
      t.updated_at = now();
      return { status: 200, body: t };
    }
  }

  // 7) GET /mock-exams/:id/report -> 模考报告（内存造合理数据）
  if (method === 'GET' && seg.length === 3 && seg[0] === 'mock-exams' && seg[2] === 'report') {
    const id = seg[1];
    const links = [...state.defectTickets.values()].slice(0, 5).map((t) => ({
      defect_ticket_id: t.id,
      knowledge_node_id: t.knowledge_node_id,
      status: t.status,
    }));
    return {
      status: 200,
      body: {
        mock_exam_id: id,
        total_score: 78.5,
        by_knowledge_node: [
          { knowledge_node_id: 'kn-1', title: '函数与导数', accuracy: 0.82, avg_duration_ms: 45000 },
          { knowledge_node_id: 'kn-2', title: '立体几何', accuracy: 0.65, avg_duration_ms: 62000 },
        ],
        defect_links: links,
        stability_index: 0.87,
      },
    };
  }

  // 8) GET /review-cycles?type=weekly -> 复盘
  if (method === 'GET' && seg.length === 1 && seg[0] === 'review-cycles') {
    const type = searchParams.get('type') || 'weekly';
    const tickets = [...state.defectTickets.values()];
    return {
      status: 200,
      body: {
        type,
        closed_count: tickets.filter((x) => x.status === 'CLOSED').length,
        reopened_count: tickets.filter((x) => x.status === 'REOPENED').length,
        new_defects: tickets.length,
        timeline: tickets.slice(0, 10).map((x) => ({ id: x.id, status: x.status, created_at: x.created_at })),
      },
    };
  }

  // 9) POST /ai/questions:generate 与 POST /ai-jobs -> AI 生成任务
  if (method === 'POST' && (
    seg.length === 2 && seg[0] === 'ai' && seg[1] === 'questions:generate'
    || seg.length === 1 && seg[0] === 'ai-jobs'
  )) {
    const v = C.validateAIGenerateRequest(body);
    if (!v.ok) return { status: 400, body: { error: v.error.code, message: v.error.message } };
    const job_id = randomUUID();
    // job 自持 provider/model 快照（对齐 byok-key-lifecycle.md 场景 5）：
    // 凭证被轮换/撤销/删除后仍可还原执行用的是哪家 provider 与模型。
    const provider_snapshot = body.provider ?? 'deepseek';
    const model_snapshot = body.model ?? body.model_name ?? 'deepseek-chat';
    state.aiJobs.set(job_id, {
      job_id,
      status: 'pending',
      provider_snapshot,
      model_snapshot,
      count: body.count,
      payload: { ...body },
      created_at: now(),
    });
    return { status: 202, body: { job_id, status: 'pending', provider_snapshot, model_snapshot } };
  }

  return null;
}
