// server/index.mjs
// 题路 TillRoad · REST API 骨架（Node 24，零第三方依赖，仅用 node 内置模块）
// 依赖契约：core/index.mjs（Lead 维护，本文件只读它导出的常量与函数，不擅自改动）。
// 存储：进程内 Map/数组（无数据库依赖），数据模型字段尽量对齐 schema.sql。
// 用法：import { createApp } from './index.mjs' 可测试；或 node server/index.mjs 直接启动。
import { createServer as httpCreateServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import * as C from '../core/index.mjs';

// ---------------------------------------------------------------------------
// 通用工具
// ---------------------------------------------------------------------------
const now = () => new Date().toISOString();

function json(res, status, obj) {
  const data = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(data),
  });
  res.end(data);
}

// 统一错误映射：core 抛出的带 .code 的 Error -> 400 {error: code}；
// 未知异常 -> 500 {error:'internal'}。
function sendError(res, e) {
  if (e && typeof e.code === 'string' && e.code) {
    json(res, 400, { error: e.code });
  } else {
    json(res, 500, { error: 'internal' });
  }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(Object.assign(new Error('invalid json'), { code: 'INVALID_JSON' }));
      }
    });
    req.on('error', reject);
  });
}

// 乐观锁：仅当请求显式携带 version 且与当前不符时判定冲突。
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

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

// 用 C.computePriority 计算优先级；支持 body 直接带字段或 body.priority 子对象。
function computePriority(body) {
  const src = body && body.priority && typeof body.priority === 'object' ? body.priority : (body || {});
  return C.computePriority({
    frequency: num(src.frequency),
    loss: num(src.loss),
    closability: num(src.closability),
    targetContribution: num(src.targetContribution),
  });
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

// ---------------------------------------------------------------------------
// createApp：每个实例持有独立内存状态，便于集成测试隔离
// ---------------------------------------------------------------------------
export function createApp() {
  const state = {
    examProfiles: new Map(),
    defectTickets: new Map(),
    verifications: [],
    aiJobs: new Map(),
  };

  function route(method, pathname, searchParams, body) {
    const seg = pathname.split('/').filter(Boolean);

    // 6') POST /verifications -> 规范路径(开发文档 §11 / schema.sql 附录)。
    //     内部委托给 /defect-tickets/:id/verifications, 避免逻辑重复; 嵌套路径保留为等价别名。
    if (method === 'POST' && seg.length === 1 && seg[0] === 'verifications' && body.defect_ticket_id) {
      return route('POST', `/defect-tickets/${encodeURIComponent(String(body.defect_ticket_id))}/verifications`, searchParams, body);
    }

    // 1) GET /health -> 200 {status:'ok'}
    if (method === 'GET' && seg.length === 1 && seg[0] === 'health') {
      return { status: 200, body: { status: 'ok' } };
    }

    // 2) POST /exam-profiles -> 201 目标配置
    if (method === 'POST' && seg.length === 1 && seg[0] === 'exam-profiles') {
      const ts = now();
      const id = randomUUID();
      const profile = {
        id,
        user_id: body.user_id ?? null,
        exam_type: body.exam_type ?? null,
        target_label: body.target_label ?? null,
        target_score: body.target_score ?? null,
        subject_target: body.subject_target ?? null,
        exam_date: body.exam_date ?? null,
        daily_minutes: body.daily_minutes ?? null,
        source_scope: body.source_scope ?? null,
        baseline: body.baseline ?? null,
        status: 'active',
        created_at: ts,
        updated_at: ts,
        version: 1,
      };
      state.examProfiles.set(id, profile);
      return { status: 201, body: profile };
    }

    // 3) POST /defect-tickets -> 201 建单
    if (method === 'POST' && seg.length === 1 && seg[0] === 'defect-tickets') {
      const wantDraft = body.status === 'DRAFT' || body.draft === true;
      if (wantDraft) {
        // P0-3 修复：仅记录错题的 DRAFT 草稿可未归因
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
      //    契约权威: 开发文档 §11 / schema.sql 附录 (POST + missing_error_layer_or_cause)。
      //    兼容 PATCH 作为旧调用方别名, 规范路径为 POST。
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
          // P0-2 修复：重新归因后开启新一轮验证轮次
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

      // 直接 close：非法迁移由 C.assertTransition 拒绝 -> 400（ACTION_DONE 不能直跳 CLOSED）。
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
          (r) => r.defect_ticket_id === id && r.stage === stage && r.round === round
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
      pathname === '/ai/questions:generate' ||
      (seg[0] === 'ai' && seg[1] === 'questions:generate') ||
      seg[0] === 'ai-jobs'
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

    return { status: 404, body: { error: 'not_found' } };
  }

  const server = httpCreateServer(async (req, res) => {
    try {
      const body = await readBody(req);
      const u = new URL(req.url, 'http://localhost');
      let pathname = u.pathname;
      if (pathname.length > 1 && pathname.endsWith('/')) pathname = pathname.slice(0, -1);
      const out = route(req.method, pathname, u.searchParams, body);
      json(res, out.status, out.body);
    } catch (e) {
      sendError(res, e);
    }
  });

  return {
    server,
    listen(...args) {
      return server.listen(...args);
    },
    close(...args) {
      return server.close(...args);
    },
  };
}

// 同时导出 createServer 别名，便于不同工厂命名习惯。
export const createServer = createApp;

// 作为主模块直接启动：node server/index.mjs（监听 PORT 或 3000）。
const invoked = process.argv[1] ? path.resolve(process.argv[1]) : '';
if (invoked && fileURLToPath(import.meta.url) === invoked) {
  const port = Number(process.env.PORT) || 3000;
  const app = createApp();
  app.listen(port, () => {
    // eslint-disable-next-line no-console
    console.log(`TillRoad API listening on http://127.0.0.1:${port}`);
  });
}
