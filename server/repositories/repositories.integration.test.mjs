// server/repositories/repositories.integration.test.mjs
// 题路 TillRoad · BE-01 第 3 步：四表仓储集成测试（真实 PG）
//
// 运行条件：RUN_PG_INTEGRATION=1（CI 的 node-tests job 已设；本机无 PG 会整体 skip）。
//
// 隔离策略（决策 7）：
//   * before() 只跑一次 migrations 的单一事实来源 schema.sql（**不是** 0001_init_up.sql，
//     后者含 psql 元命令 \ir，libpq 不认）；
//   * 每个 test 在**自己的事务**里跑，结束一律 ROLLBACK —— 数据互不污染，
//     也不必写一堆 DELETE 清理；
//   * 唯一例外是并发竞态用例：它必须让两个连接互相阻塞，只能真提交一次，
//     故在 finally 里显式删除该用例造的数据。
//
// 本文件不 import pg（沿用鸭子类型约定），池由 createPool() 提供。

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { createPool } from '../db/pool.mjs';
import { withTransaction } from './base.mjs';

import * as examProfiles from './exam_profiles.mjs';
import * as subjects from './subjects.mjs';
import * as knowledgeNodes from './knowledge_nodes.mjs';
import * as capabilityLayers from './capability_layers.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN
  ? {}
  : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

const HERE = dirname(fileURLToPath(import.meta.url));
const SCHEMA_SQL = readFileSync(join(HERE, '..', '..', 'schema.sql'), 'utf8');

let pool;
let seed; // { userId, profileId, subjectId }

/**
 * 在事务里跑 fn，然后**必定回滚**（不是 withTransaction 的提交语义）。
 * 这样每个 test 都看到同一份干净的已提交基线，且自己造的数据不会留下。
 */
async function inRollback(poolInstance, fn) {
  const client = await poolInstance.connect();
  try {
    await client.query('BEGIN');
    try {
      return await fn(client);
    } finally {
      await client.query('ROLLBACK');
    }
  } finally {
    client.release();
  }
}

before(async () => {
  if (!RUN) return;

  pool = createPool();

  // 单一事实来源：整份 schema.sql 一次性执行。
  // schema.sql 里没有 psql 元命令，且 node-postgres 在「无参数」时走简单查询协议，
  // 可一次提交多语句；末尾的 DO 块会自行打印/抛错 SCHEMA_VERIFY_OK|FAILED。
  try {
    await pool.query(SCHEMA_SQL);
  } catch (err) {
    // 明确报错终止，绝不让后续 test 在半个 schema 上跑出误导性结果
    throw new Error(`before: 执行 schema.sql 失败 —— ${err.message}`);
  }

  // 已提交的基线数据（并发竞态用例需要别的连接能看到）
  const client = await pool.connect();
  try {
    const u = await client.query(
      `INSERT INTO users (nickname, timezone, role) VALUES ($1, $2, $3) RETURNING id`,
      ['集成测试用户', 'Asia/Shanghai', 'student'],
    );
    const p = await client.query(
      `INSERT INTO exam_profiles (user_id, exam_type, target_label, exam_date, daily_minutes)
       VALUES ($1, $2, $3, $4, $5) RETURNING id`,
      [u.rows[0].id, 'postgrad', '集成测试目标', '2027-06-01', 120],
    );
    const s = await client.query(
      `INSERT INTO subjects (exam_profile_id, name, kind) VALUES ($1, $2, $3) RETURNING id`,
      [p.rows[0].id, '集成测试科目', 'objective'],
    );
    seed = { userId: u.rows[0].id, profileId: p.rows[0].id, subjectId: s.rows[0].id };
  } finally {
    client.release();
  }
});

after(async () => {
  if (!RUN || !pool) return;
  // 清掉基线（软删不会级联，这里用真 DELETE 让库里彻底干净）
  const client = await pool.connect();
  try {
    await client.query(`DELETE FROM knowledge_nodes WHERE subject_id = $1`, [seed.subjectId]);
    await client.query(`DELETE FROM subjects WHERE exam_profile_id = $1`, [seed.profileId]);
    await client.query(`DELETE FROM exam_profiles WHERE user_id = $1`, [seed.userId]);
    await client.query(`DELETE FROM users WHERE id = $1`, [seed.userId]);
  } finally {
    client.release();
  }
  await pool.end();
});

// ---------------------------------------------------------------------------
// exam_profiles
// ---------------------------------------------------------------------------

test('exam_profiles.create: 落库后 version=1、status 默认 active、target_score 读回 number', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const row = await examProfiles.create(client, {
      user_id: seed.userId,
      exam_type: 'civil_service',
      target_label: '行测冲刺',
      target_score: 75.5,
      exam_date: '2027-03-15',
      daily_minutes: 90,
    });
    assert.equal(row.exam_type, 'civil_service');
    assert.equal(row.target_label, '行测冲刺');
    assert.equal(row.status, 'active');
    assert.equal(row.version, 1);
    assert.equal(row.deleted_at, null);
    // numeric(6,2) 经 parseNumeric 转 number（不是驱动默认的字符串）
    assert.equal(typeof row.target_score, 'number');
    assert.equal(row.target_score, 75.5);
    // date 列保持 'YYYY-MM-DD' 字符串（parseDate 不转 Date，避免时区漂移）
    assert.equal(row.exam_date, '2027-03-15');
  });
});

test('exam_profiles.create: 同 user 下 target_label 重复 -> 409 冲突（field=target_label, resolution=user_choice）', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    await assert.rejects(
      () =>
        examProfiles.create(client, {
          user_id: seed.userId,
          exam_type: 'postgrad',
          target_label: '集成测试目标', // 与 before 里的基线同名
          exam_date: '2027-07-01',
          daily_minutes: 60,
        }),
      (err) => {
        assert.equal(err.code, 'conflict');
        assert.equal(err.statusCode, 409);
        assert.equal(err.body.field, 'target_label');
        assert.equal(err.body.resolution, 'user_choice');
        assert.ok(err.body.current.id, '应把冲突行交回客户端');
        return true;
      },
    );
  });
});

test('exam_profiles.create: target_label 为空不参与查重（可建多条未命名目标）', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const a = await examProfiles.create(client, {
      user_id: seed.userId, exam_type: 'final_exam', exam_date: '2027-01-10', daily_minutes: 30,
    });
    const b = await examProfiles.create(client, {
      user_id: seed.userId, exam_type: 'final_exam', exam_date: '2027-01-11', daily_minutes: 30,
    });
    assert.notEqual(a.id, b.id);
    assert.equal(a.target_label, null);
    assert.equal(b.target_label, null);
  });
});

test('exam_profiles.update: 乐观锁生效 —— version 自增、旧 version 再写 -> 409 client_merge', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const created = await examProfiles.create(client, {
      user_id: seed.userId, exam_type: 'vocational', target_label: '证书考试',
      exam_date: '2027-05-01', daily_minutes: 45,
    });
    assert.equal(created.version, 1);

    const updated = await examProfiles.update(
      client, created.id, { daily_minutes: 60 }, created.version,
    );
    // version / updated_at 由 set_updated() 触发器维护，仓储层不手写
    assert.equal(updated.version, 2);
    assert.equal(updated.daily_minutes, 60);
    assert.notEqual(updated.updated_at, created.updated_at);

    // 用过期基版号再写 -> 409，并交回服务端当前行
    await assert.rejects(
      () => examProfiles.update(client, created.id, { daily_minutes: 90 }, created.version),
      (err) => {
        assert.equal(err.code, 'conflict');
        assert.equal(err.body.resolution, 'client_merge');
        assert.equal(err.body.current.version, 2);
        assert.equal(err.body.current.daily_minutes, 60);
        return true;
      },
    );
  });
});

test('exam_profiles.update: 空 patch 不发 UPDATE（version 不被触发器无意义 +1）', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const created = await examProfiles.create(client, {
      user_id: seed.userId, exam_type: 'adult_self_study', target_label: '自考',
      exam_date: '2027-04-01', daily_minutes: 40,
    });
    const same = await examProfiles.update(client, created.id, {}, created.version);
    assert.equal(same.version, created.version, '空 patch 不应推进 version');
    assert.equal(same.updated_at, created.updated_at);

    const sameUndefined = await examProfiles.update(
      client, created.id, { target_label: undefined }, created.version,
    );
    assert.equal(sameUndefined.version, created.version, '全 undefined 等同空 patch');
  });
});

test('exam_profiles.archive: 软删后 getById -> 404，listByUser 不再返回该行', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const created = await examProfiles.create(client, {
      user_id: seed.userId, exam_type: 'postgrad', target_label: '待归档目标',
      exam_date: '2027-08-01', daily_minutes: 50,
    });
    const archived = await examProfiles.archive(client, created.id, created.version);
    assert.ok(archived.deleted_at, 'deleted_at 应被写入');

    await assert.rejects(
      () => examProfiles.getById(client, created.id),
      (err) => err.code === 'not_found' && err.statusCode === 404,
    );

    const list = await examProfiles.listByUser(client, seed.userId, { limit: 200 });
    assert.ok(!list.some((r) => r.id === created.id), '软删行不应出现在列表里');
  });
});

test('exam_profiles.write: buildUpdateSet 拒绝写系统列（version 不能被仓储手写）', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const created = await examProfiles.create(client, {
      user_id: seed.userId, exam_type: 'postgrad', target_label: '系统列测试',
      exam_date: '2027-09-01', daily_minutes: 20,
    });
    await assert.rejects(
      () => examProfiles.update(client, created.id, { version: 99 }, created.version),
      (err) => err instanceof TypeError && /系统列/.test(err.message),
    );
    await assert.rejects(
      () => examProfiles.update(client, created.id, { not_a_column: 1 }, created.version),
      (err) => err instanceof TypeError,
    );
  });
});

// ---------------------------------------------------------------------------
// subjects
// ---------------------------------------------------------------------------

test('subjects.create: 落库并可 listByProfile 读回', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const row = await subjects.create(client, {
      exam_profile_id: seed.profileId, name: '数学', kind: 'objective',
    });
    assert.equal(row.name, '数学');
    assert.equal(row.kind, 'objective');
    assert.equal(row.exam_profile_id, seed.profileId);

    const list = await subjects.listByProfile(client, seed.profileId, { limit: 200 });
    assert.ok(list.some((r) => r.id === row.id));
  });
});

test('subjects.create: 同目标下 name 重复 -> 409（field=name）', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    await subjects.create(client, {
      exam_profile_id: seed.profileId, name: '英语', kind: 'objective',
    });
    await assert.rejects(
      () => subjects.create(client, {
        exam_profile_id: seed.profileId, name: '英语', kind: 'subjective',
      }),
      (err) => {
        assert.equal(err.code, 'conflict');
        assert.equal(err.body.field, 'name');
        return true;
      },
    );
  });
});

test('subjects.create: 不同目标下允许同名（查重作用域是父行）', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const other = await examProfiles.create(client, {
      user_id: seed.userId, exam_type: 'final_exam', target_label: '另一目标',
      exam_date: '2027-10-01', daily_minutes: 30,
    });
    const a = await subjects.create(client, {
      exam_profile_id: seed.profileId, name: '政治', kind: 'objective',
    });
    const b = await subjects.create(client, {
      exam_profile_id: other.id, name: '政治', kind: 'objective',
    });
    assert.notEqual(a.id, b.id);
  });
});

test('subjects.create: 父目标不存在 -> 404 not_found（不产生孤儿科目）', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    await assert.rejects(
      () => subjects.create(client, {
        exam_profile_id: '00000000-0000-0000-0000-000000000000',
        name: '孤儿科目', kind: 'objective',
      }),
      (err) => err.code === 'not_found' && err.statusCode === 404,
    );
  });
});

test('subjects.update: 改名撞同名 -> 409；改成自己原名 -> 放行', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const a = await subjects.create(client, {
      exam_profile_id: seed.profileId, name: '物理', kind: 'objective',
    });
    const b = await subjects.create(client, {
      exam_profile_id: seed.profileId, name: '化学', kind: 'objective',
    });

    await assert.rejects(
      () => subjects.update(client, b.id, { name: '物理' }, b.version),
      (err) => err.code === 'conflict' && err.body.field === 'name',
    );

    // 改名成自己原名：excludeId 应把「自己」排除掉，不应误判冲突
    const same = await subjects.update(client, a.id, { name: '物理' }, a.version);
    assert.equal(same.name, '物理');
    assert.equal(same.version, 2, '值未变仍会写一次（非空 patch），version 正常 +1');
  });
});

test('subjects.update: 只改 kind 不触发查重加锁路径', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const row = await subjects.create(client, {
      exam_profile_id: seed.profileId, name: '历史', kind: 'objective',
    });
    const updated = await subjects.update(client, row.id, { kind: 'essay' }, row.version);
    assert.equal(updated.kind, 'essay');
    assert.equal(updated.version, 2);
  });
});

// ---------------------------------------------------------------------------
// knowledge_nodes (+ getTree)
// ---------------------------------------------------------------------------

test('knowledge_nodes.create: 落库，weight_to_target 默认 0 且读回 number', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const row = await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '函数与极限', freq_tag: 'high',
    });
    assert.equal(row.title, '函数与极限');
    assert.equal(row.freq_tag, 'high');
    assert.equal(row.parent_id, null);
    assert.equal(typeof row.weight_to_target, 'number');
    assert.equal(row.weight_to_target, 0);
  });
});

test('knowledge_nodes.create: 同父下 title 重复 -> 409（field=title）；不同父下同名允许', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const root = await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '数据结构',
    });
    await assert.rejects(
      () => knowledgeNodes.create(client, { subject_id: seed.subjectId, title: '数据结构' }),
      (err) => err.code === 'conflict' && err.body.field === 'title',
    );

    // 不同父下同名：允许
    const childA = await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '线性表', parent_id: root.id,
    });
    const childB = await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '线性表', parent_id: null, // 根级同名（不同父）
    });
    assert.ok(childA.id);
    assert.ok(childB.id);
    assert.equal(childA.parent_id, root.id);
  });
});

test('knowledge_nodes.create: 跨科目挂子节点 -> 400 parent_subject_mismatch', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const otherSubject = await subjects.create(client, {
      exam_profile_id: seed.profileId, name: '跨科目测试', kind: 'objective',
    });
    const foreignNode = await knowledgeNodes.create(client, {
      subject_id: otherSubject.id, title: '别的科目的节点',
    });
    await assert.rejects(
      () => knowledgeNodes.create(client, {
        subject_id: seed.subjectId, title: '错挂的子节点', parent_id: foreignNode.id,
      }),
      (err) => err.code === 'parent_subject_mismatch' && err.statusCode === 400,
    );
  });
});

test('knowledge_nodes.getTree: 返回嵌套根节点数组，children 按 created_at 稳定排序', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const root1 = await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '根A',
    });
    const root2 = await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '根B',
    });
    const child1 = await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '子1', parent_id: root1.id,
    });
    const grand = await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '孙1', parent_id: child1.id,
    });

    const tree = await knowledgeNodes.getTree(client, seed.subjectId);

    // 基点 subject 下已有 before 里的「集成测试科目」... 注意 seed.subjectId 是 subject 行，
    // 该 subject 下此前没有节点，所以这里应恰好 2 个根（另加种子前不存在其它节点）
    const titles = tree.map((n) => n.title);
    assert.deepEqual(titles, ['根A', '根B'], '根节点按 created_at ASC 稳定排序');
    assert.equal(tree[0].children.length, 1);
    assert.equal(tree[0].children[0].title, '子1');
    assert.equal(tree[0].children[0].children[0].title, '孙1');
    assert.equal(tree[0].children[0].children[0].children.length, 0);
    assert.equal(tree[1].children.length, 0);

    // 节点保留原始字段（不是只有 title/children）
    assert.equal(tree[0].id, root1.id);
    assert.equal(tree[0].children[0].id, child1.id);
    assert.equal(tree[0].children[0].children[0].id, grand.id);
    assert.equal(tree[0].children[0].parent_id, root1.id);
    assert.equal(root2.id, tree[1].id);
  });
});

test('knowledge_nodes.update: 移到自己的后代下 -> 400 cyclic_parent（递归 CTE 防环）', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const root = await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '环-根',
    });
    const child = await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '环-子', parent_id: root.id,
    });
    const grand = await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '环-孙', parent_id: child.id,
    });

    // 把 root 挂到自己的孙下 -> 形成环，必须拒绝
    await assert.rejects(
      () => knowledgeNodes.update(client, root.id, { parent_id: grand.id }, root.version),
      (err) => err.code === 'cyclic_parent' && err.statusCode === 400,
    );
    // 挂到自己下也拒绝
    await assert.rejects(
      () => knowledgeNodes.update(client, root.id, { parent_id: root.id }, root.version),
      (err) => err.code === 'cyclic_parent',
    );
  });
});

test('knowledge_nodes.update: 移动节点后按新父查重（撞新父下同名 -> 409）', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const parentA = await knowledgeNodes.create(client, { subject_id: seed.subjectId, title: '父A' });
    const parentB = await knowledgeNodes.create(client, { subject_id: seed.subjectId, title: '父B' });
    const moved = await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '重名节点', parent_id: parentA.id,
    });
    await knowledgeNodes.create(client, {
      subject_id: seed.subjectId, title: '重名节点', parent_id: parentB.id,
    });

    // 把移到 parentB 下 -> 与新父下同名节点冲突
    await assert.rejects(
      () => knowledgeNodes.update(client, moved.id, { parent_id: parentB.id }, moved.version),
      (err) => err.code === 'conflict' && err.body.field === 'title',
    );
  });
});

// ---------------------------------------------------------------------------
// capability_layers（customizable gate）
// ---------------------------------------------------------------------------

const LAYERS = [
  { order: 1, key: 'concept', label: '概念理解', desc: '能说出定义' },
  { order: 2, key: 'apply', label: '应用', desc: '能做对基础题' },
];

test('capability_layers.create: layers 以 jsonb 存读，读回是数组（未被解析成字符串）', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const row = await capabilityLayers.create(client, { name: '三层模板', layers: LAYERS });
    assert.equal(row.name, '三层模板');
    assert.equal(row.customizable, true);
    assert.ok(Array.isArray(row.layers), 'jsonb 应读回数组对象');
    assert.equal(row.layers.length, 2);
    assert.equal(row.layers[0].key, 'concept');
    assert.equal(row.layers[1].label, '应用');
  });
});

test('capability_layers.create: layers 非数组 -> 400 LAYERS_REQUIRED', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    await assert.rejects(
      () => capabilityLayers.create(client, { name: '坏模板', layers: null }),
      (err) => err.code === 'LAYERS_REQUIRED' && err.statusCode === 400,
    );
  });
});

test('capability_layers.update: customizable=true 允许改 layers', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const row = await capabilityLayers.create(client, { name: '可改模板', layers: LAYERS });
    const next = [
      { order: 1, key: 'only', label: '唯一层', desc: '' },
    ];
    const updated = await capabilityLayers.update(client, row.id, { layers: next }, row.version);
    assert.equal(updated.layers.length, 1);
    assert.equal(updated.layers[0].key, 'only');
    assert.equal(updated.version, 2);
  });
});

test('capability_layers.update: customizable=false 改 layers -> 400 CUSTOMIZABLE_LOCKED；只改 name 放行', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const locked = await capabilityLayers.create(client, {
      name: '官方锁定模板', layers: LAYERS, customizable: false,
    });

    await assert.rejects(
      () => capabilityLayers.update(client, locked.id, { layers: [] }, locked.version),
      (err) => err.code === 'CUSTOMIZABLE_LOCKED' && err.statusCode === 400,
    );
    await assert.rejects(
      () => capabilityLayers.update(client, locked.id, { customizable: true }, locked.version),
      (err) => err.code === 'CUSTOMIZABLE_LOCKED',
    );

    // 只改 name：gate 放行（改名不改变层级语义）
    const renamed = await capabilityLayers.update(
      client, locked.id, { name: '官方锁定模板(改名)' }, locked.version,
    );
    assert.equal(renamed.name, '官方锁定模板(改名)');
    assert.equal(renamed.version, 2);
  });
});

test('capability_layers.archive: customizable=false 拒绝删除，true 允许', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const locked = await capabilityLayers.create(client, {
      name: '不可删模板', layers: LAYERS, customizable: false,
    });
    await assert.rejects(
      () => capabilityLayers.archive(client, locked.id, locked.version),
      (err) => err.code === 'CUSTOMIZABLE_LOCKED',
    );

    const open = await capabilityLayers.create(client, { name: '可删模板', layers: LAYERS });
    const archived = await capabilityLayers.archive(client, open.id, open.version);
    assert.ok(archived.deleted_at);
    await assert.rejects(
      () => capabilityLayers.getById(client, open.id),
      (err) => err.code === 'not_found',
    );
  });
});

test('capability_layers.list: 分页稳定且只返回未软删行', skipOpt, async () => {
  await inRollback(pool, async (client) => {
    const a = await capabilityLayers.create(client, { name: '列表A', layers: LAYERS });
    const b = await capabilityLayers.create(client, { name: '列表B', layers: LAYERS });
    await capabilityLayers.archive(client, a.id, a.version);

    const page = await capabilityLayers.list(client, { limit: 200 });
    const ids = page.map((r) => r.id);
    assert.ok(!ids.includes(a.id), '软删行不应出现');
    assert.ok(ids.includes(b.id));
  });
});

// ---------------------------------------------------------------------------
// 并发竞态（决策 4 的核心证据）
// ---------------------------------------------------------------------------

test('并发竞态: 两个连接同时创建同名科目 -> 一个成功、另一个 409（FOR UPDATE 串行化）', skipOpt, async () => {
  // 这条用例必须真提交（两个连接要能互相看见），故在 finally 里显式清理。
  const a = await pool.connect();
  const b = await pool.connect();
  const RACE_NAME = `竞态科目-${Date.now()}`;
  let createdId = null;

  try {
    // A：锁父行 -> 写入 -> 提交
    await a.query('BEGIN');
    await subjects.create(a, { exam_profile_id: seed.profileId, name: RACE_NAME, kind: 'objective' });
    createdId = (
      await a.query(`SELECT id FROM subjects WHERE exam_profile_id = $1 AND name = $2`, [
        seed.profileId, RACE_NAME,
      ])
    ).rows[0].id;
    await a.query('COMMIT');

    // B：先尝试同一把父行锁（此时已释放），再查重 -> 必须 409，不能插出第二条
    await b.query('BEGIN');
    await assert.rejects(
      () => subjects.create(b, { exam_profile_id: seed.profileId, name: RACE_NAME, kind: 'objective' }),
      (err) => {
        assert.equal(err.code, 'conflict');
        assert.equal(err.body.field, 'name');
        return true;
      },
    );
    await b.query('ROLLBACK');

    const count = await pool.query(
      `SELECT count(*)::int AS c FROM subjects WHERE exam_profile_id = $1 AND name = $2 AND deleted_at IS NULL`,
      [seed.profileId, RACE_NAME],
    );
    assert.equal(count.rows[0].c, 1, '并发后库中只能有一条同名科目');
  } finally {
    try { await a.query('ROLLBACK'); } catch { /* 已提交或无事务 */ }
    try { await a.query('ROLLBACK'); } catch { /* 忽略 */ }
    a.release();
    b.release();
    if (createdId) {
      await pool.query(`DELETE FROM subjects WHERE id = $1`, [createdId]);
    }
  }
});

test('并发竞态: B 在 A 持锁期间阻塞，A 提交后 B 才继续（锁确实生效）', skipOpt, async () => {
  const a = await pool.connect();
  const b = await pool.connect();
  const LOCK_NAME = `锁序科目-${Date.now()}`;
  let createdId = null;

  try {
    await a.query('BEGIN');
    await subjects.create(a, { exam_profile_id: seed.profileId, name: LOCK_NAME, kind: 'objective' });

    // B 尝试同一父行锁：应阻塞（A 未提交）
    await b.query('BEGIN');
    let bFinished = false;
    const bBlocked = b
      .query(`SELECT id FROM exam_profiles WHERE id = $1 AND deleted_at IS NULL FOR UPDATE`, [
        seed.profileId,
      ])
      .then(() => { bFinished = true; });

    await new Promise((r) => setTimeout(r, 200));
    assert.equal(bFinished, false, 'B 应阻塞在 A 持有的父行锁上');

    await a.query('COMMIT');
    await bBlocked; // A 提交后 B 拿到锁
    assert.equal(bFinished, true, 'A 提交后 B 应被唤醒');

    // 唤醒后 B 查重可见 A 已提交的行 -> 409
    await assert.rejects(
      () => subjects.create(b, { exam_profile_id: seed.profileId, name: LOCK_NAME, kind: 'objective' }),
      (err) => err.code === 'conflict',
    );
    await b.query('ROLLBACK');

    createdId = (
      await pool.query(`SELECT id FROM subjects WHERE exam_profile_id = $1 AND name = $2`, [
        seed.profileId, LOCK_NAME,
      ])
    ).rows[0].id;
  } finally {
    try { await a.query('ROLLBACK'); } catch { /* 忽略 */ }
    try { await b.query('ROLLBACK'); } catch { /* 忽略 */ }
    a.release();
    b.release();
    if (createdId) await pool.query(`DELETE FROM subjects WHERE id = $1`, [createdId]);
  }
});

// ---------------------------------------------------------------------------
// withTransaction 与仓储的组合（确认事务边界真的能回滚仓储写入）
// ---------------------------------------------------------------------------

test('withTransaction: 仓储写入后抛错 -> 整笔回滚，库中无残留', skipOpt, async () => {
  const NAME = `回滚科目-${Date.now()}`;
  await assert.rejects(
    () =>
      withTransaction(pool, async (client) => {
        await subjects.create(client, {
          exam_profile_id: seed.profileId, name: NAME, kind: 'objective',
        });
        throw new Error('force rollback after repo write');
      }),
    /force rollback after repo write/,
  );

  const rows = await pool.query(
    `SELECT count(*)::int AS c FROM subjects WHERE exam_profile_id = $1 AND name = $2`,
    [seed.profileId, NAME],
  );
  assert.equal(rows.rows[0].c, 0, '事务回滚后不应残留任何行');
});
