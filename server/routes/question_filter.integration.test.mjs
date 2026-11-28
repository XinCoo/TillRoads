// server/routes/question_filter.integration.test.mjs
// 题路 TillRoad · m31635：题库多条件组合筛选（科目 + 题型 + 掌握状态 + 批次）
//
// 只有 RUN_PG_INTEGRATION=1 才跑（CI 会设），本机无 PG 时整文件跳过。
//
// 为什么必须连真库：
//   * 题型过滤靠 `type = ANY($n::text[])` —— 数组参数绑定是 PG 行为，fake 伪造不出来；
//   * 掌握状态三态靠 EXISTS / **NOT** EXISTS 子查询，`unmarked` 必须整个子查询取反，
//     这类 SQL 语义只能在真库上验证；
//   * 组合筛选的 AND 叠加顺序与参数占位符编号会随条件增减而变，真库才能发现错位。
//
// 断言口径：本文件**自建用户 + 自建科目 + 自建题目**，不依赖别的集成测试留下的数据，
// 所以可以安全用绝对条数（不会像 questions.integration.test.mjs 那样被前置用例污染）。
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';

import { createPool } from '../db/pool.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { createApp } from '../index.mjs';
import { FULL_SCHEMA_SQL } from '../db/test_schema.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN
  ? {}
  : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

const TOKEN_A = 'tk_filter_a';
const TOKEN_B = 'tk_filter_b';

let pool;
let app;
let base;
let seed; // { userA, userB, subjectA1, subjectA2, subjectB, q, batchId }

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

/** 造一个用户 + 考试目标，返回 { userId, profileId }。 */
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
  return { userId, profileId: p.rows[0].id };
}

async function makeSubject(c, profileId, name) {
  const r = await c.query(
    `INSERT INTO subjects (exam_profile_id, name, kind) VALUES ($1, $2, 'objective') RETURNING id`,
    [profileId, name],
  );
  return r.rows[0].id;
}

/** 插一道题。ownerUserId=null → 公共题。batchId 可空。 */
async function makeQuestion(
  c,
  { subjectId, ownerUserId, stem, type = 'choice', hash, batchId = null },
) {
  const r = await c.query(
    `INSERT INTO questions
       (source, subject_id, type, stem, options, answer, content_hash, owner_user_id, batch_id)
     VALUES ('import', $1, $2, $3, $4::jsonb, 'A', $5, $6, $7)
     RETURNING id`,
    [
      subjectId,
      type,
      stem,
      JSON.stringify([{ key: 'A', text: '选项甲' }, { key: 'B', text: '选项乙' }]),
      hash,
      ownerUserId,
      batchId,
    ],
  );
  return r.rows[0].id;
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
    const a = await makeUser(c, '组合筛选用户A');
    const b = await makeUser(c, '组合筛选用户B');
    const subjectA1 = await makeSubject(c, a.profileId, '组合筛选科目一');
    const subjectA2 = await makeSubject(c, a.profileId, '组合筛选科目二');
    const subjectB = await makeSubject(c, b.profileId, '组合筛选B科目');

    seed = {
      userA: a.userId,
      userB: b.userId,
      profileA: a.profileId,
      profileB: b.profileId,
      subjectA1,
      subjectA2,
      subjectB,
      q: {},
    };

    // 一批次档案，用于验证 batch_id 与其它维度叠加。
    const batch = await c.query(
      `INSERT INTO import_batches (user_id, filename, question_count)
       VALUES ($1, '组合筛选批次.json', 1) RETURNING id`,
      [a.userId],
    );
    seed.batchId = batch.rows[0].id;

    // ── A 的题目矩阵（题型 × 掌握状态 × 科目 × 批次）────────────────────────
    // 科目一：choice(已掌握) / choice(未掌握) / multi(未标记) / 公共 choice(未标记)
    seed.q.a1choiceMastered = await makeQuestion(c, {
      subjectId: subjectA1,
      ownerUserId: a.userId,
      stem: '组合筛选A1：choice 已掌握',
      type: 'choice',
      hash: 'hash-filter-a1-choice-mastered',
    });
    seed.q.a1choiceUnmastered = await makeQuestion(c, {
      subjectId: subjectA1,
      ownerUserId: a.userId,
      stem: '组合筛选A2：choice 未掌握',
      type: 'choice',
      hash: 'hash-filter-a2-choice-unmastered',
      batchId: seed.batchId,
    });
    seed.q.a1multiUnmarked = await makeQuestion(c, {
      subjectId: subjectA1,
      ownerUserId: a.userId,
      stem: '组合筛选A3：multi 未标记',
      type: 'multi',
      hash: 'hash-filter-a3-multi-unmarked',
    });
    seed.q.a1publicChoiceUnmarked = await makeQuestion(c, {
      subjectId: subjectA1,
      ownerUserId: null,
      stem: '组合筛选A4：公共 choice 未标记',
      type: 'choice',
      hash: 'hash-filter-a4-public-choice',
    });
    // 科目二：choice(未标记) / fill(已掌握)
    seed.q.a2choiceUnmarked = await makeQuestion(c, {
      subjectId: subjectA2,
      ownerUserId: a.userId,
      stem: '组合筛选A5：choice 未标记（科目二）',
      type: 'choice',
      hash: 'hash-filter-a5-choice-unmarked',
    });
    seed.q.a2fillMastered = await makeQuestion(c, {
      subjectId: subjectA2,
      ownerUserId: a.userId,
      stem: '组合筛选A6：fill 已掌握（科目二）',
      type: 'fill',
      hash: 'hash-filter-a6-fill-mastered',
    });
    // B 的题：任何 A 的筛选都不该看到它（验证 owner 隔离没被新参数破坏）
    seed.q.bChoiceMastered = await makeQuestion(c, {
      subjectId: subjectB,
      ownerUserId: b.userId,
      stem: '组合筛选B1：choice 已掌握（B 的题）',
      type: 'choice',
      hash: 'hash-filter-b1-choice-mastered',
    });

    // 掌握度：q1=已掌握、q2=未掌握、q3=未标记、q4=公共(未标记)、
    //         q5=未标记、q6=已掌握、qB=已掌握（B 自己标）
    const mark = async (userId, questionId, mastered) => {
      await c.query(
        `INSERT INTO question_mastery (user_id, question_id, mastered) VALUES ($1, $2, $3)`,
        [userId, questionId, mastered],
      );
    };
    await mark(a.userId, seed.q.a1choiceMastered, true);
    await mark(a.userId, seed.q.a1choiceUnmastered, false);
    await mark(a.userId, seed.q.a2fillMastered, true);
    await mark(b.userId, seed.q.bChoiceMastered, true);
  } finally {
    c.release();
  }

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
    // 顺序要紧：先删引用表（FK 指向 questions / users），再删题。
    await c.query(`DELETE FROM question_mastery WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
    await c.query(`DELETE FROM question_hidden WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
    await c.query(`DELETE FROM import_batches WHERE user_id IN ($1, $2)`, [seed.userA, seed.userB]);
    await c.query(
      `DELETE FROM questions
        WHERE owner_user_id IN ($1, $2)
           OR subject_id IN (
                SELECT s.id FROM subjects s
                  JOIN exam_profiles p ON p.id = s.exam_profile_id
                 WHERE p.user_id IN ($1, $2))`,
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

/** 取一批 id，用于集合断言。 */
function idsOf(result) {
  return result.data.items.map((it) => it.id).sort();
}

test('m31635：无筛选参数时返回全部可见题（A 的 6 道 + 公共题，不含 B 的题）', skipOpt, async () => {
  const r = await req('GET', '/questions?limit=200', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.items.length, 6, `应 6 道（5 道自有 + 1 道公共），实际 ${r.data.items.length}`);
  assert.ok(
    !r.data.items.some((q) => q.id === seed.q.bChoiceMastered),
    '不能看到 B 的私有题',
  );
  for (const item of r.data.items) {
    assert.ok(
      item.owner_user_id === null || item.owner_user_id === seed.userA,
      `出现不属于自己的题：owner=${item.owner_user_id}`,
    );
  }
});

test('m31635：type 单选 / 多选（逗号分隔）过滤', skipOpt, async () => {
  // choice → q1、q2、q4（公共）、q5 = 4 道
  const choice = await req('GET', '/questions?type=choice&limit=200', undefined, TOKEN_A);
  assert.equal(choice.status, 200, JSON.stringify(choice.data));
  assert.deepEqual(idsOf(choice), [
    seed.q.a1choiceMastered,
    seed.q.a1choiceUnmastered,
    seed.q.a1publicChoiceUnmarked,
    seed.q.a2choiceUnmarked,
  ].sort());
  for (const item of choice.data.items) {
    assert.equal(item.type, 'choice', 'type 过滤失效');
  }

  // 多选用逗号分隔：choice,multi → 上面 4 道 + multi = 5 道
  const multi = await req('GET', '/questions?type=choice,multi&limit=200', undefined, TOKEN_A);
  assert.equal(multi.status, 200, JSON.stringify(multi.data));
  assert.equal(multi.data.items.length, 5, `choice,multi 应 5 道，实际 ${multi.data.items.length}`);

  // 单个非 choice 题型：fill → 1 道
  const fill = await req('GET', '/questions?type=fill&limit=200', undefined, TOKEN_A);
  assert.equal(fill.status, 200, JSON.stringify(fill.data));
  assert.deepEqual(idsOf(fill), [seed.q.a2fillMastered]);

  // 空白 / 非法题型静默忽略（不报 400，退化成不筛）
  const blank = await req('GET', '/questions?type=%20%20&limit=200', undefined, TOKEN_A);
  assert.equal(blank.status, 200, JSON.stringify(blank.data));
  assert.equal(blank.data.items.length, 6, '空白 type 应视同没传');

  const bogus = await req('GET', '/questions?type=nonsense&limit=200', undefined, TOKEN_A);
  assert.equal(bogus.status, 200, JSON.stringify(bogus.data));
  assert.equal(bogus.data.items.length, 6, '非法 type 应静默忽略，不把整页打成错误页');
});

test('m31635：mastery 三态过滤（mastered / unmastered / unmarked）', skipOpt, async () => {
  // mastered → q1、q6
  const mastered = await req('GET', '/questions?mastery=mastered&limit=200', undefined, TOKEN_A);
  assert.equal(mastered.status, 200, JSON.stringify(mastered.data));
  assert.deepEqual(idsOf(mastered), [seed.q.a1choiceMastered, seed.q.a2fillMastered].sort());

  // unmastered → 只有 q2（标过未掌握）；**未标记不算**
  const unmastered = await req('GET', '/questions?mastery=unmastered&limit=200', undefined, TOKEN_A);
  assert.equal(unmastered.status, 200, JSON.stringify(unmastered.data));
  assert.deepEqual(idsOf(unmastered), [seed.q.a1choiceUnmastered]);
  assert.ok(
    !unmastered.data.items.some((q) => q.id === seed.q.a1multiUnmarked),
    '「未标记」不能被算成「未掌握」',
  );

  // unmarked → q3、q4（公共）、q5 = 3 道；**已掌握的题不能出现**（NOT EXISTS 整个取反）
  const unmarked = await req('GET', '/questions?mastery=unmarked&limit=200', undefined, TOKEN_A);
  assert.equal(unmarked.status, 200, JSON.stringify(unmarked.data));
  assert.deepEqual(idsOf(unmarked), [
    seed.q.a1multiUnmarked,
    seed.q.a1publicChoiceUnmarked,
    seed.q.a2choiceUnmarked,
  ].sort());
  assert.ok(
    !unmarked.data.items.some((q) => q.id === seed.q.a1choiceMastered),
    'NOT EXISTS 若写成 NOT EXISTS(... AND mastered=false) 会把已掌握也算成未标记',
  );

  // 非法值静默忽略
  const bogus = await req('GET', '/questions?mastery=whatever&limit=200', undefined, TOKEN_A);
  assert.equal(bogus.status, 200, JSON.stringify(bogus.data));
  assert.equal(bogus.data.items.length, 6, '非法 mastery 应视同没传');
});

test('m31635：type + mastery 组合（AND 叠加）', skipOpt, async () => {
  // choice + mastered → q1
  const r1 = await req(
    'GET',
    '/questions?type=choice&mastery=mastered&limit=200',
    undefined,
    TOKEN_A,
  );
  assert.equal(r1.status, 200, JSON.stringify(r1.data));
  assert.deepEqual(idsOf(r1), [seed.q.a1choiceMastered]);

  // choice,multi + unmarked → q3（multi 未标记）、q4（公共未标记）、q5（choice 未标记） = 3 道
  const r2 = await req(
    'GET',
    '/questions?type=choice,multi&mastery=unmarked&limit=200',
    undefined,
    TOKEN_A,
  );
  assert.equal(r2.status, 200, JSON.stringify(r2.data));
  assert.deepEqual(idsOf(r2), [
    seed.q.a1multiUnmarked,
    seed.q.a1publicChoiceUnmarked,
    seed.q.a2choiceUnmarked,
  ].sort());

  // fill + mastered → q6
  const r3 = await req('GET', '/questions?type=fill&mastery=mastered&limit=200', undefined, TOKEN_A);
  assert.equal(r3.status, 200, JSON.stringify(r3.data));
  assert.deepEqual(idsOf(r3), [seed.q.a2fillMastered]);
});

test('m31635：科目 + 题型 + 掌握状态三维叠加', skipOpt, async () => {
  // 科目一 + choice + mastered → q1
  const r1 = await req(
    'GET',
    `/questions?subject_id=${seed.subjectA1}&type=choice&mastery=mastered&limit=200`,
    undefined,
    TOKEN_A,
  );
  assert.equal(r1.status, 200, JSON.stringify(r1.data));
  assert.deepEqual(idsOf(r1), [seed.q.a1choiceMastered]);

  // 科目二 + choice + unmarked → q5
  const r2 = await req(
    'GET',
    `/questions?subject_id=${seed.subjectA2}&type=choice&mastery=unmarked&limit=200`,
    undefined,
    TOKEN_A,
  );
  assert.equal(r2.status, 200, JSON.stringify(r2.data));
  assert.deepEqual(idsOf(r2), [seed.q.a2choiceUnmarked]);

  // 科目一 + choice + unmarked → 只有公共题 q4
  const r3 = await req(
    'GET',
    `/questions?subject_id=${seed.subjectA1}&type=choice&mastery=unmarked&limit=200`,
    undefined,
    TOKEN_A,
  );
  assert.equal(r3.status, 200, JSON.stringify(r3.data));
  assert.deepEqual(idsOf(r3), [seed.q.a1publicChoiceUnmarked]);
});

test('m31635：四维全参数（科目 + 题型 + 掌握状态 + 批次）', skipOpt, async () => {
  // 批次里只有 q2（未掌握）。全参数命中 → q2
  const hit = await req(
    'GET',
    `/questions?subject_id=${seed.subjectA1}&type=choice&mastery=unmastered&batch_id=${seed.batchId}&limit=200`,
    undefined,
    TOKEN_A,
  );
  assert.equal(hit.status, 200, JSON.stringify(hit.data));
  assert.deepEqual(idsOf(hit), [seed.q.a1choiceUnmastered]);

  // 同样的组合但把掌握状态换成 mastered → 0 条（批次里的题是未掌握）
  const miss = await req(
    'GET',
    `/questions?subject_id=${seed.subjectA1}&type=choice&mastery=mastered&batch_id=${seed.batchId}&limit=200`,
    undefined,
    TOKEN_A,
  );
  assert.equal(miss.status, 200, JSON.stringify(miss.data));
  assert.equal(miss.data.items.length, 0, '四维叠加后不应命中');

  // 只按批次 → 1 道（不受其它维度影响）
  const onlyBatch = await req('GET', `/questions?batch_id=${seed.batchId}&limit=200`, undefined, TOKEN_A);
  assert.equal(onlyBatch.status, 200, JSON.stringify(onlyBatch.data));
  assert.deepEqual(idsOf(onlyBatch), [seed.q.a1choiceUnmastered]);
});

test('m31635：旧参数 mastered=true 仍然生效（向后兼容）', skipOpt, async () => {
  const r = await req('GET', '/questions?mastered=true&limit=200', undefined, TOKEN_A);
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.deepEqual(idsOf(r), [seed.q.a1choiceMastered, seed.q.a2fillMastered].sort());
});

test('m31635：新参数不破坏 owner 隔离（B 的筛选口径只看 B 自己的题）', skipOpt, async () => {
  const bAll = await req('GET', '/questions?limit=200', undefined, TOKEN_B);
  assert.equal(bAll.status, 200, JSON.stringify(bAll.data));
  // 注意：公共题（owner_user_id IS NULL）对所有人可见，所以 B 看到「自己的题 + 公共题」两道，
  // 这是既有可见性口径（与真实仓储 listVisible 一致），不是 bug。
  assert.deepEqual(
    idsOf(bAll),
    [seed.q.bChoiceMastered, seed.q.a1publicChoiceUnmarked].sort(),
    'B 应看到自己的题 + 公共题',
  );
  assert.ok(
    !bAll.data.items.some(
      (q) => q.owner_user_id !== null && q.owner_user_id !== seed.userB,
    ),
    'B 不能看到 A 的私有题',
  );

  const bMastered = await req('GET', '/questions?mastery=mastered&limit=200', undefined, TOKEN_B);
  assert.equal(bMastered.status, 200, JSON.stringify(bMastered.data));
  assert.deepEqual(idsOf(bMastered), [seed.q.bChoiceMastered]);

  // A 的题对 B 不可见 —— 即使题型/掌握状态完全相同
  const aAsB = await req('GET', '/questions?type=choice&mastery=mastered&limit=200', undefined, TOKEN_B);
  assert.equal(aAsB.status, 200, JSON.stringify(aAsB.data));
  assert.deepEqual(idsOf(aAsB), [seed.q.bChoiceMastered]);
});
