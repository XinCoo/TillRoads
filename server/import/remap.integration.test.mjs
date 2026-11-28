// server/import/remap.integration.test.mjs
// 题路 TillRoad · m34301：`.tillroad` 导入的「跨设备科目 / 考点 ID 重映射」真库集成测试
//
// 只有 RUN_PG_INTEGRATION=1 才跑（CI 会设），本机无 PG 时整文件跳过。
//
// 为什么必须连真库：
//   本轮要验证的是「导出快照里的旧 uuid → 目标库里真实存在的科目 / 考点 uuid」这层映射，
//   以及「同名科目已存在时不重复创建」——两者都依赖 subjects / knowledge_nodes 的真实
//   唯一约束与外键；fake 仓储只能伪造返回，伪造不出「第二次导入真的撞上了库里那行」。
//
// 覆盖任务书 A5 的三组场景：
//   1. 设备 A 有 2 科目 + 3 考点 + 5 题 → 导入用户 B（B 库里什么都没有）→ 全部重建并挂对位置
//   2. 同一用户重复导入 → 复用已有科目 / 考点，不重复创建
//   3. 文件里某题 subject_id 指向不存在的科目（脏数据）→ 该题 subject_id 置 null，不报错
//
// 注：这里不用 GET /export/questions 现导现导。真实导出会把该用户**全部**科目与全部题目
//   打进去（包括其它用例刚造的数据），断言就会随执行顺序漂移。改用「手工构造一份与导出
//   完全同形状的快照」，形状与 server/routes/export.mjs 的响应逐字段对齐，映射路径一字不差。

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { gzipSync } from 'node:zlib';

import { createPool } from '../db/pool.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { FULL_SCHEMA_SQL } from './../db/test_schema.mjs';
import { runImport } from '../routes/questions_import.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN
  ? {}
  : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

let pool;
let userA; // 导出方
let userB; // 接收方（跨设备）

/** 建一个用户 + 一个 active 考试目标，返回 { userId, profileId }。 */
async function createUser(nickname, examType = 'postgrad') {
  const c = await pool.connect();
  try {
    const u = await c.query(
      `INSERT INTO users (nickname, timezone, role) VALUES ($1, $2, $3) RETURNING id`,
      [nickname, 'Asia/Shanghai', 'student'],
    );
    const userId = u.rows[0].id;
    const p = await c.query(
      `INSERT INTO exam_profiles (user_id, exam_type, target_label, exam_date, daily_minutes)
       VALUES ($1, $2, $3, $4, $5) RETURNING id`,
      [userId, examType, nickname, '2027-12-20', 120],
    );
    return { userId, profileId: p.rows[0].id };
  } finally {
    c.release();
  }
}

/** 删干净一个用户的全部数据（含科目 / 考点 / 题 / 批次），用于用例自清理。 */
async function dropUser(userId) {
  const c = await pool.connect();
  try {
    await c.query(`DELETE FROM questions WHERE owner_user_id = $1`, [userId]);
    await c.query(
      `DELETE FROM assets
        WHERE owner_type = 'question'
          AND owner_id NOT IN (SELECT id FROM questions)`,
    );
    await c.query(`DELETE FROM import_batches WHERE user_id = $1`, [userId]);
    // knowledge_nodes 随 subjects 级联（ON DELETE CASCADE）。
    await c.query(
      `DELETE FROM subjects
        WHERE exam_profile_id IN (SELECT id FROM exam_profiles WHERE user_id = $1)`,
      [userId],
    );
    await c.query(`DELETE FROM exam_profiles WHERE user_id = $1`, [userId]);
    await c.query(`DELETE FROM users WHERE id = $1`, [userId]);
  } finally {
    c.release();
  }
}

/** 把快照按 `.tillroad` 的真实形态（gzip 后的 JSON）包成导入请求体。 */
function tillroadBody(snapshot, filename = 'cross-device.tillroad') {
  return {
    filename,
    // mime 故意用 octet-stream：extract.mjs 靠 gzip magic（0x1f 0x8b）判定，
    // 不依赖扩展名与 mime —— 正好顺带验证这条容错路径。
    mime: 'application/octet-stream',
    content_base64: gzipSync(Buffer.from(JSON.stringify(snapshot), 'utf8')).toString('base64'),
  };
}

/** 列某用户默认目标下的科目（按名字排序，便于断言）。 */
async function listSubjects(userId) {
  const c = await pool.connect();
  try {
    const r = await c.query(
      `SELECT s.id, s.name
         FROM subjects s
         JOIN exam_profiles p ON p.id = s.exam_profile_id
        WHERE p.user_id = $1 AND p.deleted_at IS NULL AND s.deleted_at IS NULL
        ORDER BY s.name`,
      [userId],
    );
    return r.rows;
  } finally {
    c.release();
  }
}

/** 列某用户全部题目的归属（stem → subject_id / knowledge_node_id）。 */
async function listOwnQuestions(userId) {
  const c = await pool.connect();
  try {
    const r = await c.query(
      `SELECT stem, subject_id, knowledge_node_id
         FROM questions
        WHERE owner_user_id = $1 AND deleted_at IS NULL
        ORDER BY stem`,
      [userId],
    );
    return r.rows;
  } finally {
    c.release();
  }
}

/** 取某科目下的考点（id/title/parent_id）。 */
async function listNodes(subjectId) {
  const c = await pool.connect();
  try {
    const r = await c.query(
      `SELECT id, title, parent_id FROM knowledge_nodes
        WHERE subject_id = $1 AND deleted_at IS NULL`,
      [subjectId],
    );
    return r.rows;
  } finally {
    c.release();
  }
}

/**
 * 构造一份与 `GET /export/questions` 同形状的快照。
 *
 * 五个旧 uuid 全部随机生成 —— 这正是「原设备的 uuid，目标库里不存在」的真实情形。
 */
function buildSnapshot() {
  const oldSubject1 = randomUUID();
  const oldSubject2 = randomUUID();
  const oldNodeRoot = randomUUID(); // 一级考点
  const oldNodeChild = randomUUID(); // 二级考点，parent = oldNodeRoot
  const oldNodeOther = randomUUID(); // 另一个科目下的一级考点

  const snapshot = {
    version: '1.0',
    exported_at: new Date().toISOString(),
    user: { id: userA.userId, nickname: '导出方' },
    subjects: [
      { id: oldSubject1, name: '重映射行测', kind: 'objective', exam_profile_id: userA.profileId },
      { id: oldSubject2, name: '重映射公基', kind: 'objective', exam_profile_id: userA.profileId },
    ],
    knowledge_nodes: [
      {
        id: oldNodeRoot,
        subject_id: oldSubject1,
        parent_id: null,
        title: '资料分析',
        freq_tag: 'high',
        weight_to_target: 0.5,
      },
      {
        id: oldNodeChild,
        subject_id: oldSubject1,
        parent_id: oldNodeRoot,
        title: '增长率',
        freq_tag: null,
        weight_to_target: null,
      },
      {
        id: oldNodeOther,
        subject_id: oldSubject2,
        parent_id: null,
        title: '宪法',
        freq_tag: 'mid',
        weight_to_target: 0.25,
      },
    ],
    questions: [
      {
        id: randomUUID(),
        type: 'choice',
        stem: '重映射第 1 题：资料分析根节点下的单选题',
        options: [
          { key: 'A', text: '甲' },
          { key: 'B', text: '乙' },
        ],
        answer: 'A',
        analysis: '',
        difficulty: null,
        tags: [],
        is_subjective: false,
        subject_id: oldSubject1,
        knowledge_node_id: oldNodeRoot,
      },
      {
        id: randomUUID(),
        type: 'judge',
        stem: '重映射第 2 题：二级考点下的判断题',
        options: null,
        answer: '正确',
        analysis: '解析略',
        difficulty: null,
        tags: [],
        is_subjective: false,
        subject_id: oldSubject1,
        knowledge_node_id: oldNodeChild,
      },
      {
        id: randomUUID(),
        type: 'fill',
        stem: '重映射第 3 题：同科目但不指定考点',
        options: null,
        answer: '北京',
        analysis: '',
        difficulty: null,
        tags: [],
        is_subjective: false,
        subject_id: oldSubject1,
        knowledge_node_id: null,
      },
      {
        id: randomUUID(),
        type: 'judge',
        stem: '重映射第 4 题：另一个科目下的判断题',
        options: null,
        answer: '错误',
        analysis: '',
        difficulty: null,
        tags: [],
        is_subjective: false,
        subject_id: oldSubject2,
        knowledge_node_id: oldNodeOther,
      },
      {
        id: randomUUID(),
        type: 'short_answer',
        stem: '重映射第 5 题：公基科目的简答题',
        options: null,
        answer: '依法治国',
        analysis: '',
        difficulty: null,
        tags: [],
        is_subjective: true,
        subject_id: oldSubject2,
        knowledge_node_id: null,
      },
    ],
  };

  return { snapshot, oldSubject1, oldSubject2, oldNodeRoot, oldNodeChild, oldNodeOther };
}

before(async () => {
  if (!RUN) return;

  pool = createPool();
  try {
    await withTransaction(pool, async (client) => {
      await client.query(FULL_SCHEMA_SQL);
    });
  } catch (err) {
    throw new Error(`before: 执行 schema.sql 失败（已回滚）—— ${err.message}`);
  }

  userA = await createUser('跨设备导出方');
  userB = await createUser('跨设备接收方');
});

after(async () => {
  if (!RUN || !pool) return;

  let cleanupFailure = null;
  try {
    // 本文件只造 users / exam_profiles / subjects / knowledge_nodes / questions /
    // import_batches，按外键顺序逐个用户删干净即可。
    if (userB) await dropUser(userB.userId);
    if (userA) await dropUser(userA.userId);
  } catch (cleanupError) {
    cleanupFailure = cleanupError;
  } finally {
    // 清理抛错也不能跳过关池，否则事件循环有活 handle，node:test 进程退不出去（CI 会挂）。
    await pool.end();
  }
  if (cleanupFailure) {
    throw new Error(
      `after(): 清理数据失败（前置测试已跑完，但库中可能残留测试数据）: ${cleanupFailure.message}`,
    );
  }
});

// ---------------------------------------------------------------------------
// 1) 跨设备：A 的快照导入 B → 科目 / 考点 / 题目全部重建，且挂在正确位置
// ---------------------------------------------------------------------------
test('跨设备：A 的 2 科目 + 3 考点 + 5 题导入 B → 全部重建并挂对位置', skipOpt, async () => {
  const { snapshot } = buildSnapshot();

  // 前置事实：B 库里这时什么都没有，所以「导入后 B 有 2 科目」不存在歧义。
  assert.equal((await listSubjects(userB.userId)).length, 0, 'B 初始不应有科目');

  const result = await runImport(pool, tillroadBody(snapshot), userB.userId);

  assert.equal(result.imported.new, 5, `5 道题应全部入库，实际 ${JSON.stringify(result.imported)}`);
  assert.equal(result.duplicates.skipped, 0);

  // 映射统计：全部是「新建」（B 库里没有同名科目 / 同路径考点）。
  const remap = result.remap_result;
  assert.equal(remap.subjects_created, 2, `应新建 2 个科目，实际 ${remap.subjects_created}`);
  assert.equal(remap.subjects_mapped, 0);
  assert.equal(remap.nodes_created, 3, `应新建 3 个考点，实际 ${remap.nodes_created}`);
  assert.equal(remap.nodes_mapped, 0);
  assert.equal(remap.questions_without_subject, 0);
  assert.deepEqual(
    [...remap.created_subject_names].sort(),
    ['重映射公基', '重映射行测'],
    `新建科目名不符：${JSON.stringify(remap.created_subject_names)}`,
  );

  // B 的科目：正好两个，名字与文件一致，且挂在 B 自己的目标下。
  const bSubjects = await listSubjects(userB.userId);
  assert.deepEqual(bSubjects.map((s) => s.name), ['重映射公基', '重映射行测']);
  const byName = new Map(bSubjects.map((s) => [s.name, s.id]));

  // B 的考点：行测下两级（资料分析 → 增长率），公基下一级（宪法）。
  const xingceNodes = await listNodes(byName.get('重映射行测'));
  assert.equal(xingceNodes.length, 2, `行测应重建 2 个考点，实际 ${xingceNodes.length}`);
  const gongjiNodes = await listNodes(byName.get('重映射公基'));
  assert.equal(gongjiNodes.length, 1, `公基应重建 1 个考点，实际 ${gongjiNodes.length}`);

  const root = xingceNodes.find((n) => n.title === '资料分析');
  const child = xingceNodes.find((n) => n.title === '增长率');
  assert.ok(root && child, `考点标题不符：${JSON.stringify(xingceNodes.map((n) => n.title))}`);
  assert.equal(root.parent_id, null, '资料分析应是根节点');
  assert.equal(child.parent_id, root.id, '增长率应挂在资料分析下面（层级不能被压平）');

  // B 的题目：5 道全部挂到**新**科目上，且考点映射逐题正确。
  const bQuestions = await listOwnQuestions(userB.userId);
  assert.equal(bQuestions.length, 5);
  const qByStem = new Map(bQuestions.map((q) => [q.stem, q]));

  const q1 = qByStem.get('重映射第 1 题：资料分析根节点下的单选题');
  const q2 = qByStem.get('重映射第 2 题：二级考点下的判断题');
  const q3 = qByStem.get('重映射第 3 题：同科目但不指定考点');
  const q4 = qByStem.get('重映射第 4 题：另一个科目下的判断题');
  const q5 = qByStem.get('重映射第 5 题：公基科目的简答题');
  for (const q of [q1, q2, q3, q4, q5]) assert.ok(q, '5 道题都应存在');

  assert.equal(q1.subject_id, byName.get('重映射行测'));
  assert.equal(q1.knowledge_node_id, root.id);
  assert.equal(q2.subject_id, byName.get('重映射行测'));
  assert.equal(q2.knowledge_node_id, child.id);
  assert.equal(q3.subject_id, byName.get('重映射行测'));
  assert.equal(q3.knowledge_node_id, null, '文件里没给考点就应保持 null');
  assert.equal(q4.subject_id, byName.get('重映射公基'));
  assert.equal(q4.knowledge_node_id, gongjiNodes[0].id);
  assert.equal(q5.subject_id, byName.get('重映射公基'));

  await dropUser(userB.userId);
  // dropUser 之外，跨设备用例还要把 A 的这份快照数据留着吗？
  // 不留：A 在本用例里并没有写入任何东西（导入的 owner 是 B），所以无需清理 A。
});

// ---------------------------------------------------------------------------
// 2) 同一用户重复导入 → 科目 / 考点全部复用，不重复创建
// ---------------------------------------------------------------------------
test('重复导入：同一份快照导两次，第二次不新建任何科目与考点', skipOpt, async () => {
  const { snapshot } = buildSnapshot();

  const first = await runImport(pool, tillroadBody(snapshot), userA.userId);
  assert.equal(first.imported.new, 5, `首次导入应新增 5 题，实际 ${JSON.stringify(first.imported)}`);
  assert.equal(first.remap_result.subjects_created, 2);
  assert.equal(first.remap_result.nodes_created, 3);

  const subjectsAfterFirst = await listSubjects(userA.userId);
  assert.equal(subjectsAfterFirst.length, 2);
  const byName = new Map(subjectsAfterFirst.map((s) => [s.name, s.id]));
  const xingceNodes = await listNodes(byName.get('重映射行测'));
  assert.equal(xingceNodes.length, 2);

  const second = await runImport(pool, tillroadBody(snapshot), userA.userId);
  // 题全是同 hash → 默认 skip，一道没进。
  assert.equal(second.imported.new, 0, '同一份文件第二次不应新增题');
  assert.equal(second.duplicates.skipped, 5, `5 道题都应判重跳过，实际 ${second.duplicates.skipped}`);
  // 科目 / 考点全部命中已有，不新建。
  assert.equal(second.remap_result.subjects_created, 0, '不应重复建科目');
  assert.equal(second.remap_result.subjects_mapped, 2, '两个科目都应命中已有');
  assert.equal(second.remap_result.nodes_created, 0, '不应重复建考点');
  assert.equal(second.remap_result.nodes_mapped, 3, '三个考点都应命中已有');

  // 库里真的没有多出来：科目仍是 2 个，行测下考点仍是 2 个。
  assert.equal((await listSubjects(userA.userId)).length, 2, '科目数不能变');
  assert.equal((await listNodes(byName.get('重映射行测'))).length, 2, '考点数不能变');
});

// ---------------------------------------------------------------------------
// 3) 脏数据：题的 subject_id 在文件 subjects 里找不到 → 置 null，不报错
// ---------------------------------------------------------------------------
test('脏数据：subject_id 映射不到时该题 subject_id 置 null，导入仍成功', skipOpt, async () => {
  const oldSubject = randomUUID();
  const ghostSubject = randomUUID(); // 文件里根本没声明这个科目

  const snapshot = {
    version: '1.0',
    exported_at: new Date().toISOString(),
    user: { id: userA.userId, nickname: '导出方' },
    subjects: [{ id: oldSubject, name: '脏数据科目', kind: 'objective', exam_profile_id: userA.profileId }],
    knowledge_nodes: [],
    questions: [
      {
        id: randomUUID(),
        type: 'judge',
        stem: '脏数据第 1 题：科目能映射',
        options: null,
        answer: '正确',
        analysis: '',
        difficulty: null,
        tags: [],
        is_subjective: false,
        subject_id: oldSubject,
        knowledge_node_id: null,
      },
      {
        id: randomUUID(),
        type: 'judge',
        stem: '脏数据第 2 题：科目 uuid 在文件里查不到',
        options: null,
        answer: '错误',
        analysis: '',
        difficulty: null,
        tags: [],
        is_subjective: false,
        subject_id: ghostSubject,
        knowledge_node_id: null,
      },
    ],
  };

  const result = await runImport(pool, tillroadBody(snapshot), userA.userId);

  assert.equal(result.imported.new, 2, '两道题都应入库（脏数据不能被整批拒绝）');
  assert.equal(result.remap_result.subjects_created, 1);
  assert.equal(
    result.remap_result.questions_without_subject,
    1,
    `应统计到 1 道题没挂上科目，实际 ${result.remap_result.questions_without_subject}`,
  );

  const rows = await listOwnQuestions(userA.userId);
  const byStem = new Map(rows.map((q) => [q.stem, q]));
  const ok = byStem.get('脏数据第 1 题：科目能映射');
  const dirty = byStem.get('脏数据第 2 题：科目 uuid 在文件里查不到');
  assert.ok(ok && dirty, '两道题都应存在');
  const subjects = await listSubjects(userA.userId);
  const dirtySubject = subjects.find((s) => s.name === '脏数据科目');
  assert.ok(dirtySubject, '文件里声明的科目应被建出来');
  assert.equal(ok.subject_id, dirtySubject.id, '能映射的题要挂上');
  assert.equal(dirty.subject_id, null, '映射不到的题 subject_id 必须置 null');
});
