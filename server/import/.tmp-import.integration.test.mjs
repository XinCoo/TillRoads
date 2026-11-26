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

import { createPool } from '../../.tmp-pglite-pool.mjs';
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
