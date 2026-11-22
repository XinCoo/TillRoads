// server/index.integration.test.mjs
// 题路 TillRoad · BE-01 第 4 步：路由层真实的 PG 集成测试（决策 13）
//
// 与 server/index.test.mjs 的分工：
//   * index.test.mjs          —— fake 层：路由分发 / 入参解析 / base_version 400 / 409 两种形状。
//                                不连 PG，本机随时跑。
//   * index.integration.test.mjs（本文件）—— 真 PG：四表端点的**成功路径**与
//                                三处事务编排（AC-KM-01 / AC-KM-02 / 级联软删）。
//                                只有 RUN_PG_INTEGRATION=1 才跑，CI 会设。
//
// 为什么必须连真库才能验这三处：
//   AC-KM-01 要证明「profile 建成功 + 科目按模板全建出来」，这依赖 getTemplateSubjects
//   与 subjects.create 的组合结果；AC-KM-02 要证明「新模板与科目重指向同时生效」；
//   级联软删要证明「三条 UPDATE 的行数都对、且子表真的查不到了」。
//   fake 只能伪造 SQL 的返回值，伪造不出「事务提交后数据库里到底有什么」。

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { createPool } from './db/pool.mjs';
import { withTransaction } from './repositories/base.mjs';
import { createApp } from './index.mjs';
import { getTemplateSubjects } from '../core/templates.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN
  ? {}
  : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

const HERE = dirname(fileURLToPath(import.meta.url));
// ★ m17431：schema 解冻后要连「基线 schema + 增量迁移」一起跑
//   （owner_user_id 列在 migrations/0002_questions_owner.sql 里，不在 schema.sql 里）。
import { FULL_SCHEMA_SQL } from './db/test_schema.mjs';

let pool;
let app;
let base;
let seed; // { userId }

/** 极简请求封装，与 index.test.mjs 保持同形状。 */
async function req(method, path, body) {
  const init = { method };
  if (body !== undefined) {
    init.headers = { 'Content-Type': 'application/json' };
    init.body = JSON.stringify(body);
  }
  const res = await fetch(base + path, init);
  const text = await res.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  return { status: res.status, data, headers: res.headers };
}

before(async () => {
  if (!RUN) return;

  pool = createPool();

  // T7：schema.sql 用 withTransaction 包住，失败整笔回滚，不在库里留半个 schema。
  try {
    await withTransaction(pool, async (client) => {
      await client.query(FULL_SCHEMA_SQL);
    });
  } catch (err) {
    throw new Error(`before: 执行 schema.sql 失败（已回滚）—— ${err.message}`);
  }

  // 已提交的基线用户（路由层的 POST /exam-profiles 要求 user_id 是真实存在的行）
  const c = await pool.connect();
  try {
    const u = await c.query(
      `INSERT INTO users (nickname, timezone, role) VALUES ($1, $2, $3) RETURNING id`,
      ['路由集成测试用户', 'Asia/Shanghai', 'student'],
    );
    seed = { userId: u.rows[0].id };
  } finally {
    c.release();
  }

  app = createApp({ pool });
  await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${app.server.address().port}`;
});

after(async () => {
  if (!RUN || !app) return;

  // 真 DELETE 清理（软删不会级联），不留脏数据给下次运行。
  const c = await pool.connect();
  let cleanupFailure = null;
  try {
    await c.query(
      `DELETE FROM knowledge_nodes
        WHERE subject_id IN (SELECT s.id FROM subjects s
                              JOIN exam_profiles p ON p.id = s.exam_profile_id
                             WHERE p.user_id = $1)`,
      [seed.userId],
    );
    await c.query(
      `DELETE FROM subjects
        WHERE exam_profile_id IN (SELECT id FROM exam_profiles WHERE user_id = $1)`,
      [seed.userId],
    );
    await c.query(`DELETE FROM exam_profiles WHERE user_id = $1`, [seed.userId]);
    // capability_layers 是**共享模板**，不挂在 user 上，必须按名字单独清（本测试专属的几张）。
    await c.query(
      `DELETE FROM capability_layers
        WHERE name = ANY($1::text[])`,
      [['我的三层模板', '我的三层模板 v2', '坏模板', '只读官方模板', '只读官方模板（改名）']],
    );
    await c.query(`DELETE FROM users WHERE id = $1`, [seed.userId]);
  } catch (cleanupError) {
    // 与 mock_exams.integration.test.mjs 同样的加固：清理抛错不能连带 skip 掉关服。
    // 原实现把 app.close()/pool.end() 放在 try/finally 之外，异常一跳出就永远执行不到，
    // HTTP server 与连接池仍有活 handle → node:test 进程退不出去（CI 超时 cancel）。
    // 不吞错误（否则数据泄漏被静默忽略）：先关服再抛，fail fast 且进程能退出。
    cleanupFailure = cleanupError;
  } finally {
    c.release();
  }

  try {
    await new Promise((resolve) => app.close(resolve));
  } finally {
    await pool.end();
  }
  if (cleanupFailure) {
    throw new Error(`after(): 清理数据失败（前置测试已跑完，但库中可能残留测试数据）: ${cleanupFailure.message}`);
  }
});

// ---------------------------------------------------------------------------
// 1) 读端点：健康检查在不连 PG 的情况下也成立（此处仍验一遍端到端链路）
// ---------------------------------------------------------------------------

test('GET /health 端到端可用（注入真 pool 后不失效）', skipOpt, async () => {
  const r = await req('GET', '/health');
  assert.equal(r.status, 200);
  assert.equal(r.data.status, 'ok');
});

// ---------------------------------------------------------------------------
// 2) AC-KM-01：POST /exam-profiles 在一个事务里建 profile + 全套默认科目
// ---------------------------------------------------------------------------

test('AC-KM-01: POST /exam-profiles 按模板预置科目，且 profile.subjects 长度与模板一致', skipOpt, async () => {
  const template = getTemplateSubjects('postgrad');
  assert.ok(template.length > 0, 'postgrad 模板不应为空');

  const r = await req('POST', '/exam-profiles', {
    user_id: seed.userId,
    exam_type: 'postgrad',
    target_label: 'AC-KM-01 目标',
    target_score: 380,
    exam_date: '2027-12-20',
    daily_minutes: 180,
  });
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.profile.status, 'active');
  assert.equal(r.data.profile.version, 1);
  assert.equal(r.data.profile.user_id, seed.userId);

  // 科目按模板全部建出来，名字与 kind 逐条对上
  assert.equal(r.data.subjects.length, template.length);
  for (let i = 0; i < template.length; i += 1) {
    assert.equal(r.data.subjects[i].name, template[i].name);
    assert.equal(r.data.subjects[i].kind, template[i].kind);
    assert.equal(r.data.subjects[i].exam_profile_id, r.data.profile.id);
  }

  // 再从库外确认一次（不依赖响应体）
  const list = await req('GET', `/exam-profiles/${r.data.profile.id}/subjects`);
  assert.equal(list.status, 200);
  assert.equal(list.data.items.length, template.length);
});

test('AC-KM-01: 模板覆盖多个 exam_type 时各自按自己的模板预置（final_exam 反证）', skipOpt, async () => {
  // 注：当前 5 个 exam_type 都有模板，故「未知类型→只建 profile」这条分支
  // 无法用合法枚举值验证（enum 会先挡掉）。这里改用另一套模板反证
  // 「科目数量随 exam_type 变化」：若将来新增无模板的枚举值，路由不需改动——
  // getTemplateSubjects 返回 []，循环 0 次，仍 201 且 subjects 为 []。
  // 该分支的契约由 core/templates.test.mjs 的 T2（未知类型返回 []）守着。
  const template = getTemplateSubjects('final_exam');
  const r = await req('POST', '/exam-profiles', {
    user_id: seed.userId,
    exam_type: 'final_exam',
    target_label: 'AC-KM-01 模板反证',
    exam_date: '2027-06-30',
    daily_minutes: 60,
  });
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.subjects.length, template.length);
});

test('AC-KM-01: 同一用户下 target_label 重复 -> 409 user_choice（查重发生在事务内）', skipOpt, async () => {
  const body = {
    user_id: seed.userId,
    exam_type: 'vocational',
    target_label: '重复标签目标',
    exam_date: '2027-05-01',
    daily_minutes: 90,
  };
  const first = await req('POST', '/exam-profiles', body);
  assert.equal(first.status, 201, JSON.stringify(first.data));

  const second = await req('POST', '/exam-profiles', body);
  assert.equal(second.status, 409, JSON.stringify(second.data));
  assert.equal(second.data.error, 'conflict');
  assert.equal(second.data.field, 'target_label');
  assert.equal(second.data.resolution, 'user_choice');

  // 关键：第二次的失败不应留下孤儿科目（profile 建失败整笔回滚）
  const list = await req('GET', `/users/${seed.userId}/exam-profiles`);
  assert.equal(list.status, 200);
  const sameLabel = list.data.items.filter((x) => x.target_label === '重复标签目标');
  assert.equal(sameLabel.length, 1, '重复标签的目标只能有一条');
});

// ---------------------------------------------------------------------------
// 3) AC-KM-02：POST /subjects/:id/customize-layers 同事务建副本 + 重指向
// ---------------------------------------------------------------------------

test('AC-KM-02: customize-layers 建副本模板并把 subject.layer_template_id 重指向它', skipOpt, async () => {
  const created = await req('POST', '/exam-profiles', {
    user_id: seed.userId,
    exam_type: 'civil_service',
    target_label: 'AC-KM-02 目标',
    exam_date: '2027-03-15',
    daily_minutes: 240,
  });
  assert.equal(created.status, 201, JSON.stringify(created.data));
  const subject = created.data.subjects[0];
  assert.equal(subject.version, 1);

  const layers = [
    { order: 1, key: 'know', label: '知道', desc: '能复述概念' },
    { order: 2, key: 'do', label: '会做', desc: '能独立解题' },
    { order: 3, key: 'teach', label: '能讲', desc: '能讲清思路' },
  ];

  const r = await req('POST', `/subjects/${subject.id}/customize-layers`, {
    name: '我的三层模板',
    layers,
    version: subject.version,
  });
  assert.equal(r.status, 201, JSON.stringify(r.data));

  // 1) 新模板可自定义，内容就是提交的那份
  assert.equal(r.data.capability_layer.name, '我的三层模板');
  assert.equal(r.data.capability_layer.customizable, true);
  assert.deepEqual(r.data.capability_layer.layers, layers);

  // 2) 科目已重指向，且版本 +1
  assert.equal(r.data.subject.id, subject.id);
  assert.equal(r.data.subject.layer_template_id, r.data.capability_layer.id);
  assert.equal(r.data.subject.version, subject.version + 1);

  // 3) 从库里再读一次，确认持久化
  const got = await req('GET', `/subjects/${subject.id}`);
  assert.equal(got.status, 200);
  assert.equal(got.data.layer_template_id, r.data.capability_layer.id);

  // 4) 用旧版本号再提交一次 -> 409，且不应再产生第二张孤儿模板
  const again = await req('POST', `/subjects/${subject.id}/customize-layers`, {
    name: '我的三层模板 v2',
    layers,
    version: subject.version, // 旧版本
  });
  assert.equal(again.status, 409, JSON.stringify(again.data));
  assert.equal(again.data.resolution, 'client_merge');

  const layersList = await req('GET', '/capability-layers?limit=200');
  assert.equal(layersList.status, 200);
  assert.equal(
    layersList.data.items.filter((x) => x.name === '我的三层模板 v2').length,
    0,
    '409 时新建的副本模板必须回滚（不留孤儿）',
  );
});

test('AC-KM-02: layers 结构非法 -> 400（在开事务前就被拒）', skipOpt, async () => {
  const created = await req('POST', '/exam-profiles', {
    user_id: seed.userId,
    exam_type: 'vocational',
    target_label: 'AC-KM-02 非法 layers',
    exam_date: '2027-04-01',
    daily_minutes: 60,
  });
  assert.equal(created.status, 201, JSON.stringify(created.data));
  const subject = created.data.subjects[0];

  const r = await req('POST', `/subjects/${subject.id}/customize-layers`, {
    name: '坏模板',
    layers: [{ order: 1, key: 'a', label: 'A', desc: 'x' }, { order: 1, key: 'b', label: 'B', desc: 'y' }],
    version: subject.version,
  });
  assert.equal(r.status, 400, JSON.stringify(r.data));
  assert.equal(r.data.error, 'DUPLICATE_LAYER_ORDER');
});

// ---------------------------------------------------------------------------
// 4) 级联软删：DELETE /exam-profiles/:id 打 tombstone 到整棵子树
// ---------------------------------------------------------------------------

test('级联软删：DELETE /exam-profiles/:id 同时软删 subjects 与 knowledge_nodes，并返回行数', skipOpt, async () => {
  const created = await req('POST', '/exam-profiles', {
    user_id: seed.userId,
    exam_type: 'final_exam',
    target_label: '级联软删目标',
    exam_date: '2027-02-10',
    daily_minutes: 45,
  });
  assert.equal(created.status, 201, JSON.stringify(created.data));
  const profile = created.data.profile;
  const subjects = created.data.subjects;
  assert.ok(subjects.length > 0);

  // 造一棵两层考点树挂在第一个科目下
  const root = await req('POST', '/knowledge-nodes', {
    subject_id: subjects[0].id,
    title: '级联-根',
    freq_tag: 'high',
  });
  assert.equal(root.status, 201, JSON.stringify(root.data));

  const child = await req('POST', '/knowledge-nodes', {
    subject_id: subjects[0].id,
    title: '级联-子',
    parent_id: root.data.id,
    weight_to_target: 0.5,
  });
  assert.equal(child.status, 201, JSON.stringify(child.data));

  const del = await req('DELETE', `/exam-profiles/${profile.id}`, { version: profile.version });
  assert.equal(del.status, 200, JSON.stringify(del.data));
  assert.equal(del.data.id, profile.id);
  assert.ok(del.data.deleted_at, 'profile 应被软删');

  // 子表行数必须与造出来的数量一致
  assert.equal(del.data.cascaded.subjects, subjects.length);
  assert.equal(del.data.cascaded.knowledge_nodes, 2);

  // 软删后所有读端点都应 404 / 空
  const gone = await req('GET', `/exam-profiles/${profile.id}`);
  assert.equal(gone.status, 404);

  const subjList = await req('GET', `/exam-profiles/${profile.id}/subjects`);
  assert.equal(subjList.status, 200);
  assert.deepEqual(subjList.data.items, []);

  const tree = await req('GET', `/subjects/${subjects[0].id}/knowledge-tree`);
  assert.equal(tree.status, 200);
  assert.deepEqual(tree.data.items, []);
});

test('级联软删：base_version 过期 -> 409，且一行都不该被软删', skipOpt, async () => {
  const created = await req('POST', '/exam-profiles', {
    user_id: seed.userId,
    exam_type: 'adult_self_study',
    target_label: '级联软删 409 目标',
    exam_date: '2027-08-08',
    daily_minutes: 30,
  });
  assert.equal(created.status, 201, JSON.stringify(created.data));
  const profile = created.data.profile;

  const del = await req('DELETE', `/exam-profiles/${profile.id}`, { version: profile.version + 5 });
  assert.equal(del.status, 409, JSON.stringify(del.data));
  assert.equal(del.data.resolution, 'client_merge');

  // 整笔回滚：profile 与科目都还在
  const still = await req('GET', `/exam-profiles/${profile.id}`);
  assert.equal(still.status, 200);
  const subs = await req('GET', `/exam-profiles/${profile.id}/subjects`);
  assert.ok(subs.data.items.length > 0, '409 时科目不应被软删');
});

// ---------------------------------------------------------------------------
// 5) 四表 PATCH / base_version 在真库上生效（乐观锁 + 空 patch 不推进版本）
// ---------------------------------------------------------------------------

test('PATCH /exam-profiles：正常推进 version，旧版本再来 409，空 patch 不推进', skipOpt, async () => {
  const created = await req('POST', '/exam-profiles', {
    user_id: seed.userId,
    exam_type: 'postgrad',
    target_label: '乐观锁目标',
    exam_date: '2027-11-11',
    daily_minutes: 90,
  });
  assert.equal(created.status, 201, JSON.stringify(created.data));
  const p = created.data.profile;

  const up = await req('PATCH', `/exam-profiles/${p.id}`, { version: p.version, daily_minutes: 150 });
  assert.equal(up.status, 200, JSON.stringify(up.data));
  assert.equal(up.data.daily_minutes, 150);
  assert.equal(up.data.version, p.version + 1);

  const stale = await req('PATCH', `/exam-profiles/${p.id}`, { version: p.version, daily_minutes: 200 });
  assert.equal(stale.status, 409, JSON.stringify(stale.data));
  assert.equal(stale.data.incoming, p.version);

  // 空 patch：不发 UPDATE，version 不变
  const noop = await req('PATCH', `/exam-profiles/${p.id}`, { version: up.data.version });
  assert.equal(noop.status, 200, JSON.stringify(noop.data));
  assert.equal(noop.data.version, up.data.version);
});

test('PATCH /exam-profiles：同一 user 下两个 profile 并发改成同一 target_label -> 恰好一个成功一个 409', skipOpt, async () => {
  const mk = async (label) => {
    const r = await req('POST', '/exam-profiles', {
      user_id: seed.userId,
      exam_type: 'postgrad',
      target_label: label,
      exam_date: '2027-12-01',
      daily_minutes: 60,
    });
    assert.equal(r.status, 201, JSON.stringify(r.data));
    return r.data.profile;
  };

  const a = await mk('并发目标A');
  const b = await mk('并发目标B');

  const [ra, rb] = await Promise.all([
    req('PATCH', `/exam-profiles/${a.id}`, { version: a.version, target_label: '并发同名' }),
    req('PATCH', `/exam-profiles/${b.id}`, { version: b.version, target_label: '并发同名' }),
  ]);

  const statuses = [ra.status, rb.status].sort((x, y) => x - y);
  // 若查重与写入不在同一事务，两次 `users FOR UPDATE` 会各自在语句结束就
  // 释放锁，双发都能读到「尚无同名」-> [200,200] 双写成功（脏数据）。
  assert.deepEqual(
    statuses,
    [200, 409],
    `期望一个 200 一个 409，实际 ${JSON.stringify([ra.data, rb.data])}`,
  );

  const conflict = ra.status === 409 ? ra : rb;
  assert.equal(conflict.data.resolution, 'user_choice');
  assert.equal(conflict.data.field, 'target_label');
});

test('capability_layers: customizable=false 的模板改 layers -> 400 CUSTOMIZABLE_LOCKED，删也拒', skipOpt, async () => {
  const mk = await req('POST', '/capability-layers', {
    name: '只读官方模板',
    layers: [{ order: 1, key: 'a', label: 'A', desc: '' }],
    customizable: false,
  });
  assert.equal(mk.status, 201, JSON.stringify(mk.data));
  const layer = mk.data;

  const bad = await req('PATCH', `/capability-layers/${layer.id}`, {
    version: layer.version,
    layers: [{ order: 1, key: 'b', label: 'B', desc: '' }],
  });
  assert.equal(bad.status, 400, JSON.stringify(bad.data));
  assert.equal(bad.data.error, 'CUSTOMIZABLE_LOCKED');

  // 只改 name 放行（gate 只锁 layers / customizable 键）
  const okName = await req('PATCH', `/capability-layers/${layer.id}`, {
    version: layer.version,
    name: '只读官方模板（改名）',
  });
  assert.equal(okName.status, 200, JSON.stringify(okName.data));

  const del = await req('DELETE', `/capability-layers/${layer.id}`, { version: okName.data.version });
  assert.equal(del.status, 400, JSON.stringify(del.data));
  assert.equal(del.data.error, 'CUSTOMIZABLE_LOCKED');
});
