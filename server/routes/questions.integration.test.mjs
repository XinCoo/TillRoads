// server/routes/questions.integration.test.mjs
// 题路 TillRoad · m17431：题库多用户隔离（owner_user_id）真实 PG 集成测试
//
// 只有 RUN_PG_INTEGRATION=1 才跑（CI 会设），本机无 PG 时整文件跳过。
//
// 覆盖任务书 A5 的四步 + 组卷隔离：
//   1. 用户 A 导入 3 题 -> questions.owner_user_id = A
//   2. 用户 B 导入同样的 3 题 -> 不判重，B 有自己的一份
//   3. 用户 A 再导入同样 3 题 -> 判重，duplicates = 3
//   4. 用户 B 组卷抽题 -> 只抽到 B 的题 + 公共题，抽不到 A 的
//   5. GET /questions 的可见性：A 只看得到自己的 + 公共的
//
// 为什么必须连真库：
//   「A 导入过、B 再导入不判重」这条依赖 owner_user_id 真的写进了 PG 列，
//   fake 仓储伪造不出「第一次真的写进了 owner_user_id 列、第二次真的按列查重」。

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { createPool } from '../db/pool.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { createApp } from '../index.mjs';
import { FULL_SCHEMA_SQL } from '../db/test_schema.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN
  ? {}
  : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const FIXTURES = join(ROOT, 'tests', 'fixtures', 'questions');

const TOKEN_A = 'tk_owner_a';
const TOKEN_B = 'tk_owner_b';

let pool;
let app;
let base;
let seed; // { userA, userB, profileA, profileB, subjectA, subjectB }

async function req(method, path, body, token) {
  const init = { method };
  if (body !== undefined) {
    init.headers = { 'Content-Type': 'application/json' };
    init.body = JSON.stringify(body);
  }
  if (token) init.headers = { ...(init.headers ?? {}), Authorization: `Bearer ${token}` };
  const res = await fetch(base + path, init);
  const text = await res.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  return { status: res.status, data };
}

/** 读样本文件成导入用 body。 */
function fileBody(name, extra = {}) {
  const buffer = readFileSync(join(FIXTURES, name));
  return {
    filename: name,
    mime: 'text/markdown',
    content_base64: buffer.toString('base64'),
    ...extra,
  };
}

/** 造一个用户 + 考试目标 + 科目，返回 id。 */
async function makeUser(c, nickname) {
  const u = await c.query(
    `INSERT INTO users (nickname, timezone, role) VALUES ($1, 'Asia/Shanghai', 'student') RETURNING id`,
    [nickname],
  );
  const userId = u.rows[0].id;
  const p = await c.query(
    `INSERT INTO exam_profiles (user_id, exam_type, target_label, exam_date, daily_minutes)
     VALUES ($1, 'postgrad', $2, '2027-12-20', 120) RETURNING id`,
    [userId, `${nickname}目标`],
  );
  const profileId = p.rows[0].id;
  const s = await c.query(
    `INSERT INTO subjects (exam_profile_id, name, kind) VALUES ($1, $2, 'objective') RETURNING id`,
    [profileId, `${nickname}科目`],
  );
  return { userId, profileId, subjectId: s.rows[0].id };
}

before(async () => {
  if (!RUN) return;

  pool = createPool();
  try {
    await withTransaction(pool, async (client) => {
      await client.query(FULL_SCHEMA_SQL);
    });
  } catch (err) {
    throw new Error(`before: 执行 schema 失败（已回滚）—— ${err.message}`);
  }

  const c = await pool.connect();
  try {
    const a = await makeUser(c, '题库隔离用户A');
    const b = await makeUser(c, '题库隔离用户B');
    seed = {
      userA: a.userId,
      userB: b.userId,
      profileA: a.profileId,
      profileB: b.profileId,
      subjectA: a.subjectId,
      subjectB: b.subjectId,
    };
  } finally {
    c.release();
  }

  // TOKENS 在 createApp 时读取，必须先设。
  process.env.TOKENS = `${TOKEN_A}:${seed.userA},${TOKEN_B}:${seed.userB}`;
  app = createApp({ pool });
  await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${app.server.address().port}`;
});

after(async () => {
  if (!RUN || !app) return;

  const c = await pool.connect();
  let cleanupFailure = null;
  try {
    // 删题（owner_user_id 指向 users，先删子表再删父表）
    // 删题：既删 A/B 名下的私有题，也要删掉挂在他们科目下的公共题
    // （第 4 个用例往 seed.subjectB 里插了 2 道 owner_user_id IS NULL 的题，
    //   只按 owner 删会漏掉它们，随后删 subjects 直接 23503 questions_subject_id_fkey）。
    await c.query(
      `DELETE FROM questions
        WHERE owner_user_id IN ($1, $2)
           OR subject_id IN (
                SELECT s.id FROM subjects s
                  JOIN exam_profiles p ON p.id = s.exam_profile_id
                 WHERE p.user_id IN ($1, $2))`,
      [seed.userA, seed.userB],
    );
    // m31124：本用例会用 A 的 token 调 POST /questions/import，导入管线现在会在
    //   import_batches 里建一行（user_id 外键、无级联），必须在删 users 之前清掉，
    //   否则收尾报 import_batches_user_id_fkey（23503）。
    await c.query(`DELETE FROM import_batches WHERE user_id IN ($1, $2)`, [
      seed.userA,
      seed.userB,
    ]);
    // 模考记录引用 exam_profiles（mock_exams_exam_profile_id_fkey），必须在删 exam_profiles
    // 之前删掉。第 4 个用例 POST /mock-exams 建了 1 条，漏掉它 after() 会 23503。
    await c.query(
      `DELETE FROM mock_exams WHERE exam_profile_id IN (SELECT id FROM exam_profiles WHERE user_id IN ($1, $2))`,
      [seed.userA, seed.userB],
    );
    await c.query(
      `DELETE FROM subjects WHERE exam_profile_id IN (SELECT id FROM exam_profiles WHERE user_id IN ($1, $2))`,
      [seed.userA, seed.userB],
    );
    await c.query(`DELETE FROM exam_profiles WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
    await c.query(`DELETE FROM users WHERE id IN ($1, $2)`, [seed.userA, seed.userB]);
  } catch (cleanupError) {
    cleanupFailure = cleanupError;
  } finally {
    c.release();
  }

  try {
    await new Promise((resolve) => app.close(resolve));
  } finally {
    await pool.end();
    delete process.env.TOKENS;
  }
  if (cleanupFailure) {
    throw new Error(`after(): 清理数据失败：${cleanupFailure.message}`);
  }
});

// ---------------------------------------------------------------------------
// 1) A 导入 -> owner_user_id = A
// ---------------------------------------------------------------------------
test('m17431：用户 A 导入的题 owner_user_id = A', skipOpt, async () => {
  const body = fileBody('sample-01-markdown.md', { subject_id: seed.subjectA });
  const r = await req('POST', '/questions/import', body, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported.new, 12, `A 应导入 12 题，实际 ${r.data.imported.new}`);
  assert.equal(r.data.duplicates.skipped, 0, 'A 首次导入不应有重复');

  const c = await pool.connect();
  try {
    const rows = await c.query(
      `SELECT owner_user_id, count(*)::int AS n FROM questions
        WHERE subject_id = $1 AND deleted_at IS NULL GROUP BY owner_user_id`,
      [seed.subjectA],
    );
    assert.equal(rows.rows.length, 1, '该科目下应只有一种归属');
    assert.equal(rows.rows[0].owner_user_id, seed.userA, 'A 导入的题必须归属 A');
    assert.equal(rows.rows[0].n, 12);
  } finally {
    c.release();
  }
});

// ---------------------------------------------------------------------------
// 2) B 导入同样的文件 -> 不判重，B 有自己的一份
// ---------------------------------------------------------------------------
test('m17431：用户 B 导入同样 3 题不判重（owner 维度隔离）', skipOpt, async () => {
  const body = fileBody('sample-01-markdown.md', { subject_id: seed.subjectB });
  const r = await req('POST', '/questions/import', body, TOKEN_B);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported.new, 12, `B 应导入 12 题（与 A 同内容但不同 owner），实际 ${r.data.imported.new}`);
  assert.equal(r.data.duplicates.skipped, 0, 'B 不该被判重');

  const c = await pool.connect();
  try {
    const rows = await c.query(
      `SELECT owner_user_id, count(*)::int AS n FROM questions
        WHERE subject_id = $1 AND deleted_at IS NULL GROUP BY owner_user_id`,
      [seed.subjectB],
    );
    assert.equal(rows.rows.length, 1);
    assert.equal(rows.rows[0].owner_user_id, seed.userB, 'B 导入的题必须归属 B');
    assert.equal(rows.rows[0].n, 12);

    // 同样的 content_hash 在两个 owner 下各有一份
    const both = await c.query(
      `SELECT content_hash, count(DISTINCT owner_user_id)::int AS owners
         FROM questions WHERE owner_user_id IN ($1, $2) AND deleted_at IS NULL
        GROUP BY content_hash HAVING count(DISTINCT owner_user_id) = 2`,
      [seed.userA, seed.userB],
    );
    assert.equal(both.rows.length, 12, '12 个 hash 都应在 A/B 下各存一份');
  } finally {
    c.release();
  }
});

// ---------------------------------------------------------------------------
// 3) A 再导入同样 3 题 -> 判重，duplicates = 12
// ---------------------------------------------------------------------------
test('m17431：用户 A 二次导入同样内容判重（duplicates = 12）', skipOpt, async () => {
  const body = fileBody('sample-01-markdown.md', { subject_id: seed.subjectA });
  const r = await req('POST', '/questions/import', body, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported.new, 0, 'A 二次导入不应新增');
  assert.equal(r.data.duplicates.skipped, 12, 'A 二次导入应全部判重');
});

// ---------------------------------------------------------------------------
// 4) 组卷隔离：B 组卷抽不到 A 的题
// ---------------------------------------------------------------------------
test('m17431：组卷只抽「公共题 + 自己的题」，抽不到别人的私有题', skipOpt, async () => {
  const c = await pool.connect();
  try {
    // 给 B 的科目补 2 道公共题（owner_user_id IS NULL）
    await c.query(
      `INSERT INTO questions (source, subject_id, type, stem, content_hash, is_subjective)
       VALUES ('manual', $1, 'choice', '公共题一', 'hash-public-1', false),
              ('manual', $1, 'choice', '公共题二', 'hash-public-2', false)`,
      [seed.subjectB],
    );
  } finally {
    c.release();
  }

  const r = await req(
    'POST',
    '/mock-exams',
    {
      exam_profile_id: seed.profileB,
      mode: 'full',
      subject_id: seed.subjectB,
      question_count: 5,
      duration_limit_ms: 30 * 60 * 1000,
    },
    TOKEN_B,
  );
  assert.equal(r.status, 201, JSON.stringify(r.data));

  const stems = (r.data.questions ?? []).map((q) => q.stem);
  assert.equal(stems.length, 5, '应抽到 5 题');
  // B 的 12 道私有题 + 2 道公共题 = 14 可用，够抽 5 题
  const c2 = await pool.connect();
  try {
    const owned = await c2.query(
      `SELECT count(*)::int AS n FROM questions
        WHERE subject_id = $1 AND owner_user_id = $2 AND deleted_at IS NULL`,
      [seed.subjectB, seed.userA],
    );
    assert.equal(owned.rows[0].n, 0, 'A 的题不应该在 B 的科目下');
  } finally {
    c2.release();
  }
});

// ---------------------------------------------------------------------------
// 5) GET /questions 的可见性
// ---------------------------------------------------------------------------
test('m17431：GET /questions 只返回「公共题 + 自己的题」', skipOpt, async () => {
  const rA = await req('GET', '/questions?limit=50', undefined, TOKEN_A);
  assert.equal(rA.status, 200, JSON.stringify(rA.data));
  const ownersA = new Set(rA.data.items.map((q) => q.owner_user_id));
  assert.ok(
    [...ownersA].every((o) => o === seed.userA || o === null),
    `A 只能看到自己的题和公共题，实际看到 ${JSON.stringify([...ownersA])}`,
  );

  const rB = await req('GET', '/questions?limit=50', undefined, TOKEN_B);
  assert.equal(rB.status, 200, JSON.stringify(rB.data));
  const ownersB = new Set(rB.data.items.map((q) => q.owner_user_id));
  assert.ok(
    [...ownersB].every((o) => o === seed.userB || o === null),
    `B 只能看到自己的题和公共题，实际看到 ${JSON.stringify([...ownersB])}`,
  );

  // A 的私有题不出现在 B 的列表里。
  // 注意：公共题（owner_user_id IS NULL）本来就会同时出现在两边，不能算泄漏——
  // 第 4 个用例就往 B 的科目里插了 2 道公共题，按「id 交集」直接比会误判 2 条。
  const aPrivateIds = new Set(
    rA.data.items.filter((q) => q.owner_user_id === seed.userA).map((q) => q.id),
  );
  assert.equal(aPrivateIds.size, 12, `A 应有 12 道私有题，实际 ${aPrivateIds.size}`);
  const leaked = rB.data.items.filter((q) => aPrivateIds.has(q.id));
  assert.equal(leaked.length, 0, 'B 的列表里不应出现 A 的私有题');
});

// ---------------------------------------------------------------------------
// 6) m21780：GET /questions 的 q / knowledge_node_id 过滤
// ---------------------------------------------------------------------------
test('m21780：GET /questions 支持 q 与 knowledge_node_id 过滤', skipOpt, async () => {
  const c = await pool.connect();
  let nodeHit;
  let nodeMiss;
  try {
    const mkNode = async (title) => {
      const r = await c.query(
        `INSERT INTO knowledge_nodes (subject_id, title, freq_tag)
         VALUES ($1, $2, 'high') RETURNING id`,
        [seed.subjectA, title],
      );
      return r.rows[0].id;
    };
    nodeHit = await mkNode('马克思主义哲学');
    nodeMiss = await mkNode('逻辑填空');

    // 3 道含「马克思主义」（2 道挂 nodeHit、1 道挂 nodeMiss），2 道不含。
    // content_hash 必须唯一，否则撞 dedupe 的唯一索引（按 owner 分域）。
    await c.query(
      `INSERT INTO questions (source, subject_id, knowledge_node_id, type, stem, content_hash, owner_user_id, is_subjective)
       VALUES ('manual', $1, $2, 'choice', '马克思主义哲学的直接理论来源是（ ）', 'hash-q-1', $4, false),
              ('manual', $1, $2, 'choice', '马克思主义政治经济学的核心是（ ）', 'hash-q-2', $4, false),
              ('manual', $1, $3, 'choice', '马克思主义中国化的第一次飞跃（ ）', 'hash-q-3', $4, false),
              ('manual', $1, $3, 'choice', '逻辑填空：望洋兴叹的意思（ ）', 'hash-q-4', $4, false),
              ('manual', $1, $2, 'choice', '图形推理的对称轴数量（ ）', 'hash-q-5', $4, false)`,
      [seed.subjectA, nodeHit, nodeMiss, seed.userA],
    );
  } finally {
    c.release();
  }

  // ═══ 断言口径：用「相对基线」，不用绝对条数 ═══
  // 前 5 个用例已把 sample-01-markdown.md 的 12 道题导入 subjectA，其中就含
  // 「马克思主义」字样的题；所以「搜马克思主义 = 3 条」这种绝对断言会随种子
  // 文件内容变化而脆断。正确做法是先取基线，再断言「过滤结果 = 基线里满足
  // 条件的那些」，这样既验证了过滤真的生效，又不依赖前置用例的副作用。
  const rBase = await req('GET', '/questions?limit=200', undefined, TOKEN_A);
  assert.equal(rBase.status, 200, JSON.stringify(rBase.data));
  const baseItems = rBase.data.items;
  const baseQ = baseItems.filter((it) => String(it.stem).includes('马克思主义'));

  // 1) 只搜关键字
  const qUrl = encodeURIComponent('马克思主义');
  const rQ = await req('GET', `/questions?q=${qUrl}&limit=200`, undefined, TOKEN_A);
  assert.equal(rQ.status, 200, JSON.stringify(rQ.data));
  assert.equal(
    rQ.data.items.length,
    baseQ.length,
    `q 过滤结果应等于基线中含关键字的条数（基线 ${baseQ.length}），实际 ${rQ.data.items.length}`,
  );
  for (const item of rQ.data.items) {
    assert.ok(String(item.stem).includes('马克思主义'), `不应出现不含关键字的题：${item.stem}`);
  }

  // 2) 只按考点过滤（nodeHit 是本用例新建的考点，只有本轮 3 道新题挂它，
  //    所以这里可以安全用绝对条数：2 道含关键字 + 1 道不含）
  const rNode = await req('GET', `/questions?knowledge_node_id=${nodeHit}&limit=200`, undefined, TOKEN_A);
  assert.equal(rNode.status, 200, JSON.stringify(rNode.data));
  assert.equal(rNode.data.items.length, 3, `nodeHit 下应 3 条，实际 ${rNode.data.items.length}`);
  for (const item of rNode.data.items) {
    assert.equal(item.knowledge_node_id, nodeHit, 'knowledge_node_id 过滤失效');
  }
  // 反过来：nodeMiss 只能命中那 2 道
  const rMiss = await req('GET', `/questions?knowledge_node_id=${nodeMiss}&limit=200`, undefined, TOKEN_A);
  assert.equal(rMiss.status, 200, JSON.stringify(rMiss.data));
  assert.equal(rMiss.data.items.length, 2, `nodeMiss 下应 2 条，实际 ${rMiss.data.items.length}`);

  // 3) 两个参数组合：马克思主义 + nodeHit → 2 条
  const rBoth = await req(
    'GET',
    `/questions?q=${qUrl}&knowledge_node_id=${nodeHit}&limit=200`,
    undefined,
    TOKEN_A,
  );
  assert.equal(rBoth.status, 200, JSON.stringify(rBoth.data));
  assert.equal(rBoth.data.items.length, 2, `组合过滤应 2 条，实际 ${rBoth.data.items.length}`);

  // 4) 空白 q 视同没传，返回全量（与基线一致）
  const rAll = await req('GET', '/questions?q=%20%20&limit=200', undefined, TOKEN_A);
  assert.equal(rAll.status, 200, JSON.stringify(rAll.data));
  assert.equal(
    rAll.data.items.length,
    baseItems.length,
    '空白 q 不应该过滤，应与基线全量一致',
  );

  // 5) 关键字按字面量匹配：搜「100%」不能因为 % 未转义而变成通配符
  const rPct = await req('GET', `/questions?q=${encodeURIComponent('100%')}&limit=200`, undefined, TOKEN_A);
  assert.equal(rPct.status, 200, JSON.stringify(rPct.data));
  assert.equal(rPct.data.items.length, 0, '`%` 未被转义，LIKE 元字符泄漏成了通配符');

  // 6) 底线：过滤结果里绝不能出现别人的私有题（回归 owner 隔离没被新参数破坏）
  for (const item of [...rQ.data.items, ...rNode.data.items, ...rBoth.data.items]) {
    assert.ok(
      item.owner_user_id === null || item.owner_user_id === seed.userA,
      `过滤结果里出现了不属于自己的题：owner=${item.owner_user_id}`,
    );
  }
});

// ---------------------------------------------------------------------------
// 6) m23700（FE-02）：手动建题 / 编辑 / 删除
//    为什么必须连真库：查重命中 409、乐观锁 409、owner 门禁 404 这三件事
//    依赖 questions 表真的写了 owner_user_id / version / deleted_at，fake 仓储伪造不出。
// ---------------------------------------------------------------------------
test('m23700：POST /questions 手动建题 -> 201，source=manual、owner=自己、version=1', skipOpt, async () => {
  const r = await req(
    'POST',
    '/questions',
    {
      subject_id: seed.subjectA,
      type: 'choice',
      stem: '手动建题：下列说法正确的是哪一个？',
      // 两种选项写法都要能进：字符串形式会被归一成 {key,text}
      options: ['A. 甲说法', 'B、乙说法', 'C 丙说法'],
      answer: 'A',
      analysis: '乙、丙两说法与题干条件矛盾。',
      difficulty: 'medium',
      tags: ['手动', '  ', '测试'],
      is_subjective: false,
    },
    TOKEN_A,
  );

  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.source, 'manual', 'source 必须被强制为 manual');
  assert.equal(r.data.owner_user_id, seed.userA, 'owner 必须取自 token');
  assert.equal(r.data.version, 1);
  assert.equal(r.data.subject_id, seed.subjectA);
  assert.equal(r.data.answer, 'A');
  assert.equal(r.data.analysis, '乙、丙两说法与题干条件矛盾。');
  assert.equal(r.data.difficulty, 'medium');
  assert.equal(r.data.is_subjective, false);
  assert.deepEqual(r.data.tags, ['手动', '测试'], 'tags 应剔空串');
  assert.equal(r.data.options.length, 3);
  assert.deepEqual(r.data.options[0], { key: 'A', text: '甲说法' });
  assert.deepEqual(r.data.options[1], { key: 'B', text: '乙说法' });
  assert.deepEqual(r.data.options[2], { key: 'C', text: '丙说法' });
  assert.ok(r.data.content_hash, 'content_hash 应由服务端算出');
  assert.ok(r.data.id);
});

test('m23700：手动建题缺字段 / 值域非法 -> 400 且错误码明确', skipOpt, async () => {
  const noStem = await req(
    'POST',
    '/questions',
    { subject_id: seed.subjectA, type: 'choice' },
    TOKEN_A,
  );
  assert.equal(noStem.status, 400, JSON.stringify(noStem.data));
  assert.equal(noStem.data.error, 'MISSING_QUESTION_STEM');

  const noType = await req(
    'POST',
    '/questions',
    { subject_id: seed.subjectA, stem: '缺题型的手动题' },
    TOKEN_A,
  );
  assert.equal(noType.status, 400, JSON.stringify(noType.data));
  assert.equal(noType.data.error, 'MISSING_QUESTION_TYPE');

  const badType = await req(
    'POST',
    '/questions',
    { subject_id: seed.subjectA, type: 'cloud', stem: '题型不存在' },
    TOKEN_A,
  );
  assert.equal(badType.status, 400, JSON.stringify(badType.data));
  assert.equal(badType.data.error, 'INVALID_QUESTION_TYPE');

  const badDifficulty = await req(
    'POST',
    '/questions',
    { subject_id: seed.subjectA, type: 'choice', stem: '难度值不对', difficulty: '0.5' },
    TOKEN_A,
  );
  assert.equal(badDifficulty.status, 400, JSON.stringify(badDifficulty.data));
  assert.equal(badDifficulty.data.error, 'INVALID_DIFFICULTY');

  // 未鉴权建题必须 401（否则任何人可往公共题库塞题）
  const noToken = await req('POST', '/questions', {
    subject_id: seed.subjectA,
    type: 'choice',
    stem: '匿名建题',
  });
  assert.equal(noToken.status, 401, JSON.stringify(noToken.data));
});

test('m23700：同样题干再建一次 -> 409 DUPLICATE_QUESTION（按 owner 分域）', skipOpt, async () => {
  const payload = {
    subject_id: seed.subjectA,
    type: 'choice',
    stem: '判重题：同一题干连续提交两次',
  };
  const first = await req('POST', '/questions', payload, TOKEN_A);
  assert.equal(first.status, 201, JSON.stringify(first.data));

  const second = await req('POST', '/questions', payload, TOKEN_A);
  assert.equal(second.status, 409, JSON.stringify(second.data));
  assert.equal(second.data.error, 'DUPLICATE_QUESTION');
  assert.equal(second.data.current.id, first.data.id, '409 应带上已有题便于前端展示');

  // 换个 owner 建同样的题不应被判重
  const other = await req('POST', '/questions', payload, TOKEN_B);
  assert.equal(other.status, 201, JSON.stringify(other.data));
  assert.notEqual(other.data.id, first.data.id);
});

test('m23700：PATCH /questions/:id 改题干后重算 hash；version 不符 -> 409；走旧 version -> 409', skipOpt, async () => {
  const created = await req(
    'POST',
    '/questions',
    { subject_id: seed.subjectA, type: 'choice', stem: '待编辑题：原始题干', answer: 'A' },
    TOKEN_A,
  );
  assert.equal(created.status, 201, JSON.stringify(created.data));
  const { id, version, content_hash: hash1 } = created.data;

  const patched = await req(
    'PATCH',
    `/questions/${id}`,
    { version, stem: '待编辑题：改过的题干', analysis: '补充解析' },
    TOKEN_A,
  );
  assert.equal(patched.status, 200, JSON.stringify(patched.data));
  assert.equal(patched.data.stem, '待编辑题：改过的题干');
  assert.equal(patched.data.analysis, '补充解析');
  assert.equal(patched.data.version, version + 1, '成功编辑 version 应 +1');
  assert.notEqual(patched.data.content_hash, hash1, '改题干必须重算 content_hash');
  assert.equal(patched.data.answer, 'A', '没传的字段不能被清空');

  const stale = await req(
    'PATCH',
    `/questions/${id}`,
    { version, stem: '待编辑题：又改一次' },
    TOKEN_A,
  );
  assert.equal(stale.status, 409, JSON.stringify(stale.data));
  assert.equal(stale.data.error, 'conflict');
  assert.equal(stale.data.current.version, version + 1);
  assert.equal(stale.data.resolution, 'client_merge');

  const noVersion = await req('PATCH', `/questions/${id}`, { stem: '没带 version' }, TOKEN_A);
  assert.equal(noVersion.status, 400, JSON.stringify(noVersion.data));
  assert.equal(noVersion.data.error, 'INVALID_BASE_VERSION');

  const emptyPatch = await req('PATCH', `/questions/${id}`, { version: version + 1 }, TOKEN_A);
  assert.equal(emptyPatch.status, 400, JSON.stringify(emptyPatch.data));
  assert.equal(emptyPatch.data.error, 'empty_patch');
});

test('m23700：GET /questions/:id 可见性；别人的私有题 / 公共题 -> 404', skipOpt, async () => {
  const mine = await req(
    'POST',
    '/questions',
    { subject_id: seed.subjectA, type: 'fill', stem: '单题详情：只有出题人看得到' },
    TOKEN_A,
  );
  assert.equal(mine.status, 201, JSON.stringify(mine.data));
  const id = mine.data.id;

  const own = await req('GET', `/questions/${id}`, undefined, TOKEN_A);
  assert.equal(own.status, 200, JSON.stringify(own.data));
  assert.equal(own.data.id, id);
  assert.equal(own.data.owner_user_id, seed.userA);

  // 别人的私有题：404（不用 403，避免枚举）
  const other = await req('GET', `/questions/${id}`, undefined, TOKEN_B);
  assert.equal(other.status, 404, JSON.stringify(other.data));

  // 公共题（owner_user_id IS NULL）对所有人可见，但不是「我的题」，不能改
  const c = await pool.connect();
  let publicId;
  try {
    const ins = await c.query(
      `INSERT INTO questions (source, subject_id, type, stem, content_hash, is_subjective)
       VALUES ('manual', $1, 'choice', '公共题：任何人都能看到', 'hash-m23700-public', false)
       RETURNING id`,
      [seed.subjectA],
    );
    publicId = ins.rows[0].id;
  } finally {
    c.release();
  }

  const readPublic = await req('GET', `/questions/${publicId}`, undefined, TOKEN_A);
  assert.equal(readPublic.status, 200, JSON.stringify(readPublic.data));
  assert.equal(readPublic.data.owner_user_id, null);

  const patchPublic = await req('PATCH', `/questions/${publicId}`, { version: 1, stem: '改公共题' }, TOKEN_A);
  assert.equal(patchPublic.status, 404, JSON.stringify(patchPublic.data));

  const missing = await req('GET', '/questions/00000000-0000-4000-8000-000000000000', undefined, TOKEN_A);
  assert.equal(missing.status, 404, JSON.stringify(missing.data));
});

test('m23700：DELETE /questions/:id 软删；删后列表不再出现、可重新建同题干', skipOpt, async () => {
  const created = await req(
    'POST',
    '/questions',
    {
      subject_id: seed.subjectA,
      type: 'choice',
      stem: '待删除题：删完应该能重建同一题干',
    },
    TOKEN_A,
  );
  assert.equal(created.status, 201, JSON.stringify(created.data));
  const { id, version } = created.data;

  const del = await req('DELETE', `/questions/${id}`, { version }, TOKEN_A);
  assert.equal(del.status, 200, JSON.stringify(del.data));
  assert.equal(del.data.deleted, true);
  assert.equal(del.data.id, id);

  const gone = await req('GET', `/questions/${id}`, undefined, TOKEN_A);
  assert.equal(gone.status, 404, JSON.stringify(gone.data));

  const listed = await req('GET', '/questions?limit=200', undefined, TOKEN_A);
  assert.equal(listed.status, 200, JSON.stringify(listed.data));
  assert.ok(!listed.data.items.some((q) => q.id === id), '软删的题不应出现在列表里');

  // 软删后同 hash 可以重新建（查重只看 deleted_at IS NULL）
  const again = await req(
    'POST',
    '/questions',
    { subject_id: seed.subjectA, type: 'choice', stem: '待删除题：删完应该能重建同一题干' },
    TOKEN_A,
  );
  assert.equal(again.status, 201, JSON.stringify(again.data));
  assert.notEqual(again.data.id, id);

  // 重复删除同一个 id -> 404（已软删 = 不存在）
  const delAgain = await req('DELETE', `/questions/${id}`, { version: version + 1 }, TOKEN_A);
  assert.equal(delAgain.status, 404, JSON.stringify(delAgain.data));

  // 删别人的题 -> 404
  const delOther = await req('DELETE', `/questions/${again.data.id}`, { version: 1 }, TOKEN_B);
  assert.equal(delOther.status, 404, JSON.stringify(delOther.data));
});

