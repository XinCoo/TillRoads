// server/import/import.integration.test.mjs
// 题路 TillRoad · BE-02：题目导入管线真实 PG 集成测试（T6）
//
// 只有 RUN_PG_INTEGRATION=1 才跑（CI 会设），本机无 PG 时整文件跳过。
//
// 覆盖 T6 要求的三条：
//   1. 上传 Markdown 样本 -> 切题 -> 入库 -> 二次上传 -> duplicates 非空
//   2. 上传扫描版 PDF（无文本层）-> 422 UNSUPPORTED_PDF
//   3. 超限文件（>10MB）-> 413 PAYLOAD_TOO_LARGE
// 另加两条本轮顺手补的边界：
//   4. 空文件 -> 400 EMPTY_CONTENT
//   5. 抽到文字但切不出题 -> 400 EMPTY_CONTENT（错误信息里必须指出四种分隔符）
//
// 为什么必须连真库：
//   「二次上传 duplicates 非空」这条依赖 content_hash 在库里真实存在 ——
//   fake 只能伪造 SELECT 的返回，伪造不出「第一次真的写进去了、
//   第二次的 hash 真的算成同一个」。而 hash 一致正是 AC-Q-02 的核心。

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { createPool } from '../db/pool.mjs';
import { withTransaction } from '../repositories/base.mjs';
import { createApp } from '../index.mjs';
import { normalizeQuestionText } from '../../core/index.mjs';

const RUN = process.env.RUN_PG_INTEGRATION === '1';
const skipOpt = RUN
  ? {}
  : { skip: '本机无 PG；设 RUN_PG_INTEGRATION=1 才运行（CI 会设）' };

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
// ★ m17431：schema 解冻后要连「基线 schema + 增量迁移」一起跑
//   （owner_user_id 列在 migrations/0002_questions_owner.sql 里，不在 schema.sql 里）。
import { FULL_SCHEMA_SQL } from './../db/test_schema.mjs';
const FIXTURES = join(ROOT, 'tests', 'fixtures', 'questions');

let pool;
let app;
let base;
let seed; // { userId, profileId, subjectId }

// ★ m30197：PATCH /questions/batch 是「按 owner 域」改题的端点，要求 ctx.authUserId，
//   所以本文件也必须用 Bearer Token 建立归属（对照 routes/questions.integration.test.mjs）。
//   token→userId 的绑定在 before 里按 seed.userId 设置。
const TOKEN = 'tk_import_owner';

async function req(method, path, body) {
  const init = { method };
  if (body !== undefined) {
    init.headers = { 'Content-Type': 'application/json' };
    init.body = JSON.stringify(body);
  }
  // 每个请求都带 token：导入写入的题会归属于 seed.userId，批量改归属才有题可改。
  init.headers = { ...(init.headers ?? {}), Authorization: `Bearer ${TOKEN}` };
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

/** 把文件读成 base64（导入端点只走 JSON+base64，不走 multipart）。 */
function fileBody(name, extra = {}) {
  const buffer = readFileSync(join(FIXTURES, name));
  return {
    filename: name,
    content_base64: buffer.toString('base64'),
    ...extra,
  };
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

  // 导入的题要挂到真实科目上（questions.subject_id 是 FK），
  // 所以按「user -> exam_profile -> subject」建一条最小链路。
  const c = await pool.connect();
  try {
    const u = await c.query(
      `INSERT INTO users (nickname, timezone, role) VALUES ($1, $2, $3) RETURNING id`,
      ['导入集成测试用户', 'Asia/Shanghai', 'student'],
    );
    const userId = u.rows[0].id;

    const p = await c.query(
      `INSERT INTO exam_profiles (user_id, exam_type, target_label, exam_date, daily_minutes)
       VALUES ($1, $2, $3, $4, $5) RETURNING id`,
      [userId, 'postgrad', '导入集成测试目标', '2027-12-20', 120],
    );
    const profileId = p.rows[0].id;

    const s = await c.query(
      `INSERT INTO subjects (exam_profile_id, name, kind) VALUES ($1, $2, $3) RETURNING id`,
      [profileId, '导入集成测试科目', 'objective'],
    );

    seed = { userId, profileId, subjectId: s.rows[0].id };
  } finally {
    c.release();
  }

  // TOKENS 在 createApp 时读取进闭包，必须先设（设晚了会拿到空数组）。
  process.env.TOKENS = `${TOKEN}:${seed.userId}`;
  app = createApp({ pool });
  await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${app.server.address().port}`;
});

after(async () => {
  if (!RUN || !app) return;

  const c = await pool.connect();
  let cleanupFailure = null;
  try {
    // 先删题（FK 指向 subjects），再删科目/profile/user。硬删，不用软删。
    await c.query(
      `DELETE FROM questions
        WHERE subject_id IN (SELECT s.id FROM subjects s
                              JOIN exam_profiles p ON p.id = s.exam_profile_id
                             WHERE p.user_id = $1)`,
      [seed.userId],
    );
    await c.query(
      `DELETE FROM assets
        WHERE owner_type = 'question'
          AND owner_id NOT IN (SELECT id FROM questions)`,
    );
    await c.query(
      `DELETE FROM subjects
        WHERE exam_profile_id IN (SELECT id FROM exam_profiles WHERE user_id = $1)`,
      [seed.userId],
    );
    await c.query(`DELETE FROM exam_profiles WHERE user_id = $1`, [seed.userId]);
    // m31124：import_batches 有 user_id 外键（无级联），必须比 users 先删。
    // 它不引用 questions，所以顺序上放在这里（题已被上面删掉）就安全。
    await c.query(`DELETE FROM import_batches WHERE user_id = $1`, [seed.userId]);
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
    delete process.env.TOKENS;
  }
  if (cleanupFailure) {
    throw new Error(`after(): 清理数据失败（前置测试已跑完，但库中可能残留测试数据）: ${cleanupFailure.message}`);
  }
});

// ---------------------------------------------------------------------------
// 1) 主链路：上传 -> 切题 -> 入库 -> 二次上传 -> duplicates
// ---------------------------------------------------------------------------
test('POST /questions/import：Markdown 样本首次导入全入库，二次导入全为 duplicates', skipOpt, async () => {
  const body = fileBody('sample-01-markdown.md', {
    mime: 'text/markdown',
    subject_id: seed.subjectId,
  });

  const first = await req('POST', '/questions/import', body);
  assert.equal(first.status, 200, JSON.stringify(first.data));
  assert.equal(first.data.imported, 12, `应导入 12 题，实际 ${first.data.imported}`);
  assert.equal(first.data.duplicates.length, 0, '首次导入不应有重复');
  assert.equal(first.data.stats.kind, 'markdown');
  assert.equal(first.data.stats.total, 12);

  // 库里确实有 12 行，且 content_hash 各不相同
  const c = await pool.connect();
  let rows;
  try {
    const r = await c.query(
      `SELECT id, stem, content_hash, options, answer, is_subjective, source
         FROM questions WHERE subject_id = $1 AND deleted_at IS NULL`,
      [seed.subjectId],
    );
    rows = r.rows;
  } finally {
    c.release();
  }
  assert.equal(rows.length, 12);
  assert.equal(new Set(rows.map((x) => x.content_hash)).size, 12, '12 题的 hash 应互不相同');

  // content_hash 必须与 core/index.mjs 的归一化一致（同一道题换个标点/空白也算同题）
  const anyRow = rows[0];
  const recomputed = normalizeQuestionText(anyRow.stem, anyRow.options, null);
  assert.equal(anyRow.content_hash, recomputed, 'content_hash 必须复用 core 的归一化');

  // options 必须是 jsonb 数组（不是被 PG 数组字面量污染的字符串）
  assert.ok(Array.isArray(anyRow.options), 'options 读回应是数组');
  assert.equal(anyRow.options.length, 4);
  assert.equal(anyRow.source, 'import');
  assert.equal(anyRow.is_subjective, false);

  // 二次上传同一份文件：0 新入库，12 条 duplicates
  const second = await req('POST', '/questions/import', body);
  assert.equal(second.status, 200, JSON.stringify(second.data));
  assert.equal(second.data.imported, 0, '二次导入不应新增');
  assert.equal(second.data.duplicates.length, 12, '二次导入应全部判重');
  for (const d of second.data.duplicates) {
    assert.ok(d.content_hash, 'duplicate 必须带 content_hash');
    assert.ok(d.existing_id, 'duplicate 必须带 existing_id');
    assert.ok(d.stem, 'duplicate 必须带 stem 供前端提示');
  }

  // 库里仍是 12 行（没有因为重复而多插）
  const c2 = await pool.connect();
  let count;
  try {
    const r = await c2.query(
      `SELECT count(*)::int AS n FROM questions WHERE subject_id = $1 AND deleted_at IS NULL`,
      [seed.subjectId],
    );
    count = r.rows[0].n;
  } finally {
    c2.release();
  }
  assert.equal(count, 12);
});

test('POST /questions/import：纯文本样本（折行 + 无 Markdown 语法）同样可导入', skipOpt, async () => {
  const body = fileBody('sample-02-plain.txt', {
    mime: 'text/plain',
    subject_id: seed.subjectId,
  });

  const first = await req('POST', '/questions/import', body);
  assert.equal(first.status, 200, JSON.stringify(first.data));
  assert.equal(first.data.imported, 10);
  assert.equal(first.data.stats.kind, 'text');

  // 折行题干入库后仍然是一条题（不是两条），且保留换行
  const c = await pool.connect();
  let row;
  try {
    const r = await c.query(
      `SELECT stem FROM questions
        WHERE subject_id = $1 AND deleted_at IS NULL AND stem LIKE '%依次填入下列横线处的词语%'`,
      [seed.subjectId],
    );
    row = r.rows[0];
  } finally {
    c.release();
  }
  assert.ok(row, '首题应已入库');
  // ★ 本轮新增清洗：题干里的连续下划线占位符入库前已被替换成「（  ）」
  assert.ok(row.stem.includes('难以（  ）'), `题干占位符应被清洗：${row.stem}`);
  assert.ok(!row.stem.includes('____'), '入库后不应再有连续下划线占位符');
});

// ---------------------------------------------------------------------------
// 2) 扫描版 PDF -> 422（不是 400：请求合法，是能力不支持）
// ---------------------------------------------------------------------------
test('POST /questions/import：扫描版 PDF（无文本层）-> 422 UNSUPPORTED_PDF', skipOpt, async () => {
  const body = fileBody('scanned-no-text.pdf', {
    mime: 'application/pdf',
    subject_id: seed.subjectId,
  });

  const r = await req('POST', '/questions/import', body);
  assert.equal(r.status, 422, JSON.stringify(r.data));
  assert.equal(r.data.error, 'UNSUPPORTED_PDF');
  // 提示必须明确指向「这是扫描版 + V1 才支持 OCR」，而不是含糊的解析失败
  assert.ok(
    typeof r.data.message === 'string' && r.data.message.includes('扫描版'),
    `message 应说明是扫描版：${JSON.stringify(r.data.message)}`,
  );
});

// ---------------------------------------------------------------------------
// 3) 超限 -> 413
// ---------------------------------------------------------------------------
test('POST /questions/import：超过 10MB -> 413 PAYLOAD_TOO_LARGE', skipOpt, async () => {
  const big = Buffer.alloc(10 * 1024 * 1024 + 1024, 0x41); // 'A' * 10MB+1KB
  const r = await req('POST', '/questions/import', {
    filename: 'big.txt',
    mime: 'text/plain',
    content_base64: big.toString('base64'),
    subject_id: seed.subjectId,
  });

  assert.equal(r.status, 413, JSON.stringify(r.data));
  assert.equal(r.data.error, 'PAYLOAD_TOO_LARGE');
  assert.ok(
    typeof r.data.message === 'string' && r.data.message.includes('10MB'),
    `message 应说明上限：${JSON.stringify(r.data.message)}`,
  );
  assert.equal(r.data.limit_bytes, 10 * 1024 * 1024);
});

// ---------------------------------------------------------------------------
// 4) 空文件 -> 400
// ---------------------------------------------------------------------------
test('POST /questions/import：空文件 -> 400 EMPTY_CONTENT', skipOpt, async () => {
  const r = await req('POST', '/questions/import', {
    filename: 'empty.txt',
    mime: 'text/plain',
    content_base64: Buffer.from('').toString('base64'),
    subject_id: seed.subjectId,
  });
  assert.equal(r.status, 400, JSON.stringify(r.data));
  assert.equal(r.data.error, 'EMPTY_CONTENT');
});

// ---------------------------------------------------------------------------
// 5) 抽到文字但切不出题 -> 400，且提示四种分隔符
// ---------------------------------------------------------------------------
test('POST /questions/import：文字里没有四类题号 -> 400 EMPTY_CONTENT（提示分隔符）', skipOpt, async () => {
  const text = '这是一份没有任何题号的说明文档。\n只有几段普通文字，没有编号、没有选项。\n';
  const r = await req('POST', '/questions/import', {
    filename: 'no-separator.txt',
    mime: 'text/plain',
    content_base64: Buffer.from(text, 'utf8').toString('base64'),
    subject_id: seed.subjectId,
  });

  assert.equal(r.status, 400, JSON.stringify(r.data));
  assert.equal(r.data.error, 'EMPTY_CONTENT');
  // 提示必须告诉用户「支持哪四类」，否则用户只能盲试
  assert.ok(
    typeof r.data.message === 'string' && r.data.message.includes('第1题'),
    `message 应列出可用的分隔符：${JSON.stringify(r.data.message)}`,
  );
});

// ---------------------------------------------------------------------------
// 6) 事务性：导入失败不能留下半个批次
// ---------------------------------------------------------------------------
test('导入是原子的：不可解析的 PDF 不会留下任何 questions 行', skipOpt, async () => {
  const c = await pool.connect();
  let before;
  try {
    const r = await c.query(`SELECT count(*)::int AS n FROM questions WHERE deleted_at IS NULL`);
    before = r.rows[0].n;
  } finally {
    c.release();
  }

  const r = await req('POST', '/questions/import', {
    filename: 'broken.pdf',
    mime: 'application/pdf',
    content_base64: Buffer.from('not a pdf at all', 'utf8').toString('base64'),
    subject_id: seed.subjectId,
  });
  assert.equal(r.status, 422, JSON.stringify(r.data));
  assert.equal(r.data.error, 'UNSUPPORTED_PDF');

  const c2 = await pool.connect();
  let after2;
  try {
    const r2 = await c2.query(`SELECT count(*)::int AS n FROM questions WHERE deleted_at IS NULL`);
    after2 = r2.rows[0].n;
  } finally {
    c2.release();
  }
  assert.equal(after2, before, '失败的导入不应改变题目总数');
});

// ---------------------------------------------------------------------------
// 7) 本轮新增：题干清洗 + 题型自动识别 + generation_meta + 新 stats 字段
// ---------------------------------------------------------------------------

/** 直接构造一个 md 文件的导入请求体（不落 fixture 文件）。 */
function textBody(filename, text, extra = {}) {
  return {
    filename,
    mime: 'text/markdown',
    content_base64: Buffer.from(text, 'utf8').toString('base64'),
    ...extra,
  };
}

async function queryQuestions(whereSql, params) {
  const c = await pool.connect();
  try {
    const r = await c.query(
      `SELECT id, stem, type, is_subjective, generation_meta, content_hash
         FROM questions
        WHERE subject_id = $1 AND deleted_at IS NULL AND ${whereSql}`,
      [seed.subjectId, ...params],
    );
    return r.rows;
  } finally {
    c.release();
  }
}

test('导入清洗：题干里的 ____ 占位符入库前变成「（  ）」', skipOpt, async () => {
  const text = [
    '1. 中国的首都是____，上海是____。',
    '答案：北京；上海',
  ].join('\n');

  const r = await req('POST', '/questions/import', textBody('sanitize.md', text, {
    subject_id: seed.subjectId,
  }));
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported, 1);

  const rows = await queryQuestions('stem LIKE $2', ['%中国的首都是%']);
  assert.equal(rows.length, 1);
  assert.ok(rows[0].stem.includes('（  ）'), `占位符应被清洗：${rows[0].stem}`);
  assert.ok(!rows[0].stem.includes('____'), '入库后不应再有连续下划线占位符');
});

test('题型自动识别：单选题落库 type=choice 且 type_source=auto', skipOpt, async () => {
  const text = [
    '1. 下列说法正确的是：',
    'A. 甲说法',
    'B. 乙说法',
    '答案：A',
  ].join('\n');

  const r = await req('POST', '/questions/import', textBody('auto-choice.md', text, {
    subject_id: seed.subjectId,
  }));
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported, 1);

  const rows = await queryQuestions('stem LIKE $2', ['%下列说法正确的是%']);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].type, 'choice');
  assert.equal(rows[0].generation_meta.type_source, 'auto');
  assert.equal(rows[0].generation_meta.detected_type, 'choice');
  assert.equal(rows[0].generation_meta.needs_review, false);
  assert.equal(rows[0].is_subjective, false);
});

test('题型自动识别：判断题落库 type=judge', skipOpt, async () => {
  const text = ['1. 地球围绕太阳运行。', '答案：正确'].join('\n');

  const r = await req('POST', '/questions/import', textBody('auto-judge.md', text, {
    subject_id: seed.subjectId,
  }));
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported, 1);

  const rows = await queryQuestions('stem LIKE $2', ['%地球围绕太阳运行%']);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].type, 'judge');
  assert.equal(rows[0].generation_meta.type_source, 'auto');
  assert.equal(rows[0].generation_meta.needs_review, false);
});

test('题型无法识别：落库用 default_type，generation_meta 标记 needs_review', skipOpt, async () => {
  const text = ['1. 简单的几个字'].join('\n');

  const r = await req('POST', '/questions/import', textBody('auto-unknown.md', text, {
    subject_id: seed.subjectId,
  }));
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported, 1);

  const rows = await queryQuestions('stem LIKE $2', ['%简单的几个字%']);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].type, 'choice', '识别不确定时应退回默认题型');
  assert.equal(rows[0].generation_meta.type_source, 'default');
  assert.equal(rows[0].generation_meta.needs_review, true);
});

test('stats：新增 sanitized / type_detected / type_needs_review 三个字段', skipOpt, async () => {
  const text = [
    '1. 填空题：中国的首都是____。',
    '答案：北京',
    '2. 下列说法正确的是：',
    'A. 甲说法',
    'B. 乙说法',
    '答案：A',
  ].join('\n');

  const r = await req('POST', '/questions/import', textBody('stats.md', text, {
    subject_id: seed.subjectId,
  }));
  assert.equal(r.status, 200, JSON.stringify(r.data));

  const s = r.data.stats;
  assert.equal(typeof s.sanitized, 'number', 'stats.sanitized 应存在');
  assert.equal(typeof s.type_detected, 'number', 'stats.type_detected 应存在');
  assert.equal(typeof s.type_needs_review, 'number', 'stats.type_needs_review 应存在');
  assert.equal(s.sanitized, 1, '只有含占位符的那题被清洗');
  assert.ok(s.type_detected >= 1, '至少有一题自动识别成功');
  // 原有 stats 字段一个都不能少
  for (const key of ['kind', 'mime', 'pages', 'total', 'preamble_lines', 'bytes', 'image_placeholders']) {
    assert.ok(key in s, `stats.${key} 不应被删掉`);
  }
});

// ---------------------------------------------------------------------------
// 8) m30197：导入按 subject 自动匹配科目 + 按 node 自动创建考点树 + 批量改归属
// ---------------------------------------------------------------------------
// 这些用例自己建科目（不依赖 before 的 seed.subjectId），
// 且科目名互不重复 —— resolveSubject 是按「该用户全部 active 科目」做匹配的，
// 同名科目会让断言随用例执行顺序变化。

/** 直接建一个科目，返回 id。after() 会按 exam_profile 连带清理。 */
async function createSubject(name) {
  const c = await pool.connect();
  try {
    const r = await c.query(
      `INSERT INTO subjects (exam_profile_id, name, kind) VALUES ($1, $2, 'objective') RETURNING id`,
      [seed.profileId, name],
    );
    return r.rows[0].id;
  } finally {
    c.release();
  }
}

/** 数「某个科目下」的题，用来验证同一份文件被拆到了不同科目。 */
async function countQuestionsInSubject(subjectId) {
  const c = await pool.connect();
  try {
    const r = await c.query(
      `SELECT count(*)::int AS n FROM questions WHERE subject_id = $1 AND deleted_at IS NULL`,
      [subjectId],
    );
    return r.rows[0].n;
  } finally {
    c.release();
  }
}

/** 列某科目下的考点，用来验证「两级考点被自动创建」。 */
async function listNodes(subjectId) {
  const c = await pool.connect();
  try {
    const r = await c.query(
      `SELECT id, title, parent_id FROM knowledge_nodes
        WHERE subject_id = $1 AND deleted_at IS NULL
        ORDER BY parent_id NULLS FIRST, title`,
      [subjectId],
    );
    return r.rows;
  } finally {
    c.release();
  }
}

test('from_file：3 道「行测」+ 2 道「公基」分别进入对应科目，且两级考点自动创建', skipOpt, async () => {
  const xingceId = await createSubject('行测');
  const gongjiId = await createSubject('公基');

  const r = await req(
    'POST',
    '/questions/import',
    fileBody('sample-04-ai-json.json', { subject_mode: 'from_file' }),
  );
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported, 5, '5 道题应全部入库');

  // D4 的第一条证据：3 道 subject=行测 全部匹配成功。
  assert.equal(r.data.subject_matched.matched_count, 5, '5 道题都应匹配到科目');
  assert.equal(r.data.subject_matched.unmatched_count, 0);
  assert.deepEqual(r.data.subject_matched.unmatched_subjects, []);
  const byName = new Map(
    r.data.subject_matched.matched_subjects.map((s) => [s.name, s.count]),
  );
  assert.equal(byName.get('行测'), 3, '行测应有 3 题');
  assert.equal(byName.get('公基'), 2, '公基应有 2 题');

  // 落库后按科目分开，不是全塞进同一个科目。
  assert.equal(await countQuestionsInSubject(xingceId), 3);
  assert.equal(await countQuestionsInSubject(gongjiId), 2);

  // D4 的第二条证据：node 自动建出的两级考点真实存在于 knowledge_nodes。
  assert.equal(r.data.node_created.created_count, 3, '三条不同路径应各记一次');
  assert.deepEqual(
    [...r.data.node_created.created_paths].sort(),
    ['判断推理/图形推理', '法律/宪法', '资料分析/增长率'].sort(),
  );

  for (const subjectId of [xingceId, gongjiId]) {
    const nodes = await listNodes(subjectId);
    const roots = nodes.filter((n) => n.parent_id === null);
    assert.ok(roots.length >= 1, '每个科目下至少应有一个根考点');
    for (const child of nodes.filter((n) => n.parent_id !== null)) {
      assert.ok(
        roots.some((root) => root.id === child.parent_id),
        `子考点的 parent_id 必须指向同一科目的根考点：${child.title}`,
      );
    }
  }

  // 行测下应是「资料分析 → 增长率」两级 + 「判断推理 → 图形推理」两级。
  const xingceNodes = await listNodes(xingceId);
  const titles = xingceNodes.map((n) => n.title).sort();
  assert.deepEqual(titles, ['资料分析', '图形推理', '判断推理', '增长率'].sort());
});

test('from_file：subject 写「科技常识」而库里叫「科技常识-物理」，模糊匹配成功', skipOpt, async () => {
  const targetId = await createSubject('科技常识-物理');

  const payload = {
    questions: [
      {
        type: 'choice',
        subject: '科技常识',
        node: '',
        stem: '下列哪一项是牛顿第一定律的表述？',
        options: [
          { key: 'A', text: '物体在不受外力时保持匀速直线运动' },
          { key: 'B', text: '力等于质量乘以加速度' },
        ],
        answer: 'A',
      },
    ],
  };
  const r = await req('POST', '/questions/import', {
    filename: 'fuzzy-subject.json',
    mime: 'application/json',
    content_base64: Buffer.from(JSON.stringify(payload), 'utf8').toString('base64'),
    subject_mode: 'from_file',
  });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported, 1);
  assert.equal(r.data.subject_matched.matched_count, 1, '模糊匹配应算作匹配成功');
  assert.equal(r.data.subject_matched.matched_subjects[0].subject_id, targetId);
  assert.equal(await countQuestionsInSubject(targetId), 1);
});

test('from_file：subject 匹配不到时不自动建科目，回落请求里的默认科目', skipOpt, async () => {
  const payload = {
    questions: [
      {
        type: 'judge',
        subject: '完全没建过的科目名',
        node: '不存在的分支/不存在的子级',
        stem: '这段文字用来验证未匹配科目时的兜底行为。',
        answer: '正确',
      },
    ],
  };
  const r = await req('POST', '/questions/import', {
    filename: 'unmatched-subject.json',
    mime: 'application/json',
    content_base64: Buffer.from(JSON.stringify(payload), 'utf8').toString('base64'),
    subject_mode: 'from_file',
    subject_id: seed.subjectId,
  });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported, 1);
  assert.equal(r.data.subject_matched.matched_count, 0);
  assert.equal(r.data.subject_matched.unmatched_count, 1);
  assert.deepEqual(r.data.subject_matched.unmatched_subjects, ['完全没建过的科目名']);

  // 硬约束：绝不自动建科目。
  const c = await pool.connect();
  try {
    const found = await c.query(
      `SELECT count(*)::int AS n FROM subjects WHERE exam_profile_id = $1 AND name = $2`,
      [seed.profileId, '完全没建过的科目名'],
    );
    assert.equal(found.rows[0].n, 0, '匹配失败不得自动创建科目');
  } finally {
    c.release();
  }

  // 兜底科目落到了请求里的 subject_id。
  // 不断言该科目的绝对题数：前面多个用例也往 seed.subjectId 里导入过，
  // 绝对计数会随测试执行顺序变化（CI 上只报第一条，排查成本很高）。
  // 改成按题干定位这一道题，再检查它落在哪个科目。
  const c0 = await pool.connect();
  try {
    const row = await c0.query(
      `SELECT subject_id FROM questions
        WHERE stem LIKE '%验证未匹配科目时的兜底行为%' AND deleted_at IS NULL`,
    );
    assert.equal(row.rows.length, 1);
    assert.equal(row.rows[0].subject_id, seed.subjectId, '未匹配时回落到请求里的默认科目');
  } finally {
    c0.release();
  }
  // 没有科目就没有考点树可挂：node 必须为 null 而不是 500。
  const c2 = await pool.connect();
  try {
    const q = await c2.query(
      `SELECT knowledge_node_id FROM questions
        WHERE subject_id = $1 AND stem LIKE '%验证未匹配科目时的兜底行为%'`,
      [seed.subjectId],
    );
    assert.equal(q.rows.length, 1);
    assert.equal(q.rows[0].knowledge_node_id, null);
  } finally {
    c2.release();
  }
});

test('uniform（默认）：文件里的 subject/node 被忽略，全部进请求指定的科目', skipOpt, async () => {
  const payload = {
    questions: [
      {
        type: 'judge',
        subject: '行测',
        node: '资料分析/增长率',
        stem: 'uniform 模式下这题的 subject 字段应被忽略。',
        answer: '正确',
      },
    ],
  };
  const r = await req('POST', '/questions/import', {
    filename: 'uniform-mode.json',
    mime: 'application/json',
    content_base64: Buffer.from(JSON.stringify(payload), 'utf8').toString('base64'),
    subject_id: seed.subjectId,
  });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.imported, 1);
  assert.equal(r.data.stats.subject_mode, 'uniform', '不传 subject_mode 时按 uniform 处理');
  assert.equal(r.data.subject_matched.matched_count, 0, 'uniform 模式不做科目匹配');
  assert.equal(r.data.node_created.created_count, 0, 'uniform 模式不自动建考点');
  // 同上：不断言绝对题数，只确认这一道题进了请求指定的科目、且没有考点。
  const c1 = await pool.connect();
  try {
    const row = await c1.query(
      `SELECT subject_id, knowledge_node_id FROM questions
        WHERE stem LIKE '%uniform 模式下这题的 subject 字段应被忽略%' AND deleted_at IS NULL`,
    );
    assert.equal(row.rows.length, 1, 'uniform 模式仍应正常入库');
    assert.equal(row.rows[0].subject_id, seed.subjectId);
    assert.equal(row.rows[0].knowledge_node_id, null, 'uniform 模式不解析 node');
  } finally {
    c1.release();
  }
});

test('PATCH /questions/batch：批量改科目会清空旧考点，批量设考点可单改', skipOpt, async () => {
  // 造两道题：直接走仓储插入会让用例依赖 SQL 细节，这里仍用导入 + from_file。
  const srcSubject = await createSubject('批量归属源科目');
  const dstSubject = await createSubject('批量归属目标科目');

  const payload = {
    questions: [
      {
        type: 'judge',
        subject: '批量归属源科目',
        node: '分支A/子级A',
        stem: '批量改归属用例第一题。',
        answer: '正确',
      },
      {
        type: 'judge',
        subject: '批量归属源科目',
        node: '分支A/子级A',
        stem: '批量改归属用例第二题。',
        answer: '错误',
      },
    ],
  };
  const imported = await req('POST', '/questions/import', {
    filename: 'batch-assign.json',
    mime: 'application/json',
    content_base64: Buffer.from(JSON.stringify(payload), 'utf8').toString('base64'),
    subject_mode: 'from_file',
  });
  assert.equal(imported.status, 200, JSON.stringify(imported.data));
  assert.equal(imported.data.imported, 2);

  const c = await pool.connect();
  let ids;
  try {
    const r = await c.query(
      `SELECT id FROM questions WHERE subject_id = $1 AND deleted_at IS NULL ORDER BY stem`,
      [srcSubject],
    );
    ids = r.rows.map((row) => row.id);
  } finally {
    c.release();
  }
  assert.equal(ids.length, 2);

  // ① 只改科目：旧考点必须一起清空（否则题在科目 B、考点却挂科目 A 的子树）。
  const moved = await req('PATCH', '/questions/batch', {
    ids,
    subject_id: dstSubject,
  });
  assert.equal(moved.status, 200, JSON.stringify(moved.data));
  assert.equal(moved.data.updated, 2);
  assert.equal(moved.data.requested, 2);
  assert.equal(moved.data.skipped, 0);
  assert.equal(await countQuestionsInSubject(dstSubject), 2);
  assert.equal(await countQuestionsInSubject(srcSubject), 0);

  const c2 = await pool.connect();
  let nodeId;
  try {
    const left = await c2.query(
      `SELECT id, subject_id, knowledge_node_id FROM questions WHERE id = ANY($1::uuid[])`,
      [ids],
    );
    for (const row of left.rows) {
      assert.equal(row.subject_id, dstSubject);
      assert.equal(row.knowledge_node_id, null, '换科目后旧考点必须清空');
    }

    // ② 单独设考点。
    const n = await c2.query(
      `INSERT INTO knowledge_nodes (subject_id, title) VALUES ($1, $2) RETURNING id`,
      [dstSubject, '批量设置的目标考点'],
    );
    nodeId = n.rows[0].id;
  } finally {
    c2.release();
  }

  const assigned = await req('PATCH', '/questions/batch', {
    ids,
    knowledge_node_id: nodeId,
  });
  assert.equal(assigned.status, 200, JSON.stringify(assigned.data));
  assert.equal(assigned.data.updated, 2);

  // ③ 传 knowledge_node_id: null = 只清考点，科目不动。
  const cleared = await req('PATCH', '/questions/batch', {
    ids,
    knowledge_node_id: null,
  });
  assert.equal(cleared.status, 200, JSON.stringify(cleared.data));
  assert.equal(cleared.data.updated, 2);

  // ④ 两个字段都不给 -> 400 NOTHING_TO_UPDATE（不能变成 no-op 成功）。
  const nothing = await req('PATCH', '/questions/batch', { ids });
  assert.equal(nothing.status, 400, JSON.stringify(nothing.data));
  assert.equal(nothing.data.error, 'NOTHING_TO_UPDATE');

  // ⑤ 空 ids -> 400 EMPTY_IDS。
  const empty = await req('PATCH', '/questions/batch', { ids: [], subject_id: dstSubject });
  assert.equal(empty.status, 400);
  assert.equal(empty.data.error, 'EMPTY_IDS');

  // ⑥ 别人的题静默跳过（公共题 / 他人题都不在 owner 域内）。
  const notMine = await req('PATCH', '/questions/batch', {
    ids: ['00000000-0000-4000-8000-000000000001'],
    subject_id: dstSubject,
  });
  assert.equal(notMine.status, 200);
  assert.equal(notMine.data.updated, 0);
  assert.equal(notMine.data.skipped, 1);
});

// ---------------------------------------------------------------------------
// m31124：导入批次（import_batches + questions.batch_id + GET /import-batches +
//                     DELETE /questions/batch { batch_id }）
// ---------------------------------------------------------------------------

/** 造一份 JSON 题库（题目内容用 prefix 区分，避免两批之间相互判重）。 */
function batchPayload(prefix, stems) {
  return {
    questions: stems.map((stem, i) => ({
      type: 'judge',
      subject: '批次测试科目',
      node: '批次节点',
      stem: `${prefix}${i + 1}：${stem}`,
      answer: '正确',
    })),
  };
}

/** 数某个批次下未被软删的题。 */
async function countQuestionsInBatch(batchId) {
  const c = await pool.connect();
  try {
    const r = await c.query(
      `SELECT count(*)::int AS n FROM questions
        WHERE batch_id = $1 AND deleted_at IS NULL`,
      [batchId],
    );
    return r.rows[0].n;
  } finally {
    c.release();
  }
}

/** 读一个 batch 行。 */
async function readBatchRow(batchId) {
  const c = await pool.connect();
  try {
    const r = await c.query(
      `SELECT id, user_id, filename, question_count FROM import_batches WHERE id = $1`,
      [batchId],
    );
    return r.rows[0] ?? null;
  } finally {
    c.release();
  }
}

test('m31124 批次：导两次得到两个批次，删第一批不影响第二批', skipOpt, async () => {
  // 本轮要求「不改 schema.sql」，所以科目/考点都由导入自己匹配/创建：
  //   先把「批次测试科目」建出来，否则 subject 匹配失败会落到兜底科目（本轮不传兜底）。
  const batchSubjectId = await createSubject('批次测试科目');

  // ── 第一批：3 题 ──────────────────────────────────────────────
  const first = await req('POST', '/questions/import', {
    filename: 'batch-first.json',
    mime: 'application/json',
    content_base64: Buffer.from(
      JSON.stringify(batchPayload('第一批', ['甲题', '乙题', '丙题'])),
      'utf8',
    ).toString('base64'),
    subject_mode: 'from_file',
  });
  assert.equal(first.status, 200, JSON.stringify(first.data));
  assert.equal(first.data.imported, 3);
  assert.ok(first.data.batch_id, '响应要回本次批次 id');
  assert.equal(first.data.import_filename, 'batch-first.json');

  // 题目行：3 行且 batch_id 一致、imported_at 非空。
  assert.equal(await countQuestionsInBatch(first.data.batch_id), 3);
  const c1 = await pool.connect();
  try {
    const r = await c1.query(
      `SELECT batch_id, import_filename, imported_at FROM questions
        WHERE subject_id = $1 AND deleted_at IS NULL AND import_filename = $2`,
      [batchSubjectId, 'batch-first.json'],
    );
    assert.equal(r.rows.length, 3);
    for (const row of r.rows) {
      assert.equal(row.batch_id, first.data.batch_id);
      assert.equal(row.import_filename, 'batch-first.json');
      assert.ok(row.imported_at, 'imported_at 必须被写上');
    }
  } finally {
    c1.release();
  }

  // 批次行：question_count 已回填成 3（不是占位的 0）。
  const firstBatch = await readBatchRow(first.data.batch_id);
  assert.ok(firstBatch, 'import_batches 里要有这一行');
  assert.equal(firstBatch.question_count, 3);
  assert.equal(firstBatch.filename, 'batch-first.json');
  assert.equal(firstBatch.user_id, seed.userId);

  // ── 第二批：2 题 ──────────────────────────────────────────────
  const second = await req('POST', '/questions/import', {
    filename: 'batch-second.json',
    mime: 'application/json',
    content_base64: Buffer.from(
      JSON.stringify(batchPayload('第二批', ['丁题', '戊题'])),
      'utf8',
    ).toString('base64'),
    subject_mode: 'from_file',
  });
  assert.equal(second.status, 200, JSON.stringify(second.data));
  assert.equal(second.data.imported, 2);
  assert.notEqual(second.data.batch_id, first.data.batch_id, '两次导入必须是两个批次');
  assert.equal(await countQuestionsInBatch(second.data.batch_id), 2);

  // ── GET /import-batches：两条，按 created_at DESC（第二批在前） ──
  const listed = await req('GET', '/import-batches?limit=50');
  assert.equal(listed.status, 200, JSON.stringify(listed.data));
  const mine = listed.data.items.filter(
    (b) => b.id === first.data.batch_id || b.id === second.data.batch_id,
  );
  assert.equal(mine.length, 2);
  assert.equal(mine[0].id, second.data.batch_id, '最近的批次排在最前');
  assert.equal(mine[0].question_count, 2);
  assert.equal(mine[1].question_count, 3);
  // 响应不泄漏 token / 内部字段（只白名单四列）。
  assert.deepEqual(
    Object.keys(mine[0]).sort(),
    ['created_at', 'filename', 'id', 'question_count'],
  );

  // ── GET /questions?batch_id=...：只返回该批的题 ─────────────
  const filtered = await req('GET', `/questions?batch_id=${first.data.batch_id}&limit=50`);
  assert.equal(filtered.status, 200, JSON.stringify(filtered.data));
  assert.equal(filtered.data.items.length, 3);
  for (const item of filtered.data.items) {
    assert.ok(String(item.stem).startsWith('第一批'), '按批次筛选只能拿到该批的题');
  }

  // 「全部批次」不带 filter 时，两批题都在。
  const all = await req('GET', '/questions?limit=100');
  assert.equal(all.status, 200);
  const batchStems = all.data.items.filter((q) => String(q.stem).startsWith('第一批') || String(q.stem).startsWith('第二批'));
  assert.equal(batchStems.length, 5);

  // ── DELETE /questions/batch { batch_id }：只删第一批 ────────
  const removed = await req('DELETE', '/questions/batch', { batch_id: first.data.batch_id });
  assert.equal(removed.status, 200, JSON.stringify(removed.data));
  assert.equal(removed.data.deleted, 3);
  assert.equal(removed.data.requested, 3);
  assert.equal(removed.data.skipped, 0);
  assert.equal(removed.data.batch_id, first.data.batch_id);

  assert.equal(await countQuestionsInBatch(first.data.batch_id), 0, '第一批 3 题全部软删');
  assert.equal(await countQuestionsInBatch(second.data.batch_id), 2, '第二批 2 题毫发无伤');

  // 软删而非物理删：行还在，只是 deleted_at 非空（「已删除」档可恢复）。
  const c2 = await pool.connect();
  try {
    const r = await c2.query(
      `SELECT deleted_at FROM questions WHERE batch_id = $1`,
      [first.data.batch_id],
    );
    assert.equal(r.rows.length, 3, '软删不能真的删行');
    for (const row of r.rows) assert.ok(row.deleted_at, 'deleted_at 必须被写上');
  } finally {
    c2.release();
  }

  // 批次行仍在（账本是账本，题是题）：question_count 保留当初导入的 3。
  const stillThere = await readBatchRow(first.data.batch_id);
  assert.ok(stillThere, '删题不删批次档案');
  assert.equal(stillThere.question_count, 3);

  // 再删一次同一批：已无可删，deleted=0 且不报错（幂等）。
  const again = await req('DELETE', '/questions/batch', { batch_id: first.data.batch_id });
  assert.equal(again.status, 200, JSON.stringify(again.data));
  assert.equal(again.data.deleted, 0);
  assert.equal(again.data.requested, 0);
});

test('m31124 批次：手动建题 batch_id 为 null，不出现在任何批次筛选里', skipOpt, async () => {
  const created = await req('POST', '/questions', {
    subject_id: seed.subjectId,
    type: 'judge',
    stem: '手动建的题（无批次）',
    answer: '正确',
  });
  assert.equal(created.status, 201, JSON.stringify(created.data));

  const c = await pool.connect();
  try {
    const r = await c.query(
      `SELECT batch_id, import_filename, imported_at FROM questions WHERE id = $1`,
      [created.data.id],
    );
    assert.equal(r.rows.length, 1);
    assert.equal(r.rows[0].batch_id, null, '手动建题必须没有批次');
    assert.equal(r.rows[0].import_filename, null);
    assert.equal(r.rows[0].imported_at, null);
  } finally {
    c.release();
  }
});

test('m31124 批次：DELETE /questions/batch 参数校验', skipOpt, async () => {
  // 既没有 batch_id 也没有 ids -> 400 EMPTY_IDS（沿用原有 ids 路径的校验）。
  const neither = await req('DELETE', '/questions/batch', {});
  assert.equal(neither.status, 400, JSON.stringify(neither.data));
  assert.equal(neither.data.error, 'EMPTY_IDS');

  // batch_id 不是字符串 -> 400 INVALID_BATCH_ID（不让它落到 PG 的 uuid 铸型变 500）。
  const badType = await req('DELETE', '/questions/batch', { batch_id: 123 });
  assert.equal(badType.status, 400, JSON.stringify(badType.data));
  assert.equal(badType.data.error, 'INVALID_BATCH_ID');

  // 不存在的批次：删不到任何行，但也不能报错（幂等）；账本里本来就没有它。
  const missing = await req('DELETE', '/questions/batch', {
    batch_id: '00000000-0000-4000-8000-0000000000ff',
  });
  assert.equal(missing.status, 200, JSON.stringify(missing.data));
  assert.equal(missing.data.deleted, 0);
  assert.equal(missing.data.requested, 0);
});
