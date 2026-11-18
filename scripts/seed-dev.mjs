// 幂等造测试数据，供 FE-03 联调。
//
// 关键约束（来自 schema.sql 与触发器，不是随意选择）：
//   · defect_tickets 有两个 NOT NULL 外键：user_id → users(id)、exam_profile_id → exam_profiles(id)，
//     所以必须按 users → exam_profiles → subjects → knowledge_nodes → defect_tickets 的链路造数据。
//   · 状态机触发器 check_defect_transition **只在 UPDATE 时**校验迁移表，
//     INSERT 时直接给 status 是允许的 —— 因此每条单子各自 INSERT，绝不用 UPDATE 连跳。
//   · check_defect_forbidden_phrase 在 INSERT OR UPDATE 时都会跑：
//       - status='DRAFT' 直接放行（P0-3：建单未归因）
//       - 其它状态要求 error_layer / error_cause 非空，且不得含禁用词
//     —— 这就是为什么下面只有 DRAFT 那条的归因写 null。
//
// 幂等策略：全部使用**固定 UUID**，脚本开头按外键顺序 DELETE 再插入，
// 重复执行结果一致，且不污染已有的真实数据（只删自己造的那批 id）。

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
try {
  process.loadEnvFile(join(ROOT, '.env'));
} catch {
  /* .env 可选 */
}

const { createPool } = await import('../server/db/pool.mjs');
const pool = createPool();

// ---- 固定 id（幂等重跑的关键）------------------------------------------------
const USER_ID = '11111111-1111-4111-8111-111111111111';
const PROFILE_ID = '22222222-2222-4222-8222-222222222222';
const SUBJECT_1 = '33333333-3333-4333-8333-333333333331';
const SUBJECT_2 = '33333333-3333-4333-8333-333333333332';
const NODE = {
  logical: '44444444-4444-4444-8444-444444444401', // 言语理解 · 逻辑填空
  analogy: '44444444-4444-4444-8444-444444444402', // 判断推理 · 类比推理
  travel: '44444444-4444-4444-8444-444444444403', // 数量关系 · 行程问题
  rate: '44444444-4444-4444-8444-444444444404', // 资料分析 · 增长率比较
  sufficient: '44444444-4444-4444-8444-444444444405', // 判断推理 · 充分必要条件
  law: '44444444-4444-4444-8444-444444444406', // 常识判断 · 法律常识
  figure: '44444444-4444-4444-8444-444444444407', // 判断推理 · 图形推理
  ratio: '44444444-4444-4444-8444-444444444408', // 资料分析 · 比重变化
};

const TICKETS = [
  // id 后缀 / status / 考点 / q_type / 优先级 / 归因层 / 天前 / 动作数 / 验证
  { n: 1, status: 'DRAFT', node: NODE.analogy, qType: '判断推理 · 类比推理', pri: 'P1', layer: null, cause: null, daysAgo: 0, hoursAgo: 2, ver: [] },
  { n: 2, status: 'ANALYZED', node: NODE.travel, qType: '数量关系 · 行程问题', pri: 'P0', layer: '方法不会', cause: '把相遇问题当成追及问题套公式导致方程列错', daysAgo: 2, ver: [] },
  { n: 3, status: 'ACTION_DONE', node: NODE.logical, qType: '言语理解 · 逻辑填空', pri: 'P1', layer: '概念不清', cause: '没有区分词语的褒贬色彩，只按语义通顺选择', daysAgo: 3, actions: [{ c: '整理近义词辨析表', d: true }, { c: '重做同类题 10 道', d: true }], ver: [] },
  { n: 4, status: 'V1', node: NODE.rate, qType: '资料分析 · 增长率比较', pri: 'P0', layer: '计算失误', cause: '增长率比较时分母取错，把基期当成现期', daysAgo: 4, actions: [{ c: '重做同类题 10 道', d: true }], ver: [{ stage: 'V1', result: 'pending' }] },
  { n: 5, status: 'V2', node: NODE.sufficient, qType: '判断推理 · 充分必要条件', pri: 'P0', layer: '概念不清', cause: '把充分条件当成必要条件，逆命题与原命题混用', daysAgo: 6, actions: [{ c: '重画条件关系图', d: true }, { c: '讲给别人听一遍', d: false }], ver: [{ stage: 'V1', result: 'pass' }, { stage: 'V2', result: 'pending' }] },
  { n: 6, status: 'V3', node: NODE.law, qType: '常识判断 · 法律常识', pri: 'P2', layer: '审题偏差', cause: '题干问的是「不正确的是」，漏看「不」字', daysAgo: 9, actions: [{ c: '圈题干关键词', d: true }], ver: [{ stage: 'V1', result: 'pass' }, { stage: 'V2', result: 'pass' }, { stage: 'V3', result: 'pending' }] },
  { n: 7, status: 'REOPENED', node: NODE.figure, qType: '判断推理 · 图形推理', pri: 'P0', layer: '方法不会', cause: '没有按「同类元素数量」优先筛查，直接套对称性规律', daysAgo: 21, reopenCount: 2, round: 3, actions: [{ c: '整理图形推理规律清单', d: true }, { c: '限时做 20 道图形题', d: true }], ver: [{ stage: 'V1', result: 'fail' }, { stage: 'V2', result: 'pass' }, { stage: 'V3', result: 'pass' }] },
  { n: 8, status: 'CLOSED', node: NODE.ratio, qType: '资料分析 · 比重变化', pri: 'P1', layer: '计算失误', cause: '比重变化的百分点与百分数混淆，比较方向判反', daysAgo: 30, actions: [{ c: '重做同类题 10 道', d: true }, { c: '整理公式卡片', d: true }], ver: [{ stage: 'V1', result: 'pass' }, { stage: 'V2', result: 'pass' }, { stage: 'V3', result: 'pass' }], closed: true },
].map((t) => ({ ...t, id: `55555555-5555-4555-8555-55555555550${t.n}` }));

const ticketIds = TICKETS.map((t) => t.id);

const client = await pool.connect();
try {
  await client.query('BEGIN');

  // ---- 清理自己造的那批（外键依赖顺序：子先父后）----------------------------
  await client.query(`DELETE FROM verifications WHERE defect_ticket_id = ANY($1::uuid[])`, [ticketIds]);
  await client.query(`DELETE FROM actions       WHERE defect_ticket_id = ANY($1::uuid[])`, [ticketIds]);
  await client.query(`DELETE FROM defect_tickets WHERE id = ANY($1::uuid[])`, [ticketIds]);
  await client.query(`DELETE FROM knowledge_nodes WHERE subject_id = ANY($1::uuid[])`, [[SUBJECT_1, SUBJECT_2]]);
  await client.query(`DELETE FROM subjects      WHERE exam_profile_id = $1`, [PROFILE_ID]);
  await client.query(`DELETE FROM exam_profiles WHERE id = $1`, [PROFILE_ID]);
  await client.query(`DELETE FROM users         WHERE id = $1`, [USER_ID]);

  // ---- users ----------------------------------------------------------------
  await client.query(
    `INSERT INTO users (id, nickname, timezone) VALUES ($1, $2, 'Asia/Shanghai')`,
    [USER_ID, '联调演示用户'],
  );

  // ---- exam_profiles --------------------------------------------------------
  await client.query(
    `INSERT INTO exam_profiles (id, user_id, exam_type, target_label, target_score, exam_date, daily_minutes)
     VALUES ($1, $2, 'civil_service', '省考 · 行测', 75.00, CURRENT_DATE + 47, 90)`,
    [PROFILE_ID, USER_ID],
  );

  // ---- subjects -------------------------------------------------------------
  await client.query(
    `INSERT INTO subjects (id, exam_profile_id, name, kind) VALUES
       ($1, $3, '行测 · 判断推理与言语', 'objective'),
       ($2, $3, '行测 · 数量与资料', 'objective')`,
    [SUBJECT_1, SUBJECT_2, PROFILE_ID],
  );

  // ---- knowledge_nodes ------------------------------------------------------
  const nodes = [
    [NODE.logical, SUBJECT_1, '逻辑填空', 'high'],
    [NODE.analogy, SUBJECT_1, '类比推理', 'mid'],
    [NODE.sufficient, SUBJECT_1, '充分必要条件', 'high'],
    [NODE.law, SUBJECT_1, '法律常识', 'low'],
    [NODE.figure, SUBJECT_1, '图形推理', 'high'],
    [NODE.travel, SUBJECT_2, '行程问题', 'mid'],
    [NODE.rate, SUBJECT_2, '增长率比较', 'high'],
    [NODE.ratio, SUBJECT_2, '比重变化', 'mid'],
  ];
  for (const [id, subjectId, title, freq] of nodes) {
    await client.query(
      `INSERT INTO knowledge_nodes (id, subject_id, title, freq_tag) VALUES ($1, $2, $3, $4)`,
      [id, subjectId, title, freq],
    );
  }

  // ---- defect_tickets（每条单独 INSERT，绝不 UPDATE 连跳状态）----------------
  for (const t of TICKETS) {
    const createdAt = t.daysAgo > 0
      ? `now() - interval '${t.daysAgo} days'`
      : `now() - interval '${t.hoursAgo ?? 0} hours'`;
    await client.query(
      `INSERT INTO defect_tickets
         (id, user_id, exam_profile_id, knowledge_node_id, q_type, error_layer, error_cause,
          priority, status, reopen_count, verification_round, reopen_reason, created_at, closed_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::defect_status,$10,$11,$12,${createdAt},${t.closed ? 'now()' : 'NULL'})`,
      [
        t.id, USER_ID, PROFILE_ID, t.node, t.qType,
        t.layer, t.cause, t.pri, t.status,
        t.reopenCount ?? 0,
        t.round ?? 1,
        t.reopenCount ? '模考中同类题再次出错' : null,
      ],
    );

    for (const [i, a] of (t.actions ?? []).entries()) {
      await client.query(
        `INSERT INTO actions (id, defect_ticket_id, content, done)
         VALUES ($1, $2, $3, $4)`,
        // 36 位 uuid：前缀 24 + 单号 2 + 8 个 0 + 序号 2 = 36（早期版本用 slice(0,36)
        // 会把序号截掉，导致同单多条 action 主键撞车）
        [`66666666-6666-4666-8666-${String(t.n).padStart(2, '0')}00000000${String(i + 1).padStart(2, '0')}`, t.id, a.c, a.d],
      );
    }

    for (const [i, v] of (t.ver ?? []).entries()) {
      await client.query(
        `INSERT INTO verifications (id, defect_ticket_id, stage, round, verify_type, result, verified_at)
         VALUES ($1,$2,$3::verify_stage,$4,$5,$6::verify_result,$7)`,
        [
          // 同 action：前缀 24 + 单号 2 + 8 个 0 + 序号 2 = 36，不能 slice 截断
          `77777777-7777-4777-8777-${String(t.n).padStart(2, '0')}00000000${String(i + 1).padStart(2, '0')}`,
          t.id,
          v.stage,
          t.round ?? 1,
          v.stage === 'V3' ? 'timed_mock' : 'redo_hidden',
          v.result,
          v.result === 'pending' ? null : new Date(),
        ],
      );
    }
  }

  await client.query('COMMIT');
  console.log(`[seed] OK  用户 ${USER_ID}`);
  console.log(`[seed] 缺陷单 ${TICKETS.length} 条：` + TICKETS.map((t) => `${t.status}(#${t.n})`).join(' '));
} catch (err) {
  await client.query('ROLLBACK').catch(() => {});
  console.error(`[seed] 失败：${err.code || ''} ${err.message}`);
  if (err.detail) console.error(`[seed] detail: ${err.detail}`);
  if (err.hint) console.error(`[seed] hint: ${err.hint}`);
  process.exitCode = 1;
} finally {
  client.release();
  await pool.end();
}
